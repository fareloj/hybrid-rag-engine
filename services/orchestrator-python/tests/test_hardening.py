import asyncio
from pathlib import Path

import httpx
import pytest
from pydantic import ValidationError

from app.config import Settings, settings
from app.ingestion import iter_files
from app.main import SearchRequest
from app.resilience import CircuitOpenError, request_json, reset_circuit


def test_settings_reject_invalid_limits_and_urls() -> None:
    with pytest.raises(ValidationError):
        Settings(max_query_chars=0)
    with pytest.raises(ValidationError):
        Settings(search_timeout_seconds=0)
    with pytest.raises(ValidationError):
        Settings(dense_index_url="not-a-url")


def test_search_request_rejects_adversarial_size() -> None:
    with pytest.raises(ValidationError):
        SearchRequest(query="x" * (settings.max_query_chars + 1))


def test_hostile_files_are_skipped(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "max_file_bytes", 32)
    (tmp_path / "valid.py").write_text("print('ok')", encoding="utf-8")
    (tmp_path / "oversized.py").write_text("x" * 33, encoding="utf-8")
    (tmp_path / "binary.py").write_bytes(b"prefix\x00payload")

    records = iter_files(tmp_path)

    assert [record.relative_path for record in records] == ["valid.py"]


def test_request_json_retries_once_then_succeeds() -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(503 if calls == 1 else 200, json={"ok": calls == 2})

    async def run() -> dict[str, bool]:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await request_json(client, "retry-test", "GET", "http://test/", timeout=1, retries=1)

    reset_circuit("retry-test")
    assert asyncio.run(run()) == {"ok": True}
    assert calls == 2


def test_circuit_opens_after_transport_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        raise httpx.ConnectError("dependency down", request=request)

    async def invoke() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await request_json(client, "circuit-test", "GET", "http://test/", timeout=1, retries=0)

    reset_circuit("circuit-test")
    monkeypatch.setattr(settings, "circuit_breaker_failures", 1)
    with pytest.raises(httpx.ConnectError):
        asyncio.run(invoke())
    with pytest.raises(CircuitOpenError):
        asyncio.run(invoke())
    assert calls == 1


def test_client_error_does_not_open_circuit(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(400, json={"error": "bad request"})

    async def invoke() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await request_json(client, "client-error-test", "GET", "http://test/", timeout=1, retries=0)

    reset_circuit("client-error-test")
    monkeypatch.setattr(settings, "circuit_breaker_failures", 1)
    for _ in range(2):
        with pytest.raises(httpx.HTTPStatusError):
            asyncio.run(invoke())
    assert calls == 2
