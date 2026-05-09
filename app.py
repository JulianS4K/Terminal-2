"""Evo Terminal FastAPI app.

Auth: Google OAuth via Supabase, restricted to a configurable email domain.
Data: Reads TEvo creds from Supabase `settings` table (env var fallback).

Env vars required:
  SUPABASE_URL                 e.g. https://xxxx.supabase.co
  SUPABASE_SERVICE_ROLE_KEY    Dashboard > Settings > API > service_role
  SUPABASE_ANON_KEY            Dashboard > Settings > API > anon public
  CRON_SECRET                  shared with the collect Edge Function
Optional:
  ALLOWED_EMAIL_DOMAIN         default "s4kent.com"
  TEVO_SANDBOX                 "true" to hit sandbox API (default false)
  AUTH_DISABLED                "true" to bypass auth (local dev only)
"""

from __future__ import annotations

import os
import re
import sys
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
from fastapi import Body, Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import HTMLResponse, JSONResponse

from evo_client import EvoClient

# ---------- Bootstrap ----------

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
CRON_SECRET = os.environ.get("CRON_SECRET")
ALLOWED_EMAIL_DOMAIN = os.environ.get("ALLOWED_EMAIL_DOMAIN", "s4kent.com")
AUTH_DISABLED = os.environ.get("AUTH_DISABLED", "false").lower() == "true"

sb = None
if SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY:
    try:
        from supabase import create_client
        sb = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    except ImportError:
        print("WARNING: supabase package not installed. Run: pip install supabase")
    except Exception as e:
        print(f"WARNING: could not init Supabase client: {e}")


def require_sb():
    if sb is None:
        raise HTTPException(500, "Supabase not configured.")
    return sb


def resolve_tevo_creds():
    """Prefer Supabase settings table, fall back to env vars."""
    if sb is not None:
        try:
            res = (
                sb.table("settings")
                .select("key,value")
                .in_("key", ["tevo_token", "tevo_secret"])
                .execute()
            )
            by_key = {r["key"]: r["value"] for r in (res.data or [])}
            t = by_key.get("tevo_token")
            s = by_key.get("tevo_secret")
            if t and s:
                return t, s, "supabase.settings"
        except Exception as e:
            print(f"Could not load TEvo creds from settings: {e}")
    return os.environ.get("TEVO_TOKEN"), os.environ.get("TEVO_SECRET"), "env"


SANDBOX = os.environ.get("TEVO_SANDBOX", "false").lower() == "true"
TOKEN, SECRET, CREDS_SOURCE = resolve_tevo_creds()
if not TOKEN or not SECRET:
    sys.exit(
        "No TEvo credentials found. Insert into Supabase `settings` table "
        "(tevo_token, tevo_secret) or set TEVO_TOKEN + TEVO_SECRET env vars."
    )
print(f"TEvo creds loaded from: {CREDS_SOURCE}")
client = EvoClient(TOKEN, SECRET, sandbox=SANDBOX)


# ---------- Auth dependency ----------

def require_auth(authorization: str | None = Header(None)):
    """Validate a Supabase-issued JWT + enforce email domain.

    Browser sends 'Authorization: Bearer <jwt>' on every API call.
    We hit Supabase's /auth/v1/user to validate the token and get the user,
    then check the email ends in the allowed domain.
    """
    if AUTH_DISABLED:
        return None
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not SUPABASE_URL or not SUPABASE_ANON_KEY:
        raise HTTPException(500, "Supabase auth not configured on server")
    try:
        r = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers={"Authorization": f"Bearer {token}", "apikey": SUPABASE_ANON_KEY},
            timeout=5,
        )
    except Exception as e:
        raise HTTPException(502, f"auth check failed: {e}")
    if not r.ok:
        raise HTTPException(401, "invalid session")
    user = r.json()
    email = (user.get("email") or "").lower()
    if not email.endswith("@" + ALLOWED_EMAIL_DOMAIN.lower()):
        raise HTTPException(403, f"access restricted to @{ALLOWED_EMAIL_DOMAIN}")
    return user


# ---------- App setup ----------

STATIC_DIR = Path(__file__).parent / "static"
app = FastAPI(title="Evo Terminal")

# (SMS / WhatsApp / web bot moved to Supabase Edge Functions in v2.7:
#  supabase/functions/sms-bot, web-bot, chat. The legacy bot.py is unused.)


@app.exception_handler(RuntimeError)
async def _runtime_error_handler(request, exc: RuntimeError):
    return JSONResponse(status_code=502, content={"error": str(exc)})


# ---------- Public routes (no auth) ----------

@app.get("/", response_class=HTMLResponse)
def index():
    return (STATIC_DIR / "index.html").read_text(encoding="utf-8")


@app.get("/chat", response_class=HTMLResponse)
def chat_page():
    """Customer-facing retail chat. Bootstraps from /api/public/config to get
    the Supabase anon key, then POSTs to the chat Edge Function for replies."""
    return (STATIC_DIR / "chat.html").read_text(encoding="utf-8")


@app.get("/event/{event_id}", response_class=HTMLResponse)
def event_terminal_page(event_id: int):
    """Broker terminal — single event detail page (Bloomberg/Robinhood hybrid).
    The event_id is read by the JS via window.location.pathname."""
    return (STATIC_DIR / "event.html").read_text(encoding="utf-8")


@app.get("/movers", response_class=HTMLResponse)
def movers_page():
    """Top winners + losers report — across event/performer/venue, owned vs market."""
    return (STATIC_DIR / "movers.html").read_text(encoding="utf-8")


@app.get("/terminal/v1", response_class=HTMLResponse)
def terminal_v1_alias():
    """Backward-compat alias — terminal-v1 was promoted to `/` on 2026-05-08.
    Old bookmarks still resolve. Returns the same HTML as `/`."""
    return (STATIC_DIR / "index.html").read_text(encoding="utf-8")


@app.get("/legacy", response_class=HTMLResponse)
def index_legacy():
    """Pre-2026-05-08 terminal. Preserved here because it has features the new
    design hasn't reabsorbed yet: watchlist add/remove modal, configurations
    browse, snapshots/velocity views, run history. Reachable for power users
    until parity is restored."""
    return (STATIC_DIR / "legacy.html").read_text(encoding="utf-8")


@app.get("/api/public/config")
def public_config():
    """Browser-safe config for the login page. No secrets."""
    return {
        "supabase_url": SUPABASE_URL,
        "supabase_anon_key": SUPABASE_ANON_KEY,
        "allowed_email_domain": ALLOWED_EMAIL_DOMAIN,
    }

# ---------- Protected routes ----------

@app.get("/api/config")
def config_info(user=Depends(require_auth)):
    return {
        "supabase_configured": sb is not None,
        "collect_available": bool(sb is not None and CRON_SECRET and SUPABASE_URL),
        "env": "sandbox" if SANDBOX else "prod",
        "user_email": (user or {}).get("email"),
    }


@app.get("/api/events")
def events_search(
    q: str | None = None,
    performer_id: int | None = None,
    venue_id: int | None = None,
    occurs_at_gte: str | None = Query(None, alias="occurs_at.gte"),
    occurs_at_lte: str | None = Query(None, alias="occurs_at.lte"),
    only_with_available_tickets: bool = True,
    _=Depends(require_auth),
):
    events = client.search_events_all(
        q=q or None,
        performer_id=performer_id,
        venue_id=venue_id,
        occurs_at_gte=occurs_at_gte,
        occurs_at_lte=occurs_at_lte,
        only_with_available_tickets=only_with_available_tickets,
        order_by="events.popularity_score DESC",
    )
    return {"count": len(events), "events": events}


_PARKING_RE = re.compile(r"\b(parking|garage|valet|lot)\b", re.IGNORECASE)

def _is_event_seat(tg: dict) -> bool:
    """True if this ticket_group is a real event seat (not parking / suite /
    hospitality). TEvo's `type` field is the canonical signal — defaults to
    'event' for actual seats. As a backup, scan section/format strings for
    parking-style tokens."""
    t = (tg.get("type") or "event").lower()
    if t != "event":
        return False
    section = (tg.get("section") or "")
    if _PARKING_RE.search(section):
        return False
    fmt = (tg.get("format") or "").lower()
    if "parking" in fmt:
        return False
    return True


@app.get("/api/events/{event_id}")
def event_detail(event_id: int, include_ancillary: bool = False, _=Depends(require_auth)):
    """Event detail. By default filters out parking/suite/hospitality
    ticket_groups so the per-event view shows only real seats.
    Pass include_ancillary=true to see everything."""
    event = client.get_event(event_id)
    try:
        stats = client.get_event_stats(event_id)
    except RuntimeError:
        stats = None
    try:
        stats_event_only = client.get_event_stats(event_id, inventory_type="event")
    except RuntimeError:
        stats_event_only = None
    listings = client.get_listings(event_id, order_by="retail_price ASC")
    raw_groups = listings.get("ticket_groups", []) or []
    if include_ancillary:
        groups = raw_groups
    else:
        groups = [tg for tg in raw_groups if _is_event_seat(tg)]
    return {
        "event": event,
        "stats": stats,
        "stats_event_only": stats_event_only,
        "ticket_groups": groups,
        "ticket_groups_total": len(raw_groups),
        "ticket_groups_filtered_parking": len(raw_groups) - len(groups),
    }


@app.get("/api/events/{event_id}/series")
def event_series(
    event_id: int,
    days: int = 30,
    _=Depends(require_auth),
):
    """Return time-series metrics for one event from event_metrics.

    Query params:
        days: lookback window in days (default 30, clamped to [1, 365])

    Response shape:
        {
          "event_id": 12345,
          "days": 30,
          "series": [
            {
              "t": "2026-04-23T14:00:00+00:00",
              "tickets_count": 1990, "groups_count": 626, "sections_count": 48,
              "retail_min": 39.0, "retail_p25": 180.0, "retail_median": 420.0,
              "retail_mean": 945.12, "retail_p75": 1200.0, "retail_p90": 2500.0,
              "retail_max": 9245.0,
              "wholesale_median": 315.0, "wholesale_mean": 720.0,
              "getin_price": 78.0, "top5_concentration": 0.62, "bid_ask_proxy": 0.22
            },
            ...
          ]
        }
    """
    days = max(1, min(int(days), 365))
    db = require_sb()
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    resp = (
        db.table("event_metrics")
        .select(
            "captured_at,"
            "tickets_count,groups_count,sections_count,"
            "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,"
            "wholesale_median,wholesale_mean,"
            "getin_price,top5_concentration"
        )
        .eq("event_id", event_id)
        .gte("captured_at", since)
        .order("captured_at")
        .execute()
    )
    series = [
        {"t": r["captured_at"], **{k: v for k, v in r.items() if k != "captured_at"}}
        for r in (resp.data or [])
    ]
    return {"event_id": event_id, "days": days, "series": series}


@app.get("/api/events/{event_id}/sections/series")
def event_section_series(
    event_id: int,
    days: int = 30,
    _=Depends(require_auth),
):
    """Section-level time series for one event. One series per section.

    Response shape:
        {
          "event_id": 12345,
          "days": 30,
          "sections": [
            {
              "section": "100",
              "is_ancillary": false,
              "points": [
                {
                  "t": "2026-04-23T14:00:00+00:00",
                  "tickets_count": 42, "groups_count": 11,
                  "retail_min": 420.0, "retail_median": 520.0,
                  "retail_mean": 535.0, "retail_max": 820.0
                },
                ...
              ]
            },
            ...
          ]
        }
    """
    days = max(1, min(int(days), 365))
    db = require_sb()
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    resp = (
        db.table("section_metrics")
        .select(
            "captured_at,section,is_ancillary,"
            "tickets_count,groups_count,"
            "retail_min,retail_median,retail_mean,retail_max"
        )
        .eq("event_id", event_id)
        .gte("captured_at", since)
        .order("captured_at")
        .execute()
    )

    by_section: dict = {}
    for r in (resp.data or []):
        key = r["section"]
        if key not in by_section:
            by_section[key] = {
                "section": key,
                "is_ancillary": bool(r.get("is_ancillary", False)),
                "points": [],
            }
        by_section[key]["points"].append({
            "t": r["captured_at"],
            "tickets_count": r.get("tickets_count"),
            "groups_count": r.get("groups_count"),
            "retail_min": r.get("retail_min"),
            "retail_median": r.get("retail_median"),
            "retail_mean": r.get("retail_mean"),
            "retail_max": r.get("retail_max"),
        })

    # Non-ancillary sections first, then alphabetical
    sections = sorted(
        by_section.values(),
        key=lambda s: (s["is_ancillary"], s["section"]),
    )
    return {"event_id": event_id, "days": days, "sections": sections}


