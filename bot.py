"""
Messaging bot — read-only query interface to Terminal-2 data over SMS or WhatsApp.

Inbound message (Twilio webhook) → signature verify → whitelist check →
Claude API tool-use loop → reply via TwiML.

Required env vars (webhook returns 503 if any missing):
  ANTHROPIC_API_KEY    — separate key for the bot, not the session
  TWILIO_AUTH_TOKEN    — for inbound signature verification

Optional env vars:
  WHATSAPP_BOT_MODEL   — defaults to "claude-sonnet-4-6"
  WHATSAPP_MAX_TURNS   — defaults to 6 (tool-use loop cap)
  SUPABASE_URL         — required for on-demand event refresh (already needed by app.py)
  CRON_SECRET          — required for on-demand event refresh (already needed by collect)
  EVENT_REFRESH_TIMEOUT_S — HTTP timeout for the Edge Function call, default 25
"""
from __future__ import annotations

import json
import os
from typing import Any

import requests
from fastapi import APIRouter, Form, Request, HTTPException
from fastapi.responses import Response

router = APIRouter()

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY")
TWILIO_AUTH_TOKEN = os.environ.get("TWILIO_AUTH_TOKEN")
SUPABASE_URL = os.environ.get("SUPABASE_URL")
CRON_SECRET = os.environ.get("CRON_SECRET")
BOT_MODEL = os.environ.get("WHATSAPP_BOT_MODEL", "claude-sonnet-4-6")
MAX_TURNS = int(os.environ.get("WHATSAPP_MAX_TURNS", "6"))
EVENT_REFRESH_TIMEOUT_S = float(os.environ.get("EVENT_REFRESH_TIMEOUT_S", "25"))

SYSTEM_PROMPT = """You are a terse market-intelligence assistant for S4K Entertainment, a secondary ticket broker.

The user texts you over WhatsApp. Reply in Bloomberg-terminal style: short, dense, numeric. Hard target: under 160 characters per reply (single SMS segment). If more is genuinely needed, split into two segments.
Use abbreviations (KNX@ATL G4, $458 med, +17.7%/24h, own 32%). Never wrap output in code blocks or markdown.

You have two sets of tools:

(A) Cached metrics from our Supabase store — refreshed every 20 minutes for events on our watchlist (~488 tracked events). These tools go through a rate-limit gate (get_or_authorize_pull): back-to-back queries serve from cache, and any on-demand refresh feeds the same listings_snapshots the terminal UI reads, which keeps TEvo calls down. Richer (S4K owned share, dispersion, tail premium, portfolio rollups) but only cover events we follow.
  - search_events, get_event_snapshot, get_market_movement, get_portfolio, get_owned_inventory, get_high_value_owned, get_event_zones (internal only)

(B) Live Ticket Evolution API — direct read for ANY event in TEvo's catalog (millions). Slower (~1-2s), uses raw TEvo rate budget per call, does NOT update our cache. Less rich (no owned share, no dispersion).
  - tevo_search_events, tevo_event_detail, tevo_event_stats, tevo_listings, tevo_search_performers, tevo_search_venues

Decision rule: prefer (A) for any event likely on our watchlist (NBA playoffs, Yankees, Knicks, big NYC venues). Fall back to (B) only when (A) returns nothing OR for events we obviously don't track (random concert tour, college football, etc.). Don't run both (A) and (B) on the same event in one turn — that's a redundant TEvo call. When you don't know an event_id, search by name first; prefer search_events over tevo_search_events for the same reason.

When listing events, always include venue (short form, e.g. MSG, TD Gdn, Xfin) and date/time. Default to upcoming events only — call out explicitly if the user asked for past events. For zone queries call get_event_zones (internal-only, permissions checked server-side); sections without curated rules come back as 'unmapped' — surface that count rather than inventing a zone. Returns zone, tickets, min and max retail per zone (no groups, no median — keep replies tight).
Always call a tool when the user asks for live numbers; never guess. If a query is ambiguous, ask one short clarifying question.

If a tool returns nothing useful, say so plainly. Don't pad with caveats. Maximum reply length: 320 characters (2 SMS segments)."""

