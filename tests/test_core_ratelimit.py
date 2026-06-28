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
