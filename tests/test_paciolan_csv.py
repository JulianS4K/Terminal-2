"""Paciolan/eVenue inventory-CSV parser (parse_inventory_csv + helpers).

Pins the normalization of the box-office export the operator identified as the
canonical Paciolan source ("evenue_<org>_<season>_<item>_<ts>.csv"). The
fixture reproduces the real export's quirks: a 41-column header with duplicate
names, alternating "clean" and "header-junk" data rows, and org_id / event_url
columns that drift per row (row-index corruption). The parser must extract a
single stable event header and one block per already-grouped row regardless.
"""
from __future__ import annotations

import pytest

from paciolan_client import (
    parse_inventory_csv,
    parse_csv_seat_key,
    _num,
    _int,
    _bool,
    _CSV_N_COLS,
)

# 41-column header, faithful to the export (duplicate opponent/venue/date/time).
_HEADER = ("host,org_id,distributor_id,policy_cd,group_code,season_cd,item_cd,"
           "event_id,event_url,type,event_name,opponent,venue,event_date,"
           "event_time,time_tbd,event_dt_local,event_dt_utc,sale_from_dt,"
           "sold_out,opponent,venue,event_date,event_time,event_time,row,qty,"
           "seat_first,seat_last,seats_range,price_level,pl_desc,price_type,"
           "pt_desc,price_usd,facility_fee_usd,per_ticket_fee_usd,"
           "all_in_price_usd,seat_key_first,seat_key_last,view_from_section_url")


def _clean_row(org, url_perf, *, row, qty, sf, sl, rng, key_first, key_last,
               price="125", fac="2", per="17.5", allin="144.5"):
    """A 'clean' data row (col0 = real host); org_id/event_url drift per row."""
    return ",".join([
        "gohuskies.evenue.net", org, "UW", "", "FBS", "FB26", "FB01",
        "343:FB26:FB01", f"https://gohuskies.evenue.net/event/FB26/{url_perf}",
        "S", "Football vs. Washington State", "Washington State",
        "Husky Stadium", "2026-09-06", "13:00", "FALSE",
        "2026-09-06T13:00:00.000Z", "2026-09-06T20:00:00.000Z",
        "2026-05-19T09:00:00.000Z", "FALSE", "Washington State",
        "Husky Stadium", "2026-09-06", "Football 2026 (343:FB26:FB01)", "13:00",
        row, qty, sf, sl, rng, "14", "Corners 100", "A", "Single Game Ticket",
        price, fac, per, allin, key_first, key_last,
        "https://media.evenue.net/p_101.jpg",
    ])


def _junk_row(*, section, row, qty, sf, sl, rng, key_first, key_last):
    """A 'header-junk' data row: first 20 cols are literal header strings, col24
    holds the section, block payload (25..40) still valid."""
    return ",".join([
        "host", "org_id", "distributor_id", "policy_cd", "group_code",
        "season_cd", "item_cd", "event_id", "event_url", "type", "event_name",
        "opponent", "venue", "event_date", "event_time", "time_tbd",
        "event_dt_local", "event_dt_utc", "sale_from_dt", "sold_out",
        "Washington State", "Husky Stadium", "2026-09-06",
        "Football 2026 (343:FB26:FB01)", section,
        row, qty, sf, sl, rng, "14", "Corners 100", "A", "Single Game Ticket",
        "125", "2", "17.5", "144.5", key_first, key_last,
        "https://media.evenue.net/p_101.jpg",
    ])


CSV = "\n".join([
    _HEADER,
    _clean_row("343", "FB01", row="10", qty="11", sf="1", sl="11", rng="1-11",
               key_first="100:101:10:1", key_last="100:101:10:11"),
    _junk_row(section="100:101", row="21", qty="7", sf="7", sl="13", rng="7-13",
              key_first="100:101:21:7", key_last="100:101:21:13"),
    _clean_row("344", "FB02", row="24", qty="7", sf="17", sl="23", rng="17-23",
               key_first="100:102:24:17", key_last="100:102:24:23"),
    _junk_row(section="100:102", row="27", qty="1", sf="25", sl="25", rng="25",
              key_first="100:102:27:25", key_last="100:102:27:25"),
]) + "\n"


# ---- seat-key + coercion helpers -----------------------------------------
def test_parse_csv_seat_key_full():
    assert parse_csv_seat_key("100:101:10:1") == {
        "level": "100", "section": "101", "row": "10", "seat": "1"}


