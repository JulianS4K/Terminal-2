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
from fastapi import BackgroundTasks, Body, Depends, FastAPI, Header, HTTPException, Query, Request
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


def _read_storefront_html(name: str) -> str:
    """Read a `static/store/<name>` HTML shell, rewrite the store.js +
    style.css refs to include `?v=<sha>`, swap the hardcoded OG share-card
    base URL for this deploy's actual host, cache the result for the life
    of the container. The source files don't change mid-process.
    """
    cached = _STOREFRONT_HTML_CACHE.get(name)
    if cached is not None:
        return cached
    path = os.path.join(STATIC_DIR, "store", name)
    with open(path, "r", encoding="utf-8") as f:
        html = f.read()
    v = _STOREFRONT_VERSION
    base = _STOREFRONT_BASE_URL
    # Cache-bust asset URLs. Closing-quote specificity prevents accidental
    # matches inside JS strings or CSS url() refs that might be added later.
    html = html.replace(
        '/static/store/store.js"',
        f'/static/store/store.js?v={v}"',
    )
    html = html.replace(
        '/static/store/style.css"',
        f'/static/store/style.css?v={v}"',
    )
    # Replace the hardcoded `https://vibepass-storefront-test.onrender.com`
    # base in OG share-card tags (PR #166) with this deploy's actual host so
    # iMessage/Slack/WhatsApp/Discord/Twitter previews point at the right
    # deploy (Render vs Railway vs custom). When base resolves to the same
    # default this is a no-op string replace.
    if base != "https://vibepass-storefront-test.onrender.com":
        html = html.replace(
            "https://vibepass-storefront-test.onrender.com",
            base,
        )
    _STOREFRONT_HTML_CACHE[name] = html
    return html


def _render_storefront_page(name: str) -> HTMLResponse:
    """Return an HTMLResponse for a static/store/*.html shell with
    Cache-Control: no-cache, must-revalidate so browsers always
    revalidate the HTML on every page load.

    The asset URLs inside the HTML are cache-busted via
    _read_storefront_html()'s `?v=<sha>` rewrite — those keep their
    long-cache friendliness. Only the HTML shell itself needs the
    revalidate header so operators (and returning customers) never
    get trapped on stale HTML pointing at un-versioned asset URLs
    after a deploy. See Round 5 of docs/d1-bot-continues-here-rustling
    -sunrise.md for the bootstrap-trap scenario this prevents.

    Cost: every page load adds one conditional GET (304 Not Modified
    when unchanged — ~1 KB request, ~50 ms latency, no body transfer).
    Trivial.
    """
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
from core.search import search_sql_only as _search_sql_only  # noqa: E402
from core.helpers import clean_opt_url as _clean_opt_url  # noqa: E402
from core.helpers import tevo_runtime_to_http as _tevo_runtime_to_http  # noqa: E402
from core.helpers import normalize_filters as _normalize_filters  # noqa: E402
from core.helpers import ticket_group_to_listing as _ticket_group_to_listing  # noqa: E402
from core.helpers import parse_iso_or_none as _parse_iso_or_none  # noqa: E402
from core.helpers import to_int_or_none as _to_int_or_none  # noqa: E402
from core.helpers import to_num_or_none as _to_num_or_none  # noqa: E402
from core.helpers import haversine_miles as _haversine_miles  # noqa: E402
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
        from supabase import create_client
        sb = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    except ImportError:  # pragma: no cover - import-time dep-missing guard
        _log.warning("WARNING: supabase package not installed. Run: pip install supabase")
    except Exception as e:  # pragma: no cover - import-time init-failure guard
        _log.warning(f"WARNING: could not init Supabase client: {e}")


def require_sb():
    if sb is None:
        raise HTTPException(500, "Supabase not configured.")
    return sb


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

_ip_limiter = _IPRateLimiter()


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
        if not _ip_limiter.check(f"{ip}|{bucket_key}", n, w):
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


@app.get("/")
def root_landing():
    """Unified frontend homescreen (D0, operator directive 2026-05-15 bot_chat #157).
    3 cards: Terminal (broker) / Undelivered (CS+fulfillment) / Store (public).
    STOREFRONT_AS_LANDING=true keeps the old customer-only redirect to /store.
    Liveness moved to /healthz (always was the real Render check path).
    """
    if STOREFRONT_AS_LANDING:
        return RedirectResponse(url="/store", status_code=302)
    return FileResponse(os.path.join(STATIC_DIR, "home", "index.html"))


@app.get("/home")
def home_landing_redirect():
    """Bounce bare /home → /home/ so the terminal's ← HUB button (nav.js,
    href=/home/) resolves the same on the FastAPI shell as on the static CDN
    (publishPath=static serves /home/index.html for the directory form)."""
    return RedirectResponse(url="/home/", status_code=308)


@app.get("/home/")
def home_landing():
    """Serve the unified landing selector at the explicit /home/ path. The
    static CDN serves static/home/index.html here natively; this route gives
    the FastAPI shell parity so HUB → /home/ never 404s regardless of which
    surface (terminal-test CDN vs storefront-test shell) served the page."""
    return FileResponse(os.path.join(STATIC_DIR, "home", "index.html"))


@app.get("/terminal")
def terminal_landing():
    """Bounce bare /terminal → /terminal/ (trailing slash) so the relative
    nav targets generated by nav.js (event.html, movers.html, etc.) resolve
    UNDER /terminal/ instead of falling out to root.

    Without the trailing slash, the browser treats /terminal as a non-directory
    URL and resolves <a href="event.html"> against the parent → /event.html,
    which 404s on this unified shell. PR #165 made the nav.js hrefs relative
    so the same bundle works on the terminal-test CDN (publishPath at root)
    AND under FastAPI mount — this redirect supplies the directory context
    the relative resolution needs on the FastAPI side."""
    return RedirectResponse(url="/terminal/", status_code=308)


@app.get("/terminal/")
def terminal_index():
    """Serve the terminal home (index.html). Same content as the bare /terminal
    redirect target — kept as a distinct handler so the route exists explicitly
    and nav.js's `./` (home) link doesn't fall through to the {page:path} catch-all
    with an empty page string (FastAPI matches it here first)."""
    return FileResponse(os.path.join(STATIC_DIR, "terminal", "index.html"))


@app.get("/terminal/{page:path}")
def terminal_static_proxy(page: str):
    """Proxy /terminal/<anything> → static/terminal/<anything> so the unified
    shell (PR #168 testing-unified architecture) keeps nav.js relative-path
    navigation working without a separate URL scheme.

    Without this route, opening https://<storefront-test>/terminal/event.html
    returns 404 because StaticFiles is only mounted at /static, not /terminal.
    Adding this proxy means nav.js's relative <a href="event.html"> from the
    /terminal/ landing resolves to /terminal/event.html → here → 200 from the
    static file. Same applies to all sibling pages (movers/performer/orders/
    login) plus the lib/ subtree (uplot, supabase, etc.).

    Security: validates `page` against path traversal + restricts to known
    extensions so the proxy can't be turned into an arbitrary-file reader."""
    if not page or page in ("", "/"):  # pragma: no cover - shadowed by the explicit /terminal/ index route
        return FileResponse(os.path.join(STATIC_DIR, "terminal", "index.html"))
    if ".." in page or page.startswith("/") or "\\" in page:
        raise HTTPException(404, "not found")
    # Whitelist extensions — proxy serves UI bundle pieces only, never
    # arbitrary files that might land under static/terminal/ in the future.
    if not page.lower().endswith((".html", ".css", ".js", ".map",
                                   ".svg", ".png", ".jpg", ".jpeg",
                                   ".ico", ".woff", ".woff2", ".webp")):
        raise HTTPException(404, "not found")
    full_path = os.path.join(STATIC_DIR, "terminal", page)
    if not os.path.isfile(full_path):
        raise HTTPException(404, "not found")
    return FileResponse(full_path)


@app.get("/undelivered")
def undelivered_landing():
    """CS fulfillment + sales tracking entry (scaffold — D2 to fill, bot_chat #179).
    Spec: design/undelivered-window-2026-05-08.md."""
    return FileResponse(os.path.join(STATIC_DIR, "undelivered", "index.html"))


# --- D4 / Exos (Bridge) ----------------------------------------------------
# Serve the d4_bridge Vite SPA from this Railway app — same origin as the hub,
# Terminal, Store, and Undelivered (PR #318 — Railway is now the primary host).
# Landing redirect, index handler, path-catch-all for assets + SPA deep links.
# App is built with Vite base '/bridge/' (vite.config.ts) and
# <BrowserRouter basename="/bridge">, so asset refs + client routes resolve
# under this prefix. Build artifact: static/bridge/ (rebuild via
# `npm --prefix d4_bridge run build` then copy dist → static/bridge/).
# Same-origin means the Supabase session in localStorage is shared with the
# hub — a user signed in on the home page is automatically signed into Bridge.
# Returns 404 cleanly until the build artifact is present.
_BRIDGE_DIR = os.path.join(STATIC_DIR, "bridge")


@app.get("/bridge")
def bridge_landing():
    """Bounce bare /bridge → /bridge/ so the SPA's relative + basename routing
    resolves under the directory prefix (same reasoning as /terminal)."""
    return RedirectResponse(url="/bridge/", status_code=308)


@app.get("/bridge/")
def bridge_index():
    """Serve the Exos/Bridge SPA shell. 404 (not 500) when the build isn't
    present yet, so the route is safe to ship ahead of the first dist copy."""
    index_path = os.path.join(_BRIDGE_DIR, "index.html")
    if not os.path.isfile(index_path):
        raise HTTPException(404, "bridge build not present — run `npm --prefix d4_bridge run build` then copy dist → static/bridge/")
    return FileResponse(index_path)


@app.get("/bridge/{page:path}")
def bridge_static_proxy(page: str):
    """Proxy /bridge/<anything> → static/bridge/<anything>. SPA deep links
    (/bridge/event/123 etc.) fall back to index.html for client-side routing.
    Path-traversal guarded + extension-whitelisted (UI bundle pieces only)."""
    if not page or page in ("", "/"):  # pragma: no cover - shadowed by the explicit /bridge/ index route
        index_path = os.path.join(_BRIDGE_DIR, "index.html")
        if not os.path.isfile(index_path):
            raise HTTPException(404, "bridge build not present")
        return FileResponse(index_path)
    if ".." in page or page.startswith("/") or "\\" in page:
        raise HTTPException(404, "not found")
    full_path = os.path.join(_BRIDGE_DIR, page)
    # Real asset → serve it. Whitelist mirrors the /terminal proxy.
    if page.lower().endswith((".html", ".css", ".js", ".map", ".json",
                               ".svg", ".png", ".jpg", ".jpeg", ".ico",
                               ".woff", ".woff2", ".webp", ".txt")):
        if not os.path.isfile(full_path):
            raise HTTPException(404, "not found")
        return FileResponse(full_path)
    # Non-asset path (a client route like /bridge/my-tickets) → SPA shell.
    index_path = os.path.join(_BRIDGE_DIR, "index.html")
    if not os.path.isfile(index_path):
        raise HTTPException(404, "bridge build not present")
    return FileResponse(index_path)


@app.get("/version.json")
def version_json():
    """Public deploy-version endpoint — same _STOREFRONT_VERSION the cache-bust
    pipeline uses, plus the resolution chain that produced it, plus a deploy
    indicator from common Render/Railway env vars. Consumed by nav.js's
    version chip (PR #184) so terminal pages render a real SHA in the topbar
    even though they don't go through _read_storefront_html (which only
    rewrites store pages). Cheap; safe to call cross-origin."""
    return {
        "version": _STOREFRONT_VERSION,
        "render_commit": os.environ.get("RENDER_GIT_COMMIT") or None,
        "railway_commit": os.environ.get("RAILWAY_GIT_COMMIT_SHA") or None,
        "git_commit": os.environ.get("GIT_COMMIT") or None,
        "render_service_id": os.environ.get("RENDER_SERVICE_ID") or None,
        "render_external_url": os.environ.get("RENDER_EXTERNAL_URL") or None,
        "railway_public_domain": os.environ.get("RAILWAY_PUBLIC_DOMAIN") or None,
        "deployed_at_iso": os.environ.get("RENDER_GIT_COMMIT_TIME") or None,
    }


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
        except Exception as e:
            out["ok"] = False
            out["supabase_smoke"] = "fail"
            # Truncate so we don't leak full traces over a public endpoint.
            out["supabase_smoke_error"] = str(e)[:300]
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


@app.get("/api/public/config")
def public_config():
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


# _is_event_seat (+ _PARKING_RE) -> core/helpers.py (BR-CODE-1 pure-helper pass); aliased at top.
@app.get("/api/events/{event_id}")
def event_detail(event_id: int, include_ancillary: bool = False, _=Depends(require_auth)):
    """Event detail. By default filters out parking/suite/hospitality
    ticket_groups so the per-event view shows only real seats.
    Pass include_ancillary=true to see everything."""
    event = client.get_event(event_id)
    try:
        stats = client.get_event_stats(event_id)
    except RuntimeError:
        stats = None
    try:
        stats_event_only = client.get_event_stats(event_id, inventory_type="event")
    except RuntimeError:
        stats_event_only = None
    listings = client.get_listings(event_id, order_by="retail_price ASC")
    raw_groups = listings.get("ticket_groups", []) or []
    if include_ancillary:
        groups = raw_groups
    else:
        groups = [tg for tg in raw_groups if _is_event_seat(tg)]
    return {
        "event": event,
        "stats": stats,
        "stats_event_only": stats_event_only,
        "ticket_groups": groups,
        "ticket_groups_total": len(raw_groups),
        "ticket_groups_filtered_parking": len(raw_groups) - len(groups),
    }


@app.get("/api/events/{event_id}/series")
def event_series(
    event_id: int,
    days: int = 30,
    _=Depends(require_auth),
):
    """Return time-series metrics for one event from event_metrics.

    Query params:
        days: lookback window in days (default 30, clamped to [1, 365])

    Response shape:
        {
          "event_id": 12345,
          "days": 30,
          "series": [
            {
              "t": "2026-04-23T14:00:00+00:00",
              "tickets_count": 1990, "groups_count": 626, "sections_count": 48,
              "retail_min": 39.0, "retail_p25": 180.0, "retail_median": 420.0,
              "retail_mean": 945.12, "retail_p75": 1200.0, "retail_p90": 2500.0,
              "retail_max": 9245.0,
              "wholesale_median": 315.0, "wholesale_mean": 720.0,
              "getin_price": 78.0, "top5_concentration": 0.62, "bid_ask_proxy": 0.22
            },
            ...
          ]
        }
    """
    days = max(1, min(int(days), 365))
    db = require_sb()
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    resp = (
        db.table("event_metrics")
        .select(
            "captured_at,"
            "tickets_count,groups_count,sections_count,"
            "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,"
            "wholesale_median,wholesale_mean,"
            "getin_price,top5_concentration"
        )
        .eq("event_id", event_id)
        .gte("captured_at", since)
        .order("captured_at")
        .execute()
    )
    series = [
        {"t": r["captured_at"], **{k: v for k, v in r.items() if k != "captured_at"}}
        for r in (resp.data or [])
    ]
    return {"event_id": event_id, "days": days, "series": series}


@app.get("/api/events/{event_id}/sections/series")
def event_section_series(
    event_id: int,
    days: int = 30,
    _=Depends(require_auth),
):
    """Section-level time series for one event. One series per section.

    Response shape:
        {
          "event_id": 12345,
          "days": 30,
          "sections": [
            {
              "section": "100",
              "is_ancillary": false,
              "points": [
                {
                  "t": "2026-04-23T14:00:00+00:00",
                  "tickets_count": 42, "groups_count": 11,
                  "retail_min": 420.0, "retail_median": 520.0,
                  "retail_mean": 535.0, "retail_max": 820.0
                },
                ...
              ]
            },
            ...
          ]
        }
    """
    days = max(1, min(int(days), 365))
    db = require_sb()
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    resp = (
        db.table("section_metrics")
        .select(
            "captured_at,section,is_ancillary,"
            "tickets_count,groups_count,"
            "retail_min,retail_median,retail_mean,retail_max"
        )
        .eq("event_id", event_id)
        .gte("captured_at", since)
        .order("captured_at")
        .execute()
    )

    by_section: dict = {}
    for r in (resp.data or []):
        key = r["section"]
        if key not in by_section:
            by_section[key] = {
                "section": key,
                "is_ancillary": bool(r.get("is_ancillary", False)),
                "points": [],
            }
        by_section[key]["points"].append({
            "t": r["captured_at"],
            "tickets_count": r.get("tickets_count"),
            "groups_count": r.get("groups_count"),
            "retail_min": r.get("retail_min"),
            "retail_median": r.get("retail_median"),
            "retail_mean": r.get("retail_mean"),
            "retail_max": r.get("retail_max"),
        })

    # Non-ancillary sections first, then alphabetical
    sections = sorted(
        by_section.values(),
        key=lambda s: (s["is_ancillary"], s["section"]),
    )
    return {"event_id": event_id, "days": days, "sections": sections}


@app.get("/api/performers")
def performers_search(
    q: str | None = None,
    fuzzy: bool = False,
    category_id: int | None = None,
    category_tree: bool = True,
    only_with_upcoming_events: bool | None = None,
    _=Depends(require_auth),
):
    if category_id is not None:
        performers = []
        for page in range(1, 21):
            resp = client.list_performers(
                category_id=category_id,
                category_tree=category_tree,
                only_with_upcoming_events=only_with_upcoming_events,
                order_by="performers.popularity_score DESC",
                per_page=100,
                page=page,
            )
            batch = resp.get("performers", [])
            performers.extend(batch)
            if len(performers) >= resp.get("total_entries", 0) or not batch:
                break
        return {"performers": performers, "total_entries": len(performers)}
    if q:
        return client.search_performers(q=q, fuzzy=fuzzy)
    raise HTTPException(400, "Provide q or category_id")


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
))


def _trip_plan_payload(performer_id: int, home_lat: float, home_lon: float,
                       budget_km: float, home_name: str, days: int,
                       max_events: int | None,
                       budget_usd: float | None = None, qty: int = 1) -> dict:
    """Shared body for the D0/D1 per-performer trip-plan routes.

    Plans the maximum-value multi-city itinerary around a performer's upcoming dates within
    a round-trip km budget — and, when `budget_usd` is given, also within a ticket-spend
    budget (get-in x max(0, qty - owned), owned tickets free). Pure read (v_event_base +
    event_listing_snapshot_daily) + compute — no writes, no upstream API.
    """
    from datetime import date, timedelta

    from trip_planner import plan_performer_trip

    db = require_sb()
    start = date.today()
    end = start + timedelta(days=max(1, min(int(days), 730)))
    budget = max(100.0, min(float(budget_km), 50000.0))
    spend = None if budget_usd is None else max(0.0, min(float(budget_usd), 10_000_000.0))
    return plan_performer_trip(
        db, int(performer_id), float(home_lat), float(home_lon), budget,
        start, end, home_name=(home_name or "Home").strip()[:60], max_events=max_events,
        budget_usd=spend, qty=max(1, min(int(qty), 50)),
    )


