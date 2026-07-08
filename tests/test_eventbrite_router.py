"""Tests for the read-only /api/eventbrite/events route (routers/eventbrite.py).

Eventbrite organizer discovery reads: price band / availability / venue geo
extraction from the stored raw /events item, the upcoming date filter, the
_num coercion edge cases, and the empty set. No real DB.
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
from routers.eventbrite import _num  # noqa: E402

TestClient = starlette_testclient.TestClient


class _Q:
    def __init__(self, data):
        self._data = data
        self.gte_called = False

    def select(self, *a, **k):
        return self

    def eq(self, *a, **k):
        return self

    def gte(self, *a, **k):
        self.gte_called = True
        return self

    def order(self, *a, **k):
        return self

    def limit(self, *a, **k):
        return self

    def execute(self):
        return type("_R", (), {"data": self._data})()


class _Sb:
    def __init__(self, rows):
        self._rows = rows
        self.last_q = None

    def table(self, name):
        self.last_q = _Q(self._rows)
        return self.last_q


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _db(monkeypatch, rows):
    sb = _Sb(rows)
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    return sb


def test_eventbrite_events_shapes(client, monkeypatch):
    rows = [
        # sold out, waitlist, mapped to TEvo, full venue geo, valid prices
        {"td_event_id": "1", "event_url": "https://www.eventbrite.com/e/x-1",
         "event_name": "Sold Show", "event_date": "2027-01-22",
         "venue_name": "Knockdown Center", "city": "Queens",
         "matched_tevo_event_id": 99, "discovered_at": "2026-07-08T00:00:00Z",
         "raw": {"venue": {"region": "NY"}, "currency": "USD",
                 "min_ticket_price": 37.24, "max_ticket_price": 42.0,
                 "is_sold_out": True, "has_available_tickets": False,
                 "waitlist_available": True, "sales_status": "sales_ended"}},
        # on sale, unmapped, free flag, venue missing (non-dict), price as bad string
        {"td_event_id": "2", "event_url": "https://www.eventbrite.com/e/x-2",
         "event_name": "Open Show", "event_date": "2027-02-01",
         "venue_name": "Elsewhere", "city": "Brooklyn",
         "matched_tevo_event_id": None, "discovered_at": "2026-07-08T00:00:00Z",
         "raw": {"currency": "USD", "min_ticket_price": "n/a",
                 "is_free": True, "has_available_tickets": True,
                 "is_sold_out": False}},
    ]
    _db(monkeypatch, rows)
    body = client.get("/api/eventbrite/events").json()
    assert body["count"] == 2
    assert body["linked"] == 1
    assert body["sold_out"] == 1
    assert body["on_sale"] == 1

    a = next(e for e in body["events"] if e["td_event_id"] == "1")
    assert a["linked"] is True and a["region"] == "NY"
    assert a["price_min"] == 37.24 and a["price_max"] == 42.0
    assert a["sold_out"] is True and a["waitlist"] is True

    b = next(e for e in body["events"] if e["td_event_id"] == "2")
    assert b["linked"] is False and b["region"] is None
    assert b["price_min"] is None            # "n/a" coerces to None
    assert b["is_free"] is True and b["has_tickets"] is True


def test_eventbrite_events_upcoming_filter(client, monkeypatch):
    sb = _db(monkeypatch, [])
    body = client.get("/api/eventbrite/events?upcoming=true").json()
    assert body["count"] == 0 and body["events"] == []
    assert sb.last_q.gte_called is True     # upcoming=true applies the date gate


def test_num_coercion():
    assert _num(None) is None
    assert _num("") is None
    assert _num("abc") is None
    assert _num(37.24) == 37.24
    assert _num("42") == 42.0
