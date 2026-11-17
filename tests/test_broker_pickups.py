"""Tests for /api/broker/pickups (routers/broker.py → get_d0_pickups).

The pricing desk's pickups list: our daily order pace per future event (hot)
and listed inventory not clearing by event day (cold). The SQL lives in mig
20261006170000; these tests pin the route contract — parameter clamping, the
RPC argument names, the response envelope, and the "migration not applied"
degrade. The route caches 5 min per parameter set, so each test uses a
distinct parameter set. No real HTTP / DB.
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
    def __init__(self, data=None, exc=None):
        self._data, self._exc = data, exc

    def execute(self):
        if self._exc:
            raise self._exc
        return type("_R", (), {"data": self._data})()


class _Sb:
    """`errs` maps an RPC name to the exception that call raises."""
    def __init__(self, rows=None, errs=None):
        self.rows, self.errs, self.calls = rows or [], errs or {}, []

    def rpc(self, name, params=None):
        self.calls.append((name, params))
        return _Q(self.rows, self.errs.get(name))


V2_MISSING = Exception("Could not find the function public.get_d0_pickups_v2 (PGRST202)")


@pytest.fixture
def client():
    return TestClient(app_module.app)


ROW = {
    "tevo_event_id": 3285604, "event_name": "Kansas City Chiefs at Atlanta Falcons",
    "occurs_at_local": "2026-11-15T13:00:00-05:00", "days_out": 40,
    "daily": [{"d": "2026-10-02", "orders": 3, "tix": 10}, {"d": "2026-10-05", "orders": 16, "tix": 38}],
    "orders_window": 27, "tix_window": 71, "sales_window": 19163.14, "trend": "spike",
    "open_qty": 1094, "pace_ratio": 0.65, "score": 82.58,
}


def test_hot_passes_params_and_wraps_rows(client, monkeypatch):
    sb = _Sb(rows=[ROW])
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    body = client.get("/api/broker/pickups?mode=hot&days=4&min_days_out=7&max_days_out=365&limit=8").json()
    assert sb.calls == [("get_d0_pickups_v2", {"p_mode": "hot", "p_window_days": 4, "p_min_days_out": 7,
                                            "p_max_days_out": 365, "p_limit": 8})]
    assert body["mode"] == "hot"
    assert body["count"] == 1
    assert body["events"][0]["tevo_event_id"] == 3285604
    assert "generated_at" in body


def test_params_are_clamped_and_mode_normalized(client, monkeypatch):
    sb = _Sb()
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    body = client.get("/api/broker/pickups?mode=COLD&days=99&min_days_out=900&max_days_out=5&limit=9999").json()
    _, p = sb.calls[0]
    assert p["p_mode"] == "cold"
    assert p["p_window_days"] == 14
    assert p["p_min_days_out"] == 730
    assert p["p_max_days_out"] == 730   # never below min_days_out
    assert p["p_limit"] == 200
    assert body["count"] == 0 and body["events"] == []


def test_unknown_mode_falls_back_to_hot(client, monkeypatch):
    sb = _Sb()
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    client.get("/api/broker/pickups?mode=bogus&days=3")
    assert sb.calls[0][1]["p_mode"] == "hot"


def test_cached_per_param_set(client, monkeypatch):
    sb = _Sb(rows=[ROW])
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    q = "/api/broker/pickups?mode=hot&days=2&min_days_out=11&max_days_out=99&limit=5"
    client.get(q)
    client.get(q)
    assert len(sb.calls) == 1


def test_falls_back_to_v1_when_v2_missing(client, monkeypatch):
    sb = _Sb(rows=[ROW], errs={"get_d0_pickups_v2": V2_MISSING})
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    body = client.get("/api/broker/pickups?mode=hot&days=3&min_days_out=9").json()
    assert [c[0] for c in sb.calls] == ["get_d0_pickups_v2", "get_d0_pickups"]
    assert sb.calls[0][1] == sb.calls[1][1]
    assert body["count"] == 1


def test_neither_function_is_503(client, monkeypatch):
    v1_missing = Exception("Could not find the function public.get_d0_pickups (PGRST202)")
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb(
        errs={"get_d0_pickups_v2": V2_MISSING, "get_d0_pickups": v1_missing}))
    r = client.get("/api/broker/pickups?mode=hot&days=5&min_days_out=12")
    assert r.status_code == 503
    assert "20261006170000" in r.json()["detail"]


def test_v2_failure_is_502_without_fallback(client, monkeypatch):
    sb = _Sb(errs={"get_d0_pickups_v2": Exception("statement timeout")})
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    r = client.get("/api/broker/pickups?mode=cold&days=6&min_days_out=13")
    assert r.status_code == 502
    assert [c[0] for c in sb.calls] == ["get_d0_pickups_v2"]


def test_v1_failure_after_fallback_is_502(client, monkeypatch):
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb(
        errs={"get_d0_pickups_v2": V2_MISSING, "get_d0_pickups": Exception("statement timeout")}))
    r = client.get("/api/broker/pickups?mode=cold&days=7&min_days_out=14")
    assert r.status_code == 502
