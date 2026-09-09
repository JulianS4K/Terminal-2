"""Fan-listings outward API — cross-source seller-type classification, read-only.

GET /api/event/{tevo_event_id}/fan-listings

Server-side twin of the terminal's Fan vs Broker classifier (event.js
computeFanBroker), exposed as JSON so external consumers can pull the
fan-likely set per event. Rule (operator definition, 2026-08-19): fans list on
ONE source, brokers distribute to most or all — so classification is purely
cross-source identity on the key (normalized section, row, qty):

  ours        key matches an EVO (TEvo) row with is_owned
  broker      key present on a broker-only channel (TEvo / GoTickets — fans
              cannot list there), OR live on 2+ of SH/GT/VD
  fan-likely  the remains: listed on a single source only

Broker-shaped tells that stop short of proven cross-listing (SH identical
exact price across 2+ sections = one seller's portfolio/spec book; 8+ blocks;
5-7 blocks) are returned as WARNING FLAGS on fan-likely rows, never as a
class. fan-likely is a CEILING (absence of evidence): any source missing for
the event widens it, and the response says which were available.

Read-only by construction: SELECTs on our own snapshot tables via the
service-role client. No upstream API is touched (CLAUDE.md RULE 2), and this
route pushes nothing anywhere — it is a pull surface for our own data.
"""
from __future__ import annotations

import re
from collections import Counter
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from fastapi import APIRouter, Depends, HTTPException

# Retail sources classified (TM/TP/SG operator-excluded, 2026-08-19);
# EVO + GOT are the broker-only evidence channels.
RETAIL = ("SH", "GT", "VD")

_SEC_TAIL = re.compile(r"(\d+[A-Za-z]?)\s*$")


def _norm_sec(sec: Any) -> str:
    """Trailing-token section normalizer — 'Lower 101' / 'PRESS 203' -> '101' /
    '203' — so GOT/EVO section vocabularies join the TD ones. Mirrors
    event.js fbNormSec; keep the two in sync."""
    up = str(sec or "").strip().upper()
    if not up or not any(c.isdigit() for c in up):
        return up
    m = _SEC_TAIL.search(up)
    return m.group(1) if m else up


def _key(sec: Any, row: Any, qty: Any) -> str:
    return f"{_norm_sec(sec)}|{str(row or '').strip().upper()}|{int(qty or 0)}"


