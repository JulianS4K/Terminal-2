"""Unit tests for the substitution checker's pure row logic (core/substitutions).

Row phase only: same-section, same-or-better row. No DB, no HTTP — these drive
the pure functions directly so the matching/ranking rules are pinned down
exhaustively. The route is covered separately in test_broker_routes.py.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.substitutions import (  # noqa: E402
    DOWNGRADE,
    INCOMPARABLE,
    SAME,
    SECTION_UPGRADE,
    UPGRADE,
    compare_rows,
    find_row_substitutions,
    find_section_substitutions,
    SECTION_AMBIGUOUS,
    gotickets_buy_url,
    parse_row,
    section_match_key,
    section_parts,
    splits_allow,
)


# ---------- parse_row ----------

def test_parse_row_numeric():
    r = parse_row("20")
    assert r.kind == "numeric"
    assert r.rank == 20


def test_parse_row_alpha_single_and_double():
    assert parse_row("A").kind == "alpha"
    assert parse_row("A").rank == 1
    assert parse_row("Z").rank == 26
    # alpha_width distinguishes single- vs double-letter rows (so the
    # venue-dependent AA-vs-Z direction isn't silently assumed).
    assert parse_row("A").alpha_width == 1
    assert parse_row("AA").alpha_width == 2
    # Within a width, ordering is monotonic and unambiguous.
    assert parse_row("BB").rank > parse_row("AA").rank


def test_parse_row_ga_variants():
    for label in ("GA", "ga", "General Admission", "GEN ADM", "GA1"):
        assert parse_row(label).kind == "ga", label


def test_parse_row_empty_and_mixed_are_unknown():
    assert parse_row(None).kind == "unknown"
    assert parse_row("   ").kind == "unknown"
    assert parse_row("12B").kind == "unknown"  # mixed -> not safely rank-able


# ---------- compare_rows ----------

def test_compare_numeric_lower_is_upgrade():
    assert compare_rows("20", "19") == UPGRADE   # 19 is closer in
    assert compare_rows("20", "20") == SAME
    assert compare_rows("20", "21") == DOWNGRADE


def test_compare_alpha_earlier_is_upgrade():
    assert compare_rows("C", "A") == UPGRADE
    assert compare_rows("C", "C") == SAME
    assert compare_rows("C", "D") == DOWNGRADE
    # Same-width double letters compare cleanly too.
    assert compare_rows("CC", "AA") == UPGRADE
    assert compare_rows("AA", "BB") == DOWNGRADE


def test_compare_alpha_cross_width_is_incomparable():
    # AA-vs-Z direction is venue-specific -> never guessed.
    assert compare_rows("Z", "AA") == INCOMPARABLE
    assert compare_rows("AA", "A") == INCOMPARABLE


def test_compare_cross_kind_is_incomparable():
    assert compare_rows("12", "A") == INCOMPARABLE
    assert compare_rows("A", "12") == INCOMPARABLE


def test_compare_ga_only_subs_ga():
    assert compare_rows("GA", "GA") == SAME
    assert compare_rows("GA", "5") == INCOMPARABLE
    assert compare_rows("5", "GA") == INCOMPARABLE


def test_compare_unknown_exact_match_is_same():
    assert compare_rows("12B", "12B") == SAME
    assert compare_rows("12B", "12C") == INCOMPARABLE


# ---------- find_row_substitutions ----------

def _c(section, row, quantity=2, gid=None, price=None):
    return {
        "tevo_ticket_group_id": gid,
        "section": section,
        "row": row,
        "quantity": quantity,
        "retail_price": price,
    }


def test_find_filters_to_same_section():
    cands = [_c("104", "10", gid=1), _c("105", "5", gid=2)]
    out = find_row_substitutions("104", "12", 1, cands)
    assert [s["ticket_group_id"] for s in out["subs"]] == [1]
    assert out["counts"]["scanned"] == 1  # other section never scanned


def test_find_orders_cheapest_first():
    # The Petco lesson: a big upgrade that costs a fortune must NOT outrank a
    # break-even same-row seat. Cost is the primary sort.
    cands = [
        _c("104", "12", gid="same", price=100),   # SAME row, cheap
        _c("104", "5", gid="best", price=500),     # big upgrade, expensive
        _c("104", "10", gid="mid", price=50),      # small upgrade, cheapest
        _c("104", "20", gid="worse", price=10),    # downgrade -> dropped despite cheapest
    ]
    out = find_row_substitutions("104", "12", 1, cands)
    assert [s["ticket_group_id"] for s in out["subs"]] == ["mid", "same", "best"]
    assert all(s["ticket_group_id"] != "worse" for s in out["subs"])
    assert out["best"]["ticket_group_id"] == "mid"
    same = next(s for s in out["subs"] if s["ticket_group_id"] == "same")
    assert same["match_type"] == SAME and same["row_delta"] == 0


def test_find_without_cost_falls_back_to_smallest_upgrade():
    # No prices => prefer the smallest acceptable upgrade (closest to sold row,
    # i.e. least over-delivery), since a smaller upgrade is generally cheaper.
    cands = [
        _c("104", "5", gid="big"),    # 7 rows better
        _c("104", "12", gid="same"),  # same row
        _c("104", "10", gid="near"),  # 2 rows better
    ]
    out = find_row_substitutions("104", "12", 1, cands)
    assert [s["ticket_group_id"] for s in out["subs"]] == ["same", "near", "big"]


def test_find_pnl_against_revenue_petco_shape():
    # Mirrors the real Petco case: sold 4 @ $16.78/tix; cover from market.
    cands = [
        _c("310", "14", quantity=4, gid="cheap", price=17.95),  # same row, break-even
        _c("310", "9", quantity=5, gid="pricey", price=281.05),  # upgrade, ruinous
    ]
    out = find_row_substitutions("310", "14", 4, cands, revenue_per_ticket=16.78)
    # cheapest acceptable wins -> the same-row $17.95 lot, not the $281 upgrade.
    assert out["best"]["ticket_group_id"] == "cheap"
    assert out["best"]["unit_cost"] == 17.95
    assert out["best"]["pnl_per_ticket"] == round(16.78 - 17.95, 2)
    assert out["best"]["pnl_total"] == round((16.78 - 17.95) * 4, 2)
    pricey = next(s for s in out["subs"] if s["ticket_group_id"] == "pricey")
    assert pricey["pnl_total"] < out["best"]["pnl_total"]  # far worse loss


def test_find_respects_quantity_needed():
    cands = [_c("104", "5", quantity=1, gid="one"), _c("104", "6", quantity=4, gid="four")]
    out = find_row_substitutions("104", "10", 2, cands)
    assert [s["ticket_group_id"] for s in out["subs"]] == ["four"]


def test_find_excludes_self_group():
    cands = [_c("104", "10", gid="self"), _c("104", "8", gid="other")]
    out = find_row_substitutions("104", "10", 1, cands, exclude_group_id="self")
    assert [s["ticket_group_id"] for s in out["subs"]] == ["other"]


def test_find_routes_cross_kind_to_ambiguous():
    cands = [_c("FLOOR", "A", gid="alpha"), _c("FLOOR", "3", gid="num")]
    out = find_row_substitutions("FLOOR", "5", 1, cands)
    # target row "5" is numeric: "3" upgrades, "A" is incomparable -> ambiguous.
    assert [s["ticket_group_id"] for s in out["subs"]] == ["num"]
    assert [s["ticket_group_id"] for s in out["ambiguous"]] == ["alpha"]
    assert out["counts"]["ambiguous"] == 1


def test_find_cross_width_alpha_goes_to_ambiguous():
    # Target row "C" (width 1); "AA" (width 2) is venue-dependent -> ambiguous,
    # while "A" (width 1) is a clean upgrade.
    cands = [_c("FLOOR", "A", gid="up"), _c("FLOOR", "AA", gid="wide")]
    out = find_row_substitutions("FLOOR", "C", 1, cands)
    assert [s["ticket_group_id"] for s in out["subs"]] == ["up"]
    assert [s["ticket_group_id"] for s in out["ambiguous"]] == ["wide"]


def test_find_section_normalization_matches_whitespace():
    cands = [_c("  104  ", "5", gid="pad")]
    out = find_row_substitutions("104", "10", 1, cands)
    assert [s["ticket_group_id"] for s in out["subs"]] == ["pad"]


def test_find_empty_candidates_is_clean():
    out = find_row_substitutions("104", "10", 1, [])
    assert out["subs"] == [] and out["ambiguous"] == []
    assert out["counts"] == {"subs": 0, "ambiguous": 0, "scanned": 0}
    assert out["target"]["row_kind"] == "numeric"


# ---------- find_section_substitutions (better-section phase) ----------

def test_section_subs_only_better_or_equal_sections_cheapest_first():
    # Sold section 310 (quality 50). 108 (quality 200) is better; 305 (quality
    # 80) is better; 320 (quality 30) is WORSE -> excluded; 310 itself skipped.
    quality = {"310": 50, "108": 200, "305": 80, "320": 30}
    cands = [
        _c("108", "20", quantity=4, gid="lower", price=180),
        _c("305", "5", quantity=4, gid="mid", price=70),
        _c("320", "1", quantity=4, gid="worse", price=10),  # better seat, worse section
        _c("310", "1", quantity=4, gid="samesec", price=5),  # same section -> row phase
    ]
    out = find_section_substitutions("310", 4, cands, quality, revenue_per_ticket=100)
    # cheapest acceptable better-section first: 305 ($70) before 108 ($180).
    assert [s["ticket_group_id"] for s in out["section_subs"]] == ["mid", "lower"]
    assert out["best"]["to_section"] == "305"
    assert out["best"]["match_type"] == SECTION_UPGRADE
    assert out["best"]["section_delta"] == 30  # 80 - 50
    assert out["best"]["pnl_total"] == round((100 - 70) * 4, 2)
    assert "worse" not in [s["ticket_group_id"] for s in out["section_subs"]]
    assert "samesec" not in [s["ticket_group_id"] for s in out["section_subs"]]


def test_section_subs_no_quality_for_sold_section_returns_note():
    out = find_section_substitutions("999", 2, [_c("100", "1", gid="x")], {"100": 50})
    assert out["section_subs"] == []
    assert out["sold_quality"] is None
    assert "note" in out


def test_section_subs_unknown_candidate_section_excluded():
    # Candidate section has no quality entry -> can't prove it's better -> skip.
    quality = {"310": 50}
    out = find_section_substitutions("310", 1, [_c("777", "1", gid="unk")], quality)
    assert out["section_subs"] == []
    assert out["counts"]["scanned"] == 0


# ---------- buy-in fees (market P&L) ----------

def test_find_fee_pct_lands_cost_and_pnl():
    # Market buy-in: $100 ask + 30% buyer fee = $130 landed. P&L vs $90/tix
    # revenue is computed on the LANDED cost, not the bare ask.
    cands = [_c("104", "12", quantity=2, gid="m", price=100)]
    out = find_row_substitutions("104", "12", 2, cands,
                                 revenue_per_ticket=90, fee_pct=30)
    b = out["best"]
    assert b["unit_cost"] == 100.0          # raw ask preserved
    assert b["landed_cost"] == 130.0        # ask + 30%
    assert b["pnl_per_ticket"] == round(90 - 130.0, 2)
    assert b["pnl_total"] == round((90 - 130.0) * 2, 2)


def test_find_fee_changes_cheapest_ranking():
    # Without fees A ($100) beats B ($110). A flat-ish % fee that hits the
    # pricier ask harder can't flip order here, but a per-listing fee model
    # would; assert fees at least re-rank on landed cost monotonically.
    cands = [
        _c("104", "12", quantity=2, gid="A", price=100),
        _c("104", "10", quantity=2, gid="B", price=110),
    ]
    out = find_row_substitutions("104", "12", 1, cands, fee_pct=50)
    assert out["best"]["ticket_group_id"] == "A"
    assert out["best"]["landed_cost"] == 150.0   # 100 * 1.5


# ---------- section_match_key (cross-source section identity) ----------

def test_section_key_strips_zone_prefix():
    # The exchange says "311"; GoTickets says "Promenade  311" (double space).
    assert section_match_key("311") == "311"
    assert section_match_key("Promenade  311") == "311"
    assert section_match_key("Section 311") == "311"
    assert section_match_key("Loge 202") == "202"


def test_section_key_keeps_non_numeric_labels_whole():
    # No trailing number -> never invent one; compare the normalized label.
    assert section_match_key("GA") == "GA"
    assert section_match_key("Box A") == "BOX A"
    assert section_match_key("orchestra center") == "ORCHESTRA CENTER"


def test_section_key_empty_is_none():
    assert section_match_key(None) is None
    assert section_match_key("   ") is None


def test_section_key_keeps_alphanumeric_block():
    assert section_match_key("Field Box 12A") == "12A"


def test_section_parts_splits_zone_from_block():
    assert section_parts("Promenade  311") == ("PROMENADE 311", "311", False)
    assert section_parts("311") == ("311", "311", True)
    assert section_parts("GA") == ("GA", None, False)
    assert section_parts(None) == (None, None, False)


def test_two_zoned_labels_sharing_a_number_are_not_the_same_section():
    # Real shape from prod: one event carrying both. Equal keys, but neither is
    # bare, so they must never match each other.
    cands = [{"id": "x", "section": "Center Field Sports Bar 3", "row": "1",
              "quantity": 2, "retail_price": 10.0}]
    res = find_row_substitutions("Audi Yankees Club 3", "5", 2, cands)
    assert res["subs"] == [] and res["ambiguous"] == []
    assert res["counts"]["scanned"] == 0


def test_bare_sold_section_with_two_zoned_labels_goes_to_ambiguous():
    # "106" can't be resolved to Loge or Lower — the seat may be fine, but we
    # won't claim which section it is.
    cands = [
        {"id": "loge", "section": "Loge 106", "row": "1", "quantity": 2,
         "retail_price": 10.0},
        {"id": "lower", "section": "Lower 106", "row": "1", "quantity": 2,
         "retail_price": 20.0},
    ]
    res = find_row_substitutions("106", "9", 2, cands)
    assert res["subs"] == []
    assert {a["ticket_group_id"] for a in res["ambiguous"]} == {"loge", "lower"}
    assert all(a["match_type"] == SECTION_AMBIGUOUS for a in res["ambiguous"])


def test_bare_sold_section_with_one_zoned_label_is_a_clean_match():
    cands = [{"id": "gt", "section": "Promenade  311", "row": "M", "quantity": 2,
              "retail_price": 10.0}]
    res = find_row_substitutions("311", "R", 2, cands)
    assert [x["ticket_group_id"] for x in res["subs"]] == ["gt"]
    assert res["subs"][0]["match_type"] == UPGRADE


def test_exact_label_match_survives_an_ambiguous_key():
    # An exact-label candidate is never collateral damage of the guard.
    cands = [
        {"id": "exact", "section": "106", "row": "1", "quantity": 2, "retail_price": 30.0},
        {"id": "loge", "section": "Loge 106", "row": "1", "quantity": 2, "retail_price": 10.0},
        {"id": "lower", "section": "Lower 106", "row": "1", "quantity": 2, "retail_price": 20.0},
    ]
    res = find_row_substitutions("106", "9", 2, cands)
    assert [x["ticket_group_id"] for x in res["subs"]] == ["exact"]


# ---------- splits_allow ----------

def test_splits_allow_respects_lot_sizes():
    assert splits_allow({"splits": [2, 4]}, 2) is True
    assert splits_allow({"splits": [2, 4]}, 3) is False
    assert splits_allow({"splits": [4]}, 2) is False


def test_splits_allow_permissive_when_unknown():
    # Absent or unusable splits mean the source didn't say — don't drop a
    # real sub over missing metadata.
    assert splits_allow({}, 2) is True
    assert splits_allow({"splits": None}, 2) is True
    assert splits_allow({"splits": []}, 2) is True
    assert splits_allow({"splits": ["junk"]}, 2) is True


def test_find_excludes_lot_that_cannot_split_to_needed_qty():
    cands = [
        {"id": 1, "section": "311", "row": "M", "quantity": 4, "splits": [4],
         "retail_price": 100.0},
        {"id": 2, "section": "311", "row": "M", "quantity": 4, "splits": [2, 4],
         "retail_price": 120.0},
    ]
    res = find_row_substitutions("311", "R", 2, cands)
    assert [s["ticket_group_id"] for s in res["subs"]] == [2]


# ---------- gotickets_buy_url ----------

def test_gotickets_buy_url_shape():
    url = gotickets_buy_url(1252283, 3262193)
    assert url == ("https://pro.gotickets.com/tickets/1252283/"
                   "?sortBy=price&sortDirection=asc&sections=3262193")


def test_gotickets_buy_url_without_section_still_links_event():
    assert gotickets_buy_url(1252283) == (
        "https://pro.gotickets.com/tickets/1252283/?sortBy=price&sortDirection=asc")


def test_gotickets_buy_url_none_without_event_id():
    assert gotickets_buy_url(None, 3262193) is None
    assert gotickets_buy_url("", 3262193) is None


# ---------- merged pool: exchange + GoTickets ----------

def test_find_matches_gotickets_label_against_exchange_section():
    # The real shape of the merged market pool: same physical section, two
    # different labels, and GoTickets is the cheaper cover.
    cands = [
        {"id": "tg1", "section": "311", "row": "O", "quantity": 2, "splits": [2],
         "retail_price": 262.10, "inv_source": "tevo_market"},
        {"id": "gt1", "section": "Promenade  311", "row": "O", "quantity": 2,
         "splits": [2], "cost": 254.44, "fee_exempt": True,
         "inv_source": "gotickets",
         "buy_url": gotickets_buy_url(1252283, 3262193)},
    ]
    res = find_row_substitutions("311", "R", 2, cands, revenue_per_ticket=280.0)
    assert res["counts"]["scanned"] == 2
    best = res["best"]
    assert best["inv_source"] == "gotickets"
    assert best["landed_cost"] == 254.44
    assert best["buy_url"].endswith("sections=3262193")
    assert best["pnl_total"] == round((280.0 - 254.44) * 2, 2)


def test_fee_exempt_candidate_is_not_marked_up():
    # A market fee applies to the exchange ask but not to an all-in price.
    cands = [
        {"id": "tg1", "section": "311", "row": "M", "quantity": 2,
         "retail_price": 250.0, "inv_source": "tevo_market"},
        {"id": "gt1", "section": "Promenade  311", "row": "M", "quantity": 2,
         "cost": 255.0, "fee_exempt": True, "inv_source": "gotickets"},
    ]
    res = find_row_substitutions("311", "R", 2, cands, fee_pct=10.0)
    by_id = {s["ticket_group_id"]: s for s in res["subs"]}
    assert by_id["tg1"]["landed_cost"] == 275.0   # 250 + 10%
    assert by_id["gt1"]["landed_cost"] == 255.0   # already all-in
    # …which flips the ranking: the cheaper ask is the pricier cover.
    assert res["best"]["ticket_group_id"] == "gt1"


def test_section_subs_carry_buy_url_and_respect_splits():
    cands = [
        {"id": "a", "section": "310", "row": "C", "quantity": 2, "splits": [2],
         "cost": 300.0, "fee_exempt": True, "inv_source": "gotickets",
         "buy_url": gotickets_buy_url(1252283, 999)},
        # cheaper, better section, but only sells as a 4-lot — not a cover for 2.
        {"id": "b", "section": "310", "row": "A", "quantity": 4, "splits": [4],
         "cost": 200.0, "fee_exempt": True, "inv_source": "gotickets"},
    ]
    res = find_section_substitutions("311", 2, cands, {"311": 250.0, "310": 400.0})
    assert res["counts"]["section_subs"] == 1
    sub = res["section_subs"][0]
    assert sub["match_type"] == SECTION_UPGRADE
    assert sub["to_section"] == "310"
    assert sub["buy_url"].endswith("sections=999")


def test_section_phase_does_not_score_zoned_labels():
    # The quality map is keyed on exchange labels; a zoned label has no score,
    # so it sits out the section phase rather than borrowing "310"'s median.
    cands = [
        {"id": "gt", "section": "Promenade  310", "row": "C", "quantity": 2,
         "cost": 300.0, "inv_source": "gotickets"},
    ]
    res = find_section_substitutions("311", 2, cands, {"311": 250.0, "310": 400.0})
    assert res["counts"]["section_subs"] == 0
