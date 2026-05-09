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

from supabase import Client

API_BASE = "https://brokerdata.seatgeek.com"


class SeatGeekError(Exception):
    pass


class SeatGeekScopeError(SeatGeekError):
    """Token works but lacks scope for this endpoint (HTTP 401, code 421004)."""


class SeatGeekClient:
    def __init__(
        self,
        api_token: str | None = None,
        db: Client | None = None,
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
