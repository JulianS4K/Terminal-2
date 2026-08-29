"""S4K Marketplace Orders API client (read-only).

Host: https://crm.s4kcs.com  ·  Base: `/api/v1`

Live **open / undelivered sell-side orders** from six resale marketplaces —
TickPick, GoTickets, SeatGeek, StubHub, Vivid Seats, Gametime — plus the
scheduled CSV exports the CRM's own hourly scheduler produces.

WHAT THIS IS NOT
----------------
Despite arriving in the same workstream as the eVenue Desk feed analysis
(docs/evenuedesk_feed_mapping.md), this is a **different API with a different
subject**. That work mapped primary box-office *inventory* (raw seat blocks,
Paciolan/ProVenue/TM). This serves our own *sell-side orders* off resale
marketplaces. Confirmed against the live host 2026-08-29: every `/api/v1/feed/*`
and `/api/v1/events` path from that reference returns **404** here. Do not
reuse the FEED_COLUMNS grammar or the ticket_uid/event_uid key model — none of
it applies. This is also unrelated to the Paciolan pipeline.

Auth: `X-API-Key: s4k_…`, scope `marketplace:read`. Sourced from the
`S4K_MARKETPLACE_API_KEY` env var, falling back to Supabase Vault under
`EVENUEDESK_API_KEY` (the name the key was originally seeded under) — never
hardcoded, never logged, never placed in a URL or query string. Keys can be
revoked or expire at any time; a 401 must stop the caller, not be retried.

Read-only: RULE 2 (CLAUDE.md §2). The API's own documentation states "Every
endpoint is a GET. Nothing here can change anything", and the issued key
carries only `marketplace:read`. This client enforces GET at the transport
layer regardless — `ALLOWED_HTTP_METHODS = frozenset({"GET"})` plus an
`_assert_readonly_method` tripwire that raises before any socket is opened.

Rate limits (per key, from the API docs):
  general : 120 requests / minute — everything
  fetch   :  10 requests / minute — /marketplace/orders and
             /marketplace/orders/{market}, which call the six marketplaces
             LIVE and can take up to ~60 s
Over the limit → 429 with a `Retry-After` header (seconds), which this client
honours rather than backing off blindly.

PARTIAL SUCCESS IS THE NORMAL CASE — read this before consuming `rows`.
A live fetch returns HTTP 200 with `rows` from the marketplaces that answered
and an `errors[]` listing those that did not; a failing marketplace is retried
twice server-side, then reported. So a 200 does **not** mean "these are all the
open orders". Any consumer that replaces its order set wholesale from one
response will silently delete every order belonging to a marketplace that
happened to error. Reconcile per `source`, and treat `errors[]` as authoritative
about which sources this response can speak for — see `sources_covered()`.
"""
from __future__ import annotations

import os
import time
from typing import Any

import requests

from core.vault import vault_secret


# Read-only by design (RULE 2). `scripts/check_readonly.py` requires both
# tokens verbatim in this file; `tests/test_readonly_guards.py` imports them.
ALLOWED_HTTP_METHODS = frozenset({"GET"})

# Confirmed live 2026-08-29 against https://crm.s4kcs.com/api/v1.
PATHS = {
    "ping": "/ping",
    "marketplaces": "/marketplace/marketplaces",
    "columns": "/marketplace/columns",
    "orders": "/marketplace/orders",
    "orders_one": "/marketplace/orders/{market}",
    "schedule": "/marketplace/schedule",
    "exports": "/marketplace/exports",
    "exports_latest": "/marketplace/exports/latest",
    "exports_named": "/marketplace/exports/{name}",
}

# The 19 columns every order row carries (GET /marketplace/columns).
ORDER_COLUMNS = (
    "source", "id", "order_status", "seller_status", "event_name", "event_date",
    "venue_name", "venue_city", "venue_state", "section", "row", "seats",
    "quantity", "price", "delivery", "inhand_date", "payout_date", "notes",
    "purchase_date",
)

# The six marketplaces this API fronts.
MARKETS = ("TickPick", "GoTickets", "SeatGeek", "StubHub", "Vivid Seats", "Gametime")

