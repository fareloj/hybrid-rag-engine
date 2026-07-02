# Stage 11 Curated Evaluation

- top_k: 5
- query_count: 8
- modes: dense_cpp, pgvector, bm25, rrf, rerank

| Mode | recall@5 | MRR | nDCG@5 | Avg latency ms |
|---|---:|---:|---:|---:|
| dense_cpp | 0.625 | 0.3229 | 0.3991 | 12.23 |
| pgvector | 0.625 | 0.3229 | 0.3991 | 2.70 |
| bm25 | 0.6875 | 0.5562 | 0.5538 | 13.84 |
| rrf | 0.4375 | 0.4167 | 0.3891 | 206.78 |
| rerank | 0.4375 | 0.3438 | 0.3343 | 565.04 |

## Queries

### endpoint_ingest
- query: `POST /ingest`
- expected: services/orchestrator-python/app/main.py
- dense_cpp: recall=1.0, mrr=0.5, ndcg=0.6309, latency_ms=12.79
- pgvector: recall=1.0, mrr=0.5, ndcg=0.6309, latency_ms=3.72
- bm25: recall=1.0, mrr=0.25, ndcg=0.4307, latency_ms=17.83
- rrf: recall=1.0, mrr=1.0, ndcg=1.0, latency_ms=212.00
- rerank: recall=1.0, mrr=0.25, ndcg=0.4307, latency_ms=730.72

### function_ingest_accent
- query: `buscar funÃ§Ã£o ingest`
- expected: services/orchestrator-python/app/ingestion.py
- dense_cpp: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=17.98
- pgvector: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=2.52
- bm25: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=12.65
- rrf: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=206.59
- rerank: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=496.05

### function_ingest_no_accent
- query: `buscar funcao ingest`
- expected: services/orchestrator-python/app/ingestion.py
- dense_cpp: recall=1.0, mrr=0.25, ndcg=0.4307, latency_ms=13.00
- pgvector: recall=1.0, mrr=0.25, ndcg=0.4307, latency_ms=3.01
- bm25: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=12.62
- rrf: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=211.18
- rerank: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=527.21

### lexical_metadata_symbols
- query: `chunks start_line end_line`
- expected: services/orchestrator-python/app/search.py
- dense_cpp: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=10.84
- pgvector: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=2.21
- bm25: recall=1.0, mrr=0.2, ndcg=0.3869, latency_ms=11.45
- rrf: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=207.16
- rerank: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=509.49

### repo_scanner
- query: `repository scanner`
- expected: services/orchestrator-python/app/ingestion.py
- dense_cpp: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=9.76
- pgvector: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=2.43
- bm25: recall=1.0, mrr=1.0, ndcg=1.0, latency_ms=11.17
- rrf: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=202.21
- rerank: recall=0.0, mrr=0.0, ndcg=0.0, latency_ms=574.61

### reranker_cuda_config
- query: `reranker cuda gpu device`
- expected: services/reranker-python/app/main.py, docker-compose.yml
- dense_cpp: recall=1.0, mrr=1.0, ndcg=1.0, latency_ms=11.18
- pgvector: recall=1.0, mrr=1.0, ndcg=1.0, latency_ms=2.72
- bm25: recall=0.5, mrr=1.0, ndcg=0.6131, latency_ms=11.43
- rrf: recall=0.5, mrr=1.0, ndcg=0.6131, latency_ms=210.69
- rerank: recall=0.5, mrr=1.0, ndcg=0.6131, latency_ms=590.34

### ambiguous_music_date
- query: `mÃºsica 11/01`
- expected: rag-hybrid-planning/ROADMAP.md
- dense_cpp: recall=1.0, mrr=0.5, ndcg=0.6309, latency_ms=9.99
- pgvector: recall=1.0, mrr=0.5, ndcg=0.6309, latency_ms=2.48
- bm25: recall=1.0, mrr=1.0, ndcg=1.0, latency_ms=22.37
- rrf: recall=1.0, mrr=1.0, ndcg=1.0, latency_ms=200.44
- rerank: recall=1.0, mrr=1.0, ndcg=1.0, latency_ms=514.26

### orphan_document_accent
- query: `documento Ã³rfÃ£o`
- expected: rag-hybrid-planning/ROADMAP.md
- dense_cpp: recall=1.0, mrr=0.3333, ndcg=0.5, latency_ms=12.31
- pgvector: recall=1.0, mrr=0.3333, ndcg=0.5, latency_ms=2.46
- bm25: recall=1.0, mrr=1.0, ndcg=1.0, latency_ms=11.22
- rrf: recall=1.0, mrr=0.3333, ndcg=0.5, latency_ms=203.94
- rerank: recall=1.0, mrr=0.5, ndcg=0.6309, latency_ms=577.67
