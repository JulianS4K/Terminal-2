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

import server as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------- Reusable fake Supabase ----------

class _FakeQuery:
    """A no-op fluent chain. Every builder method returns self; execute()
    yields an object exposing the preloaded `.data`."""

    def __init__(self, data):
        self._data = data
        self._count = False

    # builder methods used across broker routes — all return self
    def select(self, *_a, **_k):
        # PostgREST returns a row count alongside the data whenever the caller
        # asks for count="exact". Model that, so routes reading `.count` are
        # exercised against the shape the real client actually returns rather
        # than a fallback that only exists for this double.
        if _k.get("count"):
            self._count = True
        return self

    def eq(self, *_a, **_k):
        return self

    def in_(self, *_a, **_k):
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def gt(self, *_a, **_k):
        return self

    def lt(self, *_a, **_k):
        return self

    def lte(self, *_a, **_k):
        return self

    def range(self, *_a, **_k):
        return self

    def execute(self):
        attrs = {"data": self._data}
        if self._count:
            attrs["count"] = len(self._data)
        return type("_Res", (), attrs)()


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
    # No metadata row AND no events => name None, deterministic shape.
    assert body == {"performer_id": 999, "name": None, "logo_default_url": None}


def test_performer_assets_name_fallback_from_events(client, monkeypatch):
    # Non-ESPN performer (e.g. a Broadway show): name falls back to the event's
    # primary_performer_name so the hero still renders a title.
    _use_db(monkeypatch, FakeSupabase(table_data={
        "performer_metadata": [],
        "events": [{"primary_performer_name": "Oh Mary!"}],
    }))
    body = client.get("/api/broker/performer/103169/assets").json()
    assert body == {"performer_id": 103169, "name": "Oh Mary!", "logo_default_url": None}


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


# ---------- /api/broker/event/{id}/cadences (moved to routers/broker.py, slice 12) ----------

def test_cadences_sections_and_listings_cadence(client, monkeypatch):
    # occurs_at_local ~5 days out -> listings cadence 60min (3600s) per
    # core.helpers.listings_cadence_seconds.
    import datetime as _dt
    soon = (_dt.datetime.now() + _dt.timedelta(days=5)).date().isoformat()
    fake = FakeSupabase(table_data={
        "events": [{"id": 1, "occurs_at_local": soon}],
        "event_metrics": [{"captured_at": "2026-05-10T00:00:00Z"}],
        "espn_injuries_snapshots": [{"last_seen_at": "2026-05-10T01:00:00Z"}],
        "espn_team_snapshots": [{"last_seen_at": "2026-05-09T00:00:00Z"}],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/cadences").json()
    assert set(body["sections"]) == {"overview", "section_metrics", "raw_tevo", "espn_injuries", "espn_team"}
    assert body["sections"]["overview"]["cadence_seconds"] == 3600
    assert body["sections"]["overview"]["last_pull_at"] == "2026-05-10T00:00:00Z"
    assert body["sections"]["espn_injuries"]["cadence_seconds"] == 600


# ---------- /api/broker/performers/by-league/{league} ----------

def test_by_league_empty_returns_zero_count(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_performers_by_league": []}))
    body = client.get("/api/broker/performers/by-league/NBA").json()
    assert body == {
        "league": "NBA", "count": 0, "performers": [],
        "_inactive_filter_applied": False, "_include_inactive_param": False,
    }


def test_by_league_maps_rows_and_computes_delta_pct(client, monkeypatch):
    row = {
        "performer_id": 16303, "performer_name": "New York Knicks", "league": "NBA",
        "home_venue_id": 99, "home_venue_name": "MSG",
        "home_events": 5, "home_market_med": 150, "home_owned_med": 140,
        "home_market_tix": 200, "home_owned_tix": 50,
        "home_prev_market_med": 120, "home_prev_owned_med": 130,
        "road_events": 3, "road_market_med": 200, "road_market_tix": 80,
        "road_prev_market_med": 200,
    }
    fake = FakeSupabase(rpc_data={"get_performers_by_league": [row]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/performers/by-league/NBA").json()
    assert body["count"] == 1
    p = body["performers"][0]
    assert p["performer_name"] == "New York Knicks"
    # (150-120)/120*100 = 25.0 ; (140-130)/130*100 = 7.69 (rounded)
    assert p["home"]["delta_market_pct"] == 25.0
    assert p["home"]["delta_owned_pct"] == 7.69
    # flat market => 0.0, not None
    assert p["road"]["delta_market_pct"] == 0.0
    # missing prev (road_prev_owned_med absent) => None
    assert p["road"]["delta_owned_pct"] is None
    # tix/events default to 0 when absent
    assert p["road"]["owned_tix"] == 0
    assert fake.rpc_calls[0] == ("get_performers_by_league", {"p_league": "NBA"})


def test_by_league_merges_division(client, monkeypatch):
    row = {"performer_id": 16303, "performer_name": "New York Knicks", "league": "NBA"}
    fake = FakeSupabase(
        rpc_data={"get_performers_by_league": [row]},
        table_data={"league_team_divisions": [
            {"tevo_performer_id": 16303, "conference": "Eastern", "division": "Atlantic"}]},
    )
    _use_db(monkeypatch, fake)
    p = client.get("/api/broker/performers/by-league/NBA").json()["performers"][0]
    assert p["conference"] == "Eastern"
    assert p["division"] == "Atlantic"
    assert "league_team_divisions" in fake.table_calls


def test_by_league_division_absent_is_null(client, monkeypatch):
    # No league_team_divisions row → conference/division default to null (FE ungrouped).
    row = {"performer_id": 999, "performer_name": "Someteam", "league": "NBA"}
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_performers_by_league": [row]}))
    p = client.get("/api/broker/performers/by-league/NBA").json()["performers"][0]
    assert p["conference"] is None and p["division"] is None


def test_by_league_division_read_error_degrades(client, monkeypatch):
    # If the divisions read throws, the route still returns performers (conf/div
    # null) rather than 500 — division enrichment is best-effort.
    row = {"performer_id": 16303, "performer_name": "New York Knicks", "league": "NBA"}

    class _BoomDivisions(FakeSupabase):
        def table(self, name):
            if name == "league_team_divisions":
                raise RuntimeError("transient divisions read failure")
            return super().table(name)

    _use_db(monkeypatch, _BoomDivisions(rpc_data={"get_performers_by_league": [row]}))
    body = client.get("/api/broker/performers/by-league/NBA").json()
    assert body["count"] == 1
    p = body["performers"][0]
    assert p["conference"] is None and p["division"] is None


# ---------- /api/broker/event/{id}/section-metrics ----------

def test_section_metrics_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"section_metrics": []}))
    body = client.get("/api/broker/event/1/section-metrics").json()
    assert body["sections"] == []
    assert body["last_pull_at"] is None
    # no events row => occurs_at_local None => 24h default cadence
    assert body["cadence_seconds"] == 60 * 60 * 24


def test_section_metrics_groups_deltas_and_sorts(client, monkeypatch):
    rows = [
        {"captured_at": "2026-05-10T12:00:00Z", "section": "104", "is_ancillary": False,
         "tickets_count": 50, "groups_count": 10, "retail_min": 100,
         "retail_median": 150, "retail_mean": 160, "retail_max": 300},
        {"captured_at": "2026-05-09T12:00:00Z", "section": "104", "is_ancillary": False,
         "tickets_count": 40, "groups_count": 8, "retail_min": 90,
         "retail_median": 140, "retail_mean": 150, "retail_max": 280},
        {"captured_at": "2026-05-10T11:00:00Z", "section": "Parking", "is_ancillary": True,
         "tickets_count": 5, "groups_count": 2, "retail_min": 20,
         "retail_median": 25, "retail_mean": 25, "retail_max": 30},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"section_metrics": rows}))
    body = client.get("/api/broker/event/1/section-metrics").json()
    secs = body["sections"]
    # non-ancillary "104" sorts before ancillary "Parking"
    assert [s["section"] for s in secs] == ["104", "Parking"]
    # 104 has a prior snapshot -> delta computed (50 vs 40 = up)
    assert secs[0]["metrics"]["tickets_count"]["v"] == 50
    assert secs[0]["metrics"]["tickets_count"]["delta"]["dir"] == "up"
    # Parking has only one snapshot -> delta None
    assert secs[1]["is_ancillary"] is True
    assert secs[1]["metrics"]["tickets_count"]["delta"] is None
    # latest captured_at across sections
    assert body["last_pull_at"] == "2026-05-10T12:00:00Z"