# ---------------------------------------------------------------------------
# Tool definitions for the Anthropic API
# ---------------------------------------------------------------------------

TOOLS: list[dict[str, Any]] = [
    {
        "name": "search_events",
        "description": (
            "Search tracked events by free-text query or filter. "
            "Defaults to UPCOMING events only (occurs_at_local >= now). "
            "For past events pass include_past=true OR an explicit start_at in the past. "
            "Returns id, name, occurs_at_local, venue_name, primary_performer_name."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Free-text match against event name"},
                "performer_id": {"type": "integer"},
                "venue_id": {"type": "integer"},
                "days_ahead": {
                    "type": "integer",
                    "description": "Window length in days from now (shorthand: sets end_at = now + N days). Lower bound is still now() unless include_past=true.",
                },
                "start_at": {
                    "type": "string",
                    "description": "ISO 8601 lower bound on occurs_at_local (e.g. '2026-05-06T00:00:00Z'). Overrides the default now() lower bound.",
                },
                "end_at": {
                    "type": "string",
                    "description": "ISO 8601 upper bound on occurs_at_local. Overrides days_ahead if both given.",
                },
                "include_past": {
                    "type": "boolean",
                    "default": False,
                    "description": "If true, drop the default now() lower bound to include past events.",
                },
                "limit": {"type": "integer", "default": 10},
            },
        },
    },
    {
        "name": "get_event_snapshot",
        "description": "Latest metrics for one event: tickets remaining, retail percentiles, get-in, S4K owned share, dispersion. Use when the user asks for current state of a specific event.",
        "input_schema": {
            "type": "object",
            "required": ["event_id"],
            "properties": {"event_id": {"type": "integer"}},
        },
    },
    {
        "name": "get_market_movement",
        "description": "Period-over-period change for one event's metrics. Returns open/now/delta for retail_median, retail_p25/p75/p90, get-in, tickets_count.",
        "input_schema": {
            "type": "object",
            "required": ["event_id"],
            "properties": {
                "event_id": {"type": "integer"},
                "hours_back": {"type": "integer", "default": 24, "description": "Lookback window in hours, default 24"},
            },
        },
    },
    {
        "name": "get_portfolio",
        "description": "Aggregate rollup across all events for a performer or venue: events count, tickets total, S4K owned share weighted, total retail value.",
        "input_schema": {
            "type": "object",
            "properties": {
                "performer_id": {"type": "integer"},
                "venue_id": {"type": "integer"},
            },
        },
    },
    {
        "name": "get_owned_inventory",
        "description": "List S4K-owned ticket groups, optionally filtered by event_id or minimum retail price. Returns section, row, qty, retail_price per group.",
        "input_schema": {
            "type": "object",
            "properties": {
                "event_id": {"type": "integer"},
                "min_retail_price": {"type": "number"},
                "limit": {"type": "integer", "default": 15},
            },
        },
    },
    {
        "name": "get_high_value_owned",
        "description": "Top events ranked by S4K's retail-value exposure (owned_tickets * owned_median_retail). Useful for 'where am I most exposed' queries.",
        "input_schema": {
            "type": "object",
            "properties": {"limit": {"type": "integer", "default": 10}},
        },
    },
    {
        "name": "tevo_search_events",
        "description": "LIVE Ticket Evolution event search. Last-resort fallback when the event isn't on our watchlist; prefer search_events first. Counts against TEvo rate budget and does NOT update our cache.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "performer_id": {"type": "integer"},
                "venue_id": {"type": "integer"},
                "limit": {"type": "integer", "default": 8},
            },
        },
    },
    {
        "name": "tevo_event_detail",
        "description": "LIVE Ticket Evolution event metadata. Use only when the event isn't on our watchlist; otherwise the cached events row already has this.",
        "input_schema": {
            "type": "object",
            "required": ["event_id"],
            "properties": {"event_id": {"type": "integer"}},
        },
    },
    {
        "name": "tevo_event_stats",
        "description": "LIVE Ticket Evolution aggregate stats. Use ONLY for off-watchlist events; for watchlist events use get_event_snapshot — that goes through the cache+rate-limit gate and feeds the terminal UI.",
        "input_schema": {
            "type": "object",
            "required": ["event_id"],
            "properties": {
                "event_id": {"type": "integer"},
                "inventory_type": {"type": "string", "enum": ["event", "parking"], "description": "Filter to seats only ('event') or parking only. Omit for all."},
            },
        },
    },
    {
        "name": "tevo_listings",
        "description": "LIVE Ticket Evolution marketplace listings — cheapest N groups for one event. Use only for off-watchlist events; on-watchlist events read from listings_snapshots via get_event_snapshot or get_owned_inventory.",
        "input_schema": {
            "type": "object",
            "required": ["event_id"],
            "properties": {
                "event_id": {"type": "integer"},
                "limit": {"type": "integer", "default": 8},
            },
        },
    },
    {
        "name": "tevo_search_performers",
        "description": "LIVE Ticket Evolution performer search by name. Use to resolve a performer_id when the user names a team/artist not in our watchlist.",
        "input_schema": {
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer", "default": 5},
            },
        },
    },
    {
        "name": "tevo_search_venues",
        "description": "LIVE Ticket Evolution venue search by name. Use to resolve a venue_id when the user names a venue we don't have in our cache.",
        "input_schema": {
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer", "default": 5},
            },
        },
    },
    {
        "name": "get_event_zones",
        "description": (
            "INTERNAL ONLY. Zone-level breakdown for one event using the manually curated "
            "performer_zones + performer_zone_rules tables (Courtside, Club Platinum, '100 Corner', "
            "'U2 11-25', etc — names vary per performer/venue). Sections without a curated rule "
            "are bucketed as 'unmapped' (do NOT invent a zone). "
            "Defaults to S4K-owned only — pass owned_only=false to see the whole market. "
            "Returns: zone, tickets, min_retail, max_retail (no groups, no median — kept terse for SMS)."
        ),
        "input_schema": {
            "type": "object",
            "required": ["event_id"],
            "properties": {
                "event_id": {"type": "integer"},
                "owned_only": {
                    "type": "boolean",
                    "default": True,
                    "description": "If true (default), only S4K-owned listings are aggregated.",
                },
            },
        },
    },
]

