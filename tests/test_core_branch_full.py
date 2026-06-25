"""Branch-completion tests for core/movers.py, core/search.py,
core/substitutions.py.

Line coverage of these three is already 100%; this file closes the remaining
PARTIAL branches (an `A->B` jump never taken), driving each side of a loop /
conditional that the existing suites only exercised one way. No real DB/network
— reuses the same programmable-fake conventions as test_core_movers_full.py,
test_core_search.py and test_substitutions.py.

Targets:
  movers.py   596->591  — holiday-view dedupe (key already seen / falsy name)
  movers.py   613->608  — rivalry-view dedupe (key already seen / falsy name)
  movers.py   734->681  — holiday-window proximity == None (weekday in window)
  search.py    79->88   — ev_rows non-empty but no usable ids -> skip metrics
  substitutions.py 388->391 — landed_cost / revenue is None -> skip pnl calc
"""
from __future__ import annotations

import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.movers import _compute_movers  # noqa: E402
from core.search import search_sql_only  # noqa: E402
from core.substitutions import (  # noqa: E402
    SECTION_UPGRADE,
    find_section_substitutions,
)


# ===========================================================================
# Shared fakes (mirrors test_core_movers_full.py / test_core_search.py)
# ===========================================================================

class _Q:
    def __init__(self, data):
        self._data = data

    def select(self, *_a, **_k):
        return self

    def gte(self, *_a, **_k):
        return self

    def lte(self, *_a, **_k):
        return self

    def gt(self, *_a, **_k):
        return self

    def or_(self, *_a, **_k):
        return self

    def ilike(self, *_a, **_k):
        return self

    def in_(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def order(self, *_a, **_k):
        return self

    def execute(self):
        return type("_R", (), {"data": self._data})()


class _Sb:
    def __init__(self, data=None):
        self._data = data or {}

    def table(self, name):
        return _Q(self._data.get(name, []))


def _now():
    return datetime.now(timezone.utc)


def _soon_iso(days=3):
    return (_now() + timedelta(days=days)).date().isoformat()


def _base_data(events, metrics, velocity=None, lifecycle=None,
               holidays_view=None, rivalry=None, holidays_tbl=None,
               performer_meta=None):
    return {
        "events": events,
        "latest_event_metrics": metrics,
        "event_lifecycle": lifecycle or [],
        "v_event_velocity_windows": velocity or [],
        "performer_metadata": performer_meta or [],
        "v_event_holidays": holidays_view or [],
        "v_rivalry_events": rivalry or [],
        "holidays": holidays_tbl or [],
    }


# ===========================================================================
# movers.py 596->591 — holiday-view loop: the `if key not in holiday_by_eid
# and r.get("holiday_name")` guard's FALSE side (skip without inserting).
# Feed (a) a duplicate tevo_event_id so the 2nd row finds key already present,
# and (b) a row whose holiday_name is falsy. Both keep the loop iterating but
# never assign — exercising the untaken 596->591 jump.
# ===========================================================================

def test_holiday_view_dedupe_and_blank_name_skipped():
    soon = _soon_iso(3)
    events = [{"id": 1, "name": "Knicks vs Celtics",
               "occurs_at_local": soon + "T19:00:00", "venue_location": "Bronx, NY",
               "primary_performer_id": 10, "primary_performer_name": "Knicks",
               "performer_ids": [10]}]
    metrics = [{"event_id": 1, "owned_tickets_count": 200,
                "owned_median_retail": 60.0, "owned_share": 0.1, "retail_min": 80}]
    holidays_view = [
        {"tevo_event_id": 1, "holiday_name": "Memorial Day"},   # first wins
        {"tevo_event_id": 1, "holiday_name": "Labor Day"},      # key already set -> skip
        {"tevo_event_id": 1, "holiday_name": ""},               # falsy name -> skip
    ]
    data = _base_data(events, metrics, holidays_view=holidays_view)
    out = _compute_movers(_Sb(data), "NYC", day_cap=14, cap=20)
    card = next(c for c in out["featured"] if c["id"] == 1)
    # first-match-wins: Memorial Day, not the later Labor Day duplicate.
    assert card["_featured_kind"] == "holiday"
    assert card["_featured_tag"] == "Memorial Day"


# ===========================================================================
# movers.py 613->608 — rivalry-view loop: same dedupe/blank-name FALSE side.
# ===========================================================================

def test_rivalry_view_dedupe_and_blank_name_skipped():
    soon = _soon_iso(3)
    events = [{"id": 1, "name": "Yankees vs Red Sox",
               "occurs_at_local": soon + "T19:00:00", "venue_location": "Bronx, NY",
               "primary_performer_id": 10, "primary_performer_name": "Yankees",
               "performer_ids": [10]}]
    metrics = [{"event_id": 1, "owned_tickets_count": 200,
                "owned_median_retail": 60.0, "owned_share": 0.1, "retail_min": 80}]
    rivalry = [
        {"tevo_event_id": 1, "rivalry_name": "Yankees vs Red Sox"},  # first wins
        {"tevo_event_id": 1, "rivalry_name": "Sox vs Yanks (dup)"},  # key set -> skip
        {"tevo_event_id": 1, "rivalry_name": ""},                    # falsy -> skip
    ]
    data = _base_data(events, metrics, rivalry=rivalry)
    out = _compute_movers(_Sb(data), "NYC", day_cap=14, cap=20)
    card = next(c for c in out["featured"] if c["id"] == 1)
    assert card["_featured_kind"] == "rivalry"
    # first-match-wins: the original name, not the later duplicate.
    assert card["_featured_tag"] == "Yankees vs Red Sox"


# ===========================================================================
# movers.py 734->681 — holiday-window expansion: a candidate whose date lands
# in the ±2 window of an applicable holiday but is a NON-weekend weekday other
# than the observed day. _classify_holiday_proximity returns None, so both the
# `== day_of` (732) and `== weekend_of` (734) branches are false and control
# jumps back to the per-candidate loop top (681) without tagging. Existing
# tests only hit day_of / weekend_of; this drives the else fall-through.
# ===========================================================================

def test_holiday_window_weekday_in_window_no_tag():
    # Choose an observed holiday on a Wednesday and an event on the Thursday
    # after (observed+1, inside range(-2,2)). Thursday is a weekday, not the
    # observed day -> proximity None -> no weekend/day-of tag set.
    base = _now()
    wed = base
    while wed.weekday() != 2:  # 2 == Wednesday
        wed = wed + timedelta(days=1)
    wed = wed + timedelta(days=7)          # push comfortably into the future
    while wed.weekday() != 2:
        wed = wed + timedelta(days=1)
    thu = wed + timedelta(days=1)          # observed+1, a weekday in-window
    events = [{"id": 1, "name": "Yankees vs Orioles",
               "occurs_at_local": thu.date().isoformat() + "T19:00:00",
               "venue_location": "Bronx, NY", "primary_performer_id": 10,
               "primary_performer_name": "Yankees", "performer_ids": [10]}]
    # owned_median 10 (<50) and tiny share so the event is NOT otherwise
    # featured (premium/market-anchor) — if a holiday tag leaked, it'd show.
    metrics = [{"event_id": 1, "owned_tickets_count": 200,
                "owned_median_retail": 10.0, "owned_share": 0.05, "retail_min": 5}]
    holidays_tbl = [{"observed_date": wed.date().isoformat(),
                     "holiday_name": "Juneteenth", "country": "US",
                     "state": None, "city": None}]
    data = _base_data(events, metrics, holidays_tbl=holidays_tbl)
    out = _compute_movers(_Sb(data), "NYC", day_cap=20, cap=20)
    # No holiday tag assigned: event is not in the featured rail as a holiday.
    assert all(c.get("_featured_kind") != "holiday"
               for c in out["featured"] if c["id"] == 1)


# ===========================================================================
# search.py 79->88 — `if ev_ids:` FALSE side: ev_rows is non-empty (survives
# the speculative filter) but every row has a falsy id, so ev_ids == [] and the
# latest_event_metrics block is skipped, jumping straight to the lifecycle pull.
# ===========================================================================

class _SearchDB:
    def __init__(self, by_table):
        self._by_table = by_table
        self.touched: list[str] = []

    def table(self, name):
        self.touched.append(name)
        return _Q(self._by_table.get(name, []))


def test_search_sql_only_rows_without_ids_skip_metrics():
    db = _SearchDB({
        # Non-speculative names so they survive the filter, but id is falsy
        # (None / 0) -> ev_ids comes out empty -> metrics block skipped.
        "events": [
            {"id": None, "name": "Knicks vs Celtics", "occurs_at_local": "2026-05-02"},
            {"id": 0, "name": "Celtics game", "occurs_at_local": "2026-05-03"},
        ],
        "latest_event_metrics": [{"event_id": 1, "owned_tickets_count": 9}],
        "event_lifecycle": [],
    })
    out = search_sql_only(db, "celtics", 10)
    assert out["source"] == "sql"
    # Both rows survive (none dropped as inactive); none are owned since the
    # metrics lookup was skipped.
    assert all(e["we_own"] is False for e in out["events"])
    assert len(out["events"]) == 2
    # The metrics table was never queried because ev_ids was empty.
    assert "latest_event_metrics" not in db.touched


# ===========================================================================
# substitutions.py 388->391 — `if revenue_per_ticket is not None and
# landed_cost is not None:` FALSE side. A candidate passes every upstream
# filter (better section, enough quantity) but carries no cost field, so
# landed_cost is None; the pnl block is skipped and section_delta is still set.
# Existing section tests always supply both, so only the true side was hit.
# ===========================================================================

def _cand(section, row, quantity=2, gid=None, price=None):
    return {
        "tevo_ticket_group_id": gid,
        "section": section,
        "row": row,
        "quantity": quantity,
        "retail_price": price,
    }


def test_section_sub_without_cost_skips_pnl():
    quality = {"310": 50, "108": 200}
    # Better section (108 > 310), enough qty, but NO price -> landed_cost None.
    cands = [_cand("108", "20", quantity=4, gid="lower", price=None)]
    out = find_section_substitutions("310", 4, cands, quality, revenue_per_ticket=100)
    assert len(out["section_subs"]) == 1
    sub = out["section_subs"][0]
    assert sub["match_type"] == SECTION_UPGRADE
    assert sub["to_section"] == "108"
    # cost/pnl all None (388 false side), but the section_delta still computed.
    assert sub["landed_cost"] is None
    assert sub["pnl_per_ticket"] is None
    assert sub["pnl_total"] is None
    assert sub["section_delta"] == 150  # 200 - 50


def test_section_sub_without_revenue_skips_pnl():
    # Symmetric: cost present but revenue_per_ticket None (default) -> 388 false.
    quality = {"310": 50, "108": 200}
    cands = [_cand("108", "20", quantity=4, gid="lower", price=70)]
    out = find_section_substitutions("310", 4, cands, quality)  # no revenue
    sub = out["section_subs"][0]
    assert sub["landed_cost"] == 70           # cost still read
    assert sub["pnl_per_ticket"] is None      # but no pnl without revenue
    assert sub["pnl_total"] is None
