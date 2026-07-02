"""D0 sales-report read routes — league + performer sales analytics.

Read-only over the already-shipped `d0_sales_fact` snapshot and its report
views (migrations 20260624…d0_sales_*; see docs/d0-sales-reports.md). No
mutations, no third-party calls — just PostgREST reads through the service-role
`require_sb` (the fact table is RLS-locked, so anon/PostgREST can't read it; the
service-role client bypasses RLS, which is the established D0 pattern).

Factory takes a getter for require_sb + the require_auth dep so handlers resolve
the live values at request time (keeps the monkeypatch route tests working),
mirroring routers/lists.py and routers/seatdata.py.

Endpoints (all GET, all require_auth):
  /api/d0/sales/leagues                                   league_summary ⋈ price_weighted
  /api/d0/sales/leagues/{league}/visiting-teams           league_visiting_teams
  /api/d0/sales/performers/{performer_id}                 home_away + price_stats + price_weighted
  /api/d0/sales/performers/{performer_id}/by-source       perf_by_source (owned vs market)
  /api/d0/sales/performers/{performer_id}/sections        perf_sections | perf_top5_sections
  /api/d0/sales/health                                    refresh_health
"""
from __future__ import annotations

from typing import Callable

from fastapi import APIRouter, Depends, HTTPException


def build_d0_sales_router(
    get_require_sb: Callable[[], Callable],
    require_auth: Callable,
) -> APIRouter:
    router = APIRouter()

    @router.get("/api/d0/sales/leagues")
    def d0_sales_leagues(_=Depends(require_auth)):
        """Per-league totals: revenue, tickets, per-sale + quantity-weighted
        median. Joined from d0_league_summary and d0_league_price_weighted on
        `league`. Sorted by revenue desc."""
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

    @router.get("/api/d0/sales/leagues/{league}/visiting-teams")
    def d0_sales_visiting_teams(league: str, limit: int = 100, _=Depends(require_auth)):
        """Away-team leaderboard for a league (d0_league_visiting_teams),
        ranked by away revenue."""
        limit = max(1, min(int(limit), 500))
        db = get_require_sb()()
        rows = (
            db.table("d0_league_visiting_teams").select("*")
            .eq("league", league.upper())
            .order("rank_by_revenue")
            .limit(limit).execute()
        ).data or []
        return {"league": league.upper(), "count": len(rows), "visiting_teams": rows}

    @router.get("/api/d0/sales/performers/{performer_id}")
    def d0_sales_performer(performer_id: int, _=Depends(require_auth)):
        """Performer sales header: home/away revenue + tickets + medians
        (d0_perf_home_away), per-role price distribution (d0_perf_price_stats),
        and quantity-weighted median per role (d0_perf_price_weighted).

        404 if the performer has no sales in the snapshot."""
        db = get_require_sb()()
        ha = (db.table("d0_perf_home_away").select("*")
              .eq("performer_id", performer_id).limit(1).execute()).data or []
        if not ha:
            raise HTTPException(404, f"no sales for performer {performer_id}")
        ps = (db.table("d0_perf_price_stats").select("*")
              .eq("performer_id", performer_id).execute()).data or []
        wgt = (db.table("d0_perf_price_weighted").select("*")
               .eq("performer_id", performer_id).execute()).data or []
        h = ha[0]
        return {
            "performer_id": performer_id,
            "performer_name": h.get("performer_name"),
            "league": h.get("performer_league"),
            "home_away": h,
            "price_stats": {r["role"]: r for r in ps if r.get("role")},
            "weighted": {r["role"]: r.get("weighted_median_price")
                         for r in wgt if r.get("role")},
        }

    @router.get("/api/d0/sales/performers/{performer_id}/by-source")
    def d0_sales_performer_by_source(performer_id: int, _=Depends(require_auth)):
        """Owned-vs-market split per role (d0_perf_by_source), revenue desc."""
        db = get_require_sb()()
        rows = (
            db.table("d0_perf_by_source").select("*")
            .eq("performer_id", performer_id)
            .order("revenue", desc=True).execute()
        ).data or []
        return {"performer_id": performer_id, "count": len(rows), "by_source": rows}

    @router.get("/api/d0/sales/performers/{performer_id}/sections")
    def d0_sales_performer_sections(
        performer_id: int, top5: bool = False, role: str | None = None,
        _=Depends(require_auth),
    ):
        """Section leaderboard (d0_perf_sections, or d0_perf_top5_sections when
        top5=true). Optional role filter ('home'|'away'). Ranked by revenue."""
        db = get_require_sb()()
        view = "d0_perf_top5_sections" if top5 else "d0_perf_sections"
        q = (db.table(view).select("*").eq("performer_id", performer_id))
        if role in ("home", "away"):
            q = q.eq("role", role)
        rows = q.order("rank_by_revenue").execute().data or []
        return {"performer_id": performer_id, "top5": bool(top5),
                "role": role, "count": len(rows), "sections": rows}

    @router.get("/api/d0/sales/health")
    def d0_sales_health(_=Depends(require_auth)):
        """Recent refresh runs (d0_refresh_health) for the two sales-fact crons,
        newest first — for the health strip + stale alarm."""
        db = get_require_sb()()
        rows = (
            db.table("d0_refresh_health").select("*")
            .order("start_time", desc=True).limit(20).execute()
        ).data or []
        return {"count": len(rows), "runs": rows}

    return router
