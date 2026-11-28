"""MLB schedule feed — served inside the sub finder API as GET /api/v1/subs/mlb/schedule.

Every MLB club's games — and, on request, every Triple-A to Single-A club's (mig 20261116230000) — with
the club's direct ticket link, mapped to the EVO (Ticket Evolution) event
to the terminal's hub event, and to the SeatGeek event (direct match on teams + date). Read from `v_mlb_schedule_feed` (mig 20261116200000), which the
collector `mlb_ticket_tick()` keeps filled from MLB's own ticketing schedule (the feed behind
mlb.com/tickets): every club x season is re-read every 11 hours, so start times, links and date
changes appear within half a day of a club releasing them, and `changed_at` moves only when something
a reader uses changed.

    GET /api/v1/subs/mlb/schedule
        ?team=NYY            club abbreviation or MLB team id; home or away (default: all)
        &home_only=true      only that club's home games
        &season=2027
        &date_from=2027-04-01&date_to=2027-04-30
        &since=2026-11-16T00:00:00Z   rows whose data changed at or after this time (incremental sync)
        &with_tickets=true   only games with a direct ticket link
        &mapped=true         only games mapped to an EVO event
        &type=regular        regular | spring | exhibition | postseason
        &level=mlb           mlb (default) | aaa | aa | high_a | single_a | milb (all four) | all
        &format=json|csv     (default json)
        &limit=1000&offset=0 (limit max 5000)

`ticket_url` is only ever the seller's own page for that one game (Ticketmaster event page,
mlb.tickets.com with the game's pid or eventId, Glitnir with its event_id); mlb.com / milb.com pages that
forward to the seller are not served. Minor league abbreviations repeat (three clubs are COL, as is
Colorado): `team` by abbreviation matches every club using it within the level asked; use the team id
for one club.
`start_local` / `start_utc` are NULL while MLB lists the time as TBD.

The route lives in routers/subs_api.py (operator 2026-11-16: "send it inside the subfinder api to
crm"), behind that API's key check: any key allowed to find subs may read it, with its usual rate and
quota. This module only answers the query. Read-only: no upstream call (RULE 2).
"""
from __future__ import annotations

import csv
import io
import json
import re
from datetime import date, datetime
from typing import Any

from fastapi.responses import JSONResponse, Response

from routers import feed_xmap

VIEW = "v_mlb_schedule_feed"
MAX_LIMIT = 5000
DEFAULT_LIMIT = 1000
TYPES = {"regular": ["regular"], "spring": ["spring"], "exhibition": ["exhibition"],
         "postseason": ["wild_card", "division_series", "league_championship", "world_series"]}
MINORS = ["aaa", "aa", "high_a", "single_a"]
LEVELS = {"mlb": ["mlb"], **{lv: [lv] for lv in MINORS}, "milb": MINORS, "all": None}
DEFAULT_LEVEL = "mlb"   # existing readers asked for MLB only
COLUMNS = ("mlb_schedule_id", "mlb_game_id", "season", "game_type", "game_date", "start_local", "time_zone",
           "start_utc", "time_tbd", "doubleheader_game", "if_necessary", "status", "description",
           "home_team_id", "home_name", "home_abbrev", "away_team_id", "away_name", "away_abbrev",
           "venue_id", "venue_name", "venue_city", "venue_postal_code", "ticket_url", "on_sale_start_et",
           "tevo_event_id", "tevo_match_method", "tevo_start_local", "tevo_time_check",
           "aq_short_event_id", "sg_event_id", "sh_event_id", "vivid_event_id", "tm_event_id",
           "gotickets_event_id", "sg_url", "sg_match_method", "terminal_path", "changed_at", "last_seen_at",
           "level", "league_name", "parent_org", "removed", "promotions")
# the marketplace ids the view does not hold, read by EVO event id (routers/feed_xmap.py)
MARKET_IDS = ("tickpick_event_id", "axs_event_id")
_ABBREV = re.compile(r"^[A-Za-z]{2,3}$")

EVENT_VIEW = "v_mlb_stadium_events"
EVENT_COLUMNS = ("mlb_schedule_id", "season", "event_type", "title", "description", "event_date", "start_local",
                 "time_zone", "start_utc", "time_tbd", "multi_day", "home_team_id", "home_abbrev", "home_name",
                 "level", "venue_id", "venue_name", "venue_city", "venue_postal_code", "ticket_url",
                 "tevo_event_id", "tevo_match_method", "tevo_event_name", "terminal_path", "removed",
                 "changed_at", "last_seen_at")
EVENT_MARKET_IDS = feed_xmap.columns("xmap_tevo_event_id")   # found by the row's own EVO event id
CHANGES_VIEW = "v_mlb_ticket_changes"
CHANGE_COLUMNS = ("change_id", "entity", "mlb_schedule_id", "kind", "old_value", "new_value", "notable",
                  "detected_at", "season", "date", "home_abbrev", "away_abbrev", "home_team_id", "event_title",
                  "venue_name", "level", "ticket_url", "tevo_event_id")
