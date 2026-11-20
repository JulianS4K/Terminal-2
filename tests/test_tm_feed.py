"""GET /api/v1/subs/tm/events and /tm/markets (routers/tm_feed.py): Ticketmaster's catalogue and
the sites each mapped event pairs to, served inside the sub finder API (operator 2026-11-18)."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
testclient = pytest.importorskip("fastapi.testclient")

from fastapi import FastAPI  # noqa: E402

from routers import subs_api as s  # noqa: E402
from routers import tm_feed  # noqa: E402
from routers.mcp_api import hash_key  # noqa: E402

KEY = "crm-key"
H = {"x-api-key": KEY}
EVENTS, MARKETS = "/api/v1/subs/tm/events", "/api/v1/subs/tm/markets"
EVENT = {"tm_event_id": "G5diZ_o6tFFbU", "name": "Atlanta Hawks vs. Charlotte Hornets", "event_date": "2026-11-20",
         "status": "onsale", "segment": "Sports", "attraction_names": ["Atlanta Hawks", "Charlotte Hornets"],
         "presales": [{"name": "Fan presale"}], "tevo_event_id": 3464939, "is_product": False}
MARKET = {"tm_event_id": "G5diZ_o6tFFbU", "tevo_event_id": 3464939, "seatgeek_event_id": 18380001,
          "vivid_event_id": 7306000, "tickpick_event_id": 8141000, "sites_paired": 3}


class _Data:
    def __init__(self, data=None):
        self.data = data

    def execute(self):
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
        self.queries, self.tables = [], []

    def rpc(self, name, args):
        if name == "mcp_verify_key":
            ok = args["p_key_hash"] == hash_key(KEY)
            return _Data([{"id": 7, "label": "crm", "tier": "external"}] if ok else [])
        if name == "sub_finder_access":
            return _Data({"find": self.find})
        return _Data(None)

    def table(self, name):
        assert name in (tm_feed.EVENT_VIEW, tm_feed.MARKET_VIEW)
        self.tables.append(name)
        q = _Query(self)
        self.queries.append(q)
        return q


def _client(db):
    app = FastAPI()
    app.include_router(s.make_router(lambda: db))
    return testclient.TestClient(app)


def test_both_feeds_need_a_key_that_may_find_subs():
    for url in (EVENTS, MARKETS):
        db = FakeDB(rows=[EVENT])
        assert _client(db).get(url).status_code == 401
        assert _client(FakeDB(rows=[EVENT], find=False)).get(url, headers=H).status_code == 403
        assert db.tables == []                                     # nothing was read


def test_events_default_is_real_events_only_and_pages():
    db = FakeDB(rows=[EVENT])
    r = _client(db).get(EVENTS, headers=H)
    assert r.status_code == 200
    assert r.json() == {"count": 1, "offset": 0, "next_offset": None, "events": [EVENT]}
    calls = db.queries[0].calls
    # every column by default: the core ones, then everything else Ticketmaster returns
    assert db.tables == [tm_feed.EVENT_VIEW]
    assert calls[0] == ("select", ",".join(tm_feed.EVENT_COLUMNS + tm_feed.DETAIL_COLUMNS))
    assert not any(c[:2] == ("eq", "safetix") for c in calls)      # SafeTix was not asked about
    assert ("eq", "is_product", False) in calls                    # parking and add-ons are left out
    assert ("range", 0, 999) in calls and ("order", "event_date") in calls and ("order", "tm_event_id") in calls
    assert not any(c[0] in ("gte", "lte", "ilike", "is_") for c in calls)   # no filter was asked for


def test_events_filters_reach_the_view():
    db = FakeDB(rows=[EVENT, EVENT])
    r = _client(db).get(EVENTS, headers=H, params={
        "date_from": "2026-11-20", "date_to": "2026-11-30", "segment": "Arts & Theatre", "state": "ny",
        "status": "ONSALE", "since": "2026-11-18T00:00:00Z", "mapped": "true", "products": "true",
        "limit": 2, "offset": 4})
    assert r.status_code == 200 and r.json()["next_offset"] == 6   # a full page: there may be more
    calls = db.queries[0].calls
    for want in (("gte", "event_date", "2026-11-20"), ("lte", "event_date", "2026-11-30"),
                 ("ilike", "segment", "Arts & Theatre"), ("eq", "venue_state", "NY"), ("eq", "status", "onsale"),
                 ("gte", "changed_at", "2026-11-18T00:00:00+00:00"), ("range", 4, 5)):
        assert want in calls
    i = calls.index(("not",))
    assert calls[i + 1] == ("is_", "tevo_event_id", "null")        # mapped=true: an EVO event is set
    assert ("eq", "is_product", False) not in calls                # products=true: nothing is left out
    db = FakeDB(rows=[])
    _client(db).get(EVENTS, headers=H, params={"mapped": "false"})
    calls = db.queries[0].calls
    assert ("is_", "tevo_event_id", "null") in calls and ("not",) not in calls


def test_events_detail_and_buy_limit_columns():
    """Operator 2026-11-18: "add and push all of them out including buy limits"."""
    for col in ("ticket_limit_numbers", "ticket_limit_count", "safetix", "all_in_pricing", "public_onsale_end",
                "doors_utc", "attractions", "products", "venue_latitude", "venue_box_office"):
        assert col in tm_feed.DETAIL_COLUMNS
    assert "ticket_limit" in tm_feed.EVENT_COLUMNS                 # Ticketmaster's own sentence stays core
    assert not set(tm_feed.EVENT_COLUMNS) & set(tm_feed.DETAIL_COLUMNS)
    db = FakeDB(rows=[EVENT])
    assert _client(db).get(EVENTS, headers=H, params={"detail": "false", "safetix": "true"}).status_code == 200
    calls = db.queries[0].calls
    assert calls[0] == ("select", ",".join(tm_feed.EVENT_COLUMNS)) and ("eq", "safetix", True) in calls
    db = FakeDB(rows=[EVENT])
    _client(db).get(EVENTS, headers=H, params={"detail": "true", "safetix": "false"})
    calls = db.queries[0].calls
    assert calls[0] == ("select", ",".join(tm_feed.EVENT_COLUMNS + tm_feed.DETAIL_COLUMNS))
    assert ("eq", "safetix", False) in calls
    # the CSV header follows the columns asked for
    full = _client(FakeDB(rows=[EVENT])).get(EVENTS, headers=H, params={"format": "csv"}).text.split("\r\n")[0]
    slim = _client(FakeDB(rows=[EVENT])).get(EVENTS, headers=H, params={"format": "csv", "detail": "false"}).text.split("\r\n")[0]
    assert full.endswith("venue_ada") and slim.endswith("changed_at") and "ticket_limit_count" in full


def test_markets_lists_the_paired_sites_and_filters_by_site():
    db = FakeDB(rows=[MARKET])
    r = _client(db).get(MARKETS, headers=H)
    assert r.status_code == 200 and r.json()["events"] == [MARKET]
    assert db.tables == [tm_feed.MARKET_VIEW]
    assert db.queries[0].calls[0] == ("select", ",".join(tm_feed.MARKET_COLUMNS)) and ("not",) not in db.queries[0].calls
    for site, col in tm_feed.SITES.items():
        db = FakeDB(rows=[MARKET])
        assert _client(db).get(MARKETS, headers=H, params={"site": site.upper(), "state": "GA"}).status_code == 200
        calls = db.queries[0].calls
        assert calls[calls.index(("not",)) + 1] == ("is_", col, "null") and ("eq", "venue_state", "GA") in calls
    assert set(tm_feed.SITES.values()) <= set(tm_feed.MARKET_COLUMNS)


def test_csv_writes_lists_and_objects_as_json_text():
    r = _client(FakeDB(rows=[EVENT])).get(EVENTS, headers=H, params={"format": "csv"})
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/csv")
    assert "tm_events.csv" in r.headers["content-disposition"]
    head, row = r.text.strip().split("\r\n")
    assert head.split(",")[0] == "tm_event_id" and "G5diZ_o6tFFbU" in row and '[""Atlanta Hawks""' in row
    r = _client(FakeDB(rows=[MARKET])).get(MARKETS, headers=H, params={"format": "csv"})
    assert "tm_markets.csv" in r.headers["content-disposition"] and "18380001" in r.text


def test_bad_parameters_answer_422_and_read_nothing():
    for url, params in ((EVENTS, {"segment": "Sports;drop"}), (EVENTS, {"state": "New York"}),
                        (EVENTS, {"status": "sold"}), (EVENTS, {"format": "xml"}), (EVENTS, {"limit": 0}),
                        (EVENTS, {"limit": 5001}), (EVENTS, {"offset": -1}), (EVENTS, {"date_from": "soon"}),
                        (EVENTS, {"since": "yesterday"}), (EVENTS, {"mapped": "maybe"}),
                        (EVENTS, {"products": "some"}), (EVENTS, {"safetix": "rotating"}),
                        (EVENTS, {"detail": "lots"}), (MARKETS, {"site": "ticketmaster"}),
                        (MARKETS, {"status": "sold"})):
        db = FakeDB(rows=[EVENT])
        r = _client(db).get(url, headers=H, params=params)
        assert r.status_code == 422 and r.json()["error"] == "invalid", (url, params)
        assert db.tables == []


def test_a_failed_read_answers_502_with_the_class_only():
    for url in (EVENTS, MARKETS):
        r = _client(FakeDB(table_exc=RuntimeError("secret detail"))).get(url, headers=H)
        assert r.status_code == 502 and r.json() == {"error": "upstream_error", "detail": "RuntimeError"}


def test_no_rows_is_an_empty_list():
    r = _client(FakeDB(rows=None)).get(MARKETS, headers=H)
    assert r.json() == {"count": 0, "offset": 0, "next_offset": None, "events": []}
