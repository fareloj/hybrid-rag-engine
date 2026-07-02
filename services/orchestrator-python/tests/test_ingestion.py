from pathlib import Path

from app.ingestion import chunk_text, iter_files, language_for


def test_language_for_known_extensions() -> None:
    assert language_for(Path("main.py")) == "python"
    assert language_for(Path("retrieval.proto")) == "protobuf"
    assert language_for(Path("unknown.nope")) is None


def test_iter_files_skips_ignored_dirs(tmp_path: Path) -> None:
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "main.py").write_text("def main():\n    return 1\n", encoding="utf-8")
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "ignored.js").write_text("ignored()", encoding="utf-8")

    records = iter_files(tmp_path)

    assert [record.relative_path for record in records] == ["src/main.py"]
    assert records[0].language == "python"


def test_chunk_text_uses_line_ranges() -> None:
    chunks = chunk_text("a\nb\nc")

    assert len(chunks) == 1
    assert chunks[0].start_line == 1
    assert chunks[0].end_line == 3
    assert chunks[0].text == "a\nb\nc"
