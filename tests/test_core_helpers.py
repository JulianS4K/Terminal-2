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

from core.helpers import classify_playoff, delta, listings_cadence_seconds  # noqa: E402
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
