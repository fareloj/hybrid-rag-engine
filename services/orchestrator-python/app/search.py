import time
from typing import Any

import httpx
import psycopg

from app.dense_index import search_dense_cpp
from app.embeddings import embed_text
from app.lexical_index import search_lexical
from app.observability import log_event, safe_query
from app.reranker import apply_rerank, rerank_candidates


def fetch_chunks(
    conn: psycopg.Connection,
    chunk_ids: list[str],
    filters: dict[str, str | None] | None = None,
) -> dict[str, dict[str, Any]]:
    if not chunk_ids:
        return {}
    filters = filters or {}
    corpus = filters.get("corpus")
    path_prefix = filters.get("path_prefix")
    language = filters.get("language")
    rows = conn.execute(
        """
        SELECT
            c.id::text AS chunk_id,
            r.name AS corpus,
            d.path,
            COALESCE(d.language, '') AS language,
            c.start_line,
            c.end_line,
            c.text,
            c.metadata
        FROM chunks c
        JOIN documents d ON d.id = c.document_id
        JOIN repositories r ON r.id = d.repository_id
        WHERE c.id = ANY(%s::uuid[])
          AND (%s::text IS NULL OR r.name = %s)
          AND (%s::text IS NULL OR left(d.path, length(%s)) = %s)
          AND (%s::text IS NULL OR d.language = %s)
        """,
        (chunk_ids, corpus, corpus, path_prefix, path_prefix, path_prefix, language, language),
    ).fetchall()
    return {row["chunk_id"]: dict(row) for row in rows}


def error_payload(exc: Exception) -> dict[str, str]:
    return {"type": exc.__class__.__name__, "message": str(exc)}


async def hybrid_search(
    conn: psycopg.Connection,
    query: str,
    top_k: int,
    dense_top_k: int,
    lexical_top_k: int,
    rrf_k: int,
    rerank_top_k: int,
    use_reranker: bool,
    filters: dict[str, str | None] | None = None,
) -> dict[str, Any]:
    started = time.perf_counter()
    async with httpx.AsyncClient() as client:
        embedding = await embed_text(client, query)

    dense_started = time.perf_counter()
    lexical_started = time.perf_counter()
    dense_result, lexical_result = await run_partial(
        search_dense_cpp(embedding, dense_top_k),
        search_lexical(query, lexical_top_k),
    )

    dense_latency_ms = (time.perf_counter() - dense_started) * 1000
    lexical_latency_ms = (time.perf_counter() - lexical_started) * 1000
    sources: dict[str, Any] = {}
    source_errors: dict[str, Any] = {}

    if isinstance(dense_result, Exception):
        source_errors["dense"] = error_payload(dense_result)
        dense_results: list[dict[str, Any]] = []
    else:
        dense_results = dense_result.get("results", [])
        sources["dense"] = {"ok": True, "count": len(dense_results), "latency_ms": dense_latency_ms}

    if isinstance(lexical_result, Exception):
        source_errors["lexical"] = error_payload(lexical_result)
        lexical_results: list[dict[str, Any]] = []
    else:
        lexical_results = lexical_result.get("results", [])
        sources["lexical"] = {"ok": True, "count": len(lexical_results), "latency_ms": lexical_latency_ms}

    fused = fuse_rrf(dense_results, lexical_results, rrf_k)
    ordered_ids = [item["chunk_id"] for item in fused]
    metadata = fetch_chunks(conn, ordered_ids, filters)
    filters_active = any((filters or {}).values())
    candidate_ids = [chunk_id for chunk_id in ordered_ids if chunk_id in metadata] if filters_active else ordered_ids
    candidate_limit = max(top_k, rerank_top_k if use_reranker else top_k)
    candidates = consolidate_results(candidate_ids, metadata, dense_results, lexical_results, fused)[:candidate_limit]
    results = candidates[:top_k]
    missing_metadata = [] if filters_active else [chunk_id for chunk_id in ordered_ids[:top_k] if chunk_id not in metadata]

    reranker_payload: dict[str, Any] | None = None
    if use_reranker and candidates:
        try:
            reranker_payload = await rerank_candidates(query, candidates, rerank_top_k)
            results = apply_rerank(candidates, reranker_payload.get("results", []), top_k, query)
            sources["reranker"] = {
                "ok": True,
                "count": len(reranker_payload.get("results", [])),
                "latency_ms": reranker_payload.get("latency_ms"),
            }
        except Exception as exc:
            source_errors["reranker"] = error_payload(exc)
            results = candidates[:top_k]

    total_latency_ms = (time.perf_counter() - started) * 1000
    log_event(
        "search_completed",
        query=safe_query(query),
        status="succeeded" if not source_errors else "partial",
        result_count=len(results),
        source_errors=source_errors,
        filters_active=filters_active,
        latency_ms={
            "total": total_latency_ms,
            "dense": dense_latency_ms if "dense" in sources else None,
            "lexical": lexical_latency_ms if "lexical" in sources else None,
            "reranker": sources.get("reranker", {}).get("latency_ms"),
        },
    )

    return {
        "api_version": "v1",
        "query": query,
        "filters": filters or {},
        "top_k": top_k,
        "rrf_k": rrf_k,
        "top_n_dense": dense_top_k,
        "top_n_lexical": lexical_top_k,
        "rerank_top_k": rerank_top_k,
        "reranker_applied": reranker_payload is not None,
        "status": "succeeded" if not source_errors else "partial",
        "results": results,
        "sources": sources,
        "source_errors": source_errors,
        "missing_metadata": missing_metadata,
        "latency_ms": {
            "total": total_latency_ms,
            "dense": dense_latency_ms if "dense" in sources else None,
            "lexical": lexical_latency_ms if "lexical" in sources else None,
        },
    }


