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
        self.rpcs, self.queries, self.tables = [], [], []

    def rpc(self, name, args):
        self.rpcs.append((name, args))
        if name == "mcp_verify_key":
            ok = args["p_key_hash"] == hash_key(KEY)
            return _Data([{"id": 7, "label": "crm", "tier": "external"}] if ok else [])
        if name == "sub_finder_access":
            return _Data({"find": self.find})
        return _Data(None)

    def table(self, name):
        assert name in (mlb_feed.VIEW, mlb_feed.EVENT_VIEW, mlb_feed.CHANGES_VIEW)
        self.tables.append(name)
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
    assert r.json() == {"count": 1, "offset": 0, "next_offset": None,
                        "games": [{**ROW, **dict.fromkeys(mlb_feed.MARKET_IDS)}]}
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
    assert lines[0].split(",") == list(mlb_feed.COLUMNS + mlb_feed.MARKET_IDS)
    assert "https://www.ticketmaster.com/event/0D00" in lines[1] and len(lines) == 2


def test_database_error_is_a_502_without_detail():
    r = _client(FakeDB(table_exc=RuntimeError("relation secret does not exist"))).get(URL, headers=H)
    assert r.status_code == 502 and "secret" not in r.text and r.json()["detail"] == "RuntimeError"


def test_csv_writes_promotions_as_json():
    row = dict(ROW, promotions=[{"type": "Giveaway", "name": "Bobblehead"}])
    r = _client(FakeDB(rows=[row])).get(URL + "?format=csv", headers=H)
    assert '"[{""type"": ""Giveaway"", ""name"": ""Bobblehead""}]"' in r.text


# ---------- /mlb/events ----------

EV_URL = "/api/v1/subs/mlb/events"
EV = {"mlb_schedule_id": 9, "title": "Monster Jam", "event_date": "2027-01-16", "venue_name": "Angel Stadium",
      "tevo_event_id": 7777}


def test_events_need_a_key_that_may_find():
    assert _client(FakeDB(rows=[EV])).get(EV_URL).status_code == 401
    r = _client(FakeDB(rows=[EV], find=False)).get(EV_URL, headers=H)
    assert r.status_code == 403


def test_events_default_lists_every_level():
    db = FakeDB(rows=[EV, EV])
    body = _client(db).get(EV_URL + "?limit=2", headers=H).json()
    row = {**EV, **dict.fromkeys(mlb_feed.EVENT_MARKET_IDS)}
    assert body == {"count": 2, "offset": 0, "next_offset": 2, "events": [row, row]}
    assert db.tables == [mlb_feed.EVENT_VIEW]
    q = db.queries[0].calls
    assert not any(c[:2] == ("in_", "level") for c in q) and ("order", "event_date") in q
    assert ("mcp_count_call", {"p_key_id": 7, "p_tool": "subs.mlb_events"}) in db.rpcs


def test_events_filters():
    db = FakeDB(rows=[])
    url = EV_URL + "?team=laa&level=mlb&date_from=2027-01-01&date_to=2027-02-01&since=2026-11-17T00:00:00Z&mapped=true"
    assert _client(db).get(url, headers=H).json()["next_offset"] is None
    q = db.queries[0].calls
    assert ("eq", "home_abbrev", "LAA") in q and ("in_", "level", ["mlb"]) in q
    assert ("gte", "event_date", "2027-01-01") in q and ("lte", "event_date", "2027-02-01") in q
    assert ("gte", "changed_at", "2026-11-17T00:00:00+00:00") in q and ("is_", "tevo_event_id", "null") in q
    db2 = FakeDB(rows=[])
    _client(db2).get(EV_URL + "?team=108", headers=H)
    assert ("eq", "home_team_id", "108") in db2.queries[0].calls


def test_events_csv_bad_input_and_db_error():
    r = _client(FakeDB(rows=[EV])).get(EV_URL + "?format=csv", headers=H)
    assert r.text.splitlines()[0].split(",") == list(mlb_feed.EVENT_COLUMNS + mlb_feed.EVENT_MARKET_IDS)
    for qs in ("?team=N-Y", "?level=rookie", "?format=xml", "?limit=0", "?date_to=2027-02-30", "?mapped=perhaps"):
        assert _client(FakeDB(rows=[EV])).get(EV_URL + qs, headers=H).status_code == 422
    r = _client(FakeDB(table_exc=RuntimeError("secret"))).get(EV_URL, headers=H)
    assert r.status_code == 502 and "secret" not in r.text


