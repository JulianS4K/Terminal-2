"""The store 'follow a tour' endpoint must never surface a raw 500.

/api/store/performers/{id}/tour-package is consumer-facing. If the planner throws
(transient DB blip, edge-case data, etc.) the route catches it, logs the traceback,
and returns a clean stops_available=0 + unavailable=True payload the FE renders as
"try again" — instead of a 500. Intentional HTTPExceptions still propagate.

Re-applied from PR #632 onto the post-v1.22 decomposition: the route now lives in
`routers/store.py` (mounted via `server.build_store_router`), and the planner symbol
the route resolves at request time is `server._tour_package_payload`.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

fastapi = pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


@pytest.fixture
def client():
    return TestClient(app_module.app)


def test_planner_exception_degrades_gracefully(client, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("planner exploded")
    monkeypatch.setattr(app_module, "_tour_package_payload", boom)
    r = client.get("/api/store/performers/72393/tour-package?qty=2&budget_usd=1500")
    assert r.status_code == 200          # never a raw 500
    body = r.json()
    assert body["unavailable"] is True
    assert body["stops_available"] == 0
    assert body["package"]["count"] == 0


def test_intentional_httpexception_still_propagates(client, monkeypatch):
    from fastapi import HTTPException

    def needs_db(*a, **k):
        raise HTTPException(status_code=503, detail="db offline")
    monkeypatch.setattr(app_module, "_tour_package_payload", needs_db)
    r = client.get("/api/store/performers/72393/tour-package")
    assert r.status_code == 503          # deliberate errors are not swallowed


def test_happy_path_payload_passes_through(client, monkeypatch):
    sentinel = {"mode": "team_away", "stops_available": 3,
                "package": {"count": 3, "fan_total_bundled": 420}, "all_stops": []}
    monkeypatch.setattr(app_module, "_tour_package_payload", lambda *a, **k: sentinel)
    r = client.get("/api/store/performers/72393/tour-package?qty=2&max_events=3")
    assert r.status_code == 200
    assert r.json() == sentinel
