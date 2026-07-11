"""D2 Orders Dashboard — FastAPI app.

Single-window view of every broker order surface D2 owns:
  - Evo (TEvo)       list_orders
  - SeatGeek         seller_orders(status='open')
  - TickPick         list_orders(status='unfulfilled')
  - Vivid Seats      list_active_orders   (pending shipment + pending retransfer)

Plus a side tab for SeatData market analytics (account + usage).

Auth model mirrors app.py:162 — Supabase JWT verification via /auth/v1/user
+ email-domain gate. The HTML root is unauthenticated (it hosts the login
flow); /api/d2/* endpoints all require Authorization: Bearer <jwt>.

Env vars (set on Render — D1 provisions):
  SUPABASE_URL                  https://xxxx.supabase.co
  SUPABASE_ANON_KEY             public anon key
  ALLOWED_EMAIL_DOMAIN          default "s4kent.com"
  D2_CANONICAL_ORIGIN           https://d2-orders-dashboard.onrender.com
                                Used as the OAuth redirectTo origin so Supabase
                                Auth bounces back to the right host post-Google.
                                Optional — front-end falls back to window.origin
                                when unset. Set this on Render to avoid surprises
                                with custom domains / preview URLs.
  AUTH_DISABLED                 "true" to bypass the Supabase JWT gate entirely.
                                Self-disables on prod platforms (RENDER /
                                FLY_APP_NAME / ENVIRONMENT=production). Loud
                                startup stderr warning when on. TESTING ONLY.

  TEVO_API_TOKEN / TEVO_API_SECRET   Evo broker creds (vault-canonical names;
                                     legacy TEVO_TOKEN / TEVO_SECRET also honored)
  SEATGEEK_API_TOKEN                 SG seller-direct token
  TICKPICK_API_TOKEN                 TickPick broker token (legacy TICKPICK_TOKEN
                                     also honored)
  VIVID_API_TOKEN                    Vivid Seats broker apiToken
  SEATDATA_API_KEY                   SeatData (optional — analytics tab only)

Start: uvicorn d2_dashboard.main:app --host 0.0.0.0 --port $PORT
"""
from __future__ import annotations

import json
import logging
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import requests
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ---------- Bootstrap ----------

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
# Service-role key — server-side reads against unified_orders / v_event_base.
# Independent of the Supabase JWT auth gate (which uses ANON_KEY). Required
# for the SQL-first hybrid in /api/d2/orders.
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
ALLOWED_EMAIL_DOMAIN = os.environ.get("ALLOWED_EMAIL_DOMAIN", "s4kent.com")
# Canonical public URL of this service. Used as the OAuth redirectTo origin so
# Supabase Auth bounces back to the right host post-Google. Set on Render to
# https://d2-orders-dashboard.onrender.com (or your custom domain). Falls back
# to the browser's window.location.origin when unset.
D2_CANONICAL_ORIGIN = (os.environ.get("D2_CANONICAL_ORIGIN") or "").rstrip("/")
# Lane-status fields surfaced via /healthz/detail (authed). Lets the operator
# read the current D2 phase / UI state without scrolling KANBAN.md. Defaults
# match where the lane stands at this commit: data-collection is healthy, the
# UI rebuild has shipped to PR but operator hasn't accepted it yet. Flip
# D2_UI_STATUS on the service env (e.g. to "rebuilt") after acceptance.
D2_PHASE = os.environ.get("D2_PHASE", "data-collection")
D2_UI_STATUS = os.environ.get("D2_UI_STATUS", "rebuild-pending")

# AUTH_DISABLED is a testing-only kill switch. To prevent a misconfig from
# accidentally opening the whole API on a live deploy, it ONLY takes effect
# when AUTH_DISABLED=true is set explicitly AND no production indicator is
# present. Hardened 2026-06-06 to mirror app.py:_is_production() — previously
# d2 honored the flag unconditionally, so a stray AUTH_DISABLED=true on the
# Render service would have served all /api/d2/* order data unauthenticated.
_AUTH_DISABLED_REQUESTED = os.environ.get("AUTH_DISABLED", "false").lower() == "true"


def _is_production() -> bool:
    """Conservative production detector — if ANY indicator says production we
    treat it as production and refuse the kill switch. Mirrors app.py."""
    railway = (os.environ.get("RAILWAY_ENVIRONMENT") or "").lower() == "production"
    generic = (os.environ.get("ENVIRONMENT") or "").lower() == "production"
    node = (os.environ.get("NODE_ENV") or "").lower() == "production"
    py = (os.environ.get("PYTHON_ENV") or "").lower() == "production"
    fly = bool(os.environ.get("FLY_APP_NAME"))  # Fly.io
    render = bool(os.environ.get("RENDER"))     # Render
    return railway or generic or node or py or fly or render


AUTH_DISABLED = _AUTH_DISABLED_REQUESTED and not _is_production()

if _AUTH_DISABLED_REQUESTED and not AUTH_DISABLED:  # pragma: no cover - import-time prod-guard warning
    import sys as _sys
    print(
        "WARNING: d2_dashboard AUTH_DISABLED=true ignored — production "
        "indicator detected (RAILWAY_ENVIRONMENT / ENVIRONMENT / NODE_ENV / "
        "PYTHON_ENV / FLY_APP_NAME / RENDER). Supabase JWT gate stays ON.",
        file=_sys.stderr,
        flush=True,
    )