# /api/broker/performers/{id}/trip-plan|tour-package + /api/broker/tours/multi|near
# -> routers/broker.py (BR-CODE-1 slice 23; thin auth-gated delegates, the D0
# twins of the D1 store routes). The payload builders below stay in server.py,
# shared with the store routes + passed to both routers via getters.


# _clean_section -> core/helpers.py (BR-CODE-1); aliased at top.
# _tour_dates -> core/helpers.py (BR-CODE-1 pure-helper pass); aliased at top.

# Geographic center of the contiguous US — the neutral "home" used when a caller
# plans location-free (ticket-budget only). Paired with an unlimited travel budget
# so the travel-km dimension never binds and the plan is driven purely by spend.
_US_CENTER_LAT, _US_CENTER_LON = 39.8283, -98.5795


def _tour_package_payload(performer_id: int, home_lat: float | None, home_lon: float | None,
                          qty: int, budget_km: float, home_name: str, days: int,
                          budget_usd: float | None, side: str, clear_at: float,
                          away_margin: float, section_like: str | None = None,
                          prefer_owned: bool = False, max_events: int | None = None,
                          start_date: str | None = None, end_date: str | None = None) -> dict:
    """Shared body for the retail 'tour with the artist' routes (D0 + store).

    Dual-mode: owned-splits where we hold inventory (concerts), market-sourced buy-to-fulfill
    for a team's away games (road owned ~ 0). Pure read + compute — no writes, no upstream API.

    Location-free planning: when home_lat/home_lon are omitted, we plan on the ticket budget
    alone — neutral US-center home + unlimited travel budget so distance never constrains the
    pick (the fan just wants the most stops their money buys, anywhere on the tour).
    max_events caps how many stops to follow; the optimizer keeps the best set that fits.
    start_date/end_date (ISO) set an explicit window; otherwise it's [today, today+days]."""
    from datetime import date as _date, timedelta

    from trip_planner import plan_performer_tour

    db = require_sb()
    start, end = _tour_dates(days)
    today = _date.today()
    if start_date:
        try:
            start = max(today, _date.fromisoformat(start_date[:10]))
        except ValueError:
            pass
    if end_date:
        try:
            end = min(today + timedelta(days=730), _date.fromisoformat(end_date[:10]))
        except ValueError:
            pass
    if end <= start:                       # guard against an inverted/empty window
        end = start + timedelta(days=1)
    spend = None if budget_usd is None else max(0.0, min(float(budget_usd), 10_000_000.0))
    loc_free = home_lat is None or home_lon is None
    hlat = _US_CENTER_LAT if loc_free else float(home_lat)
    hlon = _US_CENTER_LON if loc_free else float(home_lon)
    bkm = 50000.0 if loc_free else max(100.0, min(float(budget_km), 50000.0))
    me = None if max_events is None else max(1, min(int(max_events), 12))
    return plan_performer_tour(
        db, int(performer_id), hlat, hlon,
        max(1, min(int(qty), 50)), bkm,
        start, end, home_name=(home_name or "Home").strip()[:60], budget_usd=spend,
        side=(side if side in ("auto", "away", "home", "concert") else "auto"),
        clear_at=min(max(float(clear_at), 0.01), 1.0),
        away_margin=min(max(float(away_margin), 0.0), 2.0),
        section_like=_clean_section(section_like), prefer_owned=bool(prefer_owned),
        max_events=me,
    )


def _multi_tour_payload(performer_ids: str, home_lat: float, home_lon: float, qty: int,
                        budget_km: float, home_name: str, days: int, budget_usd: float | None,
                        side: str, clear_at: float, away_margin: float,
                        section_like: str | None, prefer_owned: bool) -> dict:
    """'Plan my summer': one routed+priced package across several performers' events."""
    from trip_planner import plan_multi_performer_tour

    # Guard the coercion: performer_ids is a free-text query param, so a
    # non-numeric token (e.g. "abc" or "1,foo,3") must 400, not bubble an
    # uncaught ValueError into a 500. Mirrors the catalog guard at the
    # /api/store/events perf-id gather.
    try:
        ids = [int(x) for x in str(performer_ids).replace(" ", "").split(",") if x][:8]
    except (TypeError, ValueError):
        raise HTTPException(400, "performer_ids must be comma-separated integers")
    if not ids:
        raise HTTPException(400, "performer_ids required (comma-separated, up to 8)")
    db = require_sb()
    start, end = _tour_dates(days)
    spend = None if budget_usd is None else max(0.0, min(float(budget_usd), 10_000_000.0))
    return plan_multi_performer_tour(
        db, ids, float(home_lat), float(home_lon),
        max(1, min(int(qty), 50)), max(100.0, min(float(budget_km), 50000.0)),
        start, end, home_name=(home_name or "Home").strip()[:60], budget_usd=spend,
        side=(side if side in ("auto", "away", "home", "concert") else "auto"),
        clear_at=min(max(float(clear_at), 0.01), 1.0),
        away_margin=min(max(float(away_margin), 0.0), 2.0),
        section_like=_clean_section(section_like), prefer_owned=bool(prefer_owned),
    )


def _discover_payload(home_lat: float, home_lon: float, within_mi: float, days: int,
                      min_shows: int, concerts_only: bool, team_side: str = "home") -> dict:
    """Shared body for reverse-discovery ('tours near me'). Read-only.

    team_side: 'home' (default — D0 broker discover, legacy home-stand grouping) or
    'away' (D1 storefront — surfaces a team by its road games that come to your area)."""
    from trip_planner import discover_tours_near

    db = require_sb()
    start, end = _tour_dates(days)
    return discover_tours_near(
        db, float(home_lat), float(home_lon),
        max(5.0, min(float(within_mi), 1000.0)), start, end,
        min_shows=max(1, min(int(min_shows), 6)),
        event_types=["concert"] if concerts_only else None,
        team_side=(team_side if team_side in ("home", "away") else "home"),
    )


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


@app.get("/api/portfolio")
def portfolio(
    performer_id: int | None = None,
    venue_id: int | None = None,
    watchlist_only: bool = False,
    include_inactive: bool = False,
    _=Depends(require_auth),
):
    """Aggregated portfolio across multiple events.

    Filters (one required):
        performer_id    - events where this performer is primary OR in performer_ids[]
        venue_id        - events at this venue
        watchlist_only  - events that originated from any watchlist row (via watch_sources)

    `include_inactive`: by default we exclude events flagged ghost / completed /
    cancelled / postponed via the event_lifecycle view, so portfolio totals
    don't double-count playoff brackets that the team got eliminated from.

    Returns: { filter, events: [...latest metric per event with `lifecycle`...],
               aggregate: {...rollups...}, inactive_excluded_count }
    """
    if not (performer_id or venue_id or watchlist_only):
        raise HTTPException(400, "Provide performer_id, venue_id, or watchlist_only=true")

    db = require_sb()

    # 1) Resolve event_ids matching the filter
    if performer_id is not None:
        # Single query: primary OR in performer_ids[]. PostgREST .or_() takes the filters
        # comma-separated; cs.{N} is the array-contains operator.
        ev_a = (
            db.table("events").select("id")
            .or_(f"primary_performer_id.eq.{int(performer_id)},performer_ids.cs.{{{int(performer_id)}}}")
            .execute().data
        ) or []
        event_ids = [r["id"] for r in ev_a]
    elif venue_id is not None:
        ev_a = db.table("events").select("id").eq("venue_id", venue_id).execute().data or []
        event_ids = [r["id"] for r in ev_a]
    else:
        ws = db.table("watch_sources").select("event_id").execute().data or []
        event_ids = list({r["event_id"] for r in ws})

    if not event_ids:
        return {
            "filter": {"performer_id": performer_id, "venue_id": venue_id, "watchlist_only": watchlist_only},
            "events": [],
            "aggregate": {
                "events_count": 0, "tickets_total": 0, "owned_tickets_total": 0,
                "owned_share_weighted": None, "retail_value_total": 0,
                "owned_retail_value_total": 0, "retail_median_avg_weighted": None,
                "events_with_owned": 0,
            },
        }

    # 2) Pull event metadata
    ev_meta = (
        db.table("events")
        .select("id,name,occurs_at_local,venue_id,venue_name,venue_location,primary_performer_id,primary_performer_name,state")
        .in_("id", event_ids)
        .execute()
    ).data or []

    # 2b) For performer-filtered queries, look up the performer's home venue(s)
    # AND classification so we can tag is_home for sports only.
    # HOME/AWAY only applies when what_event_type='game' (per TEvo taxonomy:
    # Sports=343 maps to 'game', Concerts/Comedy/Theater do not — Taylor
    # Swift at MSG isn't "home", the venue just hosts).
    home_venue_ids: set[int] = set()
    is_sports_performer: bool = False
    perf_classification: dict | None = None
    if performer_id is not None:
        phv_rows = (
            db.table("performer_home_venues")
            .select("venue_id")
            .eq("performer_id", performer_id)
            .execute()
        ).data or []
        home_venue_ids = {int(r["venue_id"]) for r in phv_rows if r.get("venue_id") is not None}

        pm_rows = (
            db.table("performer_metadata")
            .select("what_event_type, top_category_name, parent_category_name, category_name, genre")
            .eq("performer_id", performer_id).limit(1)
            .execute()
        ).data or []
        if pm_rows:
            perf_classification = pm_rows[0]
            is_sports_performer = (perf_classification.get("what_event_type") == "game")

    # 3) Pull latest metrics row per event
    ev_metrics = (
        db.table("latest_event_metrics")
        .select(
            "event_id,captured_at,tickets_count,groups_count,sections_count,"
            "retail_min,retail_median,retail_p75,retail_p90,retail_max,retail_sum,"
            "getin_price,owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
            "price_dispersion,tail_premium,top5_concentration"
        )
        .in_("event_id", event_ids)
        .execute()
    ).data or []
    metrics_by_id = {m["event_id"]: m for m in ev_metrics}

    # 3.5) Lifecycle classification for each event. Used to exclude ghosts
    # (eliminated playoff brackets, completed games, cancellations) from
    # aggregates by default. Each event row also gets a `lifecycle` block
    # so the UI can show a status badge.
    lc_rows = (
        db.table("event_lifecycle").select("event_id,status,is_active,confidence,reasons")
        .in_("event_id", event_ids).execute()
    ).data or []
    lifecycle_by_id = {r["event_id"]: r for r in lc_rows}
    inactive_excluded_count = 0
    if not include_inactive:
        before = len(event_ids)
        active_ids = {r["event_id"] for r in lc_rows if r.get("is_active")}
        # Keep events that are either active or have no lifecycle row (defensive — shouldn't happen)
        ev_meta = [e for e in ev_meta if e["id"] in active_ids or e["id"] not in lifecycle_by_id]
        inactive_excluded_count = before - len(ev_meta)

    # 4) Merge per-event
    out_events = []
    for ev in ev_meta:
        m = metrics_by_id.get(ev["id"], {})
        # is_home: only meaningful for sports performers. Concerts/comedy/
        # theater performers don't have a home venue concept (the venue just
        # hosts). Gate on what_event_type='game' from performer_metadata.
        is_home = None
        if performer_id is not None and is_sports_performer:
            if ev.get("venue_id") is not None:
                is_home = int(ev["venue_id"]) in home_venue_ids
        out_events.append({
            "id": ev["id"],
            "name": ev["name"],
            "occurs_at_local": ev["occurs_at_local"],
            "state": ev.get("state"),
            "venue_id": ev["venue_id"],
            "venue_name": ev["venue_name"],
            "venue_location": ev["venue_location"],
            "primary_performer_id": ev["primary_performer_id"],
            "primary_performer_name": ev["primary_performer_name"],
            "is_home": is_home,
            "captured_at": m.get("captured_at"),
            "tickets_count": m.get("tickets_count"),
            "groups_count": m.get("groups_count"),
            "sections_count": m.get("sections_count"),
            "retail_min": m.get("retail_min"),
            "retail_median": m.get("retail_median"),
            "retail_p75": m.get("retail_p75"),
            "retail_p90": m.get("retail_p90"),
            "retail_max": m.get("retail_max"),
            "retail_sum": m.get("retail_sum"),
            "getin_price": m.get("getin_price"),
            "owned_groups_count": m.get("owned_groups_count"),
            "owned_tickets_count": m.get("owned_tickets_count"),
            "owned_share": m.get("owned_share"),
            "owned_median_retail": m.get("owned_median_retail"),
            "price_dispersion": m.get("price_dispersion"),
            "tail_premium": m.get("tail_premium"),
            "top5_concentration": m.get("top5_concentration"),
            "lifecycle": lifecycle_by_id.get(ev["id"]),  # status badge data
        })

    # Sort: events with metrics first, soonest first
    out_events.sort(key=lambda e: (e["captured_at"] is None, e.get("occurs_at_local") or ""))

    # 5) Aggregate
    def fnum(v):
        try:
            return float(v) if v is not None else 0.0
        except (TypeError, ValueError):
            return 0.0

    tickets_total = sum(int(e["tickets_count"] or 0) for e in out_events)
    owned_tickets_total = sum(int(e["owned_tickets_count"] or 0) for e in out_events)
    retail_value_total = sum(fnum(e["retail_sum"]) for e in out_events)
    owned_retail_value_total = sum(
        int(e["owned_tickets_count"] or 0) * fnum(e["owned_median_retail"])
        for e in out_events
    )
    events_with_owned = sum(1 for e in out_events if (e["owned_tickets_count"] or 0) > 0)

    # Quantity-weighted retail median
    weighted_num = 0.0
    weighted_den = 0
    for e in out_events:
        if e["retail_median"] is not None and (e["tickets_count"] or 0) > 0:
            weighted_num += fnum(e["retail_median"]) * int(e["tickets_count"])
            weighted_den += int(e["tickets_count"])
    retail_median_avg_weighted = (weighted_num / weighted_den) if weighted_den > 0 else None

    return {
        "filter": {
            "performer_id": performer_id,
            "venue_id": venue_id,
            "watchlist_only": watchlist_only,
            "include_inactive": include_inactive,
        },
        "performer_classification": perf_classification,    # null when not perf-filtered
        "is_sports_performer": is_sports_performer,         # gates the HOME/AWAY UI
        "events": out_events,
        "inactive_excluded_count": inactive_excluded_count,  # ghost / completed / cancelled events filtered out
        "aggregate": {
            "events_count": len(out_events),
            "tickets_total": tickets_total,
            "owned_tickets_total": owned_tickets_total,
            "owned_share_weighted": (owned_tickets_total / tickets_total) if tickets_total > 0 else None,
            "retail_value_total": round(retail_value_total, 2),
            "owned_retail_value_total": round(owned_retail_value_total, 2),
            "retail_median_avg_weighted": round(retail_median_avg_weighted, 2) if retail_median_avg_weighted is not None else None,
            "events_with_owned": events_with_owned,
        },
    }



@app.get("/api/venues")
def venues_search(
    q: str | None = None,
    fuzzy: bool = False,
    lat: float | None = None,
    lon: float | None = None,
    within: int | None = None,
    postal_code: str | None = None,
    _=Depends(require_auth),
):
    if q:
        return client.search_venues(q=q, fuzzy=fuzzy)
    if lat is not None and lon is not None:
        return client.list_venues(lat=lat, lon=lon, within=within or 15)
    if postal_code:
        return client.list_venues(postal_code=postal_code, within=within or 15)
    raise HTTPException(400, "Provide q, or (lat+lon), or postal_code.")


# Catalog detail passthroughs (/api/performers/{id}, /api/venues/{id},
# /api/configurations[/{id}]) live in routers/catalog.py (BR-CODE-1 slice 2).
# get_client is a getter so handlers resolve the live `client` at request time
# (keeps the monkeypatch tests + auth ownership in app.py).
from routers.catalog import build_catalog_router  # noqa: E402

app.include_router(build_catalog_router(get_client=lambda: client, require_auth=require_auth))


# /api/watchlist GET, /api/runs, /api/snapshots/* (read lists) moved to
# routers/lists.py (BR-CODE-1 slice 3). get_require_sb is a getter so handlers
# resolve the live require_sb at request time (keeps monkeypatch tests). The
# watchlist POST/DELETE (mutating) routes stay below.
from routers.lists import build_lists_router  # noqa: E402

app.include_router(build_lists_router(get_require_sb=lambda: require_sb, require_auth=require_auth))


@app.post("/api/watchlist")
def watchlist_add(item: dict = Body(...), _=Depends(require_auth)):
    db = require_sb()
    kind = item.get("kind")
    ext_id = item.get("ext_id")
    label = item.get("label")
    if kind not in ("performer", "venue"):
        raise HTTPException(400, "kind must be performer or venue")
    if not ext_id:
        raise HTTPException(400, "ext_id required")
    try:
        res = db.table("watchlist").insert(
            {"kind": kind, "ext_id": int(ext_id), "label": label or None}
        ).execute()
        return {"ok": True, "item": (res.data or [None])[0]}
    except Exception as e:
        msg = str(e)
        if "duplicate" in msg.lower() or "unique" in msg.lower() or "23505" in msg:
            return {"ok": False, "error": "already in watchlist"}
        raise HTTPException(400, msg)


@app.delete("/api/watchlist/{item_id}")
def watchlist_remove(item_id: int, _=Depends(require_auth)):
    db = require_sb()
    db.table("watchlist").delete().eq("id", item_id).execute()
    return {"ok": True}


# (/api/runs + /api/snapshots/latest + /api/snapshots/velocity moved to
# routers/lists.py — see the include_router above, BR-CODE-1 slice 3.)


def _fire_collect(url: str, secret: str) -> None:
    try:
        requests.post(
            url,
            headers={"X-Cron-Secret": secret, "Content-Type": "application/json"},
            json={},
            timeout=180,
        )
    except Exception as e:
        _log.warning(f"collect fire error: {e}")


# Per-user throttle for /api/collect/run — 1 invocation per 5 min per email.
# Defends against accidental loops or a leaked JWT being used to spam-fire the
# collector. Cheap in-process state; resets on Railway redeploy.
_collect_run_last_call: dict[str, float] = {}
_COLLECT_RUN_COOLDOWN_SEC = 300


@app.post("/api/collect/run")
def collect_run(watchlist_id: int | None = None, user=Depends(require_auth)):
    if not (SUPABASE_URL and CRON_SECRET):
        raise HTTPException(500, "Set SUPABASE_URL and CRON_SECRET to invoke the collector.")
    if watchlist_id is not None and watchlist_id < 1:
        raise HTTPException(400, "watchlist_id must be a positive integer")

    import time
    email = (user or {}).get("email") or "unknown"
    now = time.time()
    last = _collect_run_last_call.get(email, 0)
    if now - last < _COLLECT_RUN_COOLDOWN_SEC:
        wait = int(_COLLECT_RUN_COOLDOWN_SEC - (now - last))
        raise HTTPException(429, f"rate limited — try again in {wait}s")
    _collect_run_last_call[email] = now

    url = f"{SUPABASE_URL}/functions/v1/collect"
    if watchlist_id is not None:
        url += f"?watchlist_id={int(watchlist_id)}"
    threading.Thread(target=_fire_collect, args=(url, CRON_SECRET), daemon=True).start()
    return {"ok": True, "message": "collector fired; poll the runs table"}


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


