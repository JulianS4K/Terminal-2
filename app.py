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

import hmac
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

def _build_storefront_version() -> str:
    """Short-SHA tag used in the `?v=<...>` query string on static asset
    references inside the served HTML shells.

    Resolution order:
      1. RENDER_GIT_COMMIT       — auto-set by Render on every deploy.
      2. RAILWAY_GIT_COMMIT_SHA  — auto-set by Railway on every deploy.
      3. GIT_COMMIT              — set by some CI workflows; defensive fallback.
      4. f"dev-{epoch}"          — local dev / unset prod; bumps per container
         start so a fresh boot always re-fetches even if env wasn't wired.

    Was returning hardcoded "dev" before; Railway audit 2026-05-16 found that
    every Railway deploy served `?v=dev` (no RENDER_GIT_COMMIT, no GIT_COMMIT)
    which defeated the cache-bust entirely. Adding Railway env + an epoch
    fallback restores the invariant.
    """
    sha = (os.environ.get("RENDER_GIT_COMMIT")
           or os.environ.get("RAILWAY_GIT_COMMIT_SHA")
           or os.environ.get("GIT_COMMIT"))
    if sha:
        return sha[:7]
    # Last-resort: per-container epoch so fresh boots always cache-bust.
    return f"dev-{int(time.time())}"


def _build_storefront_base_url() -> str:
    """Absolute base URL used in OG share-card tags so previews
    (iMessage/Slack/WhatsApp/Discord/Twitter) point at THIS deploy, not at
    a hardcoded sibling deploy. Was hardcoded `vibepass-storefront-test.onrender.com`
    in static/store/index.html (PR #166) so Railway-shared links previewed
    the Render service.

    Resolution order:
      1. STOREFRONT_BASE_URL    — manual override (full URL with scheme).
      2. RENDER_EXTERNAL_URL    — auto-set by Render to https://<service>.onrender.com.
      3. RAILWAY_PUBLIC_DOMAIN  — auto-set by Railway to <env>.up.railway.app (no scheme).
      4. Fallback hardcoded Render URL — preserves prior behavior on unconfigured
         envs so nothing regresses.
    """
    override = os.environ.get("STOREFRONT_BASE_URL")
    if override:
        return override.rstrip("/")
    render_url = os.environ.get("RENDER_EXTERNAL_URL")
    if render_url:
        return render_url.rstrip("/")
    railway_dom = os.environ.get("RAILWAY_PUBLIC_DOMAIN")
    if railway_dom:
        dom = railway_dom.strip().removeprefix("https://").removeprefix("http://")
        return f"https://{dom}"
    return "https://vibepass-storefront-test.onrender.com"


_STOREFRONT_VERSION = _build_storefront_version()
_STOREFRONT_BASE_URL = _build_storefront_base_url()
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
_SPECULATIVE_NAME_PATTERNS = (
    "CANCELLED",
    "(IF NECESSARY)",
)


def _is_speculative_event_name(name: str | None) -> bool:
    """True when an event name contains any pattern indicating the game may
    never happen as scheduled (CANCELLED or playoff if-necessary). Consumer
    surfaces should drop these. (Date TBD) events are NOT speculative —
    they're real scheduled games with pending datetime confirmation, surfaced
    via the `tbd` badge."""
    if not name:
        return False
    upper = name.upper()
    return any(p in upper for p in _SPECULATIVE_NAME_PATTERNS)


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

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
CRON_SECRET = os.environ.get("CRON_SECRET")
ALLOWED_EMAIL_DOMAIN = os.environ.get("ALLOWED_EMAIL_DOMAIN", "s4kent.com")

# AUTH_DISABLED is a local-dev kill switch. To prevent a misconfig from
# accidentally opening the whole API, it ONLY takes effect when:
#   (a) AUTH_DISABLED=true is set explicitly, AND
#   (b) at least ONE indicator says we're NOT in production.
# Hardened 2026-05-11; broadened beyond Railway-only check to be portable.
_AUTH_DISABLED_REQUESTED = os.environ.get("AUTH_DISABLED", "false").lower() == "true"

def _is_production() -> bool:
    """Conservative production detector. If ANY of these indicators say
    production, we treat it as production (deny the kill-switch)."""
    railway = (os.environ.get("RAILWAY_ENVIRONMENT") or "").lower() == "production"
    generic = (os.environ.get("ENVIRONMENT") or "").lower() == "production"
    node = (os.environ.get("NODE_ENV") or "").lower() == "production"
    py = (os.environ.get("PYTHON_ENV") or "").lower() == "production"
    fly = bool(os.environ.get("FLY_APP_NAME"))  # Fly.io
    render = bool(os.environ.get("RENDER"))     # Render
    # If NO env-indicator is set at all, we're likely local dev — only then
    # honor the kill switch. This errs heavily on the side of safety.
    any_prod_signal = railway or generic or node or py or fly or render
    return any_prod_signal

AUTH_DISABLED = _AUTH_DISABLED_REQUESTED and not _is_production()
if _AUTH_DISABLED_REQUESTED and not AUTH_DISABLED:
    print("WARNING: AUTH_DISABLED=true ignored — production indicator detected (RAILWAY_ENVIRONMENT / ENVIRONMENT / NODE_ENV / PYTHON_ENV / FLY_APP_NAME / RENDER).")

# STOREFRONT_SQL_ONLY — demo mode for pre-checkout MVP. When on:
#   - /api/store/events/{id} reads ticket_groups from listings_snapshots
#     (cron-collected) instead of going live to TEvo.
#   - /api/store/reserve skips TEvo validation and returns a mock receipt.
#   - /api/store/events/near forces source=supabase (no TEvo geo call).
#
# Why: until real checkout is wired, live TEvo only buys us freshness, and
# the test environment shouldn't burn TEvo quota on every page load. Flip
# off the moment real /v9/orders calls go live — stale snapshots are
# dangerous when shoppers can actually buy.
STOREFRONT_SQL_ONLY = os.environ.get("STOREFRONT_SQL_ONLY", "false").lower() == "true"
if STOREFRONT_SQL_ONLY:
    print("STOREFRONT_SQL_ONLY=true — storefront serves from listings_snapshots; no live TEvo calls on store routes.")

# STOREFRONT_SEARCH_SQL_ONLY — independent flag for /api/store/search routing
# (operator 2026-05-18). Splits search off from the general STOREFRONT_SQL_ONLY
# so search can default to SQL (snappy + zero TEvo quota) while event-detail
# stays on TEvo live (fresh ticket-group pricing). To revert search to TEvo:
# set STOREFRONT_SEARCH_SQL_ONLY=false. STOREFRONT_SQL_ONLY=true still wins
# (forces SQL for both) for backward compat with prior deployments. Live
# search code path (_search_live) is preserved as a flippable fallback.
STOREFRONT_SEARCH_SQL_ONLY = os.environ.get("STOREFRONT_SEARCH_SQL_ONLY", "true").lower() == "true"
if STOREFRONT_SEARCH_SQL_ONLY and not STOREFRONT_SQL_ONLY:
    print("STOREFRONT_SEARCH_SQL_ONLY=true — /api/store/search uses _search_sql_only; event-detail still live TEvo.")

# STOREFRONT_PREFER_INTERNAL_ZONES — flip on once the hand-curated granular
# zones (NYK at MSG taxonomy, etc.) cover most/all sections. Today most of
# them have coverage gaps that leave shoppers with un-filterable listings,
# so the default surfaces the consumer-bowl layer (Lower 100s / Club 200s
# etc.) which is well-covered. Internal detection logic stays wired so a
# flip flag does the right thing event-by-event when data matures.
STOREFRONT_PREFER_INTERNAL_ZONES = (
    os.environ.get("STOREFRONT_PREFER_INTERNAL_ZONES", "false").lower() == "true"
)
if STOREFRONT_PREFER_INTERNAL_ZONES:
    print("STOREFRONT_PREFER_INTERNAL_ZONES=true — granular zones preferred when (performer, venue) has them.")

# Reserve endpoint auth gate. Default is `true` — unauthenticated state-changing
# routes are wrong by default. MVP demo envs that want the front-end button to
# work without a Supabase session must explicitly set STOREFRONT_RESERVE_REQUIRES_AUTH=false.
# Sprint 2 (real-purchase path) keeps this true unconditionally.
STOREFRONT_RESERVE_REQUIRES_AUTH = (
    os.environ.get("STOREFRONT_RESERVE_REQUIRES_AUTH", "true").lower() == "true"
)
if not STOREFRONT_RESERVE_REQUIRES_AUTH:
    print("STOREFRONT_RESERVE_REQUIRES_AUTH=false — /api/store/reserve is UNAUTHENTICATED (MVP demo mode).")

# TEvo Hosted Checkout — DORMANT until the operator provisions the domain.
# When set (e.g. "checkout.vibepass.com"), the storefront Reserve button
# redirects the buyer to TEvo's hosted checkout at
#   https://<domain>/checkout/payment/<event_id>/<ticket_group_id>?quantity=N
# where TEvo is the merchant-of-record and handles payment, Apple/Google
# Pay, and fraud. When empty (the default) the Reserve flow stays the MVP
# mock — NO real purchases, NO redirect. This is a pure browser redirect:
# our backend never writes to TEvo, so the RULE 2 read-only wall is not
# involved. Enabling is operator-gated: provision the hosted-checkout
# subdomain with the TEvo rep + point DNS (CNAME -> cname.vercel-dns.com),
# land real legal copy (D1-OPS-5), THEN set this env var.
STOREFRONT_CHECKOUT_DOMAIN = os.environ.get("STOREFRONT_CHECKOUT_DOMAIN", "").strip()
if STOREFRONT_CHECKOUT_DOMAIN:
    print(f"STOREFRONT_CHECKOUT_DOMAIN={STOREFRONT_CHECKOUT_DOMAIN} — Reserve redirects to TEvo Hosted Checkout (real purchases ENABLED).")

sb = None
if SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY:
    try:
        from supabase import create_client
        sb = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    except ImportError:
        print("WARNING: supabase package not installed. Run: pip install supabase")
    except Exception as e:
        print(f"WARNING: could not init Supabase client: {e}")


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
            print(f"Could not load TEvo creds from settings: {e}")
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
    print(f"TEvo client lazy-initialized (creds source: {src})")
    return client


SANDBOX = os.environ.get("TEVO_SANDBOX", "false").lower() == "true"
TOKEN, SECRET, CREDS_SOURCE = resolve_tevo_creds()
if not TOKEN or not SECRET:
    # In SQL-only demo mode the storefront never calls TEvo — the EvoClient
    # is never invoked. Boot in degraded mode (no TEvo client) so the
    # storefront still serves from listings_snapshots. Any non-storefront
    # route that needs the live client (broker terminal, /api/admin/*) will
    # crash on the missing global, which is the right failure mode.
    if STOREFRONT_SQL_ONLY:
        print(
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
    print(f"TEvo creds loaded from: {CREDS_SOURCE}")
    client = EvoClient(TOKEN, SECRET, sandbox=SANDBOX)


# ---------- Auth dependency ----------

def require_auth(authorization: str | None = Header(None)):
    """Validate a Supabase-issued JWT + enforce email domain.

    Browser sends 'Authorization: Bearer <jwt>' on every API call.
    We hit Supabase's /auth/v1/user to validate the token and get the user,
    then check the email ends in the allowed domain.
    """
    if AUTH_DISABLED:
        return None
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not SUPABASE_URL or not SUPABASE_ANON_KEY:
        raise HTTPException(500, "Supabase auth not configured on server")
    try:
        r = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers={"Authorization": f"Bearer {token}", "apikey": SUPABASE_ANON_KEY},
            timeout=5,
        )
    except Exception as e:
        # Don't surface internal exception detail externally — may expose
        # Supabase hostnames, connection error strings, or timeout messages
        # that are useful to an attacker mapping our internal topology.
        logging.getLogger(__name__).error("Auth check against Supabase failed: %s", e)
        raise HTTPException(502, "auth check failed — upstream auth service unreachable")
    if not r.ok:
        raise HTTPException(401, "invalid session")
    user = r.json()
    # Stop-gap hardening, mirrors d2_dashboard/main.py require_auth:
    #   - aud must be "authenticated"  → rejects service-role / anon tokens
    #   - email_confirmed_at must be set → rejects unconfirmed signups
    if user.get("aud") != "authenticated":
        raise HTTPException(401, "invalid token audience")
    if not user.get("email_confirmed_at"):
        raise HTTPException(403, "email not confirmed")
    email = (user.get("email") or "").lower()
    if not email.endswith("@" + ALLOWED_EMAIL_DOMAIN.lower()):
        raise HTTPException(403, f"access restricted to @{ALLOWED_EMAIL_DOMAIN}")
    return user


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
    if _origin == "*" or "*" in _origin:
        raise RuntimeError(
            f"CORS_ALLOWED_ORIGINS contains a wildcard ({_origin!r}); rejected because "
            "allow_credentials=True is incompatible with wildcard origins. List concrete "
            "https://… URLs in the env var instead."
        )
    if not (_origin.startswith("http://localhost") or _origin.startswith("http://127.0.0.1") or _origin.startswith("https://")):
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
        "connect-src 'self' https://*.supabase.co; "
        "frame-ancestors 'none'; "
        "base-uri 'self'; "
        "form-action 'self'"
    )

    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        response.headers.setdefault("Content-Security-Policy", self._CSP)
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
        ("/api/store/reserve",  20,  60.0),  # mock reserve, but hits TEvo
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
    if not page or page in ("", "/"):
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
    if not page or page in ("", "/"):
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
        # TEvo Hosted Checkout: domain is null while dormant (Reserve stays
        # the MVP mock); when the operator sets STOREFRONT_CHECKOUT_DOMAIN,
        # store.js redirects Reserve to the hosted checkout URL.
        "checkout_domain": STOREFRONT_CHECKOUT_DOMAIN or None,
        "purchase_enabled": bool(STOREFRONT_CHECKOUT_DOMAIN),
    }

# ---------- Protected routes ----------

@app.get("/api/config")
def config_info(user=Depends(require_auth)):
    return {
        "supabase_configured": sb is not None,
        "collect_available": bool(sb is not None and CRON_SECRET and SUPABASE_URL),
        "env": "sandbox" if SANDBOX else "prod",
        "user_email": (user or {}).get("email"),
    }


@app.get("/api/events")
def events_search(
    q: str | None = None,
    performer_id: int | None = None,
    venue_id: int | None = None,
    occurs_at_gte: str | None = Query(None, alias="occurs_at.gte"),
    occurs_at_lte: str | None = Query(None, alias="occurs_at.lte"),
    only_with_available_tickets: bool = True,
    _=Depends(require_auth),
):
    events = client.search_events_all(
        q=q or None,
        performer_id=performer_id,
        venue_id=venue_id,
        occurs_at_gte=occurs_at_gte,
        occurs_at_lte=occurs_at_lte,
        only_with_available_tickets=only_with_available_tickets,
        order_by="events.popularity_score DESC",
    )
    return {"count": len(events), "events": events}


_PARKING_RE = re.compile(r"\b(parking|garage|valet|lot)\b", re.IGNORECASE)

def _is_event_seat(tg: dict) -> bool:
    """True if this ticket_group is a real event seat (not parking / suite /
    hospitality). TEvo's `type` field is the canonical signal — defaults to
    'event' for actual seats. As a backup, scan section/format strings for
    parking-style tokens."""
    t = (tg.get("type") or "event").lower()
    if t != "event":
        return False
    section = (tg.get("section") or "")
    if _PARKING_RE.search(section):
        return False
    fmt = (tg.get("format") or "").lower()
    if "parking" in fmt:
        return False
    return True


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


@app.get("/api/performers/{performer_id}")
def performer_detail(performer_id: int, include_opponents: bool = True, _=Depends(require_auth)):
    return client.get_performer(performer_id, include_opponents=include_opponents)


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


@app.get("/api/broker/leagues")
def broker_leagues(_=Depends(require_auth)):
    """Static list of ESPN-tracked leagues for the league-browse strip in the Performers tab."""
    return {"leagues": _ESPN_LEAGUES}


@app.get("/api/broker/performer/{performer_id}/assets")
def broker_performer_assets(performer_id: int, _=Depends(require_auth)):
    """ESPN team logo + colors + URLs for a TEvo performer. Backed by
    performer_metadata (populated by crawl-espn-team-assets fn — drained
    every 3 min by cron 'crawl-espn-team-assets-3min').

    Returns null fields for performers without ESPN mapping (e.g. concerts
    or playoff bracket placeholders). 65/866 populated as of 2026-05-08.
    """
    db = require_sb()
    row = (db.table("performer_metadata")
             .select("performer_id, name, espn_team_id, espn_league, "
                     "color_primary, color_alternate, "
                     "logo_default_url, logo_dark_url, logo_scoreboard_url, logo_4k_primary_url, logo_secondary_url, "
                     "espn_team_url, espn_roster_url, espn_schedule_url, espn_fetched_at")
             .eq("performer_id", performer_id).limit(1).execute().data or [])
    return row[0] if row else {"performer_id": performer_id, "logo_default_url": None}


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


@app.get("/api/broker/performers/{performer_id}/trip-plan")
def broker_performer_trip_plan(
    performer_id: int,
    home_lat: float,
    home_lon: float,
    budget_km: float = 6000.0,
    home_name: str = "Home",
    days: int = 365,
    max_events: int | None = None,
    budget_usd: float | None = None,
    qty: int = 1,
    _=Depends(require_auth),
):
    """D0 terminal: optimal trip around a touring performer's upcoming concert dates.

    Given a home location + travel budget (and optional ticket-spend budget + tickets/show),
    returns the maximum-value itinerary plus the sort-by-date baseline for comparison.
    """
    return _trip_plan_payload(performer_id, home_lat, home_lon, budget_km,
                              home_name, days, max_events, budget_usd, qty)


def _clean_section(s: str | None) -> str | None:
    s = (s or "").strip()[:24]
    return s or None


def _tour_dates(days: int):
    from datetime import date, timedelta
    start = date.today()
    return start, start + timedelta(days=max(1, min(int(days), 730)))


def _tour_package_payload(performer_id: int, home_lat: float, home_lon: float,
                          qty: int, budget_km: float, home_name: str, days: int,
                          budget_usd: float | None, side: str, clear_at: float,
                          away_margin: float, section_like: str | None = None,
                          prefer_owned: bool = False) -> dict:
    """Shared body for the retail 'tour with the artist' routes (D0 + store).

    Dual-mode: owned-splits where we hold inventory (concerts), market-sourced buy-to-fulfill
    for a team's away games (road owned ~ 0). Pure read + compute — no writes, no upstream API.
    """
    from trip_planner import plan_performer_tour

    db = require_sb()
    start, end = _tour_dates(days)
    spend = None if budget_usd is None else max(0.0, min(float(budget_usd), 10_000_000.0))
    return plan_performer_tour(
        db, int(performer_id), float(home_lat), float(home_lon),
        max(1, min(int(qty), 50)), max(100.0, min(float(budget_km), 50000.0)),
        start, end, home_name=(home_name or "Home").strip()[:60], budget_usd=spend,
        side=(side if side in ("auto", "away", "home", "concert") else "auto"),
        clear_at=min(max(float(clear_at), 0.01), 1.0),
        away_margin=min(max(float(away_margin), 0.0), 2.0),
        section_like=_clean_section(section_like), prefer_owned=bool(prefer_owned),
    )


def _multi_tour_payload(performer_ids: str, home_lat: float, home_lon: float, qty: int,
                        budget_km: float, home_name: str, days: int, budget_usd: float | None,
                        side: str, clear_at: float, away_margin: float,
                        section_like: str | None, prefer_owned: bool) -> dict:
    """'Plan my summer': one routed+priced package across several performers' events."""
    from trip_planner import plan_multi_performer_tour

    ids = [int(x) for x in str(performer_ids).replace(" ", "").split(",") if x][:8]
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


@app.get("/api/broker/performers/{performer_id}/tour-package")
def broker_performer_tour_package(
    performer_id: int,
    home_lat: float,
    home_lon: float,
    qty: int = 3,
    budget_km: float = 8000.0,
    home_name: str = "Home",
    days: int = 365,
    budget_usd: float | None = None,
    side: str = "auto",
    clear_at: float = 0.15,
    away_margin: float = 0.18,
    section_like: str | None = None,
    prefer_owned: bool = False,
    _=Depends(require_auth),
):
    """D0: retail 'tour with the artist' package — routed multi-city tour priced via the
    dual-mode model (owned-splits for concerts, market-sourced for a team's away games)."""
    return _tour_package_payload(performer_id, home_lat, home_lon, qty, budget_km, home_name,
                                 days, budget_usd, side, clear_at, away_margin,
                                 section_like, prefer_owned)


@app.get("/api/broker/tours/multi")
def broker_multi_tour(
    performer_ids: str,
    home_lat: float,
    home_lon: float,
    qty: int = 3,
    budget_km: float = 10000.0,
    home_name: str = "Home",
    days: int = 365,
    budget_usd: float | None = None,
    side: str = "auto",
    clear_at: float = 0.15,
    away_margin: float = 0.18,
    section_like: str | None = None,
    prefer_owned: bool = False,
    _=Depends(require_auth),
):
    """D0 'plan my summer' — one package across several performers (comma-separated ids)."""
    return _multi_tour_payload(performer_ids, home_lat, home_lon, qty, budget_km, home_name,
                               days, budget_usd, side, clear_at, away_margin,
                               section_like, prefer_owned)


def _discover_payload(home_lat: float, home_lon: float, within_mi: float, days: int,
                      min_shows: int, concerts_only: bool) -> dict:
    """Shared body for reverse-discovery ('tours near me'). Read-only."""
    from trip_planner import discover_tours_near

    db = require_sb()
    start, end = _tour_dates(days)
    return discover_tours_near(
        db, float(home_lat), float(home_lon),
        max(5.0, min(float(within_mi), 1000.0)), start, end,
        min_shows=max(1, min(int(min_shows), 6)),
        event_types=["concert"] if concerts_only else None,
    )


@app.get("/api/broker/tours/near")
def broker_tours_near(
    home_lat: float,
    home_lon: float,
    within_mi: float = 250.0,
    days: int = 120,
    min_shows: int = 2,
    concerts_only: bool = False,
    _=Depends(require_auth),
):
    """D0 reverse discovery — performers with >= min_shows within `within_mi` of home."""
    return _discover_payload(home_lat, home_lon, within_mi, days, min_shows, concerts_only)


def _bulk_performer_assets(db, performer_ids: list[int]) -> dict[int, dict]:
    """Fetch performer_metadata for many performer_ids at once. Returns map
    {performer_id: {logo_default_url, color_primary, ...}}. Used by event
    overview to attach home + away logos in a single roundtrip."""
    if not performer_ids:
        return {}
    rows = (db.table("performer_metadata")
              .select("performer_id, name, espn_team_id, espn_league, "
                      "color_primary, color_alternate, logo_default_url, logo_dark_url")
              .in_("performer_id", performer_ids)
              .execute()).data or []
    return {int(r["performer_id"]): r for r in rows}


# Playoff-specific phrases we recognize in event names. Order matters: more
# specific labels (NBA Finals) are tried before generic round indicators so
# the badge surfaces "NBA Finals" instead of "Playoffs" when both match.
_PLAYOFF_SPECIFIC_RE = re.compile(
    r"\b("
    r"NBA\s+Finals|"
    r"NBA\s+(?:Eastern|Western)\s+Conference\s+(?:Semi)?Finals|"
    r"NHL\s+Stanley\s+Cup\s+Finals|"
    r"NHL\s+(?:Eastern|Western)\s+Conference\s+(?:Semi)?Finals|"
    r"Stanley\s+Cup(?:\s+Finals?)?|"
    r"World\s+Series|"
    r"Super\s+Bowl(?:\s+L[IVX]+)?|"
    r"MLS\s+Cup|"
    r"NCAA\s+(?:Final\s+Four|National\s+Championship)|"
    r"College\s+Football\s+Playoff(?:\s+National\s+Championship)?"
    r")\b",
    re.IGNORECASE,
)
_PLAYOFF_GENERIC_RE = re.compile(
    r"\((?:Game\s+\d+|Round\s+\d+)|"           # parenthetical TEvo markers
    r"\b(?:Playoffs?|Postseason|Wild\s+Card|"
    r"Conference\s+Finals?|Conference\s+Semifinals?|"
    r"Division\s+Series)\b",
    re.IGNORECASE,
)


def _classify_playoff(event_name: str | None) -> dict | None:
    """Return a playoff badge dict for the event name, or None.

    Two-tier:
      - specific  match (e.g. "NBA Finals") → that phrase is the label
      - generic   match (e.g. "Round 3", "(Game 7,") → label = "Playoffs"

    Falls back to None when nothing matches. Case-insensitive throughout.
    """
    if not event_name:
        return None
    m = _PLAYOFF_SPECIFIC_RE.search(event_name)
    if m:
        # Normalize whitespace so multi-word matches print cleanly.
        label = re.sub(r"\s+", " ", m.group(1)).strip()
        return {"label": label, "kind": "specific"}
    if _PLAYOFF_GENERIC_RE.search(event_name):
        return {"label": "Playoffs", "kind": "generic"}
    return None