CHANGE_KINDS = {"added", "link_live", "link_removed", "link_changed", "date_changed", "time_changed",
                "venue_changed", "status_changed", "on_sale_set", "on_sale_changed", "removed", "restored",
                "promo_added", "event_added", "event_moved", "event_removed"}


def _err(status: int, error: str, detail: str | None = None, **extra: Any) -> JSONResponse:
    return JSONResponse({"error": error, **({"detail": detail} if detail else {}), **extra}, status_code=status)


def _bool(v: str | None) -> bool | None:
    if v is None or v == "":
        return None
    s = v.strip().lower()
    if s in ("1", "true", "yes", "on"):
        return True
    if s in ("0", "false", "no", "off"):
        return False
    raise ValueError(v)


def _date(v: str | None) -> str | None:
    return date.fromisoformat(v).isoformat() if v else None


def _since(v: str | None) -> str | None:
    if not v:
        return None
    return datetime.fromisoformat(v.strip().replace("Z", "+00:00")).isoformat()


# the seller's own link says who sells a game: ProVenue (tickets.com) links are mlb.tickets.com or mpv.tickets.com
SELLER_URL = {"provenue": "https://m__.tickets.com%"}


def schedule_response(db: Any, params: Any, seller: str | None = None, default_level: str = DEFAULT_LEVEL) -> Any:
    """The feed for one request: a dict (JSON), a CSV Response, or a JSONResponse error.
    `params` is the request's query parameters (a mapping). `seller` pins the games to one seller by their
    ticket link (GET /provenue/events: ProVenue's games, mig 20261128100000); `default_level` is the level
    when the request names none."""
    q = params
    try:
        team = (q.get("team") or "").strip()
        if team and not (team.isdigit() or _ABBREV.match(team)):
            raise ValueError("team")
        home_only = _bool(q.get("home_only"))
        season = int(q["season"]) if q.get("season") else None
        date_from, date_to = _date(q.get("date_from")), _date(q.get("date_to"))
        since = _since(q.get("since"))
        with_tickets, mapped = _bool(q.get("with_tickets")), _bool(q.get("mapped"))
        gtype = (q.get("type") or "").strip().lower()
        if gtype and gtype not in TYPES:
            raise ValueError("type")
        level = (q.get("level") or default_level).strip().lower()
        if level not in LEVELS:
            raise ValueError("level")
        fmt = (q.get("format") or "json").strip().lower()
        if fmt not in ("json", "csv"):
            raise ValueError("format")
        limit = int(q.get("limit") or DEFAULT_LIMIT)
        offset = int(q.get("offset") or 0)
        if not 1 <= limit <= MAX_LIMIT or offset < 0:
            raise ValueError("limit")
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")

    sel = db.table(VIEW).select(",".join(COLUMNS))
    if team:
        col = "team_id" if team.isdigit() else "abbrev"
        val = team if team.isdigit() else team.upper()
        sel = sel.eq(f"home_{col}", val) if home_only else sel.or_(f"home_{col}.eq.{val},away_{col}.eq.{val}")
    if season is not None:
        sel = sel.eq("season", season)
    if date_from:
        sel = sel.gte("game_date", date_from)
    if date_to:
        sel = sel.lte("game_date", date_to)
    if since:
        sel = sel.gte("changed_at", since)
    if with_tickets:
        sel = sel.not_.is_("ticket_url", "null")
    if mapped:
        sel = sel.not_.is_("tevo_event_id", "null")
    if gtype:
        sel = sel.in_("game_type", TYPES[gtype])
    if LEVELS[level] is not None:
        sel = sel.in_("level", LEVELS[level])
    if seller:
        sel = sel.ilike("ticket_url", SELLER_URL[seller])
    try:
        rows = (sel.order("game_date").order("start_utc").order("mlb_schedule_id")
                .range(offset, offset + limit - 1).execute().data) or []
        rows = feed_xmap.add(db, rows, "tevo", "tevo_event_id", MARKET_IDS)
    except Exception as exc:  # noqa: BLE001 - surfaced as a 502 with the class only
        return _err(502, "upstream_error", type(exc).__name__)

    if fmt == "csv":
        return _csv(rows, COLUMNS + MARKET_IDS, "mlb_schedule.csv")
    nxt = offset + limit if len(rows) == limit else None
    return {"count": len(rows), "offset": offset, "next_offset": nxt, "games": rows}


def _csv(rows: list, columns: tuple, filename: str) -> Response:
    """CSV of `rows`; nested values (promotions) are written as JSON text."""
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=columns, extrasaction="ignore")
    w.writeheader()
    for r in rows:
        w.writerow({k: (json.dumps(v) if isinstance(v, (list, dict)) else v) for k, v in r.items()})
    return Response(buf.getvalue(), media_type="text/csv",
                    headers={"Content-Disposition": f"attachment; filename={filename}"})


