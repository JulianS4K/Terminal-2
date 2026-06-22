"""Unit tests for the pure functions in core/movers.py (BR-CODE-1 heavy-helper
extraction). The movers engine was previously only exercised end-to-end via
tests/test_store_home.py; these cover its classifiers + section builders
directly (no DB — they take plain dicts/strings).
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.movers import (  # noqa: E402
    _classify_marquee_competition, _has_canadian_team, _classify_holiday_proximity,
    _section_moving_fast, _section_price_drops, _section_climbing, _section_specials,
)


# ---------- classifiers ----------

def test_classify_marquee_competition():
    assert _classify_marquee_competition("US Open Tennis - Day 5") == "US Open Tennis"
    assert _classify_marquee_competition("Monaco Grand Prix") == "F1"
    assert _classify_marquee_competition("Formula 1 Las Vegas") == "F1"
    assert _classify_marquee_competition("Inter Miami CF at Orlando City SC") == "Inter Miami away"
    # home game (not "... at ...") is NOT flagged
    assert _classify_marquee_competition("Orlando City SC at Inter Miami CF") is None
    assert _classify_marquee_competition("Knicks vs Celtics") is None
    assert _classify_marquee_competition(None) is None


def test_has_canadian_team():
    assert _has_canadian_team("Toronto Blue Jays at New York Yankees") is True
    assert _has_canadian_team("Montréal Canadiens at Rangers") is True
    assert _has_canadian_team("Boston Red Sox at New York Yankees") is False
    assert _has_canadian_team(None) is False


def test_classify_holiday_proximity():
    # Jan 1 2026 = Thursday, Jan 3 = Saturday, Jan 2 = Friday
    assert _classify_holiday_proximity("2026-01-01", "2026-01-01") == "day_of"
    assert _classify_holiday_proximity("2026-01-03", "2026-01-01") == "weekend_of"  # Sat
    assert _classify_holiday_proximity("2026-01-02", "2026-01-01") is None          # Fri weekday
    assert _classify_holiday_proximity("not-a-date", "2026-01-01") is None


# ---------- section builders ----------

def test_section_moving_fast_filters_and_sorts():
    cands = [
        {"id": 1, "tix_d24h": -60, "occurs_at_local": "2026-05-02"},
        {"id": 2, "tix_d24h": -50, "occurs_at_local": "2026-05-01"},
        {"id": 3, "tix_d24h": -10, "occurs_at_local": "2026-05-01"},  # below threshold
        {"id": 4, "tix_d24h": None, "occurs_at_local": "2026-05-01"},  # no signal
    ]
    out = _section_moving_fast(cands)
    assert [c["id"] for c in out] == [1, 2]  # ≥50 drop, biggest first


def test_section_price_drops_tags_discount():
    cands = [
        {"id": 1, "getin_pct_24h": -15.0, "occurs_at_local": "2026-05-02"},
        {"id": 2, "getin_pct_24h": -10.0, "occurs_at_local": "2026-05-01"},
        {"id": 3, "getin_pct_24h": -5.0, "occurs_at_local": "2026-05-01"},  # < 10% drop
    ]
    out = _section_price_drops(cands)
    assert [c["id"] for c in out] == [1, 2]
    assert out[0]["_discount_pct"] == 15.0
    assert out[1]["_discount_pct"] == 10.0


def test_section_climbing_requires_tix_down_and_getin_up():
    cands = [
        {"id": 1, "tix_d24h": -5, "getin_pct_24h": 8.0},   # qualifies
        {"id": 2, "tix_d24h": -5, "getin_pct_24h": 3.0},   # getin climb < 5%
        {"id": 3, "tix_d24h": 2, "getin_pct_24h": 10.0},   # tix not falling
    ]
    out = _section_climbing(cands)
    assert [c["id"] for c in out] == [1]
    assert out[0]["_climb_pct"] == 8.0


def test_section_specials_gates_owned_and_tags():
    cands = [
        {"id": 1, "owned_tickets_count": 200, "occurs_at_local": "2026-05-02"},  # rivalry
        {"id": 2, "owned_tickets_count": 150, "occurs_at_local": "2026-05-01"},  # holiday weekend
        {"id": 3, "owned_tickets_count": 50, "occurs_at_local": "2026-05-01"},   # below owned gate
        {"id": 4, "owned_tickets_count": 300, "occurs_at_local": "2026-05-03"},  # no tag -> dropped
    ]
    holiday_by_eid = {2: {"name": "Memorial Day", "weekend": True}}
    rivalry_by_eid = {1: "Yankees vs Red Sox"}
    out = _section_specials(cands, holiday_by_eid, rivalry_by_eid)
    # sorted by occurs_at_local: id 2 (05-01) before id 1 (05-02); 3 + 4 dropped
    assert [c["id"] for c in out] == [2, 1]
    assert out[0]["_special"] == "Memorial Day Weekend"
    assert out[0]["_special_kind"] == "holiday"
    assert out[1]["_special"] == "Yankees vs Red Sox"
    assert out[1]["_special_kind"] == "rivalry"
