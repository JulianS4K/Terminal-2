"""Oxylabs Residential Proxy Public API client (read-only, plus one sanctioned login).

Host: https://residential-api.oxylabs.io  (base path /v2)
Auth: the API issues a JWT only through `POST /v2/login`, authenticated with HTTP Basic
(`username:password`); the token lasts 1 hour and is sent as `Authorization: Bearer` on every
read. Credentials resolve arg → env `OXYLABS_RESIDENTIAL_USERNAME` / `_PASSWORD` → Supabase
Vault under the names the operator stored them (`OXY-Test-Username` / `Oxy-Test-PW`,
whitelisted in get_app_secret() by mig 20261110214000).

Endpoints used:
  POST /v2/login                                           token (writes nothing)
  GET  /v2/users/{userId}/client-stats                     account traffic, current month (GB)
  GET  /v2/users/{userId}/sub-users                        active sub-users
  GET  /v2/users/{userId}/sub-users/{subUserId}            sub-user traffic by period (GB)
  GET  /v2/users/{userId}/sub-users/{subUserId}/target-stats  traffic by target for one day

RULE 2 carve-out (operator authorization 2026-11-10: "Authorize login only"): the ONLY non-GET
this client may send is `POST residential-api.oxylabs.io/v2/login`, pinned by
``OXYLABS_WRITE_PATHS`` (scripts/check_readonly.py requires the exact literal). The API's
sub-user writes — create (POST), update (PATCH: password, traffic limit, status) and delete —
are deliberately not implemented, and adding any is security-CRIT (CLAUDE.md §2).
"""
from __future__ import annotations

import os
import re
import time
from datetime import date, datetime
from typing import Any
from urllib.parse import quote, urlsplit

import requests

from core.http_retry import fetch_with_retry
from core.vault import vault_secret

# RULE 2: GET to residential-api.oxylabs.io; POST only for the login below.
ALLOWED_HTTP_METHODS = frozenset({"GET", "POST"})

# (method, host, path regex): the ONLY write this client may send. Security-CRIT to widen.
OXYLABS_WRITE_PATHS = (("POST", "residential-api.oxylabs.io", r"^/v2/login$"),)
_WRITES = tuple((m, h, re.compile(p)) for m, h, p in OXYLABS_WRITE_PATHS)
API_HOST = "residential-api.oxylabs.io"

VAULT_USERNAME = "OXY-Test-Username"
VAULT_PASSWORD = "Oxy-Test-PW"
STATS_TYPES = frozenset({"24h", "week", "month", "current_month", "lifetime", "custom"})
TOKEN_TTL_SECONDS = 3600
TOKEN_REFRESH_MARGIN = 300  # re-login 5 minutes before the 1-hour expiry


class OxylabsError(RuntimeError):
    """Any Oxylabs API failure. `status_code` is set for HTTP errors."""

    def __init__(self, message: str, status_code: int | None = None):
        super().__init__(message)
        self.status_code = status_code


class OxylabsReadOnlyError(OxylabsError):
    """Raised when the guard refuses a request."""


def _assert_readonly_method(method: str, url: str = "") -> None:
    """GET to the API host; POST only if it is one of OXYLABS_WRITE_PATHS. Raises otherwise."""
    m = method.upper()
    parts = urlsplit(url)
    if m not in ALLOWED_HTTP_METHODS:
        raise OxylabsReadOnlyError(
            f"READ-ONLY violation: method {method} is not allowed. RULE 2 read-only lockdown (CLAUDE.md §2)."
        )
    if url and (parts.scheme != "https" or parts.hostname != API_HOST):
        raise OxylabsReadOnlyError(f"READ-ONLY violation: host {parts.hostname!r} is not {API_HOST}.")
    if m != "GET" and not any(m == wm and parts.hostname == wh and wr.match(parts.path) for wm, wh, wr in _WRITES):
        raise OxylabsReadOnlyError(
            f"READ-ONLY violation: {m} {parts.hostname}{parts.path} is not the sanctioned login "
            "(RULE 2, operator 2026-11-10)."
        )


def _resolve(value: str | None, env: str, db: Any, vault_name: str) -> str | None:
    value = value or os.environ.get(env) or vault_secret(
        db, vault_name, on_error=lambda e: print(f"oxylabs: vault lookup failed: {type(e).__name__}"),
    )
    return value.strip() if value and value.strip() else None


def _day(value: date | datetime | str) -> str:
    return value.strftime("%Y-%m-%d") if isinstance(value, (date, datetime)) else str(value).strip()


