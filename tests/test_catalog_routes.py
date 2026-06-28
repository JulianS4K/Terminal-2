"""Tests for the TEvo-catalog passthrough GET routes in app.py.

Fifth increment of the BR-CODE-3 route net (bottleneck research
2026-06-19). These routes are thin delegations to the TEvo `client`
(get_performer / get_venue / list_configurations / get_configuration),
so the contract under test is argument passthrough + response relay. We
stub app.client with a recorder (mirrors tests/test_store_events.py); no
real HTTP.
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

import server as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


class _RecorderClient:
    """Stand-in for app.client. Returns a programmable value per method and
    records the (args, kwargs) it was called with."""

    def __init__(self, returns):
        self.returns = returns
        self.calls: dict[str, tuple] = {}

    def get_performer(self, performer_id, include_opponents=True):
        self.calls["get_performer"] = ((performer_id,), {"include_opponents": include_opponents})
        return self.returns

    def get_venue(self, venue_id):
        self.calls["get_venue"] = ((venue_id,), {})
        return self.returns

    def list_configurations(self, venue_id=None, name=None):
        self.calls["list_configurations"] = ((), {"venue_id": venue_id, "name": name})
        return self.returns

    def get_configuration(self, config_id):
        self.calls["get_configuration"] = ((config_id,), {})
        return self.returns


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _stub(monkeypatch, returns):
    rec = _RecorderClient(returns)
    monkeypatch.setattr(app_module, "client", rec)
    return rec


# ---------- /api/performers/{id} ----------

def test_performer_detail_passthrough_default_opponents(client, monkeypatch):
    rec = _stub(monkeypatch, {"id": 16303, "name": "New York Knicks"})
    body = client.get("/api/performers/16303").json()
    assert body == {"id": 16303, "name": "New York Knicks"}
    # default include_opponents is True
    assert rec.calls["get_performer"] == ((16303,), {"include_opponents": True})


def test_performer_detail_opponents_false(client, monkeypatch):
    rec = _stub(monkeypatch, {"id": 1})
    client.get("/api/performers/1?include_opponents=false")
    assert rec.calls["get_performer"][1]["include_opponents"] is False


# ---------- /api/venues/{id} ----------

def test_venue_detail_passthrough(client, monkeypatch):
    rec = _stub(monkeypatch, {"id": 896, "name": "Madison Square Garden"})
    body = client.get("/api/venues/896").json()
    assert body["name"] == "Madison Square Garden"
    assert rec.calls["get_venue"] == ((896,), {})


# ---------- /api/configurations ----------

def test_configurations_list_passthrough_filters(client, monkeypatch):
    rec = _stub(monkeypatch, {"configurations": []})
    client.get("/api/configurations?venue_id=896&name=Basketball")
    assert rec.calls["list_configurations"][1] == {"venue_id": 896, "name": "Basketball"}


def test_configurations_list_blank_name_becomes_none(client, monkeypatch):
    rec = _stub(monkeypatch, {"configurations": []})
    client.get("/api/configurations?name=")
    # empty-string name is normalized to None before hitting the client
    assert rec.calls["list_configurations"][1]["name"] is None


# ---------- /api/configurations/{id} ----------

def test_configuration_detail_passthrough(client, monkeypatch):
    rec = _stub(monkeypatch, {"id": 42})
    body = client.get("/api/configurations/42").json()
    assert body == {"id": 42}
    assert rec.calls["get_configuration"] == ((42,), {})


# ---------- /api/events (search passthrough, moved BR-CODE-1 slice 6) ----------

def test_events_search_passthrough(client, monkeypatch):
    captured = {}

    class _Rec:
        def search_events_all(self, **kw):
            captured.update(kw)
            return [{"id": 1}, {"id": 2}]

    monkeypatch.setattr(app_module, "client", _Rec())
    body = client.get("/api/events?q=knicks&performer_id=16303").json()
    assert body == {"count": 2, "events": [{"id": 1}, {"id": 2}]}
    # query args + the fixed popularity order_by are passed through to the client.
    assert captured["q"] == "knicks"
    assert captured["performer_id"] == 16303
    assert captured["order_by"] == "events.popularity_score DESC"
