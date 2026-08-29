"""eVenue Desk marketplace API client (read-only).

Host: https://crm.s4kcs.com  —  consumer plane `/api/v1/*`

**A separate upstream source, NOT the Paciolan pipeline.** The desk is an
aggregator that fronts several primary box-office platforms (Paciolan,
ProVenue, Ticketmaster), but it is its own host, its own auth, and its own
event-ID scheme, and it lands in its own `evenuedesk_*` tables. It shares no
code, no tables and no cron with `paciolan_client.py` /
`paciolan_*` — that pipeline stays browser-extension-sourced against
`<tenant>.evenue.net`, which this env cannot reach and RULE 2 forbids writing
to. Do not merge the two; a change here must never touch paciolan_*.

Auth: `X-API-Key: <key>`. The key is sourced from the `EVENUEDESK_API_KEY` env
var, falling back to Supabase Vault under the same name — never hardcoded,
never logged, and never rendered into an exception message or a URL.

Read-only: RULE 2 (CLAUDE.md §2). The desk's consumer plane is documented as
GET-only, and this client enforces that at the transport layer anyway —
`ALLOWED_HTTP_METHODS = frozenset({"GET"})` plus an `_assert_readonly_method`
tripwire that raises before any socket is opened. There is no reprice, hold,
order or inventory-mutation path here and none may be added.

Endpoint-shape caveat (2026-08-29): only `GET /api/v1/ping` is confirmed
against the live desk (operator-supplied smoke test). The feed endpoints below
are transcribed from the eVenue Desk API Reference PDF and are **unverified**
— the operator's key carries an `s4k_` prefix where that reference documents
`evd_`, so the marketplace plane may differ. `FEED_PATHS` is the single place
to correct them. Until a real response is captured, callers should land the
payload raw (see `evenuedesk_raw_pulls`) rather than trusting a parsed shape.
"""
from __future__ import annotations

import os
import time
from typing import Any

import requests

from core.vault import vault_secret


# Read-only by design (RULE 2). Same guard contract as every other broker
# client; `scripts/check_readonly.py` requires both tokens to appear in this
# file verbatim, and `tests/test_readonly_guards.py` imports them.
ALLOWED_HTTP_METHODS = frozenset({"GET"})

# Consumer-plane paths. `ping` is confirmed live; the rest are transcribed from
# the API reference and unverified against this host — correct them here (and
# only here) once a real response is captured.
FEED_PATHS = {
    "ping": "/api/v1/ping",
    "events": "/api/v1/events",
    "feed_full": "/api/v1/feed/full",
    "feed_changes": "/api/v1/feed/changes",
}

# Canonical raw-blocks column order, measured across the four sample scans
# (2026-08-19 / 2026-08-21) — see docs/evenuedesk_feed_mapping.md §2. Ingest
# MUST key by column NAME, never position: the 2026-08-21 export introduced an
# undocumented `max_contiguous` column mid-row.
FEED_COLUMNS = (
    "event_uid", "internal_id", "paciolan_id", "platform", "school_host",
    "event_name", "opponent", "event_date", "event_time", "venue",
    "level", "section", "row", "seat_low", "seat_high", "qty",
    "price", "price_level", "price_source", "ticket_uid", "pulled_at",
    "max_contiguous",
)


class EVenueDeskError(RuntimeError):
    pass


class EVenueDeskReadOnlyError(EVenueDeskError):
    """Raised when a non-GET method is attempted against the eVenue Desk."""


class EVenueDeskAuthError(EVenueDeskError):
    """401/403 — bad, missing, or unauthorized API key."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    EVenueDeskReadOnlyError, ALLOWED_HTTP_METHODS,
    "Pulling data only — never write back to the eVenue Desk.",
)


def _vault_secret(db: Any, name: str) -> str | None:
    """Read a secret from Supabase Vault. Thin wrapper over the shared resolver
    (core/vault.py) preserving this module's log prefix + name."""
    return vault_secret(db, name,
                        on_error=lambda e: print(f"evenuedesk: vault lookup for {name} failed: {e}"))


