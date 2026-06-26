"""Line-coverage tests for the STORE-B slice of app.py.

Routes owned by this file (and the helpers they call):
  - GET /api/store/events/near                (hybrid / supabase / tevo / fallback)
  - GET /api/store/performers/{id}/trip-plan
  - GET /api/store/performers/{id}/tour-package
  - GET /api/store/tours/multi
  - GET /api/store/tours/near                 (+ _discover_payload delegate)
  - GET /api/store/events/{id}                (_resolve_event_with_filters, live + SQL-only)
  - GET /api/store/seatmap/{v}/{c}/manifest.json | map.svg | section-map
  - GET /api/store/events/{id}/zones

All TEvo + Supabase access is monkeypatched — NO real network/DB. The trip /
tour / multi / discover entrypoints are stubbed (they live outside this slice)
so the thin store routes that delegate to them are exercised without dragging
the optimizer in. The heavy lifting is on /events/near and /events/{id}, whose
helpers (_attach_owned_metadata, _resolve_event_with_filters, _fetch_event_
from_db, _fetch_owned_ticket_groups[_from_db], _build_zone_resolver,
_fire_canonical_refresh) are driven through their branches via a fluent
FakeSupabase + FakeEvoClient.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env BEFORE importing app (mirrors house style) ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

fastapi = pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# =====================================================================
# Fake Supabase — fluent query builder keyed by table name.
# =====================================================================

class _Result:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


class _Query:
    """Records filters; resolves .execute() via a per-table resolver callback.

    The resolver gets (table_name, filters_dict, count_flag) and returns either
    a list (data) or an (data, count) tuple.
    """

    def __init__(self, table, resolver, raise_on_execute=False):
        self._table = table
        self._resolver = resolver
        self._filters = {"_in": {}, "_gt": {}, "_eq": {}, "order": None,
                         "limit": None, "select": None, "count": None}
        self._raise = raise_on_execute

    def select(self, cols, count=None):
        self._filters["select"] = cols
        self._filters["count"] = count
        return self

    def eq(self, col, val):
        self._filters["_eq"][col] = val
        return self

    def gt(self, col, val):
        self._filters["_gt"][col] = val
        return self

    def in_(self, col, vals):
        self._filters["_in"][col] = list(vals)
        return self

    def order(self, col, desc=False):
        self._filters["order"] = (col, desc)
        return self

    def limit(self, n):
        self._filters["limit"] = n
        return self

    def insert(self, payload):
        self._filters["insert"] = payload
        return self

    def execute(self):
        if self._raise:
            raise RuntimeError("supabase boom")
        out = self._resolver(self._table, self._filters)
        if isinstance(out, _Result):
            return out
        if isinstance(out, tuple):
            return _Result(out[0], out[1])
        return _Result(out)


class FakeSupabase:
    """Resolver-driven Supabase double.

    table_resolvers: {table_name: callable(filters)->data|(data,count)|_Result}
    rpc_resolvers:   {rpc_name: callable(params)->data}
    Anything not registered returns []/None. Set raise_tables to force
    .execute() to raise for a given table (covers except: branches).
    """

    def __init__(self, table_resolvers=None, rpc_resolvers=None, raise_tables=None):
        self.table_resolvers = table_resolvers or {}
        self.rpc_resolvers = rpc_resolvers or {}
        self.raise_tables = set(raise_tables or [])
        self.inserts = []

    def table(self, name):
        def resolver(table_name, filters):
            if "insert" in filters:
                self.inserts.append((table_name, filters["insert"]))
            fn = self.table_resolvers.get(table_name)
            return fn(filters) if fn else []
        return _Query(name, resolver, raise_on_execute=(name in self.raise_tables))

    def rpc(self, name, params=None):
        class _RpcQuery:
            def __init__(self, outer):
                self._outer = outer

            def execute(self_inner):
                fn = self.rpc_resolvers.get(name)
                if fn is None:
                    return _Result(None)
                return _Result(fn(params or {}))
        return _RpcQuery(self)


class FakeEvoClient:
    """Replaces app.client. list_events / get_event / get_ticket_groups
    are programmable; any of them can be set to raise RuntimeError."""

    def __init__(self, events=None, event=None, ticket_groups=None,
                 list_raises=False, event_raises=None, tg_raises=False):
        self._events = events or []
        self._event = event
        self._ticket_groups = ticket_groups or []
        self.list_raises = list_raises
        self.event_raises = event_raises
        self.tg_raises = tg_raises
        self.list_calls = []

    def list_events(self, **kwargs):
        self.list_calls.append(kwargs)
        if self.list_raises:
            raise RuntimeError("TEvo geo down")
        return {"events": self._events}

    def get_event(self, event_id):
        if self.event_raises:
            raise RuntimeError(self.event_raises)
        return self._event

    def get_ticket_groups(self, event_id, owned=True):
        if self.tg_raises:
            raise RuntimeError("TEvo tg down")
        return {"ticket_groups": self._ticket_groups}


@pytest.fixture
def client():
    return TestClient(app_module.app)


@pytest.fixture(autouse=True)
def _isolate(monkeypatch):
    """Default: SQL-only OFF, prefer-internal OFF, branded-asset bulk calls
    stubbed to empty, fire-and-forget refresh neutralized. Individual tests
    override as needed."""
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "STOREFRONT_PREFER_INTERNAL_ZONES", False)
    monkeypatch.setattr(app_module, "_bulk_performer_assets", lambda db, pids: {})
    monkeypatch.setattr(app_module, "_bulk_event_context", lambda db, ids: {})
    # _fire_canonical_refresh spawns a daemon thread that would hit the network;
    # neutralize by default (a dedicated test exercises its own logic).
    monkeypatch.setattr(app_module, "_fire_canonical_refresh", lambda eid, ev: None)
    # The per-IP rate limiter (_ip_limiter) is a module-global whose hit deque
    # accumulates across the WHOLE pytest session — every other test module that
    # hits /api/store/* shares the same 'testclient' IP bucket. Without a reset
    # this module trips the 60/min /api/store/ cap and returns 429. Clear it
    # before each test so these run deterministically in the full suite.
    app_module._ip_limiter._hits.clear()
    yield


# =====================================================================
# /api/store/events/near
# =====================================================================

def _near_tables(owned_ids, events_by_id, coords=None, lifecycle=None,
                 metrics_extra=None):
    coords = coords or {}
    lifecycle = lifecycle or {}

    def latest_event_metrics(f):
        # Used in two shapes: select event_id only (supabase candidate pull)
        # and select metrics (in _attach_owned_metadata).
        sel = f["select"] or ""
        if "owned_tickets_count" in sel and "event_id" in sel and "," in sel:
            ids = f["_in"].get("event_id", owned_ids)
            return [
                {"event_id": i, "owned_tickets_count": 5,
                 "owned_groups_count": 2, "retail_min": 120.0,
                 **(metrics_extra or {})}
                for i in ids if i in owned_ids
            ]
        # candidate pull (select event_id, gt owned_tickets_count)
        return [{"event_id": i} for i in owned_ids]

    def events(f):
        ids = f["_in"].get("id", list(events_by_id))
        return [events_by_id[i] for i in ids if i in events_by_id]

    def event_lifecycle(f):
        ids = f["_in"].get("event_id", [])
        return [{"event_id": i, "is_active": lifecycle.get(i, True)} for i in ids]

    def venue_assets(f):
        vids = f["_in"].get("tevo_venue_id", [])
        return [{"tevo_venue_id": v, "latitude": coords[v][0],
                 "longitude": coords[v][1]} for v in vids if v in coords]

    return {
        "latest_event_metrics": latest_event_metrics,
        "events": events,
        "event_lifecycle": event_lifecycle,
        "venue_assets": venue_assets,
    }


def test_near_hybrid_happy_path(client, monkeypatch):
    evs = {
        1: {"id": 1, "name": "Knicks", "occurs_at_local": "x", "venue_id": 896,
            "venue_name": "MSG", "venue_location": "NY", "primary_performer_id": 10,
            "primary_performer_name": "NYK"},
        2: {"id": 2, "name": "Nets", "occurs_at_local": "y", "venue_id": 900,
            "venue_name": "Barclays", "venue_location": "NY",
            "primary_performer_id": 11, "primary_performer_name": "BKN"},
    }
    # venue 896 has coords (near), 900 has none (distance null → sorts last)
    sb = FakeSupabase(_near_tables([1, 2], evs, coords={896: (40.75, -73.99)}))
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client",
                        FakeEvoClient(events=[{"id": 1}, {"id": 2}, {"id": None}]))
    r = client.get("/api/store/events/near?lat=40.75&lon=-73.99&within=100&limit=10")
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "hybrid"
    assert body["tevo_candidates"] == 2
    ids = [e["id"] for e in body["events"]]
    assert ids[0] == 1  # has distance → sorts first
    assert body["events"][-1]["distance_miles"] is None


def test_near_hybrid_falls_back_to_supabase_on_tevo_error(client, monkeypatch):
    evs = {1: {"id": 1, "name": "A", "occurs_at_local": "x", "venue_id": 896,
               "venue_name": "MSG", "venue_location": "NY",
               "primary_performer_id": 10, "primary_performer_name": "NYK"}}
    sb = FakeSupabase(_near_tables([1], evs, coords={896: (40.75, -73.99)}))
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(list_raises=True))
    r = client.get("/api/store/events/near?lat=40.75&lon=-73.99&within=100")
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "supabase"  # fell through
    assert body["supabase_candidates"] == 1
    assert body["events"][0]["id"] == 1


def test_near_supabase_mode_filters_radius_and_missing_coords(client, monkeypatch):
    evs = {
        1: {"id": 1, "name": "near", "occurs_at_local": "x", "venue_id": 896,
            "venue_name": "MSG", "venue_location": "NY",
            "primary_performer_id": 10, "primary_performer_name": "A"},
        2: {"id": 2, "name": "far", "occurs_at_local": "y", "venue_id": 901,
            "venue_name": "Far", "venue_location": "CA",
            "primary_performer_id": 11, "primary_performer_name": "B"},
        3: {"id": 3, "name": "nocoord", "occurs_at_local": "z", "venue_id": 902,
            "venue_name": "Q", "venue_location": "?",
            "primary_performer_id": 12, "primary_performer_name": "C"},
    }
    coords = {896: (40.75, -73.99), 901: (34.05, -118.24)}  # 902 missing
    sb = FakeSupabase(_near_tables([1, 2, 3], evs, coords=coords))
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient())
    r = client.get("/api/store/events/near?lat=40.75&lon=-73.99&within=50&source=supabase")
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "supabase"
    # Only the near event is within 50mi; far + nocoord excluded.
    assert [e["id"] for e in body["events"]] == [1]
    assert body["missing_coords"] == 1


def test_near_tevo_debug_mode(client, monkeypatch):
    monkeypatch.setattr(app_module, "client", FakeEvoClient(events=[
        {"id": 5, "name": "X", "occurs_at_local": "t",
         "venue": {"name": "V", "location": "L"}},
    ]))
    r = client.get("/api/store/events/near?lat=1&lon=2&source=tevo")
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "tevo"
    assert body["count"] == 1
    assert body["events"][0]["venue_name"] == "V"
    assert body["events"][0]["distance_miles"] is None


def test_near_tevo_debug_mode_upstream_error_502(client, monkeypatch):
    monkeypatch.setattr(app_module, "client", FakeEvoClient(list_raises=True))
    r = client.get("/api/store/events/near?lat=1&lon=2&source=tevo")
    assert r.status_code == 502


def test_near_sql_only_forces_supabase(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", True)
    evs = {1: {"id": 1, "name": "A", "occurs_at_local": "x", "venue_id": 896,
               "venue_name": "MSG", "venue_location": "NY",
               "primary_performer_id": 10, "primary_performer_name": "A"}}
    sb = FakeSupabase(_near_tables([1], evs, coords={896: (40.75, -73.99)}))
    monkeypatch.setattr(app_module, "sb", sb)
    # client would raise if touched — proves SQL-only never calls TEvo.
    monkeypatch.setattr(app_module, "client", FakeEvoClient(list_raises=True))
    r = client.get("/api/store/events/near?lat=40.75&lon=-73.99&source=hybrid")
    assert r.status_code == 200
    assert r.json()["source"] == "supabase"


def test_near_attach_owned_metadata_empty_and_lifecycle(client, monkeypatch):
    # candidate ids exist but none owned → _attach returns [] (no metrics_rows).
    evs = {}
    sb = FakeSupabase(_near_tables([], evs))
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(events=[{"id": 99}]))
    r = client.get("/api/store/events/near?lat=1&lon=2&source=hybrid")
    assert r.status_code == 200
    assert r.json()["count"] == 0


def test_near_inactive_event_dropped(client, monkeypatch):
    evs = {1: {"id": 1, "name": "dead", "occurs_at_local": "x", "venue_id": 896,
               "venue_name": "MSG", "venue_location": "NY",
               "primary_performer_id": 10, "primary_performer_name": "A"}}
    sb = FakeSupabase(_near_tables([1], evs, coords={896: (40.75, -73.99)},
                                   lifecycle={1: False}))
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(events=[{"id": 1}]))
    r = client.get("/api/store/events/near?lat=40.75&lon=-73.99&source=supabase")
    assert r.status_code == 200
    assert r.json()["count"] == 0  # inactive filtered by _attach_owned_metadata


def test_near_lifecycle_and_coords_query_raise(client, monkeypatch):
    # event_lifecycle + venue_assets raise → except branches set inactive=set()
    # / coord_map={}. Event survives but distance is null.
    evs = {1: {"id": 1, "name": "A", "occurs_at_local": "x", "venue_id": 896,
               "venue_name": "MSG", "venue_location": "NY",
               "primary_performer_id": 10, "primary_performer_name": "A"}}
    sb = FakeSupabase(_near_tables([1], evs, coords={896: (40.75, -73.99)}),
                      raise_tables={"event_lifecycle", "venue_assets"})
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(events=[{"id": 1}]))
    r = client.get("/api/store/events/near?lat=40.75&lon=-73.99&source=hybrid")
    assert r.status_code == 200
    assert r.json()["events"][0]["distance_miles"] is None


# =====================================================================
# trip-plan / tour-package / tours/multi / tours/near (thin delegates)
# =====================================================================

def test_trip_plan_delegates(client, monkeypatch):
    captured = {}
    def fake(*args):
        captured["args"] = args
        return {"plan": "ok"}
    monkeypatch.setattr(app_module, "_trip_plan_payload", fake)
    r = client.get("/api/store/performers/42/trip-plan?home_lat=40&home_lon=-73&qty=2")
    assert r.status_code == 200
    assert r.json() == {"plan": "ok"}
    assert captured["args"][0] == 42  # performer_id


def test_tour_package_delegates(client, monkeypatch):
    monkeypatch.setattr(app_module, "_tour_package_payload",
                        lambda *a, **k: {"package": "ok"})
    r = client.get("/api/store/performers/7/tour-package?qty=3&budget_usd=500")
    assert r.status_code == 200
    assert r.json() == {"package": "ok"}


def test_multi_tour_delegates(client, monkeypatch):
    monkeypatch.setattr(app_module, "_multi_tour_payload",
                        lambda *a, **k: {"multi": "ok"})
    r = client.get("/api/store/tours/multi?performer_ids=1,2,3&home_lat=40&home_lon=-73")
    assert r.status_code == 200
    assert r.json() == {"multi": "ok"}


def test_tours_near_delegates(client, monkeypatch):
    captured = {}
    def fake(*a, **k):
        captured["kwargs"] = k
        return {"discover": "ok"}
    monkeypatch.setattr(app_module, "_discover_payload", fake)
    r = client.get("/api/store/tours/near?home_lat=40&home_lon=-73&min_shows=3")
    assert r.status_code == 200
    assert r.json() == {"discover": "ok"}
    assert captured["kwargs"].get("team_side") == "away"


# =====================================================================
# /api/store/events/{event_id}  (live mode via _resolve_event_with_filters)
# =====================================================================

def _live_event(event_id=3346000):
    return {
        "id": event_id,
        "name": "Knicks vs Nets",
        "occurs_at": "2026-06-01T19:00:00Z",
        "occurs_at_local": "2026-06-01T19:00:00-04:00",
        "venue": {"id": 896, "name": "MSG", "location": "New York, NY",
                  "time_zone": "America/New_York"},
        "configuration": {"id": 14341, "name": "Basketball",
                          "seating_chart": {"medium": "https://x/m.jpg",
                                            "large": "https://x/l.jpg"}},
        "performances": [
            {"primary": True, "performer": {"id": 10, "name": "NYK"}},
            {"primary": False, "performer": {"id": 11, "name": "Series Tag"}},
        ],
    }


def _tg(tgid, section="100", row="A", price=120.0, qty=2, ttype="event",
        splits=None):
    return {
        "id": tgid, "type": ttype, "section": section, "row": row,
        "retail_price": price, "quantity": qty, "available_quantity": qty,
        "format": "Eticket", "splits": splits if splits is not None else [1, 2],
        "wheelchair": False, "instant_delivery": True, "eticket": True,
    }


def _event_detail_sb(asset_bundle_rows=None, venue_assets_rows=None,
                     raise_tables=None):
    def resolver_factory(rows):
        return lambda f: rows
    tr = {
        "v_event_seating_chart": resolver_factory(asset_bundle_rows or []),
        "venue_assets": resolver_factory(venue_assets_rows or []),
    }
    return FakeSupabase(tr, raise_tables=raise_tables)


def test_event_detail_live_full(client, monkeypatch):
    sb = _event_detail_sb(
        asset_bundle_rows=[{
            "configuration_id": 14341, "configuration_name": "Basketball",
            "seating_chart_medium": "https://x/m.jpg",
            "seating_chart_large": "https://x/l.jpg",
            "fanvenues_key": "fv1", "venue_hero_url": "https://x/hero.jpg",
            "venue_map_url": None, "venue_capacity": 20000,
            "venue_is_indoor": True, "team_color_primary": "1d428a",
            "team_color_alternate": None, "team_logo_url": "https://x/logo.png",
            "team_logo_dark_url": None, "team_espn_url": None,
        }],
        venue_assets_rows=[{
            "latitude": 40.75, "longitude": -73.99, "city": "New York",
            "state": "NY", "country": "US", "espn_venue_id": 5,
            "espn_venue_name": "MSG",
        }],
    )
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "_bulk_performer_assets",
                        lambda db, pids: {10: {"logo_default_url": "https://x/p.png",
                                               "color_primary": "abc"}})
    monkeypatch.setattr(app_module, "_bulk_event_context",
                        lambda db, ids: {ids[0]: {"rivalry": "Battle of NY"}})
    # cache miss → live fetch; capture cache writes via rpc resolver
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(),
        ticket_groups=[
            _tg(1, "100", "A", 120.0),
            _tg(2, "Floor", "1", 500.0),
            _tg(3, "P1", "-", 40.0, ttype="parking"),
            _tg(9, "X", "Y", 0.0, qty=0),  # zero qty → filtered out
        ],
    ))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    body = r.json()
    assert body["event"]["id"] == 3346000
    assert body["event"]["venue"]["latitude"] == 40.75
    assert body["event"]["configuration"]["fanvenues_key"] == "fv1"
    assert body["listings_count"] == 2  # two event-type seats, parking separate
    assert body["parking_count"] == 1
    assert body["inventory_source"] == "live"
    assert body["context"]["rivalry"] == "Battle of NY"
    # series-tag performer (no logo/color, non-primary) dropped
    assert [p["id"] for p in body["event"]["performers"]] == [10]
    # sections_available + splits_available populated
    assert "Floor" in body["sections_available"]
    assert body["splits_available"]


def test_event_detail_live_cache_hit(client, monkeypatch):
    sb = _event_detail_sb()
    # rpc get_cached_ticket_groups returns fresh payload → 'cache' source
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    sb.rpc_resolvers["get_cached_ticket_groups"] = lambda p: {
        "ticket_groups": [_tg(1, "100", "A", 120.0)],
        "captured_at": now,
    }
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), tg_raises=True))  # live would raise if reached
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    assert r.json()["inventory_source"] == "cache"


def test_event_detail_live_cache_stale_falls_through_to_live(client, monkeypatch):
    sb = _event_detail_sb()
    sb.rpc_resolvers["get_cached_ticket_groups"] = lambda p: {
        "ticket_groups": [_tg(1)],
        "captured_at": "2000-01-01T00:00:00+00:00",  # ancient → stale
    }
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), ticket_groups=[_tg(2, "200", "B", 99.0)]))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    assert r.json()["inventory_source"] == "live"


def test_event_detail_live_cache_bad_timestamp(client, monkeypatch):
    sb = _event_detail_sb()
    sb.rpc_resolvers["get_cached_ticket_groups"] = lambda p: {
        "ticket_groups": [_tg(1)],
        "captured_at": "not-a-date",  # ValueError → payload_age_ok=False
    }
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), ticket_groups=[_tg(2)]))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    assert r.json()["inventory_source"] == "live"


def test_event_detail_live_cache_missing_captured_at(client, monkeypatch):
    sb = _event_detail_sb()
    sb.rpc_resolvers["get_cached_ticket_groups"] = lambda p: {
        "ticket_groups": [_tg(1)],  # no captured_at key → payload_age_ok=False
    }
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), ticket_groups=[_tg(2)]))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    assert r.json()["inventory_source"] == "live"


def test_event_detail_live_rpc_raises_then_live(client, monkeypatch):
    # get_cached_ticket_groups raises → except: pass → live path.
    sb = _event_detail_sb()
    def boom(p):
        raise RuntimeError("rpc down")
    sb.rpc_resolvers["get_cached_ticket_groups"] = boom
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), ticket_groups=[_tg(1)]))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    assert r.json()["inventory_source"] == "live"


def test_event_detail_live_event_not_found_404(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", _event_detail_sb())
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event_raises="TEvo API 404 not found"))
    r = client.get("/api/store/events/123")
    assert r.status_code == 404


def test_event_detail_live_tg_fetch_fails_502(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", _event_detail_sb())
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), tg_raises=True))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 502


def test_event_detail_filters_section_price_qty_zone(client, monkeypatch):
    sb = _event_detail_sb()
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(),
        ticket_groups=[
            _tg(1, "100", "A", 120.0, splits=[2]),
            _tg(2, "100", "B", 300.0, splits=[4]),
            _tg(3, "200", "C", 50.0, splits=[1]),
        ],
    ))
    # zone resolver returns "Lower (100s)" for section 100, None otherwise
    monkeypatch.setattr(app_module, "match_performer_zone", None, raising=False)
    def fake_resolver(perf_id, venue_id):
        return lambda section, row: "Lower (100s)" if str(section) == "100" else None
    monkeypatch.setattr(app_module, "_build_zone_resolver", fake_resolver)
    r = client.get("/api/store/events/3346000"
                   "?section=100&min_price=100&max_price=250&min_qty=2&zones=lower (100s)")
    assert r.status_code == 200
    body = r.json()
    ids = [l["id"] for l in body["listings"]]
    # section=100 keeps 1,2; min_price>=100 keeps 1,2; max_price<=250 keeps 1;
    # min_qty=2 split keeps 1; zone 'lower (100s)' keeps 1.
    assert ids == [1]
    assert body["listings"][0]["zone"] == "Lower (100s)"


def test_event_detail_min_qty_no_splits_uses_available(client, monkeypatch):
    # A listing with empty splits is gated by available_quantity (covers the
    # no-splits branch of _meets).
    sb = _event_detail_sb()
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(),
        ticket_groups=[
            _tg(1, "100", "A", 120.0, qty=4, splits=[]),  # avail 4 >= 3 → kept
            _tg(2, "200", "B", 90.0, qty=1, splits=[]),   # avail 1 < 3 → dropped
        ],
    ))
    r = client.get("/api/store/events/3346000?min_qty=3")
    assert r.status_code == 200
    assert [l["id"] for l in r.json()["listings"]] == [1]


def test_event_detail_put_cache_rpc_raises(client, monkeypatch):
    # Live path writes the cache via put_cached_ticket_groups; if that rpc
    # raises it's swallowed (except: pass) and the response still renders live.
    sb = _event_detail_sb()
    def boom(p):
        raise RuntimeError("put cache down")
    sb.rpc_resolvers["put_cached_ticket_groups"] = boom
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), ticket_groups=[_tg(1)]))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    assert r.json()["inventory_source"] == "live"


def test_event_detail_asset_bundle_and_venue_assets_raise(client, monkeypatch):
    sb = _event_detail_sb(raise_tables={"v_event_seating_chart", "venue_assets"})
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), ticket_groups=[_tg(1)]))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    # falls back to inline config; both except branches taken
    assert r.json()["event"]["configuration"]["id"] == 14341


def test_event_detail_sb_none_no_context(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), ticket_groups=[_tg(1)]))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200
    body = r.json()
    assert body["context"]["rivalry"] is None  # _empty_ctx path
    assert body["inventory_source"] == "live"


def test_event_detail_bulk_assets_raise(client, monkeypatch):
    sb = _event_detail_sb()
    monkeypatch.setattr(app_module, "sb", sb)
    def boom(db, pids):
        raise RuntimeError("assets down")
    monkeypatch.setattr(app_module, "_bulk_performer_assets", boom)
    monkeypatch.setattr(app_module, "client", FakeEvoClient(
        event=_live_event(), ticket_groups=[_tg(1)]))
    r = client.get("/api/store/events/3346000")
    assert r.status_code == 200  # perf_assets={} on failure, still renders


# =====================================================================
# /api/store/events/{event_id}  (SQL-only mode → _fetch_event_from_db etc.)
# =====================================================================

def _sql_only_sb(event_row=None, perf_meta=None, snapshot_latest=None,
                 snapshot_rows=None, raise_tables=None):
    def events(f):
        return [event_row] if event_row else []

    def performer_metadata(f):
        return perf_meta or []

    def listings_snapshots(f):
        # latest captured_at query has order set + limit 1
        if f.get("order"):
            return snapshot_latest or []
        return snapshot_rows or []

    tr = {
        "events": events,
        "performer_metadata": performer_metadata,
        "listings_snapshots": listings_snapshots,
        "v_event_seating_chart": lambda f: [],
        "venue_assets": lambda f: [],
    }
    return FakeSupabase(tr, raise_tables=raise_tables)


def test_event_detail_sql_only_full(client, monkeypatch):
    from datetime import datetime, timezone
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", True)
    captured = datetime.now(timezone.utc).isoformat()
    sb = _sql_only_sb(
        event_row={
            "id": 555, "name": "Demo Game", "occurs_at_local": "2026-06-01T19:00:00-04:00",
            "state": "active", "venue_id": 896, "venue_name": "MSG",
            "venue_location": "New York, NY", "primary_performer_id": 10,
            "primary_performer_name": "NYK", "performer_ids": [10, 11, 12],
        },
        perf_meta=[{"performer_id": 11, "name": "BKN"}],  # 12 unnamed → dropped
        snapshot_latest=[{"captured_at": captured}],
        snapshot_rows=[{
            "tevo_ticket_group_id": 1, "section": "100", "row": "A",
            "quantity": 2, "retail_price": 120.0, "format": "Eticket",
            "splits": [1, 2], "wheelchair": False, "instant_delivery": True,
            "eticket": True, "is_ancillary": False, "type": "event",
            "is_owned": True,
        }],
    )
    monkeypatch.setattr(app_module, "sb", sb)
    monkeypatch.setattr(app_module, "client", FakeEvoClient())  # untouched
    r = client.get("/api/store/events/555")
    assert r.status_code == 200
    body = r.json()
    assert body["inventory_source"] == "snapshot"
    assert body["demo_mode"] is True
    assert body["snapshot_age_seconds"] is not None
    assert body["listings_count"] == 1
    # secondary performer 11 named; 12 unnamed dropped. primary=10.
    perf_ids = {p["id"] for p in body["event"]["performers"]}
    assert 10 in perf_ids


def test_event_detail_sql_only_not_found_404(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", True)
    sb = _sql_only_sb(event_row=None)
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/999")
    assert r.status_code == 404


def test_event_detail_sql_only_no_snapshots(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", True)
    sb = _sql_only_sb(
        event_row={
            "id": 7, "name": "E", "occurs_at_local": "x", "state": "active",
            "venue_id": 896, "venue_name": "MSG", "venue_location": "NY",
            "primary_performer_id": 10, "primary_performer_name": "NYK",
            "performer_ids": [10],
        },
        snapshot_latest=[],  # no listings → groups=[], captured=None
    )
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/7")
    assert r.status_code == 200
    body = r.json()
    assert body["listings_count"] == 0
    assert body["snapshot_age_seconds"] is None  # no captured_at


def test_event_detail_sql_only_bad_captured_at(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", True)
    sb = _sql_only_sb(
        event_row={
            "id": 8, "name": "E", "occurs_at_local": "x", "state": "active",
            "venue_id": 896, "venue_name": "MSG", "venue_location": "NY",
            "primary_performer_id": 10, "primary_performer_name": "NYK",
            "performer_ids": [10],
        },
        snapshot_latest=[{"captured_at": "not-a-date"}],
        snapshot_rows=[],
    )
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/8")
    assert r.status_code == 200
    assert r.json()["snapshot_age_seconds"] is None  # ValueError branch


def test_event_detail_sql_only_no_secondary_performers(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", True)
    sb = _sql_only_sb(
        event_row={
            "id": 9, "name": "Solo", "occurs_at_local": "x", "state": "active",
            "venue_id": 896, "venue_name": "MSG", "venue_location": "NY",
            "primary_performer_id": 10, "primary_performer_name": "NYK",
            "performer_ids": [10],  # only primary → other_ids empty
        },
        snapshot_latest=[],
    )
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/9")
    assert r.status_code == 200


# =====================================================================
# _fire_canonical_refresh (drive directly — synchronous _go via fake thread)
# =====================================================================

# The autouse _isolate fixture stubs app_module._fire_canonical_refresh to a
# no-op so event-detail tests don't spawn threads. These direct tests grab the
# REAL function from the module's __dict__-independent reference captured at
# import time, so the stub doesn't shadow what we're trying to cover.
_REAL_FIRE_CANONICAL_REFRESH = app_module._fire_canonical_refresh


class _SyncThread:
    """Runs target() synchronously so the daemon body is covered + assertable."""
    def __init__(self, target=None, daemon=None):
        self._target = target

    def start(self):
        self._target()


def test_fire_canonical_refresh_existing_event(monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module.threading, "Thread", _SyncThread)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x")
    monkeypatch.setattr(app_module, "CRON_SECRET", "sek")
    fired = {}
    monkeypatch.setattr(app_module, "_fire_collect",
                        lambda url, secret: fired.update(url=url))
    sb = FakeSupabase({"events": lambda f: [{"id": 1}]})  # event exists
    monkeypatch.setattr(app_module, "sb", sb)
    _REAL_FIRE_CANONICAL_REFRESH(1, {})
    assert "event_id=1" in fired["url"]


def test_fire_canonical_refresh_auto_track_new_event(monkeypatch):
    monkeypatch.setattr(app_module.threading, "Thread", _SyncThread)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x")
    monkeypatch.setattr(app_module, "CRON_SECRET", "sek")
    fired = {}
    monkeypatch.setattr(app_module, "_fire_collect",
                        lambda url, secret: fired.update(url=url))

    def events(f):
        return []  # not tracked → auto-track path

    def watchlist(f):
        if "insert" in f:
            return [{"id": 77}]
        return []
    sb = FakeSupabase({"events": events, "watchlist": watchlist})
    monkeypatch.setattr(app_module, "sb", sb)
    ev = {"performances": [{"primary": True,
                            "performer": {"id": 10, "name": "NYK"}}]}
    _REAL_FIRE_CANONICAL_REFRESH(42, ev)
    assert "watchlist_id=77" in fired["url"]


def test_fire_canonical_refresh_no_config_noop(monkeypatch):
    # Missing CRON_SECRET → early return, no thread.
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x")
    monkeypatch.setattr(app_module, "CRON_SECRET", "")
    sb = FakeSupabase({})
    monkeypatch.setattr(app_module, "sb", sb)
    _REAL_FIRE_CANONICAL_REFRESH(1, {})  # returns without error


def test_fire_canonical_refresh_events_lookup_raises(monkeypatch):
    monkeypatch.setattr(app_module.threading, "Thread", _SyncThread)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x")
    monkeypatch.setattr(app_module, "CRON_SECRET", "sek")
    sb = FakeSupabase({}, raise_tables={"events"})
    monkeypatch.setattr(app_module, "sb", sb)
    _REAL_FIRE_CANONICAL_REFRESH(1, {})  # except branch logs + returns


def test_fire_canonical_refresh_no_primary_performer(monkeypatch):
    monkeypatch.setattr(app_module.threading, "Thread", _SyncThread)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x")
    monkeypatch.setattr(app_module, "CRON_SECRET", "sek")
    sb = FakeSupabase({"events": lambda f: []})  # new event
    monkeypatch.setattr(app_module, "sb", sb)
    # performances empty → primary {} → pid None → skip
    _REAL_FIRE_CANONICAL_REFRESH(1, {"performances": []})


def test_fire_canonical_refresh_duplicate_watchlist(monkeypatch):
    monkeypatch.setattr(app_module.threading, "Thread", _SyncThread)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x")
    monkeypatch.setattr(app_module, "CRON_SECRET", "sek")
    fired = {}
    monkeypatch.setattr(app_module, "_fire_collect",
                        lambda url, secret: fired.update(url=url))

    state = {"insert_done": False}

    class _DupWatchlistQuery(_Query):
        pass

    def events(f):
        return []

    def watchlist(f):
        if "insert" in f:
            raise RuntimeError("duplicate key value violates unique constraint 23505")
        # select id after dup → return existing
        return [{"id": 88}]
    sb = FakeSupabase({"events": events, "watchlist": watchlist})
    monkeypatch.setattr(app_module, "sb", sb)
    ev = {"performances": [{"primary": True, "performer": {"id": 5, "name": "X"}}]}
    _REAL_FIRE_CANONICAL_REFRESH(99, ev)
    assert "watchlist_id=88" in fired["url"]


def test_fire_canonical_refresh_insert_other_error(monkeypatch):
    monkeypatch.setattr(app_module.threading, "Thread", _SyncThread)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x")
    monkeypatch.setattr(app_module, "CRON_SECRET", "sek")
    called = {"fire": False}
    monkeypatch.setattr(app_module, "_fire_collect",
                        lambda url, secret: called.update(fire=True))

    def events(f):
        return []

    def watchlist(f):
        if "insert" in f:
            raise RuntimeError("some other db error")  # not a dup → logged, no id
        return []
    sb = FakeSupabase({"events": events, "watchlist": watchlist})
    monkeypatch.setattr(app_module, "sb", sb)
    ev = {"performances": [{"primary": True, "performer": {"id": 5, "name": "X"}}]}
    _REAL_FIRE_CANONICAL_REFRESH(99, ev)
    assert called["fire"] is False  # no watchlist_id → no collect kick


def test_fire_canonical_refresh_dup_lookup_raises(monkeypatch):
    monkeypatch.setattr(app_module.threading, "Thread", _SyncThread)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x")
    monkeypatch.setattr(app_module, "CRON_SECRET", "sek")

    calls = {"n": 0}

    def events(f):
        return []

    def watchlist(f):
        if "insert" in f:
            raise RuntimeError("duplicate 23505")
        calls["n"] += 1
        raise RuntimeError("lookup after dup failed")
    sb = FakeSupabase({"events": events, "watchlist": watchlist})
    # watchlist select must raise too; route raises via raise_tables won't apply
    # to insert. Use the resolver raising directly above.
    monkeypatch.setattr(app_module, "sb", sb)
    ev = {"performances": [{"primary": True, "performer": {"id": 5, "name": "X"}}]}
    _REAL_FIRE_CANONICAL_REFRESH(99, ev)


# =====================================================================
# _build_zone_resolver (direct)
# =====================================================================

def test_build_zone_resolver_noop_when_missing(monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    resolve = app_module._build_zone_resolver(10, 896)
    assert resolve("100", "A") is None


def test_build_zone_resolver_caches_and_handles_errors(monkeypatch):
    calls = {"n": 0}

    def match_zone(params):
        calls["n"] += 1
        return "Lower (100s)" if params["p_section"] == "100" else 123  # non-str → None
    sb = FakeSupabase(rpc_resolvers={"match_performer_zone": match_zone})
    monkeypatch.setattr(app_module, "sb", sb)
    resolve = app_module._build_zone_resolver(10, 896)
    assert resolve("100", "A") == "Lower (100s)"
    assert resolve("100", "A") == "Lower (100s)"  # cached → no 2nd rpc
    assert calls["n"] == 1
    assert resolve("200", "B") is None  # non-str data → None


def test_build_zone_resolver_rpc_raises(monkeypatch):
    class _BoomSB:
        def rpc(self, name, params):
            class _Q:
                def execute(self_inner):
                    raise RuntimeError("rpc down")
            return _Q()
    monkeypatch.setattr(app_module, "sb", _BoomSB())
    resolve = app_module._build_zone_resolver(10, 896)
    assert resolve("100", "A") is None  # except → cached None


# =====================================================================
# /api/store/seatmap/{venue}/{config}/manifest.json | map.svg
# =====================================================================

class _FakeResp:
    def __init__(self, status_code=200, json_body=None, content=b"", is_json=True):
        self.status_code = status_code
        self._json = json_body
        self.content = content
        self._is_json = is_json

    @property
    def ok(self):
        return 200 <= self.status_code < 300

    def json(self):
        if not self._is_json:
            raise ValueError("not JSON")
        return self._json


def _stub_requests_get(monkeypatch, resp):
    def fake_get(url, *a, **k):
        return resp
    monkeypatch.setattr(app_module.requests, "get", fake_get)


def test_seatmap_manifest_ok(client, monkeypatch):
    _stub_requests_get(monkeypatch, _FakeResp(200, json_body={"sections": {}}))
    r = client.get("/api/store/seatmap/896/14341/manifest.json")
    assert r.status_code == 200
    assert "max-age=86400" in r.headers.get("cache-control", "")


def test_seatmap_manifest_not_json_502(client, monkeypatch):
    _stub_requests_get(monkeypatch, _FakeResp(200, is_json=False))
    r = client.get("/api/store/seatmap/896/14341/manifest.json")
    assert r.status_code == 502


def test_seatmap_manifest_404(client, monkeypatch):
    _stub_requests_get(monkeypatch, _FakeResp(404, is_json=False))
    assert client.get("/api/store/seatmap/1/2/manifest.json").status_code == 404


def test_seatmap_svg_ok(client, monkeypatch):
    _stub_requests_get(monkeypatch, _FakeResp(200, content=b"<svg/>", is_json=False))
    r = client.get("/api/store/seatmap/896/14341/map.svg")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("image/svg+xml")
    assert "sandbox" in r.headers.get("content-security-policy", "")


def test_seatmap_svg_upstream_5xx_502(client, monkeypatch):
    _stub_requests_get(monkeypatch, _FakeResp(500, is_json=False))
    assert client.get("/api/store/seatmap/1/2/map.svg").status_code == 502


def test_seatmap_request_exception_502(client, monkeypatch):
    def boom(*a, **k):
        raise app_module.requests.RequestException("conn reset")
    monkeypatch.setattr(app_module.requests, "get", boom)
    assert client.get("/api/store/seatmap/1/2/map.svg").status_code == 502


# =====================================================================
# /api/store/seatmap/{venue}/{config}/section-map
# =====================================================================

def _section_map_sb(rows_by_cfg):
    def venue_section_map(f):
        cfg = f["_eq"].get("configuration_id")
        return rows_by_cfg.get(cfg, [])
    return FakeSupabase({"venue_section_map": venue_section_map})


def test_section_map_primary_bucket(client, monkeypatch):
    sb = _section_map_sb({53: [
        {"section_raw": "Field Box 112A", "seatmap_key": "field box 112"},
        {"section_raw": "  ", "seatmap_key": "x"},
        {"section_raw": "B", "seatmap_key": None},
    ]})
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/seatmap/896/53/section-map")
    body = r.json()
    assert body["config_used"] == 53
    assert body["count"] == 1


def test_section_map_falls_back_to_union(client, monkeypatch):
    sb = _section_map_sb({0: [{"section_raw": "GA", "seatmap_key": "ga"}]})
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/seatmap/896/9999/section-map")
    body = r.json()
    assert body["config_used"] == 0
    assert body["sections"] == {"GA": "ga"}


def test_section_map_config_zero_no_double(client, monkeypatch):
    sb = _section_map_sb({})
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/seatmap/896/0/section-map")
    assert r.json()["count"] == 0


def test_section_map_query_raises(client, monkeypatch):
    sb = FakeSupabase({"venue_section_map": lambda f: []},
                      raise_tables={"venue_section_map"})
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/seatmap/896/53/section-map")
    assert r.status_code == 200
    assert r.json()["count"] == 0  # _rows except → []


def test_section_map_unsupported_platform_400(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", _section_map_sb({}))
    assert client.get("/api/store/seatmap/896/53/section-map?platform=tp").status_code == 400


def test_section_map_sb_none(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    r = client.get("/api/store/seatmap/896/53/section-map")
    assert r.status_code == 200
    assert r.json()["config_used"] is None


# =====================================================================
# /api/store/events/{event_id}/zones
# =====================================================================

def _zones_sb(rollup_rows, event_meta=None, pair_count=None, pair_raises=False):
    def events(f):
        return event_meta or []

    def performer_zones(f):
        if pair_raises:
            raise RuntimeError("boom")
        return _Result([{"id": i} for i in range(pair_count or 0)],
                       count=pair_count)
    tr = {"events": events, "performer_zones": performer_zones}
    return FakeSupabase(tr, rpc_resolvers={
        "get_event_zones_rollup": lambda p: rollup_rows})


def test_zones_consumer_layer(client, monkeypatch):
    sb = _zones_sb(
        rollup_rows=[
            {"source": "curated", "zone": "Lower (100s)", "tickets": 5,
             "min_retail": 100, "max_retail": 200},
            {"source": "fallback", "zone": "noise", "tickets": 1},  # dropped
        ],
        event_meta=[{"primary_performer_id": 10, "venue_id": 896}],
        pair_count=4,  # below threshold → no granular
    )
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/3346000/zones")
    body = r.json()
    assert body["layer"] == "consumer"
    assert body["has_granular_available"] is False
    assert len(body["zones"]) == 1
    assert body["zones"][0]["name"] == "Lower (100s)"


def test_zones_empty_none_layer(client, monkeypatch):
    sb = _zones_sb(rollup_rows=[], event_meta=[], pair_count=0)
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/1/zones")
    body = r.json()
    assert body["layer"] == "none"
    assert body["zones"] == []


def test_zones_rollup_rpc_raises(client, monkeypatch):
    sb = _zones_sb(rollup_rows=[], event_meta=[])
    def boom(p):
        raise RuntimeError("rpc down")
    sb.rpc_resolvers["get_event_zones_rollup"] = boom
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/1/zones")
    assert r.status_code == 200
    assert r.json()["zones"] == []


def test_zones_granular_layer_preferred(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_PREFER_INTERNAL_ZONES", True)
    sb = _zones_sb(
        rollup_rows=[
            {"source": "curated", "zone": "Courtside", "tickets": 2,
             "min_retail": 1000, "max_retail": 2000},  # not bowl pattern → internal
            {"source": "curated", "zone": "Lower (100s)", "tickets": 5,
             "min_retail": 100, "max_retail": 200},  # bowl pattern → excluded
        ],
        event_meta=[{"primary_performer_id": 10, "venue_id": 896}],
        pair_count=20,  # above threshold → has granular
    )
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/3346000/zones")
    body = r.json()
    assert body["layer"] == "internal"
    assert [z["name"] for z in body["zones"]] == ["Courtside"]


def test_zones_granular_preferred_but_none_match(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_PREFER_INTERNAL_ZONES", True)
    sb = _zones_sb(
        rollup_rows=[
            {"source": "curated", "zone": "Lower (100s)", "tickets": 5},
        ],
        event_meta=[{"primary_performer_id": 10, "venue_id": 896}],
        pair_count=20,
    )
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/3346000/zones")
    body = r.json()
    # has_granular + prefer, but all zones are bowl pattern → chosen empty → none
    assert body["layer"] == "none"
    assert body["zones"] == []


def test_zones_pair_count_query_raises(client, monkeypatch):
    sb = _zones_sb(
        rollup_rows=[{"source": "curated", "zone": "Lower (100s)", "tickets": 5}],
        event_meta=[{"primary_performer_id": 10, "venue_id": 896}],
        pair_raises=True,
    )
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/3346000/zones")
    body = r.json()
    assert body["pair_zone_count"] == 0  # except → 0
    assert body["layer"] == "consumer"


def test_zones_no_event_meta(client, monkeypatch):
    sb = _zones_sb(
        rollup_rows=[{"source": "curated", "zone": "Lower (100s)", "tickets": 5}],
        event_meta=[],  # ev_meta empty → pair_zone_count stays 0
    )
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/events/3346000/zones")
    assert r.json()["pair_zone_count"] == 0


def test_multi_tour_non_numeric_performer_ids_400(client):
    # Regression: a non-numeric performer_ids token used to raise an uncaught
    # ValueError -> 500. It must now return a clean 400 (the int() coercion is
    # guarded, mirroring the catalog perf-id guard).
    r = client.get("/api/store/tours/multi?performer_ids=abc&home_lat=40&home_lon=-73")
    assert r.status_code == 400
    assert "comma-separated integers" in r.json()["detail"]
    # A mixed valid/invalid list 400s too (one bad token poisons the parse).
    r2 = client.get("/api/store/tours/multi?performer_ids=1,foo,3&home_lat=40&home_lon=-73")
    assert r2.status_code == 400
