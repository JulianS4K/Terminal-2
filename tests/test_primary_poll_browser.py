"""The Timberwolves browser worker (core/primary_poll_browser.py; operator 2026-11-23: "start the
timberwolves poller and test and then merge"): what it keeps from a game's page, what it refuses to
load, and that a page which does not answer is a failed poll with no listings."""
from __future__ import annotations

import sys
import types
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core import primary_poll_browser as b  # noqa: E402
from core import primary_poll_sync as sync  # noqa: E402

BLOCK = {"id": "blk1", "market": "PRIMARY", "quantities": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14],
         "location": {"neighborhood": "Admissions -- 200 Level", "section": "203", "row": "X",
                      "seats": list(range(1, 15))},
         "price": {"amount": 5500, "priceTypeName": None}, "hasAda": False, "hasObstructedView": False,
         "hasAisle": False, "isGA": False,
         "pricesByType": [{"priceTypeId": "9999", "amount": 4990}, {"priceTypeId": "7336", "amount": 5545}]}
RATES = b.PRICING["timberwolves"]
RESALE = {"id": "blk2", "market": "SECONDARY", "quantities": [2], "hasObstructedView": True,
          "location": {"section": "230", "row": "N", "seats": [9, 10]}, "price": {"amount": 2300}}
BARE = {"id": "blk3", "market": "OTHER"}
INVENTORY = {"data": {"getBlocks": {"blocks": [BLOCK, RESALE, BARE]}}}
OFFER = {"data": {"offerById": {"content": {"inventoryListDescription": "Price includes tax"},
                                "eventGroup": [{"qtyMin": 1, "qtyMax": 6,
                                                "priceTypes": [{"priceTypeId": "9999", "isDefault": False},
                                                               {"priceTypeId": "7336", "isDefault": True}]}]}}}
EVENT = {"id": "1729", "name": "Timberwolves vs. Nets", "url": "https://tickets.timberwolves.com/offers/7575",
         "order_min": None, "order_max": None}


def test_listings_carry_seats_the_quantities_allowed_and_the_orders_limit():
    first, second, third = b.parse_listings(INVENTORY, order_max=6, rates=RATES, price_type="7336")
    # the operator's cart of 2026-11-23: 42.00 + 8.40 fees + 5.05 tax = 55.45 a ticket; the page shows 55
    assert first == {"id": "blk1", "market": "primary", "area": "Admissions -- 200 Level", "section": "203",
                     "row": "X", "seat_low": "1", "seat_high": "14", "seats": [str(n) for n in range(1, 15)],
                     "qty": 14, "allowed_quantities": BLOCK["quantities"], "max_per_order": 6, "price": 42.0,
                     "fee": 8.4, "tax": 5.05, "all_in": 55.45, "order_fee": None, "price_includes_tax": False,
                     "price_estimated": True, "ticket_type": None,
                     "delivery": None, "ada": False, "obstructed": False, "aisle": False, "ga": False}
    assert second["market"] == "resale" and second["obstructed"] is True and second["max_per_order"] == 2
    assert second["seat_low"] == "9" and second["seat_high"] == "10"
    # resale: the total is only known to the dollar, and is split the same way
    assert (second["price"], second["fee"], second["tax"], second["all_in"]) == (17.42, 3.48, 2.1, 23.0)
    assert round(second["price"] + second["fee"] + second["tax"], 2) == second["all_in"] and second["price_estimated"]
    assert third["all_in"] is None and third["fee"] is None and third["tax"] is None and not third["price_estimated"]
    # a team whose fee is not confirmed (the Lynx): the all-in total and no split
    bare = b.parse_listings(INVENTORY)[0]
    assert (bare["price"], bare["fee"], bare["tax"], bare["all_in"]) == (None, None, None, 49.9)
    assert bare["price_estimated"] is False and bare["price_includes_tax"] is None
    # a block with nothing but an id: no seats, no price, no limit, an unknown market
    assert third["market"] is None and third["seats"] is None and third["qty"] is None and third["price"] is None
    assert third["max_per_order"] is None and third["seat_low"] is None and third["obstructed"] is False
    assert b.parse_listings(INVENTORY)[0]["max_per_order"] == 14            # no order limit known
    # the limit is a quantity the block really sells: 7 seats sold as 1-5 or all 7 give 5 under a limit
    # of 6, and a block sold only whole and over the limit gives none
    odd = {"data": {"getBlocks": {"blocks": [dict(BLOCK, quantities=[1, 2, 3, 4, 5, 7]), dict(BLOCK, quantities=[8])]}}}
    assert [row["max_per_order"] for row in b.parse_listings(odd, order_max=6)] == [5, None]
    assert [row["max_per_order"] for row in b.parse_listings(odd)] == [7, 8]
    for bad in (None, {}, {"data": None}, {"errors": [{"message": "no"}]}, {"data": {"getBlocks": {"blocks": None}}}):
        with pytest.raises(b.BrowserPollError):
            b.parse_listings(bad)


