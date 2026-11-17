"""The sub finder API on its own: a second, API-only web service.

Operator 2026-11-16: the CRM asked for a base URL that is not the `-test` storefront
service, there is no domain of ours to point at it yet, and "just use a temp render for now".
So the same `/api/v1/subs` router (routers/subs_api.py) is also served by a small service of
its own, under its own Render hostname:

    uvicorn core.subs_only:app

It is the router and nothing else: no storefront, no terminal, no background worker. In
particular the buy and offer workers do NOT run here. A buy or an offer asked through this
host is filed in the same tables, and the main service's workers carry it out, exactly as
for a call made to the main host. Both hosts read and write the same database, so the keys,
the address lock, the limits and the audit log are the same on either.

What it needs: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY. With either missing every keyed
call answers 401 (a key that cannot be verified is refused) and /healthz says so.

Limits: the per-key rate and quota apply as on the main host, and callers are also held to
PER_IP_CALLS a minute each by address. The window counters live in this process, so they
are separate from the main service's.

RULE 2: like the router, this module makes no upstream call.
"""
from __future__ import annotations

import os
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from core.db import make_supabase_client
from core.helpers import client_ip_from_xff
from routers.subs_api import make_router

PER_IP_CALLS = 600        # calls a minute from one address, the ceiling the main service uses on this path
PER_IP_WINDOW_S = 60.0


class WindowLimiter:
    """`check(key, n, window_s)`: may `key` make another call, at most `n` in any `window_s`
    seconds? Kept in this process; the same contract as the main service's limiter."""

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._hits: dict[str, list[float]] = {}
        self._lock = threading.Lock()
        self._clock = clock

    def check(self, key: str, n: int, window_s: float) -> bool:
        now = self._clock()
        with self._lock:
            hits = [t for t in self._hits.get(key, ()) if now - t < window_s]
            allowed = len(hits) < n
            if allowed:
                hits.append(now)
            self._hits[key] = hits
            return allowed


def build_app(env: Mapping[str, str] | None = None,
              client_factory: Callable[[str, str], Any] = make_supabase_client) -> FastAPI:
    env = os.environ if env is None else env
    url, key = env.get("SUPABASE_URL"), env.get("SUPABASE_SERVICE_ROLE_KEY")
    state: dict[str, Any] = {"db": None}

    def get_db() -> Any:
        if state["db"] is None:
            if not (url and key):
                raise RuntimeError("Supabase is not configured for this service")
            state["db"] = client_factory(url, key)
        return state["db"]

    limiter = WindowLimiter()
    # no interactive docs or schema: the guide is served by the API itself, to a key
    app = FastAPI(title="S4K Sub Finder API", docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware("http")
    async def per_ip(request: Request, call_next):
        if request.url.path != "/healthz":      # the host's own health poll comes from one address
            ip = client_ip_from_xff(request.headers.get("x-forwarded-for"),
                                    request.client.host if request.client else "unknown",
                                    request.headers.get("cf-connecting-ip")) or "unknown"
            if not limiter.check(f"ip:{ip}", PER_IP_CALLS, PER_IP_WINDOW_S):
                return JSONResponse({"error": "rate_limited", "retry_after_seconds": int(PER_IP_WINDOW_S)},
                                    status_code=429, headers={"Retry-After": str(int(PER_IP_WINDOW_S))})
        return await call_next(request)

    @app.get("/healthz")
    def healthz():
        return {"ok": True, "service": "subs-api", "configured": bool(url and key)}

    app.include_router(make_router(get_db, limiter=limiter))
    return app


app = build_app()
