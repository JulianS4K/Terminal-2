"""Full-coverage unit tests for core/movers.py — drives _compute_movers and
_section_featured through their many branches with a fake Supabase (no real
DB/network). Complements tests/test_core_movers.py (pure section helpers) and
tests/test_broker_movers.py (HTTP movers routes) without touching either.

House style: self-contained fake DB (cf. _Sb/_Q in test_broker_movers.py) that
routes queries by table name and supports the full PostgREST-style chain the
movers engine uses (select/gte/lte/or_/ilike/gt/in_/limit/execute).
"""
from __future__ import annotations

import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.movers import (  # noqa: E402
    _compute_movers, _section_featured,
    _classify_marquee_competition, _has_canadian_team,
    _classify_holiday_proximity, _section_specials,
)


# ---------------------------------------------------------------------------
# Fake Supabase — routes by table name, ignores filter args (the engine does
# its own in-Python filtering of whatever data we hand back), supports the full
# chained-call surface used by _compute_movers.
# ---------------------------------------------------------------------------

class _Q:
    def __init__(self, data, raise_on_execute=False, wc_data=None,
                 raise_on_ilike=False):
        self._data = data
        self._raise = raise_on_execute
        self._wc_data = wc_data          # served when .ilike() was used
        self._raise_on_ilike = raise_on_ilike
        self._ilike_used = False

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
        self._ilike_used = True
        return self

    def in_(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def execute(self):
        if self._ilike_used and self._raise_on_ilike:
            raise RuntimeError("wc boom")
        if self._raise:
            raise RuntimeError("boom")
        if self._ilike_used and self._wc_data is not None:
            return type("_R", (), {"data": self._wc_data})()
        return type("_R", (), {"data": self._data})()


class _Sb:
    """data: {table_name: rows}. raises: {table_name} that error on execute().
    The 'events' table optionally serves a separate 'events_wc' dataset for the
    World-Cup pull (the only events query that uses .ilike())."""

    def __init__(self, data=None, raises=None, wc_raises=False):
        self._data = data or {}
        self._raises = raises or set()
        self._wc_raises = wc_raises

    def table(self, name):
        wc = self._data.get("events_wc") if name == "events" else None
        return _Q(self._data.get(name, []),
                  raise_on_execute=(name in self._raises),
                  wc_data=wc,
                  raise_on_ilike=(name == "events" and self._wc_raises))


# ---------------------------------------------------------------------------
# helpers for building rows tied to a fresh "now" so velocity is considered
# fresh and dates land inside the day_cap horizon.
# ---------------------------------------------------------------------------

def _now():
    return datetime.now(timezone.utc)


def _today_iso():
    return _now().date().isoformat()


def _soon_iso(days=3):
    return (_now() + timedelta(days=days)).date().isoformat()


def _fresh_ts():
    # 1h ago — within the 48h freshness window
    return (_now() - timedelta(hours=1)).isoformat()


def _base_data(events, metrics, velocity=None, lifecycle=None,
               holidays_view=None, rivalry=None, holidays_tbl=None,
               performer_meta=None, world_cup=None):
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


# ---------------------------------------------------------------------------
# _compute_movers — early returns / city handling
# ---------------------------------------------------------------------------

def test_unknown_city_returns_empty():
    out = _compute_movers(_Sb(), "Boston", day_cap=7, cap=20)
    assert out == {"city": "Boston", "days": 7, "count": 0, "events": []}


def test_nyc_aliases_accepted_no_events():
    for city in ("NYC", "New York", "NEW YORK CITY"):
        out = _compute_movers(_Sb(_base_data([], [])), city, day_cap=7, cap=20)
        assert out["count"] == 0
        assert out["events"] == []


def test_events_query_failure_degrades_to_empty():
    db = _Sb(_base_data([], []), raises={"events"})
    out = _compute_movers(db, "NYC", day_cap=7, cap=20)
    assert out == {"city": "NYC", "days": 7, "count": 0, "events": []}


def test_no_metrics_returns_empty():
    ev = [{"id": 1, "name": "Knicks vs Celtics", "occurs_at_local": _soon_iso(),
           "venue_location": "New York, NY"}]
    db = _Sb(_base_data(ev, []))
    out = _compute_movers(db, "NYC", day_cap=7, cap=20)
    assert out["count"] == 0 and out["events"] == []


def test_all_speculative_names_filtered_to_empty():
    ev = [{"id": 1, "name": "Knicks vs Celtics (If Necessary)",
           "occurs_at_local": _soon_iso(), "venue_location": "New York, NY"}]
    db = _Sb(_base_data(ev, [{"event_id": 1, "owned_tickets_count": 200}]))
    out = _compute_movers(db, "NYC", day_cap=7, cap=20)
    # speculative non-playoff name dropped -> no events_rows left
    assert out["count"] == 0


# ---------------------------------------------------------------------------
# _compute_movers — full happy path hitting every rail + enrichment
# ---------------------------------------------------------------------------

def _rich_dataset():
    """Events covering featured/moving_fast/price_drops/climbing/specials rails."""
    soon = _soon_iso(3)
    events = [
        # 1: rivalry + holiday-view + featured (owned>100)
        {"id": 1, "name": "Yankees vs Red Sox", "occurs_at_local": soon + "T19:00:00",
         "venue_name": "Yankee Stadium", "venue_location": "Bronx, NY",
         "primary_performer_id": 10, "primary_performer_name": "Yankees",
         "performer_ids": [10, 11]},
        # 2: moving_fast (big tix drop), owned>50
        {"id": 2, "name": "Concert A", "occurs_at_local": soon + "T20:00:00",
         "venue_name": "MSG", "venue_location": "Manhattan, NY",
         "primary_performer_id": 20, "primary_performer_name": "Band A",
         "performer_ids": [20]},
        # 3: price_drops (getin down >=10%)
        {"id": 3, "name": "Concert B", "occurs_at_local": soon + "T20:00:00",
         "venue_name": "MSG", "venue_location": "Brooklyn, NY",
         "primary_performer_id": None, "primary_performer_name": None,
         "performer_ids": []},
        # 4: climbing (tix down + getin up >=5%)
        {"id": 4, "name": "Concert C", "occurs_at_local": soon + "T20:00:00",
         "venue_name": "MSG", "venue_location": "Queens, NY",
         "primary_performer_id": 40, "primary_performer_name": "Band C",
         "performer_ids": ["bad", 40, 41]},
        # 5: specials-only holiday (owned>100, no featured/velocity signal)
        {"id": 5, "name": "Mets Game", "occurs_at_local": soon + "T13:00:00",
         "venue_name": "Citi Field", "venue_location": "Queens, NY",
         "primary_performer_id": 50, "primary_performer_name": "Mets",
         "performer_ids": [50]},
    ]
    metrics = [
        {"event_id": 1, "owned_tickets_count": 250, "owned_median_retail": 120.0,
         "owned_share": 0.3, "retail_min": 80},
        {"event_id": 2, "owned_tickets_count": 60, "owned_median_retail": 40.0,
         "retail_min": 30},
        {"event_id": 3, "owned_tickets_count": 60, "owned_median_retail": 40.0,
         "retail_min": None},
        {"event_id": 4, "owned_tickets_count": 60, "owned_median_retail": 40.0,
         "retail_min": 25},
        {"event_id": 5, "owned_tickets_count": 150, "owned_median_retail": 20.0,
         "retail_min": 15},
    ]
    velocity = [
        {"tevo_event_id": 2, "tevo_tix_d24h": -80, "tevo_getin_d24h_pct": 0.0,
         "tevo_getin_now": 30, "tevo_now_at": _fresh_ts()},
        {"tevo_event_id": 3, "tevo_tix_d24h": -5, "tevo_getin_d24h_pct": -20.0,
         "tevo_getin_now": 28, "tevo_now_at": _fresh_ts()},
        {"tevo_event_id": 4, "tevo_tix_d24h": -5, "tevo_getin_d24h_pct": 9.0,
         "tevo_getin_now": 26, "tevo_now_at": _fresh_ts()},
    ]
    holidays_view = [{"tevo_event_id": 5, "holiday_name": "Memorial Day"}]
    rivalry = [{"tevo_event_id": 1, "rivalry_name": "Yankees vs Red Sox",
                "rivalry_intensity": 9}]
    performer_meta = [
        {"performer_id": 10, "name": "Yankees", "logo_default_url": "y.png",
         "color_primary": "#001"},
        {"performer_id": 11, "name": "Red Sox", "logo_default_url": "r.png",
         "color_primary": "#f00"},
    ]
    return _base_data(events, metrics, velocity=velocity,
                      holidays_view=holidays_view, rivalry=rivalry,
                      performer_meta=performer_meta)


def test_full_happy_path_populates_all_rails():
    db = _Sb(_rich_dataset())
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    assert out["city"] == "NYC"
    # event 1 -> featured (rivalry), 2 -> moving_fast, 3 -> price_drops,
    # 4 -> climbing, 5 -> specials (holiday owned>100)
    feat_ids = {c["id"] for c in out["featured"]}
    # 1 (rivalry) + 5 (holiday) both clear featured's owned>100 gate and are
    # consumed there first (featured runs before specials).
    assert {1, 5} <= feat_ids
    assert {c["id"] for c in out["moving_fast"]} == {2}
    assert {c["id"] for c in out["price_drops"]} == {3}
    assert {c["id"] for c in out["climbing"]} == {4}
    assert out["count"] == (len(out["featured"]) + len(out["moving_fast"])
                            + len(out["price_drops"]) + len(out["climbing"])
                            + len(out["specials"]))
    # home-team assets attached on featured rivalry card
    card1 = next(c for c in out["featured"] if c["id"] == 1)
    assert card1["primary_performer_logo"] == "y.png"
    assert card1["away_performer_name"] == "Red Sox"


def test_inactive_lifecycle_drops_event():
    data = _rich_dataset()
    data["event_lifecycle"] = [{"event_id": 2, "is_active": False}]
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    assert {c["id"] for c in out["moving_fast"]} == set()


def test_world_cup_event_survives_inactive_and_gate():
    soon = _soon_iso(5)
    events = [
        {"id": 99, "name": "World Cup Soccer Match 72",
         "occurs_at_local": soon + "T18:00:00", "venue_name": "MB Stadium",
         "venue_location": "Atlanta, GA",  # outside NYC patterns -> via WC pull
         "primary_performer_id": 70,
         "primary_performer_name": "World Cup Soccer", "performer_ids": [70]},
    ]
    metrics = [{"event_id": 99, "owned_tickets_count": 62,
                "owned_median_retail": 300.0, "retail_min": 250}]
    # NYC events query returns one unrelated NYC event; WC pull (.ilike) adds 99.
    nyc_ev = [{"id": 1, "name": "Knicks vs Celtics",
               "occurs_at_local": soon + "T19:00:00", "venue_location": "Bronx, NY",
               "primary_performer_id": None, "primary_performer_name": None,
               "performer_ids": []}]
    metrics.append({"event_id": 1, "owned_tickets_count": 5,
                    "owned_median_retail": 5.0, "retail_min": 5})
    data = _base_data(nyc_ev, metrics)
    data["events_wc"] = events  # served only when .ilike() is used
    data["event_lifecycle"] = [{"event_id": 99, "is_active": False}]
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=30, cap=20)
    # WC exempt from inactive + owned<=100 gate -> reaches featured
    assert any(c["id"] == 99 and c.get("_featured_kind") == "world_cup"
               for c in out["featured"])


