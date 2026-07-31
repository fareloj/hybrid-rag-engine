import math
import time
import uuid
from typing import Any

import httpx
import psycopg
from psycopg.types.json import Jsonb

from app.config import settings
from app.dense_index import search_dense_cpp
from app.embeddings import embed_text
from app.evaluation_dataset import CURATED_QUERIES
from app.lexical_index import search_lexical
from app.search import hybrid_search


def expected_item_matches(result: dict[str, Any], expected: dict[str, Any]) -> bool:
    if result.get("path") != expected.get("path"):
        return False
    expected_start = expected.get("start_line")
    expected_end = expected.get("end_line")
    if expected_start is None or expected_end is None:
        return True
    result_start = result.get("start_line")
    result_end = result.get("end_line")
    if result_start is None or result_end is None:
        return False
    return result_start <= expected_end and result_end >= expected_start


def path_matches(result: dict[str, Any], expected: list[dict[str, Any]]) -> bool:
    return any(expected_item_matches(result, item) for item in expected)


def relevance(result: dict[str, Any], expected: list[dict[str, Any]]) -> float:
    result_path = result.get("path")
    if not result_path:
        return 0.0
    for item in expected:
        if item["path"] != result_path:
            continue
        return 1.0 if expected_item_matches(result, item) else 0.0
    return 0.0


def recall_at_k(results: list[dict[str, Any]], expected: list[dict[str, Any]], k: int) -> float:
    if not expected:
        return 0.0
    matched = sum(any(expected_item_matches(result, item) for result in results[:k]) for item in expected)
    return matched / len(expected)


def mrr(results: list[dict[str, Any]], expected: list[dict[str, Any]]) -> float:
    for index, result in enumerate(results, start=1):
        if path_matches(result, expected):
            return 1.0 / index
    return 0.0


def ndcg_at_k(results: list[dict[str, Any]], expected: list[dict[str, Any]], k: int) -> float:
    seen_chunks: set[str] = set()
    matched_expected: set[int] = set()
    gains = []
    for result in results[:k]:
        chunk_key = result.get("chunk_id") or f"{result.get('path')}:{result.get('start_line')}:{result.get('end_line')}"
        if chunk_key in seen_chunks:
            gains.append(0.0)
            continue
        seen_chunks.add(chunk_key)
        matched_index = next(
            (
                index
                for index, item in enumerate(expected)
                if index not in matched_expected and expected_item_matches(result, item)
            ),
            None,
        )
        if matched_index is None:
            gains.append(0.0)
        else:
            matched_expected.add(matched_index)
            gains.append(1.0)
    dcg = sum(gain / math.log2(index + 2) for index, gain in enumerate(gains))
    ideal_gains = [1.0 for _ in expected[:k]]
    idcg = sum(gain / math.log2(index + 2) for index, gain in enumerate(ideal_gains))
    return dcg / idcg if idcg else 0.0


def overlap(left: list[dict[str, Any]], right: list[dict[str, Any]], k: int) -> float:
    left_ids = {item.get("chunk_id") for item in left[:k]}
    right_ids = {item.get("chunk_id") for item in right[:k]}
    union = left_ids | right_ids
    return len(left_ids & right_ids) / len(union) if union else 0.0


