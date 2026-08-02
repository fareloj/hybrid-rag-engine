#!/usr/bin/env python3
"""Concurrent HTTP load generator for the Hybrid RAG search API."""

from __future__ import annotations

import argparse
import http.client
import json
import math
import subprocess
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


QUERIES = [
    "musica",
    "música 11/01",
    "POST /ingest",
    "repository scanner",
    "reingestao incremental",
    "reingestão incremental",
    "documento orfao",
    "documento órfão",
    "chunks start_line end_line",
    "function that removes orphaned documents after reingestion",
    "what protects requests when downstream services repeatedly fail",
    "class Settings max_query_chars python code",
]


@dataclass
class RequestResult:
    latency_ms: float
    status_code: int | None
    result_status: str | None
    reranked: bool
    error: str | None = None


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[rank]


def parse_size(value: str) -> int:
    units = {
        "B": 1,
        "KB": 1000,
        "MB": 1000**2,
        "GB": 1000**3,
        "KIB": 1024,
        "MIB": 1024**2,
        "GIB": 1024**3,
    }
    value = value.strip().upper()
    for unit in sorted(units, key=len, reverse=True):
        if value.endswith(unit):
            return int(float(value[: -len(unit)].strip()) * units[unit])
    return int(float(value))


class ResourceSampler:
    def __init__(self, interval_seconds: float = 2.0) -> None:
        self.interval_seconds = interval_seconds
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.container_cpu: dict[str, float] = {}
        self.container_memory: dict[str, int] = {}
        self.gpu_memory_mib = 0.0
        self.gpu_utilization = 0.0
        self.gpu_temperature = 0.0
        self.samples = 0

    def start(self) -> None:
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def stop(self) -> dict[str, Any]:
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=self.interval_seconds + 5)
        return {
            "samples": self.samples,
            "peak_container_cpu_percent": self.container_cpu,
            "peak_container_memory_bytes": self.container_memory,
            "peak_gpu_memory_mib": self.gpu_memory_mib,
            "peak_gpu_utilization_percent": self.gpu_utilization,
            "peak_gpu_temperature_c": self.gpu_temperature,
        }

    def _run(self) -> None:
        while not self.stop_event.is_set():
            self._sample_containers()
            self._sample_gpu()
            self.samples += 1
            self.stop_event.wait(self.interval_seconds)

    def _sample_containers(self) -> None:
        try:
            result = subprocess.run(
                ["docker", "stats", "--no-stream", "--format", "{{json .}}"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=15,
                check=True,
            )
            for line in result.stdout.splitlines():
                item = json.loads(line)
                name = item.get("Name", "unknown")
                cpu = float(item.get("CPUPerc", "0").rstrip("%"))
                memory = parse_size(item.get("MemUsage", "0B").split("/")[0])
                self.container_cpu[name] = max(self.container_cpu.get(name, 0.0), cpu)
                self.container_memory[name] = max(self.container_memory.get(name, 0), memory)
        except (OSError, ValueError, subprocess.SubprocessError, json.JSONDecodeError):
            return

    def _sample_gpu(self) -> None:
        try:
            result = subprocess.run(
                [
                    "nvidia-smi",
                    "--query-gpu=memory.used,utilization.gpu,temperature.gpu",
                    "--format=csv,noheader,nounits",
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=10,
                check=True,
            )
            memory, utilization, temperature = [float(part.strip()) for part in result.stdout.splitlines()[0].split(",")]
            self.gpu_memory_mib = max(self.gpu_memory_mib, memory)
            self.gpu_utilization = max(self.gpu_utilization, utilization)
            self.gpu_temperature = max(self.gpu_temperature, temperature)
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            return


def request_worker(
    worker_id: int,
    request_count: int | None,
    deadline: float | None,
    base_url: str,
    timeout_seconds: float,
    rerank_ratio: float,
    top_k: int,
) -> list[RequestResult]:
    parsed = urlsplit(base_url)
    connection_class = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    connection = connection_class(parsed.hostname, parsed.port, timeout=timeout_seconds)
    path = f"{parsed.path.rstrip('/')}/v1/search"
    results: list[RequestResult] = []
    index = 0

    while (request_count is None or index < request_count) and (deadline is None or time.perf_counter() < deadline):
        global_index = (worker_id * 17) + index
        reranked = rerank_ratio > 0 and (global_index % 100) < round(rerank_ratio * 100)
        body = json.dumps(
            {
                "query": QUERIES[global_index % len(QUERIES)],
                "top_k": top_k,
                "use_reranker": reranked,
            },
            ensure_ascii=False,
        ).encode("utf-8")
        started = time.perf_counter()
        try:
            connection.request("POST", path, body=body, headers={"Content-Type": "application/json; charset=utf-8"})
            response = connection.getresponse()
            payload_bytes = response.read()
            latency_ms = (time.perf_counter() - started) * 1000
            payload = json.loads(payload_bytes.decode("utf-8")) if payload_bytes else {}
            error = None if 200 <= response.status < 300 else f"HTTP {response.status}: {payload}"
            results.append(RequestResult(latency_ms, response.status, payload.get("status"), reranked, error))
        except Exception as exc:
            results.append(RequestResult((time.perf_counter() - started) * 1000, None, None, reranked, str(exc)))
            try:
                connection.close()
            finally:
                connection = connection_class(parsed.hostname, parsed.port, timeout=timeout_seconds)
        index += 1

    connection.close()
    return results


def distribute(total: int, workers: int) -> list[int]:
    base, remainder = divmod(total, workers)
    return [base + (1 if index < remainder else 0) for index in range(workers)]


def run_load(args: argparse.Namespace) -> dict[str, Any]:
    from concurrent.futures import ThreadPoolExecutor

    started = time.perf_counter()
    deadline = started + args.duration_seconds if args.duration_seconds else None
    counts = distribute(args.requests, args.concurrency) if args.requests else [None] * args.concurrency
    sampler = ResourceSampler(args.resource_sample_interval)
    sampler.start()
    with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = [
            executor.submit(
                request_worker,
                worker_id,
                counts[worker_id],
                deadline,
                args.base_url,
                args.timeout_seconds,
                args.rerank_ratio,
                args.top_k,
            )
            for worker_id in range(args.concurrency)
        ]
        results = [item for future in futures for item in future.result()]
    resources = sampler.stop()
    elapsed_seconds = time.perf_counter() - started

    latencies = [item.latency_ms for item in results]
    errors = [item for item in results if item.error]
    partials = [item for item in results if item.result_status == "partial"]
    reranked = [item for item in results if item.reranked]
    report = {
        "scenario": args.scenario,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "configuration": {
            "base_url": args.base_url,
            "concurrency": args.concurrency,
            "requested_requests": args.requests,
            "duration_seconds": args.duration_seconds,
            "timeout_seconds": args.timeout_seconds,
            "rerank_ratio": args.rerank_ratio,
            "top_k": args.top_k,
        },
        "results": {
            "requests": len(results),
            "reranked_requests": len(reranked),
            "successes": len(results) - len(errors),
            "errors": len(errors),
            "error_rate": len(errors) / len(results) if results else 1.0,
            "partial_responses": len(partials),
            "partial_rate": len(partials) / len(results) if results else 0.0,
            "elapsed_seconds": elapsed_seconds,
            "throughput_rps": len(results) / elapsed_seconds if elapsed_seconds else 0.0,
            "latency_ms": {
                "min": min(latencies, default=0.0),
                "mean": sum(latencies) / len(latencies) if latencies else 0.0,
                "p50": percentile(latencies, 0.50),
                "p95": percentile(latencies, 0.95),
                "p99": percentile(latencies, 0.99),
                "max": max(latencies, default=0.0),
            },
            "errors_by_message": {},
        },
        "resources": resources,
    }
    for item in errors:
        message = (item.error or "unknown")[:500]
        report["results"]["errors_by_message"][message] = report["results"]["errors_by_message"].get(message, 0) + 1
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://localhost:8090")
    parser.add_argument("--scenario", default="manual")
    parser.add_argument("--concurrency", type=int, default=10)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--requests", type=int)
    mode.add_argument("--duration-seconds", type=float)
    parser.add_argument("--rerank-ratio", type=float, default=0.0)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=60.0)
    parser.add_argument("--resource-sample-interval", type=float, default=2.0)
    parser.add_argument("--max-error-rate", type=float, default=0.01)
    parser.add_argument("--max-partial-rate", type=float, default=0.0)
    parser.add_argument("--max-p95-ms", type=float, default=10_000.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.concurrency < 1:
        parser.error("--concurrency must be positive")
    if args.requests is not None and args.requests < 1:
        parser.error("--requests must be positive")
    if args.duration_seconds is not None and args.duration_seconds <= 0:
        parser.error("--duration-seconds must be positive")
    if not 0 <= args.rerank_ratio <= 1:
        parser.error("--rerank-ratio must be between 0 and 1")
    return args


def main() -> int:
    args = parse_args()
    report = run_load(args)
    output = json.dumps(report, indent=2, ensure_ascii=False)
    print(output)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n", encoding="utf-8")
    results = report["results"]
    passed = (
        results["error_rate"] <= args.max_error_rate
        and results["partial_rate"] <= args.max_partial_rate
        and results["latency_ms"]["p95"] <= args.max_p95_ms
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
