"""Paciolan/eVenue seat grouping + read-only guard.

The grouping tests pin the DATA RULE that the SQL view v_paciolan_seat_groups
and the Python group_consecutive() both implement: consecutive AVAILABLE seats
(same level+section+row+price+seat_type) collapse into one block, and a
sold/missing seat is the qty break. The fixtures are the REAL 16U Row 19 seats
observed on bgsufalcons.evenue.net/event/F26/F01.
"""
from __future__ import annotations

import pytest

from paciolan_client import (
    ALLOWED_HTTP_METHODS,
    PaciolanReadOnlyError,
    _assert_readonly_method,
    classify_seat_type,
    group_consecutive,
    parse_seat_key,
    split_level_section,
    parse_seatmap_html,
)


def _seat(section, row, no, price, seat_type, available, is_ga=False):
    return {
        "level": "U", "section_label": section, "row_label": str(row),
        "seat_number": str(no), "seat_no": no, "price": price,
        "seat_type": seat_type, "is_ga": is_ga, "available": available,
    }


# Real 16U Row 19: seats 1-2 = $25 premium (crown), 6-33 = $21 standard.
# Sold/missing gaps: 3-5, 24-30, 34-37. Available: 1,2 | 6..23 | 31,32,33.
ROW19 = (
    [_seat("16U", 19, 1, 25.0, "premium", True),
     _seat("16U", 19, 2, 25.0, "premium", True)]
    + [_seat("16U", 19, n, 25.0, "premium", False) for n in (3, 4)]
    + [_seat("16U", 19, 5, 21.0, "standard", False)]
    + [_seat("16U", 19, n, 21.0, "standard", True) for n in range(6, 24)]
    + [_seat("16U", 19, n, 21.0, "standard", False) for n in range(24, 31)]
    + [_seat("16U", 19, n, 21.0, "standard", True) for n in (31, 32, 33)]
    + [_seat("16U", 19, n, 21.0, "standard", False) for n in (34, 35)]
    + [_seat("16U", 19, n, 25.0, "premium", False) for n in (36, 37)]
)


def test_row19_collapses_to_three_blocks():
    blocks = group_consecutive(ROW19)
    # (seat_from, seat_to, qty, price, type)
    got = sorted((b["seat_from"], b["seat_to"], b["quantity"], b["price"],
                  b["seat_type"]) for b in blocks)
    assert got == [
        (1, 2, 2, 25.0, "premium"),    # premium pair
        (6, 23, 18, 21.0, "standard"),  # big standard block
        (31, 33, 3, 21.0, "standard"),  # 3-together after the 24-30 gap
    ]


def test_missing_seat_is_the_qty_break():
    # If seat 15 were sold, the 6-23 block splits at that gap into 6-14 and 16-23.
    seats = [s for s in ROW19 if not (s["seat_no"] == 15)]
    seats.append(_seat("16U", 19, 15, 21.0, "standard", False))
    blocks = {(b["seat_from"], b["seat_to"]): b["quantity"]
              for b in group_consecutive(seats) if b["price"] == 21.0}
    assert (6, 14) in blocks and blocks[(6, 14)] == 9
    assert (16, 23) in blocks and blocks[(16, 23)] == 8
    assert (31, 33) in blocks


def test_price_change_breaks_a_block_even_when_adjacent():
    # Seats 1(premium $25) and 2(premium $25) then 3 would be standard $21: a
    # price/type change is a break key, so adjacency alone doesn't merge them.
    seats = [_seat("16U", 5, 1, 25.0, "premium", True),
             _seat("16U", 5, 2, 25.0, "premium", True),
             _seat("16U", 5, 3, 21.0, "standard", True)]
    blocks = group_consecutive(seats)
    assert sorted((b["seat_from"], b["seat_to"], b["price"]) for b in blocks) == [
        (1, 2, 25.0), (3, 3, 21.0)]


def test_ga_lettered_seats_stay_qty_one():
    seats = [
        {"level": "GA", "section_label": "GA", "row_label": "GA",
         "seat_number": "GA", "seat_no": None, "price": 30.0,
         "seat_type": "ga", "is_ga": True, "available": True},
        {"level": "GA", "section_label": "GA", "row_label": "GA",
         "seat_number": "GA", "seat_no": None, "price": 30.0,
         "seat_type": "ga", "is_ga": True, "available": True},
    ]
    blocks = group_consecutive(seats)
    assert len(blocks) == 2
    assert all(b["quantity"] == 1 for b in blocks)


def test_unavailable_seats_never_appear_in_any_block():
    all_nos = {n for b in group_consecutive(ROW19)
               for n in range(b["seat_from"], b["seat_to"] + 1)}
    for sold in (3, 4, 5, 24, 25, 30, 34, 37):
        assert sold not in all_nos


def test_split_level_section_and_seat_key():
    assert split_level_section("U:16U") == ("U", "16U")
    assert split_level_section("BN:20A") == ("BN", "20A")
    assert split_level_section("WC:WC11L") == ("WC", "WC11L")
    parsed = parse_seat_key("U:16U:19:1")
    assert parsed == {"level": "U", "section_label": "16U",
                      "row_label": "19", "seat_number": "1"}


def test_classify_seat_type():
    assert classify_seat_type(level="U", icon="crown", is_ga=False) == "premium"
    assert classify_seat_type(level="U", icon="circle", is_ga=False) == "standard"
    assert classify_seat_type(level="WC", icon="circle", is_ga=False) == "accessible"
    assert classify_seat_type(level="GA", icon="circle", is_ga=True) == "ga"


def test_parse_seatmap_html_extracts_seats_and_sections():
    html = (
        '<path data-level-section="U:16U" percent="81.47" '
        'aria-label="Section 16U, 81% available"></path>'
        '<circle data-seat-key="U:16U:19:1" data-available="true" '
        'aria-label="Section 16U, Row 19, Seat 1, $25.00, available"></circle>'
        '<circle data-seat-key="U:16U:19:24" data-available="false" '
        'aria-label="Section 16U, Row 19, Seat 24, $21.00, unavailable"></circle>'
    )
    out = parse_seatmap_html(html)
    assert out["sections"][0]["level"] == "U"
    assert out["sections"][0]["section_label"] == "16U"
    assert out["sections"][0]["pct_available"] == pytest.approx(81.47)
    s1 = next(s for s in out["seats"] if s["data_seat_key"] == "U:16U:19:1")
    assert s1["available"] is True and s1["price"] == 25.0
    s24 = next(s for s in out["seats"] if s["data_seat_key"] == "U:16U:19:24")
    assert s24["available"] is False and s24["price"] == 21.0


# ---------- RULE 2 read-only guard (parity with the other clients) ----------
def test_paciolan_assert_readonly_raises_on_writes():
    for method in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(PaciolanReadOnlyError):
            _assert_readonly_method(method)


def test_paciolan_assert_readonly_allows_get():
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_paciolan_allowlist_constant_is_get_only():
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})
