"""Generate PROJECT_CONTEXT.md: a ~2k-token briefing that replaces exploration.

The most expensive minutes of a CoCo session are the first ten in an
unfamiliar repo: 20-50k input tokens spent listing directories and opening
files just to learn what the project *is*, where its entry points are, and
which files matter right now. Input tokens are the bulk of agent spend, so
this script precomputes that orientation once — purpose, layout, entry
points, tool conventions, recently-hot files — into a compact markdown file
(target: under 150 lines) that an agent or developer reads instead of
walking the tree. One briefing read (~2k tokens) in place of a 30-file
exploration pays for itself in the very first session.

Stdlib + `git` subprocess only. Nothing here executes project code:
manifests are parsed with tomllib/json/regex, and git history is only read.

Usage:
    python indexer/context_pack.py --root . --repo org/name \
        [--out PROJECT_CONTEXT.md] [--stamp 2026-07-30T00:00:00Z]

Output is deterministic for a given repo state + --stamp.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11: fall back to regex parsing
    tomllib = None  # type: ignore[assignment]

HOT_FILES_LIMIT = 15
MAX_LAYOUT_DIRS = 20
MAX_ENTRIES_PER_SOURCE = 12
PURPOSE_MAX_CHARS = 180

# Fixed, safe directory-name -> role annotations. Names outside this map get
# a file count only — guessing roles from content would need the very
# exploration this file exists to avoid.
DIR_ROLES: dict[str, str] = {
    ".cortex": "CoCo plugin assets (skills, hooks)",
    ".github": "CI workflows / repo automation",
    "api": "API layer",
    "app": "application code",
    "cli": "command-line interface",
    "config": "configuration",
    "docs": "documentation",
    "examples": "usage examples",
    "indexer": "indexing / ingestion pipeline",
    "infra": "infrastructure as code",
    "lib": "shared library code",
    "migrations": "schema migrations",
    "notebooks": "analysis notebooks",
    "scripts": "operational scripts",
    "sql": "SQL DDL and queries",
    "src": "application source",
    "templates": "templates",
    "terraform": "infrastructure as code",
    "test": "test suite",
    "tests": "test suite",
}

SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build",
    "target", ".terraform", ".pytest_cache", ".mypy_cache",
    ".snowcuffs", ".cocoplus",  # local state, not project structure
}


def _read(path: Path) -> str:
    """File text, or '' on any error — every parse here is best-effort."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _load_json(path: Path) -> object:
    try:
        return json.loads(_read(path) or "null")
    except json.JSONDecodeError:
        return None


# ---------------------------------------------------------------- header ---

def read_purpose(root: Path) -> str | None:
    """First non-heading README paragraph, collapsed to one line."""
    for name in ("README.md", "README.rst", "README"):
        path = root / name
        if path.is_file():
            break
    else:
        return None
    para: list[str] = []
    in_fence = False
    for line in _read(path).splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if not stripped:
            if para:
                break
            continue
        if stripped.startswith(("#", ">", "![", "[!", "---", "===")):
            if para:
                break  # heading/badge after the paragraph ends it
            continue
        para.append(stripped)
    if not para:
        return None
    text = re.sub(r"\s+", " ", " ".join(para)).strip()
    if len(text) > PURPOSE_MAX_CHARS:
        text = text[:PURPOSE_MAX_CHARS].rsplit(" ", 1)[0] + " …"
    return text


# ---------------------------------------------------------------- layout ---

def _count_files(path: Path) -> int:
    total = 0
    for _dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        total += len(filenames)
    return total


def scan_layout(root: Path) -> list[tuple[str, int, str | None]]:
    """(dir name, recursive file count, role|None) for each top-level dir."""
    try:
        children = sorted(p.name for p in root.iterdir() if p.is_dir())
    except OSError:
        return []
    rows: list[tuple[str, int, str | None]] = []
    for name in children:
        if name in SKIP_DIRS or (name.startswith(".") and name not in DIR_ROLES):
            continue
        rows.append((name, _count_files(root / name), DIR_ROLES.get(name)))
    return rows


# ---------------------------------------------------------- entry points ---

def _pyproject_scripts(root: Path) -> list[str]:
    text = _read(root / "pyproject.toml")
    if not text:
        return []
    if tomllib is not None:
        try:
            scripts = tomllib.loads(text).get("project", {}).get("scripts", {})
            return [f"{k} -> {v}" for k, v in sorted(scripts.items())
                    if isinstance(v, str)]
        except Exception:
            pass  # malformed TOML: fall through to the regex path
    section = re.search(r"(?ms)^\[project\.scripts\]\s*$(.*?)(?=^\[|\Z)", text)
    if not section:
        return []
    pairs = re.findall(r"(?m)^\s*([\w.-]+)\s*=\s*['\"]([^'\"]+)['\"]",
                       section.group(1))
    return [f"{k} -> {v}" for k, v in sorted(pairs)]


