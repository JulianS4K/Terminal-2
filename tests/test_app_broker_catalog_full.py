"""Full line-coverage tests for the BROKER CATALOG slice of app.py.

Covers the ~900-1840 route band:
  - GET  /api/events/{event_id}                          (event_detail)
  - GET  /api/events/{event_id}/series                   (event_series)
  - GET  /api/events/{event_id}/sections/series          (event_section_series)
  - GET  /api/performers                                 (performers_search)
  - GET  /api/broker/performers/{id}/trip-plan           (+ _trip_plan_payload)
  - GET  /api/broker/performers/{id}/tour-package        (+ _tour_package_payload)
  - GET  /api/broker/tours/multi                         (+ _multi_tour_payload)
  - GET  /api/broker/tours/near                          (+ _discover_payload)
  - GET  /api/broker/news                                (broker_news)
  - GET  /api/broker/performers/by-league/{league}       (broker_performers_by_league)
  - GET  /api/portfolio                                  (portfolio)
  - GET  /api/venues                                     (venues_search)
  - POST /api/watchlist  +  DELETE /api/watchlist/{id}   (watchlist_add/remove)
  - POST /api/collect/run                                (collect_run)

House style mirrors tests/test_broker_routes.py: fake env BEFORE importing
app, drive app.app via TestClient, monkeypatch app.require_sb / app.client and
the trip_planner.* helpers. No real network / DB.
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
os.environ.setdefault("AUTH_DISABLED", "true")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402
import trip_planner as trip_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------- Reusable fake Supabase (fluent chain) ----------

class _FakeQuery:
    """No-op fluent chain; execute() yields an object exposing `.data`.
    Insert/delete builders capture their payload so mutating routes can be
    asserted, and an optional `raise_on_execute` simulates DB errors."""

    def __init__(self, data, sink=None, raise_on_execute=None):
        self._data = data
        self._sink = sink
        self._raise = raise_on_execute

    def select(self, *_a, **_k):
        return self

    def eq(self, *_a, **_k):
        return self

    def in_(self, *_a, **_k):
        return self

    def or_(self, *_a, **_k):
        return self

    def gte(self, *_a, **_k):
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def insert(self, payload, *_a, **_k):
        if self._sink is not None:
            self._sink.setdefault("insert", []).append(payload)
        return self

    def delete(self, *_a, **_k):
        if self._sink is not None:
            self._sink["delete"] = True
        return self

    def execute(self):
        if self._raise is not None:
            raise self._raise
        return type("_Res", (), {"data": self._data})()


class FakeSupabase:
    """Programmable stand-in for the supabase client.

    rpc_data/table_data: {name: rows}. `errors` maps a table name to an
    exception raised on .execute() (for the watchlist failure branches).
    """

    def __init__(self, rpc_data=None, table_data=None, errors=None):
        self.rpc_data = rpc_data or {}
        self.table_data = table_data or {}
        self.errors = errors or {}
        self.rpc_calls: list[tuple[str, dict]] = []
        self.table_calls: list[str] = []
        self.sink: dict = {}

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params or {}))
        return _FakeQuery(self.rpc_data.get(name, []))

    def table(self, name):
        self.table_calls.append(name)
        return _FakeQuery(
            self.table_data.get(name, []),
            sink=self.sink,
            raise_on_execute=self.errors.get(name),
        )


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _use_db(monkeypatch, fake: FakeSupabase):
    monkeypatch.setattr(app_module, "require_sb", lambda: fake)


class _RecorderClient:
    """Stand-in for app.client (the TEvo client). Each method returns its
    programmed value and records call args."""

    def __init__(self, returns=None):
        self.returns = returns or {}
        self.calls: dict[str, tuple] = {}

    def get_event(self, event_id):
        self.calls["get_event"] = (event_id,)
        return self.returns.get("get_event", {"id": event_id})

    def get_event_stats(self, event_id, inventory_type=None):
        self.calls.setdefault("get_event_stats", []).append((event_id, inventory_type))
        key = "get_event_stats_event" if inventory_type == "event" else "get_event_stats"
        val = self.returns.get(key, {"avg": 1})
        if isinstance(val, Exception):
            raise val
        return val

    def get_listings(self, event_id, order_by=None):
        self.calls["get_listings"] = (event_id, order_by)
        return self.returns.get("get_listings", {"ticket_groups": []})

    def list_performers(self, **kw):
        self.calls.setdefault("list_performers", []).append(kw)
        return self.returns.get("list_performers", {"performers": [], "total_entries": 0})

    def search_performers(self, **kw):
        self.calls["search_performers"] = kw
        return self.returns.get("search_performers", {"performers": []})

    def search_venues(self, **kw):
        self.calls["search_venues"] = kw
        return self.returns.get("search_venues", {"venues": []})

    def list_venues(self, **kw):
        self.calls.setdefault("list_venues", []).append(kw)
        return self.returns.get("list_venues", {"venues": []})


def _use_client(monkeypatch, rec: _RecorderClient):
    monkeypatch.setattr(app_module, "client", rec)
    return rec


# ============================================================
# GET /api/events/{event_id}
# ============================================================

def test_event_detail_filters_ancillary_by_default(client, monkeypatch):
    groups = [
        {"section": "104", "row": "5"},          # real seat
        {"section": "Parking Lot A"},            # ancillary -> filtered
    ]
    rec = _RecorderClient({
        "get_event": {"id": 42, "name": "Knicks"},
        "get_listings": {"ticket_groups": groups},
    })
    _use_client(monkeypatch, rec)
    body = client.get("/api/events/42").json()
    assert body["event"]["id"] == 42
    assert body["ticket_groups_total"] == 2
    # at least one parking group filtered out
    assert body["ticket_groups_filtered_parking"] >= 1
    assert len(body["ticket_groups"]) == body["ticket_groups_total"] - body["ticket_groups_filtered_parking"]
    assert body["stats"] == {"avg": 1}


def test_event_detail_include_ancillary_keeps_all(client, monkeypatch):
    groups = [{"section": "104"}, {"section": "Parking Lot A"}]
    rec = _RecorderClient({"get_listings": {"ticket_groups": groups}})
    _use_client(monkeypatch, rec)
    body = client.get("/api/events/42?include_ancillary=true").json()
    assert body["ticket_groups"] == groups
    assert body["ticket_groups_filtered_parking"] == 0


def test_event_detail_stats_runtime_error_degrades(client, monkeypatch):
    # Both get_event_stats calls raise RuntimeError -> stats / stats_event_only None.
    rec = _RecorderClient({
        "get_event_stats": RuntimeError("no stats"),
        "get_event_stats_event": RuntimeError("no stats"),
        "get_listings": {"ticket_groups": None},   # None -> [] branch
    })
    _use_client(monkeypatch, rec)
    body = client.get("/api/events/7").json()
    assert body["stats"] is None
    assert body["stats_event_only"] is None
    assert body["ticket_groups"] == []
    assert body["ticket_groups_total"] == 0


def test_event_detail_non_int_id_422(client):
    # FastAPI path validation: non-int id -> 422 (never reaches client).
    assert client.get("/api/events/not-an-int").status_code == 422


# ============================================================
# GET /api/events/{event_id}/series
# ============================================================

def test_event_series_maps_rows(client, monkeypatch):
    rows = [
        {"captured_at": "2026-05-10T12:00:00Z", "tickets_count": 100, "retail_median": 250},
        {"captured_at": "2026-05-11T12:00:00Z", "tickets_count": 110, "retail_median": 260},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"event_metrics": rows}))
    body = client.get("/api/events/42/series?days=900").json()  # >365 clamps to 365
    assert body["event_id"] == 42
    assert body["days"] == 365
    assert len(body["series"]) == 2
    assert body["series"][0]["t"] == "2026-05-10T12:00:00Z"
    assert body["series"][0]["tickets_count"] == 100
    assert "captured_at" not in body["series"][0]


def test_event_series_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"event_metrics": []}))
    body = client.get("/api/events/1/series?days=0").json()  # <1 clamps to 1
    assert body == {"event_id": 1, "days": 1, "series": []}


# ============================================================
# GET /api/events/{event_id}/sections/series
# ============================================================

def test_event_section_series_groups_and_sorts(client, monkeypatch):
    rows = [
        {"captured_at": "2026-05-10T12:00:00Z", "section": "Parking", "is_ancillary": True,
         "tickets_count": 5, "groups_count": 2, "retail_min": 20, "retail_median": 25,
         "retail_mean": 25, "retail_max": 30},
        {"captured_at": "2026-05-10T12:00:00Z", "section": "104", "is_ancillary": False,
         "tickets_count": 50, "groups_count": 10, "retail_min": 100, "retail_median": 150,
         "retail_mean": 160, "retail_max": 300},
        {"captured_at": "2026-05-10T13:00:00Z", "section": "104", "is_ancillary": False,
         "tickets_count": 55, "groups_count": 11, "retail_min": 110, "retail_median": 155,
         "retail_mean": 165, "retail_max": 310},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"section_metrics": rows}))
    body = client.get("/api/events/42/sections/series").json()
    secs = body["sections"]
    # non-ancillary 104 sorts before ancillary Parking
    assert [s["section"] for s in secs] == ["104", "Parking"]
    # 104 accrued two points
    assert len(secs[0]["points"]) == 2
    assert secs[1]["is_ancillary"] is True
    assert secs[0]["points"][0]["tickets_count"] == 50


def test_event_section_series_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"section_metrics": []}))
    body = client.get("/api/events/1/sections/series").json()
    assert body == {"event_id": 1, "days": 30, "sections": []}


# ============================================================
# GET /api/performers
# ============================================================

def test_performers_search_by_query(client, monkeypatch):
    rec = _RecorderClient({"search_performers": {"performers": [{"id": 1}]}})
    _use_client(monkeypatch, rec)
    body = client.get("/api/performers?q=knicks&fuzzy=true").json()
    assert body == {"performers": [{"id": 1}]}
    assert rec.calls["search_performers"] == {"q": "knicks", "fuzzy": True}


def test_performers_search_by_category_paginates_until_total(client, monkeypatch):
    # First page returns a full batch reaching total_entries -> loop breaks.
    rec = _RecorderClient({
        "list_performers": {"performers": [{"id": 1}, {"id": 2}], "total_entries": 2},
    })
    _use_client(monkeypatch, rec)
    body = client.get("/api/performers?category_id=10").json()
    assert body["total_entries"] == 2
    assert len(body["performers"]) == 2
    # only one page fetched (len >= total_entries broke the loop)
    assert len(rec.calls["list_performers"]) == 1


def test_performers_search_category_empty_batch_breaks(client, monkeypatch):
    # Empty batch with total_entries high -> `not batch` breaks the loop.
    rec = _RecorderClient({
        "list_performers": {"performers": [], "total_entries": 999},
    })
    _use_client(monkeypatch, rec)
    body = client.get("/api/performers?category_id=5").json()
    assert body == {"performers": [], "total_entries": 0}
    assert len(rec.calls["list_performers"]) == 1


def test_performers_search_no_args_400(client, monkeypatch):
    _use_client(monkeypatch, _RecorderClient())
    r = client.get("/api/performers")
    assert r.status_code == 400


# ============================================================
# GET /api/broker/performers/{id}/trip-plan
# ============================================================

def test_trip_plan_passes_clamped_args(client, monkeypatch):
    captured = {}

    def _fake_plan(db, performer_id, hlat, hlon, budget, start, end, **kw):
        captured.update(dict(performer_id=performer_id, hlat=hlat, hlon=hlon,
                             budget=budget, kw=kw, start=start, end=end))
        return {"ok": True}

    monkeypatch.setattr(trip_module, "plan_performer_trip", _fake_plan)
    _use_db(monkeypatch, FakeSupabase())
    body = client.get(
        "/api/broker/performers/16303/trip-plan"
        "?home_lat=40.75&home_lon=-73.99&budget_km=50&home_name=&days=2000"
        "&budget_usd=20000000&qty=99"
    ).json()
    assert body == {"ok": True}
    assert captured["performer_id"] == 16303
    assert captured["hlat"] == 40.75
    assert captured["budget"] == 100.0        # budget_km 50 clamped up to 100 floor
    assert captured["kw"]["home_name"] == "Home"   # blank -> "Home"
    assert captured["kw"]["budget_usd"] == 10_000_000.0  # clamped down
    assert captured["kw"]["qty"] == 50         # clamped to 50 ceiling


def test_trip_plan_no_budget_usd_is_none(client, monkeypatch):
    captured = {}

    def _fake_plan(db, performer_id, hlat, hlon, budget, start, end, **kw):
        captured["budget_usd"] = kw.get("budget_usd")
        return {"ok": True}

    monkeypatch.setattr(trip_module, "plan_performer_trip", _fake_plan)
    _use_db(monkeypatch, FakeSupabase())
    client.get("/api/broker/performers/1/trip-plan?home_lat=1&home_lon=2")
    assert captured["budget_usd"] is None


# ============================================================
# GET /api/broker/performers/{id}/tour-package
# ============================================================

def test_tour_package_route_passes_args(client, monkeypatch):
    captured = {}

    def _fake_tour(db, performer_id, hlat, hlon, qty, bkm, start, end, **kw):
        captured.update(dict(hlat=hlat, hlon=hlon, qty=qty, bkm=bkm, kw=kw))
        return {"ok": True}

    monkeypatch.setattr(trip_module, "plan_performer_tour", _fake_tour)
    _use_db(monkeypatch, FakeSupabase())
    body = client.get(
        "/api/broker/performers/16303/tour-package"
        "?home_lat=40.75&home_lon=-73.99&qty=3&budget_km=8000"
        "&side=away&clear_at=0.15&away_margin=0.18&section_like=104&budget_usd=5000"
    ).json()
    assert body == {"ok": True}
    assert captured["kw"]["side"] == "away"
    assert captured["hlat"] == 40.75


def test_tour_package_bad_side_defaults_auto(client, monkeypatch):
    captured = {}

    def _fake_tour(db, performer_id, hlat, hlon, qty, bkm, start, end, **kw):
        captured["side"] = kw.get("side")
        captured["section_like"] = kw.get("section_like")
        return {"ok": True}

    monkeypatch.setattr(trip_module, "plan_performer_tour", _fake_tour)
    _use_db(monkeypatch, FakeSupabase())
    client.get(
        "/api/broker/performers/1/tour-package"
        "?home_lat=40&home_lon=-73&side=bogus&prefer_owned=true"
    )
    assert captured["side"] == "auto"   # bogus -> 'auto'


def test_tour_package_payload_date_branches_direct(monkeypatch):
    # The route doesn't expose start_date/end_date, but the helper (in our slice)
    # parses them. Exercise the valid-window, invalid-ISO, and inverted-window
    # branches + max_events clamp by calling _tour_package_payload directly.
    captured = {}

    def _fake_tour(db, performer_id, hlat, hlon, qty, bkm, start, end, **kw):
        captured["start"], captured["end"] = str(start), str(end)
        captured["max_events"] = kw.get("max_events")
        return {"ok": True}

    monkeypatch.setattr(trip_module, "plan_performer_tour", _fake_tour)
    monkeypatch.setattr(app_module, "require_sb", lambda: FakeSupabase())

    # valid future window + max_events clamp to 12
    app_module._tour_package_payload(
        1, 40.0, -73.0, qty=2, budget_km=8000, home_name="", days=365,
        budget_usd=None, side="away", clear_at=0.15, away_margin=0.18,
        section_like="104", prefer_owned=False, max_events=99,
        start_date="2030-01-01", end_date="2030-12-31",
    )
    assert captured["start"] == "2030-01-01"
    assert captured["max_events"] == 12

    # invalid ISO dates -> except: pass (start/end keep _tour_dates defaults)
    app_module._tour_package_payload(
        1, None, None, qty=2, budget_km=8000, home_name="Home", days=365,
        budget_usd=5000, side="auto", clear_at=0.15, away_margin=0.18,
        start_date="nope", end_date="alsobad", max_events=None,
    )
    assert captured["max_events"] is None  # max_events None branch

    # inverted window (end before start) -> guard bumps end to start+1
    app_module._tour_package_payload(
        1, 40.0, -73.0, qty=2, budget_km=8000, home_name="Home", days=365,
        budget_usd=None, side="auto", clear_at=0.15, away_margin=0.18,
        start_date="2030-06-01", end_date="2030-01-01",
    )
    assert captured["end"] > captured["start"]


# ============================================================
# GET /api/broker/tours/multi
# ============================================================

def test_multi_tour_parses_ids(client, monkeypatch):
    captured = {}

    def _fake_multi(db, ids, hlat, hlon, qty, bkm, start, end, **kw):
        captured.update(dict(ids=ids, qty=qty))
        return {"ok": True}

    monkeypatch.setattr(trip_module, "plan_multi_performer_tour", _fake_multi)
    _use_db(monkeypatch, FakeSupabase())
    body = client.get(
        "/api/broker/tours/multi"
        "?performer_ids=1,2, 3,&home_lat=40&home_lon=-73&qty=5&budget_usd=1000"
    ).json()
    assert body == {"ok": True}
    assert captured["ids"] == [1, 2, 3]


def test_multi_tour_empty_ids_400(client, monkeypatch):
    monkeypatch.setattr(trip_module, "plan_multi_performer_tour", lambda *a, **k: {})
    _use_db(monkeypatch, FakeSupabase())
    r = client.get("/api/broker/tours/multi?performer_ids=,,&home_lat=40&home_lon=-73")
    assert r.status_code == 400


# ============================================================
# GET /api/broker/tours/near
# ============================================================

def test_tours_near_passes_params(client, monkeypatch):
    captured = {}

    def _fake_discover(db, hlat, hlon, within, start, end, **kw):
        captured.update(dict(hlat=hlat, hlon=hlon, within=within, kw=kw))
        return {"ok": True, "performers": []}

    monkeypatch.setattr(trip_module, "discover_tours_near", _fake_discover)
    _use_db(monkeypatch, FakeSupabase())
    body = client.get(
        "/api/broker/tours/near"
        "?home_lat=40.75&home_lon=-73.99&within_mi=2000&days=60&min_shows=99&concerts_only=true"
    ).json()
    assert body["ok"] is True
    assert captured["within"] == 1000.0       # 2000 clamped to 1000 ceiling
    assert captured["kw"]["min_shows"] == 6   # 99 clamped to 6 ceiling
    assert captured["kw"]["event_types"] == ["concert"]


def test_tours_near_default_team_side_home(client, monkeypatch):
    captured = {}

    def _fake_discover(db, hlat, hlon, within, start, end, **kw):
        captured["team_side"] = kw.get("team_side")
        captured["event_types"] = kw.get("event_types")
        return {"ok": True}

    monkeypatch.setattr(trip_module, "discover_tours_near", _fake_discover)
    _use_db(monkeypatch, FakeSupabase())
    client.get("/api/broker/tours/near?home_lat=40&home_lon=-73")
    assert captured["team_side"] == "home"
    assert captured["event_types"] is None  # concerts_only default False


# ============================================================
# GET /api/broker/news
# ============================================================

def test_news_global_feed(client, monkeypatch):
    items = [{"headline": "Trade", "espn_league": "NBA"}]
    _use_db(monkeypatch, FakeSupabase(table_data={"espn_news": items}))
    body = client.get("/api/broker/news?limit=999").json()  # clamps to 100
    assert body["count"] == 1
    assert body["items"] == items
    assert body["filter"] == {"league": None, "team_ids": [], "event_id": None}


def test_news_team_ids_mode(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"espn_news": []}))
    body = client.get("/api/broker/news?team_ids=20, 18 ,&league=NBA").json()
    assert body["filter"]["team_ids"] == ["20", "18"]
    assert body["filter"]["league"] == "NBA"


def test_news_event_id_resolves_xref_and_teams(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "event_xref": [{"espn_event_id": "E1", "espn_league": "NBA"}],
        "espn_event_snapshots": [{"home_team_id": 18, "away_team_id": 2, "captured_at": "x"}],
        "espn_news": [{"headline": "h"}],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/news?event_id=3091423").json()
    assert body["filter"]["event_id"] == 3091423
    assert body["filter"]["league"] == "NBA"
    assert set(body["filter"]["team_ids"]) == {"18", "2"}


def test_news_event_id_no_xref(client, monkeypatch):
    # event_id given but xref empty -> resolved_teams stays empty, no snapshot probe.
    fake = FakeSupabase(table_data={"event_xref": [], "espn_news": []})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/news?event_id=999").json()
    assert body["filter"]["team_ids"] == []
    assert body["filter"]["league"] is None


def test_news_event_id_xref_but_no_snapshot(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "event_xref": [{"espn_event_id": "E1", "espn_league": "MLB"}],
        "espn_event_snapshots": [],
        "espn_news": [],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/news?event_id=5").json()
    assert body["filter"]["league"] == "MLB"
    assert body["filter"]["team_ids"] == []


# ============================================================
# GET /api/broker/performers/by-league/{league}
# ============================================================

def test_by_league_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_performers_by_league": []}))
    body = client.get("/api/broker/performers/by-league/NBA").json()
    assert body["count"] == 0
    assert body["performers"] == []
    assert body["_inactive_filter_applied"] is False


def test_by_league_maps_and_deltas(client, monkeypatch):
    row = {
        "performer_id": 16303, "performer_name": "Knicks", "league": "NBA",
        "home_venue_id": 99, "home_venue_name": "MSG",
        "home_market_med": 150, "home_prev_market_med": 120,   # +25%
        "home_owned_med": "bad", "home_prev_owned_med": 130,   # TypeError/ValueError -> None
        "road_market_med": 200, "road_prev_market_med": 0,     # prev 0 -> None
    }
    fake = FakeSupabase(rpc_data={"get_performers_by_league": [row]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/performers/by-league/NBA?include_inactive=true").json()
    p = body["performers"][0]
    assert p["home"]["delta_market_pct"] == 25.0
    assert p["home"]["delta_owned_pct"] is None        # unparseable cur
    assert p["road"]["delta_market_pct"] is None       # prev 0
    assert p["home"]["events"] == 0                    # missing -> 0
    assert body["_include_inactive_param"] is True
    assert fake.rpc_calls[0] == ("get_performers_by_league", {"p_league": "NBA"})


def test_by_league_delta_none_when_missing(client, monkeypatch):
    # cur or prev None -> early None return in _delta_pct.
    row = {"performer_id": 1, "home_market_med": None, "home_prev_market_med": 100}
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_performers_by_league": [row]}))
    body = client.get("/api/broker/performers/by-league/NHL").json()
    assert body["performers"][0]["home"]["delta_market_pct"] is None


# ============================================================
# GET /api/portfolio
# ============================================================

def test_portfolio_no_filter_400(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    assert client.get("/api/portfolio").status_code == 400


def test_portfolio_performer_no_events_empty_aggregate(client, monkeypatch):
    # events resolve to [] -> early empty-aggregate return.
    _use_db(monkeypatch, FakeSupabase(table_data={"events": []}))
    body = client.get("/api/portfolio?performer_id=16303").json()
    assert body["events"] == []
    assert body["aggregate"]["events_count"] == 0
    assert body["aggregate"]["owned_share_weighted"] is None


def test_portfolio_performer_full_rollup_sports(client, monkeypatch):
    ev_meta = [
        {"id": 100, "name": "Knicks vs Celtics", "occurs_at_local": "2026-06-02T19:00:00-04:00",
         "venue_id": 99, "venue_name": "MSG", "venue_location": "NY", "state": "NY",
         "primary_performer_id": 16303, "primary_performer_name": "Knicks"},
        {"id": 200, "name": "Knicks at Nets", "occurs_at_local": "2026-06-01T19:00:00-04:00",
         "venue_id": 42, "venue_name": "Barclays", "venue_location": "BK", "state": "NY",
         "primary_performer_id": 16303, "primary_performer_name": "Knicks"},
    ]
    metrics = [
        {"event_id": 100, "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 100,
         "retail_median": 200, "retail_sum": "not-a-number", "owned_tickets_count": 10,
         "owned_median_retail": 150},  # bad retail_sum -> fnum except branch
        # event 200 has no metrics row -> captured_at None path
    ]
    fake = FakeSupabase(table_data={
        "events": ev_meta,   # both .or_() id-pull and .in_() meta-pull hit "events"
        "latest_event_metrics": metrics,
        "performer_home_venues": [{"venue_id": 99}],
        "performer_metadata": [{"what_event_type": "game", "top_category_name": "Sports"}],
        "event_lifecycle": [
            {"event_id": 100, "status": "scheduled", "is_active": True, "confidence": 1, "reasons": []},
            {"event_id": 200, "status": "scheduled", "is_active": True, "confidence": 1, "reasons": []},
        ],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/portfolio?performer_id=16303").json()
    assert body["is_sports_performer"] is True
    assert body["aggregate"]["events_count"] == 2
    # event 100 at home venue 99 -> is_home True
    ev100 = next(e for e in body["events"] if e["id"] == 100)
    assert ev100["is_home"] is True
    ev200 = next(e for e in body["events"] if e["id"] == 200)
    assert ev200["is_home"] is False
    # aggregates: tickets 100, owned 10, owned retail = 10*150
    agg = body["aggregate"]
    assert agg["tickets_total"] == 100
    assert agg["owned_tickets_total"] == 10
    assert agg["owned_retail_value_total"] == 1500.0
    assert agg["events_with_owned"] == 1
    assert agg["retail_median_avg_weighted"] == 200.0  # only ev100 has median+tix


def test_portfolio_venue_filter(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "events": [{"id": 100, "name": "E", "occurs_at_local": None, "venue_id": 42,
                    "venue_name": "V", "venue_location": "L", "state": "NY",
                    "primary_performer_id": 1, "primary_performer_name": "P"}],
        "latest_event_metrics": [],
        "event_lifecycle": [{"event_id": 100, "is_active": True}],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/portfolio?venue_id=42").json()
    assert body["filter"]["venue_id"] == 42
    assert body["is_sports_performer"] is False  # no performer filter
    assert body["events"][0]["is_home"] is None


def test_portfolio_all_events_ignored_empty_aggregate(client, monkeypatch):
    # Every resolved event is operator-ignored (state='ignored', e.g. the
    # Sphere Wizard of Oz pseudo-events) -> early empty-aggregate return.
    fake = FakeSupabase(table_data={
        "events": [{"id": 100, "name": "The Wizard of Oz at Sphere", "occurs_at_local": None,
                    "venue_id": 1, "venue_name": "Sphere", "venue_location": "Las Vegas, NV",
                    "state": "ignored", "primary_performer_id": 123021,
                    "primary_performer_name": "The Wizard of Oz"}],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/portfolio?venue_id=1").json()
    assert body["events"] == []
    assert body["aggregate"]["events_count"] == 0
    assert body["filter"]["venue_id"] == 1


def test_portfolio_watchlist_only_excludes_inactive(client, monkeypatch):
    # watch_sources resolves ids; lifecycle marks event inactive -> excluded.
    fake = FakeSupabase(table_data={
        "watch_sources": [{"event_id": 100}],
        "events": [{"id": 100, "name": "E", "occurs_at_local": None, "venue_id": 1,
                    "venue_name": "V", "venue_location": "L", "state": None,
                    "primary_performer_id": 1, "primary_performer_name": "P"}],
        "latest_event_metrics": [],
        "event_lifecycle": [{"event_id": 100, "is_active": False, "status": "completed"}],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/portfolio?watchlist_only=true").json()
    assert body["inactive_excluded_count"] == 1
    assert body["events"] == []


def test_portfolio_non_sports_performer_no_metadata(client, monkeypatch):
    # performer_metadata empty -> perf_classification None, not sports.
    fake = FakeSupabase(table_data={
        "events": [{"id": 100, "name": "Concert", "occurs_at_local": "2026-06-01T19:00:00Z",
                    "venue_id": 1, "venue_name": "V", "venue_location": "L", "state": None,
                    "primary_performer_id": 5, "primary_performer_name": "Band"}],
        "latest_event_metrics": [],
        "performer_home_venues": [],
        "performer_metadata": [],
        "event_lifecycle": [{"event_id": 100, "is_active": True}],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/portfolio?performer_id=5&include_inactive=true").json()
    assert body["is_sports_performer"] is False
    assert body["performer_classification"] is None
    assert body["events"][0]["is_home"] is None


# ============================================================
# GET /api/venues
# ============================================================

def test_venues_search_by_query(client, monkeypatch):
    rec = _RecorderClient({"search_venues": {"venues": [{"id": 1}]}})
    _use_client(monkeypatch, rec)
    body = client.get("/api/venues?q=garden&fuzzy=true").json()
    assert body == {"venues": [{"id": 1}]}
    assert rec.calls["search_venues"] == {"q": "garden", "fuzzy": True}


def test_venues_search_by_latlon(client, monkeypatch):
    rec = _RecorderClient({"list_venues": {"venues": []}})
    _use_client(monkeypatch, rec)
    client.get("/api/venues?lat=40.75&lon=-73.99")
    assert rec.calls["list_venues"][0] == {"lat": 40.75, "lon": -73.99, "within": 15}


def test_venues_search_by_postal_code(client, monkeypatch):
    rec = _RecorderClient({"list_venues": {"venues": []}})
    _use_client(monkeypatch, rec)
    client.get("/api/venues?postal_code=10001&within=50")
    assert rec.calls["list_venues"][0] == {"postal_code": "10001", "within": 50}


def test_venues_search_no_args_400(client, monkeypatch):
    _use_client(monkeypatch, _RecorderClient())
    assert client.get("/api/venues").status_code == 400


# ============================================================
# POST /api/watchlist  +  DELETE /api/watchlist/{id}
# ============================================================

def test_watchlist_add_success(client, monkeypatch):
    inserted = {"id": 7, "kind": "performer", "ext_id": 16303, "label": "Knicks"}
    _use_db(monkeypatch, FakeSupabase(table_data={"watchlist": [inserted]}))
    body = client.post("/api/watchlist", json={"kind": "performer", "ext_id": 16303,
                                               "label": "Knicks"}).json()
    assert body["ok"] is True
    assert body["item"] == inserted


def test_watchlist_add_blank_label_becomes_none(client, monkeypatch):
    fake = FakeSupabase(table_data={"watchlist": [{"id": 1}]})
    _use_db(monkeypatch, fake)
    client.post("/api/watchlist", json={"kind": "venue", "ext_id": 42, "label": ""})
    # label "" normalized to None in the insert payload
    assert fake.sink["insert"][0]["label"] is None


def test_watchlist_add_bad_kind_400(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    r = client.post("/api/watchlist", json={"kind": "team", "ext_id": 1})
    assert r.status_code == 400
    assert "kind must be" in r.json()["detail"]


def test_watchlist_add_missing_ext_id_400(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    r = client.post("/api/watchlist", json={"kind": "performer"})
    assert r.status_code == 400
    assert "ext_id required" in r.json()["detail"]


def test_watchlist_add_duplicate_returns_ok_false(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(
        table_data={"watchlist": []},
        errors={"watchlist": Exception("duplicate key value violates unique constraint")},
    ))
    body = client.post("/api/watchlist", json={"kind": "performer", "ext_id": 1}).json()
    assert body == {"ok": False, "error": "already in watchlist"}


def test_watchlist_add_other_db_error_400(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(
        table_data={"watchlist": []},
        errors={"watchlist": Exception("connection refused")},
    ))
    r = client.post("/api/watchlist", json={"kind": "performer", "ext_id": 1})
    assert r.status_code == 400
    assert "connection refused" in r.json()["detail"]


def test_watchlist_remove_success(client, monkeypatch):
    fake = FakeSupabase(table_data={"watchlist": []})
    _use_db(monkeypatch, fake)
    body = client.delete("/api/watchlist/7").json()
    assert body == {"ok": True}
    assert fake.sink.get("delete") is True


# ============================================================
# POST /api/collect/run
# ============================================================

def test_collect_run_fires_collector(client, monkeypatch):
    fired = {}

    class _FakeThread:
        def __init__(self, target=None, args=(), daemon=None):
            fired["args"] = args

        def start(self):
            fired["started"] = True

    monkeypatch.setattr(app_module, "CRON_SECRET", "secret-xyz")
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://example.invalid")
    monkeypatch.setattr(app_module.threading, "Thread", _FakeThread)
    # fresh cooldown table so we aren't rate limited from a prior test
    app_module._collect_run_last_call.clear()
    body = client.post("/api/collect/run?watchlist_id=5").json()
    assert body["ok"] is True
    assert fired["started"] is True
    url = fired["args"][0]
    assert url.endswith("/functions/v1/collect?watchlist_id=5")


def test_collect_run_no_watchlist_id(client, monkeypatch):
    class _FakeThread:
        def __init__(self, *a, **k):
            self.args = k.get("args")

        def start(self):
            pass

    monkeypatch.setattr(app_module, "CRON_SECRET", "secret-xyz")
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://example.invalid")
    monkeypatch.setattr(app_module.threading, "Thread", _FakeThread)
    app_module._collect_run_last_call.clear()
    r = client.post("/api/collect/run")
    assert r.status_code == 200


def test_collect_run_missing_config_500(client, monkeypatch):
    monkeypatch.setattr(app_module, "CRON_SECRET", "")
    monkeypatch.setattr(app_module, "SUPABASE_URL", "")
    r = client.post("/api/collect/run")
    assert r.status_code == 500


def test_collect_run_bad_watchlist_id_400(client, monkeypatch):
    monkeypatch.setattr(app_module, "CRON_SECRET", "secret-xyz")
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://example.invalid")
    r = client.post("/api/collect/run?watchlist_id=0")
    assert r.status_code == 400


def test_collect_run_rate_limited_429(client, monkeypatch):
    class _FakeThread:
        def __init__(self, *a, **k):
            pass

        def start(self):
            pass

    monkeypatch.setattr(app_module, "CRON_SECRET", "secret-xyz")
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://example.invalid")
    monkeypatch.setattr(app_module.threading, "Thread", _FakeThread)
    app_module._collect_run_last_call.clear()
    # first call records a timestamp under the AUTH_DISABLED email
    assert client.post("/api/collect/run").status_code == 200
    # second immediate call hits the cooldown
    r = client.post("/api/collect/run")
    assert r.status_code == 429
    assert "rate limited" in r.json()["detail"]


def test_fire_collect_swallows_errors(monkeypatch):
    # direct unit test of the helper's try/except path (no thread).
    def _boom(*a, **k):
        raise RuntimeError("network down")

    monkeypatch.setattr(app_module.requests, "post", _boom)
    # must not raise
    app_module._fire_collect("http://x", "secret")


def test_fire_collect_posts(monkeypatch):
    captured = {}

    def _ok(url, headers=None, json=None, timeout=None):
        captured.update(url=url, headers=headers, timeout=timeout)

    monkeypatch.setattr(app_module.requests, "post", _ok)
    app_module._fire_collect("http://x/collect", "sek")
    assert captured["url"] == "http://x/collect"
    assert captured["headers"]["X-Cron-Secret"] == "sek"
