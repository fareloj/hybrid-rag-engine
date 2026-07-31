from app.reranker import apply_rerank, rrf_weight_for_query


def candidate(chunk_id: str, rank: int) -> dict:
    return {"chunk_id": chunk_id, "rank": rank, "rrf_score": 1 / rank, "metadata_found": True, "text": chunk_id}


def test_guarded_rerank_preserves_strong_rrf_match() -> None:
    candidates = [candidate("exact", 1), candidate("model-favorite", 2)]
    reranker = [
        {"id": "model-favorite", "rank": 1, "score": 0.9},
        {"id": "exact", "rank": 2, "score": 0.8},
    ]

    results = apply_rerank(candidates, reranker, 2)

    assert [item["chunk_id"] for item in results] == ["exact", "model-favorite"]
    assert results[0]["reranker_rank"] == 2
    assert "final_fusion_score" in results[0]


def test_semantic_rerank_can_promote_relevant_candidate() -> None:
    candidates = [candidate("first", 1), candidate("second", 2), candidate("relevant", 3)]
    reranker = [
        {"id": "relevant", "rank": 1, "score": 0.95},
        {"id": "second", "rank": 2, "score": 0.5},
        {"id": "first", "rank": 3, "score": 0.1},
    ]

    results = apply_rerank(candidates, reranker, 3, "which candidate best explains this repository behavior")

    assert [item["chunk_id"] for item in results] == ["relevant", "first", "second"]


def test_exact_queries_receive_stronger_rrf_guardrail() -> None:
    assert rrf_weight_for_query("POST /ingest") > rrf_weight_for_query(
        "what protects requests when downstream services repeatedly fail"
    )
