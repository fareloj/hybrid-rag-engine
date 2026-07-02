from typing import Any

import httpx
import psycopg

from app.config import settings
from app.resilience import request_json


def load_chunks(conn: psycopg.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT
            c.id::text AS id,
            d.path,
            COALESCE(d.language, '') AS language,
            c.start_line,
            c.end_line,
            c.text
        FROM chunks c
        JOIN documents d ON d.id = c.document_id
        ORDER BY d.path, c.chunk_index
        """
    ).fetchall()
    return [dict(row) for row in rows]


async def reindex_lexical(conn: psycopg.Connection) -> dict[str, Any]:
    chunks = load_chunks(conn)
    async with httpx.AsyncClient() as client:
        return await request_json(
            client,
            "lexical_index",
            "POST",
            f"{settings.lexical_index_url}/index",
            json={"chunks": chunks},
            timeout=settings.index_timeout_seconds,
        )


async def search_lexical(query: str, top_k: int) -> dict[str, Any]:
    async with httpx.AsyncClient() as client:
        return await request_json(
            client,
            "lexical_index",
            "POST",
            f"{settings.lexical_index_url}/search",
            json={"query": query, "top_k": top_k},
            timeout=settings.search_timeout_seconds,
        )
