"""SeatGeek BROKER DATA API client.

Host: https://brokerdata.seatgeek.com
Auth: ?token=<TOKEN> query param. Token in vault as SEATGEEK_API_TOKEN.

This is the partner-only Seller Direct Broker Data API — DIFFERENT from
the public SG API at api.seatgeek.com/2 (which our token doesn't grant
access to). Endpoints we use:

  GET /listings        broker inventory for an event_id (this account's
                       view of the marketplace)
  GET /v2/listings     ALL secondary listings on SG marketplace for an
                       event (broader, full competitor visibility)
  GET /sales           transacted sales for an event (broker side; only
                       broadcast/wholesale price exposed, not retail)
  GET /purchases       broker's own SG purchases (token currently lacks
                       this scope — kept here for when SG enables it)

ID model: SG event_id is independent from TEvo event_id. The broker API
has NO search endpoint, so matching is manual:
  1. User finds SG event_id (broker portal, SG website URL, etc.)
  2. POST /api/seatgeek/event/{tevo_event_id}/link?sg_event_id=N
  3. Subsequent /sync-listings + /sync-sales work off the xref.
"""
from __future__ import annotations

import hashlib
import os
import random
import time
from datetime import datetime, timezone
from typing import Any

import requests

# Type-only import: this module's runtime guards (RULE 2) must be importable
# in environments where the `supabase` package isn't installed (e.g. minimal
# CI containers running scripts/check_readonly.py and tests/test_readonly_guards.py).
from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from supabase import Client  # pragma: no cover

API_BASE = "https://brokerdata.seatgeek.com"
# Seller Direct API — different host, same partner token. Read-only ingest.
SELLER_DIRECT_BASE = "https://sellerdirect-api.seatgeek.com"

# RULE 2 — READ-ONLY across all SeatGeek surfaces.
# We never POST/PUT/PATCH/DELETE to brokerdata.seatgeek.com or
# sellerdirect-api.seatgeek.com. Any non-GET method here is a bug.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


def _assert_readonly_method(method: str) -> None:
    """Hard guard: this client must never write back to SeatGeek."""
    if method.upper() not in ALLOWED_HTTP_METHODS:
        raise SeatGeekError(
            f"READ-ONLY violation: method {method} is not allowed. "
            "SeatGeek integration is strictly read-only (RULE 2 in SCHEMA.md). "
            "Pulling data only — never write back to SG."
        )


class SeatGeekError(Exception):
    pass


class SeatGeekScopeError(SeatGeekError):
    """Token works but lacks scope for this endpoint (HTTP 401, code 421004)."""


