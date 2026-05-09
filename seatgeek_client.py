"""SeatGeek API client — third data source. Metadata + discovery only.

SeatGeek's public API does NOT expose pricing or transacted sales (those
are TEvo + SeatData jobs). What SG adds beyond what we already have:
  * Cross-validation of event / venue / performer naming + lat/lng
  * Section info per venue (canonical seating layouts)
  * Recommendations (related events/performers, affinity-scored)
  * Performer images (4 sizes: huge / large / medium / small)
  * SeatGeek's taxonomy tree (cross-reference with TEvo classification)

Endpoints implemented (per spec dropped 2026-05-09):

  Events
    GET /events                              list / search
    GET /events/{eventId}                    show single
    GET /events/section_info/{eventId}       venue layout for an event

  Performers
    GET /performers                          list / search
    GET /performers/{performerId}            show single

  Venues
    GET /venues                              list / search
    GET /venues/{venueId}                    show single

  Taxonomies
    GET /taxonomies                          full taxonomy tree

  Recommendations
    GET /recommendations                     events similar to seed
    GET /recommendations/performers          performers similar to seed

Auth: SeatGeek public API uses ?client_id=X (query param). Some endpoints
accept HTTP Basic with client_id+client_secret for higher rate limits.
Both are read from Supabase Vault (preferred) or env vars (override).

Rate limits: SG doesn't publish hard numbers; observed ~1000 req/hour
for public endpoints. We respect 429 with exponential backoff; no DB
budget table since calls are free.
"""
from __future__ import annotations

import os
import random
import time
from typing import Any, Iterator

import requests

from supabase import Client

API_BASE = "https://api.seatgeek.com/2"


class SeatGeekError(Exception):
    pass


