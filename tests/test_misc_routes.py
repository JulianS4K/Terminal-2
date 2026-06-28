"""Tests for the misc singleton routes (routers/misc.py) — BR-CODE-1 slice 10."""
from __future__ import annotations
import os, sys
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
pytest.importorskip("fastapi")
tc = pytest.importorskip("fastapi.testclient")
import server as app_module  # noqa: E402
TestClient = tc.TestClient


class _Q:
    def __init__(s, d): s._d = d
    def select(s, *a, **k): return s
    def eq(s, *a, **k): return s
    def limit(s, *a, **k): return s
    def execute(s): return type("R", (), {"data": s._d})()


class _Sb:
    def __init__(s, t=None): s._t = t or {}
    def table(s, n): return _Q(s._t.get(n, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def test_config_shape(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", object())
    body = client.get("/api/config").json()
    assert body["supabase_configured"] is True
    assert body["env"] in ("sandbox", "prod")


def test_cross_source_404_when_event_missing(client, monkeypatch):
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb({"events": []}))
    assert client.get("/api/cross-source/event/999").status_code == 404


def test_cross_source_aggregates_xrefs(client, monkeypatch):
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb({
        "events": [{"id": 55, "name": "E"}],
        "event_xref": [{"espn_event_id": "e1", "espn_league": "NBA"}],
        "seatgeek_event_xref": [{"sg_event_id": 17}],
        "seatdata_event_xref": [],
    }))
    body = client.get("/api/cross-source/event/55").json()
    assert body["tevo_event"]["id"] == 55
    assert body["espn"]["espn_league"] == "NBA"
    assert body["seatgeek"]["sg_event_id"] == 17
    assert body["seatdata"] is None
    assert body["matched_count"] == 2
