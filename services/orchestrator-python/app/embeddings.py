import math
from typing import Any

import httpx
import psycopg

from app.config import settings
from app.resilience import request_json


def normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in vector))
    if norm == 0 or not math.isfinite(norm):
        raise ValueError("embedding vector has invalid norm")
    return [value / norm for value in vector]


def parse_embedding_response(payload: dict[str, Any]) -> list[float]:
    if "embedding" in payload:
        return [float(value) for value in payload["embedding"]]
    if "embeddings" in payload and payload["embeddings"]:
        return [float(value) for value in payload["embeddings"][0]]
    raise ValueError("Ollama response did not include an embedding")


async def embed_text(client: httpx.AsyncClient, text: str) -> list[float]:
    payload = await request_json(
        client,
        "ollama",
        "POST",
        f"{settings.ollama_base_url}/api/embed",
        json={"model": settings.embedding_model, "input": text},
        timeout=settings.embedding_timeout_seconds,
    )
    return normalize(parse_embedding_response(payload))


async def embed_pending_chunks(conn: psycopg.Connection, limit: int | None = None) -> dict[str, Any]:
    query = """
        SELECT c.id, c.text
        FROM chunks c
        LEFT JOIN embeddings e ON e.chunk_id = c.id AND e.model = %s
        WHERE e.chunk_id IS NULL
        ORDER BY c.created_at, c.id
    """
    params: list[Any] = [settings.embedding_model]
    if limit is not None:
        query += " LIMIT %s"
        params.append(limit)

    rows = conn.execute(query, params).fetchall()
    stats: dict[str, Any] = {
        "model": settings.embedding_model,
        "requested": len(rows),
        "embedded": 0,
        "dimensions": None,
    }
    if not rows:
        return stats

    async with httpx.AsyncClient() as client:
        for row in rows:
            vector = await embed_text(client, row["text"])
            dimensions = len(vector)
            if stats["dimensions"] is None:
                stats["dimensions"] = dimensions
            elif stats["dimensions"] != dimensions:
                raise ValueError(f"embedding dimension changed from {stats['dimensions']} to {dimensions}")

            conn.execute(
                """
                INSERT INTO embeddings(chunk_id, model, dimensions, embedding)
                VALUES (%s, %s, %s, %s::vector)
                ON CONFLICT (chunk_id) DO UPDATE
                SET model = EXCLUDED.model,
                    dimensions = EXCLUDED.dimensions,
                    embedding = EXCLUDED.embedding,
                    created_at = now()
                """,
                (row["id"], settings.embedding_model, dimensions, str(vector)),
            )
            stats["embedded"] += 1

    conn.commit()
    return stats