# Endpoints in the stricter 10/min "fetch" bucket — they hit the marketplaces
# live and can take ~60 s.
LIVE_FETCH_PATHS = frozenset({PATHS["orders"], PATHS["orders_one"]})


class S4KMarketplaceError(RuntimeError):
    pass


class S4KMarketplaceReadOnlyError(S4KMarketplaceError):
    """Raised when a non-GET method is attempted against the S4K CRM."""


class S4KMarketplaceAuthError(S4KMarketplaceError):
    """401 (missing/invalid/expired/revoked key) or 403 (missing scope).

    Per the API docs a 401 means STOP and get a new key — never retry it.
    """


class S4KMarketplaceRateLimited(S4KMarketplaceError):
    """429 — rate limited; `retry_after` carries the server's seconds hint."""

    def __init__(self, message: str, retry_after: int | None = None):
        super().__init__(message)
        self.retry_after = retry_after


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    S4KMarketplaceReadOnlyError, ALLOWED_HTTP_METHODS,
    "Pulling data only — never write back to the S4K CRM.",
)


def _vault_secret(db: Any, name: str) -> str | None:
    """Read a secret from Supabase Vault. Thin wrapper over the shared resolver
    (core/vault.py) preserving this module's log prefix + name."""
    return vault_secret(db, name,
                        on_error=lambda e: print(f"s4k_marketplace: vault lookup for {name} failed: {e}"))


def sources_covered(payload: dict[str, Any]) -> set[str]:
    """The marketplaces a given `/marketplace/orders` response can speak for.

    A live fetch returns 200 even when some marketplaces failed, so `rows`
    alone cannot tell you whether "no TickPick orders" means TickPick had none
    or TickPick errored. This returns the markets NOT listed in `errors[]` —
    the only ones whose absence from `rows` is meaningful. Reconcile per source
    against this set; never delete orders for a source outside it.
    """
    failed = {
        (e or {}).get("market", "").strip().lower()
        for e in (payload.get("errors") or [])
    }
    return {m for m in MARKETS if m.lower() not in failed}


