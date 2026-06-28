"""Shared HTTP retry/backoff loop for the read-only broker clients (BR-CODE-2).

Every `*_client.py` hand-rolled the same 429/5xx retry loop — make the request,
on a retryable status honor `Retry-After` (else capped exponential backoff),
sleep, retry up to N times — with subtly *different* constants and, worse,
inconsistent correctness. This centralizes the loop so the rate-limit handling
is uniform and audited in one place.

The helper owns only the LOOP: it calls `do_request()` (a thunk the client
supplies, wrapping its own transport/auth/params) and returns the final
`requests.Response` for the caller to parse / raise on. Each client keeps its
bespoke response handling (some return `.json()`, some a `(status, body)` tuple,
some raise a sanitized error) — only the retry mechanics are shared.

`sleep` + `jitter` are injected so the loop is deterministic under test (clients
pass their own module's `time.sleep`, which keeps their existing
`monkeypatch.setattr(<client>.time, "sleep", ...)` tests binding).
"""
from __future__ import annotations

import time
from typing import Any, Callable


def fetch_with_retry(
    do_request: Callable[[], Any],
    *,
    max_retries: int,
    retry_statuses,
    base_backoff: float,
    max_backoff: float,
    sleep: Callable[[float], None] = time.sleep,
    jitter: Callable[[], float] | None = None,
):
    """Call `do_request()` (→ a requests.Response) with retry on a retryable
    status code.

    Returns the final Response — `.ok` or not — for the caller to handle.
    Returns ``None`` only when ``max_retries < 0`` (empty range, no request
    made): a defensive no-op the clients guard against.

    Backoff: `Retry-After` header wins when present + numeric; otherwise
    `base_backoff * 2**attempt`. Always clamped to `max_backoff`. When `jitter`
    is supplied, its value is added to each wait (still clamped) — used by the
    SeatGeek-family clients that spread retries to avoid thundering-herd.
    """
    last = None
    for attempt in range(max_retries + 1):
        r = do_request()
        last = r
        if r.ok:
            return r
        if r.status_code not in retry_statuses or attempt == max_retries:
            return r
        ra = r.headers.get("Retry-After")
        if ra:
            try:
                wait = float(ra)
            except (TypeError, ValueError):
                wait = base_backoff * (2 ** attempt)
        else:
            wait = base_backoff * (2 ** attempt)
        wait = min(wait, max_backoff)
        if jitter is not None:
            wait = min(max_backoff, wait + jitter())
        sleep(wait)
    return last
