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
    for name in ("_movers_cache", "_MOVERS_CACHE_REFRESHING"):
        obj = getattr(app, name, None)
        if obj is not None and hasattr(obj, "clear"):
            obj.clear()


@pytest.fixture(autouse=True)
def _reset_app_global_state():
    _clear_app_global_state()
    yield
    _clear_app_global_state()
