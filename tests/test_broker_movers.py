"""Tests for the /api/broker movers surfaces in app.py.

Third increment of the broker/admin coverage push (BR-CODE-3, bottleneck
research 2026-06-19). Targets the deterministic, read-only movers paths:

  - /api/broker/movers?window_days=N  -> v2 index path (_broker_movers_v2):
        groups get_event_movers_v2 rows by category, passes summary through.
  - /api/broker/watchlist-movers       -> empty-watchlist short-circuit.

Kept self-contained (own minimal fake) to match the repo's standalone
test-file convention. No real HTTP / DB.
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


class _Q:
    def __init__(self, data):
        self._data = data

    def select(self, *_a, **_k):
        return self

    def eq(self, *_a, **_k):
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def execute(self):
        return type("_R", (), {"data": self._data})()


class _Sb:
    def __init__(self, rpc=None, table=None):
        self._rpc = rpc or {}
        self._table = table or {}

    def rpc(self, name, params=None):
        return _Q(self._rpc.get(name, []))

    def table(self, name):
        return _Q(self._table.get(name, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


# ---------- /api/broker/movers (v2 index path) ----------

def test_movers_v2_groups_rows_by_category(client, monkeypatch):
    rows = [
        {"category": "nba", "tevo_event_id": 1, "signal": 9.0},
        {"category": "nba", "tevo_event_id": 2, "signal": 8.0},
        {"category": "mlb", "tevo_event_id": 3, "signal": 7.0},
    ]
    summary = [{"category": "nba", "n": 2}]
    monkeypatch.setattr(
        app_module, "require_sb",
        lambda: _Sb(rpc={"get_event_movers_v2": rows,
                         "get_event_movers_index_summary": summary}),
    )
    body = client.get("/api/broker/movers?window_days=7&source=merged").json()
    assert body["v"] == 2
    assert body["source"] == "merged"
    assert body["window_days"] == 7
    assert body["event_count"] == 3
    assert set(body["events_by_category"]) == {"nba", "mlb"}
    assert len(body["events_by_category"]["nba"]) == 2
    assert body["summary"] == summary


def test_movers_v2_empty_is_clean(client, monkeypatch):
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb())
    body = client.get("/api/broker/movers?window_days=30").json()
    assert body["v"] == 2
    assert body["event_count"] == 0
    assert body["events_by_category"] == {}
    assert body["summary"] == []


# ---------- /api/broker/watchlist-movers (empty short-circuit) ----------

def test_watchlist_movers_empty_short_circuits(client, monkeypatch):
    # No watchlisted events => count 0, no movers RPC needed.
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb(table={"watch_sources": []}))
    body = client.get("/api/broker/watchlist-movers?window_hours=24").json()
    assert body["count"] == 0
    assert body["events"] == []
    assert body["window_hours"] == 24


def test_watchlist_movers_clamps_window_hours(client, monkeypatch):
    # window_hours is clamped to <=168 even on the empty path.
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb(table={"watch_sources": []}))
    body = client.get("/api/broker/watchlist-movers?window_hours=99999").json()
    assert body["window_hours"] == 168