@app.get("/api/broker/event/{event_id}/overview")
def broker_event_overview(event_id: int, _=Depends(require_auth)):
    """Top-left pane: event header + event-level metrics + zone breakdown.
    Returns latest + prior values so the UI can render delta arrows."""
    db = require_sb()

    # Event header (use cowork's RPC for the rich payload)
    detail = db.rpc("get_broker_event_detail", {"p_event_id": event_id}).execute().data or []
    head = detail[0] if detail else None

    # Latest two event_metrics for delta computation. Pull every column we
    # collect — frontend slices it into Distribution / Volume / Wholesale /
    # Market Structure / Owned panels.
    em_rows = (
        db.table("event_metrics")
        .select(
            "captured_at,"
            # Inventory
            "tickets_count,groups_count,sections_count,median_group_size,"
            "ancillary_groups,ancillary_tickets,"
            # Retail price distribution
            "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,retail_sum,"
            # Wholesale price distribution
            "wholesale_min,wholesale_median,wholesale_mean,wholesale_max,"
            # Market structure / quality
            # NOTE: bid_ask_proxy was dropped in mig 20260428000001 (always 0 — TEvo
            # API doesn't expose true wholesale to this token). Don't re-add to the
            # select or the query 500s.
            "getin_price,top5_concentration,"
            "price_dispersion,tail_premium,"
            # Owned (S4K)
            "owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
            # Splits inventory metrics (mig 20260508230000)
            "splits_min_q,splits_listings_with_singles,splits_listings_with_pairs,"
            "splits_listings_with_3,splits_listings_with_4plus,splits_listings_no_split,"
            "splits_pct_pairs,splits_pct_singles"
        )
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(2)
        .execute()
    ).data or []
    curr = em_rows[0] if len(em_rows) >= 1 else {}
    prev = em_rows[1] if len(em_rows) >= 2 else {}

    metric_keys = [
        # Inventory
        "tickets_count", "groups_count", "sections_count", "median_group_size",
        "ancillary_groups", "ancillary_tickets",
        # Retail distribution
        "retail_min", "retail_p25", "retail_median", "retail_mean", "retail_p75", "retail_p90", "retail_max", "retail_sum",
        # Wholesale distribution
        "wholesale_min", "wholesale_median", "wholesale_mean", "wholesale_max",
        # Market structure
        "getin_price", "top5_concentration",
        "price_dispersion", "tail_premium",
        # Owned
        "owned_groups_count", "owned_tickets_count", "owned_share", "owned_median_retail",
        # Splits inventory
        "splits_min_q", "splits_listings_with_singles", "splits_listings_with_pairs",
        "splits_listings_with_3", "splits_listings_with_4plus", "splits_listings_no_split",
        "splits_pct_pairs", "splits_pct_singles",
    ]
    metrics = {k: {"v": curr.get(k), "delta": _delta(curr.get(k), prev.get(k))} for k in metric_keys}

    # Zone breakdown — owned + market split via cowork's RPC
    zones_owned = db.rpc("get_event_zones_rollup", {"p_event_id": event_id, "p_owned_only": True}).execute().data or []
    zones_market = db.rpc("get_event_zones_rollup", {"p_event_id": event_id, "p_owned_only": False}).execute().data or []

    cadence = _listings_cadence_seconds(head.get("occurs_at_local") if head else None)
    last_pull = curr.get("captured_at")

    # Attach home + away assets (logos, colors). Resolve teams via:
    # 1) primary_performer_id is "home" (per AGENTS.md performer_home_venues semantics)
    # 2) other performer_ids[] entries are away/opponent
    # If event_xref maps to ESPN, additional team_ids come back from espn_event_snapshots.
    perf_ids: list[int] = []
    if head:
        if head.get("primary_performer_id"):
            perf_ids.append(int(head["primary_performer_id"]))
        for pid in (head.get("performer_ids") or []):
            if pid and pid not in perf_ids:
                perf_ids.append(int(pid))
    assets_by_id = _bulk_performer_assets(db, perf_ids)
    home_perf_id = head.get("primary_performer_id") if head else None
    home_assets = assets_by_id.get(int(home_perf_id)) if home_perf_id else None
    away_assets_list = [assets_by_id.get(int(p)) for p in perf_ids if p != home_perf_id and assets_by_id.get(int(p))]

    # Lifecycle classification — flags ghost playoff games, completed events,
    # postponed/cancelled. Used by the UI to render a status banner and to
    # let movers/league/portfolio surfaces filter ghosts out by default.
    # See migration 20260509050000_event_lifecycle for rule definitions.
    try:
        lc_rows = db.rpc("derive_event_lifecycle", {"p_event_id": event_id}).execute().data or []
        lc = lc_rows[0] if lc_rows else None
    except Exception:
        lc = None

    return {
        "event": head,
        "metrics": metrics,
        "zones": {"owned": zones_owned, "market": zones_market},
        "last_pull_at": last_pull,
        "cadence_seconds": cadence,
        "assets": {
            "home": home_assets,
            "away": away_assets_list[0] if away_assets_list else None,
            "all": list(assets_by_id.values()),
        },
        "lifecycle": lc,
    }


_PARKING_ZONE_RE = re.compile(r"\b(parking|garage|valet|lot|hospitality|premium\s*park)\b", re.IGNORECASE)
_PARKING_SECTION_RE = re.compile(r"\b(parking|garage|valet|lot|hospitality|premium\s*park|prepaid|preferred\s*parking|guest\s*parking|vip\s*lot|vip\s*parking)\b", re.IGNORECASE)


@app.get("/api/broker/event/{event_id}/section-zones")
def broker_event_section_zones(event_id: int, _=Depends(require_auth)):
    """Section → zone lookup map for an event. Used by the Market vs Owned
    Depth panel to render a Zone column next to each ticket_group.

    Resolution: curated performer_zones (priority) → derive_zone_fallback()
    keyword/numeric heuristic → null.
    """
    db = require_sb()
    ev = (db.table("events")
            .select("primary_performer_id, venue_id")
            .eq("id", event_id).limit(1).execute().data or [])
    if not ev:
        return {"map": {}, "source_mix": {}}
    primary_perf = ev[0].get("primary_performer_id")
    venue_id = ev[0].get("venue_id")

    # Distinct (section, row) pairs in the event's latest listings snapshot
    latest = (db.table("listings_snapshots")
                .select("captured_at").eq("event_id", event_id)
                .order("captured_at", desc=True).limit(1).execute().data or [])
    if not latest:
        return {"map": {}, "source_mix": {}}
    latest_at = latest[0]["captured_at"]
    sec_rows = (db.table("listings_snapshots")
                  .select("section, row")
                  .eq("event_id", event_id).eq("captured_at", latest_at)
                  .execute().data or [])
    secs = list({(r.get("section"), r.get("row")) for r in sec_rows})

    # Build map. For each (section, row), call derive_zone_fallback for the system
    # answer; also check performer_zones for curated. Curated wins.
    section_map: dict[str, dict] = {}
    source_mix: dict[str, int] = {}

    # Curated lookups (in batch) — query performer_zone_section_rules joined with performer_zones
    if primary_perf and venue_id:
        cur_rules = (db.table("performer_zones")
                       .select("id, zone, performer_zone_section_rules(section_pattern, match_type, row_pattern, priority)")
                       .eq("performer_id", primary_perf).eq("venue_id", venue_id)
                       .eq("source", "curated")
                       .execute().data or [])
        # Flatten rules: list of (zone, pattern, match_type, row_pattern, priority)
        rules: list[tuple] = []
        for cz in cur_rules:
            for rule in (cz.get("performer_zone_section_rules") or []):
                rules.append((cz["zone"], rule.get("section_pattern") or "",
                              rule.get("match_type") or "exact",
                              rule.get("row_pattern"), rule.get("priority") or 0))
        rules.sort(key=lambda r: -r[4])  # priority desc

        def _curated_match(section: str | None, row: str | None) -> str | None:
            if not section: return None
            sec = section
            for zone, patt, mtype, rpatt, _pri in rules:
                hit = False
                if mtype == "exact":     hit = sec == patt
                elif mtype == "prefix":  hit = sec.lower().startswith(patt.lower())
                elif mtype == "suffix":  hit = sec.lower().endswith(patt.lower())
                elif mtype == "substring": hit = patt.lower() in sec.lower()
                elif mtype == "regex":
                    try: hit = bool(re.search(patt, sec, re.IGNORECASE))
                    except re.error: hit = False
                if hit and rpatt and row:
                    try: hit = bool(re.search(rpatt, row, re.IGNORECASE))
                    except re.error: pass
                if hit: return zone
            return None
    else:
        def _curated_match(section, row): return None

    # Resolve each section
    for section, row in secs:
        z_curated = _curated_match(section, row)
        if z_curated:
            section_map[section] = {"zone": z_curated, "source": "curated"}
            source_mix["curated"] = source_mix.get("curated", 0) + 1
            continue
        # Fallback: derive_zone_fallback RPC
        try:
            res = db.rpc("derive_zone_fallback", {"p_section": section, "p_row": row}).execute().data
            zfall = res if isinstance(res, str) else None
        except Exception:
            zfall = None
        if zfall:
            section_map[section] = {"zone": zfall, "source": "fallback"}
            source_mix["fallback"] = source_mix.get("fallback", 0) + 1
        else:
            section_map[section] = {"zone": None, "source": "unmapped"}
            source_mix["unmapped"] = source_mix.get("unmapped", 0) + 1

    return {"map": section_map, "source_mix": source_mix}


@app.get("/api/broker/event/{event_id}/zones")
def broker_event_zones(event_id: int, include_parking: bool = False, _=Depends(require_auth)):
    """Per-zone latest metrics with full distribution.

    Picks ONE zone_source per event by priority: curated > fallback > unmapped.
    User spec: never show two competing zone classifications side-by-side.
    If the event has any curated zones, only curated rows surface; the fallback
    layer is redundant noise in that case (mostly leftover sections that didn't
    match a curated rule, with tiny ticket counts).

    Returns latest snapshot per zone within the chosen source. zone_metrics has
    the same shape as event_metrics (full percentile distribution + owned
    breakdown).
    """
    db = require_sb()
    rows = (
        db.table("zone_metrics")
        .select(
            "zone, zone_source, captured_at, "
            "tickets_count, groups_count, sections_count, "
            "retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum, "
            "wholesale_min, wholesale_median, wholesale_mean, wholesale_max, "
            "getin_price, "
            "owned_groups_count, owned_tickets_count, owned_share, owned_median_retail"
        )
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(1000)
        .execute()
    ).data or []

    # 1) Decide which source to use. Priority: curated > fallback > unmapped.
    sources_present = {r.get("zone_source") for r in rows}
    if "curated" in sources_present:
        chosen_source = "curated"
    elif "fallback" in sources_present:
        chosen_source = "fallback"
    elif "unmapped" in sources_present:
        chosen_source = "unmapped"
    else:
        chosen_source = None

    # 2) Filter to chosen source, then take latest per zone (rows are pre-sorted desc).
    if chosen_source is None:
        return {"zones": [], "count": 0, "source": None, "available_sources": []}

    seen = set()
    out = []
    parking_count = 0
    for r in rows:
        if r.get("zone_source") != chosen_source:
            continue
        z = r.get("zone")
        if z in seen:
            continue
        # Auto-hide parking/garage/hospitality unless caller explicitly opts in.
        # Zone names like "Parking East", "Garage A", "Premium Parking", "Hospitality Tent".
        if not include_parking and z and _PARKING_ZONE_RE.search(z):
            parking_count += 1
            continue
        seen.add(z)
        out.append(r)

    # 3) Sort by tickets_count desc within the chosen source
    out.sort(key=lambda r: -(r.get("tickets_count") or 0))

    return {
        "zones": out,
        "count": len(out),
        "source": chosen_source,
        "available_sources": sorted(sources_present),
        "parking_hidden": parking_count,
        "include_parking": include_parking,
    }


# /api/broker/event/{id}/section-metrics + /api/broker/watchlist-movers +
# /api/broker/event/{id}/orders -> routers/broker.py (BR-CODE-1 slice 25;
# standalone DB-read routes, require_sb only + the pure core delta/cadence helpers).
# /api/broker/event/{id}/raw-tevo -> routers/broker.py (BR-CODE-1 slice 24).


@app.get("/api/broker/performer/{performer_id}/espn")
def broker_performer_espn(performer_id: int, _=Depends(require_auth)):
    """ESPN context for a TEvo performer. Resolves performer_id → ESPN team_id
    via performer_external_ids (source='espn'), then pulls the latest team
    snapshot, current injuries, recent news, and the last 5 game snapshots
    involving that team.

    Returns: {
      applicable, performer_id, espn_team_id, league,
      team:    { record_summary, standing_summary, streak, win_pct, captured_at },
      injuries:[{ athlete_name, position, status, injury_type, return_date, ... }],
      news:    [{ headline, description, url, published_at, type }],
      recent:  [{ espn_event_id, captured_at, home_team_id, away_team_id, home_score, away_score, status_short }]
    }
    """
    db = require_sb()
    pei = (db.table("performer_external_ids")
             .select("performer_id, external_id, league, meta")
             .eq("performer_id", performer_id).eq("source", "espn")
             .limit(1).execute().data or [])
    if not pei:
        return {"applicable": False, "reason": "no ESPN mapping for this performer"}
    espn_team_id = str(pei[0]["external_id"])
    league       = pei[0]["league"]

    # Latest team snapshot (one row, most recent captured_at).
    team_rows = (db.table("espn_team_snapshots")
                   .select("captured_at, wins, losses, ties, win_pct, games_back, playoff_seed, conference_rank, division_rank, record_summary, standing_summary, streak")
                   .eq("espn_team_id", espn_team_id).eq("espn_league", league)
                   .order("captured_at", desc=True).limit(1).execute().data or [])

    # Current injuries — latest snapshot per athlete (last 24h).
    injuries = (db.table("espn_injuries_snapshots")
                  .select("athlete_id, athlete_name, position, status, injury_type, short_comment, return_date, captured_at")
                  .eq("espn_team_id", espn_team_id).eq("espn_league", league)
                  .gte("captured_at", (datetime.now(timezone.utc) - timedelta(hours=36)).isoformat())
                  .order("captured_at", desc=True).limit(50).execute().data or [])
    seen = set(); inj_dedup = []
    for x in injuries:
        k = x.get("athlete_id")
        if k in seen: continue
        seen.add(k); inj_dedup.append(x)

    # Recent news (last 30 days, top 8).
    news = (db.table("espn_news")
              .select("headline, description, url, published_at, type")
              .eq("espn_team_id", espn_team_id).eq("espn_league", league)
              .order("published_at", desc=True).limit(8).execute().data or [])

    # Last 5 finished/upcoming game snapshots where this team is home or away.
    recent = []
    try:
        recent = (db.rpc("get_team_recent_games", {"p_espn_team_id": espn_team_id, "p_league": league, "p_limit": 5}).execute().data or [])
    except Exception:
        # Fallback: query espn_event_snapshots directly (latest snap per event).
        rows_h = (db.table("espn_event_snapshots")
                    .select("espn_event_id, captured_at, status_short, state, home_team_id, away_team_id, home_score, away_score")
                    .eq("home_team_id", espn_team_id).eq("espn_league", league)
                    .order("captured_at", desc=True).limit(15).execute().data or [])
        rows_a = (db.table("espn_event_snapshots")
                    .select("espn_event_id, captured_at, status_short, state, home_team_id, away_team_id, home_score, away_score")
                    .eq("away_team_id", espn_team_id).eq("espn_league", league)
                    .order("captured_at", desc=True).limit(15).execute().data or [])
        all_rows = rows_h + rows_a
        seen_ev = set(); merged = []
        for x in sorted(all_rows, key=lambda r: r.get("captured_at", ""), reverse=True):
            ek = x.get("espn_event_id")
            if ek in seen_ev: continue
            seen_ev.add(ek); merged.append(x)
            if len(merged) >= 5: break
        recent = merged

    return {
        "applicable": True,
        "performer_id": performer_id,
        "espn_team_id": espn_team_id,
        "league": league,
        "team":     team_rows[0] if team_rows else None,
        "injuries": inj_dedup[:20],
        "news":     news,
        "recent":   recent,
    }


@app.post("/api/admin/seed-home-venues")
def admin_seed_home_venues(league: str, _=Depends(require_auth)):
    """One-shot admin: for every performer in performer_external_ids
    (source='espn') in the given league that's NOT yet in performer_home_venues,
    fetch /v9/performers/{id} from TEvo and upsert a home-venue row.

    Used to backfill MLS (which had 0 rows in performer_home_venues despite
    30 teams in performer_external_ids) and any other league that's missing
    venue resolution.

    Returns: { league, scanned, added, skipped_no_venue, errors }
    """
    db = require_sb()
    pei = (db.table("performer_external_ids")
             .select("performer_id, external_id, external_name, league")
             .eq("source", "espn").eq("league", league).execute().data or [])
    have = {r["performer_id"] for r in (db.table("performer_home_venues")
             .select("performer_id").eq("league", league).execute().data or [])}
    todo = [r for r in pei if r["performer_id"] not in have]

    added = 0; skipped = 0; errors: list[str] = []
    for r in todo:
        pid = int(r["performer_id"])
        try:
            perf = client.get_performer(pid, include_opponents=False)
            # TEvo returns the home venue under `venue` (singular) for sports.
            # `home_venue` is also populated for some leagues — fall back to it.
            v = perf.get("venue") or perf.get("home_venue") or {}
            vid = v.get("id")
            if not vid:
                skipped += 1
                continue
            addr = v.get("address") or {}
            location = ", ".join(x for x in [addr.get("locality"), addr.get("region")] if x) or v.get("location")
            db.table("performer_home_venues").upsert({
                "performer_id":   pid,
                "performer_name": perf.get("name") or r.get("external_name"),
                "venue_id":       int(vid),
                "venue_name":     v.get("name"),
                "venue_location": location,
                "league":         league,
                "source":         "tevo_lookup",
            }, on_conflict="performer_id").execute()
            added += 1
        except Exception as e:
            errors.append(f"performer_id={pid}: {e}")
    return {"league": league, "scanned": len(todo), "added": added, "skipped_no_venue": skipped, "errors": errors[:10]}


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
    """Upsert a TEvo event-detail dict into our `events` table. Returns the
    event id if upserted, None otherwise."""
    eid = ev.get("id")
    if not eid:
        return None
    venue = ev.get("venue") or {}
    perfs = ev.get("performances") or []
    primary = next((p.get("performer") for p in perfs if p.get("primary")), None) \
              or (perfs[0].get("performer") if perfs else None) \
              or {}
    row = {
        "id": int(eid),
        "name": ev.get("name"),
        "occurs_at_local": ev.get("occurs_at_local") or ev.get("occurs_at"),
        "state": ev.get("state"),
        "venue_id": venue.get("id"),
        "venue_name": venue.get("name"),
        "venue_location": venue.get("location"),
        "primary_performer_id": primary.get("id"),
        "primary_performer_name": primary.get("name"),
        "performer_ids": [
            p.get("performer", {}).get("id")
            for p in perfs
            if isinstance(p.get("performer", {}).get("id"), int)
        ],
        "popularity_score": ev.get("popularity_score"),
        "long_term_popularity_score": ev.get("long_term_popularity_score"),
        "configuration_id": (ev.get("configuration") or {}).get("id"),
        "configuration_name": (ev.get("configuration") or {}).get("name"),
        "event_type": ev.get("category", {}).get("slug")
                      if isinstance(ev.get("category"), dict)
                      else ev.get("category"),
    }
    try:
        db.table("events").upsert(row, on_conflict="id").execute()
        return int(eid)
    except Exception as e:
        _log.warning(f"events upsert failed for {eid}: {e}")
        return None