def test_world_cup_dedupe_skips_already_seen():
    soon = _soon_iso(5)
    ev = {"id": 99, "name": "World Cup Soccer Match 72",
          "occurs_at_local": soon + "T18:00:00", "venue_name": "MB",
          "venue_location": "New York, NY", "primary_performer_id": 70,
          "primary_performer_name": "World Cup Soccer", "performer_ids": [70]}
    metrics = [{"event_id": 99, "owned_tickets_count": 200,
                "owned_median_retail": 300.0, "retail_min": 250}]
    data = _base_data([ev], metrics)
    # WC pull returns the SAME event -> dedupe path (already in seen_eids)
    data["events_wc"] = [ev]
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=30, cap=20)
    # appears once even though both events query + WC query return it
    assert sum(1 for c in out["featured"] if c["id"] == 99) == 1


def test_world_cup_pull_failure_degrades():
    # NYC events succeed; the WC .ilike() query raises -> swallowed, NYC-only.
    data = _rich_dataset()
    db = _Sb(data, wc_raises=True)
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    assert any(c["id"] == 1 for c in out["featured"])


def test_velocity_and_lifecycle_query_failures_degrade():
    data = _rich_dataset()
    db = _Sb(data, raises={"event_lifecycle", "v_event_velocity_windows"})
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    # lifecycle/velocity exceptions are swallowed; rails relying on velocity
    # go empty but featured (no velocity needed) still works
    assert any(c["id"] == 1 for c in out["featured"])
    assert out["moving_fast"] == []