# Marquee competitions — events that aren't playoffs but carry their own
# editorial weight (US Open Tennis, F1 Grand Prix, Inter Miami away). Added
# 2026-05-19 v3 for the Featured rail's narrative-signal branch.
_MARQUEE_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"^US\s+Open\s+Tennis\b", re.I),                 "US Open Tennis"),
    (re.compile(r"\bFormula\s*1\b|\bGrand\s+Prix\b", re.I),      "F1"),
    # Inter Miami AWAY only — when the matchup is "Inter Miami CF at <home>".
    # Home games carry less narrative interest (we're not catering to local
    # Miami buyers in this storefront's scope).
    (re.compile(r"^Inter\s+Miami\s+CF\s+at\s+", re.I),           "Inter Miami away"),
]


def _classify_marquee_competition(event_name: str | None) -> str | None:
    """Return a marquee-competition label for the event name, or None.
    Used by `_section_featured` to flag US Open / F1 / Inter Miami away
    games into the Featured rail regardless of pricing signals.
    """
    if not event_name:
        return None
    for pat, label in _MARQUEE_PATTERNS:
        if pat.search(event_name):
            return label
    return None


# FIFA World Cup 2026 detection (D3, 2026-06-16). EVO/TEvo lists World Cup
# matches under the performer "World Cup Soccer" with names like
# "2026 World Cup Soccer - Match 72 (Congo DR vs Uzbekistan) (Group K)".
# Tight by design so it does NOT catch lookalikes that merely contain the
# words "world cup": MLB "(World Cup Scarf Giveaway)" promos, "Rugby World
# Cup", or "World Cup Countdown Concert" — none of which are WC matches.
_WORLD_CUP_RE = re.compile(
    r"\bworld\s*cup\s*soccer\b|\bworld\s*cup\b.{0,40}\bmatch\s+\d+", re.I
)


def _classify_world_cup(event_name: str | None,
                        performer_name: str | None = None) -> bool:
    """True if the event is a FIFA World Cup soccer match.

    We surface owned World Cup matches in the storefront Featured rail
    regardless of host city — the rail is NYC-anchored, but the World Cup is
    a national draw and our owned WC inventory can sit at any host venue
    (e.g. Match 72 at Mercedes-Benz Stadium, Atlanta). The primary signal is
    the EVO performer name "World Cup Soccer"; the name regex is a fallback.
    """
    if performer_name and performer_name.strip().lower() == "world cup soccer":
        return True
    if not event_name:
        return False
    return bool(_WORLD_CUP_RE.search(event_name))


# Canadian team detection (2026-05-19 v4) — operator directive: Canadian
# holidays (Canada Day, Civic Holiday, etc.) should only tag events where
# a Canadian team is visiting an NYC venue. Otherwise the holiday window
# leaks "Canada Day" tags onto Yankees-Tigers games which is nonsensical
# for the consumer.
_CANADIAN_TEAM_RE = re.compile(
    r"\b("
    r"Toronto\s+(?:Blue\s+Jays|Raptors|FC|Maple\s+Leafs)|"
    r"Montréal?\s+Canadiens|CF\s+Montr|"
    r"Vancouver\s+(?:Canucks|Whitecaps)|"
    r"Edmonton\s+Oilers|Calgary\s+Flames|"
    r"Ottawa\s+Senators|Winnipeg\s+Jets"
    r")\b",
    re.IGNORECASE,
)

def _has_canadian_team(event_name: str | None) -> bool:
    """True if the event name mentions a Canadian major-league team. Used
    to gate Canadian holiday tagging in the NYC storefront."""
    if not event_name:
        return False
    return bool(_CANADIAN_TEAM_RE.search(event_name))


# Holiday priority — higher wins on same-day conflicts (operator directive
# 2026-05-19 v4: "Father's Day over Juneteenth when they conflict on same
# day"). Generic ranking favors family-celebration holidays (typically
# associated with attending sports together) over administrative holidays.
_HOLIDAY_PRIORITY: dict[str, int] = {
    "Father's Day":     100,
    "Mother's Day":     100,
    "Memorial Day":      95,
    "Independence Day":  95,
    "Labor Day":         95,
    "Thanksgiving":      95,
    "Christmas":         95,
    "New Year's Day":    90,
    "Juneteenth":        50,
}


def _classify_holiday_proximity(candidate_date_iso: str,
                                observed_date_iso: str) -> str | None:
    """Decide whether a candidate event date earns a holiday tag, and what
    flavor. Returns one of:
      - "day_of"     → candidate == observed_date           (tag "Memorial Day")
      - "weekend_of" → candidate is Sat/Sun in ±2 window    (tag "Memorial Day Weekend")
      - None         → candidate is a non-holiday weekday   (no tag)

    Operator directive 2026-05-19 v6: "suffix only when weekend = true,
    not for a tuesday event". A Tuesday after Memorial Day Monday is NOT
    Memorial Day Weekend — the holiday window-expansion (±2 from observed_date)
    only earns a weekend tag for actual weekend days. Other weekdays in
    the window fall back to the non-holiday Featured branches (premium,
    market-anchor) or land in other rails (moving_fast, etc.).

    Pure function — accepts ISO date strings, returns a string or None.
    Caller is expected to have already verified the candidate's date is
    within ±2 days of observed_date (i.e. the holiday is in range).
    """
    from datetime import date as _date_cls
    try:
        cand_d = _date_cls.fromisoformat(candidate_date_iso)
    except (TypeError, ValueError):
        return None
    if candidate_date_iso == observed_date_iso:
        return "day_of"
    # weekday(): 0=Mon..6=Sun; 5=Sat, 6=Sun
    if cand_d.weekday() in (5, 6):
        return "weekend_of"
    return None


def _bulk_event_context(db, event_ids: list[int]) -> dict[int, dict]:
    """Bulk-fetch all six context dimensions a storefront card / detail page
    might surface, in one helper.

    Returns:
      { event_id: { "rivalry":    {...}|None,
                    "mlb_series": {...}|None,
                    "tournament": {...}|None,
                    "weather":    {...}|None,
                    "holiday":    {...}|None,
                    "playoff":    {...}|None } }

    Backing views (audit / context lanes — P1 reads only):
      rivalry      ← v_rivalry_events             (mig 20260509530000)
      mlb_series   ← v_mlb_game_series            (mig 20260509470000)
      tournament   ← v_event_tournament_context   (mig 20260510010000)
      weather      ← v_event_weather_with_fallback (mig 20260509560000)
      holiday      ← v_event_calendar_context     (mig 20260509550000)
      playoff      ← regex on events.name + performer_metadata series tags

    Weather + holiday + playoff rules are applied here, not in the client, so
    the storefront UI doesn't have to know about climatology vs forecast vs
    severity tiers, or playoff naming conventions — it just renders what
    the server hands it.

    Missing views (per-env) degrade gracefully to None for that key.
    """
    if not event_ids:
        return {}

    ids = [int(e) for e in event_ids if e is not None]
    ctx: dict[int, dict] = {
        eid: {"rivalry": None, "mlb_series": None, "tournament": None,
              "weather": None, "holiday": None, "playoff": None}
        for eid in ids
    }

    # Playoff: read event names + series-tag performer membership in one
    # roundtrip. Series tags like "NBA Finals" / "NBA Eastern Conference
    # Semifinals" attach to the event via performer_ids and give us the
    # most specific label; the name regex covers Round 3 / Game 7 events
    # that don't yet have a series-tag attached.
    try:
        ev_rows = (db.table("events").select("id,name,performer_ids")
                     .in_("id", ids).execute().data) or []
        # Collect all unique non-primary performer ids so we can resolve
        # series-tag names in one query.
        candidate_perf_ids: set[int] = set()
        for er in ev_rows:
            for p in (er.get("performer_ids") or []):
                try:
                    candidate_perf_ids.add(int(p))
                except (TypeError, ValueError):
                    pass
        series_tag_by_id: dict[int, str] = {}
        if candidate_perf_ids:
            try:
                pm_rows = (db.table("performer_metadata")
                             .select("performer_id,name")
                             .in_("performer_id", list(candidate_perf_ids))
                             .execute().data) or []
                for pm in pm_rows:
                    nm = (pm.get("name") or "")
                    # Only keep "series tag" performers — leagues + rounds.
                    if _PLAYOFF_SPECIFIC_RE.search(nm) or re.search(
                        r"\b(NBA|NHL|NFL|MLB|MLS|WNBA)\s+(Playoffs?|Postseason|"
                        r"Wild\s+Card|Finals?|Semifinals?|Championship|"
                        r"Conference)\b",
                        nm, re.IGNORECASE,
                    ):
                        series_tag_by_id[int(pm["performer_id"])] = nm
            except Exception:
                series_tag_by_id = {}
        for er in ev_rows:
            eid = int(er.get("id") or 0)
            if eid not in ctx:
                continue
            # Prefer the most-specific series-tag performer if attached.
            tagged: str | None = None
            for p in (er.get("performer_ids") or []):
                try:
                    pid = int(p)
                except (TypeError, ValueError):
                    continue
                name = series_tag_by_id.get(pid)
                if not name:
                    continue
                # Specific (e.g. "NBA Finals") beats generic ("NBA Playoffs").
                if _PLAYOFF_SPECIFIC_RE.search(name):
                    tagged = name
                    break
                if tagged is None:
                    tagged = name
            if tagged:
                # Strip umbrella "Playoffs" / "Postseason" when we have a
                # more specific round-tag handy.
                kind = "specific" if _PLAYOFF_SPECIFIC_RE.search(tagged) else "generic"
                ctx[eid]["playoff"] = {"label": tagged, "kind": kind}
                continue
            # Fall back to regex on the event name.
            ctx[eid]["playoff"] = _classify_playoff(er.get("name"))
    except Exception:
        pass

    # Rivalry: v_rivalry_events can emit duplicate rows when both the
    # performer-id and name joins match the same matchup, so dedup at the
    # event id level (first row wins; intensity is the same either way).
    try:
        rows = (db.table("v_rivalry_events")
                  .select("tevo_event_id,rivalry_name,league,is_branded,"
                          "rivalry_intensity,wikipedia_url")
                  .in_("tevo_event_id", ids)
                  .execute()).data or []
        seen: set[int] = set()
        for r in rows:
            eid = int(r["tevo_event_id"])
            if eid in seen or eid not in ctx:
                continue
            seen.add(eid)
            ctx[eid]["rivalry"] = {
                "name": r.get("rivalry_name"),
                "league": r.get("league"),
                "is_branded": bool(r.get("is_branded")),
                "intensity": r.get("rivalry_intensity"),
                "wikipedia_url": r.get("wikipedia_url"),
            }
    except Exception:
        pass

    # MLB series: v_mlb_game_series rows hold the full tevo_event_ids array
    # for the series. Pull every series whose end-date is today or later, then
    # walk the array to attach the series context to each game in the set,
    # adding game_number (1-based position within the series).
    try:
        today_iso = datetime.now(timezone.utc).date().isoformat()
        rows = (db.table("v_mlb_game_series")
                  .select("home_team,away_team,venue_name,series_start,series_end,"
                          "series_span_days,game_count,tevo_event_ids,branded_series_name")
                  .gte("series_end", today_iso)
                  .execute()).data or []
        for r in rows:
            tevo_ids = r.get("tevo_event_ids") or []
            tevo_ids = [int(e) for e in tevo_ids if e is not None]
            for pos, eid in enumerate(tevo_ids, start=1):
                if eid not in ctx:
                    continue
                ctx[eid]["mlb_series"] = {
                    "home_team": r.get("home_team"),
                    "away_team": r.get("away_team"),
                    "venue_name": r.get("venue_name"),
                    "series_start": r.get("series_start"),
                    "series_end": r.get("series_end"),
                    "span_days": r.get("series_span_days"),
                    "game_count": r.get("game_count"),
                    "branded_name": r.get("branded_series_name"),
                    "sibling_event_ids": tevo_ids,
                    "game_number": pos,
                }
    except Exception:
        pass

    # Tournament: one row per TEvo event in v_event_tournament_context (left
    # join on event_xref + espn_tournament_events). Surfaces a multi-day
    # parent so "Round 2 of US Open · Aug 26 – Sep 8" can render.
    try:
        rows = (db.table("v_event_tournament_context")
                  .select("tevo_event_id,tournament_name,tournament_short_name,"
                          "tournament_start,tournament_end,tournament_venue,"
                          "espn_league,circuit_name")
                  .in_("tevo_event_id", ids)
                  .execute()).data or []
        for r in rows:
            eid = int(r["tevo_event_id"])
            if eid not in ctx:
                continue
            ctx[eid]["tournament"] = {
                "name": r.get("tournament_name"),
                "short_name": r.get("tournament_short_name"),
                "start_date": r.get("tournament_start"),
                "end_date": r.get("tournament_end"),
                "venue": r.get("tournament_venue"),
                "league": r.get("espn_league"),
                "circuit_name": r.get("circuit_name"),
            }
    except Exception:
        pass

    # Weather: v_event_weather_with_fallback has fallback-coalesced + raw
    # forecast/climatology columns + NWS alert JSON. Apply display rules
    # server-side so the client just renders what's set:
    #   - indoor + no alert       → None (hide)
    #   - any venue + active NWS  → alert (always shows up to 16d)
    #   - outdoor + ≤7d forecast  → full forecast
    #   - outdoor 8-16d + alert   → alert only
    #   - otherwise               → None
    try:
        rows = (db.table("v_event_weather_with_fallback")
                  .select("tevo_event_id,days_to_event,weather_kind,is_indoor,"
                          "fcst_temp_f,fcst_precip_pct,fcst_precip_in,"
                          "fcst_wind_mph,fcst_gust_mph,fcst_summary,"
                          "weather_alerts")
                  .in_("tevo_event_id", ids)
                  .execute()).data or []
        for r in rows:
            eid = int(r["tevo_event_id"])
            if eid not in ctx:
                continue
            days = r.get("days_to_event")
            if days is None or days > 16 or days < 0:
                continue  # too far out or past
            alerts = r.get("weather_alerts") or []
            kind = r.get("weather_kind") or ""
            is_indoor = bool(r.get("is_indoor"))

            # Slim NWS alerts down to fields the UI actually shows.
            slim_alerts = []
            for a in alerts[:3]:  # cap at 3 — anything more is noise
                slim_alerts.append({
                    "event": a.get("event"),
                    "severity": a.get("severity"),
                    "impact_tier": a.get("impact_tier"),
                    "headline": a.get("headline"),
                    "expires_at": a.get("expires_at"),
                })

            has_alert = bool(slim_alerts)
            show_forecast = (
                not is_indoor
                and kind.startswith("forecast_outdoor")
                and days <= 7
                and r.get("fcst_temp_f") is not None
            )

            if not has_alert and not show_forecast:
                continue  # nothing worth showing

            w: dict = {
                "days_to_event": days,
                "is_indoor": is_indoor,
                "alerts": slim_alerts,
            }
            if show_forecast:
                w["forecast"] = {
                    "temp_f": r.get("fcst_temp_f"),
                    "summary": r.get("fcst_summary"),
                    "precip_pct": r.get("fcst_precip_pct"),
                    "precip_in": r.get("fcst_precip_in"),
                    "wind_mph": r.get("fcst_wind_mph"),
                    "gust_mph": r.get("fcst_gust_mph"),
                }
            ctx[eid]["weather"] = w
    except Exception:
        pass

    # Holiday: v_event_calendar_context returns JSON arrays of holidays
    # on/near the event date + active school breaks, each with precision
    # (national/state/city) and impact (boost/neutral). Pick the single
    # most-relevant pill to show — day-of beats nearby, city beats state
    # beats national, "boost" beats "neutral".
    try:
        rows = (db.table("v_event_calendar_context")
                  .select("tevo_event_id,event_date,is_holiday,"
                          "within_holiday_window,school_break_active,"
                          "holidays_today,holidays_nearby,school_breaks_active")
                  .in_("tevo_event_id", ids)
                  .execute()).data or []

        def _precision_rank(p: str) -> int:
            return {"city": 0, "state": 1, "national": 2}.get(p or "national", 3)

        for r in rows:
            eid = int(r["tevo_event_id"])
            if eid not in ctx:
                continue

            today = r.get("holidays_today") or []
            nearby = r.get("holidays_nearby") or []
            breaks = r.get("school_breaks_active") or []

            best: dict | None = None

            # Day-of holiday: any precision, boost wins over neutral.
            if today:
                today_sorted = sorted(
                    today,
                    key=lambda h: (
                        0 if h.get("impact") == "boost" else 1,
                        _precision_rank(h.get("precision")),
                    ),
                )
                h = today_sorted[0]
                best = {
                    "kind": "day_of",
                    "label": h.get("name"),
                    "impact": h.get("impact"),
                    "precision": h.get("precision"),
                    "date": r.get("event_date"),
                }

            # Nearby (±1 day) — only show if no day-of beat us.
            if best is None and nearby:
                nearby_sorted = sorted(
                    nearby,
                    key=lambda h: (
                        0 if h.get("impact") == "boost" else 1,
                        _precision_rank(h.get("precision")),
                        abs(int(h.get("days_offset") or 0)),
                    ),
                )
                h = nearby_sorted[0]
                offset = int(h.get("days_offset") or 0)
                suffix = " weekend" if abs(offset) == 1 else ""
                best = {
                    "kind": "nearby",
                    "label": (h.get("name") or "") + suffix,
                    "impact": h.get("impact"),
                    "precision": h.get("precision"),
                    "date": h.get("date"),
                    "days_offset": offset,
                }

            # School break — only summer/winter (the only ones that meaningfully
            # boost attendance for weekday games). Otherwise we'd label half
            # the calendar with spring/fall breaks that don't move pricing.
            if best is None and breaks:
                summer_winter = [
                    b for b in breaks
                    if any(k in (b.get("name") or "").lower()
                           for k in ("summer", "winter"))
                ]
                if summer_winter:
                    summer_winter.sort(key=lambda b: _precision_rank(b.get("precision")))
                    b = summer_winter[0]
                    best = {
                        "kind": "school_break",
                        "label": b.get("name"),
                        "impact": "boost",
                        "precision": b.get("precision"),
                        "start_date": b.get("start_date"),
                        "end_date": b.get("end_date"),
                    }

            if best is not None:
                ctx[eid]["holiday"] = best
    except Exception:
        pass

    return ctx


@app.get("/api/broker/news")
def broker_news(
    limit: int = 20,
    league: str | None = None,
    team_ids: str | None = None,
    event_id: int | None = None,
    _=Depends(require_auth),
):
    """Recent ESPN news. Modes:
      - no filter         → global feed (home view).
      - league=NBA        → single league.
      - team_ids=20,18    → comma-separated espn_team_ids (event level page).
      - event_id=N        → resolves event_xref → home/away ESPN team_ids and
                            scopes news to those two teams + their league.
    """
    limit = max(1, min(int(limit), 100))
    db = require_sb()

    resolved_teams: list[str] = []
    resolved_league: str | None = league

    if event_id is not None and not team_ids:
        xref = (db.table("event_xref")
                  .select("espn_event_id, espn_league")
                  .eq("tevo_event_id", event_id).limit(1).execute().data or [])
        if xref:
            resolved_league = xref[0]["espn_league"]
            snap = (db.table("espn_event_snapshots")
                      .select("home_team_id, away_team_id")
                      .eq("espn_event_id", xref[0]["espn_event_id"])
                      .order("captured_at", desc=True).limit(1).execute().data or [])
            if snap:
                for k in ("home_team_id", "away_team_id"):
                    v = snap[0].get(k)
                    if v: resolved_teams.append(str(v))
    elif team_ids:
        resolved_teams = [t.strip() for t in team_ids.split(",") if t.strip()]

    q = (db.table("espn_news")
           .select("headline, description, url, published_at, type, espn_team_id, espn_league")
           .order("published_at", desc=True).limit(limit))
    if resolved_league:
        q = q.eq("espn_league", resolved_league)
    if resolved_teams:
        q = q.in_("espn_team_id", resolved_teams)
    rows = q.execute().data or []

    return {
        "count": len(rows),
        "items": rows,
        "filter": {"league": resolved_league, "team_ids": resolved_teams, "event_id": event_id},
    }


@app.get("/api/broker/performers/by-league/{league}")
def broker_performers_by_league(league: str, include_inactive: bool = False, _=Depends(require_auth)):
    """Per-team HOME/ROAD price metrics for ESPN-tracked teams in a league.
    Backed by the get_performers_by_league SQL RPC (mig 20260508050000).

    Returns: { league, count, performers: [
        { performer_id, performer_name, home_venue_id, home_venue_name,
          home: { events, market_med, owned_med, market_tix, owned_tix, first_event, last_event },
          road: { events, market_med, owned_med, market_tix, owned_tix, first_event, last_event } },
        ...
    ] }

    `include_inactive`: passthrough flag. The underlying SQL RPC currently
    aggregates over ALL events (including ghost playoff brackets where the
    team was eliminated). NEXT (code) — update get_performers_by_league
    to JOIN against event_lifecycle and exclude is_active=false rows when
    include_inactive=false. Until that lands, the response field
    `_inactive_filter_applied` reports false so the frontend can flag it.
    """
    db = require_sb()
    rows = db.rpc("get_performers_by_league", {"p_league": league}).execute().data or []

    def _delta_pct(cur, prev):
        if cur is None or prev is None: return None
        try:
            c = float(cur); p = float(prev)
        except (TypeError, ValueError):
            return None
        if p == 0: return None
        return round((c - p) / p * 100, 2)

    performers = [
        {
            "performer_id":    r.get("performer_id"),
            "performer_name":  r.get("performer_name"),
            "league":          r.get("league"),
            "home_venue_id":   r.get("home_venue_id"),
            "home_venue_name": r.get("home_venue_name"),
            "home": {
                "events":          r.get("home_events") or 0,
                "market_med":      r.get("home_market_med"),
                "owned_med":       r.get("home_owned_med"),
                "market_tix":      r.get("home_market_tix") or 0,
                "owned_tix":       r.get("home_owned_tix")  or 0,
                "first_event":     r.get("home_first_event"),
                "last_event":      r.get("home_last_event"),
                "prev_market_med": r.get("home_prev_market_med"),
                "prev_owned_med":  r.get("home_prev_owned_med"),
                "delta_market_pct": _delta_pct(r.get("home_market_med"), r.get("home_prev_market_med")),
                "delta_owned_pct":  _delta_pct(r.get("home_owned_med"),  r.get("home_prev_owned_med")),
            },
            "road": {
                "events":          r.get("road_events") or 0,
                "market_med":      r.get("road_market_med"),
                "owned_med":       r.get("road_owned_med"),
                "market_tix":      r.get("road_market_tix") or 0,
                "owned_tix":       r.get("road_owned_tix")  or 0,
                "first_event":     r.get("road_first_event"),
                "last_event":      r.get("road_last_event"),
                "prev_market_med": r.get("road_prev_market_med"),
                "prev_owned_med":  r.get("road_prev_owned_med"),
                "delta_market_pct": _delta_pct(r.get("road_market_med"), r.get("road_prev_market_med")),
                "delta_owned_pct":  _delta_pct(r.get("road_owned_med"),  r.get("road_prev_owned_med")),
            },
        }
        for r in rows
    ]
    return {
        "league": league,
        "count": len(performers),
        "performers": performers,
        "_inactive_filter_applied": False,  # see NEXT in docstring; tracked in KANBAN
        "_include_inactive_param": include_inactive,
    }


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


@app.get("/api/venues/{venue_id}")
def venue_detail(venue_id: int, _=Depends(require_auth)):
    return client.get_venue(venue_id)


@app.get("/api/configurations")
def configurations_list(venue_id: int | None = None, name: str | None = None, _=Depends(require_auth)):
    return client.list_configurations(venue_id=venue_id, name=name or None)


@app.get("/api/configurations/{config_id}")
def configuration_detail(config_id: int, _=Depends(require_auth)):
    return client.get_configuration(config_id)


@app.get("/api/watchlist")
def watchlist_list(_=Depends(require_auth)):
    db = require_sb()
    data = db.table("watchlist").select("*").order("added_at", desc=True).execute().data
    return {"items": data or []}


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


@app.get("/api/runs")
def runs_list(limit: int = 20, _=Depends(require_auth)):
    db = require_sb()
    data = db.table("runs").select("*").order("id", desc=True).limit(limit).execute().data
    return {"items": data or []}


@app.get("/api/snapshots/latest")
def snapshots_latest(_=Depends(require_auth)):
    db = require_sb()
    snaps = db.table("latest_snapshots").select("*").execute().data or []
    if not snaps:
        return {"items": []}
    ids = [s["event_id"] for s in snaps]
    events = db.table("events").select("*").in_("id", ids).execute().data or []
    by_id = {e["id"]: e for e in events}
    items = []
    for s in snaps:
        e = by_id.get(s["event_id"], {})
        items.append({
            **s,
            "event_name": e.get("name"),
            "occurs_at_local": e.get("occurs_at_local"),
            "venue_name": e.get("venue_name"),
            "venue_location": e.get("venue_location"),
            "primary_performer_name": e.get("primary_performer_name"),
        })
    items.sort(key=lambda x: x.get("occurs_at_local") or "")
    return {"items": items}


