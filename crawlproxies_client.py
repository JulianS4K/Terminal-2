"""crawlproxies User API client (read-only).

Host: https://crawlproxies.com  (base path /api/user/v1)
Auth: a user API key (`crawl_user_...`, up to 5 per account, created on the
dashboard's API page) sent as `Authorization: Bearer <key>`. Resolved arg → env
`CRAWLPROXIES_API_KEY` → Supabase Vault (`get_app_secret`), mirroring the other
upstream clients so rotation is one vault.update_secret() with no redeploy.

Endpoints used (all GET):
  GET /account                          username, email, balance, active plans
  GET /plans                            plans newest first (status/limit/offset)
  GET /plans/{plan_id}                  one plan: status, creds, traffic, expiry
  GET /plans/{plan_id}/usage            traffic per bucket (1h|24h|7d|30d)
  GET /plans/{plan_id}/proxy-list       Datacenter IP list (json or text formats)
  GET /transactions                     balance ledger (topup|purchase|extend|refund|gift)
  GET /payments                         crypto top-up invoices

Deliberately NOT implemented: `DELETE /key` (revokes the key used for the
call). It is the API's only write and it is account-side configuration, which
RULE 2 forbids without operator authorization (CLAUDE.md §2).

Amounts are integer US cents (`*_cents`) unless named `*_usd`; times are ISO
8601 UTC. Errors come back non-2xx with `{"detail": "..."}` — 401 bad/revoked
key, 403 account inactive, 404 unknown plan, 409 not an active Datacenter plan
(proxy-list), 422 bad parameter, 429 rate limited (per IP), 503 proxy list
temporarily unavailable. 429 and 503 are retried with backoff.

RULE 2 — `crawlproxies.com` is on FORBIDDEN_HOSTS in scripts/check_readonly.py
and this module is in CLIENT_FILES (GET-only). Routing scraper traffic THROUGH
the proxies (`requests_proxies` / `gateway_proxies`) is a separate concern:
those helpers only build a `proxies=` mapping and make no calls themselves.
"""
from __future__ import annotations

import os
import time
from collections.abc import Iterator
from typing import Any
from urllib.parse import quote

import requests

from core.http_retry import fetch_with_retry
from core.readonly_guard import build_readonly_guard
from core.vault import vault_secret

# RULE 2 — READ-ONLY against crawlproxies.com. Any non-GET attempt raises before
# a network call is made. Pairs with scripts/check_readonly.py (static audit)
# and tests/test_readonly_guards.py (runtime assertions).
ALLOWED_HTTP_METHODS = frozenset({"GET"})

USAGE_RANGES = frozenset({"1h", "24h", "7d", "30d"})
PLAN_STATUSES = frozenset({"active", "expired"})
TRANSACTION_TYPES = frozenset({"topup", "purchase", "extend", "refund", "gift"})
PROXY_PROTOCOLS = frozenset({"http", "socks5"})
PROXY_LIST_FORMATS = frozenset({"json", "standard", "url", "hostport"})


class CrawlProxiesError(RuntimeError):
    """Any crawlproxies API failure. `status_code` is set for HTTP errors."""

    def __init__(self, message: str, status_code: int | None = None):
        super().__init__(message)
        self.status_code = status_code


class CrawlProxiesReadOnlyError(CrawlProxiesError):
    """Raised when a non-GET method is attempted against crawlproxies.com."""


# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    CrawlProxiesReadOnlyError, ALLOWED_HTTP_METHODS,
    "Reading account/plan/usage data only — never write to crawlproxies.com.",
)


def _choice(name: str, value: str, allowed: frozenset[str]) -> str:
    if value not in allowed:
        raise CrawlProxiesError(f"{name} must be one of {sorted(allowed)}, got {value!r}")
    return value


