"""Unit tests for the extracted core helpers (BR-CODE-1 helper pass).

These cover the functions moved out of app.py into core/ so the monolith
decomposition is regression-guarded at the unit level (no FastAPI / DB needed):
  - core.helpers.classify_playoff        (pure: event name -> badge dict | None)
  - core.helpers.listings_cadence_seconds / delta (pure)
  - core.broker_helpers.bulk_performer_assets (one in_() table read, fake db)
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.helpers import (  # noqa: E402
    classify_playoff, delta, listings_cadence_seconds,
    or_ilike_clause, is_speculative_event_name, classify_world_cup,
    clean_opt_url, tevo_runtime_to_http,
)
from core.broker_helpers import bulk_performer_assets, bulk_event_context  # noqa: E402


# ---------- classify_playoff ----------

def test_classify_playoff_specific_beats_generic():
    # "NBA Finals" is a specific phrase -> that exact label, kind=specific,
    # even though "Playoffs"-class generic markers could also be present.
    out = classify_playoff("New York Knicks vs Boston Celtics - NBA Finals (Game 7)")
    assert out == {"label": "NBA Finals", "kind": "specific"}


def test_classify_playoff_generic_marker():
    # A parenthetical "(Game 3" round marker with no specific phrase -> Playoffs.
    out = classify_playoff("Yankees vs Red Sox (Game 3, If Necessary)")
    assert out == {"label": "Playoffs", "kind": "generic"}


def test_classify_playoff_none_for_regular_season():
    assert classify_playoff("Knicks vs Celtics") is None
    assert classify_playoff("") is None
    assert classify_playoff(None) is None


def test_classify_playoff_whitespace_normalized():
    # Multi-space match collapses to single spaces in the label.
    out = classify_playoff("Final:  NHL   Stanley  Cup  Finals")
    assert out["kind"] == "specific"
    assert "  " not in out["label"]


# ---------- listings_cadence_seconds + delta (pure, re-cover post-move) ----------

def test_listings_cadence_buckets():
    assert listings_cadence_seconds(None) == 60 * 60 * 24
    assert listings_cadence_seconds("not-a-date") == 60 * 60  # parse fail -> 60m


def test_delta_directions():
    assert delta(150, 120)["dir"] == "up"
    assert delta(100, 120)["dir"] == "down"
    assert delta(100, 100) == {"abs": 0, "pct": 0, "dir": "flat"}
    assert delta(None, 5) is None


# ---------- bulk_performer_assets ----------

class _FakeChain:
    def __init__(self, data):
        self._data = data
    def select(self, *_a, **_k):
        return self
    def in_(self, *_a, **_k):
        return self
    def execute(self):
        return type("_R", (), {"data": self._data})()


class _FakeDB:
    def __init__(self, rows):
        self._rows = rows
        self.tables_touched = []
    def table(self, name):
        self.tables_touched.append(name)
        return _FakeChain(self._rows)


def test_bulk_performer_assets_empty_ids_skips_db():
    db = _FakeDB([{"performer_id": 1}])
    assert bulk_performer_assets(db, []) == {}
    # no query issued for an empty id list
    assert db.tables_touched == []


def test_bulk_performer_assets_maps_by_int_id():
    rows = [
        {"performer_id": 16303, "name": "Knicks", "logo_default_url": "x.png"},
        {"performer_id": "18", "name": "Celtics", "logo_default_url": "y.png"},
    ]
    db = _FakeDB(rows)
    out = bulk_performer_assets(db, [16303, 18])
    assert db.tables_touched == ["performer_metadata"]
    # keys coerced to int (handles string performer_id rows from the DB)
    assert set(out) == {16303, 18}
    assert out[16303]["name"] == "Knicks"
    assert out[18]["logo_default_url"] == "y.png"


# ---------- bulk_event_context ----------

class _CtxChain:
    """Per-table fluent chain: every filter returns self; execute() yields the
    table's preloaded rows. Supports the builder methods bulk_event_context uses."""
    def __init__(self, rows):
        self._rows = rows
    def select(self, *_a, **_k):
        return self
    def in_(self, *_a, **_k):
        return self
    def gte(self, *_a, **_k):
        return self
    def execute(self):
        return type("_R", (), {"data": self._rows})()


class _CtxDB:
    def __init__(self, by_table):
        self._by_table = by_table
    def table(self, name):
        return _CtxChain(self._by_table.get(name, []))


def test_bulk_event_context_empty_ids():
    assert bulk_event_context(_CtxDB({}), []) == {}


def test_bulk_event_context_shape_and_none_defaults():
    # Event present but no context rows in any view -> every dimension None.
    db = _CtxDB({"events": [{"id": 5, "name": "Knicks vs Celtics", "performer_ids": []}]})
    out = bulk_event_context(db, [5])
    assert set(out) == {5}
    assert out[5] == {
        "rivalry": None, "mlb_series": None, "tournament": None,
        "weather": None, "holiday": None, "playoff": None,
    }


def test_bulk_event_context_playoff_from_name_and_rivalry():
    db = _CtxDB({
        "events": [{"id": 7, "name": "Rangers vs Devils - NHL Stanley Cup Finals",
                    "performer_ids": []}],
        "v_rivalry_events": [{"tevo_event_id": 7, "rivalry_name": "Hudson River Rivalry",
                              "league": "NHL", "is_branded": True,
                              "rivalry_intensity": 9, "wikipedia_url": "http://x"}],
    })
    out = bulk_event_context(db, [7])
    # playoff resolved via the event-name regex (no series-tag performer)
    assert out[7]["playoff"] == {"label": "NHL Stanley Cup Finals", "kind": "specific"}
    # rivalry mapped from the view row
    assert out[7]["rivalry"]["name"] == "Hudson River Rivalry"
    assert out[7]["rivalry"]["is_branded"] is True


