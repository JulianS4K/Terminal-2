"""Read the Timberwolves' seat listings with a real browser and store them (operator 2026-11-23:
"start the timberwolves poller and test and then merge", choosing the browser worker), and those of
every other team whose ticket site is on the same platform (jump_client.SITES), from the first run
after it lists single games: the Lynx (operator 2026-11-23: "ping and map lynx when schedule
releases") and NC Courage, Denver Summit, Seattle Reign, Boston Legacy, Seattle Sounders and North
Carolina FC (operator 2026-11-24: "Add all those jump teams to the catalogue scanner and push
through into api").

The Timberwolves' ticket site (jump_client.py) shows a game's seats only after the page has loaded:
the page's own script asks the site for them. This worker opens each game's public page in a headless
browser, as a visitor does, and keeps the two answers the page receives for itself: the seat blocks
(`getInventoryDetails`) and the offer's order limits (`OfferById`). It builds no request of its own to
the site's data service and sends nothing: no cart, no hold, no order (RULE 2).

One run, every PRIMARY_POLL_INTERVAL_SECONDS (600, one slot: the database says which games are due, each on its
own cadence of 10 minutes to one hour and at a random slot inside it; mig 20261123194030):
  1. the games, from the home page (jump_client.events, a GET);
  2. for each game, its page in the browser, the listings normalised, and the event sent to
     `primary_poll_ingest()`: with its listings, or failed with the reason, which deletes them;
  3. `primary_poll_run_done()`, so the feeds serve this pull.
It is core/primary_poll_sync.poll_source with a browser as the reader, so the rules are the same: a
game whose page does not answer in time is a failed poll and sends no listings.

It runs as its own service (render-primary-poll-browser.yaml, Dockerfile.primary-poll-browser), off
unless PRIMARY_POLL_BROWSER_LIVE=1. The web service's worker must then be given
PRIMARY_POLL_SOURCES=sitickets: one poller a source.

    python -m core.primary_poll_browser
"""
from __future__ import annotations

import logging
import os
import time
from typing import Any, Callable
from urllib.parse import urlsplit

import jump_client
from core import primary_poll_sync

log = logging.getLogger("primary_poll_browser")

# the teams read: every site of jump_client.SITES, each stored under its own name as the source. A team
# that lists no single game (the Lynx until the WNBA schedule is released, the clubs out of season) ends its
# run at the event list and stores nothing; the first run that finds games announces them to the event
# mapper (primary_poll_run_done, mig 20261123183730).
ORGS = tuple(jump_client.SITES)
DATA_URL = "https://fan.jump.com/graphql"
# the hosts a game's page needs to show its seats: the teams' own sites and the platform's; analytics,
# ads and everything else are not loaded
PAGE_HOSTS = frozenset({urlsplit(site).hostname for site in jump_client.SITES.values()}
                       | {"fan.jump.com", "cdn.orgs.jump.com", "cdn.media.jump.com"})
SKIPPED_RESOURCES = frozenset({"image", "font", "media"})
PAGE_TIMEOUT_MS = 45_000
MARKETS = {"PRIMARY": "primary", "SECONDARY": "resale"}
# org -> (fee, tax), each as a share of the price before fees and tax. The site shows only the all-in total
# on a listing; the split appears in the cart, which this worker never opens (a cart holds seats). So the
# price, the fee and the tax are worked out from the total: all-in = price x (1 + fee + tax).
#   fee 20%: operator 2026-11-23, "derive it, 20% fee holds".
#   tax 12.025%: the operator's cart of 2026-11-23 (2 x 42.00 = 84.00, fees 16.80, estimated taxes 10.10,
#   total 110.90). One observation: if the rate changes, the all-in total stays right and the split drifts.
# A team not listed here (the Lynx: its fee is not confirmed) gets the all-in total and no split.
PRICING = {"timberwolves": (0.20, 0.12025)}


