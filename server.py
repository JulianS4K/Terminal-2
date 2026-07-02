"""Evo Terminal FastAPI app.

Auth: Google OAuth via Supabase, restricted to a configurable email domain.
Data: Reads TEvo creds from Supabase `settings` table (env var fallback).

Env vars required:
  SUPABASE_URL                 e.g. https://xxxx.supabase.co
  SUPABASE_SERVICE_ROLE_KEY    Dashboard > Settings > API > service_role
  SUPABASE_ANON_KEY            Dashboard > Settings > API > anon public
  CRON_SECRET                  shared with the collect Edge Function
Optional:
  ALLOWED_EMAIL_DOMAIN         default "s4kent.com"
  TEVO_SANDBOX                 "true" to hit sandbox API (default false)
  AUTH_DISABLED                "true" to bypass auth (local dev only)
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import re
import secrets
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

import requests
from fastapi import BackgroundTasks, Body, Depends, FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware

import render_webhook
from evo_client import EvoClient

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")


# ---------- Storefront asset cache-busting ----------
#
# Browsers happily hold the storefront's store.js + style.css forever
# unless the URL changes. Until Sprint 5 ships content-hashed filenames
# + Cache-Control headers, we append `?v=<short-sha>` to each asset
# reference inside the served HTML so every deploy invalidates the
# browser cache. Without this, frontend changes in a D1 PR can appear
# "not deployed" from the operator's perspective for hours after the
# actual merge — see Round 4 of docs/d1-bot-continues-here audit.

# _build_storefront_version + _build_storefront_base_url (+ the computed
# _STOREFRONT_VERSION / _STOREFRONT_BASE_URL) -> core/config.py (BR-CODE-1
# config seam). Imported (aliased) near the top of this module.
_STOREFRONT_HTML_CACHE: dict[str, str] = {}


# ---------- Speculative-event filter ----------
#
# Consumer storefront should NOT surface tickets whose names mark them as
# games that may NEVER happen — playoff "(If Necessary)" series-extenders,
# plus already-CANCELLED games. We hold inventory for these as brokers (they
# can be valuable IF the game happens) but they're a bad consumer-checkout
# experience because the event may be voided.
#
# IMPORTANT: "(Date TBD)" + "Date and Time TBD" are NOT included — those
# games ARE happening, the date just isn't confirmed yet. The existing
# `tbd` badge on the storefront card surfaces them with a clear warning
# (see _is_tbd() + the test_home_tbd_detected_from_name test).
#
# sg_classify_events() already gates these out of broker tier-polling per
# the 20260516030000 migration. The consumer storefront search/movers/home
# queries don't share that classification, so we filter at the app layer
# using a name substring scan. Patterns are case-insensitive.
#
# Railway audit 2026-05-16 found "(If Necessary)" games leaking into
# /api/store/search?q=knicks and /api/store/movers — surfaced as bookable
# on the consumer storefront despite the broker tier already marking them
# SKIP. CANCELLED was already filtered at 3 app-layer call sites; this
# helper consolidates + adds (If Necessary).
# _SPECULATIVE_NAME_PATTERNS + _is_speculative_event_name -> core/helpers.py
# (BR-CODE-1 leaf-helper pass). Imported (aliased) below.


# Storefront HTML shell rendering + cache moved to core/storefront_html.py
# (BR-CODE-1 core/ pass). Thin wrappers pass the live deploy identity + cache so
# the tests (which call app._read_storefront_html / app._render_storefront_page
# directly and mutate app._STOREFRONT_HTML_CACHE / patch app._STOREFRONT_VERSION)
# keep binding; signatures unchanged for the storefront-pages router getter.
def _read_storefront_html(name: str) -> str:
    return _ce_read_storefront_html(
        name, static_dir=STATIC_DIR, version=_STOREFRONT_VERSION,
        base_url=_STOREFRONT_BASE_URL, cache=_STOREFRONT_HTML_CACHE,
    )


def _render_storefront_page(name: str) -> HTMLResponse:
    # Builds the response from the SERVER _read_storefront_html wrapper (not
    # core's read directly) so the app._read_storefront_html monkeypatch binds.
    return HTMLResponse(
        content=_read_storefront_html(name),
        headers={"Cache-Control": "no-cache, must-revalidate"},
    )


# ---------- Bootstrap ----------

# Runtime config moved to core/config.py (BR-CODE-1 core extraction); imported
# here so existing `app.<NAME>` reads + the test monkeypatches keep working.
# The auth kill-switch (AUTH_DISABLED / _is_production) stays below — it's part
# of the auth gate (require_auth).
from core.config import (  # noqa: E402
    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY, CRON_SECRET,
    ALLOWED_EMAIL_DOMAIN, STOREFRONT_SQL_ONLY, STOREFRONT_SEARCH_SQL_ONLY,
    STOREFRONT_PREFER_INTERNAL_ZONES, STOREFRONT_RESERVE_REQUIRES_AUTH,
    STOREFRONT_CHECKOUT_DOMAIN, STOREFRONT_CHECKOUT_DISABLED,
    RECAPTCHA_SITE_KEY, RECAPTCHA_ENABLED,
)
# Storefront deploy identity -> core/config.py (BR-CODE-1 config seam). Aliased
# to the historical `_`-prefixed names so consumers + the test monkeypatch
# (app._STOREFRONT_VERSION) + the direct test calls (app._build_storefront_version)
# all keep resolving the app-module binding.
from core.config import (  # noqa: E402
    build_storefront_version as _build_storefront_version,
    build_storefront_base_url as _build_storefront_base_url,
    STOREFRONT_VERSION as _STOREFRONT_VERSION,
    STOREFRONT_BASE_URL as _STOREFRONT_BASE_URL,
)

# Observability: configure structured stdout logging + (opt-in) Sentry error
# tracking. No-op for Sentry until the operator sets SENTRY_DSN. Run at import
# so every code path logs through one configured handler.
from core.observability import init_observability  # noqa: E402
_OBSERVABILITY = init_observability()
_log = logging.getLogger("app")

# Auth gate moved to core/auth.py (BR-CODE-1 core extraction): require_auth +
# the AUTH_DISABLED kill-switch + _is_production. Imported so existing
# `app.<NAME>` reads keep working; require_auth reads its deps from core
# (one-directional import). The security tests force the gate ON by patching
# `core.auth.AUTH_DISABLED`.
from core.auth import require_auth, AUTH_DISABLED, _is_production  # noqa: E402
from core.auth import require_cron_or_auth as _require_cron_or_auth  # noqa: E402
# Human bot-gate cookie helpers -> core/auth.py (BR-CODE-1 config/auth seam),
# aliased to their historical `_`-prefixed names so consumers keep resolving.
from core.auth import (  # noqa: E402
    issue_human_token as _issue_human_token,
    valid_human_token as _valid_human_token,
    verify_recaptcha as _verify_recaptcha,
    HUMAN_COOKIE_NAME as _HUMAN_COOKIE_NAME,
    HUMAN_TTL_SECONDS as _HUMAN_TTL_SECONDS,
)

# Helpers moved to core/ (BR-CODE-1 helper pass). Aliased to the historical
# `_`-prefixed names so every call site + the route tests' monkeypatch
# (app._bulk_performer_assets) keep resolving the app-module binding.
from core.helpers import classify_playoff as _classify_playoff, _PLAYOFF_SPECIFIC_RE  # noqa: E402
from core.helpers import (  # noqa: E402
    or_ilike_clause as _or_ilike_clause,
    is_speculative_event_name as _is_speculative_event_name,
    classify_world_cup as _classify_world_cup,
)
from core.broker_helpers import bulk_performer_assets as _bulk_performer_assets  # noqa: E402
from core.broker_helpers import bulk_event_context as _bulk_event_context  # noqa: E402
from core.movers import compute_movers as _compute_movers  # noqa: E402
from core.search import (  # noqa: E402
    search_sql_only as _search_sql_only,
    search_cache_get as _ce_search_cache_get,
    search_cache_put as _ce_search_cache_put,
    search_players as _ce_search_players,
    search_live as _ce_search_live,
)
from core.helpers import clean_opt_url as _clean_opt_url  # noqa: E402
from core.helpers import tevo_runtime_to_http as _tevo_runtime_to_http  # noqa: E402
from core.helpers import normalize_filters as _normalize_filters  # noqa: E402
from core.helpers import ticket_group_to_listing as _ticket_group_to_listing  # noqa: E402
from core.helpers import parse_iso_or_none as _parse_iso_or_none  # noqa: E402
from core.helpers import to_int_or_none as _to_int_or_none  # noqa: E402
from core.helpers import to_num_or_none as _to_num_or_none  # noqa: E402
from core.helpers import haversine_miles as _haversine_miles  # noqa: E402
from core.discovery import attach_owned_metadata as _ce_attach_owned_metadata  # noqa: E402
from core.trip_payloads import (  # noqa: E402
    trip_plan_payload as _ce_trip_plan_payload,
    tour_package_payload as _ce_tour_package_payload,
    multi_tour_payload as _ce_multi_tour_payload,
    discover_payload as _ce_discover_payload,
)
from core.ingest import (  # noqa: E402
    fire_collect as _ce_fire_collect,
    upsert_tevo_event_into_events as _ce_upsert_tevo_event_into_events,
    flatten_order as _ce_flatten_order,
)
from core.storefront_html import read_storefront_html as _ce_read_storefront_html  # noqa: E402
from core.canonical_refresh import fire_canonical_refresh as _ce_fire_canonical_refresh  # noqa: E402
from core.helpers import venue_tokens as _venue_tokens  # noqa: E402
from core.helpers import venue_overlap as _venue_overlap  # noqa: E402
from core.helpers import is_event_seat as _is_event_seat  # noqa: E402
from core.helpers import clean_section as _clean_section  # noqa: E402
from core.helpers import movers_cache_key as _movers_cache_key  # noqa: E402
from core.helpers import normalize_search_key as _normalize_search_key  # noqa: E402
from core.helpers import is_tbd as _is_tbd  # noqa: E402
from core.helpers import section_sort_key as _section_sort_key  # noqa: E402
from core.helpers import is_bowl_pattern_name as _is_bowl_pattern_name  # noqa: E402
from core.helpers import tour_dates as _tour_dates  # noqa: E402
from core.helpers import share_to_dict as _share_to_dict  # noqa: E402
from core.helpers import flatten_order_items as _flatten_order_items  # noqa: E402

# (storefront-mode flags + reCAPTCHA config moved to core/config.py — imported
# at the top of this bootstrap block, BR-CODE-1 core extraction.)

# _HUMAN_COOKIE_SECRET + _HUMAN_COOKIE_NAME + _HUMAN_TTL_SECONDS +
# _issue_human_token + _valid_human_token -> core/auth.py (BR-CODE-1 config/auth
# seam). Imported (aliased) near the top of this module.


# _verify_recaptcha -> core/auth.py (BR-CODE-1 config/auth seam; pairs with the
# human-token bot gate). Imported (aliased) near the top of this module.


def _require_human(request: Request, payload: dict | None = None):
    """Gate a write/spam endpoint behind the human check. No-op when the gate is
    dormant. Accepts a valid vp_human cookie OR a fresh reCAPTCHA token in the
    request body ('recaptcha_token'); otherwise 403. Also runs the always-on
    honeypot check (a non-empty 'hp' field => silently treat as a bot)."""
    # Honeypot — always on, even when reCAPTCHA is dormant. A hidden field no
    # human ever fills; bots that auto-fill inputs trip it.
    if payload and str(payload.get("hp") or "").strip():
        raise HTTPException(400, "invalid request")
    if not RECAPTCHA_ENABLED:
        return
    if _valid_human_token(request.cookies.get(_HUMAN_COOKIE_NAME)):
        return
    token = (payload or {}).get("recaptcha_token")
    xff = request.headers.get("x-forwarded-for") or ""
    ip = (xff.split(",")[-1].strip() if xff else (request.client.host if request.client else None))
    if _verify_recaptcha(token, "submit", ip):
        return
    raise HTTPException(403, "bot verification required — refresh the page and try again")

sb = None
if SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY:  # pragma: no cover - import-time guard; both env vars are always set when the module is imported under any supported config, so the false side is unreachable post-import
    try:
        # Bounded per-request timeout (core/db.py) so a Supabase blip fails fast
        # instead of piling up requests -> dyno OOM (production-readiness P0).
        from core.db import make_supabase_client
        sb = make_supabase_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    except ImportError:  # pragma: no cover - import-time dep-missing guard
        _log.warning("WARNING: supabase package not installed. Run: pip install supabase")
    except Exception as e:  # pragma: no cover - import-time init-failure guard
        _log.warning(f"WARNING: could not init Supabase client: {e}")


def require_sb():
    if sb is None:
        raise HTTPException(500, "Supabase not configured.")
    return sb


# Shared circuit breaker for Supabase reads (production-readiness P1 #4). Opens
# after consecutive failures so a Supabase outage fast-fails + sheds load instead
# of cascading; the storefront's safe_read paths fall back to a stale snapshot.
# Status is surfaced on /healthz. Tunable via env.
from core.resilience import CircuitBreaker, safe_read as _safe_read, resilient_call as _resilient_call  # noqa: E402

_db_breaker = CircuitBreaker(
    fail_threshold=int(os.environ.get("DB_CIRCUIT_FAIL_THRESHOLD", "5")),
    reset_timeout=float(os.environ.get("DB_CIRCUIT_RESET_SECONDS", "30")),
)


def safe_sb_read(fn, fallback, *, on_error=None):
    """Storefront stale-snapshot read: run `fn()` through the shared DB breaker,
    returning `fallback` (value or thunk) if the breaker is open or the read
    fails. Keeps a Supabase blip from 500-ing a customer-facing page."""
    return _safe_read(fn, fallback, breaker=_db_breaker, on_error=on_error)


def sb_read_or_raise(fn):
    """Active-query DB read: run `fn()` through the shared DB breaker with retry,
    but RE-RAISE on final failure (or CircuitOpenError when the breaker is open).
    For reads the caller wants to surface as an explicit error (e.g. search 502)
    rather than silently degrade to empty — while still shedding load via the
    breaker. Used by /api/store/search."""
    return _resilient_call(fn, breaker=_db_breaker)


def resolve_tevo_creds():
    """Prefer Supabase settings table, fall back to env vars.

    Env-var fallback accepts either naming convention:
      - `TEVO_TOKEN`     + `TEVO_SECRET`      (legacy)
      - `TEVO_API_TOKEN` + `TEVO_API_SECRET`  (what Render's IaC sets)

    Returns (token, secret, source). Source is one of:
      "supabase.settings" | "env" | "missing"
    """
    if sb is not None:
        try:
            res = (
                sb.table("settings")
                .select("key,value")
                .in_("key", ["tevo_token", "tevo_secret"])
                .execute()
            )
            by_key = {r["key"]: r["value"] for r in (res.data or [])}
            t = by_key.get("tevo_token")
            s = by_key.get("tevo_secret")
            if t and s:
                return t, s, "supabase.settings"
        except Exception as e:
            _log.warning(f"Could not load TEvo creds from settings: {e}")
    # Env fallback — accept either name convention.
    env_t = os.environ.get("TEVO_TOKEN") or os.environ.get("TEVO_API_TOKEN")
    env_s = os.environ.get("TEVO_SECRET") or os.environ.get("TEVO_API_SECRET")
    if env_t and env_s:
        return env_t, env_s, "env"
    return None, None, "missing"


def ensure_tevo_client():
    """Lazy-initialize the EvoClient if the boot-time attempt failed.

    Boot can fail to populate `client` when:
      - Supabase keys were stale at boot (resolve_tevo_creds raises silently)
      - Env vars were missing or mis-named
      - STOREFRONT_SQL_ONLY=true at boot, so we intentionally skipped the
        client creation, and now the operator wants to flip live

    Called from any request path that needs TEvo. Idempotent — returns
    the existing client when already populated. Re-resolves creds and
    builds the client on demand otherwise. Avoids forcing a redeploy
    every time creds change.
    """
    global client, TOKEN, SECRET, CREDS_SOURCE
    if client is not None:
        return client
    t, s, src = resolve_tevo_creds()
    if not (t and s):
        return None  # caller decides what to do; usually 502
    TOKEN, SECRET, CREDS_SOURCE = t, s, src
    client = EvoClient(TOKEN, SECRET, sandbox=SANDBOX)
    _log.info(f"TEvo client lazy-initialized (creds source: {src})")
    return client


SANDBOX = os.environ.get("TEVO_SANDBOX", "false").lower() == "true"
TOKEN, SECRET, CREDS_SOURCE = resolve_tevo_creds()
if not TOKEN or not SECRET:  # pragma: no cover - import-time missing-creds boot path
    # In SQL-only demo mode the storefront never calls TEvo — the EvoClient
    # is never invoked. Boot in degraded mode (no TEvo client) so the
    # storefront still serves from listings_snapshots. Any non-storefront
    # route that needs the live client (broker terminal, /api/admin/*) will
    # crash on the missing global, which is the right failure mode.
    if STOREFRONT_SQL_ONLY:
        _log.info(
            "TEvo creds missing — running in STOREFRONT_SQL_ONLY mode without a live "
            "EvoClient. /api/store/* routes will serve from listings_snapshots only."
        )
        client = None
    else:
        sys.exit(
            "No TEvo credentials found. Insert into Supabase `settings` table "
            "(tevo_token, tevo_secret) or set TEVO_TOKEN + TEVO_SECRET env vars. "
            "Or set STOREFRONT_SQL_ONLY=true to boot in demo mode without TEvo."
        )
else:
    _log.info(f"TEvo creds loaded from: {CREDS_SOURCE}")
    client = EvoClient(TOKEN, SECRET, sandbox=SANDBOX)


# ---------- Auth dependency ----------

# require_auth moved to core/auth.py (imported above, BR-CODE-1 core extraction).


# ---------- App setup ----------

app = FastAPI(title="Evo Terminal — data-only API (UI on rebuild)")

# CORS allowlist. CORS_ALLOWED_ORIGINS env var is a comma-separated list of
# origins; default permits local dev only. Added 2026-05-11 (security chat).
_CORS_ORIGINS = [
    o.strip()
    for o in (os.environ.get("CORS_ALLOWED_ORIGINS") or "http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000").split(",")
    if o.strip()
]
# Reject wildcards loudly at boot. CORS allow_credentials=True with a
# wildcard origin is a critical misconfiguration — browsers will send cookies
# + Authorization headers cross-origin to /api/store/reserve and friends.
# Fail-fast at startup rather than discover via security incident.
for _origin in _CORS_ORIGINS:
    if _origin == "*" or "*" in _origin:  # pragma: no cover - import-time CORS misconfig guard
        raise RuntimeError(
            f"CORS_ALLOWED_ORIGINS contains a wildcard ({_origin!r}); rejected because "
            "allow_credentials=True is incompatible with wildcard origins. List concrete "
            "https://… URLs in the env var instead."
        )
    if not (_origin.startswith("http://localhost") or _origin.startswith("http://127.0.0.1") or _origin.startswith("https://")):  # pragma: no cover - import-time CORS misconfig guard
        raise RuntimeError(
            f"CORS_ALLOWED_ORIGINS entry {_origin!r} is not a concrete http(s) URL. "
            "Localhost dev origins (http://localhost / http://127.0.0.1) and https://… origins are accepted."
        )
app.add_middleware(
    CORSMiddleware,
    allow_origins=_CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Cron-Secret"],
)


class _SecurityHeadersMiddleware(BaseHTTPMiddleware):
    """Emit baseline security headers on every response. The CSP is tight
    enough to block the inline-script + third-party-script vectors but
    permissive enough that the retail HTML keeps working (own-origin only).
    Added 2026-05-11 (security chat)."""

    _CSP = (
        "default-src 'self'; "
        "script-src 'self'; "
        "style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data: https:; "
        # maps.ticketevolution.com: the Tevomaps seat-map library fetches the
        # venue map.svg via connect (fetch/XHR), so it must be in connect-src.
        # The per-page <meta> CSP already allows it, but browsers enforce the
        # INTERSECTION of meta + this header — without it here the SVG fetch is
        # blocked and the storefront seat map renders blank. (The D0 terminal is
        # served from a static CDN that doesn't run this middleware, so only its
        # permissive meta CSP applied — which is why the terminal map worked and
        # the storefront map didn't.)
        "connect-src 'self' https://*.supabase.co https://maps.ticketevolution.com; "
        "frame-ancestors 'none'; "
        "base-uri 'self'; "
        "form-action 'self'"
    )

    # Storefront variant when the reCAPTCHA v3 gate is enabled: allow Google's
    # challenge script/frame. Scoped to /store paths + gated on RECAPTCHA_ENABLED
    # so terminal/home/bridge and the dormant case keep the tighter policy.
    _CSP_RECAPTCHA = (
        "default-src 'self'; "
        "script-src 'self' https://www.google.com https://www.gstatic.com; "
        "style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data: https:; "
        "connect-src 'self' https://www.google.com https://*.supabase.co https://maps.ticketevolution.com; "
        "frame-src https://www.google.com; "
        "frame-ancestors 'none'; "
        "base-uri 'self'; "
        "form-action 'self'"
    )

    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        csp = self._CSP
        if RECAPTCHA_ENABLED and request.url.path.startswith("/store"):
            csp = self._CSP_RECAPTCHA
        response.headers.setdefault("Content-Security-Policy", csp)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        response.headers.setdefault("X-Frame-Options", "DENY")
        # Permissions-Policy: deny powerful features by default. The Bridge
        # surface (/bridge/*) hosts the organizer door scanner, which needs
        # getUserMedia — without camera=(self) here the browser blocks the
        # camera and never even prompts for permission. Scope the allowance to
        # /bridge only; storefront/terminal stay camera=().
        if request.url.path.startswith("/bridge"):
            response.headers.setdefault(
                "Permissions-Policy", "geolocation=(), microphone=(), camera=(self)")
        else:
            response.headers.setdefault(
                "Permissions-Policy", "geolocation=(), microphone=(), camera=()")
        # HSTS: tell browsers to upgrade to HTTPS for this host for 2y +
        # include subdomains. Render terminates TLS at the proxy so the
        # response is always HTTPS-served regardless of how we send it.
        response.headers.setdefault(
            "Strict-Transport-Security",
            "max-age=63072000; includeSubDomains",
        )
        # Long-cache storefront static assets (D1-OPS-2). The HTML shells
        # reference them with a ?v=<sha> cache-bust, so a versioned request
        # is safe to pin for a year (immutable) — the next deploy serves a
        # new URL. Rare unversioned/direct hits get a short TTL so a deploy
        # isn't masked forever for them. HTML shells set their own
        # no-cache header (via _render_storefront_page) and aren't matched
        # here. setdefault() so a route that set its own Cache-Control wins.
        if (request.url.path.startswith("/static/store/")
                and response.status_code == 200):
            if request.query_params.get("v"):
                response.headers.setdefault(
                    "Cache-Control", "public, max-age=31536000, immutable")
            else:
                response.headers.setdefault("Cache-Control", "public, max-age=600")
        return response


app.add_middleware(_SecurityHeadersMiddleware)


# ---------- Per-IP rate limiter (added 2026-05-11 security chat) ----------
# In-process sliding-window limiter keyed by client IP + path-prefix bucket.
# Single-instance Railway deploy makes a process-local limiter sufficient.
# If you scale to >1 dyno, swap to Redis-backed slowapi or move to Cloudflare.
import time as _time
import time  # public alias for in-process caches that want time.time()
from collections import defaultdict as _dd, deque as _dq

class _IPRateLimiter:
    def __init__(self):
        self._hits: dict = _dd(_dq)
        self._lock = threading.Lock()

    def check(self, key: str, max_per_window: int, window_sec: float) -> bool:
        now = _time.monotonic()
        with self._lock:
            dq = self._hits[key]
            cutoff = now - window_sec
            while dq and dq[0] < cutoff:
                dq.popleft()
            if len(dq) >= max_per_window:
                return False
            dq.append(now)
            return True

# Pick the rate-limiter backend: Redis (multi-instance safe) when REDIS_URL is
# set + reachable, else the in-process limiter above (production-readiness P1 #5).
# Provision Redis + set REDIS_URL before scaling past 1 dyno — until then the
# in-process limiter is per-instance and bypassable.
from core.ratelimit import make_rate_limiter  # noqa: E402

_ip_limiter = make_rate_limiter(
    os.environ.get("REDIS_URL"),
    in_process_factory=_IPRateLimiter,
    log=_log.warning,
)


class _RateLimitMiddleware(BaseHTTPMiddleware):
    """Per-IP rate limit. Path-prefix buckets — most-specific match wins.
    Returns 429 with a brief retry hint. Hits are dropped after window."""

    # (path_prefix, max_calls, window_seconds)
    _BUCKETS: list = [
        ("/api/store/share/",   10,  60.0),  # POST/DELETE/GET-by-id — spam vector
        ("/api/store/shares",   60,  60.0),  # list endpoint
        ("/api/store/share",    10,  60.0),  # POST create
        ("/api/store/verify-human", 30, 60.0),  # bot gate — once per session, generous
        ("/api/store/reserve",  10,  60.0),  # mock reserve, but hits TEvo (tightened for demo)
        ("/api/store/",         60,  60.0),  # public catalog reads
        ("/api/config",         30,  60.0),  # auth-validates against Supabase per call
        ("/api/public/config", 120,  60.0),  # cheap, but worth a cap
        ("/api/admin/",          5,  60.0),  # admin write surface
    ]
    _DEFAULT = (200, 60.0)

    def _bucket(self, path: str):
        for prefix, n, w in self._BUCKETS:
            if path.startswith(prefix):
                return n, w
        return self._DEFAULT

    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        # Skip CORS preflight + healthcheck — preflights aren't load-bearing.
        # Render polls /healthz (render.yaml healthCheckPath) frequently from one
        # IP; exempt the REAL liveness path so those polls don't trip the per-IP
        # rate cap. (/health never existed as a route — A1-OPS-5.)
        if request.method == "OPTIONS" or path in ("/", "/healthz"):
            return await call_next(request)
        # Trust X-Forwarded-For when present (Render/Railway set it). Fall back
        # to request.client. Use the RIGHTMOST entry: that's the hop appended
        # by our own edge proxy and is the only one a client can't forge. The
        # leftmost entry is client-supplied — keying on it let a single client
        # rotate fake IPs and bypass every per-IP bucket (audit 2026-06-10).
        xff = request.headers.get("x-forwarded-for") or ""
        ip = (xff.split(",")[-1].strip() if xff else (request.client.host if request.client else "unknown")) or "unknown"
        n, w = self._bucket(path)
        # Key is ip + bucket-prefix, NOT the full path. Using the raw path lets
        # a bot cycle resource IDs (e.g. /api/store/events/1, /2, …) to get a
        # fresh bucket per resource and bypass the per-IP cap entirely.
        bucket_key = next(
            (pfx for pfx, _, _ in self._BUCKETS if path.startswith(pfx)),
            "*",
        )
        # The limiter is contractually non-raising (Redis backend degrades to
        # in-process / fail-open internally), but a rate-limit failure must
        # NEVER become an app outage — so wrap defensively and fail open on any
        # unexpected limiter error rather than 500 the request.
        try:
            allowed = _ip_limiter.check(f"{ip}|{bucket_key}", n, w)
        except Exception as e:  # noqa: BLE001 - a limiter fault must not take down the request path
            _log.warning("rate limiter check errored (%r); failing open", e)
            allowed = True
        if not allowed:
            return JSONResponse(
                {"error": "rate limited", "retry_after_seconds": int(w)},
                status_code=429,
                headers={"Retry-After": str(int(w))},
            )
        return await call_next(request)


app.add_middleware(_RateLimitMiddleware)


# (SMS / WhatsApp / web bot moved to Supabase Edge Functions in v2.7:
#  supabase/functions/sms-bot, web-bot, chat. The legacy bot.py is unused.)


@app.exception_handler(RuntimeError)
async def _runtime_error_handler(request, exc: RuntimeError):
    return JSONResponse(status_code=502, content={"error": str(exc)})


# ---------- Public routes (no auth) ----------
# Phase 1: data-collection only. UI is on full reboot — no HTML routes shipped.
# All previous /, /chat, /event, /movers, /preview/*, /terminal/v1, /legacy
# routes removed along with their static/*.html assets in the 2026-05-09
# UI rebuild prep. JSON API endpoints below remain available for whatever
# UI gets built next.

STOREFRONT_AS_LANDING = os.environ.get("STOREFRONT_AS_LANDING", "false").lower() == "true"

# Storefront "Ask the concierge" (retail-chat) kill-switch. Disabled for now to
# stop paid Anthropic spend on the public concierge (each turn fans out into a
# multi-call tool-use loop on Claude Haiku 4.5). When off, /api/store/retail-chat
# short-circuits with a friendly canned reply and never calls the chat edge fn.
# Re-enable by setting STOREFRONT_CONCIERGE_ENABLED=true (no code change needed).
STOREFRONT_CONCIERGE_ENABLED = os.environ.get("STOREFRONT_CONCIERGE_ENABLED", "false").lower() == "true"


# Static page-server routes (/, /home[/], /terminal[/...], /undelivered,
# /bridge[/...], /version.json) live in routers/pages.py (BR-CODE-1 decomp).
# Getters resolve the two test-patched server symbols at request time so the
# route tests (which monkeypatch app.STOREFRONT_AS_LANDING / app._STOREFRONT_VERSION)
# keep binding through the factory.
from routers.pages import build_pages_router  # noqa: E402

# Bridge build artifact dir. Kept as a module attribute so the route tests can
# monkeypatch app._BRIDGE_DIR; the pages router resolves it at request time.
_BRIDGE_DIR = os.path.join(STATIC_DIR, "bridge")

app.include_router(build_pages_router(
    STATIC_DIR,
    get_storefront_as_landing=lambda: STOREFRONT_AS_LANDING,
    get_storefront_version=lambda: _STOREFRONT_VERSION,
    get_bridge_dir=lambda: _BRIDGE_DIR,
))


@app.get("/healthz")
def healthz():
    """Diagnostic endpoint. Public — no secrets returned, just boot + connectivity
    facts. Useful when a deploy goes orange and we need a one-curl picture.

    Reports:
      python_version, is_production, storefront_sql_only,
      supabase_url_set, supabase_service_role_key_set,
      supabase_anon_key_set, evo_client_configured, evo_creds_source,
      tevo_env_resolves (set-booleans per env-var name),
      supabase_smoke: pass | fail (with truncated error message)

    Privacy note: key *lengths* used to leak here, exposing which key
    format was loaded (200+ legacy JWT vs ~40 new sb_*_*). Recon-grade.
    Replaced with set/unset booleans per b5258f7 item 4.
    """
    import sys as _sys
    out = {
        "ok": True,
        "python": _sys.version.split()[0],
        "is_production": _is_production(),
        "storefront_sql_only": STOREFRONT_SQL_ONLY,
        "storefront_search_sql_only": STOREFRONT_SEARCH_SQL_ONLY,
        "supabase_url_set": bool(SUPABASE_URL),
        "supabase_service_role_key_set": bool(SUPABASE_SERVICE_ROLE_KEY),
        "supabase_anon_key_set": bool(SUPABASE_ANON_KEY),
        "supabase_client_initialized": sb is not None,
        "evo_client_configured": client is not None,
        "evo_creds_source": CREDS_SOURCE,
        "error_tracking": "sentry" if _OBSERVABILITY.get("sentry") else "off",
        "db_circuit": _db_breaker.status,
        "tevo_env_resolves": {
            "TEVO_TOKEN_set": bool(os.environ.get("TEVO_TOKEN")),
            "TEVO_API_TOKEN_set": bool(os.environ.get("TEVO_API_TOKEN")),
            "TEVO_SECRET_set": bool(os.environ.get("TEVO_SECRET")),
            "TEVO_API_SECRET_set": bool(os.environ.get("TEVO_API_SECRET")),
        },
    }
    # Tiny safe query against a table we know exists.
    if sb is None:
        out["supabase_smoke"] = "skipped — sb is None"
    else:
        try:
            r = sb.table("events").select("id").limit(1).execute()
            out["supabase_smoke"] = "pass"
            out["supabase_smoke_rows"] = len(r.data or [])
            _db_breaker.record_success()
        except Exception as e:
            out["ok"] = False
            out["supabase_smoke"] = "fail"
            # Truncate so we don't leak full traces over a public endpoint.
            out["supabase_smoke_error"] = str(e)[:300]
            _db_breaker.record_failure()
        out["db_circuit"] = _db_breaker.status
    return out


# ---------------------------------------------------------------------------
# Render webhook receiver → GitHub Actions bridge
# ---------------------------------------------------------------------------
# Incorporates render-examples/webhook-receiver + webhook-github-action into
# the unified service: Render POSTs a Standard-Webhooks-signed payload here on
# deploy/service/db events; we verify it, ACK 200 fast, then (in the
# background) dispatch on event type — a successful deploy_ended triggers the
# post-deploy GitHub workflow; other types are enriched + logged. Pure logic
# lives in render_webhook.py (unit-tested in tests/test_render_webhook.py).

@app.post("/webhooks/render")
async def render_deploy_webhook(request: Request, background: BackgroundTasks):  # pragma: no cover - async route body not attributable by coverage.py via TestClient; behavior covered in test_app_infra_full.py
    """Receive + verify a Render webhook, then handle it asynchronously. Always
    answers fast so Render doesn't time out and retry; verification failures
    return 401 (so a misconfigured secret is visible in Render's webhook
    delivery log).

    Fails closed: if RENDER_WEBHOOK_SECRET is unset, every request is rejected
    — we never accept an unsigned/unverifiable webhook.
    """
    cfg = render_webhook.load_config()
    body = await request.body()
    try:
        render_webhook.verify_signature(cfg["webhook_secret"], body, dict(request.headers))
    except render_webhook.WebhookVerificationError as e:
        raise HTTPException(status_code=401, detail=f"webhook verification failed: {e}")

    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="invalid JSON body")

    # Process after the 200 is sent — the Render API + GitHub calls can take a
    # few seconds and must not block the webhook ACK.
    def _process(p, c):
        try:
            logging.getLogger("render_webhook").info("webhook handled: %s", render_webhook.handle_webhook(p, c))
        except Exception:  # background task — never let it escape
            logging.getLogger("render_webhook").exception("webhook handler crashed")

    background.add_task(_process, payload, cfg)
    return {"ok": True, "received": payload.get("type")}


# Route moved to routers/misc.py (BR-CODE-1 decomposition); the payload builder
# stays here (reads the live config constants the tests patch) + is injected via
# the get_public_config getter.
def _public_config_payload():
    """Browser-safe config for the login page. No secrets."""
    return {
        "supabase_url": SUPABASE_URL,
        "supabase_anon_key": SUPABASE_ANON_KEY,
        "allowed_email_domain": ALLOWED_EMAIL_DOMAIN,
        # Storefront SQL-only demo mode flag. UI hides geolocation + shows
        # a 'demo · sql snapshot' pill so users know what they're seeing.
        "storefront_sql_only": STOREFRONT_SQL_ONLY,
        "storefront_search_sql_only": STOREFRONT_SEARCH_SQL_ONLY,
        # TEvo Hosted Checkout: force-OFF. Live online checkout is disabled
        # (STOREFRONT_CHECKOUT_DISABLED) — always report no checkout so store.js
        # never redirects to a hosted-checkout URL, even if STOREFRONT_CHECKOUT_
        # DOMAIN is set. Re-enabling is a deliberate two-step: clear the kill
        # switch AND set the domain.
        "checkout_domain": None if STOREFRONT_CHECKOUT_DISABLED else (STOREFRONT_CHECKOUT_DOMAIN or None),
        "purchase_enabled": (not STOREFRONT_CHECKOUT_DISABLED) and bool(STOREFRONT_CHECKOUT_DOMAIN),
        # reCAPTCHA v3 sitewide bot gate. site_key is null while dormant (store.js
        # then skips loading Google's script); when set, store.js runs the gate on
        # first interaction. The secret never leaves the server.
        "recaptcha_site_key": RECAPTCHA_SITE_KEY or None,
        "recaptcha_enabled": RECAPTCHA_ENABLED,
    }

# ---------- Protected routes ----------

# /api/config + /api/cross-source/event/{id} moved to routers/misc.py
# (BR-CODE-1 slice 10). Wired once below the bootstrap (search "build_misc_router").


# /api/events (search) moved to routers/catalog.py (BR-CODE-1 slice 6).
# /api/events/{id} + /{id}/series + /{id}/sections/series -> routers/catalog.py
# (BR-CODE-1 slice 36; get_client + get_require_sb getter + core is_event_seat).


# _is_event_seat (+ _PARKING_RE) -> core/helpers.py (BR-CODE-1 pure-helper pass); aliased at top.

# /api/performers (search) -> routers/catalog.py (BR-CODE-1 slice 31; TEvo
# client passthrough, joins its /{id} sibling already there).
# /api/performers/{id} + /api/venues/{id} + /api/configurations[/{id}] moved to
# routers/catalog.py (BR-CODE-1 slice 2); included once below (search → "wired").

# Static league list for the league-browse strip in the Performers tab.
# Sourced from performer_external_ids where source='espn'. Order roughly
# matches in-season activity in May.
_ESPN_LEAGUES = [
    {"key": "NBA",       "label": "NBA",        "teams": 30},
    {"key": "MLB",       "label": "MLB",        "teams": 30},
    {"key": "NHL",       "label": "NHL",        "teams": 32},
    {"key": "WNBA",      "label": "WNBA",       "teams": 15},
    {"key": "MLS",       "label": "MLS",        "teams": 30},
    {"key": "NFL",       "label": "NFL",        "teams": 32},
    {"key": "World Cup", "label": "World Cup",  "teams": 48},
]


# Simple broker routes (/leagues, /performer/{id}/assets, /event/{id}/espn)
# moved to routers/broker.py (BR-CODE-1 slice 11). Helper-heavy broker routes
# stay in app.py until their shared helpers are extracted. Wired once below.
from routers.broker import build_broker_router  # noqa: E402

app.include_router(build_broker_router(
    get_require_sb=lambda: require_sb,
    require_auth=require_auth,
    espn_leagues=_ESPN_LEAGUES,
    get_supabase_url=lambda: SUPABASE_URL,
    get_supabase_anon_key=lambda: SUPABASE_ANON_KEY,
    # Trip-planner delegates (D0 broker twins of the D1 store routes). Lambdas
    # resolve the live server payload builders so the monkeypatch tests bind.
    get_trip_plan_payload=lambda: _trip_plan_payload,
    get_tour_package_payload=lambda: _tour_package_payload,
    get_multi_tour_payload=lambda: _multi_tour_payload,
    get_discover_payload=lambda: _discover_payload,
    get_client=lambda: client,
    get_bulk_performer_assets=lambda: _bulk_performer_assets,
))


# Trip-planner payload builders moved to core/trip_payloads.py (BR-CODE-1 core/
# pass). Thin wrappers inject the live require_sb so app.<name> monkeypatches
# (notably app._tour_package_payload) keep binding; signatures unchanged for the
# store + broker router getters.
def _trip_plan_payload(*args, **kwargs):
    return _ce_trip_plan_payload(*args, require_sb=require_sb, **kwargs)


def _tour_package_payload(*args, **kwargs):
    return _ce_tour_package_payload(*args, require_sb=require_sb, **kwargs)


def _multi_tour_payload(*args, **kwargs):
    return _ce_multi_tour_payload(*args, require_sb=require_sb, **kwargs)


def _discover_payload(*args, **kwargs):
    return _ce_discover_payload(*args, require_sb=require_sb, **kwargs)


# _bulk_performer_assets -> core/broker_helpers.py and _classify_playoff (+ its
# _PLAYOFF_*_RE) -> core/helpers.py (BR-CODE-1 helper pass). Imported (aliased)
# at the top of this module; call sites unchanged.


# Marquee competitions — events that aren't playoffs but carry their own
# editorial weight (US Open Tennis, F1 Grand Prix, Inter Miami away). Added
# 2026-05-19 v3 for the Featured rail's narrative-signal branch.
# Movers engine (the _section_* builders, the 3 classifiers
# _classify_marquee_competition / _has_canadian_team / _classify_holiday_proximity
# + their constants _MARQUEE_PATTERNS / _CANADIAN_TEAM_RE / _HOLIDAY_PRIORITY, and
# _compute_movers) -> core/movers.py (BR-CODE-1 heavy-helper pass). app.py imports
# compute_movers (aliased) near the top; the cluster was movers-exclusive.


# FIFA World Cup 2026 detection (D3, 2026-06-16). EVO/TEvo lists World Cup
# matches under the performer "World Cup Soccer" with names like
# "2026 World Cup Soccer - Match 72 (Congo DR vs Uzbekistan) (Group K)".
# Tight by design so it does NOT catch lookalikes that merely contain the
# words "world cup": MLB "(World Cup Scarf Giveaway)" promos, "Rugby World
# Cup", or "World Cup Countdown Concert" — none of which are WC matches.
# _WORLD_CUP_RE + _classify_world_cup -> core/helpers.py (BR-CODE-1 leaf-helper
# pass). Imported (aliased) near the top of this module.


# (_CANADIAN_TEAM_RE/_has_canadian_team + _HOLIDAY_PRIORITY/_classify_holiday_proximity
#  moved to core/movers.py with the rest of the movers engine — see note above.)


# _bulk_event_context -> core/broker_helpers.py (BR-CODE-1 heavy-helper pass).
# Imported (aliased) at the top of this module; single call site unchanged.


# /api/broker/news + /api/broker/performers/by-league/{league} + raw-tevo ->
# routers/broker.py (BR-CODE-1 slice 24; standalone DB-read routes, raw-tevo
# adds the live TEvo read-through — no in-server helper coupling).

# /api/portfolio -> routers/broker.py (BR-CODE-1 slice 37; pure require_sb
# aggregation across an owned-event set — no client/helper coupling).


# /api/venues (search) -> routers/catalog.py (BR-CODE-1 slice 31; TEvo client
# passthrough, joins its /{id} sibling already there).


# Catalog detail passthroughs (/api/performers/{id}, /api/venues/{id},
# /api/configurations[/{id}]) live in routers/catalog.py (BR-CODE-1 slice 2).
# get_client is a getter so handlers resolve the live `client` at request time
# (keeps the monkeypatch tests + auth ownership in app.py).
from routers.catalog import build_catalog_router  # noqa: E402

app.include_router(build_catalog_router(
    get_client=lambda: client,
    require_auth=require_auth,
    get_require_sb=lambda: require_sb,
))


# /api/watchlist GET, /api/runs, /api/snapshots/* (read lists) moved to
# routers/lists.py (BR-CODE-1 slice 3). get_require_sb is a getter so handlers
# resolve the live require_sb at request time (keeps monkeypatch tests). The
# watchlist POST/DELETE (mutating) routes stay below.
from routers.lists import build_lists_router  # noqa: E402

app.include_router(build_lists_router(get_require_sb=lambda: require_sb, require_auth=require_auth))


# /api/watchlist POST + DELETE -> routers/lists.py (BR-CODE-1 slice 35; joins
# the watchlist GET there — require_sb + require_auth only). The whole
# /api/watchlist + /api/runs + /api/snapshots/* surface now lives in lists.py.


# Ingest helpers (_fire_collect, _upsert_tevo_event_into_events, _flatten_order)
# moved to core/ingest.py (BR-CODE-1 core/ pass). Thin wrappers keep the
# app-module bindings the tests patch/call directly (app._fire_collect /
# app._upsert_tevo_event_into_events / app._flatten_order) + the admin-router
# getters; `requests` is the same module object so the app.requests.post patch
# still reaches core.ingest.fire_collect.
def _fire_collect(url: str, secret: str) -> None:
    return _ce_fire_collect(url, secret)


# Per-user throttle for /api/collect/run — 1 invocation per 5 min per email.
# Defends against accidental loops or a leaked JWT being used to spam-fire the
# collector. Cheap in-process state; resets on Railway redeploy.
_collect_run_last_call: dict[str, float] = {}
_COLLECT_RUN_COOLDOWN_SEC = 300


# The admin/ingest routes (/api/collect/run + /api/admin/{seed-home-venues,
# wire-sg-to-tevo, wire-sd-to-tevo, collect-orders, collect-sg-seller}) moved to
# routers/admin.py (BR-CODE-1 slice 41). Their patchable helpers + cooldown state
# (_upsert_tevo_event_into_events, _flatten_order, _fire_collect,
# _collect_run_last_call, _get_seatgeek_client, _get_seatdata_client) stay here —
# tests call several directly — and are injected via getters. Wired once below,
# after those helpers are defined (search "build_admin_router").


# ============================================================================
# Broker terminal — event-detail page endpoints
# ----------------------------------------------------------------------------
# Backs the new /event/{id} terminal (Bloomberg/Robinhood hybrid).
# Each endpoint returns its own last_pull_at + cadence_seconds so the page
# can poll independently per data type, cascaded across events.
# ============================================================================


# Pure helpers moved to core/helpers.py (BR-CODE-1 helper pass); aliased so the
# inline _delta / _listings_cadence_seconds usages keep working unchanged.
from core.helpers import delta as _delta  # noqa: E402
from core.helpers import listings_cadence_seconds as _listings_cadence_seconds  # noqa: E402


# /api/broker/event/{id}/overview -> routers/broker.py (BR-CODE-1 slice 26;
# require_sb + pure core delta/cadence helpers + _bulk_performer_assets via getter).

# /api/broker/event/{id}/section-zones + /zones -> routers/broker.py (BR-CODE-1
# slice 27; require_sb + the _PARKING_* regexes, both moved into the router).

# /api/broker/event/{id}/section-metrics + /api/broker/watchlist-movers +
# /api/broker/event/{id}/orders -> routers/broker.py (BR-CODE-1 slice 25;
# standalone DB-read routes, require_sb only + the pure core delta/cadence helpers).
# /api/broker/event/{id}/raw-tevo -> routers/broker.py (BR-CODE-1 slice 24).
# /api/broker/performer/{id}/espn -> routers/broker.py (BR-CODE-1 slice 28;
# require_sb + stdlib datetime only — ESPN snapshot/injury/news/recent reads).


# (admin_seed_home_venues moved to routers/admin.py — slice 41)


# ---------------------------------------------------------------------------
# Admin: wire SG / SeatData events to TEvo events
# ---------------------------------------------------------------------------
# For SG events with seller-direct listings but no seatgeek_event_xref row,
# search TEvo by event name + date, ingest matching TEvo events into our
# `events` table, then call sg_attempt_event_xref to link them.
#
# RULE 2 compliant — every TEvo call is GET via the read-only client.

# _venue_tokens + _venue_overlap -> core/helpers.py (BR-CODE-1 pure-utility pass); aliased at top.
def _upsert_tevo_event_into_events(db, ev: dict) -> int | None:
    return _ce_upsert_tevo_event_into_events(db, ev)


# (admin_wire_sg_to_tevo + admin_wire_sd_to_tevo moved to routers/admin.py —
#  slice 41; _upsert_tevo_event_into_events kept here, injected via getter.)


# (broker_event_espn moved to routers/broker.py — slice 11)

# /api/broker/event/{id}/chart-data -> routers/broker.py (BR-CODE-1 slice 29;
# self-contained ~485-line route, all _series/_stand/_team_index helpers nested
# inside it — require_sb the only external dep).

# /api/broker/movers (+ _broker_movers_v2 helper) -> routers/broker.py
# (BR-CODE-1 slice 30 — FINAL broker route; require_sb + core delta helper only).
# The entire /api/broker/* surface now lives in routers/broker.py.


# (broker_event_cadences moved to routers/broker.py — slice 12, uses
#  core.helpers.listings_cadence_seconds)


# ============================================================================
# SeatData routes — second pricing source (sales history) alongside TEvo
# ============================================================================
# Hard-capped to BASIC plan budget (100 paid pulls/day, 2000/month) per
# migration 20260509060000. Going over those caps requires bumping BOTH the
# DB defaults AND the seatdata_client.py constants.
#
# Auth: SEATDATA_API_KEY resolved via SeatDataClient's chain:
#   1. SEATDATA_API_KEY env var (Railway / Render)
#   2. Supabase Vault via get_app_secret('SEATDATA_API_KEY')
# Routes return 503 if the key is missing from both env and vault.

def _get_seatdata_client():
    """Lazy import + instantiation. Returns None if SEATDATA_API_KEY not found anywhere."""
    from seatdata_client import SeatDataClient, SeatDataError
    try:
        return SeatDataClient(db=require_sb())
    except SeatDataError:
        return None


# SeatData READ routes (account/usage/budget/event/event-sales) moved to
# routers/seatdata.py (BR-CODE-1 slice 7). The link/auto-search/sync POSTs stay
# in app.py. Getters resolve the live _get_seatdata_client + require_sb at
# request time (keeps monkeypatch tests).
from routers.seatdata import build_seatdata_router  # noqa: E402

app.include_router(build_seatdata_router(
    get_seatdata_client=lambda: _get_seatdata_client(),
    get_require_sb=lambda: require_sb,
    require_auth=require_auth,
    require_cron_or_auth=_require_cron_or_auth,
))


# AXS box-office READ routes (event/sections/listings/series) moved to
# routers/axs.py (BR-CODE-1 slice 8). All read-only require_sb reads.
from routers.axs import build_axs_router  # noqa: E402

app.include_router(build_axs_router(get_require_sb=lambda: require_sb, require_auth=require_auth))


# (seatdata link + auto-search + sync-sales POSTs moved to routers/seatdata.py
#  — slice 33; require_cron_or_auth passed in for the cron-driven sync routes.)


# ============================================================================
# EVO orders — pulls /v9/orders every 10 min, maps to events
# ============================================================================
# Auth on this route: either a normal Bearer token (manual trigger from UI)
# or a matching X-Cron-Secret header (pg_cron-driven). The cron secret is
# expected in env var CRON_SECRET on Railway. Hardened 2026-05-11:
# fail-closed if unset (was: defaulted to a known placeholder string),
# constant-time compare to avoid timing-leak.
# CRON_SECRET is declared once at module top (line ~216) — no re-declaration.


# _require_cron_or_auth -> core/auth.py (BR-CODE-1 config/auth seam). Imported
# (aliased) near the top of this module.


# _parse_iso_or_none + _to_int_or_none + _to_num_or_none -> core/helpers.py (BR-CODE-1); aliased at top.
def _flatten_order(order: dict) -> dict:
    return _ce_flatten_order(order)


# _flatten_order_items -> core/helpers.py (BR-CODE-1); aliased at top.
# (collect_evo_orders moved to routers/admin.py — slice 41; _flatten_order kept
#  here, injected via getter so the app._flatten_order monkeypatch still binds.)


# /api/broker/event/{id}/orders -> routers/broker.py (BR-CODE-1 slice 25).


# ============================================================================
# SeatGeek BROKER DATA API routes — third data source
# ============================================================================
# Host: brokerdata.seatgeek.com. Auth: ?token=<TOKEN> (from vault).
# Endpoints we use:
#   /listings        broker inventory for an event
#   /v2/listings     ALL secondary marketplace listings (broader)
#   /sales           transacted sales for an event
#   /purchases       broker's own SG purchases (token currently lacks scope)
#
# ID model: SG event_id is independent. Broker API has NO search endpoint,
# so matching is manual: user finds SG event_id (broker portal / SG website
# URL), POSTs /link, then sync-listings + sync-sales work off the xref.

def _get_seatgeek_client():
    """Lazy import + instantiation. Returns None if SEATGEEK_API_TOKEN is missing."""
    try:
        from seatgeek_client import SeatGeekClient
        return SeatGeekClient(db=require_sb())
    except Exception as e:
        # Surface the setup hint via 503 in the route
        if "SEATGEEK_API_TOKEN not found" in str(e):
            return None
        raise


# SeatGeek READ routes (event/listings/sales/seller-listings/seller-orders/
# seller-status) moved to routers/seatgeek.py (BR-CODE-1 slice 9). The
# link/sync POSTs stay in app.py. All read-only require_sb reads.
from routers.seatgeek import build_seatgeek_router  # noqa: E402

app.include_router(build_seatgeek_router(
    get_require_sb=lambda: require_sb,
    require_auth=require_auth,
    get_sg_client=lambda: _get_seatgeek_client,
))



# (seatgeek_event_listings + seatgeek_event_sales moved to routers/seatgeek.py — slice 9)
# (seatgeek link + sync-listings + sync-sales POSTs moved to routers/seatgeek.py
#  — slice 32; get_sg_client getter resolves the live _get_seatgeek_client.)


# ----------------------------------------------------------------------------
# SeatGeek SELLER DIRECT — read-only ingest of S4K listings + orders
# ----------------------------------------------------------------------------
# Different host (sellerdirect-api.seatgeek.com) from the broker-data API.
# /listings + /orders + /order. Each row carries SG event_id + name + venue
# + date inline → auto-backfills seatgeek_event_xref via sg_attempt_event_xref().

# (collect_sg_seller moved to routers/admin.py — slice 41.)
#
# Admin/ingest router wiring (BR-CODE-1 slice 41). Placed here, after all the
# patchable helpers + client factories + cooldown state are defined above, so
# the getters resolve live server bindings at request time (keeps the
# app.client / app._flatten_order / app._venue_overlap / app.CRON_SECRET /
# app._collect_run_last_call monkeypatches binding through the factory).
from routers.admin import build_admin_router  # noqa: E402

app.include_router(build_admin_router(
    get_require_sb=lambda: require_sb,
    get_client=lambda: client,
    require_auth=require_auth,
    require_cron_or_auth=_require_cron_or_auth,
    get_seatgeek_client=lambda: _get_seatgeek_client(),
    get_supabase_url=lambda: SUPABASE_URL,
    get_cron_secret=lambda: CRON_SECRET,
    get_collect_run_last_call=lambda: _collect_run_last_call,
    collect_run_cooldown_sec=_COLLECT_RUN_COOLDOWN_SEC,
    get_fire_collect=lambda: _fire_collect,
    get_upsert_tevo_event=lambda: _upsert_tevo_event_into_events,
    get_flatten_order=lambda: _flatten_order,
    get_flatten_order_items=lambda: _flatten_order_items,
    get_venue_overlap=lambda: _venue_overlap,
))


# (seatgeek seller-listings / seller-orders / seller-status moved to
#  routers/seatgeek.py — slice 9)


# (config_info + cross_source_event moved to routers/misc.py — slice 10)
from routers.misc import build_misc_router  # noqa: E402

app.include_router(build_misc_router(
    get_sb=lambda: sb,
    get_require_sb=lambda: require_sb,
    require_auth=require_auth,
    cron_secret=CRON_SECRET,
    supabase_url=SUPABASE_URL,
    sandbox=SANDBOX,
    get_public_config=lambda: _public_config_payload,
))



# ---------- Store (MVP) ----------
# Public-facing storefront over the brokerage's owned TEvo inventory. Read-only,
# no real purchase — "Reserve" returns a mock receipt. Source of truth is TEvo's
# /v9/ticket_groups?owned=true for live inventory; the catalog page uses
# event_metrics.owned_tickets_count > 0 to find events worth listing.

# _ticket_group_to_listing -> core/helpers.py (BR-CODE-1 shared event/listings
# layer; pure dict reshape). Imported (aliased) near the top of this module.


# Our TEvo brokerage's office id. Resolved via probe `/v9/orders` (probe v2,
# 2026-05-13): brokerage=S4K Entertainment (id 1768), office=Office 3
# (id 42029, NYC). Filter /v9/events with office_id=this to get only events
# our office has inventory for (server-side filter, 100% we_own match).
# Override via TEVO_OFFICE_ID env var if the brokerage adds offices later.
TEVO_OFFICE_ID = int(os.environ.get("TEVO_OFFICE_ID", "42029"))


# /api/store/events (catalog GET) -> routers/store.py (BR-CODE-1 slice 34;
# get_client + get_bulk_performer_assets + get_require_sb, all already wired).


# _haversine_miles -> core/helpers.py (BR-CODE-1 pure-utility pass); aliased at top.
# _attach_owned_metadata body -> core/discovery.py (BR-CODE-1 core/ pass). Thin
# wrapper injects the live _bulk_performer_assets so app._bulk_performer_assets
# monkeypatches still bind; signature unchanged for the near-route getter.
def _attach_owned_metadata(
    db,
    candidate_ids: list[int],
    user_lat: float,
    user_lon: float,
) -> list[dict]:
    return _ce_attach_owned_metadata(
        db, candidate_ids, user_lat, user_lon,
        bulk_performer_assets=_bulk_performer_assets,
    )


# In-memory TTL cache for storefront search results. TEvo's
# /v9/searches/suggestions has no upstream cache — 5 repeated calls vary
# 785-2833ms (empirical 2026-05-12). 60s window means even an aggressive
# typist won't burn quota on common queries.
_search_cache: dict[str, tuple[float, dict]] = {}
_SEARCH_CACHE_TTL = 60.0


# Movers stale-while-revalidate cache. /api/store/movers does a 4-table
# join (events + latest_event_metrics + event_lifecycle + v_event_velocity
# _windows + performer_metadata) per call and consistently times at ~1s
# warm. Underlying velocity data only refreshes hourly (driven by the
# listings_snapshots ingest cadence), so a 5-min server cache is well
# within the data's natural refresh window AND eliminates ~1s on every
# homescreen load past the first.
#
# Pattern: fresh hits return instantly; stale hits return cached payload
# AND schedule a background recompute via FastAPI BackgroundTasks; cold
# (never-seen-key) hits compute synchronously. Refresh-in-flight tracking
# prevents duplicate fans for the same key under concurrent requests.
_movers_cache: dict[str, tuple[float, dict]] = {}
_MOVERS_CACHE_TTL = 300.0  # 5 min — conservative vs. hourly velocity refresh
_MOVERS_CACHE_REFRESHING: set[str] = set()


# _movers_cache_key -> core/helpers.py (BR-CODE-1); aliased at top.
# _normalize_search_key -> core/helpers.py (BR-CODE-1); aliased at top.
# PostgREST ILIKE pattern wildcards we need to escape so a user-supplied
# query like "%" doesn't become a match-everything pattern. Backslash
# escaped FIRST so we don't double-escape our own escapes.
# _ILIKE_WILDCARDS + _escape_ilike + _search_sql_only -> core/search.py
# (BR-CODE-1). app.py imports search_sql_only (aliased) near the top.


# Characters that, if present in an .or_() clause VALUE, force PostgREST to
# treat the value as ending early. Wrapping the value in double quotes tells
# PostgREST to read the value verbatim. Required for hard-coded patterns
# like "%, NY%" — the comma would otherwise be parsed as a clause separator.
# _OR_VALUE_RESERVED + _or_ilike_clause -> core/helpers.py (BR-CODE-1 leaf-helper
# pass). Imported (aliased) near the top of this module.


# _is_tbd -> core/helpers.py (BR-CODE-1); aliased at top.
# _clean_opt_url + _tevo_runtime_to_http (+ _TEVO_STATUS_RE) -> core/helpers.py
# (BR-CODE-1 shared event/listings layer). Imported (aliased) near the top.


# Search helpers (cache + sports-player layer + live TEvo path) moved to
# core/search.py (BR-CODE-1 core/ pass). These thin wrappers pass the live
# server symbols (the cache dict, ensure_tevo_client, _search_sql_only) so the
# monkeypatch tests (app._search_cache / app.ensure_tevo_client /
# app._search_sql_only) keep binding; signatures unchanged for the store router.
def _search_cache_get(key: str) -> dict | None:
    return _ce_search_cache_get(_search_cache, key, _SEARCH_CACHE_TTL)


def _search_cache_put(key: str, payload: dict) -> None:
    _ce_search_cache_put(_search_cache, key, payload)


def _search_players(db, q_norm: str, limit: int) -> list[dict]:
    return _ce_search_players(db, q_norm, limit)


def _search_live(db, q_norm: str, limit: int) -> dict:
    return _ce_search_live(
        db, q_norm, limit,
        ensure_client=ensure_tevo_client,
        search_sql_only=_search_sql_only,
    )


# /api/store/search + /api/store/concierge + /api/store/movers + /api/store/home
# + /api/store/events/near -> routers/store.py (BR-CODE-1 slice 22; mounted
# above). The in-process caches (_search_cache / _movers_cache /
# _MOVERS_CACHE_REFRESHING) + the heavy helpers (_search_*, _attach_owned_metadata,
# _refresh_movers) stay here; the routes resolve them via getters so the route
# tests' monkeypatch keeps binding.


def _refresh_movers(city: str, days: int, limit: int, key: str) -> None:
    """Background refresh fired by BackgroundTasks AFTER the stale response
    is sent. Failures log and clear the in-flight flag so a future request
    can retry; the stale cached payload stays in place (better than
    eviction — a slightly old payload beats no payload).
    """
    try:
        fresh = _compute_movers(require_sb(), city, days, limit)
        _movers_cache[key] = (time.time(), fresh)
    except Exception as e:
        _log.warning(f"[movers refresh] failed for {key}: {e!r}")
    finally:
        _MOVERS_CACHE_REFRESHING.discard(key)


# ---------------------------------------------------------------------------
# Storefront sections — themed sliders. EVO/TEvo-ONLY (operator directive
# 2026-06-16): the consumer store features no SeatGeek information or values.
# All velocity signals derive from TEvo data:
#   moving_fast   demand velocity   tix_d24h <= -50 (≥50 tickets left our market in 24h)
#   price_drops   our get-in fell   getin_pct_24h <= -10 (our get-in price dropped ≥10% in 24h)
#   climbing      price firming     d24h < 0 AND getin_pct_24h >= +5%
#   specials      curated/calendar  owned > 100 AND (holiday-window OR rivalry)
# Each section is independent — a single event can appear in 0, 1, or 2 sections.
# ---------------------------------------------------------------------------


# The movers engine (_section_moving_fast/_price_drops/_climbing/_specials/
# _featured + _compute_movers) lives in core/movers.py (BR-CODE-1). It's
# imported as `_compute_movers` near the top of this module; the store/broker
# movers routes call it unchanged.


# /api/store/home + /api/store/events/near -> routers/store.py (BR-CODE-1
# slice 22; mounted above). _attach_owned_metadata + _bulk_performer_assets
# stay here, resolved via getters so the route tests' monkeypatch keeps binding.


# /api/store/performers/{id}/trip-plan|tour-package + /api/store/tours/multi|near
# -> routers/store.py (BR-CODE-1 slice; thin delegates, payload builders stay
# in server.py shared with the D0 broker routes, passed via getters).


# _section_sort_key -> core/helpers.py (BR-CODE-1); aliased at top.
# _csv + _normalize_filters -> core/helpers.py (BR-CODE-1 shared event/listings
# layer); imported (aliased) near the top of this module.


def _build_zone_resolver(performer_id: int | None, venue_id: int | None):
    # Body in core/store_events.py (BR-CODE-1 core/ pass). Wrapper passes the
    # live sb so the app.sb monkeypatch binds; signature unchanged.
    return _ce_build_zone_resolver(sb, performer_id, venue_id)


# _normalize_filters -> core/helpers.py (BR-CODE-1); imported (aliased) at top.


# _fire_canonical_refresh body -> core/canonical_refresh.py (BR-CODE-1 core/
# pass). Thin wrapper injects the live sb + config + _fire_collect so the
# monkeypatches (app.sb / app.SUPABASE_URL / app.CRON_SECRET / app._fire_collect)
# + the app.threading.Thread sync-stub + the resolve-injection + direct
# app._fire_canonical_refresh test calls all keep binding.
def _fire_canonical_refresh(event_id: int, ev: dict) -> None:
    return _ce_fire_canonical_refresh(
        event_id, ev, sb=sb, supabase_url=SUPABASE_URL,
        cron_secret=CRON_SECRET, fire_collect=_fire_collect,
    )


# SQL-only store helpers moved to core/store_events.py (BR-CODE-1 core/ pass).
# Thin wrappers keep the (event_id) signatures + resolve the live require_sb
# (monkeypatched in tests) so all call sites + the direct test call bind.
from core.store_events import (  # noqa: E402
    fetch_event_from_db as _ce_fetch_event_from_db,
    fetch_owned_ticket_groups_from_db as _ce_fetch_owned_ticket_groups_from_db,
    build_zone_resolver as _ce_build_zone_resolver,
    fetch_owned_ticket_groups as _ce_fetch_owned_ticket_groups,
)


def _fetch_event_from_db(event_id: int) -> dict:
    return _ce_fetch_event_from_db(require_sb, event_id)


def _fetch_owned_ticket_groups_from_db(event_id: int) -> tuple[list[dict], str, str | None]:
    return _ce_fetch_owned_ticket_groups_from_db(require_sb, event_id)


def _fetch_owned_ticket_groups(
    event_id: int,
    max_age_seconds: int | None = None,
) -> tuple[list[dict], str]:
    # Body in core/store_events.py (BR-CODE-1 core/ pass). Wrapper passes the
    # live sb + client so their monkeypatches bind; signature unchanged.
    return _ce_fetch_owned_ticket_groups(sb, client, event_id, max_age_seconds)


# _tevo_runtime_to_http (maps an EvoClient RuntimeError to a 404/503/502) +
# _TEVO_STATUS_RE moved to core/helpers.py (BR-CODE-1 shared event/listings
# layer). Imported (aliased) near the top of this module.


# _resolve_event_with_filters body -> core/store_events.py (BR-CODE-1 keystone).
# The wrapper passes the LIVE server globals + helper aliases at call time, so
# every monkeypatch (app.sb / app.client / app.STOREFRONT_SQL_ONLY /
# app._fire_canonical_refresh / app._fetch_* / app._build_zone_resolver /
# app._bulk_*) still binds, and the (event_id, filters, include_inactive)
# signature is unchanged for the shares-router getter + direct test callers.
from core.store_events import (  # noqa: E402
    resolve_event_with_filters as _ce_resolve_event_with_filters,
)


def _resolve_event_with_filters(event_id: int, filters: dict, include_inactive: bool = False) -> dict:
    return _ce_resolve_event_with_filters(
        sb, client, STOREFRONT_SQL_ONLY, _fire_canonical_refresh,
        _fetch_event_from_db, _fetch_owned_ticket_groups_from_db,
        _fetch_owned_ticket_groups, _build_zone_resolver,
        _bulk_performer_assets, _bulk_event_context,
        event_id, filters, include_inactive,
    )


# /api/store/events/{id} (+ /zones) -> routers/store.py (BR-CODE-1 slice, now
# unblocked by the resolve_event_with_filters -> core move). Getters bind the
# live server symbols so the monkeypatch tests still intercept.
from routers.store import build_store_router  # noqa: E402
app.include_router(build_store_router(
    get_require_sb=lambda: require_sb,
    get_resolve_event=lambda: _resolve_event_with_filters,
    get_prefer_internal_zones=lambda: STOREFRONT_PREFER_INTERNAL_ZONES,
    get_trip_plan_payload=lambda: _trip_plan_payload,
    get_tour_package_payload=lambda: _tour_package_payload,
    get_multi_tour_payload=lambda: _multi_tour_payload,
    get_discover_payload=lambda: _discover_payload,
    # Discovery routes (search / movers / home / near). Lambdas resolve the
    # live server symbols at request time so the monkeypatch tests bind.
    get_storefront_sql_only=lambda: STOREFRONT_SQL_ONLY,
    get_storefront_search_sql_only=lambda: STOREFRONT_SEARCH_SQL_ONLY,
    get_search_cache_get=lambda: _search_cache_get,
    get_search_cache_put=lambda: _search_cache_put,
    get_search_sql_only=lambda: _search_sql_only,
    get_search_live=lambda: _search_live,
    get_search_players=lambda: _search_players,
    get_movers_cache=lambda: _movers_cache,
    get_movers_cache_ttl=lambda: _MOVERS_CACHE_TTL,
    get_movers_refreshing=lambda: _MOVERS_CACHE_REFRESHING,
    get_refresh_movers=lambda: _refresh_movers,
    get_compute_movers=lambda: _compute_movers,
    get_bulk_performer_assets=lambda: _bulk_performer_assets,
    get_client=lambda: client,
    get_attach_owned_metadata=lambda: _attach_owned_metadata,
    get_safe_read=lambda: safe_sb_read,
    get_resilient_read=lambda: sb_read_or_raise,
    get_tevo_office_id=lambda: TEVO_OFFICE_ID,
    # Bot-gated store POSTs (verify-human / reserve).
    get_require_auth=lambda: require_auth,
    get_recaptcha_enabled=lambda: RECAPTCHA_ENABLED,
    get_verify_recaptcha=lambda: _verify_recaptcha,
    get_require_human=lambda: _require_human,
    get_reserve_requires_auth=lambda: STOREFRONT_RESERVE_REQUIRES_AUTH,
    get_fetch_owned_tg_from_db=lambda: _fetch_owned_ticket_groups_from_db,
))


# /api/store/seatmap/* proxy + section crosswalk -> routers/seatmap.py
# (BR-CODE-1 decomposition slice). get_sb resolves the live app.sb so the
# monkeypatch tests bind; the moved _fetch helper uses the shared requests
# module, which tests stub via app.requests.get.
from routers.seatmap import build_seatmap_router  # noqa: E402
app.include_router(build_seatmap_router(get_sb=lambda: sb))




# _is_bowl_pattern_name (+ _CONSUMER_ZONE_NAME_RE) -> core/helpers.py (BR-CODE-1); aliased at top.


# /api/store/verify-human + /api/store/reserve -> routers/store.py
# (BR-CODE-1 slice 38; bot-gated POSTs via getters — RECAPTCHA_ENABLED/
# _verify_recaptcha/_require_human/STOREFRONT_RESERVE_REQUIRES_AUTH/
# _fetch_owned_ticket_groups_from_db + require_auth. reserve stays a MOCK.)
# The entire /api/store/* surface now lives in routers/store.py.


# ---------- Retail chat (natural-language price/inventory assistant) ----------
#
# Thin proxy in front of the deployed `chat` Supabase edge function (the same
# tool-using assistant behind the SMS/web bots). It already resolves events,
# aggregates price zones, and filters owned-EVO listings by qty + budget
# ("next Yankees home game with tickets under $5"). We proxy rather than let
# the browser call the function directly so that (a) the LLM key stays on the
# edge function, (b) the terminal call is email-gated, (c) the storefront call
# is hard-locked to OWNED inventory, and (d) we avoid the function's
# localhost-only CORS allowlist.
#
# scope discipline: the proxy sets `scope` server-side — the client cannot
# choose it. Terminal → "all" (full market); storefront → "owned" (our owned
# EVO inventory only). The edge function clamps include_all accordingly, so a
# consumer can never widen the storefront beyond owned inventory.

# retail-chat (/api/retail-chat + /api/store/retail-chat) -> routers/retail_chat.py
# (BR-CODE-1 decomposition slice). The concierge flag stays a server config
# global; the getter resolves the live value so the test monkeypatch binds.
from routers.retail_chat import build_retail_chat_router  # noqa: E402
# Re-export the transcript constants + offline reply the router now owns, so
# app_module._RETAIL_CHAT_MAX_TURNS / _MAX_CHARS / _CONCIERGE_OFFLINE_REPLY
# keep resolving for tests (same compat pattern as core/auth).
from routers.retail_chat import (  # noqa: E402,F401
    _RETAIL_CHAT_MAX_TURNS, _RETAIL_CHAT_MAX_CHARS, _CONCIERGE_OFFLINE_REPLY,
    _client_ip, _sanitize_chat_history, _proxy_retail_chat,
)
app.include_router(build_retail_chat_router(
    require_auth=require_auth,
    get_concierge_enabled=lambda: STOREFRONT_CONCIERGE_ENABLED,
))


# The storefront HTML page shells (/store, /store/chat, /store/event/{id},
# /store/discover, /store/tour, /store/about|privacy|terms, /store-sw.js, plus
# /s/{share_id} + /store/shares) moved to routers/storefront_pages.py (BR-CODE-1
# decomposition). The version/base-rewrite + cache helper stays here (tests call
# _read_storefront_html / _render_storefront_page directly and mutate the cache);
# it's injected via the getter so those monkeypatches keep binding.
from routers.storefront_pages import build_storefront_pages_router  # noqa: E402

app.include_router(build_storefront_pages_router(
    STATIC_DIR,
    get_render_storefront_page=lambda: _render_storefront_page,
))


# ---------- Share links (revocable, trackable) ----------
# Server-mediated share links backed by the share_links table. Coexists with
# the stateless filter-in-URL form — recipients see the same event detail UI
# either way, but a stateful share is revocable, has an optional expiry, and
# tracks view count.

_SHARE_FILTER_KEYS = ("zones", "section", "min_price", "max_price", "min_qty")


# _share_to_dict -> core/helpers.py (BR-CODE-1); aliased at top.
# /api/store/share* JSON routes -> routers/shares.py (BR-CODE-1 decomposition
# slice). Getters resolve the live app symbols at request time so the test
# monkeypatches (app.require_sb / app._resolve_event_with_filters) still bind.
from routers.shares import build_shares_router  # noqa: E402
app.include_router(build_shares_router(
    get_require_sb=lambda: require_sb,
    require_auth=require_auth,
    get_resolve_event=lambda: _resolve_event_with_filters,
))


# (/s/{share_id} + /store/shares page shells moved to routers/storefront_pages.py
#  — BR-CODE-1 decomposition; wired with the other storefront page routes.)


# The /store/test/* wiring-harness HTML pages (non-prod gated) live in
# routers/store_test.py (BR-CODE-1 decomp). get_is_production resolves the
# test-patched server symbol at request time so the route tests' monkeypatch
# (app._is_production) keeps binding through the factory.
from routers.store_test import build_store_test_router  # noqa: E402

app.include_router(build_store_test_router(
    STATIC_DIR,
    get_is_production=lambda: _is_production(),
))


# ============================================================
# D2 dashboard mount (unified-for-testing architecture, 2026-05-16)
# ============================================================
# Operator directive: keep 3 services alive (terminal-test, storefront-test,
# d2-orders-dashboard) but route warm runtime traffic to storefront-test during
# dev/test to avoid cold-start drag. At beta, each surface migrates back to its
# own service. PR #129 exposed d2_dashboard.main.router for this purpose.
#
# Mount strategy: prefix-less include_router (resolves bot_chat 180 question A).
# D2's `/api/d2/*` routes land at same paths. D2's standalone `@router.get("/")`
# is shadowed by the earlier `@app.get("/")` homescreen (FastAPI: first-registered
# wins for matching). Auth (question B): D2 routes reuse their own dependency
# injection; the shell's `require_auth` applies on app.py's own routes.
try:
    from d2_dashboard.main import router as d2_router  # type: ignore
    app.include_router(d2_router)
    logging.getLogger(__name__).info("d2_dashboard router mounted at unified shell (%d routes)", len(d2_router.routes))
except Exception as _d2_import_err:  # pragma: no cover — d2 module optional in dev
    logging.getLogger(__name__).warning("d2_dashboard router NOT mounted: %s", _d2_import_err)


# ============================================================
# Scheduler watchdog — durable self-heal for pg_cron wedges
# ============================================================
# With cron.use_background_workers=off, ONE cron job that runs unbounded holds an
# open transaction that blocks cron_should_fire()/the launcher -> the WHOLE pg_cron
# scheduler freezes (observed 3× on 2026-07-01, ~13h degraded). A pg_cron watchdog
# would freeze with everything; a Claude-session cron dies on reconnect. This
# always-on FastAPI service is the one place that survives a DB-side scheduler
# freeze, so the durable watchdog lives here.
#
# Every ~60s it calls scheduler_watchdog_kill_stale_backends() (SECURITY DEFINER,
# service_role-only). That RPC is the single source of truth for "is the scheduler
# wedged": it reads max(start_time) FROM cron.job_run_details and returns
# {wedged:false} when fresh, else terminates the long-running client backend(s)
# holding the launcher and records the kill to health_check_history
# (check_class='scheduler') so it surfaces on the health dashboard. The loop is
# fully wrapped so it never dies, and no-ops cleanly if sb is unconfigured (dev).
#
# Note: with multiple web workers each runs a loop; the RPC is idempotent + self-
# guarding (only kills backends active > p_min_active_seconds), so redundant pokes
# are safe.

_SCHED_WATCHDOG_INTERVAL_S = float(os.environ.get("SCHED_WATCHDOG_INTERVAL_SECONDS", "60"))
_SCHED_WATCHDOG_STALE_MIN = int(os.environ.get("SCHED_WATCHDOG_STALE_MINUTES", "6"))
_SCHED_WATCHDOG_MIN_ACTIVE_S = int(os.environ.get("SCHED_WATCHDOG_MIN_ACTIVE_SECONDS", "300"))
_sched_watchdog_last: dict = {"at": None, "wedged": None, "killed": None,
                              "last_cron_run": None, "error": None}


async def _scheduler_watchdog_tick():
    """One watchdog poke: call the kill RPC (which self-guards on cron freshness)
    and record the outcome. Runs the blocking sync client call off the event loop."""
    def _call():
        return require_sb().rpc(
            "scheduler_watchdog_kill_stale_backends",
            {"p_stale_minutes": _SCHED_WATCHDOG_STALE_MIN,
             "p_min_active_seconds": _SCHED_WATCHDOG_MIN_ACTIVE_S},
        ).execute()

    resp = await asyncio.to_thread(_call)
    data = getattr(resp, "data", None) or {}
    _sched_watchdog_last.update(
        at=datetime.now(timezone.utc).isoformat(),
        wedged=data.get("wedged"), killed=data.get("killed"),
        last_cron_run=data.get("last_cron_run"), error=None)
    killed = data.get("killed") or 0
    if data.get("wedged") and killed:
        _log.warning("scheduler_watchdog: cleared wedge — killed %s backend(s); last_cron_run=%s",
                     killed, data.get("last_cron_run"))
    return data


async def _scheduler_watchdog_loop():
    if sb is None:
        _log.info("scheduler_watchdog: sb unconfigured — watchdog disabled")
        return
    _log.info("scheduler_watchdog: started (every %ss, stale>%smin)",
              _SCHED_WATCHDOG_INTERVAL_S, _SCHED_WATCHDOG_STALE_MIN)
    while True:
        try:
            await _scheduler_watchdog_tick()
        except Exception as e:  # never let the loop die on a transient DB blip
            _sched_watchdog_last.update(
                at=datetime.now(timezone.utc).isoformat(), error=str(e))
            _log.warning("scheduler_watchdog: tick failed: %s", e)
        await asyncio.sleep(_SCHED_WATCHDOG_INTERVAL_S)


@app.on_event("startup")
async def _start_scheduler_watchdog():  # pragma: no cover - startup hook; loop covered via _scheduler_watchdog_tick
    # Fire-and-forget; the loop owns its own error handling and never raises out.
    asyncio.create_task(_scheduler_watchdog_loop())


@app.get("/api/admin/scheduler-watchdog/status")
def scheduler_watchdog_status(_=Depends(require_auth)):
    """Last watchdog tick outcome (auth-gated): current scheduler wedge state,
    last cron run seen, and whether a backend was terminated."""
    return _sched_watchdog_last


# ---------- Site essentials (SEO + browser-tab UX) ----------
#
# Browsers + crawlers probe /robots.txt + /sitemap.xml + /favicon.ico at fixed
# paths; without explicit routes they'd 404 (Railway audit 2026-05-16). These
# moved to routers/site_essentials.py (BR-CODE-1 app.py decomposition); the
# factory takes this deploy's base URL so each env advertises its own sitemap.
from routers.site_essentials import build_site_essentials_router  # noqa: E402

app.include_router(build_site_essentials_router(_STOREFRONT_BASE_URL))


# Static assets (CSS / JS / images) served from /static.
# Keep this LAST so explicit routes above win.
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