def test_order_limits_and_the_default_price_type_come_from_the_pages_offer():
    assert b.order_limits(OFFER) == (1, 6) and b.default_price_type(OFFER) == "7336"
    for missing in (None, {}, {"data": {"offerById": {"eventGroup": []}}}):
        assert b.order_limits(missing) == (None, None) and b.default_price_type(missing) is None
    for no_default in ({"data": {"offerById": {"eventGroup": [{"priceTypes": None}]}}},
                       {"data": {"offerById": {"eventGroup": [{"priceTypes": [{"priceTypeId": "1", "isDefault": False}]}]}}}):
        assert b.default_price_type(no_default) is None


def test_the_all_in_price_is_exact_where_the_page_gives_it_and_splits_to_the_cent():
    assert b.all_in_price(BLOCK, "7336") == 55.45              # the default price type's own total
    assert b.all_in_price(BLOCK) == b.all_in_price(BLOCK, "0") == 49.9      # no such type: the first one
    assert b.all_in_price(RESALE) == 23.0                      # resale: only the figure the page shows
    assert b.all_in_price({"pricesByType": [{"priceTypeId": "1", "amount": None}], "price": {"amount": 100}}) == 1.0
    assert b.all_in_price({}) is None and b.all_in_price({"price": {"amount": "n/a"}}) is None
    assert b.split_all_in(55.45, RATES) == (42.0, 8.4, 5.05)
    for paid in (55.45, 33.27, 1019.0, 20.0, 0.01):            # the three parts always add up to the total
        assert round(sum(b.split_all_in(paid, RATES)), 2) == paid
    assert "lynx" not in b.PRICING                             # not confirmed for the Lynx: no split there


class _Request:
    def __init__(self, url, resource_type="document", post_data=None):
        self.url, self.resource_type, self.post_data = url, resource_type, post_data


class _Response:
    def __init__(self, url, operation=None, body=None):
        self.url, self._body = url, body
        self.request = _Request(url, "fetch", '{"operationName":"%s","variables":{}}' % operation if operation else None)

    def json(self):
        return self._body


class _Route:
    def __init__(self, request):
        self.request, self.did = request, None

    def continue_(self):
        self.did = "continue"

    def abort(self):
        self.did = "abort"


def test_a_page_loads_only_its_own_hosts_and_no_images_fonts_or_video():
    for url, kind, did in (("https://tickets.timberwolves.com/offers/7575", "document", "continue"),
                           ("https://fan.jump.com/graphql", "fetch", "continue"),
                           ("https://cdn.orgs.jump.com/x/maps/config.b2c.json", "fetch", "continue"),
                           ("https://tickets.timberwolves.com/maps/sprites/sprites.png", "image", "abort"),
                           ("https://cdn.orgs.jump.com/x/font.woff2", "font", "abort"),
                           ("https://api.segment.io/v1/t", "fetch", "abort"),
                           ("https://browser-intake-datadoghq.com/api/v2/rum", "fetch", "abort"),
                           ("about:blank", "document", "abort")):
        route = _Route(_Request(url, kind))
        b.allow(route)
        assert route.did == did, url


class _Expect:
    def __init__(self, page, predicate):
        self.page, self.predicate, self.value = page, predicate, None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            found = [r for r in self.page.responses if self.predicate(r)]
            if not found:
                raise TimeoutError("Timeout 45000ms exceeded while waiting for event \"response\"")
            self.value = found[0]
        return False


class _Page:
    def __init__(self, responses):
        self.responses, self.handlers, self.closed, self.went = responses, [], False, None

    def on(self, event, handler):
        assert event == "response"
        self.handlers.append(handler)

    def expect_response(self, predicate, timeout):
        assert timeout == b.PAGE_TIMEOUT_MS
        return _Expect(self, predicate)

    def goto(self, url, wait_until, timeout):
        self.went = (url, wait_until)
        for response in self.responses:
            for handler in self.handlers:
                handler(response)

    def close(self):
        self.closed = True


class _Context:
    def __init__(self, pages):
        self.pages, self.opened, self.routes = list(pages), [], []

    def new_page(self):
        page = self.pages.pop(0)
        self.opened.append(page)
        return page

    def route(self, pattern, handler):
        self.routes.append((pattern, handler))


