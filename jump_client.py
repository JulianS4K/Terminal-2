"""Team ticket sites on the Jump platform (read-only).

The Minnesota Timberwolves sell their own tickets at tickets.timberwolves.com, a site built on
Jump (jump.com). Its home page carries every upcoming home game and the game's public
single-game offer inside the HTML, so this module reads that one page:

  events(org)       every upcoming game: id, name, start, venue, the public offer's id, how many
                    seats the team says are available and the price range

  listings(org, e)  NOT READ HERE. The seat-level inventory (section, row, seats, primary or
                    resale, price) is not in any page: the site's own script asks for it with a
                    POST to fan.jump.com/graphql. This module is GET only and stays so: it raises
                    JumpInventoryNotEnabled. The listings are read by the browser worker instead
                    (core/primary_poll_browser.py, operator 2026-11-23), which opens the game's
                    public page and keeps what the page itself receives. A worker that polls the
                    Timberwolves through this module alone records a failed poll, and the feed
                    sends no listings for the game.

The site answers 403 to a client that does not name a browser, so the request carries a desktop
browser's User-Agent (operator 2026-11-23, told of the filter: "poll all the games for si and
timberwolves every 10 mins"). No key, no login, no cookie. Nothing is ever written to the site
(RULE 2): no cart, no hold, no order.
"""
from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

import requests

from core.readonly_guard import build_readonly_guard

# RULE 2 — READ-ONLY. GETs of public pages; any other method raises before a network call.
# Paired with the static check in scripts/check_readonly.py and tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class JumpError(RuntimeError):
    pass


class JumpReadOnlyError(JumpError):
    """Raised when a non-GET method is attempted against a Jump ticket site."""


class JumpInventoryNotEnabled(JumpError):
    """The seat-level inventory needs a read the operator has not authorized yet."""


# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    JumpReadOnlyError, ALLOWED_HTTP_METHODS,
    "Reading public pages only — never a cart, hold or order on a team's ticket site.",
)

# org -> its ticket site. The Lynx (operator 2026-11-23: "ping and map lynx when schedule releases") list
# no games until the WNBA schedule is out: events("lynx") raises until then, and nothing is stored.
SITES = {"timberwolves": "https://tickets.timberwolves.com", "lynx": "https://tickets.lynxbasketball.com"}
USER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
              "Chrome/126.0 Safari/537.36")
TIMEOUT_S = 30
_CHUNK = re.compile(r'self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)')
_DECODER = json.JSONDecoder()
_ROW = re.compile(r"^([0-9a-f]+):", re.MULTILINE)
MAX_POINTER_DEPTH = 4


def _get(org: str, path: str) -> str:
    _assert_readonly_method("GET")
    if org not in SITES:
        raise JumpError("not a known ticket site")
    resp = requests.get(SITES[org] + path, headers={"User-Agent": USER_AGENT, "Accept": "text/html"},
                        timeout=TIMEOUT_S)
    if resp.status_code != 200:
        raise JumpError(f"HTTP {resp.status_code} for {path}")
    return resp.text


def page_data(html: str) -> str:
    """The data the page streams to its own script, joined into one text."""
    try:
        return "".join(json.loads(chunk) for chunk in _CHUNK.findall(html))
    except ValueError as exc:
        raise JumpError("the page's data could not be read") from exc


def _rows(text: str) -> dict[str, Any]:
    """The page's data is a list of rows, `3a:<JSON>`; a value written once is pointed to from
    elsewhere as `$3a:props:eventList:0:venue`. This is every row that is JSON, by its label."""
    rows: dict[str, Any] = {}
    for mark in _ROW.finditer(text):
        try:
            value, _ = _DECODER.raw_decode(text, mark.end())
        except ValueError:
            continue                                   # a row that is not JSON (a script or a style sheet)
        rows.setdefault(mark.group(1), value)
    return rows


