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
NOT imported here. This client mirrors the RULE 2 read-only guards used
by evo_client.py and seatgeek_client.py so the same enforcement model
applies if anyone tries to add writes later.
"""
from __future__ import annotations

from typing import Any

import requests


# Read-only by design. Mirrors the RULE 2 pattern in evo_client.py and
# seatgeek_client.py. api.tickpick.com is not in scripts/check_readonly.py's
# FORBIDDEN_HOSTS list, but the same runtime guard is wired so any future
# attempt to send a non-GET via this client raises before the network call.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class TickPickError(RuntimeError):
    pass


class TickPickReadOnlyError(TickPickError):
    """Raised when a non-GET method is attempted against TickPick."""


def _assert_readonly_method(method: str) -> None:
    if method.upper() not in ALLOWED_HTTP_METHODS:
        raise TickPickReadOnlyError(
            f"READ-ONLY violation: method {method} is not allowed. "
            "TickPick client is read-only by design (RULE 2 spirit). "
            "Pulling data only — never write back to api.tickpick.com."
        )


class TickPickClient:
    BASE_URL = "https://api.tickpick.com/1.0"

    def __init__(self, token: str, *, timeout: int = 30):
        if not token:
            raise TickPickError("TickPick token is required")
        self.token = token
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
        r = requests.get(url, headers=headers, params=clean, timeout=self.timeout)
        if not r.ok:
            raise TickPickError(
                f"{r.status_code} {r.reason} on GET {r.request.url}\n"
                f"Response body: {r.text}"
            )
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
        body = self._get(f"/orders/{order_id}/details")
        return body if isinstance(body, dict) else {}
