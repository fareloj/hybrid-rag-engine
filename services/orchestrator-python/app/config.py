from pydantic import Field, HttpUrl, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    postgres_host: str = "postgres"
    postgres_port: int = Field(default=5432, ge=1, le=65_535)
    postgres_db: str = "rag"
    postgres_user: str = "rag"
    postgres_password: str = "rag"
    max_file_bytes: int = Field(default=1_000_000, ge=1, le=50_000_000)
    chunk_max_lines: int = Field(default=120, ge=1, le=2_000)
    max_query_chars: int = Field(default=8_000, ge=1, le=50_000)
    max_rerank_candidates: int = Field(default=64, ge=1, le=256)

    ollama_base_url: str = "http://ollama:11434"
    embedding_model: str = "qwen3-embedding:0.6b"
    reranker_model: str = "Qwen/Qwen3-Reranker-0.6B"

    dense_index_url: str = "http://dense-index-cpp:8081"
    lexical_index_url: str = "http://lexical-index-java:8082"
    reranker_url: str = "http://reranker-python:8083"

    health_timeout_seconds: float = Field(default=3.0, gt=0, le=30)
    ollama_health_timeout_seconds: float = Field(default=5.0, gt=0, le=60)
    embedding_timeout_seconds: float = Field(default=30.0, gt=0, le=180)
    index_timeout_seconds: float = Field(default=120.0, gt=0, le=600)
    search_timeout_seconds: float = Field(default=10.0, gt=0, le=120)
    reranker_timeout_seconds: float = Field(default=45.0, gt=0, le=240)
    http_retry_count: int = Field(default=1, ge=0, le=5)
    circuit_breaker_failures: int = Field(default=3, ge=1, le=20)
    circuit_breaker_reset_seconds: float = Field(default=15.0, gt=0, le=300)

    @model_validator(mode="after")
    def validate_urls(self) -> "Settings":
        for field_name in ("ollama_base_url", "dense_index_url", "lexical_index_url", "reranker_url"):
            HttpUrl(self.__dict__[field_name])
        return self

    @property
    def postgres_dsn(self) -> str:
        return (
            f"postgresql://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )


settings = Settings()
