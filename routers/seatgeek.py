"""SeatGeek read routes — event / listings / sales / seller-listings /
seller-orders / seller-status.

Slice 9 of the app.py decomposition (BR-CODE-1). All read-only require_sb reads
of persisted SG snapshots/seller tables (no SG API calls — the link/sync POSTs
stay in app.py). Factory takes a live require_sb getter + require_auth; behavior
identical to the prior inline app.py routes.
"""
from __future__ import annotations

from typing import Callable

from fastapi import APIRouter, Depends


def build_seatgeek_router(get_require_sb: Callable[[], Callable], require_auth: Callable) -> APIRouter:
    router = APIRouter()

    @router.get("/api/seatgeek/event/{event_id}")
    def seatgeek_event(event_id: int, _=Depends(require_auth)):
        db = get_require_sb()()
        rows = (db.table("seatgeek_event_latest").select("*")
                .eq("tevo_event_id", event_id).limit(1).execute()).data or []
        if not rows:
            return {"tevo_event_id": event_id, "linked": False}
        return {"tevo_event_id": event_id, "linked": True, **rows[0]}

    @router.get("/api/seatgeek/event/{event_id}/listings")
    def seatgeek_event_listings(event_id: int, latest_only: bool = True, limit: int = 1000,
                                _=Depends(require_auth)):
        db = get_require_sb()()
        if latest_only:
            last = (db.table("seatgeek_listings_snapshots")
                    .select("captured_at").eq("tevo_event_id", event_id)
                    .order("captured_at", desc=True).limit(1).execute()).data or []
            if not last:
                return {"event_id": event_id, "listings": [], "summary": None}
            rows = (db.table("seatgeek_listings_snapshots")
                    .select("sglid,section,row,quantity,retail_price_all_in,broadcast_price,"
                            "deal_quality_score,is_broker_owned,is_b2b,is_instant_download,"
                            "is_sro,has_limited_view,delivery_method,in_hand_date,"
                            "market_source,stock_type,splits,captured_at")
                    .eq("tevo_event_id", event_id)
                    .eq("captured_at", last[0]["captured_at"])
                    .limit(int(limit)).execute()).data or []
        else:
            rows = (db.table("seatgeek_listings_snapshots")
                    .select("*")
                    .eq("tevo_event_id", event_id)
                    .order("captured_at", desc=True)
                    .limit(int(limit)).execute()).data or []
        if not rows:
            return {"event_id": event_id, "listings": [], "summary": None}
        prices = sorted([r["retail_price_all_in"] for r in rows if r.get("retail_price_all_in") is not None])
        n = len(prices)
        median = prices[n // 2] if n and n % 2 else (prices[n // 2 - 1] + prices[n // 2]) / 2 if n else None
        return {
            "event_id": event_id, "listings": rows,
            "summary": {
                "total_listings": len({r.get("sglid") for r in rows if r.get("sglid")}),
                "total_tickets": sum(int(r.get("quantity") or 0) for r in rows),
                "broker_owned":  sum(1 for r in rows if r.get("is_broker_owned")),
                "b2b_sourced":   sum(1 for r in rows if r.get("is_b2b")),
                "median_retail_all_in": round(median, 2) if median is not None else None,
                "min_retail_all_in":    min(prices) if prices else None,
                "max_retail_all_in":    max(prices) if prices else None,
                "captured_at": rows[0].get("captured_at"),
            },
        }

    @router.get("/api/seatgeek/event/{event_id}/sales")
    def seatgeek_event_sales(event_id: int, limit: int = 1000, _=Depends(require_auth)):
        db = get_require_sb()()
        rows = (db.table("seatgeek_sales_snapshots")
                .select("sg_sale_id,broadcast_price,quantity,section,row,stock_type,"
                        "delivery_method,in_hand_date,is_instant,sale_at_utc")
                .eq("tevo_event_id", event_id)
                .order("sale_at_utc", desc=True)
                .limit(int(limit)).execute()).data or []
        if not rows:
            return {"event_id": event_id, "sales": [], "summary": None}
        bps = sorted([r["broadcast_price"] for r in rows if r.get("broadcast_price") is not None])
        n = len(bps)
        median_bp = bps[n // 2] if n and n % 2 else (bps[n // 2 - 1] + bps[n // 2]) / 2 if n else None
        return {
            "event_id": event_id, "sales": rows,
            "summary": {
                "total_sales": len(rows),
                "total_tickets_sold": sum(int(r.get("quantity") or 0) for r in rows),
                "median_broadcast_price": round(median_bp, 2) if median_bp is not None else None,
                "min_broadcast_price":    min(bps) if bps else None,
                "max_broadcast_price":    max(bps) if bps else None,
                "first_sale": rows[-1].get("sale_at_utc"),
                "last_sale":  rows[0].get("sale_at_utc"),
            },
        }

    @router.get("/api/seatgeek/event/{event_id}/seller-listings")
    def seatgeek_seller_listings_for_event(event_id: int, latest_only: bool = True,
                                           limit: int = 1000, _=Depends(require_auth)):
        db = get_require_sb()()
        if latest_only:
            last = (db.table("seatgeek_seller_listings")
                    .select("pulled_at").eq("tevo_event_id", event_id)
                    .order("pulled_at", desc=True).limit(1).execute()).data or []
            if not last:
                return {"event_id": event_id, "listings": [], "summary": None}
            rows = (db.table("seatgeek_seller_listings")
                    .select("sg_listing_id,seller_listing_id,sg_event_id,sg_event_name,"
                            "sg_venue,sg_event_date,sg_event_time,quantity,section,row,"
                            "cost,is_edelivery,is_instant,in_hand_date,notes,pulled_at")
                    .eq("tevo_event_id", event_id)
                    .eq("pulled_at", last[0]["pulled_at"])
                    .limit(int(limit)).execute()).data or []
        else:
            rows = (db.table("seatgeek_seller_listings").select("*")
                    .eq("tevo_event_id", event_id)
                    .order("pulled_at", desc=True)
                    .limit(int(limit)).execute()).data or []
        if not rows:
            return {"event_id": event_id, "listings": [], "summary": None}
        return {
            "event_id": event_id, "listings": rows,
            "summary": {
                "total_listings": len({r.get("sg_listing_id") for r in rows if r.get("sg_listing_id")}),
                "total_tickets": sum(int(r.get("quantity") or 0) for r in rows),
                "median_cost": (sorted([r["cost"] for r in rows if r.get("cost") is not None])[len(rows) // 2]
                                if any(r.get("cost") is not None for r in rows) else None),
                "captured_at": rows[0].get("pulled_at"),
            },
        }

    @router.get("/api/seatgeek/event/{event_id}/seller-orders")
    def seatgeek_seller_orders_for_event(event_id: int, _=Depends(require_auth)):
        db = get_require_sb()()
        rows = (db.table("seatgeek_orders")
                .select("sg_order_id,status,created_at_sg,sale_price,sale_quantity,"
                        "sale_section,sale_row,sg_event_name,sg_venue,sg_event_date,"
                        "delivery_method,stock_type,fulfillment_issue_message,"
                        "payment_total,last_status_at")
                .eq("tevo_event_id", event_id)
                .order("created_at_sg", desc=True).execute()).data or []
        if not rows:
            return {"event_id": event_id, "orders": [], "summary": None}
        by_status: dict[str, int] = {}
        tickets_sold = 0
        gross = 0.0
        for r in rows:
            st = r.get("status") or "unknown"
            by_status[st] = by_status.get(st, 0) + 1
            if st in ("confirmed", "fulfilled", "delivered"):
                q = int(r.get("sale_quantity") or 0)
                p = float(r.get("sale_price") or 0)
                tickets_sold += q
                gross += p * q
        return {
            "event_id": event_id, "orders": rows,
            "summary": {
                "total_orders": len(rows),
                "by_status": by_status,
                "tickets_sold": tickets_sold,
                "gross_sold":   round(gross, 2),
                "last_order_at": rows[0].get("last_status_at") if rows else None,
            },
        }

    @router.get("/api/seatgeek/seller-status")
    def seatgeek_seller_status(_=Depends(require_auth)):
        db = get_require_sb()()
        pull_log = (db.table("seatgeek_seller_pull_log").select("*")
                    .order("called_at", desc=True).limit(20).execute()).data or []
        listing_stats = (db.table("seatgeek_seller_listings")
                         .select("sg_event_id,tevo_event_id,pulled_at")
                         .order("pulled_at", desc=True).limit(2000).execute()).data or []
        distinct_sg = len({r["sg_event_id"] for r in listing_stats if r.get("sg_event_id")})
        linked_sg = len({r["sg_event_id"] for r in listing_stats
                         if r.get("sg_event_id") and r.get("tevo_event_id")})
        order_count_q = (db.table("seatgeek_orders").select("id", count="exact").limit(1).execute())
        return {
            "recent_pulls": pull_log[:10],
            "distinct_sg_events_in_listings": distinct_sg,
            "auto_linked_to_tevo": linked_sg,
            "auto_link_rate": (linked_sg / distinct_sg) if distinct_sg else None,
            "total_orders_persisted": getattr(order_count_q, "count", None) or 0,
            "last_listings_pulled_at": listing_stats[0]["pulled_at"] if listing_stats else None,
        }

    return router