def _follow(rows: dict[str, Any], pointer: str) -> Any:
    """What a pointer leads to: the row it names, then down its path. None when it leads nowhere."""
    label, *path = pointer[1:].split(":")
    at = rows.get(label)
    for step in path:
        if isinstance(at, list) and step == "props" and len(at) > 3 and at[0] == "$":
            at = at[3]                                 # a page element is ["$", type, key, props]
        elif isinstance(at, list) and step.isdigit() and int(step) < len(at):
            at = at[int(step)]
        elif isinstance(at, dict):
            at = at.get(step)
        else:
            return None
    return at


def _resolved(rows: dict[str, Any], value: Any, depth: int = 0) -> Any:
    """`value` with its pointers followed, a few levels down; a pointer that leads nowhere is None."""
    if isinstance(value, str) and value.startswith("$"):
        return _resolved(rows, _follow(rows, value), depth + 1) if depth < MAX_POINTER_DEPTH else None
    if isinstance(value, dict) and depth < MAX_POINTER_DEPTH:
        return {k: _resolved(rows, v, depth + 1) for k, v in value.items()}
    return value


def _objects(text: str, typename: str, rows: dict[str, Any]) -> dict[str, dict]:
    """Every object of one type in the page's data, by id, pointers followed; the fullest copy wins
    and the others fill what it lacks (the page repeats an object with fewer fields where it is only
    referred to)."""
    found: dict[str, dict] = {}
    for at in re.finditer(r'\{"__typename":"%s"' % re.escape(typename), text):
        try:
            obj, _ = _DECODER.raw_decode(text[at.start():])
        except ValueError:
            continue
        key = obj.get("id")
        if not key:
            continue
        obj = {k: v for k, v in _resolved(rows, obj).items() if v is not None}
        held = found.get(key)
        if held is None:
            found[key] = obj
        else:
            full, part = (obj, held) if len(obj) >= len(held) else (held, obj)
            found[key] = {**part, **full}
    return found


def _dollars(price: Any) -> float | None:
    if isinstance(price, dict) and isinstance(price.get("amount"), (int, float)):
        return price["amount"] / 100
    return None


def parse_events(text: str, org: str) -> list[dict]:
    """The games in the home page's data, soonest first, each with its public offer."""
    rows = _rows(text)
    offers = _objects(text, "Offer", rows)
    out = []
    for ev in _objects(text, "Event", rows).values():
        offer_id = ev.get("defaultOfferId")
        if not offer_id or not ev.get("name") or not ev.get("eventStart"):
            continue
        offer = offers.get(offer_id) or ev.get("defaultOffer")
        offer = offer if isinstance(offer, dict) else {}
        venue = ev.get("venue") if isinstance(ev.get("venue"), dict) else {}
        address = venue.get("address") if isinstance(venue.get("address"), dict) else {}
        start = datetime.fromisoformat(ev["eventStart"].replace("Z", "+00:00"))
        zone = venue.get("timezone")
        try:
            local = start.astimezone(ZoneInfo(zone)) if zone else None
        except (KeyError, ValueError):
            local = None
        out.append({
            "id": str(ev["id"]), "name": ev["name"],
            "local_date": local.strftime("%Y-%m-%d") if local else None,
            "local_time": local.strftime("%H:%M") if local else None,
            "start_utc": start.isoformat(), "timezone": zone,
            "venue": venue.get("name"), "city": address.get("city"), "state": address.get("state"),
            "url": f"{SITES[org]}/offers/{offer_id}",
            "offer_id": str(offer_id), "order_min": offer.get("qtyMin"), "order_max": offer.get("qtyMax"),
            "total_available": offer.get("totalAvailable"),
            "price_min": _dollars(offer.get("fromPrice")), "price_max": _dollars(offer.get("toPrice")),
        })
    return sorted(out, key=lambda e: (e["start_utc"], e["id"]))


def events(org: str = "timberwolves") -> list[dict]:
    found = parse_events(page_data(_get(org, "/")), org)
    if not found:
        raise JumpError("the home page lists no games")
    return found


def listings(org: str, event: dict) -> list[dict]:
    """Not read yet: see the module's note. Always raises JumpInventoryNotEnabled."""
    raise JumpInventoryNotEnabled("seat inventory is read by the browser worker, not by this client")