@app.get("/api/performers")
def performers_search(
    q: str | None = None,
    fuzzy: bool = False,
    category_id: int | None = None,
    category_tree: bool = True,
    only_with_upcoming_events: bool | None = None,
    _=Depends(require_auth),
):
    if category_id is not None:
        performers = []
        for page in range(1, 21):
            resp = client.list_performers(
                category_id=category_id,
                category_tree=category_tree,
                only_with_upcoming_events=only_with_upcoming_events,
                order_by="performers.popularity_score DESC",
                per_page=100,
                page=page,
            )
            batch = resp.get("performers", [])
            performers.extend(batch)
            if len(performers) >= resp.get("total_entries", 0) or not batch:
                break
        return {"performers": performers, "total_entries": len(performers)}
    if q:
        return client.search_performers(q=q, fuzzy=fuzzy)
    raise HTTPException(400, "Provide q or category_id")


@app.get("/api/performers/{performer_id}")
def performer_detail(performer_id: int, include_opponents: bool = True, _=Depends(require_auth)):
    return client.get_performer(performer_id, include_opponents=include_opponents)


# Static league list for the league-browse strip in the Performers tab.
# Sourced from performer_external_ids where source='espn'. Order roughly
# matches in-season activity in May.
_ESPN_LEAGUES = [
    {"key": "NBA",       "label": "NBA",        "teams": 30},
    {"key": "MLB",       "label": "MLB",        "teams": 30},
    {"key": "NHL",       "label": "NHL",        "teams": 32},
    {"key": "WNBA",      "label": "WNBA",       "teams": 15},
    {"key": "MLS",       "label": "MLS",        "teams": 30},
    {"key": "NFL",       "label": "NFL",        "teams": 32},
    {"key": "World Cup", "label": "World Cup",  "teams": 48},
]


@app.get("/api/broker/leagues")
def broker_leagues(_=Depends(require_auth)):
    """Static list of ESPN-tracked leagues for the league-browse strip in the Performers tab."""
    return {"leagues": _ESPN_LEAGUES}


@app.get("/api/broker/performer/{performer_id}/assets")
def broker_performer_assets(performer_id: int, _=Depends(require_auth)):
    """ESPN team logo + colors + URLs for a TEvo performer. Backed by
    performer_metadata (populated by crawl-espn-team-assets fn — drained
    every 3 min by cron 'crawl-espn-team-assets-3min').

    Returns null fields for performers without ESPN mapping (e.g. concerts
    or playoff bracket placeholders). 65/866 populated as of 2026-05-08.
    """
    db = require_sb()
    row = (db.table("performer_metadata")
             .select("performer_id, name, espn_team_id, espn_league, "
                     "color_primary, color_alternate, "
                     "logo_default_url, logo_dark_url, logo_scoreboard_url, logo_4k_primary_url, logo_secondary_url, "
                     "espn_team_url, espn_roster_url, espn_schedule_url, espn_fetched_at")
             .eq("performer_id", performer_id).limit(1).execute().data or [])
    return row[0] if row else {"performer_id": performer_id, "logo_default_url": None}


def _bulk_performer_assets(db, performer_ids: list[int]) -> dict[int, dict]:
    """Fetch performer_metadata for many performer_ids at once. Returns map
    {performer_id: {logo_default_url, color_primary, ...}}. Used by event
    overview to attach home + away logos in a single roundtrip."""
    if not performer_ids:
        return {}
    rows = (db.table("performer_metadata")
              .select("performer_id, name, espn_team_id, espn_league, "
                      "color_primary, color_alternate, logo_default_url, logo_dark_url")
              .in_("performer_id", performer_ids)
              .execute()).data or []
    return {int(r["performer_id"]): r for r in rows}


@app.get("/api/broker/news")
def broker_news(
    limit: int = 20,
    league: str | None = None,
    team_ids: str | None = None,
    event_id: int | None = None,
    _=Depends(require_auth),
):
    """Recent ESPN news. Modes:
      - no filter         → global feed (home view).
      - league=NBA        → single league.
      - team_ids=20,18    → comma-separated espn_team_ids (event level page).
      - event_id=N        → resolves event_xref → home/away ESPN team_ids and
                            scopes news to those two teams + their league.
    """
    limit = max(1, min(int(limit), 100))
    db = require_sb()

    resolved_teams: list[str] = []
    resolved_league: str | None = league

    if event_id is not None and not team_ids:
        xref = (db.table("event_xref")
                  .select("espn_event_id, espn_league")
                  .eq("tevo_event_id", event_id).limit(1).execute().data or [])
        if xref:
            resolved_league = xref[0]["espn_league"]
            snap = (db.table("espn_event_snapshots")
                      .select("home_team_id, away_team_id")
                      .eq("espn_event_id", xref[0]["espn_event_id"])
                      .order("captured_at", desc=True).limit(1).execute().data or [])
            if snap:
                for k in ("home_team_id", "away_team_id"):
                    v = snap[0].get(k)
                    if v: resolved_teams.append(str(v))
    elif team_ids:
        resolved_teams = [t.strip() for t in team_ids.split(",") if t.strip()]

    q = (db.table("espn_news")
           .select("headline, description, url, published_at, type, espn_team_id, espn_league")
           .order("published_at", desc=True).limit(limit))
    if resolved_league:
        q = q.eq("espn_league", resolved_league)
    if resolved_teams:
        q = q.in_("espn_team_id", resolved_teams)
    rows = q.execute().data or []

    return {
        "count": len(rows),
        "items": rows,
        "filter": {"league": resolved_league, "team_ids": resolved_teams, "event_id": event_id},
    }


@app.get("/api/broker/performers/by-league/{league}")
def broker_performers_by_league(league: str, include_inactive: bool = False, _=Depends(require_auth)):
    """Per-team HOME/ROAD price metrics for ESPN-tracked teams in a league.
    Backed by the get_performers_by_league SQL RPC (mig 20260508050000).

    Returns: { league, count, performers: [
        { performer_id, performer_name, home_venue_id, home_venue_name,
          home: { events, market_med, owned_med, market_tix, owned_tix, first_event, last_event },
          road: { events, market_med, owned_med, market_tix, owned_tix, first_event, last_event } },
        ...
    ] }

    `include_inactive`: passthrough flag. The underlying SQL RPC currently
    aggregates over ALL events (including ghost playoff brackets where the
    team was eliminated). NEXT (code) — update get_performers_by_league
    to JOIN against event_lifecycle and exclude is_active=false rows when
    include_inactive=false. Until that lands, the response field
    `_inactive_filter_applied` reports false so the frontend can flag it.
    """
    db = require_sb()
    rows = db.rpc("get_performers_by_league", {"p_league": league}).execute().data or []

    def _delta_pct(cur, prev):
        if cur is None or prev is None: return None
        try:
            c = float(cur); p = float(prev)
        except (TypeError, ValueError):
            return None
        if p == 0: return None
        return round((c - p) / p * 100, 2)

    performers = [
        {
            "performer_id":    r.get("performer_id"),
            "performer_name":  r.get("performer_name"),
            "league":          r.get("league"),
            "home_venue_id":   r.get("home_venue_id"),
            "home_venue_name": r.get("home_venue_name"),
            "home": {
                "events":          r.get("home_events") or 0,
                "market_med":      r.get("home_market_med"),
                "owned_med":       r.get("home_owned_med"),
                "market_tix":      r.get("home_market_tix") or 0,
                "owned_tix":       r.get("home_owned_tix")  or 0,
                "first_event":     r.get("home_first_event"),
                "last_event":      r.get("home_last_event"),
                "prev_market_med": r.get("home_prev_market_med"),
                "prev_owned_med":  r.get("home_prev_owned_med"),
                "delta_market_pct": _delta_pct(r.get("home_market_med"), r.get("home_prev_market_med")),
                "delta_owned_pct":  _delta_pct(r.get("home_owned_med"),  r.get("home_prev_owned_med")),
            },
            "road": {
                "events":          r.get("road_events") or 0,
                "market_med":      r.get("road_market_med"),
                "owned_med":       r.get("road_owned_med"),
                "market_tix":      r.get("road_market_tix") or 0,
                "owned_tix":       r.get("road_owned_tix")  or 0,
                "first_event":     r.get("road_first_event"),
                "last_event":      r.get("road_last_event"),
                "prev_market_med": r.get("road_prev_market_med"),
                "prev_owned_med":  r.get("road_prev_owned_med"),
                "delta_market_pct": _delta_pct(r.get("road_market_med"), r.get("road_prev_market_med")),
                "delta_owned_pct":  _delta_pct(r.get("road_owned_med"),  r.get("road_prev_owned_med")),
            },
        }
        for r in rows
    ]
    return {
        "league": league,
        "count": len(performers),
        "performers": performers,
        "_inactive_filter_applied": False,  # see NEXT in docstring; tracked in KANBAN
        "_include_inactive_param": include_inactive,
    }


