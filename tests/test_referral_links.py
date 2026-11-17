"""Tests for core/referral_links.py — referral wrapping of outbound buy links.

Pins the three link shapes (Impact, Partnerize, ids appended to the
marketplace's own URL), that a link is only wrapped when it points at that
marketplace over https, and that a malformed programme entry costs the
referral, never the link.
"""
from __future__ import annotations

import json

import pytest

from core import referral_links as r

IMPACT = {"network": "impact", "base": "https://seatgeek.pxf.io/c/111/222/333"}
PARTNERIZE = {"network": "partnerize", "camref": "1101abc"}
QUERY = {"network": "query", "params": {"aid": "12332"}, "sub_param": "rid"}


def test_load_programs_keeps_valid_entries_only():
    raw = json.dumps({
        "seatgeek": {**IMPACT, "base": IMPACT["base"] + "/"},      # trailing slash tolerated
        "stubhub": PARTNERIZE,
        "vivid": QUERY,
        "tickpick": {"network": "query", "params": {"ref": "s4k"}},   # no sub id parameter
        "unknown-market": IMPACT,                                  # not a marketplace we link to
        "gametime": "impact",                                      # not an object
        "ticketmaster": {"network": "impact", "base": "http://x.pxf.io/c/1/2/3"},   # not https
        "axs": {"network": "cj", "pid": "1"},                      # a network we do not build
    })
    assert r.load_programs(raw) == {
        "seatgeek": IMPACT, "stubhub": PARTNERIZE, "vivid": QUERY,
        "tickpick": {"network": "query", "params": {"ref": "s4k"}, "sub_param": None}}


@pytest.mark.parametrize("spec", [
    {"network": "impact"},
    {"network": "impact", "base": "https://seatgeek.pxf.io/c/111/222"},
    {"network": "impact", "base": "https://seatgeek.pxf.io/c/111/222/333?u=x"},
    {"network": "partnerize"},
    {"network": "partnerize", "camref": "bad/camref"},
    {"network": "query"},
    {"network": "query", "params": {}},
    {"network": "query", "params": ["aid"]},
    {"network": "query", "params": {"aid": "1&x=2"}},
    {"network": "query", "params": {"a id": "1"}},
    {"network": "query", "params": {"aid": "1"}, "sub_param": "r id"},
])
def test_malformed_program_is_dropped(spec):
    assert r.load_programs(json.dumps({"seatgeek": spec})) == {}


@pytest.mark.parametrize("raw", ["", "   ", "{not json", "[1, 2]", '"impact"'])
def test_load_programs_bad_input_is_empty(raw):
    assert r.load_programs(raw) == {}


def test_load_programs_reads_the_environment(monkeypatch):
    monkeypatch.delenv(r.ENV_VAR, raising=False)
    assert r.load_programs() == {}
    monkeypatch.setenv(r.ENV_VAR, json.dumps({"stubhub": PARTNERIZE}))
    assert r.load_programs() == {"stubhub": PARTNERIZE}
    # wrap() with no explicit programs reads the same variable
    assert r.wrap("stubhub", "https://www.stubhub.com/e/1") == (
        "https://prf.hn/click/camref:1101abc/destination:https%3A%2F%2Fwww.stubhub.com%2Fe%2F1", True)


def test_wrap_impact():
    progs = {"seatgeek": IMPACT}
    url = "https://seatgeek.com/knicks-tickets/1?quantity=2"
    assert r.wrap("seatgeek", url, "ev42", progs) == (
        "https://seatgeek.pxf.io/c/111/222/333?u=https%3A%2F%2Fseatgeek.com%2Fknicks-tickets%2F1%3Fquantity%3D2"
        "&subId1=ev42", True)
    assert r.wrap("seatgeek", url, None, progs) == (
        "https://seatgeek.pxf.io/c/111/222/333?u=https%3A%2F%2Fseatgeek.com%2Fknicks-tickets%2F1%3Fquantity%3D2", True)


def test_wrap_partnerize():
    progs = {"stubhub": PARTNERIZE}
    assert r.wrap("stubhub", "https://www.stubhub.com/e/1/", "ev 42!", progs) == (
        "https://prf.hn/click/camref:1101abc/pubref:ev42/destination:https%3A%2F%2Fwww.stubhub.com%2Fe%2F1%2F", True)


def test_wrap_query_appends_and_replaces_our_ids():
    progs = {"seatgeek": QUERY}
    assert r.wrap("seatgeek", "https://seatgeek.com/e/1?quantity=2&aid=999", "ev42", progs) == (
        "https://seatgeek.com/e/1?quantity=2&aid=12332&rid=ev42", True)
    assert r.wrap("seatgeek", "https://seatgeek.com/e/1", None, progs) == ("https://seatgeek.com/e/1?aid=12332", True)
    no_sub = {"seatgeek": {"network": "query", "params": {"aid": "12332"}, "sub_param": None}}
    assert r.wrap("seatgeek", "https://seatgeek.com/e/1", "ev42", no_sub) == ("https://seatgeek.com/e/1?aid=12332", True)


@pytest.mark.parametrize("key,url", [
    ("vivid", "https://www.vividseats.com/p/1"),            # no programme for this marketplace
    ("seatgeek", "http://seatgeek.com/e/1"),                # not https
    ("seatgeek", "https://seatgeek.com.evil.test/e/1"),     # not the marketplace's host
    ("seatgeek", "https://notseatgeek.com/e/1"),
    ("seatgeek", "not a url"),
])
def test_wrap_leaves_other_links_alone(key, url):
    assert r.wrap(key, url, "ev42", {"seatgeek": IMPACT}) == (url, False)


def test_wrap_accepts_subdomains_and_every_listed_host():
    progs = {"ticketmaster": {"network": "impact", "base": "https://ticketmaster.evyy.net/c/1/2/3"}}
    for url in ("https://www.ticketmaster.com/e/1", "https://concerts.livenation.com/e/1"):
        assert r.wrap("ticketmaster", url, None, progs)[1] is True


def test_clean_sub_id():
    assert r.clean_sub_id(None) is None and r.clean_sub_id("!!") is None
    assert r.clean_sub_id("ev 3226757/home") == "ev3226757home"
    assert r.clean_sub_id("x" * 100) == "x" * 64
    assert r.clean_sub_id(3226757) == "3226757"
