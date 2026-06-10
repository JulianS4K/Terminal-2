#!/usr/bin/env python3
"""PostToolUse guard — runs the repo's governance gates at edit time.

Fired by hooks/hooks.json after every Edit/Write/MultiEdit. Reads the hook
payload from stdin, decides which gate the edited file is subject to, and
runs it from the project root:

  - code files (.py .sql .js .ts .tsx .jsx .mjs .cjs .html)
        -> scripts/check_readonly.py   (RULE 2 — no writes to broker hosts)
  - markdown at repo root or under docs/
        -> bin/check-docs.sh           (closed doc registry + doc-version line)

Exit semantics (Claude Code hook contract):
  0 = clean (silent)
  2 = violation -> stderr is fed back to Claude as blocking feedback so the
      session fixes it immediately instead of discovering it in CI
  other = non-blocking warning (used when a gate can't run in this env)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

CODE_SUFFIXES = {".py", ".sql", ".js", ".ts", ".tsx", ".jsx", ".mjs", ".cjs", ".html"}


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # malformed payload — never block on harness quirks

    file_path = (payload.get("tool_input") or {}).get("file_path") or ""
    if not file_path:
        return 0

    root = Path(os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or ".").resolve()
    if not (root / "CLAUDE.md").exists():  # not the Terminal-2 checkout
        return 0

    path = Path(file_path)
    try:
        rel = path.resolve().relative_to(root)
    except ValueError:
        return 0  # edit outside the repo — not ours to gate

    # Self-guard: edits to the scanner/gate themselves still re-run them below.
    suffix = path.suffix.lower()

    if suffix in CODE_SUFFIXES:
        py = sys.executable or shutil.which("python3") or "python3"
        proc = subprocess.run(
            [py, str(root / "scripts" / "check_readonly.py")],
            capture_output=True, text=True, cwd=str(root),
        )
        if proc.returncode != 0:
            sys.stderr.write(
                "RULE 2 VIOLATION introduced by this edit (scripts/check_readonly.py "
                "failed — read-only upstream lockdown, CLAUDE.md §2). Fix before "
                "continuing:\n" + (proc.stdout + proc.stderr)[-3000:]
            )
            return 2
        return 0

    if suffix == ".md" and (len(rel.parts) == 1 or rel.parts[0] == "docs"):
        bash = shutil.which("bash")
        if not bash:
            sys.stderr.write("docs gate skipped: bash not available in this environment\n")
            return 1  # non-blocking
        proc = subprocess.run(
            [bash, str(root / "bin" / "check-docs.sh")],
            capture_output=True, text=True, cwd=str(root),
        )
        if proc.returncode != 0:
            sys.stderr.write(
                "DOCS REGISTRY VIOLATION introduced by this edit (bin/check-docs.sh "
                "failed — closed doc set / doc-version rules, CLAUDE.md §6). Fix "
                "before continuing:\n" + (proc.stdout + proc.stderr)[-3000:]
            )
            return 2
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