@app.get("/api/portfolio")
def portfolio(
    performer_id: int | None = None,
    venue_id: int | None = None,
    watchlist_only: bool = False,
    include_inactive: bool = False,
    _=Depends(require_auth),
):
    """Aggregated portfolio across multiple events.

    Filters (one required):
        performer_id    - events where this performer is primary OR in performer_ids[]
        venue_id        - events at this venue
        watchlist_only  - events that originated from any watchlist row (via watch_sources)

    `include_inactive`: by default we exclude events flagged ghost / completed /
    cancelled / postponed via the event_lifecycle view, so portfolio totals
    don't double-count playoff brackets that the team got eliminated from.

    Returns: { filter, events: [...latest metric per event with `lifecycle`...],
               aggregate: {...rollups...}, inactive_excluded_count }
    """
    if not (performer_id or venue_id or watchlist_only):
        raise HTTPException(400, "Provide performer_id, venue_id, or watchlist_only=true")

    db = require_sb()

    # 1) Resolve event_ids matching the filter
    if performer_id is not None:
        # Single query: primary OR in performer_ids[]. PostgREST .or_() takes the filters
        # comma-separated; cs.{N} is the array-contains operator.
        ev_a = (
            db.table("events").select("id")
            .or_(f"primary_performer_id.eq.{int(performer_id)},performer_ids.cs.{{{int(performer_id)}}}")
            .execute().data
        ) or []
        event_ids = [r["id"] for r in ev_a]
    elif venue_id is not None:
        ev_a = db.table("events").select("id").eq("venue_id", venue_id).execute().data or []
        event_ids = [r["id"] for r in ev_a]
    else:
        ws = db.table("watch_sources").select("event_id").execute().data or []
        event_ids = list({r["event_id"] for r in ws})

    if not event_ids:
        return {
            "filter": {"performer_id": performer_id, "venue_id": venue_id, "watchlist_only": watchlist_only},
            "events": [],
            "aggregate": {
                "events_count": 0, "tickets_total": 0, "owned_tickets_total": 0,
                "owned_share_weighted": None, "retail_value_total": 0,
                "owned_retail_value_total": 0, "retail_median_avg_weighted": None,
                "events_with_owned": 0,
            },
        }

    # 2) Pull event metadata
    ev_meta = (
        db.table("events")
        .select("id,name,occurs_at_local,venue_id,venue_name,venue_location,primary_performer_id,primary_performer_name,state")
        .in_("id", event_ids)
        .execute()
    ).data or []

    # 2b) For performer-filtered queries, look up the performer's home venue(s)
    # AND classification so we can tag is_home for sports only.
    # HOME/AWAY only applies when what_event_type='game' (per TEvo taxonomy:
    # Sports=343 maps to 'game', Concerts/Comedy/Theater do not — Taylor
    # Swift at MSG isn't "home", the venue just hosts).
    home_venue_ids: set[int] = set()
    is_sports_performer: bool = False
    perf_classification: dict | None = None
    if performer_id is not None:
        phv_rows = (
            db.table("performer_home_venues")
            .select("venue_id")
            .eq("performer_id", performer_id)
            .execute()
        ).data or []
        home_venue_ids = {int(r["venue_id"]) for r in phv_rows if r.get("venue_id") is not None}

        pm_rows = (
            db.table("performer_metadata")
            .select("what_event_type, top_category_name, parent_category_name, category_name, genre")
            .eq("performer_id", performer_id).limit(1)
            .execute()
        ).data or []
        if pm_rows:
            perf_classification = pm_rows[0]
            is_sports_performer = (perf_classification.get("what_event_type") == "game")

    # 3) Pull latest metrics row per event
    ev_metrics = (
        db.table("latest_event_metrics")
        .select(
            "event_id,captured_at,tickets_count,groups_count,sections_count,"
            "retail_min,retail_median,retail_p75,retail_p90,retail_max,retail_sum,"
            "getin_price,owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
            "price_dispersion,tail_premium,top5_concentration"
        )
        .in_("event_id", event_ids)
        .execute()
    ).data or []
    metrics_by_id = {m["event_id"]: m for m in ev_metrics}

    # 3.5) Lifecycle classification for each event. Used to exclude ghosts
    # (eliminated playoff brackets, completed games, cancellations) from
    # aggregates by default. Each event row also gets a `lifecycle` block
    # so the UI can show a status badge.
    lc_rows = (
        db.table("event_lifecycle").select("event_id,status,is_active,confidence,reasons")
        .in_("event_id", event_ids).execute()
    ).data or []
    lifecycle_by_id = {r["event_id"]: r for r in lc_rows}
    inactive_excluded_count = 0
    if not include_inactive:
        before = len(event_ids)
        active_ids = {r["event_id"] for r in lc_rows if r.get("is_active")}
        # Keep events that are either active or have no lifecycle row (defensive — shouldn't happen)
        ev_meta = [e for e in ev_meta if e["id"] in active_ids or e["id"] not in lifecycle_by_id]
        inactive_excluded_count = before - len(ev_meta)

    # 4) Merge per-event
    out_events = []
    for ev in ev_meta:
        m = metrics_by_id.get(ev["id"], {})
        # is_home: only meaningful for sports performers. Concerts/comedy/
        # theater performers don't have a home venue concept (the venue just
        # hosts). Gate on what_event_type='game' from performer_metadata.
        is_home = None
        if performer_id is not None and is_sports_performer:
            if ev.get("venue_id") is not None:
                is_home = int(ev["venue_id"]) in home_venue_ids
        out_events.append({
            "id": ev["id"],
            "name": ev["name"],
            "occurs_at_local": ev["occurs_at_local"],
            "state": ev.get("state"),
            "venue_id": ev["venue_id"],
            "venue_name": ev["venue_name"],
            "venue_location": ev["venue_location"],
            "primary_performer_id": ev["primary_performer_id"],
            "primary_performer_name": ev["primary_performer_name"],
            "is_home": is_home,
            "captured_at": m.get("captured_at"),
            "tickets_count": m.get("tickets_count"),
            "groups_count": m.get("groups_count"),
            "sections_count": m.get("sections_count"),
            "retail_min": m.get("retail_min"),
            "retail_median": m.get("retail_median"),
            "retail_p75": m.get("retail_p75"),
            "retail_p90": m.get("retail_p90"),
            "retail_max": m.get("retail_max"),
            "retail_sum": m.get("retail_sum"),
            "getin_price": m.get("getin_price"),
            "owned_groups_count": m.get("owned_groups_count"),
            "owned_tickets_count": m.get("owned_tickets_count"),
            "owned_share": m.get("owned_share"),
            "owned_median_retail": m.get("owned_median_retail"),
            "price_dispersion": m.get("price_dispersion"),
            "tail_premium": m.get("tail_premium"),
            "top5_concentration": m.get("top5_concentration"),
            "lifecycle": lifecycle_by_id.get(ev["id"]),  # status badge data
        })

    # Sort: events with metrics first, soonest first
    out_events.sort(key=lambda e: (e["captured_at"] is None, e.get("occurs_at_local") or ""))

    # 5) Aggregate
    def fnum(v):
        try:
            return float(v) if v is not None else 0.0
        except (TypeError, ValueError):
            return 0.0

    tickets_total = sum(int(e["tickets_count"] or 0) for e in out_events)
    owned_tickets_total = sum(int(e["owned_tickets_count"] or 0) for e in out_events)
    retail_value_total = sum(fnum(e["retail_sum"]) for e in out_events)
    owned_retail_value_total = sum(
        int(e["owned_tickets_count"] or 0) * fnum(e["owned_median_retail"])
        for e in out_events
    )
    events_with_owned = sum(1 for e in out_events if (e["owned_tickets_count"] or 0) > 0)

    # Quantity-weighted retail median
    weighted_num = 0.0
    weighted_den = 0
    for e in out_events:
        if e["retail_median"] is not None and (e["tickets_count"] or 0) > 0:
            weighted_num += fnum(e["retail_median"]) * int(e["tickets_count"])
            weighted_den += int(e["tickets_count"])
    retail_median_avg_weighted = (weighted_num / weighted_den) if weighted_den > 0 else None

    return {
        "filter": {
            "performer_id": performer_id,
            "venue_id": venue_id,
            "watchlist_only": watchlist_only,
            "include_inactive": include_inactive,
        },
        "performer_classification": perf_classification,    # null when not perf-filtered
        "is_sports_performer": is_sports_performer,         # gates the HOME/AWAY UI
        "events": out_events,
        "inactive_excluded_count": inactive_excluded_count,  # ghost / completed / cancelled events filtered out
        "aggregate": {
            "events_count": len(out_events),
            "tickets_total": tickets_total,
            "owned_tickets_total": owned_tickets_total,
            "owned_share_weighted": (owned_tickets_total / tickets_total) if tickets_total > 0 else None,
            "retail_value_total": round(retail_value_total, 2),
            "owned_retail_value_total": round(owned_retail_value_total, 2),
            "retail_median_avg_weighted": round(retail_median_avg_weighted, 2) if retail_median_avg_weighted is not None else None,
            "events_with_owned": events_with_owned,
        },
    }



@app.get("/api/venues")
def venues_search(
    q: str | None = None,
    fuzzy: bool = False,
    lat: float | None = None,
    lon: float | None = None,
    within: int | None = None,
    postal_code: str | None = None,
    _=Depends(require_auth),
):
    if q:
        return client.search_venues(q=q, fuzzy=fuzzy)
    if lat is not None and lon is not None:
        return client.list_venues(lat=lat, lon=lon, within=within or 15)
    if postal_code:
        return client.list_venues(postal_code=postal_code, within=within or 15)
    raise HTTPException(400, "Provide q, or (lat+lon), or postal_code.")


@app.get("/api/venues/{venue_id}")
def venue_detail(venue_id: int, _=Depends(require_auth)):
    return client.get_venue(venue_id)


@app.get("/api/configurations")
def configurations_list(venue_id: int | None = None, name: str | None = None, _=Depends(require_auth)):
    return client.list_configurations(venue_id=venue_id, name=name or None)


@app.get("/api/configurations/{config_id}")
def configuration_detail(config_id: int, _=Depends(require_auth)):
    return client.get_configuration(config_id)


@app.get("/api/watchlist")
def watchlist_list(_=Depends(require_auth)):
    db = require_sb()
    data = db.table("watchlist").select("*").order("added_at", desc=True).execute().data
    return {"items": data or []}


@app.post("/api/watchlist")
def watchlist_add(item: dict = Body(...), _=Depends(require_auth)):
    db = require_sb()
    kind = item.get("kind")
    ext_id = item.get("ext_id")
    label = item.get("label")
    if kind not in ("performer", "venue"):
        raise HTTPException(400, "kind must be performer or venue")
    if not ext_id:
        raise HTTPException(400, "ext_id required")
    try:
        res = db.table("watchlist").insert(
            {"kind": kind, "ext_id": int(ext_id), "label": label or None}
        ).execute()
        return {"ok": True, "item": (res.data or [None])[0]}
    except Exception as e:
        msg = str(e)
        if "duplicate" in msg.lower() or "unique" in msg.lower() or "23505" in msg:
            return {"ok": False, "error": "already in watchlist"}
        raise HTTPException(400, msg)


@app.delete("/api/watchlist/{item_id}")
def watchlist_remove(item_id: int, _=Depends(require_auth)):
    db = require_sb()
    db.table("watchlist").delete().eq("id", item_id).execute()
    return {"ok": True}


@app.get("/api/runs")
def runs_list(limit: int = 20, _=Depends(require_auth)):
    db = require_sb()
    data = db.table("runs").select("*").order("id", desc=True).limit(limit).execute().data
    return {"items": data or []}


@app.get("/api/snapshots/latest")
def snapshots_latest(_=Depends(require_auth)):
    db = require_sb()
    snaps = db.table("latest_snapshots").select("*").execute().data or []
    if not snaps:
        return {"items": []}
    ids = [s["event_id"] for s in snaps]
    events = db.table("events").select("*").in_("id", ids).execute().data or []
    by_id = {e["id"]: e for e in events}
    items = []
    for s in snaps:
        e = by_id.get(s["event_id"], {})
        items.append({
            **s,
            "event_name": e.get("name"),
            "occurs_at_local": e.get("occurs_at_local"),
            "venue_name": e.get("venue_name"),
            "venue_location": e.get("venue_location"),
            "primary_performer_name": e.get("primary_performer_name"),
        })
    items.sort(key=lambda x: x.get("occurs_at_local") or "")
    return {"items": items}


@app.get("/api/snapshots/velocity")
def snapshots_velocity(_=Depends(require_auth)):
    db = require_sb()
    data = db.table("event_velocity").select("*").order("occurs_at_local").execute().data or []
    return {"items": data}


def _fire_collect(url: str, secret: str) -> None:
    try:
        requests.post(
            url,
            headers={"X-Cron-Secret": secret, "Content-Type": "application/json"},
            json={},
            timeout=180,
        )
    except Exception as e:
        print(f"collect fire error: {e}")


# Per-user throttle for /api/collect/run — 1 invocation per 5 min per email.
# Defends against accidental loops or a leaked JWT being used to spam-fire the
# collector. Cheap in-process state; resets on Railway redeploy.
_collect_run_last_call: dict[str, float] = {}
_COLLECT_RUN_COOLDOWN_SEC = 300


@app.post("/api/collect/run")
def collect_run(watchlist_id: int | None = None, user=Depends(require_auth)):
    if not (SUPABASE_URL and CRON_SECRET):
        raise HTTPException(500, "Set SUPABASE_URL and CRON_SECRET to invoke the collector.")
    if watchlist_id is not None and watchlist_id < 1:
        raise HTTPException(400, "watchlist_id must be a positive integer")

    import time
    email = (user or {}).get("email") or "unknown"
    now = time.time()
    last = _collect_run_last_call.get(email, 0)
    if now - last < _COLLECT_RUN_COOLDOWN_SEC:
        wait = int(_COLLECT_RUN_COOLDOWN_SEC - (now - last))
        raise HTTPException(429, f"rate limited — try again in {wait}s")
    _collect_run_last_call[email] = now

    url = f"{SUPABASE_URL}/functions/v1/collect"
    if watchlist_id is not None:
        url += f"?watchlist_id={int(watchlist_id)}"
    threading.Thread(target=_fire_collect, args=(url, CRON_SECRET), daemon=True).start()
    return {"ok": True, "message": "collector fired; poll the runs table"}


# ============================================================================
# Broker terminal — event-detail page endpoints
# ----------------------------------------------------------------------------
# Backs the new /event/{id} terminal (Bloomberg/Robinhood hybrid).
# Each endpoint returns its own last_pull_at + cadence_seconds so the page
# can poll independently per data type, cascaded across events.
# ============================================================================