@app.post("/api/admin/wire-sg-to-tevo")
def admin_wire_sg_to_tevo(
    dry_run: bool = False,
    venue_overlap_min: float = 0.34,
    _=Depends(require_auth),
):
    """For every SG event with seller-direct listings and no TEvo xref:
      1. Pull distinct (sg_event_id, sg_event_name, sg_event_date, sg_venue)
      2. Call TEvo /v9/events/search for the name on that date
      3. Pick the result whose venue tokens overlap >= venue_overlap_min
      4. Upsert that TEvo event into our `events` table
      5. Call sg_attempt_event_xref (which inserts the xref row)

    dry_run=true: returns proposed matches without writing anything.
    Returns: counts + per-event audit so you can see what matched and why.
    """
    db = require_sb()
    rows = (db.table("seatgeek_seller_listings")
              .select("sg_event_id,sg_event_name,sg_event_date,sg_venue")
              .execute().data or [])
    seen = set()
    todo: list[dict] = []
    for r in rows:
        key = r.get("sg_event_id")
        if key in seen or not key:
            continue
        seen.add(key)
        # Skip already-xref'd events
        existing = (db.table("seatgeek_event_xref")
                      .select("tevo_event_id").eq("sg_event_id", key)
                      .limit(1).execute().data or [])
        if existing:
            continue
        todo.append(r)

    audit: list[dict] = []
    new_xrefs = 0
    no_match = 0
    inserted_events = 0
    errors: list[str] = []

    for r in todo:
        sg_event_id = int(r["sg_event_id"])
        sg_name = r.get("sg_event_name") or ""
        sg_date = r.get("sg_event_date")  # YYYY-MM-DD string
        sg_venue = r.get("sg_venue") or ""
        if not sg_date:
            audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                          "matched": False, "reason": "no sg_event_date"})
            no_match += 1
            continue
        # 1-day window around sg_date
        from datetime import datetime as _dt, timedelta as _td
        try:
            d = _dt.fromisoformat(str(sg_date))
        except Exception:
            audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                          "matched": False, "reason": f"bad date {sg_date}"})
            no_match += 1
            continue

        try:
            resp = client.search_events_fulltext(
                q=sg_name,
                **{"occurs_at.gte": d.isoformat(),
                   "occurs_at.lt":  (d + _td(days=1)).isoformat()},
                per_page=20,
            )
        except Exception as e:
            errors.append(f"sg_event_id={sg_event_id}: TEvo search failed: {e}")
            continue
        hits = (resp or {}).get("events", []) or []
        if not hits:
            audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                          "matched": False, "reason": "TEvo: 0 hits on date"})
            no_match += 1
            continue
        # Score by venue overlap
        scored = []
        for h in hits:
            v = (h.get("venue") or {}).get("name") or ""
            ov = _venue_overlap(sg_venue, v)
            scored.append((ov, h))
        scored.sort(key=lambda x: -x[0])
        best_ov, best = scored[0]
        if best_ov < venue_overlap_min:
            audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                          "matched": False, "best_venue": (best.get("venue") or {}).get("name"),
                          "best_overlap": round(best_ov, 2),
                          "reason": f"venue overlap {best_ov:.2f} < {venue_overlap_min}"})
            no_match += 1
            continue

        if dry_run:
            audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                          "tevo_event_id": best.get("id"),
                          "tevo_name": best.get("name"),
                          "tevo_venue": (best.get("venue") or {}).get("name"),
                          "venue_overlap": round(best_ov, 2),
                          "matched": True, "dry_run": True})
            new_xrefs += 1
            continue

        # Upsert TEvo event into events table
        new_eid = _upsert_tevo_event_into_events(db, best)
        if new_eid:
            inserted_events += 1

        # Call sg_attempt_event_xref to write the xref row
        try:
            res = db.rpc("sg_attempt_event_xref", {
                "p_sg_event_id": sg_event_id,
                "p_sg_event_name": sg_name,
                "p_sg_event_date": str(sg_date),
                "p_sg_venue": sg_venue,
            }).execute()
            matched_tevo_id = res.data
        except Exception as e:
            errors.append(f"sg_event_id={sg_event_id}: xref RPC failed: {e}")
            continue

        if matched_tevo_id:
            new_xrefs += 1
            audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                          "tevo_event_id": int(matched_tevo_id),
                          "tevo_name": best.get("name"),
                          "tevo_venue": (best.get("venue") or {}).get("name"),
                          "venue_overlap": round(best_ov, 2),
                          "matched": True})
        else:
            audit.append({"sg_event_id": sg_event_id, "sg_name": sg_name,
                          "tevo_event_id": int(best.get("id") or 0),
                          "matched": False,
                          "reason": "TEvo event ingested but xref RPC returned NULL "
                                    "(matcher rejected — likely performer-name mismatch)"})

    return {
        "candidates": len(todo),
        "newly_linked": new_xrefs,
        "no_match": no_match,
        "tevo_events_ingested": inserted_events,
        "errors": errors[:20],
        "dry_run": dry_run,
        "audit": audit,
    }


@app.post("/api/admin/wire-sd-to-tevo")
def admin_wire_sd_to_tevo(_=Depends(require_auth)):
    """Same as wire-sg-to-tevo but for SeatData. SD events come in with
    sd_event_name/date/venue; we search TEvo and call sd's existing
    matcher (manual upsert via auto_name_date_venue path).

    Currently SD only has 1 event (Knicks G5, already xref'd) — this route
    is futureproofing for when more SD events arrive."""
    db = require_sb()
    rows = (db.table("seatdata_sales_snapshots")
              .select("sd_event_id").execute().data or [])
    seen = {r.get("sd_event_id") for r in rows if r.get("sd_event_id")}
    if not seen:
        return {"candidates": 0, "newly_linked": 0, "audit": []}

    audit = []
    new_xrefs = 0
    for sd_id in seen:
        existing = (db.table("seatdata_event_xref")
                      .select("tevo_event_id").eq("sd_event_id", sd_id)
                      .limit(1).execute().data or [])
        if existing:
            audit.append({"sd_event_id": sd_id, "matched": True,
                          "tevo_event_id": existing[0]["tevo_event_id"],
                          "note": "already linked"})
            continue
        # No SD event-detail call here yet — when more SD events arrive we
        # plumb in the SD-side metadata fetch and search TEvo. Logged as
        # missing for now.
        audit.append({"sd_event_id": sd_id, "matched": False,
                      "reason": "no metadata available; manual link required"})
    return {
        "candidates": len(seen),
        "newly_linked": new_xrefs,
        "already_linked": sum(1 for a in audit if a["matched"]),
        "audit": audit,
    }


# (broker_event_espn moved to routers/broker.py — slice 11)


