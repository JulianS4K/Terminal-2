"""AXS events and SeatGeek-primary events, served inside the sub finder API next to the Ticketmaster feed.

Operator 2026-11-22: "Also push out axs and SeatGeek primary in API and announce in news".

    GET /api/v1/subs/axs/events        every live upcoming AXS event we hold, by default only the ones AXS
                                       itself sells (view v_axs_events_feed)
    GET /api/v1/subs/seatgeek/events   the upcoming events where SeatGeek is the primary ticketer
                                       (view v_seatgeek_primary_feed)

Both take:
        ?date_from=2026-11-22&date_to=2026-12-31
        &state=NY                the venue's state code
        &mapped=true|false       matched to an EVO event or not
        &q=cowboys arlington     a search: every word must be in the name, performers, venue or city
        &since=2026-11-22T00:00:00Z   rows first seen, or matched, at or after this time
        &format=json|csv         (default json)
        &limit=1000&offset=0     (limit max 5000)
/axs/events also takes  &primary=false   the events AXS lists and another ticketer sells (default true)

Names, dates, venues, status and the ticket page. No prices and no inventory. The views are mig
20261122031530. This module only answers the query: it reads our own tables and makes no upstream
call (RULE 2).
"""
from __future__ import annotations

from typing import Any

from routers import feed_xmap
from routers.mlb_feed import _bool, _date, _err, _paging, _since
from routers.tm_feed import _STATE, _answer, _words

AXS_VIEW = "v_axs_events_feed"
SEATGEEK_VIEW = "v_seatgeek_primary_feed"
SEARCH_COLUMN = "search_text"          # lower case, accents removed; filtered on, never returned
AXS_COLUMNS = ("axs_event_id", "name", "headliner", "performers", "tour_title", "category", "genre", "status",
               "event_date", "start_local_time", "start_utc", "timezone", "time_tba", "axs_venue_id", "venue_name",
               "venue_city", "venue_state", "venue_country", "announce_utc", "onsale_utc", "presale_utc",
               "ticket_url", "ticketer", "axs_primary", "tevo_event_id", "tevo_event_name", "tevo_match_method",
               "terminal_path", "first_seen_at", "last_seen_at", "changed_at")
SEATGEEK_COLUMNS = ("sg_event_id", "name", "category", "status", "event_date", "start_local_time", "start_utc",
                    "time_tba", "performers", "sg_venue_id", "venue_name", "venue_city", "venue_state",
                    "venue_country", "ticket_url", "seatgeek_open_id", "seatgeek_primary", "tevo_event_id",
                    "tevo_event_name", "tevo_match_method", "terminal_path", "first_seen_at", "last_seen_at",
                    "changed_at")
# the same event's id on the other marketplaces, on every row (routers/feed_xmap.py)
AXS_MARKET_IDS = feed_xmap.columns("axs_event_id")
SEATGEEK_MARKET_IDS = feed_xmap.columns("seatgeek_event_id")


def _params(q: Any) -> dict:
    """The filters both feeds share, checked. Raises ValueError naming the bad parameter."""
    state = (q.get("state") or "").strip().upper()
    if state and not _STATE.match(state):
        raise ValueError("state")
    fmt = (q.get("format") or "json").strip().lower()
    if fmt not in ("json", "csv"):
        raise ValueError("format")
    limit, offset = _paging(q)
    return {"state": state, "fmt": fmt, "limit": limit, "offset": offset, "mapped": _bool(q.get("mapped")),
            "date_from": _date(q.get("date_from")), "date_to": _date(q.get("date_to")),
            "since": _since(q.get("since")), "words": _words(q.get("q"))}


def _filtered(sel: Any, f: dict) -> Any:
    if f["date_from"]:
        sel = sel.gte("event_date", f["date_from"])
    if f["date_to"]:
        sel = sel.lte("event_date", f["date_to"])
    if f["state"]:
        sel = sel.eq("venue_state", f["state"])
    if f["since"]:
        sel = sel.gte("changed_at", f["since"])
    if f["mapped"] is True:
        sel = sel.not_.is_("tevo_event_id", "null")
    elif f["mapped"] is False:
        sel = sel.is_("tevo_event_id", "null")
    for word in f["words"]:
        sel = sel.ilike(SEARCH_COLUMN, f"%{word}%")
    return sel


def axs_response(db: Any, params: Any) -> Any:
    """GET /axs/events: a dict (JSON), a CSV Response, or a JSONResponse error."""
    try:
        f = _params(params)
        primary = _bool(params.get("primary"))
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")
    sel = _filtered(db.table(AXS_VIEW).select(",".join(AXS_COLUMNS)), f)
    sel = sel.eq("axs_primary", primary is not False)      # AXS itself sells it, unless primary=false
    return _answer(sel, f, AXS_COLUMNS, "events", "axs_events.csv", id_column="axs_event_id",
                   xmap=(db, "axs", AXS_MARKET_IDS))


def seatgeek_response(db: Any, params: Any) -> Any:
    """GET /seatgeek/events: the events SeatGeek tickets as the primary seller."""
    try:
        f = _params(params)
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")
    sel = _filtered(db.table(SEATGEEK_VIEW).select(",".join(SEATGEEK_COLUMNS)), f)
    return _answer(sel, f, SEATGEEK_COLUMNS, "events", "seatgeek_events.csv", id_column="sg_event_id",
                   xmap=(db, "seatgeek", SEATGEEK_MARKET_IDS))