class SeatGeekClient:
    def __init__(
        self,
        api_token: str | None = None,
        db: Client | None = None,
        timeout_s: int = 20,
    ):
        # Key resolution: explicit arg → env (SEATGEEK_API_TOKEN) → Vault → error.
        # SeatGeek calls the auth value `client_id` in the URL but we treat it
        # as a single API token internally to match TEvo + SeatData naming.
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
                "SEATGEEK_API_TOKEN not found. Either set the env var, or "
                "store it in Vault: SELECT public.upsert_app_secret('SEATGEEK_API_TOKEN', '<token>')."
            )
        # `client_id` is what SeatGeek's URL params want — it's the same value.
        self.client_id = self.api_token
        self.timeout_s = timeout_s
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": "Terminal-2/1.0 (broker terminal)",
            "Accept": "application/json",
        })

    # -------- internal HTTP --------

    def _log_pull(self, endpoint: str, status: int, rows: int | None,
                  error: str | None = None, meta: dict | None = None) -> None:
        if not self.db:
            return
        try:
            self.db.table("seatgeek_pull_log").insert({
                "endpoint": endpoint, "http_status": status,
                "rows_returned": rows, "error_message": error,
                "request_meta": meta or {},
            }).execute()
        except Exception as e:
            print(f"seatgeek: pull log failed: {e}")

    def _get(self, path: str, params: dict | None = None,
             max_429_retries: int = 3) -> dict | list:
        url = f"{API_BASE}/{path.lstrip('/')}"
        # SG auth: client_id query param (= our api_token internally).
        # Drop None and pass through bool-as-1/0 per SG convention.
        clean: dict[str, Any] = {"client_id": self.client_id}
        for k, v in (params or {}).items():
            if v is None:
                continue
            if isinstance(v, bool):
                clean[k] = 1 if v else 0
            else:
                clean[k] = v
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
                body = {"raw": r.text}
            return body if r.status_code == 200 else (
                self._raise(path, r.status_code, body)
            )

    def _raise(self, path: str, status: int, body: Any) -> dict:
        # Always returns a dict so callers can also inspect error envelopes,
        # but we do raise to surface failures upstream.
        self._log_pull(path, status, None, str(body)[:500])
        raise SeatGeekError(f"GET {path} returned {status}: {body}")

    # -------- Events --------

    def list_events(self, **params) -> dict:
        """GET /events. See spec for query params (performers.id, venue.id,
        datetime_local, datetime_utc with .gt/.gte/.lt/.lte, taxonomies.name,
        q, id, addons_visible, type, page, per_page).
        Returns {events: [...], meta: {...}}."""
        body = self._get("/events", params)
        rows = (body or {}).get("events") if isinstance(body, dict) else []
        self._log_pull("events.list", 200, len(rows or []), meta={"params": params})
        return body if isinstance(body, dict) else {"events": body or []}

    def iter_events(self, *, max_pages: int = 50, per_page: int = 50, **params) -> Iterator[dict]:
        params = dict(params); params.pop("page", None)
        seen = 0
        for page in range(1, max_pages + 1):
            resp = self.list_events(page=page, per_page=min(int(per_page), 100), **params)
            batch = resp.get("events") or []
            total = (resp.get("meta") or {}).get("total", 0)
            if not batch:
                break
            for ev in batch:
                yield ev
            seen += len(batch)
            if total and seen >= total:
                break

    def get_event(self, event_id: int | str) -> dict:
        """GET /events/{id}. Returns the SG event object."""
        body = self._get(f"/events/{event_id}")
        self._log_pull("events.show", 200, 1, meta={"id": event_id})
        return body or {}

    def get_event_sections(self, event_id: int | str) -> dict:
        """GET /events/section_info/{id}. Returns {sections: {section_name: [rows...]}}."""
        body = self._get(f"/events/section_info/{event_id}")
        rows = len(((body or {}).get("sections") or {}))
        self._log_pull("events.section_info", 200, rows, meta={"id": event_id})
        return body or {}

    # -------- Performers --------

    def list_performers(self, **params) -> dict:
        body = self._get("/performers", params)
        rows = (body or {}).get("performers") if isinstance(body, dict) else []
        self._log_pull("performers.list", 200, len(rows or []), meta={"params": params})
        return body if isinstance(body, dict) else {"performers": body or []}

    def get_performer(self, performer_id: int | str) -> dict:
        body = self._get(f"/performers/{performer_id}")
        self._log_pull("performers.show", 200, 1, meta={"id": performer_id})
        return body or {}

    # -------- Venues --------

    def list_venues(self, **params) -> dict:
        body = self._get("/venues", params)
        rows = (body or {}).get("venues") if isinstance(body, dict) else []
        self._log_pull("venues.list", 200, len(rows or []), meta={"params": params})
        return body if isinstance(body, dict) else {"venues": body or []}

    def get_venue(self, venue_id: int | str) -> dict:
        body = self._get(f"/venues/{venue_id}")
        self._log_pull("venues.show", 200, 1, meta={"id": venue_id})
        return body or {}

    # -------- Taxonomies --------

    def list_taxonomies(self) -> list:
        body = self._get("/taxonomies")
        if isinstance(body, dict) and "taxonomies" in body:
            tax = body["taxonomies"]
        elif isinstance(body, list):
            tax = body
        else:
            tax = []
        self._log_pull("taxonomies.list", 200, len(tax))
        return tax

    # -------- Recommendations --------

    def recommend_events(self, *, seed_event_ids: list | None = None,
                         seed_performer_ids: list | None = None,
                         geoip: str | None = None, lat: float | None = None,
                         lon: float | None = None, postal_code: str | None = None,
                         range_: str | None = None, **extra) -> dict:
        params = {**extra}
        if seed_event_ids: params["events.id"] = ",".join(str(x) for x in seed_event_ids)
        if seed_performer_ids: params["performers.id"] = ",".join(str(x) for x in seed_performer_ids)
        if geoip: params["geoip"] = geoip
        if lat is not None: params["lat"] = lat
        if lon is not None: params["lon"] = lon
        if postal_code: params["postal_code"] = postal_code
        if range_: params["range"] = range_
        body = self._get("/recommendations", params)
        rows = (body or {}).get("recommendations") if isinstance(body, dict) else (body or [])
        self._log_pull("recommendations.events", 200, len(rows or []), meta={"params": params})
        return body if isinstance(body, dict) else {"recommendations": body or []}

    def recommend_performers(self, *, seed_event_ids: list | None = None,
                             seed_performer_ids: list | None = None, **extra) -> dict:
        params = {**extra}
        if seed_event_ids: params["events.id"] = ",".join(str(x) for x in seed_event_ids)
        if seed_performer_ids: params["performers.id"] = ",".join(str(x) for x in seed_performer_ids)
        body = self._get("/recommendations/performers", params)
        rows = (body or {}).get("recommendations") if isinstance(body, dict) else (body or [])
        self._log_pull("recommendations.performers", 200, len(rows or []), meta={"params": params})
        return body if isinstance(body, dict) else {"recommendations": body or []}

    # -------- DB persistence helpers --------

    def link_event(self, tevo_event_id: int, sg_event: dict, *,
                   match_method: str = "manual", confidence: float | None = None) -> None:
        if not self.db:
            return
        self.db.table("seatgeek_event_xref").upsert({
            "tevo_event_id": tevo_event_id,
            "sg_event_id": int(sg_event["id"]),
            "sg_url": sg_event.get("url"),
            "sg_short_title": sg_event.get("short_title"),
            "sg_type": sg_event.get("type"),
            "sg_taxonomies": sg_event.get("taxonomies") or [],
            "sg_score": sg_event.get("score"),
            "sg_announce_date": sg_event.get("announce_date"),
            "match_method": match_method,
            "match_confidence": confidence,
            "meta": {},
        }, on_conflict="tevo_event_id").execute()

    def link_venue(self, tevo_venue_id: int, sg_venue: dict, *,
                   match_method: str = "manual", confidence: float | None = None) -> None:
        if not self.db:
            return
        loc = sg_venue.get("location") or {}
        self.db.table("seatgeek_venue_xref").upsert({
            "tevo_venue_id": tevo_venue_id,
            "sg_venue_id": int(sg_venue["id"]),
            "sg_name": sg_venue.get("name"),
            "sg_url": sg_venue.get("url"),
            "sg_address": sg_venue.get("address"),
            "sg_city": sg_venue.get("city"),
            "sg_state": sg_venue.get("state"),
            "sg_country": sg_venue.get("country"),
            "sg_postal_code": sg_venue.get("postal_code"),
            "sg_lat": loc.get("lat"),
            "sg_lng": loc.get("lon"),
            "match_method": match_method,
            "match_confidence": confidence,
        }, on_conflict="tevo_venue_id").execute()

    def link_performer(self, tevo_performer_id: int, sg_performer: dict, *,
                       match_method: str = "manual", confidence: float | None = None) -> None:
        if not self.db:
            return
        imgs = sg_performer.get("images") or {}
        self.db.table("seatgeek_performer_xref").upsert({
            "tevo_performer_id": tevo_performer_id,
            "sg_performer_id": int(sg_performer["id"]),
            "sg_slug": sg_performer.get("slug"),
            "sg_name": sg_performer.get("name"),
            "sg_short_name": sg_performer.get("short_name"),
            "sg_type": sg_performer.get("type"),
            "sg_url": sg_performer.get("url"),
            "sg_image_url": imgs.get("huge") or imgs.get("large") or sg_performer.get("image"),
            "sg_images": imgs,
            "sg_taxonomies": sg_performer.get("taxonomies") or [],
            "match_method": match_method,
            "match_confidence": confidence,
        }, on_conflict="tevo_performer_id").execute()

    def cache_taxonomies(self, taxonomies: list) -> int:
        if not self.db or not taxonomies:
            return 0
        rows = [{
            "sg_id": int(t["id"]), "name": t.get("name"),
            "parent_id": int(t["parent_id"]) if t.get("parent_id") else None,
            "raw": t,
        } for t in taxonomies if t.get("id") is not None]
        if not rows:
            return 0
        self.db.table("seatgeek_taxonomies").upsert(rows, on_conflict="sg_id").execute()
        return len(rows)

    def cache_event_sections(self, sg_event_id: int, sections: dict,
                             tevo_event_id: int | None = None) -> None:
        if not self.db or not sections:
            return
        sec_count = len(sections)
        total_rows = sum(len(rows or []) for rows in sections.values())
        self.db.table("seatgeek_event_sections").upsert({
            "sg_event_id": int(sg_event_id),
            "tevo_event_id": tevo_event_id,
            "sections": sections,
            "section_count": sec_count,
            "total_rows": total_rows,
            "refreshed_at": "now()",
        }, on_conflict="sg_event_id").execute()

    def cache_recommendations(self, *, seed_type: str, seed_sg_id: int,
                              rec_type: str, recs: list) -> int:
        if not self.db or not recs:
            return 0
        rows = []
        for r in recs:
            entity = r.get("event") or r.get("performer") or {}
            rec_id = entity.get("id")
            if rec_id is None:
                continue
            rows.append({
                "seed_type": seed_type, "seed_sg_id": int(seed_sg_id),
                "rec_type": rec_type, "rec_sg_id": int(rec_id),
                "affinity_score": float(r.get("score") or 0),
                "rec_payload": r,
            })
        if not rows:
            return 0
        self.db.table("seatgeek_recommendations").upsert(
            rows, on_conflict="seed_type,seed_sg_id,rec_type,rec_sg_id"
        ).execute()
        return len(rows)