def _listings_cadence_seconds(occurs_at_local: str | None) -> int:
    """Mirror collect-listings cron windows: closer events poll faster."""
    if not occurs_at_local:
        return 60 * 60 * 24
    try:
        # occurs_at_local is TEXT not TIMESTAMPTZ — known P1. Slice to date.
        d = datetime.fromisoformat(occurs_at_local[:10])
        days_out = (d - datetime.now()).days
    except Exception:
        return 60 * 60
    if days_out <= 1:
        return 60 * 20      # 20 min
    if days_out <= 7:
        return 60 * 60      # 60 min
    if days_out <= 30:
        return 60 * 60 * 4  # 4h
    if days_out <= 60:
        return 60 * 60 * 12 # 12h
    return 60 * 60 * 24     # 24h


def _delta(curr, prev):
    """Compute delta + percent for a numeric metric. Returns dict or None."""
    if curr is None or prev is None:
        return None
    try:
        c = float(curr); p = float(prev)
    except (TypeError, ValueError):
        return None
    if c == p:
        return {"abs": 0, "pct": 0, "dir": "flat"}
    diff = c - p
    pct = (diff / p * 100) if p != 0 else None
    return {"abs": round(diff, 2), "pct": round(pct, 2) if pct is not None else None,
            "dir": "up" if diff > 0 else "down"}


@app.get("/api/broker/event/{event_id}/overview")
def broker_event_overview(event_id: int, _=Depends(require_auth)):
    """Top-left pane: event header + event-level metrics + zone breakdown.
    Returns latest + prior values so the UI can render delta arrows."""
    db = require_sb()

    # Event header (use cowork's RPC for the rich payload)
    detail = db.rpc("get_broker_event_detail", {"p_event_id": event_id}).execute().data or []
    head = detail[0] if detail else None

    # Latest two event_metrics for delta computation. Pull every column we
    # collect — frontend slices it into Distribution / Volume / Wholesale /
    # Market Structure / Owned panels.
    em_rows = (
        db.table("event_metrics")
        .select(
            "captured_at,"
            # Inventory
            "tickets_count,groups_count,sections_count,median_group_size,"
            "ancillary_groups,ancillary_tickets,"
            # Retail price distribution
            "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,retail_sum,"
            # Wholesale price distribution
            "wholesale_min,wholesale_median,wholesale_mean,wholesale_max,"
            # Market structure / quality
            # NOTE: bid_ask_proxy was dropped in mig 20260428000001 (always 0 — TEvo
            # API doesn't expose true wholesale to this token). Don't re-add to the
            # select or the query 500s.
            "getin_price,top5_concentration,"
            "price_dispersion,tail_premium,"
            # Owned (S4K)
            "owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
            # Splits inventory metrics (mig 20260508230000)
            "splits_min_q,splits_listings_with_singles,splits_listings_with_pairs,"
            "splits_listings_with_3,splits_listings_with_4plus,splits_listings_no_split,"
            "splits_pct_pairs,splits_pct_singles"
        )
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(2)
        .execute()
    ).data or []
    curr = em_rows[0] if len(em_rows) >= 1 else {}
    prev = em_rows[1] if len(em_rows) >= 2 else {}

    metric_keys = [
        # Inventory
        "tickets_count", "groups_count", "sections_count", "median_group_size",
        "ancillary_groups", "ancillary_tickets",
        # Retail distribution
        "retail_min", "retail_p25", "retail_median", "retail_mean", "retail_p75", "retail_p90", "retail_max", "retail_sum",
        # Wholesale distribution
        "wholesale_min", "wholesale_median", "wholesale_mean", "wholesale_max",
        # Market structure
        "getin_price", "top5_concentration",
        "price_dispersion", "tail_premium",
        # Owned
        "owned_groups_count", "owned_tickets_count", "owned_share", "owned_median_retail",
        # Splits inventory
        "splits_min_q", "splits_listings_with_singles", "splits_listings_with_pairs",
        "splits_listings_with_3", "splits_listings_with_4plus", "splits_listings_no_split",
        "splits_pct_pairs", "splits_pct_singles",
    ]
    metrics = {k: {"v": curr.get(k), "delta": _delta(curr.get(k), prev.get(k))} for k in metric_keys}

    # Zone breakdown — owned + market split via cowork's RPC
    zones_owned = db.rpc("get_event_zones_rollup", {"p_event_id": event_id, "p_owned_only": True}).execute().data or []
    zones_market = db.rpc("get_event_zones_rollup", {"p_event_id": event_id, "p_owned_only": False}).execute().data or []

    cadence = _listings_cadence_seconds(head.get("occurs_at_local") if head else None)
    last_pull = curr.get("captured_at")

    # Attach home + away assets (logos, colors). Resolve teams via:
    # 1) primary_performer_id is "home" (per AGENTS.md performer_home_venues semantics)
    # 2) other performer_ids[] entries are away/opponent
    # If event_xref maps to ESPN, additional team_ids come back from espn_event_snapshots.
    perf_ids: list[int] = []
    if head:
        if head.get("primary_performer_id"):
            perf_ids.append(int(head["primary_performer_id"]))
        for pid in (head.get("performer_ids") or []):
            if pid and pid not in perf_ids:
                perf_ids.append(int(pid))
    assets_by_id = _bulk_performer_assets(db, perf_ids)
    home_perf_id = head.get("primary_performer_id") if head else None
    home_assets = assets_by_id.get(int(home_perf_id)) if home_perf_id else None
    away_assets_list = [assets_by_id.get(int(p)) for p in perf_ids if p != home_perf_id and assets_by_id.get(int(p))]

    # Lifecycle classification — flags ghost playoff games, completed events,
    # postponed/cancelled. Used by the UI to render a status banner and to
    # let movers/league/portfolio surfaces filter ghosts out by default.
    # See migration 20260509050000_event_lifecycle for rule definitions.
    try:
        lc_rows = db.rpc("derive_event_lifecycle", {"p_event_id": event_id}).execute().data or []
        lc = lc_rows[0] if lc_rows else None
    except Exception:
        lc = None

    return {
        "event": head,
        "metrics": metrics,
        "zones": {"owned": zones_owned, "market": zones_market},
        "last_pull_at": last_pull,
        "cadence_seconds": cadence,
        "assets": {
            "home": home_assets,
            "away": away_assets_list[0] if away_assets_list else None,
            "all": list(assets_by_id.values()),
        },
        "lifecycle": lc,
    }


_PARKING_ZONE_RE = re.compile(r"\b(parking|garage|valet|lot|hospitality|premium\s*park)\b", re.IGNORECASE)
_PARKING_SECTION_RE = re.compile(r"\b(parking|garage|valet|lot|hospitality|premium\s*park|prepaid|preferred\s*parking|guest\s*parking|vip\s*lot|vip\s*parking)\b", re.IGNORECASE)


@app.get("/api/broker/event/{event_id}/section-zones")
def broker_event_section_zones(event_id: int, _=Depends(require_auth)):
    """Section → zone lookup map for an event. Used by the Market vs Owned
    Depth panel to render a Zone column next to each ticket_group.

    Resolution: curated performer_zones (priority) → derive_zone_fallback()
    keyword/numeric heuristic → null.
    """
    db = require_sb()
    ev = (db.table("events")
            .select("primary_performer_id, venue_id")
            .eq("id", event_id).limit(1).execute().data or [])
    if not ev:
        return {"map": {}, "source_mix": {}}
    primary_perf = ev[0].get("primary_performer_id")
    venue_id = ev[0].get("venue_id")

    # Distinct (section, row) pairs in the event's latest listings snapshot
    latest = (db.table("listings_snapshots")
                .select("captured_at").eq("event_id", event_id)
                .order("captured_at", desc=True).limit(1).execute().data or [])
    if not latest:
        return {"map": {}, "source_mix": {}}
    latest_at = latest[0]["captured_at"]
    sec_rows = (db.table("listings_snapshots")
                  .select("section, row")
                  .eq("event_id", event_id).eq("captured_at", latest_at)
                  .execute().data or [])
    secs = list({(r.get("section"), r.get("row")) for r in sec_rows})

    # Build map. For each (section, row), call derive_zone_fallback for the system
    # answer; also check performer_zones for curated. Curated wins.
    section_map: dict[str, dict] = {}
    source_mix: dict[str, int] = {}

    # Curated lookups (in batch) — query performer_zone_section_rules joined with performer_zones
    if primary_perf and venue_id:
        cur_rules = (db.table("performer_zones")
                       .select("id, zone, performer_zone_section_rules(section_pattern, match_type, row_pattern, priority)")
                       .eq("performer_id", primary_perf).eq("venue_id", venue_id)
                       .eq("source", "curated")
                       .execute().data or [])
        # Flatten rules: list of (zone, pattern, match_type, row_pattern, priority)
        rules: list[tuple] = []
        for cz in cur_rules:
            for rule in (cz.get("performer_zone_section_rules") or []):
                rules.append((cz["zone"], rule.get("section_pattern") or "",
                              rule.get("match_type") or "exact",
                              rule.get("row_pattern"), rule.get("priority") or 0))
        rules.sort(key=lambda r: -r[4])  # priority desc

        def _curated_match(section: str | None, row: str | None) -> str | None:
            if not section: return None
            sec = section
            for zone, patt, mtype, rpatt, _pri in rules:
                hit = False
                if mtype == "exact":     hit = sec == patt
                elif mtype == "prefix":  hit = sec.lower().startswith(patt.lower())
                elif mtype == "suffix":  hit = sec.lower().endswith(patt.lower())
                elif mtype == "substring": hit = patt.lower() in sec.lower()
                elif mtype == "regex":
                    try: hit = bool(re.search(patt, sec, re.IGNORECASE))
                    except re.error: hit = False
                if hit and rpatt and row:
                    try: hit = bool(re.search(rpatt, row, re.IGNORECASE))
                    except re.error: pass
                if hit: return zone
            return None
    else:
        def _curated_match(section, row): return None

    # Resolve each section
    for section, row in secs:
        z_curated = _curated_match(section, row)
        if z_curated:
            section_map[section] = {"zone": z_curated, "source": "curated"}
            source_mix["curated"] = source_mix.get("curated", 0) + 1
            continue
        # Fallback: derive_zone_fallback RPC
        try:
            res = db.rpc("derive_zone_fallback", {"p_section": section, "p_row": row}).execute().data
            zfall = res if isinstance(res, str) else None
        except Exception:
            zfall = None
        if zfall:
            section_map[section] = {"zone": zfall, "source": "fallback"}
            source_mix["fallback"] = source_mix.get("fallback", 0) + 1
        else:
            section_map[section] = {"zone": None, "source": "unmapped"}
            source_mix["unmapped"] = source_mix.get("unmapped", 0) + 1

    return {"map": section_map, "source_mix": source_mix}


@app.get("/api/broker/event/{event_id}/zones")
def broker_event_zones(event_id: int, include_parking: bool = False, _=Depends(require_auth)):
    """Per-zone latest metrics with full distribution.

    Picks ONE zone_source per event by priority: curated > fallback > unmapped.
    User spec: never show two competing zone classifications side-by-side.
    If the event has any curated zones, only curated rows surface; the fallback
    layer is redundant noise in that case (mostly leftover sections that didn't
    match a curated rule, with tiny ticket counts).

    Returns latest snapshot per zone within the chosen source. zone_metrics has
    the same shape as event_metrics (full percentile distribution + owned
    breakdown).
    """
    db = require_sb()
    rows = (
        db.table("zone_metrics")
        .select(
            "zone, zone_source, captured_at, "
            "tickets_count, groups_count, sections_count, "
            "retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum, "
            "wholesale_min, wholesale_median, wholesale_mean, wholesale_max, "
            "getin_price, "
            "owned_groups_count, owned_tickets_count, owned_share, owned_median_retail"
        )
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(1000)
        .execute()
    ).data or []

    # 1) Decide which source to use. Priority: curated > fallback > unmapped.
    sources_present = {r.get("zone_source") for r in rows}
    if "curated" in sources_present:
        chosen_source = "curated"
    elif "fallback" in sources_present:
        chosen_source = "fallback"
    elif "unmapped" in sources_present:
        chosen_source = "unmapped"
    else:
        chosen_source = None

    # 2) Filter to chosen source, then take latest per zone (rows are pre-sorted desc).
    if chosen_source is None:
        return {"zones": [], "count": 0, "source": None, "available_sources": []}

    seen = set()
    out = []
    parking_count = 0
    for r in rows:
        if r.get("zone_source") != chosen_source:
            continue
        z = r.get("zone")
        if z in seen:
            continue
        # Auto-hide parking/garage/hospitality unless caller explicitly opts in.
        # Zone names like "Parking East", "Garage A", "Premium Parking", "Hospitality Tent".
        if not include_parking and z and _PARKING_ZONE_RE.search(z):
            parking_count += 1
            continue
        seen.add(z)
        out.append(r)

    # 3) Sort by tickets_count desc within the chosen source
    out.sort(key=lambda r: -(r.get("tickets_count") or 0))

    return {
        "zones": out,
        "count": len(out),
        "source": chosen_source,
        "available_sources": sorted(sources_present),
        "parking_hidden": parking_count,
        "include_parking": include_parking,
    }


