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
    def __init__(self, data, sb=None):
        self._data = data
        self._sb = sb
        self.gte_called = False

    def select(self, *a, **k):
        return self

    def eq(self, *a, **k):
        return self

    def gte(self, *a, **k):
        self.gte_called = True
        if self._sb is not None:
            self._sb.gte_called = True   # aggregate across queries (route makes >1)
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
        self.gte_called = False

    def table(self, name):
        self.last_q = _Q(self._rows, self)
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
    assert sb.gte_called is True     # upcoming=true applies the date gate


def test_num_coercion():
    assert _num(None) is None
    assert _num("") is None
    assert _num("abc") is None
    assert _num(37.24) == 37.24
    assert _num("42") == 42.0


def test_eventbrite_single_event_detail(client, monkeypatch):
    row = {
        "td_event_id": "1712180019529",
        "event_url": "https://www.eventbrite.com/e/anna-1712180019529",
        "event_name": "Elsewhere Presents: Anna von Hausswolff",
        "event_date": "2027-01-22",
        "venue_name": "Knockdown Center", "city": "Queens",
        "matched_tevo_event_id": None,
        "discovered_at": "2026-07-08T00:00:00Z",
        "raw": {
            "venue": {"region": "NY", "address_display": "52-19 Flushing Avenue, Queens, NY 11378",
                      "postal_code": "11378", "latitude": "40.7157764", "longitude": "-73.9144982"},
            "currency": "USD", "min_ticket_price": 37.24, "max_ticket_price": 37.24,
            "is_sold_out": True, "has_available_tickets": False, "waitlist_available": True,
            "sales_status": "sales_ended", "age_restriction": "16+",
            "start_date": "2027-01-22 19:00", "end_date": "2027-01-22 22:00",
            "summary": "Anna von Hausswolff @ Knockdown Center! Tickets start at $22 • 7pm • 16+ | Genre: Alternative",
            "image_original_url": "https://img.evbuc.com/original.jpg",
            "refund_policy": {"description": "No Refunds"},
            "venue_url": "https://www.eventbrite.com/o/105655500371",
        },
    }
    _db(monkeypatch, [row])
    ev = client.get("/api/eventbrite/event/1712180019529").json()
    assert ev["td_event_id"] == "1712180019529"
    assert ev["linked"] is False and ev["region"] == "NY"
    assert ev["price_min"] == 37.24 and ev["price_max"] == 37.24
    assert ev["sold_out"] is True and ev["waitlist"] is True
    assert ev["genre"] == "Alternative"                      # parsed from summary tail
    assert ev["latitude"] == 40.7157764 and ev["longitude"] == -73.9144982
    assert ev["venue_address"].startswith("52-19 Flushing")
    assert ev["refund_policy"] == "No Refunds"
    assert ev["image_url"] == "https://img.evbuc.com/original.jpg"
    assert ev["start_date"] == "2027-01-22 19:00"


def test_eventbrite_single_event_not_found(client, monkeypatch):
    _db(monkeypatch, [])
    res = client.get("/api/eventbrite/event/does-not-exist")
    assert res.status_code == 404


# --- StubHub secondary-market mapping ---------------------------------------
# A platform-aware mock: the route queries td_discovered_events twice (EB events,
# then the platform='stubhub' index), so the mock must return the right subset per
# .eq("platform", ...) filter. Rows carry a "platform" key.
class _QF:
    def __init__(self, rows):
        self._rows = rows
        self._filters = {}

    def select(self, *a, **k):
        return self

    def eq(self, col=None, val=None, *a, **k):
        if col is not None:
            self._filters[col] = val
        return self

    def gte(self, *a, **k):
        return self

    def order(self, *a, **k):
        return self

    def limit(self, *a, **k):
        return self

    def execute(self):
        data = self._rows
        for col, val in self._filters.items():
            data = [r for r in data if str(r.get(col)) == str(val)]
        return type("_R", (), {"data": data})()


class _SbF:
    def table(self, name):
        self.last_q = _QF(self._rows)
        return self.last_q


def _dbf(monkeypatch, rows):
    sb = _SbF()
    sb._rows = rows
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    return sb