elif AUTH_DISABLED:  # pragma: no cover - import-time branch; AUTH_DISABLED is fixed at first import so the not-taken arm is unreachable at test time
    import sys as _sys
    print(
        "d2_dashboard: AUTH_DISABLED=true — /api/d2/* endpoints serve "
        "unauthenticated reads of merged broker order data. Local-dev/testing "
        "bypass only; it self-disables on prod platforms.",
        file=_sys.stderr,
        flush=True,
    )

TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"
STATIC_DIR = Path(__file__).resolve().parent / "static"

# Boot-time sanity check. The JWT gate needs Supabase env vars; surface their
# absence loudly instead of silently serving a "Server misconfigured" panel
# after JS boot. AUTH_DISABLED is production-locked (above), so on a prod
# platform the gate is always on and these env vars are always required.
PROD_MISSING_SUPABASE = (
    (not AUTH_DISABLED)
    and bool(os.environ.get("RENDER") or os.environ.get("FLY_APP_NAME"))
    and not (SUPABASE_URL and SUPABASE_ANON_KEY)
)
if PROD_MISSING_SUPABASE:  # pragma: no cover - import-time prod-guard warning
    import sys as _sys
    print(
        "ERROR: d2_dashboard has AUTH_DISABLED=false on a production platform "
        "but SUPABASE_URL / SUPABASE_ANON_KEY are not set. The Supabase JWT "
        "gate cannot function. Either set both env vars or set "
        "AUTH_DISABLED=true. Serving 503 at / until resolved.",
        file=_sys.stderr,
        flush=True,
    )

# Read the dashboard shell once at import time. The template contains a single
# `__D2_CONFIG_JSON__` placeholder that gets replaced with the per-request JSON
# config blob on each `/` hit. Cheaper than Jinja and avoids the dep.
_DASHBOARD_SHELL_PATH = TEMPLATES_DIR / "dashboard.html"
_DASHBOARD_SHELL = (
    _DASHBOARD_SHELL_PATH.read_text(encoding="utf-8")
    if _DASHBOARD_SHELL_PATH.is_file()
    else None
)
_CONFIG_PLACEHOLDER = "__D2_CONFIG_JSON__"

app = FastAPI(title="Undelivered — D2 fulfillment + sales tracking")

# ---------- CORS ----------
# D0's unified-shell /undelivered scaffold on vibepass-storefront-test.onrender.com
# fetches D2's /api/d2/* cross-origin. Without CORS the browser blocks the XHR
# at preflight. Whitelist explicit origins (not '*') because the API is
# auth-gated and credentialed requests are incompatible with wildcard.
# Localhost in dev: any port (8000, 8080, 5173, etc.); regex covers them.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://vibepass-storefront-test.onrender.com",
        "https://vibepass-terminal-test.onrender.com",  # if D0 terminal also fetches /api/d2/*
        "https://d2-orders-dashboard.onrender.com",      # same-origin is fine without CORS, but listing keeps the matrix explicit
    ],
    # Localhost origins are a dev convenience only — on a production deploy a
    # credentialed allow-any-localhost-port grant is broader than needed
    # (audit 2026-06-10). _is_production() is the same detector the
    # AUTH_DISABLED kill switch uses.
    allow_origin_regex=(None if _is_production() else r"https?://localhost(:\d+)?"),
    allow_credentials=True,
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
    max_age=600,
)

if STATIC_DIR.is_dir():  # pragma: no cover - import-time branch; STATIC_DIR exists in the repo so the not-taken (no-mount) arm is unreachable at test time
    app.mount("/static/d2", StaticFiles(directory=str(STATIC_DIR)), name="d2_static")

# ---------- Router for unified-shell mount (D0 consolidated frontend) ----------
#
# `router` exposes the same routes as `app` but as an importable APIRouter.
# Standalone deploy still works (we app.include_router(router) at the end);
# the unified shell can also do `unified_app.include_router(router, prefix="/undelivered")`
# to host this dashboard under /undelivered/* on the consolidated service.
#
# Per operator directive 2026-05-15 + bot_chat 180: D0 owns the unified shell;
# D2 supplies this router. Sub-app mount via FastAPI(app).mount() is the
# alternative — APIRouter is the lower-friction path because middleware
# composes cleanly (FastAPI mount() warns about middleware isolation).
router = APIRouter()


# ---------- Auth (mirrors app.py require_auth) ----------

def require_auth(authorization: str | None = Header(None)):
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
        # useful to an attacker mapping our internal topology. Mirrors app.py.
        logging.getLogger(__name__).error("Auth check against Supabase failed: %s", e)
        raise HTTPException(502, "auth check failed — upstream auth service unreachable")
    if not r.ok:
        raise HTTPException(401, "invalid session")
    user = r.json()
    # Stop-gap hardening (full local PyJWT verify is followup):
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


# ---------- Client factories (lazy — only init when called) ----------

def _vault_secret(name: str) -> str | None:
    """Fetch a secret from Supabase Vault via get_app_secret RPC.
    Returns None when Supabase is unavailable or the secret is unset."""
    sb = _sb()
    if sb is None:
        return None
    try:
        res = sb.rpc("get_app_secret", {"p_name": name}).execute()
        data = res.data
        if isinstance(data, str):
            return data or None
        if isinstance(data, dict):
            return data.get("get_app_secret") or data.get("value") or None
    except Exception:
        pass
    return None


def _env_first_named(*names: str) -> tuple[str | None, str | None]:
    """Return the first set env var from `names` plus the name that resolved.
    Used by /healthz/detail so the operator can see which token variant was
    loaded (e.g. when a 401 fires on TickPick — was the right env var read?)."""
    for n in names:
        v = os.environ.get(n)
        if v:
            return v, n
    return None, None


