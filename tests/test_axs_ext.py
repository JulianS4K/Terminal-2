"""The AXS watch's extension reader: the document built from what the Firefox extension captured (core/axs_ext_doc.py)
and the routes it calls (routers/axs_ext.py). No real DB: a fake Supabase client records the RPCs."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import axs_ext_doc  # noqa: E402

# the shapes AXS's own seat page receives, as TicketsData's v2 envelope carried them (mig 20260727120000)
OFFER_SEARCH = {"offers": [
    {"offerID": "700", "offerName": "Public Onsale", "minQuantity": 1, "maxQuantity": 8, "items": [
        {"offerID": "700", "priceLevelID": "1", "sectionLabel": "101", "rowLabel": "A", "number": "3", "seatType": "STANDARD",
         "statusCodeLabel": "Available", "neighborhoodLabel": "Lower Bowl"},
        {"offerID": "700", "priceLevelID": "1", "sectionLabel": "101", "rowLabel": "A", "number": "1", "seatType": "STANDARD",
         "statusCodeLabel": "Available", "neighborhoodLabel": "Lower Bowl"},
        {"offerID": "700", "priceLevelID": "1", "sectionLabel": "101", "rowLabel": "A", "number": "2", "seatType": "STANDARD",
         "statusCodeLabel": "Available", "neighborhoodLabel": "Lower Bowl"},
        {"offerID": "700", "priceLevelID": "1", "sectionLabel": "101", "rowLabel": "A", "number": "7", "seatType": "STANDARD",
         "statusCodeLabel": "Available", "neighborhoodLabel": "Lower Bowl"},
        {"offerID": "700", "priceLevelID": "2", "sectionLabel": "FLOOR", "isGASection": True, "seatType": "STANDARD"},
        {"offerID": "700", "priceLevelID": "2", "sectionLabel": "FLOOR", "isGASection": True, "seatType": "STANDARD"},
    ]},
    {"offerID": "9001", "items": [
        {"offerID": "9001", "priceLevelID": "9", "sectionLabel": "102", "rowLabel": "B", "number": "7", "seatType": "FLASHSEATS",
         "priceCodeLabel": "Limited View"},
    ]},
]}
PRICE_BOOK = {"inventory": [{"offerPrices": [
    {"offerID": "700", "offerType": "Single", "zonePrices": [{"priceLevels": [
        {"priceLevelID": "1", "priceLevelLabel": "Lower", "prices": [{"base": 8000, "fees": [{"amount": 1200}, {"amount": 50}]}]},
        {"priceLevelID": "2", "priceLevelLabel": "GA Floor", "prices": [{"base": 6550}]},
    ]}]},
    {"offerID": "9001", "offerType": "Marketplace Resale", "zonePrices": [{"priceLevels": [
        {"priceLevelID": "9", "prices": [{"base": 9550}]},
    ]}]},
]}]}
ONSALE = {"onsale": {"flow": "PICK_A_SEAT_2D", "onSaleStatus": {"onSaleNow": True, "onSaleDate": "2026-05-29 14:00:00 +0000"}}}
EVENT = {"event": {"title": "Arena Night", "venue": {"name": "Big Arena"}, "timezone": "America/Chicago"}}


def _capture(**over):
    cap = {"event_id": "41", "url": "https://www.axs.com/events/41/x", "fired_at": "2026-11-25T20:00:00Z",
           "outcome": "loaded", "http_status": 200, "elapsed_s": 14.2,
           "captures": [{"url": "u1", "status": 200, "json": OFFER_SEARCH}, {"url": "u2", "status": 200, "json": PRICE_BOOK},
                        {"url": "u3", "status": 200, "json": ONSALE}, {"url": "u4", "status": 200, "json": EVENT},
                        {"url": "u5", "status": 200, "json": {"analytics": True}}]}
    cap.update(over)
    return cap


def test_a_read_becomes_the_ticketsdata_envelope():
    rec = axs_ext_doc.build_record(_capture())
    assert rec["p_status_code"] == 200 and rec["p_event_id"] == "41" and rec["p_fired_at"] == "2026-11-25T20:00:00Z"
    body = rec["p_content"]["body"]
    assert body["status"] == "ok" and body["exit_code"] == 0 and body["elapsed_seconds"] == 14.2
    assert body["event"]["title"] == "Arena Night" and body["event"]["venue"] == {"name": "Big Arena"}
    assert body["onsale"]["offer_id"] == "700" and body["onsale"]["flow"] == "PICK_A_SEAT_2D"
    assert body["onsale"]["status"]["onSaleNow"] is True
    assert body["groups"] == [{"offer_id": "700", "ticket_qty": {"min": 1, "max": 8}}]


def test_seats_are_runs_and_prices_come_from_the_price_book():
    body = axs_ext_doc.build_body(_capture())
    by = {(l["section"], l.get("row"), tuple(l.get("seats") or [])): l for l in body["listings"]}
    run = by[("101", "A", ("1", "2", "3"))]
    assert run["quantity"] == 3 and run["kind"] == "primary" and run["price_level"] == "Lower"
    assert run["pricing"] == {"face": 80.0, "fees_total": 12.5, "all_in": 92.5}
    assert run["neighborhood"] == "Lower Bowl" and run["offer_name"] == "Public Onsale"
    assert by[("101", "A", ("7",))]["quantity"] == 1                       # a gap breaks the run
    ga = by[("FLOOR", None, ())]
    assert ga["general_admission"] is True and ga["quantity"] == 2 and "seats" not in ga
    assert ga["pricing"] == {"face": 65.5}
    resale = by[("102", "B", ("7",))]
    assert resale["kind"] == "resale" and resale["price_code"] == "Limited View" and resale["pricing"]["face"] == 95.5
    assert body["listings_summary"]["seats"] == 7


def test_a_ga_event_without_seat_items_reads_the_price_levels():
    book = {"offerPrices": [{"offerID": "800", "zonePrices": [{"zoneLabel": "General Admission", "priceLevels": [
        {"priceLevelID": "5", "priceLevelLabel": "GA", "availability": {"amount": 4}, "prices": [{"base": 8000}]},
        {"priceLevelID": "6", "priceLevelLabel": "GA Late", "availability": 0, "prices": [{"base": 9000}]}]}]}]}
    body = axs_ext_doc.build_body(_capture(captures=[{"url": "u", "status": 200, "json": book}]))
    assert body["status"] == "ok"
    assert body["listings"] == [{"kind": "primary", "section": "General Admission", "general_admission": True, "offer_id": "800",
                                 "price_level": "GA", "quantity": 4, "pricing": {"face": 80.0}}]


@pytest.mark.parametrize("text,status,needle", [
    ("Big Show\nComing Soon\nSign up for alerts", "error", "not on sale yet"),
    ("Tickets are not currently on sale", "error", "not on sale yet"),
    ("Sorry, this event has ended.", "expired", None),
    ("Some page with nothing", "error", "no seat inventory"),
])
def test_a_page_with_nothing_to_read_says_why(text, status, needle):
    body = axs_ext_doc.build_body(_capture(captures=[], page_text=text))
    assert body["status"] == status
    if needle:
        assert needle in body["error"]


def test_failures_map_to_the_records_failure_fields():
    blocked = axs_ext_doc.build_record(_capture(outcome="blocked", http_status=403))
    assert blocked["p_status_code"] == 403 and blocked["p_content"] is None
    queue = axs_ext_doc.build_record(_capture(outcome="queue"))
    assert queue["p_status_code"] is None and queue["p_error_msg"].startswith("queue:")
    timeout = axs_ext_doc.build_record(_capture(outcome="timeout", error="no inventory within 45s"))
    assert timeout["p_timed_out"] is True and timeout["p_error_msg"] == "timeout: no inventory within 45s"
    gone = axs_ext_doc.build_record(_capture(http_status=404))
    assert gone["p_status_code"] == 404 and gone["p_content"] is None


# ---- routes ----
pytest.importorskip("fastapi")
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from routers.axs_ext import build_axs_ext_router  # noqa: E402


class _Q:
    def __init__(self, data):
        self._data = data

    def __getattr__(self, _name):
        return lambda *a, **k: self

    def execute(self):
        return type("_R", (), {"data": self._data})()


class _Sb:
    def __init__(self, rpc=None, tables=None):
        self._rpc, self._tables, self.rpc_calls = rpc, tables or {}, []

    def table(self, name):
        return _Q(self._tables.get(name, []))

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params))
        return _Q(self._rpc)


def _client(sb, secret="s3cret"):
    if secret is None:
        os.environ.pop("AXS_EXT_INGEST_SECRET", None)
    else:
        os.environ["AXS_EXT_INGEST_SECRET"] = secret
    app = FastAPI()
    app.include_router(build_axs_ext_router(get_require_sb=lambda: (lambda: sb)))
    return TestClient(app)


H = {"X-Ingest-Secret": "s3cret"}


def test_routes_are_closed_without_a_secret_and_refuse_a_wrong_one():
    assert _client(_Sb(), secret=None).post("/api/axs/ext/next", json={"worker": "a"}, headers=H).status_code == 503
    assert _client(_Sb()).post("/api/axs/ext/next", json={"worker": "a"}, headers={"X-Ingest-Secret": "no"}).status_code == 401
    assert _client(_Sb()).get("/api/axs/ext/ping").status_code == 401


def test_next_names_the_extension_worker():
    sb = _Sb(rpc={"events": [{"id": "41", "url": "https://www.axs.com/events/41"}], "lanes": 2, "spacing_ms": 4000})
    r = _client(sb).post("/api/axs/ext/next", json={"worker": "ff-abc123", "limit": 500}, headers=H)
    assert r.status_code == 200 and r.json()["lanes"] == 2
    assert sb.rpc_calls == [("axs_watch_next", {"p_limit": 100, "p_worker": "ext:ff-abc123"})]
    assert _client(sb).post("/api/axs/ext/next", json={"worker": "bad worker!"}, headers=H).status_code == 422


def test_record_builds_the_document_and_settles_it():
    sb = _Sb(rpc={"outcome": "ok", "listings": 5, "request_id": 1})
    r = _client(sb).post("/api/axs/ext/record", json=_capture(), headers=H)
    assert r.status_code == 200 and r.json()["outcome"] == "ok" and r.json()["sent_status"] == 200
    name, params = sb.rpc_calls[0]
    assert name == "axs_watch_record_ext" and params["p_event_id"] == "41"
    assert params["p_content"]["body"]["status"] == "ok"
    assert _client(sb).post("/api/axs/ext/record", json={"event_id": "x1"}, headers=H).status_code == 422


def test_ping_reports_the_switches():
    sb = _Sb(tables={"axs_watch_config": [{"enabled": True, "reader": "extension", "ext_lanes": 2, "ext_spacing_ms": 4000}]})
    r = _client(sb).get("/api/axs/ext/ping", headers=H)
    assert r.json() == {"ok": True, "enabled": True, "reader": "extension", "ext_lanes": 2, "ext_spacing_ms": 4000}