def _rows_with_stubhub():
    return [
        {"platform": "eventbrite", "td_event_id": "E_CONN",
         "event_url": "https://www.eventbrite.com/e/wu-lyf",
         "event_name": "WU LYF", "event_date": "2026-07-16",
         "venue_name": "Elsewhere - The Hall", "city": "Brooklyn",
         "matched_tevo_event_id": None, "raw": {"currency": "USD"}},
        {"platform": "eventbrite", "td_event_id": "E_FETCH",
         "event_url": "https://www.eventbrite.com/e/no-cure",
         "event_name": "No Cure", "event_date": "2026-07-10",
         "venue_name": "Elsewhere - The Hall", "city": "Brooklyn",
         "matched_tevo_event_id": None, "raw": {"currency": "USD"}},
        {"platform": "eventbrite", "td_event_id": "E_NONE",
         "event_url": "https://www.eventbrite.com/e/witch",
         "event_name": "Witch Project", "event_date": "2026-07-11",
         "venue_name": "Elsewhere", "city": "Brooklyn",
         "matched_tevo_event_id": None, "raw": {"currency": "USD"}},
        # connector-discovered SH row: min price under raw.sh, no listing detail
        {"platform": "stubhub", "td_event_id": "161118309",
         "event_url": "https://www.stubhub.com/event/161118309/",
         "raw": {"source": "stubhub_connector_search",
                 "eb_match": {"td_event_id": "E_CONN"},
                 "sh": {"entity_id": "161118309", "min_price": 69.0}}},
        # manual /fetch SH row: full inventory snapshot + seat-level items
        {"platform": "stubhub", "td_event_id": "161120445",
         "event_url": "https://www.stubhub.com/event/161120445/",
         "raw": {"source": "manual_url_fetch",
                 "eb_match": {"td_event_id": "E_FETCH"},
                 "inventory": {"listings": 8, "total_tickets": 42,
                               "min_price": 55.81, "max_price": 1050.75},
                 "items": [
                     {"section": "GA Premium", "ticketClassName": "General Admission",
                      "rawPrice": 1050.75, "availableTickets": 2, "notes": []},
                     "corrupt-non-dict-row",   # defensively skipped by the normalizer
                     {"section": "General Admission", "rawPrice": 55.81, "availableTickets": 6,
                      "notes": [{"formattedListingNoteContent": "Standing room only (SRO)"}]},
                 ]}},
    ]


def test_eventbrite_list_attaches_stubhub(client, monkeypatch):
    _dbf(monkeypatch, _rows_with_stubhub())
    body = client.get("/api/eventbrite/events").json()
    assert body["count"] == 3
    assert body["on_stubhub"] == 2

    conn = next(e for e in body["events"] if e["td_event_id"] == "E_CONN")
    assert conn["stubhub"]["entity_id"] == "161118309"
    assert conn["stubhub"]["min_price"] == 69.0
    assert conn["stubhub"]["listings"] is None      # connector search has no seat detail

    fetch = next(e for e in body["events"] if e["td_event_id"] == "E_FETCH")
    assert fetch["stubhub"]["min_price"] == 55.81
    assert fetch["stubhub"]["max_price"] == 1050.75
    assert fetch["stubhub"]["listings"] == 8 and fetch["stubhub"]["total_tickets"] == 42

    none = next(e for e in body["events"] if e["td_event_id"] == "E_NONE")
    assert none["stubhub"] is None


def test_eventbrite_single_event_attaches_stubhub(client, monkeypatch):
    _dbf(monkeypatch, _rows_with_stubhub())
    ev = client.get("/api/eventbrite/event/E_CONN").json()
    assert ev["stubhub"]["entity_id"] == "161118309"
    assert ev["stubhub"]["min_price"] == 69.0
    assert ev["stubhub"]["url"] == "https://www.stubhub.com/event/161118309/"
    assert ev["stubhub"]["listings_detail"] is None      # connector search: no seat detail

    ev2 = client.get("/api/eventbrite/event/E_NONE").json()
    assert ev2["stubhub"] is None


def test_eventbrite_stubhub_listings_detail(client, monkeypatch):
    _dbf(monkeypatch, _rows_with_stubhub())
    ev = client.get("/api/eventbrite/event/E_FETCH").json()
    ld = ev["stubhub"]["listings_detail"]
    assert ld is not None and len(ld) == 2
    # normalized + sorted cheapest-first (the $55.81 GA row leads the $1050 row)
    assert ld[0]["price"] == 55.81 and ld[0]["section"] == "General Admission"
    assert ld[0]["quantity"] == 6 and ld[0]["note"] == "Standing room only (SRO)"
    assert ld[1]["price"] == 1050.75 and ld[1]["section"] == "GA Premium"
    assert ld[1]["note"] is None


def _detail_with_summary(client, monkeypatch, summary):
    _db(monkeypatch, [{"td_event_id": "1", "event_name": "x", "matched_tevo_event_id": None,
                       "raw": {"summary": summary}}])
    return client.get("/api/eventbrite/event/1").json()


def test_eventbrite_genre_parse_robustness(client, monkeypatch):
    # Real tail marker → the genre value only.
    assert _detail_with_summary(client, monkeypatch, "7pm • 16+ | Genre: Alternative")["genre"] == "Alternative"
    # An earlier "Genre:" mention in the blurb must not win over the tail marker.
    assert _detail_with_summary(
        client, monkeypatch, "A genre-bending night — Genre: bending | Genre: Electronic")["genre"] == "Electronic"
    # A substring like "SubGenre:" (no pipe marker) must not be picked up.
    assert _detail_with_summary(client, monkeypatch, "SubGenre: Indie vibes")["genre"] is None
    # No marker at all → None.
    assert _detail_with_summary(client, monkeypatch, "Just a show, no genre tag")["genre"] is None