# ---------- /api/broker/event/{id}/zones ----------

def test_zones_empty_returns_null_source(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"zone_metrics": []}))
    body = client.get("/api/broker/event/1/zones").json()
    assert body == {"zones": [], "count": 0, "source": None, "available_sources": []}


def test_zones_curated_wins_dedupes_hides_parking_sorts(client, monkeypatch):
    # rows pre-sorted captured_at desc (the route relies on the DB order); curated
    # is present so the fallback row must be dropped, latest-per-zone kept, parking
    # hidden, and the survivors sorted by tickets_count desc.
    rows = [
        {"zone": "Lower", "zone_source": "curated", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 100},
        {"zone": "Upper", "zone_source": "curated", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 200},
        {"zone": "Parking East", "zone_source": "curated", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 5},
        {"zone": "Lower", "zone_source": "curated", "captured_at": "2026-05-09T12:00:00Z", "tickets_count": 80},  # older dup
        {"zone": "Club", "zone_source": "fallback", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 300},  # non-chosen source
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"zone_metrics": rows}))
    body = client.get("/api/broker/event/1/zones").json()
    assert body["source"] == "curated"
    assert [z["zone"] for z in body["zones"]] == ["Upper", "Lower"]  # tickets desc, parking gone
    assert body["count"] == 2
    assert body["parking_hidden"] == 1
    assert body["available_sources"] == ["curated", "fallback"]
    assert body["include_parking"] is False


def test_zones_live_curated_preferred_and_enriched(client, monkeypatch):
    # get_event_zones_rollup returns the LIVE curated split (computed off
    # performer_zones + latest listings). It wins over the cron zone_metrics
    # snapshot: the live set drives the zone LIST + qty/retail bounds, and each
    # zone is enriched with its latest zone_metrics row when present. Parking
    # hidden; non-curated rollup rows ignored; sorted by tickets desc.
    zm = [
        {"zone": "Field", "zone_source": "curated", "captured_at": "2026-05-10T12:00:00Z",
         "tickets_count": 10, "retail_median": 250, "getin_price": 90},
        {"zone": "Field", "zone_source": "curated", "captured_at": "2026-05-09T12:00:00Z",
         "tickets_count": 9, "retail_median": 999},  # older dup -> ignored
    ]
    rollup = [
        {"zone": "Upper", "source": "curated", "tickets": 300, "min_retail": 40, "max_retail": 120},
        {"zone": "Field", "source": "curated", "tickets": 120, "min_retail": 80, "max_retail": 500},
        {"zone": "Parking Lot A", "source": "curated", "tickets": 4, "min_retail": 25, "max_retail": 25},
        {"zone": "SG Sections", "source": "fallback", "tickets": 1, "min_retail": 1, "max_retail": 1},
    ]
    _use_db(monkeypatch, FakeSupabase(
        table_data={"zone_metrics": zm},
        rpc_data={"get_event_zones_rollup": rollup},
    ))
    body = client.get("/api/broker/event/1/zones").json()
    assert body["source"] == "curated"
    assert body["live"] is True
    assert [z["zone"] for z in body["zones"]] == ["Upper", "Field"]  # tickets desc; parking + fallback gone
    assert body["count"] == 2
    assert body["parking_hidden"] == 1
    upper, field = body["zones"]
    assert upper["tickets_count"] == 300 and upper["retail_min"] == 40 and upper["retail_max"] == 120
    assert upper.get("retail_median") is None      # no zone_metrics detail to enrich with
    assert upper["getin_price"] == 40              # defaults to live min when no detail
    assert field["tickets_count"] == 120           # live qty wins over the snapshot's 10
    assert field["retail_min"] == 80               # live bounds
    assert field["retail_median"] == 250           # enriched from the latest zone_metrics (not the older 999)
    assert field["getin_price"] == 90              # kept from the zone_metrics detail


def test_zones_live_rollup_failure_degrades_to_zone_metrics(client, monkeypatch):
    # If the live rollup RPC errors, the panel degrades to the cron zone_metrics
    # snapshot instead of 500ing.
    class _RaisingRollup(FakeSupabase):
        def rpc(self, name, params=None):
            if name == "get_event_zones_rollup":
                raise RuntimeError("rollup boom")
            return super().rpc(name, params)

    rows = [
        {"zone": "Upper", "zone_source": "curated", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 50},
    ]
    _use_db(monkeypatch, _RaisingRollup(table_data={"zone_metrics": rows}))
    body = client.get("/api/broker/event/1/zones").json()
    assert body["source"] == "curated"
    assert body.get("live") is None                # took the non-live zone_metrics path
    assert [z["zone"] for z in body["zones"]] == ["Upper"]


# ---------- /api/broker/watchlist-movers ----------

def test_watchlist_movers_empty_watchlist(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"watch_sources": []}))
    body = client.get("/api/broker/watchlist-movers").json()
    assert body == {"window_hours": 24, "sort": "value", "count": 0, "events": []}


def test_watchlist_movers_filters_to_watchlist_and_computes_vals(client, monkeypatch):
    fake = FakeSupabase(
        table_data={"watch_sources": [{"event_id": 1}]},
        rpc_data={"get_event_movers": [
            {"event_id": 1, "name": "Knicks", "cur_market_med": 150, "cur_market_tix": 10,
             "prev_market_med": 120, "prev_market_tix": 10},
            {"event_id": 3, "name": "Not Watched", "cur_market_med": 999, "cur_market_tix": 1,
             "prev_market_med": 100, "prev_market_tix": 1},  # not in watchlist -> dropped
        ]},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/watchlist-movers").json()
    assert body["count"] == 1
    e = body["events"][0]
    assert e["event_id"] == 1
    assert e["delta_market_pct"] == 25.0          # (150-120)/120*100
    assert e["cur_market_val"] == 1500.0          # 150*10
    assert e["delta_market_val"] == 300.0         # 1500-1200
    assert fake.rpc_calls[0][0] == "get_event_movers"


# ---------- /api/broker/news ----------

def test_news_global_feed_passthrough(client, monkeypatch):
    items = [{"headline": "Trade", "espn_league": "NBA", "espn_team_id": "18"}]
    _use_db(monkeypatch, FakeSupabase(table_data={"espn_news": items}))
    body = client.get("/api/broker/news").json()
    assert body["count"] == 1
    assert body["items"] == items
    assert body["filter"] == {"league": None, "team_ids": [], "event_id": None}


def test_news_team_ids_mode_parses_filter(client, monkeypatch):
    # team_ids mode exercises the .in_() path; FakeQuery ignores filters but the
    # route must still parse the CSV into the echoed filter.
    _use_db(monkeypatch, FakeSupabase(table_data={"espn_news": []}))
    body = client.get("/api/broker/news?team_ids=20,18&limit=5").json()
    assert body["filter"]["team_ids"] == ["20", "18"]
    assert body["count"] == 0


# ---------- /api/broker/event/{id}/section-zones (degradation paths) ----------

def test_section_zones_no_event_returns_empty(client, monkeypatch):
    # Unknown event -> empty map, no crash (the curated/fallback machinery below
    # is never reached).
    _use_db(monkeypatch, FakeSupabase(table_data={"events": []}))
    body = client.get("/api/broker/event/999/section-zones").json()
    assert body == {"map": {}, "source_mix": {}}


def test_section_zones_no_listings_returns_empty(client, monkeypatch):
    # Event exists but has no listings snapshot yet -> empty map (no sections to
    # classify).
    _use_db(monkeypatch, FakeSupabase(table_data={
        "events": [{"primary_performer_id": 16303, "venue_id": 42}],
        "listings_snapshots": [],
    }))
    body = client.get("/api/broker/event/1/section-zones").json()
    assert body == {"map": {}, "source_mix": {}}


# ---------- /api/broker/tours/near (param plumbing) ----------

def test_tours_near_passes_params_to_discovery(client, monkeypatch):
    captured = {}
    def _fake_discover(home_lat, home_lon, within_mi, days, min_shows, concerts_only):
        captured.update(dict(home_lat=home_lat, home_lon=home_lon, within_mi=within_mi,
                             days=days, min_shows=min_shows, concerts_only=concerts_only))
        return {"ok": True, "performers": []}
    monkeypatch.setattr(app_module, "_discover_payload", _fake_discover)
    body = client.get("/api/broker/tours/near"
                      "?home_lat=40.75&home_lon=-73.99&within_mi=100&days=60"
                      "&min_shows=3&concerts_only=true").json()
    assert body == {"ok": True, "performers": []}
    assert captured == {"home_lat": 40.75, "home_lon": -73.99, "within_mi": 100.0,
                        "days": 60, "min_shows": 3, "concerts_only": True}


# ---------- /api/broker/event/{id}/orders ----------

def test_orders_empty_returns_null_summary(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"evo_order_items": []}))
    body = client.get("/api/broker/event/1/orders").json()
    assert body == {"event_id": 1, "items": [], "orders": [], "summary": None}


