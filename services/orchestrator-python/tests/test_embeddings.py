import math

import pytest

from app.embeddings import normalize, parse_embedding_response


def test_parse_embedding_response_supports_single_embedding() -> None:
    assert parse_embedding_response({"embedding": [1, 2, 3]}) == [1.0, 2.0, 3.0]


def test_parse_embedding_response_supports_batch_embedding() -> None:
    assert parse_embedding_response({"embeddings": [[1, 2, 3]]}) == [1.0, 2.0, 3.0]


def test_normalize_returns_unit_vector() -> None:
    vector = normalize([3.0, 4.0])

    assert math.isclose(vector[0], 0.6)
    assert math.isclose(vector[1], 0.8)


def test_normalize_rejects_zero_vector() -> None:
    with pytest.raises(ValueError):
        normalize([0.0, 0.0])
