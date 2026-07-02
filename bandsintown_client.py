"""Bands in Town artist + tour-tracking API client (read-only).

Host: https://rest.bandsintown.com
Auth: a registered application id passed as the `app_id` query parameter on
every request (Bands in Town Public API). Resolved arg → env
`BANDSINTOWN_APP_ID` → Supabase Vault, mirroring the other broker clients.
The `app_id` is an application identifier rather than a high-value secret,
but it's resolved through the same path so rotation stays a single
vault.update_secret() call with no redeploy.

Endpoints used (all GET — the Public API has no write surface):
  GET /artists/:artist                 artist profile (id, tracker_count,
                                       upcoming_event_count, links)
  GET /artists/:artist/events          tour dates; `date` filter accepts
                                       "upcoming" (default), "past", "all",
                                       or a "YYYY-MM-DD,YYYY-MM-DD" range

`:artist` is the artist name (percent-encoded), or one of the id forms
`id_<spotify-id>` / `mbid_<musicbrainz-id>`. Names with spaces / slashes
(e.g. "AC/DC") MUST be encoded — `_encode_artist` handles that.

Bands in Town is a pure upstream read source for artist tour tracking, in
the same RULE 2 read-only bucket as the order/listing clients:
`rest.bandsintown.com` is on the FORBIDDEN_HOSTS allowlist in
scripts/check_readonly.py and this module appears in CLIENT_FILES.
"""
from __future__ import annotations

import os
import time
from typing import Any
from urllib.parse import quote

import requests

from core.http_retry import fetch_with_retry
from core.vault import vault_secret


# RULE 2 — READ-ONLY against rest.bandsintown.com. The Public API exposes no
# write endpoints; any non-GET attempt raises before a network call is made.
# The runtime guard pairs with the static check in scripts/check_readonly.py
# and the unit tests in tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class BandsInTownError(RuntimeError):
    pass


class BandsInTownReadOnlyError(BandsInTownError):
    """Raised when a non-GET method is attempted against Bands in Town."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    BandsInTownReadOnlyError, ALLOWED_HTTP_METHODS,
    "Pulling tour data only — never write back to rest.bandsintown.com.",
)


class BandsInTownClient:
    BASE_URL = "https://rest.bandsintown.com"

    def __init__(self, app_id: str | None = None, db: Any | None = None,
                 *, timeout: int = 30):
        # app_id resolution order:
        #   1. Explicit app_id argument (one-off scripts / tests)
        #   2. BANDSINTOWN_APP_ID env var
        #   3. Supabase Vault via get_app_secret('BANDSINTOWN_APP_ID')
        self.db = db
        app_id = (
            app_id
            or os.environ.get("BANDSINTOWN_APP_ID")
            or vault_secret(
                db, "BANDSINTOWN_APP_ID",
                on_error=lambda e: print(f"bandsintown: vault lookup failed: {e}"),
            )
        )
        if not app_id:
            raise BandsInTownError(
                "BANDSINTOWN_APP_ID not found. Either pass app_id, set the env "
                "var, or store it in Supabase Vault: "
                "SELECT vault.create_secret('<app_id>', 'BANDSINTOWN_APP_ID'); "
                "and whitelist the name in public.get_app_secret()."
            )
        self.app_id = app_id.strip()
        self.timeout = timeout

    # ---------- helpers ----------

    @staticmethod
    def _encode_artist(artist: str) -> str:
        """Percent-encode an artist path segment.

        `quote(safe="")` encodes everything that isn't URL-unreserved, so
        "AC/DC" -> "AC%2FDC" and "Tyler, the Creator" survives the path. The
        id forms (`id_<...>`, `mbid_<...>`) are already URL-safe and pass
        through unchanged.
        """
        name = str(artist or "").strip()
        if not name:
            raise BandsInTownError("artist is required")
        return quote(name, safe="")

    # ---------- transport ----------

    def _get(self, path: str, params: dict | None = None) -> Any:
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{self.BASE_URL}{path}"
        merged = {"app_id": self.app_id, **(params or {})}
        clean = {k: v for k, v in merged.items() if v is not None}
        headers = {"Accept": "application/json"}
        # Shared 429/503 retry loop (core/http_retry.py, BR-CODE-2). Network
        # failures are re-raised as BandsInTownError so callers see one
        # exception class at the module boundary (mirrors gotickets_client).
        try:
            r = fetch_with_retry(
                lambda: requests.get(url, headers=headers, params=clean, timeout=self.timeout),
                max_retries=4, retry_statuses=frozenset({429, 503}),
                base_backoff=0.5, max_backoff=30.0, sleep=time.sleep,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            raise BandsInTownError(f"network error: {type(e).__name__}") from e
        if not r.ok:
            raise BandsInTownError(f"HTTP {r.status_code}")
        try:
            return r.json()
        except ValueError:
            return {"raw_text": r.text}

    # ---------- Artists ----------

    def get_artist(self, artist: str) -> dict[str, Any]:
        """GET /artists/:artist — artist profile.

        Returns the artist dict (`id`, `name`, `tracker_count`,
        `upcoming_event_count`, `url`, image links, …). Returns `{}` when the
        artist is unknown / the body isn't a JSON object.
        """
        body = self._get(f"/artists/{self._encode_artist(artist)}")
        return body if isinstance(body, dict) else {}

    def get_artist_events(
        self,
        artist: str,
        *,
        date: str | None = None,
        **extra: Any,
    ) -> list[dict[str, Any]]:
        """GET /artists/:artist/events — tour dates for one artist.

        `date` accepts "upcoming" (Bands in Town's default when omitted),
        "past", "all", or a "YYYY-MM-DD,YYYY-MM-DD" range. Always returns a
        list — `[]` for an unknown artist or a non-list body.
        """
        body = self._get(
            f"/artists/{self._encode_artist(artist)}/events",
            {"date": date, **extra},
        )
        return body if isinstance(body, list) else []

    def get_tour_dates(self, artist: str) -> list[dict[str, Any]]:
        """Convenience: every known tour date (past + upcoming) for an artist.

        Thin wrapper over `get_artist_events(date="all")` — the common entry
        point for tour tracking.
        """
        return self.get_artist_events(artist, date="all")