def _setup_py_scripts(root: Path) -> list[str]:
    """console_scripts entries by regex — setup.py is NEVER executed."""
    text = _read(root / "setup.py")
    marker = text.find("console_scripts")
    if marker < 0:
        return []
    pairs = re.findall(r"['\"]\s*([\w.-]+)\s*=\s*([\w.:]+)\s*['\"]",
                       text[marker:])
    return [f"{k} -> {v}" for k, v in sorted(set(pairs))]


def _package_json_scripts(root: Path) -> list[str]:
    data = _load_json(root / "package.json")
    scripts = data.get("scripts") if isinstance(data, dict) else None
    if not isinstance(scripts, dict):
        return []
    return sorted(str(k) for k in scripts)


def _makefile_targets(root: Path) -> list[str]:
    targets: list[str] = []
    for line in _read(root / "Makefile").splitlines():
        m = re.match(r"^([A-Za-z][\w.-]*)\s*:(?!=)", line)
        if m and m.group(1) not in targets:
            targets.append(m.group(1))
    return targets


def _compose_services(root: Path) -> list[str]:
    """Top-level keys under `services:` — line-based, no YAML library."""
    for name in ("docker-compose.yml", "docker-compose.yaml",
                 "compose.yml", "compose.yaml"):
        path = root / name
        if path.is_file():
            break
    else:
        return []
    services: list[str] = []
    in_services = False
    for line in _read(path).splitlines():
        if re.match(r"^services\s*:\s*$", line):
            in_services = True
            continue
        if in_services:
            if re.match(r"^\S", line):  # dedent back to top level
                break
            m = re.match(r"^ {2}([\w.-]+)\s*:\s*$", line)
            if m:
                services.append(m.group(1))
    return services


def entry_points(root: Path) -> list[tuple[str, list[str]]]:
    """(source label, entries) for each manifest that exists, parsed cheaply."""
    sources: list[tuple[str, list[str]]] = []
    for label, items in (
        ("pyproject scripts", _pyproject_scripts(root)),
        ("setup.py console_scripts", _setup_py_scripts(root)),
        ("package.json scripts", _package_json_scripts(root)),
        ("Makefile targets", _makefile_targets(root)),
        ("docker-compose services", _compose_services(root)),
    ):
        if items:
            sources.append((label, items[:MAX_ENTRIES_PER_SOURCE]))
    return sources


# ------------------------------------------------------------ conventions ---

def detect_conventions(root: Path) -> tuple[list[str], list[str], list[str]]:
    """Returns (lint/format tools, test tools, CI workflow file names)."""
    pyproject = _read(root / "pyproject.toml")
    setup_cfg = _read(root / "setup.cfg")
    tox_ini = _read(root / "tox.ini")
    package = _load_json(root / "package.json")
    pkg = package if isinstance(package, dict) else {}

    def first_file(*patterns: str) -> str | None:
        for pattern in patterns:
            hits = sorted(p.name for p in root.glob(pattern) if p.is_file())
            if hits:
                return hits[0]
        return None

    lint: list[str] = []
    tests: list[str] = []

    def note(bucket: list[str], tool: str, evidence: str | None) -> None:
        if evidence:
            bucket.append(f"{tool} ({evidence})")

    note(lint, "ruff", first_file("ruff.toml", ".ruff.toml")
         or ("pyproject.toml [tool.ruff]" if "[tool.ruff" in pyproject else None))
    note(lint, "black",
         "pyproject.toml [tool.black]" if "[tool.black" in pyproject else None)
    note(lint, "flake8", first_file(".flake8")
         or ("setup.cfg [flake8]" if "[flake8]" in setup_cfg else None)
         or ("tox.ini [flake8]" if "[flake8]" in tox_ini else None))
    note(lint, "eslint", first_file(".eslintrc*", "eslint.config.*"))
    note(lint, "prettier", first_file(".prettierrc*", "prettier.config.*"))
    note(lint, "sqlfluff", first_file(".sqlfluff")
         or ("pyproject.toml [tool.sqlfluff]" if "[tool.sqlfluff" in pyproject
             else None))
    note(tests, "pytest", first_file("pytest.ini", "conftest.py")
         or ("pyproject.toml [tool.pytest.ini_options]" if "[tool.pytest" in pyproject
             else None)
         or ("setup.cfg [tool:pytest]" if "[tool:pytest]" in setup_cfg else None))
    note(tests, "jest", first_file("jest.config.*")
         or ('package.json "jest"' if "jest" in pkg else None))

    workflows = sorted(
        p.name for p in (root / ".github" / "workflows").glob("*.y*ml")
        if p.is_file())
    return lint, tests, workflows