class BrowserPollError(RuntimeError):
    pass


def _is(response: Any, operation: str) -> bool:
    """Is this the page's own answer for `operation` from the site's data service?"""
    return (response.url.startswith(DATA_URL)
            and f'"operationName":"{operation}"' in (response.request.post_data or ""))


def order_limits(offer: Any) -> tuple[int | None, int | None]:
    """(fewest, most) tickets one order may hold, from the page's offer answer; (None, None) when the
    page did not carry them."""
    try:
        group = offer["data"]["offerById"]["eventGroup"][0]
    except (KeyError, IndexError, TypeError):
        return None, None
    return group.get("qtyMin"), group.get("qtyMax")


def default_price_type(offer: Any) -> str | None:
    """The id of the offer's default price type ("Individual"), from the page's offer answer."""
    try:
        types = offer["data"]["offerById"]["eventGroup"][0]["priceTypes"]
    except (KeyError, IndexError, TypeError):
        return None
    for kind in types or []:
        if kind.get("isDefault"):
            return kind.get("priceTypeId")
    return None


def all_in_price(block: dict, price_type: str | None = None) -> float | None:
    """What a buyer pays for one ticket of this block, fees and tax included. The team's own seats carry it
    to the cent, per price type (55.45); every block carries the figure the page shows, to the dollar (55)."""
    exact = [p for p in block.get("pricesByType") or [] if isinstance(p.get("amount"), (int, float))]
    chosen = [p for p in exact if p.get("priceTypeId") == price_type] or exact
    if chosen:
        return chosen[0]["amount"] / 100
    shown = (block.get("price") or {}).get("amount")
    return shown / 100 if isinstance(shown, (int, float)) else None


def split_all_in(paid: float, rates: tuple[float, float]) -> tuple[float, float, float]:
    """(price, fee, tax) per ticket from the all-in total: price + fee + tax is exactly the total."""
    fee_rate, tax_rate = rates
    price = round(paid / (1 + fee_rate + tax_rate), 2)
    fee = round(price * fee_rate, 2)
    return price, fee, round(paid - price - fee, 2)


def parse_listings(inventory: Any, order_max: int | None = None, rates: tuple[float, float] | None = None,
                   price_type: str | None = None) -> list[dict]:
    """The page's seat blocks as the database takes them. With `rates`, the all-in total is split into
    price, fee and tax (marked estimated). Raises when the answer is not an inventory."""
    try:
        blocks = inventory["data"]["getBlocks"]["blocks"]
    except (KeyError, TypeError) as exc:
        raise BrowserPollError("the page's answer carries no seat blocks") from exc
    if not isinstance(blocks, list):
        raise BrowserPollError("the page's answer carries no seat blocks")
    out = []
    for block in blocks:
        where = block.get("location") or {}
        seats = [str(seat) for seat in where.get("seats") or []]
        allowed = block.get("quantities") or []
        most = max(allowed) if allowed else None
        if most is not None and order_max:
            most = min(most, order_max)
        paid = all_in_price(block, price_type)
        price, fee, tax = split_all_in(paid, rates) if rates and paid is not None else (None, None, None)
        out.append({
            "id": block["id"], "market": MARKETS.get(block.get("market")),
            "area": where.get("neighborhood"), "section": where.get("section"), "row": where.get("row"),
            "seat_low": seats[0] if seats else None, "seat_high": seats[-1] if seats else None,
            "seats": seats or None, "qty": len(seats) or None,
            "allowed_quantities": allowed, "max_per_order": most,
            "price": price, "fee": fee, "tax": tax, "all_in": paid, "order_fee": None,
            "price_includes_tax": False if price is not None else None, "price_estimated": price is not None,
            "ticket_type": (block.get("price") or {}).get("priceTypeName"), "delivery": None,
            "ada": block.get("hasAda"), "obstructed": bool(block.get("hasObstructedView")),
            "aisle": block.get("hasAisle"), "ga": block.get("isGA"),
        })
    return out


