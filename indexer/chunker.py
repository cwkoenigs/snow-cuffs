"""Deterministic file -> chunk splitter for the code search corpus.

Chunk IDs are content hashes: md5(repo || path || chunk_text). Re-running the
chunker on unchanged code produces identical IDs, so upsert.py's MERGE writes
nothing and Cortex Search re-embeds nothing. That property is what keeps
embedding cost proportional to *change volume*, not repo size.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

CHUNK_LINES = 120       # window size
OVERLAP_LINES = 20      # context carried between windows
MAX_FILE_BYTES = 512_000

INDEXED_EXTENSIONS = {
    ".py", ".sql", ".js", ".ts", ".tsx", ".jsx", ".java", ".scala", ".go",
    ".rs", ".sh", ".yml", ".yaml", ".toml", ".md", ".json", ".tf",
}

SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build",
    "target", ".terraform", ".pytest_cache", ".mypy_cache",
}

# PROJECT_CONTEXT.md is injected whole at session start by the session-start
# hook — indexing it too would spend corpus space and re-embeds on content
# every session already receives.
SKIP_FILES = {"PROJECT_CONTEXT.md"}


@dataclass(frozen=True)
class Chunk:
    chunk_id: str
    repo: str
    file_path: str
    language: str
    start_line: int
    end_line: int
    content: str


def _language(path: Path) -> str:
    return path.suffix.lstrip(".").lower() or "text"


def chunk_file(repo: str, root: Path, path: Path) -> Iterator[Chunk]:
    rel = path.relative_to(root).as_posix()
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    lines = text.splitlines()
    if not lines:
        return

    step = CHUNK_LINES - OVERLAP_LINES
    for start in range(0, len(lines), step):
        window = lines[start : start + CHUNK_LINES]
        content = "\n".join(window)
        if not content.strip():
            continue
        # Path prefix in the searchable text helps retrieval quality a lot
        # for near-zero token cost.
        content = f"# {repo}/{rel}\n{content}"
        digest = hashlib.md5(
            f"{repo}\x00{rel}\x00{content}".encode("utf-8")
        ).hexdigest()
        yield Chunk(
            chunk_id=digest,
            repo=repo,
            file_path=rel,
            language=_language(path),
            start_line=start + 1,
            end_line=start + len(window),
            content=content,
        )
        if start + CHUNK_LINES >= len(lines):
            break


def chunk_repo(repo: str, root: str | os.PathLike) -> list[Chunk]:
    root_path = Path(root).resolve()
    chunks: list[Chunk] = []
    for dirpath, dirnames, filenames in os.walk(root_path):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_FILES:
                continue
            path = Path(dirpath) / name
            if path.suffix.lower() not in INDEXED_EXTENSIONS:
                continue
            try:
                if path.stat().st_size > MAX_FILE_BYTES:
                    continue
            except OSError:
                continue
            chunks.extend(chunk_file(repo, root_path, path))
    return chunks
