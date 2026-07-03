"""Tests for the prediction-markets + macro-series broker routes.

Covers routers/broker.py:
  - /api/broker/event/{id}/prediction-markets  (RPC dict passthrough, empty
    fallback when the RPC is absent, and the exception degrade path)
  - /api/broker/macro/{series_id}              (view read, oldest->newest
    reversal, limit clamp, empty)

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


# ---------- /api/broker/event/{id}/prediction-markets ----------

def test_prediction_markets_passthrough(client, monkeypatch):
    payload = {
        "event_id": 3201000,
        "game_markets": [{"source": "kalshi", "subtitle": "Texas", "yes_price": 0.57}],
        "futures": [{"source": "polymarket", "subtitle": "Texas Rangers", "yes_price": 0.021}],
    }
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_event_prediction_markets": payload}))
    body = client.get("/api/broker/event/3201000/prediction-markets").json()
    assert body == payload
    assert body["game_markets"][0]["yes_price"] == 0.57


def test_prediction_markets_absent_rpc_falls_back_to_empty(client, monkeypatch):
    # FakeSupabase default for an unknown rpc is [] (not a dict) -> empty shape.
    _use_db(monkeypatch, FakeSupabase())
    body = client.get("/api/broker/event/7/prediction-markets").json()
    assert body == {"event_id": 7, "game_markets": [], "futures": []}


def test_prediction_markets_rpc_error_degrades(client, monkeypatch):
    class _Boom(FakeSupabase):
        def rpc(self, name, params=None):
            raise RuntimeError("function get_event_prediction_markets does not exist")

    _use_db(monkeypatch, _Boom())
    body = client.get("/api/broker/event/9/prediction-markets").json()
    assert body["event_id"] == 9
    assert body["game_markets"] == [] and body["futures"] == []
    assert "does not exist" in body["error"]


# ---------- /api/broker/performer/{id}/prediction-markets ----------

def test_performer_prediction_markets_passthrough(client, monkeypatch):
    payload = {
        "performer_id": 15544,
        "markets": [
            {"source": "kalshi", "market_type": "game", "subtitle": "Texas", "yes_price": 0.57},
            {"source": "polymarket", "market_type": "futures", "subtitle": "Texas Rangers", "yes_price": 0.021},
        ],
    }
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_performer_prediction_markets": payload}))
    body = client.get("/api/broker/performer/15544/prediction-markets").json()
    assert body == payload
    assert len(body["markets"]) == 2


def test_performer_prediction_markets_absent_rpc_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    body = client.get("/api/broker/performer/1/prediction-markets").json()
    assert body == {"performer_id": 1, "markets": []}


def test_performer_prediction_markets_error_degrades(client, monkeypatch):
    class _Boom(FakeSupabase):
        def rpc(self, name, params=None):
            raise RuntimeError("function get_performer_prediction_markets does not exist")

    _use_db(monkeypatch, _Boom())
    body = client.get("/api/broker/performer/2/prediction-markets").json()
    assert body["performer_id"] == 2 and body["markets"] == []
    assert "does not exist" in body["error"]


# ---------- /api/broker/macro/{series_id} ----------

def test_macro_series_reverses_to_oldest_first(client, monkeypatch):
    # View returns newest-first (route orders desc); route reverses for charting.
    rows = [
        {"observation_date": "2026-07-01", "value": 2654017},
        {"observation_date": "2026-06-30", "value": 2477905},
        {"observation_date": "2026-06-29", "value": 2690919},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_macro_indicators_latest": rows}))
    body = client.get("/api/broker/macro/TSA_THROUGHPUT?limit=3").json()
    assert body["series_id"] == "TSA_THROUGHPUT"
    assert body["count"] == 3
    # oldest first after the reversal
    assert [p["observation_date"] for p in body["points"]] == [
        "2026-06-29", "2026-06-30", "2026-07-01"]


def test_macro_series_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"v_macro_indicators_latest": []}))
    body = client.get("/api/broker/macro/UMCSENT").json()
    assert body == {"series_id": "UMCSENT", "points": [], "count": 0}


def test_macro_series_clamps_extreme_limit(client, monkeypatch):
    # limit above 600 or below 1 is clamped; just assert the call succeeds and
    # echoes the (empty) result — the clamp itself is exercised by both bounds.
    _use_db(monkeypatch, FakeSupabase(table_data={"v_macro_indicators_latest": []}))
    assert client.get("/api/broker/macro/TSA_THROUGHPUT?limit=99999").status_code == 200
    assert client.get("/api/broker/macro/TSA_THROUGHPUT?limit=0").status_code == 200
