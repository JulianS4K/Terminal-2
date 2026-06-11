#!/usr/bin/env python3
"""PostToolUse guard — runs the repo's governance gates at edit time.

Fired by hooks/hooks.json after every Edit/Write/MultiEdit. Reads the hook
payload from stdin, decides which gate the edited file is subject to, and
runs it from the project root:

  - code files in the RULE 2 scanner's scope (.py / web suffixes anywhere it
    scans, plus .sql under supabase/migrations)
        -> scripts/check_readonly.py   (RULE 2 — no writes to broker hosts)
  - markdown at repo root or under docs/
        -> bin/check-docs.sh           (closed doc registry + doc-version line)

Scope is taken FROM the scanner (PY_SCAN_SUFFIXES / WEB_SCAN_SUFFIXES /
_is_skipped) so the two never drift, and edits the scanner would ignore
(tests/, plugin dirs, non-migration .sql, …) short-circuit without paying for
a full-repo scan.

Exit semantics (Claude Code PostToolUse hook contract):
  0 = clean / not in scope (silent)
  2 = real violation -> stderr is fed back to Claude so the session fixes it
      now instead of discovering it in CI
  1 = non-blocking warning (a gate could not run, or hit a config error that
      is not itself a content violation)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def _load_scanner_scope(root: Path):
    """Import the scanner's own scope so this guard mirrors it exactly.
    Returns (py_web_suffixes, migrations_rel, is_skipped) or None if the
    scanner can't be imported (treated as 'gate can't run' upstream)."""
    scripts_dir = root / "scripts"
    if not (scripts_dir / "check_readonly.py").exists():
        return None
    sys.path.insert(0, str(scripts_dir))
    try:
        import check_readonly as cr  # type: ignore
    except Exception:
        return None
    finally:
        try:
            sys.path.remove(str(scripts_dir))
        except ValueError:
            pass
    suffixes = set(cr.PY_SCAN_SUFFIXES) | set(cr.WEB_SCAN_SUFFIXES)
    return suffixes, cr.MIGRATIONS_REL, cr._is_skipped


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

    suffix = path.suffix.lower()
    py = sys.executable

    # ---- RULE 2 gate (code files in the scanner's scope) --------------------
    scope = _load_scanner_scope(root)
    if scope is None:
        # Scanner missing/unimportable -> can't enforce RULE 2 here. Non-blocking
        # so we never raise a bogus violation when the gate itself can't run.
        if suffix in {".py", ".sql", ".ts", ".js", ".tsx", ".jsx", ".mjs", ".cjs", ".html"}:
            sys.stderr.write("RULE 2 gate skipped: scripts/check_readonly.py unavailable\n")
            return 1
    else:
        suffixes, migrations_rel, is_skipped = scope
        rel_posix = rel.as_posix()
        in_scope = False
        if suffix == ".sql":
            in_scope = rel_posix.startswith(migrations_rel + "/")
        elif suffix in suffixes:
            in_scope = not is_skipped(rel)
        if in_scope:
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

    # ---- docs registry gate (root or docs/ markdown) -----------------------
    if suffix == ".md" and (len(rel.parts) == 1 or rel.parts[0] == "docs"):
        bash = shutil.which("bash")
        if not bash:
            sys.stderr.write("docs gate skipped: bash not available in this environment\n")
            return 1
        proc = subprocess.run(
            [bash, str(root / "bin" / "check-docs.sh")],
            capture_output=True, text=True, cwd=str(root),
        )
        # check-docs.sh: 0 = clean, 1 = registry violation, 2 = config error
        # (README unparsable / bad arg). Only 1 is a content violation to block on.
        if proc.returncode == 1:
            sys.stderr.write(
                "DOCS REGISTRY VIOLATION introduced by this edit (bin/check-docs.sh "
                "failed — closed doc set / doc-version rules, CLAUDE.md §6). Fix "
                "before continuing:\n" + (proc.stdout + proc.stderr)[-3000:]
            )
            return 2
        if proc.returncode != 0:
            sys.stderr.write(
                "docs gate could not run (bin/check-docs.sh config error, not a "
                "content violation):\n" + (proc.stdout + proc.stderr)[-1500:]
            )
            return 1
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