@app.get("/api/broker/event/{event_id}/chart-data")
def broker_event_chart_data(
    event_id: int,
    days: int = 30,
    hours: int | None = None,
    range: str | None = None,   # "6h" "24h" "3d" "7d" "30d" "all"
    _=Depends(require_auth),
):
    """Stage 2 chart data: 4 default time-series + 4 overlay event streams.

    Series:
      prices_owned   — event_metrics.owned_median_retail
      prices_market  — event_metrics.retail_median
      counts_owned   — event_metrics.owned_tickets_count
      counts_market  — event_metrics.tickets_count
      home_standings — espn_team_snapshots filtered to home team (win_pct over time)
      away_standings — espn_team_snapshots filtered to away team (win_pct over time)

    Overlay events (vertical markers):
      injuries     — espn_injuries_snapshots, only is_baseline=false rows (real changes)
      roster_moves — espn_athlete_team_history with transaction_type in (traded, released)

    Last-5 record:
      espn_event_snapshots state='post' for either team, last 5 by captured_at,
      W/L computed from home_team_id + scores.
    """
    # Time range: prefer `range` (preset string) over `hours` over `days`.
    # Presets: 6h, 24h, 3d, 7d, 30d, all. Min 6h, max 30d (cap user-driven
    # views; 'all' bypasses the cap and pulls everything we have).
    range_hours: int | None = None
    if range:
        rmap = {"6h": 6, "24h": 24, "1d": 24, "3d": 72, "7d": 168, "30d": 720, "all": None}
        if range.lower() not in rmap:
            raise HTTPException(400, f"range must be one of {list(rmap)}")
        range_hours = rmap[range.lower()]
    elif hours is not None:
        range_hours = max(6, min(int(hours), 720))
    else:
        days = max(1, min(int(days), 180))
        range_hours = days * 24

    db = require_sb()
    if range_hours is None:
        # 'all' — pick a far-past floor so SELECTs still index well
        since_iso = "1970-01-01T00:00:00+00:00"
    else:
        since_iso = (datetime.now(timezone.utc) - timedelta(hours=range_hours)).isoformat()
    days = (range_hours // 24) if range_hours else 9999  # back-compat for any consumer reading `days`

    # 1) Full event_metrics distribution as time series — chart workbench
    # toggles any subset on/off. SELECT every column we collect.
    em = (
        db.table("event_metrics")
        .select(
            "captured_at,"
            "tickets_count,groups_count,sections_count,median_group_size,"
            "ancillary_groups,ancillary_tickets,"
            "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,retail_sum,"
            "wholesale_min,wholesale_median,wholesale_mean,wholesale_max,"
            "getin_price,top5_concentration,price_dispersion,tail_premium,"
            "owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
            "nonowned_median_retail,"   # NEW: median of non-S4K listings ("MARKET NOT US")
            "splits_min_q,splits_pct_pairs,splits_pct_singles,"
            "splits_listings_with_singles,splits_listings_with_pairs,"
            "splits_listings_with_3,splits_listings_with_4plus,splits_listings_no_split"
        )
        .eq("event_id", event_id)
        .gte("captured_at", since_iso)
        .order("captured_at")
        .execute()
    ).data or []

    def _series(col: str) -> list:
        return [{"t": r["captured_at"], "v": r.get(col)} for r in em]

    # Legacy aliases (preserved for backwards-compat)
    prices_owned    = _series("owned_median_retail")
    prices_market   = _series("retail_median")
    prices_nonowned = _series("nonowned_median_retail")  # NEW — "MARKET NOT US"
    counts_owned    = _series("owned_tickets_count")
    counts_market   = _series("tickets_count")

    # AXS box-office series (median section price + listing count over time).
    # Sourced from axs_event_snapshots via RPC; empty until AXS snapshots are
    # AQ-linked to this tevo_event_id and ingested. Overlaid on both the
    # median-price and the listing-count charts alongside TEvo/market.
    try:
        axs_rows = (
            db.rpc("get_axs_event_price_series",
                   {"p_event_id": event_id, "p_since": since_iso}).execute()
        ).data or []
    except Exception:
        axs_rows = []
    prices_axs = [{"t": r["captured_at"], "v": r.get("median_price")} for r in axs_rows]
    counts_axs = [{"t": r["captured_at"], "v": r.get("listings_count")} for r in axs_rows]

    # 2) Resolve home + away ESPN team ids from event_xref → espn_event_snapshots
    home_team_id = away_team_id = home_slug = away_slug = home_league = None
    xref = (
        db.table("event_xref").select("espn_event_id,espn_slug,espn_league")
        .eq("tevo_event_id", event_id).limit(1).execute()
    ).data or []
    if xref:
        x = xref[0]
        home_league = x["espn_league"]
        snap = (
            db.table("espn_event_snapshots")
            .select("home_team_id,away_team_id")
            .eq("espn_event_id", x["espn_event_id"])
            .order("captured_at", desc=True).limit(1)
            .execute()
        ).data or []
        if snap:
            home_team_id = snap[0].get("home_team_id")
            away_team_id = snap[0].get("away_team_id")
            home_slug = away_slug = x["espn_slug"]

    def _team_standings(team_id: str | None) -> list:
        if not team_id or not home_league:
            return []
        rows = (
            db.table("espn_team_snapshots")
            .select("captured_at,win_pct,wins,losses,games_back,playoff_seed,conference_rank,division_rank,record_summary,streak")
            .eq("espn_team_id", team_id)
            .eq("espn_league", home_league)   # league-scope: same id exists across leagues
            .gte("captured_at", since_iso)
            .order("captured_at")
            .execute()
        ).data or []
        return rows

    home_standings_rows = _team_standings(home_team_id)
    away_standings_rows = _team_standings(away_team_id)

    def _stand_series(rows: list, field: str) -> list:
        """Pluck one ESPN standings field into a t,v time-series."""
        return [{"t": r["captured_at"], "v": r.get(field)} for r in rows]

    # Legacy field kept for backwards-compat: home_standings/away_standings are
    # the win_pct series with extra metadata. New per-field series are emitted
    # separately so the chart workbench can plot any combination.
    home_standings = [{"t": r["captured_at"], "v": r.get("win_pct"),
                       "wins": r.get("wins"), "losses": r.get("losses"),
                       "seed": r.get("playoff_seed"), "rec": r.get("record_summary")}
                      for r in home_standings_rows]
    away_standings = [{"t": r["captured_at"], "v": r.get("win_pct"),
                       "wins": r.get("wins"), "losses": r.get("losses"),
                       "seed": r.get("playoff_seed"), "rec": r.get("record_summary")}
                      for r in away_standings_rows]

    # 3) Injury rows. Originally filtered is_baseline=false ("real status flips
    # only") but espn-collect's is_baseline detection only works for MLB+NHL —
    # NBA/NFL/MLS/WNBA/WC always come back with is_baseline=true, so the strict
    # filter hid 100% of their injury data. Relaxed to include baseline rows
    # too. Front-end tags each marker with `is_change` so the user can tell
    # status flips apart from initial-baseline injuries (copilot lane: fix
    # the upstream is_baseline detection in espn-collect).
    # CRITICAL: filter by espn_league too — espn_team_id is league-scoped
    # (id "18" = NBA Knicks AND MLB Pirates AND NFL Saints AND NHL #18 AND WNBA #18).
    # Without the league filter we'd pull 229 rows when only 12 are real.
    inj_rows = (
        db.table("espn_injuries_snapshots")
        .select("captured_at,athlete_name,status,injury_type,short_comment,espn_team_id,is_baseline")
        .in_("espn_team_id", [t for t in (home_team_id, away_team_id) if t])
        .eq("espn_league", home_league or "")
        .gte("captured_at", since_iso)
        .order("captured_at")
        .execute()
    ).data or [] if (home_team_id or away_team_id) and home_league else []
    injuries = [{"t": r["captured_at"], "athlete": r.get("athlete_name"),
                 "status": r.get("status"), "team": "home" if r.get("espn_team_id") == home_team_id else "away",
                 "comment": r.get("short_comment"),
                 "is_change": (r.get("is_baseline") is False)}  # true = real status flip; false = baseline row
                for r in inj_rows]

    # 4) Roster moves (trades + releases)
    rm_rows = []
    if (home_team_id or away_team_id) and home_league:
        rm_rows = (
            db.table("espn_athlete_team_history")
            .select("detected_at,transaction_type,prior_team_id,espn_team_id,espn_athlete_id,notes")
            .in_("transaction_type", ["traded", "released"])
            .eq("espn_league", home_league)   # league-scope; team_id+league together is the unique team
            .gte("detected_at", since_iso)
            .or_(",".join(filter(None, [
                f"espn_team_id.eq.{home_team_id}" if home_team_id else None,
                f"espn_team_id.eq.{away_team_id}" if away_team_id else None,
                f"prior_team_id.eq.{home_team_id}" if home_team_id else None,
                f"prior_team_id.eq.{away_team_id}" if away_team_id else None,
            ])) or "espn_team_id.eq.NULL")
            .order("detected_at")
            .execute()
        ).data or []
    roster_moves = [{"t": r["detected_at"], "type": r["transaction_type"],
                     "athlete_id": r.get("espn_athlete_id"),
                     "from_team": r.get("prior_team_id"), "to_team": r.get("espn_team_id"),
                     "notes": r.get("notes")} for r in rm_rows]

    # 5) Last-5 record per team
    def _last5(team_id: str | None) -> list:
        if not team_id or not home_league:
            return []
        rows = (
            db.table("espn_event_snapshots")
            .select("captured_at,espn_event_id,home_team_id,away_team_id,home_score,away_score,state")
            .or_(f"home_team_id.eq.{team_id},away_team_id.eq.{team_id}")
            .eq("espn_league", home_league)   # league-scope: id "20" exists in NBA + MLB + NFL etc.
            .eq("state", "post")
            .order("captured_at", desc=True).limit(25)
            .execute()
        ).data or []
        # Dedupe by espn_event_id before taking 5 — the collector re-snapshots
        # each finished game many times, so a raw .limit(5) on snapshot rows
        # would repeat one game up to 5×. Rows are captured_at-desc, so the
        # first row per event is its latest snapshot. Mirrors the dedupe in the
        # /performer/{id}/espn fallback above.
        out = []
        seen_ev = set()
        for r in rows:
            ek = r.get("espn_event_id")
            if ek in seen_ev:
                continue
            seen_ev.add(ek)
            h, a = r.get("home_score"), r.get("away_score")
            if h is None or a is None:
                continue
            is_home = r.get("home_team_id") == team_id
            won = (is_home and h > a) or (not is_home and a > h)
            out.append({"t": r["captured_at"], "result": "W" if won else "L",
                        "score": f"{h}-{a}", "home": is_home})
            if len(out) >= 5:
                break
        return out

    last5_home = _last5(home_team_id)
    last5_away = _last5(away_team_id)

    # ----- News velocity per team (rows per hour bucket) -----
    def _news_series(team_id: str | None) -> list:
        if not team_id: return []
        nrows = (
            db.table("espn_news")
            .select("published_at")
            .eq("espn_team_id", team_id).eq("espn_league", home_league or "")
            .gte("published_at", since_iso)
            .order("published_at")
            .execute()
        ).data or []
        # Bucket to UTC hours for a clean stairstep series
        from collections import Counter
        buckets: Counter = Counter()
        for r in nrows:
            ts = r.get("published_at") or ""
            buckets[ts[:13]] += 1   # YYYY-MM-DDTHH
        return [{"t": k + ":00:00+00:00", "v": v} for k, v in sorted(buckets.items())]

    home_news = _news_series(home_team_id)
    away_news = _news_series(away_team_id)

    # ----- Active-injury count over time (per team) -----
    # For each injury status change, we don't easily know "is this player still
    # injured at time T" without a reverse pass. Approximation: count distinct
    # athlete_ids whose latest status change before T was not 'Active'. Cheap
    # forward-fill in Python — these tables are small.
    def _injury_load_series(team_id: str | None) -> list:
        if not team_id: return []
        rows = (
            db.table("espn_injuries_snapshots")
            .select("captured_at,athlete_id,status")
            .eq("espn_team_id", team_id).eq("espn_league", home_league or "")
            .gte("captured_at", since_iso)
            .order("captured_at")
            .execute()
        ).data or []
        # State: athlete_id -> latest status. Each row mutates state, emit count.
        state: dict[str, str] = {}
        out = []
        for r in rows:
            aid = r.get("athlete_id"); st = (r.get("status") or "").lower()
            if not aid: continue
            state[aid] = st
            active_injured = sum(1 for s in state.values() if s and s != "active")
            out.append({"t": r["captured_at"], "v": active_injured})
        return out

    home_injury_load = _injury_load_series(home_team_id)
    away_injury_load = _injury_load_series(away_team_id)

    # ----- Composite team_index with window-content-derived weights -----
    # Weight each signal by how much CONTENT (snapshots) it generated during
    # the visible window. Heavy injury-news day → injuries dominate the index.
    # Quiet news week → standings drive it. Per user spec.
    def _team_index_series(stand_rows, news_rows, inj_load_rows, team_id: str | None) -> tuple[list, dict]:
        if not team_id:
            return [], {}
        n_stand = len(stand_rows)
        n_news  = len(news_rows)
        n_inj   = len(inj_load_rows)
        total = max(n_stand + n_news + n_inj, 1)
        w = {"standings": n_stand/total, "news": n_news/total, "injury": n_inj/total}

        # Build a unified hourly grid from all three sources
        keypoints = sorted({r["t"] for r in (stand_rows + news_rows + inj_load_rows)})
        if not keypoints: return [], w

        # Forward-fill helpers
        def ff_value(rows, t):
            v = None
            for r in rows:
                if r["t"] <= t: v = r.get("v")
                else: break
            return v

        # Normalize each series to 0-100 within the window
        def vals(rs): return [r.get("v") for r in rs if r.get("v") is not None]
        s_vals = vals(stand_rows); n_vals = vals(news_rows); i_vals = vals(inj_load_rows)
        def norm(v, vs):
            if v is None or not vs: return 50.0  # neutral if no data
            mn, mx = min(vs), max(vs)
            if mx == mn: return 50.0
            return (float(v) - mn) / (mx - mn) * 100.0

        out = []
        for t in keypoints:
            s = norm(ff_value(stand_rows, t), s_vals)            # higher win% = higher
            n = norm(ff_value(news_rows,  t), n_vals)            # more news = higher (popularity proxy)
            i = 100.0 - norm(ff_value(inj_load_rows, t), i_vals) # MORE injuries = LOWER index
            idx = w["standings"]*s + w["news"]*n + w["injury"]*i
            out.append({"t": t, "v": round(idx, 2)})
        return out, w

    # Pass the already-normalized t/v standings series (home_standings/
    # away_standings), NOT the raw rows — _team_index_series indexes every input
    # row by r["t"], which the raw espn_team_snapshots rows (keyed captured_at)
    # don't have. Raw rows would KeyError the instant standings exist.
    home_index, home_weights = _team_index_series(home_standings, home_news, home_injury_load, home_team_id)
    away_index, away_weights = _team_index_series(away_standings, away_news, away_injury_load, away_team_id)

    # ----- Per-zone time series (curated > fallback > unmapped, single source) -----
    # User spec: only render ONE zone classification, prefer curated. Returns one
    # series per zone with retail_median + tickets_count time points so the
    # chart workbench can plot any subset.
    zm_rows = (
        db.table("zone_metrics")
        .select("captured_at, zone, zone_source, retail_median, tickets_count, owned_tickets_count, owned_median_retail")
        .eq("event_id", event_id)
        .gte("captured_at", since_iso)
        .order("captured_at")
        .execute()
    ).data or []
    zm_sources = {r.get("zone_source") for r in zm_rows}
    if "curated" in zm_sources:   zm_chosen = "curated"
    elif "fallback" in zm_sources: zm_chosen = "fallback"
    elif "unmapped" in zm_sources: zm_chosen = "unmapped"
    else:                           zm_chosen = None
    zone_series: dict[str, dict] = {}
    if zm_chosen:
        for r in zm_rows:
            if r.get("zone_source") != zm_chosen: continue
            zname = r.get("zone") or "unmapped"
            ent = zone_series.setdefault(zname, {
                "zone": zname, "source": zm_chosen,
                "prices_market": [], "counts_market": [],
                "prices_owned":  [], "counts_owned":  [],
            })
            ent["prices_market"].append({"t": r["captured_at"], "v": r.get("retail_median")})
            ent["counts_market"].append({"t": r["captured_at"], "v": r.get("tickets_count")})
            ent["prices_owned"].append({"t": r["captured_at"], "v": r.get("owned_median_retail")})
            ent["counts_owned"].append({"t": r["captured_at"], "v": r.get("owned_tickets_count")})
    zone_series_list = sorted(zone_series.values(), key=lambda z: -sum(p.get("v") or 0 for p in z["counts_market"]))

    # Range metadata so the chart can pin its x-axis explicitly to the
    # requested window — prevents Chart.js from auto-fitting to whichever
    # series happens to have data, which collapsed 30d views to ~24h when
    # newer series (nonowned_median_retail, splits_min_q) hadn't backfilled
    # past their introduction date.
    until_iso = datetime.now(timezone.utc).isoformat()
    range_meta = {
        "range":    range or (f"{range_hours}h" if range_hours else "all"),
        "hours":    range_hours,
        "since":    since_iso if range_hours else None,  # None = open-left for 'all'
        "until":    until_iso,
    }

    return {
        "event_id": event_id,
        "days": days,
        "range_meta": range_meta,
        "series": {
            # ===== TEvo: prices and counts (legacy IDs preserved) =====
            "prices_owned":    prices_owned,
            "prices_market":   prices_market,
            "prices_nonowned": prices_nonowned,    # NEW: "MARKET NOT US" median
            "counts_owned":    counts_owned,
            "counts_market":   counts_market,
            # ===== AXS box office: median price + listing count =====
            "prices_axs":      prices_axs,
            "counts_axs":      counts_axs,
            # ===== TEvo: full retail percentile distribution =====
            "retail_min":     _series("retail_min"),
            "retail_p25":     _series("retail_p25"),
            "retail_p75":     _series("retail_p75"),
            "retail_p90":     _series("retail_p90"),
            "retail_max":     _series("retail_max"),
            "retail_mean":    _series("retail_mean"),
            "retail_sum":     _series("retail_sum"),
            # ===== TEvo: wholesale percentile distribution =====
            "wholesale_min":     _series("wholesale_min"),
            "wholesale_median":  _series("wholesale_median"),
            "wholesale_mean":    _series("wholesale_mean"),
            "wholesale_max":     _series("wholesale_max"),
            # ===== TEvo: structure and concentration =====
            "getin_price":          _series("getin_price"),
            "top5_concentration":   _series("top5_concentration"),
            "price_dispersion":     _series("price_dispersion"),
            "tail_premium":         _series("tail_premium"),
            "median_group_size":    _series("median_group_size"),
            "groups_count":         _series("groups_count"),
            "sections_count":       _series("sections_count"),
            "ancillary_tickets":    _series("ancillary_tickets"),
            "ancillary_groups":     _series("ancillary_groups"),
            # ===== TEvo: owned aggregates =====
            "owned_groups_count":   _series("owned_groups_count"),
            "owned_share":          _series("owned_share"),
            # ===== TEvo: splits inventory =====
            "splits_min_q":         _series("splits_min_q"),
            "splits_pct_pairs":     _series("splits_pct_pairs"),
            "splits_pct_singles":   _series("splits_pct_singles"),
            "splits_with_singles":  _series("splits_listings_with_singles"),
            "splits_with_pairs":    _series("splits_listings_with_pairs"),
            "splits_with_3":        _series("splits_listings_with_3"),
            "splits_with_4plus":    _series("splits_listings_with_4plus"),
            "splits_no_split":      _series("splits_listings_no_split"),
            # ===== ESPN standings: legacy combined + new per-field per-team =====
            "home_standings": home_standings,   # legacy alias for home_win_pct
            "away_standings": away_standings,
            "home_win_pct":     _stand_series(home_standings_rows, "win_pct"),
            "home_wins":        _stand_series(home_standings_rows, "wins"),
            "home_losses":      _stand_series(home_standings_rows, "losses"),
            "home_games_back":  _stand_series(home_standings_rows, "games_back"),
            "home_seed":        _stand_series(home_standings_rows, "playoff_seed"),
            "home_conf_rank":   _stand_series(home_standings_rows, "conference_rank"),
            "home_div_rank":    _stand_series(home_standings_rows, "division_rank"),
            "away_win_pct":     _stand_series(away_standings_rows, "win_pct"),
            "away_wins":        _stand_series(away_standings_rows, "wins"),
            "away_losses":      _stand_series(away_standings_rows, "losses"),
            "away_games_back":  _stand_series(away_standings_rows, "games_back"),
            "away_seed":        _stand_series(away_standings_rows, "playoff_seed"),
            "away_conf_rank":   _stand_series(away_standings_rows, "conference_rank"),
            "away_div_rank":    _stand_series(away_standings_rows, "division_rank"),
            # ===== ESPN news velocity =====
            "home_news_1h":     home_news,
            "away_news_1h":     away_news,
            # ===== ESPN injury load over time =====
            "home_injury_load": home_injury_load,
            "away_injury_load": away_injury_load,
            # ===== ESPN composite "team_index" (window-content-weighted) =====
            "home_team_index":  home_index,
            "away_team_index":  away_index,
        },
        "signal_weights": {
            "home": home_weights,
            "away": away_weights,
            "explainer": "Composite team_index = sum(weight_i * normalized_signal_i). Weights derived from how many content rows each signal source produced during the visible window — heavy news → news dominates; quiet news week → standings drive it.",
        },
        "overlays": {
            "injuries":     injuries,
            "roster_moves": roster_moves,
        },
        "last5": {
            "home": last5_home,
            "away": last5_away,
        },
        "teams": {
            "home_team_id": home_team_id,
            "away_team_id": away_team_id,
            "league":       home_league,
        },
        "zone_series": {
            "source":    zm_chosen,
            "available": sorted([s for s in zm_sources if s]),
            "zones":     zone_series_list,
        },
    }


def _broker_movers_v2(source: str, window_days: int, category=None, include_inactive: bool = False):
    """v2 movers path: reads from event_movers_index (SMA-based signal scoring).
    Returns events grouped by category with cross-source spread data.
    Index is seeded 3×/day by compute_movers_index_post_snapshot cron.
    """
    db = require_sb()
    rows = db.rpc("get_event_movers_v2", {
        "p_source":      source,
        "p_window_days": window_days,
        "p_category":    category,   # None → all categories (SQL NULL)
        "p_limit":       200,        # 6 cat × 25 events = 150 max; 200 gives headroom
    }).execute().data or []
    summary = db.rpc("get_event_movers_index_summary", {
        "p_source":      source,
        "p_window_days": window_days,
    }).execute().data or []
    by_cat: dict = {}
    for r in rows:
        cat = r.get("category") or "unknown"
        by_cat.setdefault(cat, []).append(r)
    return {
        "v":                  2,
        "source":             source,
        "window_days":        window_days,
        "category":           category,
        "event_count":        len(rows),
        "events_by_category": by_cat,
        "summary":            summary,
    }


@app.get("/api/broker/movers")
def broker_movers(window_hours: int = 24, source: str = "merged", window_days: int | None = None,
                  category: str | None = None, include_inactive: bool = False, _=Depends(require_auth)):
    """Top 10 winners + losers at event / performer / venue level, owned vs market.
    Window: compare latest event_metrics row vs latest row from `window_hours` ago.

    Owned segment    = events with owned_tickets_count > 0 in current window
    Market segment   = events with market listings (regardless of owned)
    Returns 12 lists total: {events,performers,venues} × {owned,market} × {winners,losers}

    `include_inactive`: by default we exclude ghost / completed / cancelled events
    (lifecycle.is_active=false) so a Raptors playoff bracket that won't happen
    doesn't pollute the movers list. Pass true to see everything raw.

    v2 path (window_days set): uses event_movers_index (SMA-based, source×window×category).
    source defaults to "merged"; category=None returns all categories grouped by key.
    """
    # v2 path: index-backed SMA signals, source×window×category
    if window_days is not None:
        return _broker_movers_v2(source, window_days, category, include_inactive)

    window_hours = max(1, min(int(window_hours), 168))
    db = require_sb()

    # Pre-aggregated in SQL via get_event_movers_with_sg RPC
    # (mig 20260518000000 wraps the original get_event_movers from mig
    # 20260508040000). Adds per-event SG sales count over the same window
    # — powers the new "SG sales" column on movers + the "BLIND SPOTS —
    # SG SELLING, WE'RE NOT" panel. DISTINCT ON (sg_sale_id) inside the
    # RPC handles the 11x SG firehose dedup (PROJECT_BIBLE §3).
    #
    # Old approach (Python aggregation over a 50k-row window) was silently
    # capped at 1000 rows by PostgREST's per-request row limit, producing
    # an empty Movers report even when the underlying data was rich.
    rpc_rows = db.rpc("get_event_movers_with_sg", {"p_window_hours": window_hours}).execute().data or []

    # Filter ghost/completed/cancelled events unless caller explicitly opts in.
    # event_lifecycle is a view over derive_event_lifecycle(); cheap to query
    # for the small id-set we get from the movers RPC.
    if rpc_rows and not include_inactive:
        ids = [r.get("event_id") for r in rpc_rows if r.get("event_id")]
        if ids:
            lc_rows = (
                db.table("event_lifecycle").select("event_id,status,is_active")
                .in_("event_id", ids).execute()
            ).data or []
            inactive = {r["event_id"] for r in lc_rows if not r.get("is_active")}
            if inactive:
                rpc_rows = [r for r in rpc_rows if r.get("event_id") not in inactive]

    def pct_delta(cur, prev):
        if cur is None or prev is None: return None
        try: c = float(cur); p = float(prev)
        except (TypeError, ValueError): return None
        if p == 0: return None
        return round((c - p) / p * 100, 2)

    def abs_delta(cur, prev):
        if cur is None or prev is None: return None
        try: return round(float(cur) - float(prev), 2)
        except (TypeError, ValueError): return None

    def _val(price, tix):
        if price is None or tix is None: return None
        try: return float(price) * float(tix)
        except (TypeError, ValueError): return None

    rows_built = []
    for r in rpc_rows:
        cur_market_val  = _val(r.get("cur_market_med"),  r.get("cur_market_tix"))
        prev_market_val = _val(r.get("prev_market_med"), r.get("prev_market_tix"))
        cur_owned_val   = _val(r.get("cur_owned_med"),   r.get("cur_owned_tix"))
        prev_owned_val  = _val(r.get("prev_owned_med"),  r.get("prev_owned_tix"))
        rows_built.append({
            "event_id":       r.get("event_id"),
            "name":           r.get("name"),
            "performer_id":   r.get("primary_performer_id"),
            "performer_name": r.get("primary_performer_name"),
            "venue_id":       r.get("venue_id"),
            "venue_name":     r.get("venue_name"),
            "occurs_at_local": r.get("occurs_at_local"),
            "latest_at":      r.get("latest_at"),
            "cur_market_med": r.get("cur_market_med"),
            "cur_market_tix": r.get("cur_market_tix"),
            "cur_owned_med":  r.get("cur_owned_med"),
            "cur_owned_tix":  r.get("cur_owned_tix"),
            "cur_owned_share": r.get("cur_owned_share"),  # v3: for "we ARE the market" badge
            "delta_market_pct": pct_delta(r.get("cur_market_med"), r.get("prev_market_med")),
            "delta_market_abs": abs_delta(r.get("cur_market_med"), r.get("prev_market_med")),
            "delta_owned_pct":  pct_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
            "delta_owned_abs":  abs_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
            # Notional ticket inventory marked-to-market — captures both price moves
            # AND inventory moves in a single number. Treat each event like a position:
            # value = price × quantity; Δvalue = (cur_price × cur_qty) − (prev_price × prev_qty).
            "cur_market_val":   round(cur_market_val,  2) if cur_market_val  is not None else None,
            "prev_market_val":  round(prev_market_val, 2) if prev_market_val is not None else None,
            "delta_market_val": (None if cur_market_val is None or prev_market_val is None
                                 else round(cur_market_val - prev_market_val, 2)),
            "cur_owned_val":    round(cur_owned_val,  2) if cur_owned_val  is not None else None,
            "prev_owned_val":   round(prev_owned_val, 2) if prev_owned_val is not None else None,
            "delta_owned_val":  (None if cur_owned_val is None or prev_owned_val is None
                                 else round(cur_owned_val - prev_owned_val, 2)),
            # SG broker-sales count over the same window (DISTINCT ON sg_sale_id
            # inside the RPC handles 11x firehose dedup). Drives the new SG
            # column on the movers table + BLIND SPOTS panel (sg_sales > N
            # AND cur_owned_tix = 0).
            "sg_sales_window":  r.get("sg_sales_window") or 0,
        })

    if not rows_built:
        return {"window_hours": window_hours, "events": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []},
                "performers": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []},
                "venues": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []}}

    def top10(items, key, desc=True):
        filtered = [r for r in items if r.get(key) is not None]
        filtered.sort(key=lambda r: r[key], reverse=desc)
        return filtered[:10]

    # Owned segment = events where current owned tix > 0
    owned = [r for r in rows_built if (r.get("cur_owned_tix") or 0) > 0]
    market = rows_built  # all events being tracked (may or may not have owned)

    # Performer + venue rollups: weight by current market tickets
    def rollup(rows_in, group_key, name_key, id_key):
        agg: dict = {}
        for r in rows_in:
            gid = r.get(group_key)
            if gid is None: continue
            slot = agg.setdefault(gid, {
                id_key: gid, name_key: r.get(name_key.replace("name", "name")),
                "weighted_market_pct_num": 0.0, "weighted_market_pct_den": 0,
                "weighted_owned_pct_num": 0.0,  "weighted_owned_pct_den":  0,
                "events_count": 0, "owned_tix_total": 0, "market_tix_total": 0,
            })
            slot["events_count"] += 1
            slot["market_tix_total"] += int(r.get("cur_market_tix") or 0)
            slot["owned_tix_total"]  += int(r.get("cur_owned_tix") or 0)
            if r.get("delta_market_pct") is not None and (r.get("cur_market_tix") or 0) > 0:
                slot["weighted_market_pct_num"] += float(r["delta_market_pct"]) * int(r["cur_market_tix"])
                slot["weighted_market_pct_den"] += int(r["cur_market_tix"])
            if r.get("delta_owned_pct") is not None and (r.get("cur_owned_tix") or 0) > 0:
                slot["weighted_owned_pct_num"] += float(r["delta_owned_pct"]) * int(r["cur_owned_tix"])
                slot["weighted_owned_pct_den"] += int(r["cur_owned_tix"])
        out = []
        for slot in agg.values():
            slot["delta_market_pct"] = (round(slot["weighted_market_pct_num"] / slot["weighted_market_pct_den"], 2)
                                       if slot["weighted_market_pct_den"] else None)
            slot["delta_owned_pct"]  = (round(slot["weighted_owned_pct_num"]  / slot["weighted_owned_pct_den"], 2)
                                       if slot["weighted_owned_pct_den"]  else None)
            out.append({
                id_key: slot[id_key], "name": slot.get(name_key.replace("name", "name")),
                "events_count": slot["events_count"],
                "market_tix_total": slot["market_tix_total"],
                "owned_tix_total": slot["owned_tix_total"],
                "delta_market_pct": slot["delta_market_pct"],
                "delta_owned_pct":  slot["delta_owned_pct"],
            })
        return out

    perf_owned  = rollup(owned,  "performer_id", "performer_name", "performer_id")
    perf_market = rollup(market, "performer_id", "performer_name", "performer_id")
    venue_owned  = rollup(owned,  "venue_id", "venue_name", "venue_id")
    venue_market = rollup(market, "venue_id", "venue_name", "venue_id")

    # Build owned lists first, then exclude those entities from the market candidate
    # pool so a single Knicks game doesn't show up twice (top owned-winner AND top
    # market-winner). Market lists fill from the next-best non-owned candidates.
    def dedupe_market(market_pool, owned_w, owned_l, key):
        excluded = {r.get(key) for r in (owned_w + owned_l) if r.get(key) is not None}
        return [r for r in market_pool if r.get(key) not in excluded]

    ev_ow  = top10(owned,  "delta_owned_pct",  desc=True)
    ev_ol  = top10(owned,  "delta_owned_pct",  desc=False)
    ev_market_dedup = dedupe_market(market, ev_ow, ev_ol, "event_id")
    ev_mw  = top10(ev_market_dedup, "delta_market_pct", desc=True)
    ev_ml  = top10(ev_market_dedup, "delta_market_pct", desc=False)

    pf_ow  = top10(perf_owned,  "delta_owned_pct",  desc=True)
    pf_ol  = top10(perf_owned,  "delta_owned_pct",  desc=False)
    pf_market_dedup = dedupe_market(perf_market, pf_ow, pf_ol, "performer_id")
    pf_mw  = top10(pf_market_dedup, "delta_market_pct", desc=True)
    pf_ml  = top10(pf_market_dedup, "delta_market_pct", desc=False)

    vn_ow  = top10(venue_owned,  "delta_owned_pct",  desc=True)
    vn_ol  = top10(venue_owned,  "delta_owned_pct",  desc=False)
    vn_market_dedup = dedupe_market(venue_market, vn_ow, vn_ol, "venue_id")
    vn_mw  = top10(vn_market_dedup, "delta_market_pct", desc=True)
    vn_ml  = top10(vn_market_dedup, "delta_market_pct", desc=False)

    # Notional value movers: rank by abs $ change in (price × tickets) — the
    # mark-to-market on the inventory position. Captures both price drops and
    # inventory drawdowns in one score, which is what an options-style P&L would
    # weight too (no convexity in tickets, so it's pure delta×dS plus dN×price).
    ev_value_winners = top10([r for r in rows_built if r.get("delta_market_val") is not None], "delta_market_val", desc=True)
    ev_value_losers  = top10([r for r in rows_built if r.get("delta_market_val") is not None], "delta_market_val", desc=False)
    ev_owned_value_winners = top10([r for r in rows_built if r.get("delta_owned_val") is not None and (r.get("cur_owned_tix") or 0) > 0], "delta_owned_val", desc=True)
    ev_owned_value_losers  = top10([r for r in rows_built if r.get("delta_owned_val") is not None and (r.get("cur_owned_tix") or 0) > 0], "delta_owned_val", desc=False)

    return {
        "window_hours": window_hours,
        # Caption surfaced by the UI so users understand what they're looking at.
        "ranking": {
            "metric_owned":  "delta_owned_pct",
            "metric_market": "delta_market_pct",
            "metric_value":  "delta_market_val (cur_med × cur_tix − prev_med × prev_tix)",
            "weighting":     "events: unweighted % change. performer/venue rollups: ticket-count-weighted average. Value lists: absolute $ change in inventory mark-to-market.",
            "dedupe_rule":   "market_winners/losers exclude any entity already in owned_winners/losers; market lists fill from next-best non-owned candidates.",
        },
        "events": {
            "owned_winners":  ev_ow,  "owned_losers":  ev_ol,
            "market_winners": ev_mw,  "market_losers": ev_ml,
            "value_winners":  ev_value_winners, "value_losers": ev_value_losers,
            "owned_value_winners": ev_owned_value_winners, "owned_value_losers": ev_owned_value_losers,
        },
        "performers": {"owned_winners": pf_ow, "owned_losers": pf_ol, "market_winners": pf_mw, "market_losers": pf_ml},
        "venues":     {"owned_winners": vn_ow, "owned_losers": vn_ol, "market_winners": vn_mw, "market_losers": vn_ml},
    }


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
))


