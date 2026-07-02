import asyncio
from typing import Any

import httpx
from fastapi import Depends, FastAPI, HTTPException
from pydantic import BaseModel, Field
from psycopg import Connection

from app.config import settings
from app.dense_index import benchmark_dense, compare_dense_for_chunk, reindex_dense
from app.db import connection
from app.embeddings import embed_pending_chunks
from app.evaluation import run_curated_evaluation
from app.ingestion import ingest_repository
from app.lexical_index import reindex_lexical, search_lexical
from app.observability import log_event, request_id_middleware
from app.search import hybrid_search

app = FastAPI(title="Hybrid RAG Orchestrator", version="0.1.0")
app.middleware("http")(request_id_middleware)


class IngestRequest(BaseModel):
    root_path: str = Field(..., min_length=1)
    name: str | None = None


class EmbedRequest(BaseModel):
    limit: int | None = Field(default=None, ge=1, le=10_000)


class DenseCompareRequest(BaseModel):
    chunk_id: str = Field(..., min_length=1)
    top_k: int = Field(default=5, ge=1, le=100)


class DenseBenchmarkRequest(BaseModel):
    sample_size: int = Field(default=5, ge=1, le=100)
    top_k: int = Field(default=5, ge=1, le=100)


class LexicalSearchRequest(BaseModel):
    query: str = ""
    top_k: int = Field(default=10, ge=1, le=100)


class SearchRequest(BaseModel):
    query: str = Field(..., min_length=1, max_length=8_000)
    top_k: int = Field(default=10, ge=1, le=50)
    dense_top_k: int = Field(default=10, ge=1, le=100)
    lexical_top_k: int = Field(default=10, ge=1, le=100)
    top_n_dense: int | None = Field(default=None, ge=1, le=100)
    top_n_lexical: int | None = Field(default=None, ge=1, le=100)
    rrf_k: int = Field(default=60, ge=1, le=1_000)
    use_reranker: bool = True
    rerank_top_k: int = Field(default=10, ge=1, le=64)


class EvaluateRequest(BaseModel):
    top_k: int = Field(default=5, ge=1, le=20)
    include_reranker: bool = True


async def check_http_json(client: httpx.AsyncClient, url: str) -> dict[str, Any]:
    try:
        response = await client.get(url, timeout=3.0)
        return {
            "ok": response.is_success,
            "status_code": response.status_code,
            "body": response.json() if "application/json" in response.headers.get("content-type", "") else response.text,
        }
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


async def check_ollama(client: httpx.AsyncClient) -> dict[str, Any]:
    try:
        response = await client.get(f"{settings.ollama_base_url}/api/tags", timeout=5.0)
        response.raise_for_status()
        payload = response.json()
        model_names = {model.get("name") for model in payload.get("models", [])}
        required = {settings.embedding_model}
        return {
            "ok": required.issubset(model_names),
            "available_models": sorted(name for name in model_names if name),
            "missing_models": sorted(required - model_names),
        }
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


@app.get("/health")
async def health() -> dict[str, Any]:
    async with httpx.AsyncClient() as client:
        dense, lexical, reranker, ollama = await asyncio.gather(
            check_http_json(client, f"{settings.dense_index_url}/health"),
            check_http_json(client, f"{settings.lexical_index_url}/health"),
            check_http_json(client, f"{settings.reranker_url}/health"),
            check_ollama(client),
        )

    dependencies = {
        "dense_index": dense,
        "lexical_index": lexical,
        "reranker": reranker,
        "ollama": ollama,
    }
    ok = all(item.get("ok") for item in dependencies.values())
    return {
        "status": "ok" if ok else "degraded",
        "service": "orchestrator-python",
        "models": {
            "embedding": settings.embedding_model,
            "reranker": settings.reranker_model,
        },
        "dependencies": dependencies,
    }


@app.post("/ingest")
async def ingest(request: IngestRequest, conn: Connection = Depends(connection)) -> dict[str, Any]:
    try:
        result = ingest_repository(conn, request.root_path, request.name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    log_event("ingest_completed", stats=result)
    return {"status": "succeeded", **result}


@app.post("/embed")
async def embed(request: EmbedRequest, conn: Connection = Depends(connection)) -> dict[str, Any]:
    try:
        result = await embed_pending_chunks(conn, request.limit)
    except httpx.HTTPStatusError as exc:
        detail = exc.response.text
        raise HTTPException(status_code=502, detail=f"Ollama embedding request failed: {detail}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    log_event("embed_completed", stats=result)
    return {"status": "succeeded", **result}


@app.post("/dense/reindex")
async def dense_reindex(conn: Connection = Depends(connection)) -> dict[str, Any]:
    try:
        result = await reindex_dense(conn)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=f"Dense index request failed: {exc.response.text}") from exc
    dense_status = result.pop("status", "unknown")
    log_event("dense_reindex_completed", dense_status=dense_status, stats=result)
    return {"status": "succeeded", "dense_status": dense_status, **result}


@app.post("/dense/compare")
async def dense_compare(request: DenseCompareRequest, conn: Connection = Depends(connection)) -> dict[str, Any]:
    try:
        return {"status": "succeeded", **await compare_dense_for_chunk(conn, request.chunk_id, request.top_k)}
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=f"Dense index request failed: {exc.response.text}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/dense/benchmark")
async def dense_benchmark(request: DenseBenchmarkRequest, conn: Connection = Depends(connection)) -> dict[str, Any]:
    try:
        return {"status": "succeeded", **await benchmark_dense(conn, request.sample_size, request.top_k)}
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=f"Dense index request failed: {exc.response.text}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/lexical/reindex")
async def lexical_reindex(conn: Connection = Depends(connection)) -> dict[str, Any]:
    try:
        result = await reindex_lexical(conn)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=f"Lexical index request failed: {exc.response.text}") from exc
    lexical_status = result.pop("status", "unknown")
    log_event("lexical_reindex_completed", lexical_status=lexical_status, stats=result)
    return {"status": "succeeded", "lexical_status": lexical_status, **result}


@app.post("/lexical/search")
async def lexical_search(request: LexicalSearchRequest) -> dict[str, Any]:
    try:
        return {"status": "succeeded", **await search_lexical(request.query, request.top_k)}
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=f"Lexical index request failed: {exc.response.text}") from exc


@app.post("/search")
async def search(request: SearchRequest, conn: Connection = Depends(connection)) -> dict[str, Any]:
    stripped_query = request.query.strip()
    if not stripped_query:
        raise HTTPException(status_code=400, detail="query must not be blank")
    try:
        dense_top_k = request.top_n_dense if request.top_n_dense is not None else request.dense_top_k
        lexical_top_k = request.top_n_lexical if request.top_n_lexical is not None else request.lexical_top_k
        return await hybrid_search(
            conn,
            stripped_query,
            request.top_k,
            dense_top_k,
            lexical_top_k,
            request.rrf_k,
            request.rerank_top_k,
            request.use_reranker,
        )
    except httpx.HTTPStatusError as exc:
        detail = exc.response.text
        raise HTTPException(status_code=502, detail=f"Search dependency request failed: {detail}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/evaluate")
async def evaluate(request: EvaluateRequest, conn: Connection = Depends(connection)) -> dict[str, Any]:
    try:
        return {"status": "succeeded", **await run_curated_evaluation(conn, request.top_k, request.include_reranker)}
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=f"Evaluation dependency request failed: {exc.response.text}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
