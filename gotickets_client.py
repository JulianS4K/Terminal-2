"""GoTickets Broker Sales API client (read-only).

Host: https://sc.gotickets.com
Auth: dual API key headers — `X-Api-Access-Id` + `X-Api-Access-Secret`.
Credentials in Supabase Vault as `GOTICKETS_ACCESS_ID` and
`GOTICKETS_API_SECRET`. Same naming the operator-side Apps Script uses
for `PropertiesService.getScriptProperties()`.

Endpoints used:
  GET /rest/sales/:order_id        full per-sale detail

There is no list endpoint in the surfaced API; callers obtain order IDs
out-of-band (Gmail-surfaced "PEDDLING SALE RECEIVED" notifications on
the operator side) and look up each by ID.

Imported from the operator's Apps Script `checkGoTicketsOrderStatus`
(2026-05-13). The original Apps Script also mutated Gmail thread labels
(`gtApplyLabel` / `gtRemoveLabel`) — that's business logic on the
operator side and is NOT part of D2's data-collection lane. This module
is the API-surface side only. `sc.gotickets.com` is on the
FORBIDDEN_HOSTS allowlist in scripts/check_readonly.py and this module
appears in CLIENT_FILES.
"""
from __future__ import annotations

import base64
import time
from typing import Any

import requests

from core.http_retry import fetch_with_retry


# RULE 2 — READ-ONLY against sc.gotickets.com.
# GoTickets sales sit in the same orders/sales bucket as Evo, SG,
# TickPick, Vivid. Any non-GET attempt raises before a network call is
# made. The runtime guard pairs with the static check in
# scripts/check_readonly.py and the unit tests in
# tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class GoTicketsError(RuntimeError):
    pass


