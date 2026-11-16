"""MLB schedule feed — GET /api/v1/subs/mlb/schedule (routers/subs_api.py → routers/mlb_feed.py)."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
testclient = pytest.importorskip("fastapi.testclient")

from fastapi import FastAPI  # noqa: E402

from routers import mlb_feed  # noqa: E402
from routers import subs_api as s  # noqa: E402
from routers.mcp_api import hash_key  # noqa: E402

KEY = "crm-key"
H = {"x-api-key": KEY}
URL = "/api/v1/subs/mlb/schedule"
ROW = {"mlb_schedule_id": 1, "game_date": "2027-03-25", "home_abbrev": "NYY", "away_abbrev": "TOR",
       "ticket_url": "https://www.ticketmaster.com/event/0D00", "tevo_event_id": 3469396,
       "aq_short_event_id": "SYS-1", "terminal_path": "/terminal/event.html?event=3469396"}


class _Data:
    def __init__(self, data=None, exc=None):
        self.data, self._exc = data, exc

    def execute(self):
        if self._exc:
            raise self._exc
        return self


class _Query:
    """Records every builder call; `not_` negates the next call like postgrest-py."""

    def __init__(self, db):
        self.db, self.calls = db, []

    @property
    def not_(self):
        self.calls.append(("not",))
        return self

    def __getattr__(self, name):
        def call(*args):
            self.calls.append((name, *args))
            return self
        return call

    def execute(self):
        if self.db.table_exc:
            raise self.db.table_exc
        return _Data(self.db.rows)


class FakeDB:
    def __init__(self, rows=None, find=True, table_exc=None):
        self.rows, self.find, self.table_exc = rows, find, table_exc
        self.rpcs, self.queries = [], []

    def rpc(self, name, args):
        self.rpcs.append((name, args))
        if name == "mcp_verify_key":
            ok = args["p_key_hash"] == hash_key(KEY)
            return _Data([{"id": 7, "label": "crm", "tier": "external"}] if ok else [])
        if name == "sub_finder_access":
            return _Data({"find": self.find})
        return _Data(None)

    def table(self, name):
        assert name == mlb_feed.VIEW
        q = _Query(self)
        self.queries.append(q)
        return q


def _client(db):
    app = FastAPI()
    app.include_router(s.make_router(lambda: db))
    return testclient.TestClient(app)


# ---------- access ----------

def test_needs_a_sub_finder_key_that_may_find():
    db = FakeDB(rows=[ROW])
    assert _client(db).get(URL).status_code == 401
    assert _client(db).get(URL, headers={"x-api-key": "wrong"}).status_code == 401
    r = _client(FakeDB(rows=[ROW], find=False)).get(URL, headers=H)
    assert r.status_code == 403 and r.json()["error"] == "forbidden"
    assert db.queries == []


def test_returns_games_and_stamps_the_call():
    db = FakeDB(rows=[ROW])
    r = _client(db).get(URL, headers=H)
    assert r.status_code == 200
    assert r.json() == {"count": 1, "offset": 0, "next_offset": None, "games": [ROW]}
    assert ("mcp_count_call", {"p_key_id": 7, "p_tool": "subs.mlb_schedule"}) in db.rpcs
    q = db.queries[0].calls
    assert q[0][0] == "select" and "ticket_url" in q[0][1] and "aq_short_event_id" in q[0][1]
    assert ("order", "game_date") in q and ("range", 0, mlb_feed.DEFAULT_LIMIT - 1) in q
    assert ("in_", "level", ["mlb"]) in q          # MLB only unless a level is asked for


# ---------- filters ----------

def test_filters_become_view_filters():
    db = FakeDB(rows=[ROW])
    r = _client(db).get(URL + "?team=nyy&season=2027&date_from=2027-04-01&date_to=2027-04-30"
                              "&since=2026-11-16T00:00:00Z&with_tickets=true&mapped=1&type=postseason", headers=H)
    assert r.status_code == 200
    q = db.queries[0].calls
    assert ("or_", "home_abbrev.eq.NYY,away_abbrev.eq.NYY") in q
    assert ("eq", "season", 2027) in q
    assert ("gte", "game_date", "2027-04-01") in q and ("lte", "game_date", "2027-04-30") in q
    assert ("gte", "changed_at", "2026-11-16T00:00:00+00:00") in q
    assert q.count(("not",)) == 2
    assert ("is_", "ticket_url", "null") in q and ("is_", "tevo_event_id", "null") in q
    assert ("in_", "game_type", mlb_feed.TYPES["postseason"]) in q


def test_home_only_by_team_id_and_false_flags_add_nothing():
    db = FakeDB(rows=[])
    assert _client(db).get(URL + "?team=147&home_only=true&with_tickets=false&mapped=", headers=H).status_code == 200
    q = db.queries[0].calls
    assert ("eq", "home_team_id", "147") in q
    assert ("not",) not in q and not any(c[0] == "or_" for c in q)


def test_paging_reports_the_next_offset():
    db = FakeDB(rows=[ROW, ROW])
    body = _client(db).get(URL + "?limit=2&offset=4", headers=H).json()
    assert body["next_offset"] == 6 and body["offset"] == 4
    assert ("range", 4, 5) in db.queries[0].calls


def test_no_rows_is_an_empty_list():
    assert _client(FakeDB(rows=None)).get(URL, headers=H).json()["games"] == []


@pytest.mark.parametrize("qs", ["?team=N-Y", "?type=playoffs", "?format=xml", "?limit=0", "?limit=6000",
                                "?offset=-1", "?date_from=2027-13-01", "?since=yesterday",
                                "?with_tickets=maybe", "?season=twenty", "?level=rookie"])
def test_bad_parameters_are_422(qs):
    db = FakeDB(rows=[ROW])
    r = _client(db).get(URL + qs, headers=H)
    assert r.status_code == 422 and r.json()["error"] == "invalid"
    assert db.queries == []


@pytest.mark.parametrize("level,want", [("milb", ["aaa", "aa", "high_a", "single_a"]), ("AAA", ["aaa"]),
                                        ("single_a", ["single_a"]), ("mlb", ["mlb"])])
def test_level_picks_the_leagues(level, want):
    db = FakeDB(rows=[ROW])
    assert _client(db).get(URL + f"?level={level}&team=COL", headers=H).status_code == 200
    q = db.queries[0].calls
    assert [c for c in q if c[:2] == ("in_", "level")] == [("in_", "level", want)]
    assert ("or_", "home_abbrev.eq.COL,away_abbrev.eq.COL") in q


def test_level_all_adds_no_level_filter():
    db = FakeDB(rows=[ROW])
    assert _client(db).get(URL + "?level=all", headers=H).status_code == 200
    assert not any(c[:2] == ("in_", "level") for c in db.queries[0].calls)


# ---------- output ----------

def test_csv_has_every_column():
    r = _client(FakeDB(rows=[ROW])).get(URL + "?format=csv", headers=H)
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/csv")
    lines = r.text.strip().splitlines()
    assert lines[0].split(",") == list(mlb_feed.COLUMNS)
    assert "https://www.ticketmaster.com/event/0D00" in lines[1] and len(lines) == 2


def test_database_error_is_a_502_without_detail():
    r = _client(FakeDB(table_exc=RuntimeError("relation secret does not exist"))).get(URL, headers=H)
    assert r.status_code == 502 and "secret" not in r.text and r.json()["detail"] == "RuntimeError"
