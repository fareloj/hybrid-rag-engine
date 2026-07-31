import time
from typing import Any

import httpx

from app.config import settings
from app.resilience import request_json


async def rerank_candidates(query: str, candidates: list[dict[str, Any]], rerank_top_k: int) -> dict[str, Any]:
    selected = candidates[:rerank_top_k]
    documents = [
        {
            "id": item["chunk_id"],
            "text": item["text"],
            "metadata": {
                "original_rank": item["rank"],
                "original_rrf_score": item["rrf_score"],
                "path": item.get("path"),
                "start_line": item.get("start_line"),
                "end_line": item.get("end_line"),
            },
        }
        for item in selected
        if item.get("metadata_found") and item.get("text")
    ]
    started = time.perf_counter()
    async with httpx.AsyncClient() as client:
        payload = await request_json(
            client,
            "reranker",
            "POST",
            f"{settings.reranker_url}/rerank",
            json={"query": query, "documents": documents},
            timeout=settings.reranker_timeout_seconds,
        )
    payload["latency_ms"] = payload.get("latency_ms", (time.perf_counter() - started) * 1000)
    return payload


def rrf_weight_for_query(query: str) -> float:
    tokens = query.split()
    has_code_symbol = any(symbol in query for symbol in ("/", "_", "::", "()", ".py", ".java", ".cpp"))
    return settings.reranker_exact_rrf_weight if has_code_symbol or len(tokens) <= 4 else settings.reranker_rrf_weight


def apply_rerank(
    candidates: list[dict[str, Any]],
    reranker_results: list[dict[str, Any]],
    top_k: int,
    query: str = "",
) -> list[dict[str, Any]]:
    rrf_weight = rrf_weight_for_query(query)
    by_id = {item["chunk_id"]: dict(item) for item in candidates}
    reranked: list[dict[str, Any]] = []
    reranked_ids: set[str] = set()
    for item in reranker_results:
        chunk_id = item.get("id")
        if chunk_id not in by_id:
            continue
        result = by_id[chunk_id]
        result["original_rank"] = result["rank"]
        result["original_rrf_score"] = result["rrf_score"]
        original_rank = int(result["rank"])
        reranker_rank = int(item["rank"])
        result["reranker_score"] = float(item["score"])
        result["reranker_rank"] = reranker_rank
        result["final_fusion_score"] = (
            rrf_weight / original_rank
            + (1 - rrf_weight) / reranker_rank
        )
        result["reranker_rrf_weight"] = rrf_weight
        reranked.append(result)
        reranked_ids.add(chunk_id)

    reranked.sort(key=lambda item: (-item["final_fusion_score"], item["original_rank"], item["chunk_id"]))
    tail = [dict(item) for item in candidates if item["chunk_id"] not in reranked_ids]
    final = [*reranked, *tail][:top_k]
    for rank, item in enumerate(final, start=1):
        item["rank"] = rank
    return final
