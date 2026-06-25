"""Shared pytest fixtures for the Terminal-2 suite.

The FastAPI app keeps a few process-global, in-memory singletons — the per-IP
sliding-window rate limiter (`app._ip_limiter`) and the storefront movers cache
(`app._movers_cache` / `app._MOVERS_CACHE_REFRESHING`). Under the full suite,
many test modules drive the same TestClient IP, so without a reset the limiter's
hit-counts accumulate across modules and trip 429s in later tests, and the
movers cache can serve a value primed by an earlier test. This autouse fixture
clears that state around every test so the suite is order-independent.

It is a no-op for tests that never import `app` (e.g. pure client-unit tests):
it only touches state if `app` is already in sys.modules, so it never forces the
app bootstrap on tests that don't need it.
"""
from __future__ import annotations

import sys

import pytest


def _clear_app_global_state() -> None:
    app = sys.modules.get("app")
    if app is None:
        return
    limiter = getattr(app, "_ip_limiter", None)
    hits = getattr(limiter, "_hits", None)
    if hits is not None:
        hits.clear()
    # Every process-global mutable cache/debounce singleton in app.py. Without a
    # reset, a value primed by one test module leaks into later modules:
    #   _search_cache / _movers_cache       — serve a stale primed result
    #   _collect_run_last_call              — a leaked timestamp throttles a later
    #                                          /api/collect/run call (debounce)
    #   _STOREFRONT_HTML_CACHE              — serve HTML primed under a different flag
    # Anything with a .clear() (dict/set) is reset; missing names are skipped so
    # this stays a no-op when app isn't imported.
    for name in (
        "_movers_cache",
        "_MOVERS_CACHE_REFRESHING",
        "_search_cache",
        "_collect_run_last_call",
        "_STOREFRONT_HTML_CACHE",
    ):
        obj = getattr(app, name, None)
        if obj is not None and hasattr(obj, "clear"):
            obj.clear()


@pytest.fixture(autouse=True)
def _reset_app_global_state():
    _clear_app_global_state()
    yield
    _clear_app_global_state()
