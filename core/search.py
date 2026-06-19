"""SQL-only storefront search — extracted from app.py (BR-CODE-1).

`search_sql_only` is the STOREFRONT_SQL_ONLY search path: ILIKE across our own
`events` + `performer_metadata` tables (never TEvo), returning the same shape as
the live path so the client stays mode-agnostic. Self-contained: takes a live
`db` client and depends outward only on core.helpers (one-directional: search ->
core, never reverse). Moved verbatim from app.py.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone

from core.helpers import (
    is_speculative_event_name as _is_speculative_event_name,
    or_ilike_clause as _or_ilike_clause,
)


_ILIKE_WILDCARDS = ("\\", "%", "_")


def _escape_ilike(s: str) -> str:
    """Escape PostgREST ILIKE wildcards in a user-supplied substring."""
    for ch in _ILIKE_WILDCARDS:
        s = s.replace(ch, "\\" + ch)
    return s


def search_sql_only(db, q_norm: str, limit: int) -> dict:
    """SQL-only search: ILIKE across our `events` + `performer_metadata` for
    queries when STOREFRONT_SQL_ONLY=true. Always hits Supabase, never TEvo.
    Returns the same shape as the live path so the client is mode-agnostic.
    """
    today_iso = datetime.now(timezone.utc).date().isoformat()
    # Strip characters that break PostgREST's or_() clause parser:
    # commas (clause separator), periods (operator separator), parens
    # (grouping). The replacement char is a space so multi-token queries
    # still work via ILIKE's wildcard handling.
    safe_q = re.sub(r"[,.()\"]", " ", q_norm).strip()
    if not safe_q:
        return {"events": [], "performers": [], "venues": [], "source": "sql"}
    # Escape ILIKE wildcards (%, _, \) so a user-supplied "%" doesn't
    # become a match-everything pattern. We wrap with our own %...%
    # after the escape.
    pattern = f"%{_escape_ilike(safe_q)}%"

    # Events: search by event name, venue name, venue location, primary
    # performer name. Limit to future + active so we don't surface ghosts.
    # Uses _or_ilike_clause for defense-in-depth: today the pattern has
    # been sanitized at line ~4467 so the legacy raw f-string would work,
    # but if that sanitization ever loosens this site would re-introduce
    # the PostgREST or-clause-separator bug that broke /api/store/movers.
    try:
        ev_rows = (db.table("events")
                     .select("id,name,occurs_at_local,venue_name,venue_location,"
                             "primary_performer_id,primary_performer_name")
                     .gte("occurs_at_local", today_iso)
                     .or_(",".join([
                         _or_ilike_clause("name", pattern),
                         _or_ilike_clause("venue_name", pattern),
                         _or_ilike_clause("venue_location", pattern),
                         _or_ilike_clause("primary_performer_name", pattern),
                     ]))
                     .order("occurs_at_local", desc=False)
                     .limit(80)
                     .execute().data) or []
    except Exception as e:
        print(f"search_sql_only events query failed: {e}")
        ev_rows = []

    # Tag with we_own + from_price via latest_event_metrics. Drop speculative
    # names (CANCELLED / (If Necessary) / (Date TBD)) — consumer storefront
    # should not surface playoff "may not happen" inventory.
    ev_rows = [e for e in ev_rows if not _is_speculative_event_name(e.get("name"))]
    if ev_rows:
        ev_ids = [int(e["id"]) for e in ev_rows if e.get("id")]
        metrics: dict[int, dict] = {}
        if ev_ids:
            try:
                rows = (db.table("latest_event_metrics")
                          .select("event_id,owned_tickets_count,owned_groups_count,retail_min")
                          .in_("event_id", ev_ids).execute().data) or []
                metrics = {int(r["event_id"]): r for r in rows if r.get("event_id")}
            except Exception:
                metrics = {}
        # Drop inactive (ghost/cancelled) events.
        try:
            lc = (db.table("event_lifecycle")
                    .select("event_id,is_active")
                    .in_("event_id", ev_ids).execute().data) or []
            inactive = {int(r["event_id"]) for r in lc if not r.get("is_active")}
        except Exception:
            inactive = set()
        ev_rows = [e for e in ev_rows if int(e.get("id") or 0) not in inactive]
    else:
        metrics = {}

    # Bias toward owned inventory: when a query like "aces" matches multiple
    # teams (Reno Aces minor-league + Las Vegas Aces WNBA), the soonest event
    # wins under the default occurs_at_local ASC sort even when we don't own
    # any inventory for that team. Audit 2026-05-16 found "aces" returning
    # Reno Aces first; we own Las Vegas Aces 5/17. Re-sort so events with
    # owned inventory come first, soonest among them next.
    ev_rows_sorted = sorted(
        ev_rows,
        key=lambda e: (
            0 if (metrics.get(int(e.get("id") or 0)) or {}).get("owned_tickets_count") else 1,
            e.get("occurs_at_local") or "9999-12-31",
        ),
    )

    events_out = []
    for e in ev_rows_sorted[:limit]:
        eid = int(e.get("id") or 0)
        m = metrics.get(eid) or {}
        events_out.append({
            "id": eid,
            "name": e.get("name"),
            "venue_name": e.get("venue_name"),
            "location": e.get("venue_location"),
            "occurs_at": e.get("occurs_at_local"),
            "we_own": bool(m.get("owned_tickets_count")),
            "from_price": m.get("retail_min"),
            "owned_tix": m.get("owned_tickets_count"),
        })

    # Performers via performer_metadata name match.
    try:
        pf_rows = (db.table("performer_metadata")
                     .select("performer_id,name,espn_league")
                     .ilike("name", pattern)
                     .limit(limit)
                     .execute().data) or []
    except Exception:
        pf_rows = []
    performers_out = [{
        "id": int(p.get("performer_id") or 0),
        "name": p.get("name"),
        "league": p.get("espn_league"),
    } for p in pf_rows if p.get("performer_id")]

    # Venues — derive from events distinct venue rows for SQL-only mode.
    # We don't have a public venues table; use distinct venue_name from
    # upcoming events matching the query.
    venues_out: list[dict] = []
    try:
        vn_rows = (db.table("events")
                     .select("venue_id,venue_name,venue_location")
                     .gte("occurs_at_local", today_iso)
                     .or_(",".join([
                         _or_ilike_clause("venue_name", pattern),
                         _or_ilike_clause("venue_location", pattern),
                     ]))
                     .limit(40)
                     .execute().data) or []
        seen: set[int] = set()
        for v in vn_rows:
            vid = int(v.get("venue_id") or 0)
            if vid in seen or not vid:
                continue
            seen.add(vid)
            venues_out.append({
                "id": vid,
                "name": v.get("venue_name"),
                "location": v.get("venue_location"),
            })
            if len(venues_out) >= limit:
                break
    except Exception:
        pass

    return {
        "events": events_out,
        "performers": performers_out,
        "venues": venues_out,
        "source": "sql",
    }
