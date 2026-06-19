"""Tests for the simple read-only GET routes in app.py.

Fourth increment of the broker/admin coverage push (BR-CODE-3, bottleneck
research 2026-06-19). Covers the low-complexity, read-only list endpoints:

  - /api/watchlist            (list)
  - /api/runs                 (list, limit passthrough)
  - /api/snapshots/latest     (latest_snapshots joined to events enrichment)
  - /api/snapshots/velocity   (event_velocity list)

Self-contained fake supporting the .select/.order/.limit/.in_/.execute
chain. No real HTTP / DB.
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


class _Q:
    def __init__(self, data):
        self._data = data

    def select(self, *_a, **_k):
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def in_(self, *_a, **_k):
        return self

    def eq(self, *_a, **_k):
        return self

    def execute(self):
        return type("_R", (), {"data": self._data})()


class _Sb:
    def __init__(self, table=None):
        self._table = table or {}

    def table(self, name):
        return _Q(self._table.get(name, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _db(monkeypatch, **table):
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb(table=table))


# ---------- /api/watchlist ----------

def test_watchlist_empty(client, monkeypatch):
    _db(monkeypatch, watchlist=[])
    assert client.get("/api/watchlist").json() == {"items": []}


def test_watchlist_returns_items(client, monkeypatch):
    rows = [{"id": 1, "kind": "performer", "ext_id": 16303, "label": "Knicks"}]
    _db(monkeypatch, watchlist=rows)
    assert client.get("/api/watchlist").json() == {"items": rows}


# ---------- /api/runs ----------

def test_runs_list(client, monkeypatch):
    rows = [{"id": 9, "status": "ok"}, {"id": 8, "status": "ok"}]
    _db(monkeypatch, runs=rows)
    body = client.get("/api/runs?limit=5").json()
    assert body == {"items": rows}


# ---------- /api/snapshots/latest ----------

def test_snapshots_latest_empty(client, monkeypatch):
    _db(monkeypatch, latest_snapshots=[])
    assert client.get("/api/snapshots/latest").json() == {"items": []}


def test_snapshots_latest_enriches_with_event(client, monkeypatch):
    snaps = [{"event_id": 100, "getin": 50}, {"event_id": 200, "getin": 75}]
    events = [
        {"id": 100, "name": "Event A", "occurs_at_local": "2026-06-02T19:00:00-04:00",
         "venue_name": "MSG", "venue_location": "New York, NY",
         "primary_performer_name": "Knicks"},
        {"id": 200, "name": "Event B", "occurs_at_local": "2026-06-01T19:00:00-04:00",
         "venue_name": "Barclays", "venue_location": "Brooklyn, NY",
         "primary_performer_name": "Nets"},
    ]
    _db(monkeypatch, latest_snapshots=snaps, events=events)
    items = client.get("/api/snapshots/latest").json()["items"]
    assert len(items) == 2
    # Sorted by occurs_at_local ascending => Event B (06-01) precedes A (06-02).
    assert [i["event_name"] for i in items] == ["Event B", "Event A"]
    # Each snapshot carries its enrichment fields joined from events.
    assert items[0]["venue_name"] == "Barclays"
    assert items[1]["getin"] == 50


# ---------- /api/snapshots/velocity ----------

def test_snapshots_velocity_list(client, monkeypatch):
    rows = [{"event_id": 1, "velocity": 3.2}]
    _db(monkeypatch, event_velocity=rows)
    assert client.get("/api/snapshots/velocity").json() == {"items": rows}
