"""Tests for the /mcp server (routers/mcp_api.py, mounted in server.py).

Pins: API-key → tier resolution, tier separation (external callers never see
internal tools), each tool's query/RPC contract and clamping, the query_view
whitelist, and the Streamable HTTP round trip through the real FastAPI app.
No real DB: a fake Supabase client records the query chain and returns canned
rows per table / RPC.
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import anyio
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

pytest.importorskip("mcp")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402
from routers import mcp_api as m  # noqa: E402

TestClient = starlette_testclient.TestClient

INT_KEY, EXT_KEY = "s4k_int_test", "s4k_ext_test"


class _Query:
    """Chainable stand-in for a postgrest query; records every call."""

    def __init__(self, db, table):
        self.db, self.table, self.calls = db, table, []

    def __getattr__(self, name):
        def call(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            return self
        return call

    def execute(self):
        self.db.queries.append(self)
        return type("R", (), {"data": self.db.tables.get(self.table)})()


class _Rpc:
    def __init__(self, db, name, args):
        self.db, self.name, self.args = db, name, args

    def execute(self):
        self.db.rpcs.append((self.name, self.args))
        if self.name in self.db.errors:
            raise self.db.errors[self.name]
        if self.name == "mcp_verify_key":
            tier = self.db.keys.get(self.args["p_key_hash"])
            row = {"id": 1, "label": "t", "tier": tier, **self.db.limits.get(tier, {})}
            return type("R", (), {"data": [row] if tier else []})()
        return type("R", (), {"data": self.db.rpc_data.get(self.name)})()


class FakeDB:
    def __init__(self, tables=None, rpc_data=None, errors=None):
        self.tables = tables or {}
        self.rpc_data = rpc_data or {}
        self.errors = errors or {}
        self.keys = {m.hash_key(INT_KEY): "internal", m.hash_key(EXT_KEY): "external",
                     m.hash_key("s4k_weird"): "admin"}
        self.limits: dict = {}
        self.queries, self.rpcs = [], []

    def table(self, name):
        return _Query(self, name)

    def rpc(self, name, args):
        return _Rpc(self, name, args)


# ---------------------------------------------------------------- helpers

def test_hash_and_clamp():
    assert m.hash_key("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    assert m._clamp("x", 1, 5, 3) == 3
    assert m._clamp(None, 1, 5, 3) == 3
    assert m._clamp(99, 1, 5, 3) == 5
    assert m._clamp(-4, 1, 5, 3) == 1


# ---------------------------------------------------------------- tools

def test_search_events_filters():
    db = FakeDB(tables={"events": [{"id": 1}]})
    out = m.search_events(db, query=" Colts ", date_from="2026-10-10T00", date_to="2026-10-20", limit=500)
    assert out == {"events": [{"id": 1}], "count": 1}
    calls = db.queries[0].calls
    assert ("ilike", ("name", "%Colts%"), {}) in calls
    assert ("gte", ("occurs_at_local", "2026-10-10"), {}) in calls
    assert ("lte", ("occurs_at_local", "2026-10-20T23:59:59"), {}) in calls
    assert ("limit", (100,), {}) in calls


def test_search_events_defaults():
    db = FakeDB()
    out = m.search_events(db)
    assert out == {"events": [], "count": 0}
    names = [c[0] for c in db.queries[0].calls]
    assert "ilike" not in names and "lte" not in names and "gte" in names


def test_event_market_not_found():
    assert m.event_market(FakeDB(), 5) == {"error": "event 5 not found"}


def test_event_market_dedupes_and_groups():
    sales = [
        {"sg_sale_id": 1, "sale_at_utc": "2026-10-01T10:00:00Z", "quantity": 2, "broadcast_price": 100},
        {"sg_sale_id": 1, "sale_at_utc": "2026-10-01T10:00:00Z", "quantity": 2, "broadcast_price": 100},
        {"sg_sale_id": 2, "sale_at_utc": "2026-10-01T12:00:00Z", "quantity": None, "broadcast_price": 50},
        {"sg_sale_id": 3, "sale_at_utc": "2026-10-02T12:00:00Z", "quantity": 4, "broadcast_price": None},
    ]
    db = FakeDB(tables={"events": [{"id": 7, "name": "X"}], "seatgeek_sales_snapshots": sales,
                        "event_competitors_snapshot": [{"competitors_count": 3, "competitors": []}]})
    out = m.event_market(db, 7, days=0)
    mk = out["seatgeek_market"]
    assert mk["days"] == 1 and mk["tracked"] is True and mk["total_sales"] == 3
    assert mk["daily"] == [
        {"day": "2026-10-01", "sales": 2, "tickets": 2, "median_price": 100.0},
        {"day": "2026-10-02", "sales": 1, "tickets": 4, "median_price": None},
    ]
    assert out["competing_events"]["competitors_count"] == 3


def test_event_market_untracked_no_competitors():
    db = FakeDB(tables={"events": [{"id": 7}]})
    out = m.event_market(db, 7)
    assert out["seatgeek_market"] == {"days": 30, "tracked": False, "total_sales": 0, "daily": [],
                                      "last_sale_at": None}
    assert out["competing_events"] == {"competitors_count": 0, "competitors": []}


def test_pickups_args():
    db = FakeDB(rpc_data={"get_d0_pickups_v2": [{"tevo_event_id": 1}]})
    assert m.pickups(db, mode="COLD", days=99, min_days_out=50, max_days_out=10, limit=0) == {
        "mode": "cold", "events": [{"tevo_event_id": 1}]}
    assert db.rpcs[0] == ("get_d0_pickups_v2", {"p_mode": "cold", "p_window_days": 14,
                                                "p_min_days_out": 50, "p_max_days_out": 50, "p_limit": 1})
    assert m.pickups(FakeDB(), mode="anything") == {"mode": "hot", "events": []}


def test_rpc_backed_tools():
    db = FakeDB(rpc_data={"get_event_orders_daily": {"totals": {}}, "get_event_source_links": {"sg_url": "u"},
                          "get_home_stats": {"coverage": {}}, "get_sg_market_chart": [{"rank": 1}],
                          "get_owned_events_upcoming": [{"event_id": 2}]})
    assert m.event_orders(db, 3, days=1000) == {"totals": {}}
    assert ("get_event_orders_daily", {"p_event_id": 3, "p_days": 365}) in db.rpcs
    assert m.event_source_links(db, 3) == {"sg_url": "u"}
    assert m.home_stats(db) == {"coverage": {}}
    assert ("get_home_stats", {}) in db.rpcs
    assert m.market_chart(db, offset=-5, limit=999) == {"events": [{"rank": 1}]}
    assert ("get_sg_market_chart", {"p_offset": 0, "p_limit": 200}) in db.rpcs
    assert m.owned_events(db, days=0) == {"events": [{"event_id": 2}]}
    empty = FakeDB()
    assert m.event_orders(empty, 1) == {}
    assert m.event_source_links(empty, 1) == {}
    assert m.home_stats(empty) == {}
    assert m.market_chart(empty) == {"events": []}
    assert m.owned_events(empty) == {"events": []}


def test_query_view_rejections():
    db = FakeDB()
    assert "views" in m.query_view(db, "pg_authid")
    assert "allowed" in m.query_view(db, "events", columns=["id", "chat_ping_count"])
    assert "allowed" in m.query_view(db, "events", filters=[{"column": "secret", "value": 1}])
    assert "ops" in m.query_view(db, "events", filters=[{"column": "id", "op": "like", "value": 1}])
    assert m.query_view(db, "events", filters=[{"column": "id", "op": "in", "value": 1}]) == {
        "error": "op 'in' needs a list value"}
    assert "allowed" in m.query_view(db, "events", order_by="chat_ping_count")
    assert db.queries == []


def test_query_view_builds_query():
    db = FakeDB(tables={"v_s4kcs_orders": [{"source": "StubHub"}]})
    out = m.query_view(db, "v_s4kcs_orders", columns=["source", "quantity"],
                       filters=[{"column": "tevo_event_id", "value": 9},
                                {"column": "source", "op": "in", "value": ["StubHub", "Vivid Seats"]},
                                {"column": "quantity", "op": "gte", "value": 2}],
                       order_by="purchase_date", descending=True, limit=10_000)
    assert out == {"view": "v_s4kcs_orders", "rows": [{"source": "StubHub"}], "count": 1}
    calls = db.queries[0].calls
    assert calls[0] == ("select", ("source,quantity",), {})
    assert ("eq", ("tevo_event_id", 9), {}) in calls
    assert ("in_", ("source", ["StubHub", "Vivid Seats"]), {}) in calls
    assert ("gte", ("quantity", 2), {}) in calls
    assert ("order", ("purchase_date",), {"desc": True}) in calls
    assert ("limit", (500,), {}) in calls


def test_query_view_default_columns():
    db = FakeDB()
    out = m.query_view(db, "events")
    assert out == {"view": "events", "rows": [], "count": 0}
    assert db.queries[0].calls[0] == ("select", (",".join(m.QUERY_VIEWS["events"]),), {})


def test_tier_tool_sets():
    ext = {f.__name__ for f in m.EXTERNAL_TOOLS}
    assert ext == {"search", "search_events", "event_market", "event_prices", "top_market_events",
                   "performer_trend", "price_movers", "competing_events", "prediction_markets",
                   "sports_context", "news", "event_weather", "price_forecast", "team_report",
                   "event_sales", "zone_prices", "zone_trend", "game_context",
                   "model_price_prediction", "data_freshness", "query_public_view", "get_started"}
    assert ext < {f.__name__ for f in m.INTERNAL_TOOLS}
    # Nothing that exposes our book is reachable on the external tier.
    assert not ext & {"pickups", "event_orders", "query_view", "owned_events", "market_chart",
                      "event_source_links", "home_stats", "team_book", "polling_coverage"}
    # ...and no owned/order column leaks through the public view whitelist.
    for cols in m.EXTERNAL_QUERY_VIEWS.values():
        assert not [c for c in cols if "owned" in c or "order" in c or "email" in c or "phone" in c
                    or "wholesale" in c]
    assert "v_s4kcs_orders" not in m.EXTERNAL_QUERY_VIEWS and "v_s4kcs_orders" in m.QUERY_VIEWS


# ---------------------------------------------------------------- auth

def test_resolve_tier():
    db = FakeDB()
    app = m.MCPApp(lambda: db)
    assert app.resolve_tier({}) is None
    assert app.resolve_tier({"authorization": "Basic abc"}) is None
    assert app.resolve_tier({"authorization": f"Bearer {INT_KEY}"}) == "internal"
    assert app.resolve_tier({"x-api-key": EXT_KEY}) == "external"
    assert app.resolve_tier({"x-api-key": "nope"}) is None
    assert app.resolve_tier({"x-api-key": "s4k_weird"}) is None
    db.errors["mcp_verify_key"] = RuntimeError("db down")
    assert app.resolve_tier({"x-api-key": INT_KEY}) is None


# ---------------------------------------------------------------- HTTP

H = {"accept": "application/json, text/event-stream", "content-type": "application/json"}


def _rpc_call(client, key, method, params=None):
    headers = dict(H, authorization=f"Bearer {key}") if key else H
    body = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        body["params"] = params
    return client.post("/mcp/", headers=headers, json=body)


@pytest.fixture
def fake_db(monkeypatch):
    db = FakeDB(rpc_data={"get_d0_pickups_v2": [{"tevo_event_id": 42}]},
                tables={"events": [{"id": 1, "name": "Colts"}]})
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    return db


def test_http_requires_key(fake_db):
    with TestClient(app_module.app) as c:
        r = _rpc_call(c, None, "tools/list")
        assert r.status_code == 401
        assert r.headers["www-authenticate"].startswith("Bearer")
        assert _rpc_call(c, "bogus", "tools/list").status_code == 401


def test_http_not_started(fake_db):
    c = TestClient(app_module.app)  # no `with` → lifespan never ran
    assert _rpc_call(c, INT_KEY, "tools/list").status_code == 503


def test_http_tiers_and_calls(fake_db):
    with TestClient(app_module.app) as c:
        init = _rpc_call(c, EXT_KEY, "initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
        assert init.status_code == 200 and init.json()["result"]["serverInfo"]["name"] == "s4k-market"

        ext_tools = {t["name"] for t in _rpc_call(c, EXT_KEY, "tools/list").json()["result"]["tools"]}
        assert ext_tools == {f.__name__ for f in m.EXTERNAL_TOOLS}
        # cached tools expose their real signature, not the wrapper's
        chart = next(t for t in _rpc_call(c, EXT_KEY, "tools/list").json()["result"]["tools"]
                     if t["name"] == "top_market_events")
        assert set(chart["inputSchema"]["properties"]) == {"limit", "chart_date"}
        int_list = _rpc_call(c, INT_KEY, "tools/list").json()["result"]["tools"]
        assert {t["name"] for t in int_list} == {f.__name__ for f in m.INTERNAL_TOOLS}
        pk = next(t for t in int_list if t["name"] == "pickups")
        assert "db" not in pk["inputSchema"]["properties"] and "mode" in pk["inputSchema"]["properties"]
        assert pk["annotations"]["readOnlyHint"] is True

        # External caller cannot invoke an internal tool.
        denied = _rpc_call(c, EXT_KEY, "tools/call", {"name": "pickups", "arguments": {}}).json()
        assert "error" in denied or denied["result"]["isError"] is True

        ok = _rpc_call(c, INT_KEY, "tools/call", {"name": "pickups", "arguments": {"mode": "hot"}}).json()
        assert ok["result"]["isError"] is False and "42" in ok["result"]["content"][0]["text"]
        ev = _rpc_call(c, EXT_KEY, "tools/call", {"name": "search_events", "arguments": {"query": "Colts"}}).json()
        assert "Colts" in ev["result"]["content"][0]["text"]

        # First connect: initialize carries the "call get_started" instruction, and the
        # onboarding guide is listed as a resource and a prompt.
        assert "get_started" in init.json()["result"]["instructions"]
        res = _rpc_call(c, EXT_KEY, "resources/list").json()["result"]["resources"]
        assert [r["uri"] for r in res] == ["s4k://onboarding"]
        guide = _rpc_call(c, EXT_KEY, "resources/read", {"uri": "s4k://onboarding"}).json()
        assert "S4K Market MCP" in guide["result"]["contents"][0]["text"]
        prompts = _rpc_call(c, EXT_KEY, "prompts/list").json()["result"]["prompts"]
        assert [p["name"] for p in prompts] == ["get_started"]


# ---------------------------------------------------------------- external tools (2026-10-21)

@pytest.fixture(autouse=True)
def _fresh_cache():
    m.reset_cache()
    yield
    m.reset_cache()


def test_as_of_blocks():
    assert m._as_of(None) == {"as_of": None, "age_hours": None, "stale": True}
    assert m._as_of("not a date") == {"as_of": "not a date", "age_hours": None, "stale": True}
    recent = m._as_of(datetime.now(timezone.utc).isoformat())
    assert recent["stale"] is False and recent["age_hours"] < 1
    old = m._as_of("2026-01-01T00:00:00Z")
    assert old["stale"] is True and old["age_hours"] > 1000
    naive = m._as_of("2026-01-01T00:00:00")
    assert naive["stale"] is True


def test_search_and_event_prices():
    db = FakeDB(rpc_data={"price_tracker_search": {"performers": [{"id": 1}], "venues": [], "events": []},
                          "price_tracker_event": {"event": {"id": 9}, "current": {"captured_at": "2026-09-27T03:44:40+00:00"}}})
    assert m.search(db, "  Lakers ", limit=999)["performers"] == [{"id": 1}]
    assert db.rpcs[0] == ("price_tracker_search", {"p_q": "Lakers", "p_limit": 25})
    out = m.event_prices(db, 9)
    assert out["freshness"]["stale"] is True and out["event"] == {"id": 9}
    assert m.event_prices(FakeDB(), 9) == {"error": "event 9 not found"}
    assert m.search(FakeDB(), "x") == {"query": "x"}


def test_top_market_events_latest_and_history():
    rows = [{"chart_date": "2026-10-21", "rank": 1, "prev_rank": 3}, {"chart_date": "2026-10-21", "rank": 2, "prev_rank": None}]
    db = FakeDB(tables={"sg_market_chart": rows})
    out = m.top_market_events(db, limit=0)
    assert out["chart_date"] == "2026-10-21" and out["count"] == 2
    assert [r["rank_change"] for r in out["events"]] == [2, None]
    assert len(db.queries) == 2  # head + rows
    # cached: same args → no new queries
    assert m.top_market_events(db, limit=0) is out and len(db.queries) == 2
    hist = m.top_market_events(db, chart_date="2026-10-01T00:00")
    assert hist["chart_date"] == "2026-10-01" and len(db.queries) == 3  # rows only
    assert m.top_market_events(FakeDB())["events"] == []


def test_performer_trend():
    rows = [{"snapshot_date": "2026-10-20", "performer_name": "Colts"}, {"snapshot_date": "2026-10-21", "performer_name": "Colts"}]
    db = FakeDB(tables={"performer_metrics_daily": rows})
    out = m.performer_trend(db, 51, days=5000, split="bogus")
    assert out["split"] == "all" and out["days"] == 730 and out["performer_name"] == "Colts"
    assert out["freshness"]["as_of"] == "2026-10-21"
    empty = m.performer_trend(FakeDB(), 51, split="home")
    assert empty["series"] == [] and empty["performer_name"] is None and empty["split"] == "home"


def test_price_movers_scoring_and_names():
    agg = [
        {"event_id": 1, "window_days": 30, "computed_at": "2026-10-21T07:20:00+00:00", "days_to_event": 3,
         "sg_price_recent": 110, "sg_price_prior": 100, "sg_cur_price": 112,
         "ev_price_recent": 50, "ev_price_prior": 100, "ev_cur_price": 48},
        {"event_id": 2, "window_days": 30, "computed_at": "2026-10-21T07:20:00+00:00", "days_to_event": 9,
         "sg_price_recent": 80, "sg_price_prior": 100, "sg_cur_price": 79},
        {"event_id": 3, "window_days": 30, "computed_at": "2026-10-21T07:20:00+00:00", "sg_price_recent": 5, "sg_price_prior": None},
        {"event_id": 4, "window_days": 30, "computed_at": "2026-10-20T07:20:00+00:00", "sg_price_recent": 999, "sg_price_prior": 1},
    ]
    db = FakeDB(tables={"event_movers_agg": agg, "events": [{"id": 1, "name": "A"}, {"id": 2, "name": "B"}]})
    up = m.price_movers(db, window_days=99, direction="UP", source="seatgeek", limit=10)
    assert up["window_days"] == 30 and [x["event_id"] for x in up["movers"]] == [1, 2]
    assert up["movers"][0]["change_pct"] == 10.0 and up["movers"][0]["event"] == {"id": 1, "name": "A"}
    assert up["movers"][0]["all_sources"]["tevo"] == {"recent": 50, "prior": 100, "now": 48}
    down = m.price_movers(db, window_days=30, direction="down", source="tevo", limit=1)
    assert down["source"] == "tevo" and [x["event_id"] for x in down["movers"]] == [1]
    assert down["movers"][0]["change_pct"] == -50.0
    assert m.price_movers(FakeDB(), source="nope")["movers"] == []


def test_competing_prediction_sports_news_weather():
    db = FakeDB(tables={
        "event_competitors_snapshot": [{"tevo_event_id": 1, "competitors_count": 2, "competitors": [], "refreshed_at": "2026-10-21T11:40:00Z"}],
        "prediction_market_xref": [{"market_id": "m1"}],
        "prediction_markets": [{"market_id": "m1", "updated_at": "2026-10-21T17:43:00Z"}],
        "espn_event_snapshots": [{"espn_event_id": "e1", "captured_at": "2026-10-21T17:40:00Z"}],
        "v_reddit_news_ticker": [{"title": "t", "created_utc": "2026-10-21T18:01:00Z"}],
        "v_event_weather_with_fallback": [{"tevo_event_id": 1, "is_indoor": True}],
    })
    assert m.competing_events(db, 1)["competitors_count"] == 2
    assert m.competing_events(FakeDB(), 1) == {"event_id": 1, "competitors_count": 0, "competitors": [],
                                               "freshness": m._as_of(None)}
    by_event = m.prediction_markets(db, event_id=1)
    assert by_event["count"] == 1 and by_event["freshness"]["as_of"] == "2026-10-21T17:43:00Z"
    assert ("eq", ("tevo_event_id", 1), {}) in db.queries[1].calls
    m.prediction_markets(db, performer_id=5)
    assert ("eq", ("tevo_performer_id", 5), {}) in db.queries[3].calls
    assert m.prediction_markets(FakeDB(), event_id=1) == {"markets": [], "count": 0, "freshness": m._as_of(None)}
    league = m.prediction_markets(db, league="nfl", limit=0)
    assert ("eq", ("league", "NFL"), {}) in db.queries[-1].calls and league["count"] == 1
    assert m.prediction_markets(db)["count"] == 1  # unfiltered: latest markets
    games = m.sports_context(db, "NFL", espn_event_id="e1")
    assert games["count"] == 1 and games["freshness"]["as_of"] == "2026-10-21T17:40:00Z"
    assert ("eq", ("espn_league", "nfl"), {}) in db.queries[-1].calls
    assert m.sports_context(FakeDB(), "nba")["games"] == []
    n = m.news(db, league="NFL", query=" rookie ")
    assert n["count"] == 1 and ("ilike", ("title", "%rookie%"), {}) in db.queries[-1].calls
    assert m.news(FakeDB())["items"] == []
    assert m.event_weather(db, 1) == {"tevo_event_id": 1, "is_indoor": True}
    assert m.event_weather(FakeDB(), 1) == {"error": "event 1 not found"}


def test_data_freshness_cached():
    db = FakeDB(rpc_data={"mcp_data_freshness": {"feeds": [{"feed": "news"}]}})
    assert m.data_freshness(db)["feeds"][0]["feed"] == "news"
    assert m.data_freshness(db)["feeds"] and len(db.rpcs) == 1  # argument-keyed cache
    m.reset_cache()
    assert m.data_freshness(FakeDB()) == {"feeds": []}


def test_ttl_cache_evicts_oldest():
    c = m._TTLCache(60.0, max_items=1)
    c.put("a", 1)
    c.put("b", 2)
    assert c.get("a") is None and c.get("b") == 2
    c.put("b", 3)  # existing key: no eviction needed
    assert c.get("b") == 3


def test_query_public_view_whitelist():
    db = FakeDB()
    out = m.query_public_view(db, "v_s4kcs_orders")
    assert "error" in out and "v_s4kcs_orders" not in out["views"]
    bad = m.query_public_view(db, "event_listing_snapshot_daily", columns=["evo_owned_tickets"])
    assert bad["error"].startswith("columns not allowed")
    ok = m.query_public_view(db, "sg_market_chart", filters=[{"column": "rank", "op": "lte", "value": 5}],
                             order_by="rank", limit=5)
    assert ok == {"view": "sg_market_chart", "rows": [], "count": 0}


def test_price_forecast_explicit_section_strips_book():
    fc = {"expected_clearing": 214.2, "lo": 157.48, "hi": 321.33,
          "demand_context": {"own_book_gap": 12, "attendance": {"rank": 1}},
          "signals": [{"own_book_gap": 3, "realized_sale": 226}]}
    db = FakeDB(rpc_data={"predict_event_clearing_price": fc})
    out = m.price_forecast(db, 3285866, section="  226 ")
    assert db.rpcs == [("predict_event_clearing_price", {"p_event_id": 3285866, "p_section": "226"})]
    f = out["forecasts"][0]
    assert out["count"] == 1 and f["expected_clearing"] == 214.2
    assert f["demand_context"] == {"attendance": {"rank": 1}}
    assert f["signals"] == [{"realized_sale": 226}]
    assert db.queries == []  # explicit section: no sales scan


def test_price_forecast_picks_best_selling_sections():
    sales = [{"sg_sale_id": 1, "section": "226"}, {"sg_sale_id": 2, "section": "226"},
             {"sg_sale_id": 2, "section": "226"}, {"sg_sale_id": 3, "section": "Floor A"},
             {"sg_sale_id": 4, "section": "101"}, {"sg_sale_id": 5, "section": "101"},
             {"sg_sale_id": 6, "section": " "}, {"sg_sale_id": 7, "section": None}]
    db = FakeDB(tables={"seatgeek_sales_snapshots": sales},
                rpc_data={"predict_event_clearing_price": {"expected_clearing": 1}})
    out = m.price_forecast(db, 9, max_sections=2)
    asked = [a["p_section"] for _, a in db.rpcs]
    assert asked == ["101", "226"]  # ties by distinct-sale count, then name
    assert out["count"] == 2
    calls = db.queries[0].calls
    assert ("eq", ("tevo_event_id", 9), {}) in calls


def test_price_forecast_no_sales_and_empty_rpc():
    db = FakeDB(tables={"seatgeek_sales_snapshots": [], "section_metrics": []})
    out = m.price_forecast(db, 9)
    assert out["forecasts"] == [] and "pass `section`" in out["note"]
    db = FakeDB(rpc_data={})
    assert m.price_forecast(db, 9, section="x")["count"] == 0


def test_price_forecast_no_sales_falls_back_to_listed_inventory():
    secs = [{"section": "112", "tickets_count": 74, "is_ancillary": False, "captured_at": "t2"},
            {"section": "Parking", "tickets_count": 99, "is_ancillary": True, "captured_at": "t2"},
            {"section": "226", "tickets_count": 53, "is_ancillary": False, "captured_at": "t2"},
            {"section": "999", "tickets_count": 500, "is_ancillary": False, "captured_at": "t1"}]
    db = FakeDB(tables={"seatgeek_sales_snapshots": [], "section_metrics": secs},
                rpc_data={"predict_event_clearing_price": {"expected_clearing": 1}})
    out = m.price_forecast(db, 9, max_sections=5)
    assert [a["p_section"] for _, a in db.rpcs] == ["112", "226"]  # latest capture, no ancillary
    assert out["sections_picked_by"] == "listed_inventory"


def test_guard_forecast_anchors_prior_only_estimate_to_market():
    # Knicks 2026-10-23: no sales, stale team prior → model said 547.71 vs a 329.84 ask median.
    f = m._guard_forecast({"expected_clearing": 547.71, "lo": 361.38, "hi": 738.11,
                           "realized_sample_n": 0, "section_ask_median": 329.84,
                           "section_tickets": 74, "sold_to_ask_ratio": 0.5511,
                           "signals": {"ask_x_ratio": {"value": 181.78}}})
    assert f["expected_clearing"] == 181.78 and f["model_estimate"] == 547.71
    assert f["lo"] == 181.78 and f["hi"] == 329.84
    assert f["confidence"] == "low" and "anchored" in f["warning"]
    # no ask_x_ratio signal → ask x ratio
    f = m._guard_forecast({"expected_clearing": 500, "realized_sample_n": 0,
                           "section_ask_median": 200, "section_tickets": 5, "sold_to_ask_ratio": 0.5})
    assert f["expected_clearing"] == 100.0
    # no listings and no sales → warn, keep number
    f = m._guard_forecast({"expected_clearing": 90, "realized_sample_n": 0, "section_tickets": 0})
    assert f["expected_clearing"] == 90 and "prior-only" in f["warning"]
    # real sales → untouched, confidence by sample size
    f = m._guard_forecast({"expected_clearing": 400, "realized_sample_n": 8,
                           "section_ask_median": 300, "section_tickets": 9})
    assert f["expected_clearing"] == 400 and f["confidence"] == "high" and "warning" not in f
    assert m._guard_forecast({"realized_sample_n": 3})["confidence"] == "medium"


def test_team_report_args_and_normalizing():
    rep = {"team": {"performer_id": 16303}, "polling": [{"pin": "knicks_home"}], "games": [
               {"event_id": 1, "data_quality": "live"}, {"event_id": 2, "data_quality": "none"}],
           "reddit": None, "roster": None, "injuries": [{"name": "x"}]}
    db = FakeDB(rpc_data={"mcp_team_report": rep})
    out = m.team_report(db, " New York Knicks ", since="2026-08-14T00:00", max_games=99, news_limit=0)
    assert db.rpcs == [("mcp_team_report", {"p_team": "New York Knicks", "p_since": "2026-08-14",
                                            "p_home_only": True, "p_max_events": 41,
                                            "p_news_limit": 1})]
    assert out["reddit"] == [] and out["roster"] == [] and out["injuries"] == [{"name": "x"}]
    assert "polling" not in out  # our pins never reach the external tier
    assert any("Reddit" in n for n in out["data_notes"])
    assert any("[2]" in n for n in out["data_notes"])
    assert m.team_report(db, "16303", since="last week") == {"error": "since must be YYYY-MM-DD"}
    assert m.team_report(FakeDB(rpc_data={}), "nobody") == {"error": "no report"}
    clean = m.team_report(FakeDB(rpc_data={"mcp_team_report": {
        "games": [{"event_id": 1, "data_quality": "live"}], "reddit": [{"t": 1}]}}), "1")
    assert "data_notes" not in clean


def test_team_book_internal_only():
    book = {"totals": {"orders": 2555}, "polling": [{"pin": "knicks_home"}]}
    db = FakeDB(rpc_data={"mcp_team_book": book})
    assert m.team_book(db, "16303", since="2026-08-24", max_games=500) == book
    assert db.rpcs == [("mcp_team_book", {"p_team": "16303", "p_since": "2026-08-24",
                                          "p_home_only": False, "p_max_events": 120})]
    assert m.team_book(db, "16303", since="soon") == {"error": "since must be YYYY-MM-DD"}
    assert m.team_book(FakeDB(rpc_data={}), "x") == {"error": "no report"}
    assert m.team_book in m.INTERNAL_TOOLS and m.team_book not in m.EXTERNAL_TOOLS


def test_get_started_and_onboarding(monkeypatch, tmp_path):
    out = m.get_started(None)
    assert out["welcome"] == m.INSTRUCTIONS and "get_started" in m.INSTRUCTIONS
    assert out["quick_start"] and "S4K Market MCP" in out["guide_markdown"]
    monkeypatch.setattr(m, "GET_STARTED_PATH", tmp_path / "missing.md")
    assert m.get_started(None)["guide_markdown"] == ""


def test_server_exposes_onboarding_resource_and_prompt():
    srv = m._make_server("t", m.EXTERNAL_TOOLS, lambda: FakeDB())
    res = anyio.run(srv.list_resources)
    assert [str(r.uri) for r in res] == ["s4k://onboarding"]
    body = anyio.run(srv.read_resource, "s4k://onboarding")
    assert "S4K Market MCP" in str(body)
    prompts = anyio.run(srv.list_prompts)
    assert [p.name for p in prompts] == ["get_started"]
    msg = anyio.run(srv.get_prompt, "get_started", {"team": "Boston Celtics"})
    assert "Boston Celtics" in str(msg)


def test_tool_catalog_and_tool_name():
    cat = {t["name"]: t for t in m.tool_catalog()}
    assert cat["top_market_events"]["parameters"] == ["limit", "chart_date"]
    assert cat["search"]["description"].startswith("Find performers")
    assert m._tool_name(b'{"jsonrpc":"2.0","method":"tools/call","params":{"name":"news"}}') == "news"
    assert m._tool_name(b'[{"method":"initialize"}]') == "initialize"
    assert m._tool_name(b'{"method":"tools/call","params":{}}') == "tools/call"
    assert m._tool_name(b"") == "rpc" and m._tool_name(b"{garbage") == "rpc" and m._tool_name(b"[]") == "rpc"
    assert m._tool_name(b"42") == "rpc"


def test_resolve_key_limits_and_defaults():
    db = FakeDB()
    app = m.MCPApp(lambda: db)
    info = app.resolve_key({"x-api-key": EXT_KEY})
    assert info == {"id": 1, "tier": "external", "rate_per_min": 60, "daily_quota": 2000, "calls_today": 0}
    db.limits["external"] = {"rate_per_min": 5, "daily_quota": 10, "calls_today": 7}
    assert app.resolve_key({"x-api-key": EXT_KEY})["calls_today"] == 7
    assert app.resolve_key({"authorization": f"bearer {INT_KEY}"})["tier"] == "internal"
    # usage stamp never raises
    db.errors["mcp_count_call"] = RuntimeError("down")
    app._count(1, "news")
    assert db.rpcs[-1][0] == "mcp_count_call"


class _DenyLimiter:
    def check(self, key, n, w):
        self.last = (key, n, w)
        return False


def test_http_rate_and_quota(fake_db, monkeypatch):
    deny = _DenyLimiter()
    monkeypatch.setattr(app_module.mcp_app, "_limiter", deny)
    with TestClient(app_module.app) as c:
        r = _rpc_call(c, EXT_KEY, "tools/list")
        assert r.status_code == 429 and r.json()["error"] == "rate limited" and r.headers["retry-after"] == "60"
        assert deny.last == ("mcp:1", 60, 60.0)
    monkeypatch.setattr(app_module.mcp_app, "_limiter", None)
    fake_db.limits["external"] = {"daily_quota": 3, "calls_today": 3}
    with TestClient(app_module.app) as c:
        r = _rpc_call(c, EXT_KEY, "tools/list")
        assert r.status_code == 429 and r.json()["error"] == "daily quota exhausted"
        # internal key unaffected; its POST is counted with the tool name
        ok = _rpc_call(c, INT_KEY, "tools/call", {"name": "pickups", "arguments": {}})
        assert ok.status_code == 200
        assert ("mcp_count_call", {"p_key_id": 1, "p_tool": "pickups"}) in fake_db.rpcs


class _FakeManager:
    """Stands in for a StreamableHTTPSessionManager: records what it was handed."""

    def __init__(self):
        self.calls = []

    async def handle_request(self, scope, receive, send):
        body, more = b"", True
        while more:
            msg = await receive()
            body += msg.get("body", b"")
            more = msg.get("more_body", False)
        self.calls.append((scope["method"], body))
        if scope["method"] == "POST":
            # a real manager may read again after the body — must see the raw stream
            assert (await receive())["type"] == "http.disconnect"
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})


def _asgi(app, method, chunks, headers):
    """Drive the ASGI app once; return (status, body) and what it sent."""
    import anyio

    sent = []
    queue = list(chunks)

    async def receive():
        if queue:
            body = queue.pop(0)
            return {"type": "http.request", "body": body, "more_body": bool(queue)}
        return {"type": "http.disconnect"}

    async def send(msg):
        sent.append(msg)

    scope = {"type": "http", "method": method, "path": "/mcp",
             "headers": [(k.encode(), v.encode()) for k, v in headers.items()]}
    anyio.run(app, scope, receive, send)
    return sent


def test_asgi_get_passthrough_and_post_replay():
    db = FakeDB()
    app = m.MCPApp(lambda: db)
    mgr = _FakeManager()
    app._managers = {"external": mgr, "internal": mgr}
    hdr = {"authorization": f"Bearer {EXT_KEY}"}
    # GET: handed straight to the manager with the original receive; not stamped
    _asgi(app, "GET", [], hdr)
    assert mgr.calls == [("GET", b"")]
    assert not [r for r in db.rpcs if r[0] == "mcp_count_call"]
    # POST in two chunks: body re-assembled, replayed intact, stamped with the tool name
    body = b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"news","arguments":{}}}'
    sent = _asgi(app, "POST", [body[:20], body[20:]], hdr)
    assert mgr.calls[-1] == ("POST", body)
    assert ("mcp_count_call", {"p_key_id": 1, "p_tool": "news"}) in db.rpcs
    assert sent[0]["status"] == 200


# ---------------------------------------------------------------- market depth tools (2026-10-27)

def _iso(hours_ago: float) -> str:
    from datetime import timedelta
    return (datetime.now(timezone.utc) - timedelta(hours=hours_ago)).isoformat()


def test_event_sales_dedupes_and_summarises():
    rows = [  # newest first, sale 1 stored twice (older pulls re-stored every sale)
        {"sg_sale_id": "1", "sale_at_utc": "2026-10-26T20:00:00Z", "broadcast_price": 300, "quantity": 2,
         "section": "226", "row": "5", "pulled_at": _iso(1)},
        {"sg_sale_id": "1", "sale_at_utc": "2026-10-26T20:00:00Z", "broadcast_price": 300, "quantity": 2,
         "section": "226", "row": "5", "pulled_at": _iso(30)},
        {"sg_sale_id": "2", "sale_at_utc": "2026-10-25T20:00:00Z", "broadcast_price": 100, "quantity": 1,
         "section": "226", "row": "9", "pulled_at": _iso(30)},
        {"sg_sale_id": "3", "sale_at_utc": "2026-10-24T20:00:00Z", "broadcast_price": 200, "quantity": 4,
         "section": "227", "row": "1", "pulled_at": _iso(30)},
    ]
    db = FakeDB(tables={"seatgeek_sales_snapshots": rows})
    out = m.event_sales(db, 42, days=999, section=" 22 ", limit=2)
    assert out["summary"]["sales"] == 3 and out["summary"]["tickets"] == 7
    assert out["summary"]["price_median"] == 200 and out["summary"]["price_min"] == 100
    assert [s["sg_sale_id"] for s in out["sales"]] == ["1", "2"]
    assert "pulled_at" not in out["sales"][0]
    assert out["freshness"]["stale"] is False
    calls = db.queries[0].calls
    assert ("eq", ("tevo_event_id", 42), {}) in calls
    assert ("ilike", ("section", "%22%"), {}) in calls
    # min_quantity drops the single
    out2 = m.event_sales(db, 42, min_quantity=2)
    assert out2["summary"]["sales"] == 2


def test_zone_prices_latest_and_24h_change():
    rows = [
        {"event_id": 7, "captured_at": _iso(0.5), "zone": "Lower", "getin_price": 220, "retail_median": 400,
         "tickets_count": 90},
        {"event_id": 7, "captured_at": _iso(0.5), "zone": "Upper", "getin_price": 90, "retail_median": 150,
         "tickets_count": 300},
        {"event_id": 7, "captured_at": _iso(12), "zone": "Lower", "getin_price": 210, "retail_median": 390,
         "tickets_count": 95},
        {"event_id": 7, "captured_at": _iso(25), "zone": "Lower", "getin_price": 200, "retail_median": 380,
         "tickets_count": 100},
    ]
    db = FakeDB(tables={"zone_metrics": rows})
    out = m.zone_prices(db, 7)
    z = {r["zone"]: r for r in out["zones"]}
    assert [r["zone"] for r in out["zones"]] == ["Lower", "Upper"]   # by median, high first
    assert z["Lower"]["getin_change_24h_pct"] == 10.0 and z["Lower"]["tickets_change_24h"] == -10
    assert z["Upper"]["getin_change_24h_pct"] is None
    assert "event_id" not in z["Lower"]
    sel = db.queries[0].calls[0]
    assert sel == ("select", (m.ZONE_COLS,), {}) and "owned" not in m.ZONE_COLS and "wholesale" not in m.ZONE_COLS
    assert m.zone_prices(FakeDB(), 7)["zones"] == []


def test_zone_trend_groups_by_zone():
    rows = [{"zone": "Lower", "capture_date": "2026-10-25", "getin_price": 200},
            {"zone": "Upper", "capture_date": "2026-10-25", "getin_price": 90},
            {"zone": "Lower", "capture_date": "2026-10-26", "getin_price": 210}]
    db = FakeDB(tables={"zone_price_observations": rows})
    out = m.zone_trend(db, 7, zone="Lower", days=5000)
    assert set(out["zones"]) == {"Lower", "Upper"} and len(out["zones"]["Lower"]) == 2
    assert out["days"] == 365
    assert ("eq", ("zone", "Lower"), {}) in db.queries[0].calls


def test_game_context_columns_are_public():
    db = FakeDB(tables={"zone_price_observations": [{"capture_date": "2026-10-26", "mkt_spread": -4.5}]})
    out = m.game_context(db, 7, capture_date="2026-10-26T00:00")
    assert out["capture_date"] == "2026-10-26" and out["context"]["mkt_spread"] == -4.5
    assert ("eq", ("capture_date", "2026-10-26"), {}) in db.queries[0].calls
    assert not [c for c in m.GAME_CONTEXT_COLS if "owned" in c or "wholesale" in c]
    assert set(m.GAME_CONTEXT_COLS) <= set(m.EXTERNAL_QUERY_VIEWS["zone_price_observations"])
    assert m.game_context(FakeDB(), 7)["context"] is None


def test_model_price_prediction_with_and_without_run():
    db = FakeDB(tables={"v_ml_knicks_price_latest": [{"zone": "Lower", "predicted_price": 410}],
                        "ml_model_runs": [{"run_id": 3, "trained_at": _iso(2), "metrics": {"mdape_model": 18}}]})
    out = m.model_price_prediction(db, event_id=99)
    assert out["count"] == 1 and out["run"]["run_id"] == 3 and "note" not in out
    assert ("eq", ("tevo_event_id", 99), {}) in db.queries[0].calls
    assert ("eq", ("status", "ok"), {}) in db.queries[1].calls
    empty = m.model_price_prediction(FakeDB())
    assert empty["run"] is None and "note" in empty


def test_polling_coverage_internal_summary():
    db = FakeDB(tables={
        "listings_poll_pins": [{"pin_key": "knicks_home"}],
        "listings_poll_league_pins": [{"league": "NBA"}],
        "v_listings_poll_pinned_events": [
            {"tevo_event_id": 1, "pin_key": "knicks_home", "sources": ["evo", "sg"], "hours_to_event": 20},
            {"tevo_event_id": 2, "pin_key": "league:NBA", "sources": ["sg"], "hours_to_event": 200}],
        "sg_broker_pending": [{"rows_persisted": 5}, {"rows_persisted": 0}, {"rows_persisted": -429},
                              {"rows_persisted": -1}, {"rows_persisted": None}],
    })
    out = m.polling_coverage(db)
    assert out["games_total"] == 2 and out["games_by_pin"]["knicks_home"]["next_48h"] == 1
    assert out["games_by_pin"]["knicks_home"]["sources"] == {"evo": 1, "sg": 1}
    assert out["sg_sales_pulls_24h"] == {"pulls": 5, "ok": 2, "rate_limited": 1, "failed": 1,
                                         "pending": 1, "new_sales": 5}


def test_market_depth_edges():
    assert m._pctl([], 0.5) is None
    # a capture with an unparseable timestamp still counts as the zone's latest, never as "24 h ago"
    db = FakeDB(tables={"zone_metrics": [{"event_id": 7, "captured_at": "not-a-time", "zone": "Pit",
                                          "getin_price": 50, "retail_median": 80, "tickets_count": 4}]})
    z = m.zone_prices(db, 7)["zones"][0]
    assert z["zone"] == "Pit" and z["getin_change_24h_pct"] is None and z["tickets_change_24h"] is None
    db2 = FakeDB()
    assert m.zone_trend(db2, 7)["zones"] == {}
    assert not [c for c in db2.queries[0].calls if c[0] == "eq" and c[1][0] == "zone"]
