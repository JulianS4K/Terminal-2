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
            return type("R", (), {"data": [{"id": 1, "label": "t", "tier": tier}] if tier else []})()
        return type("R", (), {"data": self.db.rpc_data.get(self.name)})()


class FakeDB:
    def __init__(self, tables=None, rpc_data=None, errors=None):
        self.tables = tables or {}
        self.rpc_data = rpc_data or {}
        self.errors = errors or {}
        self.keys = {m.hash_key(INT_KEY): "internal", m.hash_key(EXT_KEY): "external",
                     m.hash_key("s4k_weird"): "admin"}
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
    assert out["seatgeek_market"] == {"days": 30, "tracked": False, "total_sales": 0, "daily": []}
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
    assert ext == {"search_events", "event_market"}
    assert ext < {f.__name__ for f in m.INTERNAL_TOOLS}
    # Nothing that exposes our book is reachable on the external tier.
    assert not ext & {"pickups", "event_orders", "query_view", "owned_events", "market_chart"}


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
        assert init.status_code == 200 and init.json()["result"]["serverInfo"]["name"] == "s4k-terminal"

        ext_tools = {t["name"] for t in _rpc_call(c, EXT_KEY, "tools/list").json()["result"]["tools"]}
        assert ext_tools == {"search_events", "event_market"}
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
