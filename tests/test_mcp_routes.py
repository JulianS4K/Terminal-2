"""Tests for the read-only /api/mcp/* routes (routers/mcp.py).

Covers the shared-secret guard (503 when the secret is unprovisioned, 401 for a
missing/wrong header, pass-through when it matches), the D0 leagues join
(summary ⋈ weighted-median + revenue sort + weighted-missing→None), and the D4
events fold (min tier price from exos_public_tiers, empty-events + no-tier +
None-price branches). No real DB — require_sb is monkeypatched to a chainable
PostgREST stub, mirroring tests/test_d0_sales_routes.py.
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

SECRET = "dev-secret"
HDR = {"X-MCP-Read-Secret": SECRET}


class _Res:
    def __init__(self, data):
        self.data = data


class _Q:
    """Chainable PostgREST stub (select/eq/in_/order/limit → execute)."""

    def __init__(self, data):
        self._data = data

    def select(self, *a, **k):
        return self

    def eq(self, *a, **k):
        return self

    def in_(self, *a, **k):
        return self

    def order(self, *a, **k):
        return self

    def limit(self, *a, **k):
        return self

    def execute(self):
        return _Res(self._data)


class _Sb:
    def __init__(self, tables=None):
        self._tables = tables or {}

    def table(self, name):
        return _Q(self._tables.get(name, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _db(monkeypatch, **tables):
    sb = _Sb(tables=tables)
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    return sb


# ---------- shared-secret guard ----------

def test_guard_503_when_secret_unset(client, monkeypatch):
    monkeypatch.delenv("MCP_READ_SECRET", raising=False)
    r = client.get("/api/mcp/d0/leagues", headers=HDR)
    assert r.status_code == 503


def test_guard_401_missing_header(client, monkeypatch):
    monkeypatch.setenv("MCP_READ_SECRET", SECRET)
    r = client.get("/api/mcp/d0/leagues")
    assert r.status_code == 401


def test_guard_401_wrong_header(client, monkeypatch):
    monkeypatch.setenv("MCP_READ_SECRET", SECRET)
    r = client.get("/api/mcp/d0/leagues", headers={"X-MCP-Read-Secret": "nope"})
    assert r.status_code == 401


# ---------- D0 leagues ----------

def test_d0_leagues_joins_weighted_and_sorts_by_revenue(client, monkeypatch):
    monkeypatch.setenv("MCP_READ_SECRET", SECRET)
    _db(monkeypatch,
        d0_league_summary=[
            {"league": "MLS", "total_revenue": 1_370_618.76},
            {"league": "MLB", "total_revenue": 96_902_138.24},
            {"league": "NHL", "total_revenue": None},
        ],
        d0_league_price_weighted=[
            {"league": "MLB", "weighted_median_price": 61.5},
            {"league": "MLS", "weighted_median_price": 50.0},
        ])
    body = client.get("/api/mcp/d0/leagues", headers=HDR).json()
    assert body["count"] == 3
    # revenue desc; None revenue sinks to the bottom
    assert [r["league"] for r in body["leagues"]] == ["MLB", "MLS", "NHL"]
    assert body["leagues"][0]["weighted_median_price"] == 61.5
    # league absent from the weighted table → grafted None
    assert body["leagues"][2]["weighted_median_price"] is None


# ---------- D4 events ----------

def test_d4_events_folds_min_tier_price(client, monkeypatch):
    monkeypatch.setenv("MCP_READ_SECRET", SECRET)
    _db(monkeypatch,
        exos_public_events=[
            {"id": "e1", "name": "Show One", "starts_at": "2026-08-01T00:00:00Z"},
            {"id": "e2", "name": "Show Two", "starts_at": "2026-08-02T00:00:00Z"},
        ],
        exos_public_tiers=[
            {"event_id": "e1", "price": 80},
            {"event_id": "e1", "price": 45},      # min branch → 45
            {"event_id": "e1", "price": None},     # None price → continue
            {"event_id": None, "price": 10},       # None event_id → continue
            # e2 has no tiers → from_price stays None
        ])
    body = client.get("/api/mcp/d4/events", headers=HDR).json()
    assert body["count"] == 2
    by_id = {e["id"]: e for e in body["events"]}
    assert by_id["e1"]["from_price"] == 45
    assert by_id["e2"]["from_price"] is None


def test_d4_events_empty(client, monkeypatch):
    monkeypatch.setenv("MCP_READ_SECRET", SECRET)
    _db(monkeypatch, exos_public_events=[])
    body = client.get("/api/mcp/d4/events?limit=5", headers=HDR).json()
    assert body == {"count": 0, "events": []}