# ---------------------------------------------------------------------------
# Tool handlers — each returns a plain dict that Claude can read.
# Wrap existing Supabase queries / endpoint logic.
# ---------------------------------------------------------------------------

def _tool_search_events(db, query: str | None = None, performer_id: int | None = None,
                        venue_id: int | None = None, days_ahead: int | None = None,
                        start_at: str | None = None, end_at: str | None = None,
                        include_past: bool = False, limit: int = 10) -> dict:
    from datetime import datetime, timedelta, timezone
    now = datetime.now(timezone.utc)

    q = db.table("events").select("id,name,occurs_at_local,venue_name,primary_performer_name")

    # Lower bound: explicit start_at > include_past escape > default-now
    if start_at is not None:
        q = q.gte("occurs_at_local", start_at)
    elif not include_past:
        q = q.gte("occurs_at_local", now.isoformat())

    # Upper bound: explicit end_at > days_ahead shorthand > unbounded
    if end_at is not None:
        q = q.lte("occurs_at_local", end_at)
    elif days_ahead is not None:
        cutoff = (now + timedelta(days=int(days_ahead))).isoformat()
        q = q.lte("occurs_at_local", cutoff)

    if performer_id is not None:
        q = q.or_(f"primary_performer_id.eq.{int(performer_id)},performer_ids.cs.{{{int(performer_id)}}}")
    if venue_id is not None:
        q = q.eq("venue_id", int(venue_id))
    if query:
        q = q.ilike("name", f"%{query}%")

    rows = (q.order("occurs_at_local").limit(min(int(limit), 25)).execute().data) or []
    return {"count": len(rows), "events": rows}


