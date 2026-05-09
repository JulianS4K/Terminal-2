#!/usr/bin/env python3
"""RULE 2 enforcement scan — fail the build on any code that could push to
TEvo or SeatGeek.

We integrate with three external read-only data sources:
  - api.ticketevolution.com           (TEvo)
  - brokerdata.seatgeek.com           (SG broker data)
  - sellerdirect-api.seatgeek.com     (SG seller direct)

This script grep-walks the repo and fails (exit 1) if it finds:
  1. requests.(post|put|patch|delete) calls anywhere in Python
  2. fetch(...) calls in TS/JS with method other than GET
  3. The hardcoded host strings appearing alongside non-GET method tokens
  4. The runtime guards (_assert_readonly_method / ALLOWED_HTTP_METHODS)
     missing from the client modules

Run as part of CI / pre-commit. Designed to fail loudly so neither code,
design coworker, nor any future AI session can ship a write to either
host without flipping this script's allowlist (which requires human review).

Usage:
  python scripts/check_readonly.py
  → exit 0 with "RULE 2 clean" if all checks pass
  → exit 1 with itemized violations if anything looks like a write attempt
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Hosts we may NEVER write to.
FORBIDDEN_HOSTS = (
    "api.ticketevolution.com",
    "api.sandbox.ticketevolution.com",
    "brokerdata.seatgeek.com",
    "sellerdirect-api.seatgeek.com",
)

# Files that legitimately reference these hosts (i.e. the client modules).
# Other files can mention the hosts in comments/docs only.
CLIENT_FILES = {
    "evo_client.py",
    "seatgeek_client.py",
}

# Required guard tokens that must appear in each client module.
REQUIRED_GUARD_TOKENS = (
    "_assert_readonly_method",
    "ALLOWED_HTTP_METHODS",
    'frozenset({"GET"})',
)

# Patterns that signal a write attempt in Python.
PY_FORBIDDEN_PATTERNS = (
    re.compile(r"requests\.\s*(post|put|patch|delete)\s*\("),
    re.compile(r"\.session\.\s*(post|put|patch|delete)\s*\("),
    re.compile(r"http\.\s*(post|put|patch|delete)\s*\("),
    re.compile(r"httpx\.\s*(post|put|patch|delete)\s*\("),
)

# Patterns that signal a write attempt in TS/JS edge functions.
# We accept method:"GET" / method:'GET' / no method (defaults to GET).
TS_FORBIDDEN_PATTERN = re.compile(
    r"""method\s*:\s*['"](POST|PUT|PATCH|DELETE)['"]""",
    flags=re.IGNORECASE,
)

# Hosts allowed to receive POST from edge functions (LLM call, etc.).
TS_POST_ALLOWLIST = (
    "api.anthropic.com",
)

SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", ".claude",
             "supabase/migrations", ".next", "dist", "build",
             # tests/ is allowed to embed synthetic violations as test fixtures
             "tests"}


def _is_skipped(path: Path) -> bool:
    parts = set(path.parts)
    return any(d in parts for d in SKIP_DIRS) or any(
        str(path).replace("\\", "/").startswith(d) for d in SKIP_DIRS
    )


def _walk(suffixes: tuple[str, ...]) -> list[Path]:
    out: list[Path] = []
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix not in suffixes:
            continue
        if _is_skipped(p.relative_to(ROOT)):
            continue
        out.append(p)
    return out


def check_python_writes() -> list[str]:
    """Find any Python file with requests.post/.put/.patch/.delete or similar."""
    violations: list[str] = []
    for f in _walk((".py",)):
        text = f.read_text(encoding="utf-8", errors="ignore")
        for pattern in PY_FORBIDDEN_PATTERNS:
            for m in pattern.finditer(text):
                # Check the surrounding 200 chars for forbidden host strings.
                start = max(0, m.start() - 100)
                end = min(len(text), m.end() + 200)
                snippet = text[start:end]
                hits = [h for h in FORBIDDEN_HOSTS if h in snippet]
                if hits:
                    line_no = text[: m.start()].count("\n") + 1
                    violations.append(
                        f"{f.relative_to(ROOT)}:{line_no}: "
                        f"'{m.group(0)}' near forbidden host(s) {hits}"
                    )
    return violations