# -------------------------------------------------------------- hot files ---

def hot_files(root: Path, limit: int = HOT_FILES_LIMIT) -> list[tuple[int, str]]:
    """Top files by commit touches in the last 90 days; [] if git is absent,
    the root is not a repo, or the log is empty. Deleted files are dropped."""
    try:
        proc = subprocess.run(
            ["git", "-C", str(root), "log", "--since=90.days",
             "--name-only", "--pretty=format:"],
            capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    counts: Counter[str] = Counter(
        line.strip() for line in proc.stdout.splitlines() if line.strip())
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    out: list[tuple[int, str]] = []
    for path, n in ranked:
        if not (root / path).is_file():
            continue
        out.append((n, path))
        if len(out) == limit:
            break
    return out


# ----------------------------------------------------------------- render ---

def render(
    repo: str,
    stamp: str,
    purpose: str | None,
    layout: list[tuple[str, int, str | None]],
    entries: list[tuple[str, list[str]]],
    lint: list[str],
    tests: list[str],
    workflows: list[str],
    hot: list[tuple[int, str]],
) -> str:
    lines: list[str] = [
        f"# Project context — {repo}",
        f"_Generated {stamp} by snow-cuffs context_pack. This briefing "
        "replaces initial repo exploration — read it instead of walking "
        "the tree._",
        "",
    ]
    if purpose:
        lines += [f"**Purpose:** {purpose}", ""]

    lines.append("## Layout")
    if layout:
        for name, count, role in layout[:MAX_LAYOUT_DIRS]:
            files = "1 file" if count == 1 else f"{count} files"
            lines.append(f"- `{name}/` ({files})" + (f" — {role}" if role else ""))
        if len(layout) > MAX_LAYOUT_DIRS:
            lines.append(f"- … and {len(layout) - MAX_LAYOUT_DIRS} more directories")
    else:
        lines.append("- (no top-level directories)")
    lines.append("")

    lines.append("## Entry points")
    if entries:
        for label, items in entries:
            lines.append(f"- **{label}:** " + ", ".join(f"`{i}`" for i in items))
    else:
        lines.append("- (none detected)")
    lines.append("")

    lines += [
        "## Conventions",
        "- Lint/format: " + (", ".join(lint) if lint else "(none detected)"),
        "- Tests: " + (", ".join(tests) if tests else "(none detected)"),
    ]
    if workflows:
        lines.append("- CI workflows (.github/workflows/): " + ", ".join(workflows))
    lines.append("")

    lines.append(f"## Hot files (top {HOT_FILES_LIMIT} by commit touches, "
                 "last 90 days)")
    if hot:
        lines += [f"- {count}× `{path}`" for count, path in hot]
    else:
        lines.append("- (no git history available)")
    lines.append("")

    lines += [
        "## Cost rules (standing instructions for agents)",
        "- Search before reading: query the `TEAM_CODE_SEARCH` Cortex Search "
        "service for the relevant chunks instead of opening files to look "
        "around.",
        "- Data or schema questions: use `$dbq` (DB_SCHEMA_SEARCH) — do not "
        "explore tables with ad-hoc SELECTs.",
        "- Batch AI SQL: price it first with "
        "`SNOWCUFFS.PUBLIC.ESTIMATE_AI_CREDITS()`.",
        "- If this file answers your question, stop exploring.",
        "",
    ]
    return "\n".join(lines)


# ------------------------------------------------------------------- main ---

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".", help="repo root to scan")
    parser.add_argument("--repo", default=None,
                        help="org/name label (default: root directory name)")
    parser.add_argument("--out", default=None,
                        help="output path (default: <root>/PROJECT_CONTEXT.md)")
    parser.add_argument("--stamp", default=None,
                        help="ISO-8601 generated-at stamp (default: now, UTC)")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        parser.error(f"--root {args.root!r} is not a directory")
    repo = args.repo or root.name

    if args.stamp:
        try:
            stamp_dt = datetime.fromisoformat(args.stamp.replace("Z", "+00:00"))
        except ValueError:
            parser.error(f"--stamp {args.stamp!r} is not ISO-8601")
    else:
        stamp_dt = datetime.now(timezone.utc)
    stamp = stamp_dt.isoformat(timespec="seconds")

    lint, tests, workflows = detect_conventions(root)
    text = render(repo=repo, stamp=stamp, purpose=read_purpose(root),
                  layout=scan_layout(root), entries=entry_points(root),
                  lint=lint, tests=tests, workflows=workflows,
                  hot=hot_files(root))

    out = Path(args.out) if args.out else root / "PROJECT_CONTEXT.md"
    out.write_text(text, encoding="utf-8")
    print(f"wrote {out}: {text.count(chr(10))} lines, ~{len(text) // 4} tokens "
          "(a first session reads this, not 30 files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