@app.get("/api/snapshots/velocity")
def snapshots_velocity(_=Depends(require_auth)):
    db = require_sb()
    data = db.table("event_velocity").select("*").order("occurs_at_local").execute().data or []
    return {"items": data}


def _fire_collect(url: str, secret: str) -> None:
    try:
        requests.post(
            url,
            headers={"X-Cron-Secret": secret, "Content-Type": "application/json"},
            json={},
            timeout=180,
        )
    except Exception as e:
        print(f"collect fire error: {e}")


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


def _listings_cadence_seconds(occurs_at_local: str | None) -> int:
    """Mirror collect-listings cron windows: closer events poll faster."""
    if not occurs_at_local:
        return 60 * 60 * 24
    try:
        # occurs_at_local is TEXT not TIMESTAMPTZ — known P1. Slice to date.
        d = datetime.fromisoformat(occurs_at_local[:10])
        days_out = (d - datetime.now()).days
    except Exception:
        return 60 * 60
    if days_out <= 1:
        return 60 * 20      # 20 min
    if days_out <= 7:
        return 60 * 60      # 60 min
    if days_out <= 30:
        return 60 * 60 * 4  # 4h
    if days_out <= 60:
        return 60 * 60 * 12 # 12h
    return 60 * 60 * 24     # 24h


def _delta(curr, prev):
    """Compute delta + percent for a numeric metric. Returns dict or None."""
    if curr is None or prev is None:
        return None
    try:
        c = float(curr); p = float(prev)
    except (TypeError, ValueError):
        return None
    if c == p:
        return {"abs": 0, "pct": 0, "dir": "flat"}
    diff = c - p
    pct = (diff / p * 100) if p != 0 else None
    return {"abs": round(diff, 2), "pct": round(pct, 2) if pct is not None else None,
            "dir": "up" if diff > 0 else "down"}


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


@app.get("/api/broker/event/{event_id}/section-metrics")
def broker_event_section_metrics(event_id: int, _=Depends(require_auth)):
    """Tab 1: section-level metrics with delta vs prior snapshot."""
    db = require_sb()
    rows = (
        db.table("section_metrics")
        .select("captured_at,section,is_ancillary,tickets_count,groups_count,"
                "retail_min,retail_median,retail_mean,retail_max")
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(2000)
        .execute()
    ).data or []
    # Group by section, take the latest two captured_at per section
    by_section: dict[str, list] = {}
    for r in rows:
        by_section.setdefault(r["section"], []).append(r)

    out = []
    last_pull = None
    for section, snaps in by_section.items():
        snaps.sort(key=lambda x: x["captured_at"], reverse=True)
        c = snaps[0]
        p = snaps[1] if len(snaps) >= 2 else {}
        if last_pull is None or c["captured_at"] > last_pull:
            last_pull = c["captured_at"]
        out.append({
            "section": section,
            "is_ancillary": bool(c.get("is_ancillary")),
            "metrics": {k: {"v": c.get(k), "delta": _delta(c.get(k), p.get(k))}
                        for k in ["tickets_count", "groups_count",
                                  "retail_min", "retail_median", "retail_mean", "retail_max"]},
        })
    out.sort(key=lambda s: (s["is_ancillary"], s["section"]))

    # Cadence matches event listings cadence
    ev_meta = (db.table("events").select("occurs_at_local").eq("id", event_id).limit(1).execute().data or [{}])[0]
    cadence = _listings_cadence_seconds(ev_meta.get("occurs_at_local"))
    return {"sections": out, "last_pull_at": last_pull, "cadence_seconds": cadence}


@app.get("/api/broker/event/{event_id}/raw-tevo")
def broker_event_raw_tevo(event_id: int, force: bool = False, _=Depends(require_auth)):
    """Tab 3: raw TEvo /v9/ticket_groups payload. Reads cowork's
    tevo_ticket_groups_cache (90s TTL); fetches fresh if expired or force=1."""
    db = require_sb()
    if not force:
        cached = db.rpc("get_cached_ticket_groups", {"p_event_id": event_id}).execute().data
        if cached:
            return {"source": "cache", "groups": (cached or {}).get("ticket_groups", []),
                    "captured_at": (cached or {}).get("captured_at")}
    # Cache miss / forced refresh — fetch live
    try:
        live = client.get_ticket_groups(event_id)
    except RuntimeError as e:
        raise HTTPException(502, f"TEvo fetch failed: {e}")
    payload = {"ticket_groups": live.get("ticket_groups", []), "captured_at": datetime.now(timezone.utc).isoformat()}
    try:
        db.rpc("put_cached_ticket_groups", {"p_event_id": event_id, "p_payload": payload, "p_ttl_seconds": 90}).execute()
    except Exception:
        pass
    return {"source": "live", "groups": payload["ticket_groups"], "captured_at": payload["captured_at"]}


@app.get("/api/broker/watchlist-movers")
def broker_watchlist_movers(
    window_hours: int = 24,
    sort: str = "value",       # "value" → Δ market_val, "pct" → Δ market_pct
    limit: int = 25,
    _=Depends(require_auth),
):
    """Watchlisted events ordered by movement. Backs the WATCHLIST panel
    on the Events tab. Same row shape as /api/broker/movers events list,
    so the front-end can render it with shared code.

    Pulls get_event_movers for the window, filters to events present in
    watch_sources, then sorts by either notional Δ value or Δ %.
    """
    window_hours = max(1, min(int(window_hours), 168))
    db = require_sb()

    # 1. Watchlisted event_ids
    watch = (db.table("watch_sources").select("event_id").execute().data or [])
    watch_ids = {int(r["event_id"]) for r in watch if r.get("event_id") is not None}
    if not watch_ids:
        return {"window_hours": window_hours, "sort": sort, "count": 0, "events": []}

    # 2. Latest+prior aggregation via the existing RPC
    rpc_rows = db.rpc("get_event_movers", {"p_window_hours": window_hours}).execute().data or []

    def pct_delta(cur, prev):
        if cur is None or prev is None: return None
        try: c = float(cur); p = float(prev)
        except (TypeError, ValueError): return None
        if p == 0: return None
        return round((c - p) / p * 100, 2)
    def val(price, tix):
        if price is None or tix is None: return None
        try: return float(price) * float(tix)
        except (TypeError, ValueError): return None

    rows = []
    for r in rpc_rows:
        if int(r.get("event_id") or 0) not in watch_ids:
            continue
        cur_market_val  = val(r.get("cur_market_med"),  r.get("cur_market_tix"))
        prev_market_val = val(r.get("prev_market_med"), r.get("prev_market_tix"))
        cur_owned_val   = val(r.get("cur_owned_med"),   r.get("cur_owned_tix"))
        prev_owned_val  = val(r.get("prev_owned_med"),  r.get("prev_owned_tix"))
        rows.append({
            "event_id": r.get("event_id"),
            "name": r.get("name"),
            "venue_id": r.get("venue_id"),
            "venue_name": r.get("venue_name"),
            "occurs_at_local": r.get("occurs_at_local"),
            "latest_at":      r.get("latest_at"),
            "cur_market_med": r.get("cur_market_med"),
            "cur_market_tix": r.get("cur_market_tix"),
            "cur_owned_med":  r.get("cur_owned_med"),
            "cur_owned_tix":  r.get("cur_owned_tix"),
            "cur_owned_share": r.get("cur_owned_share"),  # v3: for "we ARE the market" badge
            "delta_market_pct": pct_delta(r.get("cur_market_med"), r.get("prev_market_med")),
            "delta_owned_pct":  pct_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
            "cur_market_val":  round(cur_market_val,  2) if cur_market_val  is not None else None,
            "cur_owned_val":   round(cur_owned_val,   2) if cur_owned_val   is not None else None,
            "delta_market_val": (None if cur_market_val is None or prev_market_val is None
                                 else round(cur_market_val - prev_market_val, 2)),
            "delta_owned_val":  (None if cur_owned_val is None or prev_owned_val is None
                                 else round(cur_owned_val - prev_owned_val, 2)),
        })

    # Sort: events with no movement signal sink to the bottom
    sort_key = "delta_market_val" if sort == "value" else "delta_market_pct"
    rows_with = [r for r in rows if r.get(sort_key) is not None]
    rows_with.sort(key=lambda r: abs(r[sort_key]), reverse=True)
    rows_without = [r for r in rows if r.get(sort_key) is None]
    out = (rows_with + rows_without)[: max(1, min(int(limit), 100))]

    return {"window_hours": window_hours, "sort": sort, "count": len(out), "events": out}


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

def _venue_tokens(name: str) -> set[str]:
    """Crude venue-name token bag for fuzzy match. Strips 'Parking' suffix
    so 'Citi Field Parking' matches 'Citi Field'."""
    if not name:
        return set()
    n = name.lower().replace(" parking", "").replace("parking", "")
    return {tok for tok in re.split(r"[^a-z0-9]+", n) if len(tok) >= 3}


def _venue_overlap(a: str, b: str) -> float:
    """Jaccard overlap between two venue names. 1.0 = identical, 0 = nothing
    in common. ~0.5 typically indicates a real match (e.g. 'Daikin Park'
    vs 'Daikin Park Houston')."""
    ta, tb = _venue_tokens(a), _venue_tokens(b)
    if not ta or not tb:
        return 0.0
    inter = ta & tb
    union = ta | tb
    return len(inter) / len(union) if union else 0.0


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
        print(f"events upsert failed for {eid}: {e}")
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


@app.get("/api/broker/event/{event_id}/espn")
def broker_event_espn(event_id: int, _=Depends(require_auth)):
    """Tab 2: ESPN aggregated data for home + away teams.
    Calls the espn edge fn server-side to keep the JWT off the wire."""
    if not (SUPABASE_URL and SUPABASE_ANON_KEY):
        raise HTTPException(500, "espn fn not reachable: missing SUPABASE_URL/SUPABASE_ANON_KEY")
    url = f"{SUPABASE_URL}/functions/v1/espn/event/{int(event_id)}"
    try:
        r = requests.get(url, headers={"Authorization": f"Bearer {SUPABASE_ANON_KEY}"}, timeout=15)
        return r.json() if r.ok else {"applicable": False, "error": f"espn fn {r.status_code}"}
    except Exception as e:
        return {"applicable": False, "error": str(e)}


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
            .order("captured_at", desc=True).limit(5)
            .execute()
        ).data or []
        out = []
        for r in rows:
            h, a = r.get("home_score"), r.get("away_score")
            if h is None or a is None:
                continue
            is_home = r.get("home_team_id") == team_id
            won = (is_home and h > a) or (not is_home and a > h)
            out.append({"t": r["captured_at"], "result": "W" if won else "L",
                        "score": f"{h}-{a}", "home": is_home})
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

    home_index, home_weights = _team_index_series(home_standings_rows, home_news, home_injury_load, home_team_id)
    away_index, away_weights = _team_index_series(away_standings_rows, away_news, away_injury_load, away_team_id)

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