def _trigger_event_refresh(event_id: int, pull_id: int | None = None) -> dict:
    """Invoke the collect-listings Edge Function for one event. Returns a small status dict."""
    if not (SUPABASE_URL and CRON_SECRET):
        return {"ok": False, "error": "SUPABASE_URL or CRON_SECRET not set"}
    base = SUPABASE_URL.rstrip("/")
    if "/functions/v1" not in base:
        base = f"{base}/functions/v1"
    url = f"{base}/collect-listings"
    params = {"event_id": int(event_id)}
    if pull_id is not None:
        params["pull_id"] = int(pull_id)
    try:
        r = requests.post(url, params=params, headers={"x-cron-secret": CRON_SECRET},
                          timeout=EVENT_REFRESH_TIMEOUT_S)
        try:
            body = r.json()
        except ValueError:
            body = {"raw": r.text[:200]}
        return {"ok": r.ok, "status": r.status_code, **(body if isinstance(body, dict) else {})}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"request failed: {e}"}


def _tool_event_snapshot(db, event_id: int, requester: str | None = None,
                         source: str = "sms", max_age_seconds: int = 300) -> dict:
    """Latest metrics for one event with cache + rate-limit gating.

    Flow:
      1. Call get_or_authorize_pull to log the request and decide cache/fresh/limited.
      2. If fresh: fire the Edge Function, then read latest_event_metrics.
      3. Always return whatever the latest snapshot is (even if rate-limited / fetch failed),
         tagged with the served_from + age.
    """
    decision = (db.rpc("get_or_authorize_pull", {
        "p_event_id": int(event_id),
        "p_source": source,
        "p_requester": requester,
        "p_max_age_seconds": int(max_age_seconds),
    }).execute().data) or {}
    served = decision.get("decision", "unknown")
    pull_id = decision.get("pull_id")

    refresh_status = None
    if served == "fetch_fresh":
        refresh_status = _trigger_event_refresh(int(event_id), pull_id=pull_id)
        if not refresh_status.get("ok"):
            served = "fresh_failed"

    ev = (db.table("events").select("id,name,occurs_at_local,venue_name,primary_performer_name")
          .eq("id", int(event_id)).maybeSingle().execute().data) or {}
    m = (db.table("latest_event_metrics").select("*").eq("event_id", int(event_id))
         .maybeSingle().execute().data) or {}
    if not ev and not m:
        return {"error": f"event_id {event_id} not found"}

    return {
        "event": ev,
        "metrics": m,
        "served_from": served,
        "snapshot_age_seconds": decision.get("age_seconds"),
        "rate_limit_reason": decision.get("reason"),
        "retry_after_seconds": decision.get("retry_after_seconds"),
        "refresh_status": refresh_status,
    }


def _tool_market_movement(db, event_id: int, hours_back: int = 24) -> dict:
    from datetime import datetime, timedelta, timezone
    since = (datetime.now(timezone.utc) - timedelta(hours=int(hours_back))).isoformat()
    rows = (db.table("event_metrics").select(
        "captured_at,tickets_count,groups_count,"
        "retail_min,retail_p25,retail_median,retail_p75,retail_p90,retail_max,getin_price,"
        "owned_tickets_count,owned_share")
        .eq("event_id", int(event_id))
        .gte("captured_at", since)
        .order("captured_at").execute().data) or []
    if len(rows) < 2:
        return {"event_id": int(event_id), "hours_back": hours_back, "points": len(rows),
                "note": "not enough history in window"}
    open_, now = rows[0], rows[-1]
    keys = ["tickets_count", "retail_min", "retail_p25", "retail_median", "retail_p75",
            "retail_p90", "retail_max", "getin_price", "owned_tickets_count"]
    deltas = {}
    for k in keys:
        o = open_.get(k); n = now.get(k)
        if o is None or n is None:
            continue
        try:
            o_f = float(o); n_f = float(n)
            pct = ((n_f - o_f) / o_f * 100) if o_f != 0 else None
            deltas[k] = {"open": o, "now": n, "delta": round(n_f - o_f, 2),
                         "pct": round(pct, 2) if pct is not None else None}
        except (TypeError, ValueError):
            continue
    return {"event_id": int(event_id), "hours_back": hours_back, "points": len(rows),
            "open_at": open_.get("captured_at"), "now_at": now.get("captured_at"),
            "movement": deltas}


