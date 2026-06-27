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

import time
from typing import Any

import requests


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
        # Network failures (ConnectionError / Timeout) re-raised as GoTicketsError
        # so callers see one consistent exception class at the module boundary.
        r = None
        for attempt in range(5):  # pragma: no branch  (loop never exhausts: the final attempt always breaks, since attempt < 4 is False there)
            try:
                r = requests.get(url, headers=headers, params=clean, timeout=self.timeout)
            except (requests.ConnectionError, requests.Timeout) as e:
                raise GoTicketsError(f"network error: {type(e).__name__}") from e
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