class EVenueDeskClient:
    BASE_URL = "https://crm.s4kcs.com"

    # The desk advances a server-side baseline per API key on /feed/changes, so
    # two concurrent pollers on one key would each see half the deltas. Keep a
    # single scheduled caller (the 10-minute cron) and use dry_run for any
    # ad-hoc inspection.
    DEFAULT_TIMEOUT = 60
    MAX_RETRIES = 3
    RETRY_STATUS = frozenset({429, 502, 503, 504})

    def __init__(
        self,
        api_key: str | None = None,
        *,
        db: Any = None,
        base_url: str | None = None,
        timeout: int | None = None,
    ):
        # arg → env → Vault. Never hardcoded; never logged.
        self.api_key = (
            api_key
            or os.environ.get("EVENUEDESK_API_KEY")
            or _vault_secret(db, "EVENUEDESK_API_KEY")
        )
        self.base_url = (base_url or os.environ.get("EVENUEDESK_BASE_URL")
                         or self.BASE_URL).rstrip("/")
        self.timeout = timeout or self.DEFAULT_TIMEOUT
        self._session = requests.Session()

    def _request(self, path: str, params: dict[str, Any] | None = None) -> Any:
        """Issue one GET against the desk and return the decoded JSON body.

        The key travels in a header, never in the URL or query string, so it
        cannot leak into a redirect, an access log, or the repr of the request
        on an exception path.
        """
        _assert_readonly_method("GET")
        if not self.api_key:
            raise EVenueDeskAuthError(
                "no eVenue Desk API key: set EVENUEDESK_API_KEY or store it in "
                "Supabase Vault under the same name"
            )
        url = f"{self.base_url}{path}"
        headers = {"X-API-Key": self.api_key, "Accept": "application/json"}

        last_exc: Exception | None = None
        for attempt in range(self.MAX_RETRIES):
            try:
                resp = self._session.get(url, headers=headers, params=params,
                                         timeout=self.timeout)
            except requests.RequestException as e:
                # Never interpolate the exception's request repr — it can carry
                # headers. Report the path only.
                last_exc = EVenueDeskError(f"GET {path} failed: {type(e).__name__}")
                time.sleep(2 ** attempt)
                continue

            if resp.status_code in (401, 403):
                raise EVenueDeskAuthError(
                    f"GET {path} returned {resp.status_code} — key rejected by the desk"
                )
            if resp.status_code in self.RETRY_STATUS and attempt < self.MAX_RETRIES - 1:
                time.sleep(2 ** attempt)
                continue
            if resp.status_code >= 400:
                raise EVenueDeskError(f"GET {path} returned {resp.status_code}")
            try:
                return resp.json()
            except ValueError as e:
                raise EVenueDeskError(f"GET {path} returned non-JSON body") from e

        raise last_exc or EVenueDeskError(f"GET {path} exhausted retries")

    # ---- consumer-plane reads ----------------------------------------------

    def ping(self) -> Any:
        """Liveness + key check. The one endpoint confirmed against this host."""
        return self._request(FEED_PATHS["ping"])

    def events(self, **params: Any) -> Any:
        """Event roster. Each event carries the source's own ID scheme — see
        docs/evd_event_id_crosswalk.csv for the per-source decomposition."""
        return self._request(FEED_PATHS["events"], params or None)

    def feed_full(self, **params: Any) -> Any:
        """Whole current feed. NOTE: this is a **baseline reset** — it rewrites
        the key's `feed_seen` rows server-side, so the next /feed/changes
        reports deltas against this pull, not against the previous one. Not a
        poll; use feed_changes() for the 10-minute cadence."""
        return self._request(FEED_PATHS["feed_full"], params or None)

    def feed_changes(self, *, dry_run: bool = False, **params: Any) -> Any:
        """Deltas since the key's baseline: added / changed / removed.

        Advances the baseline unless `dry_run`. This is the correct polling
        call — reconciled exactly against the sample scans (see
        docs/evenuedesk_feed_mapping.md §6). Pass dry_run=True for any ad-hoc
        look so you don't consume the scheduled poller's deltas.
        """
        if dry_run:
            params["dry_run"] = "true"
        return self._request(FEED_PATHS["feed_changes"], params or None)
