"""Tests for GET /api/event/{id}/fan-listings (routers/fan_listings.py).

Server-side twin of the terminal's Fan vs Broker classifier. No real DB — a
fake Supabase client whose .table() chains resolve canned rows per (table,
filters), mirroring tests/test_paciolan_routes. Covers the full classification
matrix: ours / broker-via-EVO / broker-via-GOT / broker-multi-market /
fan-likely with each warning flag, plus the batch-window, dedupe, parking and
missing-source branches.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from routers.fan_listings import (  # noqa: E402
    _key,
    _norm_sec,
    build_fan_listings_router,
)


# ---- unit: key normalization ----

def test_norm_sec_variants():
    assert _norm_sec("") == ""
    assert _norm_sec(None) == ""
    assert _norm_sec("FLOOR") == "FLOOR"                 # no digits → verbatim
    assert _norm_sec("Lower 101") == "101"               # level prefix stripped
    assert _norm_sec("press 203") == "203"
    assert _norm_sec("114a") == "114A"                   # letter suffix kept
    assert _norm_sec("1ST BASE LOT") == "1ST BASE LOT"   # digit but no numeric tail


def test_key_null_handling():
    assert _key(None, None, None) == "||0"
    assert _key(" Lower 101 ", " gg ", "2") == "101|GG|2"


# ---- fake supabase client ----

class _Q:
    def __init__(self, name, resolver):
        self._name, self._resolver, self._f = name, resolver, {"eq": {}}

    def select(self, *a, **k):
        return self

    def eq(self, col, val):
        self._f["eq"][col] = val
        return self

    def gte(self, *a, **k):
        return self

    def in_(self, col, vals):
        self._f["in"] = (col, list(vals))
        return self

    def order(self, *a, **k):
        self._f["order"] = True
        return self

    def limit(self, n):
        self._f["limit"] = n
        return self

    def execute(self):
        return type("_R", (), {"data": self._resolver(self._name, self._f)})()


class _Sb:
    def __init__(self, resolver):
        self._resolver = resolver

    def table(self, name):
        return _Q(name, self._resolver)


def _client(resolver):
    app = FastAPI()
    app.include_router(build_fan_listings_router(
        get_require_sb=lambda: (lambda: _Sb(resolver)),
        require_auth=lambda: None,
    ))
    return TestClient(app)


# ---- canned event: full classification matrix ----

BATCH = "2026-08-19T12:00:00+00:00"   # latest batch
STALE = "2026-08-19T11:00:00+00:00"  # outside the 15-min window

def _sh_rows():
    def r(lid, sec, row, qty, px, cap=BATCH, parking=False):
        return {"td_listing_id": lid, "section": sec, "row": row,
                "quantity": qty, "list_price": px, "price_with_fees": px,
                "is_parking": parking, "captured_at": cap}
    return [
        r("L1", "101", "A", 2, 50.0),           # ours (EVO is_owned)
        r("L2", "102", "B", 2, 60.0),           # broker — on EVO
        r("L3", "103", "C", 2, 70.0),           # broker — on GOT ("Level 103")
        r("L4", "104", "D", 2, 80.0),           # broker — also live on VD
        r("L5", "105", "E", 2, 55.5),           # fan-likely, clean
        r("L6", "106", "F", 2, 99.9),           # fan — price cluster (3× 99.9,
        r("L7", "107", "G", 2, 99.9),           #   3 sections)
        r("L8", "108", "H", 2, 99.9),
        r("L9", "109", "J", 9, 40.0),           # fan — block_8plus
        r("L10", "110", "K", 6, 45.0),          # fan — block_5to7
        r(None, "111", "L", 1, None),           # fan clean; null id + null price
        r(None, "111", "L", 1, None),           # dup null id → deduped
        r("L5", "105", "E", 2, 54.0, cap=STALE),  # stale → dropped
        r("LP", "Lot 1", "P", 1, 20.0, parking=True),  # parking → dropped
    ]

def _resolver_happy(name, f):
    eq = f["eq"]
    if name == "aq_event_map":
        return [{"aq_short_event_id": "AQX", "event_name": "Test Event"}]
    if name == "ticketsdata_event_xref":
        # GT deliberately unmapped → its book is empty
        return [{"platform": "SH", "event_id": 111},
                {"platform": "VD", "event_id": 333}]
    if name == "ticketsdata_listings_snapshots":
        if eq.get("platform") == "SH":
            return _sh_rows()
        return [{"td_listing_id": "V1", "section": "104", "row": "D",
                 "quantity": 2, "list_price": 78.0, "price_with_fees": 78.0,
                 "is_parking": False, "captured_at": BATCH},
                {"td_listing_id": "V2", "section": "220", "row": "M",
                 "quantity": 3, "list_price": 33.0, "price_with_fees": 33.0,
                 "is_parking": False, "captured_at": BATCH}]
    if name == "listings_snapshots":
        if "captured_at" in eq:
            return [
                {"section": "101", "row": "A", "quantity": 2, "is_owned": True},
                {"section": "102", "row": "B", "quantity": 2, "is_owned": False},
                {"section": "102", "row": "B", "quantity": 2, "is_owned": False},
                {"section": "P Lot", "row": "Parking", "quantity": 1, "is_owned": False},
            ]
        return [{"captured_at": BATCH}]
    if name == "gotickets_listings_snapshots":
        if "captured_at" in eq:
            return [{"section": "Level 103", "row": "C", "quantity": 2}]
        return [{"captured_at": BATCH}]
    raise AssertionError(f"unexpected table {name}")  # pragma: no cover


def test_fan_listings_default_returns_only_fans():
    r = _client(_resolver_happy).get("/api/event/42/fan-listings")
    assert r.status_code == 200
    d = r.json()
    assert d["tevo_event_id"] == 42 and d["event_name"] == "Test Event"
    assert d["sources_available"] == {
        "SH": True, "GT": False, "VD": True, "EVO": True, "GOT": True}
    # SH book: 12 batch rows − parking − dup = 11 classified
    assert d["summary"]["SH"] == {"ours": 1, "broker": 3, "fan_likely": 7}
    assert d["summary"]["VD"] == {"broker": 1, "fan_likely": 1}
    assert d["summary"]["GT"] == {}
    assert all(x["class"] == "fan_likely" for x in d["listings"])
    assert len(d["listings"]) == 8
    # Clean fans first (null price sorts as 0), flagged after.
    assert [x["section"] for x in d["listings"][:3]] == ["111", "220", "105"]
    flags = {f"{x['source']}:{x['section']}": x["flags"] for x in d["listings"]}
    assert flags["SH:106"] == ["price_cluster"]
    assert flags["SH:109"] == ["block_8plus"]
    assert flags["SH:110"] == ["block_5to7"]
    assert flags["SH:111"] == [] and flags["VD:220"] == []


def test_fan_listings_include_all_carries_every_class():
    d = _client(_resolver_happy).get("/api/event/42/fan-listings?include=all").json()
    by_cls = {}
    for x in d["listings"]:
        by_cls.setdefault(x["class"], []).append(x)
    assert len(by_cls["ours"]) == 1 and by_cls["ours"][0]["section"] == "101"
    broker_secs = {x["source"] + ":" + x["section"] for x in by_cls["broker"]}
    assert broker_secs == {"SH:102", "SH:103", "SH:104", "VD:104"}
    assert len(by_cls["fan_likely"]) == 8
    # fan rows sort ahead of broker/ours rows
    assert d["listings"][0]["class"] == "fan_likely"


def test_fan_listings_404_when_unmapped():
    def resolver(name, f):
        assert name == "aq_event_map"
        return []
    r = _client(resolver).get("/api/event/999/fan-listings")
    assert r.status_code == 404


def test_fan_listings_empty_sources_degrade_honestly():
    """SH mapped but its book empty; EVO/GOT have no captures at all."""
    def resolver(name, f):
        if name == "aq_event_map":
            return [{"aq_short_event_id": "AQY", "event_name": "Bare Event"}]
        if name == "ticketsdata_event_xref":
            return [{"platform": "SH", "event_id": 111}]
        return []  # every snapshot table empty
    d = _client(resolver).get("/api/event/7/fan-listings").json()
    assert d["sources_available"] == {
        "SH": False, "GT": False, "VD": False, "EVO": False, "GOT": False}
    assert d["listings"] == []
    assert d["summary"] == {"SH": {}, "GT": {}, "VD": {}}