def _tool_portfolio(db, performer_id: int | None = None, venue_id: int | None = None) -> dict:
    if performer_id is None and venue_id is None:
        return {"error": "provide performer_id or venue_id"}
    if performer_id is not None:
        rows = (db.table("events").select("id")
                .or_(f"primary_performer_id.eq.{int(performer_id)},performer_ids.cs.{{{int(performer_id)}}}")
                .execute().data) or []
    else:
        rows = (db.table("events").select("id").eq("venue_id", int(venue_id)).execute().data) or []
    event_ids = [r["id"] for r in rows]
    if not event_ids:
        return {"events_count": 0, "tickets_total": 0, "owned_tickets_total": 0, "retail_value_total": 0}
    metrics = (db.table("latest_event_metrics").select(
        "event_id,tickets_count,owned_tickets_count,retail_sum,retail_median,owned_median_retail")
        .in_("event_id", event_ids).execute().data) or []
    tickets_total = sum(int(m.get("tickets_count") or 0) for m in metrics)
    owned_total = sum(int(m.get("owned_tickets_count") or 0) for m in metrics)
    retail_value = sum(float(m.get("retail_sum") or 0) for m in metrics)
    owned_value = sum(int(m.get("owned_tickets_count") or 0) * float(m.get("owned_median_retail") or 0)
                      for m in metrics)
    return {
        "events_count": len(metrics),
        "tickets_total": tickets_total,
        "owned_tickets_total": owned_total,
        "owned_share_pct": round(owned_total / tickets_total * 100, 2) if tickets_total else None,
        "retail_value_total": round(retail_value, 2),
        "owned_retail_value_total": round(owned_value, 2),
        "events_with_owned": sum(1 for m in metrics if (m.get("owned_tickets_count") or 0) > 0),
    }


def _tool_owned_inventory(db, event_id: int | None = None, min_retail_price: float | None = None,
                          limit: int = 15) -> dict:
    q = (db.table("listings_snapshots").select(
        "event_id,section,row,quantity,retail_price,office_name,captured_at")
         .eq("is_owned", True).order("captured_at", desc=True))
    if event_id is not None:
        q = q.eq("event_id", int(event_id))
    if min_retail_price is not None:
        q = q.gte("retail_price", float(min_retail_price))
    rows = q.limit(min(int(limit), 50)).execute().data or []
    return {"count": len(rows), "rows": rows}


def _tool_event_zones(db, event_id: int, owned_only: bool = True,
                      requester: str | None = None, source: str = "sms") -> dict:
    """Zone-level breakdown for one event. Internal-only (checks bot_users.is_internal).

    Output is intentionally narrow: zone, tickets, min_retail, max_retail. No groups
    or median — those bloat SMS replies without changing decisions.
    """
    if not requester:
        return {"error": "internal data requires an authenticated requester"}
    user = (db.table("bot_users").select("is_internal,active")
            .eq("phone", requester).maybeSingle().execute().data) or None
    if not user or not user.get("is_internal"):
        return {"error": "not authorized — zone data is internal only"}

    # Use the shared rate-limit / cache layer so on-demand pulls keep the snapshot fresh.
    decision = (db.rpc("get_or_authorize_pull", {
        "p_event_id": int(event_id),
        "p_source": source,
        "p_requester": requester,
        "p_max_age_seconds": 300,
    }).execute().data) or {}
    if decision.get("decision") == "fetch_fresh":
        _trigger_event_refresh(int(event_id), pull_id=decision.get("pull_id"))

    rollup = (db.rpc("get_event_zones_rollup", {
        "p_event_id": int(event_id),
        "p_owned_only": bool(owned_only),
    }).execute().data) or []
    return {
        "event_id": int(event_id),
        "owned_only": bool(owned_only),
        "snapshot_age_seconds": decision.get("age_seconds"),
        "served_from": decision.get("decision"),
        "zones": rollup,
    }