# AXS box-office READ routes (event/sections/listings/series) moved to
# routers/axs.py (BR-CODE-1 slice 8). All read-only require_sb reads.
from routers.axs import build_axs_router  # noqa: E402

app.include_router(build_axs_router(get_require_sb=lambda: require_sb, require_auth=require_auth))


@app.post("/api/seatdata/event/{event_id}/link")
def seatdata_link_event(event_id: int, sd_event_id: int = Query(..., description="SeatData event_id"),
                        _=Depends(require_auth)):
    """Manually link a TEvo event to a SeatData event. Free."""
    db = require_sb()
    db.table("seatdata_event_xref").upsert({
        "tevo_event_id": event_id,
        "sd_event_id": sd_event_id,
        "match_method": "manual",
        "match_confidence": 1.0,
    }, on_conflict="tevo_event_id").execute()
    return {"linked": True, "tevo_event_id": event_id, "sd_event_id": sd_event_id}


@app.post("/api/seatdata/event/{event_id}/auto-search")
def seatdata_auto_search(
    event_id: int,
    authorization: str | None = Header(None),
    x_cron_secret: str | None = Header(None, alias="X-Cron-Secret"),
):
    """Search SeatData by date+venue and link if a high-confidence match is found.
    Free (uses /v1/events/search). Returns the chosen sd_event_id or null.
    Cron-or-auth: pg_cron drives this via pg_net with X-Cron-Secret.
    """
    _require_cron_or_auth(authorization, x_cron_secret)
    client = _get_seatdata_client()
    if not client:
        raise HTTPException(503, "SEATDATA_API_KEY not set on this Railway env")
    db = require_sb()
    ev = (db.table("events")
          .select("id,name,occurs_at_local,venue_name,venue_location,primary_performer_name")
          .eq("id", event_id).limit(1).execute()).data or []
    if not ev:
        raise HTTPException(404, f"event {event_id} not found")
    e = ev[0]
    perf = (e.get("primary_performer_name") or "").split(",")[0].split()[-1] if e.get("primary_performer_name") else None
    date_prefix = (e.get("occurs_at_local") or "")[:10]  # YYYY-MM-DD
    venue = e.get("venue_name") or ""
    page = client.search_events(event_name=perf or None, event_date=date_prefix or None,
                                venue_name=venue or None, limit=20)
    candidates = page.get("data") or []
    # Match on exact date + venue
    match = None
    for c in candidates:
        if c.get("event_date") == date_prefix and (c.get("venue_name") or "").lower() == venue.lower():
            match = c; break
    if not match:
        return {"matched": False, "candidates": candidates[:5]}
    sd_event_id = match["event_id"]
    client.link_event(event_id, sd_event_id, match_method="auto_name_date_venue",
                      confidence=0.95, meta={"sd_event_name": match.get("event_name")})
    return {"matched": True, "sd_event_id": sd_event_id, "match": match}


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
    """Project a TEvo /v9/orders row to our evo_orders schema."""
    buyer = order.get("buyer") or {}
    buyer_brk = buyer.get("brokerage") or {}
    seller = order.get("seller") or {}
    seller_brk = seller.get("brokerage") or {}
    cl = order.get("client") or {}
    return {
        "evo_order_id": _to_int_or_none(order.get("id")),
        "state": order.get("state"),
        "type": order.get("type"),
        "fraud_check_status": order.get("fraud_check_status"),
        "total":               _to_num_or_none(order.get("total")),
        "subtotal":            _to_num_or_none(order.get("subtotal")),
        "tax":                 _to_num_or_none(order.get("tax")),
        "shipping":            _to_num_or_none(order.get("shipping")),
        "service_fee":         _to_num_or_none(order.get("service_fee")),
        "refunded":            _to_num_or_none(order.get("refunded")),
        "balance":             _to_num_or_none(order.get("balance")),
        "additional_expense":  _to_num_or_none(order.get("additional_expense")),
        "reference":           order.get("reference"),
        "invoice_number":      order.get("invoice_number"),
        "po_number":           order.get("po_number"),
        "instructions":        order.get("instructions"),
        "partner":             order.get("partner"),
        "buyer_id":            _to_int_or_none(buyer.get("id")),
        "buyer_name":          buyer.get("name"),
        "buyer_brokerage_id":  _to_int_or_none(buyer_brk.get("id")),
        "buyer_brokerage_name": buyer_brk.get("name"),
        "seller_id":           _to_int_or_none(seller.get("id")),
        "seller_name":         seller.get("name"),
        "seller_brokerage_id": _to_int_or_none(seller_brk.get("id")),
        "seller_brokerage_name": seller_brk.get("name"),
        "client_id":           _to_int_or_none(cl.get("id")),
        "client_name":         cl.get("name"),
        "client_phone":        ((cl.get("phone_numbers") or [{}])[0] or {}).get("number") if cl.get("phone_numbers") else None,
        "client_email":        ((cl.get("email_addresses") or [{}])[0] or {}).get("address") if cl.get("email_addresses") else None,
        "evo_created_at":      _parse_iso_or_none(order.get("created_at")),
        "evo_updated_at":      _parse_iso_or_none(order.get("updated_at")),
        "hold_placed_at":      _parse_iso_or_none(order.get("hold_placed_at")),
        "hold_expires_at":     _parse_iso_or_none(order.get("hold_expires_at")),
        "raw":                 order,
        "last_seen_at":        datetime.now(timezone.utc).isoformat(),
    }


# _flatten_order_items -> core/helpers.py (BR-CODE-1); aliased at top.
@app.post("/api/admin/collect-orders")
def collect_evo_orders(
    max_pages: int = 50,                   # 50 * 10 = 500 orders per tick
    state: str | None = None,              # filter by state if provided
    authorization: str | None = Header(None),
    x_cron_secret: str | None = Header(None, alias="X-Cron-Secret"),
):
    """Pull TEvo /v9/orders, persist to evo_orders + evo_order_items, return summary.

    Designed for a 10-min pg_cron driving us via pg_net.http_post. Idempotent
    via PRIMARY KEY (evo_order_id) + UNIQUE (evo_item_id) — re-running just
    refreshes existing rows. evo_order_items rows are deleted+re-inserted per
    order on update so item-list mutations (added / removed) reflect cleanly.
    """
    _require_cron_or_auth(authorization, x_cron_secret)
    db = require_sb()

    orders_seen = 0
    orders_inserted = 0
    items_inserted = 0
    events_touched: set[int] = set()
    errors: list[str] = []

    try:
        for o in client.iter_orders(max_pages=int(max_pages),
                                    per_page=10,
                                    state=state):
            orders_seen += 1
            try:
                row = _flatten_order(o)
                if row["evo_order_id"] is None:
                    continue
                # Upsert order
                db.table("evo_orders").upsert(
                    row, on_conflict="evo_order_id"
                ).execute()
                orders_inserted += 1
                # Replace item rows for this order — handles add/remove cleanly
                db.table("evo_order_items").delete().eq("evo_order_id", row["evo_order_id"]).execute()
                items = _flatten_order_items(o)
                if items:
                    db.table("evo_order_items").insert(items).execute()
                    items_inserted += len(items)
                    for it in items:
                        if it.get("event_id"):
                            events_touched.add(int(it["event_id"]))
            except Exception as e:
                errors.append(f"order {o.get('id')}: {e}")
    except Exception as e:
        errors.append(f"iter_orders failed: {e}")

    return {
        "ok": len(errors) == 0,
        "orders_seen": orders_seen,
        "orders_upserted": orders_inserted,
        "items_inserted": items_inserted,
        "events_touched": len(events_touched),
        "events_touched_ids": sorted(events_touched)[:50],
        "errors": errors[:10],
    }


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

app.include_router(build_seatgeek_router(get_require_sb=lambda: require_sb, require_auth=require_auth))


@app.post("/api/seatgeek/event/{event_id}/link")
def seatgeek_link_event(event_id: int, sg_event_id: int = Query(..., description="SeatGeek event_id"),
                        _=Depends(require_auth)):
    """Manually link a TEvo event to a SG event. Required before sync-listings
    or sync-sales — broker API has no search, so matching is manual.
    Free; no SG call (just DB upsert)."""
    db = require_sb()
    db.table("seatgeek_event_xref").upsert({
        "tevo_event_id": event_id,
        "sg_event_id": sg_event_id,
        "match_method": "manual",
        "match_confidence": 1.0,
    }, on_conflict="tevo_event_id").execute()
    return {"linked": True, "tevo_event_id": event_id, "sg_event_id": sg_event_id}


@app.post("/api/seatgeek/event/{event_id}/sync-listings")
def seatgeek_sync_listings(event_id: int, v2: bool = False, _=Depends(require_auth)):
    """Pull /listings (or /v2/listings if v2=true) and persist. v1 = broker
    inventory only; v2 = ALL secondary marketplace listings."""
    sg = _get_seatgeek_client()
    if not sg:
        raise HTTPException(503, "SEATGEEK_API_TOKEN not in Vault.")
    db = require_sb()
    xref = (db.table("seatgeek_event_xref").select("sg_event_id")
            .eq("tevo_event_id", event_id).limit(1).execute()).data or []
    if not xref:
        raise HTTPException(404, f"event {event_id} not linked to SG; POST /link first")
    sg_event_id = int(xref[0]["sg_event_id"])
    try:
        body = sg.listings(sg_event_id, v2=v2, tevo_event_id=event_id)
    except Exception as e:
        msg = str(e)
        if "scope denied" in msg:
            raise HTTPException(403, msg)
        raise HTTPException(502, f"SeatGeek call failed: {msg}")
    listings = body.get("listings") or []
    sg.link_event(event_id, sg_event_id, sg_event_inline=body.get("event"))
    inserted = sg.store_listings(event_id, sg_event_id, listings,
                                 endpoint=("v2" if v2 else "v1"))
    return {
        "event_id": event_id, "sg_event_id": sg_event_id,
        "endpoint": "/v2/listings" if v2 else "/listings",
        "rows_received": len(listings), "rows_inserted": inserted,
        "cache_hit": body.get("cache_hit"),
        "refreshed_at_utc": body.get("refreshed_at_utc"),
        "event_inline": body.get("event"),
    }


@app.post("/api/seatgeek/event/{event_id}/sync-sales")
def seatgeek_sync_sales(event_id: int, _=Depends(require_auth)):
    """Pull /sales and persist. Sales are immutable — re-running is safe."""
    sg = _get_seatgeek_client()
    if not sg:
        raise HTTPException(503, "SEATGEEK_API_TOKEN not in Vault.")
    db = require_sb()
    xref = (db.table("seatgeek_event_xref").select("sg_event_id")
            .eq("tevo_event_id", event_id).limit(1).execute()).data or []
    if not xref:
        raise HTTPException(404, f"event {event_id} not linked to SG; POST /link first")
    sg_event_id = int(xref[0]["sg_event_id"])
    try:
        body = sg.sales(sg_event_id, tevo_event_id=event_id)
    except Exception as e:
        msg = str(e)
        if "scope denied" in msg:
            raise HTTPException(403, msg)
        raise HTTPException(502, f"SeatGeek call failed: {msg}")
    sales = body.get("sales") or []
    sg.link_event(event_id, sg_event_id, sg_event_inline=body.get("event"))
    inserted = sg.store_sales(event_id, sg_event_id, sales)
    return {
        "event_id": event_id, "sg_event_id": sg_event_id,
        "rows_received": len(sales), "rows_inserted": inserted,
        "cache_hit": body.get("cache_hit"),
        "refreshed_at_utc": body.get("refreshed_at_utc"),
        "event_inline": body.get("event"),
    }


# (seatgeek_event_listings + seatgeek_event_sales moved to routers/seatgeek.py — slice 9)


# ----------------------------------------------------------------------------
# SeatGeek SELLER DIRECT — read-only ingest of S4K listings + orders
# ----------------------------------------------------------------------------
# Different host (sellerdirect-api.seatgeek.com) from the broker-data API.
# /listings + /orders + /order. Each row carries SG event_id + name + venue
# + date inline → auto-backfills seatgeek_event_xref via sg_attempt_event_xref().

