"""/dev-storage: serves the presigned URLs of `storage.LocalStore`, the stand-in for COS.

Not under /v1 and not in the API docs: the app never calls it by name, only through URLs the API
handed out. With a real object store configured every request here is a 404."""

from urllib.parse import quote

from fastapi import APIRouter, Request, Response

from ..errors import AppError
from ..runtime import Run
from ..storage import LocalStore

router = APIRouter(prefix="/dev-storage", include_in_schema=False)


def _local(run) -> LocalStore:
    if not isinstance(run.store, LocalStore):
        raise AppError(404, "not_found", "接口不存在")
    return run.store


def _checked(run, request: Request, method: str, key: str) -> LocalStore:
    store = _local(run)
    if not store.verify(method, key, dict(request.query_params), run.clock.now()):
        raise AppError(403, "signature_invalid", "地址已过期或无效")
    return store


@router.put("/{key:path}")
async def put_part(key: str, request: Request, run: Run) -> Response:
    store = _checked(run, request, "PUT", key)
    limit = run.settings.upload_part_bytes
    data = bytearray()
    async for chunk in request.stream():
        data += chunk
        if len(data) > limit:
            raise AppError(413, "part_too_large", f"每个分片最多 {limit} 字节")
    etag = await store.put_part(key, request.query_params["upload"], int(request.query_params["part"]), bytes(data))
    if etag is None:
        raise AppError(404, "upload_not_found", "这次上传已结束或不存在")
    return Response(status_code=200, headers={"ETag": etag})


@router.get("/{key:path}")
async def get_object(key: str, request: Request, run: Run) -> Response:
    store = _checked(run, request, "GET", key)
    data = await store.read(key)
    if data is None:
        raise AppError(404, "object_not_found", "文件不存在")
    name = quote(request.query_params.get("name", "audio"))
    return Response(
        data,
        media_type="application/octet-stream",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{name}"},
    )
