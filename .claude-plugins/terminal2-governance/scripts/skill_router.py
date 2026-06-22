#!/usr/bin/env python3
"""PreToolUse skill router — surfaces the right workflow skill at trigger time.

The discoverability half of the skills layer: a skill only helps if it's
invoked. This hook fires BEFORE a tool runs (counterpart to the PostToolUse
governance guard), matches the action to a known workflow skill, and injects a
NON-BLOCKING nudge so the agent invokes the skill instead of free-handing the
workflow and rediscovering a §3 landmine.

Design (mirrors post_edit_guard.py so the two stay consistent):
  - Only acts inside the Terminal-2 checkout (CLAUDE.md present).
  - NON-BLOCKING: emits `additionalContext`; never denies a tool call. The agent
    stays in control — the nudge is a pointer, not a gate. (The hard operator
    gate on `apply_migration` already lives in CLAUDE.md §1 + the skill itself.)
  - Fires ONCE per (session, skill): a /tmp marker keyed on session_id means the
    first migration edit nudges, not every keystroke. No nagging.
  - ROUTES is the single source of truth — add a row to wire a new skill.

PreToolUse hook contract (Claude Code):
  exit 0 + JSON {hookSpecificOutput:{hookEventName,additionalContext}} → context
  injected, tool proceeds. Anything malformed → silent exit 0 (never block on a
  harness quirk or a routing miss).
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

# --- Routing table: one row per wired skill --------------------------------
# tools   : tool names this rule reacts to (exact match)
# path_re : if set, tool_input.file_path must match (for Edit/Write-style tools)
# sql_ddl : if True, only fire when tool_input.query looks like a write/DDL
# skill   : the skill to surface
# nudge   : the line injected as additionalContext
_DDL = re.compile(r"\b(insert|update|delete|create|alter|drop|truncate|grant|revoke)\b", re.I)

ROUTES = [
    {
        "tools": {"Edit", "Write", "MultiEdit"},
        "path_re": re.compile(r"(^|/)supabase/migrations/[^/]+\.sql$"),
        "skill": "ship-a-migration",
        "nudge": (
            "A workflow skill exists for this: **ship-a-migration**. You're editing a "
            "migration file — invoke it to follow the full lifecycle (check-don't-rebuild "
            "→ sample-test on real rows → operator-gated apply → verify on the SAME samples → PR). "
            "It carries the §3 column landmines + the operator-gate rule so they aren't missed."
        ),
    },
    {
        "tools": {"mcp__Supabase__apply_migration"},
        "skill": "ship-a-migration",
        "nudge": (
            "About to apply to prod. **ship-a-migration** step 5 requires explicit operator "
            "permission for THIS apply (CLAUDE.md §1) and step 7 verifies on the same sample IDs "
            "from step 3. Confirm you've cleared those before proceeding."
        ),
    },
    {
        "tools": {"mcp__Supabase__execute_sql"},
        "sql_ddl": True,
        "skill": "ship-a-migration",
        "nudge": (
            "This `execute_sql` looks like a write/DDL, not a read. Prod mutations belong in a "
            "migration via the **ship-a-migration** workflow (operator-gated apply, verification "
            "gate), not ad-hoc execute_sql. If this is a read-only audit query, ignore this."
        ),
    },
]


def _match(tool_name: str, tool_input: dict, root: Path):
    for rule in ROUTES:
        if tool_name not in rule["tools"]:
            continue
        pr = rule.get("path_re")
        if pr is not None:
            fp = tool_input.get("file_path") or ""
            try:
                rel = Path(fp).resolve().relative_to(root).as_posix()
            except (ValueError, OSError):
                rel = fp.replace("\\", "/")
            if not pr.search(rel):
                continue
        if rule.get("sql_ddl"):
            if not _DDL.search(tool_input.get("query") or ""):
                continue
        return rule
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    root = Path(os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or ".").resolve()
    if not (root / "CLAUDE.md").exists():  # not the Terminal-2 checkout
        return 0

    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    rule = _match(tool_name, tool_input, root)
    if rule is None:
        return 0

    # Fire once per (session, skill) — avoid nagging on every edit.
    session = re.sub(r"[^A-Za-z0-9_-]", "", str(payload.get("session_id") or "default"))[:64]
    marker = Path(tempfile.gettempdir()) / f"t2_skill_router_{session}_{rule['skill']}.seen"
    if marker.exists():
        return 0
    try:
        marker.touch()
    except OSError:
        pass  # best-effort; nudging twice is harmless, blocking would be worse

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": rule["nudge"],
        }
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