def test_specials_and_rivalry_view_failures_degrade():
    data = _rich_dataset()
    db = _Sb(data, raises={"v_event_holidays", "v_rivalry_events"})
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    # no rivalry/holiday-view tags -> event 1 falls to premium featured branch
    card1 = next(c for c in out["featured"] if c["id"] == 1)
    assert card1.get("_featured_kind") in ("premium", "market_anchor")


def test_holiday_window_expansion_weekend_tag():
    # Build a candidate on a Saturday adjacent to a holiday observed Friday.
    # Find a near-future Saturday.
    base = _now()
    # advance to next Saturday
    sat = base + timedelta(days=(5 - base.weekday()) % 7 + 1)
    sat_d = sat.date()
    fri_d = (sat - timedelta(days=1)).date()
    events = [{"id": 7, "name": "Yankees vs Orioles",
               "occurs_at_local": sat_d.isoformat() + "T19:00:00",
               "venue_name": "Yankee Stadium", "venue_location": "Bronx, NY",
               "primary_performer_id": 10, "primary_performer_name": "Yankees",
               "performer_ids": [10]}]
    metrics = [{"event_id": 7, "owned_tickets_count": 250,
                "owned_median_retail": 120.0, "owned_share": 0.1,
                "retail_min": 80}]
    holidays_tbl = [{"observed_date": fri_d.isoformat(),
                     "holiday_name": "Independence Day", "country": "US",
                     "state": None, "city": None}]
    data = _base_data(events, metrics, holidays_tbl=holidays_tbl)
    db = _Sb(data)
    # day_cap big enough to include the saturday
    out = _compute_movers(db, "NYC", day_cap=20, cap=20)
    card = next((c for c in out["featured"] if c["id"] == 7), None)
    assert card is not None
    assert card["_featured_kind"] == "holiday"
    assert card["_featured_tag"] == "Independence Day Weekend"


