"""Tests for read-only /api/broker/* routes in app.py.

Second increment of the broker/admin coverage push (BR-CODE-3, bottleneck
research 2026-06-19). Introduces a small reusable FakeSupabase that drives
both the `.rpc(name, params).execute().data` and the
`.table(name).select(...).eq(...).order(...).limit(...).execute().data`
fluent chains, so future broker tests can program RPC / table responses
without a live DB.

Covered here (all GET, read-only, deterministic):
  - /api/broker/leagues            (static, no DB)
  - /api/broker/performer/{id}/assets   (single-table read + empty fallback)
  - /api/broker/event/{id}/overview     (multi-RPC payload; empty + populated)

Pattern mirrors tests/test_store_events.py: fake env BEFORE importing app,
then drive app.app via Starlette's TestClient. No real HTTP / DB.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")  # don't gate routes in tests

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------- Reusable fake Supabase ----------

class _FakeQuery:
    """A no-op fluent chain. Every builder method returns self; execute()
    yields an object exposing the preloaded `.data`."""

    def __init__(self, data):
        self._data = data

    # builder methods used across broker routes — all return self
    def select(self, *_a, **_k):
        return self

    def eq(self, *_a, **_k):
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def execute(self):
        return type("_Res", (), {"data": self._data})()


class FakeSupabase:
    """Programmable stand-in for the supabase client.

    rpc_data: {rpc_name: list-of-rows}; table_data: {table_name: list-of-rows}.
    Unknown names default to [] (mirrors `.data or []` call sites). Records
    every rpc/table name touched for assertions.
    """

    def __init__(self, rpc_data=None, table_data=None):
        self.rpc_data = rpc_data or {}
        self.table_data = table_data or {}
        self.rpc_calls: list[tuple[str, dict]] = []
        self.table_calls: list[str] = []

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params or {}))
        return _FakeQuery(self.rpc_data.get(name, []))

    def table(self, name):
        self.table_calls.append(name)
        return _FakeQuery(self.table_data.get(name, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _use_db(monkeypatch, fake: FakeSupabase):
    monkeypatch.setattr(app_module, "require_sb", lambda: fake)


# ---------- /api/broker/leagues ----------

def test_leagues_returns_static_list(client):
    body = client.get("/api/broker/leagues").json()
    assert body == {"leagues": app_module._ESPN_LEAGUES}
    assert isinstance(body["leagues"], list)


# ---------- /api/broker/performer/{id}/assets ----------

def test_performer_assets_empty_fallback(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"performer_metadata": []}))
    body = client.get("/api/broker/performer/999/assets").json()
    # No row => deterministic fallback shape keyed on the requested id.
    assert body == {"performer_id": 999, "logo_default_url": None}


def test_performer_assets_returns_row(client, monkeypatch):
    row = {
        "performer_id": 16303, "name": "New York Knicks",
        "espn_team_id": "18", "espn_league": "NBA",
        "logo_default_url": "https://x/knicks.png",
    }
    _use_db(monkeypatch, FakeSupabase(table_data={"performer_metadata": [row]}))
    body = client.get("/api/broker/performer/16303/assets").json()
    assert body["performer_id"] == 16303
    assert body["espn_league"] == "NBA"
    assert body["logo_default_url"] == "https://x/knicks.png"


# ---------- /api/broker/event/{id}/overview ----------

def test_overview_empty_event_degrades_cleanly(client, monkeypatch):
    # Every RPC + table returns [] => head None, metrics all None, no crash.
    _use_db(monkeypatch, FakeSupabase())
    monkeypatch.setattr(app_module, "_bulk_performer_assets", lambda db, pids: {})
    r = client.get("/api/broker/event/3091423/overview")
    assert r.status_code == 200
    body = r.json()
    assert body["event"] is None
    assert body["zones"] == {"owned": [], "market": []}
    assert body["lifecycle"] is None
    # metrics is the full keyed structure even with no data, each {v, delta}.
    assert body["metrics"]["getin_price"] == {"v": None, "delta": None}


def test_overview_populated_computes_metric_deltas(client, monkeypatch):
    head = {
        "id": 3091423, "name": "New York Knicks vs Boston Celtics",
        "primary_performer_id": 16303, "performer_ids": [16303],
        "occurs_at_local": "2026-06-01T19:00:00-04:00",
    }
    em_curr = {"captured_at": "2026-05-10T12:00:00Z", "getin_price": 150, "tickets_count": 500}
    em_prev = {"captured_at": "2026-05-09T12:00:00Z", "getin_price": 120, "tickets_count": 400}
    fake = FakeSupabase(
        rpc_data={"get_broker_event_detail": [head]},
        table_data={"event_metrics": [em_curr, em_prev]},
    )
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "_bulk_performer_assets", lambda db, pids: {})
    body = client.get("/api/broker/event/3091423/overview").json()
    assert body["event"]["name"].startswith("New York Knicks")
    # current value surfaced + a non-null delta vs prior (150 vs 120).
    assert body["metrics"]["getin_price"]["v"] == 150
    assert body["metrics"]["getin_price"]["delta"] is not None
    assert body["last_pull_at"] == "2026-05-10T12:00:00Z"
    # the rich-detail RPC was actually consulted for the header.
    assert any(name == "get_broker_event_detail" for name, _ in fake.rpc_calls)