def test_orders_rolls_up_state_counts_and_sold(client, monkeypatch):
    items = [
        {"evo_order_id": 10, "evo_item_id": 1, "quantity": 2, "price": 100},  # accepted
        {"evo_order_id": 11, "evo_item_id": 2, "quantity": 1, "price": 50},   # pending
    ]
    orders = [
        {"evo_order_id": 10, "state": "accepted", "evo_updated_at": "2026-05-10T12:00:00Z"},
        {"evo_order_id": 11, "state": "pending", "evo_updated_at": "2026-05-09T12:00:00Z"},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "evo_order_items": items, "evo_orders": orders,
    }))
    body = client.get("/api/broker/event/1/orders").json()
    s = body["summary"]
    assert s["total_items"] == 2
    assert s["by_state"] == {"accepted": 1, "pending": 1}
    # only accepted/completed items count toward sold totals
    assert s["tickets_sold"] == 2
    assert s["gross_sold"] == 200.0       # 100 * 2
    assert s["last_update_at"] == "2026-05-10T12:00:00Z"


# ---------- /api/broker/event/{id}/substitutions (substitution checker, row phase) ----------

def test_substitutions_empty_event_degrades_cleanly(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"listings_snapshots": []}))
    body = client.get("/api/broker/event/1/substitutions?section=104&row=12").json()
    assert body["event_id"] == 1
    assert body["captured_at"] is None
    assert body["subs"] == [] and body["ambiguous"] == []
    assert body["counts"]["scanned"] == 0


def test_substitutions_finds_same_section_better_row(client, monkeypatch):
    # All owned rows share one captured_at so the FakeSupabase "latest" probe
    # and the row pull resolve to the same snapshot.
    rows = [
        {"tevo_ticket_group_id": "best", "captured_at": "2026-05-10T12:00:00Z",
         "section": "104", "row": "5", "quantity": 2, "retail_price": 400, "is_owned": True},
        {"tevo_ticket_group_id": "same", "captured_at": "2026-05-10T12:00:00Z",
         "section": "104", "row": "12", "quantity": 2, "retail_price": 250, "is_owned": True},
        {"tevo_ticket_group_id": "worse", "captured_at": "2026-05-10T12:00:00Z",
         "section": "104", "row": "20", "quantity": 2, "retail_price": 150, "is_owned": True},
        {"tevo_ticket_group_id": "othersec", "captured_at": "2026-05-10T12:00:00Z",
         "section": "105", "row": "1", "quantity": 2, "retail_price": 900, "is_owned": True},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"listings_snapshots": rows}))
    body = client.get("/api/broker/event/1/substitutions?section=104&row=12&quantity=2&revenue=600").json()
    assert body["captured_at"] == "2026-05-10T12:00:00Z"
    assert body["source"] == "owned"
    # cheapest-first: same-row $250 outranks the $400 upgrade; downgrade +
    # other section excluded.
    assert [s["ticket_group_id"] for s in body["subs"]] == ["same", "best"]
    assert body["best"]["ticket_group_id"] == "same"
    # revenue 600 / qty 2 = 300/tix; same-row cost 250 -> +50/tix, +100 total.
    assert body["best"]["pnl_per_ticket"] == 50.0
    assert body["best"]["pnl_total"] == 100.0
    assert body["counts"]["scanned"] == 3  # 3 in section 104


def test_substitutions_owned_pool_merges_sg_seller_book(client, monkeypatch):
    # TEvo owned holds only a pricey upgrade; our SG seller book holds a cheap
    # same-row lot. The seller sub must win (cheapest) and be tagged sg_seller.
    ls = [
        {"tevo_ticket_group_id": "tevo_up", "captured_at": "2026-05-10T12:00:00Z",
         "section": "310", "row": "9", "quantity": 4, "retail_price": 281.05, "is_owned": True},
    ]
    seller = [
        # older snapshot of the same listing — must be superseded by latest.
        {"seller_listing_id": "SLR1", "section": "310", "row": "14", "quantity": 4,
         "cost": 99.0, "pulled_at": "2026-05-09T00:00:00Z", "tevo_event_id": 3100123},
        {"seller_listing_id": "SLR1", "section": "310", "row": "14", "quantity": 4,
         "cost": 17.95, "pulled_at": "2026-05-10T00:00:00Z", "tevo_event_id": 3100123},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": ls, "seatgeek_seller_listings": seller,
    }))
    body = client.get("/api/broker/event/3100123/substitutions"
                      "?section=310&row=14&quantity=4&revenue=67.12").json()
    assert body["best"]["ticket_group_id"] == "SLR1"
    assert body["best"]["inv_source"] == "sg_seller"
    assert body["best"]["unit_cost"] == 17.95  # latest pulled_at wins over 99.0
    assert body["best"]["match_type"] == "same"
    # both lots qualify (seller same-row + TEvo upgrade), seller is cheaper.
    assert [s["ticket_group_id"] for s in body["subs"]] == ["SLR1", "tevo_up"]


def test_substitutions_section_fallback_offers_better_section(client, monkeypatch):
    # No same-section (310) sub, but we own a better-section lot (108). The
    # section phase should rank it by market quality (retail_median).
    ls = [
        {"tevo_ticket_group_id": "lower", "captured_at": "2026-05-10T12:00:00Z",
         "section": "108", "row": "20", "quantity": 4, "retail_price": 180, "is_owned": True},
    ]
    section_metrics = [
        {"section": "310", "retail_median": 50, "is_ancillary": False, "captured_at": "2026-05-10T12:00:00Z"},
        {"section": "108", "retail_median": 200, "is_ancillary": False, "captured_at": "2026-05-10T12:00:00Z"},
        {"section": "LOT A", "retail_median": 999, "is_ancillary": True, "captured_at": "2026-05-10T12:00:00Z"},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": ls, "section_metrics": section_metrics,
    }))
    body = client.get("/api/broker/event/1/substitutions"
                      "?section=310&row=14&quantity=4&revenue=400").json()
    assert body["subs"] == []  # nothing in-section
    ss = body["section_subs"]
    assert ss["best"]["to_section"] == "108"
    assert ss["best"]["match_type"] == "section_upgrade"
    assert ss["best"]["section_delta"] == 150  # 200 - 50
    assert ss["sold_quality"] == 50


def test_substitutions_market_fee_lands_cost(client, monkeypatch):
    rows = [
        {"tevo_ticket_group_id": "ask", "captured_at": "2026-05-10T12:00:00Z",
         "section": "310", "row": "14", "quantity": 4, "retail_price": 100, "is_owned": False},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"listings_snapshots": rows}))
    body = client.get("/api/broker/event/1/substitutions"
                      "?section=310&row=14&quantity=4&revenue=400&source=market&fee_pct=25").json()
    assert body["fee_pct"] == 25.0
    b = body["best"]
    assert b["unit_cost"] == 100      # raw ask
    assert b["landed_cost"] == 125.0  # +25% buyer fee
    assert b["pnl_per_ticket"] == round(100 - 125.0, 2)  # revenue 400/4=100/tix


def test_substitutions_quantity_filter_and_ambiguous_bucket(client, monkeypatch):
    rows = [
        {"tevo_ticket_group_id": "toofew", "captured_at": "2026-05-10T12:00:00Z",
         "section": "FLOOR", "row": "3", "quantity": 1, "retail_price": 100, "is_owned": True},
        {"tevo_ticket_group_id": "alpha", "captured_at": "2026-05-10T12:00:00Z",
         "section": "FLOOR", "row": "A", "quantity": 4, "retail_price": 100, "is_owned": True},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"listings_snapshots": rows}))
    body = client.get("/api/broker/event/1/substitutions?section=FLOOR&row=5&quantity=2").json()
    # numeric "3" would upgrade but lacks quantity; alpha "A" is incomparable.
    assert body["subs"] == []
    assert [s["ticket_group_id"] for s in body["ambiguous"]] == ["alpha"]


