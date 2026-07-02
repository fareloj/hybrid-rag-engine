import asyncio
import time
from dataclasses import dataclass
from typing import Any

import httpx

from app.config import settings
from app.observability import log_event, request_headers


class CircuitOpenError(RuntimeError):
    pass


@dataclass
class CircuitState:
    failures: int = 0
    opened_at: float | None = None


_circuits: dict[str, CircuitState] = {}


def _state(service: str) -> CircuitState:
    return _circuits.setdefault(service, CircuitState())


def reset_circuit(service: str) -> None:
    _circuits.pop(service, None)


def _check_circuit(service: str) -> None:
    state = _state(service)
    if state.opened_at is None:
        return
    elapsed = time.monotonic() - state.opened_at
    if elapsed < settings.circuit_breaker_reset_seconds:
        raise CircuitOpenError(f"{service} circuit open after repeated failures")
    log_event("circuit_half_open", service=service)
    state.opened_at = None


def _record_success(service: str) -> None:
    state = _state(service)
    if state.failures or state.opened_at is not None:
        log_event("circuit_closed", service=service)
    state.failures = 0
    state.opened_at = None


def _record_failure(service: str, exc: Exception) -> None:
    state = _state(service)
    state.failures += 1
    if state.failures >= settings.circuit_breaker_failures and state.opened_at is None:
        state.opened_at = time.monotonic()
        log_event("circuit_opened", service=service, failures=state.failures, error=str(exc))


async def request_json(
    client: httpx.AsyncClient,
    service: str,
    method: str,
    url: str,
    *,
    timeout: float,
    json: dict[str, Any] | None = None,
    retries: int | None = None,
) -> dict[str, Any]:
    attempts = (settings.http_retry_count if retries is None else retries) + 1
    last_error: Exception | None = None

    for attempt in range(1, attempts + 1):
        _check_circuit(service)
        try:
            response = await client.request(method, url, json=json, headers=request_headers(), timeout=timeout)
            response.raise_for_status()
            _record_success(service)
            return response.json()
        except httpx.HTTPStatusError as exc:
            last_error = exc
            if exc.response.status_code < 500 or attempt >= attempts:
                _record_failure(service, exc)
                raise
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            last_error = exc
            if attempt >= attempts:
                _record_failure(service, exc)
                raise

        await asyncio.sleep(min(0.25 * attempt, 1.0))

    assert last_error is not None
    _record_failure(service, last_error)
    raise last_error
