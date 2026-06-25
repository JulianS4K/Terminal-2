"""Full line-coverage tests for core/broker_helpers.py.

These exercise bulk_performer_assets + bulk_event_context directly against a
programmable FakeSupabase (no network/DB). The fake drives the fluent
`.table(name).select(...).in_(...).gte(...).execute().data` chains the helpers
use, returning per-table preloaded rows so every assembly / dedupe / display
branch can be hit deterministically.

Style mirrors tests/test_broker_routes.py (its FakeSupabase), reproduced here so
this file stands alone and edits no existing test.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("SUPABASE_URL", "https://example.invalid")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-key")
os.environ.setdefault("TEVO_TOKEN", "test-token")
os.environ.setdefault("TEVO_SECRET", "test-secret")
os.environ.setdefault("AUTH_DISABLED", "true")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.broker_helpers import bulk_performer_assets, bulk_event_context  # noqa: E402


# ---------- Programmable fake Supabase ----------

class _FakeQuery:
    """No-op fluent chain; execute() yields an object exposing `.data`.

    If `raise_on_execute` is set, execute() raises it — lets us drive the
    per-section `try/except` degradation branches in bulk_event_context.
    """

    def __init__(self, data, raise_on_execute=None):
        self._data = data
        self._raise = raise_on_execute

    def select(self, *_a, **_k):
        return self

    def in_(self, *_a, **_k):
        return self

    def gte(self, *_a, **_k):
        return self

    def execute(self):
        if self._raise is not None:
            raise self._raise
        return type("_Res", (), {"data": self._data})()


class FakeSupabase:
    """table_data: {table_name: rows}. Unknown tables default to [].

    raise_tables: set of table names whose .execute() should raise (to exercise
    the except branches). data_none_tables: tables that return None (.data is
    None) to exercise the `or []` / `or {}` fallbacks.
    """

    def __init__(self, table_data=None, raise_tables=None, data_none_tables=None):
        self.table_data = table_data or {}
        self.raise_tables = raise_tables or set()
        self.data_none_tables = data_none_tables or set()
        self.table_calls: list[str] = []

    def table(self, name):
        self.table_calls.append(name)
        exc = RuntimeError(f"boom:{name}") if name in self.raise_tables else None
        if name in self.data_none_tables:
            return _FakeQuery(None, raise_on_execute=exc)
        return _FakeQuery(self.table_data.get(name, []), raise_on_execute=exc)


# ---------- bulk_performer_assets ----------

def test_performer_assets_empty_ids_returns_empty():
    assert bulk_performer_assets(FakeSupabase(), []) == {}


def test_performer_assets_maps_rows_by_id():
    rows = [
        {"performer_id": 16303, "name": "Knicks", "logo_default_url": "x"},
        {"performer_id": "777", "name": "Celtics"},  # str id coerced to int key
    ]
    out = bulk_performer_assets(FakeSupabase(table_data={"performer_metadata": rows}), [16303, 777])
    assert set(out) == {16303, 777}
    assert out[16303]["name"] == "Knicks"
    assert out[777]["name"] == "Celtics"


def test_performer_assets_none_data_falls_back_to_empty():
    out = bulk_performer_assets(
        FakeSupabase(data_none_tables={"performer_metadata"}), [1])
    assert out == {}


# ---------- bulk_event_context: trivial ----------

def test_event_context_empty_ids_returns_empty():
    assert bulk_event_context(FakeSupabase(), []) == {}


def test_event_context_filters_none_ids_and_inits_skeleton():
    # event_ids with a None entry: None is dropped, the rest get a full skeleton.
    out = bulk_event_context(FakeSupabase(), [5, None, 6])
    assert set(out) == {5, 6}
    assert out[5] == {"rivalry": None, "mlb_series": None, "tournament": None,
                      "weather": None, "holiday": None, "playoff": None}


# ---------- Playoff branch ----------

def test_playoff_specific_series_tag_wins():
    # Event carries a series-tag performer "NBA Finals" (specific) -> label kept,
    # short-circuits the loop. Also an unparseable performer id is skipped.
    events = [{"id": 1, "name": "Knicks vs Celtics", "performer_ids": [16303, "bad", 900]}]
    pm = [{"performer_id": 900, "name": "NBA Finals"}]
    out = bulk_event_context(
        FakeSupabase(table_data={"events": events, "performer_metadata": pm}), [1])
    assert out[1]["playoff"] == {"label": "NBA Finals", "kind": "specific"}


def test_playoff_generic_tag_when_no_specific():
    # Generic series tag ("NBA Playoffs") matched by the inline regex; tagged but
    # generic -> kind generic. Two generic tags: first sets tagged, stays generic.
    events = [{"id": 2, "name": "Some Game", "performer_ids": [901, 902]}]
    pm = [
        {"performer_id": 901, "name": "NBA Playoffs"},
        {"performer_id": 902, "name": "NBA Postseason"},
    ]
    out = bulk_event_context(
        FakeSupabase(table_data={"events": events, "performer_metadata": pm}), [2])
    assert out[2]["playoff"]["kind"] == "generic"
    assert out[2]["playoff"]["label"] in ("NBA Playoffs", "NBA Postseason")


def test_playoff_falls_back_to_name_regex_when_no_tag():
    # No series-tag performer -> regex on event name finds the specific label.
    events = [{"id": 3, "name": "World Series Game 7", "performer_ids": [123]}]
    pm = [{"performer_id": 123, "name": "Plain Team Name"}]  # not a series tag
    out = bulk_event_context(
        FakeSupabase(table_data={"events": events, "performer_metadata": pm}), [3])
    assert out[3]["playoff"] == {"label": "World Series", "kind": "specific"}


def test_playoff_no_candidate_performers_and_none_match():
    # Event has no performer_ids -> candidate set empty, pm query skipped;
    # name has no playoff marker -> classify_playoff returns None.
    events = [{"id": 4, "name": "Regular Tuesday Game", "performer_ids": []}]
    out = bulk_event_context(FakeSupabase(table_data={"events": events}), [4])
    assert out[4]["playoff"] is None


def test_playoff_event_id_not_in_ctx_is_skipped():
    # events row for an id not requested -> skipped without error.
    events = [{"id": 999, "name": "World Series", "performer_ids": []}]
    out = bulk_event_context(FakeSupabase(table_data={"events": events}), [4])
    assert out[4]["playoff"] is None


def test_playoff_specific_tag_with_unparseable_id_in_second_loop():
    # The second loop over performer_ids also hits the TypeError/ValueError
    # continue (the "bad" id) before resolving the good tag.
    events = [{"id": 5, "name": "x", "performer_ids": ["bad", 910]}]
    pm = [{"performer_id": 910, "name": "Stanley Cup Finals"}]
    out = bulk_event_context(
        FakeSupabase(table_data={"events": events, "performer_metadata": pm}), [5])
    assert out[5]["playoff"]["kind"] == "specific"


def test_playoff_pm_query_exception_degrades():
    # performer_metadata query raises -> series_tag_by_id reset to {} -> name regex.
    events = [{"id": 6, "name": "NBA Finals", "performer_ids": [920]}]
    out = bulk_event_context(
        FakeSupabase(table_data={"events": events}, raise_tables={"performer_metadata"}),
        [6])
    assert out[6]["playoff"] == {"label": "NBA Finals", "kind": "specific"}


def test_playoff_events_query_exception_degrades():
    out = bulk_event_context(
        FakeSupabase(raise_tables={"events"}), [7])
    assert out[7]["playoff"] is None


# ---------- Rivalry branch ----------

def test_rivalry_dedupes_and_skips_unknown_eid():
    rows = [
        {"tevo_event_id": 10, "rivalry_name": "Clasico", "league": "LaLiga",
         "is_branded": True, "rivalry_intensity": 9, "wikipedia_url": "u"},
        {"tevo_event_id": 10, "rivalry_name": "Dup", "league": "x"},  # dup -> ignored
        {"tevo_event_id": 99, "rivalry_name": "OffList"},  # not requested -> skipped
    ]
    out = bulk_event_context(FakeSupabase(table_data={"v_rivalry_events": rows}), [10])
    assert out[10]["rivalry"]["name"] == "Clasico"
    assert out[10]["rivalry"]["is_branded"] is True


def test_rivalry_query_exception_degrades():
    out = bulk_event_context(
        FakeSupabase(raise_tables={"v_rivalry_events"}), [10])
    assert out[10]["rivalry"] is None


# ---------- MLB series branch ----------

def test_mlb_series_attaches_game_number_and_skips_none_and_unknown():
    rows = [{
        "home_team": "Padres", "away_team": "Braves", "venue_name": "Petco",
        "series_start": "2026-06-25", "series_end": "2026-06-27",
        "series_span_days": 3, "game_count": 3,
        "tevo_event_ids": [20, None, 21, 999], "branded_series_name": "NL West Clash",
    }]
    out = bulk_event_context(FakeSupabase(table_data={"v_mlb_game_series": rows}), [20, 21])
    # 20 is position 1; None is filtered before enumerate; 21 is position 2; 999 skipped.
    assert out[20]["mlb_series"]["game_number"] == 1
    assert out[21]["mlb_series"]["game_number"] == 2
    assert out[20]["mlb_series"]["sibling_event_ids"] == [20, 21, 999]
    assert out[20]["mlb_series"]["branded_name"] == "NL West Clash"


def test_mlb_series_empty_tevo_ids():
    rows = [{"home_team": "X", "tevo_event_ids": None}]
    out = bulk_event_context(FakeSupabase(table_data={"v_mlb_game_series": rows}), [20])
    assert out[20]["mlb_series"] is None


def test_mlb_series_query_exception_degrades():
    out = bulk_event_context(
        FakeSupabase(raise_tables={"v_mlb_game_series"}), [20])
    assert out[20]["mlb_series"] is None


# ---------- Tournament branch ----------

def test_tournament_maps_and_skips_unknown_eid():
    rows = [
        {"tevo_event_id": 30, "tournament_name": "US Open", "tournament_short_name": "USO",
         "tournament_start": "2026-08-26", "tournament_end": "2026-09-08",
         "tournament_venue": "Flushing", "espn_league": "tennis", "circuit_name": "ATP"},
        {"tevo_event_id": 999, "tournament_name": "Off"},  # skipped
    ]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_tournament_context": rows}), [30])
    assert out[30]["tournament"]["name"] == "US Open"
    assert out[30]["tournament"]["league"] == "tennis"


def test_tournament_query_exception_degrades():
    out = bulk_event_context(
        FakeSupabase(raise_tables={"v_event_tournament_context"}), [30])
    assert out[30]["tournament"] is None


# ---------- Weather branch ----------

def test_weather_skips_too_far_too_past_and_unknown():
    rows = [
        {"tevo_event_id": 40, "days_to_event": None},      # None -> skip
        {"tevo_event_id": 40, "days_to_event": 99},        # >16 -> skip
        {"tevo_event_id": 40, "days_to_event": -1},        # <0 -> skip
        {"tevo_event_id": 999, "days_to_event": 1},        # unknown eid -> skip
    ]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_weather_with_fallback": rows}), [40])
    assert out[40]["weather"] is None


def test_weather_no_alert_no_forecast_is_hidden():
    # Indoor, no alerts, no forecast -> nothing worth showing.
    rows = [{"tevo_event_id": 41, "days_to_event": 2, "is_indoor": True,
             "weather_kind": "climatology", "weather_alerts": []}]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_weather_with_fallback": rows}), [41])
    assert out[41]["weather"] is None


def test_weather_alert_only_path_caps_three():
    alerts = [
        {"event": f"A{i}", "severity": "S", "impact_tier": "t", "headline": "h",
         "expires_at": "z"} for i in range(5)
    ]
    rows = [{"tevo_event_id": 42, "days_to_event": 10, "is_indoor": True,
             "weather_kind": "forecast_outdoor", "weather_alerts": alerts}]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_weather_with_fallback": rows}), [42])
    w = out[42]["weather"]
    assert len(w["alerts"]) == 3          # capped
    assert "forecast" not in w            # indoor + >7d => no forecast block
    assert w["is_indoor"] is True


def test_weather_outdoor_forecast_block():
    rows = [{"tevo_event_id": 43, "days_to_event": 3, "is_indoor": False,
             "weather_kind": "forecast_outdoor_x", "fcst_temp_f": 72,
             "fcst_summary": "Sunny", "fcst_precip_pct": 10, "fcst_precip_in": 0,
             "fcst_wind_mph": 5, "fcst_gust_mph": 9, "weather_alerts": []}]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_weather_with_fallback": rows}), [43])
    w = out[43]["weather"]
    assert w["forecast"]["temp_f"] == 72
    assert w["forecast"]["summary"] == "Sunny"


def test_weather_outdoor_but_no_temp_no_forecast_hidden():
    # Outdoor + within range + no alerts but fcst_temp_f None -> show_forecast
    # False -> hidden.
    rows = [{"tevo_event_id": 44, "days_to_event": 3, "is_indoor": False,
             "weather_kind": "forecast_outdoor", "fcst_temp_f": None,
             "weather_alerts": []}]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_weather_with_fallback": rows}), [44])
    assert out[44]["weather"] is None


def test_weather_query_exception_degrades():
    out = bulk_event_context(
        FakeSupabase(raise_tables={"v_event_weather_with_fallback"}), [40])
    assert out[40]["weather"] is None


# ---------- Holiday branch ----------

def test_holiday_day_of_boost_wins():
    rows = [{
        "tevo_event_id": 50, "event_date": "2026-07-04",
        "holidays_today": [
            {"name": "Random Day", "impact": "neutral", "precision": "national"},
            {"name": "July 4th", "impact": "boost", "precision": "national"},
        ],
        "holidays_nearby": [], "school_breaks_active": [],
    }]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_calendar_context": rows}), [50])
    assert out[50]["holiday"]["kind"] == "day_of"
    assert out[50]["holiday"]["label"] == "July 4th"


def test_holiday_nearby_when_no_day_of():
    rows = [{
        "tevo_event_id": 51, "event_date": "2026-07-05",
        "holidays_today": [],
        "holidays_nearby": [
            {"name": "Indep Day", "impact": "boost", "precision": "national",
             "days_offset": -1, "date": "2026-07-04"},
        ],
        "school_breaks_active": [],
    }]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_calendar_context": rows}), [51])
    h = out[51]["holiday"]
    assert h["kind"] == "nearby"
    assert h["label"] == "Indep Day weekend"  # |offset|==1 -> suffix
    assert h["days_offset"] == -1


def test_holiday_nearby_no_weekend_suffix_when_offset_two():
    rows = [{
        "tevo_event_id": 52, "event_date": "2026-07-06",
        "holidays_today": [],
        "holidays_nearby": [
            {"name": "Far Holiday", "impact": "neutral", "precision": "city",
             "days_offset": 2, "date": "2026-07-04"},
        ],
        "school_breaks_active": [],
    }]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_calendar_context": rows}), [52])
    assert out[52]["holiday"]["label"] == "Far Holiday"  # no suffix


def test_holiday_school_break_summer_only():
    rows = [{
        "tevo_event_id": 53, "event_date": "2026-07-10",
        "holidays_today": [], "holidays_nearby": [],
        "school_breaks_active": [
            {"name": "Spring Break", "precision": "state"},   # filtered out
            {"name": "Summer Vacation", "precision": "city",
             "start_date": "2026-06-15", "end_date": "2026-09-01"},
        ],
    }]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_calendar_context": rows}), [53])
    h = out[53]["holiday"]
    assert h["kind"] == "school_break"
    assert h["label"] == "Summer Vacation"
    assert h["impact"] == "boost"


def test_holiday_school_break_none_summer_winter_stays_none():
    rows = [{
        "tevo_event_id": 54, "event_date": "2026-04-10",
        "holidays_today": [], "holidays_nearby": [],
        "school_breaks_active": [{"name": "Spring Break", "precision": "state"}],
    }]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_calendar_context": rows}), [54])
    assert out[54]["holiday"] is None


def test_holiday_skips_unknown_eid_and_no_context_stays_none():
    rows = [
        {"tevo_event_id": 999, "holidays_today": [{"name": "x"}]},  # unknown -> skip
        {"tevo_event_id": 55, "holidays_today": [], "holidays_nearby": [],
         "school_breaks_active": []},  # all empty -> best None -> stays None
    ]
    out = bulk_event_context(FakeSupabase(table_data={"v_event_calendar_context": rows}), [55])
    assert out[55]["holiday"] is None


def test_holiday_query_exception_degrades():
    out = bulk_event_context(
        FakeSupabase(raise_tables={"v_event_calendar_context"}), [50])
    assert out[50]["holiday"] is None


# ---------- Combined sanity ----------

def test_event_context_all_dimensions_none_data():
    # All views return None .data -> every dimension falls back to None cleanly.
    out = bulk_event_context(
        FakeSupabase(data_none_tables={
            "events", "performer_metadata", "v_rivalry_events", "v_mlb_game_series",
            "v_event_tournament_context", "v_event_weather_with_fallback",
            "v_event_calendar_context",
        }), [1])
    assert out[1] == {"rivalry": None, "mlb_series": None, "tournament": None,
                      "weather": None, "holiday": None, "playoff": None}