def test_substitutions_market_pool_spans_gotickets(client, monkeypatch):
    # The merged pool: same physical section under two labels. GoTickets quotes
    # all-in retail, which here undercuts the exchange ask for the same row.
    ls = [
        {"tevo_ticket_group_id": "ask", "captured_at": "2026-09-01T16:00:00Z",
         "section": "311", "row": "O", "quantity": 2, "splits": [2],
         "retail_price": 262.10, "is_owned": False},
    ]
    gt = [
        {"gt_listing_id": 7086439326, "gt_event_id": 1252283,
         "captured_at": "2026-09-01T15:34:00Z", "section": "Promenade  311",
         "section_id": 3262193, "row": "O", "quantity": 2, "splits": [2],
         "all_in_price": 254.44, "display_price": 254.44},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": ls, "gotickets_listings_snapshots": gt,
    }))
    body = client.get("/api/broker/event/3170362/substitutions"
                      "?section=311&row=R&quantity=2&revenue=560&source=market").json()
    assert body["pools"] == ["tevo_market", "gotickets"]
    assert body["gt_captured_at"] == "2026-09-01T15:34:00Z"
    # Both are same-section (the GT zone prefix is reconciled) better-row subs;
    # cheapest first puts GoTickets on top.
    assert [x["inv_source"] for x in body["subs"]] == ["gotickets", "tevo_market"]
    best = body["best"]
    assert best["unit_cost"] == 254.44
    assert best["buy_url"] == ("https://pro.gotickets.com/tickets/1252283/"
                              "?sortBy=price&sortDirection=asc&sections=3262193")
    assert best["pnl_total"] == round((280.0 - 254.44) * 2, 2)


def test_substitutions_market_all_in_price_is_not_fee_marked_up(client, monkeypatch):
    # fee_pct applies to the exchange ask only — GoTickets is already all-in.
    ls = [
        {"tevo_ticket_group_id": "ask", "captured_at": "2026-09-01T16:00:00Z",
         "section": "311", "row": "M", "quantity": 2, "retail_price": 250.0,
         "is_owned": False},
    ]
    gt = [
        {"gt_listing_id": 1, "gt_event_id": 1252283, "captured_at": "2026-09-01T15:34:00Z",
         "section": "Promenade  311", "section_id": 3262193, "row": "M",
         "quantity": 2, "splits": [2], "all_in_price": 255.0, "display_price": 255.0},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": ls, "gotickets_listings_snapshots": gt,
    }))
    body = client.get("/api/broker/event/3170362/substitutions"
                      "?section=311&row=R&quantity=2&source=market&fee_pct=10").json()
    landed = {x["inv_source"]: x["landed_cost"] for x in body["subs"]}
    assert landed["tevo_market"] == 275.0   # 250 + 10%
    assert landed["gotickets"] == 255.0     # unchanged
    assert body["best"]["inv_source"] == "gotickets"


def test_substitutions_owned_pool_never_reads_gotickets(client, monkeypatch):
    ls = [
        {"tevo_ticket_group_id": "mine", "captured_at": "2026-09-01T16:00:00Z",
         "section": "311", "row": "M", "quantity": 2, "retail_price": 300.0,
         "is_owned": True},
    ]
    gt = [
        {"gt_listing_id": 1, "gt_event_id": 1252283, "captured_at": "2026-09-01T15:34:00Z",
         "section": "Promenade  311", "section_id": 3262193, "row": "M",
         "quantity": 2, "all_in_price": 1.0, "display_price": 1.0},
    ]
    fake = FakeSupabase(table_data={
        "listings_snapshots": ls, "gotickets_listings_snapshots": gt,
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/3170362/substitutions"
                      "?section=311&row=R&quantity=2").json()
    # We don't hold GoTickets stock, so an owned swap must not see it — not
    # even the $1 bait row.
    assert body["pools"] == ["tevo_owned", "sg_seller"]
    assert body["gt_captured_at"] is None
    assert "gotickets_listings_snapshots" not in fake.table_calls
    assert [x["inv_source"] for x in body["subs"]] == ["tevo_owned"]


def test_substitutions_market_without_gotickets_data(client, monkeypatch):
    ls = [
        {"tevo_ticket_group_id": "ask", "captured_at": "2026-09-01T16:00:00Z",
         "section": "311", "row": "M", "quantity": 2, "retail_price": 250.0,
         "is_owned": False},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": ls, "gotickets_listings_snapshots": [],
    }))
    body = client.get("/api/broker/event/3170362/substitutions"
                      "?section=311&row=R&quantity=2&source=market").json()
    assert body["pools"] == ["tevo_market"]
    assert body["gt_captured_at"] is None
    assert body["best"]["inv_source"] == "tevo_market"


def test_substitutions_gotickets_ambiguous_section_labels_need_a_human(client, monkeypatch):
    # A venue fielding both "Loge 106" and "Lower 106" can't resolve a bare
    # sold section "106" — those surface as ambiguous, never as a cover.
    gt = [
        {"gt_listing_id": 1, "gt_event_id": 900, "captured_at": "2026-09-01T15:00:00Z",
         "section": "Loge 106", "section_id": 11, "row": "5", "quantity": 2,
         "all_in_price": 100.0, "display_price": 100.0},
        {"gt_listing_id": 2, "gt_event_id": 900, "captured_at": "2026-09-01T15:00:00Z",
         "section": "Lower 106", "section_id": 12, "row": "5", "quantity": 2,
         "all_in_price": 110.0, "display_price": 110.0},
        # Unlabelled row: no section at all, so it can never match either.
        {"gt_listing_id": 3, "gt_event_id": 900, "captured_at": "2026-09-01T15:00:00Z",
         "section": "", "section_id": None, "row": "5", "quantity": 2,
         "all_in_price": 90.0, "display_price": 90.0},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": [], "gotickets_listings_snapshots": gt,
    }))
    body = client.get("/api/broker/event/900/substitutions"
                      "?section=106&row=9&quantity=2&source=market").json()
    assert body["subs"] == []
    assert {a["section"] for a in body["ambiguous"]} == {"Loge 106", "Lower 106"}
    assert body["best"] is None


def test_substitutions_gotickets_dedupes_and_falls_back_to_display_price(client, monkeypatch):
    # Same listing twice in one capture (first wins), and a null all_in_price
    # falls back to the display price rather than dropping the listing.
    gt = [
        {"gt_listing_id": 55, "gt_event_id": 1252283, "captured_at": "2026-09-01T15:34:00Z",
         "section": "Promenade  311", "section_id": 3262193, "row": "M",
         "quantity": 2, "all_in_price": None, "display_price": 258.96},
        {"gt_listing_id": 55, "gt_event_id": 1252283, "captured_at": "2026-09-01T15:34:00Z",
         "section": "Promenade  311", "section_id": 3262193, "row": "M",
         "quantity": 2, "all_in_price": 999.0, "display_price": 999.0},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": [], "gotickets_listings_snapshots": gt,
    }))
    body = client.get("/api/broker/event/3170362/substitutions"
                      "?section=311&row=R&quantity=2&source=market").json()
    assert len(body["subs"]) == 1
    assert body["subs"][0]["unit_cost"] == 258.96


def test_substitutions_gotickets_link_omitted_without_section_id(client, monkeypatch):
    gt = [
        {"gt_listing_id": 7, "gt_event_id": 1252283, "captured_at": "2026-09-01T15:34:00Z",
         "section": "Promenade  311", "section_id": None, "row": "M",
         "quantity": 2, "all_in_price": 200.0, "display_price": 200.0},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": [], "gotickets_listings_snapshots": gt,
    }))
    body = client.get("/api/broker/event/3170362/substitutions"
                      "?section=311&row=R&quantity=2&source=market").json()
    # Still linkable to the event page; just not filtered to the section.
    assert body["best"]["buy_url"] == (
        "https://pro.gotickets.com/tickets/1252283/?sortBy=price&sortDirection=asc")


# ---------- /api/broker/order-lookup (order # -> sub fields) ----------

