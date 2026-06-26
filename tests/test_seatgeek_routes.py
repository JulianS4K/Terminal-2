"""Tests for the read-only /api/seatgeek/* routes (routers/seatgeek.py).

BR-CODE-1 slice 9. SG persisted reads: event (linked/unlinked), listings +
sales summary math, seller-status link-rate. No real DB / SG calls.
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
    def __init__(self, tables=None, counts=None):
        self._tables = tables or {}
        self._counts = counts or {}

    def table(self, name):
        return _Q(self._tables.get(name, []), self._counts.get(name))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _db(monkeypatch, **kw):
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb(**kw))


def test_sg_event_unlinked(client, monkeypatch):
    _db(monkeypatch, tables={"seatgeek_event_latest": []})
    assert client.get("/api/seatgeek/event/55").json() == {"tevo_event_id": 55, "linked": False}


def test_sg_event_linked_merges_row(client, monkeypatch):
    _db(monkeypatch, tables={"seatgeek_event_latest": [{"median": 120, "owned": 3}]})
    body = client.get("/api/seatgeek/event/55").json()
    assert body["linked"] is True and body["median"] == 120 and body["owned"] == 3


def test_sg_listings_summary(client, monkeypatch):
    rows = [
        {"sglid": "a", "quantity": 2, "retail_price_all_in": 100, "is_broker_owned": True, "captured_at": "t"},
        {"sglid": "b", "quantity": 1, "retail_price_all_in": 300, "is_b2b": True, "captured_at": "t"},
    ]
    _db(monkeypatch, tables={
        "seatgeek_listings_snapshots": rows})
    # latest_only path needs a "last captured_at" probe row; the same table stub
    # returns `rows` for every call, so the probe returns rows[0] -> fine.
    s = client.get("/api/seatgeek/event/55/listings").json()["summary"]
    assert s["total_listings"] == 2
    assert s["total_tickets"] == 3
    assert s["broker_owned"] == 1 and s["b2b_sourced"] == 1
    assert s["min_retail_all_in"] == 100 and s["max_retail_all_in"] == 300


def test_sg_sales_summary(client, monkeypatch):
    rows = [
        {"sg_sale_id": "1", "broadcast_price": 200, "quantity": 2, "sale_at_utc": "2026-05-10"},
        {"sg_sale_id": "2", "broadcast_price": 100, "quantity": 1, "sale_at_utc": "2026-05-09"},
    ]
    _db(monkeypatch, tables={"seatgeek_sales_snapshots": rows})
    s = client.get("/api/seatgeek/event/55/sales").json()["summary"]
    assert s["total_sales"] == 2 and s["total_tickets_sold"] == 3
    assert s["min_broadcast_price"] == 100 and s["max_broadcast_price"] == 200
    assert s["last_sale"] == "2026-05-10"


def test_sg_seller_status_link_rate(client, monkeypatch):
    stats = [
        {"sg_event_id": "A", "tevo_event_id": 1, "pulled_at": "t2"},
        {"sg_event_id": "B", "tevo_event_id": None, "pulled_at": "t1"},
    ]
    _db(monkeypatch,
        tables={"seatgeek_seller_pull_log": [{"called_at": "t2"}], "seatgeek_seller_listings": stats},
        counts={"seatgeek_orders": 9})
    body = client.get("/api/seatgeek/seller-status").json()
    assert body["distinct_sg_events_in_listings"] == 2
    assert body["auto_linked_to_tevo"] == 1
    assert body["auto_link_rate"] == 0.5
    assert body["total_orders_persisted"] == 9