@app.get("/api/broker/event/{event_id}/cadences")
def broker_event_cadences(event_id: int, _=Depends(require_auth)):
    """Per-section poll cadence for the page. Each section reads its own
    last_pull_at + cadence_seconds; next poll = last + cadence + jitter."""
    db = require_sb()
    ev = (db.table("events").select("id,occurs_at_local").eq("id", event_id).limit(1).execute().data or [{}])[0]
    listings_cad = _listings_cadence_seconds(ev.get("occurs_at_local"))
    # last_pull_at for listings = most recent event_metrics row
    last_listings = (
        db.table("event_metrics").select("captured_at")
        .eq("event_id", event_id).order("captured_at", desc=True).limit(1)
        .execute()
    ).data or []
    last_listings_at = last_listings[0]["captured_at"] if last_listings else None

    # ESPN injuries cadence = 10 min (espn-roster-10min cron)
    last_inj = (
        db.table("espn_injuries_snapshots").select("last_seen_at")
        .order("last_seen_at", desc=True).limit(1).execute()
    ).data or []
    last_inj_at = last_inj[0]["last_seen_at"] if last_inj else None

    # ESPN team standings cadence = daily; ESPN scores/odds for events ±24h = 10 min
    last_team_snap = (
        db.table("espn_team_snapshots").select("last_seen_at")
        .order("last_seen_at", desc=True).limit(1).execute()
    ).data or []
    last_team_at = last_team_snap[0]["last_seen_at"] if last_team_snap else None

    return {
        "event_id": event_id,
        "sections": {
            "overview":        {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
            "section_metrics": {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
            "raw_tevo":        {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
            "espn_injuries":   {"last_pull_at": last_inj_at,      "cadence_seconds": 60 * 10},
            "espn_team":       {"last_pull_at": last_team_at,     "cadence_seconds": 60 * 60 * 24},
        },
    }


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


@app.get("/api/seatdata/account")
def seatdata_account(_=Depends(require_auth)):
    """Diagnostic: SeatData account identity, plans, server-side rate-limit catalog."""
    client = _get_seatdata_client()
    if not client:
        raise HTTPException(503, "SEATDATA_API_KEY not set on this Railway env")
    return client.account()


@app.get("/api/seatdata/usage")
def seatdata_usage(_=Depends(require_auth)):
    """Diagnostic: SeatData billing-period usage totals (server-reported)."""
    client = _get_seatdata_client()
    if not client:
        raise HTTPException(503, "SEATDATA_API_KEY not set on this Railway env")
    return client.usage()


@app.get("/api/seatdata/budget")
def seatdata_budget(_=Depends(require_auth)):
    """Our DB-tracked pull budget (independent of SeatData's internal counters).
    Hard-capped at 100/day, 2000/month per migration 20260509060000.
    Returns: {allowed, used, daily_cap, monthly_used, monthly_cap, reason}.
    """
    db = require_sb()
    res = db.rpc("seatdata_check_budget", {"p_endpoint": "paid"}).execute()
    return res.data or {}


@app.get("/api/seatdata/event/{event_id}")
def seatdata_event(event_id: int, _=Depends(require_auth)):
    """Read SeatData state for a TEvo event_id (xref + persisted snapshots).
    Free — no SeatData API calls. Returns null fields if not yet linked/pulled."""
    db = require_sb()
    xref = (
        db.table("seatdata_event_xref").select("*")
        .eq("tevo_event_id", event_id).limit(1).execute()
    ).data or []
    if not xref:
        return {"tevo_event_id": event_id, "linked": False, "xref": None,
                "sales_count": 0, "stats_count": 0, "latest_stats": None}
    sales_n = (
        db.table("seatdata_sales_snapshots").select("id", count="exact")
        .eq("tevo_event_id", event_id).limit(1).execute()
    )
    stats_n = (
        db.table("seatdata_event_stats").select("id", count="exact")
        .eq("tevo_event_id", event_id).limit(1).execute()
    )
    latest = (
        db.table("seatdata_event_latest").select("*")
        .eq("tevo_event_id", event_id).limit(1).execute()
    ).data or []
    return {
        "tevo_event_id": event_id,
        "linked": True,
        "xref": xref[0],
        "sales_count": getattr(sales_n, "count", None) or 0,
        "stats_count": getattr(stats_n, "count", None) or 0,
        "latest_stats": latest[0] if latest else None,
    }


@app.get("/api/seatdata/event/{event_id}/sales")
def seatdata_event_sales(event_id: int, limit: int = 500, _=Depends(require_auth)):
    """Read persisted sales rows for an event. Free — no SeatData API call.
    Sorted by sale_timestamp DESC (most recent first)."""
    limit = max(1, min(int(limit), 5000))
    db = require_sb()
    rows = (
        db.table("seatdata_sales_snapshots")
        .select("sale_timestamp,quantity,price,zone,section,row")
        .eq("tevo_event_id", event_id)
        .order("sale_timestamp", desc=True)
        .limit(limit).execute()
    ).data or []
    if not rows:
        return {"event_id": event_id, "count": 0, "sales": [],
                "summary": {"avg": None, "median": None, "min": None, "max": None,
                            "tickets_total": 0, "zones": [], "first_sale": None, "last_sale": None}}
    prices = sorted(r["price"] for r in rows if r.get("price") is not None)
    n = len(prices)
    median = prices[n // 2] if n % 2 == 1 else (prices[n // 2 - 1] + prices[n // 2]) / 2 if n else None
    return {
        "event_id": event_id,
        "count": len(rows),
        "sales": rows,
        "summary": {
            "avg":    round(sum(prices) / n, 2) if n else None,
            "median": round(median, 2) if median is not None else None,
            "min":    min(prices) if prices else None,
            "max":    max(prices) if prices else None,
            "tickets_total": sum(max(int(r.get("quantity") or 1), 1) for r in rows),
            "zones":  sorted({r.get("zone") for r in rows if r.get("zone")}),
            "first_sale": rows[-1]["sale_timestamp"],
            "last_sale":  rows[0]["sale_timestamp"],
        },
    }


@app.get("/api/axs/event/{event_id}")
def axs_event(event_id: int, _=Depends(require_auth)):
    """AXS box-office state for a TEvo event_id (latest persisted snapshot).
    Free — reads axs_event_snapshots; no AXS API call. Null fields if not yet
    AQ-linked / pulled. is_axs_primary reflects the /fetch probe classifier."""
    db = require_sb()
    snap = (
        db.table("axs_event_snapshots")
        .select("id,captured_at,axs_event_id,event_url,event_name,venue_name,"
                "occurs_at_local,currency,price_min,price_max,getin,listings_count,"
                "sections_count,offers_count,seats_primary,seats_resale,onsale_now,"
                "in_axs_list,response_s")
        .eq("tevo_event_id", event_id)
        .order("captured_at", desc=True).limit(1).execute()
    ).data or []
    if not snap:
        return {"tevo_event_id": event_id, "linked": False, "latest": None,
                "captured_at": None}
    return {"tevo_event_id": event_id, "linked": True, "latest": snap[0],
            "captured_at": snap[0]["captured_at"]}


@app.get("/api/axs/event/{event_id}/sections")
def axs_event_sections(event_id: int, limit: int = 1000, _=Depends(require_auth)):
    """Per-section availability + pricing from the latest AXS snapshot. Free —
    no AXS API call. Sorted cheapest-first. Mirrors the SeatData sales shape."""
    limit = max(1, min(int(limit), 5000))
    db = require_sb()
    snap = (
        db.table("axs_event_snapshots")
        .select("id,captured_at,event_name,venue_name,currency,price_min,price_max,getin")
        .eq("tevo_event_id", event_id)
        .order("captured_at", desc=True).limit(1).execute()
    ).data or []
    if not snap:
        return {"event_id": event_id, "count": 0, "sections": [], "summary": None,
                "captured_at": None}
    s0 = snap[0]
    rows = (
        db.table("axs_section_snapshots")
        .select("section_label,neighborhood,is_ga,sold_out,avail_qty,price_min,"
                "price_max,seat_types,has_resale,connection_fee")
        .eq("snapshot_id", s0["id"])
        .order("price_min", desc=False).limit(limit).execute()
    ).data or []
    prices = sorted(r["price_min"] for r in rows if r.get("price_min") is not None)
    return {
        "event_id": event_id,
        "count": len(rows),
        "captured_at": s0["captured_at"],
        "event_name": s0.get("event_name"),
        "venue_name": s0.get("venue_name"),
        "currency": s0.get("currency"),
        "sections": rows,
        "summary": {
            "total_sections": len(rows),
            "available_qty": sum(int(r.get("avail_qty") or 0) for r in rows),
            "resale_sections": sum(1 for r in rows if r.get("has_resale")),
            "sold_out_sections": sum(1 for r in rows if r.get("sold_out")),
            "min_price": prices[0] if prices else s0.get("getin"),
            "max_price": prices[-1] if prices else s0.get("price_max"),
        },
    }


@app.get("/api/axs/event/{event_id}/listings")
def axs_event_listings(event_id: int, limit: int = 3000, _=Depends(require_auth)):
    """AXS box-office inventory in the EVO listing standard (consecutive-seat
    blocks), latest snapshot. Free — reads v_axs_listings. Each row is a block:
    section/row/quantity/retail_price/type/format/splits/wheelchair + AXS-only
    seat_numbers (TEvo ticket groups don't carry exact seats)."""
    limit = max(1, min(int(limit), 10000))
    db = require_sb()
    snap = (
        db.table("axs_event_snapshots").select("id,captured_at,event_name,venue_name")
        .eq("tevo_event_id", event_id).order("captured_at", desc=True).limit(1).execute()
    ).data or []
    if not snap:
        return {"event_id": event_id, "count": 0, "listings": [], "summary": None,
                "captured_at": None}
    s0 = snap[0]
    rows = (
        db.table("v_axs_listings")
        .select("section,row,quantity,retail_price,type,format,wheelchair,seat_numbers,"
                "src,neighborhood,is_ga,seat_from,seat_to")
        .eq("snapshot_id", s0["id"])
        .order("section").order("row").order("seat_from")
        .limit(limit).execute()
    ).data or []
    prices = [r["retail_price"] for r in rows if r.get("retail_price") is not None]
    return {
        "event_id": event_id,
        "captured_at": s0["captured_at"],
        "event_name": s0.get("event_name"),
        "venue_name": s0.get("venue_name"),
        "count": len(rows),
        "listings": rows,
        "summary": {
            "blocks": len(rows),
            "total_seats": sum(int(r.get("quantity") or 0) for r in rows),
            "min_price": min(prices) if prices else None,
            "max_price": max(prices) if prices else None,
            "biggest_block": max((int(r.get("quantity") or 0) for r in rows), default=0),
            "resale_blocks": sum(1 for r in rows if r.get("src") == "resale"),
        },
    }


@app.get("/api/axs/event/{event_id}/series")
def axs_event_series(event_id: int, range: str | None = None, hours: int | None = None,
                     days: int = 30, _=Depends(require_auth)):
    """AXS box-office time series for the event charts: median section price +
    listing count per snapshot. Free — reads axs_event_snapshots via RPC.
    Shape mirrors chart-data's {t,v} series so the FE merges it straight in."""
    rmap = {"6h": 6, "24h": 24, "1d": 24, "3d": 72, "7d": 168, "30d": 720, "all": None}
    if range is not None:
        range_hours = rmap.get(range.lower(), 720)
    elif hours is not None:
        range_hours = max(6, min(int(hours), 8760))
    else:
        range_hours = max(1, min(int(days), 365)) * 24
    since_iso = ("1970-01-01T00:00:00+00:00" if range_hours is None
                 else (datetime.now(timezone.utc) - timedelta(hours=range_hours)).isoformat())
    db = require_sb()
    try:
        rows = (db.rpc("get_axs_event_price_series",
                       {"p_event_id": event_id, "p_since": since_iso}).execute()).data or []
    except Exception:
        rows = []
    return {
        "event_id": event_id,
        "prices_axs": [{"t": r["captured_at"], "v": r.get("median_price")} for r in rows],
        "counts_axs": [{"t": r["captured_at"], "v": r.get("listings_count")} for r in rows],
    }


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


def _require_cron_or_auth(authorization: str | None, x_cron_secret: str | None):
    """Allow either authenticated user OR matching X-Cron-Secret.

    Fails closed if CRON_SECRET is not configured on the server — never
    accepts an empty/placeholder secret.
    """
    if x_cron_secret and CRON_SECRET and hmac.compare_digest(x_cron_secret, CRON_SECRET):
        return {"cron": True}
    return require_auth(authorization)


def _parse_iso_or_none(s):
    if not s:
        return None
    try:
        # TEvo emits 'Z' suffix; Python 3.11+ fromisoformat handles it
        return s.replace("Z", "+00:00") if isinstance(s, str) and s.endswith("Z") else s
    except Exception:
        return None


def _to_int_or_none(v):
    if v is None or v == "":
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _to_num_or_none(v):
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


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


def _flatten_order_items(order: dict) -> list[dict]:
    """Project order.items[] into evo_order_items schema, mapping event_id."""
    out = []
    for it in (order.get("items") or []):
        tg = it.get("ticket_group") or {}
        ev = tg.get("event") or {}
        venue = ev.get("venue") or {}
        out.append({
            "evo_order_id":              _to_int_or_none(order.get("id")),
            "evo_item_id":               _to_int_or_none(it.get("id")),
            "quantity":                  _to_int_or_none(it.get("quantity")),
            "price":                     _to_num_or_none(it.get("price")),
            "ticket_group_id":           _to_int_or_none(tg.get("id")),
            "ticket_group_remote_id":    tg.get("remote_id"),
            "ticket_group_office_id":    _to_int_or_none(tg.get("office_id")),
            "ticket_group_section":      tg.get("section"),
            "ticket_group_row":          tg.get("row"),
            "ticket_group_seats":        tg.get("seats") or [],
            "ticket_group_quantity":     _to_int_or_none(tg.get("quantity")),
            "ticket_group_retail_price": _to_num_or_none(tg.get("retail_price")),
            "ticket_group_wholesale_price": _to_num_or_none(tg.get("wholesale_price")),
            "ticket_group_external_notes": tg.get("external_notes"),
            "event_id":                  _to_int_or_none(ev.get("id")),
            "event_name":                ev.get("name"),
            "occurs_at":                 _parse_iso_or_none(ev.get("occurs_at")),
            "venue_id":                  _to_int_or_none(venue.get("id")),
            "venue_name":                venue.get("name"),
            "eticket_available":         it.get("eticket_available"),
            "eticket_delivery":          it.get("eticket_delivery"),
            "eticket_downloaded_at":     _parse_iso_or_none(it.get("eticket_downloaded_at")) or None,
            "eticket_downloaded_by":     _to_int_or_none(it.get("eticket_downloaded_by")),
            "raw":                       it,
        })
    return out


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


@app.get("/api/broker/event/{event_id}/orders")
def broker_event_orders(event_id: int, _=Depends(require_auth)):
    """Read persisted evo_orders + items for an event. Free, no TEvo call.
    Used by the event-detail page to show pending/accepted/rejected/completed
    counts + the actual order rows.
    """
    db = require_sb()
    items = (
        db.table("evo_order_items")
        .select("evo_order_id,evo_item_id,quantity,price,"
                "ticket_group_id,ticket_group_section,ticket_group_row,ticket_group_seats,"
                "eticket_available,eticket_downloaded_at,occurs_at")
        .eq("event_id", event_id).execute()
    ).data or []
    if not items:
        return {"event_id": event_id, "items": [], "orders": [], "summary": None}
    order_ids = list({i["evo_order_id"] for i in items if i.get("evo_order_id")})
    orders = (
        db.table("evo_orders")
        .select("evo_order_id,state,type,fraud_check_status,total,subtotal,refunded,balance,"
                "buyer_name,seller_name,client_name,evo_created_at,evo_updated_at")
        .in_("evo_order_id", order_ids).execute()
    ).data or []
    state_map = {o["evo_order_id"]: o for o in orders}
    # Summary roll-up
    by_state: dict[str, int] = {}
    tickets_sold = 0
    gross_sold = 0.0
    for it in items:
        oid = it.get("evo_order_id")
        st = (state_map.get(oid) or {}).get("state") or "unknown"
        by_state[st] = by_state.get(st, 0) + 1
        if st in ("accepted", "completed") and it.get("quantity") and it.get("price"):
            tickets_sold += int(it["quantity"])
            gross_sold += float(it["price"]) * int(it["quantity"])
    return {
        "event_id": event_id,
        "items": items,
        "orders": orders,
        "summary": {
            "total_items":     len(items),
            "by_state":        by_state,
            "tickets_sold":    tickets_sold,
            "gross_sold":      round(gross_sold, 2),
            "last_update_at":  max((o.get("evo_updated_at") for o in orders if o.get("evo_updated_at")), default=None),
        },
    }


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


@app.get("/api/seatgeek/event/{event_id}")
def seatgeek_event(event_id: int, _=Depends(require_auth)):
    """Read SeatGeek state for a TEvo event_id (xref + latest snapshot rollup).
    Free — no SG API call. Returns null fields if not yet linked."""
    db = require_sb()
    rows = (db.table("seatgeek_event_latest").select("*")
            .eq("tevo_event_id", event_id).limit(1).execute()).data or []
    if not rows:
        return {"tevo_event_id": event_id, "linked": False}
    return {"tevo_event_id": event_id, "linked": True, **rows[0]}


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


@app.get("/api/seatgeek/event/{event_id}/listings")
def seatgeek_event_listings(event_id: int, latest_only: bool = True, limit: int = 1000,
                            _=Depends(require_auth)):
    """Read persisted SG listings. latest_only=true returns only the most
    recent snapshot per sglid; false returns the full history."""
    db = require_sb()
    if latest_only:
        # latest snapshot per event = MAX(captured_at) for that tevo_event_id
        last = (db.table("seatgeek_listings_snapshots")
                .select("captured_at").eq("tevo_event_id", event_id)
                .order("captured_at", desc=True).limit(1).execute()).data or []
        if not last:
            return {"event_id": event_id, "listings": [], "summary": None}
        rows = (db.table("seatgeek_listings_snapshots")
                .select("sglid,section,row,quantity,retail_price_all_in,broadcast_price,"
                        "deal_quality_score,is_broker_owned,is_b2b,is_instant_download,"
                        "is_sro,has_limited_view,delivery_method,in_hand_date,"
                        "market_source,stock_type,splits,captured_at")
                .eq("tevo_event_id", event_id)
                .eq("captured_at", last[0]["captured_at"])
                .limit(int(limit)).execute()).data or []
    else:
        rows = (db.table("seatgeek_listings_snapshots")
                .select("*")
                .eq("tevo_event_id", event_id)
                .order("captured_at", desc=True)
                .limit(int(limit)).execute()).data or []
    if not rows:
        return {"event_id": event_id, "listings": [], "summary": None}
    # Quick rollup
    prices = sorted([r["retail_price_all_in"] for r in rows if r.get("retail_price_all_in") is not None])
    n = len(prices)
    median = prices[n // 2] if n and n % 2 else (prices[n // 2 - 1] + prices[n // 2]) / 2 if n else None
    return {
        "event_id": event_id, "listings": rows,
        "summary": {
            "total_listings": len({r.get("sglid") for r in rows if r.get("sglid")}),
            "total_tickets": sum(int(r.get("quantity") or 0) for r in rows),
            "broker_owned":  sum(1 for r in rows if r.get("is_broker_owned")),
            "b2b_sourced":   sum(1 for r in rows if r.get("is_b2b")),
            "median_retail_all_in": round(median, 2) if median is not None else None,
            "min_retail_all_in":    min(prices) if prices else None,
            "max_retail_all_in":    max(prices) if prices else None,
            "captured_at": rows[0].get("captured_at"),
        },
    }


@app.get("/api/seatgeek/event/{event_id}/sales")
def seatgeek_event_sales(event_id: int, limit: int = 1000, _=Depends(require_auth)):
    """Read persisted SG sales. Sorted newest first."""
    db = require_sb()
    rows = (db.table("seatgeek_sales_snapshots")
            .select("sg_sale_id,broadcast_price,quantity,section,row,stock_type,"
                    "delivery_method,in_hand_date,is_instant,sale_at_utc")
            .eq("tevo_event_id", event_id)
            .order("sale_at_utc", desc=True)
            .limit(int(limit)).execute()).data or []
    if not rows:
        return {"event_id": event_id, "sales": [], "summary": None}
    bps = sorted([r["broadcast_price"] for r in rows if r.get("broadcast_price") is not None])
    n = len(bps)
    median_bp = bps[n // 2] if n and n % 2 else (bps[n // 2 - 1] + bps[n // 2]) / 2 if n else None
    return {
        "event_id": event_id, "sales": rows,
        "summary": {
            "total_sales": len(rows),
            "total_tickets_sold": sum(int(r.get("quantity") or 0) for r in rows),
            "median_broadcast_price": round(median_bp, 2) if median_bp is not None else None,
            "min_broadcast_price":    min(bps) if bps else None,
            "max_broadcast_price":    max(bps) if bps else None,
            "first_sale": rows[-1].get("sale_at_utc"),
            "last_sale":  rows[0].get("sale_at_utc"),
        },
    }


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


@app.get("/api/seatgeek/event/{event_id}/seller-listings")
def seatgeek_seller_listings_for_event(event_id: int, latest_only: bool = True,
                                       limit: int = 1000, _=Depends(require_auth)):
    """Read persisted seller-direct listings for a TEvo event."""
    db = require_sb()
    if latest_only:
        last = (db.table("seatgeek_seller_listings")
                .select("pulled_at").eq("tevo_event_id", event_id)
                .order("pulled_at", desc=True).limit(1).execute()).data or []
        if not last:
            return {"event_id": event_id, "listings": [], "summary": None}
        rows = (db.table("seatgeek_seller_listings")
                .select("sg_listing_id,seller_listing_id,sg_event_id,sg_event_name,"
                        "sg_venue,sg_event_date,sg_event_time,quantity,section,row,"
                        "cost,is_edelivery,is_instant,in_hand_date,notes,pulled_at")
                .eq("tevo_event_id", event_id)
                .eq("pulled_at", last[0]["pulled_at"])
                .limit(int(limit)).execute()).data or []
    else:
        rows = (db.table("seatgeek_seller_listings").select("*")
                .eq("tevo_event_id", event_id)
                .order("pulled_at", desc=True)
                .limit(int(limit)).execute()).data or []
    if not rows:
        return {"event_id": event_id, "listings": [], "summary": None}
    return {
        "event_id": event_id, "listings": rows,
        "summary": {
            "total_listings": len({r.get("sg_listing_id") for r in rows if r.get("sg_listing_id")}),
            "total_tickets": sum(int(r.get("quantity") or 0) for r in rows),
            "median_cost": (sorted([r["cost"] for r in rows if r.get("cost") is not None])[len(rows) // 2]
                            if any(r.get("cost") is not None for r in rows) else None),
            "captured_at": rows[0].get("pulled_at"),
        },
    }


@app.get("/api/seatgeek/event/{event_id}/seller-orders")
def seatgeek_seller_orders_for_event(event_id: int, _=Depends(require_auth)):
    """Read persisted seller-direct orders for a TEvo event."""
    db = require_sb()
    rows = (db.table("seatgeek_orders")
            .select("sg_order_id,status,created_at_sg,sale_price,sale_quantity,"
                    "sale_section,sale_row,sg_event_name,sg_venue,sg_event_date,"
                    "delivery_method,stock_type,fulfillment_issue_message,"
                    "payment_total,last_status_at")
            .eq("tevo_event_id", event_id)
            .order("created_at_sg", desc=True).execute()).data or []
    if not rows:
        return {"event_id": event_id, "orders": [], "summary": None}
    by_status: dict[str, int] = {}
    tickets_sold = 0
    gross = 0.0
    for r in rows:
        st = r.get("status") or "unknown"
        by_status[st] = by_status.get(st, 0) + 1
        if st in ("confirmed", "fulfilled", "delivered"):
            q = int(r.get("sale_quantity") or 0)
            p = float(r.get("sale_price") or 0)
            tickets_sold += q
            gross += p * q
    return {
        "event_id": event_id, "orders": rows,
        "summary": {
            "total_orders": len(rows),
            "by_status": by_status,
            "tickets_sold": tickets_sold,
            "gross_sold":   round(gross, 2),
            "last_order_at": rows[0].get("last_status_at") if rows else None,
        },
    }


@app.get("/api/seatgeek/seller-status")
def seatgeek_seller_status(_=Depends(require_auth)):
    """Diagnostic: how many SG events have we seen, how many auto-linked
    to TEvo, what's the latest pull?"""
    db = require_sb()
    pull_log = (db.table("seatgeek_seller_pull_log").select("*")
                .order("called_at", desc=True).limit(20).execute()).data or []
    listing_stats = (db.table("seatgeek_seller_listings")
                     .select("sg_event_id,tevo_event_id,pulled_at")
                     .order("pulled_at", desc=True).limit(2000).execute()).data or []
    distinct_sg = len({r["sg_event_id"] for r in listing_stats if r.get("sg_event_id")})
    linked_sg = len({r["sg_event_id"] for r in listing_stats
                     if r.get("sg_event_id") and r.get("tevo_event_id")})
    order_count_q = (db.table("seatgeek_orders").select("id", count="exact").limit(1).execute())
    return {
        "recent_pulls": pull_log[:10],
        "distinct_sg_events_in_listings": distinct_sg,
        "auto_linked_to_tevo": linked_sg,
        "auto_link_rate": (linked_sg / distinct_sg) if distinct_sg else None,
        "total_orders_persisted": getattr(order_count_q, "count", None) or 0,
        "last_listings_pulled_at": listing_stats[0]["pulled_at"] if listing_stats else None,
    }


@app.get("/api/cross-source/event/{event_id}")
def cross_source_event(event_id: int, _=Depends(require_auth)):
    """One-stop view of all 3 external xrefs for a TEvo event.
    Returns ESPN + SeatGeek + SeatData ids together so frontend doesn't
    need 3 separate calls. Free."""
    db = require_sb()
    ev = (db.table("events")
          .select("id,name,occurs_at_local,venue_id,venue_name,primary_performer_id,primary_performer_name,event_type")
          .eq("id", event_id).limit(1).execute()).data or []
    if not ev:
        raise HTTPException(404, f"event {event_id} not found")
    espn = (db.table("event_xref").select("espn_event_id,espn_league,espn_slug,match_method,matched_at")
            .eq("tevo_event_id", event_id).limit(1).execute()).data or []
    sg = (db.table("seatgeek_event_xref").select("sg_event_id,sg_event_name,sg_event_type,sg_event_location,match_method,matched_at,last_listings_at,last_sales_at")
          .eq("tevo_event_id", event_id).limit(1).execute()).data or []
    sd = (db.table("seatdata_event_xref").select("sd_event_id,match_method,matched_at,last_paid_pull_at")
          .eq("tevo_event_id", event_id).limit(1).execute()).data or []
    return {
        "tevo_event": ev[0],
        "espn":     espn[0] if espn else None,
        "seatgeek": sg[0]   if sg   else None,
        "seatdata": sd[0]   if sd   else None,
        "matched_count": sum(1 for x in (espn, sg, sd) if x),
    }


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

def _ticket_group_to_listing(tg: dict) -> dict:
    """Reduce a TEvo ticket_group payload to the public-safe fields a buyer
    needs. Strips wholesale price, signature, office/brokerage attribution."""
    return {
        "id": tg.get("id"),
        "section": tg.get("section"),
        "row": tg.get("row"),
        "available_quantity": tg.get("available_quantity") or tg.get("quantity"),
        "splits": tg.get("splits") or [],
        "retail_price": tg.get("retail_price"),
        "format": tg.get("format"),
        "type": tg.get("type") or "event",
        "in_hand": tg.get("in_hand"),
        "in_hand_on": tg.get("in_hand_on"),
        "instant_delivery": tg.get("instant_delivery"),
        "public_notes": tg.get("public_notes"),
        "view_type": tg.get("view_type"),
        "wheelchair": tg.get("wheelchair"),
    }


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
        print(f"[store_events] TEvo events fetch failed: {e!r}")
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
                perf_ids.add(int(pid))
    perf_assets: dict[int, dict] = {}
    if perf_ids:
        try:
            db = require_sb()
            perf_assets = _bulk_performer_assets(db, list(perf_ids))
        except Exception as e:
            # Don't break the catalog if performer_metadata is unavailable;
            # cards just render without logos/colors.
            print(f"performer_metadata bulk-fetch failed: {e}")
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


def _haversine_miles(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in miles between two (lat,lon) pairs."""
    R_MI = 3958.7613  # Earth's mean radius in miles
    lat1r, lat2r = math.radians(lat1), math.radians(lat2)
    dlat = lat2r - lat1r
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1r) * math.cos(lat2r) * math.sin(dlon / 2) ** 2
    return 2 * R_MI * math.asin(math.sqrt(a))


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


def _movers_cache_key(city: str, days: int, limit: int) -> str:
    """Canonical cache key — case-folds city so 'nyc'/'NYC'/'New York' map
    to a single slot. The endpoint already maps 'NEW YORK' + 'NEW YORK CITY'
    aliases through the same venue_patterns, so the cache key uppercase
    matches that intent."""
    return f"{(city or '').upper()}|{int(days)}|{int(limit)}"


def _normalize_search_key(q: str) -> str:
    """Normalize a user query for cache slot identity. Collapses runs of
    whitespace + lowercases + strips, so "  Knicks  ", "knicks", "KNICKS"
    all collapse to the same slot. Mode (sql vs live) is appended at the
    callsite so the cache stays correct across STOREFRONT_SQL_ONLY flips."""
    return re.sub(r"\s+", " ", (q or "").strip().lower())


# PostgREST ILIKE pattern wildcards we need to escape so a user-supplied
# query like "%" doesn't become a match-everything pattern. Backslash
# escaped FIRST so we don't double-escape our own escapes.
_ILIKE_WILDCARDS = ("\\", "%", "_")


def _escape_ilike(s: str) -> str:
    """Escape PostgREST ILIKE wildcards in a user-supplied substring."""
    for ch in _ILIKE_WILDCARDS:
        s = s.replace(ch, "\\" + ch)
    return s


# Characters that, if present in an .or_() clause VALUE, force PostgREST to
# treat the value as ending early. Wrapping the value in double quotes tells
# PostgREST to read the value verbatim. Required for hard-coded patterns
# like "%, NY%" — the comma would otherwise be parsed as a clause separator.
_OR_VALUE_RESERVED = (",", "(", ")")


def _or_ilike_clause(col: str, pattern: str) -> str:
    """Build a single `col.ilike.<pattern>` clause for PostgREST `.or_()`.
    Wraps the pattern in double quotes when it contains characters that
    conflict with the or-clause parser (commas, parens). Embedded double
    quotes are doubled per PostgREST's quoting rules.
    """
    if any(c in pattern for c in _OR_VALUE_RESERVED) or '"' in pattern:
        escaped = pattern.replace('"', '""')
        return f'{col}.ilike."{escaped}"'
    return f"{col}.ilike.{pattern}"


def _is_tbd(name: str | None) -> bool:
    """Detect whether an event name signals a TBD date/opponent/necessity.

    TEvo doesn't expose a boolean `tbd` column on our `events` SQL table —
    only on the live API response. For SQL-only paths (e.g. /api/store/home)
    we detect it from the name string. Patterns observed in prod (verified
    against latest_event_metrics owned-future sample):

      "(Date TBD)"          — playoff games with unscheduled date
      "Date and Time TBD"   — concerts / non-sports with unscheduled time
      "(If Necessary)"      — playoff games not yet locked in

    All checks are case-insensitive.
    """
    if not name:
        return False
    up = name.upper()
    return (
        "(DATE TBD)" in up
        or "DATE AND TIME TBD" in up
        or "(IF NECESSARY)" in up
    )


def _clean_opt_url(v) -> str | None:
    """Coerce sentinel non-URLs to real None.

    `v_event_seating_chart` (and occasionally TEvo's inline config) carry the
    literal string "null" / "None" / "" for an absent seat-map URL. Passed
    through verbatim, the frontend treats the truthy string "null" as a URL
    and renders a broken <img> whose src resolves to /store/event/null. Coerce
    those sentinels to None so the no-chart placeholder path is taken.
    """
    if v is None:
        return None
    s = str(v).strip()
    if s.lower() in ("null", "none", ""):
        return None
    return v


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


def _search_sql_only(db, q_norm: str, limit: int) -> dict:
    """SQL-only search: ILIKE across our `events` + `performer_metadata` for
    queries when STOREFRONT_SQL_ONLY=true. Always hits Supabase, never TEvo.
    Returns the same shape as the live path so the client is mode-agnostic.
    """
    today_iso = datetime.now(timezone.utc).date().isoformat()
    # Strip characters that break PostgREST's or_() clause parser:
    # commas (clause separator), periods (operator separator), parens
    # (grouping). The replacement char is a space so multi-token queries
    # still work via ILIKE's wildcard handling.
    safe_q = re.sub(r"[,.()\"]", " ", q_norm).strip()
    if not safe_q:
        return {"events": [], "performers": [], "venues": [], "source": "sql"}
    # Escape ILIKE wildcards (%, _, \) so a user-supplied "%" doesn't
    # become a match-everything pattern. We wrap with our own %...%
    # after the escape.
    pattern = f"%{_escape_ilike(safe_q)}%"

    # Events: search by event name, venue name, venue location, primary
    # performer name. Limit to future + active so we don't surface ghosts.
    # Uses _or_ilike_clause for defense-in-depth: today the pattern has
    # been sanitized at line ~4467 so the legacy raw f-string would work,
    # but if that sanitization ever loosens this site would re-introduce
    # the PostgREST or-clause-separator bug that broke /api/store/movers.
    try:
        ev_rows = (db.table("events")
                     .select("id,name,occurs_at_local,venue_name,venue_location,"
                             "primary_performer_id,primary_performer_name")
                     .gte("occurs_at_local", today_iso)
                     .or_(",".join([
                         _or_ilike_clause("name", pattern),
                         _or_ilike_clause("venue_name", pattern),
                         _or_ilike_clause("venue_location", pattern),
                         _or_ilike_clause("primary_performer_name", pattern),
                     ]))
                     .order("occurs_at_local", desc=False)
                     .limit(80)
                     .execute().data) or []
    except Exception as e:
        print(f"search_sql_only events query failed: {e}")
        ev_rows = []

    # Tag with we_own + from_price via latest_event_metrics. Drop speculative
    # names (CANCELLED / (If Necessary) / (Date TBD)) — consumer storefront
    # should not surface playoff "may not happen" inventory.
    ev_rows = [e for e in ev_rows if not _is_speculative_event_name(e.get("name"))]
    if ev_rows:
        ev_ids = [int(e["id"]) for e in ev_rows if e.get("id")]
        metrics: dict[int, dict] = {}
        if ev_ids:
            try:
                rows = (db.table("latest_event_metrics")
                          .select("event_id,owned_tickets_count,owned_groups_count,retail_min")
                          .in_("event_id", ev_ids).execute().data) or []
                metrics = {int(r["event_id"]): r for r in rows if r.get("event_id")}
            except Exception:
                metrics = {}
        # Drop inactive (ghost/cancelled) events.
        try:
            lc = (db.table("event_lifecycle")
                    .select("event_id,is_active")
                    .in_("event_id", ev_ids).execute().data) or []
            inactive = {int(r["event_id"]) for r in lc if not r.get("is_active")}
        except Exception:
            inactive = set()
        ev_rows = [e for e in ev_rows if int(e.get("id") or 0) not in inactive]
    else:
        metrics = {}

    # Bias toward owned inventory: when a query like "aces" matches multiple
    # teams (Reno Aces minor-league + Las Vegas Aces WNBA), the soonest event
    # wins under the default occurs_at_local ASC sort even when we don't own
    # any inventory for that team. Audit 2026-05-16 found "aces" returning
    # Reno Aces first; we own Las Vegas Aces 5/17. Re-sort so events with
    # owned inventory come first, soonest among them next.
    ev_rows_sorted = sorted(
        ev_rows,
        key=lambda e: (
            0 if (metrics.get(int(e.get("id") or 0)) or {}).get("owned_tickets_count") else 1,
            e.get("occurs_at_local") or "9999-12-31",
        ),
    )

    events_out = []
    for e in ev_rows_sorted[:limit]:
        eid = int(e.get("id") or 0)
        m = metrics.get(eid) or {}
        events_out.append({
            "id": eid,
            "name": e.get("name"),
            "venue_name": e.get("venue_name"),
            "location": e.get("venue_location"),
            "occurs_at": e.get("occurs_at_local"),
            "we_own": bool(m.get("owned_tickets_count")),
            "from_price": m.get("retail_min"),
            "owned_tix": m.get("owned_tickets_count"),
        })

    # Performers via performer_metadata name match.
    try:
        pf_rows = (db.table("performer_metadata")
                     .select("performer_id,name,espn_league")
                     .ilike("name", pattern)
                     .limit(limit)
                     .execute().data) or []
    except Exception:
        pf_rows = []
    performers_out = [{
        "id": int(p.get("performer_id") or 0),
        "name": p.get("name"),
        "league": p.get("espn_league"),
    } for p in pf_rows if p.get("performer_id")]

    # Venues — derive from events distinct venue rows for SQL-only mode.
    # We don't have a public venues table; use distinct venue_name from
    # upcoming events matching the query.
    venues_out: list[dict] = []
    try:
        vn_rows = (db.table("events")
                     .select("venue_id,venue_name,venue_location")
                     .gte("occurs_at_local", today_iso)
                     .or_(",".join([
                         _or_ilike_clause("venue_name", pattern),
                         _or_ilike_clause("venue_location", pattern),
                     ]))
                     .limit(40)
                     .execute().data) or []
        seen: set[int] = set()
        for v in vn_rows:
            vid = int(v.get("venue_id") or 0)
            if vid in seen or not vid:
                continue
            seen.add(vid)
            venues_out.append({
                "id": vid,
                "name": v.get("venue_name"),
                "location": v.get("venue_location"),
            })
            if len(venues_out) >= limit:
                break
    except Exception:
        pass

    return {
        "events": events_out,
        "performers": performers_out,
        "venues": venues_out,
        "source": "sql",
    }


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


@app.get("/api/store/search")
def store_search(
    q: str = Query(..., max_length=200, description="Search term; max 200 chars to prevent multi-MB DoS payloads"),
    limit: int = 8,
):
    """Live storefront search. Hits TEvo /v9/searches/suggestions in live
    mode (and cross-joins our SQL for we_own/from_price tagging), or
    ILIKE-searches our tables when STOREFRONT_SQL_ONLY=true.

    Returns three buckets the dropdown UI renders separately:
      events:     [ { id, name, venue_name, location, occurs_at, we_own,
                      from_price, owned_tix } ]
      performers: [ { id, name, location, venue_name?, league? } ]
      venues:     [ { id, name, location } ]

    Cached per-q for 60s in process memory so a typist's stream of
    keystrokes doesn't burn TEvo quota.
    """
    q_norm = (q or "").strip()
    if not q_norm:
        return {"q": "", "events": [], "performers": [], "venues": [],
                "source": "empty", "latency_ms": 0}

    # Cap at 50; the upstream cap is 20, so anything past that just trims.
    lim = max(1, min(int(limit), 50))
    # Normalize so "  Knicks  ", "knicks", "KNICKS" all hit the same slot.
    # Mode (sql vs live) still differentiates so flipping STOREFRONT_SQL_ONLY
    # doesn't serve stale-mode cache entries.
    # Cache key segregates by which path actually ran. Matches the routing
    # decision below so a STOREFRONT_SEARCH_SQL_ONLY flip doesn't serve stale
    # cross-mode entries.
    _search_path = "sql" if (STOREFRONT_SQL_ONLY or STOREFRONT_SEARCH_SQL_ONLY) else "live"
    cache_key = f"{_normalize_search_key(q_norm)}|{lim}|{_search_path}"
    cached = _search_cache_get(cache_key)
    if cached is not None:
        return {**cached, "q": q_norm, "source": "cache", "latency_ms": 0}

    t0 = time.time()
    db = require_sb()
    # Routing: STOREFRONT_SEARCH_SQL_ONLY (default true) takes search to the
    # SQL path. STOREFRONT_SQL_ONLY=true wins regardless (legacy unified flag).
    # _search_live preserved as a flippable fallback — set
    # STOREFRONT_SEARCH_SQL_ONLY=false in env to revert search to TEvo.
    if STOREFRONT_SQL_ONLY or STOREFRONT_SEARCH_SQL_ONLY:
        payload = _search_sql_only(db, q_norm, lim)
    else:
        payload = _search_live(db, q_norm, lim)

    elapsed_ms = int((time.time() - t0) * 1000)
    payload["q"] = q_norm
    payload["latency_ms"] = elapsed_ms
    _search_cache_put(cache_key, payload)
    return payload


@app.get("/api/store/concierge")
def store_concierge(city: str = "NYC", days: int = 60, limit: int = 18):
    """Concierge rail — upcoming owned events where we hold PREMIUM top-band
    seats (>= $500), EVO/TEvo inventory only (D3, 2026-06-16). Backed by the
    `concierge_events` rollup; ordered most-premium first. `from_price` is the
    entry into each event's premium tier. NYC-scoped like the movers rail.
    """
    db = require_sb()
    today_iso = datetime.now(timezone.utc).date().isoformat()
    horizon_iso = (datetime.now(timezone.utc) + timedelta(days=max(1, min(int(days), 120)))).date().isoformat()
    venue_patterns = ("%New York%", "%Brooklyn%", "%Bronx%", "%Queens%",
                      "%Flushing%", "%Elmont%", "%, NY%", "%Newark%", "%East Rutherford%")
    try:
        q = (db.table("concierge_events")
               .select("event_id,name,venue_name,venue_location,occurs_at_local,"
                       "from_price,prem_max_price,prem_tickets,primary_performer_name")
               .gte("occurs_date", today_iso)
               .lte("occurs_date", horizon_iso))
        q = q.or_(",".join(_or_ilike_clause("venue_location", p) for p in venue_patterns))
        rows = q.order("prem_max_price", desc=True).limit(max(1, min(int(limit), 40))).execute().data or []
    except Exception as e:
        print(f"store_concierge query failed: {e}")
        return {"count": 0, "events": []}
    # Map event_id -> id so the card links to /store/event/{id}.
    events = [{**r, "id": r.pop("event_id")} for r in rows]
    return {"count": len(events), "events": events}


@app.get("/api/store/movers")
def store_movers(
    background_tasks: BackgroundTasks,
    city: str = "NYC",
    days: int = 21,
    limit: int = 8,
):
    """Homepage "moving fast" strip — owned-inventory events in a target
    city sorted by 24h ticket-velocity (most negative tickets_delta first).

    Only one city supported today (`city=NYC`); future versions can resolve
    user location → city automatically. Days defaults to 21 (3 weeks). Each
    returned event carries an optional `signal` field with one of three
    labels (no others surfaced per 2026-05-12 directive):

        'selling_fast'  — TEvo market lost ≥50 tickets in last 24h
        'demand_rising' — tickets dropped AND getin price firmed ≥5%
        'premium'       — getin price ≥ $500 (e.g. playoff games)

    Hidden when nothing matches. Driven by v_event_velocity_windows joined
    against latest_event_metrics + events + event_lifecycle.

    PERFORMANCE: stale-while-revalidate cached. The bare compute hits ~1s
    warm (audit-2026-05-16 measurement). Underlying velocity data refreshes
    only hourly, so a 5-min cache is well within the refresh cadence and
    collapses the homescreen response to a dict lookup (~5ms) on every
    request past the first per (city, days, limit) tuple.
    """
    cap = max(1, min(int(limit), 24))
    day_cap = max(1, min(int(days), 90))
    key = _movers_cache_key(city, day_cap, cap)
    now = time.time()
    cached = _movers_cache.get(key)

    if cached:
        age = now - cached[0]
        if age < _MOVERS_CACHE_TTL:
            # FRESH: serve immediately, no compute.
            return cached[1]
        # STALE: serve old payload + schedule a background recompute so
        # the NEXT request gets fresh data. Customer never waits.
        # Guard against duplicate fans for the same key under concurrent
        # requests — only one refresh in flight at a time per key.
        if key not in _MOVERS_CACHE_REFRESHING:
            _MOVERS_CACHE_REFRESHING.add(key)
            background_tasks.add_task(_refresh_movers, city, day_cap, cap, key)
        return cached[1]

    # COLD: never-seen key. Compute synchronously, cache, return.
    fresh = _compute_movers(require_sb(), city, day_cap, cap)
    _movers_cache[key] = (now, fresh)
    return fresh


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
        print(f"[movers refresh] failed for {key}: {e!r}")
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


def _section_moving_fast(candidates: list[dict], cap: int = 10) -> list[dict]:
    """Demand velocity (TEvo): supply leaving our broker market fast — a 24h
    ticket-count drop of ≥50. EVO-only; no SeatGeek sales signal."""
    out = []
    for c in candidates:
        d24h = c.get("tix_d24h")
        if isinstance(d24h, int) and d24h <= -50:
            out.append(c)
    out.sort(key=lambda c: (
        -abs(c.get("tix_d24h") or 0),
        c.get("occurs_at_local") or "9999",
    ))
    return out[:cap]


def _section_price_drops(candidates: list[dict], cap: int = 10) -> list[dict]:
    """Our get-in price fell ≥10% in the last 24h (TEvo get-in movement).
    EVO-only — no SeatGeek market comparison. Displayed as "↓ X% in 24h"."""
    out = []
    for c in candidates:
        getin_pct = c.get("getin_pct_24h")
        if isinstance(getin_pct, (int, float)) and getin_pct <= -10.0:
            c["_discount_pct"] = round(abs(getin_pct), 1)
            out.append(c)
    out.sort(key=lambda c: (-c.get("_discount_pct", 0.0),
                            c.get("occurs_at_local") or "9999"))
    return out[:cap]


def _section_climbing(candidates: list[dict], cap: int = 10) -> list[dict]:
    """Price firming (TEvo): tickets dropping AND get-in climbing ≥5% in 24h.
    EVO-only; the former SeatGeek-median path was removed."""
    out = []
    for c in candidates:
        d24h = c.get("tix_d24h")
        getin_pct = c.get("getin_pct_24h")
        tevo_climb = (isinstance(d24h, int) and d24h < 0
                      and isinstance(getin_pct, (int, float)) and getin_pct >= 5.0)
        if tevo_climb:
            c["_climb_pct"] = round(getin_pct, 1)
            out.append(c)
    out.sort(key=lambda c: (-(c.get("_climb_pct") or 0),
                            c.get("occurs_at_local") or "9999"))
    return out[:cap]


def _section_specials(candidates: list[dict],
                      holiday_by_eid: dict[int, dict],
                      rivalry_by_eid: dict[int, str],
                      cap: int = 10) -> list[dict]:
    """Curated rail — events that qualify on a non-market basis. Two
    sources fold in here:
      1. v_event_holidays + holiday-window expansion: day-of OR ±2 day
         (Memorial Day vs Memorial Day Weekend, etc.)
      2. v_rivalry_events: known rivalry games (Yankees-Red Sox, etc.)
    Both gated to owned > 100 — same depth bar the operator set for
    the "specials" rail. Each card is tagged with `_special` describing
    what earned its slot (e.g. "Memorial Day", "Memorial Day Weekend",
    or "Yankees vs Red Sox").
    """
    out = []
    for c in candidates:
        if (c.get("owned_tickets_count") or 0) <= 100:
            continue
        eid = c.get("id")
        try:
            eid_int = int(eid) if eid is not None else None
        except (TypeError, ValueError):
            eid_int = None
        if eid_int is None:
            continue
        holiday = holiday_by_eid.get(eid_int)
        rivalry = rivalry_by_eid.get(eid_int)
        if holiday or rivalry:
            # Prefer rivalry tag when both apply — more specific narrative.
            if rivalry:
                c["_special"] = rivalry
            else:
                hname = (holiday or {}).get("name") or ""
                # Weekend-of holidays get "Memorial Day Weekend" framing;
                # day-of keeps the bare holiday name.
                c["_special"] = f"{hname} Weekend" if (holiday or {}).get("weekend") else hname
            c["_special_kind"] = "rivalry" if rivalry else "holiday"
            out.append(c)
    out.sort(key=lambda c: c.get("occurs_at_local") or "9999")
    return out[:cap]


def _section_featured(candidates: list,
                      holiday_by_eid: dict,
                      rivalry_by_eid: dict,
                      cap: int = 20) -> list:
    """Featured rail — operator directive 2026-05-19 v3. Multi-signal
    curation. All branches require `owned_tickets_count > 100`. Tag
    selection: playoff > world_cup > rivalry > holiday > marquee > premium.

      1. Playoff games           — `_classify_playoff()` regex hit
      2. World Cup matches       — `_classify_world_cup()` (D3 2026-06-16).
                                   FIFA World Cup 2026 soccer matches we own,
                                   tagged "World Cup". Exempt from the owned>100
                                   gate (marquee international inventory is thin
                                   per match, like playoffs).
      3. Holiday calendar games  — date within holiday window (±2 days
                                   from observed_date; weekend coverage).
                                   Tag = "Memorial Day" for day-of,
                                   "Memorial Day Weekend" for ±1/±2.
      4. Rivalry games           — `v_rivalry_events` membership
      5. Marquee competitions    — US Open Tennis / F1 / Inter Miami away
      6. Other category          — `owned_median_retail > $50` catch-all
                                   (concerts, regular-season home games,
                                   anything not in 1-5)

    Premium-only events show no tag (section title "Featured" carries the
    framing). Internal owned-count labels not exposed.
    """
    out = []
    for c in candidates:
        eid = c.get("id")
        if eid is None:
            continue
        try:
            eid_int = int(eid)
        except (TypeError, ValueError):
            continue
        owned = c.get("owned_tickets_count") or 0
        playoff = _classify_playoff(c.get("name") or "")
        world_cup = _classify_world_cup(c.get("name"), c.get("primary_performer_name"))
        if owned <= 100 and not playoff and not world_cup:
            # Global depth gate for non-playoff events. Playoff games are
            # exempt (operator directive 2026-05-26) — they're the highest-
            # value NYC inventory even at thin owned counts (e.g. Knicks
            # Game 7 sits at owned ~60, well under the regular-season bar).
            # World Cup matches share the exemption (D3 2026-06-16): marquee
            # international inventory is thin per match (e.g. Match 72 owned
            # ~62) but exactly what the Featured rail is for.
            continue
        rivalry = rivalry_by_eid.get(eid_int)
        holiday = holiday_by_eid.get(eid_int)
        marquee = _classify_marquee_competition(c.get("name") or "")
        # Branches 1-5: specific narrative signals (any of) → always Featured
        if playoff:
            c["_featured_tag"] = (playoff.get("label") or "Playoff")
            c["_featured_kind"] = "playoff"
        elif world_cup:
            c["_featured_tag"] = "World Cup"
            c["_featured_kind"] = "world_cup"
        elif rivalry:
            c["_featured_tag"] = rivalry
            c["_featured_kind"] = "rivalry"
        elif holiday:
            # Holiday tag — day-of keeps bare name ("Memorial Day"); ±1/±2
            # gets the weekend framing ("Memorial Day Weekend").
            hname = (holiday or {}).get("name") or ""
            c["_featured_tag"] = f"{hname} Weekend" if (holiday or {}).get("weekend") else hname
            c["_featured_kind"] = "holiday"
        elif marquee:
            c["_featured_tag"] = marquee
            c["_featured_kind"] = "marquee"
        else:
            # Branch 5a: "any other category" — requires median > $50
            # Branch 5b: market-anchor fallback (operator 2026-05-19 v4):
            #   owned > 200 AND owned_share >= 20% catches bargain-tier
            #   games where we dominate inventory but pricing is consumer-
            #   friendly. Threshold based on Yankees distribution audit:
            #   regular games sit 12-22% share; >=20% = "we are the market".
            med = c.get("owned_median_retail")
            try:
                med_f = float(med) if med is not None else None
            except (TypeError, ValueError):
                med_f = None
            share = c.get("owned_share")
            try:
                share_f = float(share) if share is not None else None
            except (TypeError, ValueError):
                share_f = None
            is_premium = (med_f is not None and med_f > 50.0)
            is_market_anchor = (owned > 200) and (share_f is not None and share_f >= 0.20)
            if not (is_premium or is_market_anchor):
                continue
            c["_featured_tag"] = ""  # no internal-metric chip on consumer UI
            c["_featured_kind"] = "premium" if is_premium else "market_anchor"
        out.append(c)
    out.sort(key=lambda c: c.get("occurs_at_local") or "9999")
    return out[:cap]


def _compute_movers(db, city: str, day_cap: int, cap: int) -> dict:
    """Pure compute path for the movers endpoint. Extracted from the route
    handler so both the cold-cache code path AND the background-refresh
    task call the same implementation. Returns the exact response dict
    the route emits (`city`, `days`, `count`, `events`).
    """
    # City filter — hardcoded NYC venue patterns for v1. Matches everywhere
    # the storefront would consider "New York metro" inventory.
    city_norm = (city or "").upper()
    if city_norm in ("NYC", "NEW YORK", "NEW YORK CITY"):
        venue_patterns = ("%New York%", "%Brooklyn%", "%Bronx%",
                          "%Queens%", "%Manhattan%", "%, NY%")
    else:
        # Unknown city → empty result; cleaner than a 400 for the home view.
        return {"city": city, "days": day_cap, "count": 0, "events": []}

    today_iso = datetime.now(timezone.utc).date().isoformat()
    horizon_iso = (datetime.now(timezone.utc) + timedelta(days=day_cap)).date().isoformat()

    # Pull events in the window with owned inventory + active lifecycle.
    # Two queries + merge (consistent with the catalog pattern; view-to-
    # table FK inference under PostgREST has been flaky).
    try:
        ev_q = db.table("events").select(
            "id,name,occurs_at_local,venue_id,venue_name,venue_location,"
            "primary_performer_id,primary_performer_name,performer_ids"
        ).gte("occurs_at_local", today_iso).lte("occurs_at_local", horizon_iso + "T23:59:59")
        # PostgREST `or_()` with a comma-separated list of `<col>.ilike.<pat>`
        # supports OR filters across multiple patterns. Use _or_ilike_clause so
        # patterns containing literal commas (e.g. "%, NY%") are double-quoted
        # and don't get split by PostgREST's clause parser — that bug silently
        # returned 0 movers for ~309 owned NYC events until the fix landed.
        or_clauses = ",".join(_or_ilike_clause("venue_location", p) for p in venue_patterns)
        ev_q = ev_q.or_(or_clauses)
        events_rows = ev_q.limit(800).execute().data or []
    except Exception as e:
        # Conservative fallback: don't break the homepage if the filter
        # syntax ever drifts.
        print(f"store_movers events query failed: {e}")
        return {"city": city, "days": day_cap, "count": 0, "events": []}

    # ----- World Cup inclusion (D3, 2026-06-16) -----
    # The Featured rail is NYC-anchored (venue_patterns above), but FIFA World
    # Cup 2026 matches are a national draw and our owned WC inventory can sit
    # at any host venue (e.g. Match 72 at Mercedes-Benz Stadium, Atlanta —
    # which the NYC venue filter would exclude). Pull owned World Cup events
    # regardless of city and merge them into events_rows so they flow through
    # the same metrics/lifecycle/curation pipeline and can reach Featured.
    # Wrapped so a failure here degrades to NYC-only behavior, never 500s.
    try:
        wc_rows = (db.table("events").select(
            "id,name,occurs_at_local,venue_id,venue_name,venue_location,"
            "primary_performer_id,primary_performer_name,performer_ids"
        ).gte("occurs_at_local", today_iso)
         .lte("occurs_at_local", horizon_iso + "T23:59:59")
         .ilike("primary_performer_name", "%World Cup Soccer%")
         .limit(100).execute().data) or []
        seen_eids = {int(e["id"]) for e in events_rows if e.get("id")}
        for e in wc_rows:
            eid = e.get("id")
            if eid is not None and int(eid) not in seen_eids:
                events_rows.append(e)
                seen_eids.add(int(eid))
    except Exception as e:
        print(f"store_movers world-cup pull failed: {e}")

    if not events_rows:
        return {"city": city, "days": day_cap, "count": 0, "events": []}
    # Drop speculative names (CANCELLED / (If Necessary)) — playoff "may not
    # happen" placeholders normally shouldn't surface to consumers. EXCEPTION
    # (operator directive 2026-05-26): playoff games keep their "(If Necessary)"
    # slot in the movers strip — they're the highest-value NYC inventory (e.g.
    # Knicks Game 7, $5,880 median) and are exactly what the Featured rail is
    # for. Genuine CANCELLED games still drop, even playoff ones. This relaxes
    # the filter ONLY for the movers strip; search + home still hide these.
    events_rows = [
        e for e in events_rows
        if not _is_speculative_event_name(e.get("name"))
        or (_classify_playoff(e.get("name"))
            and "CANCELLED" not in (e.get("name") or "").upper())
    ]
    if not events_rows:
        return {"city": city, "days": day_cap, "count": 0, "events": []}
    events_by_id = {int(e["id"]): e for e in events_rows if e.get("id")}
    ev_ids = list(events_by_id.keys())

    # Owned-only metrics so we don't list events we can't actually sell.
    metrics = (db.table("latest_event_metrics")
                 .select("event_id,owned_tickets_count,owned_groups_count,"
                         "tickets_count,retail_min,owned_median_retail,owned_share,"
                         "captured_at")
                 .gt("owned_tickets_count", 0)
                 .in_("event_id", ev_ids)
                 .execute().data) or []
    if not metrics:
        return {"city": city, "days": day_cap, "count": 0, "events": []}
    metrics_by_id = {int(m["event_id"]): m for m in metrics if m.get("event_id")}

    # Lifecycle filter — drop ghost/cancelled/postponed.
    try:
        lc = (db.table("event_lifecycle")
                .select("event_id,is_active")
                .in_("event_id", list(metrics_by_id.keys()))
                .execute().data) or []
        inactive = {int(r["event_id"]) for r in lc if not r.get("is_active")}
    except Exception:
        inactive = set()

    # World Cup exemption (D3, 2026-06-16): the ghost detector eliminates events
    # whose TEvo event row hasn't been re-polled recently (e.g. Match 72 flagged
    # `ghost_eliminated` / `sports_stale_135hr`). That recency signal is about
    # the events-feed cadence, NOT inventory — and we have live owned listings on
    # these matches, so dropping them is a false negative. Keep owned World Cup
    # matches out of `inactive`. Genuinely cancelled ones are still removed by the
    # speculative-name filter above ("CANCELLED" never qualifies as WC here).
    for _eid in list(inactive):
        _ev = events_by_id.get(_eid) or {}
        if _classify_world_cup(_ev.get("name"), _ev.get("primary_performer_name")):
            inactive.discard(_eid)

    # Velocity windows for the 1h/24h ticket delta + getin pct moves.
    try:
        vw = (db.table("v_event_velocity_windows")
                .select("tevo_event_id,tevo_tix_now,tevo_tix_d24h,"
                        "tevo_getin_now,tevo_getin_d24h_pct,tevo_now_at")
                .in_("tevo_event_id", list(metrics_by_id.keys()))
                .execute().data) or []
    except Exception:
        vw = []
    velocity_by_id = {int(v["tevo_event_id"]): v for v in vw if v.get("tevo_event_id") is not None}

    # Bulk performer assets — fetch BOTH home (primary_performer_id) AND
    # away (first secondary in performer_ids array) so cards can render
    # home-vs-away branding. performer_ids is a text[] column on `events`;
    # cast to int and dedupe. 2026-05-19: extends prior home-only fetch.
    perf_ids_set: set[int] = set()
    for i in metrics_by_id:
        if i in inactive:
            continue
        ev = events_by_id[i]
        pp = ev.get("primary_performer_id")
        if pp:
            try: perf_ids_set.add(int(pp))
            except (TypeError, ValueError): pass
        for raw_pid in (ev.get("performer_ids") or []):
            try: perf_ids_set.add(int(raw_pid))
            except (TypeError, ValueError): pass
    perf_assets = _bulk_performer_assets(db, list(perf_ids_set)) if perf_ids_set else {}

    # Freshness gate for velocity signals. v_event_velocity_windows computes
    # the d24h ticket delta from the latest event_metrics sample vs the one
    # ~24h before it. If the latest sample is itself ancient, that delta is a
    # stale read, so we bound how old it can be before we stop trusting it for
    # rail membership (moving_fast / climbing).
    #
    # Window sizing (revised 2026-05-25 — was 3h, which silently emptied the
    # moving_fast/price_drops/climbing rails): the storefront's owned MLB/NBA
    # events are re-polled on a ~24-48h cadence (the featured playoff events
    # poll faster, but the long-tail regular-season games — exactly the ones
    # that trend "moving fast" — refresh daily-ish). A 3h gate excluded EVERY
    # qualifying event (samples were 21-141h old) so the rails rendered empty.
    # 48h admits the freshest-available sample for the typical cadence while
    # still excluding genuinely cold data (e.g. a 6-day-old sample). The d24h
    # value is NOT displayed on the mover card (which shows only "from $X"),
    # so a lagged-but-bounded delta is fine here — it only governs which
    # events qualify as a discovery-rail signal, not a precise live count.
    _VELOCITY_FRESH_MAX_AGE_SEC = 48 * 3600  # 48 hours — matches collector cadence

    def _is_velocity_fresh(v: dict) -> bool:
        ts = v.get("tevo_now_at")
        if not ts:
            return False
        try:
            captured = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
            age = (datetime.now(timezone.utc) - captured).total_seconds()
            return 0 <= age <= _VELOCITY_FRESH_MAX_AGE_SEC
        except (TypeError, ValueError):
            return False

    # ----- EVO-only storefront (operator directive 2026-06-16) -----
    # The consumer store features EVO/TEvo inventory ONLY — no SeatGeek
    # information or values surface to customers. The former SG enrichment
    # (xref + sales + listings windows) was removed; the discovery rails below
    # (moving_fast / price_drops / climbing) run purely off TEvo velocity
    # signals (ticket-count delta + get-in price movement).

    # ----- Build candidate pool with all signal data attached -----
    # Every owned (>=1) event lands in `candidates` with its full signal
    # payload. Each section helper below filters this pool independently;
    # an event can qualify for 0, 1, or multiple sections.
    # `all_owned_cards` collects EVERY owned event (incl. owned<=50) so the
    # empty-rail fallback below has a pool to draw from when nothing clears
    # the curation gates (operator directive 2026-05-26).
    candidates: list[dict] = []
    all_owned_cards: list[dict] = []
    for eid, m in metrics_by_id.items():
        if eid in inactive:
            continue
        ev = events_by_id.get(eid) or {}
        v = velocity_by_id.get(eid) or {}
        velocity_fresh = _is_velocity_fresh(v)
        tix_d24h = v.get("tevo_tix_d24h") if velocity_fresh else None
        getin_pct_24h = v.get("tevo_getin_d24h_pct") if velocity_fresh else None
        getin_now = v.get("tevo_getin_now")
        from_price = m.get("retail_min") if m.get("retail_min") is not None else getin_now

        try:
            d24h_val = int(tix_d24h) if tix_d24h is not None else None
        except (TypeError, ValueError):
            d24h_val = None
        try:
            pct_val = float(getin_pct_24h) if getin_pct_24h is not None else None
        except (TypeError, ValueError):
            pct_val = None

        # Home-team assets (primary performer)
        primary_pid_raw = ev.get("primary_performer_id")
        primary_pid: int | None = None
        try:
            primary_pid = int(primary_pid_raw) if primary_pid_raw else None
        except (TypeError, ValueError):
            primary_pid = None
        a = perf_assets.get(primary_pid) if primary_pid else None
        # Away-team assets — first performer_id in array that's NOT primary.
        # Sports matchups: events.performer_ids = [home_id, away_id, ...].
        # Playoff/single-team entries may have only the primary; in that
        # case away_* fields stay null (graceful no-op on FE).
        away_pid: int | None = None
        for raw_pid in (ev.get("performer_ids") or []):
            try:
                pid_int = int(raw_pid)
            except (TypeError, ValueError):
                continue
            if primary_pid is not None and pid_int == primary_pid:
                continue
            away_pid = pid_int
            break
        b = perf_assets.get(away_pid) if away_pid else None
        owned_tickets = m.get("owned_tickets_count") or 0
        card = {
            "id": ev.get("id"),
            "name": ev.get("name"),
            "occurs_at_local": ev.get("occurs_at_local"),
            "venue_name": ev.get("venue_name"),
            "venue_location": ev.get("venue_location"),
            "primary_performer_name": ev.get("primary_performer_name"),
            "primary_performer_logo": (a or {}).get("logo_default_url"),
            "primary_performer_color": (a or {}).get("color_primary"),
            # Away-team assets — 2026-05-19: "populate all store events
            # with team assets where available". Null when no away
            # performer in array (e.g. playoff placeholder events).
            "away_performer_id":    away_pid,
            "away_performer_name":  (b or {}).get("name"),
            "away_performer_logo":  (b or {}).get("logo_default_url"),
            "away_performer_color": (b or {}).get("color_primary"),
            "from_price": from_price,
            "tix_d24h": d24h_val,
            "getin_pct_24h": pct_val,
            "owned_tickets_count": owned_tickets,
            "owned_median_retail": m.get("owned_median_retail"),
            "owned_share": m.get("owned_share"),
        }
        all_owned_cards.append(card)
        if owned_tickets > 50:
            # Sections (except holidays) require owned > 50 for inventory depth;
            # holidays/specials are tighter at > 100, applied in the section
            # helpers. Playoff games additionally bypass the owned>100 Featured
            # gate (see _section_featured).
            candidates.append(card)

    # ----- Specials enrichment: pull holiday-window matches + rivalry
    # tags. Both wrapped in try/except so a view-side failure degrades
    # to no-specials rather than killing the whole movers response.
    candidate_ids = [int(c["id"]) for c in candidates if c.get("id") is not None]
    # holiday_by_eid value shape (2026-05-19): {"name": str, "weekend": bool}
    # weekend=False → event is ON the holiday's observed_date (label "Memorial Day")
    # weekend=True  → event is ±1/±2 days from observed_date (label "Memorial Day Weekend")
    # Operator directive: distinguish day-of from weekend-of so the actual
    # holiday day stands apart in the rail badges.
    holiday_by_eid: dict[int, dict] = {}
    rivalry_by_eid: dict[int, str] = {}
    if candidate_ids:
        try:
            hrows = (db.table("v_event_holidays")
                       .select("tevo_event_id,holiday_name")
                       .in_("tevo_event_id", candidate_ids)
                       .execute().data) or []
            # First match wins per event — v_event_holidays can emit
            # multiple rows when a date hits multiple holidays. The view
            # already orders by match_specificity DESC server-side. This
            # view is exact-date only (see line 5856 landmine note), so
            # all matches from here are day-of → weekend=False.
            for r in hrows:
                eid = r.get("tevo_event_id")
                if eid is None:
                    continue
                key = int(eid)
                if key not in holiday_by_eid and r.get("holiday_name"):
                    holiday_by_eid[key] = {"name": r["holiday_name"], "weekend": False}
        except Exception as e:
            print(f"store_movers v_event_holidays query failed: {e}")
        try:
            rrows = (db.table("v_rivalry_events")
                       .select("tevo_event_id,rivalry_name,rivalry_intensity")
                       .in_("tevo_event_id", candidate_ids)
                       .execute().data) or []
            # v_rivalry_events emits duplicate rows when both teams in a
            # matchup are competitors (app.py:1198 bible landmine).
            # Dedupe Python-side; first row wins.
            for r in rrows:
                eid = r.get("tevo_event_id")
                if eid is None:
                    continue
                key = int(eid)
                if key not in rivalry_by_eid and r.get("rivalry_name"):
                    rivalry_by_eid[key] = r["rivalry_name"]
        except Exception as e:
            print(f"store_movers v_rivalry_events query failed: {e}")

    # ----- Build the 4 themed sliders. Each section is independent and
    # gets its own copy of qualifying candidates (cards may appear in
    # more than one section, e.g. a rivalry game that's also moving fast).
    # Cross-list dedup (operator directive 2026-05-19 v2): an event appears
    # in at most ONE rail. Process in priority order; each rail consumes
    # events from a shared `seen` set, so subsequent rails skip them.
    # Priority: Featured > moving_fast > price_drops > climbing > specials.
    seen: set = set()
    def _consume(items: list) -> list:
        out = []
        for c in items:
            eid = c.get("id")
            try:
                eid_int = int(eid) if eid is not None else None
            except (TypeError, ValueError):
                eid_int = None
            if eid_int is None or eid_int in seen:
                continue
            seen.add(eid_int)
            out.append(c)
        return out

    # Holiday-window expansion (operator directive 2026-05-19 v3, refined v4):
    # base `v_event_holidays` exact-date join misses weekend games. Pull all
    # in-window holidays + apply per-event applicability rules:
    #   - US country-level     → tag (storefront is NYC)
    #   - US state=NY or city=New York → tag
    #   - US state/city != NY  → skip
    #   - CA country-level     → tag ONLY when event has a Canadian team
    #   - CA province-level (QC etc.) → never tag
    # Priority: Father's/Mother's Day > Memorial/Independence/Labor/Thanks/
    # Christmas > New Year's > Juneteenth > everything else.
    try:
        cand_dates = sorted({
            (c.get("occurs_at_local") or "")[:10]
            for c in candidates if c.get("occurs_at_local")
        })
        if cand_dates:
            from datetime import date as _date_cls
            win_lo = (_date_cls.fromisoformat(cand_dates[0])  - timedelta(days=2)).isoformat()
            win_hi = (_date_cls.fromisoformat(cand_dates[-1]) + timedelta(days=2)).isoformat()
            holiday_rows = (db.table("holidays")
                              .select("observed_date,holiday_name,country,state,city")
                              .gte("observed_date", win_lo)
                              .lte("observed_date", win_hi)
                              .execute().data) or []
            # Group: date_str → list of (holiday_row) within ±2 day window
            date_to_options: dict[str, list[dict]] = {}
            for h in holiday_rows:
                obs = h.get("observed_date")
                if not obs:
                    continue
                try:
                    obs_d = _date_cls.fromisoformat(obs)
                except (TypeError, ValueError):
                    continue
                # Window: -2 day through +1 day inclusive.
                # observed_date itself is included (dd=0) — used to flag
                # day-of matches that v_event_holidays may have missed.
                for dd in range(-2, 2):
                    ds = (obs_d + timedelta(days=dd)).isoformat()
                    date_to_options.setdefault(ds, []).append(h)
            # Resolve per candidate. Apply applicability + priority.
            for c in candidates:
                eid = c.get("id")
                if eid is None:
                    continue
                try:
                    eid_int = int(eid)
                except (TypeError, ValueError):
                    continue
                if eid_int in holiday_by_eid:
                    continue  # exact-date join from v_event_holidays already set
                cd = (c.get("occurs_at_local") or "")[:10]
                options = date_to_options.get(cd, [])
                if not options:
                    continue
                ev_name = c.get("name") or ""
                applicable: list[dict] = []
                for h in options:
                    country = h.get("country")
                    state = h.get("state")
                    city = h.get("city")
                    if country == "US":
                        # NY-state / New-York-city restrictions OK (storefront
                        # is NYC). Skip other-city / other-state US holidays.
                        if city and city != "New York":
                            continue
                        if state and state != "NY":
                            continue
                        applicable.append(h)
                    elif country == "CA":
                        # Canadian holiday — only tag when a Canadian team
                        # is visiting NYC. Skip province-specific holidays.
                        if state:
                            continue
                        if not _has_canadian_team(ev_name):
                            continue
                        applicable.append(h)
                    # other countries → silently skip
                if not applicable:
                    continue
                # Priority sort: higher _HOLIDAY_PRIORITY wins; tie-break to US
                applicable.sort(key=lambda hh: (
                    -_HOLIDAY_PRIORITY.get(hh.get("holiday_name", ""), 0),
                    0 if hh.get("country") == "US" else 1,
                ))
                chosen = applicable[0]
                hname = chosen.get("holiday_name", "")
                # Day-of vs weekend-of vs skip: see _classify_holiday_proximity
                # docstring. Operator 2026-05-19 v6: Tuesday after Memorial Day
                # Monday is NOT "Memorial Day Weekend" — only Sat/Sun in the
                # ±2 window earn the weekend tag.
                proximity = _classify_holiday_proximity(cd, chosen.get("observed_date") or "")
                if proximity == "day_of":
                    holiday_by_eid[eid_int] = {"name": hname, "weekend": False}
                elif proximity == "weekend_of":
                    holiday_by_eid[eid_int] = {"name": hname, "weekend": True}
                # else: non-weekend weekday in window → no tag
    except Exception as e:
        print(f"store_movers holiday-window expansion failed: {e}")

    # Featured = playoff OR holiday-weekend OR rivalry OR marquee competition
    # OR (other category with owned_median > $50). Owned > 100 required globally.
    # Runs FIRST so curated picks win over generic-velocity rails.
    featured = _consume(_section_featured(candidates, holiday_by_eid, rivalry_by_eid))
    moving_fast = _consume(_section_moving_fast(candidates))
    price_drops = _consume(_section_price_drops(candidates))
    climbing = _consume(_section_climbing(candidates))
    # Specials brought back as its own rail (was folded into Featured in
    # PR #279; operator narrowed Featured + asked specials to "populate to
    # other lists we have"). Holiday/rivalry events with owned > 100 that
    # don't qualify for Featured land here.
    specials = _consume(_section_specials(candidates, holiday_by_eid, rivalry_by_eid))

    # Empty-rail fallback (operator directive 2026-05-26): never render a blank
    # homepage. When nothing clears the curation gates — common in thin-
    # inventory windows (offseason, between playoff rounds) — surface the
    # soonest upcoming owned NYC events in the Featured rail so it always has
    # something bookable. These qualify on recency + owned inventory alone, so
    # they carry no curation chip (_featured_tag = "").
    if not (featured or moving_fast or price_drops or climbing or specials):
        fallback = sorted(all_owned_cards,
                          key=lambda c: c.get("occurs_at_local") or "9999")[:cap]
        for fc in fallback:
            fc.setdefault("_featured_tag", "")
            fc["_featured_kind"] = "fallback"
        featured = fallback

    return {
        "city": city,
        "days": day_cap,
        "count": len(featured) + len(moving_fast) + len(price_drops) + len(climbing) + len(specials),
        "featured": featured,
        "moving_fast": moving_fast,
        "price_drops": price_drops,
        "climbing": climbing,
        "specials": specials,
    }


@app.get("/api/store/home")
def store_home(
    limit: int = 60,
    city: str = "",
):
    """Homepage "first paint" endpoint — owned + active future events
    served entirely from SQL (no TEvo round-trip).

    Why this exists: the catalog endpoint (/api/store/events) is TEvo-direct
    per the PR #84 rewrite, which means ~1.4s response time AND from_price
    + owned_tickets_count fields land as null (would need a per-event call
    to enrich, see app.py:~4283 comment). Cards render without prices, which
    looks half-finished to a visitor.

    This endpoint sidesteps that by joining `latest_event_metrics`
    (retail_min, owned counts, captured_at) with `events` (metadata),
    `event_lifecycle` (drop ghost/cancelled), `v_event_velocity_windows`
    (24h ticket-delta + getin signal), and `performer_metadata` (logos/
    colors). Response shape mirrors /api/store/events so the client renderer
    is interchangeable.

    Curation order (premium-first → demand-rising → soon-by-date):
      1. Premium (retail_min >= $500)            — playoff/hot inventory
      2. Selling-fast (tevo_tix_d24h <= -50)      — high-velocity events
      3. Demand-rising (tix dropping + getin firming >=5%)
      4. Others sorted by occurs_at_local asc

    `city=NYC` (optional) restricts to NYC-area venues (Yankee Stadium,
    Citi Field, MSG, Barclays, etc.). Empty means national. Single-city
    enum for v1; future versions resolve from user geo.

    Designed for the home view first paint. After this lands, the client
    can lazy-load /api/store/events for the long-tail of non-owned events.
    """
    db = require_sb()
    cap = max(1, min(int(limit), 100))
    city_norm = (city or "").upper().strip()

    # Pull owned-future LEM rows.
    try:
        lem_rows = (db.table("latest_event_metrics")
                      .select("event_id,owned_tickets_count,owned_groups_count,"
                              "retail_min,retail_median,retail_p25,retail_p75,"
                              "getin_price,captured_at,tickets_count")
                      .gt("owned_tickets_count", 0)
                      .limit(1000)
                      .execute().data) or []
    except Exception as e:
        # Conservative fallback so the homepage never breaks on a transient
        # matview read error. Empty payload renders the existing "Loading…"
        # → "No events match" UI path.
        print(f"[store_home] LEM query failed: {e!r}")
        return {"count": 0, "events": [], "source": "sql"}

    if not lem_rows:
        return {"count": 0, "events": [], "limit": cap, "source": "sql"}

    ev_ids = [int(r["event_id"]) for r in lem_rows if r.get("event_id")]
    lem_by_id = {int(r["event_id"]): r for r in lem_rows if r.get("event_id")}

    # Events (future only). Two-query merge — same pattern as
    # _attach_owned_metadata and store_movers (PostgREST view-to-table
    # FK inference has been flaky on rebuilds).
    #
    # NOTE: events.tbd column doesn't exist in our schema — tbd is a TEvo
    # API response field, not a SQL column. We detect TBD from the event
    # name string via _is_tbd() in the card-build loop below.
    today_iso = datetime.now(timezone.utc).date().isoformat()
    try:
        ev_rows = (db.table("events")
                     .select("id,name,occurs_at_local,venue_id,venue_name,"
                             "venue_location,primary_performer_id,"
                             "primary_performer_name,performer_ids")
                     .in_("id", ev_ids)
                     .gte("occurs_at_local", today_iso)
                     .limit(1000)
                     .execute().data) or []
    except Exception as e:
        print(f"[store_home] events query failed: {e!r}")
        return {"count": 0, "events": [], "source": "sql"}

    events_by_id = {int(e["id"]): e for e in ev_rows if e.get("id")}

    # Drop CANCELLED-name rows (rare, but cheap to filter — TEvo bakes the
    # marker into the event name).
    events_by_id = {
        k: v for k, v in events_by_id.items()
        if not _is_speculative_event_name(v.get("name"))
    }

    # Active-only via event_lifecycle.
    if events_by_id:
        try:
            lc = (db.table("event_lifecycle")
                    .select("event_id,is_active")
                    .in_("event_id", list(events_by_id.keys()))
                    .execute().data) or []
            inactive = {int(r["event_id"]) for r in lc if not r.get("is_active")}
        except Exception:
            inactive = set()
        events_by_id = {k: v for k, v in events_by_id.items() if k not in inactive}

    # Optional city filter. NYC-area substring match. Future cities can be
    # added behind the same enum gate.
    if city_norm in ("NYC", "NEW YORK", "NEW YORK CITY"):
        nyc_substrings = ("new york", "brooklyn", "bronx", "queens",
                          "manhattan", "flushing")
        events_by_id = {
            k: v for k, v in events_by_id.items()
            if any(s in (v.get("venue_location") or "").lower() for s in nyc_substrings)
            or ", NY" in (v.get("venue_location") or "")
        }

    if not events_by_id:
        return {"count": 0, "events": [], "limit": cap, "source": "sql"}

    # NOTE on velocity: an earlier iteration of this endpoint joined
    # v_event_velocity_windows to surface selling_fast / demand_rising
    # signals. EXPLAIN ANALYZE against prod showed that join was the
    # dominant cost (~702ms of ~738ms total — 95% of latency) because the
    # view scans 38k+ event_metrics rows + per-event SubPlans for the 24h
    # delta. We've split that off: the homepage now serves the SQL grid
    # in <50ms, and the existing /api/store/movers endpoint (separately
    # wired to <section id="moversStrip"> in index.html) provides the
    # velocity-based "moving fast" strip below the grid. Net UX is the
    # same — just two parallel calls instead of one slow one.

    # Bulk performer assets for card branding (logo + brand color).
    # 2026-05-19: extends to home + away performers so cards can render
    # matchup branding (Cavs-at-Knicks both logos, etc.).
    perf_ids_set: set[int] = set()
    for e in events_by_id.values():
        pp = e.get("primary_performer_id")
        if pp:
            try: perf_ids_set.add(int(pp))
            except (TypeError, ValueError): pass
        for raw_pid in (e.get("performer_ids") or []):
            try: perf_ids_set.add(int(raw_pid))
            except (TypeError, ValueError): pass
    perf_assets = _bulk_performer_assets(db, list(perf_ids_set)) if perf_ids_set else {}

    # Build cards. Schema mirrors /api/store/events for renderer reuse, plus
    # `from_price` + `owned_tickets_count` + `signal` actually populated
    # (when the event clears the premium gate).
    cards: list[dict] = []
    for eid, ev in events_by_id.items():
        lem = lem_by_id.get(eid, {})
        perf_id = ev.get("primary_performer_id")
        try:
            primary_pid = int(perf_id) if perf_id else None
        except (TypeError, ValueError):
            primary_pid = None
        assets = perf_assets.get(primary_pid) if primary_pid else None
        # Away-team assets — first performer in array that's NOT the home
        # team. Null when array has only the primary (playoff placeholders).
        away_pid: int | None = None
        for raw_pid in (ev.get("performer_ids") or []):
            try:
                pid_int = int(raw_pid)
            except (TypeError, ValueError):
                continue
            if primary_pid is not None and pid_int == primary_pid:
                continue
            away_pid = pid_int
            break
        away_assets = perf_assets.get(away_pid) if away_pid else None

        try:
            rm = float(lem.get("retail_min")) if lem.get("retail_min") is not None else None
        except (TypeError, ValueError):
            rm = None

        # Signal classification — premium only (price >= $500). The
        # selling_fast / demand_rising signals require velocity data and
        # live on /api/store/movers instead (see NOTE above).
        signal: str | None = "premium" if (rm is not None and rm >= 500.0) else None

        cards.append({
            "id": eid,
            "name": ev.get("name"),
            "occurs_at_local": ev.get("occurs_at_local"),
            "venue_name": ev.get("venue_name"),
            "venue_location": ev.get("venue_location"),
            "primary_performer_name": ev.get("primary_performer_name"),
            "primary_performer_id": perf_id,
            "primary_performer_logo": (assets or {}).get("logo_default_url"),
            "primary_performer_color": (assets or {}).get("color_primary"),
            "primary_performer_league": (assets or {}).get("espn_league"),
            # Away-team assets — 2026-05-19: populate where available.
            # Null fields when no away performer or no metadata.
            "away_performer_id":    away_pid,
            "away_performer_name":  (away_assets or {}).get("name"),
            "away_performer_logo":  (away_assets or {}).get("logo_default_url"),
            "away_performer_color": (away_assets or {}).get("color_primary"),
            # Available_count is filled from TEvo's per-event count on the
            # detail page; the matview's tickets_count is the storefront-
            # wide listing count which is the better cards-level signal.
            "available_count": lem.get("tickets_count"),
            "we_own": True,
            # tbd derived from event-name string (no SQL column for this).
            "tbd": _is_tbd(ev.get("name")),
            # Enrichment that catalog endpoint leaves null — the whole point.
            "from_price": rm,
            "retail_median": lem.get("retail_median"),
            "owned_tickets_count": lem.get("owned_tickets_count"),
            "owned_groups_count": lem.get("owned_groups_count"),
            "captured_at": lem.get("captured_at"),
            # Velocity fields kept in the schema for renderer compatibility
            # but always null here — populated by /api/store/movers on the
            # separate strip. Avoids a JS-side schema break.
            "tix_d24h": None,
            "getin_d24h_pct": None,
            "signal": signal,
            # Other badge enrichments (rivalry/series/weather/holiday/playoff)
            # stay null here — re-layer in a follow-up PR if/when we want them
            # on the home grid. The detail page already renders all of these.
            "rivalry": None,
            "mlb_series": None,
            "tournament": None,
            "weather": None,
            "holiday": None,
            "playoff": None,
        })

    # Curation sort: premium first, then by date asc.
    def _home_sort_key(c):
        rank = 0 if c.get("signal") == "premium" else 1
        return (rank, c.get("occurs_at_local") or "9999")

    cards.sort(key=_home_sort_key)
    cards = cards[:cap]

    return {
        "count": len(cards),
        "events": cards,
        "limit": cap,
        "city": city_norm or None,
        "source": "sql",
    }


@app.get("/api/store/events/near")
def store_events_near(
    lat: float,
    lon: float,
    within: float = 50.0,       # miles
    limit: int = 10,
    source: str = "hybrid",     # 'hybrid' | 'supabase' | 'tevo'
):
    """Owned-inventory events sorted by distance from (lat, lon).

    Implements evo-docs §05 ("Displaying Events Near Your Users"). Three
    modes selectable via `?source=`:

    1. **hybrid** (default) — TEvo's `/v9/events?lat&lon&within` provides
       authoritative geo filtering (100% venue coverage). We then intersect
       the result with our `latest_event_metrics WHERE owned_tickets_count
       > 0` and apply `event_lifecycle.is_active`. Best of both: TEvo's
       geo authority + our owned/lifecycle filtering.

    2. **supabase** — pure local: read our owned+active set, join
       `venue_assets` for lat/lon (83% coverage), compute Python haversine,
       filter by within. Faster (no TEvo round-trip), zero TEvo quota,
       but caps coverage at venues we've geocoded.

    3. **tevo** — raw TEvo geo result, no owned filter. Useful for
       comparison/debug only; the storefront wall says we never show
       inventory we don't own, so this mode is debug-only and excluded
       from the consumer UI.

    Distance display uses our `venue_assets` coords for both hybrid and
    supabase modes (TEvo's events response doesn't include lat/lon on
    the venue object). Events with no coord yield `distance_miles: null`
    and sort to the end.
    """
    within = max(1.0, min(within, 500.0))
    cap = max(1, min(limit, 50))

    # SQL-only mode: force supabase mode regardless of ?source=. No TEvo
    # calls on the home page during demo testing.
    if STOREFRONT_SQL_ONLY:
        source = "supabase"

    if source == "tevo":
        # No Supabase needed for debug mode — straight passthrough.
        # Debug mode: raw TEvo geo, NO owned filter. Returns whatever TEvo
        # has nearby. Not used by the consumer UI.
        try:
            tevo_resp = client.list_events(
                lat=lat, lon=lon, within=within,
                only_with_available_tickets=True,
                order_by="events.occurs_at ASC",
                per_page=min(cap, 100),
            )
        except RuntimeError as e:
            print(f"[store_events_near] TEvo geo lookup failed: {e!r}")
            raise HTTPException(502, "geo lookup failed")
        evs = tevo_resp.get("events") or []
        return {
            "count": len(evs),
            "events": [
                {
                    "id": e.get("id"),
                    "name": e.get("name"),
                    "occurs_at_local": e.get("occurs_at_local"),
                    "venue_name": (e.get("venue") or {}).get("name"),
                    "venue_location": (e.get("venue") or {}).get("location"),
                    "distance_miles": None,
                }
                for e in evs
            ],
            "user_lat": lat, "user_lon": lon, "within_miles": within,
            "source": "tevo",
        }

    db = require_sb()

    if source == "hybrid":
        # Step 1: TEvo geo query for events near (lat, lon) with available
        # marketplace tickets. Authoritative venue coords; per_page is
        # capped at 100 by TEvo so we take all of them as candidates.
        try:
            tevo_resp = client.list_events(
                lat=lat, lon=lon, within=within,
                only_with_available_tickets=True,
                order_by="events.occurs_at ASC",
                per_page=100,
            )
        except RuntimeError as e:
            # On TEvo failure, fall through to supabase mode rather than
            # 502'ing the home page. Logged for observability.
            print(f"near (hybrid): TEvo failed, falling back to supabase: {e}")
            source = "supabase"
        else:
            candidate_ids = [int(e["id"]) for e in (tevo_resp.get("events") or []) if e.get("id")]
            decorated = _attach_owned_metadata(db, candidate_ids, lat, lon)
            decorated.sort(key=lambda x: (x["distance_miles"] is None, x["distance_miles"] or 1e9))
            return {
                "count": len(decorated[:cap]),
                "events": decorated[:cap],
                "user_lat": lat, "user_lon": lon, "within_miles": within,
                "total_within_radius": len(decorated),
                "tevo_candidates": len(candidate_ids),
                "source": "hybrid",
            }

    # source == "supabase" (or hybrid fallback)
    # Pull all owned event ids; _attach_owned_metadata does its own join
    # via the two-query merge pattern. (No `events!inner(...)` here either
    # — PostgREST view→table FK inference is flaky after cache rebuilds.)
    rows = (
        db.table("latest_event_metrics")
        .select("event_id")
        .gt("owned_tickets_count", 0)
        .limit(500)
        .execute().data
    ) or []
    candidate_ids = [int(r["event_id"]) for r in rows if r.get("event_id")]
    decorated = _attach_owned_metadata(db, candidate_ids, lat, lon)
    # Drop events outside the radius (or missing coords entirely).
    in_radius = [d for d in decorated
                 if d["distance_miles"] is not None and d["distance_miles"] <= within]
    in_radius.sort(key=lambda x: x["distance_miles"])
    return {
        "count": len(in_radius[:cap]),
        "events": in_radius[:cap],
        "user_lat": lat, "user_lon": lon, "within_miles": within,
        "total_within_radius": len(in_radius),
        "supabase_candidates": len(rows),
        "missing_coords": sum(1 for d in decorated if d["distance_miles"] is None),
        "source": "supabase",
    }


@app.get("/api/store/performers/{performer_id}/trip-plan")
def store_performer_trip_plan(
    performer_id: int,
    home_lat: float,
    home_lon: float,
    budget_km: float = 6000.0,
    home_name: str = "Home",
    days: int = 365,
    max_events: int | None = None,
    budget_usd: float | None = None,
    qty: int = 1,
):
    """D1 store: 'plan a trip around <performer>'.

    Consumer-facing. Given a fan's home location + how far they're willing to travel
    (and optionally a ticket-spend budget + tickets/show), returns the best set of this
    performer's upcoming shows to attend, alongside the naive sort-by-date plan.

    Shares the optimizer with the D0 broker route via `trip_planner`.
    """
    return _trip_plan_payload(performer_id, home_lat, home_lon, budget_km,
                              home_name, days, max_events, budget_usd, qty)


@app.get("/api/store/performers/{performer_id}/tour-package")
def store_performer_tour_package(
    performer_id: int,
    home_lat: float,
    home_lon: float,
    qty: int = 3,
    budget_km: float = 8000.0,
    home_name: str = "Home",
    days: int = 365,
    budget_usd: float | None = None,
    side: str = "auto",
    clear_at: float = 0.15,
    away_margin: float = 0.18,
    section_like: str | None = None,
    prefer_owned: bool = False,
):
    """D1 store: retail 'tour with the artist' agent. Builds a routed multi-city package and
    prices it — owned-splits where we hold inventory (concerts), market-sourced for a team's
    away games. Shares the engine with the D0 route via `trip_planner`."""
    return _tour_package_payload(performer_id, home_lat, home_lon, qty, budget_km, home_name,
                                 days, budget_usd, side, clear_at, away_margin,
                                 section_like, prefer_owned)


@app.get("/api/store/tours/multi")
def store_multi_tour(
    performer_ids: str,
    home_lat: float,
    home_lon: float,
    qty: int = 3,
    budget_km: float = 10000.0,
    home_name: str = "Home",
    days: int = 365,
    budget_usd: float | None = None,
    side: str = "auto",
    clear_at: float = 0.15,
    away_margin: float = 0.18,
    section_like: str | None = None,
    prefer_owned: bool = False,
):
    """D1 store 'plan my summer' — one routed+priced package across several performers
    (comma-separated `performer_ids`, up to 8). Shares the engine with the D0 route."""
    return _multi_tour_payload(performer_ids, home_lat, home_lon, qty, budget_km, home_name,
                               days, budget_usd, side, clear_at, away_margin,
                               section_like, prefer_owned)


@app.get("/api/store/tours/near")
def store_tours_near(
    home_lat: float,
    home_lon: float,
    within_mi: float = 250.0,
    days: int = 120,
    min_shows: int = 2,
    concerts_only: bool = False,
):
    """D1 store reverse discovery — 'what tours can I catch near me'. Performers with
    >= min_shows within `within_mi` of home in the window, with price-from + demand."""
    return _discover_payload(home_lat, home_lon, within_mi, days, min_shows, concerts_only)


def _section_sort_key(s: str) -> tuple:
    """Sort key for venue sections. Letters before digits (Floor, Courtside,
    GA come before 100, 101, etc.); within each group, natural-numeric for
    digits and case-insensitive alpha for letters. Mixed strings (e.g. "100A")
    sort with the numeric group by their leading digits."""
    s = (s or "").strip()
    if not s:
        return (2, "")
    if s[0].isalpha():
        return (0, s.lower())
    # Numeric or mixed (digit-leading) — extract leading digits for natural sort.
    digits = ""
    for ch in s:
        if ch.isdigit():
            digits += ch
        else:
            break
    return (1, int(digits) if digits else 0, s.lower())


def _csv(v: str | None) -> list[str]:
    return [s.strip() for s in (v or "").split(",") if s.strip()]


def _build_zone_resolver(performer_id: int | None, venue_id: int | None):
    """Return a fn (section, row) -> zone_name | None for this performer+venue.

    Calls match_performer_zone() once per unique (section, row) pair encountered.
    Cached within a single request so 100 listings across ~30 unique pairs cost
    ~30 RPCs at most. Returns a no-op resolver if (performer_id, venue_id) are
    missing or Supabase is offline."""
    if sb is None or not performer_id or not venue_id:
        return lambda section, row: None
    cache: dict[tuple[str, str], str | None] = {}

    def resolve(section, row):
        key = (str(section or ""), str(row or ""))
        if key in cache:
            return cache[key]
        try:
            res = sb.rpc(
                "match_performer_zone",
                {
                    "p_performer_id": performer_id,
                    "p_venue_id": venue_id,
                    "p_section": section or "",
                    "p_row": row or "",
                },
            ).execute()
            cache[key] = res.data if isinstance(res.data, str) else None
        except Exception:
            cache[key] = None
        return cache[key]

    return resolve


def _normalize_filters(raw: dict | None) -> dict:
    """Coerce a free-form filter dict (URL params or share_links.filters JSON)
    into the canonical shape the resolver expects. Drops empty values."""
    raw = raw or {}
    def _maybe_csv(v):
        if v is None:
            return []
        if isinstance(v, list):
            return [str(x).strip() for x in v if str(x).strip()]
        return _csv(str(v))
    def _maybe_num(v):
        if v is None or v == "":
            return None
        try:
            return float(v)
        except (TypeError, ValueError):
            return None
    def _maybe_int(v):
        if v is None or v == "":
            return None
        try:
            return int(v)
        except (TypeError, ValueError):
            return None
    return {
        "section": _maybe_csv(raw.get("section")),
        "zones": _maybe_csv(raw.get("zones")),
        "min_price": _maybe_num(raw.get("min_price")),
        "max_price": _maybe_num(raw.get("max_price")),
        "min_qty": _maybe_int(raw.get("min_qty")),
    }


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
            print(f"canonical refresh: events lookup failed for {event_id}: {e}")
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
            print(f"auto-track: event {event_id} has no primary performer; skipping")
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
                print(f"auto-track: added performer {pid} ({pname}) to watchlist as id={watchlist_id}")
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
                    print(f"auto-track: lookup after dup failed: {e2}")
            else:
                print(f"auto-track: watchlist insert failed for performer {pid}: {e}")

        if watchlist_id:
            url = f"{SUPABASE_URL}/functions/v1/collect-listings?watchlist_id={watchlist_id}"
            _fire_collect(url, CRON_SECRET)

    threading.Thread(target=_go, daemon=True).start()


def _fetch_event_from_db(event_id: int) -> dict:
    """SQL-only mode: synthesize the TEvo /v9/events/{id} response shape
    from our local `events` table so the storefront can render without a
    live TEvo call. Configuration (seating chart) is TEvo-only data we
    don't mirror, so it comes back empty — UI hides the image.
    """
    db = require_sb()
    row = (
        db.table("events")
        .select("id,name,occurs_at_local,state,venue_id,venue_name,venue_location,"
                "primary_performer_id,primary_performer_name,performer_ids")
        .eq("id", event_id)
        .limit(1)
        .execute().data
    )
    if not row:
        raise HTTPException(404, f"event {event_id} not found in local snapshot")
    e = row[0]
    # Build the performances list: primary first, then secondaries (names
    # resolved via a second lookup so we don't return bare ids).
    perfs: list[dict] = []
    if e.get("primary_performer_id"):
        perfs.append({
            "performer": {
                "id": e["primary_performer_id"],
                "name": e.get("primary_performer_name"),
            },
            "primary": True,
        })
    other_ids = [int(p) for p in (e.get("performer_ids") or [])
                 if int(p) != int(e.get("primary_performer_id") or 0)]
    if other_ids:
        # Look up names from performer_metadata (covers all ~56k performers),
        # not from events.primary_performer_name (only covers performers who
        # have been primary in some event). NBA playoff games carry "series"
        # performer IDs that never appear as primary — those would render as
        # "null" in the UI without this. We drop any performer we still can't
        # name as a defensive belt-and-suspenders.
        names = (
            db.table("performer_metadata")
            .select("performer_id,name")
            .in_("performer_id", other_ids)
            .execute().data
        ) or []
        name_map = {int(r["performer_id"]): r.get("name")
                    for r in names if r.get("performer_id") and r.get("name")}
        for pid in other_ids:
            nm = name_map.get(int(pid))
            if not nm:
                # Unnamed — likely a TEvo-internal "series" tag (e.g. the
                # conference label on a playoff game). Skip.
                continue
            perfs.append({
                "performer": {"id": pid, "name": nm},
                "primary": False,
            })
    return {
        "id": e["id"],
        "name": e.get("name"),
        "occurs_at_local": e.get("occurs_at_local"),
        # occurs_at not stored — UI uses occurs_at_local exclusively, so this
        # is fine. Synthesized to match the TEvo shape.
        "occurs_at": e.get("occurs_at_local"),
        "state": e.get("state"),
        "venue": {
            "id": e.get("venue_id"),
            "name": e.get("venue_name"),
            "location": e.get("venue_location"),
            "time_zone": None,
        },
        "configuration": {},   # TEvo-only; UI gracefully renders without
        "performances": perfs,
    }


def _fetch_owned_ticket_groups_from_db(event_id: int) -> tuple[list[dict], str, str | None]:
    """SQL-only mode: pull the latest snapshot of owned ticket_groups for
    an event from `listings_snapshots` and shape rows like TEvo's response.
    Returns (groups, source, captured_at_iso). source is always 'snapshot'.
    """
    db = require_sb()
    # Latest captured_at for this event — single round-trip.
    latest = (
        db.table("listings_snapshots")
        .select("captured_at")
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(1)
        .execute().data
    )
    if not latest:
        return [], "snapshot", None
    captured_at = latest[0]["captured_at"]
    rows = (
        db.table("listings_snapshots")
        .select("tevo_ticket_group_id,section,row,quantity,retail_price,format,splits,"
                "wheelchair,instant_delivery,eticket,is_ancillary,type,is_owned")
        .eq("event_id", event_id)
        .eq("captured_at", captured_at)
        .eq("is_owned", True)
        .execute().data
    ) or []
    groups = []
    for r in rows:
        # Shape like TEvo's /v9/ticket_groups response so the existing
        # filter + render pipeline works unchanged.
        groups.append({
            "id": r.get("tevo_ticket_group_id"),
            "type": r.get("type") or "event",
            "section": r.get("section"),
            "row": r.get("row"),
            "quantity": r.get("quantity"),
            "available_quantity": r.get("quantity"),
            "retail_price": r.get("retail_price"),
            "format": r.get("format"),
            "splits": r.get("splits") or [],
            "wheelchair": r.get("wheelchair"),
            "instant_delivery": r.get("instant_delivery"),
            "eticket": r.get("eticket"),
            "in_hand": True,        # snapshot doesn't track this; assume yes
            "in_hand_on": None,
            "public_notes": None,    # not mirrored to listings_snapshots
        })
    return groups, "snapshot", captured_at


def _fetch_owned_ticket_groups(
    event_id: int,
    max_age_seconds: int | None = None,
) -> tuple[list[dict], str]:
    """Pull owned-only ticket_groups for an event. Returns (groups, source)
    where source is 'cache' (≤max_age) or 'live'.

    Cache strategy:
    - Read: gated on `max_age_seconds`. Storefront passes ~10 to keep retail
      pages near-real-time; broker terminal passes None (uses the row's own
      90s expires_at). This lets one cache table serve both consumers with
      different freshness contracts.
    - Write: always 90s TTL so the broker terminal still gets long-lived
      data after a storefront refresh.

    Note: cache key is event_id only; owned=true is implied for both
    storefront and broker call sites that hit this helper.
    """
    if sb is not None:
        try:
            cached = sb.rpc("get_cached_ticket_groups", {"p_event_id": event_id}).execute().data
            if cached:
                payload_age_ok = True
                if max_age_seconds is not None:
                    captured_at_str = (cached or {}).get("captured_at")
                    if captured_at_str:
                        try:
                            captured_at = datetime.fromisoformat(
                                str(captured_at_str).replace("Z", "+00:00")
                            )
                            age = (datetime.now(timezone.utc) - captured_at).total_seconds()
                            payload_age_ok = age <= max_age_seconds
                        except (ValueError, TypeError):
                            payload_age_ok = False
                    else:
                        payload_age_ok = False
                if payload_age_ok:
                    return (cached or {}).get("ticket_groups", []) or [], "cache"
        except Exception:
            # Cache failure must never block the page; fall through to live.
            pass
    try:
        live = client.get_ticket_groups(event_id, owned=True)
    except RuntimeError as e:
        print(f"[ticket_groups] TEvo ticket_groups failed for {event_id}: {e!r}")
        raise HTTPException(502, "ticket listings fetch failed")
    groups = live.get("ticket_groups", []) or []
    if sb is not None:
        try:
            sb.rpc("put_cached_ticket_groups", {
                "p_event_id": event_id,
                "p_payload": {
                    "ticket_groups": groups,
                    "captured_at": datetime.now(timezone.utc).isoformat(),
                },
                "p_ttl_seconds": 90,
            }).execute()
        except Exception:
            pass
    return groups, "live"


# Map an EvoClient RuntimeError to a semantically correct HTTP status.
# evo_client raises RuntimeError("TEvo API returned <code>") for a non-2xx
# upstream response, or "TEvo API returned no response" for a connection/
# timeout/DNS failure. A 400/404 from TEvo means the event id doesn't
# resolve → that's a client-facing 404 (Not Found), NOT a gateway error.
# Everything else (5xx, no-response) is a genuine upstream failure → 502;
# 429/503 surface as 503 so callers/crawlers back off ("try again") rather
# than treating it as a hard gateway break. Never echoes upstream body/URL —
# only the mapped status + a caller-supplied generic detail reach the client
# (the evo_client already scrubbed everything but the status into the message).
_TEVO_STATUS_RE = re.compile(r"\b(\d{3})\b")


def _tevo_runtime_to_http(
    e: Exception, *, not_found_detail: str, failure_detail: str
) -> HTTPException:
    m = _TEVO_STATUS_RE.search(str(e))
    upstream = int(m.group(1)) if m else None
    if upstream in (400, 404):
        return HTTPException(404, not_found_detail)
    if upstream in (429, 503):
        return HTTPException(503, failure_detail)
    return HTTPException(502, failure_detail)


def _resolve_event_with_filters(event_id: int, filters: dict, include_inactive: bool = False) -> dict:
    """Fetch event + owned listings, apply filters, return the same shape
    /api/store/events/{id} returns. Shared by the public detail endpoint
    and the share-link resolver.

    SQL-only mode (STOREFRONT_SQL_ONLY=true): reads from `events` +
    `listings_snapshots` instead of TEvo. Same response shape so the UI
    is unchanged. inventory_source reflects 'snapshot' + adds
    snapshot_age_seconds so the demo banner can show staleness honestly.

    MVP prod checkpoint (2026-05-13): the SQL `event_lifecycle` gate was
    removed. Rationale: the catalog now filters by office_id at TEvo, so
    only events our office has inventory for ever surface. The gate was
    a defensive measure against ghost playoff rows + cancelled-but-still-
    listed games; with office_id, those edge cases are rare AND the
    broker terminal is the right place to manage stale listings, not the
    public detail page. Lifting the gate also fixes a real inconsistency
    where catalog showed a TBD playoff game (TEvo had inventory) but
    detail 404'd (audit SQL had marked it 'completed' when the series
    ended without that game). Set include_inactive=true is now a no-op
    kept for callsite compatibility.
    """
    snapshot_captured_at: str | None = None
    if STOREFRONT_SQL_ONLY:
        ev = _fetch_event_from_db(event_id)
        groups, tg_source, snapshot_captured_at = _fetch_owned_ticket_groups_from_db(event_id)
    else:
        try:
            ev = client.get_event(event_id)
        except RuntimeError as e:
            # Log full upstream error server-side; return a stable generic
            # string so TEvo's response text + upstream status codes never
            # reach the public detail page. Mirrors the /api/store/events
            # 502 scrub at line ~4194. Status is normalized: a 400/404 from
            # TEvo means the event doesn't exist → 404 (not a 502 gateway
            # error, which previously made cycling-id scans + dead share
            # links look like outages); 5xx/timeout → 502, 429/503 → 503.
            print(f"[store_event_detail] TEvo event lookup failed for {event_id}: {e!r}")
            raise _tevo_runtime_to_http(
                e,
                not_found_detail="event not found",
                failure_detail="event lookup failed",
            ) from e

        # Storefront freshness contract: 10s. Tighter than broker's 90s because
        # this is the buy-decision page — stale availability => bad UX.
        groups, tg_source = _fetch_owned_ticket_groups(event_id, max_age_seconds=10)

    eligible = [
        tg
        for tg in groups
        if (tg.get("type") or "event").lower() == "event"
        and (tg.get("available_quantity") or tg.get("quantity") or 0) > 0
    ]
    total_before_filters = len(eligible)

    # Parking inventory — TEvo splits seats vs parking via the type field.
    # We surface parking on a separate tab so its prices don't pollute
    # from_price / min-price filters / seat zone+section filters. Cap
    # display at $5K so a known-bad parking outlier (max retail $994K
    # observed in raw data, clearly a mis-priced parking pass) doesn't
    # blow up the tab.
    parking_groups = [
        tg
        for tg in groups
        if (tg.get("type") or "").lower() == "parking"
        and (tg.get("available_quantity") or tg.get("quantity") or 0) > 0
        and float(tg.get("retail_price") or 0) <= 5000
    ]
    parking_groups.sort(key=lambda tg: float(tg.get("retail_price") or 1e12))

    venue = ev.get("venue") or {}
    performances = ev.get("performances") or []
    primary_perf = next(
        ((p.get("performer") or {}) for p in performances if p.get("primary")),
        ((performances[0].get("performer") or {}) if performances else {}),
    )
    perf_id = primary_perf.get("id")
    venue_id = venue.get("id")

    f = _normalize_filters(filters)

    # Capture the full section universe BEFORE applying any section filter
    # so the UI can render section chips that don't disappear when the user
    # narrows the listings. Letter-prefixed sections (Floor, Courtside, GA,
    # etc.) sort BEFORE numeric sections per the StubHub/SeatGeek convention;
    # numeric sections sort naturally (1, 2, 10, 100 — not lex-order).
    sections_available = sorted(
        {str(tg.get("section") or "").strip()
         for tg in eligible if tg.get("section")},
        key=_section_sort_key,
    )

    # Distinct quantities the seller offers across the unfiltered listing
    # set. UI uses this to build the min-qty dropdown so we don't offer
    # "any" when nothing sells in singles, or "4+" when no listing has a
    # split ≥ 4. Pre-min_qty-filter so the dropdown stays useful as the
    # user narrows.
    splits_available = sorted({
        int(s) for tg in eligible for s in (tg.get("splits") or [])
        if (isinstance(s, int) or str(s).isdigit())
    })

    section_set = {s.lower() for s in f["section"]}
    if section_set:
        eligible = [tg for tg in eligible if str(tg.get("section") or "").lower() in section_set]

    if f["min_price"] is not None:
        eligible = [tg for tg in eligible if float(tg.get("retail_price") or 0) >= f["min_price"]]
    if f["max_price"] is not None:
        eligible = [tg for tg in eligible if float(tg.get("retail_price") or 0) <= f["max_price"]]

    if f["min_qty"] is not None and f["min_qty"] > 0:
        target = f["min_qty"]
        def _meets(tg):
            splits = tg.get("splits") or []
            avail = int(tg.get("available_quantity") or tg.get("quantity") or 0)
            if splits:
                return any(s >= target for s in splits)
            return avail >= target
        eligible = [tg for tg in eligible if _meets(tg)]

    zone_set = {z.lower() for z in f["zones"]}
    listings_with_zone: list[tuple[dict, str | None]]
    if zone_set:
        resolver = _build_zone_resolver(perf_id, venue_id)
        kept: list[tuple[dict, str | None]] = []
        for tg in eligible:
            z = resolver(tg.get("section"), tg.get("row"))
            if z and z.lower() in zone_set:
                kept.append((tg, z))
        listings_with_zone = kept
    else:
        listings_with_zone = [(tg, None) for tg in eligible]

    listings_with_zone.sort(key=lambda x: float(x[0].get("retail_price") or 1e12))

    listings = []
    for tg, zone in listings_with_zone:
        item = _ticket_group_to_listing(tg)
        if zone:
            item["zone"] = zone
        listings.append(item)

    config = ev.get("configuration") or {}
    seating = (config.get("seating_chart") or {})

    # Bulk-attach branded assets (logo / colors) for the performers on
    # this event. performer_metadata is populated by the audit lane's ESPN
    # ingest — we read only. Falls through gracefully when a performer has
    # no asset row yet (most non-MLB/NBA/NFL/NHL teams don't).
    perf_assets: dict[int, dict] = {}
    if sb is not None:
        try:
            perf_ids = [int((p.get("performer") or {}).get("id"))
                        for p in performances
                        if (p.get("performer") or {}).get("id")]
            if perf_ids:
                perf_assets = _bulk_performer_assets(sb, perf_ids)
        except Exception:
            perf_assets = {}

    def _attach_assets(p):
        perf = p.get("performer") or {}
        pid = perf.get("id")
        a = perf_assets.get(int(pid)) if pid else None
        return {
            "id": pid,
            "name": perf.get("name"),
            "primary": p.get("primary"),
            "logo_url": (a or {}).get("logo_default_url"),
            "color_primary": (a or {}).get("color_primary"),
        }

    # Snapshot age (SQL-only mode only) — UI uses this to show honest staleness.
    snapshot_age_seconds: int | None = None
    if snapshot_captured_at:
        try:
            ts = datetime.fromisoformat(str(snapshot_captured_at).replace("Z", "+00:00"))
            snapshot_age_seconds = int((datetime.now(timezone.utc) - ts).total_seconds())
        except (ValueError, TypeError):
            snapshot_age_seconds = None

    # Pull asset bundle from v_event_seating_chart — audit-lane-maintained
    # view that joins events × configurations × venue_assets × performer
    # metadata into one row per event. Single round-trip, single source of
    # truth. Includes TEvo seating chart URLs (configurations.static_maps)
    # AND fanvenues_key for dynamic interactive seatmaps. Silently degrades
    # to the minimal payload when the row is missing.
    asset_bundle: dict = {}
    if sb is not None and ev.get("id"):
        try:
            ab_rows = (
                sb.table("v_event_seating_chart")
                .select(
                    "configuration_id,configuration_name,seating_chart_medium,"
                    "seating_chart_large,fanvenues_key,venue_hero_url,venue_map_url,"
                    "venue_capacity,venue_is_indoor,team_color_primary,team_color_alternate,"
                    "team_logo_url,team_logo_dark_url,team_espn_url"
                )
                .eq("event_id", int(ev["id"]))
                .limit(1)
                .execute().data
            ) or []
            if ab_rows:
                asset_bundle = ab_rows[0]
        except Exception:
            asset_bundle = {}

    # Also pull venue coords from venue_assets (not exposed by the view —
    # used by the near-me feature, separate from the event page UX).
    venue_assets: dict = {}
    if sb is not None and venue.get("id"):
        try:
            va_rows = (
                sb.table("venue_assets")
                .select("latitude,longitude,city,state,country,"
                        "espn_venue_id,espn_venue_name")
                .eq("tevo_venue_id", int(venue["id"]))
                .limit(1)
                .execute().data
            ) or []
            if va_rows:
                venue_assets = va_rows[0]
        except Exception:
            venue_assets = {}

    response = {
        "event": {
            "id": ev.get("id"),
            "name": ev.get("name"),
            "occurs_at": ev.get("occurs_at"),
            "occurs_at_local": ev.get("occurs_at_local"),
            "venue": {
                "id": venue.get("id"),
                "name": venue.get("name"),
                "location": venue.get("location"),
                "time_zone": venue.get("time_zone"),
                # Audit-lane assets (v_event_seating_chart + venue_assets).
                # All optional — UI hides any field that's null.
                "hero_image_url": asset_bundle.get("venue_hero_url"),
                "venue_map_url": asset_bundle.get("venue_map_url"),
                "is_indoor": asset_bundle.get("venue_is_indoor"),
                "capacity": asset_bundle.get("venue_capacity"),
                "latitude": venue_assets.get("latitude"),
                "longitude": venue_assets.get("longitude"),
                "city": venue_assets.get("city"),
                "state": venue_assets.get("state"),
                "country": venue_assets.get("country"),
                "espn_venue_id": venue_assets.get("espn_venue_id"),
                "espn_venue_name": venue_assets.get("espn_venue_name"),
            },
            "configuration": {
                # Static seating chart from TEvo's /v9/configurations.
                # Both medium (~500px) and large (~1000px) URLs available;
                # UI defaults to medium and lazy-loads large on click.
                # SQL-only mode reads these from v_event_seating_chart; live
                # mode falls back to the inline config dict from TEvo's
                # /v9/events/:id response.
                "id": asset_bundle.get("configuration_id") or config.get("id"),
                "name": asset_bundle.get("configuration_name") or config.get("name"),
                # _clean_opt_url BEFORE the `or` so a sentinel "null" in
                # asset_bundle doesn't shadow a real URL from the live config.
                "seating_chart_medium": (
                    _clean_opt_url(asset_bundle.get("seating_chart_medium"))
                    or _clean_opt_url(seating.get("medium"))
                ),
                "seating_chart_large": (
                    _clean_opt_url(asset_bundle.get("seating_chart_large"))
                    or _clean_opt_url(seating.get("large"))
                ),
                # fanvenues_key — opaque ID for TEvo's seatmaps-client.js
                # interactive seat picker. Surfaced so a future enhancement
                # can mount the dynamic seatmap (today the UI uses the static
                # jpg). Per docs/api-08 §Seating Charts.
                "fanvenues_key": asset_bundle.get("fanvenues_key"),
            },
            # TEvo carries "series" performers alongside competing teams on
            # playoff games (e.g. "NBA Playoffs", "NBA Western Conference
            # Semifinals"). They show up in events.performer_ids and have rows
            # in performer_metadata, but with no logo / color / ESPN xref.
            # Drop them (non-primary only) so the header doesn't read
            # "Lakers (home) vs NBA Playoffs vs NBA Western Conference
            # Semifinals vs Thunder". Always keep the primary even when it
            # has minimal metadata (Peso Pluma etc. — would otherwise leave
            # a headliner-less event card).
            "performers": [
                p_meta for p_meta in (_attach_assets(p) for p in performances)
                if p_meta.get("primary")
                or p_meta.get("logo_url") or p_meta.get("color_primary")
            ],
        },
        "listings": listings,
        "listings_count": len(listings),
        # Parking is a separate tab on the event page (when present).
        # Stays out of sections_available / splits_available / from_price
        # so the seat-tab UX is unaffected by parking inventory.
        "parking_listings": [_ticket_group_to_listing(tg) for tg in parking_groups],
        "parking_count": len(parking_groups),
        "total_before_filters": total_before_filters,
        # All section names present in the unfiltered set so the UI can
        # render the section chip group without it collapsing as the user
        # narrows. Without this the chips disappear after one click and
        # multi-select feels broken.
        "sections_available": sections_available,
        # Distinct seller-offered quantities (union of splits arrays in the
        # unfiltered set). UI builds the min-qty dropdown from this so we
        # don't offer values no listing actually sells in.
        "splits_available": splits_available,
        "filters": f,
        # 'cache' (≤10s old, live mode) | 'live' (live mode) | 'snapshot' (SQL-only mode)
        "inventory_source": tg_source,
        "snapshot_age_seconds": snapshot_age_seconds,
        "demo_mode": STOREFRONT_SQL_ONLY,
    }

    # Context badges — rivalry / MLB series / tournament / weather / holiday
    # / playoff. All nullable; UI hides the badge when None. Single bulk
    # call to keep the per-detail roundtrip count low.
    _empty_ctx = {
        "rivalry": None, "mlb_series": None, "tournament": None,
        "weather": None, "holiday": None, "playoff": None,
    }
    if sb is not None:
        ctx_by_id = _bulk_event_context(sb, [event_id])
        response["context"] = ctx_by_id.get(event_id) or dict(_empty_ctx)
    else:
        response["context"] = dict(_empty_ctx)

    # Fire-and-forget: refresh canonical SQL via the audit-lane Edge Function.
    # Auto-tracks the event (adds performer to watchlist) if we've never seen
    # it before. Never blocks the response. SKIPPED in SQL-only mode — no
    # point firing a TEvo collector while we're trying to keep TEvo out.
    if not STOREFRONT_SQL_ONLY:
        _fire_canonical_refresh(event_id, ev)

    return response


@app.get("/api/store/events/{event_id}")
def store_event_detail(
    event_id: int,
    section: str | None = None,         # CSV of exact section names
    min_price: float | None = None,
    max_price: float | None = None,
    min_qty: int | None = None,
    zones: str | None = None,           # CSV of curated zone names (case-insensitive)
):
    """Event detail + live owned-only ticket groups from TEvo, with optional
    share-link filters applied server-side. Filters are AND-ed; an empty set of
    matches is a valid response (UI shows "no listings match")."""
    return _resolve_event_with_filters(
        event_id,
        {
            "section": section,
            "min_price": min_price,
            "max_price": max_price,
            "min_qty": min_qty,
            "zones": zones,
        },
    )


# Consumer-grade zone names match a programmatic bowl pattern:
# "{Lower|Club|Upper|Floor|...} (Xs)" — e.g. "Lower (100s)", "Upper (400s)".
# But many performer+venue pairs ALSO get venue-specific bowl additions like
# "Floor / Pit / GA" or "Special" that DON'T match this pattern yet are
# still part of the consumer seed (Lakers at Crypto.com Arena has 5 such
# zones total, none granular).
#
# A name regex alone misclassifies these. So we use a TWO-STEP heuristic:
#   1. Look at the PAIR (performer + venue) total zone count. NYK at MSG
#      has 26 zones (22 granular + 4 bowl) — well above the consumer-only
#      ceiling of ~5–7. Anything > 8 zones almost certainly has a granular
#      hand-curated layer.
#   2. Within a "has-granular" pair, classify each individual zone by name
#      regex (bowl-pattern → consumer, else granular).
_CONSUMER_ZONE_NAME_RE = re.compile(
    r"^(Lower|Club|Upper|Floor|Field|Mezzanine|Balcony|Loge|Terrace)\s*\(\d+s\)$",
    re.IGNORECASE,
)
# Threshold above which a pair almost certainly has hand-curated granular
# zones in addition to the consumer-bowl baseline. The seeded consumer
# baseline tops out at ~5–7 zones per pair empirically.
_GRANULAR_LAYER_ZONE_COUNT_THRESHOLD = 8


def _is_bowl_pattern_name(name: str | None) -> bool:
    """Whether a zone name matches the programmatic bowl-level pattern."""
    return bool(_CONSUMER_ZONE_NAME_RE.match((name or "").strip()))


@app.get("/api/store/events/{event_id}/zones")
def store_event_zones(event_id: int):
    """List curated zones with owned-ticket counts so the Share dialog can
    offer zone choices.

    Layer preference (per Julian's 2026-05-11 direction):
      1. If the event's performer+venue has any INTERNAL (granular) zones
         with matching owned tickets, return ONLY those. The granular
         taxonomy is hand-curated (NYK at MSG has 22 zones — Courtside,
         Club Platinum, etc.) and is the right shopper UX where available.
      2. Else fall back to CONSUMER (coarse bowl-level) zones — the
         "Lower (100s) / Club (200s) / Upper (300s) / Upper (400s)" set
         that's been programmatically seeded across ~30 venues.
      3. Else empty (most events outside the seeded set).

    Response includes `layer` so the UI can label the chip group
    appropriately if it ever wants to.
    """
    db = require_sb()
    try:
        rows = db.rpc(
            "get_event_zones_rollup",
            {"p_event_id": event_id, "p_owned_only": True},
        ).execute().data or []
    except Exception:
        rows = []
    # Only consider curated zones — fallback/unmapped names from
    # derive_zone_fallback() are noisy and not safe to share by name.
    curated = [r for r in rows if r.get("source") == "curated"]

    # Step 1: count the FULL zone universe for this event's performer+venue.
    # If it's larger than the consumer-only ceiling, we know the pair has
    # been hand-curated with granular zones layered on top of the bowl seed.
    pair_zone_count = 0
    try:
        ev_meta = (
            db.table("events").select("primary_performer_id,venue_id")
            .eq("id", event_id).limit(1).execute().data
        ) or []
        if ev_meta:
            perf_id = ev_meta[0].get("primary_performer_id")
            venue_id_x = ev_meta[0].get("venue_id")
            if perf_id and venue_id_x:
                pair_rows = (
                    db.table("performer_zones").select("id", count="exact")
                    .eq("performer_id", perf_id).eq("venue_id", venue_id_x)
                    .execute()
                )
                pair_zone_count = pair_rows.count or len(pair_rows.data or [])
    except Exception:
        pair_zone_count = 0

    has_granular_layer = pair_zone_count > _GRANULAR_LAYER_ZONE_COUNT_THRESHOLD

    # Step 2: pick the layer to surface. Off by default — granular taxonomy
    # has coverage gaps right now (NYK at MSG covers ~25 of 89 owned tickets
    # in section ranges with curated rules; the rest fall through). Once A1
    # closes those gaps, flip STOREFRONT_PREFER_INTERNAL_ZONES=true.
    if has_granular_layer and STOREFRONT_PREFER_INTERNAL_ZONES:
        # Granular layer exists AND we're configured to prefer it.
        chosen = [r for r in curated if not _is_bowl_pattern_name(r.get("zone"))]
        layer = "internal" if chosen else "none"
    else:
        # Default path — return whatever curated zones exist. For pairs with
        # both layers (NYK at MSG), this returns the bowl-level set since
        # match_performer_zone() now picks bowl-pattern names by display
        # order. For consumer-only pairs (most events), returns those.
        chosen = curated
        layer = "consumer" if chosen else "none"

    zones = [
        {
            "name": r.get("zone"),
            "tickets": r.get("tickets") or 0,
            "min_retail": r.get("min_retail"),
            "max_retail": r.get("max_retail"),
        }
        for r in chosen
    ]
    return {
        "event_id": event_id,
        "zones": zones,
        "layer": layer,
        "pair_zone_count": pair_zone_count,  # debug: # of zones for performer+venue
        "has_granular_available": has_granular_layer,  # UI can show a 'switch to expert view' toggle
        "prefer_internal_enabled": STOREFRONT_PREFER_INTERNAL_ZONES,
    }


@app.post("/api/store/reserve")
def store_reserve(payload: dict = Body(...), authorization: str | None = Header(None)):
    """MVP placeholder: a real checkout is not wired up yet. Validates that
    the requested ticket_group + quantity matches the live owned inventory in
    TEvo, then returns a mock confirmation. NEVER calls /v9/orders.

    Auth: gated by STOREFRONT_RESERVE_REQUIRES_AUTH env flag. MVP demo
    leaves it off so the front-end's "Reserve (mock)" button works without
    a Supabase session. Sprint 2 (real-purchase path) flips the flag on
    once the front-end attaches Authorization headers."""
    if STOREFRONT_RESERVE_REQUIRES_AUTH:
        require_auth(authorization)
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
            print(f"[store_reserve] TEvo ticket_groups failed for {event_id}: {e!r}")
            raise HTTPException(502, "ticket listings fetch failed")
        match = next(
            (tg for tg in (tg_resp.get("ticket_groups") or []) if int(tg.get("id") or 0) == ticket_group_id),
            None,
        )
        if not match:
            raise HTTPException(404, "ticket group is no longer available from this seller")

    avail = int(match.get("available_quantity") or match.get("quantity") or 0)
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


@app.api_route("/store", methods=["GET", "HEAD"])
def store_index_page():
    return _render_storefront_page("index.html")


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


def _share_to_dict(row: dict) -> dict:
    """Public-safe representation of a share_links row."""
    if not row:
        return {}
    revoked = row.get("revoked_at")
    expires = row.get("expires_at")
    expired = False
    if expires:
        try:
            expired = datetime.fromisoformat(str(expires).replace("Z", "+00:00")) <= datetime.now(timezone.utc)
        except ValueError:
            expired = False
    return {
        "id": row.get("id"),
        "url": f"/s/{row.get('id')}",
        "event_id": row.get("event_id"),
        "filters": row.get("filters") or {},
        "note": row.get("note"),
        "created_at": row.get("created_at"),
        "expires_at": expires,
        "revoked_at": revoked,
        "view_count": row.get("view_count") or 0,
        "last_viewed_at": row.get("last_viewed_at"),
        "active": (revoked is None) and (not expired),
    }


@app.post("/api/store/share")
def store_share_create(payload: dict = Body(...), user=Depends(require_auth)):
    """Create a revocable share link for one event with saved filters.

    Body:
      event_id: int (required)
      filters: { zones, section, min_price, max_price, min_qty } (optional)
      note: str (optional, ≤ 500 chars)
      expires_in_days: int (optional, 1-365; null = never expires)

    Auth: require_auth (Supabase JWT + allowed-domain email). Closed on
    2026-05-11 (security chat) — see SECURITY BACKLOG in KANBAN.md.
    """
    # Validate before touching Supabase so 4xx errors surface the real reason
    # instead of "Supabase not configured" when both are wrong.
    try:
        event_id = int(payload.get("event_id") or 0)
    except (TypeError, ValueError):
        raise HTTPException(400, "event_id must be an integer")
    if not event_id:
        raise HTTPException(400, "event_id is required")

    filters = _normalize_filters(payload.get("filters") or {})
    # Persist arrays only if non-empty + numeric values only if set, so the
    # JSON stays compact and equivalent to the URL form.
    persisted: dict = {}
    if filters["section"]: persisted["section"] = filters["section"]
    if filters["zones"]:   persisted["zones"]   = filters["zones"]
    if filters["min_price"] is not None: persisted["min_price"] = filters["min_price"]
    if filters["max_price"] is not None: persisted["max_price"] = filters["max_price"]
    if filters["min_qty"]   is not None: persisted["min_qty"]   = filters["min_qty"]

    note = (payload.get("note") or "").strip() or None
    if note and len(note) > 500:
        raise HTTPException(400, "note too long (max 500 chars)")

    # All validation passed — now we need Supabase to persist.
    db = require_sb()

    # Compute the auto-expiry ceiling: event_start + 1h. Past this point the
    # share is effectively useless (event has started + small buffer for
    # walk-up viewing), so we always cap expires_at here. User-chosen
    # expires_in_days narrows further; null/0/never == "use the cap".
    #
    # Default: cap. User explicit shorter days: min(user_days_date, cap).
    # Buffer is 1h chosen so a recipient opening the link AT tip-off still
    # sees the inventory; past +1h they get a 410 from /api/store/share/{id}.
    event_end_ceiling: datetime | None = None
    try:
        ev_row = (
            db.table("events")
            .select("occurs_at_local")
            .eq("id", event_id)
            .limit(1)
            .execute().data
        )
        if ev_row and ev_row[0].get("occurs_at_local"):
            ev_start = datetime.fromisoformat(
                str(ev_row[0]["occurs_at_local"]).replace("Z", "+00:00")
            )
            # `occurs_at_local` carries the real offset (it's stored as TZ-
            # qualified ISO), so the resulting datetime is timezone-aware.
            event_end_ceiling = ev_start + timedelta(hours=1)
    except Exception:
        event_end_ceiling = None  # No event row found — fall back to user-only.

    expires_at: str | None = None
    raw_days = payload.get("expires_in_days")
    user_pick: datetime | None = None
    if raw_days not in (None, "", 0):
        try:
            days = int(raw_days)
        except (TypeError, ValueError):
            raise HTTPException(400, "expires_in_days must be an integer")
        if not (1 <= days <= 365):
            raise HTTPException(400, "expires_in_days must be between 1 and 365")
        user_pick = datetime.now(timezone.utc) + timedelta(days=days)

    # Pick the tighter of (user choice, event-end ceiling). When the event
    # is unknown, fall back to the user choice. When neither is set the
    # share never expires (legacy behavior preserved).
    if user_pick and event_end_ceiling:
        chosen = min(user_pick, event_end_ceiling)
    else:
        chosen = user_pick or event_end_ceiling
    if chosen:
        expires_at = chosen.astimezone(timezone.utc).isoformat()

    # Populate created_by so DELETE + LIST routes can enforce ownership
    # (closed 2026-05-16 audit S1/S2 — any authed user used to be able to
    # revoke/enumerate ANY share link by id). When AUTH_DISABLED=true (dev),
    # require_auth returns None — store NULL and the ownership filters in
    # those routes correctly skip in that mode.
    created_by = user["id"] if user else None

    # ~12 chars (9 random bytes → 12 url-safe chars) ≈ 72 bits of entropy.
    # Retry once on the astronomically unlikely collision.
    share_id = secrets.token_urlsafe(9)
    row = {
        "id": share_id,
        "event_id": event_id,
        "filters": persisted,
        "note": note,
        "expires_at": expires_at,
        "created_by": created_by,
    }
    try:
        ins = db.table("share_links").insert(row).execute()
    except Exception as e:
        # Pretty much always a primary-key collision; one retry is enough.
        share_id = secrets.token_urlsafe(9)
        row["id"] = share_id
        try:
            ins = db.table("share_links").insert(row).execute()
        except Exception as e2:
            # Sanitized: log full upstream error server-side, return a stable
            # generic string so Supabase exception text (table/constraint
            # names, internal validation) doesn't leak to public callers.
            # Audit S4 2026-05-16.
            print(f"[store_share_create] share insert failed twice for {share_id}: {e2!r}")
            raise HTTPException(500, "could not create share link") from e

    saved = (ins.data or [None])[0] or row
    return _share_to_dict(saved)


@app.get("/api/store/share/{share_id}")
def store_share_resolve(share_id: str):
    """Public endpoint: resolves a share link to its filtered event payload.
    Bumps view_count on every successful read. 410 if revoked or expired."""
    db = require_sb()
    res = (
        db.table("share_links")
        .select("id,event_id,filters,note,created_at,expires_at,revoked_at,view_count,last_viewed_at")
        .eq("id", share_id)
        .limit(1)
        .execute()
    )
    rows = res.data or []
    if not rows:
        raise HTTPException(404, "share link not found")
    row = rows[0]

    if row.get("revoked_at"):
        raise HTTPException(410, "this share link has been revoked")
    expires = row.get("expires_at")
    if expires:
        try:
            if datetime.fromisoformat(str(expires).replace("Z", "+00:00")) <= datetime.now(timezone.utc):
                raise HTTPException(410, "this share link has expired")
        except ValueError:
            pass  # Bad timestamp shouldn't 500 the recipient

    detail = _resolve_event_with_filters(int(row["event_id"]), row.get("filters") or {})

    # View tracking — best-effort; a tracking failure shouldn't break the page.
    try:
        db.rpc("bump_share_view", {"p_id": share_id}).execute()
    except Exception:
        pass

    return {
        "share": _share_to_dict(row),
        **detail,
    }


@app.delete("/api/store/share/{share_id}")
def store_share_revoke(share_id: str, user=Depends(require_auth)):
    """Soft-delete: stamps revoked_at. The row stays so view history survives.
    Idempotent — revoking an already-revoked link is fine.

    Auth: require_auth. Closed on 2026-05-11 (security chat) — any unauth
    user used to be able to revoke any share link by id.

    Ownership: closed 2026-05-16 (audit S1) — auth was checked but not
    ownership, so any authed user could revoke ANY share link by id. Now
    the update is filtered by created_by = current_user.id. When
    AUTH_DISABLED=true (dev), require_auth returns None and we skip the
    ownership filter (matches the rest of the auth-disabled pattern).
    """
    db = require_sb()
    q = (
        db.table("share_links")
        .update({"revoked_at": datetime.now(timezone.utc).isoformat()})
        .eq("id", share_id)
    )
    if user is not None:
        q = q.eq("created_by", user["id"])
    res = q.execute()
    if not (res.data or []):
        # Could be: row doesn't exist, OR row exists but user doesn't own it.
        # Either way, surface as 404 (don't leak existence to non-owner).
        raise HTTPException(404, "share link not found")
    return {"ok": True, "id": share_id, "revoked_at": (res.data[0] or {}).get("revoked_at")}


@app.get("/api/store/shares")
def store_share_list(
    event_id: int | None = None,
    include_inactive: bool = False,
    limit: int = 50,
    user=Depends(require_auth),
):
    """List share links, newest first. Filter by event_id when present.

    Auth: require_auth. Closed on 2026-05-11 (security chat) — used to
    leak every share row (event_id, filters, notes, view counts) to anon.

    Ownership: closed 2026-05-16 (audit S2) — auth was checked but the
    list wasn't filtered by creator, so authed users saw EVERY share
    (multi-tenant data leak: filters, notes, view metrics from other
    creators). Now filtered by created_by = current_user.id when auth
    is enabled. AUTH_DISABLED=true (dev) skips the filter — admins/dev
    see everything, matching existing auth-disabled semantics.
    """
    db = require_sb()
    q = db.table("share_links").select(
        "id,event_id,filters,note,created_at,expires_at,revoked_at,view_count,last_viewed_at"
    ).order("created_at", desc=True).limit(min(max(limit, 1), 200))
    if user is not None:
        q = q.eq("created_by", user["id"])
    if event_id:
        q = q.eq("event_id", event_id)
    if not include_inactive:
        q = q.is_("revoked_at", "null")
    rows = q.execute().data or []
    shares = [_share_to_dict(r) for r in rows]
    if not include_inactive:
        # Filter expired in code — Postgres `is null OR > now` would need
        # an .or_() clause and the supabase-py builder is fussy. The list
        # is small (page = 50) so post-filtering is fine.
        shares = [s for s in shares if s["active"]]
    return {"count": len(shares), "shares": shares}


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
    from d2_dashboard.main import router as d2_router, root as d2_dashboard_root  # type: ignore
    app.include_router(d2_router)
    # Fold the standalone d2-orders-dashboard service INTO this unified shell.
    # The dashboard PAGE (d2's own "/") is shadowed by the hub homescreen
    # (app.get("/") above), so serve it same-origin at /d2 instead. Its assets
    # live in d2_dashboard/static and load from /static/d2/* — mount that here,
    # BEFORE the catch-all /static mount below, so the longer prefix wins.
    _D2_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "d2_dashboard", "static")
    if os.path.isdir(_D2_STATIC_DIR):
        app.mount("/static/d2", StaticFiles(directory=_D2_STATIC_DIR), name="d2_static")
    app.add_api_route("/d2", d2_dashboard_root, methods=["GET"], include_in_schema=False)
    app.add_api_route("/d2/", d2_dashboard_root, methods=["GET"], include_in_schema=False)
    logging.getLogger(__name__).info("d2_dashboard mounted (router + /d2 page + /static/d2)")
except Exception as _d2_import_err:  # pragma: no cover — d2 module optional in dev
    logging.getLogger(__name__).warning("d2_dashboard NOT mounted: %s", _d2_import_err)


# ---------- Site essentials (SEO + browser-tab UX) ----------
#
# Browsers + crawlers probe these at fixed paths. Without explicit routes,
# /robots.txt + /sitemap.xml + /favicon.ico would 404. Railway audit
# 2026-05-16 found all 3 missing on the deployed storefront.

_ROBOTS_TXT = (
    "User-agent: *\n"
    "Allow: /\n"
    "Disallow: /api/\n"
    "Disallow: /store/test\n"
    "Disallow: /store/test/\n"
    f"Sitemap: {_STOREFRONT_BASE_URL}/sitemap.xml\n"
)


@app.get("/robots.txt", include_in_schema=False)
def robots_txt():
    """Crawler directive — public pages allowed, /api/ + test harness denied.
    Sitemap URL self-references this deploy's base so each environment
    advertises its own sitemap correctly."""
    return Response(content=_ROBOTS_TXT, media_type="text/plain; charset=utf-8")


@app.get("/sitemap.xml", include_in_schema=False)
def sitemap_xml():
    """Minimal sitemap covering the public storefront entry points. Per-event
    URLs are dynamic + ranked elsewhere; this is the static surface map only.
    """
    base = _STOREFRONT_BASE_URL
    urls = ["/store", "/store/about", "/store/privacy", "/store/terms"]
    body = '<?xml version="1.0" encoding="UTF-8"?>\n'
    body += '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
    for path in urls:
        body += f"  <url><loc>{base}{path}</loc></url>\n"
    body += "</urlset>\n"
    return Response(content=body, media_type="application/xml; charset=utf-8")


@app.get("/favicon.ico", include_in_schema=False)
def favicon_ico():
    """Browsers probe /favicon.ico even when the page declares an SVG.
    Redirect to the canonical SVG so users get the icon instead of a 404."""
    return RedirectResponse(url="/static/store/favicon.svg", status_code=308)


# Static assets (CSS / JS / images) served from /static.
# Keep this LAST so explicit routes above win.
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