def test_order_lookup_seatgeek(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"seatgeek_orders": [{
        "sg_order_id": "SG123", "tevo_event_id": 3100123, "sg_event_name": "Braves at Padres",
        "sale_section": "310", "sale_row": "14", "sale_quantity": 4,
        "payment_total": 67.12, "payment_price": 60.0,
    }]}))
    body = client.get("/api/broker/order-lookup?order_id=SG123").json()
    assert body["found"] is True and body["source"] == "seatgeek"
    assert body["tevo_event_id"] == 3100123
    assert body["section"] == "310" and body["row"] == "14" and body["quantity"] == 4
    assert body["revenue"] == 67.12


def test_order_lookup_tickpick_when_source_pinned(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"tickpick_orders": [{
        "tp_order_id": "TP9", "tevo_event_id": 5, "event_name": "X", "section": "A",
        "row": "2", "quantity": 2, "total": 100,
    }]}))
    body = client.get("/api/broker/order-lookup?order_id=TP9&source=tickpick").json()
    assert body["source"] == "tickpick" and body["section"] == "A" and body["revenue"] == 100


def test_order_lookup_evo_uses_first_item_and_counts(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={
        "evo_orders": [{"evo_order_id": 42, "tevo_event_id": 7, "total": 500, "subtotal": 450}],
        "evo_order_items": [
            {"ticket_group_section": "100", "ticket_group_row": "5", "quantity": 2,
             "event_name": "Y", "event_id": 7},
            {"ticket_group_section": "200", "ticket_group_row": "9", "quantity": 2,
             "event_name": "Y", "event_id": 7},
        ],
    }))
    body = client.get("/api/broker/order-lookup?order_id=42").json()
    assert body["source"] == "evo" and body["section"] == "100" and body["row"] == "5"
    assert body["revenue"] == 450  # subtotal preferred
    assert body["line_items"] == 2


def test_order_lookup_evo_accepts_composite_tevo_order_number(client, monkeypatch):
    # TEvo displays "<purchase_order>-<order_id>"; we key on the trailing id.
    _use_db(monkeypatch, FakeSupabase(table_data={
        "evo_orders": [{"evo_order_id": 19056200, "tevo_event_id": 3170362,
                        "total": 560, "subtotal": 560}],
        "evo_order_items": [
            {"ticket_group_section": "311", "ticket_group_row": "R", "quantity": 2,
             "event_name": "US Open Session 8", "event_id": 3170362},
        ],
    }))
    body = client.get("/api/broker/order-lookup?order_id=8036615-19056200").json()
    assert body["found"] is True and body["source"] == "evo"
    assert body["evo_order_id"] == 19056200
    assert body["section"] == "311" and body["row"] == "R"
    assert body["quantity"] == 2 and body["revenue"] == 560


def test_order_lookup_not_found(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    body = client.get("/api/broker/order-lookup?order_id=NOPE").json()
    assert body["found"] is False
    assert "note" in body


# ---------- order-lookup → S4K CRM fallback (the two markets we don't ingest) ----------

class _FakeCRM:
    """Stands in for s4kcs_client.S4KCSClient."""

    def __init__(self, row=None, raises=None):
        self._row, self._raises = row, raises
        self.asked = []

    def find_order(self, order_id):
        self.asked.append(order_id)
        if self._raises is not None:
            raise self._raises
        return self._row


def _use_crm(monkeypatch, crm):
    monkeypatch.setattr(app_module, "_s4kcs_client", lambda: crm)


def test_order_lookup_reads_the_stored_s4kcs_book_first(client, monkeypatch):
    # Ingested every 10 min, so the table answers without a 10MB live fetch.
    crm = _FakeCRM(row={"source": "StubHub", "id": "644308803"})
    _use_crm(monkeypatch, crm)
    _use_db(monkeypatch, FakeSupabase(table_data={"v_s4kcs_orders": [{
        "source": "StubHub", "s4k_order_id": "644308803",
        "order_status": "Upload Transfer Receipts",
        "event_name": "US Open Tennis: Session 11", "event_date": "2026-09-04",
        "venue_name": "Louis Armstrong Stadium", "section": "3", "row": "N",
        "seats": "", "quantity": 2, "price": 870.34,
        "delivery": "Mobile Tickets", "inhand_date": "2026-09-02",
        "tevo_event_id": None,
    }]}))
    body = client.get("/api/broker/order-lookup?order_id=644308803").json()
    assert body["found"] is True and body["via"] == "s4kcs_orders"
    assert body["source"] == "StubHub" and body["revenue"] == 870.34
    assert body["section"] == "3" and body["row"] == "N"
    assert crm.asked == []  # the live API was never touched


def test_order_lookup_takes_the_vivid_price_from_our_own_book(client, monkeypatch):
    # The CRM ships Vivid rows with no price; v_s4kcs_orders substitutes the
    # total from vivid_orders, so the lookup reports real revenue.
    _use_crm(monkeypatch, _FakeCRM())
    _use_db(monkeypatch, FakeSupabase(table_data={"v_s4kcs_orders": [{
        "source": "Vivid Seats", "s4k_order_id": "81252078", "section": "5",
        "row": "12", "quantity": 2, "price": 240.0, "crm_price": None,
        "price_source": "vivid_orders", "tevo_event_id": 3100123,
    }]}))
    body = client.get("/api/broker/order-lookup?order_id=81252078").json()
    assert body["revenue"] == 240.0
    assert body["tevo_event_id"] == 3100123


def test_order_lookup_stored_row_carries_a_mapped_event_id(client, monkeypatch):
    # Once the AQ mapper fills tevo_event_id the lookup can search directly,
    # so no "pick the event" note is emitted.
    _use_crm(monkeypatch, _FakeCRM())
    _use_db(monkeypatch, FakeSupabase(table_data={"v_s4kcs_orders": [{
        "source": "Gametime", "s4k_order_id": "G1", "section": "12", "row": "4",
        "quantity": 2, "price": 100.0, "tevo_event_id": 3170362,
    }]}))
    body = client.get("/api/broker/order-lookup?order_id=G1").json()
    assert body["tevo_event_id"] == 3170362
    assert body["note"] is None


def test_order_lookup_falls_back_to_s4k_crm(client, monkeypatch):
    # A StubHub order: real shape from the CRM book. We ingest no StubHub
    # orders, so before this fallback it resolved to nothing at all.
    _use_db(monkeypatch, FakeSupabase())
    crm = _FakeCRM(row={
        "source": "StubHub", "id": "644308803", "section": "3", "row": "N",
        "quantity": 2, "price": 870.34, "event_name": "US Open Tennis: Session 11",
        "event_date": "2026-09-04", "venue_name": "Louis Armstrong Stadium",
        "inhand_date": "2026-09-02", "delivery": "Mobile Tickets", "seats": "",
        "order_status": "Upload Transfer Receipts",
    })
    _use_crm(monkeypatch, crm)
    body = client.get("/api/broker/order-lookup?order_id=644308803").json()
    assert body["found"] is True
    # Nothing stored for it yet (created since the last 10-min poll), so the
    # live book answered.
    assert body["source"] == "StubHub" and body["via"] == "s4k_crm"
    assert body["section"] == "3" and body["row"] == "N" and body["quantity"] == 2
    assert body["revenue"] == 870.34
    assert body["event_date"] == "2026-09-04"
    assert body["order_status"] == "Upload Transfer Receipts"
    # The CRM knows no canonical event id — that's the AQ mapper's job, not a
    # name+date guess here, so the caller is told to pick the event.
    assert body["tevo_event_id"] is None
    assert "pick the event" in body["note"]
    assert crm.asked == ["644308803"]


def test_order_lookup_prefers_an_ingested_book_over_the_crm(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"tickpick_orders": [{
        "tp_order_id": "TP9", "tevo_event_id": 5, "event_name": "X",
        "section": "A", "row": "2", "quantity": 2, "total": 100,
    }]}))
    crm = _FakeCRM(row={"source": "StubHub", "id": "TP9"})
    _use_crm(monkeypatch, crm)
    body = client.get("/api/broker/order-lookup?order_id=TP9").json()
    assert body["source"] == "tickpick" and body["tevo_event_id"] == 5
    assert crm.asked == []  # never consulted — we had it already