def test_holiday_window_canadian_team_gate_and_skips():
    base = _now()
    sat = base + timedelta(days=(5 - base.weekday()) % 7 + 1)
    sat_d = sat.date()
    fri_d = (sat - timedelta(days=1)).date()
    events = [
        # Canadian team visiting -> CA holiday applies
        {"id": 8, "name": "Toronto Blue Jays at Yankees",
         "occurs_at_local": sat_d.isoformat() + "T19:00:00",
         "venue_location": "Bronx, NY", "primary_performer_id": 10,
         "primary_performer_name": "Yankees", "performer_ids": [10]},
        # Non-Canadian -> CA holiday skipped, US other-state skipped -> no tag
        {"id": 9, "name": "Yankees vs Orioles",
         "occurs_at_local": sat_d.isoformat() + "T19:00:00",
         "venue_location": "Bronx, NY", "primary_performer_id": 10,
         "primary_performer_name": "Yankees", "performer_ids": [10]},
    ]
    metrics = [
        {"event_id": 8, "owned_tickets_count": 250, "owned_median_retail": 120.0,
         "owned_share": 0.1, "retail_min": 80},
        {"event_id": 9, "owned_tickets_count": 250, "owned_median_retail": 10.0,
         "owned_share": 0.05, "retail_min": 5},
    ]
    holidays_tbl = [
        {"observed_date": fri_d.isoformat(), "holiday_name": "Canada Day",
         "country": "CA", "state": None, "city": None},
        # province-specific CA holiday -> always skipped
        {"observed_date": fri_d.isoformat(), "holiday_name": "Civic Holiday",
         "country": "CA", "state": "QC", "city": None},
        # other-state US holiday -> skipped for both
        {"observed_date": fri_d.isoformat(), "holiday_name": "Patriots Day",
         "country": "US", "state": "MA", "city": None},
        # other-city US holiday -> skipped
        {"observed_date": fri_d.isoformat(), "holiday_name": "Evacuation Day",
         "country": "US", "state": None, "city": "Boston"},
        # other-country -> skipped
        {"observed_date": fri_d.isoformat(), "holiday_name": "Bastille Day",
         "country": "FR", "state": None, "city": None},
    ]
    data = _base_data(events, metrics, holidays_tbl=holidays_tbl)
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=20, cap=20)
    card8 = next((c for c in out["featured"] if c["id"] == 8), None)
    assert card8 is not None and card8["_featured_tag"] == "Canada Day Weekend"
    # event 9 has no applicable holiday; owned_median 10 (<50) and share 0.05 so
    # not premium nor market-anchor -> not in featured at all
    assert all(c["id"] != 9 for c in out["featured"])


