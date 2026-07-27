"""Tests for the read-only /api/axs/* routes (routers/axs.py).

BR-CODE-1 slice 8. AXS box-office reads: event (linked/unlinked), sections +
listings summary math, series RPC shape. No real DB.
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
        return type("_R", (), {"data": self._data})()


class _Sb:
    def __init__(self, tables=None, rpc=None):
        self._tables = tables or {}
        self._rpc = rpc or {}

    def table(self, name):
        return _Q(self._tables.get(name, []))

    def rpc(self, name, params=None):
        return _Q(self._rpc.get(name, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _db(monkeypatch, **kw):
    monkeypatch.setattr(app_module, "require_sb", lambda: _Sb(**kw))


def test_axs_events_list(client, monkeypatch):
    evs = [
        {"axs_event_id": "ev-a", "event_url": "https://axs.com/a", "tevo_event_id": 42,
         "tevo_venue_id": 7, "active": True, "last_pulled_at": "2026-06-19T00:00:00Z",
         "last_snapshot_id": 100},
        {"axs_event_id": "ev-b", "event_url": "https://axs.com/b", "tevo_event_id": None,
         "tevo_venue_id": None, "active": True, "last_pulled_at": None,
         "last_snapshot_id": None},
    ]
    snaps = [{"id": 100, "captured_at": "2026-06-19T00:00:00Z", "event_name": "Show A",
              "venue_name": "Arena", "occurs_at_local": "2026-07-01T20:00:00-04:00",
              "currency": "USD", "getin": 55, "price_min": 55, "price_max": 250,
              "listings_count": 120, "sections_count": 18, "offers_count": 3,
              "seats_primary": 100, "seats_resale": 20, "onsale_now": True}]
    metrics = [{"event_id": 42, "owned_tickets_count": 8, "owned_groups_count": 2,
                "owned_share": 0.25}]
    _db(monkeypatch, tables={"axs_events": evs, "axs_event_snapshots": snaps,
                             "latest_event_metrics": metrics})
    body = client.get("/api/axs/events").json()
    assert body["count"] == 2
    assert body["linked"] == 1
    assert body["pulled"] == 1
    assert body["owned"] == 1
    a = next(e for e in body["events"] if e["axs_event_id"] == "ev-a")
    assert a["linked"] is True and a["event_name"] == "Show A"
    assert a["getin"] == 55 and a["seats_resale"] == 20
    assert a["we_own"] is True and a["owned_tickets"] == 8 and a["owned_share"] == 0.25
    b = next(e for e in body["events"] if e["axs_event_id"] == "ev-b")
    assert b["linked"] is False and b["event_name"] is None and b["captured_at"] is None
    assert b["we_own"] is False and b["owned_tickets"] is None


def test_axs_event_unlinked(client, monkeypatch):
    _db(monkeypatch, tables={"axs_event_snapshots": []})
    body = client.get("/api/axs/event/3091423").json()
    assert body["linked"] is False and body["latest"] is None


def test_axs_event_linked(client, monkeypatch):
    snap = {"id": 9, "captured_at": "2026-05-10T00:00:00Z", "getin": 5000}
    _db(monkeypatch, tables={"axs_event_snapshots": [snap]})
    body = client.get("/api/axs/event/3091423").json()
    assert body["linked"] is True
    assert body["latest"]["getin"] == 5000
    assert body["captured_at"] == "2026-05-10T00:00:00Z"


def test_axs_sections_summary(client, monkeypatch):
    secs = [
        {"section_label": "A", "avail_qty": 4, "price_min": 100, "has_resale": True, "sold_out": False},
        {"section_label": "B", "avail_qty": 2, "price_min": 250, "has_resale": False, "sold_out": True},
    ]
    _db(monkeypatch, tables={
        "axs_event_snapshots": [{"id": 1, "captured_at": "t", "getin": 90, "price_max": 300}],
        "axs_section_snapshots": secs})
    s = client.get("/api/axs/event/1/sections").json()["summary"]
    assert s["total_sections"] == 2
    assert s["available_qty"] == 6
    assert s["resale_sections"] == 1 and s["sold_out_sections"] == 1
    assert s["min_price"] == 100 and s["max_price"] == 250


def test_axs_listings_summary(client, monkeypatch):
    rows = [
        {"quantity": 3, "retail_price": 120, "src": "primary", "listing_id": 136875980610387530},
        {"quantity": 2, "retail_price": 400, "src": "resale", "listing_id": 42},
    ]
    buy = "https://shop.axs.com/?c=axs&e=55498790445672539"
    _db(monkeypatch, tables={
        "axs_event_snapshots": [{"id": 1, "captured_at": "t", "event_name": "E", "venue_name": "V"}],
        "v_axs_listings": rows},
        rpc={"axs_event_buy_url": buy})
    body = client.get("/api/axs/event/1/listings").json()
    assert body["buy_url"] == buy   # offer-level AXS buy deep-link surfaced per listing
    assert body["listings"][0]["listing_id"] == 136875980610387530  # stable listing id passthrough
    s = body["summary"]
    assert s["blocks"] == 2 and s["total_seats"] == 5
    assert s["min_price"] == 120 and s["max_price"] == 400
    assert s["biggest_block"] == 3 and s["resale_blocks"] == 1


def test_axs_listings_no_snapshot_has_null_buy_url(client, monkeypatch):
    _db(monkeypatch, tables={"axs_event_snapshots": []})
    body = client.get("/api/axs/event/9/listings").json()
    assert body["count"] == 0 and body["buy_url"] is None


def test_axs_series_shape(client, monkeypatch):
    rows = [{"captured_at": "2026-05-10T00:00:00Z", "median_price": 200, "listings_count": 50}]
    _db(monkeypatch, rpc={"get_axs_event_price_series": rows})
    body = client.get("/api/axs/event/1/series?range=7d").json()
    assert body["prices_axs"] == [{"t": "2026-05-10T00:00:00Z", "v": 200}]
    assert body["counts_axs"] == [{"t": "2026-05-10T00:00:00Z", "v": 50}]
