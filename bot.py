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
"""
from __future__ import annotations

import json
import os
from typing import Any

from fastapi import APIRouter, Form, Request, HTTPException
from fastapi.responses import Response

router = APIRouter()

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY")
TWILIO_AUTH_TOKEN = os.environ.get("TWILIO_AUTH_TOKEN")
BOT_MODEL = os.environ.get("WHATSAPP_BOT_MODEL", "claude-sonnet-4-6")
MAX_TURNS = int(os.environ.get("WHATSAPP_MAX_TURNS", "6"))

SYSTEM_PROMPT = """You are a terse market-intelligence assistant for S4K Entertainment, a secondary ticket broker.

The user texts you over WhatsApp. Reply in Bloomberg-terminal style: short, dense, numeric. Hard target: under 160 characters per reply (single SMS segment). If more is genuinely needed, split into two segments.
Use abbreviations (KNX@ATL G4, $458 med, +17.7%/24h, own 32%). Never wrap output in code blocks or markdown.

You have tools to query the live Terminal database (events, snapshots, S4K owned inventory, portfolio rollups).
Always call a tool when the user asks for live numbers; never guess. If a query is ambiguous, ask one short clarifying question.

If a tool returns nothing useful, say so plainly. Don't pad with caveats. Maximum reply length: 320 characters (2 SMS segments)."""

# ---------------------------------------------------------------------------
# Tool definitions for the Anthropic API
# ---------------------------------------------------------------------------

TOOLS: list[dict[str, Any]] = [
    {
        "name": "search_events",
        "description": "Search tracked events by free-text query or filter. Returns id, name, occurs_at_local, venue.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Free-text match against event name"},
                "performer_id": {"type": "integer"},
                "venue_id": {"type": "integer"},
                "days_ahead": {"type": "integer", "description": "Filter to events occurring within next N days"},
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
]

# ---------------------------------------------------------------------------
# Tool handlers — each returns a plain dict that Claude can read.
# Wrap existing Supabase queries / endpoint logic.
# ---------------------------------------------------------------------------

def _tool_search_events(db, query: str | None = None, performer_id: int | None = None,
                        venue_id: int | None = None, days_ahead: int | None = None,
                        limit: int = 10) -> dict:
    q = db.table("events").select("id,name,occurs_at_local,venue_name,primary_performer_name")
    if performer_id is not None:
        q = q.or_(f"primary_performer_id.eq.{int(performer_id)},performer_ids.cs.{{{int(performer_id)}}}")
    if venue_id is not None:
        q = q.eq("venue_id", int(venue_id))
    if query:
        q = q.ilike("name", f"%{query}%")
    rows = (q.order("occurs_at_local").limit(min(int(limit), 25)).execute().data) or []
    if days_ahead:
        from datetime import datetime, timedelta, timezone
        cutoff = (datetime.now(timezone.utc) + timedelta(days=int(days_ahead))).isoformat()
        rows = [r for r in rows if (r.get("occurs_at_local") or "") <= cutoff]
    return {"count": len(rows), "events": rows}


def _tool_event_snapshot(db, event_id: int) -> dict:
    ev = (db.table("events").select("id,name,occurs_at_local,venue_name,primary_performer_name")
          .eq("id", int(event_id)).maybeSingle().execute().data) or {}
    m = (db.table("latest_event_metrics").select("*").eq("event_id", int(event_id))
         .maybeSingle().execute().data) or {}
    if not ev and not m:
        return {"error": f"event_id {event_id} not found"}
    return {"event": ev, "metrics": m}


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


TOOL_HANDLERS = {
    "search_events": _tool_search_events,
    "get_event_snapshot": _tool_event_snapshot,
    "get_market_movement": _tool_market_movement,
    "get_portfolio": _tool_portfolio,
    "get_owned_inventory": _tool_owned_inventory,
    "get_high_value_owned": _tool_high_value_owned,
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

def _run_claude_loop(db, user_message: str) -> str:
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
            # Extract tool_use blocks, run handlers, append tool_result, loop
            tool_results = []
            for block in resp.content:
                if getattr(block, "type", None) == "tool_use":
                    handler = TOOL_HANDLERS.get(block.name)
                    if handler is None:
                        result_str = json.dumps({"error": f"unknown tool {block.name}"})
                    else:
                        try:
                            result = handler(db, **(block.input or {}))
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
            reply = _run_claude_loop(db, body_in)
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