@app.get("/api/broker/event/{event_id}/section-metrics")
def broker_event_section_metrics(event_id: int, _=Depends(require_auth)):
    """Tab 1: section-level metrics with delta vs prior snapshot."""
    db = require_sb()
    rows = (
        db.table("section_metrics")
        .select("captured_at,section,is_ancillary,tickets_count,groups_count,"
                "retail_min,retail_median,retail_mean,retail_max")
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(2000)
        .execute()
    ).data or []
    # Group by section, take the latest two captured_at per section
    by_section: dict[str, list] = {}
    for r in rows:
        by_section.setdefault(r["section"], []).append(r)

    out = []
    last_pull = None
    for section, snaps in by_section.items():
        snaps.sort(key=lambda x: x["captured_at"], reverse=True)
        c = snaps[0]
        p = snaps[1] if len(snaps) >= 2 else {}
        if last_pull is None or c["captured_at"] > last_pull:
            last_pull = c["captured_at"]
        out.append({
            "section": section,
            "is_ancillary": bool(c.get("is_ancillary")),
            "metrics": {k: {"v": c.get(k), "delta": _delta(c.get(k), p.get(k))}
                        for k in ["tickets_count", "groups_count",
                                  "retail_min", "retail_median", "retail_mean", "retail_max"]},
        })
    out.sort(key=lambda s: (s["is_ancillary"], s["section"]))

    # Cadence matches event listings cadence
    ev_meta = (db.table("events").select("occurs_at_local").eq("id", event_id).limit(1).execute().data or [{}])[0]
    cadence = _listings_cadence_seconds(ev_meta.get("occurs_at_local"))
    return {"sections": out, "last_pull_at": last_pull, "cadence_seconds": cadence}


@app.get("/api/broker/event/{event_id}/raw-tevo")
def broker_event_raw_tevo(event_id: int, force: bool = False, _=Depends(require_auth)):
    """Tab 3: raw TEvo /v9/ticket_groups payload. Reads cowork's
    tevo_ticket_groups_cache (90s TTL); fetches fresh if expired or force=1."""
    db = require_sb()
    if not force:
        cached = db.rpc("get_cached_ticket_groups", {"p_event_id": event_id}).execute().data
        if cached:
            return {"source": "cache", "groups": (cached or {}).get("ticket_groups", []),
                    "captured_at": (cached or {}).get("captured_at")}
    # Cache miss / forced refresh — fetch live
    try:
        live = client.get_ticket_groups(event_id)
    except RuntimeError as e:
        raise HTTPException(502, f"TEvo fetch failed: {e}")
    payload = {"ticket_groups": live.get("ticket_groups", []), "captured_at": datetime.now(timezone.utc).isoformat()}
    try:
        db.rpc("put_cached_ticket_groups", {"p_event_id": event_id, "p_payload": payload, "p_ttl_seconds": 90}).execute()
    except Exception:
        pass
    return {"source": "live", "groups": payload["ticket_groups"], "captured_at": payload["captured_at"]}


@app.get("/api/broker/watchlist-movers")
def broker_watchlist_movers(
    window_hours: int = 24,
    sort: str = "value",       # "value" → Δ market_val, "pct" → Δ market_pct
    limit: int = 25,
    _=Depends(require_auth),
):
    """Watchlisted events ordered by movement. Backs the WATCHLIST panel
    on the Events tab. Same row shape as /api/broker/movers events list,
    so the front-end can render it with shared code.

    Pulls get_event_movers for the window, filters to events present in
    watch_sources, then sorts by either notional Δ value or Δ %.
    """
    window_hours = max(1, min(int(window_hours), 168))
    db = require_sb()

    # 1. Watchlisted event_ids
    watch = (db.table("watch_sources").select("event_id").execute().data or [])
    watch_ids = {int(r["event_id"]) for r in watch if r.get("event_id") is not None}
    if not watch_ids:
        return {"window_hours": window_hours, "sort": sort, "count": 0, "events": []}

    # 2. Latest+prior aggregation via the existing RPC
    rpc_rows = db.rpc("get_event_movers", {"p_window_hours": window_hours}).execute().data or []

    def pct_delta(cur, prev):
        if cur is None or prev is None: return None
        try: c = float(cur); p = float(prev)
        except (TypeError, ValueError): return None
        if p == 0: return None
        return round((c - p) / p * 100, 2)
    def val(price, tix):
        if price is None or tix is None: return None
        try: return float(price) * float(tix)
        except (TypeError, ValueError): return None

    rows = []
    for r in rpc_rows:
        if int(r.get("event_id") or 0) not in watch_ids:
            continue
        cur_market_val  = val(r.get("cur_market_med"),  r.get("cur_market_tix"))
        prev_market_val = val(r.get("prev_market_med"), r.get("prev_market_tix"))
        cur_owned_val   = val(r.get("cur_owned_med"),   r.get("cur_owned_tix"))
        prev_owned_val  = val(r.get("prev_owned_med"),  r.get("prev_owned_tix"))
        rows.append({
            "event_id": r.get("event_id"),
            "name": r.get("name"),
            "venue_id": r.get("venue_id"),
            "venue_name": r.get("venue_name"),
            "occurs_at_local": r.get("occurs_at_local"),
            "latest_at":      r.get("latest_at"),
            "cur_market_med": r.get("cur_market_med"),
            "cur_market_tix": r.get("cur_market_tix"),
            "cur_owned_med":  r.get("cur_owned_med"),
            "cur_owned_tix":  r.get("cur_owned_tix"),
            "cur_owned_share": r.get("cur_owned_share"),  # v3: for "we ARE the market" badge
            "delta_market_pct": pct_delta(r.get("cur_market_med"), r.get("prev_market_med")),
            "delta_owned_pct":  pct_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
            "cur_market_val":  round(cur_market_val,  2) if cur_market_val  is not None else None,
            "cur_owned_val":   round(cur_owned_val,   2) if cur_owned_val   is not None else None,
            "delta_market_val": (None if cur_market_val is None or prev_market_val is None
                                 else round(cur_market_val - prev_market_val, 2)),
            "delta_owned_val":  (None if cur_owned_val is None or prev_owned_val is None
                                 else round(cur_owned_val - prev_owned_val, 2)),
        })

    # Sort: events with no movement signal sink to the bottom
    sort_key = "delta_market_val" if sort == "value" else "delta_market_pct"
    rows_with = [r for r in rows if r.get(sort_key) is not None]
    rows_with.sort(key=lambda r: abs(r[sort_key]), reverse=True)
    rows_without = [r for r in rows if r.get(sort_key) is None]
    out = (rows_with + rows_without)[: max(1, min(int(limit), 100))]

    return {"window_hours": window_hours, "sort": sort, "count": len(out), "events": out}


@app.get("/api/broker/performer/{performer_id}/espn")
def broker_performer_espn(performer_id: int, _=Depends(require_auth)):
    """ESPN context for a TEvo performer. Resolves performer_id → ESPN team_id
    via performer_external_ids (source='espn'), then pulls the latest team
    snapshot, current injuries, recent news, and the last 5 game snapshots
    involving that team.

    Returns: {
      applicable, performer_id, espn_team_id, league,
      team:    { record_summary, standing_summary, streak, win_pct, captured_at },
      injuries:[{ athlete_name, position, status, injury_type, return_date, ... }],
      news:    [{ headline, description, url, published_at, type }],
      recent:  [{ espn_event_id, captured_at, home_team_id, away_team_id, home_score, away_score, status_short }]
    }
    """
    db = require_sb()
    pei = (db.table("performer_external_ids")
             .select("performer_id, external_id, league, meta")
             .eq("performer_id", performer_id).eq("source", "espn")
             .limit(1).execute().data or [])
    if not pei:
        return {"applicable": False, "reason": "no ESPN mapping for this performer"}
    espn_team_id = str(pei[0]["external_id"])
    league       = pei[0]["league"]

    # Latest team snapshot (one row, most recent captured_at).
    team_rows = (db.table("espn_team_snapshots")
                   .select("captured_at, wins, losses, ties, win_pct, games_back, playoff_seed, conference_rank, division_rank, record_summary, standing_summary, streak")
                   .eq("espn_team_id", espn_team_id).eq("espn_league", league)
                   .order("captured_at", desc=True).limit(1).execute().data or [])

    # Current injuries — latest snapshot per athlete (last 24h).
    injuries = (db.table("espn_injuries_snapshots")
                  .select("athlete_id, athlete_name, position, status, injury_type, short_comment, return_date, captured_at")
                  .eq("espn_team_id", espn_team_id).eq("espn_league", league)
                  .gte("captured_at", (datetime.now(timezone.utc) - timedelta(hours=36)).isoformat())
                  .order("captured_at", desc=True).limit(50).execute().data or [])
    seen = set(); inj_dedup = []
    for x in injuries:
        k = x.get("athlete_id")
        if k in seen: continue
        seen.add(k); inj_dedup.append(x)

    # Recent news (last 30 days, top 8).
    news = (db.table("espn_news")
              .select("headline, description, url, published_at, type")
              .eq("espn_team_id", espn_team_id).eq("espn_league", league)
              .order("published_at", desc=True).limit(8).execute().data or [])

    # Last 5 finished/upcoming game snapshots where this team is home or away.
    recent = []
    try:
        recent = (db.rpc("get_team_recent_games", {"p_espn_team_id": espn_team_id, "p_league": league, "p_limit": 5}).execute().data or [])
    except Exception:
        # Fallback: query espn_event_snapshots directly (latest snap per event).
        rows_h = (db.table("espn_event_snapshots")
                    .select("espn_event_id, captured_at, status_short, state, home_team_id, away_team_id, home_score, away_score")
                    .eq("home_team_id", espn_team_id).eq("espn_league", league)
                    .order("captured_at", desc=True).limit(15).execute().data or [])
        rows_a = (db.table("espn_event_snapshots")
                    .select("espn_event_id, captured_at, status_short, state, home_team_id, away_team_id, home_score, away_score")
                    .eq("away_team_id", espn_team_id).eq("espn_league", league)
                    .order("captured_at", desc=True).limit(15).execute().data or [])
        all_rows = rows_h + rows_a
        seen_ev = set(); merged = []
        for x in sorted(all_rows, key=lambda r: r.get("captured_at", ""), reverse=True):
            ek = x.get("espn_event_id")
            if ek in seen_ev: continue
            seen_ev.add(ek); merged.append(x)
            if len(merged) >= 5: break
        recent = merged

    return {
        "applicable": True,
        "performer_id": performer_id,
        "espn_team_id": espn_team_id,
        "league": league,
        "team":     team_rows[0] if team_rows else None,
        "injuries": inj_dedup[:20],
        "news":     news,
        "recent":   recent,
    }


