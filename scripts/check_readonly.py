#!/usr/bin/env python3
"""RULE 2 enforcement scan — fail the build on any code that could push to
TEvo, SeatGeek, TickPick, or Vivid Seats.

We integrate with these external read-only data sources for our orders /
sales / listings feeds:
  - api.ticketevolution.com           (TEvo orders + listings)
  - brokerdata.seatgeek.com           (SG broker data — listings + sales)
  - sellerdirect-api.seatgeek.com     (SG seller direct)
  - api.tickpick.com                  (TickPick broker orders)
  - brokers.vividseats.com            (Vivid Seats broker orders)
  - sc.gotickets.com                  (GoTickets broker sales)
  - gotickets.com                     (GoTickets Pro API — listings read; its
                                       POST /orders purchase endpoint is locked)
  - seatdata.io                       (SeatData market analytics)
  - ticketsdata.com                   (TicketsData cross-platform feed)
  - www.broadway.com / checkout.broadway.com  (Broadway.com availability)
  - rest.bandsintown.com              (Bands in Town artist tour dates)
  - api.twitterapi.io                 (TwitterAPI.io — X posts for the news wire)

This script grep-walks the repo and fails (exit 1) if it finds:
  1. requests.(post|put|patch|delete) calls anywhere in Python
  2. fetch(...) calls in TS/JS with method other than GET
  3. net.http_post|put|patch|delete calls in plpgsql migrations targeting
     forbidden hosts (Phase-1 server-side data ingest path)
  4. The hardcoded host strings appearing alongside non-GET method tokens
  5. The runtime guards (_assert_readonly_method / ALLOWED_HTTP_METHODS)
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

import functools
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
    "api.tickpick.com",
    "brokers.vividseats.com",
    "sc.gotickets.com",
    # GoTickets Pro API host (gotickets.com/rest/pro/api). It has a real
    # purchase endpoint (POST /orders) that must NEVER be written; we only read
    # GET /events/{id}/listings via gotickets_client.GoTicketsProClient. Bare
    # "gotickets.com" substring-matches gotickets.com AND sc.gotickets.com / any
    # future subdomain, same pattern as axs.com / seatdata.io / evenue.net.
    "gotickets.com",
    "seatdata.io",
    "ticketsdata.com",
    "www.broadway.com",
    "checkout.broadway.com",
    "rest.bandsintown.com",
    # TwitterAPI.io (X read gateway for the news wire — pg_net GET only, no
    # Python client). Bare host substring-matches api.twitterapi.io and any
    # future subdomain, same as seatdata.io / axs.com.
    "twitterapi.io",
    # AXS has order/hold endpoints that must never be touched. All sanctioned
    # AXS traffic proxies through ticketsdata.com (covered above); a direct
    # call to axs.com is forbidden outright. Bare "axs.com" substring-matches
    # www.axs.com / api.axs.com / any future subdomain.
    "axs.com",
    # Paciolan / eVenue primary box-office (live purchase flow with order/hold
    # endpoints). Collection is browser-extension-sourced (read-only DOM scrape,
    # see paciolan_extension/ + paciolan_client.py); a direct write to any
    # eVenue host is forbidden. Bare "evenue.net" substring-matches
    # <tenant>.evenue.net / any future subdomain, same as seatdata.io / axs.com.
    "evenue.net",
    # S4K CRM marketplace-orders API. A SEPARATE source from the Paciolan
    # pipeline above — own host, own auth, own subject (our sell-side resale
    # ORDERS, not box-office inventory). Documented GET-only and the key
    # carries only marketplace:read, but the host is pinned here so the audit
    # fails the build if a write path is ever introduced.
    # Read-only via s4k_marketplace_client.S4KMarketplaceClient.
    "crm.s4kcs.com",
)

# Client modules that legitimately reference these hosts, mapped to the HTTP
# methods each is permitted to use. Other files can mention the hosts in
# comments/docs only.
#
# All clients are GET-only EXCEPT seatdata_client.py, which has ONE sanctioned
# metadata POST (/v0.4/events/event-request-add) that writes none of our data
# and touches no price/inventory — see CLAUDE.md §2 listing-source lockdown.
CLIENT_FILES = {
    "evo_client.py": frozenset({"GET"}),
    "seatgeek_client.py": frozenset({"GET"}),
    "tickpick_client.py": frozenset({"GET"}),
    "vivid_client.py": frozenset({"GET"}),
    "gotickets_client.py": frozenset({"GET"}),
    "seatdata_client.py": frozenset({"GET", "POST"}),
    "ticketsdata_client.py": frozenset({"GET"}),
    "broadway_client.py": frozenset({"GET"}),
    "axs_client.py": frozenset({"GET"}),
    "bandsintown_client.py": frozenset({"GET"}),
    # Paciolan/eVenue normalizer — makes NO network calls (browser-extension-
    # sourced), but declares the canonical GET-only guard so the new upstream is
    # locked by the same mechanical audit as every other source.
    "paciolan_client.py": frozenset({"GET"}),
    # S4K CRM marketplace-orders API (crm.s4kcs.com). Separate source from
    # paciolan_client.py — shares no tables, no cron, no code with it.
    "s4k_marketplace_client.py": frozenset({"GET"}),
}

# Guard tokens that must appear in EVERY client module, regardless of which
# HTTP methods it permits.
COMMON_GUARD_TOKENS = (
    "_assert_readonly_method",
    "ALLOWED_HTTP_METHODS",
)


def _frozenset_token(methods: frozenset[str]) -> str:
    """Render the exact `frozenset({...})` literal a client must declare for
    its allowed-methods set, e.g. frozenset({"GET"}) or
    frozenset({"GET", "POST"}). Mirrors the source spelling so the token
    check verifies the client hasn't widened its method allowlist."""
    inner = ", ".join(f'"{m}"' for m in sorted(methods))
    return f"frozenset({{{inner}}})"

