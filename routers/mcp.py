"""Read-only /api/mcp/* routes backing the MCP Apps surfaces (D0 + D4).

These endpoints feed the interactive `ui://` apps in `mcp_apps/` (an ext-apps
MCP service). They are GET-only and reuse existing read logic so nothing is
duplicated:
  - /api/mcp/d0/leagues  -> the d0_league_summary ⋈ d0_league_price_weighted
                            join (mirror of routers/d0_sales.py:d0_sales_leagues)
  - /api/mcp/d4/events    -> the anon-readable `exos_public_events` view (already
                            status=published) with min tier price folded from
                            `exos_public_tiers` (cf. d4_bridge/src/lib/events.ts)

D1 is intentionally NOT here: the D1 app reuses the existing retail concierge
(`/api/store/retail-chat`, routers/retail_chat.py) rather than a second search
path — one function, not two.

Access is gated by a single shared-secret header (`X-MCP-Read-Secret`) checked
against env `MCP_READ_SECRET`, not the Google-OAuth `require_auth` the terminal
routes use — this is a machine-to-machine surface for the trusted MCP service.
If `MCP_READ_SECRET` is unset the whole surface fail-closes with 503 (feature
disabled), so the endpoints are inert until an operator provisions the secret.

RULE 2 (CLAUDE.md): read-only. No write path to any listing source is added or
reachable from here — every handler is a DB read.
"""
from __future__ import annotations

import hmac
from typing import Callable

from fastapi import APIRouter, Depends, Header, HTTPException


def build_mcp_router(
    get_require_sb: Callable[[], Callable],
    get_read_secret: Callable[[], str | None],
) -> APIRouter:
    """Factory for the read-only MCP-Apps data router. Getters resolve the live
    server symbols at request time so the monkeypatch tests bind (same pattern
    as the other routers)."""
    router = APIRouter()

    def _guard(
        x_mcp_read_secret: str | None = Header(default=None, alias="X-MCP-Read-Secret"),
    ) -> None:
        """Shared-secret gate. Fail-closed when the secret is unprovisioned so
        the surface can't be reached before an operator turns it on."""
        secret = get_read_secret()
        if not secret:
            raise HTTPException(503, "MCP read API disabled (MCP_READ_SECRET unset)")
        if not x_mcp_read_secret or not hmac.compare_digest(x_mcp_read_secret, secret):
            raise HTTPException(401, "invalid or missing X-MCP-Read-Secret")

    @router.get("/api/mcp/d0/leagues")
    def mcp_d0_leagues(_=Depends(_guard)):
        """Per-league sales totals + quantity-weighted median, revenue desc.
        Mirrors routers/d0_sales.py:d0_sales_leagues (service-role read; the
        d0_* fact tables are RLS-locked)."""
        db = get_require_sb()()
        summ = db.table("d0_league_summary").select("*").execute().data or []
        wgt = {w["league"]: w for w in (
            db.table("d0_league_price_weighted").select("*").execute().data or [])}
        out = []
        for r in summ:
            w = wgt.get(r.get("league")) or {}
            out.append({**r, "weighted_median_price": w.get("weighted_median_price")})
        out.sort(key=lambda r: (r.get("total_revenue") or 0), reverse=True)
        return {"count": len(out), "leagues": out}

    @router.get("/api/mcp/d4/events")
    def mcp_d4_events(limit: int = 50, _=Depends(_guard)):
        """Published Exos/Bridge events (exos_public_events) with the minimum
        ticket-tier price folded in from exos_public_tiers as `from_price`.
        Read-only; create-event / sell-ticket are deferred and have no path here."""
        lim = max(1, min(int(limit), 200))
        db = get_require_sb()()
        evs = (
            db.table("exos_public_events")
            .select("id,name,slug,starts_at,venue_name,venue_location,image_url,timezone")
            .order("starts_at")
            .limit(lim)
            .execute()
        ).data or []
        ids = [e["id"] for e in evs if e.get("id")]
        min_price: dict = {}
        if ids:
            tiers = (
                db.table("exos_public_tiers")
                .select("event_id,price")
                .in_("event_id", ids)
                .execute()
            ).data or []
            for t in tiers:
                eid, price = t.get("event_id"), t.get("price")
                if eid is None or price is None:
                    continue
                cur = min_price.get(eid)
                min_price[eid] = price if cur is None else min(cur, price)
        out = [
            {
                "id": e.get("id"),
                "name": e.get("name"),
                "slug": e.get("slug"),
                "starts_at": e.get("starts_at"),
                "venue_name": e.get("venue_name"),
                "venue_location": e.get("venue_location"),
                "image_url": e.get("image_url"),
                "timezone": e.get("timezone"),
                "from_price": min_price.get(e.get("id")),
            }
            for e in evs
        ]
        return {"count": len(out), "events": out}

    return router
