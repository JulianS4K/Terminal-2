"""Indianapolis Motor Speedway section prices for the Indy 500 (read-only).

The speedway sells the Indy 500 itself, on its own site (indianapolismotorspeedway.com). Its seat map
asks a data service that answers a visitor's browser with 401, so seat blocks and ticket counts are
NOT readable and this module does not go near that service. What the site does publish, as plain
HTML, is a price list: one row a seating area with the price in each sales window, or SOLD OUT, and
a second page with the general admission prices. This module reads those two pages and nothing else:

  events()          the Indy 500 race day: its name and date, from the price page
  listings(event)   one row a seating area on sale at today's price (two rows, lowest and highest,
                    where the page gives a range), plus general admission. A sold-out area has no row.

These rows are SECTION PRICES, not seat blocks: no quantity, no row, no seats, and the price is the
listed one (what checkout adds is not on the page, so fee, tax and all-in are empty).

Operator 2026-11-24: "build the indy 500 section price poller and show me listings". No key, no
login, no cookie. Nothing is ever written to the speedway's site (RULE 2): no cart, no hold, no order.
"""
from __future__ import annotations

import html as html_lib
import re
import time
from datetime import date, datetime
from zoneinfo import ZoneInfo

import requests

from core.readonly_guard import build_readonly_guard

# RULE 2 — READ-ONLY. GETs of public pages; any other method raises before a network call.
# Paired with the static check in scripts/check_readonly.py and tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class ImsError(RuntimeError):
    pass


class ImsReadOnlyError(ImsError):
    """Raised when a non-GET method is attempted against the speedway's site."""


# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    ImsReadOnlyError, ALLOWED_HTTP_METHODS,
    "Reading public pages only — never a cart, hold or order on indianapolismotorspeedway.com.",
)

BASE = "https://www.indianapolismotorspeedway.com"
PRICES_PATH = "/events/indy500/buy-tickets/ticket-prices"
GA_PATH = "/events/indy500/buy-tickets/ticket-prices-general-admission"
TICKETS_PATH = "/events/indy500/buy-tickets/tickets-race-day"
EVENT_SLUG = "indy500"
TIMEZONE = "America/Indiana/Indianapolis"
VENUE, CITY, STATE = "Indianapolis Motor Speedway", "Indianapolis", "IN"
USER_AGENT = "S4K-primary-poll/1.0"
TIMEOUT_S = 30
# The worker lists a source's events at every wake (10 minutes) and reads listings when an event is due
# (hourly this far out). The price list changes a few times a season, so the list of events is answered
# from the last page read for up to LIST_TTL_S, and a read of listings reuses a page FRESH_S old at most.
LIST_TTL_S = 3000
FRESH_S = 120
_page: dict = {"at": None, "html": None}

