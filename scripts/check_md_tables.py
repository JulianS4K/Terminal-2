#!/usr/bin/env python3
"""Markdown table-structure gate.

Catches malformed GFM tables in the canonical governance docs — specifically the
failure mode that slipped past the docs-registry gate once: two table rows
mashed onto one line (a stray missing newline) so a body row has more cells than
its header. The docs-registry gate validates the registry + version headers, NOT
table well-formedness; this fills that gap.

Rule: inside a detected table, every body row must have the SAME column count as
its header row. A mashed row (two rows joined) has ~2x the columns → fail.

Robustness (avoids false positives on the gnarly bibles):
  - fenced code blocks (``` / ~~~) are skipped — SQL etc. contains bare `|`.
  - escaped pipes (\\|) are not cell delimiters.
  - inline code spans (`...`) are blanked before counting — they may hold `|`.

Exit codes:
  0  clean (no tables, or every body row matches its header width)
  1  a malformed row (CI should fail the PR)
  2  config error (a target file is missing)

Usage:
  python scripts/check_md_tables.py [file ...]
  (default: the canonical governance docs at the repo root)
"""
from __future__ import annotations

import pathlib
import re
import sys

DEFAULT_TARGETS = (
    "PROJECT_BIBLE.md",
    "RESOURCES_BIBLE.md",
    "CLAUDE.md",
    "KANBAN.md",
    "MIGRATION_CONVENTIONS.md",
    "README.md",
)

FENCE_RE = re.compile(r"^\s*(```|~~~)")
SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$")
INLINE_CODE_RE = re.compile(r"`[^`]*`")


def _column_count(line: str) -> int:
    """GFM cell count for a table row, tolerant of \\| and inline code."""
    s = line.strip()
    # Blank inline-code spans first (they may contain unescaped pipes).
    s = INLINE_CODE_RE.sub(lambda m: " " * len(m.group(0)), s)
    # Neutralize escaped pipes.
    s = s.replace(r"\|", "  ")
    # Strip the optional leading/trailing pipe, then split on the rest.
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return len(s.split("|"))


def _is_table_row(line: str) -> bool:
    return line.lstrip().startswith("|")


def check_file(path: pathlib.Path) -> list[str]:
    errors: list[str] = []
    lines = path.read_text().splitlines()
    in_fence = False
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if FENCE_RE.match(line):
            in_fence = not in_fence
            i += 1
            continue
        if in_fence or not _is_table_row(line):
            i += 1
            continue
        # Potential table header at i; a real table has a separator at i+1.
        if i + 1 < n and SEP_RE.match(lines[i + 1]) and _is_table_row(lines[i + 1]):
            header_cols = _column_count(line)
            j = i + 2
            while j < n and _is_table_row(lines[j]) and not FENCE_RE.match(lines[j]):
                row_cols = _column_count(lines[j])
                if row_cols != header_cols:
                    errors.append(
                        f"{path}:{j + 1}: table row has {row_cols} columns but its "
                        f"header (line {i + 1}) has {header_cols} — likely two rows "
                        f"mashed onto one line, or a missing/extra `|`."
                    )
                j += 1
            i = j
        else:
            i += 1
    return errors


def main(argv) -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    targets = argv[1:] if len(argv) > 1 else DEFAULT_TARGETS
    paths = [pathlib.Path(t) if pathlib.Path(t).is_absolute() else repo_root / t
             for t in targets]

    missing = [str(p) for p in paths if not p.exists()]
    if missing:
        print(f"ERROR (config): file(s) not found: {', '.join(missing)}", file=sys.stderr)
        return 2

    all_errors: list[str] = []
    for p in paths:
        all_errors.extend(check_file(p))

    if all_errors:
        print("❌ malformed markdown table(s):", file=sys.stderr)
        for e in all_errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print(f"✅ markdown tables well-formed across {len(paths)} doc(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