class CrawlProxiesClient:
    BASE_URL = "https://crawlproxies.com"
    API_PREFIX = "/api/user/v1"

    def __init__(self, api_key: str | None = None, db: Any | None = None,
                 *, timeout: int = 30):
        # api_key resolution order:
        #   1. Explicit api_key argument (one-off scripts / tests)
        #   2. CRAWLPROXIES_API_KEY env var
        #   3. Supabase Vault via get_app_secret('CRAWLPROXIES_API_KEY')
        self.db = db
        api_key = (
            api_key
            or os.environ.get("CRAWLPROXIES_API_KEY")
            or vault_secret(
                db, "CRAWLPROXIES_API_KEY",
                on_error=lambda e: print(f"crawlproxies: vault lookup failed: {type(e).__name__}"),
            )
        )
        if not api_key or not api_key.strip():
            raise CrawlProxiesError(
                "CRAWLPROXIES_API_KEY not found. Either pass api_key, set the env "
                "var, or store it in Supabase Vault: "
                "SELECT vault.create_secret('<crawl_user_...>', 'CRAWLPROXIES_API_KEY'); "
                "(the name is whitelisted in public.get_app_secret())."
            )
        self.api_key = api_key.strip()
        self.timeout = timeout

    # ---------- transport ----------

    @staticmethod
    def _plan_path(plan_id: str) -> str:
        pid = str(plan_id or "").strip()
        if not pid:
            raise CrawlProxiesError("plan_id is required")
        return f"/plans/{quote(pid, safe='')}"

    def _request(self, path: str, params: dict | None = None,
                 *, accept: str = "application/json") -> requests.Response:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{self.BASE_URL}{self.API_PREFIX}{path}"
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        headers = {"Authorization": f"Bearer {self.api_key}", "Accept": accept}
        try:
            r = fetch_with_retry(
                lambda: requests.get(url, headers=headers, params=clean, timeout=self.timeout),
                max_retries=4, retry_statuses=frozenset({429, 503}),
                base_backoff=0.5, max_backoff=30.0, sleep=time.sleep,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            raise CrawlProxiesError(f"network error: {type(e).__name__}") from e
        if not r.ok:
            raise CrawlProxiesError(
                f"HTTP {r.status_code}: {self._detail(r)}", status_code=r.status_code,
            )
        return r

    @staticmethod
    def _detail(r: requests.Response) -> str:
        """Pull the API's `{"detail": ...}` message (422 sends a list)."""
        try:
            body = r.json()
        except ValueError:
            return (r.text or "").strip()[:200]
        detail = body.get("detail") if isinstance(body, dict) else None
        if isinstance(detail, list):
            return "; ".join(
                f"{'.'.join(str(p) for p in d.get('loc', []))}: {d.get('msg', '')}"
                if isinstance(d, dict) else str(d)
                for d in detail
            )
        return str(detail) if detail is not None else str(body)[:200]

    def _get_json(self, path: str, params: dict | None = None) -> dict[str, Any]:
        r = self._request(path, params)
        try:
            body = r.json()
        except ValueError as e:
            raise CrawlProxiesError("response was not JSON", status_code=r.status_code) from e
        return body if isinstance(body, dict) else {}

    # ---------- Account ----------

    def get_account(self) -> dict[str, Any]:
        """GET /account — id, username, email, balance_cents/_usd, active_plans."""
        return self._get_json("/account")

    # ---------- Plans ----------

    def list_plans(self, *, status: str | None = None, limit: int = 50,
                   offset: int = 0) -> dict[str, Any]:
        """GET /plans — one page: `{plans, total, limit, offset}` (newest first)."""
        if status is not None:
            _choice("status", status, PLAN_STATUSES)
        return self._get_json("/plans", {"status": status, "limit": limit, "offset": offset})

    def iter_plans(self, *, status: str | None = None,
                   page_size: int = 100) -> Iterator[dict[str, Any]]:
        """Every plan across pages (page_size capped at the API max of 100)."""
        yield from self._paginate(
            lambda lim, off: self.list_plans(status=status, limit=lim, offset=off),
            "plans", min(page_size, 100),
        )

    def get_plan(self, plan_id: str) -> dict[str, Any]:
        """GET /plans/{plan_id} — live status, credentials, used/total GB, expiry."""
        return self._get_json(self._plan_path(plan_id))

    def get_plan_usage(self, plan_id: str, *, range: str = "24h",
                       utc_offset_minutes: int = 0) -> dict[str, Any]:
        """GET /plans/{plan_id}/usage — `points` (oldest first) of `{ts, bytes}`.

        `range`: 1h (5-min buckets), 24h (hourly), 7d (6-hourly), 30d (daily).
        `supported` is False for plans not metered by traffic.
        """
        _choice("range", range, USAGE_RANGES)
        if not -840 <= int(utc_offset_minutes) <= 840:
            raise CrawlProxiesError("utc_offset_minutes must be within ±840")
        return self._get_json(
            f"{self._plan_path(plan_id)}/usage",
            {"range": range, "utc_offset_minutes": int(utc_offset_minutes)},
        )

    def get_proxy_list(self, plan_id: str, *, protocol: str = "http",
                       limit: int | str = 1000, shuffle: bool = False,
                       format: str = "json") -> dict[str, Any]:
        """GET /plans/{plan_id}/proxy-list — Datacenter IPs (each IP is also the exit IP).

        Always returns the JSON shape `{plan_id?, protocol, proxies: [...], count,
        total, stale, ...}`. For the text formats (`standard`, `url`, `hostport`)
        `proxies` holds the lines and count/total/stale come from the
        X-Count / X-Total / X-Stale headers. The list rotates every few minutes —
        fetch it fresh rather than storing it. 409 = not an active Datacenter plan.
        """
        _choice("protocol", protocol, PROXY_PROTOCOLS)
        _choice("format", format, PROXY_LIST_FORMATS)
        lim = str(limit)
        if lim != "all" and not (lim.isdigit() and 1 <= int(lim) <= 999999):
            raise CrawlProxiesError("limit must be 1..999999 or 'all'")
        params = {"protocol": protocol, "limit": lim,
                  "shuffle": "true" if shuffle else "false", "format": format}
        path = f"{self._plan_path(plan_id)}/proxy-list"
        if format == "json":
            return self._get_json(path, params)

        r = self._request(path, params, accept="text/plain")
        lines = [ln.strip() for ln in (r.text or "").splitlines() if ln.strip()]

        def _int(h: str) -> int | None:
            v = r.headers.get(h)
            return int(v) if v is not None and str(v).isdigit() else None

        stale = str(r.headers.get("X-Stale", "")).lower() in {"1", "true", "yes"}
        count = _int("X-Count")
        return {
            "plan_id": str(plan_id), "protocol": protocol, "format": format,
            "proxies": lines,
            "count": count if count is not None else len(lines),
            "total": _int("X-Total"),
            "stale": stale,
        }

    # ---------- Billing ----------

    def list_transactions(self, *, type: str | None = None, limit: int = 50,
                          offset: int = 0) -> dict[str, Any]:
        """GET /transactions — balance ledger page (amount_cents < 0 for charges)."""
        if type is not None:
            _choice("type", type, TRANSACTION_TYPES)
        return self._get_json("/transactions", {"type": type, "limit": limit, "offset": offset})

    def iter_transactions(self, *, type: str | None = None,
                          page_size: int = 200) -> Iterator[dict[str, Any]]:
        yield from self._paginate(
            lambda lim, off: self.list_transactions(type=type, limit=lim, offset=off),
            "transactions", min(page_size, 200),
        )

    def list_payments(self, *, limit: int = 50, offset: int = 0) -> dict[str, Any]:
        """GET /payments — crypto top-up invoices and whether each was credited."""
        return self._get_json("/payments", {"limit": limit, "offset": offset})

    def iter_payments(self, *, page_size: int = 200) -> Iterator[dict[str, Any]]:
        yield from self._paginate(
            lambda lim, off: self.list_payments(limit=lim, offset=off),
            "payments", min(page_size, 200),
        )

    @staticmethod
    def _paginate(fetch, key: str, page_size: int) -> Iterator[dict[str, Any]]:
        offset = 0
        while True:
            page = fetch(page_size, offset)
            rows = page.get(key) or []
            yield from rows
            offset += len(rows)
            total = page.get("total")
            if not rows or len(rows) < page_size or (isinstance(total, int) and offset >= total):
                return


# ---------- proxy wiring helpers (pure — no network) ----------

def requests_proxies(entry: str, protocol: str = "http") -> dict[str, str]:
    """`ip:port:user:pass` (a proxy-list line) → a `requests` `proxies=` mapping.

    socks5 uses the `socks5h://` scheme so DNS resolves at the proxy (needs
    `requests[socks]`). Credentials are percent-encoded.
    """
    _choice("protocol", protocol, PROXY_PROTOCOLS)
    parts = str(entry or "").strip().split(":")
    if len(parts) < 4:
        raise CrawlProxiesError("proxy entry must be ip:port:user:pass")
    host, port, user, pw = parts[0], parts[1], parts[2], ":".join(parts[3:])
    scheme = "socks5h" if protocol == "socks5" else "http"
    url = f"{scheme}://{quote(user, safe='')}:{quote(pw, safe='')}@{host}:{port}"
    return {"http": url, "https": url}


def gateway_proxies(plan: dict[str, Any], protocol: str = "http") -> dict[str, str]:
    """A gateway plan (from get_plan / list_plans) → a `requests` `proxies=` mapping.

    Uses `connection.hostname` + `port_http`/`port_socks` and the plan's
    `proxy_username`/`proxy_password`. Datacenter plans (`connection.mode ==
    "ip_list"`) have no gateway — use get_proxy_list + requests_proxies instead.
    """
    _choice("protocol", protocol, PROXY_PROTOCOLS)
    conn = plan.get("connection") or {}
    if conn.get("mode") == "ip_list":
        raise CrawlProxiesError("Datacenter plan has no gateway; use get_proxy_list()")
    host = conn.get("hostname")
    port = conn.get("port_socks") if protocol == "socks5" else conn.get("port_http")
    user, pw = plan.get("proxy_username"), plan.get("proxy_password")
    if not (host and port and user and pw):
        raise CrawlProxiesError("plan has no usable gateway connection (provisioning?)")
    return requests_proxies(f"{host}:{port}:{user}:{pw}", protocol)
