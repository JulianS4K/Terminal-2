"""Tests for /api/paciolan/* routes (routers/paciolan.py).

Browser-extension ingest (X-Ingest-Secret gated) + the read endpoints over
v_paciolan_listings / paciolan_section_snapshots. No real DB — a fake Supabase
client whose .table()/.rpc() return canned rows, mirroring tests/test_axs_routes.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from routers.paciolan import build_paciolan_router  # noqa: E402


class _Q:
    def __init__(self, data):
        self._data = data

    def select(self, *a, **k):
        return self

    def eq(self, *a, **k):
        return self

    def order(self, *a, **k):
        return self

    def limit(self, *a, **k):
        return self

    def execute(self):
        return type("_R", (), {"data": self._data})()


class _Sb:
    def __init__(self, tables=None, rpc=None):
        self._tables = tables or {}
        self._rpc = rpc
        self.rpc_calls = []

    def table(self, name):
        return _Q(self._tables.get(name, []))

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params))
        return _Q(self._rpc)


def _client(sb, secret="s3cret"):
    if secret is None:
        os.environ.pop("PACIOLAN_INGEST_SECRET", None)
    else:
        os.environ["PACIOLAN_INGEST_SECRET"] = secret
    app = FastAPI()
    app.include_router(build_paciolan_router(
        get_require_sb=lambda: (lambda: sb),
        require_auth=lambda: None,
    ))
    return TestClient(app)


PAYLOAD = {
    "platform": "paciolan", "tenant": "bgsufalcons", "event_code": "F26/F01",
    "sections": [{"level": "U", "section_label": "16U", "pct_available": 81.4}],
    "seats": [
        {"data_seat_key": "U:16U:19:1", "seat_no": 1, "available": True},
        {"data_seat_key": "U:16U:19:2", "seat_no": 2, "available": True},
        {"data_seat_key": "U:16U:19:3", "seat_no": 3, "available": False},
    ],
}


# ---- ingest ----
def test_ingest_not_configured_returns_503():
    r = _client(_Sb(), secret=None).post("/api/paciolan/ingest", json=PAYLOAD)
    assert r.status_code == 503


def test_ingest_bad_secret_returns_401():
    c = _client(_Sb(), secret="right")
    r = c.post("/api/paciolan/ingest", json=PAYLOAD,
               headers={"X-Ingest-Secret": "wrong"})
    assert r.status_code == 401
    r2 = c.post("/api/paciolan/ingest", json=PAYLOAD)  # missing header
    assert r2.status_code == 401


def test_ingest_empty_payload_returns_422():
    c = _client(_Sb(), secret="right")
    r = c.post("/api/paciolan/ingest", json={"tenant": "x"},
               headers={"X-Ingest-Secret": "right"})
    assert r.status_code == 422


def test_ingest_ok_calls_rpc_and_returns_snapshot_id():
    sb = _Sb(rpc=4242)
    c = _client(sb, secret="right")
    r = c.post("/api/paciolan/ingest", json=PAYLOAD,
               headers={"X-Ingest-Secret": "right"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["snapshot_id"] == 4242
    assert body["sections"] == 1
    assert body["seats"] == 3
    assert body["available_seats"] == 2
    assert sb.rpc_calls == [("paciolan_ingest", {"p_payload": PAYLOAD})]


# ---- CSV ingest (the box-office inventory export) ----
_CSV_HEADER = ("host,org_id,distributor_id,policy_cd,group_code,season_cd,"
               "item_cd,event_id,event_url,type,event_name,opponent,venue,"
               "event_date,event_time,time_tbd,event_dt_local,event_dt_utc,"
               "sale_from_dt,sold_out,opponent,venue,event_date,event_time,"
               "event_time,row,qty,seat_first,seat_last,seats_range,price_level,"
               "pl_desc,price_type,pt_desc,price_usd,facility_fee_usd,"
               "per_ticket_fee_usd,all_in_price_usd,seat_key_first,"
               "seat_key_last,view_from_section_url")
_CSV_ROW = ("gohuskies.evenue.net,343,UW,,FBS,FB26,FB01,343:FB26:FB01,"
            "https://gohuskies.evenue.net/event/FB26/FB01,S,"
            "Football vs. Washington State,Washington State,Husky Stadium,"
            "2026-09-06,13:00,FALSE,2026-09-06T13:00:00.000Z,"
            "2026-09-06T20:00:00.000Z,2026-05-19T09:00:00.000Z,FALSE,"
            "Washington State,Husky Stadium,2026-09-06,"
            "Football 2026 (343:FB26:FB01),13:00,10,11,1,11,1-11,14,Corners 100,"
            "A,Single Game Ticket,125,2,17.5,144.5,100:101:10:1,100:101:10:11,"
            "https://media.evenue.net/p_101.jpg")
_CSV_OK = _CSV_HEADER + "\n" + _CSV_ROW + "\n"
_CSV_HEADERS = {"X-Ingest-Secret": "right", "Content-Type": "text/csv"}


def test_csv_ingest_not_configured_returns_503():
    r = _client(_Sb(), secret=None).post(
        "/api/paciolan/csv-ingest", content=_CSV_OK, headers=_CSV_HEADERS)
    assert r.status_code == 503


def test_csv_ingest_bad_secret_returns_401():
    c = _client(_Sb(), secret="right")
    r = c.post("/api/paciolan/csv-ingest", content=_CSV_OK,
               headers={"X-Ingest-Secret": "wrong", "Content-Type": "text/csv"})
    assert r.status_code == 401
    r2 = c.post("/api/paciolan/csv-ingest", content=_CSV_OK,
                headers={"Content-Type": "text/csv"})  # missing header
    assert r2.status_code == 401


def test_csv_ingest_unparseable_returns_422():
    c = _client(_Sb(), secret="right")
    r = c.post("/api/paciolan/csv-ingest", content="a,b,c\n1,2,3\n",
               headers=_CSV_HEADERS)
    assert r.status_code == 422
    assert "unparseable" in r.json()["detail"]


def test_csv_ingest_no_blocks_returns_422():
    # Valid header, one row with neither a seat key nor a seats range → 0 blocks.
    empty_row = "gohuskies.evenue.net" + "," * 40
    c = _client(_Sb(), secret="right")
    r = c.post("/api/paciolan/csv-ingest",
               content=_CSV_HEADER + "\n" + empty_row + "\n",
               headers=_CSV_HEADERS)
    assert r.status_code == 422
    assert "no seat blocks" in r.json()["detail"]


def test_csv_ingest_ok_parses_and_calls_rpc():
    sb = _Sb(rpc=515)
    c = _client(sb, secret="right")
    r = c.post("/api/paciolan/csv-ingest", content=_CSV_OK,
               headers={**_CSV_HEADERS, "X-Source-Filename": "evenue_343.csv"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["snapshot_id"] == 515
    assert body["event_id"] == "343:FB26:FB01"
    assert body["blocks"] == 1
    assert body["seats"] == 11
    # RPC got the parsed payload with the filename threaded in.
    name, params = sb.rpc_calls[0]
    assert name == "paciolan_csv_ingest"
    payload = params["p_payload"]
    assert payload["source_filename"] == "evenue_343.csv"
    assert payload["event"]["org_id"] == "343"           # derived, not corrupt col
    assert payload["blocks"][0]["section"] == "101"


def test_csv_ingest_ok_without_filename_header():
    sb = _Sb(rpc=1)
    c = _client(sb, secret="right")
    r = c.post("/api/paciolan/csv-ingest", content=_CSV_OK, headers=_CSV_HEADERS)
    assert r.status_code == 200
    assert "source_filename" not in sb.rpc_calls[0][1]["p_payload"]


# ---- listings ----
def test_listings_summary_math():
    rows = [
        {"tenant": "t", "level": "U", "section": "16U", "row": "19",
         "quantity": 18, "retail_price": 21.0, "type": "standard",
         "seat_from": 6, "seat_to": 23},
        {"tenant": "t", "level": "U", "section": "16U", "row": "19",
         "quantity": 2, "retail_price": 25.0, "type": "premium",
         "seat_from": 1, "seat_to": 2},
    ]
    sb = _Sb(tables={"v_paciolan_listings": rows})
    r = _client(sb).get("/api/paciolan/snapshot/7/listings")
    assert r.status_code == 200
    s = r.json()["summary"]
    assert s["blocks"] == 2
    assert s["total_seats"] == 20
    assert s["biggest_block"] == 18
    assert s["min_price"] == 21.0 and s["max_price"] == 25.0
    assert s["premium_blocks"] == 1


def test_listings_empty_summary_defaults():
    r = _client(_Sb(tables={"v_paciolan_listings": []})).get(
        "/api/paciolan/snapshot/7/listings?limit=999999")
    s = r.json()["summary"]
    assert s["blocks"] == 0 and s["total_seats"] == 0
    assert s["biggest_block"] == 0
    assert s["min_price"] is None and s["max_price"] is None


# ---- events (URL layer) ----
_EVENTS = [
    # mapped + actively pulled + healthy last pull
    {"tenant": "bgsufalcons", "event_code": "F26/F01", "event_name": "Falcons",
     "map_tevo_event_id": 999001, "target_active": True, "last_status": "ok"},
    # unmapped, not pulled, last pull errored (counts toward "stale")
    {"tenant": "bgsufalcons", "event_code": "F26/F02", "event_name": "Falcons 2",
     "map_tevo_event_id": None, "target_active": False, "last_status": "error"},
    # expired last status also counts as stale; no target
    {"tenant": "other", "event_code": "X/1", "event_name": "X",
     "map_tevo_event_id": None, "target_active": None, "last_status": "expired"},
]


def test_events_summary_counts():
    sb = _Sb(tables={"v_paciolan_events": _EVENTS})
    r = _client(sb).get("/api/paciolan/events")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] == 3
    assert body["mapped"] == 1
    assert body["pulling"] == 1
    assert body["stale"] == 2          # error + expired
    assert body["events"][0]["event_code"] == "F26/F01"


def test_events_active_filter_and_empty():
    # active=true exercises the .eq() branch; empty table exercises `data or []`.
    r = _client(_Sb(tables={"v_paciolan_events": []})).get(
        "/api/paciolan/events?active=true&limit=999999")
    body = r.json()
    assert body["count"] == 0 and body["events"] == []
    assert body["mapped"] == 0 and body["pulling"] == 0 and body["stale"] == 0


# ---- health screen ----
def test_health_returns_single_row():
    row = {"targets_active": 2, "pending": 1, "inflight": 0, "ok_24h": 5,
           "empty_24h": 1, "error_24h": 0, "expired_24h": 0}
    r = _client(_Sb(tables={"v_paciolan_pull_health": [row]})).get(
        "/api/paciolan/health")
    assert r.status_code == 200
    assert r.json()["ok_24h"] == 5 and r.json()["targets_active"] == 2


def test_health_empty_returns_object():
    r = _client(_Sb(tables={"v_paciolan_pull_health": []})).get(
        "/api/paciolan/health")
    assert r.status_code == 200 and r.json() == {}


# ---- sections ----
def test_sections_endpoint():
    rows = [{"level": "U", "section_label": "16U", "pct_available": 81.4,
             "disabled": False}]
    r = _client(_Sb(tables={"paciolan_section_snapshots": rows})).get(
        "/api/paciolan/snapshot/7/sections")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] == 1 and body["sections"][0]["section_label"] == "16U"
