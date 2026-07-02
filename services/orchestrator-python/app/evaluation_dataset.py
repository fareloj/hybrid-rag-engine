CURATED_QUERIES = [
    {
        "id": "endpoint_ingest",
        "query": "POST /ingest",
        "expected": [{"path": "services/orchestrator-python/app/main.py"}],
        "tags": ["endpoint", "exact", "code"],
    },
    {
        "id": "function_ingest_accent",
        "query": "buscar função ingest",
        "expected": [{"path": "services/orchestrator-python/app/ingestion.py"}],
        "tags": ["accent", "function", "natural"],
    },
    {
        "id": "function_ingest_no_accent",
        "query": "buscar funcao ingest",
        "expected": [{"path": "services/orchestrator-python/app/ingestion.py"}],
        "tags": ["no_accent", "function", "natural"],
    },
    {
        "id": "lexical_metadata_symbols",
        "query": "chunks start_line end_line",
        "expected": [{"path": "services/orchestrator-python/app/search.py"}],
        "tags": ["symbols", "metadata", "code"],
    },
    {
        "id": "repo_scanner",
        "query": "repository scanner",
        "expected": [{"path": "services/orchestrator-python/app/ingestion.py"}],
        "tags": ["english", "scanner"],
    },
    {
        "id": "reranker_cuda_config",
        "query": "reranker cuda gpu device",
        "expected": [{"path": "services/reranker-python/app/main.py"}, {"path": "docker-compose.yml"}],
        "tags": ["reranker", "cuda", "config"],
    },
    {
        "id": "ambiguous_music_date",
        "query": "música 11/01",
        "expected": [{"path": "rag-hybrid-planning/ROADMAP.md"}],
        "tags": ["ambiguous", "accent", "date"],
    },
    {
        "id": "orphan_document_accent",
        "query": "documento órfão",
        "expected": [{"path": "rag-hybrid-planning/ROADMAP.md"}],
        "tags": ["accent", "rare", "red_team"],
    },
]