class GoTicketsReadOnlyError(GoTicketsError):
    """Raised when a non-GET method is attempted against GoTickets."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    GoTicketsReadOnlyError, ALLOWED_HTTP_METHODS,
    "Pulling data only — never write back to sc.gotickets.com.",
)


class GoTicketsClient:
    BASE_URL = "https://sc.gotickets.com"

    def __init__(self, access_id: str, api_secret: str, *, timeout: int = 30):
        if not access_id or not api_secret:
            raise GoTicketsError(
                "GoTickets access_id and api_secret are required"
            )
        self.access_id = (access_id or "").strip()
        self.api_secret = (api_secret or "").strip()
        self.timeout = timeout

    # ---------- transport ----------

    def _get(self, path: str, params: dict | None = None) -> Any:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{self.BASE_URL}{path}"
        headers = {
            "X-Api-Access-Id": self.access_id,
            "X-Api-Access-Secret": self.api_secret,
            "Accept": "application/json",
        }
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        # Retry-After honoring backoff for 429/503; mirrors tickpick_client._get.
        # Shared 429/503 retry loop (core/http_retry.py, BR-CODE-2). Network
        # failures (ConnectionError / Timeout) raised inside the thunk propagate
        # out of fetch_with_retry and are re-raised as GoTicketsError here so
        # callers see one consistent exception class at the module boundary.
        try:
            r = fetch_with_retry(
                lambda: requests.get(url, headers=headers, params=clean, timeout=self.timeout),
                max_retries=4, retry_statuses=frozenset({429, 503}),
                base_backoff=0.5, max_backoff=30.0, sleep=time.sleep,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            raise GoTicketsError(f"network error: {type(e).__name__}") from e
        if not r.ok:
            raise GoTicketsError(f"HTTP {r.status_code}")
        try:
            return r.json()
        except ValueError:
            return {"raw_text": r.text}

    # ---------- Sales ----------

    def get_sale(self, order_id: str | int) -> dict[str, Any]:
        """GET /rest/sales/:order_id — full per-sale detail.

        Canonical fields the operator-side automation reads from the
        response (verify on first live pull, may vary):
          - fulfilled        (bool — definitive transfer signal)
          - fulfillmentTime  (str | null)
          - sellerStatus     (str — e.g. 'NONE', and other enum values TBD)
          - cancelReason     (str | null — e.g. 'REJECTED')
          - event.status     (str)
        """
        body = self._get(f"/rest/sales/{order_id}")
        return body if isinstance(body, dict) else {}


class GoTicketsProClient:
    """GoTickets **Pro API** — read-only slice (live event listings).

    Host: ``https://gotickets.com/rest/pro/api`` — a DIFFERENT API from
    ``GoTicketsClient`` (which reads sales off ``sc.gotickets.com`` with dual
    ``X-Api-Access-*`` headers). The Pro API authenticates with a single
    ``X-Broker-Api-Token`` header whose value is the Base64 of
    ``accessId:accessSecret`` — the SAME credentials, just joined + encoded.
    The API key must have "Pro Access" enabled.

    Only the READ slice is surfaced:
      GET /events/{eventId}/listings    live listings for one event

    Deliberately NOT implemented — CLAUDE.md §2 (upstream APIs are read-only):
      - POST /orders           order creation / purchase — FORBIDDEN, never add
      - GET /payment-methods   wallet endpoints that exist only to feed the
      - GET /gift-cards        forbidden checkout flow; no read-only use for us

    The purchase half is locked out MECHANICALLY, not just by omission: the
    module-level RULE-2 guard (``_assert_readonly_method``) raises on any
    non-GET before a network call, and ``gotickets.com`` is on the
    ``scripts/check_readonly.py`` FORBIDDEN_HOSTS allowlist (CI static audit).

    ``eventId`` is GoTickets-internal and does NOT resolve through our AQ hub
    (PROJECT_BIBLE §0 — source event ids never line up). The Pro API has no
    event-discovery endpoint, so this is a by-id spot-pull: the caller supplies
    a known GoTickets ``eventId`` out-of-band, mirroring
    ``GoTicketsClient.get_sale``. A systematic, catalog-wide ingest would need
    an ``eventId`` → hub mapping that does not exist yet (deferred — see KANBAN).
    """

    BASE_URL = "https://gotickets.com/rest/pro/api"

    def __init__(self, access_id: str, api_secret: str, *, timeout: int = 30):
        if not access_id or not api_secret:
            raise GoTicketsError(
                "GoTickets access_id and api_secret are required"
            )
        self.access_id = (access_id or "").strip()
        self.api_secret = (api_secret or "").strip()
        self.timeout = timeout
        # X-Broker-Api-Token = base64(accessId:accessSecret), no trailing
        # newline (the vendor's `base64 -w 0`). Built once at construction.
        raw = f"{self.access_id}:{self.api_secret}".encode()
        self.api_token = base64.b64encode(raw).decode("ascii")

    # ---------- transport ----------

    def _get(self, path: str, params: dict | None = None) -> Any:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{self.BASE_URL}{path}"
        headers = {
            "X-Broker-Api-Token": self.api_token,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        # Shared 429/503 Retry-After backoff (core/http_retry.py, BR-CODE-2);
        # same loop GoTicketsClient._get uses. Network failures raised inside
        # the thunk propagate out and are re-raised as GoTicketsError so callers
        # see one exception class at the module boundary.
        try:
            r = fetch_with_retry(
                lambda: requests.get(url, headers=headers, params=clean, timeout=self.timeout),
                max_retries=4, retry_statuses=frozenset({429, 503}),
                base_backoff=0.5, max_backoff=30.0, sleep=time.sleep,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            raise GoTicketsError(f"network error: {type(e).__name__}") from e
        if not r.ok:
            raise GoTicketsError(f"HTTP {r.status_code}")
        try:
            return r.json()
        except ValueError:
            return {"raw_text": r.text}

    # ---------- Listings ----------

    def get_event_listings(
        self, event_id: str | int, *, payment_method_token: str | None = None
    ) -> list[dict[str, Any]]:
        """GET /events/{eventId}/listings — live listings for one event.

        ``event_id`` is the GoTickets-internal event id (supplied out-of-band;
        it does NOT map to our ``tevo_event_id`` / AQ hub).

        ``payment_method_token`` is optional and defaults to omitted. When
        provided, the API returns a ``transactionRatePercentage`` per listing
        (a credit-card processing-fee estimate). We leave it off for read-only
        market observation — we want raw ``displayPrice`` / ``tax``, not
        buyer-side fee math (which only matters for the forbidden checkout).

        Per-listing fields to expect (verify on first live pull, may vary):
          ``displayPrice``, ``tax``, quantity / section / row, and
          ``transactionRatePercentage`` only when ``payment_method_token`` is
          passed.

        Returns the listings array, or ``[]`` if the response is not a JSON list.
        """
        body = self._get(
            f"/events/{event_id}/listings",
            {"paymentMethodToken": payment_method_token},
        )
        return body if isinstance(body, list) else []
