"""Ticket Evolution API client.

Covers:
  Events         /v9/events, /v9/events/search, /v9/events/:id,
                 /v9/events/:id/stats
  Listings       /v9/listings
  Performers     /v9/performers, /v9/performers/search, /v9/performers/:id
  Venues         /v9/venues, /v9/venues/search, /v9/venues/:id
  Configurations /v9/configurations, /v9/configurations/:id

Auth: X-Token + X-Signature (HMAC-SHA256 of canonical
"METHOD host path?query" string, base64 encoded).

CRITICAL: '?' is ALWAYS present in the canonical signed string, even when
the query is empty. TEvo's server canonicalizes that way — forgetting it
yields 401 "Signature is not valid" on endpoints with no query params
(most commonly /v9/events/:id/stats).

Conditionals:
  Date/numeric params support .eq / .not_eq / .gt / .gte / .lt / .lte.
  Pass dotted keys via **extra (Python kwargs can't contain dots):

      client.list_events(**{
          "occurs_at.gte":  "2026-05-01",
          "occurs_at.lt":   "2026-06-01",
      })

Gotchas:
  * event.available_count / products_count / products_eticket_count are
    DEPRECATED — use get_event_stats() for authoritative numbers.
  * event.occurs_at has a misleading "Z" suffix but is NOT UTC; the time
    is local. Use event.occurs_at_local (has the real offset) instead.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
from typing import Any, Iterator
from urllib.parse import urlencode

import requests


class EvoClient:
    def __init__(self, token: str, secret: str, sandbox: bool = False, timeout: int = 30):
        self.token = token
        self._secret = secret.encode("utf-8")
        self.host = (
            "api.sandbox.ticketevolution.com" if sandbox else "api.ticketevolution.com"
        )
        self.base_url = f"https://{self.host}"
        self.timeout = timeout

    # ---------- auth / transport ----------

    def _sign(self, method: str, path: str, query: str) -> str:
        """Sign 'METHOD host path?query' — '?' always present, even if query empty."""
        string_to_sign = f"{method} {self.host}{path}?{query}"
        digest = hmac.new(
            self._secret, string_to_sign.encode("utf-8"), hashlib.sha256
        ).digest()
        return base64.b64encode(digest).decode("utf-8")

    @staticmethod
    def _normalize(params: dict | None) -> dict:
        """Drop None values, stringify bools to TEvo's 'true'/'false'."""
        out = {}
        for k, v in (params or {}).items():
            if v is None:
                continue
            if isinstance(v, bool):
                out[k] = "true" if v else "false"
            else:
                out[k] = v
        return out

    def _get(self, path: str, params: dict | None = None) -> dict[str, Any]:
        clean = self._normalize(params)
        query = urlencode(sorted(clean.items()))
        signature = self._sign("GET", path, query)
        url = f"{self.base_url}{path}?{query}"
        headers = {
            "X-Token": self.token,
            "X-Signature": signature,
            "Accept": "application/vnd.ticketevolution.api+json; version=9",
        }
        r = requests.get(url, headers=headers, timeout=self.timeout)
        if not r.ok:
            raise RuntimeError(
                f"{r.status_code} {r.reason} on {r.request.method} {r.url}\n"
                f"Response body: {r.text}"
            )
        return r.json()

    def _iter_paginated(
        self,
        path: str,
        result_key: str,
        *,
        max_pages: int = 50,
        per_page: int = 100,
        **kwargs,
    ) -> Iterator[dict]:
        """Yield items across pages for any paginated list endpoint."""
        seen = 0
        for page in range(1, max_pages + 1):
            resp = self._get(path, {**kwargs, "per_page": min(per_page, 100), "page": page})
            batch = resp.get(result_key, [])
            total = resp.get("total_entries", 0)
            if not batch:
                break
            for item in batch:
                yield item
            seen += len(batch)
            if seen >= total:
                break

    # ========== Events ==========

    def list_events(
        self,
        q: str | None = None,
        *,
        performer_id: int | None = None,
        venue_id: int | None = None,
        occurs_at_gte: str | None = None,   # shortcut for occurs_at.gte
        occurs_at_lte: str | None = None,   # shortcut for occurs_at.lte
        only_with_available_tickets: bool | None = None,
        order_by: str | None = None,
        per_page: int = 100,
        page: int = 1,
        **extra,
    ) -> dict[str, Any]:
        """GET /v9/events — list events with filters (Index)."""
        params = {
            "q": q,
            "performer_id": performer_id,
            "venue_id": venue_id,
            "occurs_at.gte": occurs_at_gte,
            "occurs_at.lte": occurs_at_lte,
            "only_with_available_tickets": only_with_available_tickets,
            "order_by": order_by,
            "per_page": min(per_page, 100),
            "page": page,
            **extra,
        }
        return self._get("/v9/events", params)

    # Backward-compat alias
    search_events = list_events

    def search_events_fulltext(self, q: str, **kwargs) -> dict[str, Any]:
        """GET /v9/events/search — full-text search endpoint.
        Accepts identical params to list_events per the docs."""
        return self._get("/v9/events/search", {**kwargs, "q": q})

    def iter_events(self, max_pages: int = 50, **kwargs) -> Iterator[dict]:
        """Yield events across all pages (uses /v9/events)."""
        kwargs.pop("page", None)
        yield from self._iter_paginated("/v9/events", "events", max_pages=max_pages, **kwargs)

    def search_events_all(self, max_pages: int = 50, **kwargs) -> list[dict]:
        """Collect every event matching the query into a list."""
        return list(self.iter_events(max_pages=max_pages, **kwargs))

    def get_event(self, event_id: int) -> dict[str, Any]:
        """GET /v9/events/:id — single event detail (Show)."""
        return self._get(f"/v9/events/{event_id}")

    def get_event_stats(
        self,
        event_id: int,
        *,
        inventory_type: str | None = None,   # "event" | "parking" | None (all)
    ) -> dict[str, Any]:
        """GET /v9/events/:id/stats — authoritative ticket/price stats.

        Use this instead of event.available_count (deprecated).
        Returns ticket_groups_count, tickets_count, retail/wholesale
        min/max/avg/sum.
        """
        params = {"inventory_type": inventory_type} if inventory_type else None
        return self._get(f"/v9/events/{event_id}/stats", params)

    # ========== Listings ==========

    def get_listings(
        self,
        event_id: int,
        *,
        type: str | None = None,             # "event" | "parking"
        quantity: int | None = None,
        section: str | None = None,
        row: str | None = None,
        owned: bool | None = None,
        order_by: str | None = None,
        **extra,
    ) -> dict[str, Any]:
        """GET /v9/listings — marketplace view of ticket groups for an event.

        DEPRECATED for our metric pipeline as of 2026-04-25. /v9/listings
        does not expose office/brokerage attribution, so the collector now
        uses get_ticket_groups() instead. Still useful for ad-hoc reads
        where the broker view is not needed.

        This endpoint does NOT paginate; every match is returned at once.
        """
        params = {
            "event_id": event_id,
            "type": type,
            "quantity": quantity,
            "section": section,
            "row": row,
            "owned": owned,
            "order_by": order_by,
            **extra,
        }
        return self._get("/v9/listings", params)

    def get_ticket_groups(
        self,
        event_id: int,
        *,
        owned: bool | None = None,
        state: str | None = None,           # "available" | "sold" | ...
        order_by: str | None = None,
        **extra,
    ) -> dict[str, Any]:
        """GET /v9/ticket_groups — broker-portal view of ticket groups for an event.

        Same inventory as /v9/listings but exposes office.brokerage attribution
        on every row (used by the edge collector to flag is_owned).

        Per TEvo: requires event_id; per_page is NOT allowed; pass owned=true
        to limit to inventory belonging to your token's brokerage.

        Mirrors the collect-listings edge function's getTicketGroups() so the
        Python client and TS edge function agree on the source of truth.
        """
        params = {
            "event_id": event_id,
            "owned": owned,
            "state": state,
            "order_by": order_by,
            **extra,
        }
        return self._get("/v9/ticket_groups", params)

    # ========== Performers ==========

    def list_performers(self, **kwargs) -> dict[str, Any]:
        """GET /v9/performers — Index. `name` is exact match;
        use search_performers for full-text."""
        kwargs.setdefault("per_page", 100)
        return self._get("/v9/performers", kwargs)

    def search_performers(
        self,
        q: str,
        *,
        fuzzy: bool | None = None,
        per_page: int = 100,
        page: int = 1,
        **extra,
    ) -> dict[str, Any]:
        """GET /v9/performers/search — full-text search."""
        params = {
            "q": q,
            "fuzzy": fuzzy,
            "per_page": min(per_page, 100),
            "page": page,
            **extra,
        }
        return self._get("/v9/performers/search", params)

    def iter_performers(self, max_pages: int = 50, **kwargs) -> Iterator[dict]:
        kwargs.pop("page", None)
        yield from self._iter_paginated(
            "/v9/performers", "performers", max_pages=max_pages, **kwargs
        )

    def get_performer(
        self, performer_id: int, *, include_opponents: bool = False
    ) -> dict[str, Any]:
        """GET /v9/performers/:id — Show. include_opponents=True adds
        a list of opponent teams (sports only)."""
        params = {"include": True} if include_opponents else None
        return self._get(f"/v9/performers/{performer_id}", params)

    # ========== Venues ==========

    def list_venues(self, **kwargs) -> dict[str, Any]:
        """GET /v9/venues — Index. Supports geolocation via lat/lon/within,
        postal_code, city_state, or ip."""
        kwargs.setdefault("per_page", 100)
        return self._get("/v9/venues", kwargs)

    def search_venues(
        self,
        q: str,
        *,
        fuzzy: bool | None = None,
        per_page: int = 100,
        page: int = 1,
        **extra,
    ) -> dict[str, Any]:
        """GET /v9/venues/search — full-text search."""
        params = {
            "q": q,
            "fuzzy": fuzzy,
            "per_page": min(per_page, 100),
            "page": page,
            **extra,
        }
        return self._get("/v9/venues/search", params)

    def iter_venues(self, max_pages: int = 50, **kwargs) -> Iterator[dict]:
        kwargs.pop("page", None)
        yield from self._iter_paginated(
            "/v9/venues", "venues", max_pages=max_pages, **kwargs
        )

    def get_venue(self, venue_id: int) -> dict[str, Any]:
        """GET /v9/venues/:id — Show."""
        return self._get(f"/v9/venues/{venue_id}")

    # ========== Configurations ==========

    def list_configurations(
        self,
        *,
        venue_id: int | None = None,
        name: str | None = None,
        per_page: int = 100,
        page: int = 1,
        **extra,
    ) -> dict[str, Any]:
        """GET /v9/configurations — Index."""
        params = {
            "venue_id": venue_id,
            "name": name,
            "per_page": min(per_page, 100),
            "page": page,
            **extra,
        }
        return self._get("/v9/configurations", params)

    def iter_configurations(self, max_pages: int = 50, **kwargs) -> Iterator[dict]:
        kwargs.pop("page", None)
        yield from self._iter_paginated(
            "/v9/configurations", "configurations", max_pages=max_pages, **kwargs
        )

    def get_configuration(self, configuration_id: int) -> dict[str, Any]:
        """GET /v9/configurations/:id — Show."""
        return self._get(f"/v9/configurations/{configuration_id}")