# ---------- /mlb/changes ----------

CH_URL = "/api/v1/subs/mlb/changes"
CH = {"change_id": 41, "entity": "game", "kind": "link_live", "new_value": "https://www.ticketmaster.com/event/0B",
      "notable": True}


def test_changes_need_a_key_that_may_find():
    assert _client(FakeDB(rows=[CH])).get(CH_URL).status_code == 401
    assert _client(FakeDB(rows=[CH], find=False)).get(CH_URL, headers=H).status_code == 403


def test_changes_page_by_change_id():
    db = FakeDB(rows=[CH, dict(CH, change_id=42)])
    body = _client(db).get(CH_URL + "?after_id=40&limit=2", headers=H).json()
    assert body["count"] == 2 and body["next_after_id"] == 42
    q = db.queries[0].calls
    assert ("gt", "change_id", 40) in q and ("order", "change_id") in q and ("limit", 2) in q
    assert db.tables == [mlb_feed.CHANGES_VIEW]
    assert _client(FakeDB(rows=[CH])).get(CH_URL, headers=H).json()["next_after_id"] is None


def test_changes_filters():
    db = FakeDB(rows=[])
    url = (CH_URL + "?since=2026-11-17T00:00:00Z&kind=link_live,%20time_changed&entity=game&notable=false"
           "&team=147&level=milb")
    assert _client(db).get(url, headers=H).status_code == 200
    q = db.queries[0].calls
    assert ("gte", "detected_at", "2026-11-17T00:00:00+00:00") in q
    assert ("in_", "kind", ["link_live", "time_changed"]) in q and ("eq", "entity", "game") in q
    assert ("eq", "notable", False) in q and ("eq", "home_team_id", "147") in q
    assert ("in_", "level", mlb_feed.LEVELS["milb"]) in q
    db2 = FakeDB(rows=[])
    _client(db2).get(CH_URL + "?team=nyy", headers=H)
    assert ("eq", "home_abbrev", "NYY") in db2.queries[0].calls


@pytest.mark.parametrize("qs", ["?after_id=-1", "?after_id=x", "?kind=exploded", "?entity=player", "?notable=maybe",
                                "?team=1-2", "?level=x", "?format=pdf", "?limit=99999", "?since=soon"])
def test_changes_bad_parameters_are_422(qs):
    db = FakeDB(rows=[CH])
    r = _client(db).get(CH_URL + qs, headers=H)
    assert r.status_code == 422 and db.queries == []


def test_changes_csv_and_db_error():
    r = _client(FakeDB(rows=[CH])).get(CH_URL + "?format=csv", headers=H)
    assert r.headers["content-type"].startswith("text/csv") and "link_live" in r.text
    r = _client(FakeDB(table_exc=RuntimeError("secret"))).get(CH_URL, headers=H)
    assert r.status_code == 502 and "secret" not in r.text


def test_provenue_events_is_the_schedule_pinned_to_provenue_links():
    # /provenue/events lists what ProVenue sells, as /axs/events lists what AXS sells (operator 2026-11-28: "mimic axs
    # calls for tickets.dev sg/provenue sources"; mig 20261128100000): the schedule by its own ticket link, every level
    assert _client(FakeDB(rows=[])).get("/api/v1/subs/provenue/events").status_code == 401
    db = FakeDB(rows=[])
    r = _client(db).get("/api/v1/subs/provenue/events", headers=H)
    assert r.status_code == 200 and r.json()["count"] == 0
    calls = db.queries[0].calls
    assert ("ilike", "ticket_url", "https://m__.tickets.com%") in calls, calls
    assert not any(c[0] == "in_" and c[1] == "level" for c in calls), calls
    db = FakeDB(rows=[])
    _client(db).get("/api/v1/subs/provenue/events", headers=H, params={"level": "mlb"})
    assert ("in_", "level", ["mlb"]) in db.queries[0].calls
    # the plain schedule is not pinned, and stays MLB by default
    db = FakeDB(rows=[])
    _client(db).get(URL, headers=H)
    assert not any(c[0] == "ilike" for c in db.queries[0].calls) and ("in_", "level", ["mlb"]) in db.queries[0].calls
