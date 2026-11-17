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
import re
from datetime import date, datetime
from typing import Any

from fastapi.responses import JSONResponse, Response

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
           "level", "league_name", "parent_org")
_ABBREV = re.compile(r"^[A-Za-z]{2,3}$")


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


def schedule_response(db: Any, params: Any) -> Any:
    """The feed for one request: a dict (JSON), a CSV Response, or a JSONResponse error.
    `params` is the request's query parameters (a mapping)."""
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
        level = (q.get("level") or DEFAULT_LEVEL).strip().lower()
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
    try:
        rows = (sel.order("game_date").order("start_utc").order("mlb_schedule_id")
                .range(offset, offset + limit - 1).execute().data) or []
    except Exception as exc:  # noqa: BLE001 - surfaced as a 502 with the class only
        return _err(502, "upstream_error", type(exc).__name__)

    if fmt == "csv":
        buf = io.StringIO()
        w = csv.DictWriter(buf, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
        return Response(buf.getvalue(), media_type="text/csv",
                        headers={"Content-Disposition": "attachment; filename=mlb_schedule.csv"})
    nxt = offset + limit if len(rows) == limit else None
    return {"count": len(rows), "offset": offset, "next_offset": nxt, "games": rows}