def test_parse_csv_seat_key_short_and_empty():
    assert parse_csv_seat_key("100:101") == {
        "level": "100", "section": "101", "row": None, "seat": None}
    assert parse_csv_seat_key("") == {
        "level": None, "section": None, "row": None, "seat": None}
    assert parse_csv_seat_key(None) == {
        "level": None, "section": None, "row": None, "seat": None}


@pytest.mark.parametrize("raw,exp", [
    ("125", 125.0), ("17.5", 17.5), ("", None), (None, None), ("  ", None),
    ("abc", None),
])
def test_num(raw, exp):
    assert _num(raw) == exp


@pytest.mark.parametrize("raw,exp", [
    ("11", 11), ("17.5", None), ("", None), ("0", 0),
])
def test_int(raw, exp):
    assert _int(raw) == exp


@pytest.mark.parametrize("raw,exp", [
    ("TRUE", True), ("false", False), ("t", True), ("N", False),
    ("", None), (None, None), ("maybe", None),
])
def test_bool(raw, exp):
    assert _bool(raw) is exp


# ---- full CSV normalization ----------------------------------------------
def test_event_identity_is_stable():
    ev = parse_inventory_csv(CSV)["event"]
    assert ev["event_id"] == "343:FB26:FB01"
    assert ev["event_name"] == "Football vs. Washington State"
    assert ev["opponent"] == "Washington State"
    assert ev["venue"] == "Husky Stadium"
    assert ev["season_cd"] == "FB26"
    assert ev["item_cd"] == "FB01"
    assert ev["event_date"] == "2026-09-06"
    assert ev["time_tbd"] is False
    assert ev["sold_out"] is False


def test_org_id_derived_from_event_id_not_corrupt_column():
    # Source org_id column drifts 343,344,… — parser must derive 343.
    ev = parse_inventory_csv(CSV)["event"]
    assert ev["org_id"] == "343"


def test_event_url_reconstructed_canonically():
    # Source event_url drifts FB01,FB02,… — parser rebuilds the FB01 perf URL.
    ev = parse_inventory_csv(CSV)["event"]
    assert ev["event_url"] == "https://gohuskies.evenue.net/event/FB26/FB01"


def test_all_rows_yield_blocks_including_header_junk_rows():
    blocks = parse_inventory_csv(CSV)["blocks"]
    assert len(blocks) == 4  # 2 clean + 2 junk rows all produce a block


def test_block_level_section_split_from_seat_key():
    blocks = parse_inventory_csv(CSV)["blocks"]
    first = blocks[0]
    assert first["level"] == "100"
    assert first["section"] == "101"
    assert first["row"] == "10"
    assert first["qty"] == 11
    assert first["seats_range"] == "1-11"
    assert first["price_usd"] == 125.0
    assert first["all_in_price_usd"] == 144.5
    assert first["pl_desc"] == "Corners 100"
    assert first["pt_desc"] == "Single Game Ticket"


def test_junk_row_block_has_valid_payload():
    blocks = parse_inventory_csv(CSV)["blocks"]
    junk = blocks[1]  # second data row is a header-junk row
    assert junk["section"] == "101"
    assert junk["row"] == "21"
    assert junk["qty"] == 7
    assert junk["seat_key_first"] == "100:101:21:7"


def test_single_seat_block_range():
    blocks = parse_inventory_csv(CSV)["blocks"]
    single = blocks[3]
    assert single["qty"] == 1
    assert single["seats_range"] == "25"
    assert single["section"] == "102"


def test_rows_without_a_usable_block_are_skipped():
    empty_block = ",".join(
        ["gohuskies.evenue.net"] + [""] * (_CSV_N_COLS - 1))
    csv_text = "\n".join([_HEADER, empty_block]) + "\n"
    assert parse_inventory_csv(csv_text)["blocks"] == []


def test_empty_csv_raises():
    with pytest.raises(ValueError, match="empty CSV"):
        parse_inventory_csv("")
    with pytest.raises(ValueError, match="empty CSV"):
        parse_inventory_csv("\n  \n")


def test_wrong_layout_raises():
    with pytest.raises(ValueError, match="unexpected eVenue layout"):
        parse_inventory_csv("a,b,c\n1,2,3\n")


def test_identity_falls_back_to_all_rows_when_none_clean():
    # A file of only header-junk rows still yields blocks; identity degrades
    # gracefully (event_id may be junk, but blocks are intact).
    csv_text = "\n".join([
        _HEADER,
        _junk_row(section="100:101", row="21", qty="7", sf="7", sl="13",
                  rng="7-13", key_first="100:101:21:7",
                  key_last="100:101:21:13"),
    ]) + "\n"
    out = parse_inventory_csv(csv_text)
    assert len(out["blocks"]) == 1
    assert out["blocks"][0]["section"] == "101"