def test_holiday_window_query_failure_degrades():
    data = _rich_dataset()
    db = _Sb(data, raises={"holidays"})
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    # still produces a response; rivalry/holiday-view path unaffected
    assert any(c["id"] == 1 for c in out["featured"])


def test_empty_rail_fallback():
    soon = _soon_iso(3)
    # owned but tiny (<=50): no rail qualifies -> fallback fires
    events = [{"id": 30, "name": "Tiny Show", "occurs_at_local": soon + "T20:00:00",
               "venue_name": "Club", "venue_location": "Manhattan, NY",
               "primary_performer_id": None, "primary_performer_name": None,
               "performer_ids": []}]
    metrics = [{"event_id": 30, "owned_tickets_count": 10,
                "owned_median_retail": 5.0, "retail_min": 5}]
    db = _Sb(_base_data(events, metrics))
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    assert len(out["featured"]) == 1
    assert out["featured"][0]["_featured_kind"] == "fallback"
    assert out["featured"][0]["_featured_tag"] == ""


# ---------------------------------------------------------------------------
# _section_featured — branch coverage for tags + gates
# ---------------------------------------------------------------------------

def test_featured_playoff_exempt_from_owned_gate():
    cands = [{"id": 1, "name": "Knicks vs Celtics - Eastern Conference Finals Game 7",
              "owned_tickets_count": 60, "owned_median_retail": 5000.0,
              "occurs_at_local": "2026-06-01"}]
    out = _section_featured(cands, {}, {})
    assert len(out) == 1
    assert out[0]["_featured_kind"] == "playoff"


def test_featured_market_anchor_branch():
    cands = [{"id": 2, "name": "Regular Game", "owned_tickets_count": 300,
              "owned_median_retail": 20.0, "owned_share": 0.25,
              "occurs_at_local": "2026-06-01"}]
    out = _section_featured(cands, {}, {})
    assert len(out) == 1
    assert out[0]["_featured_kind"] == "market_anchor"
    assert out[0]["_featured_tag"] == ""


def test_featured_holiday_day_of_no_weekend_suffix():
    cands = [{"id": 3, "name": "Game", "owned_tickets_count": 200,
              "owned_median_retail": 60.0, "occurs_at_local": "2026-06-01"}]
    out = _section_featured(cands, {3: {"name": "Memorial Day", "weekend": False}}, {})
    assert out[0]["_featured_tag"] == "Memorial Day"
    assert out[0]["_featured_kind"] == "holiday"


def test_featured_marquee_branch():
    cands = [{"id": 4, "name": "US Open Tennis - Day 5", "owned_tickets_count": 200,
              "owned_median_retail": 30.0, "occurs_at_local": "2026-06-01"}]
    out = _section_featured(cands, {}, {})
    assert out[0]["_featured_kind"] == "marquee"
    assert out[0]["_featured_tag"] == "US Open Tennis"


def test_featured_skips_missing_or_bad_id():
    cands = [
        {"id": None, "name": "X", "owned_tickets_count": 200,
         "owned_median_retail": 60.0},
        {"id": "not-int", "name": "Y", "owned_tickets_count": 200,
         "owned_median_retail": 60.0},
        {"id": 5, "name": "Good", "owned_tickets_count": 200,
         "owned_median_retail": 60.0, "occurs_at_local": "2026-06-01"},
    ]
    out = _section_featured(cands, {}, {})
    assert [c["id"] for c in out] == [5]


def test_featured_below_gate_and_bad_numeric_fields_dropped():
    cands = [
        # owned<=100, not playoff/wc -> dropped
        {"id": 6, "name": "Small", "owned_tickets_count": 50,
         "owned_median_retail": 999.0, "occurs_at_local": "2026-06-01"},
        # owned>100 but median/share unparseable + not premium -> dropped
        {"id": 7, "name": "Junk", "owned_tickets_count": 150,
         "owned_median_retail": "n/a", "owned_share": "n/a",
         "occurs_at_local": "2026-06-01"},
    ]
    out = _section_featured(cands, {}, {})
    assert out == []


