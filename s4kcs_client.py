"""S4K CRM marketplace-orders API client (read-only).

Host: https://crm.s4kcs.com/api/v1
Auth: an `X-API-Key: s4k_…` header, resolved arg → env `S4KCS_API_KEY` →
Supabase Vault (`crm.s4kcs.com`), mirroring the other clients.

Why this exists: our own ingest covers four order books (EVO, SeatGeek,
TickPick, Vivid). The CRM aggregates open sell-side orders from SIX
marketplaces, adding **StubHub and Gametime — which we ingest nowhere**. The
substitution checker's order lookup falls back to it so a broker can paste any
marketplace's order number instead of retyping the sold ticket by hand.

Endpoints used (all GET — per its own docs the API has no write surface):
  GET /ping                          key check
  GET /marketplace/marketplaces      the six markets + whether creds are set
  GET /marketplace/columns           the column set every order row carries
  GET /marketplace/orders            live fetch across markets (can take ~60s)

Rate limits are 120 req/min general but only **10/min** on the live-fetch
endpoints, and one fetch returns every open order (tens of thousands of rows,
~10 MB). So `orders()` memoises per parameter set for `cache_ttl` seconds and
`find_order` scans that cached list — the API has no by-id endpoint.

RULE 2: this is an upstream read source like the order/listing clients. The
runtime guard below raises on any non-GET before a network call is made.
"""
from __future__ import annotations

import os
import time
from typing import Any

import requests

from core.http_retry import fetch_with_retry
from core.vault import vault_secret


# RULE 2 — READ-ONLY against crm.s4kcs.com. Every documented endpoint is a GET;
# any non-GET attempt raises before a network call is made. Pairs with the
# static audit in scripts/check_readonly.py and tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class S4KCSError(RuntimeError):
    pass


class S4KCSReadOnlyError(S4KCSError):
    """Raised when a non-GET method is attempted against the S4K CRM."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    S4KCSReadOnlyError, ALLOWED_HTTP_METHODS,
    "Reading marketplace orders only — never write back to crm.s4kcs.com.",
)

# The single Vault name carrying the key. It was also seeded as
# `EVENUEDESK_API_KEY`; that duplicate was deleted so one name owns the secret
# and a rotation has exactly one place to land.
VAULT_SECRET_NAME = "crm.s4kcs.com"

# {(markets, ev_from, ev_to): (fetched_at_monotonic, rows)}. Module-level so the
# cache survives per-request client construction in the route.
_ORDERS_CACHE: dict[tuple, tuple[float, list[dict[str, Any]]]] = {}


def _resolve_key(api_key: str | None, db: Any | None) -> str | None:
    """arg → env → vault. Never logs the value."""
    if api_key:
        return api_key
    env = os.environ.get("S4KCS_API_KEY")
    if env:
        return env
    return vault_secret(
        db, VAULT_SECRET_NAME,
        on_error=lambda e: print(f"s4kcs: vault lookup failed: {e}"),
    )


class S4KCSClient:
    BASE_URL = "https://crm.s4kcs.com/api/v1"

    def __init__(self, api_key: str | None = None, db: Any | None = None,
                 *, timeout: int = 120, cache_ttl: float = 600.0):
        key = _resolve_key(api_key, db)
        if not key:
            raise S4KCSError(
                "S4KCS API key not found. Either pass api_key, set the "
                "S4KCS_API_KEY env var, or store it in Supabase Vault as "
                "'crm.s4kcs.com' (whitelisted in public.get_app_secret())."
            )
        # The vault copy was seeded with a leading space, which makes the
        # header invalid. That value has been normalized, but a re-paste can
        # reintroduce it and the failure is an opaque 401 — so strip rather
        # than depend on the stored value being clean (as TEVO_SECRET does).
        self.api_key = key.strip()
        self.timeout = timeout
        self.cache_ttl = cache_ttl

    # ---------- transport ----------

    def _get(self, path: str, params: dict | None = None) -> Any:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{self.BASE_URL}{path}"
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        headers = {"X-API-Key": self.api_key, "Accept": "application/json"}
        try:
            r = fetch_with_retry(
                lambda: requests.get(url, headers=headers, params=clean,
                                     timeout=self.timeout),
                max_retries=4, retry_statuses=frozenset({429, 503}),
                base_backoff=0.5, max_backoff=30.0, sleep=time.sleep,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            raise S4KCSError(f"network error: {type(e).__name__}") from e
        if not r.ok:
            raise S4KCSError(f"HTTP {r.status_code}")
        try:
            return r.json()
        except ValueError:
            return {"raw_text": r.text}

    # ---------- endpoints ----------

    def ping(self) -> dict[str, Any]:
        """GET /ping — confirms the key works. `{ok, key, scopes, expires_at}`."""
        body = self._get("/ping")
        return body if isinstance(body, dict) else {}

    def marketplaces(self) -> list[dict[str, Any]]:
        """GET /marketplace/marketplaces — `[{name, key, configured}, …]`."""
        body = self._get("/marketplace/marketplaces")
        return (body or {}).get("marketplaces", []) if isinstance(body, dict) else []

    def columns(self) -> list[str]:
        """GET /marketplace/columns — the column set every order row carries."""
        body = self._get("/marketplace/columns")
        return (body or {}).get("columns", []) if isinstance(body, dict) else []

    def orders(self, *, markets: str | None = None, ev_from: str | None = None,
               ev_to: str | None = None, use_cache: bool = True) -> list[dict[str, Any]]:
        """GET /marketplace/orders — open sell-side orders across marketplaces.

        Memoised for `cache_ttl` seconds per parameter set: the live fetch is
        rate-limited to 10/min and returns the whole book, so repeated lookups
        must not each hit it. `use_cache=False` forces a refresh.

        A marketplace that fails its own fetch is reported in the response's
        `errors` and simply contributes no rows — the others still return, so
        this never raises on a partial outage.
        """
        cache_key = (markets, ev_from, ev_to)
        now = time.monotonic()
        if use_cache:
            hit = _ORDERS_CACHE.get(cache_key)
            if hit is not None and (now - hit[0]) < self.cache_ttl:
                return hit[1]
        body = self._get("/marketplace/orders", {
            "markets": markets, "ev_from": ev_from, "ev_to": ev_to,
        })
        rows = body.get("rows", []) if isinstance(body, dict) else []
        rows = rows if isinstance(rows, list) else []
        _ORDERS_CACHE[cache_key] = (now, rows)
        return rows

    def find_order(self, order_id: str, **kwargs: Any) -> dict[str, Any] | None:
        """The open order with this marketplace order id, or None.

        The API has no by-id endpoint, so this scans the (cached) order list.
        Ids are strings there; compared as trimmed strings so a caller passing
        an int or a padded value still matches.
        """
        wanted = str(order_id or "").strip()
        if not wanted:
            return None
        for row in self.orders(**kwargs):
            if str(row.get("id") or "").strip() == wanted:
                return row
        return None