def _paging(q: Any) -> tuple[int, int]:
    limit = int(q.get("limit") or DEFAULT_LIMIT)
    offset = int(q.get("offset") or 0)
    if not 1 <= limit <= MAX_LIMIT or offset < 0:
        raise ValueError("limit")
    return limit, offset


def _fmt(q: Any) -> str:
    fmt = (q.get("format") or "json").strip().lower()
    if fmt not in ("json", "csv"):
        raise ValueError("format")
    return fmt


def _team(q: Any) -> str:
    team = (q.get("team") or "").strip()
    if team and not (team.isdigit() or _ABBREV.match(team)):
        raise ValueError("team")
    return team


def _level(q: Any, default: str) -> str:
    level = (q.get("level") or default).strip().lower()
    if level not in LEVELS:
        raise ValueError("level")
    return level


def events_response(db: Any, params: Any) -> Any:
    """Concerts and other live events at the ballparks (mig 20261117060000): GET /api/v1/subs/mlb/events.
    Query: team (home club id or abbreviation), level (default all), date_from, date_to, since, mapped,
    format, limit, offset."""
    q = params
    try:
        team = _team(q)
        level = _level(q, "all")
        date_from, date_to = _date(q.get("date_from")), _date(q.get("date_to"))
        since = _since(q.get("since"))
        mapped = _bool(q.get("mapped"))
        fmt = _fmt(q)
        limit, offset = _paging(q)
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")

    sel = db.table(EVENT_VIEW).select(",".join(EVENT_COLUMNS))
    if team:
        sel = sel.eq("home_team_id", team) if team.isdigit() else sel.eq("home_abbrev", team.upper())
    if LEVELS[level] is not None:
        sel = sel.in_("level", LEVELS[level])
    if date_from:
        sel = sel.gte("event_date", date_from)
    if date_to:
        sel = sel.lte("event_date", date_to)
    if since:
        sel = sel.gte("changed_at", since)
    if mapped:
        sel = sel.not_.is_("tevo_event_id", "null")
    try:
        rows = (sel.order("event_date").order("start_utc").order("mlb_schedule_id")
                .range(offset, offset + limit - 1).execute().data) or []
        rows = feed_xmap.add(db, rows, "tevo", "tevo_event_id", EVENT_MARKET_IDS)
    except Exception as exc:  # noqa: BLE001 - surfaced as a 502 with the class only
        return _err(502, "upstream_error", type(exc).__name__)
    if fmt == "csv":
        return _csv(rows, EVENT_COLUMNS + EVENT_MARKET_IDS, "mlb_events.csv")
    nxt = offset + limit if len(rows) == limit else None
    return {"count": len(rows), "offset": offset, "next_offset": nxt, "events": rows}


def changes_response(db: Any, params: Any) -> Any:
    """Every change the poller detected (mig 20261117060000): GET /api/v1/subs/mlb/changes.
    Query: after_id (resume after the last change_id you read) or since (ISO instant), kind
    (comma list), entity (game | event | promotion), notable, team, level (default all), format, limit.
    Ordered by change_id; `next_after_id` is the cursor for the next page."""
    q = params
    try:
        after_id = int(q["after_id"]) if q.get("after_id") else None
        if after_id is not None and after_id < 0:
            raise ValueError("after_id")
        since = _since(q.get("since"))
        kinds = [k.strip().lower() for k in (q.get("kind") or "").split(",") if k.strip()]
        if any(k not in CHANGE_KINDS for k in kinds):
            raise ValueError("kind")
        entity = (q.get("entity") or "").strip().lower()
        if entity and entity not in ("game", "event", "promotion"):
            raise ValueError("entity")
        notable = _bool(q.get("notable"))
        team = _team(q)
        level = _level(q, "all")
        fmt = _fmt(q)
        limit, _ = _paging(q)
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")

    sel = db.table(CHANGES_VIEW).select(",".join(CHANGE_COLUMNS))
    if after_id is not None:
        sel = sel.gt("change_id", after_id)
    if since:
        sel = sel.gte("detected_at", since)
    if kinds:
        sel = sel.in_("kind", kinds)
    if entity:
        sel = sel.eq("entity", entity)
    if notable is not None:
        sel = sel.eq("notable", notable)
    if team:
        sel = sel.eq("home_team_id", team) if team.isdigit() else sel.eq("home_abbrev", team.upper())
    if LEVELS[level] is not None:
        sel = sel.in_("level", LEVELS[level])
    try:
        rows = sel.order("change_id").limit(limit).execute().data or []
    except Exception as exc:  # noqa: BLE001 - surfaced as a 502 with the class only
        return _err(502, "upstream_error", type(exc).__name__)
    if fmt == "csv":
        return _csv(rows, CHANGE_COLUMNS, "mlb_changes.csv")
    nxt = rows[-1]["change_id"] if len(rows) == limit else None
    return {"count": len(rows), "next_after_id": nxt, "changes": rows}
