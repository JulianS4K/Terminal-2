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

    def in_(self, *_a, **_k):
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


def test_order_lookup_not_found(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    body = client.get("/api/broker/order-lookup?order_id=NOPE").json()
    assert body["found"] is False
    assert "note" in body