def test_featured_world_cup_branch():
    cands = [{"id": 8, "name": "Group Stage Match",
              "primary_performer_name": "World Cup Soccer",
              "owned_tickets_count": 60, "owned_median_retail": 0.0,
              "occurs_at_local": "2026-06-01"}]
    out = _section_featured(cands, {}, {})
    assert out[0]["_featured_kind"] == "world_cup"
    assert out[0]["_featured_tag"] == "World Cup"


# ---------------------------------------------------------------------------
# pure-classifier None/edge branches (lines 47, 75, 118-125)
# ---------------------------------------------------------------------------

def test_classifier_none_inputs():
    assert _classify_marquee_competition(None) is None
    assert _classify_marquee_competition("") is None
    assert _has_canadian_team(None) is False
    assert _has_canadian_team("") is False


def test_holiday_proximity_all_branches():
    # bad date -> None (TypeError/ValueError guard)
    assert _classify_holiday_proximity("nope", "2026-01-01") is None
    assert _classify_holiday_proximity(None, "2026-01-01") is None  # type: ignore[arg-type]
    # exact match -> day_of
    assert _classify_holiday_proximity("2026-01-01", "2026-01-01") == "day_of"
    # Saturday (2026-01-03) -> weekend_of
    assert _classify_holiday_proximity("2026-01-03", "2026-01-02") == "weekend_of"
    # Friday weekday in window -> None
    assert _classify_holiday_proximity("2026-01-02", "2026-01-01") is None


# ---------------------------------------------------------------------------
# _section_specials bad/None id branches (lines 197-198, 200)
# ---------------------------------------------------------------------------

def test_section_specials_bad_and_none_ids_skipped():
    cands = [
        {"id": "not-int", "owned_tickets_count": 200, "occurs_at_local": "x"},
        {"id": None, "owned_tickets_count": 200, "occurs_at_local": "x"},
        {"id": 1, "owned_tickets_count": 200, "occurs_at_local": "2026-05-01"},
    ]
    out = _section_specials(cands, {}, {1: "Rivalry X"})
    assert [c["id"] for c in out] == [1]


# ---------------------------------------------------------------------------
# _compute_movers — value-parse + None-eid resilience inside the builder loop
# ---------------------------------------------------------------------------

def test_compute_handles_unparseable_velocity_and_performer_ids():
    soon = _soon_iso(3)
    events = [{"id": 1, "name": "Knicks vs Celtics",
               "occurs_at_local": soon + "T19:00:00", "venue_location": "Bronx, NY",
               "primary_performer_id": "not-int",       # bad primary -> except
               "primary_performer_name": "Knicks",
               "performer_ids": ["bad", None, 11]}]      # bad away ids skipped
    metrics = [{"event_id": 1, "owned_tickets_count": 200,
                "owned_median_retail": 60.0, "owned_share": 0.1, "retail_min": 80}]
    velocity = [{"tevo_event_id": 1, "tevo_tix_d24h": "xx",  # unparseable int
                 "tevo_getin_d24h_pct": "yy",               # unparseable float
                 "tevo_getin_now": 30, "tevo_now_at": _fresh_ts()}]
    data = _base_data(events, metrics, velocity=velocity)
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    card = next(c for c in out["featured"] if c["id"] == 1)
    assert card["tix_d24h"] is None and card["getin_pct_24h"] is None