def test_order_lookup_crm_miss_reports_both_books(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    _use_crm(monkeypatch, _FakeCRM(row=None))
    body = client.get("/api/broker/order-lookup?order_id=NOPE").json()
    assert body["found"] is False
    assert "S4K CRM" in body["note"]


def test_order_lookup_crm_failure_degrades(client, monkeypatch):
    # Upstream down / key revoked: say so rather than claiming "not found".
    _use_db(monkeypatch, FakeSupabase())
    _use_crm(monkeypatch, _FakeCRM(raises=RuntimeError("HTTP 401")))
    body = client.get("/api/broker/order-lookup?order_id=644308803").json()
    assert body["found"] is False
    assert "lookup failed" in body["note"] and "RuntimeError" in body["note"]


# ---------- server-side client factory ----------

def test_s4kcs_client_factory_builds_when_key_present(monkeypatch):
    monkeypatch.setenv("S4KCS_API_KEY", "s4k_env")
    monkeypatch.setattr(app_module, "require_sb", lambda: None)
    c = app_module._s4kcs_client()
    assert c is not None and c.api_key == "s4k_env"


def test_s4kcs_client_factory_returns_none_without_a_key(monkeypatch, capsys):
    monkeypatch.delenv("S4KCS_API_KEY", raising=False)
    monkeypatch.setattr(app_module, "require_sb", lambda: None)
    assert app_module._s4kcs_client() is None
    assert "s4kcs: client unavailable" in capsys.readouterr().out


# ---------- /api/broker/sub-worklist (the substitution QUEUE) ----------

def _wl_row(**over):
    row = {
        "source": "StubHub", "s4k_order_id": "abc", "tevo_event_id": 3287886,
        "event_name": "Vikings at Patriots", "event_date": "2026-12-10",
        "venue_name": "Gillette Stadium", "order_status": "Under Review",
        "sub_signal": "probable", "section": "112", "order_row": "21",
        "quantity": 2, "sold_ea": 382.0, "sold_total": 764.0,
        "candidates": 3, "best_sub_source": "tevo", "best_price_basis": "tevo_retail",
        "best_listing_id": 99, "best_section": "112", "best_row": "17",
        "best_qty": 2, "best_ea": 300.0, "best_total": 600.0,
        "margin_ea": 82.0, "margin_total": 164.0, "rows_closer": 4,
        "buy_url": None, "listing_captured_at": "2026-09-09T19:00:00Z",
        "refreshed_at": "2026-09-09T19:05:00Z",
    }
    row.update(over)
    return row


def test_sub_worklist_empty_reports_no_refresh_time(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"s4kcs_sub_worklist": []}))
    body = client.get("/api/broker/sub-worklist").json()
    assert body["rows"] == [] and body["count"] == 0
    # no rows -> nothing to report a refresh time from, rather than "now"
    assert body["refreshed_at"] is None
    assert body["with_candidate"] == 0
    assert body["filters"]["source"] is None


def test_sub_worklist_counts_only_rows_with_a_candidate(client, monkeypatch):
    # candidates=0 rows stay in the queue on purpose (the whole book is in
    # scope), so with_candidate must not simply equal the row count.
    rows = [_wl_row(), _wl_row(s4k_order_id="def", candidates=0,
                              best_listing_id=None, margin_total=None)]
    _use_db(monkeypatch, FakeSupabase(table_data={"s4kcs_sub_worklist": rows}))
    body = client.get("/api/broker/sub-worklist").json()
    assert body["count"] == 2
    assert body["with_candidate"] == 1
    assert body["refreshed_at"] == "2026-09-09T19:05:00Z"