def _tool_high_value_owned(db, limit: int = 10) -> dict:
    metrics = (db.table("latest_event_metrics").select(
        "event_id,owned_tickets_count,owned_median_retail,owned_share")
        .gt("owned_tickets_count", 0).execute().data) or []
    if not metrics:
        return {"count": 0, "rows": []}
    for m in metrics:
        m["owned_value"] = int(m.get("owned_tickets_count") or 0) * float(m.get("owned_median_retail") or 0)
    metrics.sort(key=lambda m: m["owned_value"], reverse=True)
    metrics = metrics[: int(limit)]
    event_ids = [m["event_id"] for m in metrics]
    events = {e["id"]: e for e in (db.table("events").select("id,name,occurs_at_local,venue_name")
                                   .in_("id", event_ids).execute().data or [])}
    out = []
    for m in metrics:
        e = events.get(m["event_id"], {})
        out.append({
            "event_id": m["event_id"],
            "name": e.get("name"),
            "occurs_at_local": e.get("occurs_at_local"),
            "venue": e.get("venue_name"),
            "owned_tickets": m["owned_tickets_count"],
            "owned_median": m["owned_median_retail"],
            "owned_share": m["owned_share"],
            "exposure_usd": round(m["owned_value"], 2),
        })
    return {"count": len(out), "rows": out}



# ---------------------------------------------------------------------------
# Live Ticket Evolution tool handlers (use the EvoClient from app.py)
# ---------------------------------------------------------------------------

def _evo():
    """Lazy import the configured EvoClient singleton from app.py."""
    from app import client as evo
    return evo


def _primary_performer_name(ev: dict) -> str | None:
    for p in (ev.get("performances") or []):
        if p.get("primary"):
            return ((p.get("performer") or {}).get("name"))
    return None


def _tool_tevo_search_events(db, query: str | None = None, performer_id: int | None = None,
                             venue_id: int | None = None, limit: int = 8) -> dict:
    try:
        events = _evo().search_events_all(
            q=query or None,
            performer_id=performer_id,
            venue_id=venue_id,
            only_with_available_tickets=True,
            order_by="events.popularity_score DESC",
        )
    except Exception as e:  # noqa: BLE001
        return {"error": f"TEvo error: {e}"}
    events = events[: int(limit)]
    return {
        "count": len(events),
        "events": [
            {
                "id": e.get("id"),
                "name": e.get("name"),
                "occurs_at_local": e.get("occurs_at_local"),
                "venue": (e.get("venue") or {}).get("name"),
                "city": ((e.get("venue") or {}).get("location") or "").split(",")[0] or None,
                "performer": _primary_performer_name(e),
            }
            for e in events
        ],
    }


def _tool_tevo_event_detail(db, event_id: int) -> dict:
    try:
        e = _evo().get_event(int(event_id))
    except Exception as ex:  # noqa: BLE001
        return {"error": f"TEvo error: {ex}"}
    return {
        "id": e.get("id"),
        "name": e.get("name"),
        "occurs_at_local": e.get("occurs_at_local"),
        "venue": (e.get("venue") or {}).get("name"),
        "venue_location": (e.get("venue") or {}).get("location"),
        "performer": _primary_performer_name(e),
        "state": e.get("state"),
    }


def _tool_tevo_event_stats(db, event_id: int, inventory_type: str | None = None) -> dict:
    try:
        s = _evo().get_event_stats(int(event_id), inventory_type=inventory_type)
    except Exception as ex:  # noqa: BLE001
        return {"error": f"TEvo error: {ex}"}
    return {
        "event_id": int(event_id),
        "inventory_type": inventory_type,
        "ticket_groups_count": s.get("ticket_groups_count"),
        "tickets_count": s.get("tickets_count"),
        "retail_price_min": s.get("retail_price_min"),
        "retail_price_avg": s.get("retail_price_avg"),
        "retail_price_max": s.get("retail_price_max"),
        "retail_price_sum": s.get("retail_price_sum"),
        "wholesale_price_avg": s.get("wholesale_price_avg"),
    }


def _tool_tevo_listings(db, event_id: int, limit: int = 8) -> dict:
    try:
        resp = _evo().get_listings(int(event_id), order_by="retail_price ASC")
    except Exception as ex:  # noqa: BLE001
        return {"error": f"TEvo error: {ex}"}
    groups = resp.get("ticket_groups") or []
    out = groups[: int(limit)]
    return {
        "event_id": int(event_id),
        "total_groups": len(groups),
        "shown": len(out),
        "cheapest": [
            {
                "section": g.get("section"),
                "row": g.get("row"),
                "qty": g.get("available_quantity"),
                "retail": g.get("retail_price"),
                "format": g.get("format"),
                "splits": g.get("splits"),
                "type": g.get("type"),
            }
            for g in out
        ],
    }


