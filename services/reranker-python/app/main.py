from functools import lru_cache
import asyncio
import json
import time
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    reranker_model: str = "Qwen/Qwen3-Reranker-0.6B"
    max_rerank_documents: int = 64
    max_document_chars: int = 4_000
    max_sequence_length: int = 256
    reranker_batch_size: int = 1
    reranker_device: str = "auto"


class RerankDocument(BaseModel):
    id: str = Field(..., min_length=1)
    text: str = Field(..., min_length=1)
    metadata: dict[str, Any] = Field(default_factory=dict)


class RerankRequest(BaseModel):
    query: str = Field(..., min_length=1, max_length=8_000)
    documents: list[RerankDocument] = Field(default_factory=list, max_length=64)


class RerankResult(BaseModel):
    id: str
    score: float
    rank: int
    metadata: dict[str, Any] = Field(default_factory=dict)


settings = Settings()
app = FastAPI(title="Hybrid RAG Reranker", version="0.1.0")


def resolve_device() -> str:
    if settings.reranker_device != "auto":
        return settings.reranker_device
    try:
        import torch
    except ImportError:
        return "cpu"
    return "cuda" if torch.cuda.is_available() else "cpu"


@lru_cache(maxsize=1)
def model() -> Any:
    try:
        from sentence_transformers import CrossEncoder
    except ImportError as exc:
        raise RuntimeError(
            "sentence-transformers is not installed. Install requirements-ml.txt "
            "when implementing the reranker phase."
        ) from exc
    return CrossEncoder(settings.reranker_model, max_length=settings.max_sequence_length, device=resolve_device())


def predict_scores(pairs: list[tuple[str, str]]) -> Any:
    return model().predict(pairs, batch_size=settings.reranker_batch_size)


@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "service": "reranker-python",
        "model": settings.reranker_model,
        "runtime": "sentence-transformers",
        "device": resolve_device(),
        "max_sequence_length": settings.max_sequence_length,
        "max_document_chars": settings.max_document_chars,
        "batch_size": settings.reranker_batch_size,
    }


@app.post("/rerank")
async def rerank(request: RerankRequest, raw_request: Request) -> dict[str, Any]:
    started = time.perf_counter()
    request_id = raw_request.headers.get("X-Request-ID", "")
    if len(request.documents) > settings.max_rerank_documents:
        raise HTTPException(status_code=413, detail=f"too many documents; max is {settings.max_rerank_documents}")
    pairs = [(request.query, document.text[: settings.max_document_chars]) for document in request.documents]
    try:
        scores = await asyncio.to_thread(predict_scores, pairs) if pairs else []
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"reranker model failed: {exc}") from exc
    ranked = sorted(
        zip(request.documents, scores, strict=True),
        key=lambda item: float(item[1]),
        reverse=True,
    )
    print(
        json.dumps(
            {
                "event": "reranker_request",
                "request_id": request_id,
                "documents": len(request.documents),
                "latency_ms": (time.perf_counter() - started) * 1000,
                "device": resolve_device(),
            },
            sort_keys=True,
        ),
        flush=True,
    )
    return {
        "results": [
            RerankResult(
                id=document.id,
                score=float(score),
                rank=index + 1,
                metadata=document.metadata,
            )
            for index, (document, score) in enumerate(ranked)
        ],
        "latency_ms": (time.perf_counter() - started) * 1000,
        "model": settings.reranker_model,
        "device": resolve_device(),
    }
