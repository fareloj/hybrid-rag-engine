# Hybrid RAG

Polyglot hybrid retrieval engine:

- Python orchestrator + Ollama model runtime
- Python reranker service with Sentence Transformers
- C++ dense vector index
- Java lexical/BM25 service
- Postgres + pgvector as source of truth and dense baseline

Planning docs live in `rag-hybrid-planning/`.

## First Run

```powershell
Copy-Item .env.example .env
docker compose up --build
```

Pull the local embedding model into Ollama before running retrieval workflows:

```powershell
ollama pull qwen3-embedding:0.6b
```

If using the compose-managed Ollama container, run:

```powershell
docker compose exec ollama ollama pull qwen3-embedding:0.6b
```

Note: `sam860/qwen3-embedding:0.6b-F16` is available in Ollama but currently returns `This server does not support embeddings` on the official Ollama server used here. The official `qwen3-embedding:0.6b` tag works with `/api/embed`.

The reranker runs outside Ollama in `reranker-python` with `Qwen/Qwen3-Reranker-0.6B` by default. Its Hugging Face cache is persisted in the `hf-model-cache` Docker volume. The service requests `gpus: all` in Docker Compose and uses `RERANKER_DEVICE=auto`, selecting CUDA when Docker can see an NVIDIA GPU. The first real rerank request can take a while because Sentence Transformers downloads and loads the model.

## Health

```powershell
Invoke-RestMethod http://localhost:8090/health
Invoke-RestMethod http://localhost:8081/health
Invoke-RestMethod http://localhost:8082/health
Invoke-RestMethod http://localhost:8083/health
```

## Ingestion

The orchestrator mounts this workspace as `/workspace` in Docker. Ingest the current repo with:

```powershell
Invoke-RestMethod http://localhost:8090/ingest `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"root_path":"/workspace","name":"gpt"}'
```

## Embeddings

The Ollama service runs with `--embeddings`. Generate embeddings for pending chunks with:

```powershell
Invoke-RestMethod http://localhost:8090/embed `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"limit":10}'
```

## Dense Index

Load Postgres embeddings into the C++ linear index:

```powershell
Invoke-RestMethod http://localhost:8090/dense/reindex -Method Post
```

Compare C++ linear search against `pgvector` for a known chunk:

```powershell
$chunk = docker compose exec -T postgres psql -U rag -d rag -t -A -c "SELECT chunk_id FROM embeddings LIMIT 1;"
Invoke-RestMethod http://localhost:8090/dense/compare `
  -Method Post `
  -ContentType 'application/json' `
  -Body "{`"chunk_id`":`"$chunk`",`"top_k`":5}"
```

Run the stage-6 baseline benchmark:

```powershell
Invoke-RestMethod http://localhost:8090/dense/benchmark `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"sample_size":5,"top_k":5}'
```

## Lexical Index

Load Postgres chunks into the Java/Lucene BM25 index:

```powershell
Invoke-RestMethod http://localhost:8090/lexical/reindex -Method Post
```

Search BM25:

```powershell
Invoke-RestMethod http://localhost:8090/lexical/search `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"query":"POST /ingest","top_k":5}'
```

## Hybrid Search

Run hybrid retrieval with RRF only:

```powershell
Invoke-RestMethod http://localhost:8090/search `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"query":"POST /ingest","top_k":5,"top_n_dense":10,"top_n_lexical":10,"use_reranker":false}'
```

Run hybrid retrieval with reranking enabled:

```powershell
Invoke-RestMethod http://localhost:8090/search `
  -Method Post `
  -ContentType 'application/json' `
  -Body '{"query":"POST /ingest","top_k":5,"top_n_dense":10,"top_n_lexical":10,"rrf_k":60,"use_reranker":true,"rerank_top_k":5}'
```

The reranked response preserves `rrf_score`, source scores, `original_rank`, `original_rrf_score`, and `reranker_score`.

Stage validation scripts:

```powershell
.\scripts\orchestrator-stage8-validate.ps1
.\scripts\rrf-stage9-validate.ps1
.\scripts\reranker-stage10-validate.ps1
```

## Local Checks

```powershell
.\scripts\check.ps1
```

## Protobuf Contracts

Generate and verify Python gRPC stubs plus a versioned descriptor:

```powershell
.\scripts\proto-generate.ps1
.\scripts\proto-check.ps1
```

## Database

Apply and verify migrations against the compose Postgres:

```powershell
.\scripts\db-migrate.ps1
.\scripts\db-verify.ps1
.\scripts\db-smoke-test.ps1
```
