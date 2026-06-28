"""SeatData API client — second pricing source alongside TEvo.

HARD-CODED to the BASIC plan budget (100 paid pulls/day, 2000/month).
Going over those caps requires bumping BOTH this file's constants AND
the corresponding values in migration 20260509060000. Two-key change so
accidental overage is unlikely.

Endpoints implemented (per /sd.pdf doc):

  Free / metadata:
    GET  /v1/account                    identity + plans + rate_limits catalog
    GET  /v1/usage                      current billing-period totals
    GET  /v1/events/search              event metadata search (cursor pagination)
    POST /v0.4/events/event-request-add async event-add by query string
    GET  /v0.4/events/event-request-status/{job_id}
    GET  /v0.5/daily-csv/download       daily catalog CSV

  Paid (charge 1 pull/event, with freshness rule):
    GET  /v1/events/{event_id}/stats    pricing time series (free if no new snapshot)
    GET  /v0.3/salesdata/get            sold listings history
    GET  /v0.1.1/listings/get           live listings (free if no refresh)

Auth: Authorization: Bearer <SEATDATA_API_KEY> from env.

Budget enforcement:
    1. Every paid call first invokes RPC seatdata_check_budget()
    2. If allowed, makes the HTTP call
    3. On success, calls seatdata_increment_budget() with was_charged
       derived from response signal (has_refreshed for listings,
       freshness rule for stats, always-charged for salesdata)
    4. Logs to seatdata_pull_log

429 backoff: respects Retry-After header; exponential backoff with
jitter on consecutive 429s. Caps at 60s sleep.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import os
import random
import time
from datetime import datetime, timezone
from typing import Any, Iterator

import requests

from core.http_retry import fetch_with_retry
from core.vault import vault_secret

from supabase import Client

API_BASE = "https://seatdata.io/api"

# RULE 2 — READ-ONLY across all SeatData surfaces.
# v0.4 has a POST event-add endpoint — that's a request to add an event
# to SeatData's catalog (NOT writing OUR data anywhere external). It's
# the only POST we allow because it doesn't push our data — it requests
# coverage. Everything else is GET.
# NOTE: ALLOWED_HTTP_METHODS uses "POST" (not a sentinel) because the guard
# function is called with the real HTTP method string ("POST"), not a
# route-specific label. POST is additionally path-scoped: the guard raises on
# any POST whose path is not in SANCTIONED_POST_PATHS, so the carve-out is
# enforced mechanically, not by call-site discipline.
ALLOWED_HTTP_METHODS = frozenset({"GET", "POST"})

# The ONLY path POST may ever target. Adding a path here is a security-CRIT
# change (CLAUDE.md §2) and requires explicit operator authorization.
SANCTIONED_POST_PATHS = frozenset({"v0.4/events/event-request-add"})


def _assert_readonly_method(method: str, path: str | None = None) -> None:
    """Hard guard: SeatData reads are always GET except for the event-add
    request endpoint (/v0.4/events/event-request-add), which is metadata-only.
    Any other write method (PUT, DELETE, PATCH) is a bug and raises, as is a
    POST to any path other than the sanctioned event-add endpoint."""
    if method.upper() not in ALLOWED_HTTP_METHODS:
        raise SeatDataError(
            f"READ-ONLY violation: method {method} is not allowed. "
            "SeatData integration is strictly read-only (RULE 2 in SCHEMA.md). "
            "The only POST we use is /v0.4/events/event-request-add (metadata only)."
        )
    if method.upper() == "POST":
        normalized = (path or "").strip().lstrip("/").split("?", 1)[0]
        if normalized not in SANCTIONED_POST_PATHS:
            raise SeatDataError(
                f"READ-ONLY violation: POST to {path!r} is not sanctioned. "
                "SeatData POST is scoped to /v0.4/events/event-request-add "
                "only (RULE 2 / CLAUDE.md §2 listing-source lockdown)."
            )

# === BASIC-PLAN HARD CAPS — DO NOT BUMP WITHOUT UPDATING MIGRATION ===
# Both values are also persisted in seatdata_pull_budget table defaults.
# If we move plans, change BOTH this file AND the migration in the same
# commit. SCHEMA.md RULE 0: any new data source has to be documented
# in the same commit as the schema change.
BASIC_PLAN_DAILY_PAID_CAP = 100
BASIC_PLAN_MONTHLY_PAID_CAP = 2000

# Per-minute rate limits (advisory; server is authoritative via headers)
BASIC_PLAN_RATE_LIMITS = {
    "account":        {"limit": 60,  "window": 60},
    "usage":          {"limit": 60,  "window": 60},
    "events_search":  {"limit": 6,   "window": 60},
    "salesdata":      {"limit": 500, "window": 60},
    "listings":       {"limit": 500, "window": 60},
    "events_stats":   {"limit": 300, "window": 60},
    "daily_csv":      {"limit": 10,  "window": 3600},
}

# Endpoint paths -> billing classification
PAID_ENDPOINTS = {
    "v0.3/salesdata/get",       # always charged when rows returned
    "v0.1.1/listings/get",      # charged only when has_refreshed=1
    "v1/events_stats",          # charged only when freshness rule says so
}


class SeatDataError(Exception):
    pass


class BudgetExceeded(SeatDataError):
    pass


class SeatDataClient:
    def __init__(self, api_key: str | None = None, db: Client | None = None,
                 timeout_s: int = 30):
        # Key resolution order:
        #   1. Explicit api_key argument (one-off scripts / tests)
        #   2. SEATDATA_API_KEY env var (Railway-style override)
        #   3. Supabase Vault via public.get_app_secret('SEATDATA_API_KEY')
        # Vault is preferred — keys live in one place, rotation is a single
        # vault.update_secret() call, no Railway redeploy required.
        self.db = db
        self.api_key = api_key or os.environ.get("SEATDATA_API_KEY") or vault_secret(
            db, "SEATDATA_API_KEY",
            on_error=lambda e: print(f"seatdata: vault lookup failed: {e}"),
        )
        if not self.api_key:
            raise SeatDataError(
                "SEATDATA_API_KEY not found. "
                "Either set the env var, or store it in Supabase Vault: "
                "SELECT vault.create_secret('<key>', 'SEATDATA_API_KEY'); "
                "Whitelist is in public.get_app_secret() — add new key names there."
            )
        self.timeout_s = timeout_s
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {self.api_key}",
            "User-Agent": "Terminal-2/1.0 (broker terminal)",
        })

    # ---------- internal: HTTP + budget --------------------------------

    def _check_budget(self) -> dict:
        """Returns the allowed/used/cap envelope from the DB. Raises if no DB."""
        if not self.db:
            # Allow the call but warn — DB not wired in (e.g. one-off CLI test).
            # The budget is a defense-in-depth layer; SeatData itself caps at
            # whatever plan we have.
            return {"allowed": True, "used": -1, "daily_cap": BASIC_PLAN_DAILY_PAID_CAP,
                    "monthly_used": -1, "monthly_cap": BASIC_PLAN_MONTHLY_PAID_CAP,
                    "reason": "no_db_attached"}
        res = self.db.rpc("seatdata_check_budget", {"p_endpoint": "paid"}).execute()
        return res.data or {}

    def _increment_budget(self, endpoint: str, was_charged: bool) -> None:
        if not self.db:
            return
        try:
            self.db.rpc("seatdata_increment_budget", {
                "p_endpoint": endpoint, "p_was_charged": was_charged
            }).execute()
        except Exception as e:
            # Budget tracking is best-effort; never block a successful pull.
            print(f"seatdata: budget increment failed for {endpoint}: {e}")

    def _log_pull(self, endpoint: str, tevo_event_id: int | None,
                  sd_event_id: int | None, was_charged: bool,
                  http_status: int, rows_returned: int | None,
                  error_message: str | None, request_meta: dict | None = None) -> None:
        if not self.db:
            return
        try:
            self.db.table("seatdata_pull_log").insert({
                "endpoint": endpoint,
                "tevo_event_id": tevo_event_id,
                "sd_event_id": sd_event_id,
                "was_charged": was_charged,
                "http_status": http_status,
                "rows_returned": rows_returned,
                "error_message": error_message,
                "request_meta": request_meta or {},
            }).execute()
        except Exception as e:
            print(f"seatdata: pull log failed: {e}")

    def _request(self, method: str, path: str, *, params: dict | None = None,
                 json_body: dict | None = None, max_429_retries: int = 3,
                 expect_gzip: bool = False) -> tuple[int, dict | list | bytes, dict]:
        _assert_readonly_method(method, path)  # RULE 2 enforcement
        """Low-level HTTP. Returns (status, parsed_json, response_headers).
        Handles 429 with exponential backoff respecting Retry-After.
        """
        url = f"{API_BASE}/{path.lstrip('/')}"
        # Shared 429 retry loop (core/http_retry.py, BR-CODE-2). Retry-After →
        # capped exponential backoff + jitter; sleep + jitter passed as this
        # module's time.sleep / random.random so the monkeypatch tests bind.
        r = fetch_with_retry(
            lambda: self.session.request(method, url, params=params, json=json_body,
                                         timeout=self.timeout_s),
            max_retries=max_429_retries, retry_statuses=frozenset({429}),
            base_backoff=1.0, max_backoff=60.0, sleep=time.sleep, jitter=random.random,
        )
        # Some v0.x endpoints return gzipped JSON
        if r.status_code == 200 and expect_gzip:
            try:
                # requests/urllib3 already strips transport-level
                # Content-Encoding: gzip, so for that case r.content is
                # already plain bytes and calling gzip.decompress on it would
                # raise. The only gzip we must handle here is an
                # application-level gzipped body (served without that header).
                # Sniff the gzip magic bytes (1f 8b) instead of trusting the
                # header — correct whether the body arrives compressed or not.
                body = gzip.decompress(r.content) if r.content[:2] == b"\x1f\x8b" else r.content
                return r.status_code, json.loads(body), dict(r.headers)
            except Exception as e:
                # Don't echo `e` — gzip / json libraries can include
                # partial response bytes in their messages. Hardened
                # 2026-05-11.
                raise SeatDataError(f"failed to decode gzip JSON ({type(e).__name__})")
        try:
            return r.status_code, r.json(), dict(r.headers)
        except ValueError:
            return r.status_code, {"raw": r.text}, dict(r.headers)

    # ---------- v1: account / usage / search (free) --------------------

    def account(self) -> dict:
        status, body, _ = self._request("GET", "v1/account")
        if status != 200:
            raise SeatDataError(f"v1/account returned {status}: {body}")
        self._increment_budget("v1/account", was_charged=False)
        self._log_pull("v1/account", None, None, False, status, None, None)
        return body

    def usage(self) -> dict:
        status, body, _ = self._request("GET", "v1/usage")
        if status != 200:
            raise SeatDataError(f"v1/usage returned {status}: {body}")
        self._increment_budget("v1/usage", was_charged=False)
        self._log_pull("v1/usage", None, None, False, status, None, None)
        return body

    def search_events(self, *, event_name: str | None = None,
                      event_date: str | None = None,
                      venue_name: str | None = None,
                      venue_city: str | None = None,
                      venue_state: str | None = None,
                      country_code: str | None = None,
                      tm_event_id: str | None = None,
                      std_event_id: int | None = None,
                      std_venue_id: int | None = None,
                      venue_slug: str | None = None,
                      historical: bool = False,
                      limit: int = 100,
                      starting_after: str | None = None) -> dict:
        params = {k: v for k, v in {
            "event_name": event_name, "event_date": event_date,
            "venue_name": venue_name, "venue_city": venue_city,
            "venue_state": venue_state, "country_code": country_code,
            "tm_event_id": tm_event_id, "std_event_id": std_event_id,
            "std_venue_id": std_venue_id, "venue_slug": venue_slug,
            "historical": str(historical).lower(),
            "limit": min(int(limit), 200),
            "starting_after": starting_after,
        }.items() if v is not None}
        status, body, _ = self._request("GET", "v1/events/search", params=params)
        if status != 200:
            raise SeatDataError(f"v1/events/search returned {status}: {body}")
        self._increment_budget("v1/events/search", was_charged=False)
        rows = len(body.get("data") or []) if isinstance(body, dict) else 0
        self._log_pull("v1/events/search", None, None, False, status, rows, None,
                       request_meta={"params": params})
        return body

    def search_events_iter(self, **kwargs) -> Iterator[dict]:
        """Auto-paginate through search results."""
        starting_after = kwargs.pop("starting_after", None)
        while True:
            page = self.search_events(starting_after=starting_after, **kwargs)
            for item in (page.get("data") or []):
                yield item
            if not page.get("has_more"):
                break
            starting_after = page.get("next_cursor")
            if not starting_after:
                break

    # ---------- paid endpoints with budget enforcement ------------------

    def _ensure_budget_or_raise(self) -> dict:
        budget = self._check_budget()
        if not budget.get("allowed"):
            raise BudgetExceeded(
                f"SeatData budget exhausted: {budget.get('reason')} "
                f"(used {budget.get('used')}/{budget.get('daily_cap')} today, "
                f"{budget.get('monthly_used')}/{budget.get('monthly_cap')} this month)"
            )
        return budget

    def event_stats(self, sd_event_id: int, *, tevo_event_id: int | None = None,
                    start_date: str | None = None, end_date: str | None = None,
                    limit: int = 100, starting_after: str | None = None) -> dict:
        """Paid: 1 pull per event (subject to freshness rule on cursor=None pages)."""
        is_continuation = bool(starting_after)
        if not is_continuation:
            self._ensure_budget_or_raise()
        params = {k: v for k, v in {
            "start_date": start_date, "end_date": end_date,
            "limit": min(int(limit), 200), "starting_after": starting_after,
        }.items() if v is not None}
        status, body, _ = self._request("GET", f"v1/events/{int(sd_event_id)}/stats", params=params)
        if status == 200:
            rows = len(body.get("data") or []) if isinstance(body, dict) else 0
            # Charge only on first page (continuation pages are free per spec).
            # Even on first page, server may not charge (freshness rule). Without
            # a per-call billed flag, treat first-page-with-data as charged for
            # our internal counter — slight over-counting is preferred over
            # under-counting.
            charged = (not is_continuation) and (rows > 0)
            self._increment_budget("v1/events_stats", was_charged=charged)
            self._log_pull("v1/events_stats", tevo_event_id, sd_event_id, charged,
                           status, rows, None,
                           request_meta={"continuation": is_continuation})
            return body
        self._log_pull("v1/events_stats", tevo_event_id, sd_event_id, False,
                       status, None, str(body)[:500])
        raise SeatDataError(f"v1/events/{sd_event_id}/stats returned {status}: {body}")

    def salesdata(self, sd_event_id: int, *, tevo_event_id: int | None = None) -> list:
        """Paid: 1 pull per event. Always charged when rows are returned."""
        self._ensure_budget_or_raise()
        params = {"event_id": int(sd_event_id)}
        status, body, _ = self._request("GET", "v0.3/salesdata/get",
                                        params=params, expect_gzip=True)
        if status == 200:
            rows_returned = len(body) if isinstance(body, list) else 0
            charged = rows_returned > 0
            self._increment_budget("v0.3/salesdata/get", was_charged=charged)
            self._log_pull("v0.3/salesdata/get", tevo_event_id, sd_event_id,
                           charged, status, rows_returned, None)
            return body if isinstance(body, list) else []
        self._log_pull("v0.3/salesdata/get", tevo_event_id, sd_event_id, False,
                       status, None, str(body)[:500])
        raise SeatDataError(f"v0.3/salesdata/get returned {status}: {body}")

    def listings(self, sd_event_id: int, *, tevo_event_id: int | None = None) -> dict:
        """Paid: 1 pull per event ONLY when has_refreshed=1."""
        self._ensure_budget_or_raise()
        params = {"event_id": int(sd_event_id)}
        status, body, _ = self._request("GET", "v0.1.1/listings/get",
                                        params=params, expect_gzip=True)
        if status == 200:
            has_refreshed = bool(body.get("has_refreshed")) if isinstance(body, dict) else False
            rows_returned = len((body or {}).get("listings") or []) if isinstance(body, dict) else 0
            self._increment_budget("v0.1.1/listings/get", was_charged=has_refreshed)
            self._log_pull("v0.1.1/listings/get", tevo_event_id, sd_event_id,
                           has_refreshed, status, rows_returned, None)
            return body if isinstance(body, dict) else {}
        self._log_pull("v0.1.1/listings/get", tevo_event_id, sd_event_id, False,
                       status, None, str(body)[:500])
        raise SeatDataError(f"v0.1.1/listings/get returned {status}: {body}")

    # ---------- async event-add (free) -----------------------------------

    def event_request_add(self, search_query: str) -> dict:
        if len(search_query) > 200:
            raise SeatDataError("search_query must be <= 200 chars")
        status, body, _ = self._request("POST", "v0.4/events/event-request-add",
                                        json_body={"search_query": search_query})
        if status not in (200, 202):
            raise SeatDataError(f"event-request-add returned {status}: {body}")
        self._increment_budget("v0.4/event-request-add", was_charged=False)
        self._log_pull("v0.4/event-request-add", None, None, False, status, None, None)
        return body

    def event_request_status(self, job_id: str) -> dict:
        status, body, _ = self._request("GET", f"v0.4/events/event-request-status/{job_id}")
        if status not in (200, 404):
            raise SeatDataError(f"event-request-status returned {status}: {body}")
        return body

    # ---------- DB persistence helpers -----------------------------------

    @staticmethod
    def _hash_row(*parts: Any) -> str:
        joined = "|".join("" if p is None else str(p) for p in parts)
        return hashlib.sha256(joined.encode("utf-8")).hexdigest()[:32]

    def store_sales(self, tevo_event_id: int, sd_event_id: int, sales: list) -> int:
        """Insert sales rows into seatdata_sales_snapshots, deduped via content_hash.
        Returns count of newly-inserted rows."""
        if not self.db or not sales:
            return 0
        rows = []
        for s in sales:
            ts = s.get("timestamp")
            # Coerce epoch-as-string too ("1620000000"): JSON feeds often send
            # numeric timestamps as strings, and the old isinstance-only check
            # stored them verbatim — a non-ISO value in sale_timestamp that also
            # made content_hash unstable vs the int form (breaking dedup).
            if isinstance(ts, (int, float)) or (isinstance(ts, str) and ts.strip().isdigit()):
                sale_ts = datetime.fromtimestamp(int(ts), tz=timezone.utc).isoformat()
            else:
                sale_ts = str(ts) if ts else None
            content_hash = self._hash_row(sale_ts, s.get("quantity"), s.get("price"),
                                          s.get("zone"), s.get("section"), s.get("row"))
            rows.append({
                "tevo_event_id": tevo_event_id, "sd_event_id": sd_event_id,
                "sale_timestamp": sale_ts, "quantity": s.get("quantity"),
                "price": s.get("price"), "zone": s.get("zone"),
                "section": s.get("section"), "row": s.get("row"),
                "content_hash": content_hash,
            })
        try:
            res = self.db.table("seatdata_sales_snapshots").upsert(
                rows, on_conflict="tevo_event_id,content_hash"
            ).execute()
            return len(res.data or [])
        except Exception as e:
            print(f"seatdata: store_sales failed: {e}")
            return 0

    def link_event(self, tevo_event_id: int, sd_event_id: int, *,
                   match_method: str = "manual", confidence: float | None = None,
                   meta: dict | None = None) -> None:
        if not self.db:
            return
        self.db.table("seatdata_event_xref").upsert({
            "tevo_event_id": tevo_event_id,
            "sd_event_id": sd_event_id,
            "match_method": match_method,
            "match_confidence": confidence,
            "meta": meta or {},
        }, on_conflict="tevo_event_id").execute()
