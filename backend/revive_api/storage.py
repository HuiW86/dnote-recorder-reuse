"""Where recording audio lives (prd.md §7.2 录音与上传, ADR-003).

The app uploads straight to object storage with presigned multipart URLs, so audio never passes
through the API server, and an interrupted upload resumes from the parts already stored. The
interface follows what Tencent COS offers (InitiateMultipartUpload, presigned UploadPart,
ListParts, CompleteMultipartUpload, AbortMultipartUpload, presigned GetObject, DeleteObject).

`LocalStore` stands in until there is a COS account: files on disk, URLs signed with an HMAC
and served by this app under /dev-storage (routers/dev_storage.py). Production refuses it."""

import asyncio
import hashlib
import hmac
import secrets
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Protocol
from urllib.parse import quote, urlencode


@dataclass(frozen=True)
class StoredPart:
    number: int
    etag: str
    size: int


class UploadMismatch(Exception):
    """The parts named on completion are not the parts that were stored (missing, wrong ETag)."""


class StorageUnavailable(Exception):
    """The store could not be reached or failed; worth retrying."""


class ObjectStore(Protocol):
    async def start_upload(self, key: str, content_type: str) -> str:
        """Begins a multipart upload and returns its id."""
        ...

    def part_url(self, key: str, upload_id: str, part_number: int, expires_at: datetime) -> str:
        """A URL the client PUTs one part to. The response's ETag header names the part."""
        ...

    async def uploaded_parts(self, key: str, upload_id: str) -> list[StoredPart] | None:
        """The parts stored so far, by number. None when the store does not know the upload
        (finished, aborted, or expired by a lifecycle rule)."""
        ...

    async def finish_upload(self, key: str, upload_id: str, parts: list[tuple[int, str]]) -> int:
        """Joins the parts (number, ETag) in order into the object and returns its size.
        Raises UploadMismatch when a part is missing or its ETag differs."""
        ...

    async def abort_upload(self, key: str, upload_id: str) -> None:
        """Drops an unfinished upload and its parts. Doing it twice is not an error."""
        ...

    def download_url(self, key: str, expires_at: datetime, filename: str) -> str:
        """A URL that serves the object as an attachment named `filename`."""
        ...

    async def delete(self, key: str) -> None:
        """Removes the object. Removing a missing object is not an error."""
        ...


def etag_of(data: bytes) -> str:
    return '"' + hashlib.sha256(data).hexdigest()[:32] + '"'


class LocalStore:
    """Objects under `root/objects`, unfinished uploads under `root/uploads/<id>`. URLs point at
    `base_url`/dev-storage/<key> with an expiry and an HMAC over everything that matters."""

    PREFIX = "/dev-storage/"

    def __init__(self, root: Path, base_url: str, secret: bytes):
        self.root = root
        self.base_url = base_url.rstrip("/")
        self._secret = secret

    # MARK: Signing

    def signature(self, method: str, key: str, fields: dict[str, str]) -> str:
        message = "\n".join([method, key, *(f"{k}={fields[k]}" for k in sorted(fields))])
        return hmac.new(self._secret, message.encode(), hashlib.sha256).hexdigest()

    def verify(self, method: str, key: str, query: dict[str, str], now: datetime) -> bool:
        fields = {k: v for k, v in query.items() if k != "sig"}
        expected = self.signature(method, key, fields)
        if not hmac.compare_digest(expected, query.get("sig", "")):
            return False
        try:
            return int(fields["exp"]) > int(now.timestamp())
        except (KeyError, ValueError):
            return False

    def _url(self, method: str, key: str, fields: dict[str, str]) -> str:
        query = urlencode(fields | {"sig": self.signature(method, key, fields)})
        return f"{self.base_url}{self.PREFIX}{quote(key)}?{query}"

    # MARK: Paths

    def _object(self, key: str) -> Path:
        path = (self.root / "objects" / key).resolve()
        if not path.is_relative_to((self.root / "objects").resolve()):
            raise ValueError("object key escapes the store")
        return path

    def _upload(self, upload_id: str) -> Path:
        if not upload_id.isalnum():
            raise ValueError("bad upload id")
        return self.root / "uploads" / upload_id

    # MARK: ObjectStore

    async def start_upload(self, key: str, content_type: str) -> str:
        upload_id = secrets.token_hex(16)

        def make() -> None:
            folder = self._upload(upload_id)
            folder.mkdir(parents=True)
            (folder / "key").write_text(key)
            (folder / "content-type").write_text(content_type)

        await asyncio.to_thread(make)
        return upload_id

    def part_url(self, key: str, upload_id: str, part_number: int, expires_at: datetime) -> str:
        fields = {"upload": upload_id, "part": str(part_number), "exp": str(int(expires_at.timestamp()))}
        return self._url("PUT", key, fields)

    async def put_part(self, key: str, upload_id: str, part_number: int, data: bytes) -> str | None:
        """Used by the dev-storage route. None when the upload is unknown or is for another key."""

        def write() -> str | None:
            folder = self._upload(upload_id)
            if not (folder / "key").is_file() or (folder / "key").read_text() != key:
                return None
            (folder / f"{part_number:05d}").write_bytes(data)
            return etag_of(data)

        return await asyncio.to_thread(write)

    async def uploaded_parts(self, key: str, upload_id: str) -> list[StoredPart] | None:
        def scan() -> list[StoredPart] | None:
            folder = self._upload(upload_id)
            if not (folder / "key").is_file() or (folder / "key").read_text() != key:
                return None
            parts = []
            for path in sorted(folder.glob("[0-9]" * 5)):
                data = path.read_bytes()
                parts.append(StoredPart(int(path.name), etag_of(data), len(data)))
            return parts

        return await asyncio.to_thread(scan)

    async def finish_upload(self, key: str, upload_id: str, parts: list[tuple[int, str]]) -> int:
        stored = {p.number: p for p in await self.uploaded_parts(key, upload_id) or []}
        for number, etag in parts:
            if number not in stored or stored[number].etag != etag:
                raise UploadMismatch(f"part {number}")

        def join() -> int:
            folder = self._upload(upload_id)
            target = self._object(key)
            target.parent.mkdir(parents=True, exist_ok=True)
            partial = target.with_name(target.name + ".partial")
            with partial.open("wb") as out:
                for number, _ in sorted(parts):
                    out.write((folder / f"{number:05d}").read_bytes())
            partial.replace(target)
            shutil.rmtree(folder)
            return target.stat().st_size

        return await asyncio.to_thread(join)

    async def abort_upload(self, key: str, upload_id: str) -> None:
        await asyncio.to_thread(shutil.rmtree, self._upload(upload_id), True)

    def download_url(self, key: str, expires_at: datetime, filename: str) -> str:
        return self._url("GET", key, {"exp": str(int(expires_at.timestamp())), "name": filename})

    async def read(self, key: str) -> bytes | None:
        """Used by the dev-storage route."""

        def load() -> bytes | None:
            path = self._object(key)
            return path.read_bytes() if path.is_file() else None

        return await asyncio.to_thread(load)

    async def delete(self, key: str) -> None:
        await asyncio.to_thread(self._object(key).unlink, True)
