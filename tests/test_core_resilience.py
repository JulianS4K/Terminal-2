"""Tests for core/resilience.py — circuit breaker + retry/backoff + safe_read.

All time/sleep is injected so the logic is deterministic (no real clock, no real
sleeping). Production-readiness P1 #4: a Supabase hiccup must fail fast + shed
load, not cascade.
"""
from __future__ import annotations

import pytest

from core.resilience import (
    CLOSED,
    HALF_OPEN,
    OPEN,
    CircuitBreaker,
    CircuitOpenError,
    resilient_call,
    safe_read,
)


def _clock():
    box = {"t": 0.0}
    return box, (lambda: box["t"])


# --- CircuitBreaker ----------------------------------------------------------

def test_breaker_starts_closed():
    cb = CircuitBreaker()
    assert cb.status == CLOSED
    assert cb.allow() is True
    assert cb.failures == 0


def test_breaker_opens_at_threshold():
    box, now = _clock()
    cb = CircuitBreaker(fail_threshold=3, reset_timeout=30, now=now)
    cb.record_failure(); cb.record_failure()
    assert cb.status == CLOSED          # 2 < 3
    cb.record_failure()
    assert cb.status == OPEN            # 3 >= 3
    assert cb.allow() is False
    assert cb.failures == 3


def test_breaker_half_opens_after_reset_timeout():
    box, now = _clock()
    cb = CircuitBreaker(fail_threshold=1, reset_timeout=30, now=now)
    cb.record_failure()
    assert cb.status == OPEN
    box["t"] = 29.9
    assert cb.status == OPEN
    box["t"] = 30.0
    assert cb.status == HALF_OPEN
    assert cb.allow() is True           # half-open permits a trial


def test_breaker_success_closes():
    box, now = _clock()
    cb = CircuitBreaker(fail_threshold=1, reset_timeout=30, now=now)
    cb.record_failure()
    assert cb.status == OPEN
    cb.record_success()
    assert cb.status == CLOSED
    assert cb.failures == 0


def test_breaker_reopens_on_half_open_failure():
    box, now = _clock()
    cb = CircuitBreaker(fail_threshold=1, reset_timeout=30, now=now)
    cb.record_failure()
    box["t"] = 30.0
    assert cb.status == HALF_OPEN
    cb.record_failure()                 # trial fails -> re-arm at t=30
    assert cb.status == OPEN
    box["t"] = 59.9
    assert cb.status == OPEN
    box["t"] = 60.0
    assert cb.status == HALF_OPEN


# --- resilient_call ----------------------------------------------------------

def test_resilient_success_first_try():
    calls = []
    out = resilient_call(lambda: calls.append(1) or "ok", sleep=lambda d: None)
    assert out == "ok"
    assert len(calls) == 1


def test_resilient_success_after_one_retry():
    box = {"n": 0}
    slept = []

    def fn():
        box["n"] += 1
        if box["n"] == 1:
            raise ValueError("transient")
        return "recovered"

    out = resilient_call(fn, retries=2, base_delay=0.5, sleep=slept.append)
    assert out == "recovered"
    assert box["n"] == 2
    assert slept == [0.5]                # backoff slept once before the retry


def test_resilient_exhausts_retries_and_raises():
    slept = []

    def fn():
        raise ValueError("always")

    with pytest.raises(ValueError):
        resilient_call(fn, retries=2, base_delay=1.0, max_delay=2.0, sleep=slept.append)
    # 2 retries -> 2 sleeps (1.0, then 2.0 clamped by max_delay)
    assert slept == [1.0, 2.0]


def test_resilient_fast_fails_when_breaker_open():
    box, now = _clock()
    cb = CircuitBreaker(fail_threshold=1, reset_timeout=30, now=now)
    cb.record_failure()                 # open
    with pytest.raises(CircuitOpenError):
        resilient_call(lambda: "never", breaker=cb, sleep=lambda d: None)


def test_resilient_records_success_on_breaker():
    box, now = _clock()
    cb = CircuitBreaker(fail_threshold=2, reset_timeout=30, now=now)
    cb.record_failure()
    assert cb.failures == 1
    resilient_call(lambda: "ok", breaker=cb, sleep=lambda d: None)
    assert cb.failures == 0             # success reset it


def test_resilient_stops_retrying_when_failure_trips_breaker():
    box, now = _clock()
    cb = CircuitBreaker(fail_threshold=1, reset_timeout=30, now=now)
    slept = []

    def fn():
        raise ValueError("boom")

    with pytest.raises(ValueError):
        resilient_call(fn, breaker=cb, retries=5, sleep=slept.append)
    # First failure trips the breaker open -> no retry sleeps at all.
    assert slept == []
    assert cb.status == OPEN


def test_resilient_only_catches_named_exceptions():
    with pytest.raises(KeyError):
        resilient_call(lambda: (_ for _ in ()).throw(KeyError("x")),
                       retries=3, exceptions=(ValueError,), sleep=lambda d: None)


# --- safe_read ---------------------------------------------------------------

def test_safe_read_returns_value_on_success():
    assert safe_read(lambda: "live", "stale", sleep=lambda d: None) == "live"


def test_safe_read_returns_fallback_value_on_failure():
    def fn():
        raise RuntimeError("down")

    assert safe_read(fn, "stale", retries=0, sleep=lambda d: None) == "stale"


def test_safe_read_returns_fallback_callable_on_failure():
    def fn():
        raise RuntimeError("down")

    assert safe_read(fn, lambda: "computed-stale", retries=0, sleep=lambda d: None) == "computed-stale"


def test_safe_read_invokes_on_error():
    seen = []

    def fn():
        raise RuntimeError("down")

    safe_read(fn, "stale", retries=0, on_error=seen.append, sleep=lambda d: None)
    assert len(seen) == 1
    assert isinstance(seen[0], RuntimeError)


def test_safe_read_fast_fail_when_open_uses_fallback():
    box, now = _clock()
    cb = CircuitBreaker(fail_threshold=1, reset_timeout=30, now=now)
    cb.record_failure()                 # open
    seen = []
    out = safe_read(lambda: "live", "stale", breaker=cb, on_error=seen.append, sleep=lambda d: None)
    assert out == "stale"
    assert isinstance(seen[0], CircuitOpenError)