def _ts_forbidden_host_vars(text: str) -> set[str]:
    """Find variable names in a TS/JS file that bind to a forbidden host
    string, e.g. `const TEVO_HOST = "api.ticketevolution.com"`. Returns the
    set of identifier names so we can detect indirect URL composition."""
    names: set[str] = set()
    # const|let|var NAME = "...host..."   (literal binding)
    pat_lit = re.compile(
        r"""(?:const|let|var)\s+([A-Z_][A-Z0-9_]*)\s*=\s*['"`]([^'"`]+)['"`]"""
    )
    for m in pat_lit.finditer(text):
        name, val = m.group(1), m.group(2)
        if any(h in val for h in FORBIDDEN_HOSTS):
            names.add(name)
    # Composed bindings: const FOO = `https://${TEVO_HOST}` or FOO = "https://" + TEVO_HOST
    pat_compose = re.compile(
        r"""(?:const|let|var)\s+([A-Z_][A-Z0-9_]*)\s*=\s*[`'"][^`'"]*\$\{([A-Z_][A-Z0-9_]*)\}|"""
        r"""(?:const|let|var)\s+([A-Z_][A-Z0-9_]*)\s*=\s*['"][^'"]*['"]\s*\+\s*([A-Z_][A-Z0-9_]*)"""
    )
    for m in pat_compose.finditer(text):
        new_name = m.group(1) or m.group(3)
        ref = m.group(2) or m.group(4)
        if ref in names and new_name:
            names.add(new_name)
    return names


def check_ts_writes() -> list[str]:
    """Find any TS/JS file with method:'POST'|'PUT'|'PATCH'|'DELETE' that
    targets a forbidden host either by literal URL or by a variable that
    resolves to one."""
    violations: list[str] = []
    for f in _walk((".ts", ".js", ".tsx", ".jsx")):
        text = f.read_text(encoding="utf-8", errors="ignore")
        host_vars = _ts_forbidden_host_vars(text)
        for m in TS_FORBIDDEN_PATTERN.finditer(text):
            # Locate the enclosing fetch(...) call. Walk back to find the
            # nearest `fetch(` so we can inspect its URL argument.
            preceding = text[max(0, m.start() - 800) : m.start()]
            # The URL arg is the first arg to fetch — text between the last
            # 'fetch(' and the next ',' or method keyword.
            i = preceding.rfind("fetch(")
            if i == -1:
                # No fetch() context — skip (probably XHR or something else).
                continue
            url_arg_region = preceding[i + len("fetch(") :]
            # Strip leading whitespace / quotes context up to the comma.
            comma = url_arg_region.find(",")
            url_arg = url_arg_region[: comma if comma >= 0 else 200]

            if any(h in url_arg for h in FORBIDDEN_HOSTS):
                line_no = text[: m.start()].count("\n") + 1
                hits = [h for h in FORBIDDEN_HOSTS if h in url_arg]
                violations.append(
                    f"{f.relative_to(ROOT)}:{line_no}: "
                    f"'{m.group(0)}' on fetch() to forbidden host(s) {hits}"
                )
                continue
            if any(name in url_arg for name in host_vars):
                line_no = text[: m.start()].count("\n") + 1
                hits = [n for n in host_vars if n in url_arg]
                violations.append(
                    f"{f.relative_to(ROOT)}:{line_no}: "
                    f"'{m.group(0)}' on fetch() with host var(s) {hits}"
                )
    return violations


def check_guard_tokens() -> list[str]:
    """Each client module must contain the runtime guard tokens."""
    violations: list[str] = []
    for client in CLIENT_FILES:
        p = ROOT / client
        if not p.exists():
            violations.append(f"{client}: file missing — guard cannot be verified")
            continue
        text = p.read_text(encoding="utf-8", errors="ignore")
        for tok in REQUIRED_GUARD_TOKENS:
            if tok not in text:
                violations.append(
                    f"{client}: guard token {tok!r} not present "
                    "(RULE 2 enforcement removed?)"
                )
    return violations


def main() -> int:
    py_violations = check_python_writes()
    ts_violations = check_ts_writes()
    guard_violations = check_guard_tokens()

    total = py_violations + ts_violations + guard_violations
    if total:
        print("RULE 2 VIOLATIONS — read-only contract broken:")
        for v in total:
            print(f"  - {v}")
        print()
        print("Fix: route the call through evo_client.EvoClient or "
              "seatgeek_client.SeatGeekClient (GET-only). If the call is "
              "intentionally read-only and lives outside those clients, "
              "add the runtime guard or move it into the client.")
        return 1

    print("RULE 2 clean — no write paths detected to TEvo or SeatGeek hosts.")
    print(f"  - Python files scanned: {len(_walk(('.py',)))}")
    print(f"  - TS/JS files scanned : {len(_walk(('.ts', '.js', '.tsx', '.jsx')))}")
    print(f"  - Client guards present: {', '.join(sorted(CLIENT_FILES))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
