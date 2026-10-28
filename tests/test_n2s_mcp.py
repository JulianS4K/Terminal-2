"""Tests for the N2S MCP server (routers/n2s_mcp.py, mounted at /n2s-mcp).

Pins: it is a separate server (none of its tools leak onto /mcp), internal keys only
(an external key gets 403), each tool's query contract and derived fields, the
Ticketmaster primary parser, and the Streamable HTTP round trip. Reuses the fake
Supabase client from test_mcp_api.
"""
from __future__ import annotations

import pytest

pytest.importorskip("mcp")
starlette_testclient = pytest.importorskip("fastapi.testclient")

from routers import mcp_api as m
from routers import n2s_mcp as n
from tests.test_mcp_api import EXT_KEY, INT_KEY, FakeDB, H, app_module

TestClient = starlette_testclient.TestClient


def _call(client, key, method, params=None):
    body = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        body["params"] = params
    return client.post("/n2s-mcp/", headers=dict(H, authorization=f"Bearer {key}"), json=body)


def test_http_internal_only_and_tool_list(monkeypatch):
    db = FakeDB(tables={"n2s_crm_direct_log": [{"fetched_at": "2026-10-28T15:00:00Z", "status": 200,
                                                "new_orders": 2}]})
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    with TestClient(app_module.app) as c:
        # An external (market-data) key is refused outright, not served a smaller list.
        r = _call(c, EXT_KEY, "tools/list")
        assert r.status_code == 403 and r.json()["tier"] == "external"
        init = _call(c, INT_KEY, "initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
        assert init.json()["result"]["serverInfo"]["name"] == "s4k-n2s"
        assert "Need-to-Sub" in init.json()["result"]["instructions"]
        tools = _call(c, INT_KEY, "tools/list").json()["result"]["tools"]
        assert {t["name"] for t in tools} == {f.__name__ for f in n.N2S_TOOLS}
        assert all(t["annotations"]["readOnlyHint"] for t in tools)
        out = _call(c, INT_KEY, "tools/call", {"name": "n2s_health", "arguments": {}}).json()
        assert out["result"]["isError"] is False and '"new_orders": 2' in out["result"]["content"][0]["text"]
        # The market-data server is unchanged: no N2S tool on /mcp.
        mk = c.post("/mcp/", headers=dict(H, authorization=f"Bearer {INT_KEY}"),
                    json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).json()["result"]["tools"]
        assert not {t["name"] for t in mk} & {f.__name__ for f in n.N2S_TOOLS}


def test_n2s_book_filters_and_profit():
    db = FakeDB(tables={"v_n2s_orders": [
        {"n2s_id": 10, "has_cover": True, "cover_cost": -50.5},
        {"n2s_id": -8775238, "has_cover": False, "cover_cost": None, "no_cover_reason": "no_match"}]})
    out = n.n2s_book(db, source="StubHub", with_cover=True, profitable_only=True, ped_only=True, limit=9999)
    q = db.queries[-1]
    assert q.table == "v_n2s_orders"
    assert ("ilike", ("s4k_source", "%StubHub%"), {}) in q.calls
    assert ("eq", ("has_cover", True), {}) in q.calls and ("lt", ("cover_cost", 0), {}) in q.calls
    assert ("lt", ("n2s_id", 0), {}) in q.calls and ("limit", (500,), {}) in q.calls
    assert out["covered"] == 1 and out["uncovered"] == 1 and out["profitable"] == 1
    assert out["orders"][0]["profit"] == 50.5 and out["orders"][1]["ped"] is True


def test_n2s_order_and_history_and_ped():
    db = FakeDB(tables={"v_n2s_orders": [], "n2s_cover_history": [{"event_kind": "appeared"}],
                        "n2s_gt_order_dryrun": [_dry()], "inbox_n2b": [{"tevo_event_id": 1}, {"tevo_event_id": 1}]})
    o = n.n2s_order(db, "658199666")
    assert o["cover_history"] == [{"event_kind": "appeared"}] and o["gt_dryrun"][0]["profit"] == 662.5
    assert n.n2s_order(db, " ") == {"error": "order_number is required"}
    assert "error" in n.n2s_order(db, "1,n2s_id.gt.0")  # no filter injection
    h = n.n2s_cover_history(db, days=99, sub_source="gotickets", gate=9, event_kind="gone", limit=0)
    q = db.queries[-1]
    assert ("eq", ("cover_gate", 6), {}) in q.calls and ("eq", ("event_kind", "gone"), {}) in q.calls
    assert ("limit", (1,), {}) in q.calls and h["count"] == 1
    p = n.ped_orders(db, days_ahead=7)
    q = db.queries[-1]
    assert ("filter", ("order_no", "not.like", "TEST%"), {}) in q.calls and "gte" in [c[0] for c in q.calls]
    assert p["count"] == 2 and p["events"] == 1
    n.ped_orders(db, include_past=True)
    assert "gte" not in [c[0] for c in db.queries[-1].calls]


def test_tm_primary_parser_and_url_guard(monkeypatch):
    body = {"facets": [
        {"section": "VIP218", "inventoryTypes": ["primary"], "offers": ["A", "B"], "count": 2, "available": True},
        {"section": "VIP218", "inventoryTypes": ["primary"], "offers": ["A"], "count": 2},
        {"section": "308", "inventoryTypes": ["resale"], "offers": ["C"], "count": 4},
        {"section": "133", "inventoryTypes": ["primary"], "offers": ["B"], "count": 1, "available": False}],
        "_embedded": {"offer": [{"offerId": "A", "totalPrice": 776.75}, {"offerId": "B", "totalPrice": 926.15},
                                {"offerId": "C", "totalPrice": 100}]}}
    assert n._tm_primary_sections(body, ["vip218", "308"]) == {
        "VIP218": {"section": "VIP218", "seats": 4, "min_total_each": 776.75}}
    assert set(n._tm_primary_sections(body, [])) == {"VIP218"}  # resale + unavailable excluded
    assert "error" in n.tm_primary(FakeDB(), "https://evil.example/event/1")

    class FakeTD:
        @classmethod
        def from_vault(cls, db, timeout=30):
            return cls()

        def fetch(self, platform, url):
            assert platform == "ticketmaster"
            return {"status": 200, "quota_remaining": 249991, "body": body}

    import ticketsdata_client
    monkeypatch.setattr(ticketsdata_client, "TicketsDataClient", FakeTD)
    out = n.tm_primary(FakeDB(), "https://www.ticketmaster.com/x/event/0A00646588324539", ["VIP218"])
    assert out["quota_remaining"] == 249991 and out["primary_sections"][0]["min_total_each"] == 776.75



def _dry(**kw):
    r = {"dryrun_id": 1, "captured_at": "2026-10-27T22:00:00Z", "n2s_id": 5000, "order_number": "X",
         "s4k_source": "StubHub", "event_name": "Knicks at Celtics", "event_date": "2026-10-23",
         "sold_section": "308", "sold_row": "R", "sold_qty": 2, "sold_ea": 1215.3,
         "sub_section": "Upper 308", "sub_row": "C", "sub_qty": 2, "quoted_ea": 884.05,
         "quoted_total": 1768.1, "cover_cost": -662.5, "cover_gate": 1, "cover_label": "Index",
         "decision": "would_buy", "skip_reasons": [], "sub_view": "unknown",
         "payload": {"eventId": 1883123, "listingId": "7792279723", "_dry_run": True}}
    r.update(kw)
    return r


def test_gt_dryrun_flags_and_off_the_market_server():
    # N2S tools live on their own server, never on the market-data one.
    market = {f.__name__ for f in m.INTERNAL_TOOLS}
    assert not market & {f.__name__ for f in n.N2S_TOOLS}
    db = FakeDB(tables={"n2s_gt_order_dryrun": [
        _dry(),
        # The Floor-vs-Loge false match: both sides name a level and they differ.
        _dry(dryrun_id=2, sold_section="Floor 6", sub_section="Loge 6", cover_cost=-4100.54),
        _dry(dryrun_id=3, n2s_id=-8737820, decision="skip", cover_gate=5,
             skip_reasons=["gate_moves_buyer"], cover_cost=-1746.9)]})
    out = n.gt_dryrun(db, decision="would_buy", gate=1, ped_only=True, since="2026-10-21", limit=9999)
    q = db.queries[-1]
    assert q.table == "n2s_gt_order_dryrun"
    names = [c[0] for c in q.calls]
    assert ("eq", ("decision", "would_buy"), {}) in q.calls and ("eq", ("cover_gate", 1), {}) in q.calls
    assert ("lt", ("n2s_id", 0), {}) in q.calls and "gte" in names
    assert ("limit", (500,), {}) in q.calls
    r1, r2, r3 = out["rows"]
    assert r1["profit"] == 662.5 and not r1["level_mismatch"] and not r1["ped"]
    assert r1["gt_listing_id"] == "7792279723" and r1["would_send"]["_dry_run"] is True
    assert r2["level_mismatch"] is True
    # A gate-5 row can never be a level mismatch (the check is for gate-1 would-buys).
    assert r3["ped"] is True and r3["level_mismatch"] is False
    assert n.gt_dryrun(db, since="nope") == {"error": "since must be YYYY-MM-DD"}


def test_gt_dryrun_summary_aggregates():
    db = FakeDB(tables={"n2s_gt_order_dryrun": [
        _dry(),
        _dry(dryrun_id=2, n2s_id=5001, sold_section="Floor 6", sub_section="Loge 6", cover_cost=-4100.54,
             quoted_total=961.58),
        _dry(dryrun_id=3, n2s_id=5002, decision="skip", cover_gate=2, cover_cost=184.34,
             skip_reasons=["gate_moves_buyer"], payload={"listingId": "L1"}),
        _dry(dryrun_id=4, n2s_id=5003, decision="skip", cover_gate=2, cover_cost=192.74,
             skip_reasons=["gate_moves_buyer"], payload={"listingId": "L1"}),
        _dry(dryrun_id=5, n2s_id=-1, decision="skip", cover_gate=5, cover_cost=-1746.9,
             skip_reasons=["gate_moves_buyer"], payload={"listingId": "L2"})]})
    s = n.gt_dryrun_summary(db, days=999)
    assert s["days"] == 90 and s["rows"] == 5 and s["would_buy"] == 2 and s["skip"] == 3
    assert s["ped_rows"] == 1 and s["level_mismatches"] == 1
    assert s["would_buy_spend"] == 2729.68 and s["would_buy_profit"] == 4763.04
    assert s["by_gate"]["2"] == {"rows": 2, "would_buy": 0, "profitable": 0,
                                 "profit_available": 0.0, "loss": -377.08}
    assert s["by_gate"]["5"]["profit_available"] == 1746.9
    assert s["skip_reasons"] == {"gate_moves_buyer": 3}
    assert s["top_profitable_skips"][0]["dryrun_id"] == 5
    # Both would-buys point at one listing (the default fixture's) — exactly what a buyer
    # without a cross-order lock would double-buy — and two skips share L1.
    assert sorted(x["gt_listing_id"] for x in s["listings_on_multiple_orders"]) == ["7792279723", "L1"]


def test_defaults_edges_and_errors(monkeypatch):
    # Unfiltered calls add no filters; a NULL cost / no listing id / empty queue are tolerated.
    db = FakeDB(tables={"v_n2s_orders": [], "n2s_cover_history": [], "n2s_crm_direct_log": [],
                        "n2s_items": [], "n2s_gt_order_dryrun": [_dry(cover_cost=None, payload={})],
                        "n2s_cover_queue": [{"sub_source": "gotickets", "refreshed_at": "2026-10-28T15:00:00Z"},
                                            {"sub_source": None, "refreshed_at": None}]})
    n.n2s_book(db)
    assert [c[0] for c in db.queries[-1].calls] == ["select", "order", "limit"]
    n.n2s_cover_history(db)
    assert [c[0] for c in db.queries[-1].calls] == ["select", "gte", "order", "limit"]
    row = n.gt_dryrun(db)["rows"][0]
    assert row["profit"] is None and row["gt_listing_id"] is None
    s = n.gt_dryrun_summary(db)
    assert s["by_gate"]["1"]["profitable"] == 0 and s["by_gate"]["1"]["loss"] == 0.0
    h = n.n2s_health(db)
    assert h["cover_queue"]["by_source"] == {"gotickets": 1, "?": 1}
    assert h["cover_queue"]["refreshed_at"] == "2026-10-28T15:00:00Z" and h["newest_order_at"] is None

    # Parser: a primary facet in a section not asked for is skipped; one with no priced
    # offer still counts its seats but has no price.
    body = {"facets": [{"section": "101", "inventoryTypes": ["primary"], "offers": ["X"], "count": 3},
                       {"section": "102", "inventoryTypes": ["primary"], "offers": ["Z"], "count": 2}],
            "_embedded": {"offer": [{"offerId": "X", "totalPrice": None}]}}
    assert n._tm_primary_sections(body, ["101"]) == {"101": {"section": "101", "seats": 3, "min_total_each": None}}

    import ticketsdata_client

    class Boom:
        @classmethod
        def from_vault(cls, db, timeout=30):
            raise ticketsdata_client.TicketsDataError("HTTP 402 — plan quota exhausted")

    monkeypatch.setattr(ticketsdata_client, "TicketsDataClient", Boom)
    assert n.tm_primary(FakeDB(), "https://www.ticketmaster.com/x/event/0A0064") == {
        "error": "HTTP 402 — plan quota exhausted"}