@app.post("/api/admin/collect-sg-seller")
def collect_sg_seller(
    statuses: str = "open,pending,confirmed,fulfilled",
    pull_listings: bool = True,
    authorization: str | None = Header(None),
    x_cron_secret: str | None = Header(None, alias="X-Cron-Secret"),
):
    """Pull seller-direct listings + orders. Cron-driven (X-Cron-Secret)
    or manually (Bearer auth). Read-only against SG; writes only to our
    seatgeek_seller_listings, seatgeek_orders, seatgeek_order_tickets,
    and (auto) seatgeek_event_xref tables.

    `statuses` is a comma-separated list of order statuses to pull. Default
    covers all in-flight states; skip 'cancelled' + 'delivered' for cron
    (they're terminal — won't change). Run those manually for backfill.
    """
    _require_cron_or_auth(authorization, x_cron_secret)
    sg = _get_seatgeek_client()
    if not sg:
        raise HTTPException(503, "SEATGEEK_API_TOKEN not in Vault.")

    summary: dict = {"started_at": datetime.now(timezone.utc).isoformat(),
                     "listings": None, "orders_by_status": {}, "errors": []}

    # Listings — paginate via page_cursor for broader coverage. Default
    # 5 pages × 200 per = 1000 listings/tick. Full catalog is 157K+; we
    # rely on cumulative pulls + xref dedup to converge.
    if pull_listings:
        try:
            collected = list(sg.iter_seller_listings(max_pages=5, per_page=200))
            stats = sg.store_seller_listings(collected)
            summary["listings"] = stats
        except Exception as e:
            summary["errors"].append(f"listings: {e}")

    # Orders by status
    for status_filter in [s.strip() for s in (statuses or "").split(",") if s.strip()]:
        try:
            collected: list = []
            for o in sg.iter_seller_orders(status_filter, max_pages=100):
                collected.append(o)
            stats = sg.store_seller_orders(collected, status_filter)
            summary["orders_by_status"][status_filter] = stats
        except Exception as e:
            summary["errors"].append(f"orders[{status_filter}]: {e}")

    summary["finished_at"] = datetime.now(timezone.utc).isoformat()
    return summary


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
))


@app.post("/api/seatdata/event/{event_id}/sync-sales")
def seatdata_sync_sales(
    event_id: int,
    authorization: str | None = Header(None),
    x_cron_secret: str | None = Header(None, alias="X-Cron-Secret"),
):
    """Pull /v0.3/salesdata/get for a linked event and persist new rows.
    PAID: 1 pull per call. Will return 503 if SEATDATA_API_KEY not set,
    402 if budget exhausted. Cron-or-auth: pg_cron drives this via pg_net
    with X-Cron-Secret.
    """
    _require_cron_or_auth(authorization, x_cron_secret)
    client = _get_seatdata_client()
    if not client:
        raise HTTPException(503, "SEATDATA_API_KEY not set on this Railway env")
    db = require_sb()
    xref = (db.table("seatdata_event_xref").select("sd_event_id")
            .eq("tevo_event_id", event_id).limit(1).execute()).data or []
    if not xref:
        raise HTTPException(404, f"event {event_id} not linked to SeatData; call /auto-search or /link first")
    sd_event_id = int(xref[0]["sd_event_id"])
    try:
        sales = client.salesdata(sd_event_id, tevo_event_id=event_id)
    except Exception as e:
        msg = str(e)
        if "budget exhausted" in msg.lower() or "BudgetExceeded" in type(e).__name__:
            raise HTTPException(402, msg)
        raise HTTPException(502, f"SeatData call failed: {msg}")
    inserted = client.store_sales(event_id, sd_event_id, sales)
    db.table("seatdata_event_xref").update({"last_paid_pull_at": datetime.now(timezone.utc).isoformat()}) \
      .eq("tevo_event_id", event_id).execute()
    return {"event_id": event_id, "sd_event_id": sd_event_id,
            "rows_received": len(sales), "rows_inserted": inserted}


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


@app.get("/api/store/events")
def store_events(
    q: str | None = None,
    performer_id: int | None = None,
    venue_id: int | None = None,
    limit: int = 60,
    offset: int = 0,
    include_inactive: bool = False,
):
    """Catalog: upcoming events our brokerage office has inventory for.

    Pulled directly from TEvo /v9/events with office_id=TEVO_OFFICE_ID,
    which is TEvo's native server-side filter for "events MY office has
    listings on". 100% we_own — there is no "browse market" fallthrough.

    Performer media (logos + brand colors) is bulk-enriched from Supabase
    performer_metadata. That's the only Supabase touch on this route —
    the events themselves come from TEvo. Rest of the prior badge
    enrichments (rivalry / MLB-series / tournament / weather / holiday /
    playoff) stay nullable for now; they get re-layered after the prod
    checkpoint.

    Pagination: TEvo caps per_page at 100; this handler pages through
    enough TEvo pages to fill the requested `limit` (max 500 → up to
    5 TEvo calls).

    Args mirror the prior shape so the front-end + share-link routes
    don't need to change. `include_inactive` is kept as a no-op for
    callsite compatibility (CANCELLED markers are still filtered by
    name string in case TEvo leaks them through the office filter).
    """
    if client is None:
        # SQL-only demo mode boots without TEvo. MVP catalog requires it.
        raise HTTPException(503, "TEvo client not configured")

    cap = min(max(limit, 1), 500)
    # offset → TEvo page index. TEvo paginates 1-based.
    per_page = min(cap, 100)
    # Cap offset to prevent absurd values from triggering a 502 on impossible
    # page lookups (TEvo doesn't paginate beyond what its catalog holds —
    # office-filtered catalog is ~3-4k events at peak, so 5000 is a safe
    # upper bound that catches malicious/bug values like ?offset=999999).
    offset = min(max(offset, 0), 5000)
    start_page = (offset // per_page) + 1
    # When offset is NOT a multiple of per_page, we land mid-page and have to
    # slice the leading rows off the first fetched page. Account for that in
    # pages_needed so the post-slice list still contains `cap` rows.
    offset_in_first_page = offset % per_page
    pages_needed = ((offset_in_first_page + cap) + per_page - 1) // per_page

    today_iso = datetime.now(timezone.utc).date().isoformat()

    raw_events: list[dict] = []
    try:
        for p in range(start_page, start_page + pages_needed):
            # office_id=TEVO_OFFICE_ID filters TEvo to ONLY events our office
            # has inventory for. Verified 100% we_own match in probe v2.
            # `office_id` goes through evo_client.list_events's **extra
            # kwarg so it reaches the request as-is.
            resp = client.list_events(
                q=q or None,
                performer_id=performer_id,
                venue_id=venue_id,
                occurs_at_gte=today_iso,
                only_with_available_tickets=True,
                order_by="events.occurs_at ASC",
                per_page=per_page,
                page=p,
                **{"office_id": TEVO_OFFICE_ID},
            )
            batch = resp.get("events", []) or []
            if not batch:
                break
            raw_events.extend(batch)
            # Stop when we have enough rows to fill the requested window AFTER
            # slicing off the leading offset_in_first_page rows. Using `>= cap`
            # alone short-circuits the loop before the second page when offset
            # is non-aligned (e.g. offset=25, cap=60: page-1 fills 60 rows,
            # break fires, slice yields only 35). Caught by test_pagination_
            # offset_non_aligned.
            if len(raw_events) >= offset_in_first_page + cap:
                break
            # Stop early if we've hit the total.
            total = int(resp.get("total_entries") or 0)
            if total and len(raw_events) >= total:
                break
    except RuntimeError as e:
        # Log full upstream error server-side; return a stable string so TEvo's
        # response text (URLs, partial tokens, internal IDs from the requests
        # exception) never reaches the public storefront.
        _log.warning(f"[store_events] TEvo events fetch failed: {e!r}")
        raise HTTPException(502, "events fetch failed")

    # TEvo bakes CANCELLED markers into the event name string.
    raw_events = [
        e for e in raw_events
        if "CANCELLED" not in (e.get("name") or "").upper()
    ]
    # Slice from the offset-in-first-page so callers requesting a non-multiple
    # offset get the records they asked for (vs records starting at the page
    # boundary).
    raw_events = raw_events[offset_in_first_page : offset_in_first_page + cap]

    # ---- Bulk-fetch performer media from Supabase performer_metadata ----
    # Single SQL roundtrip pulls logo + color for every performer that
    # appears on the catalog page. The TEvo /v9/events response only
    # carries performer id + name — logos and ESPN team data live in our
    # SQL enrichment table (populated by the crawl-venues-and-performers
    # collector). This is the only Supabase touch on the catalog.
    perf_ids: set[int] = set()
    for ev in raw_events:
        for perf in (ev.get("performances") or []):
            pid = (perf.get("performer") or {}).get("id")
            if pid:
                # Guard the coercion: a non-numeric performer id must not 500 the
                # whole catalog. The per-card loop below already tolerates bad
                # ids (try/except → None); mirror that here so the gather step
                # can't crash first on the same data.
                try:
                    perf_ids.add(int(pid))
                except (TypeError, ValueError):
                    pass
    perf_assets: dict[int, dict] = {}
    if perf_ids:
        try:
            db = require_sb()
            perf_assets = _bulk_performer_assets(db, list(perf_ids))
        except Exception as e:
            # Don't break the catalog if performer_metadata is unavailable;
            # cards just render without logos/colors.
            _log.warning(f"performer_metadata bulk-fetch failed: {e}")
            perf_assets = {}

    out: list[dict] = []
    for ev in raw_events:
        venue = ev.get("venue") or {}
        # TEvo venue shape: {id, name, slug, location, time_zone,
        #   city, state, country, ...}. `location` is "City, ST" string
        #   on most events; fall back to city/state if absent.
        venue_loc = venue.get("location")
        if not venue_loc:
            city = venue.get("city") or ""
            state = venue.get("state") or ""
            venue_loc = f"{city}, {state}".strip(", ") or None

        # /v9/events list response uses `performances`, NOT `performers`
        # (that's the /v9/events/:id show shape). Each performance nests
        # a `performer: {id, name}` object plus a `primary` boolean.
        performances = ev.get("performances") or []
        primary_perf = (
            next((p for p in performances if p.get("primary")), None)
            or (performances[0] if performances else {})
        )
        performer = (primary_perf or {}).get("performer") or {}

        # owned_by_office is TEvo's native we-own signal — true when our
        # token's brokerage office has inventory listed for this event.
        # With office_id filter applied to /v9/events, this is always
        # true; kept on the response shape for forward-compat.
        we_own = bool(ev.get("owned_by_office"))

        # Performer media: logo + brand color from Supabase performer_metadata.
        # Falls back to None on either side if the performer isn't seeded.
        perf_id = performer.get("id")
        try:
            primary_pid = int(perf_id) if perf_id else None
        except (TypeError, ValueError):
            primary_pid = None
        assets = perf_assets.get(primary_pid) if primary_pid else None
        # Away-team assets — first non-primary performance in the array.
        # 2026-05-19: "populate all store events with team assets where
        # available". Sports matchups: TEvo emits both teams as separate
        # performances. Playoff placeholders may carry only home.
        away_pid: int | None = None
        away_name: str | None = None
        for p in performances:
            pf = (p or {}).get("performer") or {}
            pid_raw = pf.get("id")
            try:
                pid_int = int(pid_raw) if pid_raw else None
            except (TypeError, ValueError):
                pid_int = None
            if pid_int is None or pid_int == primary_pid:
                continue
            away_pid = pid_int
            away_name = pf.get("name")
            break
        away_assets = perf_assets.get(away_pid) if away_pid else None

        out.append({
            "id": ev.get("id"),
            "name": ev.get("name"),
            # occurs_at_local has the real local offset; occurs_at is the
            # misleading "Z"-suffixed local time. Prefer _local.
            "occurs_at_local": ev.get("occurs_at_local") or ev.get("occurs_at"),
            "venue_name": venue.get("name"),
            "venue_location": venue_loc,
            "primary_performer_name": performer.get("name"),
            "primary_performer_id": perf_id,
            "primary_performer_logo": (assets or {}).get("logo_default_url"),
            "primary_performer_color": (assets or {}).get("color_primary"),
            "primary_performer_league": (assets or {}).get("espn_league"),
            # Away-team assets — populated when matchup data + metadata
            # both available. FE renders both logos for sports cards.
            "away_performer_id":    away_pid,
            "away_performer_name":  away_name,
            "away_performer_logo":  (away_assets or {}).get("logo_default_url"),
            "away_performer_color": (away_assets or {}).get("color_primary"),
            # available_count is deprecated for authoritative pricing but
            # is fine as a "tickets available" indicator on cards (the
            # detail page uses /v9/events/:id/stats for exact numbers).
            "available_count": ev.get("available_count"),
            "we_own": we_own,
            "tbd": bool(ev.get("tbd")),
            "popularity_score": ev.get("popularity_score"),
            # from_price + owned_tickets_count still need a per-event call
            # so stay null on the catalog payload; revealed on click-through.
            "from_price": None,
            "owned_tickets_count": None,
            "owned_groups_count": None,
            "captured_at": None,
            # Other badge enrichments (rivalry / series / weather / holiday
            # / playoff) — re-layer in a follow-up after the prod checkpoint.
            "rivalry": None,
            "mlb_series": None,
            "tournament": None,
            "weather": None,
            "holiday": None,
            "playoff": None,
        })

    return {"count": len(out), "events": out, "limit": cap, "offset": offset}


# _haversine_miles -> core/helpers.py (BR-CODE-1 pure-utility pass); aliased at top.
def _attach_owned_metadata(
    db,
    candidate_ids: list[int],
    user_lat: float,
    user_lon: float,
) -> list[dict]:
    """Given a list of TEvo event_ids, intersect with our owned + active set
    and decorate with metadata + display distance. Used by both 'hybrid' and
    'supabase' near-me modes to keep response shape identical.
    """
    if not candidate_ids:
        return []
    # Two-query merge (was `events!inner(...)` — PostgREST PGRST200 after
    # cache rebuilds because view-to-table FK inference is flaky).
    metrics_rows = (
        db.table("latest_event_metrics")
        .select("event_id,owned_tickets_count,owned_groups_count,retail_min")
        .gt("owned_tickets_count", 0)
        .in_("event_id", [int(e) for e in candidate_ids])
        .execute().data
    ) or []
    if not metrics_rows:
        return []
    metric_event_ids = [int(m["event_id"]) for m in metrics_rows if m.get("event_id")]
    events_rows = (
        db.table("events")
        .select("id,name,occurs_at_local,venue_id,venue_name,venue_location,"
                "primary_performer_id,primary_performer_name")
        .in_("id", metric_event_ids)
        .execute().data
    ) or []
    events_by_id = {int(e["id"]): e for e in events_rows if e.get("id")}
    rows = [
        {**m, "events": events_by_id.get(int(m["event_id"]))}
        for m in metrics_rows
        if events_by_id.get(int(m["event_id"]))
    ]
    if not rows:
        return []

    ev_ids = [r["event_id"] for r in rows]
    try:
        lc = (
            db.table("event_lifecycle").select("event_id,is_active")
            .in_("event_id", ev_ids).execute().data
        ) or []
        inactive = {r["event_id"] for r in lc if not r.get("is_active")}
    except Exception:
        inactive = set()

    venue_ids = list({(r.get("events") or {}).get("venue_id") for r in rows
                      if (r.get("events") or {}).get("venue_id")})
    coord_map: dict[int, tuple[float, float]] = {}
    if venue_ids:
        try:
            ca = (
                db.table("venue_assets").select("tevo_venue_id,latitude,longitude")
                .in_("tevo_venue_id", venue_ids).execute().data
            ) or []
            for c in ca:
                if c.get("latitude") is not None and c.get("longitude") is not None:
                    coord_map[int(c["tevo_venue_id"])] = (float(c["latitude"]), float(c["longitude"]))
        except Exception:
            coord_map = {}

    perf_ids = [int((r.get("events") or {}).get("primary_performer_id"))
                for r in rows
                if (r.get("events") or {}).get("primary_performer_id")
                and r["event_id"] not in inactive]
    perf_assets = _bulk_performer_assets(db, perf_ids) if perf_ids else {}

    out: list[dict] = []
    for r in rows:
        eid = r["event_id"]
        if eid in inactive:
            continue
        ev = r.get("events") or {}
        coords = coord_map.get(int(ev.get("venue_id"))) if ev.get("venue_id") else None
        dist = _haversine_miles(user_lat, user_lon, coords[0], coords[1]) if coords else None
        a = perf_assets.get(int(ev.get("primary_performer_id"))) if ev.get("primary_performer_id") else None
        out.append({
            "id": eid,
            "name": ev.get("name"),
            "occurs_at_local": ev.get("occurs_at_local"),
            "venue_name": ev.get("venue_name"),
            "venue_location": ev.get("venue_location"),
            "primary_performer_name": ev.get("primary_performer_name"),
            "primary_performer_logo": (a or {}).get("logo_default_url"),
            "primary_performer_color": (a or {}).get("color_primary"),
            "from_price": r.get("retail_min"),
            "owned_tickets_count": r.get("owned_tickets_count"),
            "distance_miles": round(dist, 1) if dist is not None else None,
        })
    return out


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


def _search_cache_get(key: str) -> dict | None:
    hit = _search_cache.get(key)
    if not hit:
        return None
    ts, payload = hit
    if time.time() - ts > _SEARCH_CACHE_TTL:
        _search_cache.pop(key, None)
        return None
    return payload


def _search_cache_put(key: str, payload: dict) -> None:
    _search_cache[key] = (time.time(), payload)
    # Drop oldest entries when the cache grows past 200 — keeps a long
    # uptime from leaking memory on a steady drip of unique queries.
    if len(_search_cache) > 200:
        oldest = min(_search_cache.items(), key=lambda kv: kv[1][0])
        _search_cache.pop(oldest[0], None)


# _search_sql_only -> core/search.py (BR-CODE-1); imported (aliased) at top.


def _search_players(db, q_norm: str, limit: int) -> list[dict]:
    """Sports player search for the storefront. Resolves a player name to their
    team + the team's upcoming events via the shared PUBLIC RPC
    `sports_player_search` (mig 20260617120000), then enriches each event with
    the same we_own/from_price tags as _search_sql_only so the dropdown can show
    "tickets you can buy" under a player.

    Public sports data only (rosters, team names, public listings) — the only
    money shown is the consumer-facing from_price already on every event card.
    Returns [] on any failure: the players block is additive and must never 500
    the whole search.
    """
    try:
        players = (db.rpc("sports_player_search",
                          {"p_q": q_norm, "p_limit": limit}).execute().data) or []
    except Exception as e:
        _log.warning(f"_search_players rpc failed: {e}")
        return []
    if not players:
        return []

    # One batched tag lookup across every event id from every matched player.
    all_ids = [
        int(ev.get("tevo_event_id") or 0)
        for pl in players for ev in (pl.get("events") or [])
        if ev.get("tevo_event_id")
    ]
    metrics: dict[int, dict] = {}
    inactive: set[int] = set()
    if all_ids:
        uniq = list(set(all_ids))
        try:
            rows = (db.table("latest_event_metrics")
                      .select("event_id,owned_tickets_count,retail_min")
                      .in_("event_id", uniq).execute().data) or []
            metrics = {int(r["event_id"]): r for r in rows if r.get("event_id")}
        except Exception:
            metrics = {}
        try:
            lc = (db.table("event_lifecycle")
                    .select("event_id,is_active")
                    .in_("event_id", uniq).execute().data) or []
            inactive = {int(r["event_id"]) for r in lc if not r.get("is_active")}
        except Exception:
            inactive = set()

    out: list[dict] = []
    for pl in players:
        events_out = []
        for ev in (pl.get("events") or []):
            eid = int(ev.get("tevo_event_id") or 0)
            if not eid or eid in inactive or _is_speculative_event_name(ev.get("name")):
                continue
            m = metrics.get(eid) or {}
            events_out.append({
                "id": eid,
                "name": ev.get("name"),
                "venue_name": ev.get("venue_name"),
                "location": ev.get("venue_location"),
                "occurs_at": ev.get("occurs_at_local"),
                "we_own": bool(m.get("owned_tickets_count")),
                "from_price": m.get("retail_min"),
                "owned_tix": m.get("owned_tickets_count"),
            })
        out.append({
            "performer_id": int(pl.get("tevo_performer_id") or 0),
            "name": pl.get("full_name") or pl.get("display_name"),
            "team_name": pl.get("team_name"),
            "league": pl.get("espn_league"),
            "position": pl.get("position_abbr"),
            "jersey": pl.get("jersey"),
            "status": pl.get("status"),
            "headshot_url": pl.get("headshot_url"),
            "events": events_out,
        })
    return out


def _search_live(db, q_norm: str, limit: int) -> dict:
    """Live search: hits TEvo /v9/searches/suggestions, then cross-joins the
    returned event IDs against our SQL to tag we_own + from_price. Used in
    non-SQL-only deployments."""
    today_iso = datetime.now(timezone.utc).date().isoformat()
    # Lazy-init client so we can serve search even if boot creds were stale.
    live_client = ensure_tevo_client()
    if live_client is None:
        # Creds genuinely missing — fall back to SQL with explicit signal.
        payload = _search_sql_only(db, q_norm, limit)
        payload["fallback"] = True
        payload["fallback_reason"] = "tevo_unconfigured"
        return payload
    try:
        resp = live_client.search_suggestions(
            q_norm, entities="events,performers,venues",
            fuzzy=True, limit=20, occurs_at_gte=today_iso,
        )
    except RuntimeError as e:
        # Don't break the page on TEvo error; fall back to SQL with a
        # structured signal so clients can show a "live search degraded"
        # hint. Status code (parsed out of the sanitized RuntimeError
        # message — evo_client.py strips URL + body since PR #66/#81) is
        # the only upstream detail we surface; full error stays in logs.
        logging.warning(
            "search_live TEvo failed, falling back to SQL: %s",
            str(e)[:200],
        )
        m = re.search(r"\b(\d{3})\b", str(e))
        upstream_status = int(m.group(1)) if m else None
        payload = _search_sql_only(db, q_norm, limit)
        payload["fallback"] = True
        payload["fallback_reason"] = "tevo_unavailable"
        if upstream_status:
            payload["fallback_detail"] = {"tevo_status": upstream_status}
        return payload

    s = (resp.get("suggestions") or {})
    ev_in = s.get("events", []) or []
    pf_in = s.get("performers", []) or []
    vn_in = s.get("venues", []) or []

    # Drop speculative event names — CANCELLED + (If Necessary) + (Date TBD).
    # TEvo bakes these markers right into the name string for playoff/round-N
    # placeholders. Consumer search should never surface them as bookable.
    ev_in = [e for e in ev_in if not _is_speculative_event_name(e.get("name"))]

    # Cross-check against our SQL to know which events we actually own.
    ev_ids = [int(e.get("id") or 0) for e in ev_in if e.get("id")]
    metrics: dict[int, dict] = {}
    if ev_ids:
        try:
            rows = (db.table("latest_event_metrics")
                      .select("event_id,owned_tickets_count,owned_groups_count,retail_min")
                      .in_("event_id", ev_ids).execute().data) or []
            metrics = {int(r["event_id"]): r for r in rows if r.get("event_id")}
        except Exception:
            metrics = {}

    events_out = []
    for e in ev_in[:limit]:
        eid = int(e.get("id") or 0)
        m = metrics.get(eid) or {}
        events_out.append({
            "id": eid,
            "name": e.get("name"),
            "venue_name": e.get("venue_name"),
            "location": e.get("location"),
            "occurs_at": e.get("occurs_at"),
            "we_own": bool(m.get("owned_tickets_count")),
            "from_price": m.get("retail_min"),
            "owned_tix": m.get("owned_tickets_count"),
        })

    return {
        "events": events_out,
        "performers": [{
            "id": int(p.get("id") or 0),
            "name": p.get("name"),
            "location": p.get("location"),
            "venue_name": p.get("venue_name"),
        } for p in pf_in[:limit] if p.get("id")],
        "venues": [{
            "id": int(v.get("id") or 0),
            "name": v.get("name"),
            "location": v.get("location"),
        } for v in vn_in[:limit] if v.get("id")],
        "source": "live",
    }


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


def _fire_canonical_refresh(event_id: int, ev: dict) -> None:
    """Fire-and-forget kick to the audit lane's collect-listings Edge Function
    so canonical SQL stays as fresh as the storefront sees.

    Two paths:
    - **Tracked event** (row exists in `events`): hit
      `collect-listings?event_id=X&min_age_seconds=10`. The audit-lane
      function dedupes against recent snapshots, so 100 shoppers in 10s
      trigger one collector run, not 100.
    - **Untracked event** (row missing): insert primary performer into
      `watchlist`, then call `collect-listings?watchlist_id=N`. The
      sweep populates `events` + `listings_snapshots` + `event_metrics`
      for that performer's full calendar. From now on the regular cron
      cadence covers the event automatically.

    Lane note: writes to `watchlist` (audit-lane table) using the same
    insert pattern as the existing `/api/watchlist` POST endpoint. We're
    using the existing API surface, not creating a parallel writer — the
    unique constraint on (kind, ext_id) keeps the table consistent.

    Always non-blocking; runs on a daemon thread. Failures are logged to
    stdout, never raised back to the page handler.
    """
    if not (sb is not None and SUPABASE_URL and CRON_SECRET):
        return  # Best-effort only; missing config silently no-ops.

    def _go():
        try:
            existing = (
                sb.table("events").select("id").eq("id", event_id).limit(1).execute().data
            )
        except Exception as e:
            _log.warning(f"canonical refresh: events lookup failed for {event_id}: {e}")
            return

        if existing:
            url = (
                f"{SUPABASE_URL}/functions/v1/collect-listings"
                f"?event_id={event_id}&min_age_seconds=10"
            )
            _fire_collect(url, CRON_SECRET)
            return

        # Auto-track path: this event is brand new to us. Add primary
        # performer to watchlist so the cron picks it up going forward.
        performances = ev.get("performances") or []
        primary = next(
            ((p.get("performer") or {}) for p in performances if p.get("primary")),
            ((performances[0].get("performer") or {}) if performances else {}),
        )
        pid = primary.get("id")
        if not pid:
            _log.info(f"auto-track: event {event_id} has no primary performer; skipping")
            return
        pid = int(pid)
        pname = primary.get("name") or f"performer {pid}"

        watchlist_id: int | None = None
        try:
            ins = sb.table("watchlist").insert(
                {"kind": "performer", "ext_id": pid, "label": pname}
            ).execute()
            row = (ins.data or [None])[0]
            if row:
                watchlist_id = row.get("id")
                _log.info(f"auto-track: added performer {pid} ({pname}) to watchlist as id={watchlist_id}")
        except Exception as e:
            msg = str(e)
            if "duplicate" in msg.lower() or "23505" in msg or "unique" in msg.lower():
                # Already in watchlist — find the existing id so we can scope the kick.
                try:
                    found = (
                        sb.table("watchlist").select("id")
                        .eq("kind", "performer").eq("ext_id", pid)
                        .limit(1).execute().data
                    )
                    if found:
                        watchlist_id = found[0]["id"]
                except Exception as e2:
                    _log.warning(f"auto-track: lookup after dup failed: {e2}")
            else:
                _log.warning(f"auto-track: watchlist insert failed for performer {pid}: {e}")

        if watchlist_id:
            url = f"{SUPABASE_URL}/functions/v1/collect-listings?watchlist_id={watchlist_id}"
            _fire_collect(url, CRON_SECRET)

    threading.Thread(target=_go, daemon=True).start()


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
))