async def run_partial(*coroutines: Any) -> tuple[Any, ...]:
    import asyncio

    return tuple(await asyncio.gather(*coroutines, return_exceptions=True))


def fuse_rrf(
    dense_results: list[dict[str, Any]],
    lexical_results: list[dict[str, Any]],
    k: int,
    dense_weight: float = 1.0,
    lexical_weight: float = 0.35,
) -> list[dict[str, Any]]:
    scores: dict[str, dict[str, Any]] = {}
    for source, results, weight in (("dense", dense_results, dense_weight), ("lexical", lexical_results, lexical_weight)):
        seen_in_source: set[str] = set()
        for fallback_rank, result in enumerate(results, start=1):
            chunk_id = result.get("chunk_id")
            if not chunk_id or chunk_id in seen_in_source:
                continue
            seen_in_source.add(chunk_id)
            rank = valid_rank(result.get("rank"), fallback_rank)
            contribution = weight / (k + rank)
            entry = scores.setdefault(
                chunk_id,
                {
                    "chunk_id": chunk_id,
                    "rrf_score": 0.0,
                    "source_contributions": {},
                },
            )
            entry["rrf_score"] += contribution
            entry["source_contributions"][source] = contribution
            entry[f"{source}_rank"] = rank

    fused = sorted(
        scores.values(),
        key=lambda item: (
            -item["rrf_score"],
            item.get("dense_rank", 1_000_000),
            item.get("lexical_rank", 1_000_000),
            item["chunk_id"],
        ),
    )
    for rank, item in enumerate(fused, start=1):
        item["rrf_rank"] = rank
    return fused


def valid_rank(value: Any, fallback: int) -> int:
    try:
        rank = int(value)
    except (TypeError, ValueError):
        return fallback
    return rank if rank > 0 else fallback


def consolidate_results(
    ordered_ids: list[str],
    metadata: dict[str, dict[str, Any]],
    dense_results: list[dict[str, Any]],
    lexical_results: list[dict[str, Any]],
    fused: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    dense_by_id = {item["chunk_id"]: item for item in dense_results if item.get("chunk_id")}
    lexical_by_id = {item["chunk_id"]: item for item in lexical_results if item.get("chunk_id")}
    fused_by_id = {item["chunk_id"]: item for item in fused}
    results = []
    for chunk_id in ordered_ids:
        chunk = metadata.get(chunk_id)
        fused_item = fused_by_id[chunk_id]
        if chunk is None:
            results.append(
                {
                    "chunk_id": chunk_id,
                    "rank": fused_item["rrf_rank"],
                    "rrf_score": fused_item["rrf_score"],
                    "metadata_found": False,
                }
            )
            continue
        dense = dense_by_id.get(chunk_id)
        lexical = lexical_by_id.get(chunk_id)
        results.append(
            {
                "chunk_id": chunk_id,
                "rank": fused_item["rrf_rank"],
                "rrf_score": fused_item["rrf_score"],
                "rrf_contributions": fused_item["source_contributions"],
                "metadata_found": True,
                "corpus": chunk["corpus"],
                "path": chunk["path"],
                "language": chunk["language"],
                "start_line": chunk["start_line"],
                "end_line": chunk["end_line"],
                "text": chunk["text"],
                "content_trust": chunk.get("metadata", {}).get("content_trust", "untrusted"),
                "security_flags": chunk.get("metadata", {}).get("security_flags", []),
                "scores": {
                    "dense": dense.get("score") if dense else None,
                    "lexical": lexical.get("score") if lexical else None,
                },
                "source_ranks": {
                    "dense": dense.get("rank") if dense else None,
                    "lexical": lexical.get("rank") if lexical else None,
                },
                "sources": [source for source, item in (("dense", dense), ("lexical", lexical)) if item],
            }
        )
    return results
