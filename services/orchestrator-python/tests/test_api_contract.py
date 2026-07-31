from app.main import SearchRequest


def test_legacy_search_request_remains_valid() -> None:
    request = SearchRequest(query="POST /ingest", top_k=5)

    assert request.query == "POST /ingest"
    assert request.filters.model_dump() == {"corpus": None, "path_prefix": None, "language": None}


def test_v1_search_filters_are_structured() -> None:
    request = SearchRequest(
        query="repository scanner",
        filters={"corpus": "navi", "path_prefix": "src/", "language": "python"},
    )

    assert request.filters.corpus == "navi"
    assert request.filters.path_prefix == "src/"
    assert request.filters.language == "python"
