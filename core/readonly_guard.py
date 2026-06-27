"""Canonical RULE-2 read-only method guard for the broker API clients.

BR-CODE-2 (client dedup). The 8 GET-only `*_client.py` modules each hand-rolled
an identical `_assert_readonly_method` — same comparison, same
"READ-ONLY violation … RULE 2" message, only the error class + a trailing
host sentence differed. Eight copies of the *one security-critical assertion*
is exactly the drift surface RULE 2 can least afford, so this factory
single-sources the logic.

Each client still declares its own module-level `ALLOWED_HTTP_METHODS`
(`frozenset({"GET"})`) + error class + `_assert_readonly_method` name — the
`scripts/check_readonly.py` static audit requires those tokens in every client
file, and `tests/test_readonly_guards.py` imports them per-client. This factory
only supplies the shared *body*.

seatdata_client keeps its own bespoke guard: it permits the one sanctioned
metadata POST (`/v0.4/events/event-request-add`) under a path allowlist, which
this GET-shaped factory deliberately does not model.
"""
from __future__ import annotations

from typing import Callable


def build_readonly_guard(
    error_cls: type[Exception],
    allowed_methods: frozenset[str],
    detail: str = "",
) -> Callable[[str], None]:
    """Return the canonical `_assert_readonly_method(method)` for a client.

    Raises `error_cls` (with the standard "READ-ONLY violation … RULE 2"
    message, plus the client's `detail` host sentence) whenever `method` —
    case-insensitively — is outside `allowed_methods`. GET (and any other
    listed method) passes silently. No network call is ever made; this is a
    pure pre-flight tripwire.
    """
    def _assert_readonly_method(method: str) -> None:
        if method.upper() not in allowed_methods:
            msg = (
                f"READ-ONLY violation: method {method} is not allowed. "
                "RULE 2 read-only lockdown (CLAUDE.md §2)."
            )
            if detail:
                msg = f"{msg} {detail}"
            raise error_cls(msg)

    return _assert_readonly_method
