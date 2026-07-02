"""Tests for core/ratelimit.py — Redis backend + backend selector.

The redis dep isn't installed in CI, so the Redis client factory + clock are
injected. Production-readiness P1 #5: a shared (Redis) limiter is multi-instance
safe; a missing/flaky Redis must fall back to in-process, never take down the app.
"""
from __future__ import annotations

from core.ratelimit import RedisRateLimiter, make_rate_limiter


class _FakeRedis:
    """Minimal INCR/EXPIRE/PING fake backing a dict."""

    def __init__(self, *, ping_ok=True):
        self.store: dict = {}
        self.expires: dict = {}
        self._ping_ok = ping_ok

    def ping(self):
        if not self._ping_ok:
            raise ConnectionError("no redis")
        return True

    def incr(self, k):
        self.store[k] = self.store.get(k, 0) + 1
        return self.store[k]

    def expire(self, k, ttl):
        self.expires[k] = ttl


# --- RedisRateLimiter --------------------------------------------------------

def test_redis_limiter_allows_under_cap_then_blocks():
    r = _FakeRedis()
    lim = RedisRateLimiter(r, now=lambda: 1000.0)
    assert lim.check("ip|/x", 2, 60.0) is True
    assert lim.check("ip|/x", 2, 60.0) is True
    assert lim.check("ip|/x", 2, 60.0) is False   # 3rd in window -> blocked


def test_redis_limiter_sets_ttl_only_on_first_hit():
    r = _FakeRedis()
    lim = RedisRateLimiter(r, now=lambda: 1000.0)
    lim.check("k", 5, 30.0)
    lim.check("k", 5, 30.0)
    # Exactly one key, TTL set once (window + 1s slack).
    assert list(r.expires.values()) == [31]


def test_redis_limiter_new_window_resets_count():
    clock = {"t": 1000.0}
    r = _FakeRedis()
    lim = RedisRateLimiter(r, now=lambda: clock["t"])
    assert lim.check("k", 1, 10.0) is True
    assert lim.check("k", 1, 10.0) is False        # same window, over cap
    clock["t"] = 1010.0                            # next window bucket
    assert lim.check("k", 1, 10.0) is True


class _BrokenRedis(_FakeRedis):
    """Fake whose data ops raise — simulates Redis dying *after* boot ping."""

    def incr(self, k):
        raise ConnectionError("redis went away")


# --- RedisRateLimiter runtime resilience (Redis dies after startup) ----------

def test_redis_limiter_fails_open_on_runtime_error_without_fallback():
    lim = RedisRateLimiter(_BrokenRedis(), now=lambda: 1000.0)
    # incr raises -> must not propagate; fail open so the app stays up.
    assert lim.check("k", 1, 60.0) is True
    assert lim.check("k", 1, 60.0) is True


def test_redis_limiter_degrades_to_fallback_on_runtime_error():
    calls = []

    class _Fallback:
        def check(self, key, n, w):
            calls.append((key, n, w))
            return False  # fallback enforces the cap

    logs = []
    lim = RedisRateLimiter(
        _BrokenRedis(), now=lambda: 1000.0, fallback=_Fallback(), log=logs.append,
    )
    assert lim.check("ip|/x", 5, 60.0) is False       # delegated to fallback
    assert calls == [("ip|/x", 5, 60.0)]
    # Degrade logged exactly once (throttled), even across repeated failures.
    assert lim.check("ip|/x", 5, 60.0) is False
    assert sum("degrading" in m for m in logs) == 1


def test_redis_limiter_logs_recovery_after_degrade():
    class _Flaky:
        """Raises on the first incr, then behaves."""
        def __init__(self):
            self.n = 0
            self.store = {}
        def incr(self, k):
            self.n += 1
            if self.n == 1:
                raise ConnectionError("blip")
            self.store[k] = self.store.get(k, 0) + 1
            return self.store[k]
        def expire(self, k, ttl):
            pass

    logs = []
    lim = RedisRateLimiter(
        _Flaky(), now=lambda: 1000.0, fallback=_InProc(), log=logs.append,
    )
    assert lim.check("k", 5, 60.0) is True            # degrade (fallback allows)
    assert lim.check("k", 5, 60.0) is True            # Redis back -> recover
    assert sum("degrading" in m for m in logs) == 1
    assert sum("recovered" in m for m in logs) == 1


# --- make_rate_limiter -------------------------------------------------------

class _InProc:
    """Stand-in for server's _IPRateLimiter."""
    def check(self, *a, **k):
        return True


def test_selector_uses_in_process_when_no_url():
    lim = make_rate_limiter(None, in_process_factory=_InProc)
    assert isinstance(lim, _InProc)


def test_selector_uses_in_process_when_empty_url():
    lim = make_rate_limiter("", in_process_factory=_InProc)
    assert isinstance(lim, _InProc)


def test_selector_uses_redis_when_url_and_reachable():
    fake = _FakeRedis(ping_ok=True)
    logs = []
    lim = make_rate_limiter(
        "redis://localhost:6379",
        in_process_factory=_InProc,
        redis_from_url=lambda url: fake,
        log=logs.append,
    )
    assert isinstance(lim, RedisRateLimiter)
    assert any("Redis backend" in m for m in logs)
    # Selector must wire an in-process fallback so a post-boot Redis outage
    # degrades instead of raising on the request path.
    assert isinstance(lim._fallback, _InProc)


def test_selector_falls_back_when_redis_unreachable():
    fake = _FakeRedis(ping_ok=False)
    logs = []
    lim = make_rate_limiter(
        "redis://localhost:6379",
        in_process_factory=_InProc,
        redis_from_url=lambda url: fake,
        log=logs.append,
    )
    assert isinstance(lim, _InProc)                # fell back
    assert any("falling back to in-process" in m for m in logs)


def test_selector_falls_back_when_factory_raises():
    def boom(url):
        raise RuntimeError("redis dep missing")

    lim = make_rate_limiter(
        "redis://x",
        in_process_factory=_InProc,
        redis_from_url=boom,
    )
    assert isinstance(lim, _InProc)
