import json
from typing import Any
from urllib.request import Request, urlopen


def search(
    query: str,
    *,
    base_url: str = "http://localhost:8090",
    corpus: str | None = None,
    path_prefix: str | None = None,
    language: str | None = None,
    top_k: int = 5,
) -> dict[str, Any]:
    payload = {
        "query": query,
        "top_k": top_k,
        "filters": {
            key: value
            for key, value in {
                "corpus": corpus,
                "path_prefix": path_prefix,
                "language": language,
            }.items()
            if value is not None
        },
    }
    request = Request(
        f"{base_url.rstrip('/')}/v1/search",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Request-ID": "external-client-example"},
        method="POST",
    )
    with urlopen(request, timeout=60) as response:
        return json.load(response)


if __name__ == "__main__":
    result = search("função que remove documentos órfãos", language="python")
    for item in result["results"]:
        print(f"{item['corpus']}:{item['path']}:{item['start_line']} score={item.get('reranker_score')}")