class SeatGeekClient:
    def __init__(
        self,
        api_token: str | None = None,
        db: "Client | None" = None,
        timeout_s: int = 25,
    ):
        # Token resolution: explicit arg → env → Supabase Vault → error.
        self.db = db
        self.api_token = api_token or os.environ.get("SEATGEEK_API_TOKEN")
        if not self.api_token and db is not None:
            try:
                res = db.rpc("get_app_secret", {"p_name": "SEATGEEK_API_TOKEN"}).execute()
                self.api_token = res.data if isinstance(res.data, str) else None
            except Exception as e:
                print(f"seatgeek: vault lookup failed: {e}")
        if not self.api_token:
            raise SeatGeekError(
                "SEATGEEK_API_TOKEN not found. Either set the env var, or store "
                "it in Vault: SELECT public.upsert_app_secret('SEATGEEK_API_TOKEN', '<token>')."
            )
        self.timeout_s = timeout_s
        self.session = requests.Session()
        self.session.headers.update({
            "Accept": "application/json",
            "User-Agent": "Terminal-2/1.0 (broker terminal)",
        })

    # ---------- internal HTTP ----------

    def _log_pull(self, endpoint: str, *, tevo_event_id: int | None,
                  sg_event_id: int | None, status: int, rows: int | None,
                  cache_hit: bool | None, refreshed_at_utc: str | None,
                  error: str | None = None, meta: dict | None = None) -> None:
        if not self.db:
            return
        try:
            self.db.table("seatgeek_pull_log").insert({
                "endpoint": endpoint,
                "tevo_event_id": tevo_event_id,
                "sg_event_id": sg_event_id,
                "http_status": status,
                "rows_returned": rows,
                "cache_hit": cache_hit,
                "refreshed_at_utc": refreshed_at_utc,
                "error_message": error,
                "request_meta": meta or {},
            }).execute()
        except Exception as e:
            print(f"seatgeek: pull log failed: {e}")

    def _get(self, path: str, params: dict | None = None,
             max_429_retries: int = 3) -> tuple[int, dict | list]:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{API_BASE}/{path.lstrip('/')}"
        clean: dict[str, Any] = {"token": self.api_token}
        for k, v in (params or {}).items():
            if v is None:
                continue
            clean[k] = (1 if v else 0) if isinstance(v, bool) else v
        attempt = 0
        backoff = 1.0
        while True:
            attempt += 1
            r = self.session.get(url, params=clean, timeout=self.timeout_s)
            if r.status_code == 429 and attempt <= max_429_retries:
                ra = r.headers.get("Retry-After")
                try:
                    sleep_s = float(ra) if ra else backoff
                except ValueError:
                    sleep_s = backoff
                time.sleep(min(60.0, sleep_s + random.random()))
                backoff = min(60.0, backoff * 2)
                continue
            try:
                body = r.json()
            except ValueError:
                body = {"raw_text": r.text}
            return r.status_code, body

    @staticmethod
    def _parse_iso(s: str | None):
        if not s:
            return None
        return s.replace("Z", "+00:00") if isinstance(s, str) and s.endswith("Z") else s

    @staticmethod
    def _hash_listing(l: dict) -> str:
        """Stable content hash for dedup. Includes the price + qty + flags
        so a re-pull only inserts a row when something changed."""
        canon = "|".join(str(l.get(k, "")) for k in (
            "sglid", "pf", "bp", "ds", "q", "s", "r",
            "bo", "is_b2b", "idl", "sro", "lv", "wa",
            "dm", "ihd", "m", "st", "ada",
        ))
        return hashlib.sha256(canon.encode("utf-8")).hexdigest()[:32]

    # ---------- /listings + /v2/listings ----------

    def listings(self, sg_event_id: int, *, v2: bool = False,
                 tevo_event_id: int | None = None) -> dict:
        """Fetch listings for an event. v2=True calls /v2/listings (broader —
        ALL secondary marketplace listings). v2=False calls /listings (broker
        scope only). Returns the full response dict.
        """
        path = "v2/listings" if v2 else "listings"
        status, body = self._get(f"/{path}", params={"event_id": int(sg_event_id)})
        listings = (body or {}).get("listings") if isinstance(body, dict) else []
        rows = len(listings or [])
        ev = (body or {}).get("event") if isinstance(body, dict) else None
        if status == 200:
            self._log_pull(path, tevo_event_id=tevo_event_id, sg_event_id=sg_event_id,
                           status=status, rows=rows,
                           cache_hit=(body or {}).get("cache_hit"),
                           refreshed_at_utc=(body or {}).get("refreshed_at_utc"),
                           meta={"event_inline": ev})
            return body if isinstance(body, dict) else {"event": None, "listings": []}
        # Handle 401 scope-denied with a typed exception so the route can return 403
        msg = ((body or {}).get("error") or {}).get("message") if isinstance(body, dict) else str(body)[:200]
        self._log_pull(path, tevo_event_id=tevo_event_id, sg_event_id=sg_event_id,
                       status=status, rows=None, cache_hit=None,
                       refreshed_at_utc=None, error=msg)
        if status == 401:
            raise SeatGeekScopeError(f"/{path} scope denied: {msg}")
        raise SeatGeekError(f"/{path} returned {status}: {msg}")

    # ---------- /sales ----------

    def sales(self, sg_event_id: int, *, tevo_event_id: int | None = None) -> dict:
        status, body = self._get("/sales", params={"event_id": int(sg_event_id)})
        sales = (body or {}).get("sales") if isinstance(body, dict) else []
        rows = len(sales or [])
        ev = (body or {}).get("event") if isinstance(body, dict) else None
        if status == 200:
            self._log_pull("sales", tevo_event_id=tevo_event_id, sg_event_id=sg_event_id,
                           status=status, rows=rows,
                           cache_hit=(body or {}).get("cache_hit"),
                           refreshed_at_utc=(body or {}).get("refreshed_at_utc"),
                           meta={"event_inline": ev})
            return body if isinstance(body, dict) else {"event": None, "sales": []}
        msg = ((body or {}).get("error") or {}).get("message") if isinstance(body, dict) else str(body)[:200]
        self._log_pull("sales", tevo_event_id=tevo_event_id, sg_event_id=sg_event_id,
                       status=status, rows=None, cache_hit=None,
                       refreshed_at_utc=None, error=msg)
        if status == 401:
            raise SeatGeekScopeError(f"/sales scope denied: {msg}")
        raise SeatGeekError(f"/sales returned {status}: {msg}")

    # ---------- /purchases (currently scope-denied for our token) ----------

    def purchases(self, *, start_time: str | None = None, end_time: str | None = None,
                  event_id: int | None = None, order_ids: str | None = None,
                  order_status: str | None = None, page: int = 1,
                  per_page: int = 10) -> dict:
        params = {
            "start_time": start_time, "end_time": end_time,
            "event_id": event_id, "order_ids": order_ids,
            "order_status": order_status,
            "page": page, "per_page": min(int(per_page), 10),
        }
        status, body = self._get("/purchases", params=params)
        if status == 200:
            return body if isinstance(body, dict) else {"purchases": []}
        msg = ((body or {}).get("error") or {}).get("message") if isinstance(body, dict) else str(body)[:200]
        if status == 401:
            raise SeatGeekScopeError(f"/purchases scope denied: {msg}")
        raise SeatGeekError(f"/purchases returned {status}: {msg}")

    # ---------- DB persistence ----------

    def link_event(self, tevo_event_id: int, sg_event_id: int,
                   sg_event_inline: dict | None = None,
                   *, match_method: str = "manual",
                   confidence: float | None = 1.0) -> None:
        """Upsert the TEvo↔SG event xref. sg_event_inline is the `event`
        block from any /listings or /sales response — it carries name,
        location, type, start_data so we cache them on the xref row."""
        if not self.db:
            return
        ev = sg_event_inline or {}
        self.db.table("seatgeek_event_xref").upsert({
            "tevo_event_id": int(tevo_event_id),
            "sg_event_id": int(sg_event_id),
            "sg_event_name": ev.get("name"),
            "sg_event_type": ev.get("type"),
            "sg_event_location": ev.get("location"),
            "sg_start_data": self._parse_iso(ev.get("start_data")),
            "sg_visible_until": self._parse_iso(ev.get("visible_until_utc")),
            "match_method": match_method,
            "match_confidence": confidence,
        }, on_conflict="tevo_event_id").execute()

    def store_listings(self, tevo_event_id: int, sg_event_id: int,
                       listings: list, *, endpoint: str = "v1") -> int:
        """Insert listings rows, deduped via (tevo_event_id, sglid, content_hash).
        Returns count of newly-inserted rows."""
        if not self.db or not listings:
            return 0
        ts = datetime.now(timezone.utc).isoformat()
        rows = []
        for l in listings:
            # SG returns ihd as a date string (or empty); coerce to date or None
            ihd = l.get("ihd")
            ihd_clean = ihd[:10] if isinstance(ihd, str) and len(ihd) >= 10 else None
            rows.append({
                "tevo_event_id": int(tevo_event_id),
                "sg_event_id": int(sg_event_id),
                "captured_at": ts,
                "sglid": int(l["sglid"]) if l.get("sglid") is not None else None,
                "display_id": l.get("id"),
                "retail_price_all_in": l.get("pf"),
                "broadcast_price": l.get("bp"),
                "deal_quality_score": l.get("ds"),
                "quantity": l.get("q"),
                "splits": l.get("sp") or [],
                "section": l.get("s"),
                "row": l.get("r"),
                "is_broker_owned":     bool(l.get("bo")) if l.get("bo") is not None else None,
                "is_b2b":              bool(l.get("is_b2b")) if l.get("is_b2b") is not None else None,
                "is_instant_download": bool(l.get("idl")) if l.get("idl") is not None else None,
                "is_sro":              bool(l.get("sro")) if l.get("sro") is not None else None,
                "has_limited_view":    bool(l.get("lv"))  if l.get("lv")  is not None else None,
                "is_wheelchair_acc":   bool(l.get("wa"))  if l.get("wa")  is not None else None,
                "ada_details":  l.get("ada"),
                "delivery_method": l.get("dm"),
                "in_hand_date": ihd_clean,
                "market_source": l.get("m"),
                "stock_type": l.get("st"),
                "seller_notes": l.get("pn"),
                "endpoint": endpoint,
                "content_hash": self._hash_listing(l),
                "raw": l,
            })
        try:
            res = self.db.table("seatgeek_listings_snapshots").upsert(
                rows, on_conflict="tevo_event_id,sglid,content_hash"
            ).execute()
            # Update last_listings_at on the xref
            self.db.table("seatgeek_event_xref").update({
                "last_listings_at": ts,
            }).eq("tevo_event_id", int(tevo_event_id)).execute()
            return len(res.data or [])
        except Exception as e:
            print(f"seatgeek: store_listings failed: {e}")
            return 0

    def store_sales(self, tevo_event_id: int, sg_event_id: int, sales: list) -> int:
        """Insert sales rows, deduped via (tevo_event_id, sg_sale_id)."""
        if not self.db or not sales:
            return 0
        rows = []
        for s in sales:
            ihd = s.get("ihd")
            ihd_clean = ihd[:10] if isinstance(ihd, str) and len(ihd) >= 10 else None
            sale_at = self._parse_iso(s.get("putc"))
            if not sale_at:
                # Skip rows with no sale time — would violate NOT NULL
                continue
            rows.append({
                "tevo_event_id": int(tevo_event_id),
                "sg_event_id": int(sg_event_id),
                "sg_sale_id": s.get("id"),
                "broadcast_price": s.get("bp"),
                "quantity": s.get("q"),
                "section": s.get("s"),
                "row": s.get("r"),
                "stock_type": s.get("st"),
                "delivery_method": s.get("dm"),
                "in_hand_date": ihd_clean,
                "is_instant": bool(s.get("idl")) if s.get("idl") is not None else None,
                "seller_notes": s.get("pn"),
                "sale_at_utc": sale_at,
                "raw": s,
            })
        if not rows:
            return 0
        try:
            res = self.db.table("seatgeek_sales_snapshots").upsert(
                rows, on_conflict="tevo_event_id,sg_sale_id"
            ).execute()
            self.db.table("seatgeek_event_xref").update({
                "last_sales_at": datetime.now(timezone.utc).isoformat(),
            }).eq("tevo_event_id", int(tevo_event_id)).execute()
            return len(res.data or [])
        except Exception as e:
            print(f"seatgeek: store_sales failed: {e}")
            return 0

    # ============================================================
    # SELLER DIRECT API (sellerdirect-api.seatgeek.com)
    # ============================================================
    # Read-only — pulls our S4K listings catalog + orders. The data on
    # these endpoints carries SG event_id + name + venue + date INLINE,
    # which is the discovery mechanism for backfilling seatgeek_event_xref
    # automatically (no manual matching needed for events we have inventory
    # or orders on).

    def _get_seller(self, path: str, params: dict | None = None,
                    max_429_retries: int = 3) -> tuple[int, dict | list]:
        """Same shape as _get but for SELLER_DIRECT_BASE."""
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{SELLER_DIRECT_BASE}/{path.lstrip('/')}"
        clean: dict[str, Any] = {"token": self.api_token}
        for k, v in (params or {}).items():
            if v is None:
                continue
            clean[k] = (1 if v else 0) if isinstance(v, bool) else v
        attempt = 0
        backoff = 1.0
        while True:
            attempt += 1
            r = self.session.get(url, params=clean, timeout=self.timeout_s)
            if r.status_code == 429 and attempt <= max_429_retries:
                ra = r.headers.get("Retry-After")
                try:
                    sleep_s = float(ra) if ra else backoff
                except ValueError:
                    sleep_s = backoff
                time.sleep(min(60.0, sleep_s + random.random()))
                backoff = min(60.0, backoff * 2)
                continue
            try:
                body = r.json()
            except ValueError:
                body = {"raw_text": r.text}
            return r.status_code, body

    def seller_listings(self, *, event_id: int | None = None,
                        per_page: int = 200,
                        page_cursor: str | None = None) -> dict:
        """GET /listings — full S4K catalog OR filtered by event_id.
        Pagination uses page_cursor (the deprecated `page` int still
        returns 400 from the server). Returns the full body dict so the
        caller can inspect meta + next cursor."""
        params: dict = {"per_page": per_page}
        if event_id is not None:
            params["event_id"] = int(event_id)
        if page_cursor:
            params["page_cursor"] = page_cursor
        status, body = self._get_seller("/listings", params=params)
        listings = (body or {}).get("listings") if isinstance(body, dict) else []
        if self.db:
            try:
                self.db.table("seatgeek_seller_pull_log").insert({
                    "endpoint": "/listings", "http_status": status,
                    "rows_returned": len(listings or []),
                    "total_reported": ((body or {}).get("meta") or {}).get("total"),
                    "request_meta": params,
                }).execute()
            except Exception:
                pass
        if status != 200:
            raise SeatGeekError(f"/listings returned {status}: {str(body)[:200]}")
        return body if isinstance(body, dict) else {"listings": listings or []}

    def iter_seller_listings(self, *, max_pages: int = 5, per_page: int = 200):
        """Walk /listings via page_cursor. Yields each listing dict.
        Default pulls just first 5 pages (1000 listings) — full catalog
        is 157K+ items, so use larger max_pages for full sweep."""
        cursor = None
        for _ in range(max_pages):
            body = self.seller_listings(per_page=per_page, page_cursor=cursor)
            listings = body.get("listings") or []
            if not listings:
                break
            for l in listings:
                yield l
            meta = body.get("meta") or {}
            prev_cursor = cursor
            cursor = meta.get("next_cursor") or meta.get("next_page_cursor") or meta.get("page_cursor")
            # Stop if the cursor didn't advance. Some APIs echo the *current*
            # page_cursor back in meta; without this guard the third fallback
            # would re-request the same page each iteration (re-yielding dupes,
            # never advancing) until max_pages.
            if not cursor or cursor == prev_cursor:
                break

    def seller_orders(self, status_filter: str, *, page: int = 1) -> dict:
        """GET /orders?status={X}&page={N}. Status is REQUIRED.
        Valid: open | confirmed | fulfilled | pending | cancelled | delivered."""
        status, body = self._get_seller("/orders", params={"status": status_filter, "page": page})
        orders = (body or {}).get("orders") if isinstance(body, dict) else []
        meta = (body or {}).get("meta") if isinstance(body, dict) else {}
        if self.db:
            try:
                self.db.table("seatgeek_seller_pull_log").insert({
                    "endpoint": "/orders",
                    "status_filter": status_filter,
                    "page": page,
                    "http_status": status,
                    "rows_returned": len(orders or []),
                    "total_reported": (meta or {}).get("total"),
                }).execute()
            except Exception:
                pass
        if status != 200:
            raise SeatGeekError(f"/orders?status={status_filter} returned {status}: {str(body)[:200]}")
        return body if isinstance(body, dict) else {"orders": [], "meta": {}}

    def iter_seller_orders(self, status_filter: str, *, max_pages: int = 50):
        """Auto-paginate through /orders for one status filter. Yields each
        order dict. Stops when total_reached or empty page returned."""
        seen = 0
        for page in range(1, max_pages + 1):
            body = self.seller_orders(status_filter, page=page)
            orders = body.get("orders") or []
            meta = body.get("meta") or {}
            total = meta.get("total") or 0
            if not orders:
                break
            for o in orders:
                yield o
            seen += len(orders)
            if total and seen >= total:
                break

    def seller_order(self, order_id: str) -> dict:
        """GET /order?order_id={X}. Single-order detail (Apps Script's primary call)."""
        status, body = self._get_seller("/order", params={"order_id": str(order_id)})
        if self.db:
            try:
                self.db.table("seatgeek_seller_pull_log").insert({
                    "endpoint": "/order", "http_status": status,
                    "rows_returned": 1 if status == 200 else 0,
                    "request_meta": {"order_id": order_id},
                }).execute()
            except Exception:
                pass
        if status != 200:
            # Don't echo order_id or body in the user-facing error — both can
            # carry attacker-controlled bytes. Hardened 2026-05-11.
            raise SeatGeekError(f"/order lookup returned HTTP {status}")
        return body if isinstance(body, dict) else {}

    @staticmethod
    def _hash_seller_listing(l: dict) -> str:
        canon = "|".join(str(l.get(k, "")) for k in (
            "sg_listing_id", "section", "row", "quantity", "cost",
            "is_edelivery", "is_instant", "in_hand_date", "notes",
            "seat_from", "seat_thru",
        ))
        return hashlib.sha256(canon.encode("utf-8")).hexdigest()[:32]

    def store_seller_listings(self, listings: list) -> dict:
        """Persist listings + auto-backfill seatgeek_event_xref via
        sg_attempt_event_xref(). Returns counts dict."""
        if not self.db or not listings:
            return {"received": 0, "inserted": 0, "events_seen": 0, "events_linked": 0}
        ts = datetime.now(timezone.utc).isoformat()
        # Dedup-and-batch-resolve event xrefs first to avoid hammering the RPC
        events_seen: dict[int, dict] = {}
        for l in listings:
            sg_eid = l.get("event_id")
            if sg_eid is None:
                continue
            try:
                sg_eid_i = int(sg_eid)
            except (TypeError, ValueError):
                continue
            if sg_eid_i not in events_seen:
                events_seen[sg_eid_i] = {
                    "sg_event_id": sg_eid_i,
                    "sg_event_name": l.get("event"),
                    "sg_venue": l.get("venue"),
                    "sg_event_date": l.get("event_date"),
                }
        events_linked = 0
        tevo_by_sg: dict[int, int] = {}
        for sg_eid, meta in events_seen.items():
            try:
                res = self.db.rpc("sg_attempt_event_xref", {
                    "p_sg_event_id": meta["sg_event_id"],
                    "p_sg_event_name": meta["sg_event_name"],
                    "p_sg_event_date": meta["sg_event_date"],
                    "p_sg_venue": meta["sg_venue"],
                }).execute()
                tevo_id = res.data if isinstance(res.data, int) else (res.data or {}).get("sg_attempt_event_xref")
                if tevo_id:
                    tevo_by_sg[sg_eid] = int(tevo_id)
                    events_linked += 1
            except Exception as e:
                print(f"seatgeek: sg_attempt_event_xref failed for {sg_eid}: {e}")

        rows = []
        for l in listings:
            sg_eid = l.get("event_id")
            if sg_eid is None:
                continue
            try:
                sg_eid_i = int(sg_eid)
            except (TypeError, ValueError):
                continue
            ihd = l.get("in_hand_date")
            ihd_clean = ihd[:10] if isinstance(ihd, str) and len(ihd) >= 10 else None
            rows.append({
                "pulled_at": ts,
                "seller_listing_id": l.get("seller_listing_id"),
                "ticket_id": l.get("ticket_id"),
                "sg_listing_id": int(l["sg_listing_id"]) if l.get("sg_listing_id") is not None else None,
                "sg_event_id": sg_eid_i,
                "sg_event_name": l.get("event"),
                "sg_venue": l.get("venue"),
                "sg_event_date": l.get("event_date"),
                "sg_event_time": l.get("event_time"),
                "quantity": l.get("quantity"),
                "section": l.get("section"),
                "row": l.get("row"),
                "seat_from": l.get("seat_from"),
                "seat_thru": l.get("seat_thru"),
                "notes": l.get("notes"),
                "cost": l.get("cost"),
                "is_edelivery": l.get("is_edelivery"),
                "is_instant": l.get("is_instant"),
                "in_hand_date": ihd_clean,
                "tevo_event_id": tevo_by_sg.get(sg_eid_i),
                "content_hash": self._hash_seller_listing(l),
                "raw": l,
            })
        try:
            # Dedup on the NON-NULL key (sg_event_id, content_hash). The old
            # (sg_listing_id, content_hash) key never matched NULL sg_listing_id
            # rows (NULL <> NULL) -> unbounded duplicate inserts on re-pull.
            # content_hash already incorporates sg_listing_id + every defining
            # attribute, so this dedups by (event, content-version) with no NULL
            # hole. Requires mig 20260626120000 (BUGHUNT-1) applied first.
            res = self.db.table("seatgeek_seller_listings").upsert(
                rows, on_conflict="sg_event_id,content_hash"
            ).execute()
            return {"received": len(listings), "inserted": len(res.data or []),
                    "events_seen": len(events_seen), "events_linked": events_linked}
        except Exception as e:
            print(f"seatgeek: store_seller_listings failed: {e}")
            return {"received": len(listings), "inserted": 0,
                    "events_seen": len(events_seen), "events_linked": events_linked,
                    "error": str(e)}

    def store_seller_orders(self, orders: list, status_filter: str) -> dict:
        """Persist orders + auto-backfill xref. Returns counts dict."""
        if not self.db or not orders:
            return {"received": 0, "upserted": 0, "tickets_inserted": 0,
                    "events_seen": 0, "events_linked": 0}
        # Dedup events for batched xref resolution
        events_seen: dict[int, dict] = {}
        for o in orders:
            ev = o.get("event") or {}
            sg_eid = ev.get("seatgeek_event_id")
            if sg_eid is None:
                continue
            try:
                sg_eid_i = int(sg_eid)
            except (TypeError, ValueError):
                continue
            if sg_eid_i not in events_seen:
                events_seen[sg_eid_i] = {
                    "sg_event_id": sg_eid_i,
                    "sg_event_name": ev.get("name"),
                    "sg_venue": ev.get("venue"),
                    "sg_event_date": ev.get("date"),
                }
        tevo_by_sg: dict[int, int] = {}
        events_linked = 0
        for sg_eid, meta in events_seen.items():
            try:
                res = self.db.rpc("sg_attempt_event_xref", {
                    "p_sg_event_id": meta["sg_event_id"],
                    "p_sg_event_name": meta["sg_event_name"],
                    "p_sg_event_date": meta["sg_event_date"],
                    "p_sg_venue": meta["sg_venue"],
                }).execute()
                tevo_id = res.data if isinstance(res.data, int) else (res.data or {}).get("sg_attempt_event_xref")
                if tevo_id:
                    tevo_by_sg[sg_eid] = int(tevo_id)
                    events_linked += 1
            except Exception as e:
                print(f"seatgeek: sg_attempt_event_xref failed for {sg_eid}: {e}")

        order_rows = []
        ticket_rows = []
        ts_now = datetime.now(timezone.utc).isoformat()
        for o in orders:
            sg_oid = o.get("id")
            if not sg_oid:
                continue
            ev = o.get("event") or {}
            listing = o.get("listing") or {}
            payment = o.get("payment") or {}
            sg_eid = ev.get("seatgeek_event_id")
            try:
                sg_eid_i = int(sg_eid) if sg_eid is not None else None
            except (TypeError, ValueError):
                sg_eid_i = None
            order_rows.append({
                "sg_order_id": sg_oid,
                "status": status_filter,
                "created_at_sg": self._parse_iso(o.get("created")),
                "delivery": o.get("delivery"),
                "delivery_method": o.get("delivery_method"),
                "stock_type": o.get("stock_type"),
                "fulfillment_issue_message": o.get("fulfillment_issue_message"),
                "pickup_email": o.get("pickup_email"),
                "pickup_phone": o.get("pickup_phone"),
                "pickup_availability": o.get("pickup_availability"),
                "pickup_location": o.get("pickup_location"),
                "pickup_instructions": o.get("pickup_instructions"),
                "sg_event_id": sg_eid_i,
                "sg_event_name": ev.get("name"),
                "sg_venue": ev.get("venue"),
                "sg_event_date": ev.get("date"),
                "sg_event_time": ev.get("time"),
                "sg_listing_id": listing.get("id"),
                "sale_price": listing.get("price"),
                "sale_row": listing.get("row"),
                "sale_section": listing.get("section"),
                "sale_quantity": listing.get("quantity"),
                "tevo_event_id": tevo_by_sg.get(sg_eid_i) if sg_eid_i else None,
                "payment_total": payment.get("total"),
                "payment_price": payment.get("price"),
                "payment_fees": payment.get("fees"),
                "payment_tax": payment.get("tax"),
                "payment_delivery": payment.get("delivery"),
                "last_status_at": ts_now,
                "raw": o,
            })
            for i, t in enumerate(o.get("tickets") or []):
                bc = t.get("barcode") or {}
                ticket_rows.append({
                    "sg_order_id": sg_oid,
                    "ticket_index": i,
                    "section": t.get("section"),
                    "row": t.get("row"),
                    "seat": t.get("seat"),
                    "is_ada": t.get("is_ada"),
                    "is_ga": t.get("ga"),
                    "obstructed_view": t.get("obstructed_view"),
                    "barcode_type": bc.get("type"),
                    "barcode_value": bc.get("value"),
                    "mobile_passes": t.get("mobile_passes") or [],
                    "raw": t,
                })

        upserted = 0
        try:
            if order_rows:
                res = self.db.table("seatgeek_orders").upsert(
                    order_rows, on_conflict="sg_order_id"
                ).execute()
                upserted = len(res.data or [])
            # Ticket rows: replace per order to handle add/remove cleanly
            sg_oids = list({r["sg_order_id"] for r in order_rows})
            if sg_oids:
                self.db.table("seatgeek_order_tickets").delete().in_("sg_order_id", sg_oids).execute()
            if ticket_rows:
                self.db.table("seatgeek_order_tickets").insert(ticket_rows).execute()
        except Exception as e:
            print(f"seatgeek: store_seller_orders failed: {e}")
            return {"received": len(orders), "upserted": upserted,
                    "tickets_inserted": len(ticket_rows),
                    "events_seen": len(events_seen),
                    "events_linked": events_linked, "error": str(e)}
        return {"received": len(orders), "upserted": upserted,
                "tickets_inserted": len(ticket_rows),
                "events_seen": len(events_seen), "events_linked": events_linked}