def test_compute_stale_velocity_and_bad_timestamp():
    soon = _soon_iso(3)
    events = [
        {"id": 1, "name": "Game One", "occurs_at_local": soon + "T19:00:00",
         "venue_location": "Bronx, NY", "primary_performer_id": 10,
         "primary_performer_name": "A", "performer_ids": [10]},
        {"id": 2, "name": "Game Two", "occurs_at_local": soon + "T19:00:00",
         "venue_location": "Bronx, NY", "primary_performer_id": 20,
         "primary_performer_name": "B", "performer_ids": [20]},
    ]
    metrics = [
        {"event_id": 1, "owned_tickets_count": 200, "owned_median_retail": 60.0,
         "owned_share": 0.1, "retail_min": 80},
        {"event_id": 2, "owned_tickets_count": 200, "owned_median_retail": 60.0,
         "owned_share": 0.1, "retail_min": 80},
    ]
    velocity = [
        # stale ts (3 days old) -> not fresh -> tix/getin treated None
        {"tevo_event_id": 1, "tevo_tix_d24h": -90, "tevo_getin_d24h_pct": -20.0,
         "tevo_getin_now": 30,
         "tevo_now_at": (_now() - timedelta(days=3)).isoformat()},
        # unparseable timestamp -> _is_velocity_fresh except branch -> False
        {"tevo_event_id": 2, "tevo_tix_d24h": -90, "tevo_getin_d24h_pct": -20.0,
         "tevo_getin_now": 30, "tevo_now_at": "not-a-timestamp"},
    ]
    data = _base_data(events, metrics, velocity=velocity)
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    # stale/bad velocity -> neither hits moving_fast/price_drops
    assert out["moving_fast"] == [] and out["price_drops"] == []


def test_compute_view_rows_with_none_eid_skipped():
    soon = _soon_iso(3)
    events = [{"id": 1, "name": "Knicks vs Celtics",
               "occurs_at_local": soon + "T19:00:00", "venue_location": "Bronx, NY",
               "primary_performer_id": 10, "primary_performer_name": "Knicks",
               "performer_ids": [10]}]
    metrics = [{"event_id": 1, "owned_tickets_count": 200,
                "owned_median_retail": 60.0, "owned_share": 0.1, "retail_min": 80}]
    holidays_view = [{"tevo_event_id": None, "holiday_name": "Memorial Day"}]
    rivalry = [{"tevo_event_id": None, "rivalry_name": "X"}]
    data = _base_data(events, metrics, holidays_view=holidays_view, rivalry=rivalry)
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    # None-eid view rows ignored; event still featured via premium branch
    assert any(c["id"] == 1 for c in out["featured"])


def test_holiday_window_day_of_tag():
    # event lands exactly ON an observed holiday weekday (not weekend) -> day_of
    base = _now()
    # pick a weekday (Mon-Thu) in the near future as observed_date == event date
    d = base
    while d.weekday() > 3:  # ensure Mon..Thu so it's a weekday, not weekend
        d = d + timedelta(days=1)
    d = d + timedelta(days=7)
    while d.weekday() > 3:
        d = d + timedelta(days=1)
    ds = d.date().isoformat()
    events = [{"id": 1, "name": "Yankees vs Orioles",
               "occurs_at_local": ds + "T19:00:00", "venue_location": "Bronx, NY",
               "primary_performer_id": 10, "primary_performer_name": "Yankees",
               "performer_ids": [10]}]
    metrics = [{"event_id": 1, "owned_tickets_count": 200,
                "owned_median_retail": 10.0, "owned_share": 0.05, "retail_min": 5}]
    holidays_tbl = [{"observed_date": ds, "holiday_name": "Juneteenth",
                     "country": "US", "state": None, "city": None}]
    data = _base_data(events, metrics, holidays_tbl=holidays_tbl)
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=20, cap=20)
    card = next((c for c in out["featured"] if c["id"] == 1), None)
    assert card is not None
    assert card["_featured_kind"] == "holiday"
    assert card["_featured_tag"] == "Juneteenth"  # day-of, no Weekend suffix


def test_holiday_window_bad_observed_dates_skipped():
    soon = _soon_iso(3)
    events = [{"id": 1, "name": "Yankees vs Orioles",
               "occurs_at_local": soon + "T19:00:00", "venue_location": "Bronx, NY",
               "primary_performer_id": 10, "primary_performer_name": "Yankees",
               "performer_ids": [10]}]
    metrics = [{"event_id": 1, "owned_tickets_count": 200,
                "owned_median_retail": 60.0, "owned_share": 0.1, "retail_min": 80}]
    holidays_tbl = [
        {"observed_date": None, "holiday_name": "X", "country": "US"},      # falsy obs
        {"observed_date": "garbage", "holiday_name": "Y", "country": "US"},  # bad parse
    ]
    data = _base_data(events, metrics, holidays_tbl=holidays_tbl)
    db = _Sb(data)
    out = _compute_movers(db, "NYC", day_cap=14, cap=20)
    # bad holiday rows skipped; event still featured (premium)
    assert any(c["id"] == 1 for c in out["featured"])
