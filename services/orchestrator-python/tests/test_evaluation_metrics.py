import pytest

from app.evaluation import mrr, ndcg_at_k, path_matches, recall_at_k


EXPECTED_CHUNK = [{"path": "app/search.py", "start_line": 100, "end_line": 120}]


def test_line_aware_metrics_reject_wrong_chunk_from_same_file() -> None:
    results = [
        {"chunk_id": "wrong", "path": "app/search.py", "start_line": 1, "end_line": 20},
        {"chunk_id": "right", "path": "app/search.py", "start_line": 110, "end_line": 130},
    ]

    assert not path_matches(results[0], EXPECTED_CHUNK)
    assert path_matches(results[1], EXPECTED_CHUNK)
    assert recall_at_k(results, EXPECTED_CHUNK, 1) == 0.0
    assert recall_at_k(results, EXPECTED_CHUNK, 2) == 1.0
    assert mrr(results, EXPECTED_CHUNK) == 0.5
    assert ndcg_at_k(results, EXPECTED_CHUNK, 2) == pytest.approx(1 / 1.584962500721156)


def test_path_only_expectation_preserves_document_level_matching() -> None:
    result = {"chunk_id": "any", "path": "app/search.py", "start_line": 1, "end_line": 20}

    assert path_matches(result, [{"path": "app/search.py"}])


def test_ndcg_does_not_count_two_chunks_for_one_expectation() -> None:
    results = [
        {"chunk_id": "first", "path": "app/search.py", "start_line": 100, "end_line": 110},
        {"chunk_id": "second", "path": "app/search.py", "start_line": 111, "end_line": 120},
    ]

    assert ndcg_at_k(results, EXPECTED_CHUNK, 2) == 1.0