def _mask_token(t: str | None) -> str | None:
    """Show only the last 4 chars of a token. Lets the operator confirm a
    token rotation took effect without exposing the full value in logs or
    on /healthz/detail."""
    if not t:
        return None
    if len(t) <= 4:
        return "***"
    return f"...{t[-4:]}"


def _broker_diag(*token_names: str, secret_names: tuple[str, ...] = ()) -> dict:
    """Build the per-broker diagnostic blob shown on /healthz/detail.
    Reports which env-var name was actually read and a masked tail of its
    value — enough for the operator to confirm a token rotation took
    effect without exposing the secret. Adds duplicate-set detection
    so when both vault-canonical and legacy names are populated with
    different values (a common cause of TickPick 401 — wrong key wins),
    the dashboard surfaces it explicitly."""
    token_val, token_src = _env_first_named(*token_names)
    set_variants = [n for n in token_names if os.environ.get(n)]
    diag: dict = {
        "token_set": bool(token_val),
        "token_env_var": token_src,
        "token_masked": _mask_token(token_val),
    }
    if len(set_variants) > 1:
        diag["token_warning"] = f"multiple env vars set ({', '.join(set_variants)}); using {token_src}"
    if secret_names:
        secret_val, secret_src = _env_first_named(*secret_names)
        diag["secret_set"] = bool(secret_val)
        diag["secret_env_var"] = secret_src
        diag["secret_masked"] = _mask_token(secret_val)
    return diag


def _gotickets_client():
    from gotickets_client import GoTicketsClient
    access_id = os.environ.get("GOTICKETS_ACCESS_ID") or _vault_secret("GOTICKETS_ACCESS_ID")
    api_secret = os.environ.get("GOTICKETS_API_SECRET") or _vault_secret("GOTICKETS_API_SECRET")
    if not (access_id and api_secret):
        return None
    return GoTicketsClient(access_id, api_secret)


# ---------- Supabase (server-side SQL reads) ----------

_SB_SINGLETON = None
_SB_INIT_ATTEMPTED = False


def _sb():
    """Lazy-init the Supabase service-role client. Returns None when
    SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY are unset — the SQL-backed
    fetchers then short-circuit and the API-backed fan-out runs instead."""
    global _SB_SINGLETON, _SB_INIT_ATTEMPTED
    if _SB_INIT_ATTEMPTED:
        return _SB_SINGLETON
    _SB_INIT_ATTEMPTED = True
    if not (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY):
        return None
    try:
        from supabase import create_client
        _SB_SINGLETON = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    except Exception as e:
        import sys as _sys
        print(f"[d2_dashboard] supabase client init failed: {e!r}", file=_sys.stderr, flush=True)
        _SB_SINGLETON = None
    return _SB_SINGLETON


# ---------- Data / DB helpers (extracted to core/d0_orders.py — slice 2) ----------
#
# The pure/shared order fetchers, row builders, deep-order + metrics helpers now
# live in core/d0_orders.py (mirrors core/broker_helpers.py / core/store_events.py:
# product-specific helper bodies in core/, one-directional main -> core). They're
# imported back by name here so the route handlers below call the module-global
# name and the test-suite's `monkeypatch.setattr(d2_main, "<name>", ...)` still
# rebinds them.
from core import d0_orders
from core.d0_orders import (  # noqa: F401  (re-exported for route + monkeypatch use)
    _to_int,
    _to_float,
    _scrub_err,
    _SAFE_CLIENT_ERROR_NAMES,
    _SQL_BACKED_SOURCES,
    _ALL_SOURCES,
    _ACTIVE_STATUSES,
    _UO_PAGE_SELECT,
    _EVENT_WINDOW_CACHE,
    _EVENT_WINDOW_TTL_SEC,
    _build_order_rows,
    _shell_config_blob,
    _deep_order_evo_sql,
    _deep_order_seatgeek_sales_sql,
    _deep_order_tickpick_sql,
    _deep_order_vivid_sql,
    _deep_order_gotickets,
    _DEEP_ORDER,
    _metrics_window_rows,
    _metrics_hourly_buckets,
    _metrics_top_events,
    _metrics_hot_events,
    _metrics_biggest_sales,
    _metrics_sales_gaps,
    _today_start_utc,
    _timed,
)


# The five fetchers below read the Supabase service-role singleton. `_sb()` stays
# in main.py (it holds the app's env-var config + client bootstrap), so the core
# implementations take an explicit `sb` argument and these thin same-signature
# shims inject `_sb()` at the call site. Keeping the original names + signatures
# here preserves the route call sites and the `monkeypatch.setattr(d2_main, ...)`
# bindings in the existing test-suite unchanged.

def _fetch_cron_freshness() -> dict[str, dict]:
    return d0_orders._fetch_cron_freshness(_sb())


def _pull_event_window(days_back: int = 1, days_forward: int = 120) -> list[dict]:
    return d0_orders._pull_event_window(_sb(), days_back, days_forward)


def _fetch_unified_orders_page(per_page: int, page: int = 1, include_terminal: bool = False) -> dict | None:
    return d0_orders._fetch_unified_orders_page(_sb(), per_page, page, include_terminal)


def _fetch_filtered_orders(
    source: str,
    per_page: int,
    page: int = 1,
    include_terminal: bool = False,
    q: str | None = None,
    when: str = "all",
) -> dict | None:
    return d0_orders._fetch_filtered_orders(_sb(), source, per_page, page, include_terminal, q, when)


