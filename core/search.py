"""SQL-only storefront search — extracted from app.py (BR-CODE-1).

`search_sql_only` is the STOREFRONT_SQL_ONLY search path: ILIKE across our own
`events` + `performer_metadata` tables (never TEvo), returning the same shape as
the live path so the client stays mode-agnostic. Self-contained: takes a live
`db` client and depends outward only on core.helpers (one-directional: search ->
core, never reverse). Moved verbatim from app.py.
"""
from __future__ import annotations

import logging
import re
import time
from datetime import datetime, timezone

from core.helpers import (
    is_speculative_event_name as _is_speculative_event_name,
    or_ilike_clause as _or_ilike_clause,
)

_log = logging.getLogger("core.search")


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
    # Uses _or_ilike_clause for defense-in-depth: `pattern` was already
    # sanitized above (the `safe_q` re.sub + `_escape_ilike` step) so the
    # legacy raw f-string would work, but if that sanitization ever loosens
    # this site would re-introduce the PostgREST or-clause-separator bug that
    # broke /api/store/movers.
    try:
        ev_rows = (db.table("events")
                     .select("id,name,occurs_at_local,venue_name,venue_location,"
                             "primary_performer_id,primary_performer_name,state")
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
    # Drop speculative names AND operator-ignored events (state='ignored', e.g.
    # pseudo-events). Client-side: PostgREST .neq() would also drop NULL states.
    ev_rows = [e for e in ev_rows
               if not _is_speculative_event_name(e.get("name"))
               and (e.get("state") or "") != "ignored"]
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


# ---------------------------------------------------------------------------
# Live search + the sports-player layer + the in-process suggestion cache.
# Moved from server.py (BR-CODE-1 core/ helper pass). The cache dict, the
# lazy TEvo client factory (ensure_client), and the SQL-only fallback
# (search_sql_only) are INJECTED by the server wrappers so the server-module
# monkeypatches (app._search_cache / app.ensure_tevo_client /
# app._search_sql_only) keep binding through the call.
# ---------------------------------------------------------------------------

def search_cache_get(cache: dict, key: str, ttl: float, *, now=time.time) -> dict | None:
    hit = cache.get(key)
    if not hit:
        return None
    ts, payload = hit
    if now() - ts > ttl:
        cache.pop(key, None)
        return None
    return payload


def search_cache_put(cache: dict, key: str, payload: dict, *, max_size: int = 200, now=time.time) -> None:
    cache[key] = (now(), payload)
    # Drop oldest entries when the cache grows past max_size — keeps a long
    # uptime from leaking memory on a steady drip of unique queries.
    if len(cache) > max_size:
        oldest = min(cache.items(), key=lambda kv: kv[1][0])
        cache.pop(oldest[0], None)


def search_players(db, q_norm: str, limit: int) -> list[dict]:
    """Sports player search for the storefront. Resolves a player name to their
    team + the team's upcoming events via the shared PUBLIC RPC
    `sports_player_search` (mig 20260617120000), then enriches each event with
    the same we_own/from_price tags as search_sql_only so the dropdown can show
    "tickets you can buy" under a player.

    Public sports data only (rosters, team names, public listings) — the only
    money shown is the consumer-facing from_price already on every event card.
    Returns [] on any failure: the players block is additive and must never 500
    the whole search.
    """
    try:
        players = (db.rpc("sports_player_search",
                          {"p_q": q_norm, "p_limit": limit}).execute().data) or []
    except Exception as e:
        _log.warning(f"search_players rpc failed: {e}")
        return []
    if not players:
        return []

    # One batched tag lookup across every event id from every matched player.
    all_ids = [
        int(ev.get("tevo_event_id") or 0)
        for pl in players for ev in (pl.get("events") or [])
        if ev.get("tevo_event_id")
    ]
    metrics: dict[int, dict] = {}
    inactive: set[int] = set()
    if all_ids:
        uniq = list(set(all_ids))
        try:
            rows = (db.table("latest_event_metrics")
                      .select("event_id,owned_tickets_count,retail_min")
                      .in_("event_id", uniq).execute().data) or []
            metrics = {int(r["event_id"]): r for r in rows if r.get("event_id")}
        except Exception:
            metrics = {}
        try:
            lc = (db.table("event_lifecycle")
                    .select("event_id,is_active")
                    .in_("event_id", uniq).execute().data) or []
            inactive = {int(r["event_id"]) for r in lc if not r.get("is_active")}
        except Exception:
            inactive = set()

    out: list[dict] = []
    for pl in players:
        events_out = []
        for ev in (pl.get("events") or []):
            eid = int(ev.get("tevo_event_id") or 0)
            if not eid or eid in inactive or _is_speculative_event_name(ev.get("name")):
                continue
            m = metrics.get(eid) or {}
            events_out.append({
                "id": eid,
                "name": ev.get("name"),
                "venue_name": ev.get("venue_name"),
                "location": ev.get("venue_location"),
                "occurs_at": ev.get("occurs_at_local"),
                "we_own": bool(m.get("owned_tickets_count")),
                "from_price": m.get("retail_min"),
                "owned_tix": m.get("owned_tickets_count"),
            })
        out.append({
            "performer_id": int(pl.get("tevo_performer_id") or 0),
            "name": pl.get("full_name") or pl.get("display_name"),
            "team_name": pl.get("team_name"),
            "league": pl.get("espn_league"),
            "position": pl.get("position_abbr"),
            "jersey": pl.get("jersey"),
            "status": pl.get("status"),
            "headshot_url": pl.get("headshot_url"),
            "events": events_out,
        })
    return out


def search_live(db, q_norm: str, limit: int, *, ensure_client, search_sql_only) -> dict:
    """Live search: hits TEvo /v9/searches/suggestions, then cross-joins the
    returned event IDs against our SQL to tag we_own + from_price. Used in
    non-SQL-only deployments. `ensure_client` (lazy TEvo client factory) and
    `search_sql_only` (the SQL fallback) are injected so the server-module
    monkeypatches still bind."""
    today_iso = datetime.now(timezone.utc).date().isoformat()
    # Lazy-init client so we can serve search even if boot creds were stale.
    live_client = ensure_client()
    if live_client is None:
        # Creds genuinely missing — fall back to SQL with explicit signal.
        payload = search_sql_only(db, q_norm, limit)
        payload["fallback"] = True
        payload["fallback_reason"] = "tevo_unconfigured"
        return payload
    try:
        resp = live_client.search_suggestions(
            q_norm, entities="events,performers,venues",
            fuzzy=True, limit=20, occurs_at_gte=today_iso,
        )
    except RuntimeError as e:
        # Don't break the page on TEvo error; fall back to SQL with a
        # structured signal so clients can show a "live search degraded"
        # hint. Status code (parsed out of the sanitized RuntimeError
        # message — evo_client.py strips URL + body since PR #66/#81) is
        # the only upstream detail we surface; full error stays in logs.
        logging.warning(
            "search_live TEvo failed, falling back to SQL: %s",
            str(e)[:200],
        )
        m = re.search(r"\b(\d{3})\b", str(e))
        upstream_status = int(m.group(1)) if m else None
        payload = search_sql_only(db, q_norm, limit)
        payload["fallback"] = True
        payload["fallback_reason"] = "tevo_unavailable"
        if upstream_status:
            payload["fallback_detail"] = {"tevo_status": upstream_status}
        return payload

    s = (resp.get("suggestions") or {})
    ev_in = s.get("events", []) or []
    pf_in = s.get("performers", []) or []
    vn_in = s.get("venues", []) or []

    # Drop speculative event names — CANCELLED + (If Necessary) + (Date TBD).
    # TEvo bakes these markers right into the name string for playoff/round-N
    # placeholders. Consumer search should never surface them as bookable.
    ev_in = [e for e in ev_in if not _is_speculative_event_name(e.get("name"))]

    # Cross-check against our SQL to know which events we actually own.
    ev_ids = [int(e.get("id") or 0) for e in ev_in if e.get("id")]
    metrics: dict[int, dict] = {}
    if ev_ids:
        try:
            rows = (db.table("latest_event_metrics")
                      .select("event_id,owned_tickets_count,owned_groups_count,retail_min")
                      .in_("event_id", ev_ids).execute().data) or []
            metrics = {int(r["event_id"]): r for r in rows if r.get("event_id")}
        except Exception:
            metrics = {}

    events_out = []
    for e in ev_in[:limit]:
        eid = int(e.get("id") or 0)
        m = metrics.get(eid) or {}
        events_out.append({
            "id": eid,
            "name": e.get("name"),
            "venue_name": e.get("venue_name"),
            "location": e.get("location"),
            "occurs_at": e.get("occurs_at"),
            "we_own": bool(m.get("owned_tickets_count")),
            "from_price": m.get("retail_min"),
            "owned_tix": m.get("owned_tickets_count"),
        })

    return {
        "events": events_out,
        "performers": [{
            "id": int(p.get("id") or 0),
            "name": p.get("name"),
            "location": p.get("location"),
            "venue_name": p.get("venue_name"),
        } for p in pf_in[:limit] if p.get("id")],
        "venues": [{
            "id": int(v.get("id") or 0),
            "name": v.get("name"),
            "location": v.get("location"),
        } for v in vn_in[:limit] if v.get("id")],
        "source": "live",
    }
