"""Eventbrite organizer read route — discovered events + price/availability.

Mirrors routers/axs.py: a single service-role read of the TicketsData-discovered
Eventbrite events (td_discovered_events, platform='eventbrite') enriched from the
stored raw /events item (face price band, sold-out / availability, image, venue
geo). Eventbrite is a PRIMARY ticketer surfaced via the TicketsData /events feed
(discovery only — no /fetch inventory pull yet). td_discovered_events is RLS
service-role-only, so — like axs_* — the backend is the only path the terminal's
user-JWT client has to this set. Factory takes a live require_sb getter +
require_auth (owned by server.py); no upstream API calls happen here.
"""
from __future__ import annotations

from typing import Callable

from fastapi import APIRouter, Depends


def _num(v):
    """Coerce a raw JSON price to float, or None. Eventbrite sends numbers, but
    guard against strings/blanks in the raw envelope."""
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def build_eventbrite_router(get_require_sb: Callable[[], Callable], require_auth: Callable) -> APIRouter:
    router = APIRouter()

    @router.get("/api/eventbrite/events")
    def eventbrite_events(upcoming: bool = False, limit: int = 500, _=Depends(require_auth)):
        """Every Eventbrite event discovered for the tracked organizer(s), from
        td_discovered_events (platform='eventbrite'). `upcoming=true` restricts to
        event_date >= today (the frontend also filters client-side). Face price
        band + sold-out / availability + image come from the stored raw item."""
        limit = max(1, min(int(limit), 2000))
        db = get_require_sb()()
        q = (
            db.table("td_discovered_events")
            .select("td_event_id,event_url,event_name,event_date,venue_name,city,"
                    "performer_label,matched_tevo_event_id,raw,discovered_at")
            .eq("platform", "eventbrite")
        )
        if upcoming:
            # event_date is a date column; compare against today's UTC date.
            from datetime import datetime, timezone
            q = q.gte("event_date", datetime.now(timezone.utc).date().isoformat())
        rows = (q.order("event_date", desc=False).limit(limit).execute()).data or []

        out = []
        for r in rows:
            raw = r.get("raw") or {}
            venue = raw.get("venue") if isinstance(raw.get("venue"), dict) else {}
            pmin = _num(raw.get("min_ticket_price"))
            pmax = _num(raw.get("max_ticket_price"))
            out.append({
                "td_event_id": r.get("td_event_id"),
                "event_url": r.get("event_url"),
                "event_name": r.get("event_name"),
                "event_date": r.get("event_date"),
                "venue_name": r.get("venue_name"),
                "city": r.get("city"),
                "region": venue.get("region"),
                "tevo_event_id": r.get("matched_tevo_event_id"),
                "linked": r.get("matched_tevo_event_id") is not None,
                "currency": raw.get("currency"),
                "price_min": pmin,
                "price_max": pmax,
                "is_free": bool(raw.get("is_free")),
                "sold_out": bool(raw.get("is_sold_out")),
                "has_tickets": bool(raw.get("has_available_tickets")),
                "waitlist": bool(raw.get("waitlist_available")),
                "sales_status": raw.get("sales_status"),
                "event_status": raw.get("event_status"),
                "age_restriction": raw.get("age_restriction"),
                "image_url": raw.get("image_url"),
                "discovered_at": r.get("discovered_at"),
            })
        return {
            "count": len(out),
            "linked": sum(1 for e in out if e["linked"]),
            "on_sale": sum(1 for e in out if e["has_tickets"] and not e["sold_out"]),
            "sold_out": sum(1 for e in out if e["sold_out"]),
            "events": out,
        }

    return router