def _fetch_unified_orders_fast(per_page: int, include_terminal: bool = False) -> dict | None:
    return d0_orders._fetch_unified_orders_fast(_sb(), per_page, include_terminal)


# ---------- Endpoints ----------

@app.get("/healthz")
def healthz():
    """Public LIVENESS check. Stripped to a minimal shape — operator can still
    confirm the process is up, but no fingerprintable detail is exposed.
    Use /healthz/detail with a valid Bearer token for the full diagnostic,
    or /readyz for a Supabase-connectivity readiness probe.

    Render's health-check path points HERE (liveness) on purpose — a transient
    Supabase blip must NOT mark the process unhealthy and trigger a restart."""
    return {"ok": True, "service": "d2_dashboard"}


@app.get("/readyz")
def readyz():
    """Public READINESS probe — verifies the dashboard can actually reach
    Supabase and read its serving view (`unified_orders`), not just that the
    process is up. Catches the failure mode /healthz can't see: a present-but-
    wrong/unreachable SUPABASE_URL passes liveness but 503s on the first data
    hit. Operators + uptime monitors curl this post-deploy.

    Leaks only a reachability enum (no error detail to the client; the full
    exception goes to stderr). One cheap LIMIT-1 read per hit. Do NOT wire
    Render's health-check path to this — keep that on /healthz (see above)."""
    sb = _sb()
    if sb is None:
        return JSONResponse(
            {"ok": False, "service": "d2_dashboard", "supabase": "not_configured"},
            status_code=503,
        )
    try:
        # Probe the exact surface the dashboard serves. UNION-ALL view + LIMIT 1
        # short-circuits after the first branch's first row — cheap.
        sb.table("unified_orders").select("source").limit(1).execute()
        return {"ok": True, "service": "d2_dashboard", "supabase": "reachable"}
    except Exception as e:
        import sys as _sys
        print(f"[d2_dashboard] /readyz supabase probe failed: {e!r}", file=_sys.stderr, flush=True)
        return JSONResponse(
            {"ok": False, "service": "d2_dashboard", "supabase": "unreachable"},
            status_code=503,
        )


@app.get("/healthz/detail")
def healthz_detail(_=Depends(require_auth)):
    """Authenticated diagnostic snapshot. Same shape the old /healthz had —
    booleans + lengths + platform indicators. Behind require_auth so only
    operator (or any @allowed-domain user) can see it."""
    import sys as _sys
    return {
        "ok": True,
        "service": "d2_dashboard",
        "phase": D2_PHASE,
        "ui": D2_UI_STATUS,
        "python": _sys.version.split()[0],
        "auth_disabled": AUTH_DISABLED,
        "supabase": {
            "url_set": bool(SUPABASE_URL),
            "anon_key_length": len(SUPABASE_ANON_KEY or ""),
            "allowed_email_domain": ALLOWED_EMAIL_DOMAIN,
        },
        "brokers": {
            "evo":      _broker_diag("TEVO_API_TOKEN", "TEVO_TOKEN", secret_names=("TEVO_API_SECRET", "TEVO_SECRET")) | {"sandbox": os.environ.get("TEVO_SANDBOX", "false").lower() == "true"},
            "seatgeek": _broker_diag("SEATGEEK_API_TOKEN"),
            "tickpick": _broker_diag("TICKPICK_API_TOKEN", "TICKPICK_TOKEN"),
            "vivid":    _broker_diag("VIVID_API_TOKEN"),
            "seatdata": _broker_diag("SEATDATA_API_KEY"),
            "gotickets": _broker_diag("GOTICKETS_ACCESS_ID", secret_names=("GOTICKETS_API_SECRET",)),
        },
        "platform": {
            "render": bool(os.environ.get("RENDER")),
            "fly": bool(os.environ.get("FLY_APP_NAME")),
            "environment": os.environ.get("ENVIRONMENT") or os.environ.get("NODE_ENV") or None,
        },
        "templates": {
            "dir_exists": TEMPLATES_DIR.is_dir(),
            "dashboard_html_exists": (TEMPLATES_DIR / "dashboard.html").is_file(),
        },
    }


@router.get("/")
def root():
    """Dashboard HTML entry point.

    Standalone deploy: visible at /. Unified shell (mount prefix=/undelivered):
    visible at /undelivered/. Either way the in-page asset links resolve via
    the static mount on `app` (or the shell's static handling).
    """
    if PROD_MISSING_SUPABASE:
        raise HTTPException(503, "d2_dashboard misconfigured: SUPABASE_URL / SUPABASE_ANON_KEY not set")
    if not _DASHBOARD_SHELL:
        raise HTTPException(500, "dashboard.html missing")
    # JSON.stringify equivalent — escape `<` to defuse `</script>` injection
    # from any future config field that ends up reflecting user input.
    blob = json.dumps(
        _shell_config_blob(SUPABASE_URL, SUPABASE_ANON_KEY, ALLOWED_EMAIL_DOMAIN, AUTH_DISABLED, D2_CANONICAL_ORIGIN)
    ).replace("<", "\\u003c")
    html = _DASHBOARD_SHELL.replace(_CONFIG_PLACEHOLDER, blob)
    return HTMLResponse(html)