# /api/store/seatmap/* proxy + section crosswalk -> routers/seatmap.py
# (BR-CODE-1 decomposition slice). get_sb resolves the live app.sb so the
# monkeypatch tests bind; the moved _fetch helper uses the shared requests
# module, which tests stub via app.requests.get.
from routers.seatmap import build_seatmap_router  # noqa: E402
app.include_router(build_seatmap_router(get_sb=lambda: sb))




# _is_bowl_pattern_name (+ _CONSUMER_ZONE_NAME_RE) -> core/helpers.py (BR-CODE-1); aliased at top.


@app.post("/api/store/verify-human")
def store_verify_human(request: Request, payload: dict = Body(...)):
    """First-interaction bot gate (reCAPTCHA v3). store.js calls this once per
    session with a v3 token (action 'gate'); on a passing score we set a
    short-lived signed cookie that the write endpoints accept, so the gate runs
    once rather than on every action. No-op success when the gate is dormant."""
    if not RECAPTCHA_ENABLED:
        return JSONResponse({"ok": True, "enabled": False})
    token = payload.get("recaptcha_token") or payload.get("token")
    xff = request.headers.get("x-forwarded-for") or ""
    ip = (xff.split(",")[-1].strip() if xff else (request.client.host if request.client else None))
    if not _verify_recaptcha(token, "gate", ip):
        raise HTTPException(403, "verification failed")
    resp = JSONResponse({"ok": True, "enabled": True})
    resp.set_cookie(
        _HUMAN_COOKIE_NAME,
        _issue_human_token(),
        max_age=_HUMAN_TTL_SECONDS,
        httponly=True,
        samesite="lax",
        secure=True,
        path="/",
    )
    return resp


@app.post("/api/store/reserve")
def store_reserve(request: Request, payload: dict = Body(...), authorization: str | None = Header(None)):
    """MVP placeholder: a real checkout is not wired up yet. Validates that
    the requested ticket_group + quantity matches the live owned inventory in
    TEvo, then returns a mock confirmation. NEVER calls /v9/orders.

    Auth: gated by STOREFRONT_RESERVE_REQUIRES_AUTH env flag. MVP demo
    leaves it off so the front-end's "Reserve (mock)" button works without
    a Supabase session. Sprint 2 (real-purchase path) flips the flag on
    once the front-end attaches Authorization headers."""
    if STOREFRONT_RESERVE_REQUIRES_AUTH:
        require_auth(authorization)
    # Bot gate: honeypot (always) + reCAPTCHA human-cookie/token (when enabled).
    _require_human(request, payload)
    try:
        event_id = int(payload.get("event_id") or 0)
        ticket_group_id = int(payload.get("ticket_group_id") or 0)
        quantity = int(payload.get("quantity") or 0)
    except (TypeError, ValueError):
        raise HTTPException(400, "event_id, ticket_group_id and quantity must be integers")
    if not (event_id and ticket_group_id and quantity > 0):
        raise HTTPException(400, "event_id, ticket_group_id and quantity > 0 required")
    # Upper-bound the requested quantity before we touch inventory. TEvo
    # ticket groups in practice cap around 8-12 per seat block; 50 is a
    # generous ceiling that still bounds the request shape so a malformed
    # client (quantity=999999) gets rejected fast without consulting the
    # upstream API or the snapshot table.
    if quantity > 50:
        raise HTTPException(400, "quantity exceeds maximum allowed per reservation")

    if STOREFRONT_SQL_ONLY:
        # SQL-only mode: validate against listings_snapshots' latest capture
        # for this event. Same validation surface (available + splits) so
        # the UX is identical, just slightly stale-tolerant.
        groups, _src, _captured = _fetch_owned_ticket_groups_from_db(event_id)
        match = next(
            (tg for tg in groups if int(tg.get("id") or 0) == ticket_group_id),
            None,
        )
        if not match:
            raise HTTPException(
                404,
                "ticket group is no longer available from this seller (snapshot-based)",
            )
    else:
        try:
            tg_resp = client.get_ticket_groups(event_id, owned=True)
        except RuntimeError as e:
            _log.warning(f"[store_reserve] TEvo ticket_groups failed for {event_id}: {e!r}")
            raise HTTPException(502, "ticket listings fetch failed")
        match = next(
            (tg for tg in (tg_resp.get("ticket_groups") or []) if int(tg.get("id") or 0) == ticket_group_id),
            None,
        )
        if not match:
            raise HTTPException(404, "ticket group is no longer available from this seller")

    # available_quantity is authoritative when present. A sold-out group reports
    # available_quantity=0 while `quantity` (the original block size) stays
    # non-zero, so the old `available_quantity or quantity` fallback (0 is falsy)
    # silently admitted reservations against zero sellable inventory. Only fall
    # back to `quantity` when available_quantity is genuinely absent (None).
    _aq = match.get("available_quantity")
    avail = int(_aq if _aq is not None else (match.get("quantity") or 0))
    splits = match.get("splits") or []
    if quantity > avail:
        raise HTTPException(409, f"requested {quantity} but only {avail} available")
    if splits and quantity not in splits:
        raise HTTPException(409, f"this listing only sells in quantities of {splits}")

    unit = float(match.get("retail_price") or 0)
    return {
        "ok": True,
        "purchase_enabled": False,
        "message": "MVP demo — no charge processed. This is what a real purchase confirmation would look like.",
        "reservation": {
            "event_id": event_id,
            "ticket_group_id": ticket_group_id,
            "section": match.get("section"),
            "row": match.get("row"),
            "quantity": quantity,
            "unit_price": unit,
            "subtotal": round(unit * quantity, 2),
            "format": match.get("format"),
            "in_hand": match.get("in_hand"),
        },
    }


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


@app.api_route("/store/chat", methods=["GET", "HEAD"])
def store_chat_page():
    """Storefront concierge chat. Mounts the shared retail-chat widget
    (static/shared/retail-chat-widget.js) against /api/store/retail-chat."""
    return _render_storefront_page("chat.html")


@app.api_route("/store", methods=["GET", "HEAD"])
def store_index_page():
    return _render_storefront_page("index.html")


@app.api_route("/store-sw.js", methods=["GET", "HEAD"], include_in_schema=False)
def store_service_worker():
    """Serve the storefront PWA service worker from a ROOT path so it can claim
    the '/store' scope. A service worker only controls pages at/below its own URL
    directory, so served from /static/store/ it could never cover the /store
    routes. store.js registers it with { scope: '/store' }; the
    Service-Worker-Allowed header authorizes that broader-than-directory scope."""
    path = os.path.join(STATIC_DIR, "store", "sw.js")
    with open(path, "r", encoding="utf-8") as f:
        body = f.read()
    return Response(
        content=body,
        media_type="application/javascript",
        headers={
            "Cache-Control": "no-cache, must-revalidate",
            "Service-Worker-Allowed": "/store",
        },
    )


@app.api_route("/store/event/{event_id}", methods=["GET", "HEAD"])
def store_event_page(event_id: int):  # noqa: ARG001 — id read by JS from URL
    return _render_storefront_page("event.html")


@app.api_route("/store/discover", methods=["GET", "HEAD"])
def store_discover_page():
    """Reverse discovery — 'what tours can I catch near me'. Backed by
    /api/store/tours/near; mounts via store.js (data-page=discover)."""
    return _render_storefront_page("discover.html")


@app.api_route("/store/tour", methods=["GET", "HEAD"])
def store_tour_page():
    """Follow-the-tour — pick a ticket count and attend a performer's whole tour;
    tickets auto-selected per date. Backed by /api/store/performers/{id}/tour-package;
    mounts via store.js (data-page=tour). Performer id read from ?performer=."""
    return _render_storefront_page("tour.html")


# ---------- Static informational pages (Sprint 3 trust + legal) ----------
# Plain HTML shells with no JS. Same Cache-Control: no-cache pattern as
# the rest of the storefront so future edits propagate without browser
# cache hangups. Footer links from every storefront page point here.

@app.api_route("/store/about", methods=["GET", "HEAD"])
def store_about_page():
    return _render_storefront_page("about.html")


@app.api_route("/store/privacy", methods=["GET", "HEAD"])
def store_privacy_page():
    return _render_storefront_page("privacy.html")


@app.api_route("/store/terms", methods=["GET", "HEAD"])
def store_terms_page():
    return _render_storefront_page("terms.html")


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


@app.api_route("/s/{share_id}", methods=["GET", "HEAD"])
def store_shared_page(share_id: str):  # noqa: ARG001 — id read by JS from URL
    """Serves the same event detail page; JS detects /s/ prefix and resolves
    the share via /api/store/share/{id} instead of using URL filter params."""
    return _render_storefront_page("event.html")


@app.api_route("/store/shares", methods=["GET", "HEAD"])
def store_shares_page():
    return _render_storefront_page("shares.html")


def _require_non_prod():
    """Test-harness gate: 404 in production. Test pages expose debug info
    (source-mode dropdown, hybrid candidate counts, inventory_source pill)
    that we don't want anonymous prod users to see. Per #57 A1 review:
    'Either @require_auth or gate behind a non-prod env check' — taking
    the non-prod gate so the test pages remain useful in staging without
    a Bearer-token auth handshake on HTML page loads."""
    if _is_production():
        raise HTTPException(404, "not found")


@app.get("/store/test")
def store_test_index_page(_=Depends(_require_non_prod)):
    """Multi-page wiring test harness — index. Sidebar navigates to one
    page per evo-doc workflow (search, performer, venue, event landing)
    plus storefront-specific share links. Useful for verifying the store
    works against real data before merging."""
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "index.html"))


@app.get("/store/test/search")
def store_test_search_page(_=Depends(_require_non_prod)):
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "search.html"))


@app.get("/store/test/performer")
def store_test_performer_page(_=Depends(_require_non_prod)):
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "performer.html"))


@app.get("/store/test/venue")
def store_test_venue_page(_=Depends(_require_non_prod)):
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "venue.html"))


@app.get("/store/test/event")
def store_test_event_page(_=Depends(_require_non_prod)):
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "event.html"))


@app.get("/store/test/share")
def store_test_share_page(_=Depends(_require_non_prod)):
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "share.html"))


@app.get("/store/test/media_test")
def store_test_media_test_page(_=Depends(_require_non_prod)):
    # C1-authored sandbox under 2026-05-13 operator routing. Validates that
    # primary_performer_logo / primary_performer_color (already in the
    # /api/store/events payload) actually render through the test harness.
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "media_test.html"))


@app.get("/store/test/trip")
def store_test_trip_page(_=Depends(_require_non_prod)):
    """Sandbox for the per-performer trip planner (/api/store/performers/{id}/trip-plan).
    Pick a performer + home + travel budget → optimal multi-city itinerary vs sort-by-date."""
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "trip.html"))


@app.get("/store/test/tour")
def store_test_tour_page(_=Depends(_require_non_prod)):
    """Sandbox for the retail 'tour with the artist' agent
    (/api/store/performers/{id}/tour-package). Dual-mode priced multi-city package."""
    return FileResponse(os.path.join(STATIC_DIR, "store", "test", "tour.html"))


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