@app.post("/api/admin/seed-home-venues")
def admin_seed_home_venues(league: str, _=Depends(require_auth)):
    """One-shot admin: for every performer in performer_external_ids
    (source='espn') in the given league that's NOT yet in performer_home_venues,
    fetch /v9/performers/{id} from TEvo and upsert a home-venue row.

    Used to backfill MLS (which had 0 rows in performer_home_venues despite
    30 teams in performer_external_ids) and any other league that's missing
    venue resolution.

    Returns: { league, scanned, added, skipped_no_venue, errors }
    """
    db = require_sb()
    pei = (db.table("performer_external_ids")
             .select("performer_id, external_id, external_name, league")
             .eq("source", "espn").eq("league", league).execute().data or [])
    have = {r["performer_id"] for r in (db.table("performer_home_venues")
             .select("performer_id").eq("league", league).execute().data or [])}
    todo = [r for r in pei if r["performer_id"] not in have]

    added = 0; skipped = 0; errors: list[str] = []
    for r in todo:
        pid = int(r["performer_id"])
        try:
            perf = client.get_performer(pid, include_opponents=False)
            # TEvo returns the home venue under `venue` (singular) for sports.
            # `home_venue` is also populated for some leagues — fall back to it.
            v = perf.get("venue") or perf.get("home_venue") or {}
            vid = v.get("id")
            if not vid:
                skipped += 1
                continue
            addr = v.get("address") or {}
            location = ", ".join(x for x in [addr.get("locality"), addr.get("region")] if x) or v.get("location")
            db.table("performer_home_venues").upsert({
                "performer_id":   pid,
                "performer_name": perf.get("name") or r.get("external_name"),
                "venue_id":       int(vid),
                "venue_name":     v.get("name"),
                "venue_location": location,
                "league":         league,
                "source":         "tevo_lookup",
            }, on_conflict="performer_id").execute()
            added += 1
        except Exception as e:
            errors.append(f"performer_id={pid}: {e}")
    return {"league": league, "scanned": len(todo), "added": added, "skipped_no_venue": skipped, "errors": errors[:10]}


@app.get("/api/broker/event/{event_id}/espn")
def broker_event_espn(event_id: int, _=Depends(require_auth)):
    """Tab 2: ESPN aggregated data for home + away teams.
    Calls the espn edge fn server-side to keep the JWT off the wire."""
    if not (SUPABASE_URL and SUPABASE_ANON_KEY):
        raise HTTPException(500, "espn fn not reachable: missing SUPABASE_URL/SUPABASE_ANON_KEY")
    url = f"{SUPABASE_URL}/functions/v1/espn/event/{int(event_id)}"
    try:
        r = requests.get(url, headers={"Authorization": f"Bearer {SUPABASE_ANON_KEY}"}, timeout=15)
        return r.json() if r.ok else {"applicable": False, "error": f"espn fn {r.status_code}"}
    except Exception as e:
        return {"applicable": False, "error": str(e)}