def build_fan_listings_router(
    get_require_sb: Callable[[], Callable], require_auth: Callable
) -> APIRouter:
    router = APIRouter()

    def _latest_batch(db, platform: str, td_event_id: int) -> list[dict]:
        """Latest collection batch for one TD platform book: rows in the last
        26h, kept within 15 minutes of that platform's max(captured_at),
        non-parking, deduped per td_listing_id (newest wins — the dealScore
        content-hash landmine double-stores listings across captures)."""
        since = (datetime.now(timezone.utc) - timedelta(hours=26)).isoformat()
        rows = (
            db.table("ticketsdata_listings_snapshots")
            .select("td_listing_id,section,row,quantity,list_price,price_with_fees,"
                    "is_parking,captured_at")
            .eq("platform", platform).eq("event_id", td_event_id)
            .gte("captured_at", since)
            .order("captured_at", desc=True).limit(5000).execute()
        ).data or []
        if not rows:
            return []
        max_at = max(r["captured_at"] for r in rows)
        cutoff = (datetime.fromisoformat(max_at.replace("Z", "+00:00"))
                  - timedelta(minutes=15)).isoformat()
        seen: dict[str, dict] = {}
        for r in rows:  # newest-first: first hit per listing id wins
            if r["captured_at"] < cutoff or r.get("is_parking"):
                continue
            lid = r.get("td_listing_id") or ""
            if lid not in seen:
                seen[lid] = r
        return list(seen.values())

    @router.get("/api/event/{tevo_event_id}/fan-listings")
    def fan_listings(tevo_event_id: int, include: str = "fan",
                     _=Depends(require_auth)):
        """Classified listings for one event. `include=fan` (default) returns
        only the fan-likely rows; `include=all` returns every classified row.
        Summary counts always cover all classes per source."""
        db = get_require_sb()()

        # tevo -> per-platform TD event ids (aq_event_map -> ticketsdata_event_xref).
        aq = (
            db.table("aq_event_map").select("aq_short_event_id,event_name")
            .eq("tevo_event_id", tevo_event_id).limit(1).execute()
        ).data or []
        if not aq:
            raise HTTPException(404, "event not in aq_event_map (no cross-source ids)")
        xref = (
            db.table("ticketsdata_event_xref").select("platform,event_id")
            .eq("aq_short_event_id", aq[0]["aq_short_event_id"])
            .in_("platform", list(RETAIL)).execute()
        ).data or []
        td_ids = {x["platform"]: x["event_id"] for x in xref}

        # Retail books (latest batch each).
        books = {p: _latest_batch(db, p, td_ids[p]) if p in td_ids else []
                 for p in RETAIL}

        # EVO broker anchor: latest capture in the last 3 days.
        evo_last = (
            db.table("listings_snapshots").select("captured_at")
            .eq("event_id", tevo_event_id)
            .order("captured_at", desc=True).limit(1).execute()
        ).data or []
        evo_rows: list[dict] = []
        if evo_last:
            evo_rows = (
                db.table("listings_snapshots")
                .select("section,row,quantity,is_owned")
                .eq("event_id", tevo_event_id)
                .eq("captured_at", evo_last[0]["captured_at"])
                .limit(10000).execute()
            ).data or []
        evo_keys: dict[str, bool] = {}
        for r in evo_rows:
            if str(r.get("row") or "").strip().lower() == "parking":
                continue
            k = _key(r["section"], r["row"], r["quantity"])
            evo_keys[k] = evo_keys.get(k, False) or bool(r.get("is_owned"))

        # GOT broker anchor: latest capture batch.
        got_last = (
            db.table("gotickets_listings_snapshots").select("captured_at")
            .eq("tevo_event_id", tevo_event_id)
            .order("captured_at", desc=True).limit(1).execute()
        ).data or []
        got_keys: set[str] = set()
        if got_last:
            grows = (
                db.table("gotickets_listings_snapshots")
                .select("section,row,quantity")
                .eq("tevo_event_id", tevo_event_id)
                .eq("captured_at", got_last[0]["captured_at"])
                .limit(10000).execute()
            ).data or []
            got_keys = {_key(r["section"], r["row"], r["quantity"]) for r in grows}

        src_keys = {p: {_key(r["section"], r["row"], r["quantity"]) for r in books[p]}
                    for p in RETAIL}
        # SH portfolio-price clusters: exact price on >=3 listings across >=2 sections.
        sh_px: dict[str, set] = {}
        sh_px_n: Counter = Counter()
        for r in books["SH"]:
            px = str(r["list_price"])
            sh_px.setdefault(px, set()).add(_norm_sec(r["section"]))
            sh_px_n[px] += 1
        sh_clusters = {px for px, secs in sh_px.items()
                       if sh_px_n[px] >= 3 and len(secs) >= 2}

        out, summary = [], {p: Counter() for p in RETAIL}
        for p in RETAIL:
            for r in books[p]:
                k = _key(r["section"], r["row"], r["quantity"])
                if evo_keys.get(k) is True:
                    cls = "ours"
                elif k in evo_keys or k in got_keys:
                    cls = "broker"
                elif any(q != p and k in src_keys[q] for q in RETAIL):
                    cls = "broker"
                else:
                    cls = "fan_likely"
                flags = []
                if cls == "fan_likely":
                    if p == "SH" and str(r["list_price"]) in sh_clusters:
                        flags.append("price_cluster")
                    qty = int(r.get("quantity") or 0)
                    if qty >= 8:
                        flags.append("block_8plus")
                    elif qty >= 5:
                        flags.append("block_5to7")
                summary[p][cls] += 1
                if include == "all" or cls == "fan_likely":
                    out.append({
                        "source": p, "class": cls,
                        "section": r["section"], "row": r["row"],
                        "quantity": r["quantity"],
                        "list_price": r["list_price"],
                        "price_with_fees": r["price_with_fees"],
                        "flags": flags,
                        "captured_at": r["captured_at"],
                    })

        # Cleanest fan candidates first: unflagged, then by price.
        out.sort(key=lambda r: (r["class"] != "fan_likely", len(r["flags"]),
                                float(r["list_price"] or 0)))
        return {
            "tevo_event_id": tevo_event_id,
            "event_name": aq[0].get("event_name"),
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "rule": "fans list on one source; brokers on most or all — "
                    "cross-listed = broker, remains = fan-likely (a ceiling)",
            "sources_available": {
                **{p: bool(books[p]) for p in RETAIL},
                "EVO": bool(evo_rows), "GOT": bool(got_keys),
            },
            "summary": {p: dict(summary[p]) for p in RETAIL},
            "listings": out,
        }

    return router
