"""Per-performer SQL digest — assemble a non-sensitive text blob from the ticket
data plane so a performer can become a notebook source (→ Ask/Chat/Podcast).

Design: rather than a generic "read any allowlisted table" source (which the
service-role client could turn into a secret/PII leak), this is a **purpose-built
digest** that reads a FIXED set of safe sources only. Sensitive tables (settings,
vault, exos_*/barcodes, leads/PII, auth) are never touched — they're structurally
out of reach here, not merely filtered.

Safe sources read (per PROJECT_BIBLE §3/§4 landmine review):
  - entity_performer_map / performer_metadata  → identity + branding
  - events (primary_performer_id + performer_ids)  → upcoming slate
  - latest_event_metrics                        → get-in / price bands / depth
  - get_event_movers_v2 (RPC)                   → 7-day price/inventory movement
  - d0_perf_home_away / _price_stats / _price_weighted  → realized-sales color
  - get_performer_prediction_markets (RPC)      → futures/odds narrative (optional)

Landmines respected: events.occurs_at_local is TEXT (ISO string), so "upcoming"
is a lexicographic string compare; d0_* views are pre-deduped (we never touch the
raw seatgeek_sales_snapshots firehose).
"""
from __future__ import annotations

import datetime as _dt
from typing import Any


def _rows(res) -> list[dict]:
    return getattr(res, "data", None) or []


def _is_upcoming(occ: str | None, now_utc: _dt.datetime) -> bool:
    """occurs_at_local is TEXT "YYYY-MM-DDTHH:MM:SS±HH:MM" (offset varies by venue
    tz). Parse it to a real instant and compare — a lexicographic string compare
    against a UTC wall-clock is WRONG (a several-hour offset flips same-evening
    events). Unparseable → keep (don't silently drop)."""
    if not occ:
        return False
    try:
        dt = _dt.datetime.fromisoformat(occ)
    except ValueError:
        return True
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_dt.timezone.utc)
    return dt >= now_utc


def _safe(fn, default):
    """Best-effort read — a missing view / RLS / empty result must not abort the
    whole digest (a performer with no owned sales is normal)."""
    try:
        return fn()
    except Exception:
        return default


def resolve_performer(db, *, performer_id: int | None = None, name: str | None = None) -> dict | None:
    """Resolve a performer to {'id', 'name'} by tevo_performer_id or by name."""
    if performer_id is not None:
        row = _safe(lambda: _rows(db.table("entity_performer_map")
                                  .select("tevo_performer_id,tevo_performer_name")
                                  .eq("tevo_performer_id", performer_id).limit(1).execute()), [])
        if row:
            return {"id": row[0]["tevo_performer_id"], "name": row[0].get("tevo_performer_name")}
        # fall back to events (map view may lag ingest)
        ev = _safe(lambda: _rows(db.table("events").select("primary_performer_id,primary_performer_name")
                                 .eq("primary_performer_id", performer_id).limit(1).execute()), [])
        if ev:
            return {"id": performer_id, "name": ev[0].get("primary_performer_name")}
        return {"id": performer_id, "name": None}
    if name:
        row = _safe(lambda: _rows(db.table("entity_performer_map")
                                  .select("tevo_performer_id,tevo_performer_name")
                                  .ilike("tevo_performer_name", f"%{name}%").limit(1).execute()), [])
        if row:
            return {"id": row[0]["tevo_performer_id"], "name": row[0].get("tevo_performer_name")}
        md = _safe(lambda: _rows(db.table("performer_metadata").select("performer_id,name")
                                 .ilike("name", f"%{name}%").limit(1).execute()), [])
        if md:
            return {"id": md[0]["performer_id"], "name": md[0].get("name")}
    return None


def _upcoming_events(db, pid: int) -> list[dict]:
    now_utc = _dt.datetime.now(_dt.timezone.utc)
    cols = "id,name,occurs_at_local,venue_name,venue_location,primary_performer_name,state,performer_ids"
    primary = _safe(lambda: _rows(db.table("events").select(cols).eq("primary_performer_id", pid).execute()), [])
    # postgrest .contains() str-joins the value with no int coercion (raises on
    # int); use an explicit `cs.{<id>}` array-literal filter so secondary-performer
    # (e.g. away-game) events are included, not silently dropped.
    also = _safe(lambda: _rows(db.table("events").select(cols)
                               .filter("performer_ids", "cs", "{%d}" % pid).execute()), [])
    seen, out = set(), []
    for e in [*primary, *also]:
        eid = e.get("id")
        if eid in seen:
            continue
        seen.add(eid)
        if not _is_upcoming(e.get("occurs_at_local"), now_utc):
            continue
        if (e.get("state") or "") in ("past", "ignored"):
            continue
        out.append(e)
    out.sort(key=lambda e: e.get("occurs_at_local") or "")
    return out


def _price_by_event(db, event_ids: list[int]) -> dict[int, dict]:
    if not event_ids:
        return {}
    cols = "event_id,getin_price,retail_median,retail_min,retail_p90,tickets_count,owned_share,price_dispersion"
    rows = _safe(lambda: _rows(db.table("latest_event_metrics").select(cols)
                               .in_("event_id", event_ids).execute()), [])
    return {r["event_id"]: r for r in rows}