class S4KMarketplaceClient:
    BASE_URL = "https://crm.s4kcs.com"
    API_PREFIX = "/api/v1"

    # Live fetches can take ~60 s per the API docs; allow headroom.
    DEFAULT_TIMEOUT = 30
    LIVE_FETCH_TIMEOUT = 120
    MAX_RETRIES = 3
    RETRY_STATUS = frozenset({502, 503, 504})

    def __init__(
        self,
        api_key: str | None = None,
        *,
        db: Any = None,
        base_url: str | None = None,
    ):
        # arg → env → Vault. Never hardcoded; never logged.
        self.api_key = (
            api_key
            or os.environ.get("S4K_MARKETPLACE_API_KEY")
            or _vault_secret(db, "EVENUEDESK_API_KEY")
        )
        self.base_url = (base_url or os.environ.get("S4K_MARKETPLACE_BASE_URL")
                         or self.BASE_URL).rstrip("/")
        self._session = requests.Session()

    def _request(self, path: str, params: dict[str, Any] | None = None,
                 *, raw: bool = False) -> Any:
        """Issue one GET and return the decoded JSON body (or text when `raw`).

        The key travels in a header, never the URL or query string, so it
        cannot leak into a redirect, an access log, or an exception repr.
        """
        _assert_readonly_method("GET")
        if not self.api_key:
            raise S4KMarketplaceAuthError(
                "no S4K marketplace API key: set S4K_MARKETPLACE_API_KEY or store "
                "it in Supabase Vault"
            )
        url = f"{self.base_url}{self.API_PREFIX}{path}"
        headers = {"X-API-Key": self.api_key,
                   "Accept": "text/csv" if raw else "application/json"}
        timeout = (self.LIVE_FETCH_TIMEOUT if path in LIVE_FETCH_PATHS
                   or path.startswith("/marketplace/orders")
                   else self.DEFAULT_TIMEOUT)

        for attempt in range(self.MAX_RETRIES):
            try:
                resp = self._session.get(url, headers=headers, params=params,
                                         timeout=timeout)
            except requests.RequestException as e:
                # Never interpolate the exception's request repr — it carries
                # headers, and therefore the key.
                if attempt == self.MAX_RETRIES - 1:
                    raise S4KMarketplaceError(
                        f"GET {path} failed: {type(e).__name__}") from None
                time.sleep(2 ** attempt)
                continue

            if resp.status_code in (401, 403):
                # Terminal by contract — the key is bad, expired, revoked, or
                # lacks marketplace:read. Retrying cannot help.
                raise S4KMarketplaceAuthError(
                    f"GET {path} returned {resp.status_code} — key rejected "
                    "(invalid/expired/revoked, or missing marketplace:read scope)"
                )
            if resp.status_code == 429:
                retry_after = None
                try:
                    retry_after = int(resp.headers.get("Retry-After", ""))
                except (TypeError, ValueError):
                    pass
                if attempt < self.MAX_RETRIES - 1:
                    # Honour the server's hint rather than guessing.
                    time.sleep(retry_after if retry_after is not None else 2 ** attempt)
                    continue
                raise S4KMarketplaceRateLimited(
                    f"GET {path} rate limited (429)", retry_after)
            if resp.status_code in self.RETRY_STATUS and attempt < self.MAX_RETRIES - 1:
                time.sleep(2 ** attempt)
                continue
            if resp.status_code >= 400:
                raise S4KMarketplaceError(f"GET {path} returned {resp.status_code}")

            if raw:
                return resp.text
            try:
                return resp.json()
            except ValueError as e:
                raise S4KMarketplaceError(f"GET {path} returned non-JSON body") from e

        raise S4KMarketplaceError(f"GET {path} exhausted retries")

    # ---- cheap metadata (general 120/min bucket) ---------------------------

    def ping(self) -> Any:
        """Confirm the key works. Returns ok/key/scopes/expires_at/server_time."""
        return self._request(PATHS["ping"])

    def marketplaces(self) -> Any:
        """The six marketplaces and whether credentials are configured for each.
        An unconfigured marketplace will always appear in `errors` on a fetch."""
        return self._request(PATHS["marketplaces"])

    def columns(self) -> Any:
        """The column names every order row carries (cf. ORDER_COLUMNS)."""
        return self._request(PATHS["columns"])

    def schedule(self) -> Any:
        """Status of the CRM's own server-side export scheduler."""
        return self._request(PATHS["schedule"])

    def exports(self) -> Any:
        """Scheduled CSV exports on disk, newest first (60 kept)."""
        return self._request(PATHS["exports"])

    def export_latest_csv(self) -> str:
        """Newest scheduled export as CSV text.

        Cheap alternative to a live fetch — the CRM's scheduler refreshes it —
        but only as fresh as that scheduler's interval (60 min by default), so
        it is not a substitute when sub-hour freshness is required.
        """
        return self._request(PATHS["exports_latest"], raw=True)

    # ---- live fetch (stricter 10/min bucket, ~60 s) -------------------------

    def orders(
        self,
        *,
        markets: str | None = None,
        ev_from: str | None = None,
        ev_to: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
    ) -> Any:
        """Live fetch of open/undelivered orders across marketplaces.

        Returns {count, rows[], errors[], filtered_out, filtered_by_source,
        window, fetched_at}. **A 200 with a non-empty `errors[]` is a PARTIAL
        result** — pass the payload to `sources_covered()` and reconcile only
        those sources, or you will delete orders for whichever marketplace
        happened to fail this minute.

        Defaults: all six markets, event window today → today + 2 years.
        """
        params = {k: v for k, v in {
            "markets": markets, "ev_from": ev_from, "ev_to": ev_to,
            "date_from": date_from, "date_to": date_to,
        }.items() if v}
        return self._request(PATHS["orders"], params or None)

    def orders_for_market(self, market: str) -> Any:
        """Live fetch for one marketplace. Name is case-insensitive; spaces may
        be underscores (`vivid_seats`). Returns 502 if that marketplace fails."""
        slug = (market or "").strip().lower().replace(" ", "_")
        if not slug:
            raise S4KMarketplaceError("market is required")
        return self._request(f"/marketplace/orders/{slug}")
