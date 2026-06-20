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
    UPGRADE,
    compare_rows,
    find_row_substitutions,
    parse_row,
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


def test_find_orders_upgrades_first_then_closer_in():
    cands = [
        _c("104", "12", gid="same"),   # SAME row
        _c("104", "5", gid="best"),    # big upgrade
        _c("104", "10", gid="mid"),    # smaller upgrade
        _c("104", "20", gid="worse"),  # downgrade -> dropped
    ]
    out = find_row_substitutions("104", "12", 1, cands)
    assert [s["ticket_group_id"] for s in out["subs"]] == ["best", "mid", "same"]
    assert all(s["ticket_group_id"] != "worse" for s in out["subs"])
    # row_delta = how many rows closer (positive = better).
    best = next(s for s in out["subs"] if s["ticket_group_id"] == "best")
    assert best["row_delta"] == 7
    same = next(s for s in out["subs"] if s["ticket_group_id"] == "same")
    assert same["match_type"] == SAME and same["row_delta"] == 0


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