def enrich_chunks(conn: psycopg.Connection, results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    chunk_ids = [item["chunk_id"] for item in results if item.get("chunk_id")]
    if not chunk_ids:
        return []
    rows = conn.execute(
        """
        SELECT c.id::text AS chunk_id, d.path, COALESCE(d.language, '') AS language, c.start_line, c.end_line, c.text
        FROM chunks c
        JOIN documents d ON d.id = c.document_id
        WHERE c.id = ANY(%s::uuid[])
        """,
        (chunk_ids,),
    ).fetchall()
    by_id = {row["chunk_id"]: dict(row) for row in rows}
    enriched = []
    for item in results:
        chunk = by_id.get(item.get("chunk_id"))
        if chunk:
            enriched.append({**item, **chunk})
    return enriched


async def search_pgvector(conn: psycopg.Connection, embedding: list[float], top_k: int) -> list[dict[str, Any]]:
    embedding_text = str(embedding)
    rows = conn.execute(
        """
        SELECT chunk_id::text, 1 - (embedding <=> %s::vector) AS score
        FROM embeddings
        WHERE model = %s
        ORDER BY embedding <=> %s::vector, chunk_id
        LIMIT %s
        """,
        (embedding_text, settings.embedding_model, embedding_text, top_k),
    ).fetchall()
    return [
        {"chunk_id": row["chunk_id"], "score": float(row["score"]), "rank": index + 1, "source": "pgvector"}
        for index, row in enumerate(rows)
    ]


async def run_curated_evaluation(conn: psycopg.Connection, top_k: int = 5, include_reranker: bool = True) -> dict[str, Any]:
    modes = ["dense_cpp", "pgvector", "bm25", "rrf"]
    if include_reranker:
        modes.append("rerank")
    per_query: list[dict[str, Any]] = []
    aggregate: dict[str, dict[str, float]] = {
        mode: {"recall_at_k": 0.0, "mrr": 0.0, "ndcg_at_k": 0.0, "latency_ms": 0.0}
        for mode in modes
    }

    async with httpx.AsyncClient() as client:
        for item in CURATED_QUERIES:
            query = item["query"]
            expected = item["expected"]
            query_result: dict[str, Any] = {"id": item["id"], "query": query, "expected": expected, "tags": item["tags"], "modes": {}}

            embedding = await embed_text(client, query)
            mode_results: dict[str, list[dict[str, Any]]] = {}

            started = time.perf_counter()
            mode_results["dense_cpp"] = enrich_chunks(conn, (await search_dense_cpp(embedding, top_k)).get("results", []))
            dense_latency = (time.perf_counter() - started) * 1000

            started = time.perf_counter()
            mode_results["pgvector"] = enrich_chunks(conn, await search_pgvector(conn, embedding, top_k))
            pg_latency = (time.perf_counter() - started) * 1000

            started = time.perf_counter()
            mode_results["bm25"] = (await search_lexical(query, top_k)).get("results", [])
            bm25_latency = (time.perf_counter() - started) * 1000

            started = time.perf_counter()
            mode_results["rrf"] = (await hybrid_search(conn, query, top_k, 20, 20, 60, 20, False)).get("results", [])
            rrf_latency = (time.perf_counter() - started) * 1000

            latencies = {"dense_cpp": dense_latency, "pgvector": pg_latency, "bm25": bm25_latency, "rrf": rrf_latency}

            if include_reranker:
                started = time.perf_counter()
                mode_results["rerank"] = (await hybrid_search(conn, query, top_k, 20, 20, 60, 20, True)).get("results", [])
                latencies["rerank"] = (time.perf_counter() - started) * 1000

            for mode in modes:
                results = mode_results[mode]
                metrics = {
                    "recall_at_k": recall_at_k(results, expected, top_k),
                    "mrr": mrr(results, expected),
                    "ndcg_at_k": ndcg_at_k(results, expected, top_k),
                    "latency_ms": latencies[mode],
                    "top_paths": [result.get("path") for result in results[:top_k]],
                }
                query_result["modes"][mode] = metrics
                for metric in ("recall_at_k", "mrr", "ndcg_at_k", "latency_ms"):
                    aggregate[mode][metric] += float(metrics[metric])

            query_result["overlap"] = {
                "dense_cpp_vs_pgvector": overlap(mode_results["dense_cpp"], mode_results["pgvector"], top_k),
                "rrf_vs_bm25": overlap(mode_results["rrf"], mode_results["bm25"], top_k),
                "rrf_vs_rerank": overlap(mode_results["rrf"], mode_results.get("rerank", []), top_k) if include_reranker else None,
            }
            per_query.append(query_result)

    count = len(CURATED_QUERIES)
    for mode in modes:
        for metric in aggregate[mode]:
            aggregate[mode][metric] = aggregate[mode][metric] / count if count else 0.0

    metrics = {
        "top_k": top_k,
        "query_count": count,
        "modes": modes,
        "aggregate": aggregate,
        "per_query": per_query,
    }
    conn.execute(
        "INSERT INTO evaluation_runs(id, name, metrics) VALUES (%s, %s, %s)",
        (uuid.uuid4(), "curated-stage11", Jsonb(metrics)),
    )
    conn.commit()
    return metrics
