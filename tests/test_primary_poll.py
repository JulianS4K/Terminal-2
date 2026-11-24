"""The primary box offices we poll ourselves (operator 2026-11-23: "push the list of events and their
respective listings out, if poller fails to run for an event, do not send listing information"):
the two read-only clients, the worker's run, and GET /api/v1/subs/primary/events and /listings."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
testclient = pytest.importorskip("fastapi.testclient")

from fastapi import FastAPI  # noqa: E402

import jump_client as jc  # noqa: E402
import sitickets_client as si  # noqa: E402
from core import primary_poll_sync as sync  # noqa: E402
from routers import primary_poll_feed as pp  # noqa: E402
from routers import subs_api as s  # noqa: E402
from routers.mcp_api import hash_key  # noqa: E402


class _Resp:
    def __init__(self, status=200, text=""):
        self.status_code, self.text = status, text


def _next_page(props):
    return '<html><script id="__NEXT_DATA__" type="application/json">%s</script></html>' % json.dumps(
        {"props": {"pageProps": props}})


# ---------- sitickets_client ----------

SI_VENUE = {"venueData": {"name": "Sports Illustrated Stadium", "city": "Harrison", "state": "NJ"},
            "venueEventsData": [
                {"event_id": 2297105, "event_name": "Red Bull New York vs. New England Revolution",
                 "event_slug": "sprint-rbny-vs-new-england", "occurs_at": "2027-05-01T19:00:00Z", "primary": True,
                 "venue_name": "Sports Illustrated Stadium", "venue_city": "Harrison", "venue_state": "NJ"},
                {"event_id": 2226372, "event_name": "DecemberSeries 2026", "event_slug": "", "occurs_at": "soon",
                 "primary": True},
                {"event_id": 2313223, "event_name": "2027 Blueprint Membership", "event_slug": "x", "primary": True},
                {"event_id": 2297141, "event_name": "2027 Sprint Season", "event_slug": "y", "primary": True},
                {"event_id": 2422939, "event_name": "Playoffs 2026 Deposit", "event_slug": "a/b", "primary": True},
                {"event_id": 1, "event_name": "A resale event", "event_slug": "z", "primary": False},
                {"event_id": 2, "event_name": " ", "event_slug": "w", "primary": True}]}
SI_GROUP = {"ti": "a5j504_alas4e_1746207051860_82.03_std_full", "tus": "128", "tur": 4, "tls": "9", "ths": "24",
            "tq": 5, "tsp": [1, 2, 3, 4], "tmc": 4, "tp": 82.03, "tpf": 2.68, "tti": "FOX2F9", "tf": "E-Ticket",
            "ia": False, "tsi": ["a5j504:alas4e:9", "a5j504:alas4e:21", 7],
            "tps": [{"n": "Sideline A / Upper Center Mid-Single-MP", "p": 84.71}]}
SI_EVENT = {"ticketGroupsError": None,
            "ticketData": {"ticketingGroups": [SI_GROUP, {"ti": 9, "tq": 2, "tsp": [], "tp": 40.1}],
                           "allInPrices": {"FOX2F9": {"allIn": 90.31, "tax": 5.44, "convenienceFee": 0,
                                                      "processingFee": 2.84, "processingFeeFlat": 0.3}}}}


def test_sitickets_events_are_the_box_office_ones_without_packages_and_memberships():
    events = si.parse_events(SI_VENUE)
    assert [e["id"] for e in events] == ["2297105", "2226372"]
    game, series = events
    assert game["local_date"] == "2027-05-01" and game["local_time"] == "19:00"
    # the stadium's local time made a moment (7 pm in New Jersey in May is 23:00 UTC): an event that has
    # started is no longer read (operator 2026-11-24: "fix the game day wart, end it at tipoff")
    assert game["start_utc"] == "2027-05-01T23:00:00+00:00" and game["timezone"] == "America/New_York"
    assert series["start_utc"] is None and series["timezone"] is None            # no readable time: no moment
    elsewhere = si.parse_events(SI_VENUE, "some-other-venue")[0]                   # a venue whose zone we do not know
    assert elsewhere["local_time"] == "19:00" and elsewhere["start_utc"] is None and elsewhere["timezone"] is None
    assert game["venue"] == "Sports Illustrated Stadium" and game["state"] == "NJ"
    assert game["url"] == "https://www.sitickets.com/event/sprint-rbny-vs-new-england"
    assert game["_slug"] == "sprint-rbny-vs-new-england"
    # no readable time, no page of its own, and the venue's own name where the row has none
    assert series["local_date"] is None and series["url"] is None and series["venue"] == "Sports Illustrated Stadium"
    assert si.parse_events({}) == []


def test_sitickets_listings_carry_seats_quantities_limits_and_prices():
    first, second = si.parse_listings(SI_EVENT)
    assert first == {"id": SI_GROUP["ti"], "market": "primary", "area": None, "section": "128", "row": "4",
                     "seat_low": "9", "seat_high": "24", "seats": ["9", "21"], "qty": 5,
                     "allowed_quantities": [1, 2, 3, 4], "max_per_order": 4, "price": 82.03, "fee": 2.84,
                     "tax": 5.44, "all_in": 90.31, "order_fee": 0.3, "price_includes_tax": False,
                     "price_estimated": False,
                     "ticket_type": "Sideline A / Upper Center Mid-Single-MP", "delivery": "E-Ticket",
                     "ada": False, "obstructed": False, "aisle": None, "ga": False}
    assert second["id"] == "9" and second["seats"] is None and second["max_per_order"] is None
    assert second["section"] is None and second["all_in"] is None
    # price + fee + tax is the all-in price; the fee is the one in the total, not the listing's own 2.68
    assert round(first["price"] + first["fee"] + first["tax"], 2) == first["all_in"]
    # a ticket type the page gives no all-in breakdown for: the listing's own fee, and no tax or total
    assert (second["fee"], second["tax"], second["order_fee"], second["price"]) == (None, None, None, 40.1)


def test_a_sitickets_general_admission_block_is_flagged_and_its_order_limit_is_the_largest_quantity_sold():
    # HSBC SVNS, 2026-11-24: one block of 13,014 with "GA" for a row and no seats. The page flags it (`iga`),
    # lets a buyer take 1 to 10 and still gives `tmc` 1, which we were sending as the most an order may take
    ga = {"ti": "bm7vvi_GA_1787851599655_81.5_std_full", "tus": "General Admission", "tur": "GA", "tls": None,
          "ths": None, "tsi": [], "tq": 13014, "tsp": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "tmc": 1, "tp": 81.5,
          "iga": True, "tf": "E-Ticket", "tps": [{"n": "General Admission"}]}
    no_choice = {"ti": "x", "tq": 3, "tsp": [], "tmc": 3, "tp": 10}      # no quantities listed: the page's own limit
    block, other = si.parse_listings({"ticketData": {"ticketingGroups": [ga, no_choice]}})
    assert block["ga"] is True and block["max_per_order"] == 10 and block["qty"] == 13014
    assert (block["section"], block["row"], block["seat_low"], block["seat_high"], block["seats"]) == (
        "General Admission", "GA", None, None, None)
    assert other["ga"] is False and other["max_per_order"] == 3
    with_fee = si.parse_listings({"ticketData": {"ticketingGroups": [{"ti": 1, "tp": 10, "tpf": 0.5}]}})[0]
    assert with_fee["fee"] == 0.5 and with_fee["all_in"] is None
    for props in ({"ticketGroupsError": "boom"}, {"ticketData": []}, {"ticketData": {"ticketingGroups": None}}, {}):
        with pytest.raises(si.SiTicketsError):
            si.parse_listings(props)


def test_sitickets_reads_pages_with_get_only_and_refuses_what_is_not_a_page(monkeypatch):
    seen = []

    def _get(url, headers, timeout):
        seen.append((url, headers["User-Agent"], timeout))
        return _Resp(200, _next_page(SI_VENUE if "/venue/" in url else SI_EVENT))

    monkeypatch.setattr(si.requests, "get", _get)
    events = si.events()
    assert len(events) == 2 and len(si.listings(events[0])) == 2
    assert seen == [("https://www.sitickets.com/venue/sports-illustrated-stadium", si.USER_AGENT, si.TIMEOUT_S),
                    ("https://www.sitickets.com/event/sprint-rbny-vs-new-england", si.USER_AGENT, si.TIMEOUT_S)]
    for bad in ({"_slug": "gotham-fc-IMUU/playoffs-2026-deposit-SOU4RL"}, {"_slug": ""}, {}):
        with pytest.raises(si.SiTicketsError):                  # sold through another flow: nothing to read
            si.listings(bad)
    with pytest.raises(si.SiTicketsError):
        si.events("../etc")
    assert len(seen) == 2                                        # none of the refusals made a call
    monkeypatch.setattr(si.requests, "get", lambda *a, **k: _Resp(503))
    with pytest.raises(si.SiTicketsError, match="HTTP 503"):
        si.events()


def test_sitickets_page_without_data_is_an_error():
    with pytest.raises(si.SiTicketsError):
        si.page_props("<html></html>")
    with pytest.raises(si.SiTicketsError):
        si.page_props('<script id="__NEXT_DATA__">{"props": {}}</script>')
    with pytest.raises(si.SiTicketsError):
        si.page_props('<script id="__NEXT_DATA__">not json</script>')


# ---------- jump_client ----------

def _flight(*rows):
    """A page whose data is these rows, as the site writes them: `label:JSON`, one a line."""
    text = "\n".join(r if isinstance(r, str) else "2%x:%s" % (n, json.dumps(r, separators=(",", ":")))
                     for n, r in enumerate(rows))
    return "<script>self.__next_f.push([1,%s])</script>" % json.dumps(text)


JUMP_OFFER = {"__typename": "Offer", "id": "7575", "name": "Single Game Tickets", "totalAvailable": 3498,
              "fromPrice": {"amount": 3400}, "toPrice": {"amount": 102000}, "qtyMin": 1, "qtyMax": 6}
JUMP_EVENT = {"__typename": "Event", "id": "1729", "name": "Timberwolves vs. Nets", "defaultOfferId": "7575",
              "eventStart": "2026-11-24T00:30:00.000Z",
              "venue": {"name": "Target Center", "timezone": "America/Chicago",
                        "address": {"city": "Minneapolis", "state": "MN"}}}
# the page writes a repeated value once and points to it from the other places
JUMP_ROWS = ('1a:["$","div",null,{"eventList":[{"venue":{"name":"Target Center","timezone":"America/Chicago",'
             '"address":"$1b:0"}}]}]',
             '1b:[{"city":"Minneapolis","state":"MN"}]',
             '1c:T12,body{color:red}',                   # a style sheet: not JSON
             '1a:"a second row under a label already seen is ignored"',
             '9:"$9"')                                   # a pointer to itself leads nowhere


def test_jump_events_come_from_the_home_page_with_each_games_public_offer():
    pointed = {**JUMP_EVENT, "venue": "$1a:props:eventList:0:venue", "image": "$9",
               "data": {"a": {"b": {"c": {"d": "$9"}}}}}
    later = {**JUMP_EVENT, "id": "1720", "name": "Timberwolves vs. Grizzlies", "defaultOfferId": "7577",
             "eventStart": "2026-11-28T01:30:00.000Z", "venue": {"name": "Target Center", "timezone": "Mars/Olympus"},
             "defaultOffer": {"totalAvailable": 3477, "fromPrice": {"amount": "n/a"}}}
    nowhere = {**JUMP_EVENT, "id": "1740", "defaultOfferId": "7579", "eventStart": "2026-12-11T01:00:00.000Z",
               "venue": "$1a:props:nothing:here", "defaultOffer": "$1b:x"}
    html = _flight(
        *JUMP_ROWS,
        {"offers": [{"__typename": "Offer", "id": "7575", "name": "Single Game Tickets"},    # a short copy, seen first
                    JUMP_OFFER,
                    {"__typename": "Offer", "id": "7575", "qtyMax": "$9"},                   # a short copy, seen after
                    {"__typename": "Offer", "name": "an offer with no id"}]},
        {"events": [later, pointed, nowhere,
                    {"__typename": "Event", "id": "9", "name": "no offer", "eventStart": "2026-12-01T00:00:00.000Z"},
                    # a season on sale is not a game (operator: "remove membership and season listings")
                    {**JUMP_EVENT, "id": "77", "name": "2027 NC Courage Season "},
                    {**JUMP_EVENT, "id": "78", "name": "Half-Season Membership"}]},
        'zz:{"__typename":"Event","id":"cut off')
    events = jc.parse_events(jc.page_data(html), "timberwolves")
    assert [e["id"] for e in events] == ["1729", "1720", "1740"]                    # soonest first
    assert events[0] == {"id": "1729", "name": "Timberwolves vs. Nets", "local_date": "2026-11-23",
                         "local_time": "18:30", "start_utc": "2026-11-24T00:30:00+00:00",
                         "timezone": "America/Chicago", "venue": "Target Center", "city": "Minneapolis",
                         "state": "MN", "url": "https://tickets.timberwolves.com/offers/7575", "offer_id": "7575",
                         "order_min": 1, "order_max": 6, "total_available": 3498, "price_min": 34.0,
                         "price_max": 1020.0}
    # an unknown time zone: no local date, and the offer the event itself carries is used
    assert events[1]["local_date"] is None and events[1]["total_available"] == 3477 and events[1]["price_min"] is None
    # pointers that lead nowhere: no venue, no offer
    assert events[2]["local_date"] is None and events[2]["venue"] is None and events[2]["total_available"] is None
    rows = jc._rows(jc.page_data(html))
    assert jc._follow(rows, "$1b:0") == {"city": "Minneapolis", "state": "MN"} and jc._follow(rows, "$1b:7") is None
    assert jc._resolved(rows, {"a": {"b": {"c": {"d": {"e": "$9"}}}}}) == {"a": {"b": {"c": {"d": {"e": "$9"}}}}}


def test_jump_reads_the_home_page_with_get_only_and_never_the_seat_inventory(monkeypatch):
    seen = []

    def _get(url, headers, timeout):
        seen.append((url, headers["User-Agent"]))
        return _Resp(200, _flight({"offers": [JUMP_OFFER], "events": [JUMP_EVENT]}))

    monkeypatch.setattr(jc.requests, "get", _get)
    events = jc.events()
    assert [e["id"] for e in events] == ["1729"]
    assert seen == [("https://tickets.timberwolves.com/", jc.USER_AGENT)]
    with pytest.raises(jc.JumpInventoryNotEnabled):              # the POST it needs is not authorized
        jc.listings("timberwolves", events[0])
    with pytest.raises(jc.JumpError):
        jc.events("lakers")
    assert len(seen) == 1
    monkeypatch.setattr(jc.requests, "get", lambda *a, **k: _Resp(200, "<html></html>"))
    with pytest.raises(jc.JumpError, match="no games"):
        jc.events()
    monkeypatch.setattr(jc.requests, "get", lambda *a, **k: _Resp(403))
    with pytest.raises(jc.JumpError, match="HTTP 403"):
        jc.events()
    with pytest.raises(jc.JumpError):
        jc.page_data(r'self.__next_f.push([1,"\q"])')


# ---------- core/primary_poll_sync ----------

class _Source:
    def __init__(self, events=None, listings=None, list_exc=None):
        self._events, self._listings, self._list_exc = events or [], listings or {}, list_exc

    def events(self, *_a):
        if self._list_exc:
            raise self._list_exc
        return self._events

    def listings(self, *args):
        got = self._listings[args[-1]["id"]]
        if isinstance(got, Exception):
            raise got
        return got


def test_a_run_sends_each_event_with_its_listings_or_with_why_its_poll_failed():
    calls = []

    def rpc(name, params):
        calls.append((name, params))
        if params.get("p_events") and params["p_events"][0]["id"] == "3":
            raise RuntimeError("db blip")
        return 4

    sitickets = _Source(events=[{"id": "1", "name": "A", "_slug": "a"}, {"id": "2", "name": "B", "_slug": "b"},
                                {"id": "3", "name": "C", "_slug": "c"}],
                        listings={"1": [{"id": "x"}, {"id": "y"}], "2": si.SiTicketsError("HTTP 503 for /event/b"),
                                  "3": [{"id": "z"}]})
    out = sync.run(rpc, sitickets, _Source(list_exc=jc.JumpError("HTTP 403 for /")))
    assert out["sitickets"] == {"events": 3, "ok": 1, "failed": 1, "listings": 2, "not_stored": 1, "skipped": 0}
    # the event list could not be read: every event of that source is marked failed in one call
    assert out["timberwolves"] == {"events": 0, "ok": 0, "failed": 0, "listings": 0,
                                   "list_error": "JumpError: HTTP 403 for /", "marked_failed": 4}
    calls = [c for c in calls if c[0] != "primary_poll_due"]       # asked first; this rpc cannot say, so all are read
    assert [c[0] for c in calls] == ["primary_poll_ingest"] * 3 + ["primary_poll_run_done",
                                                                     "primary_poll_source_failed"]
    # the run is closed with every event the source listed, so the feeds serve this pull and no older one
    closed = calls[3][1]
    assert closed["p_source"] == "sitickets" and closed["p_event_ids"] == ["1", "2", "3"] and len(closed["p_run"]) == 32
    ok, failed = calls[0][1], calls[1][1]
    assert ok == {"p_source": "sitickets", "p_events": [{"id": "1", "name": "A", "ok": True,
                                                           "listings": [{"id": "x"}, {"id": "y"}]}]}
    assert failed["p_events"] == [{"id": "2", "name": "B", "ok": False, "listings": [],
                                   "error": "SiTicketsError: HTTP 503 for /event/b"}]   # no listing goes with it
    assert calls[4][1] == {"p_source": "timberwolves", "p_error": "JumpError: HTTP 403 for /"}   # and no run closed


def test_only_the_events_that_are_due_are_read_and_the_pull_still_lists_them_all():
    calls = []

    def rpc(name, params):
        calls.append((name, params))
        if name == "primary_poll_due":
            return ["2"]                         # the database says which are due: by date, median price and tickets listed
        return None

    events = [{"id": 1, "name": "Far off"}, {"id": 2, "name": "Tonight"}, {"id": 3, "name": "Next month"}]
    read = []

    def listings(event):
        read.append(event["id"])
        return [{"id": "x"}]

    out = sync.poll_source(rpc, "timberwolves", lambda: events, listings)
    assert out == {"events": 3, "ok": 1, "failed": 0, "listings": 1, "not_stored": 0, "skipped": 2} and read == [2]
    assert calls[0] == ("primary_poll_due", {"p_source": "timberwolves", "p_event_ids": ["1", "2", "3"]})
    assert [c[0] for c in calls] == ["primary_poll_due", "primary_poll_ingest", "primary_poll_run_done"]
    assert calls[2][1]["p_event_ids"] == ["1", "2", "3"]          # the skipped events are still in the pull
    # nothing due: nothing is read, and the pull is still closed
    calls.clear(), read.clear()
    out = sync.poll_source(lambda name, params: [] if name == "primary_poll_due" else calls.append(name),
                           "timberwolves", lambda: events, listings)
    assert out["skipped"] == 3 and read == [] and calls == ["primary_poll_run_done"]
    # the database cannot say what is due: everything is read
    def down(name, params):
        if name == "primary_poll_due":
            raise RuntimeError("db blip")

    read.clear()
    assert sync.poll_source(down, "timberwolves", lambda: events, listings)["ok"] == 3 and read == [1, 2, 3]


def test_a_run_that_cannot_be_closed_says_so_and_goes_on_to_the_next_source():
    def rpc(name, params):
        if name == "primary_poll_run_done" and params["p_source"] == "sitickets":
            raise RuntimeError("db blip")

    out = sync.run(rpc, _Source(events=[{"id": "1", "name": "A"}], listings={"1": []}), _Source())
    assert out["sitickets"] == {"events": 1, "ok": 1, "failed": 0, "listings": 0, "not_stored": 0, "skipped": 0,
                                "run_not_closed": "RuntimeError: db blip"}
    assert out["timberwolves"] == {"events": 0, "ok": 0, "failed": 0, "listings": 0, "not_stored": 0, "skipped": 0}


def test_a_run_over_the_real_clients_never_has_timberwolves_listings(monkeypatch):
    monkeypatch.setattr(si, "events", lambda: [])
    monkeypatch.setattr(jc, "events", lambda org: [{"id": "1729", "name": "Timberwolves vs. Nets"}])
    sent = []
    out = sync.run(lambda name, params: sent.append(params), si, jc)
    assert out["timberwolves"] == {"events": 1, "ok": 0, "failed": 1, "listings": 0, "not_stored": 0, "skipped": 0}
    game = next(p for p in sent if p.get("p_source") == "timberwolves" and "p_events" in p)["p_events"][0]
    assert game["ok"] is False and game["listings"] == [] and game["error"].startswith("JumpInventoryNotEnabled")


# ---------- GET /primary/events and /primary/listings ----------

KEY = "crm-key"
H = {"x-api-key": KEY}
EVENTS, LISTINGS = "/api/v1/subs/primary/events", "/api/v1/subs/primary/listings"
EVENT_ROW = {"source": "sitickets", "event_id": "2297105", "name": "Red Bull New York vs. New England Revolution",
             "event_date": "2027-05-01", "listings_available": True, "listing_count": 165, "listings_withheld": None}
LISTING_ROW = {"source": "sitickets", "event_id": "2297105", "listing_id": "a", "section": "128", "seat_row": "4",
               "seat_low": "9", "seat_high": "24", "quantity": 5, "price": 82.03}


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
        assert name in (pp.EVENTS_VIEW, pp.LISTINGS_VIEW)
        self.tables.append(name)
        q = _Query(self)
        self.queries.append(q)
        return q


def _client(db):
    app = FastAPI()
    app.include_router(s.make_router(lambda: db))
    return testclient.TestClient(app)


def test_both_routes_need_a_key_that_may_find_subs():
    for url in (EVENTS, LISTINGS):
        db = FakeDB(rows=[EVENT_ROW])
        assert _client(db).get(url).status_code == 401
        assert _client(FakeDB(rows=[EVENT_ROW], find=False)).get(url, headers=H).status_code == 403
        assert db.tables == []


def test_events_are_every_polled_event_with_whether_listings_can_be_sent():
    db = FakeDB(rows=[EVENT_ROW])
    r = _client(db).get(EVENTS, headers=H)
    assert r.status_code == 200 and r.json() == {"count": 1, "offset": 0, "next_offset": None, "events": [EVENT_ROW]}
    calls = db.queries[0].calls
    assert db.tables == [pp.EVENTS_VIEW] and calls[0] == ("select", ",".join(pp.EVENT_COLUMNS))
    assert [c[1] for c in calls if c[0] == "order"] == ["event_date", "start_local_time", "source", "event_id"]
    assert ("range", 0, 999) in calls and not any(c[0] in ("eq", "gte", "lte", "ilike", "is_") for c in calls)
    assert "tevo_event_id" in pp.EVENT_COLUMNS and "tevo_event_id" in pp.LISTING_COLUMNS    # the EVO event, on every row
    assert pp.EVENT_COLUMNS[-4:] == ("median_price", "poll_every_minutes", "next_poll_at", "listed_quantity")  # its own cadence
    assert pp.SEARCH_COLUMN not in pp.EVENT_COLUMNS and "poll_error" not in pp.EVENT_COLUMNS
    db = FakeDB(rows=[EVENT_ROW, EVENT_ROW])
    r = _client(db).get(EVENTS, headers=H, params={
        "source": "SITickets", "date_from": "2026-11-23", "date_to": "2027-05-01", "available": "false",
        "q": "Red Bull", "limit": "2", "offset": "4"})
    calls = db.queries[0].calls
    assert r.json()["next_offset"] == 6 and ("range", 4, 5) in calls
    for expected in (("eq", "source", "sitickets"), ("gte", "event_date", "2026-11-23"),
                     ("lte", "event_date", "2027-05-01"), ("eq", "listings_available", False),
                     ("ilike", "search_text", "%red%"), ("ilike", "search_text", "%bull%")):
        assert expected in calls
    for mapped, expected in (("true", [("not",), ("is_", "tevo_event_id", "null")]),
                             ("false", [("is_", "tevo_event_id", "null")])):
        db = FakeDB(rows=[EVENT_ROW])
        _client(db).get(EVENTS, headers=H, params={"mapped": mapped})
        assert [c for c in db.queries[0].calls if c[0] in ("not", "is_")] == expected


def test_listings_can_be_narrowed_to_an_event_a_market_and_a_section():
    db = FakeDB(rows=[LISTING_ROW])
    r = _client(db).get(LISTINGS, headers=H)
    assert r.status_code == 200 and r.json()["listings"] == [LISTING_ROW]
    calls = db.queries[0].calls
    assert db.tables == [pp.LISTINGS_VIEW] and calls[0] == ("select", ",".join(pp.LISTING_COLUMNS))
    assert [c[1] for c in calls if c[0] == "order"] == ["event_date", "source", "event_id", "price", "listing_id"]
    assert not any(c[0] == "eq" for c in calls)
    assert "obstructed" not in pp.LISTING_COLUMNS                 # an obstructed-view listing is never sent
    for column in ("price", "fee", "tax", "all_in_price", "order_fee", "price_estimated"):
        assert column in pp.LISTING_COLUMNS
    assert pp.LISTING_COLUMNS[-3:] == ("tax", "order_fee", "price_estimated")   # the view gained them at its end
    db = FakeDB(rows=None)
    r = _client(db).get(LISTINGS, headers=H, params={"source": "timberwolves", "event_id": "1729",
                                                    "tevo_event_id": "3466081", "market": "Resale", "section": "218"})
    assert r.json() == {"count": 0, "offset": 0, "next_offset": None, "listings": []}
    for expected in (("eq", "source", "timberwolves"), ("eq", "event_id", "1729"), ("eq", "market", "resale"),
                     ("eq", "section", "218"), ("eq", "tevo_event_id", 3466081)):
        assert expected in db.queries[0].calls


def test_csv_bad_parameters_and_a_database_error():
    r = _client(FakeDB(rows=[LISTING_ROW])).get(LISTINGS, headers=H, params={"format": "csv"})
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/csv")
    assert r.text.splitlines()[0] == ",".join(pp.LISTING_COLUMNS) and "primary_listings.csv" in r.headers[
        "content-disposition"]
    for url, params in ((EVENTS, {"source": "stubhub"}), (EVENTS, {"format": "xml"}), (EVENTS, {"available": "maybe"}),
                        (EVENTS, {"limit": "0"}), (EVENTS, {"date_from": "tomorrow"}), (EVENTS, {"q": "!"}),
                        (EVENTS, {"mapped": "perhaps"}), (LISTINGS, {"tevo_event_id": "abc"}),
                        (LISTINGS, {"market": "grey"}), (LISTINGS, {"event_id": "1;drop"}),
                        (LISTINGS, {"section": "a,b"}), (LISTINGS, {"format": "xml"})):
        db = FakeDB(rows=[])
        r = _client(db).get(url, headers=H, params=params)
        assert r.status_code == 422 and r.json()["error"] == "invalid" and db.tables == [], (url, params)
    for url in (EVENTS, LISTINGS):
        r = _client(FakeDB(table_exc=RuntimeError("down"))).get(url, headers=H)
        assert r.status_code == 502 and r.json() == {"error": "upstream_error", "detail": "RuntimeError"}


def test_every_team_site_on_the_same_platform_is_a_source_of_the_feed():
    # operator 2026-11-24: "Add all those jump teams to the catalogue scanner and push through into api"
    assert pp.SOURCES == ("sitickets", "ims", *jc.SITES) and len(jc.SITES) == 8
    for source in ("nccourage", "denversummit", "reign", "bostonlegacy", "sounders", "northcarolinafc", "lynx"):
        for url in (EVENTS, LISTINGS):
            db = FakeDB(rows=[])
            r = _client(db).get(url, headers=H, params={"source": source})
            assert r.status_code == 200 and ("eq", "source", source) in db.queries[0].calls, (url, source)
    # a season, a membership, a plan or a deposit is not a game; a game named for the season's opener is
    for name in ("2027 NC Courage Season", "2027 Full Season - Online", "Half-Season Membership", "Season Ticket Deposit",
                 "10-Game Plan"):
        assert jc.NOT_AN_EVENT.search(name), name
    for name in ("Timberwolves vs. Nets", "Season Opener: NC Courage vs. Washington Spirit", "Sounders vs. Timbers 3-14-27"):
        assert not jc.NOT_AN_EVENT.search(name), name
