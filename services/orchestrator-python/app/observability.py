import contextvars
import hashlib
import json
import time
import uuid
from typing import Any

from fastapi import Request, Response

request_id_var: contextvars.ContextVar[str | None] = contextvars.ContextVar("request_id", default=None)


def current_request_id() -> str:
    value = request_id_var.get()
    if value:
        return value
    generated = uuid.uuid4().hex
    request_id_var.set(generated)
    return generated


def request_headers() -> dict[str, str]:
    return {"X-Request-ID": current_request_id()}


def safe_query(query: str) -> dict[str, Any]:
    normalized = query.strip()
    return {
        "length": len(normalized),
        "sha256_12": hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:12],
    }


def log_event(event: str, **fields: Any) -> None:
    payload = {
        "event": event,
        "request_id": current_request_id(),
        **fields,
    }
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True), flush=True)


async def request_id_middleware(request: Request, call_next: Any) -> Response:
    request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex
    token = request_id_var.set(request_id)
    started = time.perf_counter()
    try:
        log_event("request_started", method=request.method, path=request.url.path)
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        log_event(
            "request_finished",
            method=request.method,
            path=request.url.path,
            status_code=response.status_code,
            latency_ms=(time.perf_counter() - started) * 1000,
        )
        return response
    except Exception as exc:
        log_event(
            "request_failed",
            method=request.method,
            path=request.url.path,
            error_type=exc.__class__.__name__,
            latency_ms=(time.perf_counter() - started) * 1000,
        )
        raise
    finally:
        request_id_var.reset(token)