def test_sub_worklist_applies_every_filter(client, monkeypatch):
    fake = FakeSupabase(table_data={"s4kcs_sub_worklist": [_wl_row()]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/sub-worklist"
                      "?source=StubHub&with_sub=true&days=30&limit=5&offset=10").json()
    assert body["filters"] == {"source": "StubHub", "with_sub": True, "days": 30,
                               "limit": 5, "offset": 10}
    assert body["count"] == 1


def test_sub_worklist_with_sub_false_selects_the_gap(client, monkeypatch):
    # the "nothing qualified" side of the filter is its own branch
    rows = [_wl_row(candidates=0, best_listing_id=None, margin_total=None)]
    _use_db(monkeypatch, FakeSupabase(table_data={"s4kcs_sub_worklist": rows}))
    body = client.get("/api/broker/sub-worklist?with_sub=false").json()
    assert body["filters"]["with_sub"] is False
    assert body["with_candidate"] == 0


def _cov_row(**over):
    row = {
        "n2s_id": 436, "order_number": "P8L5T1EUKG", "s4k_source": "Gametime",
        "n2s_order_key": "P8L5T1EUKG",
        "n2s_status": "n2s", "fail_reason": "Unknown", "timer_expired": True,
        "event_name": "US Open Tennis - Session 21", "event_date": "2026-09-12",
        "venue": "Arthur Ashe Stadium", "tevo_event_id": 3287886,
        "section": "317", "order_row": "P", "quantity": 2, "sold_ea": 42.0,
        "sub_source": "gotickets", "sub_listing_id": "7167764492",
        "sub_section": "317", "sub_row": "H", "sub_qty": 2, "sub_avail": 2,
        "sub_ea": 61.0,
        "sub_total": 122.0, "cover_cost": 38.0, "rows_closer": 8,
        "buy_url": None, "captured_at": "2026-09-09T22:00:00Z",
        "cover_rank": 1, "fifo_position": 3,
        "cover_gate": 2, "cover_label": "S4KTrading",
        "refreshed_at": "2026-09-09T22:05:00Z", "alert_at": "2026-09-09T21:00:00Z",
        "has_cover": True, "no_cover_reason": None,
        "open_intent_id": None, "open_intent_by": None,
    }
    row.update(over)
    return row


def _gap_row(**over):
    """An open obligation with NO cover — the majority of the real book, and
    what this panel used to omit entirely."""
    row = _cov_row(**over)
    row.update({
        "sub_source": None, "sub_listing_id": None, "sub_section": None,
        "sub_row": None, "sub_qty": None, "sub_avail": None,
        "sub_ea": None, "sub_total": None,
        "cover_cost": None, "rows_closer": None, "buy_url": None,
        "captured_at": None, "cover_rank": None, "fifo_position": None,
        "refreshed_at": None, "has_cover": False, "no_cover_reason": "no_match",
    })
    row.update(over)
    return row


def test_n2s_covers_empty_reports_no_refresh_time(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": []}))
    body = client.get("/api/broker/n2s-covers").json()
    assert body["rows"] == [] and body["count"] == 0
    # A stale/absent payload must read as "no answer", never "no covers", so an
    # empty page reports no refresh time rather than now().
    assert body["refreshed_at"] is None
    assert body["total_cover_cost"] == 0
    assert body["at_or_below_sale"] == 0 and body["displaced"] == 0


def test_n2s_covers_separates_cost_from_saving(client, monkeypatch):
    # cover_cost is signed: positive costs us, negative means the cover is
    # cheaper than the sale. The count must not be "all rows".
    rows = [_cov_row(), _cov_row(n2s_id=437, cover_cost=-93.62)]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": rows}))
    body = client.get("/api/broker/n2s-covers").json()
    assert body["count"] == 2
    assert body["at_or_below_sale"] == 1
    assert body["total_cover_cost"] == -55.62
    assert body["refreshed_at"] == "2026-09-09T22:05:00Z"


def test_n2s_covers_counts_fifo_displaced_orders(client, monkeypatch):
    # cover_rank > 1 means an earlier order claimed the cheaper listing; that
    # is contention worth surfacing, not a row to hide.
    rows = [_cov_row(), _cov_row(n2s_id=438, cover_rank=2)]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": rows}))
    body = client.get("/api/broker/n2s-covers").json()
    assert body["displaced"] == 1


def test_n2s_covers_treats_missing_cover_rank_as_first_choice(client, monkeypatch):
    rows = [_cov_row(cover_rank=None)]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": rows}))
    body = client.get("/api/broker/n2s-covers").json()
    assert body["displaced"] == 0


def test_n2s_covers_ignores_rows_with_no_cost(client, monkeypatch):
    rows = [_cov_row(cover_cost=None)]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": rows}))
    body = client.get("/api/broker/n2s-covers").json()
    assert body["total_cover_cost"] == 0
    assert body["at_or_below_sale"] == 0


def test_n2s_covers_keeps_orders_that_have_no_sub(client, monkeypatch):
    """The whole point of the rewrite: an uncovered obligation is the WORK, so
    it must be served, counted and explained — not omitted the way reading
    n2s_cover_queue directly used to omit it."""
    rows = [_cov_row(), _gap_row(n2s_id=500),
            _gap_row(n2s_id=501, no_cover_reason="unmapped")]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": rows}))
    body = client.get("/api/broker/n2s-covers").json()
    assert body["count"] == 3
    assert body["covered"] == 1
    assert body["uncovered"] == 2
    assert body["by_no_cover_reason"] == {"no_match": 1, "unmapped": 1}
    # A row with no cover contributes no cost — NULL is "nothing allocated",
    # not a free settlement.
    assert body["total_cover_cost"] == 38.0


def test_n2s_covers_refreshed_at_comes_from_a_covered_row(client, monkeypatch):
    """Uncovered rows carry no refreshed_at (nothing was computed for them), so
    a book that leads with gaps must still report when the covers were built —
    otherwise the freshness stamp reads as 'never' on a healthy pipeline."""
    rows = [_gap_row(n2s_id=500), _cov_row()]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": rows}))
    body = client.get("/api/broker/n2s-covers").json()
    assert body["refreshed_at"] == "2026-09-09T22:05:00Z"


def test_n2s_covers_reports_pipeline_freshness_when_the_page_is_empty(client, monkeypatch):
    """A filter must not look like an outage. With every open order late and
    include_late=false the page is empty, so no SERVED row carries a
    refreshed_at — but the matcher is still running, and reading "never
    refreshed" there would send the operator hunting a dead pipeline."""
    late = _cov_row(timer_expired=True, refreshed_at="2026-09-09T22:05:00Z")
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": [late]}))
    body = client.get("/api/broker/n2s-covers?with_sub=true").json()
    assert body["refreshed_at"] == "2026-09-09T22:05:00Z"


def test_n2s_covers_with_sub_filter_is_passed_through(client, monkeypatch):
    fake = FakeSupabase(table_data={"v_n2s_orders": [_cov_row()]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/n2s-covers?with_sub=false").json()
    assert body["filters"]["with_sub"] is False


def test_n2s_covers_serves_the_lot_size_of_a_split_take(client, monkeypatch):
    """sub_qty is what we buy and what the vendor payload owes; sub_avail is the
    listing's whole lot. Both must reach the panel — dropping sub_avail makes a
    2-of-4 split take indistinguishable from a 2-seat listing, and the operator
    finds out only in the vendor console."""
    split = _cov_row(sub_qty=2, sub_avail=4)
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": [split]}))
    row = client.get("/api/broker/n2s-covers").json()["rows"][0]
    assert row["sub_qty"] == 2 and row["sub_avail"] == 4
    # Economics stay on what is owed, not on the lot we happen to draw from.
    assert row["sub_total"] == 122.0


def test_n2s_covers_serves_an_over_delivery_cover(client, monkeypatch):
    """An over-delivery buys a lot one seat bigger than the obligation. The
    panel needs sub_qty (3) and quantity (2) both intact to say so; collapsing
    them would have the operator buy 2 of a lot that only sells as 3."""
    over = _cov_row(quantity=2, sub_qty=3, sub_avail=3,
                    sub_total=1099.20, cover_cost=601.20)
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": [over]}))
    row = client.get("/api/broker/n2s-covers").json()["rows"][0]
    assert row["quantity"] == 2 and row["sub_qty"] == 3
    # A whole-lot buy is not a split take — the two markers are exclusive.
    assert row["sub_avail"] == row["sub_qty"]
    # The spare seat is inside the cost, not omitted from it.
    assert row["cover_cost"] == 601.20


def test_n2s_covers_profitable_filter_is_passed_through(client, monkeypatch):
    """Profitable means cover_cost < 0 — the obligation settles for less than
    the seat sold for. Break-even is excluded on purpose: it is not money."""
    _use_db(monkeypatch, FakeSupabase(
        table_data={"v_n2s_orders": [_cov_row(cover_cost=-99.62)]}))
    body = client.get("/api/broker/n2s-covers?profitable=true").json()
    assert body["filters"]["profitable"] is True
    # Default must stay off, or the panel would silently hide the gap rows
    # that are the whole point of this book.
    assert client.get("/api/broker/n2s-covers").json()["filters"]["profitable"] is False


def test_n2s_covers_hidden_late_count_respects_the_profit_filter(client, monkeypatch):
    """hidden_late says what the TIMER removed, so it must count the same book
    the page is showing. Counting the whole late book under profitable=true
    would advertise "N hidden" and send the operator to a Timer switch that
    reveals no profitable covers at all."""
    fake = FakeSupabase(table_data={"v_n2s_orders": [_cov_row(cover_cost=-99.62)]})
    _use_db(monkeypatch, fake)
    client.get("/api/broker/n2s-covers?profitable=true")
    # The double records each builder call; the count query must have narrowed
    # on cover_cost the same way the page query did.
    assert fake.table_calls.count("v_n2s_orders") == 2


def test_n2s_covers_serves_the_source_order_key(client, monkeypatch):
    """The panel needs the marketplace's own order id to look the obligation up
    while it is still live. EVO's order_number is an <invoice>-<order>
    composite, so the key is carried separately rather than parsed out here."""
    evo = _cov_row(s4k_source="EVO", order_number="8047273-19083928",
                   n2s_order_key="19083928")
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": [evo]}))
    row = client.get("/api/broker/n2s-covers").json()["rows"][0]
    assert row["order_number"] == "8047273-19083928"
    assert row["n2s_order_key"] == "19083928"


def test_n2s_covers_displaced_ignores_uncovered_rows(client, monkeypatch):
    """cover_rank is NULL on a gap row; it must not be read as first choice and
    counted into the contention figure."""
    rows = [_gap_row(n2s_id=500), _cov_row(n2s_id=438, cover_rank=2)]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": rows}))
    body = client.get("/api/broker/n2s-covers").json()
    assert body["displaced"] == 1


def test_n2s_covers_hides_late_by_default_and_says_how_many(client, monkeypatch):
    """The default filters out every order past its 15-minute CRM timer, which
    measured 108 of 108. An empty page must therefore report the hidden count —
    otherwise it reads as "nothing needs covering", the exact opposite of true."""
    fake = FakeSupabase(table_data={"v_n2s_orders": [_cov_row(), _cov_row(n2s_id=2)]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/n2s-covers").json()
    assert body["filters"]["include_late"] is False
    # The fake does not filter, so both the page query and the late-count query
    # see the same rows; what matters is that the count is reported at all.
    assert body["hidden_late"] == 2


def test_n2s_covers_include_late_skips_the_hidden_count(client, monkeypatch):
    fake = FakeSupabase(table_data={"v_n2s_orders": [_cov_row()]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/n2s-covers?include_late=true").json()
    assert body["filters"]["include_late"] is True
    assert body["hidden_late"] == 0


def test_n2s_covers_applies_every_filter(client, monkeypatch):
    fake = FakeSupabase(table_data={"v_n2s_orders": [_cov_row()]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/n2s-covers"
                      "?source=Gametime&days=14&limit=5&offset=10").json()
    assert body["filters"] == {"source": "Gametime", "days": 14,
                               "with_sub": None, "include_late": False,
                               "profitable": False,
                               "limit": 5, "offset": 10}
    assert body["count"] == 1


def _verify_row(**over):
    row = {
        "n2s_id": 436, "order_number": "P8L5T1EUKG", "s4k_source": "Gametime",
        "sub_source": "gotickets", "sub_listing_id": "7167764492",
        "quoted_ea": 61.0, "price_now": 61.0, "price_delta_ea": 0.0,
        "verdict": "ok", "buyable": True,
        "checked_at": "2026-09-09T23:40:00Z",
    }
    row.update(over)
    return row


def test_n2s_verify_empty_queue(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"n2s_cover_verify": []}))
    body = client.get("/api/broker/n2s-covers/verify").json()
    assert body["count"] == 0 and body["buyable"] == 0
    assert body["by_verdict"] == {}


def test_n2s_verify_counts_only_buyable_rows(client, monkeypatch):
    # `gone` and `order_closed` are hard blocks; `stale_data` means "cannot
    # tell", which must NOT count as buyable either.
    rows = [
        _verify_row(),
        _verify_row(n2s_id=437, verdict="price_up", price_now=70.0,
                    price_delta_ea=9.0, buyable=True),
        _verify_row(n2s_id=438, verdict="gone", price_now=None,
                    price_delta_ea=None, buyable=False),
        _verify_row(n2s_id=439, verdict="order_closed", buyable=False),
        _verify_row(n2s_id=440, verdict="stale_data", buyable=False),
    ]
    _use_db(monkeypatch, FakeSupabase(rpc_data={"n2s_cover_verify": rows}))
    body = client.get("/api/broker/n2s-covers/verify").json()
    assert body["count"] == 5
    assert body["buyable"] == 2
    assert body["by_verdict"] == {"ok": 1, "price_up": 1, "gone": 1,
                                  "order_closed": 1, "stale_data": 1}


def test_n2s_verify_labels_a_missing_verdict(client, monkeypatch):
    rows = [_verify_row(verdict=None, buyable=False)]
    _use_db(monkeypatch, FakeSupabase(rpc_data={"n2s_cover_verify": rows}))
    body = client.get("/api/broker/n2s-covers/verify").json()
    assert body["by_verdict"] == {"unknown": 1}


def test_n2s_verify_freshness_floor_is_one_minute(client, monkeypatch):
    # A zero/negative window would ask for "captured after now", which can only
    # ever answer stale_data — clamp it so the gate stays meaningful.
    fake = FakeSupabase(rpc_data={"n2s_cover_verify": [_verify_row()]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/n2s-covers/verify?freshness_minutes=0").json()
    assert fake.rpc_calls[0][1]["p_freshness"] == "1 minutes"
    assert body["freshness_minutes"] == 0


class _RaisingSupabase(FakeSupabase):
    """RPC that raises, to prove a deliberate DB refusal reaches the caller."""

    def __init__(self, exc, **kw):
        super().__init__(**kw)
        self._exc = exc

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params or {}))
        raise self._exc


def _intent_row(**over):
    row = {
        "intent_id": 1, "n2s_id": 436, "order_number": "81364906",
        "s4k_source": "Vivid Seats", "sub_source": "gotickets",
        "sub_listing_id": "7167764492", "sub_section": "623", "sub_row": "H",
        "sub_qty": 2, "quoted_ea": 140.0, "quoted_total": 280.0,
        "cover_cost": -99.62, "buy_url": "https://pro.gotickets.com/tickets/1/",
        "verify_verdict": "ok", "verify_delta": 0.0, "status": "requested",
        "requested_by": "julian@s4kent.com", "requested_at": "2026-09-09T23:50:00Z",
        "payload": {"endpoint": "POST https://gotickets.com/rest/pro/api/orders"},
        "payload_ready": True, "payload_gaps": [],
        "operator_fills": ["paymentMethodToken", "recipient__original_buyer_pii"],
        "notes": None,
    }
    row.update(over)
    return row


def test_buy_intent_records_without_buying(client, monkeypatch):
    # The buy is placed by hand in the vendor console, so the response carries
    # a fill sheet: what WE produced, plus what the human types at checkout.
    created = {"intent_id": 1, "status": "requested", "verdict": "ok",
               "payload_ready": True, "payload_gaps": [],
               "operator_fills": ["paymentMethodToken", "deliveryMethodId"]}
    fake = FakeSupabase(rpc_data={"n2s_buy_intent_create": [created]})
    _use_db(monkeypatch, fake)
    body = client.post("/api/broker/n2s-covers/436/buy-intent"
                       "?requested_by=julian").json()
    # The whole point: an intent is a record, never a purchase.
    assert body["bought"] is False
    assert body["intent"]["intent_id"] == 1
    # A sheet the operator must still complete is NOT a defect — it stays
    # "ready", because payload_ready reports only on what our side owes.
    assert body["intent"]["payload_ready"] is True
    assert body["intent"]["operator_fills"]
    assert fake.rpc_calls[0][1]["p_n2s_id"] == 436


def test_buy_intent_surfaces_a_refusal_as_409(client, monkeypatch):
    # "not buyable" / "no cover" / duplicate are deliberate DB refusals — the
    # caller must see the reason, not a bare 500.
    _use_db(monkeypatch, _RaisingSupabase(RuntimeError("cover is not buyable (gone)")))
    r = client.post("/api/broker/n2s-covers/436/buy-intent")
    assert r.status_code == 409
    assert "not buyable" in r.json()["detail"]


def test_buy_intent_empty_result_is_also_a_refusal(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"n2s_buy_intent_create": []}))
    r = client.post("/api/broker/n2s-covers/436/buy-intent")
    assert r.status_code == 409


def test_buy_intent_cancel_frees_the_order(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"n2s_buy_intent_cancel": [True]}))
    body = client.post("/api/broker/buy-intents/1/cancel?by=julian").json()
    assert body["status"] == "cancelled"


def test_buy_intent_cancel_missing_is_409(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"n2s_buy_intent_cancel": [False]}))
    assert client.post("/api/broker/buy-intents/9/cancel").status_code == 409


def test_buy_intent_cancel_scalar_response(client, monkeypatch):
    # supabase may hand back a bare scalar rather than a list
    _use_db(monkeypatch, FakeSupabase(rpc_data={"n2s_buy_intent_cancel": True}))
    assert client.post("/api/broker/buy-intents/1/cancel").json()["status"] == "cancelled"


def test_buy_intents_list_counts_what_our_side_still_owes(client, monkeypatch):
    # `complete` counts sheets with nothing left on OUR side. It deliberately
    # ignores operator_fills: if the human's checkout fields counted against a
    # sheet, none would ever read complete and the number would say nothing.
    rows = [_intent_row(),
            _intent_row(intent_id=2, payload_ready=False,
                        payload_gaps=["no_purchase_integration_for_seatgeek"],
                        operator_fills=[])]
    _use_db(monkeypatch, FakeSupabase(table_data={"n2s_buy_intent": rows}))
    body = client.get("/api/broker/buy-intents").json()
    assert body["count"] == 2
    assert body["complete"] == 1
    assert body["needs_us"] == 1
    assert body["status"] == "requested"


def test_buy_intents_list_selects_the_operator_fill_list(client, monkeypatch):
    # A sheet without operator_fills cannot be acted on — the operator would
    # not know what the console still wants from them.
    fake = FakeSupabase(table_data={"n2s_buy_intent": [_intent_row()]})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/buy-intents").json()
    assert "recipient__original_buyer_pii" in body["rows"][0]["operator_fills"]


def test_buy_intents_list_all_statuses(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"n2s_buy_intent": [_intent_row()]}))
    body = client.get("/api/broker/buy-intents?status=").json()
    assert body["status"] == "" and body["count"] == 1


