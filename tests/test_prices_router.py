"""Tests for routers/prices.py — the public /prices price tracker.

The router is built against a fake service-role client, so no DB or upstream
HTTP is touched. Covers: page shells, param validation, RPC param mapping,
the TTL cache, 404/502 handling, and the outbound-link shaping (https-only,
fixed order, primary vs resale).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
testclient = pytest.importorskip("fastapi.testclient")

from fastapi import FastAPI  # noqa: E402

from routers.prices import build_links, build_prices_router  # noqa: E402

STATIC_DIR = os.path.join(str(REPO_ROOT), "static")

EVENT = {
    "event": {"id": 3226757, "name": "Inter Miami CF at Atlanta United", "venue_id": 33372,
              "venue_name": "Mercedes-Benz Stadium", "venue_location": "Atlanta, GA",
              "performer_id": 51427, "performer_name": "Atlanta United",
              "occurs_at_local": "2026-10-17T19:30:00-04:00", "category": "mls"},
    "current": {"getin": 100, "captured_at": "2026-09-27T03:44:40+00:00", "prior_3d": 100,
                "change_3d_pct": 0, "tickets": 1324},
    "history": [[1780000000, 120], [1780100000, 100]],
    "zones": [],
    "weather": {"is_indoor": True},
    "forecast": {"direction": "flat", "dte_days": 4},
}


class _Q:
    def __init__(self, data=None, exc=None):
        self._data, self._exc = data, exc

    # table() chain
    def select(self, *a, **k):
        return self

    def eq(self, *a, **k):
        return self

    def limit(self, *a, **k):
        return self

    def execute(self):
        if self._exc:
            raise self._exc
        return type("R", (), {"data": self._data})()


class FakeDB:
    def __init__(self):
        self.calls = []
        self.responses = {}
        self.table_rows = []
        self.table_exc = None

    def rpc(self, fn, params):
        self.calls.append((fn, params))
        r = self.responses.get(fn)
        if isinstance(r, Exception):
            return _Q(exc=r)
        return _Q(data=r)

    def table(self, name):
        return _Q(data=self.table_rows, exc=self.table_exc)


@pytest.fixture
def db():
    return FakeDB()


@pytest.fixture
def client(db):
    app = FastAPI()
    app.include_router(build_prices_router(STATIC_DIR, get_require_sb=lambda: (lambda: db)))
    return testclient.TestClient(app)


# ---------- page shells ----------

@pytest.mark.parametrize("path,page", [
    ("/prices", 'data-page="home"'),
    ("/prices/event/123", 'data-page="event"'),
    ("/prices/performer/9", 'data-page="list"'),
    ("/prices/venue/9", 'data-page="list"'),
])
def test_pages_serve_shells(client, path, page):
    r = client.get(path)
    assert r.status_code == 200
    assert page in r.text
    assert "/static/prices/prices.js" in r.text
    assert r.headers["cache-control"].startswith("no-cache")


def test_page_rejects_non_numeric_id(client):
    assert client.get("/prices/event/abc").status_code == 422


# ---------- /api/prices/events ----------

def test_events_maps_params(client, db):
    db.responses["price_tracker_events"] = {"entity": None, "total": 1, "rows": [{"id": 1}]}
    r = client.get("/api/prices/events", params={
        "category": "nfl", "day_from": "2026-10-13", "day_to": "2026-10-20", "sort": "date", "limit": 50})
    assert r.status_code == 200
    assert r.json()["total"] == 1
    fn, params = db.calls[-1]
    assert fn == "price_tracker_events"
    assert params == {
        "p_performer_id": None, "p_venue_id": None, "p_category": "nfl", "p_when": "upcoming",
        "p_day_from": "2026-10-13", "p_day_to": "2026-10-20", "p_sort": "date", "p_limit": 50,
    }


@pytest.mark.parametrize("params", [
    {"category": "nope"}, {"when": "later"}, {"sort": "random"},
    {"day_from": "13/10/2026"}, {"limit": 0}, {"limit": 999}, {"venue_id": 0},
])
def test_events_validates(client, db, params):
    r = client.get("/api/prices/events", params=params)
    assert r.status_code in (400, 422)
    assert db.calls == []


def test_events_cached(client, db):
    db.responses["price_tracker_events"] = {"entity": None, "total": 0, "rows": []}
    client.get("/api/prices/events", params={"venue_id": 5})
    client.get("/api/prices/events", params={"venue_id": 5})
    assert len(db.calls) == 1
    client.get("/api/prices/events", params={"venue_id": 6})
    assert len(db.calls) == 2


def test_events_db_failure_is_502(client, db):
    db.responses["price_tracker_events"] = RuntimeError("boom")
    r = client.get("/api/prices/events")
    assert r.status_code == 502
    assert "boom" not in r.text


# ---------- /api/prices/event/{id} ----------

def test_event_payload_with_links(client, db):
    db.responses["price_tracker_event"] = EVENT
    db.responses["get_event_source_links"] = {
        "sg_url": "http://www.seatgeek.com/e/events/1",
        "td": {"SH": "https://www.stubhub.com/x/event/1/", "TM": "https://www.ticketmaster.com/e/1",
               "VD": "javascript:alert(1)"},
    }
    db.table_rows = [{"event_url": "https://www.axs.com/events/1"}]
    r = client.get("/api/prices/event/3226757")
    assert r.status_code == 200
    body = r.json()
    assert body["event"]["name"] == "Inter Miami CF at Atlanta United"
    keys = [l["key"] for l in body["links"]]
    assert keys == ["stubhub", "seatgeek", "ticketmaster", "axs"]  # vivid dropped (unsafe url)
    assert {l["key"]: l["kind"] for l in body["links"]}["ticketmaster"] == "primary"
    assert all(l["url"].startswith("https://") for l in body["links"])


def test_event_links_best_effort(client, db):
    db.responses["price_tracker_event"] = EVENT
    db.responses["get_event_source_links"] = RuntimeError("forbidden")
    r = client.get("/api/prices/event/3226757")
    assert r.status_code == 200
    assert r.json()["links"] == []


def test_event_cached_and_axs_failure_tolerated(client, db):
    db.responses["price_tracker_event"] = EVENT
    db.responses["get_event_source_links"] = {"td": {"VD": "https://www.vividseats.com/p/1"}}
    db.table_exc = RuntimeError("axs down")
    first = client.get("/api/prices/event/3226757").json()
    assert [l["key"] for l in first["links"]] == ["vivid"]
    n = len(db.calls)
    assert client.get("/api/prices/event/3226757").json() == first
    assert len(db.calls) == n


def test_event_404(client, db):
    db.responses["price_tracker_event"] = None
    assert client.get("/api/prices/event/42").status_code == 404


# ---------- /api/prices/search ----------

def test_search_short_query_skips_db(client, db):
    r = client.get("/api/prices/search", params={"q": " a "})
    assert r.json() == {"performers": [], "venues": [], "events": []}
    assert db.calls == []


def test_search_normalizes_and_caches(client, db):
    db.responses["price_tracker_search"] = {"performers": [{"id": 1, "name": "Atlanta United", "n": 3}],
                                            "venues": [], "events": []}
    client.get("/api/prices/search", params={"q": "  Atlanta   United "})
    client.get("/api/prices/search", params={"q": "atlanta united"})
    assert db.calls == [("price_tracker_search", {"p_q": "Atlanta United", "p_limit": 6})]


def test_search_too_long(client):
    assert client.get("/api/prices/search", params={"q": "x" * 200}).status_code == 422


# ---------- cache ----------

def test_ttl_cache_expiry_and_eviction(monkeypatch):
    from routers import prices as mod
    now = [1000.0]
    monkeypatch.setattr(mod.time, "monotonic", lambda: now[0])
    c = mod._TTLCache(ttl=10, max_items=2)
    c.put("a", 1)
    now[0] += 1
    c.put("b", 2)
    c.put("b", 3)          # overwrite at capacity does not evict
    assert c.get("a") == 1 and c.get("b") == 3
    now[0] += 1
    c.put("c", 4)          # evicts the oldest ("a")
    assert c.get("a") is None and c.get("c") == 4
    now[0] += 30
    assert c.get("b") is None  # expired


# ---------- link shaping ----------

def test_build_links_handles_empty():
    assert build_links(None) == []
    assert build_links({"td": {"ZZ": "https://x.test"}}) == []


def test_build_links_td_seatgeek_wins_over_sg_url():
    links = build_links({"sg_url": "https://seatgeek.com/a", "td": {"SG": "https://seatgeek.com/b"}})
    assert links == [{"key": "seatgeek", "name": "SeatGeek", "kind": "resale", "url": "https://seatgeek.com/b"}]


# ---------- wiring into the real app ----------

def test_server_mounts_prices_routes():
    os.environ.setdefault("TEVO_API_TOKEN", "test-token")
    os.environ.setdefault("TEVO_API_SECRET", "test-secret")
    os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
    os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
    os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
    os.environ.setdefault("AUTH_DISABLED", "true")
    import server
    c = testclient.TestClient(server.app)
    for path in ("/prices", "/prices/event/1", "/prices/performer/1", "/prices/venue/1"):
        assert c.get(path).status_code == 200
    # A <2-char search never reaches the DB, so it proves the API mount offline.
    assert c.get("/api/prices/search", params={"q": "a"}).json() == {
        "performers": [], "venues": [], "events": []}
