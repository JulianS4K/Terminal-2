"""Tests for the read-only /api/d0/sales/* routes (routers/d0_sales.py).

Covers the league index (summary ⋈ weighted-median join + revenue sort), the
visiting-teams leaderboard, the performer header (home_away + price_stats +
weighted, plus the 404 no-sales path), the owned-vs-market by-source split, the
sections view switch (top5 flag + role filter), and the refresh-health strip.
No real DB — require_sb is monkeypatched to a fake that records the chained
PostgREST builder calls, mirroring tests/test_seatdata_routes.py.
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


class _Res:
    def __init__(self, data):
        self.data = data


class _Q:
    """Chainable PostgREST stub. Records eq() filters so tests can assert the
    handler pushed the right predicates down to the view."""

    def __init__(self, data, calls):
        self._data = data
        self._calls = calls

    def select(self, *a, **k):
        return self

    def eq(self, col, val):
        self._calls.setdefault("eq", []).append((col, val))
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
        self.calls: dict = {}

    def table(self, name):
        self.calls.setdefault("tables", []).append(name)
        return _Q(self._tables.get(name, []), self.calls)


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _db(monkeypatch, **tables):
    sb = _Sb(tables=tables)
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    return sb


# ---------- leagues ----------

def test_leagues_joins_weighted_and_sorts_by_revenue(client, monkeypatch):
    _db(monkeypatch,
        d0_league_summary=[
            {"league": "MLS", "total_revenue": 1_370_618.76, "tickets_sold": 19027},
            {"league": "MLB", "total_revenue": 96_902_138.24, "tickets_sold": 1_122_825},
        ],
        d0_league_price_weighted=[
            {"league": "MLB", "weighted_median_price": 61.5},
            {"league": "MLS", "weighted_median_price": 50.0},
        ])
    body = client.get("/api/d0/sales/leagues").json()
    assert body["count"] == 2
    # sorted by revenue desc → MLB first
    assert [r["league"] for r in body["leagues"]] == ["MLB", "MLS"]
    # weighted median grafted on by league
    assert body["leagues"][0]["weighted_median_price"] == 61.5
    assert body["leagues"][1]["weighted_median_price"] == 50.0


def test_leagues_weighted_missing_is_none(client, monkeypatch):
    _db(monkeypatch,
        d0_league_summary=[{"league": "NFL", "total_revenue": 906_876.89}],
        d0_league_price_weighted=[])
    body = client.get("/api/d0/sales/leagues").json()
    assert body["leagues"][0]["weighted_median_price"] is None


# ---------- visiting teams ----------

def test_visiting_teams_filters_by_upper_league(client, monkeypatch):
    sb = _db(monkeypatch,
             d0_league_visiting_teams=[{"visiting_team": "NY Yankees", "away_revenue": 123.0}])
    body = client.get("/api/d0/sales/leagues/mlb/visiting-teams?limit=5").json()
    assert body["league"] == "MLB" and body["count"] == 1
    # league pushed down uppercased
    assert ("league", "MLB") in sb.calls["eq"]


# ---------- performer header ----------

def test_performer_404_when_no_sales(client, monkeypatch):
    _db(monkeypatch, d0_perf_home_away=[])
    assert client.get("/api/d0/sales/performers/72393").status_code == 404


def test_performer_header_shapes_roles(client, monkeypatch):
    _db(monkeypatch,
        d0_perf_home_away=[{"performer_name": "Inter Miami CF", "performer_league": "MLS",
                            "home_revenue": 395213.43, "away_revenue": 134474.02}],
        d0_perf_price_stats=[{"role": "home", "median": 89.33}, {"role": "away", "median": 173.0}],
        d0_perf_price_weighted=[{"role": "home", "weighted_median_price": 87.87},
                                {"role": "away", "weighted_median_price": 172.0}])
    body = client.get("/api/d0/sales/performers/72393").json()
    assert body["performer_name"] == "Inter Miami CF"
    assert body["league"] == "MLS"
    assert body["price_stats"]["home"]["median"] == 89.33
    assert body["weighted"]["away"] == 172.0


# ---------- by-source ----------

def test_performer_by_source(client, monkeypatch):
    _db(monkeypatch,
        d0_perf_by_source=[{"source": "seatgeek_sales", "is_owned": False, "revenue": 395213.43},
                           {"source": "evo", "is_owned": True, "revenue": 403.2}])
    body = client.get("/api/d0/sales/performers/72393/by-source").json()
    assert body["count"] == 2
    assert body["by_source"][0]["source"] == "seatgeek_sales"


# ---------- sections ----------

def test_sections_default_view(client, monkeypatch):
    sb = _db(monkeypatch, d0_perf_sections=[{"section": "107", "revenue": 14945.94}])
    body = client.get("/api/d0/sales/performers/72393/sections").json()
    assert body["top5"] is False and body["count"] == 1
    assert "d0_perf_sections" in sb.calls["tables"]


def test_sections_top5_and_role_filter(client, monkeypatch):
    sb = _db(monkeypatch, d0_perf_top5_sections=[{"section": "club 119", "role": "home"}])
    body = client.get("/api/d0/sales/performers/72393/sections?top5=true&role=home").json()
    assert body["top5"] is True and body["role"] == "home"
    assert "d0_perf_top5_sections" in sb.calls["tables"]
    assert ("role", "home") in sb.calls["eq"]


def test_sections_ignores_bad_role(client, monkeypatch):
    sb = _db(monkeypatch, d0_perf_sections=[{"section": "107"}])
    client.get("/api/d0/sales/performers/72393/sections?role=bogus")
    # a non home/away role is not pushed down as an eq filter
    assert ("role", "bogus") not in sb.calls.get("eq", [])


# ---------- health ----------

def test_health_strip(client, monkeypatch):
    _db(monkeypatch,
        d0_refresh_health=[{"jobname": "d0_refresh_sales_fact_nightly", "status": "succeeded",
                            "duration_secs": 12.3}])
    body = client.get("/api/d0/sales/health").json()
    assert body["count"] == 1
    assert body["runs"][0]["status"] == "succeeded"