def test_n2s_covers_exposes_gate_and_label(client, monkeypatch):
    """The gate cascade's classification must survive to the API.

    Regression guard for a real break: the cascade added cover_gate/cover_label
    to n2s_cover_candidates, but n2s_cover_queue, n2s_covers() and v_n2s_orders
    each had to be widened separately. Until the last landed, the label died one
    step downstream and the panel showed nothing — with no error anywhere.
    """
    rows = [_cov_row(),
            _cov_row(n2s_id=437, cover_gate=5,
                     cover_label="Index Down offer subs", cover_cost=-12.5)]
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": rows}))
    body = client.get("/api/broker/n2s-covers").json()
    got = {r["n2s_id"]: r for r in body["rows"]}
    assert got[436]["cover_gate"] == 2
    assert got[436]["cover_label"] == "S4KTrading"
    # gates 3-6 carry "offer subs": the buyer is MOVED and must consent first.
    assert got[437]["cover_gate"] == 5
    assert "offer subs" in got[437]["cover_label"]


def test_n2s_covers_gap_row_carries_no_gate(client, monkeypatch):
    """An uncovered obligation must not claim a gate.

    A gap row is the work, not a cover — labelling it would tell an operator
    there is something to act on when there is not.
    """
    _use_db(monkeypatch, FakeSupabase(table_data={"v_n2s_orders": [
        _gap_row(cover_gate=None, cover_label=None)]}))
    row = client.get("/api/broker/n2s-covers").json()["rows"][0]
    assert row["has_cover"] is False
    assert row["cover_gate"] is None and row["cover_label"] is None