@router.get("/api/d2/orders")
def orders(
    per_page: int = 25,
    page: int = 1,
    fast: int = 0,
    include_terminal: int = 0,
    source: str = "all",
    q: str | None = None,
    when: str = "all",
    _=Depends(require_auth),
):
    """SQL-only orders feed. All 5 sources (evo / seatgeek_sales / seatdata /
    tickpick / vivid) are pulled from public.unified_orders, which the
    upstream ingest crons keep populated. No broker-API calls in the data
    path — cron freshness (`/api/d2/cron-freshness`) is the operator's
    staleness signal; if a cron stalls, the affected source surfaces empty
    rows + an aged `as_of` chip rather than silently falling back to live
    API (which would burn broker quota and hide ingest problems).

    `?include_terminal=0` (default): active-only — hides rows in known
    terminal canonical_status (fulfilled/rejected/cancelled). Rows with
    NULL canonical_status (unknown source_status) are still surfaced —
    they probably need operator attention. This is the primary tab's
    default view.

    `?include_terminal=1`: show all — no canonical_status filter. The
    primary tab's "All" pill flips this.

    `?source=<evo|seatgeek_sales|tickpick|vivid>`, `?q=<event name>`,
    `?when=<all|upcoming|past>`: terminal Orders filters. Any non-default
    value routes to the server-side filtered fetch — a single `source` gets
    the full `per_page` window (page through ALL of that source's book)
    instead of the balanced per_page//n_sources cap. `q` is an event-name
    ILIKE; `when` filters on event_date around now()-12h. Responses carry
    `has_more` so the client can drive Prev/Next without a count(*).

    ?fast=1 mode (two-phase load): single global SQL query, upcoming-only
    (event_date >= now()-12h), event_date ASC, NO event_window join.
    Renders the soonest N upcoming events in <200ms. The client follows
    up with the full call (with v_event_base join for unresolved events)
    in the background via the diff-aware DOM update.

    Default mode: two parallel SQL pulls — per-source fan-out across
    unified_orders + cached v_event_base window. Cron freshness moved to
    /api/d2/cron-freshness on a separate poll so a slow cron RPC doesn't
    pace this feed.

    Per-leg timings are logged to stderr (Render logs) AND surfaced as a
    Server-Timing response header so the operator can see exactly which
    leg is slow from browser dev tools."""
    import time as _time
    per_page = max(1, min(per_page, 100))
    page = max(1, page)
    include_terminal_flag = bool(include_terminal)

    # Source / Search / Date filters (terminal Orders controls). When any is
    # set we route to the server-side filtered fetch: a single source gets the
    # FULL per_page window (page through all of e.g. EVO), not the balanced
    # per_page//n_sources cap. `source=all` + no q + when=all keeps the
    # original balanced fan-out untouched.
    source_norm = (source or "all").strip().lower()
    q_norm = (q or "").strip() or None
    when_norm = (when or "all").strip().lower()
    if when_norm not in ("all", "upcoming", "past"):
        when_norm = "all"
    use_filtered = (source_norm != "all") or (q_norm is not None) or (when_norm != "all")

    timings: dict = {}
    t0 = _time.perf_counter()

    if use_filtered and not fast:
        bundle = _timed(
            "sql.filtered", _fetch_filtered_orders,
            source_norm, per_page, page, include_terminal_flag, q_norm, when_norm,
            _timings=timings,
        )
        if bundle is None:
            raise HTTPException(503, "Supabase not configured (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY required)")
        rows = bundle["rows"]
        per_source_count = dict(bundle.get("per_source_count") or {})
        per_source_as_of = dict(bundle.get("per_source_as_of") or {})
        sql_err = bundle.get("error")
        sources_summary = [
            {
                "source": src,
                "ok": not bool(sql_err),
                "count": per_source_count.get(src, 0),
                "total_reported": None,
                "error": sql_err,
                "origin": "sql",
                "as_of": per_source_as_of.get(src),
            }
            for src in _ALL_SOURCES
        ]
        rows.sort(key=lambda x: (x.get("ordered_at") or ""), reverse=True)
        total_ms = (_time.perf_counter() - t0) * 1000
        response = JSONResponse({
            "sources": sources_summary,
            "rows": rows,
            "page": page,
            "per_page": per_page,
            "phase": "filtered",
            "include_terminal": include_terminal_flag,
            "source": source_norm,
            "q": q_norm,
            "when": when_norm,
            "has_more": bool(bundle.get("has_more")),
            "timings_ms": {k: round(v, 1) for k, v in timings.items()} | {"total": round(total_ms, 1)},
        })
        response.headers["Server-Timing"] = ", ".join(
            f"{k.replace('.','_')};dur={v:.1f}" for k, v in timings.items()
        ) + f", total;dur={total_ms:.1f}"
        return response

    if fast:
        # Single query, single thread, upcoming-only. Phase 1 of two-phase load.
        bundle = _timed("sql.unified.fast", _fetch_unified_orders_fast, per_page, include_terminal_flag, _timings=timings)
        if bundle is None:
            raise HTTPException(503, "Supabase not configured")
        rows = bundle["rows"]
        per_source_count = dict(bundle.get("per_source_count") or {})
        per_source_as_of = dict(bundle.get("per_source_as_of") or {})
        sql_err = bundle.get("error")
        sources_summary = [
            {
                "source": src,
                "ok": not bool(sql_err),
                "count": per_source_count.get(src, 0),
                "total_reported": None,
                "error": sql_err,
                "origin": "sql",
                "as_of": per_source_as_of.get(src),
            }
            for src in _ALL_SOURCES
        ]
        total_ms = (_time.perf_counter() - t0) * 1000
        import sys as _sys
        print(
            f"[d2_dashboard] /api/d2/orders fast=1 total={total_ms:.0f}ms "
            f"sql.unified.fast={timings.get('sql.unified.fast', 0):.0f}ms",
            file=_sys.stderr, flush=True,
        )
        return JSONResponse({
            "sources": sources_summary,
            "rows": rows,
            "page": page,
            "per_page": per_page,
            "phase": "fast",
            "include_terminal": include_terminal_flag,
            "timings_ms": {k: round(v, 1) for k, v in timings.items()} | {"total": round(total_ms, 1)},
        })

    with ThreadPoolExecutor(max_workers=2) as ex:
        sql_future       = ex.submit(_timed, "sql.unified", _fetch_unified_orders_page, per_page, page, include_terminal_flag, _timings=timings)
        events_future    = ex.submit(_timed, "sql.event_window", _pull_event_window, _timings=timings)
        bundle           = sql_future.result()
        event_window     = events_future.result()

    if bundle is None:
        raise HTTPException(503, "Supabase not configured (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY required)")

    # event_window is fetched in parallel for future enrichment / UI use, but
    # the SQL fan-out already surfaces native event_name + event_date per source
    # (mig 20260514000000) and back-fills from v_event_base inside the bundler
    # for any source whose ingest left those fields blank.
    _ = event_window

    rows = bundle["rows"]
    per_source_count = dict(bundle.get("per_source_count") or {})
    per_source_as_of = dict(bundle.get("per_source_as_of") or {})
    sql_err = bundle.get("error")

    # has_more for the balanced fan-out: any source that filled its per_page//n
    # slice may have more rows on the next page.
    _balanced_per_source = max(1, per_page // max(1, len(_SQL_BACKED_SOURCES)))
    has_more = any(c >= _balanced_per_source for c in per_source_count.values())

    sources_summary = [
        {
            "source": src,
            "ok": not bool(sql_err),
            "count": per_source_count.get(src, 0),
            "total_reported": None,
            "error": sql_err,
            "origin": "sql",
            "as_of": per_source_as_of.get(src),
            # cron blob deliberately omitted here — fetched via
            # /api/d2/cron-freshness on a separate, slower poll
        }
        for src in _ALL_SOURCES
    ]

    rows.sort(key=lambda x: (x.get("ordered_at") or ""), reverse=True)
    total_ms = (_time.perf_counter() - t0) * 1000

    import sys as _sys
    print(
        f"[d2_dashboard] /api/d2/orders total={total_ms:.0f}ms "
        f"sql.unified={timings.get('sql.unified', 0):.0f}ms "
        f"sql.event_window={timings.get('sql.event_window', 0):.0f}ms "
        f"event_window_cached={'yes' if (timings.get('sql.event_window', 999) < 5) else 'no'}",
        file=_sys.stderr, flush=True,
    )

    response = JSONResponse({
        "sources": sources_summary,
        "rows": rows,
        "page": page,
        "per_page": per_page,
        "phase": "full",
        "include_terminal": include_terminal_flag,
        "source": "all",
        "has_more": has_more,
        "timings_ms": {k: round(v, 1) for k, v in timings.items()} | {"total": round(total_ms, 1)},
    })
    response.headers["Server-Timing"] = ", ".join(
        f"{k.replace('.','_')};dur={v:.1f}" for k, v in timings.items()
    ) + f", total;dur={total_ms:.1f}"
    return response


@router.get("/api/d2/cron-freshness")
def cron_freshness(_=Depends(require_auth)):
    """Per-source cron freshness, served separately from /api/d2/orders so
    a slow cron RPC (66ms+ vs unified_orders' 3ms) doesn't pace the orders
    feed. The dashboard polls this on a longer interval (or on Health-tab
    open) than the 5-min orders auto-refresh."""
    by_source = _fetch_cron_freshness()
    return JSONResponse({"sources": by_source})


@router.get("/api/d2/health")
def health(_=Depends(require_auth)):
    """Refresh-health snapshot — what each cron is doing and whether its
    pipeline is healthy. Read-only; intended for the dashboard's Health tab.

    Returns:
      crons: list of one entry per cron job (jobname, schedule, active,
             last_run, last_status). Sourced from public.d2_cron_freshness().
      queues: per-source pending-queue depth (unresolved pg_net requests)
             so the operator can see if process() is keeping up.
      sql_counts: row counts in unified_orders per source + max(last_seen_at)
             so the operator can see how stale the canonical view is.
      fulfillby_fields: per-source whether the upstream surfaces an explicit
             fulfill-by / in-hand date — currently none do (informational)."""
    sb = _sb()
    if sb is None:
        raise HTTPException(503, "Supabase not configured")

    # 1) Cron freshness — full list (not reduced to queue-only like the
    #    orders chip uses).
    cron_rows: list[dict] = []
    try:
        cron_rows = (sb.rpc("d2_cron_freshness").execute().data) or []
    except Exception as e:
        import sys as _sys
        print(f"[d2_dashboard] cron freshness pull failed: {e!r}", file=_sys.stderr, flush=True)

    # 2) Per-source unresolved pending-queue depth + SQL row counts.
    queues: dict[str, int] = {}
    sql_counts: dict[str, dict] = {}
    try:
        for src, table in (("tickpick", "tickpick_orders_pending"), ("vivid", "vivid_orders_pending")):
            try:
                res = sb.table(table).select("id", count="exact").is_("resolved_at", "null").execute()
                queues[src] = res.count or 0
            except Exception:
                queues[src] = -1   # sentinel: query failed
        # Per-source row counts + freshness from unified_orders
        for src in _ALL_SOURCES:
            res = (
                sb.table("unified_orders")
                .select("last_seen_at", count="exact")
                .eq("source", src)
                .order("last_seen_at", desc=True)
                .limit(1)
                .execute()
            )
            sql_counts[src] = {
                "rows":    res.count or 0,
                "newest_seen": (res.data[0]["last_seen_at"] if res.data else None),
            }
    except Exception as e:
        import sys as _sys
        print(f"[d2_dashboard] health counts pull failed: {e!r}", file=_sys.stderr, flush=True)

    # 3) Fulfill-by / in-hand date inventory — what each source surfaces.
    #    Currently none of our raw tables carry an explicit fulfill-by
    #    timestamp; documenting that here so the operator sees the gap.
    fulfillby_fields = {
        "evo":            {"in_hand": None, "fulfill_by": None, "notes": "hold_expires_at is auction-hold timer, not fulfill deadline; event_date is implicit"},
        "seatgeek_sales": {"in_hand": "in_hand_date", "fulfill_by": None, "notes": "broker firehose observation — in_hand_date is the listing's promised drop date; no fulfill-by lifecycle (sales are terminal at observation time)"},
        "tickpick":       {"in_hand": None, "fulfill_by": None, "notes": "tickpick_orders.raw jsonb may carry more; not surfaced yet"},
        "vivid":          {"in_hand": None, "fulfill_by": None, "notes": "vivid_orders.raw_xml + raw jsonb; no explicit fulfill-by field in feed"},
        "seatdata":       {"in_hand": None, "fulfill_by": None, "notes": "completed-sales feed — no fulfillment lifecycle"},
    }

    return JSONResponse({
        "crons": cron_rows,
        "queues": queues,
        "sql_counts": sql_counts,
        "fulfillby_fields": fulfillby_fields,
        "checked_at": __import__("datetime").datetime.utcnow().isoformat() + "Z",
    })


@router.get("/api/d2/order/{source}/{order_id}")
def order_detail(source: str, order_id: str, _=Depends(require_auth)):
    """Single-order deep fetch.

    For evo / tickpick / vivid: reads the matching row from the raw
    `{source}_orders` table in Supabase. For seatgeek_sales: reads from
    `seatgeek_sales_snapshots` (broker firehose) keyed by `sg_sale_id`.
    No upstream-API call.

    For gotickets: by-id API call — no SQL backing yet (tracked for future
    ingest cron in the canonical lane).

    Read-only — no fulfillment / transfer / write endpoints are wired here
    per the 2026-05-13 lockdown."""
    if source not in _DEEP_ORDER:
        raise HTTPException(404, f"unknown source: {source}")
    import sys as _sys
    factory_name, fetcher = _DEEP_ORDER[source]
    client_factory = getattr(_sys.modules[__name__], factory_name)
    c = client_factory()
    if c is None:
        err = "Supabase not configured" if factory_name == "_sb" else "no creds"
        return JSONResponse({"ok": False, "source": source, "order_id": order_id, "error": err}, status_code=200)
    try:
        data = fetcher(c, order_id)
        if not data:
            return JSONResponse({"ok": False, "source": source, "order_id": order_id, "error": "not found"}, status_code=200)
        return JSONResponse({"ok": True, "source": source, "order_id": order_id, "data": data})
    except Exception as e:
        return JSONResponse(
            {"ok": False, "source": source, "order_id": order_id, "error": _scrub_err(f"{source}.order_detail", e)},
            status_code=200,
        )


@router.get("/api/d2/metrics")
def metrics(_=Depends(require_auth)):
    """CEO-view metrics bundle. One round-trip; backend fans out 13 SQL
    calls in parallel:
      - 4 windows × current + 4 × prior   : d2_metrics_window (KPI grid)
      - hourly buckets (last 24h)         : d2_metrics_hourly_buckets (sparkline)
      - top events (last 7d, by closed $) : d2_metrics_top_events
      - hot events (last 1h, by velocity) : d2_metrics_hot_events
      - biggest sales (last 5 min)        : d2_metrics_biggest_sales
      - sales gaps (last 24h, >30min)     : d2_metrics_sales_gaps

    Windows anchor on America/New_York for "today" so the day boundary
    matches the operator's clock. Post-2026-05-16 rewire: SG source is
    seatgeek_sales (broker firehose); the dormant seatgeek seller source
    is excluded from metrics."""
    from datetime import datetime, timedelta, timezone
    import time as _time
    sb = _sb()
    if sb is None:
        raise HTTPException(503, "Supabase not configured (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY required)")

    timings: dict = {}
    t0 = _time.perf_counter()
    now_utc = datetime.now(timezone.utc)
    today_start = _today_start_utc()
    yesterday_start = today_start - timedelta(days=1)

    current_windows = {
        "hour":  (now_utc - timedelta(hours=1),  now_utc),
        "today": (today_start,                    now_utc),
        "24h":   (now_utc - timedelta(hours=24), now_utc),
        "7d":    (now_utc - timedelta(days=7),   now_utc),
    }
    prior_windows = {
        "hour":  (now_utc - timedelta(hours=2),  now_utc - timedelta(hours=1)),
        "today": (yesterday_start,                today_start),
        "24h":   (now_utc - timedelta(hours=48), now_utc - timedelta(hours=24)),
        "7d":    (now_utc - timedelta(days=14),  now_utc - timedelta(days=7)),
    }
    hourly_start = now_utc - timedelta(hours=24)
    top_start    = now_utc - timedelta(days=7)
    # Hot events = velocity in the last hour (orders_count ordered desc).
    hot_start    = now_utc - timedelta(hours=1)
    # Biggest sales = anything that cleared in the last 5 min by default.
    biggest_since = now_utc - timedelta(minutes=5)

    # Parallel fan-out: 10 calls in worst case. Each is a single PostgREST
    # round-trip to a STABLE SQL function — typical RTT ~50-100ms, so the
    # total bundle should land in ~max(per-call) with the pool sized to
    # the work.
    results: dict = {"windows": {}, "hourly_buckets": [], "top_events": [], "errors": []}

    def _safe_window(label: str, kind: str, p_start, p_end):
        try:
            data = _timed(f"sql.window.{label}.{kind}", _metrics_window_rows, sb, p_start, p_end, _timings=timings)
            return label, kind, data, None
        except Exception as e:
            return label, kind, [], _scrub_err(f"d2_metrics_window.{label}.{kind}", e)

    def _safe_hourly():
        try:
            data = _timed("sql.hourly_buckets", _metrics_hourly_buckets, sb, hourly_start, now_utc, _timings=timings)
            return data, None
        except Exception as e:
            return [], _scrub_err("d2_metrics_hourly_buckets", e)

    def _safe_top():
        try:
            data = _timed("sql.top_events", _metrics_top_events, sb, top_start, now_utc, 10, _timings=timings)
            return data, None
        except Exception as e:
            return [], _scrub_err("d2_metrics_top_events", e)

    def _safe_hot():
        try:
            data = _timed("sql.hot_events", _metrics_hot_events, sb, hot_start, now_utc, 10, _timings=timings)
            return data, None
        except Exception as e:
            return [], _scrub_err("d2_metrics_hot_events", e)

    def _safe_biggest():
        try:
            data = _timed("sql.biggest_sales", _metrics_biggest_sales, sb, biggest_since, 10, _timings=timings)
            return data, None
        except Exception as e:
            return [], _scrub_err("d2_metrics_biggest_sales", e)

    def _safe_gaps():
        try:
            data = _timed("sql.sales_gaps", _metrics_sales_gaps, sb, 24, 30, _timings=timings)
            return data, None
        except Exception as e:
            return [], _scrub_err("d2_metrics_sales_gaps", e)

    with ThreadPoolExecutor(max_workers=12) as ex:
        futures = []
        for label in current_windows:
            cs, ce = current_windows[label]
            ps, pe = prior_windows[label]
            futures.append(ex.submit(_safe_window, label, "current", cs, ce))
            futures.append(ex.submit(_safe_window, label, "prior",   ps, pe))
        hourly_future  = ex.submit(_safe_hourly)
        top_future     = ex.submit(_safe_top)
        hot_future     = ex.submit(_safe_hot)
        biggest_future = ex.submit(_safe_biggest)
        gaps_future    = ex.submit(_safe_gaps)

        for fut in futures:
            label, kind, data, err = fut.result()
            results["windows"].setdefault(label, {"current": [], "prior": []})
            results["windows"][label][kind] = data
            if err:
                results["errors"].append({"leg": f"window.{label}.{kind}", "error": err})

        for leg_name, fut in (
            ("hourly_buckets", hourly_future),
            ("top_events",     top_future),
            ("hot_events",     hot_future),
            ("biggest_sales",  biggest_future),
            ("sales_gaps",     gaps_future),
        ):
            data, err = fut.result()
            results[leg_name] = data
            if err:
                results["errors"].append({"leg": leg_name, "error": err})

    total_ms = (_time.perf_counter() - t0) * 1000
    results["checked_at"] = now_utc.isoformat()
    results["timings_ms"] = {k: round(v, 1) for k, v in timings.items()} | {"total": round(total_ms, 1)}

    import sys as _sys
    print(f"[d2_dashboard] /api/d2/metrics total={total_ms:.0f}ms legs={len(timings)}", file=_sys.stderr, flush=True)
    return JSONResponse(results)


@router.get("/api/d2/sales-feed")
def sales_feed(limit: int = 20, _=Depends(require_auth)):
    """Newest N rows across all 5 sources from public.unified_orders.
    Polled every 30s by the Metrics tab for the live sales-feed surface.
    Plain PostgREST query (no RPC) — single round-trip.

    `?limit=N` clamped to [1, 100]; default 20."""
    from datetime import datetime, timezone
    import time as _time
    sb = _sb()
    if sb is None:
        raise HTTPException(503, "Supabase not configured (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY required)")
    limit = max(1, min(int(limit), 100))
    t0 = _time.perf_counter()
    try:
        res = (
            sb.table("unified_orders")
            .select("source,source_order_id,gross_value,quantity,event_name,event_date,created_at,canonical_status,is_sale_succeeded")
            .in_("source", list(_ALL_SOURCES))
            .order("created_at", desc=True)
            .limit(limit)
            .execute()
        )
        rows = res.data or []
    except Exception as e:
        return JSONResponse(
            {"ok": False, "error": _scrub_err("sales_feed", e), "rows": [], "checked_at": datetime.now(timezone.utc).isoformat()},
            status_code=200,
        )
    total_ms = (_time.perf_counter() - t0) * 1000
    return JSONResponse({
        "ok": True,
        "rows": rows,
        "limit": limit,
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "timings_ms": {"sql.sales_feed": round(total_ms, 1)},
    })


# ---------- Include router into standalone app ----------
#
# Standalone Render deploy serves everything from `app` (which now includes the
# router routes). The unified D0 shell imports `router` directly and mounts it
# under a prefix (e.g. "/undelivered") — bypassing this include.
app.include_router(router)