def test_the_reader_keeps_what_the_page_itself_received_and_always_closes_the_page():
    inventory = _Response(b.DATA_URL, "getInventoryDetails", INVENTORY)
    full = _Page([_Response("https://tickets.timberwolves.com/offers/7575"),
                  _Response(b.DATA_URL, "GetEventListNoOffers", {}), _Response(b.DATA_URL, "OfferById", OFFER),
                  _Response("https://elsewhere.example/graphql", "getInventoryDetails", {"data": "not the site"}),
                  inventory])
    no_offer = _Page([inventory])
    silent = _Page([_Response(b.DATA_URL, "OfferById", OFFER)])
    read = b.page_reader(_Context([full, no_offer, silent]))
    assert read(EVENT) == {"inventory": INVENTORY, "offer": OFFER}
    assert full.went == (EVENT["url"], "domcontentloaded") and full.closed
    assert read(EVENT) == {"inventory": INVENTORY, "offer": None} and no_offer.closed
    with pytest.raises(TimeoutError):                    # the page never got its seats
        read(EVENT)
    assert silent.closed


class _Jump:
    USER_AGENT = "a browser"

    def __init__(self, events, lynx_out_of_season=True):
        self._events, self.asked, self.lynx_out_of_season = events, [], lynx_out_of_season

    def events(self, org):
        self.asked.append(org)
        if org != "timberwolves" and self.lynx_out_of_season:      # every other team lists no single game yet
            raise RuntimeError("the home page lists no games")
        return self._events


def test_a_run_stores_each_game_with_its_listings_and_a_page_that_fails_with_none():
    calls = []
    games = [dict(EVENT), {**EVENT, "id": "1720", "name": "Timberwolves vs. Grizzlies"}]

    def read_page(event):
        if event["id"] == "1720":
            raise TimeoutError("Timeout 45000ms exceeded")
        return {"inventory": INVENTORY, "offer": OFFER}

    out = b.run(lambda name, params: calls.append((name, params)), _Jump(games), read_page)
    assert out == {"events": 2, "ok": 1, "failed": 1, "listings": 3, "not_stored": 0, "skipped": 0}
    assert calls.pop(0)[0] == "primary_poll_due"                 # asked first; this rpc cannot say, so all are read
    assert [c[0] for c in calls] == ["primary_poll_ingest", "primary_poll_ingest", "primary_poll_run_done"]
    good, bad = calls[0][1]["p_events"][0], calls[1][1]["p_events"][0]
    assert calls[0][1]["p_source"] == "timberwolves" and good["ok"] is True and len(good["listings"]) == 3
    assert (good["order_min"], good["order_max"]) == (1, 6)                 # read from the page, sent with the event
    assert good["listings"][0]["max_per_order"] == 6
    assert (good["listings"][0]["price"], good["listings"][0]["all_in"]) == (42.0, 55.45)   # the default price type
    assert bad == {**games[1], "listings": [], "ok": False, "error": "TimeoutError: Timeout 45000ms exceeded"}
    assert calls[2][1]["p_event_ids"] == ["1729", "1720"]


class _Browser:
    def __init__(self, context):
        self.context, self.closed, self.options = context, False, None

    def new_context(self, **options):
        self.options = options
        return self.context

    def close(self):
        self.closed = True


class _Playwright:
    def __init__(self, browser):
        self.chromium = types.SimpleNamespace(launch=lambda: browser)


def test_a_cycle_opens_one_browser_filters_what_it_loads_and_closes_it_even_on_an_error():
    context = _Context([_Page([_Response(b.DATA_URL, "getInventoryDetails", INVENTORY)])])
    browser = _Browser(context)
    calls = []
    jump = _Jump([dict(EVENT)])
    out = b.cycle(lambda name, params: calls.append((name, params)), jump, _Playwright(browser))
    assert out["timberwolves"]["ok"] == 1 and out["timberwolves"]["listings"] == 3 and browser.closed
    # the other teams list no games yet: each one's run ends at the event list, stores no event and closes no pull
    others = [org for org in b.ORGS if org != "timberwolves"]
    assert jump.asked == list(b.ORGS) and b.ORGS[0] == "timberwolves" and len(others) == 8
    assert all(out[org]["events"] == 0 for org in others)
    assert out["lynx"]["list_error"] == "RuntimeError: the home page lists no games"
    assert [(n, p["p_source"]) for n, p in calls] == [("primary_poll_due", "timberwolves"),
                                                      ("primary_poll_ingest", "timberwolves"),
                                                      ("primary_poll_run_done", "timberwolves"),
                                                      *(("primary_poll_source_failed", org) for org in others)]
    assert browser.options["user_agent"] == "a browser" and context.routes == [("**/*", b.allow)]

    class _Broken(_Browser):
        def new_context(self, **options):
            raise RuntimeError("no display")

    broken = _Broken(None)
    with pytest.raises(RuntimeError):
        b.cycle(lambda name, params: None, _Jump([]), _Playwright(broken))
    assert broken.closed


