"""Unit tests for core.search (BR-CODE-1 extraction of the SQL-only search path).

No live DB / FastAPI — drives search_sql_only against a tiny programmable fake
that records the tables it touched and returns preloaded rows per table.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.search import _escape_ilike, search_sql_only  # noqa: E402


# ---------- _escape_ilike ----------

def test_escape_ilike_escapes_wildcards():
    # %, _ and backslash are PostgREST ILIKE wildcards → must be backslash-escaped
    # so a user-supplied "%" can't become a match-everything pattern.
    assert _escape_ilike("50% off") == "50\\% off"
    assert _escape_ilike("a_b") == "a\\_b"
    assert _escape_ilike("c\\d") == "c\\\\d"


def test_escape_ilike_plain_passthrough():
    assert _escape_ilike("Knicks") == "Knicks"


# ---------- search_sql_only ----------

class _Chain:
    def __init__(self, rows):
        self._rows = rows
    # every builder method returns self
    def __getattr__(self, _name):
        def _m(*_a, **_k):
            return self
        return _m
    def execute(self):
        return type("_R", (), {"data": self._rows})()


class _DB:
    def __init__(self, by_table):
        self._by_table = by_table
        self.touched: list[str] = []
    def table(self, name):
        self.touched.append(name)
        return _Chain(self._by_table.get(name, []))


def test_search_sql_only_blank_query_short_circuits():
    db = _DB({})
    out = search_sql_only(db, "  ,.()  ", 10)  # all stripped → empty
    assert out == {"events": [], "performers": [], "venues": [], "source": "sql"}
    assert db.touched == []  # never hit the DB


def test_search_sql_only_shape_and_owned_bias():
    # Two events match; only the second is owned. Owned must sort first even
    # though the unowned one is sooner.
    db = _DB({
        "events": [
            {"id": 1, "name": "Reno Aces", "occurs_at_local": "2026-05-01",
             "venue_name": "Greater Nevada", "venue_location": "Reno, NV"},
            {"id": 2, "name": "Las Vegas Aces", "occurs_at_local": "2026-05-17",
             "venue_name": "Michelob Arena", "venue_location": "Las Vegas, NV"},
        ],
        "latest_event_metrics": [
            {"event_id": 2, "owned_tickets_count": 12, "retail_min": 95},
        ],
        "event_lifecycle": [
            {"event_id": 1, "is_active": True},
            {"event_id": 2, "is_active": True},
        ],
        "performer_metadata": [
            {"performer_id": 50, "name": "Las Vegas Aces", "espn_league": "WNBA"},
        ],
    })
    out = search_sql_only(db, "aces", 10)
    assert out["source"] == "sql"
    # owned (id 2) sorts ahead of unowned (id 1)
    assert [e["id"] for e in out["events"]] == [2, 1]
    assert out["events"][0]["we_own"] is True
    assert out["events"][0]["from_price"] == 95
    assert out["events"][1]["we_own"] is False
    assert out["performers"][0]["league"] == "WNBA"


def test_search_sql_only_drops_speculative_and_inactive():
    db = _DB({
        "events": [
            {"id": 1, "name": "Knicks (If Necessary)", "occurs_at_local": "2026-05-01"},
            {"id": 2, "name": "Knicks vs Celtics", "occurs_at_local": "2026-05-02"},
            {"id": 3, "name": "Celtics game", "occurs_at_local": "2026-05-03"},
        ],
        "latest_event_metrics": [],
        "event_lifecycle": [{"event_id": 3, "is_active": False}],  # 3 is a ghost
    })
    out = search_sql_only(db, "knicks", 10)
    ids = [e["id"] for e in out["events"]]
    assert 1 not in ids   # speculative "(If Necessary)" dropped
    assert 3 not in ids   # inactive/ghost dropped
    assert ids == [2]
