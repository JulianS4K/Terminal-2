"""Shared rate-limiter backend selection (production-readiness P1 #5).

The in-process `_IPRateLimiter` (a per-process sliding-window deque, defined in
server.py) is single-instance only: at >1 dyno the limit is per-instance and
therefore bypassable. This module adds a **Redis** fixed-window backend and a
selector that picks it when `REDIS_URL` is set (falling back to the in-process
limiter when Redis is absent, unreachable, or the dep isn't installed).

Both backends expose the same `check(key, max_per_window, window_sec) -> bool`
interface the middleware calls, so the swap is transparent.

The Redis client factory + wall clock are injectable so the selector + backend
are fully testable without a live Redis (the `redis` dep isn't installed in CI).
"""
from __future__ import annotations

import time
from typing import Any, Callable


class RedisRateLimiter:
    """Fixed-window counter in Redis: INCR a per-(key, window-bucket) counter and
    EXPIRE it. Atomic per call (INCR), shared across instances, and good enough
    for abuse protection. Boundary bursts (the known fixed-window tradeoff) are
    acceptable here — this guards against floods, not for billing accuracy.
    """

    def __init__(self, client, *, now: Callable[[], float] = time.time):
        self._client = client
        self._now = now

    def check(self, key: str, max_per_window: int, window_sec: float) -> bool:
        window = max(1, int(window_sec))
        bucket = int(self._now() // window)
        k = f"rl:{key}:{bucket}"
        count = self._client.incr(k)
        if count == 1:
            # First hit in this window — set the TTL (+1s slack) so the key
            # self-evicts. Only on the first INCR to avoid resetting the TTL.
            self._client.expire(k, window + 1)
        return count <= max_per_window


def _redis_from_url(url: str):  # pragma: no cover - thin lazy-import shim over the optional redis dep (not installed in CI)
    import redis
    return redis.Redis.from_url(url, socket_connect_timeout=2, socket_timeout=2)


def make_rate_limiter(
    redis_url: str | None,
    *,
    in_process_factory: Callable,
    redis_from_url: Callable[[str], Any] = _redis_from_url,
    log: Callable[..., None] = lambda *a, **k: None,
):
    """Return a Redis-backed limiter when `redis_url` is set and reachable,
    else the in-process limiter from `in_process_factory()`.

    Any failure constructing/pinging Redis logs and falls back — a missing or
    flaky Redis must never take down rate limiting (let alone the app).
    """
    if redis_url:
        try:
            client = redis_from_url(redis_url)
            client.ping()
            log("rate limiter: using Redis backend (multi-instance safe)")
            return RedisRateLimiter(client)
        except Exception as e:  # noqa: BLE001 - any Redis failure -> graceful in-process fallback
            log(f"rate limiter: Redis unavailable ({e!r}); falling back to in-process")
    return in_process_factory()
