"""Tests for /api/broker/event/{id}/espn — the server-side ESPN edge-fn proxy.

P2 test work (BR-CODE-3). The route calls the espn edge function server-side
(keeping the user JWT off the wire) and DEGRADES GRACEFULLY: a non-ok response
or any exception returns an {"applicable": False, "error": ...} dict rather
than 500ing the event page. These tests pin that contract — a silent-failure
guard so a future refactor can't turn a degraded ESPN fn into a hard error.

No real network: the requests.get to the edge fn is monkeypatched.
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

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


class _FakeResp:
    def __init__(self, payload, ok=True, status_code=200):
        self._payload = payload
        self.ok = ok
        self.status_code = status_code

    def json(self):
        return self._payload


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _stub_get(monkeypatch, resp=None, raises=None):
    def fake_get(*a, **kw):
        if raises is not None:
            raise raises
        return resp
    # app.py's broker_event_espn calls requests.get (shared module).
    monkeypatch.setattr(app_module.requests, "get", fake_get)


def test_espn_passthrough_on_ok(client, monkeypatch):
    _stub_get(monkeypatch, _FakeResp({"home": {"team": "Knicks"}, "applicable": True}))
    body = client.get("/api/broker/event/3091423/espn").json()
    assert body["applicable"] is True
    assert body["home"]["team"] == "Knicks"


def test_espn_degrades_on_non_ok(client, monkeypatch):
    # A 404 from the edge fn must NOT 500 the route — graceful fallback dict.
    _stub_get(monkeypatch, _FakeResp({"err": "x"}, ok=False, status_code=404))
    r = client.get("/api/broker/event/1/espn")
    assert r.status_code == 200
    body = r.json()
    assert body["applicable"] is False
    assert "espn fn 404" in body["error"]


def test_espn_degrades_on_exception(client, monkeypatch):
    # A network exception is swallowed into the fallback dict, not surfaced.
    _stub_get(monkeypatch, raises=RuntimeError("connection refused"))
    body = client.get("/api/broker/event/1/espn").json()
    assert body["applicable"] is False
    assert "connection refused" in body["error"]


def test_espn_500_when_supabase_unconfigured(client, monkeypatch):
    # Missing Supabase config is a server misconfig → explicit 500 (distinct
    # from the graceful degrade above).
    monkeypatch.setattr(app_module, "SUPABASE_URL", None)
    r = client.get("/api/broker/event/1/espn")
    assert r.status_code == 500