def _tool_tevo_search_performers(db, query: str, limit: int = 5) -> dict:
    try:
        resp = _evo().search_performers(q=query)
    except Exception as ex:  # noqa: BLE001
        return {"error": f"TEvo error: {ex}"}
    perfs = (resp.get("performers") or [])[: int(limit)]
    return {
        "count": len(perfs),
        "performers": [
            {
                "id": p.get("id"),
                "name": p.get("name"),
                "category": (p.get("category") or {}).get("name"),
                "popularity": p.get("popularity_score"),
            }
            for p in perfs
        ],
    }


def _tool_tevo_search_venues(db, query: str, limit: int = 5) -> dict:
    try:
        resp = _evo().search_venues(q=query)
    except Exception as ex:  # noqa: BLE001
        return {"error": f"TEvo error: {ex}"}
    venues = (resp.get("venues") or [])[: int(limit)]
    return {
        "count": len(venues),
        "venues": [
            {
                "id": v.get("id"),
                "name": v.get("name"),
                "city": (v.get("address") or {}).get("locality"),
                "state": (v.get("address") or {}).get("region"),
                "country": (v.get("address") or {}).get("country_code"),
            }
            for v in venues
        ],
    }


TOOL_HANDLERS = {
    "search_events": _tool_search_events,
    "get_event_snapshot": _tool_event_snapshot,
    "get_market_movement": _tool_market_movement,
    "get_portfolio": _tool_portfolio,
    "get_owned_inventory": _tool_owned_inventory,
    "get_high_value_owned": _tool_high_value_owned,
    "tevo_search_events": _tool_tevo_search_events,
    "tevo_event_detail": _tool_tevo_event_detail,
    "tevo_event_stats": _tool_tevo_event_stats,
    "tevo_listings": _tool_tevo_listings,
    "tevo_search_performers": _tool_tevo_search_performers,
    "tevo_search_venues": _tool_tevo_search_venues,
    "get_event_zones": _tool_event_zones,
}

# ---------------------------------------------------------------------------
# Twilio signature verification
# ---------------------------------------------------------------------------

def _verify_twilio_signature(request_url: str, params: dict[str, str], header_signature: str) -> bool:
    """Validate X-Twilio-Signature header per Twilio's HMAC-SHA1 scheme."""
    if not TWILIO_AUTH_TOKEN or not header_signature:
        return False
    import base64
    import hashlib
    import hmac
    payload = request_url
    for key in sorted(params.keys()):
        payload += key + params[key]
    digest = hmac.new(TWILIO_AUTH_TOKEN.encode(), payload.encode(), hashlib.sha1).digest()
    expected = base64.b64encode(digest).decode()
    return hmac.compare_digest(expected, header_signature)

# ---------------------------------------------------------------------------
# Anthropic tool-use orchestration
# ---------------------------------------------------------------------------

# Tools that need caller context (for rate-limiting + audit). The model's tool schema
# does NOT expose these args, so we force-inject them here regardless of what the
# model passes — preventing a spoofed requester from circumventing the rate limit.
_CONTEXT_INJECTED_TOOLS = {"get_event_snapshot", "get_event_zones"}