MONTHS = {m: i for i, m in enumerate(
    ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"), start=1)}
_TABLE = re.compile(r"<table\b.*?</table>", re.DOTALL | re.IGNORECASE)
_ROW = re.compile(r"<tr\b.*?</tr>", re.DOTALL | re.IGNORECASE)
_CELL = re.compile(r"<t[dh]\b.*?</t[dh]>", re.DOTALL | re.IGNORECASE)
_TAG = re.compile(r"<[^>]+>")
# the site's menu: <b>Indianapolis 500 presented by Gainbridge</b></span> <span class="meta">May 18-30, 2027 | ...
_EVENT = re.compile(r"<b>\s*(Indianapolis 500[^<]*?)\s*</b>\s*</span>\s*<span class=\"meta\">\s*"
                    r"([A-Za-z]+)\.?\s+(\d{1,2})(?:\s*-\s*(\d{1,2}))?,\s*(\d{4})", re.IGNORECASE)
_WINDOW = re.compile(r"^([A-Za-z]+)\.?\s+(\d{1,2})\s*-\s*([A-Za-z]+)\.?\s+(\d{1,2})$")
_MONEY = re.compile(r"\$\s*(\d[\d,]*(?:\.\d{1,2})?)")
_SOLD_OUT = re.compile(r"^sold\s*out$", re.IGNORECASE)
_SLUG = re.compile(r"[^a-z0-9]+")


def _get(path: str) -> str:
    _assert_readonly_method("GET")
    resp = requests.get(BASE + path, headers={"User-Agent": USER_AGENT, "Accept": "text/html"}, timeout=TIMEOUT_S)
    if resp.status_code != 200:
        raise ImsError(f"HTTP {resp.status_code} for {path}")
    return resp.text


def _prices_page(max_age_s: float) -> str:
    """The price page: the one read last when it is `max_age_s` old at most, else a new read."""
    now = time.monotonic()
    if _page["html"] is None or now - _page["at"] > max_age_s:
        _page.update(html=_get(PRICES_PATH), at=now)
    return _page["html"]


def _text(cell: str) -> str:
    return re.sub(r"\s+", " ", html_lib.unescape(_TAG.sub(" ", cell)).replace("\xa0", " ")).strip()


def table_rows(html: str) -> list[list[str]]:
    """The cells of every row of the page's first table, as text."""
    found = _TABLE.search(html or "")
    if not found:
        raise ImsError("the page carries no price table")
    return [[_text(c) for c in _CELL.findall(row)] for row in _ROW.findall(found.group(0))]


def _day(year: int, month: str, day: str) -> date:
    number = MONTHS.get(month[:3].lower())
    if not number:
        raise ImsError(f"not a month: {month}")
    try:
        return date(year, number, int(day))
    except ValueError as exc:
        raise ImsError(f"not a date: {month} {day}, {year}") from exc


def parse_event(html: str) -> dict:
    """The Indy 500's name and race day, from the site's menu (its last day is the race)."""
    found = _EVENT.search(html or "")
    if not found:
        raise ImsError("the page does not name the Indy 500 and its dates")
    name, month, first, last, year = found.groups()
    return {"name": name, "date": _day(int(year), month, last or first)}


def parse_windows(header: list[str], race_day: date) -> list[tuple[date, date]]:
    """The sales windows of the price table's header ("Oct. 28 - Jan. 3", ...), as dates. The page
    gives no year: the last window ends on race day, and each date before is the latest one that does
    not come after the date that follows it."""
    spans = [_WINDOW.match(cell) for cell in header[2:]]
    if not spans or not all(spans):
        raise ImsError("the price table's sales windows could not be read")
    days = [pair for s in spans for pair in ((s.group(1), s.group(2)), (s.group(3), s.group(4)))]
    limit, dated = race_day, []
    for month, day in reversed(days):
        at = _day(limit.year, month, day)
        if at > limit:
            at = _day(limit.year - 1, month, day)
        dated.append(at)
        limit = at
    dated.reverse()
    if dated[-1] != race_day:
        raise ImsError("the price table does not end on race day")
    return list(zip(dated[0::2], dated[1::2]))


def parse_price(cell: str) -> tuple[float, float] | None:
    """A price cell: (lowest, highest), or None when the area is sold out. Anything else is an error:
    a cell we cannot read must fail the poll, not pass for sold out."""
    amounts = [float(a.replace(",", "")) for a in _MONEY.findall(cell)]
    if amounts:
        return min(amounts), max(amounts)
    if _SOLD_OUT.match(cell.strip()):
        return None
    raise ImsError(f"not a price: {cell[:40]}")


def parse_prices(html: str, race_day: date, today: date) -> list[dict]:
    """The seating areas on sale today: {"section", "low", "high"}. A sold-out area is left out."""
    rows = table_rows(html)
    if not rows or len(rows[0]) < 3:
        raise ImsError("the price table has no sales windows")
    windows = parse_windows(rows[0], race_day)
    current = next((i for i, (_, end) in enumerate(windows) if today <= end), None)
    if current is None:
        raise ImsError("the sales windows of the price table are over")
    out = []
    for cells in rows[1:]:
        if len(cells) != len(rows[0]) or not cells[0]:
            raise ImsError("a row of the price table could not be read")
        price = parse_price(cells[2 + current])
        if price:
            out.append({"section": cells[0], "low": price[0], "high": price[1]})
    return out


def parse_general_admission(html: str, race_day: date, today: date) -> float | None:
    """Race day's general admission price: the "Event Day" one on race day, the current one before.
    None when the page lists none for race day (sold out)."""
    rows = table_rows(html)
    column = 2 if today >= race_day else 1
    inside = False
    for cells in rows:
        if len(cells) == 1:                                   # a heading: "Indy 500 Race Day - Sunday, May 30"
            if inside:
                break
            inside = bool(re.search(r"race day", cells[0], re.IGNORECASE))
        elif inside and cells[0].lower() == "general admission":
            if len(cells) <= column:
                raise ImsError("the general admission row could not be read")
            price = parse_price(cells[column])
            return price[0] if price else None
    if not inside:
        raise ImsError("the general admission page has no race day")
    return None


def _today() -> date:
    return datetime.now(ZoneInfo(TIMEZONE)).date()


def _listing(listing_id: str, section: str, price: float, kind: str, ga: bool) -> dict:
    return {
        "id": listing_id, "market": "primary", "area": None, "section": section, "row": None,
        "seat_low": None, "seat_high": None, "seats": None,
        "qty": None, "allowed_quantities": None, "max_per_order": None,
        "price": price, "fee": None, "tax": None, "all_in": None, "order_fee": None,
        "price_includes_tax": None, "price_estimated": False,
        "ticket_type": kind, "delivery": None, "ada": None, "obstructed": False, "aisle": None, "ga": ga,
    }


def events() -> list[dict]:
    found = parse_event(_prices_page(LIST_TTL_S))
    return [{
        "id": f"{EVENT_SLUG}-{found['date'].year}", "name": found["name"],
        "local_date": found["date"].isoformat(), "local_time": None, "start_utc": None, "timezone": None,
        "venue": VENUE, "city": CITY, "state": STATE, "url": BASE + TICKETS_PATH,
        "offer_id": None, "order_min": None, "order_max": None,
        "total_available": None, "price_min": None, "price_max": None,
    }]


def listings(event: dict, today: date | None = None) -> list[dict]:
    """The section prices of `events()`'s event, today. Fills the event's price_min and price_max."""
    today = today or _today()
    race_day = date.fromisoformat(event["local_date"])
    out = []
    for area in parse_prices(_prices_page(FRESH_S), race_day, today):
        slug = _SLUG.sub("-", area["section"].lower()).strip("-")
        if area["low"] == area["high"]:
            out.append(_listing(slug, area["section"], area["low"], "Reserved seat: section price", False))
        else:
            out.append(_listing(f"{slug}:from", area["section"], area["low"],
                                "Reserved seat: lowest price in the section", False))
            out.append(_listing(f"{slug}:to", area["section"], area["high"],
                                "Reserved seat: highest price in the section", False))
    general = parse_general_admission(_get(GA_PATH), race_day, today)
    if general is not None:
        out.append(_listing("general-admission", "General Admission", general, "General admission", True))
    prices = [row["price"] for row in out]
    event["price_min"], event["price_max"] = (min(prices), max(prices)) if prices else (None, None)
    return out
