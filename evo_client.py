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
import time
from typing import Any, Iterator
from urllib.parse import urlencode

import requests


# RULE 2 — READ-ONLY across api.ticketevolution.com.
# We pull listings, events, performers, venues, configurations, orders.
# We never POST/PUT/PATCH/DELETE — no creating orders, no editing inventory.
# Any non-GET method here is a bug; the guard below catches it at runtime
# before a request can even fly. Do not add a method to this allowlist
# without explicit human approval (see SCHEMA.md RULE 2).
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class EvoReadOnlyError(RuntimeError):
    """Raised when a non-GET method is attempted against TEvo."""


def _assert_readonly_method(method: str) -> None:
    """Hard guard: this client must never write back to TEvo."""
    if method.upper() not in ALLOWED_HTTP_METHODS:
        raise EvoReadOnlyError(
            f"READ-ONLY violation: method {method} is not allowed. "
            "TEvo integration is strictly read-only (RULE 2 in SCHEMA.md). "
            "Pulling data only — never write back to api.ticketevolution.com."
        )


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

    # RULE 2 — READ-ONLY against api.ticketevolution.com.
    # See module-level _assert_readonly_method + ALLOWED_HTTP_METHODS for
    # the runtime enforcement. Any non-GET attempt raises EvoReadOnlyError
    # before a network call is made.

    # 429 backoff config — TEvo doesn't publish hard rate limits but
    # empirical testing shows ~5 req/sec sustained is the safe band, with
    # bursts of ~30 sequential requests triggering 429s. Other clients in
    # the repo (chat fn, espn-collect, seatgeek, seatdata) implement their
    # own backoff because this client previously did not. Closes that gap.
    _MAX_RETRIES = 4
    _BACKOFF_BASE_SEC = 0.5     # 0.5, 1, 2, 4 — caps below the 5s order-of-magnitude
    _BACKOFF_CAP_SEC = 30.0
    _RETRY_STATUSES = frozenset({429, 502, 503, 504})

    def _get(self, path: str, params: dict | None = None) -> dict[str, Any]:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        clean = self._normalize(params)
        query = urlencode(sorted(clean.items()))
        signature = self._sign("GET", path, query)
        url = f"{self.base_url}{path}?{query}"
        headers = {
            "X-Token": self.token,
            "X-Signature": signature,
            "Accept": "application/vnd.ticketevolution.api+json; version=9",
        }

        last_resp = None
        for attempt in range(self._MAX_RETRIES + 1):
            r = requests.get(url, headers=headers, timeout=self.timeout)
            last_resp = r
            if r.ok:
                return r.json()
            if r.status_code not in self._RETRY_STATUSES or attempt == self._MAX_RETRIES:
                break
            # Honor Retry-After when TEvo provides it; else exponential.
            wait: float
            ra = r.headers.get("Retry-After")
            if ra:
                try:
                    wait = float(ra)
                except (TypeError, ValueError):
                    wait = self._BACKOFF_BASE_SEC * (2 ** attempt)
            else:
                wait = self._BACKOFF_BASE_SEC * (2 ** attempt)
            wait = min(wait, self._BACKOFF_CAP_SEC)
            time.sleep(wait)

        # Out of retries, or non-retryable status.
        # Security: do NOT include URL or response body in the exception
        # message — both bubble through `f"...: {e}"` patterns to HTTP
        # responses (e.g., app.py:5218). URL contains user-supplied query
        # params (recon vector); body can leak TEvo internal data or
        # intermediate-proxy info. Pattern matches seatgeek_client.py:495
        # (B1 SEC-MED SW-1, security chat 2026-05-10).
        # Log full detail server-side; only generic status reaches caller.
        #
        # Truthiness note: `requests.Response.__bool__` returns `self.ok`
        # (`status_code < 400`), so `if last_resp` is FALSE for the exact
        # case we want to log — a non-2xx response. Use `is not None` to
        # distinguish "no response object at all" (connection failure) from
        # "response object that happens to be non-2xx". Flagged by D1 in
        # the 2026-05-13 MVP-deploy debugging session.
        import logging
        if last_resp is not None:
            logging.getLogger(__name__).warning(
                "TEvo API non-2xx response: %s %s on %s %s — body: %s",
                last_resp.status_code,
                last_resp.reason,
                last_resp.request.method,
                last_resp.url,
                last_resp.text[:500],
            )
            raise RuntimeError(f"TEvo API returned {last_resp.status_code}")
        else:
            logging.getLogger(__name__).warning(
                "TEvo API call failed with no response (connection/timeout/DNS)"
            )
            raise RuntimeError("TEvo API returned no response")

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

    def search_suggestions(
        self,
        q: str,
        *,
        entities: str = "events,performers,venues",
        fuzzy: bool = True,
        limit: int = 8,
        occurs_at_gte: str | None = None,
    ) -> dict[str, Any]:
        """GET /v9/searches/suggestions — multi-entity autocomplete.

        Returns shape:
          { "total_entries": N,   (count of entity types, not hits)
            "suggestions": {
              "events":     [ { id, name, slug, location, venue_name,
                                occurs_at, ... }, ... ],
              "performers": [ { id, name, slug, location, venue_name, ... }, ... ],
              "venues":     [ { id, name, slug, location, ... }, ... ],
            }
          }

        Empirical limits (verified 2026-05-12 against api.ticketevolution.com):
        - `limit` is hard-capped at 20 per entity by the API regardless of
          what we send. Pass 20 if you want the max; smaller values trim.
        - Each entity bucket caps independently — 20 events AND 20 performers
          AND 20 venues can all return on a single call.
        - Multi-word matchup queries ("yankees vs red sox") return zero
          events. Use single-team queries + intersect client-side if you
          need matchup search.
        - Latency varies 380-2800ms with no upstream caching. Cache caller-
          side if you're hitting the same q repeatedly.
        """
        params = {
            "q": q,
            "entities": entities,
            "fuzzy": fuzzy,
            "limit": min(int(limit), 20),
        }
        if occurs_at_gte:
            # TEvo accepts both occurs_at.gte and occurs_at_gte; the dotted
            # form is canonical. _normalize() preserves the key as-is.
            params["occurs_at.gte"] = occurs_at_gte
        return self._get("/v9/searches/suggestions", params)

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

    # ========== Orders ==========
    # /v9/orders gives us the brokerage's own pending/accepted/rejected/
    # completed orders. Different from /listings — orders are post-buy
    # state for our own account, not market inventory.
    #
    # Per docs: pagination max is 10 per_page (NOT 100). States are:
    #   pending | accepted | rejected | completed | pending_substitution
    # Types are: Order (sale) | PurchaseOrder (purchase). type filter is
    # case-sensitive — passing 'order' returns ALL orders.

    def list_orders(
        self,
        *,
        q: str | None = None,
        seller_id: int | None = None,
        buyer_id: int | None = None,
        order_id: int | None = None,
        order_group_id: int | None = None,
        state: str | None = None,
        type: str | None = None,                # Order | PurchaseOrder
        needs_eticket: bool | None = None,
        direct_buyer_type: str | None = None,
        reference: str | None = None,
        performer_id: int | None = None,
        venue_id: int | None = None,
        event_date: str | None = None,          # ISO_8601
        page: int = 1,
        per_page: int = 10,                     # MAX is 10 per docs
        **extra: Any,
    ) -> dict[str, Any]:
        """GET /v9/orders — Index. Per-page MAX is 10 (server-enforced)."""
        params = {
            "q": q, "seller_id": seller_id, "buyer_id": buyer_id,
            "order_id": order_id, "order_group_id": order_group_id,
            "state": state, "type": type,
            "needs_eticket": needs_eticket, "direct_buyer_type": direct_buyer_type,
            "reference": reference, "performer_id": performer_id,
            "venue_id": venue_id, "event_date": event_date,
            "page": page, "per_page": min(per_page, 10),
            **extra,
        }
        return self._get("/v9/orders", params)

    def iter_orders(
        self,
        *,
        max_pages: int = 200,                   # 200 * 10 = 2000 orders per scan
        per_page: int = 10,
        **kwargs: Any,
    ) -> Iterator[dict]:
        """Yield orders across pages. Stops when total_entries reached or empty page."""
        kwargs.pop("page", None)
        per_page = min(per_page, 10)
        seen = 0
        for page in range(1, max_pages + 1):
            resp = self.list_orders(page=page, per_page=per_page, **kwargs)
            batch = resp.get("orders") or []
            total = resp.get("total_entries", 0)
            if not batch:
                break
            for o in batch:
                yield o
            seen += len(batch)
            if seen >= total:
                break

    def get_order(self, order_id: int) -> dict[str, Any]:
        """GET /v9/orders/:id — Show single order."""
        return self._get(f"/v9/orders/{order_id}")