# Patterns that signal a write attempt in Python.
PY_FORBIDDEN_PATTERNS = (
    re.compile(r"requests\.\s*(post|put|patch|delete)\s*\("),
    re.compile(r"\.session\.\s*(post|put|patch|delete)\s*\("),
    re.compile(r"http\.\s*(post|put|patch|delete)\s*\("),
    re.compile(r"httpx\.\s*(post|put|patch|delete)\s*\("),
    # method-as-string variants: session.request("POST", ...), requests.request('PUT', ...)
    re.compile(r"""\.request\s*\(\s*['"](?:POST|PUT|PATCH|DELETE)['"]""", re.IGNORECASE),
    re.compile(r"""requests\.request\s*\(\s*['"](?:POST|PUT|PATCH|DELETE)['"]""", re.IGNORECASE),
    # urllib.request.urlopen(..., data=...) silently becomes a POST
    re.compile(r"urlopen\s*\([^)]*\bdata\s*="),
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

# SKIP_DIRS applies only to .py / .ts walks. plpgsql scan opts in supabase/migrations explicitly.
# File suffixes each scan covers. Exposed as module constants so external
# callers (e.g. the terminal2-governance edit-time hook) can mirror this
# scanner's exact scope instead of maintaining a drift-prone parallel list.
PY_SCAN_SUFFIXES = (".py",)
WEB_SCAN_SUFFIXES = (".ts", ".js", ".tsx", ".jsx", ".mjs", ".cjs", ".html")
# .sql is scanned ONLY under this dir (see check_plpgsql_writes); .sql edits
# elsewhere are out of scanner scope.
MIGRATIONS_REL = "supabase/migrations"

SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", ".claude",
             "supabase/migrations", ".next", "dist", "build",
             # tests/ is allowed to embed synthetic violations as test fixtures
             "tests"}

# plpgsql write-method patterns (Phase-1 server-side ingest uses pg_net)
PLPGSQL_FORBIDDEN_PATTERN = re.compile(
    r"net\.http_(post|put|patch|delete)\s*\(",
    flags=re.IGNORECASE,
)


def _is_skipped(path: Path) -> bool:
    parts = set(path.parts)
    return any(d in parts for d in SKIP_DIRS) or any(
        str(path).replace("\\", "/").startswith(d) for d in SKIP_DIRS
    )


@functools.lru_cache(maxsize=None)
def _walk(suffixes: tuple[str, ...]) -> list[Path]:
    # Cached per-process: main()'s success banner re-requests the same suffix
    # tuples the checkers already walked, and the edit-time hook puts this
    # script on the per-edit hot path — without the cache a clean run does
    # two redundant full-tree rglob() traversals just to print counts.
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
    for f in _walk(PY_SCAN_SUFFIXES):
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
    # .html covers inline <script> blocks; .mjs/.cjs cover module/CommonJS JS.
    for f in _walk(WEB_SCAN_SUFFIXES):
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
                # No fetch() context — axios/XHR/got-style call. We can't parse
                # the URL arg structurally, so fall back to a proximity check:
                # flag if a forbidden host (or a var bound to one) appears in
                # the surrounding window.
                window = text[max(0, m.start() - 800) : min(len(text), m.end() + 400)]
                hits = [h for h in FORBIDDEN_HOSTS if h in window]
                var_hits = [n for n in host_vars if re.search(rf"\b{re.escape(n)}\b", window)]
                if hits or var_hits:
                    line_no = text[: m.start()].count("\n") + 1
                    violations.append(
                        f"{f.relative_to(ROOT)}:{line_no}: "
                        f"'{m.group(0)}' (non-fetch HTTP call) near forbidden "
                        f"host(s) {hits or var_hits}"
                    )
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


