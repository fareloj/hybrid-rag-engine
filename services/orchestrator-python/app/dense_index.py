import json
import time
from typing import Any

import httpx
import psycopg

from app.config import settings
from app.resilience import request_json


def parse_pgvector(value: str) -> list[float]:
    parsed = json.loads(value)
    return [float(item) for item in parsed]


def load_vectors(conn: psycopg.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT chunk_id::text, embedding::text AS embedding
        FROM embeddings
        WHERE model = %s
        ORDER BY chunk_id
        """,
        (settings.embedding_model,),
    ).fetchall()
    return [
        {
            "chunk_id": row["chunk_id"],
            "values": parse_pgvector(row["embedding"]),
        }
        for row in rows
    ]


async def reindex_dense(conn: psycopg.Connection) -> dict[str, Any]:
    vectors = load_vectors(conn)
    async with httpx.AsyncClient() as client:
        return await request_json(
            client,
            "dense_index",
            "POST",
            f"{settings.dense_index_url}/index",
            json={"vectors": vectors},
            timeout=settings.index_timeout_seconds,
        )


async def search_dense_cpp(embedding: list[float], top_k: int, mode: str | None = None) -> dict[str, Any]:
    async with httpx.AsyncClient() as client:
        return await request_json(
            client,
            "dense_index",
            "POST",
            f"{settings.dense_index_url}/search",
            json={"embedding": embedding, "top_k": top_k, "mode": mode or settings.dense_search_mode},
            timeout=settings.search_timeout_seconds,
        )


async def compare_dense_for_chunk(conn: psycopg.Connection, chunk_id: str, top_k: int) -> dict[str, Any]:
    row = conn.execute(
        """
        SELECT embedding::text AS embedding
        FROM embeddings
        WHERE chunk_id = %s AND model = %s
        """,
        (chunk_id, settings.embedding_model),
    ).fetchone()
    if row is None:
        raise ValueError(f"embedding not found for chunk_id {chunk_id}")

    embedding_text = row["embedding"]
    embedding = parse_pgvector(embedding_text)
    cpp_start = time.perf_counter()
    cpp_results = (await search_dense_cpp(embedding, top_k, "linear"))["results"]
    cpp_latency_ms = (time.perf_counter() - cpp_start) * 1000
    pg_start = time.perf_counter()
    pgvector_results = conn.execute(
        """
        SELECT chunk_id::text, 1 - (embedding <=> %s::vector) AS score
        FROM embeddings
        WHERE model = %s
        ORDER BY embedding <=> %s::vector, chunk_id
        LIMIT %s
        """,
        (embedding_text, settings.embedding_model, embedding_text, top_k),
    ).fetchall()
    pgvector_latency_ms = (time.perf_counter() - pg_start) * 1000
    pgvector = [
        {
            "chunk_id": row["chunk_id"],
            "score": float(row["score"]),
            "rank": index + 1,
            "source": "pgvector",
        }
        for index, row in enumerate(pgvector_results)
    ]
    return {
        "chunk_id": chunk_id,
        "top_k": top_k,
        "cpp": cpp_results,
        "pgvector": pgvector,
        "overlap": len({item["chunk_id"] for item in cpp_results} & {item["chunk_id"] for item in pgvector}),
        "latency_ms": {
            "cpp": cpp_latency_ms,
            "pgvector": pgvector_latency_ms,
        },
    }


async def benchmark_dense(conn: psycopg.Connection, sample_size: int, top_k: int) -> dict[str, Any]:
    rows = conn.execute(
        """
        SELECT chunk_id::text
        FROM embeddings
        WHERE model = %s
        ORDER BY chunk_id
        LIMIT %s
        """,
        (settings.embedding_model, sample_size),
    ).fetchall()
    comparisons = []
    for row in rows:
        comparisons.append(await compare_dense_for_chunk(conn, row["chunk_id"], top_k))

    if not comparisons:
        return {
            "sample_size": 0,
            "top_k": top_k,
            "avg_overlap": 0,
            "avg_cpp_latency_ms": 0,
            "avg_pgvector_latency_ms": 0,
            "comparisons": [],
        }

    return {
        "sample_size": len(comparisons),
        "top_k": top_k,
        "avg_overlap": sum(item["overlap"] for item in comparisons) / len(comparisons),
        "avg_cpp_latency_ms": sum(item["latency_ms"]["cpp"] for item in comparisons) / len(comparisons),
        "avg_pgvector_latency_ms": sum(item["latency_ms"]["pgvector"] for item in comparisons) / len(comparisons),
        "comparisons": comparisons,
    }


async def benchmark_ann(conn: psycopg.Connection, sample_size: int, top_k: int) -> dict[str, Any]:
    rows = conn.execute(
        """
        SELECT chunk_id::text, embedding::text AS embedding
        FROM embeddings
        WHERE model = %s
        ORDER BY chunk_id
        LIMIT %s
        """,
        (settings.embedding_model, sample_size),
    ).fetchall()
    comparisons = []
    for row in rows:
        embedding = parse_pgvector(row["embedding"])
        linear_started = time.perf_counter()
        linear_payload = await search_dense_cpp(embedding, top_k, "linear")
        linear = linear_payload["results"]
        linear_latency_ms = (time.perf_counter() - linear_started) * 1000
        hnsw_started = time.perf_counter()
        hnsw_payload = await search_dense_cpp(embedding, top_k, "hnsw")
        hnsw = hnsw_payload["results"]
        hnsw_latency_ms = (time.perf_counter() - hnsw_started) * 1000
        linear_ids = {item["chunk_id"] for item in linear}
        hnsw_ids = {item["chunk_id"] for item in hnsw}
        overlap_count = len(linear_ids & hnsw_ids)
        comparisons.append(
            {
                "chunk_id": row["chunk_id"],
                "overlap": overlap_count,
                "recall_at_k": overlap_count / max(1, len(linear_ids)),
                "linear_latency_ms": linear_latency_ms,
                "hnsw_latency_ms": hnsw_latency_ms,
                "linear_service_latency_ms": linear_payload.get("latency_ms"),
                "hnsw_service_latency_ms": hnsw_payload.get("latency_ms"),
            }
        )

    count = len(comparisons)
    return {
        "sample_size": count,
        "top_k": top_k,
        "avg_recall_at_k": sum(item["recall_at_k"] for item in comparisons) / count if count else 0,
        "avg_linear_latency_ms": sum(item["linear_latency_ms"] for item in comparisons) / count if count else 0,
        "avg_hnsw_latency_ms": sum(item["hnsw_latency_ms"] for item in comparisons) / count if count else 0,
        "avg_linear_service_latency_ms": sum(item["linear_service_latency_ms"] for item in comparisons) / count if count else 0,
        "avg_hnsw_service_latency_ms": sum(item["hnsw_service_latency_ms"] for item in comparisons) / count if count else 0,
        "comparisons": comparisons,
    }
