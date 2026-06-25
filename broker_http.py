"""Shared HTTP transport for the read-only upstream-API clients.

Every ``*_client.py`` at the repo root is GET-only by construction (the lone
carve-out is ``seatdata_client``'s one sanctioned metadata POST). Historically
each client reimplemented the same retry/backoff loop and the same Vault-secret
lookup, and the retry-status set had drifted apart client to client — some
backed off on 503/504, some only on 429, so a transient SeatGeek 503 failed
hard while the same condition on TEvo retried. This module is the single home
for that shared transport logic so the behavior is consistent and lives in one
place.

RULE 2 (CLAUDE.md §2) — this module issues GET requests ONLY. The per-client
read-only guards (``_assert_readonly_method`` / ``ALLOWED_HTTP_METHODS``)
deliberately stay in each client file so ``scripts/check_readonly.py`` can
prove the read-only contract per-client; nothing here weakens or relocates
them. ``get_with_retry`` never sends a non-GET method.
"""
from __future__ import annotations

import random
import time
from typing import Any

import requests


# Canonical transient-failure set. Superset of the per-client sets that had
# drifted apart (429-only on SeatGeek/SeatData; 429/503 on TickPick/Vivid/
# GoTickets; the full set only on TEvo). 502/503/504 are all transient
# gateway/upstream conditions that warrant a backoff-and-retry.
RETRY_STATUSES = frozenset({429, 502, 503, 504})

DEFAULT_MAX_ATTEMPTS = 5            # total tries incl. the first (== 4 retries)
DEFAULT_BACKOFF_BASE_SEC = 0.5
DEFAULT_BACKOFF_CAP_SEC = 30.0


def vault_secret(db: Any, name: str, *, log_prefix: str = "vault") -> str | None:
    """Resolve a secret from Supabase Vault via the ``get_app_secret`` RPC.

    Requires a service-role ``db`` client. Returns ``None`` (never raises, never
    surfaces the value) on a missing client or any lookup failure — only the
    failure, never the secret, is printed.
    """
    if db is None:
        return None
    try:
        res = db.rpc("get_app_secret", {"p_name": name}).execute()
        return getattr(res, "data", None) or None
    except Exception as e:  # only the failure, never the value
        print(f"{log_prefix}: vault lookup for {name} failed: {e}")
        return None


def retry_delay(
    resp: Any,
    attempt: int,
    *,
    base: float = DEFAULT_BACKOFF_BASE_SEC,
    cap: float = DEFAULT_BACKOFF_CAP_SEC,
    jitter: bool = False,
) -> float:
    """Seconds to wait before the next retry.

    Honors a numeric ``Retry-After`` header when the server provides one, else
    exponential backoff ``base * 2 ** (attempt - 1)``. ``attempt`` is 1-based
    (the first retry is ``attempt == 1``). Result is capped at ``cap``; with
    ``jitter`` a uniform ``[0, 1)`` is added before the cap to de-correlate
    concurrent retriers.
    """
    ra = resp.headers.get("Retry-After") if resp is not None else None
    try:
        wait = float(ra) if ra else base * (2 ** (attempt - 1))
    except (TypeError, ValueError):
        wait = base * (2 ** (attempt - 1))
    if jitter:
        wait += random.random()
    return min(wait, cap)


def get_with_retry(
    url: str,
    *,
    getter: Any = None,
    timeout: float,
    retry_statuses: frozenset[int] | tuple[int, ...] = RETRY_STATUSES,
    max_attempts: int = DEFAULT_MAX_ATTEMPTS,
    backoff_base: float = DEFAULT_BACKOFF_BASE_SEC,
    backoff_cap: float = DEFAULT_BACKOFF_CAP_SEC,
    jitter: bool = False,
    **request_kwargs: Any,
) -> requests.Response:
    """Issue a GET (the only method these clients use) with unified retry/backoff.

    ``getter`` defaults to ``requests.get``; pass a bound ``session.get`` for a
    client that holds a ``requests.Session``, or a thin wrapper that maps
    connection errors onto a client-specific exception. Extra keyword arguments
    (``params=``, ``headers=``) flow straight through to the getter, so a caller
    that previously wrote ``requests.get(url, params=p, timeout=t)`` keeps the
    exact same call shape (and any test monkeypatching ``requests.get`` keeps
    working).

    Retries while the response status is in ``retry_statuses`` and attempts
    remain, sleeping per :func:`retry_delay`. Returns the final ``Response`` —
    after retries are exhausted or a non-retryable status arrives — and never
    raises on an HTTP status: the caller maps status onto its own exceptions,
    exactly as before.
    """
    get = getter or requests.get
    attempt = 0
    resp: requests.Response | None = None
    while True:
        attempt += 1
        resp = get(url, timeout=timeout, **request_kwargs)
        if resp.status_code in retry_statuses and attempt < max_attempts:
            time.sleep(
                retry_delay(resp, attempt, base=backoff_base, cap=backoff_cap, jitter=jitter)
            )
            continue
        return resp