def check_plpgsql_writes() -> list[str]:
    """Scan supabase/migrations/*.sql for net.http_post|put|patch|delete calls
    targeting forbidden hosts. Phase-1 server-side ingest writes data via
    pg_net and could bypass the Python/TS RULE 2 layers if not checked here."""
    violations: list[str] = []
    mig_dir = ROOT / "supabase" / "migrations"
    if not mig_dir.exists():
        return violations
    for f in sorted(mig_dir.glob("*.sql")):
        text = f.read_text(encoding="utf-8", errors="ignore")
        for m in PLPGSQL_FORBIDDEN_PATTERN.finditer(text):
            # Look at the surrounding 800 chars for the URL.
            start = max(0, m.start() - 200)
            end = min(len(text), m.end() + 800)
            snippet = text[start:end]
            forbidden_hits = [h for h in FORBIDDEN_HOSTS if h in snippet]
            if forbidden_hits:
                line_no = text[: m.start()].count("\n") + 1
                violations.append(
                    f"{f.relative_to(ROOT)}:{line_no}: "
                    f"'{m.group(0)}' near forbidden host(s) {forbidden_hits}"
                )
    return violations


def check_guard_tokens() -> list[str]:
    """Each client module must contain the runtime guard tokens."""
    violations: list[str] = []
    # Opt-OUT, not opt-in: discover every root-level *_client.py and require it
    # to be registered in CLIENT_FILES. Without this a newly-added client gets
    # ZERO guard-token enforcement and slips past silently (audit 2026-06-22).
    for p in sorted(ROOT.glob("*_client.py")):
        if p.name not in CLIENT_FILES:
            violations.append(
                f"{p.name}: unregistered *_client.py — add it to CLIENT_FILES in "
                "scripts/check_readonly.py with its permitted HTTP methods so the "
                "RULE 2 guard-token check covers it (every broker client must be "
                "GET-only by construction)."
            )
    for client, methods in CLIENT_FILES.items():
        p = ROOT / client
        if not p.exists():
            violations.append(f"{client}: file missing — guard cannot be verified")
            continue
        text = p.read_text(encoding="utf-8", errors="ignore")
        required = (*COMMON_GUARD_TOKENS, _frozenset_token(methods))
        for tok in required:
            if tok not in text:
                violations.append(
                    f"{client}: guard token {tok!r} not present "
                    "(RULE 2 enforcement removed or method allowlist widened?)"
                )
    return violations


def main() -> int:
    py_violations = check_python_writes()
    ts_violations = check_ts_writes()
    plpgsql_violations = check_plpgsql_writes()
    guard_violations = check_guard_tokens()

    total = py_violations + ts_violations + plpgsql_violations + guard_violations
    if total:
        print("RULE 2 VIOLATIONS — read-only contract broken:")
        for v in total:
            print(f"  - {v}")
        print()
        print("Fix: route the call through one of the GET-only clients — "
              "evo_client.EvoClient, seatgeek_client.SeatGeekClient, "
              "tickpick_client.TickPickClient, vivid_client.VividClient — "
              "or use net.http_get exclusively in plpgsql migrations.")
        return 1

    mig_count = len(list((ROOT / "supabase" / "migrations").glob("*.sql"))) if (ROOT / "supabase" / "migrations").exists() else 0
    print("RULE 2 clean — no write paths detected to TEvo, SeatGeek, TickPick, or Vivid Seats hosts.")
    print(f"  - Python files scanned   : {len(_walk(PY_SCAN_SUFFIXES))}")
    print(f"  - TS/JS/HTML files scanned: {len(_walk(WEB_SCAN_SUFFIXES))}")
    print(f"  - plpgsql migrations     : {mig_count}")
    print(f"  - Client guards present  : {', '.join(sorted(CLIENT_FILES))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
