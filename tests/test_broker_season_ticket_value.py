"""Tests for the season-ticket package value broker routes.

Covers routers/broker.py:
  - /api/broker/season-ticket-value            (leaderboard RPC dict passthrough,
    empty fallback when the RPC is absent, exception degrade)
  - /api/broker/season-ticket-value/{id}       (live per-package RPC passthrough,
    empty skeleton fallback, exception degrade, and the row_band clamp both bounds)

Same fake-env-before-import + TestClient pattern as tests/test_broker_routes.py.
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

from tests.test_broker_routes import FakeSupabase  # reuse the fluent fake

TestClient = starlette_testclient.TestClient


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _use_db(monkeypatch, fake):
    monkeypatch.setattr(app_module, "require_sb", lambda: fake)


# ---------- /api/broker/season-ticket-value (leaderboard) ----------

def test_leaderboard_passthrough(client, monkeypatch):
    payload = {
        "packages": [
            {"pkg_event_id": 3287281, "league": "NFL", "team": "Philadelphia Eagles",
             "verdict": "BUY", "pct_cheaper_vwap": 71.0, "med_savings_vwap": 163.0},
        ],
        "computed_at": "2026-07-09T09:40:00+00:00",
    }
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_season_ticket_leaderboard": payload}))
    body = client.get("/api/broker/season-ticket-value").json()
    assert body == payload
    assert body["packages"][0]["verdict"] == "BUY"


def test_leaderboard_absent_rpc_falls_back_to_empty(client, monkeypatch):
    # Unknown rpc default is [] (not a dict) -> empty leaderboard shape.
    _use_db(monkeypatch, FakeSupabase())
    body = client.get("/api/broker/season-ticket-value").json()
    assert body == {"packages": [], "computed_at": None}


def test_leaderboard_rpc_error_degrades(client, monkeypatch):
    class _Boom(FakeSupabase):
        def rpc(self, name, params=None):
            raise RuntimeError("function get_season_ticket_leaderboard does not exist")

    _use_db(monkeypatch, _Boom())
    body = client.get("/api/broker/season-ticket-value").json()
    assert body["packages"] == [] and body["computed_at"] is None
    assert "does not exist" in body["error"]


# ---------- /api/broker/season-ticket-value/{id} (live detail) ----------

def test_detail_passthrough(client, monkeypatch):
    payload = {
        "event": {"pkg_event_id": 3287262, "league": "NFL", "team": "Dallas Cowboys"},
        "params": {"row_band": 5},
        "summary": {"seats_valued": 39, "verdict": "SKIP", "pct_cheaper_vwap": 28.0},
        "seats": [{"section": "419", "row": 20, "pkg_ask": 1576.08, "savings_vwap": -100.0}],
    }
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_season_ticket_value": payload}))
    body = client.get("/api/broker/season-ticket-value/3287262").json()
    assert body == payload
    assert body["summary"]["verdict"] == "SKIP"


def test_detail_absent_rpc_returns_skeleton(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    body = client.get("/api/broker/season-ticket-value/7?row_band=8").json()
    assert body == {"event": {"pkg_event_id": 7}, "params": {"row_band": 8},
                    "summary": None, "seats": []}


def test_detail_rpc_error_degrades(client, monkeypatch):
    class _Boom(FakeSupabase):
        def rpc(self, name, params=None):
            raise RuntimeError("function get_season_ticket_value does not exist")

    _use_db(monkeypatch, _Boom())
    body = client.get("/api/broker/season-ticket-value/9").json()
    assert body["event"] == {"pkg_event_id": 9} and body["summary"] is None
    assert body["seats"] == [] and "does not exist" in body["error"]


def test_detail_row_band_clamped_high_and_low(client, monkeypatch):
    fake = FakeSupabase(rpc_data={"get_season_ticket_value": {"ok": True}})
    _use_db(monkeypatch, fake)

    client.get("/api/broker/season-ticket-value/3287262?row_band=99")
    assert fake.rpc_calls[-1] == ("get_season_ticket_value",
                                  {"p_pkg_event_id": 3287262, "p_row_band": 20})

    client.get("/api/broker/season-ticket-value/3287262?row_band=-3")
    assert fake.rpc_calls[-1] == ("get_season_ticket_value",
                                  {"p_pkg_event_id": 3287262, "p_row_band": 0})

    client.get("/api/broker/season-ticket-value/3287262")  # default band = 5
    assert fake.rpc_calls[-1] == ("get_season_ticket_value",
                                  {"p_pkg_event_id": 3287262, "p_row_band": 5})