def test_bulk_event_context_playoff_series_tag_beats_name():
    # A series-tag performer ("NBA Finals") attaches the specific label even
    # when the event name itself carries no playoff phrase.
    db = _CtxDB({
        "events": [{"id": 9, "name": "Celtics vs Mavericks", "performer_ids": [101]}],
        "performer_metadata": [{"performer_id": 101, "name": "NBA Finals"}],
    })
    out = bulk_event_context(db, [9])
    assert out[9]["playoff"] == {"label": "NBA Finals", "kind": "specific"}


# ---------- or_ilike_clause ----------

def test_or_ilike_clause_plain_pattern_unquoted():
    assert or_ilike_clause("venue_name", "%Brooklyn%") == "venue_name.ilike.%Brooklyn%"


def test_or_ilike_clause_quotes_reserved_chars():
    # A comma in the pattern would otherwise split the PostgREST or-clause —
    # must be double-quoted (the "%, NY%" bug that returned 0 NYC movers).
    assert or_ilike_clause("venue_location", "%, NY%") == 'venue_location.ilike."%, NY%"'
    # parens are reserved too
    assert or_ilike_clause("name", "(If Necessary)") == 'name.ilike."(If Necessary)"'


def test_or_ilike_clause_doubles_embedded_quotes():
    assert or_ilike_clause("c", 'a"b') == 'c.ilike."a""b"'


# ---------- is_speculative_event_name ----------

def test_is_speculative_event_name():
    assert is_speculative_event_name("Knicks vs Celtics (If Necessary)") is True
    assert is_speculative_event_name("Yankees game CANCELLED") is True
    assert is_speculative_event_name("Knicks vs Celtics") is False
    assert is_speculative_event_name("Game 7 (Date TBD)") is False  # TBD != speculative
    assert is_speculative_event_name(None) is False


# ---------- classify_world_cup ----------

def test_classify_world_cup_performer_signal():
    assert classify_world_cup("Match 72", "World Cup Soccer") is True
    assert classify_world_cup("anything", "  World Cup Soccer ") is True


def test_classify_world_cup_name_regex_fallback():
    assert classify_world_cup("FIFA World Cup Soccer Final") is True
    assert classify_world_cup("World Cup Group Stage - Match 12") is True
    assert classify_world_cup("Knicks vs Celtics") is False
    assert classify_world_cup(None) is False


# ---------- clean_opt_url ----------

def test_clean_opt_url_coerces_sentinels():
    for sentinel in ("null", "None", "  NULL ", "", "  "):
        assert clean_opt_url(sentinel) is None
    assert clean_opt_url(None) is None


def test_clean_opt_url_passes_real_urls():
    assert clean_opt_url("https://x/chart.png") == "https://x/chart.png"


# ---------- tevo_runtime_to_http ----------

def test_tevo_runtime_to_http_status_mapping():
    mk = lambda e: tevo_runtime_to_http(e, not_found_detail="nf", failure_detail="fail")
    # 400/404 -> 404
    assert mk(RuntimeError("TEvo API returned 404")).status_code == 404
    assert mk(RuntimeError("TEvo API returned 400")).status_code == 404
    # 429/503 -> 503 (retryable)
    assert mk(RuntimeError("TEvo API returned 429")).status_code == 503
    assert mk(RuntimeError("TEvo API returned 503")).status_code == 503
    # other 5xx -> 502
    assert mk(RuntimeError("TEvo API returned 500")).status_code == 502
    # no status in message (connection/DNS) -> 502
    assert mk(RuntimeError("TEvo API returned no response")).status_code == 502


def test_tevo_runtime_to_http_carries_details():
    nf = tevo_runtime_to_http(RuntimeError("404"), not_found_detail="gone", failure_detail="oops")
    assert nf.detail == "gone"
    fail = tevo_runtime_to_http(RuntimeError("500"), not_found_detail="gone", failure_detail="oops")
    assert fail.detail == "oops"


# ---------- csv_list + normalize_filters ----------

def test_csv_list_trims_and_drops_empties():
    from core.helpers import csv_list
    assert csv_list("a, b ,,c") == ["a", "b", "c"]
    assert csv_list(None) == []
    assert csv_list("") == []


def test_normalize_filters_canonical_shape():
    from core.helpers import normalize_filters
    out = normalize_filters({
        "section": "100, 200",
        "zones": ["Lower", " ", "Club"],
        "min_price": "50", "max_price": "", "min_qty": "2",
    })
    assert out == {
        "section": ["100", "200"],
        "zones": ["Lower", "Club"],
        "min_price": 50.0, "max_price": None, "min_qty": 2,
    }


def test_normalize_filters_empty_and_bad_values():
    from core.helpers import normalize_filters
    out = normalize_filters(None)
    assert out == {"section": [], "zones": [], "min_price": None,
                   "max_price": None, "min_qty": None}
    # non-numeric price / qty coerce to None, not raise
    bad = normalize_filters({"min_price": "abc", "min_qty": "x"})
    assert bad["min_price"] is None and bad["min_qty"] is None