def _run_claude_loop(db, user_message: str, requester: str | None = None, source: str = "sms") -> str:
    """Run the multi-turn tool-use loop. Returns the final text reply."""
    try:
        from anthropic import Anthropic
    except ImportError:
        return "bot offline (anthropic SDK not installed)"
    if not ANTHROPIC_API_KEY:
        return "bot offline (ANTHROPIC_API_KEY not set)"
    client = Anthropic(api_key=ANTHROPIC_API_KEY)

    messages: list[dict] = [{"role": "user", "content": user_message}]
    for _turn in range(MAX_TURNS):
        resp = client.messages.create(
            model=BOT_MODEL,
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
        )
        if resp.stop_reason == "tool_use":
            tool_results = []
            for block in resp.content:
                if getattr(block, "type", None) == "tool_use":
                    handler = TOOL_HANDLERS.get(block.name)
                    if handler is None:
                        result_str = json.dumps({"error": f"unknown tool {block.name}"})
                    else:
                        args = dict(block.input or {})
                        if block.name in _CONTEXT_INJECTED_TOOLS:
                            args["requester"] = requester
                            args["source"] = source
                        try:
                            result = handler(db, **args)
                            result_str = json.dumps(result, default=str)
                        except Exception as e:  # noqa: BLE001
                            result_str = json.dumps({"error": f"tool error: {e}"})
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result_str,
                    })
            # Add the assistant's tool_use turn + our tool_result turn
            messages.append({"role": "assistant", "content": resp.content})
            messages.append({"role": "user", "content": tool_results})
            continue
        # End-of-turn: collect text blocks
        out_text = "".join(getattr(b, "text", "") for b in resp.content if getattr(b, "type", None) == "text")
        return (out_text or "").strip() or "no reply"
    return "loop hit max_turns; aborting"

# ---------------------------------------------------------------------------
# Webhook
# ---------------------------------------------------------------------------

def _twiml(message: str) -> Response:
    """Twilio Messaging webhook expects TwiML XML in the response body."""
    safe = (message or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    safe = safe[:1500]  # WhatsApp body limit ~4096 but stay defensive
    body = f'<?xml version="1.0" encoding="UTF-8"?><Response><Message>{safe}</Message></Response>'
    return Response(content=body, media_type="application/xml")


@router.post("/sms/webhook")
async def sms_webhook(request: Request):
    return await _handle_inbound(request, channel="sms")


@router.post("/whatsapp/webhook")
async def whatsapp_webhook(request: Request):
    return await _handle_inbound(request, channel="whatsapp")


async def _handle_inbound(request: Request, channel: str):
    if not ANTHROPIC_API_KEY or not TWILIO_AUTH_TOKEN:
        raise HTTPException(503, "WhatsApp bot not configured")
    # Lazy-import the Supabase client used by the tool handlers
    from app import require_sb
    db = require_sb()

    form = await request.form()
    params = {k: str(v) for k, v in form.items()}
    body_in = params.get("Body", "").strip()
    raw_from = params.get("From", "").strip()
    from_phone = raw_from.replace("whatsapp:", "") if channel == "whatsapp" else raw_from
    message_sid = params.get("MessageSid")

    # Verify Twilio signed the request. Build the URL Twilio used (proxy may have stripped scheme).
    forwarded_proto = request.headers.get("x-forwarded-proto", request.url.scheme)
    public_url = f"{forwarded_proto}://{request.headers.get('host', request.url.netloc)}{request.url.path}"
    sig = request.headers.get("x-twilio-signature", "")
    if not _verify_twilio_signature(public_url, params, sig):
        # Audit and reject
        try:
            db.table("bot_messages").insert({
                "direction": "in", "phone": from_phone, "body": body_in,
                "message_sid": message_sid, "meta": {"reject": "bad_signature"},
            }).execute()
        except Exception:
            pass
        raise HTTPException(403, "bad signature")

    # Audit-log the inbound (regardless of whitelist outcome)
    try:
        db.table("bot_messages").insert({
            "channel": channel, "direction": "in", "phone": from_phone, "body": body_in,
            "message_sid": message_sid,
        }).execute()
    except Exception:
        pass

    # Whitelist check
    user = (db.table("bot_users").select("phone,label,active")
            .eq("phone", from_phone).maybeSingle().execute().data) or None
    if not user or not user.get("active"):
        reply = "not authorized — contact julian@s4kent.com"
    else:
        try:
            reply = _run_claude_loop(db, body_in, requester=from_phone, source=channel)
        except Exception as e:  # noqa: BLE001
            reply = f"bot error: {e}"

    # Audit-log the outbound
    try:
        db.table("bot_messages").insert({
            "channel": channel, "direction": "out", "phone": from_phone, "body": reply,
        }).execute()
    except Exception:
        pass

    return _twiml(reply)
