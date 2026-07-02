import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import UUID, uuid5

import psycopg

from app.config import settings

NAMESPACE = UUID("5d4c2c1b-52ef-43d8-9d88-000000000001")

IGNORED_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".idea",
    ".vscode",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".venv",
    "venv",
    "env",
    "node_modules",
    "dist",
    "build",
    "target",
    "reports",
    "generated",
    "descriptors",
    ".next",
    ".turbo",
    ".tools",
    ".cache",
    ".ruff_cache",
}

IGNORED_EXTENSIONS = {
    ".7z",
    ".bin",
    ".bmp",
    ".class",
    ".dll",
    ".exe",
    ".gif",
    ".ico",
    ".jar",
    ".jpg",
    ".jpeg",
    ".lock",
    ".min.js",
    ".mp3",
    ".mp4",
    ".pdf",
    ".png",
    ".pyc",
    ".so",
    ".zip",
}

IGNORED_FILE_NAMES = {
    "evaluation_dataset.py",
}

LANGUAGE_BY_EXTENSION = {
    ".c": "c",
    ".cc": "cpp",
    ".cpp": "cpp",
    ".cs": "csharp",
    ".css": "css",
    ".go": "go",
    ".h": "c",
    ".hpp": "cpp",
    ".html": "html",
    ".java": "java",
    ".js": "javascript",
    ".json": "json",
    ".jsx": "javascript",
    ".kt": "kotlin",
    ".md": "markdown",
    ".proto": "protobuf",
    ".ps1": "powershell",
    ".py": "python",
    ".rs": "rust",
    ".sql": "sql",
    ".toml": "toml",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".xml": "xml",
    ".yaml": "yaml",
    ".yml": "yaml",
}


@dataclass(frozen=True)
class FileRecord:
    path: Path
    relative_path: str
    language: str | None
    content_hash: str
    size_bytes: int
    text: str


@dataclass(frozen=True)
class ChunkRecord:
    index: int
    start_line: int
    end_line: int
    text: str


def stable_id(*parts: str) -> UUID:
    return uuid5(NAMESPACE, "::".join(parts))


def language_for(path: Path) -> str | None:
    suffixes = "".join(path.suffixes[-2:])
    if suffixes in LANGUAGE_BY_EXTENSION:
        return LANGUAGE_BY_EXTENSION[suffixes]
    return LANGUAGE_BY_EXTENSION.get(path.suffix.lower())


def should_skip_file(path: Path, root: Path) -> bool:
    if any(part in IGNORED_DIRS for part in path.relative_to(root).parts[:-1]):
        return True
    name = path.name.lower()
    if name in IGNORED_FILE_NAMES or name.endswith("-validate.ps1"):
        return True
    if any(name.endswith(extension) for extension in IGNORED_EXTENSIONS):
        return True
    try:
        stat = path.stat()
    except OSError:
        return True
    return stat.st_size <= 0 or stat.st_size > settings.max_file_bytes