class OxylabsResidentialClient:
    BASE_URL = f"https://{API_HOST}/v2"

    def __init__(self, username: str | None = None, password: str | None = None, db: Any | None = None,
                 *, session: Any = None, timeout: int = 30, clock=time.monotonic):
        self.db = db
        self.username = _resolve(username, "OXYLABS_RESIDENTIAL_USERNAME", db, VAULT_USERNAME)
        self.password = _resolve(password, "OXYLABS_RESIDENTIAL_PASSWORD", db, VAULT_PASSWORD)
        if not (self.username and self.password):
            raise OxylabsError(
                "Oxylabs Residential API credentials not found. Pass username/password, set "
                "OXYLABS_RESIDENTIAL_USERNAME / OXYLABS_RESIDENTIAL_PASSWORD, or store them in Vault "
                f"as {VAULT_USERNAME!r} / {VAULT_PASSWORD!r} (both whitelisted in get_app_secret())."
            )
        self.session = session or requests.Session()
        self.timeout = timeout
        self._clock = clock
        self._token: str | None = None
        self._user_id: str | None = None
        self._token_at = 0.0

    # ---------- transport ----------

    def _send(self, method: str, url: str, *, retry: bool, **kw: Any) -> requests.Response:
        _assert_readonly_method(method, url)  # RULE 2 enforcement, before any network call
        try:
            return fetch_with_retry(
                lambda: self.session.request(method, url, timeout=self.timeout, **kw),
                max_retries=4 if retry else 0, retry_statuses=frozenset({429, 502, 503, 504}),
                base_backoff=0.5, max_backoff=30.0, sleep=time.sleep,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            raise OxylabsError(f"network error: {type(e).__name__}") from e

    @staticmethod
    def _error(r: requests.Response) -> OxylabsError:
        try:
            body = r.json()
            detail = body.get("error") if isinstance(body, dict) else None
        except ValueError:
            detail = None
        detail = detail or (r.text or "").strip()[:200]
        return OxylabsError(f"HTTP {r.status_code}: {detail}", status_code=r.status_code)

    def login(self) -> str:
        """POST /v2/login (Basic auth) → caches the 1-hour token and the account's user_id."""
        r = self._send("POST", f"{self.BASE_URL}/login", retry=False,
                       auth=(self.username, self.password), headers={"Accept": "application/json"})
        if not r.ok:
            raise self._error(r)
        try:
            body = r.json()
        except ValueError as e:
            raise OxylabsError("login response was not JSON", status_code=r.status_code) from e
        token = body.get("token") if isinstance(body, dict) else None
        user_id = body.get("user_id") if isinstance(body, dict) else None
        if not (token and user_id):
            raise OxylabsError("login response missing token/user_id", status_code=r.status_code)
        self._token, self._user_id, self._token_at = token, str(user_id), self._clock()
        return self._user_id

    def _ensure_token(self) -> None:
        if not self._token or self._clock() - self._token_at > TOKEN_TTL_SECONDS - TOKEN_REFRESH_MARGIN:
            self.login()

    @property
    def user_id(self) -> str:
        self._ensure_token()
        assert self._user_id is not None
        return self._user_id

    def _get(self, path: str, params: dict | None = None) -> Any:
        self._ensure_token()
        clean = {k: v for k, v in (params or {}).items() if v is not None}

        def fetch() -> requests.Response:
            return self._send("GET", f"{self.BASE_URL}{path}", retry=True, params=clean,
                              headers={"Authorization": f"Bearer {self._token}", "Accept": "application/json"})

        r = fetch()
        if r.status_code == 401:
            self.login()  # token revoked or expired early: one fresh login, then retry once
            r = fetch()
        if not r.ok:
            raise self._error(r)
        try:
            return r.json()
        except ValueError as e:
            raise OxylabsError("response was not JSON", status_code=r.status_code) from e

    def _user_path(self) -> str:
        return f"/users/{quote(self.user_id, safe='')}"

    @staticmethod
    def _sub_user_id(sub_user_id: int | str) -> str:
        sid = str(sub_user_id).strip()
        if not sid.isdigit():
            raise OxylabsError("sub_user_id must be a numeric id")
        return sid

    # ---------- reads ----------

    def get_client_stats(self) -> dict[str, Any]:
        """GET /users/{userId}/client-stats — `{traffic (GB), date_from, date_to}` for this month."""
        body = self._get(f"{self._user_path()}/client-stats")
        return body if isinstance(body, dict) else {}

    def list_sub_users(self) -> list[dict[str, Any]]:
        """GET /users/{userId}/sub-users — active sub-users with traffic and limits (GB)."""
        body = self._get(f"{self._user_path()}/sub-users")
        return body if isinstance(body, list) else []

    def get_sub_user_stats(self, sub_user_id: int | str, *, type: str = "current_month",
                           date_from: date | datetime | str | None = None,
                           date_to: date | datetime | str | None = None,
                           time_zone: str | None = None) -> dict[str, Any]:
        """GET /users/{userId}/sub-users/{id} — `{traffic, results: [{period, traffic}]}` (GB).

        `type`: 24h | week | month | current_month | lifetime | custom (custom needs
        date_from/date_to, 'YYYY-MM-DD' or 'YYYY-MM-DD HH'; hourly ranges max 7 days).
        """
        if type not in STATS_TYPES:
            raise OxylabsError(f"type must be one of {sorted(STATS_TYPES)}, got {type!r}")
        if type == "custom" and not (date_from and date_to):
            raise OxylabsError("type='custom' needs date_from and date_to")
        params = {"type": type, "time_zone": time_zone,
                  "date_from": None if date_from is None else (date_from if isinstance(date_from, str) else _day(date_from)),
                  "date_to": None if date_to is None else (date_to if isinstance(date_to, str) else _day(date_to))}
        body = self._get(f"{self._user_path()}/sub-users/{self._sub_user_id(sub_user_id)}", params)
        return body if isinstance(body, dict) else {}

    def get_sub_user_target_stats(self, sub_user_id: int | str,
                                  day: date | datetime | str) -> dict[str, Any]:
        """GET .../sub-users/{id}/target-stats — traffic + requests by target for one day (last 30 days)."""
        body = self._get(f"{self._user_path()}/sub-users/{self._sub_user_id(sub_user_id)}/target-stats",
                         {"date": _day(day)})
        return body if isinstance(body, dict) else {}
