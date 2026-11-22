"""The one error shape (prd.md §7.3): {"error": {"code", "message", "retryable"}}.

`code` is stable and what the app branches on; `message` is for display (Chinese)."""

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("revive_api")


class AppError(Exception):
    """`keep_changes`: commit what the request wrote before failing (a wrong verification code
    still counts as an attempt). Otherwise the request's transaction is rolled back."""

    def __init__(self, status: int, code: str, message: str, retryable: bool = False, keep_changes: bool = False):
        super().__init__(code)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.keep_changes = keep_changes


def error_body(code: str, message: str, retryable: bool = False) -> dict:
    return {"error": {"code": code, "message": message, "retryable": retryable}}


def install(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def app_error(_: Request, error: AppError) -> JSONResponse:
        return JSONResponse(error_body(error.code, error.message, error.retryable), status_code=error.status)

    @app.exception_handler(RequestValidationError)
    async def invalid(_: Request, error: RequestValidationError) -> JSONResponse:
        fields = ", ".join(".".join(str(p) for p in e["loc"][1:]) or "body" for e in error.errors())
        return JSONResponse(error_body("invalid_request", f"请求不完整或格式不对：{fields}"), status_code=422)

    @app.exception_handler(StarletteHTTPException)
    async def http(_: Request, error: StarletteHTTPException) -> JSONResponse:
        code = {404: "not_found", 405: "method_not_allowed"}.get(error.status_code, "http_error")
        return JSONResponse(
            error_body(code, "接口不存在" if error.status_code == 404 else str(error.detail)),
            status_code=error.status_code,
        )

    @app.exception_handler(Exception)
    async def unexpected(_: Request, error: Exception) -> JSONResponse:
        log.exception("unhandled error")
        return JSONResponse(error_body("internal", "服务暂时出错，请稍后再试", retryable=True), status_code=500)