def test_the_service_is_off_by_default_then_runs_and_survives_a_failed_run(monkeypatch):
    slept = []
    b.main(env={}, sleep=slept.append)                                             # not switched on
    b.main(env={"PRIMARY_POLL_BROWSER_LIVE": "1"}, sleep=slept.append)             # no database
    assert slept == []

    class _Manager:
        def __enter__(self):
            return "playwright"

        def __exit__(self, *exc):
            return False

    monkeypatch.setitem(sys.modules, "playwright", types.ModuleType("playwright"))
    monkeypatch.setitem(sys.modules, "playwright.sync_api", types.SimpleNamespace(sync_playwright=_Manager))
    import core.db
    from core import n2s_autobuy_live
    seen = {"rpc": [], "runs": 0}

    class _Db:
        def rpc(self, name, params):
            seen["rpc"].append(name)
            return types.SimpleNamespace(execute=lambda: types.SimpleNamespace(data={"ok": True}))

    monkeypatch.setattr(core.db, "make_supabase_client", lambda url, key: _Db())
    monkeypatch.setattr(n2s_autobuy_live, "retrying", lambda rpc: rpc)

    def _cycle(rpc, jump, playwright):
        seen["runs"] += 1
        if seen["runs"] == 1:
            raise RuntimeError("browser crashed")
        seen["stored"] = rpc("primary_poll_ingest", {})
        seen["with"] = (jump.__name__, playwright)
        return {"events": 30}

    class _Stop(Exception):
        pass

    def _sleep(seconds):
        slept.append(seconds)
        if len(slept) == 2:
            raise _Stop()

    monkeypatch.setattr(b, "cycle", _cycle)
    env = {"PRIMARY_POLL_BROWSER_LIVE": "1", "SUPABASE_URL": "u", "SUPABASE_SERVICE_ROLE_KEY": "k",
           "PRIMARY_POLL_INTERVAL_SECONDS": "5"}
    with pytest.raises(_Stop):
        b.main(env=env, sleep=_sleep)
    assert seen["runs"] == 2 and seen["rpc"] == ["primary_poll_ingest"] and seen["stored"] == {"ok": True}
    assert seen["with"] == ("jump_client", "playwright") and all(0 <= s <= 5 for s in slept)


def test_the_lynx_are_read_like_the_timberwolves_once_they_list_games():
    import jump_client
    assert set(b.ORGS) == set(jump_client.SITES) == {                # operator 2026-11-24: "Add all those jump teams"
        "timberwolves", "lynx", "nccourage", "denversummit", "reign", "bostonlegacy", "sounders", "northcarolinafc",
        "atleticodallas"}
    for site in jump_client.SITES.values():                      # every team's own host may load in the page
        assert site.startswith("https://tickets.") and site.removeprefix("https://") in b.PAGE_HOSTS
    assert {"fan.jump.com", "cdn.orgs.jump.com", "cdn.media.jump.com"} <= b.PAGE_HOSTS
    assert not any(org in b.PRICING for org in b.ORGS[1:])      # only the Timberwolves' fee and tax are known
    calls = []
    game = {**EVENT, "id": "9001", "name": "Lynx vs. Fever", "url": "https://tickets.lynxbasketball.com/offers/1"}
    out = b.run(lambda name, params: calls.append((name, params)), _Jump([game], lynx_out_of_season=False),
                lambda event: {"inventory": INVENTORY, "offer": OFFER}, "lynx")
    assert out == {"events": 1, "ok": 1, "failed": 0, "listings": 3, "not_stored": 0, "skipped": 0}
    assert [p["p_source"] for _, p in calls] == ["lynx"] * 3 and calls[2][1]["p_event_ids"] == ["9001"]


def test_each_worker_polls_only_the_sources_it_is_given(monkeypatch):
    assert sync.sources_from(None) == sync.sources_from("") == ("sitickets", "timberwolves", "ims")
    assert sync.sources_from(" SITickets ,") == ("sitickets",)
    with pytest.raises(ValueError, match="stubhub"):
        sync.sources_from("sitickets,stubhub")

    class _Never:
        def events(self, *_a):
            raise AssertionError("this source is another worker's")

    class _None:
        def events(self):
            return []

        all_events = events
        listings = None

    out = sync.run(lambda name, params: None, _None(), _Never(), ("sitickets",))
    assert list(out) == ["sitickets"]
