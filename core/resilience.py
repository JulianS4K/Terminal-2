"""Circuit breaker + retry/backoff for outbound dependency calls (Supabase).

Production-readiness P1 (`docs/production_readiness.md` row 4): a Supabase hiccup
should fail fast and shed load, not cascade. This module provides the primitives:

  * `CircuitBreaker` — after `fail_threshold` consecutive failures it OPENS and
    fast-fails every call for `reset_timeout` seconds, then allows a single
    HALF-OPEN trial. A success closes it; a failure re-opens it.
  * `resilient_call` — run a thunk with bounded retry + exponential backoff,
    honoring a breaker (fast-fail when open).
  * `safe_read` — `resilient_call` that swallows the final failure and returns a
    caller-supplied fallback (the storefront stale-snapshot path).

Time and sleep are injectable so the logic is deterministic under test (no real
clock, no real sleeping) — `time.monotonic`/`time.sleep` are the prod defaults.
"""
from __future__ import annotations

import time
from typing import Callable

CLOSED = "closed"
OPEN = "open"
HALF_OPEN = "half_open"


class CircuitOpenError(Exception):
    """Raised by resilient_call when the breaker is OPEN (fast-fail, no call)."""


class CircuitBreaker:
    """Consecutive-failure breaker with a timed half-open trial.

    State is derived from `_opened_at` + the clock, so it advances to HALF_OPEN
    on its own once `reset_timeout` elapses — no background timer needed.
    """

    def __init__(
        self,
        fail_threshold: int = 5,
        reset_timeout: float = 30.0,
        *,
        now: Callable[[], float] = time.monotonic,
    ):
        self.fail_threshold = fail_threshold
        self.reset_timeout = reset_timeout
        self._now = now
        self._failures = 0
        self._opened_at: float | None = None

    @property
    def status(self) -> str:
        if self._opened_at is None:
            return CLOSED
        if self._now() - self._opened_at >= self.reset_timeout:
            return HALF_OPEN
        return OPEN

    @property
    def failures(self) -> int:
        return self._failures

    def allow(self) -> bool:
        """True unless the breaker is fully OPEN (HALF_OPEN allows one trial)."""
        return self.status != OPEN

    def record_success(self) -> None:
        self._failures = 0
        self._opened_at = None

    def record_failure(self) -> None:
        self._failures += 1
        if self._failures >= self.fail_threshold:
            # (Re)open. In HALF_OPEN this re-arms the timer for another wait.
            self._opened_at = self._now()


def resilient_call(
    fn: Callable,
    *,
    breaker: CircuitBreaker | None = None,
    retries: int = 2,
    base_delay: float = 0.1,
    max_delay: float = 2.0,
    exceptions: tuple = (Exception,),
    sleep: Callable[[float], None] = time.sleep,
):
    """Call `fn()` with up to `retries` retries + exponential backoff.

    Honors `breaker`: fast-fails with CircuitOpenError when OPEN, records each
    success/failure, and stops retrying early if a failure trips the breaker OPEN.
    """
    if breaker is not None and not breaker.allow():
        raise CircuitOpenError("circuit open")
    attempt = 0
    while True:
        try:
            result = fn()
        except exceptions:
            attempt += 1
            if breaker is not None:
                breaker.record_failure()
            # Out of retries, or the breaker just tripped open -> give up.
            if attempt > retries or (breaker is not None and not breaker.allow()):
                raise
            sleep(min(base_delay * (2 ** (attempt - 1)), max_delay))
            continue
        else:
            if breaker is not None:
                breaker.record_success()
            return result


def safe_read(
    fn: Callable,
    fallback,
    *,
    breaker: CircuitBreaker | None = None,
    retries: int = 1,
    sleep: Callable[[float], None] = time.sleep,
    on_error: Callable[[Exception], None] | None = None,
):
    """`resilient_call` that never raises — returns `fallback` on final failure.

    `fallback` may be a value or a zero-arg callable (evaluated lazily, only when
    needed). `on_error(exc)` is invoked with the swallowed exception for logging.
    The storefront's stale-snapshot read path.
    """
    try:
        return resilient_call(fn, breaker=breaker, retries=retries, sleep=sleep)
    except Exception as exc:  # noqa: BLE001 - intentional catch-all: this is the shed-load boundary
        if on_error is not None:
            on_error(exc)
        return fallback() if callable(fallback) else fallback
