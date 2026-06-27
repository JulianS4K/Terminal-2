"""Admin + ingest routes — collector trigger + TEvo/SG/SD wiring + order pulls.

server.py decomposition (BR-CODE-1). The operator-/cron-triggered ingest
surface: POST /api/collect/run, /api/admin/{seed-home-venues, wire-sg-to-tevo,
wire-sd-to-tevo, collect-orders, collect-sg-seller}. These are A1's data-plane
routes — pull data IN from TEvo/SeatGeek (GET-only, RULE-2 clean) and write our
own DB; they never push an order/hold/price OUT to any upstream.

All live collaborators are injected via getters that resolve the server module's
bindings at request time, so the existing route tests (which monkeypatch
app.client / app._flatten_order / app._venue_overlap / app.CRON_SECRET / etc.)
keep binding through the factory. The patchable helpers themselves
(_upsert_tevo_event_into_events, _flatten_order, _fire_collect, the client
factories, the cooldown table) stay in server.py — tests call several of them
directly.
"""
from __future__ import annotations

import threading
from datetime import datetime, timezone, timedelta
from typing import Any, Callable

from fastapi import APIRouter, Depends, Header, HTTPException


def build_admin_router(
    *,
    get_require_sb: Callable[[], Callable],
    get_client: Callable[[], Any],
    require_auth: Callable,
    require_cron_or_auth: Callable,
    get_seatgeek_client: Callable[[], Any],
    get_supabase_url: Callable[[], str | None],
    get_cron_secret: Callable[[], str | None],
    get_collect_run_last_call: Callable[[], dict],
    collect_run_cooldown_sec: int,
    get_fire_collect: Callable[[], Callable],
    get_upsert_tevo_event: Callable[[], Callable],
    get_flatten_order: Callable[[], Callable],
    get_flatten_order_items: Callable[[], Callable],
    get_venue_overlap: Callable[[], Callable],
) -> APIRouter:
    router = APIRouter()

    @router.post("/api/collect/run")
    def collect_run(watchlist_id: int | None = None, user=Depends(require_auth)):
        supabase_url = get_supabase_url()
        cron_secret = get_cron_secret()
        if not (supabase_url and cron_secret):
            raise HTTPException(500, "Set SUPABASE_URL and CRON_SECRET to invoke the collector.")
        if watchlist_id is not None and watchlist_id < 1:
            raise HTTPException(400, "watchlist_id must be a positive integer")

        import time
        email = (user or {}).get("email") or "unknown"
        now = time.time()
        last_call = get_collect_run_last_call()
        last = last_call.get(email, 0)
        if now - last < collect_run_cooldown_sec:
            wait = int(collect_run_cooldown_sec - (now - last))
            raise HTTPException(429, f"rate limited — try again in {wait}s")
        last_call[email] = now

        url = f"{supabase_url}/functions/v1/collect"
        if watchlist_id is not None:
            url += f"?watchlist_id={int(watchlist_id)}"
        threading.Thread(target=get_fire_collect(), args=(url, cron_secret), daemon=True).start()
        return {"ok": True, "message": "collector fired; poll the runs table"}

    @router.post("/api/admin/seed-home-venues")
    def admin_seed_home_venues(league: str, _=Depends(require_auth)):
        """One-shot admin: for every performer in performer_external_ids
        (source='espn') in the given league that's NOT yet in performer_home_venues,
        fetch /v9/performers/{id} from TEvo and upsert a home-venue row.

        Used to backfill MLS (which had 0 rows in performer_home_venues despite
        30 teams in performer_external_ids) and any other league that's missing
        venue resolution.

        Returns: { league, scanned, added, skipped_no_venue, errors }
        """
        db = get_require_sb()()
        client = get_client()
        pei = (db.table("performer_external_ids")
                 .select("performer_id, external_id, external_name, league")
                 .eq("source", "espn").eq("league", league).execute().data or [])
        have = {r["performer_id"] for r in (db.table("performer_home_venues")
                 .select("performer_id").eq("league", league).execute().data or [])}
        todo = [r for r in pei if r["performer_id"] not in have]

        added = 0; skipped = 0; errors: list[str] = []
        for r in todo:
            pid = int(r["performer_id"])
            try:
                perf = client.get_performer(pid, include_opponents=False)
                # TEvo returns the home venue under `venue` (singular) for sports.
                # `home_venue` is also populated for some leagues — fall back to it.
                v = perf.get("venue") or perf.get("home_venue") or {}
                vid = v.get("id")
                if not vid:
                    skipped += 1
                    continue
                addr = v.get("address") or {}
                location = ", ".join(x for x in [addr.get("locality"), addr.get("region")] if x) or v.get("location")
                db.table("performer_home_venues").upsert({
                    "performer_id":   pid,
                    "performer_name": perf.get("name") or r.get("external_name"),
                    "venue_id":       int(vid),
                    "venue_name":     v.get("name"),
                    "venue_location": location,
                    "league":         league,
                    "source":         "tevo_lookup",
                }, on_conflict="performer_id").execute()
                added += 1
            except Exception as e:
                errors.append(f"performer_id={pid}: {e}")
        return {"league": league, "scanned": len(todo), "added": added, "skipped_no_venue": skipped, "errors": errors[:10]}

    @router.post("/api/admin/wire-sg-to-tevo")
    def admin_wire_sg_to_tevo(
        dry_run: bool = False,
        venue_overlap_min: float = 0.34,
        _=Depends(require_auth),
    ):
        """For every SG event with seller-direct listings and no TEvo xref:
          1. Pull distinct (sg_event_id, sg_event_name, sg_event_date, sg_venue)
          2. Call TEvo /v9/events/search for the name on that date
          3. Pick the result whose venue tokens overlap >= venue_overlap_min
          4. Upsert that TEvo event into our `events` table
          5. Call sg_attempt_event_xref (which inserts the xref row)

        dry_run=true: returns proposed matches without writing anything.
        Returns: counts + per-event audit so you can see what matched and why.
        """
        db = get_require_sb()()
        client = get_client()
        venue_overlap = get_venue_overlap()
        upsert_tevo_event_into_events = get_upsert_tevo_event()
        rows = (db.table("seatgeek_seller_listings")
                  .select("sg_event_id,sg_event_name,sg_event_date,sg_venue")
                  .execute().data or [])
        seen = set()
        todo: list[dict] = []
        for r in rows:
            key = r.get("sg_event_id")
            if key in seen or not key:
                continue
            seen.add(key)
            # Skip already-xref'd events
            existing = (db.table("seatgeek_event_xref")
                          .select("tevo_event_id").eq("sg_event_id", key)
                          .limit(1).execute().data or [])
            if existing:
                continue
            todo.append(r)

        audit: list[dict] = []
        new_xrefs = 0
        no_match = 0
        inserted_events = 0
        errors: list[str] = []

        for r in todo:
            sg_event_id = int(r["sg_event_id"])
            sg_name = r.get("sg_event_name") or ""
            sg_date = r.get("sg_event_date")  # YYYY-MM-DD string
            sg_venue = r.get("sg_venue") or ""
            if not sg_date:
                audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                              "matched": False, "reason": "no sg_event_date"})
                no_match += 1
                continue
            # 1-day window around sg_date
            try:
                d = datetime.fromisoformat(str(sg_date))
            except Exception:
                audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                              "matched": False, "reason": f"bad date {sg_date}"})
                no_match += 1
                continue

            try:
                resp = client.search_events_fulltext(
                    q=sg_name,
                    **{"occurs_at.gte": d.isoformat(),
                       "occurs_at.lt":  (d + timedelta(days=1)).isoformat()},
                    per_page=20,
                )
            except Exception as e:
                errors.append(f"sg_event_id={sg_event_id}: TEvo search failed: {e}")
                continue
            hits = (resp or {}).get("events", []) or []
            if not hits:
                audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                              "matched": False, "reason": "TEvo: 0 hits on date"})
                no_match += 1
                continue
            # Score by venue overlap
            scored = []
            for h in hits:
                v = (h.get("venue") or {}).get("name") or ""
                ov = venue_overlap(sg_venue, v)
                scored.append((ov, h))
            scored.sort(key=lambda x: -x[0])
            best_ov, best = scored[0]
            if best_ov < venue_overlap_min:
                audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                              "matched": False, "best_venue": (best.get("venue") or {}).get("name"),
                              "best_overlap": round(best_ov, 2),
                              "reason": f"venue overlap {best_ov:.2f} < {venue_overlap_min}"})
                no_match += 1
                continue

            if dry_run:
                audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                              "tevo_event_id": best.get("id"),
                              "tevo_name": best.get("name"),
                              "tevo_venue": (best.get("venue") or {}).get("name"),
                              "venue_overlap": round(best_ov, 2),
                              "matched": True, "dry_run": True})
                new_xrefs += 1
                continue

            # Upsert TEvo event into events table
            new_eid = upsert_tevo_event_into_events(db, best)
            if new_eid:
                inserted_events += 1

            # Call sg_attempt_event_xref to write the xref row
            try:
                res = db.rpc("sg_attempt_event_xref", {
                    "p_sg_event_id": sg_event_id,
                    "p_sg_event_name": sg_name,
                    "p_sg_event_date": str(sg_date),
                    "p_sg_venue": sg_venue,
                }).execute()
                matched_tevo_id = res.data
            except Exception as e:
                errors.append(f"sg_event_id={sg_event_id}: xref RPC failed: {e}")
                continue

            if matched_tevo_id:
                new_xrefs += 1
                audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                              "tevo_event_id": int(matched_tevo_id),
                              "tevo_name": best.get("name"),
                              "tevo_venue": (best.get("venue") or {}).get("name"),
                              "venue_overlap": round(best_ov, 2),
                              "matched": True})
            else:
                audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                              "tevo_event_id": int(best.get("id") or 0),
                              "matched": False,
                              "reason": "TEvo event ingested but xref RPC returned NULL "
                                        "(matcher rejected — likely performer-name mismatch)"})

        return {
            "candidates": len(todo),
            "newly_linked": new_xrefs,
            "no_match": no_match,
            "tevo_events_ingested": inserted_events,
            "errors": errors[:20],
            "dry_run": dry_run,
            "audit": audit,
        }

    @router.post("/api/admin/wire-sd-to-tevo")
    def admin_wire_sd_to_tevo(_=Depends(require_auth)):
        """Same as wire-sg-to-tevo but for SeatData. SD events come in with
        sd_event_name/date/venue; we search TEvo and call sd's existing
        matcher (manual upsert via auto_name_date_venue path).

        Currently SD only has 1 event (Knicks G5, already xref'd) — this route
        is futureproofing for when more SD events arrive."""
        db = get_require_sb()()
        rows = (db.table("seatdata_sales_snapshots")
                  .select("sd_event_id").execute().data or [])
        seen = {r.get("sd_event_id") for r in rows if r.get("sd_event_id")}
        if not seen:
            return {"candidates": 0, "newly_linked": 0, "audit": []}

        audit = []
        new_xrefs = 0
        for sd_id in seen:
            existing = (db.table("seatdata_event_xref")
                          .select("tevo_event_id").eq("sd_event_id", sd_id)
                          .limit(1).execute().data or [])
            if existing:
                audit.append({"sd_event_id": sd_id, "matched": True,
                              "tevo_event_id": existing[0]["tevo_event_id"],
                              "note": "already linked"})
                continue
            # No SD event-detail call here yet — when more SD events arrive we
            # plumb in the SD-side metadata fetch and search TEvo. Logged as
            # missing for now.
            audit.append({"sd_event_id": sd_id, "matched": False,
                          "reason": "no metadata available; manual link required"})
        return {
            "candidates": len(seen),
            "newly_linked": new_xrefs,
            "already_linked": sum(1 for a in audit if a["matched"]),
            "audit": audit,
        }

    @router.post("/api/admin/collect-orders")
    def collect_evo_orders(
        max_pages: int = 50,                   # 50 * 10 = 500 orders per tick
        state: str | None = None,              # filter by state if provided
        authorization: str | None = Header(None),
        x_cron_secret: str | None = Header(None, alias="X-Cron-Secret"),
    ):
        """Pull TEvo /v9/orders, persist to evo_orders + evo_order_items, return summary.

        Designed for a 10-min pg_cron driving us via pg_net.http_post. Idempotent
        via PRIMARY KEY (evo_order_id) + UNIQUE (evo_item_id) — re-running just
        refreshes existing rows. evo_order_items rows are deleted+re-inserted per
        order on update so item-list mutations (added / removed) reflect cleanly.
        """
        require_cron_or_auth(authorization, x_cron_secret)
        db = get_require_sb()()
        client = get_client()
        flatten_order = get_flatten_order()
        flatten_order_items = get_flatten_order_items()

        orders_seen = 0
        orders_inserted = 0
        items_inserted = 0
        events_touched: set[int] = set()
        errors: list[str] = []

        try:
            for o in client.iter_orders(max_pages=int(max_pages),
                                        per_page=10,
                                        state=state):
                orders_seen += 1
                try:
                    row = flatten_order(o)
                    if row["evo_order_id"] is None:
                        continue
                    # Upsert order
                    db.table("evo_orders").upsert(
                        row, on_conflict="evo_order_id"
                    ).execute()
                    orders_inserted += 1
                    # Replace item rows for this order — handles add/remove cleanly
                    db.table("evo_order_items").delete().eq("evo_order_id", row["evo_order_id"]).execute()
                    items = flatten_order_items(o)
                    if items:
                        db.table("evo_order_items").insert(items).execute()
                        items_inserted += len(items)
                        for it in items:
                            if it.get("event_id"):
                                events_touched.add(int(it["event_id"]))
                except Exception as e:
                    errors.append(f"order {o.get('id')}: {e}")
        except Exception as e:
            errors.append(f"iter_orders failed: {e}")

        return {
            "ok": len(errors) == 0,
            "orders_seen": orders_seen,
            "orders_upserted": orders_inserted,
            "items_inserted": items_inserted,
            "events_touched": len(events_touched),
            "events_touched_ids": sorted(events_touched)[:50],
            "errors": errors[:10],
        }

    @router.post("/api/admin/collect-sg-seller")
    def collect_sg_seller(
        statuses: str = "open,pending,confirmed,fulfilled",
        pull_listings: bool = True,
        authorization: str | None = Header(None),
        x_cron_secret: str | None = Header(None, alias="X-Cron-Secret"),
    ):
        """Pull seller-direct listings + orders. Cron-driven (X-Cron-Secret)
        or manually (Bearer auth). Read-only against SG; writes only to our
        seatgeek_seller_listings, seatgeek_orders, seatgeek_order_tickets,
        and (auto) seatgeek_event_xref tables.

        `statuses` is a comma-separated list of order statuses to pull. Default
        covers all in-flight states; skip 'cancelled' + 'delivered' for cron
        (they're terminal — won't change). Run those manually for backfill.
        """
        require_cron_or_auth(authorization, x_cron_secret)
        sg = get_seatgeek_client()
        if not sg:
            raise HTTPException(503, "SEATGEEK_API_TOKEN not in Vault.")

        summary: dict = {"started_at": datetime.now(timezone.utc).isoformat(),
                         "listings": None, "orders_by_status": {}, "errors": []}

        # Listings — paginate via page_cursor for broader coverage. Default
        # 5 pages × 200 per = 1000 listings/tick. Full catalog is 157K+; we
        # rely on cumulative pulls + xref dedup to converge.
        if pull_listings:
            try:
                collected = list(sg.iter_seller_listings(max_pages=5, per_page=200))
                stats = sg.store_seller_listings(collected)
                summary["listings"] = stats
            except Exception as e:
                summary["errors"].append(f"listings: {e}")

        # Orders by status
        for status_filter in [s.strip() for s in (statuses or "").split(",") if s.strip()]:
            try:
                collected: list = []
                for o in sg.iter_seller_orders(status_filter, max_pages=100):
                    collected.append(o)
                stats = sg.store_seller_orders(collected, status_filter)
                summary["orders_by_status"][status_filter] = stats
            except Exception as e:
                summary["errors"].append(f"orders[{status_filter}]: {e}")

        summary["finished_at"] = datetime.now(timezone.utc).isoformat()
        return summary

    return router
