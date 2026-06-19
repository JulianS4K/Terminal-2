"""Tests for the read-only /api/seatdata/* routes (routers/seatdata.py).

BR-CODE-1 slice 7. Covers the SeatData diagnostics + DB reads (no mutations):
account (+503 when unconfigured), budget (rpc), event (linked + unlinked),
event/sales (the price summary math). No real SeatData / DB calls.
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


class _Res:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


class _Q:
    def __init__(self, data, count=None):
        self._data = data
        self._count = count

    def select(self, *a, **k):
        return self

    def eq(self, *a, **k):
        return self

    def order(self, *a, **k):
        return self

    def limit(self, *a, **k):
        return self

    def execute(self):
        return _Res(self._data, self._count)


class _Sb:
    def __init__(self, tables=None, rpc=None, counts=None):
        self._tables = tables or {}
        self._rpc = rpc or {}
        self._counts = counts or {}

    def table(self, name):
        return _Q(self._tables.get(name, []), self._counts.get(name))

    def rpc(self, name, params=None):
        return _Q(self._rpc.get(name, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _db(monkeypatch, **kw):
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb(**kw))


# ---------- account ----------

def test_account_503_when_unconfigured(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: None)
    assert client.get("/api/seatdata/account").status_code == 503


def test_account_passthrough(client, monkeypatch):
    class C:
        def account(self):
            return {"plan": "pro"}
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: C())
    assert client.get("/api/seatdata/account").json() == {"plan": "pro"}


# ---------- budget ----------

def test_budget_rpc(client, monkeypatch):
    _db(monkeypatch, rpc={"seatdata_check_budget": {"allowed": True, "used": 3}})
    assert client.get("/api/seatdata/budget").json() == {"allowed": True, "used": 3}


# ---------- event ----------

def test_event_unlinked(client, monkeypatch):
    _db(monkeypatch, tables={"seatdata_event_xref": []})
    body = client.get("/api/seatdata/event/55").json()
    assert body["linked"] is False and body["sales_count"] == 0


def test_event_linked_with_counts(client, monkeypatch):
    _db(monkeypatch,
        tables={"seatdata_event_xref": [{"tevo_event_id": 55, "sd_event_id": "x"}],
                "seatdata_event_latest": [{"median": 120}]},
        counts={"seatdata_sales_snapshots": 7, "seatdata_event_stats": 2})
    body = client.get("/api/seatdata/event/55").json()
    assert body["linked"] is True
    assert body["sales_count"] == 7 and body["stats_count"] == 2
    assert body["latest_stats"] == {"median": 120}


# ---------- event/sales (summary math) ----------

def test_event_sales_summary_math(client, monkeypatch):
    rows = [
        {"sale_timestamp": "2026-05-10T00:00:00Z", "quantity": 2, "price": 100, "zone": "Lower", "section": "1", "row": "A"},
        {"sale_timestamp": "2026-05-09T00:00:00Z", "quantity": 1, "price": 200, "zone": "Upper", "section": "2", "row": "B"},
        {"sale_timestamp": "2026-05-08T00:00:00Z", "quantity": 1, "price": 300, "zone": "Lower", "section": "3", "row": "C"},
    ]
    _db(monkeypatch, tables={"seatdata_sales_snapshots": rows})
    s = client.get("/api/seatdata/event/55/sales").json()
    assert s["count"] == 3
    assert s["summary"]["median"] == 200
    assert s["summary"]["min"] == 100 and s["summary"]["max"] == 300
    assert s["summary"]["tickets_total"] == 4  # 2+1+1
    assert s["summary"]["zones"] == ["Lower", "Upper"]
    # rows are pre-sorted DESC by the query; first_sale = last row, last_sale = first row.
    assert s["summary"]["last_sale"] == "2026-05-10T00:00:00Z"


def test_event_sales_empty(client, monkeypatch):
    _db(monkeypatch, tables={"seatdata_sales_snapshots": []})
    s = client.get("/api/seatdata/event/55/sales").json()
    assert s["count"] == 0 and s["summary"]["avg"] is None
