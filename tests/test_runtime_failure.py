"""Runtime-failure matrix for every external dependency.

Testing-recommendation #3: the Redis limiter bug existed precisely because the
fallback was tested at *construction* and never *mid-flight*. The fix is a
three-column matrix per external dependency:

    1. works              — the dependency is healthy
    2. down at startup    — absent/unreachable when we first reach for it
    3. dies during a req  — healthy at boot, then raises on the hot path  <-- the gap

The third column is where the only red production finding lived, so every
dependency gets an explicit test for it here.

Dependencies covered:
    * Redis      (core.ratelimit)   — limiter backend
    * Supabase   (core.resilience)  — the resilient_call / safe_read read path
    * TEvo       (core.search)      — live search with SQL fallback
"""
from __future__ import annotations

from core.ratelimit import RedisRateLimiter, make_rate_limiter
from core.resilience import CircuitBreaker, CircuitOpenError, resilient_call, safe_read
from core.search import search_live


# ============================================================================
# Fakes
# ============================================================================

class _Redis:
    """INCR/EXPIRE/PING fake. `die_after` flips it to raising on the Nth incr so
    we can simulate Redis dropping mid-request (not just at boot)."""

    def __init__(self, *, ping_ok=True, die_after=None):
        self.store: dict = {}
        self._ping_ok = ping_ok
        self._die_after = die_after
        self._incrs = 0

    def ping(self):
        if not self._ping_ok:
            raise ConnectionError("redis down at boot")
        return True

    def incr(self, k):
        self._incrs += 1
        if self._die_after is not None and self._incrs > self._die_after:
            raise ConnectionError("redis died mid-request")
        self.store[k] = self.store.get(k, 0) + 1
        return self.store[k]

    def expire(self, k, ttl):
        pass


class _InProcess:
    """Stand-in for server.py's per-process limiter: allows `cap` per key."""

    def __init__(self):
        self.hits: dict = {}

    def check(self, key, max_per_window, window_sec):
        self.hits[key] = self.hits.get(key, 0) + 1
        return self.hits[key] <= max_per_window


# ============================================================================
# Redis  (core.ratelimit)
# ============================================================================

def test_redis_works():
    """Column 1: healthy Redis limits normally."""
    lim = make_rate_limiter(
        "redis://x", in_process_factory=_InProcess,
        redis_from_url=lambda url: _Redis(),
    )
    assert isinstance(lim, RedisRateLimiter)
    assert lim.check("ip|/a", 1, 60.0) is True
    assert lim.check("ip|/a", 1, 60.0) is False


def test_redis_down_at_startup_falls_back_to_in_process():
    """Column 2: ping fails at boot -> selector returns the in-process limiter,
    app still rate-limits (per-instance) instead of crashing."""
    logs = []
    lim = make_rate_limiter(
        "redis://x", in_process_factory=_InProcess,
        redis_from_url=lambda url: _Redis(ping_ok=False),
        log=logs.append,
    )
    assert isinstance(lim, _InProcess)
    assert any("falling back to in-process" in m for m in logs)


def test_redis_dies_mid_request_degrades_to_fallback_never_raises():
    """Column 3 (the gap): Redis pings OK at boot, then drops on a later call.
    check() must degrade to the in-process fallback and NEVER raise — a limiter
    outage must not 500 the request path."""
    redis = _Redis(die_after=1)          # first incr ok, second raises
    fallback = _InProcess()
    logs = []
    lim = RedisRateLimiter(redis, fallback=fallback, log=logs.append)

    assert lim.check("ip|/a", 5, 60.0) is True     # served by Redis
    # Redis now dead — must not raise, must consult the fallback.
    assert lim.check("ip|/a", 5, 60.0) is True     # served by fallback, no raise
    assert fallback.hits.get("ip|/a") == 1
    assert any("degrading to in-process fallback" in m for m in logs)


def test_redis_dies_mid_request_fails_open_with_no_fallback():
    """Column 3, no fallback wired: degrade to fail-OPEN (True), still no raise."""
    lim = RedisRateLimiter(_Redis(die_after=0), fallback=None)
    assert lim.check("k", 1, 60.0) is True   # fail open, never raises