def read_text_file(path: Path) -> str | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in raw[:4096]:
        return None
    for encoding in ("utf-8", "utf-8-sig", "latin-1"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return None


def iter_files(root: Path) -> list[FileRecord]:
    root = root.resolve()
    records: list[FileRecord] = []
    for current_root, dir_names, file_names in os.walk(root, followlinks=False):
        dir_names[:] = [name for name in dir_names if name not in IGNORED_DIRS]
        current_path = Path(current_root)
        for file_name in file_names:
            path = current_path / file_name
            if should_skip_file(path, root):
                continue
            text = read_text_file(path)
            if text is None or not text.strip():
                continue
            relative_path = path.relative_to(root).as_posix()
            records.append(
                FileRecord(
                    path=path,
                    relative_path=relative_path,
                    language=language_for(path),
                    content_hash=hashlib.sha256(text.encode("utf-8")).hexdigest(),
                    size_bytes=path.stat().st_size,
                    text=text,
                )
            )
    return records


def chunk_text(text: str) -> list[ChunkRecord]:
    lines = text.splitlines()
    chunks: list[ChunkRecord] = []
    for start_index in range(0, len(lines), settings.chunk_max_lines):
        block = lines[start_index : start_index + settings.chunk_max_lines]
        chunk_body = "\n".join(block).strip()
        if not chunk_body:
            continue
        chunks.append(
            ChunkRecord(
                index=len(chunks),
                start_line=start_index + 1,
                end_line=start_index + len(block),
                text=chunk_body,
            )
        )
    return chunks


def ingest_repository(conn: psycopg.Connection, root_path: str, name: str | None = None) -> dict[str, Any]:
    root = Path(root_path).resolve()
    if not root.exists() or not root.is_dir():
        raise ValueError(f"repository path is not a directory: {root_path}")

    repo_name = name or root.name
    repo_id = stable_id("repository", str(root))
    run_id = stable_id("ingestion-run", str(root), hashlib.sha256(str(root).encode("utf-8")).hexdigest())
    files = iter_files(root)
    stats = {
        "repository": repo_name,
        "root_path": str(root),
        "files_seen": len(files),
        "documents_upserted": 0,
        "documents_deleted": 0,
        "chunks_inserted": 0,
    }

    with conn.transaction():
        conn.execute(
            """
            INSERT INTO repositories(id, name, root_path)
            VALUES (%s, %s, %s)
            ON CONFLICT (root_path) DO UPDATE
            SET name = EXCLUDED.name
            """,
            (repo_id, repo_name, str(root)),
        )
        conn.execute(
            """
            INSERT INTO ingestion_runs(id, repository_id, status, stats)
            VALUES (%s, %s, 'running', %s)
            ON CONFLICT (id) DO UPDATE
            SET status = 'running', started_at = now(), finished_at = NULL, error = NULL, stats = EXCLUDED.stats
            """,
            (run_id, repo_id, json.dumps(stats)),
        )

        for file_record in files:
            document_id = stable_id("document", str(root), file_record.relative_path)
            conn.execute(
                """
                INSERT INTO documents(id, repository_id, path, language, content_hash, size_bytes, updated_at)
                VALUES (%s, %s, %s, %s, %s, %s, now())
                ON CONFLICT (repository_id, path) DO UPDATE
                SET language = EXCLUDED.language,
                    content_hash = EXCLUDED.content_hash,
                    size_bytes = EXCLUDED.size_bytes,
                    updated_at = now()
                """,
                (
                    document_id,
                    repo_id,
                    file_record.relative_path,
                    file_record.language,
                    file_record.content_hash,
                    file_record.size_bytes,
                ),
            )
            conn.execute("DELETE FROM chunks WHERE document_id = %s", (document_id,))
            stats["documents_upserted"] += 1

            for chunk in chunk_text(file_record.text):
                chunk_id = stable_id("chunk", str(root), file_record.relative_path, str(chunk.index), file_record.content_hash)
                conn.execute(
                    """
                    INSERT INTO chunks(id, document_id, chunk_index, start_line, end_line, text, metadata)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        chunk_id,
                        document_id,
                        chunk.index,
                        chunk.start_line,
                        chunk.end_line,
                        chunk.text,
                        json.dumps(
                            {
                                "repo": repo_name,
                                "path": file_record.relative_path,
                                "language": file_record.language or "",
                            }
                        ),
                    ),
                )
                stats["chunks_inserted"] += 1

        current_paths = [file_record.relative_path for file_record in files]
        if current_paths:
            delete_result = conn.execute(
                """
                DELETE FROM documents
                WHERE repository_id = %s
                  AND NOT (path = ANY(%s))
                """,
                (repo_id, current_paths),
            )
        else:
            delete_result = conn.execute("DELETE FROM documents WHERE repository_id = %s", (repo_id,))
        stats["documents_deleted"] = delete_result.rowcount or 0

        conn.execute(
            """
            UPDATE ingestion_runs
            SET status = 'succeeded', finished_at = now(), stats = %s
            WHERE id = %s
            """,
            (json.dumps(stats), run_id),
        )

    return {"run_id": str(run_id), "repository_id": str(repo_id), **stats}
