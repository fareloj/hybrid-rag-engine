from fastapi.testclient import TestClient

from app import main


client = TestClient(main.app)


def test_rerank_sorts_scores_and_preserves_metadata(monkeypatch) -> None:
    monkeypatch.setattr(main, "predict_scores", lambda pairs: [0.25, 0.9])

    response = client.post(
        "/rerank",
        headers={"X-Request-ID": "ci-contract"},
        json={
            "query": "where is ingestion implemented",
            "documents": [
                {"id": "first", "text": "unrelated", "metadata": {"path": "a.py"}},
                {"id": "second", "text": "def ingest(): pass", "metadata": {"path": "ingest.py"}},
            ],
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert [item["id"] for item in payload["results"]] == ["second", "first"]
    assert [item["rank"] for item in payload["results"]] == [1, 2]
    assert payload["results"][0]["score"] == 0.9
    assert payload["results"][0]["metadata"] == {"path": "ingest.py"}


def test_rerank_returns_503_when_model_is_unavailable(monkeypatch) -> None:
    def unavailable(_pairs):
        raise RuntimeError("model unavailable")

    monkeypatch.setattr(main, "predict_scores", unavailable)

    response = client.post(
        "/rerank",
        json={"query": "test", "documents": [{"id": "chunk", "text": "content"}]},
    )

    assert response.status_code == 503
    assert response.json()["detail"] == "model unavailable"


def test_rerank_accepts_empty_candidate_list() -> None:
    response = client.post("/rerank", json={"query": "test", "documents": []})

    assert response.status_code == 200
    assert response.json()["results"] == []

