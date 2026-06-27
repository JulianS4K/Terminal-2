"""TickPick Broker Orders API client (read-only).

Host: https://api.tickpick.com
Auth: Bearer <token> in Authorization header. Token in vault as
TICKPICK_API_TOKEN.

Endpoints used:
  GET /1.0/orders                        list broker orders (filterable
                                         via ?status=, e.g. 'unfulfilled')
  GET /1.0/orders/:order_id/details      full per-order detail

Imported from JulianS4K/Unified-Order-Suite. The original suite included
a fulfillment write (POST /1.0/orders/:id/fulfillment); that endpoint is
NOT imported here. TickPick orders are in the same RULE 2 read-only
bucket as the Evo /v9/orders and SG /sales feeds — `api.tickpick.com`
is on the FORBIDDEN_HOSTS allowlist in scripts/check_readonly.py and
this module appears in CLIENT_FILES.
"""
from __future__ import annotations

import time
from typing import Any

import requests


# RULE 2 — READ-ONLY against api.tickpick.com.
# TickPick orders are part of the orders/sales bucket alongside Evo and
# SG. Any non-GET attempt raises EvoReadOnlyError-style before a network
# call is made. The runtime guard pairs with the static check in
# scripts/check_readonly.py and the unit tests in
# tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class TickPickError(RuntimeError):
    pass


class TickPickReadOnlyError(TickPickError):
    """Raised when a non-GET method is attempted against TickPick."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    TickPickReadOnlyError, ALLOWED_HTTP_METHODS,
    "Pulling data only — never write back to api.tickpick.com.",
)


class TickPickClient:
    BASE_URL = "https://api.tickpick.com/1.0"

    def __init__(self, token: str, *, timeout: int = 30):
        if not token:
            raise TickPickError("TickPick token is required")
        self.token = (token or "").strip()
        self.timeout = timeout

    # ---------- transport ----------

    def _get(self, path: str, params: dict | None = None) -> Any:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{self.BASE_URL}{path}"
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
        }
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        # Retry-After honoring backoff for 429/503; mirrors seatgeek_client._get
        for attempt in range(5):  # pragma: no branch  (loop never exhausts: the final attempt always breaks, since attempt < 4 is False there)
            r = requests.get(url, headers=headers, params=clean, timeout=self.timeout)
            if r.status_code in (429, 503) and attempt < 4:
                retry_after = r.headers.get("Retry-After")
                try:
                    delay = float(retry_after) if retry_after else (0.5 * (2 ** attempt))
                except (TypeError, ValueError):
                    delay = 0.5 * (2 ** attempt)
                time.sleep(min(delay, 30.0))
                continue
            break
        if not r.ok:
            raise TickPickError(f"HTTP {r.status_code}")
        try:
            return r.json()
        except ValueError:
            return {"raw_text": r.text}

    # ---------- Orders ----------

    def list_orders(
        self,
        *,
        status: str | None = "unfulfilled",
        **extra: Any,
    ) -> list[dict[str, Any]]:
        """GET /1.0/orders — broker orders. Defaults to status=unfulfilled
        (the filter the Unified-Order-Suite uses). Pass status=None to
        omit the filter entirely."""
        body = self._get("/orders", {"status": status, **extra})
        # TickPick returns a JSON array at the top level for /orders.
        if isinstance(body, list):
            return body
        if isinstance(body, dict) and isinstance(body.get("orders"), list):
            return body["orders"]
        return []

    def get_order_details(self, order_id: str | int) -> dict[str, Any]:
        """GET /1.0/orders/:id/details — full detail for one order."""
        body = self._get(f"/orders/{int(order_id)}/details")
        return body if isinstance(body, dict) else {}