@app.get("/api/broker/event/{event_id}/chart-data")
def broker_event_chart_data(
    event_id: int,
    days: int = 30,
    hours: int | None = None,
    range: str | None = None,   # "6h" "24h" "3d" "7d" "30d" "all"
    _=Depends(require_auth),
):
    """Stage 2 chart data: 4 default time-series + 4 overlay event streams.

    Series:
      prices_owned   — event_metrics.owned_median_retail
      prices_market  — event_metrics.retail_median
      counts_owned   — event_metrics.owned_tickets_count
      counts_market  — event_metrics.tickets_count
      home_standings — espn_team_snapshots filtered to home team (win_pct over time)
      away_standings — espn_team_snapshots filtered to away team (win_pct over time)

    Overlay events (vertical markers):
      injuries     — espn_injuries_snapshots, only is_baseline=false rows (real changes)
      roster_moves — espn_athlete_team_history with transaction_type in (traded, released)

    Last-5 record:
      espn_event_snapshots state='post' for either team, last 5 by captured_at,
      W/L computed from home_team_id + scores.
    """
    # Time range: prefer `range` (preset string) over `hours` over `days`.
    # Presets: 6h, 24h, 3d, 7d, 30d, all. Min 6h, max 30d (cap user-driven
    # views; 'all' bypasses the cap and pulls everything we have).
    range_hours: int | None = None
    if range:
        rmap = {"6h": 6, "24h": 24, "1d": 24, "3d": 72, "7d": 168, "30d": 720, "all": None}
        if range.lower() not in rmap:
            raise HTTPException(400, f"range must be one of {list(rmap)}")
        range_hours = rmap[range.lower()]
    elif hours is not None:
        range_hours = max(6, min(int(hours), 720))
    else:
        days = max(1, min(int(days), 180))
        range_hours = days * 24

    db = require_sb()
    if range_hours is None:
        # 'all' — pick a far-past floor so SELECTs still index well
        since_iso = "1970-01-01T00:00:00+00:00"
    else:
        since_iso = (datetime.now(timezone.utc) - timedelta(hours=range_hours)).isoformat()
    days = (range_hours // 24) if range_hours else 9999  # back-compat for any consumer reading `days`

    # 1) Full event_metrics distribution as time series — chart workbench
    # toggles any subset on/off. SELECT every column we collect.
    em = (
        db.table("event_metrics")
        .select(
            "captured_at,"
            "tickets_count,groups_count,sections_count,median_group_size,"
            "ancillary_groups,ancillary_tickets,"
            "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,retail_sum,"
            "wholesale_min,wholesale_median,wholesale_mean,wholesale_max,"
            "getin_price,top5_concentration,price_dispersion,tail_premium,"
            "owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
            "nonowned_median_retail,"   # NEW: median of non-S4K listings ("MARKET NOT US")
            "splits_min_q,splits_pct_pairs,splits_pct_singles,"
            "splits_listings_with_singles,splits_listings_with_pairs,"
            "splits_listings_with_3,splits_listings_with_4plus,splits_listings_no_split"
        )
        .eq("event_id", event_id)
        .gte("captured_at", since_iso)
        .order("captured_at")
        .execute()
    ).data or []

    def _series(col: str) -> list:
        return [{"t": r["captured_at"], "v": r.get(col)} for r in em]

    # Legacy aliases (preserved for backwards-compat)
    prices_owned    = _series("owned_median_retail")
    prices_market   = _series("retail_median")
    prices_nonowned = _series("nonowned_median_retail")  # NEW — "MARKET NOT US"
    counts_owned    = _series("owned_tickets_count")
    counts_market   = _series("tickets_count")

    # 2) Resolve home + away ESPN team ids from event_xref → espn_event_snapshots
    home_team_id = away_team_id = home_slug = away_slug = home_league = None
    xref = (
        db.table("event_xref").select("espn_event_id,espn_slug,espn_league")
        .eq("tevo_event_id", event_id).limit(1).execute()
    ).data or []
    if xref:
        x = xref[0]
        home_league = x["espn_league"]
        snap = (
            db.table("espn_event_snapshots")
            .select("home_team_id,away_team_id")
            .eq("espn_event_id", x["espn_event_id"])
            .order("captured_at", desc=True).limit(1)
            .execute()
        ).data or []
        if snap:
            home_team_id = snap[0].get("home_team_id")
            away_team_id = snap[0].get("away_team_id")
            home_slug = away_slug = x["espn_slug"]

    def _team_standings(team_id: str | None) -> list:
        if not team_id or not home_league:
            return []
        rows = (
            db.table("espn_team_snapshots")
            .select("captured_at,win_pct,wins,losses,games_back,playoff_seed,conference_rank,division_rank,record_summary,streak")
            .eq("espn_team_id", team_id)
            .eq("espn_league", home_league)   # league-scope: same id exists across leagues
            .gte("captured_at", since_iso)
            .order("captured_at")
            .execute()
        ).data or []
        return rows

    home_standings_rows = _team_standings(home_team_id)
    away_standings_rows = _team_standings(away_team_id)

    def _stand_series(rows: list, field: str) -> list:
        """Pluck one ESPN standings field into a t,v time-series."""
        return [{"t": r["captured_at"], "v": r.get(field)} for r in rows]

    # Legacy field kept for backwards-compat: home_standings/away_standings are
    # the win_pct series with extra metadata. New per-field series are emitted
    # separately so the chart workbench can plot any combination.
    home_standings = [{"t": r["captured_at"], "v": r.get("win_pct"),
                       "wins": r.get("wins"), "losses": r.get("losses"),
                       "seed": r.get("playoff_seed"), "rec": r.get("record_summary")}
                      for r in home_standings_rows]
    away_standings = [{"t": r["captured_at"], "v": r.get("win_pct"),
                       "wins": r.get("wins"), "losses": r.get("losses"),
                       "seed": r.get("playoff_seed"), "rec": r.get("record_summary")}
                      for r in away_standings_rows]

    # 3) Injury rows. Originally filtered is_baseline=false ("real status flips
    # only") but espn-collect's is_baseline detection only works for MLB+NHL —
    # NBA/NFL/MLS/WNBA/WC always come back with is_baseline=true, so the strict
    # filter hid 100% of their injury data. Relaxed to include baseline rows
    # too. Front-end tags each marker with `is_change` so the user can tell
    # status flips apart from initial-baseline injuries (copilot lane: fix
    # the upstream is_baseline detection in espn-collect).
    # CRITICAL: filter by espn_league too — espn_team_id is league-scoped
    # (id "18" = NBA Knicks AND MLB Pirates AND NFL Saints AND NHL #18 AND WNBA #18).
    # Without the league filter we'd pull 229 rows when only 12 are real.
    inj_rows = (
        db.table("espn_injuries_snapshots")
        .select("captured_at,athlete_name,status,injury_type,short_comment,espn_team_id,is_baseline")
        .in_("espn_team_id", [t for t in (home_team_id, away_team_id) if t])
        .eq("espn_league", home_league or "")
        .gte("captured_at", since_iso)
        .order("captured_at")
        .execute()
    ).data or [] if (home_team_id or away_team_id) and home_league else []
    injuries = [{"t": r["captured_at"], "athlete": r.get("athlete_name"),
                 "status": r.get("status"), "team": "home" if r.get("espn_team_id") == home_team_id else "away",
                 "comment": r.get("short_comment"),
                 "is_change": (r.get("is_baseline") is False)}  # true = real status flip; false = baseline row
                for r in inj_rows]

    # 4) Roster moves (trades + releases)
    rm_rows = []
    if (home_team_id or away_team_id) and home_league:
        rm_rows = (
            db.table("espn_athlete_team_history")
            .select("detected_at,transaction_type,prior_team_id,espn_team_id,espn_athlete_id,notes")
            .in_("transaction_type", ["traded", "released"])
            .eq("espn_league", home_league)   # league-scope; team_id+league together is the unique team
            .gte("detected_at", since_iso)
            .or_(",".join(filter(None, [
                f"espn_team_id.eq.{home_team_id}" if home_team_id else None,
                f"espn_team_id.eq.{away_team_id}" if away_team_id else None,
                f"prior_team_id.eq.{home_team_id}" if home_team_id else None,
                f"prior_team_id.eq.{away_team_id}" if away_team_id else None,
            ])) or "espn_team_id.eq.NULL")
            .order("detected_at")
            .execute()
        ).data or []
    roster_moves = [{"t": r["detected_at"], "type": r["transaction_type"],
                     "athlete_id": r.get("espn_athlete_id"),
                     "from_team": r.get("prior_team_id"), "to_team": r.get("espn_team_id"),
                     "notes": r.get("notes")} for r in rm_rows]

    # 5) Last-5 record per team
    def _last5(team_id: str | None) -> list:
        if not team_id or not home_league:
            return []
        rows = (
            db.table("espn_event_snapshots")
            .select("captured_at,espn_event_id,home_team_id,away_team_id,home_score,away_score,state")
            .or_(f"home_team_id.eq.{team_id},away_team_id.eq.{team_id}")
            .eq("espn_league", home_league)   # league-scope: id "20" exists in NBA + MLB + NFL etc.
            .eq("state", "post")
            .order("captured_at", desc=True).limit(5)
            .execute()
        ).data or []
        out = []
        for r in rows:
            h, a = r.get("home_score"), r.get("away_score")
            if h is None or a is None:
                continue
            is_home = r.get("home_team_id") == team_id
            won = (is_home and h > a) or (not is_home and a > h)
            out.append({"t": r["captured_at"], "result": "W" if won else "L",
                        "score": f"{h}-{a}", "home": is_home})
        return out

    last5_home = _last5(home_team_id)
    last5_away = _last5(away_team_id)

    # ----- News velocity per team (rows per hour bucket) -----
    def _news_series(team_id: str | None) -> list:
        if not team_id: return []
        nrows = (
            db.table("espn_news")
            .select("published_at")
            .eq("espn_team_id", team_id).eq("espn_league", home_league or "")
            .gte("published_at", since_iso)
            .order("published_at")
            .execute()
        ).data or []
        # Bucket to UTC hours for a clean stairstep series
        from collections import Counter
        buckets: Counter = Counter()
        for r in nrows:
            ts = r.get("published_at") or ""
            buckets[ts[:13]] += 1   # YYYY-MM-DDTHH
        return [{"t": k + ":00:00+00:00", "v": v} for k, v in sorted(buckets.items())]

    home_news = _news_series(home_team_id)
    away_news = _news_series(away_team_id)

    # ----- Active-injury count over time (per team) -----
    # For each injury status change, we don't easily know "is this player still
    # injured at time T" without a reverse pass. Approximation: count distinct
    # athlete_ids whose latest status change before T was not 'Active'. Cheap
    # forward-fill in Python — these tables are small.
    def _injury_load_series(team_id: str | None) -> list:
        if not team_id: return []
        rows = (
            db.table("espn_injuries_snapshots")
            .select("captured_at,athlete_id,status")
            .eq("espn_team_id", team_id).eq("espn_league", home_league or "")
            .gte("captured_at", since_iso)
            .order("captured_at")
            .execute()
        ).data or []
        # State: athlete_id -> latest status. Each row mutates state, emit count.
        state: dict[str, str] = {}
        out = []
        for r in rows:
            aid = r.get("athlete_id"); st = (r.get("status") or "").lower()
            if not aid: continue
            state[aid] = st
            active_injured = sum(1 for s in state.values() if s and s != "active")
            out.append({"t": r["captured_at"], "v": active_injured})
        return out

    home_injury_load = _injury_load_series(home_team_id)
    away_injury_load = _injury_load_series(away_team_id)

    # ----- Composite team_index with window-content-derived weights -----
    # Weight each signal by how much CONTENT (snapshots) it generated during
    # the visible window. Heavy injury-news day → injuries dominate the index.
    # Quiet news week → standings drive it. Per user spec.
    def _team_index_series(stand_rows, news_rows, inj_load_rows, team_id: str | None) -> tuple[list, dict]:
        if not team_id:
            return [], {}
        n_stand = len(stand_rows)
        n_news  = len(news_rows)
        n_inj   = len(inj_load_rows)
        total = max(n_stand + n_news + n_inj, 1)
        w = {"standings": n_stand/total, "news": n_news/total, "injury": n_inj/total}

        # Build a unified hourly grid from all three sources
        keypoints = sorted({r["t"] for r in (stand_rows + news_rows + inj_load_rows)})
        if not keypoints: return [], w

        # Forward-fill helpers
        def ff_value(rows, t):
            v = None
            for r in rows:
                if r["t"] <= t: v = r.get("v")
                else: break
            return v

        # Normalize each series to 0-100 within the window
        def vals(rs): return [r.get("v") for r in rs if r.get("v") is not None]
        s_vals = vals(stand_rows); n_vals = vals(news_rows); i_vals = vals(inj_load_rows)
        def norm(v, vs):
            if v is None or not vs: return 50.0  # neutral if no data
            mn, mx = min(vs), max(vs)
            if mx == mn: return 50.0
            return (float(v) - mn) / (mx - mn) * 100.0

        out = []
        for t in keypoints:
            s = norm(ff_value(stand_rows, t), s_vals)            # higher win% = higher
            n = norm(ff_value(news_rows,  t), n_vals)            # more news = higher (popularity proxy)
            i = 100.0 - norm(ff_value(inj_load_rows, t), i_vals) # MORE injuries = LOWER index
            idx = w["standings"]*s + w["news"]*n + w["injury"]*i
            out.append({"t": t, "v": round(idx, 2)})
        return out, w

    home_index, home_weights = _team_index_series(home_standings_rows, home_news, home_injury_load, home_team_id)
    away_index, away_weights = _team_index_series(away_standings_rows, away_news, away_injury_load, away_team_id)

    # ----- Per-zone time series (curated > fallback > unmapped, single source) -----
    # User spec: only render ONE zone classification, prefer curated. Returns one
    # series per zone with retail_median + tickets_count time points so the
    # chart workbench can plot any subset.
    zm_rows = (
        db.table("zone_metrics")
        .select("captured_at, zone, zone_source, retail_median, tickets_count, owned_tickets_count, owned_median_retail")
        .eq("event_id", event_id)
        .gte("captured_at", since_iso)
        .order("captured_at")
        .execute()
    ).data or []
    zm_sources = {r.get("zone_source") for r in zm_rows}
    if "curated" in zm_sources:   zm_chosen = "curated"
    elif "fallback" in zm_sources: zm_chosen = "fallback"
    elif "unmapped" in zm_sources: zm_chosen = "unmapped"
    else:                           zm_chosen = None
    zone_series: dict[str, dict] = {}
    if zm_chosen:
        for r in zm_rows:
            if r.get("zone_source") != zm_chosen: continue
            zname = r.get("zone") or "unmapped"
            ent = zone_series.setdefault(zname, {
                "zone": zname, "source": zm_chosen,
                "prices_market": [], "counts_market": [],
                "prices_owned":  [], "counts_owned":  [],
            })
            ent["prices_market"].append({"t": r["captured_at"], "v": r.get("retail_median")})
            ent["counts_market"].append({"t": r["captured_at"], "v": r.get("tickets_count")})
            ent["prices_owned"].append({"t": r["captured_at"], "v": r.get("owned_median_retail")})
            ent["counts_owned"].append({"t": r["captured_at"], "v": r.get("owned_tickets_count")})
    zone_series_list = sorted(zone_series.values(), key=lambda z: -sum(p.get("v") or 0 for p in z["counts_market"]))

    # Range metadata so the chart can pin its x-axis explicitly to the
    # requested window — prevents Chart.js from auto-fitting to whichever
    # series happens to have data, which collapsed 30d views to ~24h when
    # newer series (nonowned_median_retail, splits_min_q) hadn't backfilled
    # past their introduction date.
    until_iso = datetime.now(timezone.utc).isoformat()
    range_meta = {
        "range":    range or (f"{range_hours}h" if range_hours else "all"),
        "hours":    range_hours,
        "since":    since_iso if range_hours else None,  # None = open-left for 'all'
        "until":    until_iso,
    }

    return {
        "event_id": event_id,
        "days": days,
        "range_meta": range_meta,
        "series": {
            # ===== TEvo: prices and counts (legacy IDs preserved) =====
            "prices_owned":    prices_owned,
            "prices_market":   prices_market,
            "prices_nonowned": prices_nonowned,    # NEW: "MARKET NOT US" median
            "counts_owned":    counts_owned,
            "counts_market":   counts_market,
            # ===== TEvo: full retail percentile distribution =====
            "retail_min":     _series("retail_min"),
            "retail_p25":     _series("retail_p25"),
            "retail_p75":     _series("retail_p75"),
            "retail_p90":     _series("retail_p90"),
            "retail_max":     _series("retail_max"),
            "retail_mean":    _series("retail_mean"),
            "retail_sum":     _series("retail_sum"),
            # ===== TEvo: wholesale percentile distribution =====
            "wholesale_min":     _series("wholesale_min"),
            "wholesale_median":  _series("wholesale_median"),
            "wholesale_mean":    _series("wholesale_mean"),
            "wholesale_max":     _series("wholesale_max"),
            # ===== TEvo: structure and concentration =====
            "getin_price":          _series("getin_price"),
            "top5_concentration":   _series("top5_concentration"),
            "price_dispersion":     _series("price_dispersion"),
            "tail_premium":         _series("tail_premium"),
            "median_group_size":    _series("median_group_size"),
            "groups_count":         _series("groups_count"),
            "sections_count":       _series("sections_count"),
            "ancillary_tickets":    _series("ancillary_tickets"),
            "ancillary_groups":     _series("ancillary_groups"),
            # ===== TEvo: owned aggregates =====
            "owned_groups_count":   _series("owned_groups_count"),
            "owned_share":          _series("owned_share"),
            # ===== TEvo: splits inventory =====
            "splits_min_q":         _series("splits_min_q"),
            "splits_pct_pairs":     _series("splits_pct_pairs"),
            "splits_pct_singles":   _series("splits_pct_singles"),
            "splits_with_singles":  _series("splits_listings_with_singles"),
            "splits_with_pairs":    _series("splits_listings_with_pairs"),
            "splits_with_3":        _series("splits_listings_with_3"),
            "splits_with_4plus":    _series("splits_listings_with_4plus"),
            "splits_no_split":      _series("splits_listings_no_split"),
            # ===== ESPN standings: legacy combined + new per-field per-team =====
            "home_standings": home_standings,   # legacy alias for home_win_pct
            "away_standings": away_standings,
            "home_win_pct":     _stand_series(home_standings_rows, "win_pct"),
            "home_wins":        _stand_series(home_standings_rows, "wins"),
            "home_losses":      _stand_series(home_standings_rows, "losses"),
            "home_games_back":  _stand_series(home_standings_rows, "games_back"),
            "home_seed":        _stand_series(home_standings_rows, "playoff_seed"),
            "home_conf_rank":   _stand_series(home_standings_rows, "conference_rank"),
            "home_div_rank":    _stand_series(home_standings_rows, "division_rank"),
            "away_win_pct":     _stand_series(away_standings_rows, "win_pct"),
            "away_wins":        _stand_series(away_standings_rows, "wins"),
            "away_losses":      _stand_series(away_standings_rows, "losses"),
            "away_games_back":  _stand_series(away_standings_rows, "games_back"),
            "away_seed":        _stand_series(away_standings_rows, "playoff_seed"),
            "away_conf_rank":   _stand_series(away_standings_rows, "conference_rank"),
            "away_div_rank":    _stand_series(away_standings_rows, "division_rank"),
            # ===== ESPN news velocity =====
            "home_news_1h":     home_news,
            "away_news_1h":     away_news,
            # ===== ESPN injury load over time =====
            "home_injury_load": home_injury_load,
            "away_injury_load": away_injury_load,
            # ===== ESPN composite "team_index" (window-content-weighted) =====
            "home_team_index":  home_index,
            "away_team_index":  away_index,
        },
        "signal_weights": {
            "home": home_weights,
            "away": away_weights,
            "explainer": "Composite team_index = sum(weight_i * normalized_signal_i). Weights derived from how many content rows each signal source produced during the visible window — heavy news → news dominates; quiet news week → standings drive it.",
        },
        "overlays": {
            "injuries":     injuries,
            "roster_moves": roster_moves,
        },
        "last5": {
            "home": last5_home,
            "away": last5_away,
        },
        "teams": {
            "home_team_id": home_team_id,
            "away_team_id": away_team_id,
            "league":       home_league,
        },
        "zone_series": {
            "source":    zm_chosen,
            "available": sorted([s for s in zm_sources if s]),
            "zones":     zone_series_list,
        },
    }


@app.get("/api/broker/movers")
def broker_movers(window_hours: int = 24, include_inactive: bool = False, _=Depends(require_auth)):
    """Top 10 winners + losers at event / performer / venue level, owned vs market.
    Window: compare latest event_metrics row vs latest row from `window_hours` ago.

    Owned segment    = events with owned_tickets_count > 0 in current window
    Market segment   = events with market listings (regardless of owned)
    Returns 12 lists total: {events,performers,venues} × {owned,market} × {winners,losers}

    `include_inactive`: by default we exclude ghost / completed / cancelled events
    (lifecycle.is_active=false) so a Raptors playoff bracket that won't happen
    doesn't pollute the movers list. Pass true to see everything raw.
    """
    window_hours = max(1, min(int(window_hours), 168))
    db = require_sb()

    # Pre-aggregated in SQL via get_event_movers RPC (mig 20260508040000).
    # Returns one row per future-dated event with cur+prior values for
    # market_median / owned_median / market_tix / owned_tix. ~300 rows
    # max — small enough to top10/rollup in Python.
    #
    # Old approach (Python aggregation over a 50k-row window) was silently
    # capped at 1000 rows by PostgREST's per-request row limit, producing
    # an empty Movers report even when the underlying data was rich.
    rpc_rows = db.rpc("get_event_movers", {"p_window_hours": window_hours}).execute().data or []

    # Filter ghost/completed/cancelled events unless caller explicitly opts in.
    # event_lifecycle is a view over derive_event_lifecycle(); cheap to query
    # for the small id-set we get from the movers RPC.
    if rpc_rows and not include_inactive:
        ids = [r.get("event_id") for r in rpc_rows if r.get("event_id")]
        if ids:
            lc_rows = (
                db.table("event_lifecycle").select("event_id,status,is_active")
                .in_("event_id", ids).execute()
            ).data or []
            inactive = {r["event_id"] for r in lc_rows if not r.get("is_active")}
            if inactive:
                rpc_rows = [r for r in rpc_rows if r.get("event_id") not in inactive]

    def pct_delta(cur, prev):
        if cur is None or prev is None: return None
        try: c = float(cur); p = float(prev)
        except (TypeError, ValueError): return None
        if p == 0: return None
        return round((c - p) / p * 100, 2)

    def abs_delta(cur, prev):
        if cur is None or prev is None: return None
        try: return round(float(cur) - float(prev), 2)
        except (TypeError, ValueError): return None

    def _val(price, tix):
        if price is None or tix is None: return None
        try: return float(price) * float(tix)
        except (TypeError, ValueError): return None

    rows_built = []
    for r in rpc_rows:
        cur_market_val  = _val(r.get("cur_market_med"),  r.get("cur_market_tix"))
        prev_market_val = _val(r.get("prev_market_med"), r.get("prev_market_tix"))
        cur_owned_val   = _val(r.get("cur_owned_med"),   r.get("cur_owned_tix"))
        prev_owned_val  = _val(r.get("prev_owned_med"),  r.get("prev_owned_tix"))
        rows_built.append({
            "event_id":       r.get("event_id"),
            "name":           r.get("name"),
            "performer_id":   r.get("primary_performer_id"),
            "performer_name": r.get("primary_performer_name"),
            "venue_id":       r.get("venue_id"),
            "venue_name":     r.get("venue_name"),
            "occurs_at_local": r.get("occurs_at_local"),
            "latest_at":      r.get("latest_at"),
            "cur_market_med": r.get("cur_market_med"),
            "cur_market_tix": r.get("cur_market_tix"),
            "cur_owned_med":  r.get("cur_owned_med"),
            "cur_owned_tix":  r.get("cur_owned_tix"),
            "cur_owned_share": r.get("cur_owned_share"),  # v3: for "we ARE the market" badge
            "delta_market_pct": pct_delta(r.get("cur_market_med"), r.get("prev_market_med")),
            "delta_market_abs": abs_delta(r.get("cur_market_med"), r.get("prev_market_med")),
            "delta_owned_pct":  pct_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
            "delta_owned_abs":  abs_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
            # Notional ticket inventory marked-to-market — captures both price moves
            # AND inventory moves in a single number. Treat each event like a position:
            # value = price × quantity; Δvalue = (cur_price × cur_qty) − (prev_price × prev_qty).
            "cur_market_val":   round(cur_market_val,  2) if cur_market_val  is not None else None,
            "prev_market_val":  round(prev_market_val, 2) if prev_market_val is not None else None,
            "delta_market_val": (None if cur_market_val is None or prev_market_val is None
                                 else round(cur_market_val - prev_market_val, 2)),
            "cur_owned_val":    round(cur_owned_val,  2) if cur_owned_val  is not None else None,
            "prev_owned_val":   round(prev_owned_val, 2) if prev_owned_val is not None else None,
            "delta_owned_val":  (None if cur_owned_val is None or prev_owned_val is None
                                 else round(cur_owned_val - prev_owned_val, 2)),
        })

    if not rows_built:
        return {"window_hours": window_hours, "events": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []},
                "performers": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []},
                "venues": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []}}

    def top10(items, key, desc=True):
        filtered = [r for r in items if r.get(key) is not None]
        filtered.sort(key=lambda r: r[key], reverse=desc)
        return filtered[:10]

    # Owned segment = events where current owned tix > 0
    owned = [r for r in rows_built if (r.get("cur_owned_tix") or 0) > 0]
    market = rows_built  # all events being tracked (may or may not have owned)

    # Performer + venue rollups: weight by current market tickets
    def rollup(rows_in, group_key, name_key, id_key):
        agg: dict = {}
        for r in rows_in:
            gid = r.get(group_key)
            if gid is None: continue
            slot = agg.setdefault(gid, {
                id_key: gid, name_key: r.get(name_key.replace("name", "name")),
                "weighted_market_pct_num": 0.0, "weighted_market_pct_den": 0,
                "weighted_owned_pct_num": 0.0,  "weighted_owned_pct_den":  0,
                "events_count": 0, "owned_tix_total": 0, "market_tix_total": 0,
            })
            slot["events_count"] += 1
            slot["market_tix_total"] += int(r.get("cur_market_tix") or 0)
            slot["owned_tix_total"]  += int(r.get("cur_owned_tix") or 0)
            if r.get("delta_market_pct") is not None and (r.get("cur_market_tix") or 0) > 0:
                slot["weighted_market_pct_num"] += float(r["delta_market_pct"]) * int(r["cur_market_tix"])
                slot["weighted_market_pct_den"] += int(r["cur_market_tix"])
            if r.get("delta_owned_pct") is not None and (r.get("cur_owned_tix") or 0) > 0:
                slot["weighted_owned_pct_num"] += float(r["delta_owned_pct"]) * int(r["cur_owned_tix"])
                slot["weighted_owned_pct_den"] += int(r["cur_owned_tix"])
        out = []
        for slot in agg.values():
            slot["delta_market_pct"] = (round(slot["weighted_market_pct_num"] / slot["weighted_market_pct_den"], 2)
                                       if slot["weighted_market_pct_den"] else None)
            slot["delta_owned_pct"]  = (round(slot["weighted_owned_pct_num"]  / slot["weighted_owned_pct_den"], 2)
                                       if slot["weighted_owned_pct_den"]  else None)
            out.append({
                id_key: slot[id_key], "name": slot.get(name_key.replace("name", "name")),
                "events_count": slot["events_count"],
                "market_tix_total": slot["market_tix_total"],
                "owned_tix_total": slot["owned_tix_total"],
                "delta_market_pct": slot["delta_market_pct"],
                "delta_owned_pct":  slot["delta_owned_pct"],
            })
        return out

    perf_owned  = rollup(owned,  "performer_id", "performer_name", "performer_id")
    perf_market = rollup(market, "performer_id", "performer_name", "performer_id")
    venue_owned  = rollup(owned,  "venue_id", "venue_name", "venue_id")
    venue_market = rollup(market, "venue_id", "venue_name", "venue_id")

    # Build owned lists first, then exclude those entities from the market candidate
    # pool so a single Knicks game doesn't show up twice (top owned-winner AND top
    # market-winner). Market lists fill from the next-best non-owned candidates.
    def dedupe_market(market_pool, owned_w, owned_l, key):
        excluded = {r.get(key) for r in (owned_w + owned_l) if r.get(key) is not None}
        return [r for r in market_pool if r.get(key) not in excluded]

    ev_ow  = top10(owned,  "delta_owned_pct",  desc=True)
    ev_ol  = top10(owned,  "delta_owned_pct",  desc=False)
    ev_market_dedup = dedupe_market(market, ev_ow, ev_ol, "event_id")
    ev_mw  = top10(ev_market_dedup, "delta_market_pct", desc=True)
    ev_ml  = top10(ev_market_dedup, "delta_market_pct", desc=False)

    pf_ow  = top10(perf_owned,  "delta_owned_pct",  desc=True)
    pf_ol  = top10(perf_owned,  "delta_owned_pct",  desc=False)
    pf_market_dedup = dedupe_market(perf_market, pf_ow, pf_ol, "performer_id")
    pf_mw  = top10(pf_market_dedup, "delta_market_pct", desc=True)
    pf_ml  = top10(pf_market_dedup, "delta_market_pct", desc=False)

    vn_ow  = top10(venue_owned,  "delta_owned_pct",  desc=True)
    vn_ol  = top10(venue_owned,  "delta_owned_pct",  desc=False)
    vn_market_dedup = dedupe_market(venue_market, vn_ow, vn_ol, "venue_id")
    vn_mw  = top10(vn_market_dedup, "delta_market_pct", desc=True)
    vn_ml  = top10(vn_market_dedup, "delta_market_pct", desc=False)

    # Notional value movers: rank by abs $ change in (price × tickets) — the
    # mark-to-market on the inventory position. Captures both price drops and
    # inventory drawdowns in one score, which is what an options-style P&L would
    # weight too (no convexity in tickets, so it's pure delta×dS plus dN×price).
    ev_value_winners = top10([r for r in rows_built if r.get("delta_market_val") is not None], "delta_market_val", desc=True)
    ev_value_losers  = top10([r for r in rows_built if r.get("delta_market_val") is not None], "delta_market_val", desc=False)
    ev_owned_value_winners = top10([r for r in rows_built if r.get("delta_owned_val") is not None and (r.get("cur_owned_tix") or 0) > 0], "delta_owned_val", desc=True)
    ev_owned_value_losers  = top10([r for r in rows_built if r.get("delta_owned_val") is not None and (r.get("cur_owned_tix") or 0) > 0], "delta_owned_val", desc=False)

    return {
        "window_hours": window_hours,
        # Caption surfaced by the UI so users understand what they're looking at.
        "ranking": {
            "metric_owned":  "delta_owned_pct",
            "metric_market": "delta_market_pct",
            "metric_value":  "delta_market_val (cur_med × cur_tix − prev_med × prev_tix)",
            "weighting":     "events: unweighted % change. performer/venue rollups: ticket-count-weighted average. Value lists: absolute $ change in inventory mark-to-market.",
            "dedupe_rule":   "market_winners/losers exclude any entity already in owned_winners/losers; market lists fill from next-best non-owned candidates.",
        },
        "events": {
            "owned_winners":  ev_ow,  "owned_losers":  ev_ol,
            "market_winners": ev_mw,  "market_losers": ev_ml,
            "value_winners":  ev_value_winners, "value_losers": ev_value_losers,
            "owned_value_winners": ev_owned_value_winners, "owned_value_losers": ev_owned_value_losers,
        },
        "performers": {"owned_winners": pf_ow, "owned_losers": pf_ol, "market_winners": pf_mw, "market_losers": pf_ml},
        "venues":     {"owned_winners": vn_ow, "owned_losers": vn_ol, "market_winners": vn_mw, "market_losers": vn_ml},
    }