# ============================================================================
# Supabase  (core.resilience) — resilient_call / safe_read / breaker
# ============================================================================

def test_supabase_works():
    """Column 1: a healthy read returns its value and closes the breaker."""
    b = CircuitBreaker(fail_threshold=3)
    assert resilient_call(lambda: "rows", breaker=b, sleep=lambda _: None) == "rows"
    assert b.status == "closed"


def test_supabase_down_at_startup_safe_read_returns_stale_fallback():
    """Column 2: Supabase unreachable from the first call -> safe_read swallows
    and serves the stale-snapshot fallback instead of 500-ing the storefront."""
    seen = []

    def dead():
        raise ConnectionError("supabase unreachable")

    out = safe_read(dead, {"stale": True}, retries=1, sleep=lambda _: None,
                    on_error=seen.append)
    assert out == {"stale": True}
    assert seen and isinstance(seen[0], ConnectionError)


def test_supabase_dies_mid_request_trips_breaker_then_fast_fails():
    """Column 3: healthy for a while, then Supabase starts failing on the hot
    path. Consecutive failures OPEN the breaker, which then fast-fails
    (CircuitOpenError) to shed load rather than pile up doomed retries."""
    state = {"healthy": True}

    def flaky():
        if state["healthy"]:
            return "ok"
        raise TimeoutError("supabase slow")

    b = CircuitBreaker(fail_threshold=2, reset_timeout=30.0, now=lambda: 0.0)
    assert resilient_call(flaky, breaker=b, sleep=lambda _: None) == "ok"

    state["healthy"] = False  # dependency dies mid-flight
    # retries=2 -> 2 failures in one call trips the 2-fail threshold OPEN.
    try:
        resilient_call(flaky, breaker=b, retries=2, sleep=lambda _: None)
    except TimeoutError:
        pass
    assert b.status == "open"

    # Breaker OPEN -> next call fast-fails without even invoking the thunk.
    calls = {"n": 0}

    def counted():
        calls["n"] += 1
        raise TimeoutError("still down")

    try:
        resilient_call(counted, breaker=b, sleep=lambda _: None)
        raise AssertionError("expected fast-fail")
    except CircuitOpenError:
        pass
    assert calls["n"] == 0  # never called — load shed


# ============================================================================
# TEvo  (core.search.search_live) — live search with SQL fallback
# ============================================================================

def _sql_fallback(db, q, limit):
    return {"events": [], "performers": [], "venues": [], "source": "sql"}


class _TevoOK:
    def search_suggestions(self, *a, **k):
        return {"suggestions": {"events": [], "performers": [], "venues": []}}


class _TevoDies:
    def search_suggestions(self, *a, **k):
        raise RuntimeError("TEvo 503 Service Unavailable")


def test_tevo_works_returns_live_source():
    """Column 1: TEvo healthy -> live path, source=live."""
    out = search_live(db=None, q_norm="lakers", limit=5,
                      ensure_client=lambda: _TevoOK(),
                      search_sql_only=_sql_fallback)
    assert out["source"] == "live"


def test_tevo_unconfigured_at_startup_falls_back_to_sql():
    """Column 2: creds missing at boot -> ensure_client None -> SQL fallback with
    an explicit reason so the client can flag 'live search degraded'."""
    out = search_live(db=None, q_norm="lakers", limit=5,
                      ensure_client=lambda: None,
                      search_sql_only=_sql_fallback)
    assert out["source"] == "sql"
    assert out["fallback"] is True
    assert out["fallback_reason"] == "tevo_unconfigured"


def test_tevo_dies_mid_request_falls_back_to_sql_with_status():
    """Column 3: TEvo raises during the request -> SQL fallback, never 500s, and
    the parsed upstream status is surfaced for the degraded-search hint."""
    out = search_live(db=None, q_norm="lakers", limit=5,
                      ensure_client=lambda: _TevoDies(),
                      search_sql_only=_sql_fallback)
    assert out["source"] == "sql"
    assert out["fallback"] is True
    assert out["fallback_reason"] == "tevo_unavailable"
    assert out["fallback_detail"] == {"tevo_status": 503}
