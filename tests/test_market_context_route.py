"""Tests for /api/store/events/{id}/market-context — the "Deal & demand"
panel's data route.

The route wraps the SECURITY DEFINER RPC get_event_market_context_public via
the service-role client. These tests monkeypatch app.sb so no Supabase is
touched, and lock in the defensive contract: a usable payload is passed
through with available=true; anything else (no client, RPC error, empty /
coverage-less payload) returns available=false so the panel hides instead of
erroring.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("STOREFRONT_SQL_ONLY", "true")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

import app as app_module  # noqa: E402

client = TestClient(app_module.app)

_PAYLOAD = {
    "event_id": 3138822,
    "our_from_price": 79.5,
    "market": {"median": 217.03, "min": 73.51, "listings": 6127,
               "by_source": [{"label": "SeatGeek", "median": 217.03}]},
    "below_market": {"amount": 138, "pct": 63, "vs": "SeatGeek median"},
    "demand": {"getin_change_24h_pct": 2.4, "label": "firm"},
    "history": [{"d": "2026-06-19", "ours": 77.6, "market": 217.0},
                {"d": "2026-06-20", "ours": 79.5, "market": 217.0}],
    "generated_at": "2026-06-20T15:00:00+00:00",
}


class _FakeRpc:
    def __init__(self, data=None, raises=False):
        self._data, self._raises = data, raises

    def rpc(self, name, params):
        assert name == "get_event_market_context_public"
        assert params["p_event_id"] == 3138822 and params["p_history_days"] == 30
        if self._raises:
            raise RuntimeError("db down")
        outer = self

        class _Exec:
            def execute(self_inner):
                return type("R", (), {"data": outer._data})()
        return _Exec()


def test_market_context_passthrough(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeRpc(data=_PAYLOAD))
    r = client.get("/api/store/events/3138822/market-context")
    assert r.status_code == 200
    body = r.json()
    assert body["available"] is True
    assert body["below_market"]["pct"] == 63
    assert body["market"]["by_source"][0]["label"] == "SeatGeek"
    assert len(body["history"]) == 2


def test_market_context_unavailable_when_no_client(monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    r = client.get("/api/store/events/3138822/market-context")
    assert r.status_code == 200
    assert r.json() == {"event_id": 3138822, "available": False}


def test_market_context_unavailable_on_rpc_error(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeRpc(raises=True))
    r = client.get("/api/store/events/3138822/market-context")
    assert r.status_code == 200
    assert r.json()["available"] is False


def test_market_context_unavailable_when_no_coverage(monkeypatch):
    # RPC returns an object with no market/history/below_market → panel hides.
    monkeypatch.setattr(app_module, "sb", _FakeRpc(data={"event_id": 3138822, "our_from_price": 50}))
    r = client.get("/api/store/events/3138822/market-context")
    assert r.json()["available"] is False