@app.get("/api/broker/event/{event_id}/cadences")
def broker_event_cadences(event_id: int, _=Depends(require_auth)):
    """Per-section poll cadence for the page. Each section reads its own
    last_pull_at + cadence_seconds; next poll = last + cadence + jitter."""
    db = require_sb()
    ev = (db.table("events").select("id,occurs_at_local").eq("id", event_id).limit(1).execute().data or [{}])[0]
    listings_cad = _listings_cadence_seconds(ev.get("occurs_at_local"))
    # last_pull_at for listings = most recent event_metrics row
    last_listings = (
        db.table("event_metrics").select("captured_at")
        .eq("event_id", event_id).order("captured_at", desc=True).limit(1)
        .execute()
    ).data or []
    last_listings_at = last_listings[0]["captured_at"] if last_listings else None

    # ESPN injuries cadence = 10 min (espn-roster-10min cron)
    last_inj = (
        db.table("espn_injuries_snapshots").select("last_seen_at")
        .order("last_seen_at", desc=True).limit(1).execute()
    ).data or []
    last_inj_at = last_inj[0]["last_seen_at"] if last_inj else None

    # ESPN team standings cadence = daily; ESPN scores/odds for events ±24h = 10 min
    last_team_snap = (
        db.table("espn_team_snapshots").select("last_seen_at")
        .order("last_seen_at", desc=True).limit(1).execute()
    ).data or []
    last_team_at = last_team_snap[0]["last_seen_at"] if last_team_snap else None

    return {
        "event_id": event_id,
        "sections": {
            "overview":        {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
            "section_metrics": {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
            "raw_tevo":        {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
            "espn_injuries":   {"last_pull_at": last_inj_at,      "cadence_seconds": 60 * 10},
            "espn_team":       {"last_pull_at": last_team_at,     "cadence_seconds": 60 * 60 * 24},
        },
    }