def allow(route: Any) -> None:
    """Load only what a game's page needs: its own hosts, and no images, fonts or video."""
    request = route.request
    if urlsplit(request.url).hostname in PAGE_HOSTS and request.resource_type not in SKIPPED_RESOURCES:
        route.continue_()
    else:
        route.abort()


def page_reader(context: Any, timeout_ms: int = PAGE_TIMEOUT_MS) -> Callable[[dict], dict]:
    """`read(event)`: open the game's public page and return what the page itself received:
    {"inventory": ..., "offer": ... or None}. A page that does not get its inventory in time raises."""
    def read(event: dict) -> dict:
        page = context.new_page()
        offers: list = []

        def keep(response: Any) -> None:
            if _is(response, "OfferById"):
                offers.append(response)

        page.on("response", keep)
        try:
            with page.expect_response(lambda r: _is(r, "getInventoryDetails"), timeout=timeout_ms) as got:
                page.goto(event["url"], wait_until="domcontentloaded", timeout=timeout_ms)
            return {"inventory": got.value.json(), "offer": offers[0].json() if offers else None}
        finally:
            page.close()
    return read


def run(rpc: primary_poll_sync.Rpc, jump: Any, read_page: Callable[[dict], dict], org: str = ORGS[0]) -> dict:
    """One run over one team's games; returns what it did."""
    def listings(event: dict) -> list[dict]:
        got = read_page(event)
        fewest, most = order_limits(got.get("offer"))
        event["order_min"], event["order_max"] = fewest, most
        return parse_listings(got["inventory"], most, PRICING.get(org), default_price_type(got.get("offer")))

    return primary_poll_sync.poll_source(rpc, org, lambda: jump.events(org), listings)


def cycle(rpc: primary_poll_sync.Rpc, jump: Any, playwright: Any, orgs: tuple[str, ...] = ORGS) -> dict:
    """One run over every team, with a browser of its own, closed at the end whatever happens."""
    browser = playwright.chromium.launch()
    try:
        context = browser.new_context(user_agent=jump.USER_AGENT, viewport={"width": 1400, "height": 900})
        context.route("**/*", allow)
        read_page = page_reader(context)
        return {org: run(rpc, jump, read_page, org) for org in orgs}
    finally:
        browser.close()


def main(env: Any = None, sleep: Callable[[float], None] = time.sleep) -> None:
    """The service's loop. Returns at once unless PRIMARY_POLL_BROWSER_LIVE=1 and the database is
    configured; a run that fails is logged and the next one starts on time."""
    env = os.environ if env is None else env
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    url, key = env.get("SUPABASE_URL"), env.get("SUPABASE_SERVICE_ROLE_KEY")
    if env.get("PRIMARY_POLL_BROWSER_LIVE") != "1" or not (url and key):
        log.warning("disabled (PRIMARY_POLL_BROWSER_LIVE != 1, or the database is not configured)")
        return
    from playwright.sync_api import sync_playwright

    from core import n2s_autobuy_live
    from core.db import make_supabase_client

    db = make_supabase_client(url, key)
    # an event sent twice is stored once (its listings are replaced), so a dropped connection is retried
    rpc = n2s_autobuy_live.retrying(lambda name, params: db.rpc(name, params).execute().data)
    interval = float(env.get("PRIMARY_POLL_INTERVAL_SECONDS", "600"))
    log.warning("started (every %ss)", interval)
    while True:
        started = time.monotonic()
        try:
            with sync_playwright() as playwright:
                log.warning("run: %s", cycle(rpc, jump_client, playwright))
        except Exception as exc:  # noqa: BLE001 - never let the loop die; a missed run withholds the listings by their age
            log.warning("run failed: %s: %s", type(exc).__name__, exc)
        sleep(max(0.0, interval - (time.monotonic() - started)))


if __name__ == "__main__":
    main()
