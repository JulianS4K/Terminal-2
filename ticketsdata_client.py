"""TicketsData unified ticket-inventory API client (read-only).

Host: https://ticketsdata.com
Aggregates live inventory + pricing across 9 marketplaces (Ticketmaster,
StubHub, SeatGeek, VividSeats, Gametime, TickPick, Viagogo, Dice, Eventbrite)
behind a single GET API. There is NO write surface — every endpoint is a
read — so this honors the read-only-upstream contract (CLAUDE.md §2).

Auth: account email + password are passed as query params (their scheme).
Credentials are sourced from env (TICKETSDATA_USERNAME / TICKETSDATA_PASSWORD),
never hardcoded, and never written to logs or exception messages — the URL is
built only at request time and never rendered with its params.

Credit cost (watch the budget — see scripts/ticketsdata_mvp.py):
  GET /fetch    1 credit    one event's inventory on one platform
  GET /events   1 credit    performer / venue -> upcoming event list
  GET /match    12 credits + 1 Market-Intelligence report   (Pro plan+)

/fetch and /events responses carry `quota_remaining`; /match also carries
`reports_remaining`. Callers should watch both to avoid exhausting the plan.
"""
from __future__ import annotations

import os
import time
from typing import Any

import requests


# Read-only by design. Mirrors the RULE 2 guard pattern used by the orders/
# sales clients (evo/seatgeek/tickpick/vivid). TicketsData has no write
# endpoint at all, but we enforce GET-only at the transport layer anyway.
ALLOWED_HTTP_METHODS = frozenset({"GET"})

SUPPORTED_PLATFORMS = frozenset({
    "ticketmaster", "stubhub", "seatgeek", "vividseats", "gametime",
    "tickpick", "viagogo", "dice", "eventbrite",
})

# Credit cost per endpoint, per the TicketsData docs. Used by callers and the
# MVP budget guard to project spend BEFORE making a call.
CREDIT_COST = {"fetch": 1, "events": 1, "match": 12}


class TicketsDataError(RuntimeError):
    pass


class TicketsDataReadOnlyError(TicketsDataError):
    """Raised when a non-GET method is attempted against TicketsData."""


class TicketsDataAuthError(TicketsDataError):
    """401 — bad credentials."""


class TicketsDataQuotaError(TicketsDataError):
    """402 — plan quota exhausted."""


def _assert_readonly_method(method: str) -> None:
    if method.upper() not in ALLOWED_HTTP_METHODS:
        raise TicketsDataReadOnlyError(
            f"READ-ONLY violation: method {method} is not allowed. "
            "TicketsData client is read-only by design (CLAUDE.md §2). "
            "Pulling data only — never write back to ticketsdata.com."
        )


class TicketsDataClient:
    BASE_URL = "https://ticketsdata.com"

    def __init__(self, username: str, password: str, *, timeout: int = 30):
        if not username or not password:
            raise TicketsDataError(
                "TicketsData credentials are required "
                "(set TICKETSDATA_USERNAME / TICKETSDATA_PASSWORD)"
            )
        self._username = username.strip()
        self._password = password  # never stripped/logged; sent verbatim
        self.timeout = timeout

    @classmethod
    def from_env(cls, *, timeout: int = 30) -> "TicketsDataClient":
        return cls(
            os.environ.get("TICKETSDATA_USERNAME", ""),
            os.environ.get("TICKETSDATA_PASSWORD", ""),
            timeout=timeout,
        )

    # ---------- transport ----------

    def _get(self, path: str, params: dict | None = None) -> dict[str, Any]:
        _assert_readonly_method("GET")
        url = f"{self.BASE_URL}{path}"
        # Credentials live in params, never in the logged/raised URL string.
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        clean["username"] = self._username
        clean["password"] = self._password

        # Per docs: retry 429 (back off), 503 (service_unavailable) and 504
        # (timeout); do NOT retry 400/401/402/404 (deterministic).
        r = None
        delays = [1.5, 3.0]
        for attempt in range(len(delays) + 1):
            r = requests.get(url, params=clean, timeout=self.timeout)
            if r.status_code in (429, 503, 504) and attempt < len(delays):
                retry_after = r.headers.get("Retry-After")
                try:
                    delay = float(retry_after) if retry_after else delays[attempt]
                except (TypeError, ValueError):
                    delay = delays[attempt]
                time.sleep(min(delay, 30.0))
                continue
            break

        if r.status_code == 401:
            raise TicketsDataAuthError("HTTP 401 — invalid TicketsData credentials")
        if r.status_code == 402:
            raise TicketsDataQuotaError("HTTP 402 — plan quota exhausted")
        if not r.ok:
            # Surface the path + status only — never the credential-bearing URL.
            raise TicketsDataError(f"HTTP {r.status_code} on GET {path}")
        try:
            body = r.json()
        except ValueError:
            return {"raw_text": r.text}
        return body if isinstance(body, dict) else {"body": body}

    # ---------- endpoints ----------

    def fetch(self, platform: str, event_url: str, *, mode: str | None = None) -> dict[str, Any]:
        """GET /fetch — full live inventory for one event on one platform.
        Cost: 1 credit. `mode` is platform-specific (see docs mode matrix)."""
        plat = (platform or "").strip().lower()
        if plat not in SUPPORTED_PLATFORMS:
            raise TicketsDataError(
                f"unsupported platform {platform!r}; one of {sorted(SUPPORTED_PLATFORMS)}"
            )
        if not event_url:
            raise TicketsDataError("event_url is required for /fetch")
        return self._get("/fetch", {"platform": plat, "event_url": event_url, "mode": mode})

    def events(
        self,
        platform: str,
        *,
        performer_url: str | None = None,
        venue_url: str | None = None,
    ) -> dict[str, Any]:
        """GET /events — upcoming events for a performer/venue/organizer page.
        Cost: 1 credit. Dice.fm venue/promoter pages use venue_url."""
        plat = (platform or "").strip().lower()
        if plat not in SUPPORTED_PLATFORMS:
            raise TicketsDataError(
                f"unsupported platform {platform!r}; one of {sorted(SUPPORTED_PLATFORMS)}"
            )
        if not performer_url and not venue_url:
            raise TicketsDataError("one of performer_url / venue_url is required for /events")
        return self._get(
            "/events",
            {"platform": plat, "performer_url": performer_url, "venue_url": venue_url},
        )

    def match(self, event_url: str) -> dict[str, Any]:
        """GET /match — cross-market arbitrage report (Pro plan+).
        Cost: 12 credits + 1 Market-Intelligence report. The engine
        auto-detects the source platform from the URL, so no platform arg."""
        if not event_url:
            raise TicketsDataError("event_url is required for /match")
        return self._get("/match", {"event_url": event_url})
