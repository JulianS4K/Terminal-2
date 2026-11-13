"""StubHub API client — our own seller account's sales + listings (read-only, OFF by default).

Hosts:  https://api.stubhub.net/v2           (production)
        https://sandbox.api.stubhub.net/v2   (sandbox)
Auth:   OAuth2 bearer token for OUR StubHub seller account, obtained with the
        user-login (authorization code) flow and kept fresh by the refresh-token
        grant. Both logins happen in SQL (`stubhub_oauth_complete`,
        `stubhub_token_refresh`, mig 20261113250000) with the app's client id +
        secret read from Supabase Vault — this module never sees the client
        secret and never POSTs anything. Token resolution: arg → env
        `STUBHUB_ACCESS_TOKEN` → Vault `STUBHUB_ACCESS_TOKEN` (via get_app_secret;
        the name must be whitelisted there when the integration is switched on).

Why this exists: StubHub is one of the two marketplaces (with Gametime) whose
orders we only see through the S4K CRM. Reading our own StubHub book directly
removes that dependency for StubHub.

Endpoints used (all GET, per developer.stubhub.com/api-reference):
  GET /sales                    our sales (paged, application/hal+json)
  GET /sales/{saleId}           one sale
  GET /sales/recentupdates      sales changed recently
  GET /sellerlistings           our listings
  GET /sellerlistings/{id}      one listing
  GET <any other read path>     via get(path)

OFF BY DEFAULT: every call raises StubHubDisabledError unless the env var
STUBHUB_API_ENABLED is "1" (operator 2026-11-13: "wire the api but keep turned
off and read only till we get tokens").

RULE 2 — READ-ONLY. The StubHub API has write endpoints (create/update listings,
confirm/fulfil sales, upload e-tickets); none is implemented and the guard
below raises on any non-GET before a network call. The OAuth scopes requested
are read-only too (READ_SCOPES; `write:*` is refused in SQL and here).
`api.stubhub.net` and `account.stubhub.com` are on the FORBIDDEN_HOSTS list in
scripts/check_readonly.py and this module is in CLIENT_FILES.
"""
from __future__ import annotations

import os
import time
from typing import Any
from urllib.parse import quote

import requests

from core.http_retry import fetch_with_retry
from core.vault import vault_secret


# RULE 2 — READ-ONLY against api.stubhub.net. Every data call is a GET; any
# other method raises before a network call is made. Pairs with the static
# audit in scripts/check_readonly.py and tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})

# The only OAuth scopes this integration may ever hold. Adding a write:* scope
# would let the token confirm sales or change listings — security-CRIT
# (CLAUDE.md §2), needs explicit operator authorization.
READ_SCOPES = ("read:sales", "read:sellerlistings", "read:events", "read:payment")


class StubHubError(RuntimeError):
    pass


class StubHubReadOnlyError(StubHubError):
    """Raised when a non-GET method, or a write scope, is attempted."""


class StubHubDisabledError(StubHubError):
    """Raised while the integration is switched off (STUBHUB_API_ENABLED != "1")."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    StubHubReadOnlyError, ALLOWED_HTTP_METHODS,
    "Reading our own StubHub sales/listings only — never write to api.stubhub.net.",
)


def assert_read_scopes(scopes: str | list[str] | tuple[str, ...]) -> list[str]:
    """Return the scopes as a list, raising StubHubReadOnlyError on any scope
    that is not one of READ_SCOPES (in particular any write:* scope)."""
    items = scopes.split() if isinstance(scopes, str) else list(scopes)
    bad = [s for s in items if s not in READ_SCOPES]
    if bad:
        raise StubHubReadOnlyError(
            f"READ-ONLY violation: scope(s) {bad} not allowed; StubHub access is "
            f"limited to {list(READ_SCOPES)} (RULE 2, CLAUDE.md §2)."
        )
    return items


def stubhub_enabled() -> bool:
    return os.environ.get("STUBHUB_API_ENABLED") == "1"


class StubHubClient:
    PROD_BASE_URL = "https://api.stubhub.net/v2"
    SANDBOX_BASE_URL = "https://sandbox.api.stubhub.net/v2"

    def __init__(self, access_token: str | None = None, db: Any | None = None, *,
                 sandbox: bool | None = None, timeout: int = 30):
        if not stubhub_enabled():
            raise StubHubDisabledError(
                "StubHub API is switched off (set STUBHUB_API_ENABLED=1 once the "
                "OAuth tokens are in place)."
            )
        if sandbox is None:
            sandbox = os.environ.get("STUBHUB_ENV", "production").lower() == "sandbox"
        self.base_url = self.SANDBOX_BASE_URL if sandbox else self.PROD_BASE_URL
        token = (
            access_token
            or os.environ.get("STUBHUB_ACCESS_TOKEN")
            or vault_secret(
                db, "STUBHUB_ACCESS_TOKEN",
                on_error=lambda e: print(f"stubhub: vault lookup failed: {type(e).__name__}"),
            )
        )
        if not token:
            raise StubHubError(
                "No StubHub access token. Connect the account first "
                "(GET /api/admin/stubhub/connect), then the token refresh keeps it in Vault."
            )
        self.access_token = token.strip()
        self.timeout = timeout

    def get(self, path: str, params: dict | None = None) -> Any:
        """GET a read path under the API root, e.g. get('/sales', {'page': 1})."""
        _assert_readonly_method("GET")  # RULE 2 enforcement
        if not path.startswith("/") or "://" in path:
            raise StubHubError(f"path must be a relative API path, got {path!r}")
        url = f"{self.base_url}{path}"
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        headers = {"Accept": "application/hal+json", "Authorization": f"Bearer {self.access_token}"}
        try:
            r = fetch_with_retry(
                lambda: requests.get(url, headers=headers, params=clean, timeout=self.timeout),
                max_retries=4, retry_statuses=frozenset({429, 503}),
                base_backoff=0.5, max_backoff=30.0, sleep=time.sleep,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            raise StubHubError(f"network error: {type(e).__name__}") from e
        if r is None or not r.ok:
            raise StubHubError(f"HTTP {getattr(r, 'status_code', '?')}")
        try:
            return r.json()
        except ValueError:
            return {"raw_text": r.text}

    # ---------- Sales (our sell side) ----------

    def sales(self, **params: Any) -> Any:
        """GET /sales — our sales, newest first per StubHub's default sort."""
        return self.get("/sales", params)

    def sale(self, sale_id: str | int) -> Any:
        """GET /sales/{saleId} — one of our sales."""
        return self.get(f"/sales/{quote(str(sale_id).strip(), safe='')}")

    def sales_recent_updates(self, **params: Any) -> Any:
        """GET /sales/recentupdates — sales whose state changed recently."""
        return self.get("/sales/recentupdates", params)

    # ---------- Seller listings ----------

    def seller_listings(self, **params: Any) -> Any:
        """GET /sellerlistings — our listings."""
        return self.get("/sellerlistings", params)

    def seller_listing(self, listing_id: str | int) -> Any:
        """GET /sellerlistings/{id} — one of our listings."""
        return self.get(f"/sellerlistings/{quote(str(listing_id).strip(), safe='')}")
