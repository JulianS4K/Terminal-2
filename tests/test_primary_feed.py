"""GET /api/v1/subs/axs/events and /seatgeek/events (routers/primary_feed.py): AXS's events and the
events SeatGeek tickets as the primary seller (operator 2026-11-22: "push out axs and SeatGeek
primary in API")."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
testclient = pytest.importorskip("fastapi.testclient")

from fastapi import FastAPI  # noqa: E402

from routers import primary_feed as pf  # noqa: E402
from routers import subs_api as s  # noqa: E402
from routers.mcp_api import hash_key  # noqa: E402

KEY = "crm-key"
H = {"x-api-key": KEY}
AXS, SG = "/api/v1/subs/axs/events", "/api/v1/subs/seatgeek/events"
AXS_ROW = {"axs_event_id": 1483914, "name": "Tape B", "performers": ["Tape B"], "event_date": "2026-11-21",
           "axs_primary": True, "tevo_event_id": 3412441}
SG_ROW = {"sg_event_id": 18116899, "name": "Tennessee Titans at Dallas Cowboys", "event_date": "2026-11-22",
          "performers": ["Dallas Cowboys", "Tennessee Titans"], "seatgeek_primary": True, "tevo_event_id": 3285875}


class _Data:
    def __init__(self, data=None):
        self.data = data

    def execute(self):
        return self


class _Query:
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
        self.queries, self.tables = [], []

    def rpc(self, name, args):
        if name == "mcp_verify_key":
            ok = args["p_key_hash"] == hash_key(KEY)
            return _Data([{"id": 7, "label": "crm", "tier": "external"}] if ok else [])
        if name == "sub_finder_access":
            return _Data({"find": self.find})
        return _Data(None)

    def table(self, name):
        assert name in (pf.AXS_VIEW, pf.SEATGEEK_VIEW)
        self.tables.append(name)
        q = _Query(self)
        self.queries.append(q)
        return q


def _client(db):
    app = FastAPI()
    app.include_router(s.make_router(lambda: db))
    return testclient.TestClient(app)


def test_both_feeds_need_a_key_that_may_find_subs():
    for url in (AXS, SG):
        db = FakeDB(rows=[AXS_ROW])
        assert _client(db).get(url).status_code == 401
        assert _client(FakeDB(rows=[AXS_ROW], find=False)).get(url, headers=H).status_code == 403
        assert db.tables == []


def test_axs_serves_the_events_axs_sells_unless_asked_otherwise():
    db = FakeDB(rows=[AXS_ROW])
    r = _client(db).get(AXS, headers=H)
    assert r.status_code == 200 and r.json() == {"count": 1, "offset": 0, "next_offset": None,
                                                 "events": [{**AXS_ROW, **dict.fromkeys(pf.AXS_MARKET_IDS)}]}
    calls = db.queries[0].calls
    assert db.tables == [pf.AXS_VIEW] and calls[0] == ("select", ",".join(pf.AXS_COLUMNS))
    assert ("eq", "axs_primary", True) in calls and ("order", "axs_event_id") in calls and ("range", 0, 999) in calls
    assert not any(c[0] in ("gte", "lte", "ilike", "is_") for c in calls)
    db = FakeDB(rows=[AXS_ROW])
    _client(db).get(AXS, headers=H, params={"primary": "false"})
    assert ("eq", "axs_primary", False) in db.queries[0].calls            # listed on AXS, sold by someone else
    assert pf.SEARCH_COLUMN not in pf.AXS_COLUMNS + pf.SEATGEEK_COLUMNS    # filtered on, not returned


def test_filters_reach_the_view():
    db = FakeDB(rows=[AXS_ROW, AXS_ROW])
    r = _client(db).get(AXS, headers=H, params={
        "date_from": "2026-11-22", "date_to": "2026-12-31", "state": "mn", "mapped": "true",
        "since": "2026-11-22T00:00:00Z", "q": "Tape Minneapolis", "limit": 2, "offset": 4})
    assert r.status_code == 200 and r.json()["next_offset"] == 6
    calls = db.queries[0].calls
    for want in (("gte", "event_date", "2026-11-22"), ("lte", "event_date", "2026-12-31"), ("eq", "venue_state", "MN"),
                 ("gte", "changed_at", "2026-11-22T00:00:00+00:00"), ("ilike", pf.SEARCH_COLUMN, "%tape%"),
                 ("ilike", pf.SEARCH_COLUMN, "%minneapolis%"), ("range", 4, 5)):
        assert want in calls
    assert calls[calls.index(("not",)) + 1] == ("is_", "tevo_event_id", "null")      # mapped=true
    db = FakeDB(rows=[])
    _client(db).get(SG, headers=H, params={"mapped": "false"})
    assert ("is_", "tevo_event_id", "null") in db.queries[0].calls and ("not",) not in db.queries[0].calls


def test_seatgeek_serves_its_primary_events_and_csv():
    db = FakeDB(rows=[SG_ROW])
    r = _client(db).get(SG, headers=H)
    assert r.status_code == 200 and r.json()["events"] == [{**SG_ROW, **dict.fromkeys(pf.SEATGEEK_MARKET_IDS)}]
    calls = db.queries[0].calls
    assert db.tables == [pf.SEATGEEK_VIEW] and calls[0] == ("select", ",".join(pf.SEATGEEK_COLUMNS))
    assert ("order", "sg_event_id") in calls and not any(c[:2] == ("eq", "axs_primary") for c in calls)
    r = _client(FakeDB(rows=[SG_ROW])).get(SG, headers=H, params={"format": "csv"})
    assert r.headers["content-type"].startswith("text/csv") and "seatgeek_events.csv" in r.headers["content-disposition"]
    assert r.text.split("\\r\\n")[0].startswith("sg_event_id,name,category") and '[""Dallas Cowboys""' in r.text
    r = _client(FakeDB(rows=[AXS_ROW])).get(AXS, headers=H, params={"format": "csv"})
    assert "axs_events.csv" in r.headers["content-disposition"]


def test_a_bad_parameter_is_refused_and_a_failed_read_is_reported():
    for url in (AXS, SG):
        for bad in ({"state": "NewYork"}, {"format": "xml"}, {"limit": "0"}, {"date_from": "tomorrow"},
                    {"since": "yesterday"}, {"mapped": "maybe"}, {"q": "%"}):
            db = FakeDB(rows=[AXS_ROW])
            r = _client(db).get(url, headers=H, params=bad)
            assert r.status_code == 422 and r.json()["error"] == "invalid" and db.tables == []
        r = _client(FakeDB(table_exc=RuntimeError("boom"))).get(url, headers=H)
        assert r.status_code == 502 and r.json() == {"error": "upstream_error", "detail": "RuntimeError"}
    db = FakeDB(rows=[AXS_ROW])
    assert _client(db).get(AXS, headers=H, params={"primary": "maybe"}).status_code == 422 and db.tables == []
