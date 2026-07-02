from app.evaluation import mrr, ndcg_at_k, overlap, recall_at_k


EXPECTED = [{"path": "a.py"}, {"path": "b.py"}]


def test_metrics_with_known_fixture() -> None:
    results = [{"path": "x.py", "chunk_id": "x"}, {"path": "a.py", "chunk_id": "a"}, {"path": "b.py", "chunk_id": "b"}]

    assert recall_at_k(results, EXPECTED, 3) == 1.0
    assert recall_at_k(results, EXPECTED, 1) == 0.0
    assert mrr(results, EXPECTED) == 0.5
    assert 0.0 < ndcg_at_k(results, EXPECTED, 3) < 1.0


def test_overlap_is_jaccard_at_k() -> None:
    left = [{"chunk_id": "a"}, {"chunk_id": "b"}]
    right = [{"chunk_id": "b"}, {"chunk_id": "c"}]

    assert overlap(left, right, 2) == 1 / 3


def test_empty_metrics_are_zero() -> None:
    assert recall_at_k([], EXPECTED, 5) == 0.0
    assert mrr([], EXPECTED) == 0.0
    assert ndcg_at_k([], EXPECTED, 5) == 0.0
    assert overlap([], [], 5) == 0.0
