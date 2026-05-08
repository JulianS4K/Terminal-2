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


@app.get("/api/events/{event_id}")
def event_detail(event_id: int, _=Depends(require_auth)):
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
    return {
        "event": event,
        "stats": stats,
        "stats_event_only": stats_event_only,
        "ticket_groups": listings.get("ticket_groups", []),
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


@app.get("/api/portfolio")
def portfolio(
    performer_id: int | None = None,
    venue_id: int | None = None,
    watchlist_only: bool = False,
    _=Depends(require_auth),
):
    """Aggregated portfolio across multiple events.

    Filters (one required):
        performer_id    - events where this performer is primary OR in performer_ids[]
        venue_id        - events at this venue
        watchlist_only  - events that originated from any watchlist row (via watch_sources)

    Returns: { filter, events: [...latest metric per event...], aggregate: {...rollups...} }
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

    # 4) Merge per-event
    out_events = []
    for ev in ev_meta:
        m = metrics_by_id.get(ev["id"], {})
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
        },
        "events": out_events,
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

    # Latest two event_metrics for delta computation
    em_rows = (
        db.table("event_metrics")
        .select(
            "captured_at,tickets_count,groups_count,sections_count,"
            "retail_min,retail_median,retail_p75,retail_p90,retail_max,retail_sum,"
            "wholesale_median,getin_price,owned_groups_count,owned_tickets_count,"
            "owned_share,owned_median_retail,price_dispersion,top5_concentration"
        )
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(2)
        .execute()
    ).data or []
    curr = em_rows[0] if len(em_rows) >= 1 else {}
    prev = em_rows[1] if len(em_rows) >= 2 else {}

    metric_keys = [
        "tickets_count", "groups_count", "sections_count",
        "retail_min", "retail_median", "retail_p75", "retail_p90", "retail_max", "retail_sum",
        "wholesale_median", "getin_price",
        "owned_groups_count", "owned_tickets_count", "owned_share", "owned_median_retail",
        "price_dispersion", "top5_concentration",
    ]
    metrics = {k: {"v": curr.get(k), "delta": _delta(curr.get(k), prev.get(k))} for k in metric_keys}

    # Zone breakdown — owned + market split via cowork's RPC
    zones_owned = db.rpc("get_event_zones_rollup", {"p_event_id": event_id, "p_owned_only": True}).execute().data or []
    zones_market = db.rpc("get_event_zones_rollup", {"p_event_id": event_id, "p_owned_only": False}).execute().data or []

    cadence = _listings_cadence_seconds(head.get("occurs_at_local") if head else None)
    last_pull = curr.get("captured_at")

    return {
        "event": head,
        "metrics": metrics,
        "zones": {"owned": zones_owned, "market": zones_market},
        "last_pull_at": last_pull,
        "cadence_seconds": cadence,
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
def broker_event_chart_data(event_id: int, days: int = 30, _=Depends(require_auth)):
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
    days = max(1, min(int(days), 180))
    db = require_sb()
    since_iso = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()

    # 1) Price + count series from event_metrics
    em = (
        db.table("event_metrics")
        .select("captured_at,retail_median,owned_median_retail,tickets_count,owned_tickets_count")
        .eq("event_id", event_id)
        .gte("captured_at", since_iso)
        .order("captured_at")
        .execute()
    ).data or []
    prices_owned  = [{"t": r["captured_at"], "v": r.get("owned_median_retail")} for r in em]
    prices_market = [{"t": r["captured_at"], "v": r.get("retail_median")}        for r in em]
    counts_owned  = [{"t": r["captured_at"], "v": r.get("owned_tickets_count")}  for r in em]
    counts_market = [{"t": r["captured_at"], "v": r.get("tickets_count")}        for r in em]

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
        if not team_id:
            return []
        rows = (
            db.table("espn_team_snapshots")
            .select("captured_at,win_pct,wins,losses,playoff_seed,record_summary")
            .eq("espn_team_id", team_id)
            .gte("captured_at", since_iso)
            .order("captured_at")
            .execute()
        ).data or []
        return [{"t": r["captured_at"], "v": r.get("win_pct"),
                 "wins": r.get("wins"), "losses": r.get("losses"),
                 "seed": r.get("playoff_seed"), "rec": r.get("record_summary")} for r in rows]

    home_standings = _team_standings(home_team_id)
    away_standings = _team_standings(away_team_id)

    # 3) Injury changes (only rows where is_baseline=false → real status flip)
    inj_rows = (
        db.table("espn_injuries_snapshots")
        .select("captured_at,athlete_name,status,injury_type,short_comment,espn_team_id")
        .in_("espn_team_id", [t for t in (home_team_id, away_team_id) if t])
        .eq("is_baseline", False)
        .gte("captured_at", since_iso)
        .order("captured_at")
        .execute()
    ).data or [] if (home_team_id or away_team_id) else []
    injuries = [{"t": r["captured_at"], "athlete": r.get("athlete_name"),
                 "status": r.get("status"), "team": "home" if r.get("espn_team_id") == home_team_id else "away",
                 "comment": r.get("short_comment")} for r in inj_rows]

    # 4) Roster moves (trades + releases)
    rm_rows = []
    if home_team_id or away_team_id:
        rm_rows = (
            db.table("espn_athlete_team_history")
            .select("detected_at,transaction_type,prior_team_id,espn_team_id,espn_athlete_id,notes")
            .in_("transaction_type", ["traded", "released"])
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
        if not team_id:
            return []
        rows = (
            db.table("espn_event_snapshots")
            .select("captured_at,espn_event_id,home_team_id,away_team_id,home_score,away_score,state")
            .or_(f"home_team_id.eq.{team_id},away_team_id.eq.{team_id}")
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

    return {
        "event_id": event_id,
        "days": days,
        "series": {
            "prices_owned":   prices_owned,
            "prices_market":  prices_market,
            "counts_owned":   counts_owned,
            "counts_market":  counts_market,
            "home_standings": home_standings,
            "away_standings": away_standings,
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
