"""Exercise the pull command with a synthetic card and the real notification parser."""
import asyncio
from types import SimpleNamespace

import pytest

import dnote_protocol as P

NAME = "sample.opus"
AUDIO = bytes([0x48]) * 40


class Card:
    def __init__(self, size, chunks, on_delete=None):
        self.size = size
        self.chunks = chunks
        self.on_delete = on_delete
        self.deleted = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        pass

    async def start_notify(self, _uuid, notify):
        self.notify = notify

    async def write_gatt_char(self, _uuid, frame, response):
        cmd = frame[1]
        if cmd == P.Cmd.QUERY_FILE_LIST:
            replies = [{"index": 0, "size": self.size, "name": NAME}, {"end": 1}]
        elif cmd == P.Cmd.REQUEST_FILE_DATA:
            assert frame == P.frame_request_file(NAME)
            replies = [bytes([flag]) + offset.to_bytes(4, "big") + data
                       for flag, offset, data in self.chunks]
        elif cmd == P.Cmd.DELETE_FILE:
            assert frame == P.frame_delete_file(NAME)
            self.deleted.append(NAME)
            if self.on_delete:
                self.on_delete()
            replies = [b"\x01"]
        else:
            raise AssertionError(cmd)
        for body in replies:
            self.notify(None, P.build_frame(cmd, body))


def pull(dnote, card, out, monkeypatch, *, delete=True):
    monkeypatch.setattr(dnote, "BleakClient", lambda addr: card)
    args = SimpleNamespace(address="test", out=out, name=None, delete=delete)
    asyncio.run(dnote.cmd_pull(args))


@pytest.mark.parametrize("size,chunks", [
    (80, [(0, 0, AUDIO), (0x21, 80, AUDIO)]),
    (80, [(0, 0, AUDIO), (0x21, 0, AUDIO)]),
    (80, [(0x20, 0, AUDIO)]),
    (39, [(0x20, 0, AUDIO)]),
    (40, [(0x40, 0, b""), (0x20, 0, AUDIO)]),
    (None, [(0x20, 0, AUDIO)]),
], ids=["gap", "repeated-offset", "early-eof", "past-end", "refusal", "missing-size"])
def test_pull_rejects_bad_transfer_before_saving_or_deleting(dnote, tmp_path, monkeypatch, size, chunks):
    card = Card(size, chunks)
    with pytest.raises(SystemExit):
        pull(dnote, card, tmp_path, monkeypatch)
    assert not card.deleted
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("raw", [b"", b"partial", b"encryt"])
def test_pull_keeps_undecodable_bytes_and_card_copy(dnote, tmp_path, monkeypatch, raw):
    card = Card(len(raw), [(0x20, 0, raw)])
    with pytest.raises(SystemExit):
        pull(dnote, card, tmp_path, monkeypatch)
    assert not card.deleted
    assert (tmp_path / (NAME + ".raw")).read_bytes() == raw
    assert not (tmp_path / "sample.ogg").exists()


def test_delete_only_after_both_copies_exist_and_retry_is_idempotent(dnote, tmp_path, monkeypatch, fixture_bytes):
    raw = fixture_bytes("encrypted.bin")
    chunks = [(0 if offset == 0 else 0x11, offset, raw[offset:offset + 200])
              for offset in range(0, len(raw), 200)]
    flag, offset, data = chunks[-1]
    chunks[-1] = (0x22, offset, data)
    chunks.append((0x10, 0, b"late"))

    def check_saved():
        assert (tmp_path / (NAME + ".raw")).read_bytes() == raw
        assert (tmp_path / "sample.ogg").read_bytes() == fixture_bytes("expected_ogg.bin")

    card = Card(len(raw), chunks, on_delete=check_saved)
    pull(dnote, card, tmp_path, monkeypatch)
    pull(dnote, card, tmp_path, monkeypatch)
    assert card.deleted == [NAME, NAME]


def test_default_pull_writes_only_ogg(dnote, tmp_path, monkeypatch):
    card = Card(40, [(0x20, 0, AUDIO)])
    pull(dnote, card, tmp_path, monkeypatch, delete=False)
    assert (tmp_path / "sample.ogg").read_bytes().startswith(b"OggS")
    assert not (tmp_path / (NAME + ".raw")).exists()
    assert not card.deleted


@pytest.mark.parametrize("existing", [NAME + ".raw", "sample.ogg"])
def test_existing_different_copy_is_preserved(dnote, tmp_path, monkeypatch, existing):
    card = Card(40, [(0x20, 0, AUDIO)])
    (tmp_path / existing).write_bytes(b"earlier backup")
    with pytest.raises(FileExistsError):
        pull(dnote, card, tmp_path, monkeypatch)
    assert (tmp_path / existing).read_bytes() == b"earlier backup"
    assert not card.deleted


def test_write_failure_keeps_card_and_cleans_incomplete_copy(dnote, tmp_path, monkeypatch):
    card = Card(40, [(0x20, 0, AUDIO)])

    def fail_sync(_):
        raise OSError("disk full")

    monkeypatch.setattr(dnote.os, "fsync", fail_sync)
    with pytest.raises(OSError, match="disk full"):
        pull(dnote, card, tmp_path, monkeypatch)
    assert not card.deleted
    assert not list(tmp_path.iterdir())


