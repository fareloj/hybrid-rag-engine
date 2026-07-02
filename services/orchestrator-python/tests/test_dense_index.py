from app.dense_index import parse_pgvector


def test_parse_pgvector() -> None:
    assert parse_pgvector("[1,2.5,-3]") == [1.0, 2.5, -3.0]