def _movement_by_event(db, event_ids: list[int]) -> dict[int, dict]:
    if not event_ids:
        return {}
    rows = _safe(lambda: _rows(db.rpc("get_event_movers_v2",
                                      {"p_source": "merged", "p_window_days": 7,
                                       "p_category": None, "p_limit": 200}).execute()), [])
    idset = set(event_ids)
    return {r["event_id"]: r for r in rows if r.get("event_id") in idset}


# d0_perf_* views are aggregate realized-sales, but their columns aren't fixed —
# a future column (e.g. cost-basis / owned-margin) must NOT auto-flow into the
# digest text (embedded + shown in the UI). Emit only allowlisted aggregate
# columns and hard-drop anything matching a sensitive token. Fail-safe: an
# unrecognized column is omitted, not leaked.
_D0_SAFE_TOKENS = ("rev", "median", "mean", "price", "count", "tix", "events",
                   "home", "away", "avg", "min", "max", "p25", "p50", "p75", "p90",
                   "section", "weighted", "visiting", "share")
_D0_DENY_TOKENS = ("cost", "margin", "basis", "profit", "fee", "buyer",
                   "email", "phone", "name", "secret", "owner")


def _digest_kv(row: dict) -> str:
    bits = []
    for k, v in row.items():
        kl = k.lower()
        if kl == "performer_id":
            continue
        if any(d in kl for d in _D0_DENY_TOKENS):
            continue
        if not any(s in kl for s in _D0_SAFE_TOKENS):
            continue
        bits.append(f"{k}={v}")
    return ", ".join(bits[:10])


def _fmt_price(v) -> str:
    try:
        return f"${float(v):,.0f}"
    except (TypeError, ValueError):
        return "n/a"


def build_performer_digest(db, performer_id: int, *, performer_name: str | None = None) -> tuple[str, str]:
    """Return (title, text) — a non-sensitive markdown digest for one performer."""
    ident = _safe(lambda: _rows(db.table("entity_performer_map")
                                .select("tevo_performer_id,tevo_performer_name,genre,top_category_name,"
                                        "what_event_type,espn_team_id,espn_league")
                                .eq("tevo_performer_id", performer_id).limit(1).execute()), [])
    info = ident[0] if ident else {}
    name = performer_name or info.get("tevo_performer_name") or f"Performer {performer_id}"

    lines: list[str] = [f"# {name}", ""]
    meta_bits = [info.get("top_category_name"), info.get("what_event_type"),
                 info.get("genre"), info.get("espn_league")]
    meta = " · ".join(str(b) for b in meta_bits if b)
    if meta:
        lines.append(meta)
    lines.append("")

    events = _upcoming_events(db, performer_id)
    ids = [e["id"] for e in events]
    prices = _price_by_event(db, ids)
    movers = _movement_by_event(db, ids)

    lines.append(f"## Upcoming events ({len(events)})")
    if not events:
        lines.append("_No upcoming events on record._")
    for e in events[:40]:
        pm = prices.get(e["id"], {})
        mv = movers.get(e["id"], {})
        parts = [e.get("occurs_at_local", "")[:16], e.get("name") or "",
                 e.get("venue_name") or "", e.get("venue_location") or ""]
        head = " · ".join(str(p) for p in parts if p)
        detail = []
        if pm.get("getin_price") is not None:
            detail.append(f"get-in {_fmt_price(pm.get('getin_price'))}")
        if pm.get("retail_median") is not None:
            detail.append(f"median {_fmt_price(pm.get('retail_median'))}")
        if pm.get("tickets_count") is not None:
            detail.append(f"{pm.get('tickets_count')} tix")
        if mv.get("price_delta_pct") is not None:
            detail.append(f"7d {float(mv['price_delta_pct']):+.1f}%")
        lines.append(f"- {head}" + (f" — {', '.join(detail)}" if detail else ""))
    lines.append("")

    # Realized-sales color (D0 perf views) — best-effort, may be empty.
    ha = _safe(lambda: _rows(db.table("d0_perf_home_away").select("*")
                             .eq("performer_id", performer_id).limit(1).execute()), [])
    ps = _safe(lambda: _rows(db.table("d0_perf_price_stats").select("*")
                             .eq("performer_id", performer_id).limit(1).execute()), [])
    if ha or ps:
        lines.append("## Realized-sales snapshot")
        if ha:
            lines.append("- Home/away: " + _digest_kv(ha[0]))
        if ps:
            lines.append("- Price stats: " + _digest_kv(ps[0]))
        lines.append("")

    # Prediction-market futures narrative (optional).
    pm_markets = _safe(lambda: db.rpc("get_performer_prediction_markets",
                                      {"p_performer_id": performer_id}).execute(), None)
    futures = (getattr(pm_markets, "data", None) or {}).get("futures") if pm_markets else None
    if futures:
        lines.append("## Futures / prediction markets")
        for f in futures[:10]:
            lines.append(f"- {f.get('title') or f.get('question') or ''} "
                         f"({f.get('source')}: {f.get('last_price') or f.get('yes_price') or ''})")
        lines.append("")

    return name, "\n".join(lines).strip()