def test_list_timeout_cannot_turn_a_partial_listing_into_a_completed_pull(dnote):
    class PartialList(Card):
        async def write_gatt_char(self, _uuid, frame, response):
            self.notify(None, P.build_frame(P.Cmd.QUERY_FILE_LIST, {"name": NAME, "index": 0, "size": 40}))

    async def run():
        session = dnote.Session(PartialList(40, []))
        await session.start()
        with pytest.raises(asyncio.TimeoutError):
            await session.file_list(timeout=0.01)

    asyncio.run(run())


def test_stale_staging_file_does_not_block_new_pull(dnote, tmp_path, monkeypatch):
    (tmp_path / ".dnote-pending-orphan").write_bytes(b"incomplete")
    card = Card(40, [(0x20, 0, AUDIO)])
    pull(dnote, card, tmp_path, monkeypatch)
    assert card.deleted == [NAME]
    assert (tmp_path / (NAME + ".raw")).read_bytes() == AUDIO


@pytest.mark.parametrize("other", [AUDIO, b"other card"], ids=["same-data", "different-data"])
def test_concurrent_writers_never_replace_a_completed_copy(dnote, tmp_path, monkeypatch, other):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier

    publish_method = "rename" if dnote.os.name == "nt" else "link"
    real_publish = getattr(dnote.os, publish_method)
    ready = Barrier(2)

    def publish_at_once(src, dst):
        ready.wait(timeout=5)
        return real_publish(src, dst)

    monkeypatch.setattr(dnote.os, publish_method, publish_at_once)
    path = tmp_path / (NAME + ".raw")
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = [pool.submit(dnote._save_copy, path, audio) for audio in (AUDIO, other)]
    errors = [result.exception() for result in results if result.exception()]
    if other == AUDIO:
        assert not errors
    else:
        assert len(errors) == 1 and isinstance(errors[0], FileExistsError)
    assert path.read_bytes() in (AUDIO, other)
    assert list(tmp_path.iterdir()) == [path]


def test_unsupported_publication_keeps_card_and_releases_output_name(dnote, tmp_path, monkeypatch):
    import errno
    if dnote.os.name == "nt":
        pytest.skip("Windows uses exclusive rename")

    def unsupported_link(src, dst):
        raise OSError(errno.EOPNOTSUPP, "hard links unsupported")

    monkeypatch.setattr(dnote.os, "link", unsupported_link)
    card = Card(40, [(0x20, 0, AUDIO)])
    with pytest.raises(OSError, match="硬链接"):
        pull(dnote, card, tmp_path, monkeypatch)
    assert not card.deleted
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("collision", [False, True], ids=["new-export", "existing-backup"])
def test_ordinary_pull_on_volume_without_hardlinks(dnote, tmp_path, monkeypatch, collision):
    import errno
    if dnote.os.name == "nt":
        pytest.skip("Windows uses exclusive rename")

    target = tmp_path / "sample.ogg"

    def unsupported_link(src, dst):
        if collision:
            target.write_bytes(b"earlier backup")
        raise OSError(errno.EOPNOTSUPP, "hard links unsupported")

    monkeypatch.setattr(dnote.os, "link", unsupported_link)
    card = Card(40, [(0x20, 0, AUDIO)])
    if collision:
        with pytest.raises(FileExistsError):
            pull(dnote, card, tmp_path, monkeypatch, delete=False)
        assert target.read_bytes() == b"earlier backup"
    else:
        pull(dnote, card, tmp_path, monkeypatch, delete=False)
        assert target.read_bytes().startswith(b"OggS")
    assert not card.deleted
    assert list(tmp_path.iterdir()) == [target]


def test_concurrent_exports_without_hardlinks_never_overwrite(dnote, tmp_path, monkeypatch):
    # Two pulls of different same-name recordings to one exFAT folder: both pass the "name is
    # free" check before either writes. The second must not replace the first.
    import errno
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier
    if dnote.os.name == "nt":
        pytest.skip("Windows uses exclusive rename")

    ready = Barrier(2)

    def unsupported_link(src, dst):
        ready.wait(timeout=5)
        raise OSError(errno.EOPNOTSUPP, "hard links unsupported")

    monkeypatch.setattr(dnote.os, "link", unsupported_link)
    path = tmp_path / "sample.ogg"
    other = b"another card's recording"
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = [pool.submit(dnote._save_copy, path, audio, require_exclusive=False) for audio in (AUDIO, other)]
    errors = [result.exception() for result in results if result.exception()]
    assert len(errors) == 1 and isinstance(errors[0], FileExistsError)
    winner = AUDIO if results[0].exception() is None else other
    assert path.read_bytes() == winner
    assert list(tmp_path.iterdir()) == [path]


def test_client_never_publishes_by_replacing():
    # Guard: os.replace and shutil.move overwrite an existing file, so a saved recording could be
    # lost. Publish with os.link / O_EXCL (see dnote._save_copy) and verify an existing name instead.
    import pathlib
    import re
    root = pathlib.Path(__file__).resolve().parents[1]
    offenders = [f"{path.name}:{number}" for path in sorted(root.glob("*.py"))
                 for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
                 if re.search(r"\b(os\.replace|shutil\.move)\(", line)]
    assert not offenders, f"use dnote._save_copy instead of replacing files: {offenders}"
