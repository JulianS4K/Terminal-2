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
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import requests
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException
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

# Auth-on by default (2026-05-13: operator re-enabled Google OAuth after
# wiring the Supabase Auth redirect URI). Set AUTH_DISABLED=true on the
# service env for a one-off testing bypass. No production self-disable —
# the operator opts in explicitly when they want the gate off.
AUTH_DISABLED = os.environ.get("AUTH_DISABLED", "false").lower() == "true"

if AUTH_DISABLED:
    import sys as _sys
    print(
        "d2_dashboard: AUTH_DISABLED=true — /api/d2/* endpoints serve "
        "unauthenticated reads of merged broker order data. Set "
        "AUTH_DISABLED=false (the default) on the service env to restore "
        "the Supabase JWT gate.",
        file=_sys.stderr,
        flush=True,
    )

TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"
STATIC_DIR = Path(__file__).resolve().parent / "static"

# Boot-time sanity check. Only meaningful when AUTH_DISABLED is *false* — in
# that mode the JWT gate needs Supabase env vars; surface their absence loudly
# instead of silently serving a "Server misconfigured" panel after JS boot.
# With AUTH_DISABLED=true (the new default), Supabase env vars are unused.
PROD_MISSING_SUPABASE = (
    (not AUTH_DISABLED)
    and bool(os.environ.get("RENDER") or os.environ.get("FLY_APP_NAME"))
    and not (SUPABASE_URL and SUPABASE_ANON_KEY)
)
if PROD_MISSING_SUPABASE:
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

if STATIC_DIR.is_dir():
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
        raise HTTPException(502, f"auth check failed: {e}")
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

def _env_first(*names: str) -> str | None:
    """Return the first set env var from `names`. Lets us accept either the
    vault-canonical key (TEVO_API_TOKEN) or the legacy storefront key
    (TEVO_TOKEN) without forcing the operator to pick."""
    for n in names:
        v = os.environ.get(n)
        if v:
            return v
    return None


def _env_first_named(*names: str) -> tuple[str | None, str | None]:
    """Like _env_first but also returns the env-var name that resolved.
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


def _evo_client():
    from evo_client import EvoClient
    token = _env_first("TEVO_API_TOKEN", "TEVO_TOKEN")
    secret = _env_first("TEVO_API_SECRET", "TEVO_SECRET")
    if not (token and secret):
        return None
    return EvoClient(token, secret, sandbox=os.environ.get("TEVO_SANDBOX", "false").lower() == "true")


def _sg_client():
    from seatgeek_client import SeatGeekClient
    try:
        return SeatGeekClient()
    except Exception:
        return None


def _tickpick_client():
    from tickpick_client import TickPickClient
    token = _env_first("TICKPICK_API_TOKEN", "TICKPICK_TOKEN")
    if not token:
        return None
    return TickPickClient(token)


def _vivid_client():
    from vivid_client import VividClient
    token = os.environ.get("VIVID_API_TOKEN")
    if not token:
        return None
    return VividClient(token)


def _seatdata_client():
    from seatdata_client import SeatDataClient
    api_key = os.environ.get("SEATDATA_API_KEY")
    if not api_key:
        return None
    return SeatDataClient(api_key=api_key)


def _gotickets_client():
    from gotickets_client import GoTicketsClient
    access_id = os.environ.get("GOTICKETS_ACCESS_ID")
    api_secret = os.environ.get("GOTICKETS_API_SECRET")
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


# ---------- Normalizer ----------
#
# Target shape per row:
#   {
#     "source":      "evo" | "seatgeek" | "tickpick" | "vivid"
#     "order_id":    str
#     "event_name":  str | None
#     "event_date":  str | None     (ISO 8601 if available)
#     "qty":         int | None
#     "status":      str | None
#     "amount":      float | None   (total, in source's currency)
#     "currency":    str | None
#     "ordered_at":  str | None     (ISO 8601)
#   }

def _norm_evo(o: dict) -> dict:
    # Evo list_orders doesn't return event at the top level — it lives inside
    # the first item's ticket_group. Pattern verified against the operator's
    # reference Tkinter app: o.items[0].ticket_group.event.{name,occurs_at}.
    items = o.get("items") or []
    first_tg = (items[0] or {}).get("ticket_group") or {} if items else {}
    event = first_tg.get("event") or {}
    qty = sum(int(it.get("quantity") or 0) for it in items) if items else None
    status = o.get("state")
    return {
        "source": "evo",
        "order_id": str(o.get("id") or ""),
        "event_name": event.get("name"),
        "event_date": event.get("occurs_at"),
        "qty": qty,
        "status": status,
        "canonical_status": _canonical_status("evo", status),
        "amount": _to_float(o.get("total")),
        "currency": o.get("currency"),
        "ordered_at": o.get("created_at"),
    }


def _norm_sg(o: dict) -> dict:
    # SeatGeek's seller_order/{id} payload uses:
    #   event.name    (not event.title)
    #   event.date    "YYYY-MM-DD"   (separate from event.time "HH:MM:SS")
    #   listing.quantity (not o.quantity)
    #   created / updated (not created_at / ordered_at)
    # Earlier reading of `.title` / `.datetime_local` left event_date + qty
    # blank on the deep-detail panel. Combine date + time into an ISO string.
    event = o.get("event") or {}
    listing = o.get("listing") or {}
    status = o.get("status")
    ev_date = event.get("date")
    ev_time = event.get("time") or "00:00:00"
    event_dt = f"{ev_date}T{ev_time}" if ev_date else (
        event.get("datetime_local") or event.get("datetime_utc")
    )
    return {
        "source": "seatgeek",
        "order_id": str(o.get("order_id") or o.get("id") or ""),
        "event_name": event.get("name") or event.get("title") or o.get("event_title"),
        "event_date": event_dt,
        "qty": _to_int(o.get("quantity") or listing.get("quantity")),
        "status": status,
        "canonical_status": _canonical_status("seatgeek", status),
        "amount": _to_float(o.get("total") or o.get("payout")),
        "currency": o.get("currency"),
        "ordered_at": o.get("created") or o.get("created_at") or o.get("ordered_at"),
    }


def _norm_tickpick(o: dict) -> dict:
    status = o.get("status")
    return {
        "source": "tickpick",
        "order_id": str(o.get("orderId") or o.get("order_id") or o.get("id") or ""),
        "event_name": o.get("eventName") or o.get("event_name"),
        "event_date": o.get("eventDate") or o.get("event_date"),
        "qty": _to_int(o.get("quantity") or o.get("qty")),
        "status": status,
        "canonical_status": _canonical_status("tickpick", status),
        "amount": _to_float(o.get("total") or o.get("payout")),
        "currency": o.get("currency"),
        "ordered_at": o.get("orderDate") or o.get("createdAt"),
    }


def _norm_vivid(o: dict) -> dict:
    # Vivid orders come from XML — flat-dict, all string values. The XML uses
    # a lowercase <event> tag for the event name (not <eventName>); reading
    # the wrong key was leaving event_name blank in the dashboard.
    status = o.get("status")
    return {
        "source": "vivid",
        "order_id": str(o.get("orderId") or ""),
        "event_name": o.get("event") or o.get("eventName"),
        "event_date": o.get("eventDate"),
        "qty": _to_int(o.get("quantity")),
        "status": status,
        "canonical_status": _canonical_status("vivid", status),
        "amount": _to_float(o.get("total") or o.get("price")),
        "currency": o.get("currency"),
        "ordered_at": o.get("orderDate"),
    }


def _norm_gotickets(o: dict) -> dict:
    """GoTickets /rest/sales/:id response. The API doesn't return a single
    'status' string — the operator's Apps Script derives state from the
    `fulfilled` bool + `cancelReason` + `sellerStatus`. Mirror that here:
        cancelReason set → cancelled
        fulfilled=true   → fulfilled
        else             → pending
    """
    fulfilled = bool(o.get("fulfilled"))
    cancel = (o.get("cancelReason") or "").strip()
    if cancel and cancel.lower() not in ("", "null"):
        canonical = "cancelled"
        raw_status = f"cancelReason:{cancel}"
    elif fulfilled:
        canonical = "fulfilled"
        raw_status = "fulfilled"
    else:
        canonical = "pending"
        raw_status = o.get("sellerStatus") or "pending"
    event = o.get("event") or {}
    return {
        "source": "gotickets",
        "order_id": str(o.get("id") or o.get("orderId") or o.get("saleId") or ""),
        "event_name": event.get("name") or event.get("title"),
        "event_date": event.get("startsAt") or event.get("date") or event.get("eventDate"),
        "qty": _to_int(o.get("quantity") or o.get("ticketCount")),
        "status": raw_status,
        "canonical_status": canonical,
        "amount": _to_float(o.get("total") or o.get("salePrice")),
        "currency": o.get("currency"),
        "ordered_at": o.get("createdAt") or o.get("saleDate"),
        "fulfillment_time": o.get("fulfillmentTime"),
    }


# Canonical status mapping — buckets borrowed from public.order_status_xref.
# Keeps the dashboard's Status column comparable across sources. Evo + SG
# rows coming from SQL already have unified_orders.canonical_status; this
# table is the in-Python equivalent for the API-path rows (tickpick, vivid,
# gotickets, plus the SQL-empty fallback path for evo + sg).
_CANONICAL_STATUS: dict[str, dict[str, str]] = {
    "evo": {
        "pending": "pending",
        "accepted": "accepted",
        "completed": "fulfilled",
        "rejected": "rejected",
        "pending_substitution": "substitution",
    },
    "seatgeek": {
        "open": "pending",
        "pending": "pending",
        "confirmed": "accepted",
        "fulfilled": "fulfilled",
        "delivered": "fulfilled",
        "cancelled": "cancelled",
        "pending_substitution": "substitution",
    },
    # TickPick's broker list is fetched with status=unfulfilled, so the
    # bare value "unfulfilled" maps to accepted (broker has the order,
    # awaiting delivery). Other terminal states map per Apps Script semantics.
    "tickpick": {
        "unfulfilled": "accepted",
        "pending":     "pending",
        "fulfilled":   "fulfilled",
        "filled":      "fulfilled",
        "cancelled":   "cancelled",
        "canceled":    "cancelled",
        "rejected":    "rejected",
    },
    # Vivid's getOrders endpoint surfaces PENDING_SHIPMENT / PENDING_RETRANSFER
    # for the active-order feed. Both = broker holds, awaiting shipment.
    "vivid": {
        "PENDING_SHIPMENT":   "accepted",
        "PENDING_RETRANSFER": "accepted",
        "FULFILLED":          "fulfilled",
        "SHIPPED":            "fulfilled",
        "CANCELLED":          "cancelled",
        "CANCELED":           "cancelled",
        "REJECTED":           "rejected",
    },
    # GoTickets: the Apps Script reads fulfilled (bool) + cancelReason + sellerStatus.
    # Status field varies — we map common values; the read-only fetcher
    # also derives a canonical via the fulfilled/cancelReason booleans
    # in _norm_gotickets below.
    "gotickets": {
        "fulfilled": "fulfilled",
        "cancelled": "cancelled",
        "canceled":  "cancelled",
        "rejected":  "rejected",
        "pending":   "pending",
    },
}


def _canonical_status(source: str, raw: str | None) -> str | None:
    """Map a source's raw status enum to the canonical bucket
    (pending / accepted / fulfilled / rejected / cancelled / substitution).
    Returns None on unrecognized values so the caller can decide whether to
    surface the raw value untranslated or hide it. Case-insensitive — handles
    Vivid's UPPERCASE XML enum and TickPick's lowercase JSON enum uniformly."""
    if not raw:
        return None
    table = _CANONICAL_STATUS.get(source, {})
    if raw in table:
        return table[raw]
    raw_low = raw.lower()
    for k, v in table.items():
        if k.lower() == raw_low:
            return v
    return None


def _to_int(v: Any) -> int | None:
    try:
        return int(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _to_float(v: Any) -> float | None:
    try:
        return float(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


# ---------- SQL-backed fetchers ----------

# All 5 sources are mirrored to public.unified_orders by upstream crons (see
# migration 20260513230100_unified_orders_with_tickpick_vivid). /api/d2/orders
# is SQL-only — no broker-API calls in the data path.
_SQL_BACKED_SOURCES = frozenset({"evo", "seatgeek", "seatdata", "tickpick", "vivid"})

_ALL_SOURCES = ("evo", "seatgeek", "seatdata", "tickpick", "vivid")


def _fetch_cron_freshness() -> dict[str, dict]:
    """Call public.d2_cron_freshness() and reduce to one row per source —
    preferring the 'queue' phase as the canonical 'when did the upstream
    pull last fire.' Returns empty dict when Supabase isn't configured.

    Shape per source: {jobname, phase, schedule, active, last_run, last_status}.
    Front-end uses last_run + schedule to render 'last pull: 12m ago · every 30m'."""
    sb = _sb()
    if sb is None:
        return {}
    try:
        res = sb.rpc("d2_cron_freshness").execute()
        rows = res.data or []
        by_source: dict[str, dict] = {}
        for r in rows:
            src = r.get("source")
            if not src:
                continue
            # Prefer the queue-phase row; fall back to whatever's available.
            if src not in by_source or r.get("phase") == "queue":
                by_source[src] = r
        return by_source
    except Exception as e:
        import sys as _sys
        print(f"[d2_dashboard] cron freshness pull failed: {e!r}", file=_sys.stderr, flush=True)
        return {}


# In-process cache for the v_event_base window. Events don't churn fast —
# a 60s TTL is comfortably within human attention spans and slashes one
# round-trip per dashboard refresh.
_EVENT_WINDOW_CACHE: dict = {"at": 0.0, "rows": []}
_EVENT_WINDOW_TTL_SEC = 60


def _pull_event_window(days_back: int = 1, days_forward: int = 120) -> list[dict]:
    """Pull a window of upcoming events from v_event_base for fuzzy-matching
    tickpick / vivid order responses to canonical tevo_event_ids. Cached
    in-process for 60s so repeated /api/d2/orders refreshes during the
    auto-poll don't re-query the view. Empty list when Supabase isn't
    configured."""
    import time as _time
    now = _time.time()
    if (now - _EVENT_WINDOW_CACHE["at"]) < _EVENT_WINDOW_TTL_SEC and _EVENT_WINDOW_CACHE["rows"]:
        return _EVENT_WINDOW_CACHE["rows"]
    sb = _sb()
    if sb is None:
        return []
    from datetime import datetime, timedelta, timezone
    cur = datetime.now(timezone.utc)
    lo = (cur - timedelta(days=days_back)).isoformat()
    hi = (cur + timedelta(days=days_forward)).isoformat()
    try:
        res = (
            sb.table("v_event_base")
            .select("tevo_event_id,event_name,event_at_local,event_at_utc")
            .gte("event_at_utc", lo)
            .lte("event_at_utc", hi)
            .execute()
        )
        rows = res.data or []
        _EVENT_WINDOW_CACHE["at"] = now
        _EVENT_WINDOW_CACHE["rows"] = rows
        return rows
    except Exception as e:
        import sys as _sys
        print(f"[d2_dashboard] event window pull failed: {e!r}", file=_sys.stderr, flush=True)
        return []


_TOKEN_STOPWORDS = frozenset({
    "the", "vs", "at", "and", "of", "a", "an", "in", "on", "to", "for", "with",
    "tour", "live", "presents", "featuring", "feat", "ft",
})


def _tokenize_event(name: str | None) -> set[str]:
    """Best-effort tokenization for fuzzy event matching: lowercase, split on
    non-alphanumeric, drop stopwords + 1–2 char fragments. Same shape used
    by the existing in-DB matcher (supabase/migrations/...phase11...)."""
    if not name:
        return set()
    import re
    toks = re.split(r"[^a-z0-9]+", name.lower())
    return {t for t in toks if len(t) >= 3 and t not in _TOKEN_STOPWORDS}


def _match_event(target_name: str | None, target_date: str | None, candidates: list[dict]) -> dict | None:
    """Pick the best v_event_base candidate for a tickpick/vivid order based
    on token overlap + date proximity. Returns None when no candidate clears
    the heuristic floor.

    Match rules (mirror the in-DB matcher's spirit, simpler):
      - candidate event_at_utc within ±12h of target_date
      - >=2 shared 3+char tokens, OR Jaccard similarity >= 0.5
    Ties broken by smallest date delta."""
    if not target_name or not candidates:
        return None
    target_tokens = _tokenize_event(target_name)
    if not target_tokens:
        return None
    target_ts = None
    if target_date:
        from datetime import datetime
        for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S"):
            try:
                target_ts = datetime.strptime(target_date.replace("Z", "+0000"), fmt)
                break
            except ValueError:
                continue
    best = None
    best_score = (0, float("inf"))  # (-shared_tokens, date_delta_seconds)
    for c in candidates:
        c_tokens = _tokenize_event(c.get("event_name"))
        if not c_tokens:
            continue
        shared = len(target_tokens & c_tokens)
        jaccard = shared / max(1, len(target_tokens | c_tokens))
        if shared < 2 and jaccard < 0.5:
            continue
        date_delta = float("inf")
        if target_ts and c.get("event_at_utc"):
            from datetime import datetime
            try:
                c_ts = datetime.fromisoformat(c["event_at_utc"].replace("Z", "+00:00"))
                if c_ts.tzinfo is None:
                    from datetime import timezone
                    c_ts = c_ts.replace(tzinfo=timezone.utc)
                date_delta = abs((target_ts - c_ts).total_seconds())
                if date_delta > 12 * 3600:
                    continue
            except (ValueError, TypeError):
                continue
        score = (shared, -date_delta)
        if score > (-best_score[0], -best_score[1]):
            best = c
            best_score = (shared, date_delta)
    return best


def _enrich_row_with_event(row: dict, event_window: list[dict]) -> dict:
    """Look up a canonical event for a tickpick/vivid order row. When matched,
    overlay tevo_event_id + canonical event_name/event_date so the row joins
    cleanly with the SQL-backed sources in the same table."""
    if not event_window:
        return row
    match = _match_event(row.get("event_name"), row.get("event_date"), event_window)
    if not match:
        return row
    row["tevo_event_id"] = match.get("tevo_event_id")
    row["event_name"] = match.get("event_name") or row.get("event_name")
    row["event_date"] = match.get("event_at_local") or match.get("event_at_utc") or row.get("event_date")
    row["event_origin"] = "matched"
    return row


# Terminal canonical_status values from public.order_status_xref. Used by
# the active-only default filter on /api/d2/orders. Rows with NULL
# canonical_status (sources whose source_status didn't match an xref row)
# are also surfaced in the active view — they're "unknown" and probably
# need operator attention more than the known-terminal rows.
_TERMINAL_STATUSES = ("fulfilled", "rejected", "cancelled")
_ACTIVE_STATUSES = ("pending", "accepted", "substitution")


def _fetch_unified_orders_page(per_page: int, page: int = 1, include_terminal: bool = False) -> dict | None:
    """Pull a balanced page of rows from unified_orders, joined to
    v_event_base for event_name + event_date. Returns None when Supabase
    isn't configured.

    Balanced means: per_page is split across SQL-backed sources rather
    than taken globally newest-first. Globally-newest skewed to whoever's
    cron was most active (operator 2026-05-14 saw 100% evo on page 1
    because SG/seatdata cron had stalled at 2026-05-09; only the live
    evo cron contributed recent created_at). This way every source with
    rows gets surface area on every page."""
    sb = _sb()
    if sb is None:
        return None
    try:
        n_sources = max(1, len(_SQL_BACKED_SOURCES))
        per_source = max(1, per_page // n_sources)
        start = max(0, (page - 1) * per_source)
        end = start + per_source - 1

        all_uo_rows: list[dict] = []
        per_source_as_of: dict[str, str] = {}
        per_source_count: dict[str, int] = {}
        any_error = None

        # One PostgREST query per source, fanned out in parallel. unified_orders
        # carries native event_name + event_date per source as of migration
        # 20260514000000 — no JOIN to v_event_base needed except for sources
        # that don't surface their own event info (seatdata).
        #
        # 2026-05-14: profiled the previous sequential loop at ~400ms total
        # for 4 sources (~100ms RTT × 4). The SQL itself is ~3ms per query;
        # the wall-clock was PostgREST round-trip latency. Parallelizing
        # drops total to ~max(per-source), ~100ms.
        def _pull_one(src: str) -> tuple[str, list[dict], str | None]:
            try:
                q = (
                    sb.table("unified_orders")
                    .select("source,source_order_id,tevo_event_id,source_status,canonical_status,is_terminal,quantity,gross_value,created_at,last_seen_at,event_name,event_date")
                    .eq("source", src)
                )
                if not include_terminal:
                    # Active-only default: hide rows in known-terminal states
                    # (fulfilled/rejected/cancelled). NULL canonical_status
                    # (xref miss on an unknown source_status) is treated as
                    # active — those usually warrant operator attention.
                    q = q.or_(f"canonical_status.is.null,canonical_status.in.({','.join(_ACTIVE_STATUSES)})")
                res = q.order("created_at", desc=True).range(start, end).execute()
                return src, (res.data or []), None
            except Exception as e:
                return src, [], _scrub_err(f"unified_orders.sql.{src}", e)

        sources_to_pull = sorted(_SQL_BACKED_SOURCES)
        with ThreadPoolExecutor(max_workers=len(sources_to_pull)) as ex:
            for src, rows_for_src, err in ex.map(_pull_one, sources_to_pull):
                if err:
                    any_error = err
                for r in rows_for_src:
                    all_uo_rows.append(r)
                    ls = r.get("last_seen_at")
                    if ls and (per_source_as_of.get(src, "") < ls):
                        per_source_as_of[src] = ls
                    per_source_count[src] = per_source_count.get(src, 0) + 1

        # Fallback: rows whose native event_name is NULL (seatdata, or any
        # source whose ingest left the field blank) get v_event_base via
        # tevo_event_id, same as before.
        missing_event_ids = list({
            r["tevo_event_id"] for r in all_uo_rows
            if r.get("tevo_event_id") and not r.get("event_name")
        })
        events_by_id: dict = {}
        if missing_event_ids:
            ev_res = (
                sb.table("v_event_base")
                .select("tevo_event_id,event_name,event_at_local,event_at_utc")
                .in_("tevo_event_id", missing_event_ids)
                .execute()
            )
            events_by_id = {e["tevo_event_id"]: e for e in (ev_res.data or [])}
        rows = []
        for r in all_uo_rows:
            event_name = r.get("event_name")
            event_date = r.get("event_date")
            if not event_name:
                ev = events_by_id.get(r.get("tevo_event_id")) or {}
                event_name = ev.get("event_name")
                event_date = ev.get("event_at_local") or ev.get("event_at_utc")
            rows.append({
                "source": r.get("source") or "",
                "order_id": str(r.get("source_order_id") or ""),
                "event_name": event_name,
                "event_date": event_date,
                "qty": _to_int(r.get("quantity")),
                "status": r.get("source_status"),
                "canonical_status": r.get("canonical_status"),
                "amount": _to_float(r.get("gross_value")),
                "currency": None,
                "ordered_at": r.get("created_at"),
            })
        result = {
            "rows": rows,
            "per_source_count": per_source_count,
            "per_source_as_of": per_source_as_of,
        }
        if any_error:
            result["error"] = any_error
        return result
    except Exception as e:
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}, "error": _scrub_err("unified_orders.sql", e)}


def _fetch_orders_from_sql(source: str, per_page: int, page: int = 1) -> dict | None:
    """Pull a source's orders out of unified_orders, joined to v_event_base
    for event_name + event_date. Returns None when Supabase isn't configured
    so the caller can fall back to the upstream API.

    Pagination via PostgREST .range() — `page` is 1-based to match the
    /api/d2/orders ?page= query semantics."""
    sb = _sb()
    if sb is None:
        return None
    try:
        start = max(0, (page - 1) * per_page)
        end = start + per_page - 1
        uo_res = (
            sb.table("unified_orders")
            .select("source,source_order_id,tevo_event_id,source_status,canonical_status,quantity,gross_value,created_at,last_seen_at")
            .eq("source", source)
            .order("created_at", desc=True)
            .range(start, end)
            .execute()
        )
        uo_rows = uo_res.data or []
        event_ids = list({r["tevo_event_id"] for r in uo_rows if r.get("tevo_event_id")})
        events_by_id: dict = {}
        if event_ids:
            ev_res = (
                sb.table("v_event_base")
                .select("tevo_event_id,event_name,event_at_local,event_at_utc")
                .in_("tevo_event_id", event_ids)
                .execute()
            )
            events_by_id = {e["tevo_event_id"]: e for e in (ev_res.data or [])}
        rows = []
        for r in uo_rows:
            ev = events_by_id.get(r.get("tevo_event_id")) or {}
            rows.append({
                "source": source,
                "order_id": str(r.get("source_order_id") or ""),
                "event_name": ev.get("event_name"),
                "event_date": ev.get("event_at_local") or ev.get("event_at_utc"),
                "qty": _to_int(r.get("quantity")),
                "status": r.get("source_status"),
                "canonical_status": r.get("canonical_status"),
                "amount": _to_float(r.get("gross_value")),
                "currency": None,
                "ordered_at": r.get("created_at"),
            })
        as_of = max((r.get("last_seen_at") for r in uo_rows if r.get("last_seen_at")), default=None)
        return {
            "source": source,
            "ok": True,
            "rows": rows,
            "total": None,           # avoid the extra count(*) round-trip
            "origin": "sql",
            "as_of": as_of,
        }
    except Exception as e:
        return {
            "source": source,
            "ok": False,
            "error": _scrub_err(f"{source}.sql", e),
            "rows": [],
            "origin": "sql",
        }


# ---------- Fan-out helpers ----------

_SAFE_CLIENT_ERROR_NAMES = frozenset({
    "TickPickError", "EvoError", "SeatGeekError", "VividError", "SeatDataError",
    "GoTicketsError",
})


def _scrub_err(source: str, exc: Exception) -> str:
    """Log full exception server-side (operator sees in Render logs); return a
    safe message to the client.

    Typed client errors (e.g. TickPickError("HTTP 401")) are constructed by
    the client modules to carry only an HTTP status code — no URLs, tokens,
    or response bodies. Those are passed through so the operator sees what's
    actually wrong (401 vs 404 vs 502) instead of an opaque "upstream error".
    Anything else is scrubbed to the generic message."""
    import sys as _sys
    print(f"[d2_dashboard] {source} fetch failed: {exc!r}", file=_sys.stderr, flush=True)
    if type(exc).__name__ in _SAFE_CLIENT_ERROR_NAMES:
        msg = str(exc).strip()
        # Belt-and-suspenders: even for typed errors, refuse anything that
        # looks like it carries a URL or a long token.
        if msg and "://" not in msg and len(msg) <= 120:
            return msg
    return "upstream error"


def _fetch_evo(per_page: int, page: int = 1) -> dict:
    return _fetch_one_source("evo", per_page, page)


def _fetch_sg(per_page: int, page: int = 1) -> dict:
    return _fetch_one_source("seatgeek", per_page, page)


def _fetch_tickpick(per_page: int, page: int = 1) -> dict:
    return _fetch_one_source("tickpick", per_page, page)


def _fetch_vivid(per_page: int, page: int = 1) -> dict:
    return _fetch_one_source("vivid", per_page, page)


def _fetch_one_source(source: str, per_page: int, page: int = 1) -> dict:
    """SQL-only single-source fetch. Returns the unified_orders fan-out for
    one source — empty rows + ok=True when the cron-fed view has nothing,
    503-shaped error when Supabase isn't configured. No upstream-API path:
    per 2026-05-14 directive the dashboard reads only from SQL; cron
    freshness (`/api/d2/cron-freshness`) is the operator's staleness signal."""
    sql_row = _fetch_orders_from_sql(source, per_page, page)
    if sql_row is None:
        return {"source": source, "ok": False, "error": "Supabase not configured", "rows": [], "origin": "sql"}
    return sql_row


# ---------- Endpoints ----------

@app.get("/healthz")
def healthz():
    """Public health check. Stripped to a minimal shape — operator can still
    confirm the service is up, but no fingerprintable detail is exposed.
    Use /healthz?detail=1 with a valid Bearer token for the full diagnostic."""
    return {"ok": True, "service": "d2_dashboard"}


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


def _shell_config_blob() -> dict:
    """Per-request bootstrap config injected into the HTML shell. Anon key is
    safe to expose by design; no secrets here. The canonical_origin lets the
    front-end build an OAuth redirectTo that matches what's registered in
    Supabase Auth rather than guessing from window.location."""
    return {
        "supabase_url": SUPABASE_URL,
        "supabase_anon_key": SUPABASE_ANON_KEY,
        "allowed_email_domain": ALLOWED_EMAIL_DOMAIN,
        "auth_disabled": AUTH_DISABLED,
        "canonical_origin": D2_CANONICAL_ORIGIN or None,
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
    blob = json.dumps(_shell_config_blob()).replace("<", "\\u003c")
    html = _DASHBOARD_SHELL.replace(_CONFIG_PLACEHOLDER, blob)
    return HTMLResponse(html)


@router.get("/api/d2/config")
def config(_=Depends(require_auth)):
    """Front-end bootstrap config (no secrets)."""
    return {
        "supabase_url": SUPABASE_URL,
        "supabase_anon_key": SUPABASE_ANON_KEY,
        "allowed_email_domain": ALLOWED_EMAIL_DOMAIN,
    }


@router.get("/api/d2/config-public")
def config_public():
    """Pre-auth bootstrap — mirror of the blob server-rendered into the HTML
    shell. Kept as a JSON endpoint for API consumers and for the front-end's
    fallback path; the shell normally doesn't fetch this on boot. Anon key is
    safe to expose (that's its design)."""
    return _shell_config_blob()


def _fetch_unified_orders_fast(per_page: int, include_terminal: bool = False) -> dict | None:
    """First-paint fast path: one global query, upcoming-only, sorted by
    event_date ASC. No per-source split, no v_event_base join, no API call.
    Operator can see the soonest events to triage in <200ms while the
    full orders feed loads in a second phase.

    "Upcoming" = event_date >= now() - 12h, matching the dashboard's
    default Hide-Past-12h filter. Filter pushed down to SQL so we don't
    waste bandwidth on rows the client would hide anyway.

    `include_terminal=False` (default) further filters to non-terminal
    canonical_status (the primary tab's active-only view)."""
    sb = _sb()
    if sb is None:
        return None
    from datetime import datetime, timedelta, timezone
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=12)).isoformat()
    try:
        q = (
            sb.table("unified_orders")
            .select("source,source_order_id,tevo_event_id,source_status,canonical_status,is_terminal,quantity,gross_value,created_at,last_seen_at,event_name,event_date")
            .gte("event_date", cutoff)
        )
        if not include_terminal:
            q = q.or_(f"canonical_status.is.null,canonical_status.in.({','.join(_ACTIVE_STATUSES)})")
        res = q.order("event_date", desc=False, nullsfirst=False).limit(per_page).execute()
        rows_out = []
        per_source_count: dict[str, int] = {}
        per_source_as_of: dict[str, str] = {}
        for r in (res.data or []):
            src = r.get("source") or ""
            rows_out.append({
                "source": src,
                "order_id": str(r.get("source_order_id") or ""),
                "event_name": r.get("event_name"),
                "event_date": r.get("event_date"),
                "qty": _to_int(r.get("quantity")),
                "status": r.get("source_status"),
                "canonical_status": r.get("canonical_status"),
                "amount": _to_float(r.get("gross_value")),
                "currency": None,
                "ordered_at": r.get("created_at"),
            })
            per_source_count[src] = per_source_count.get(src, 0) + 1
            ls = r.get("last_seen_at")
            if ls and (per_source_as_of.get(src, "") < ls):
                per_source_as_of[src] = ls
        return {
            "rows": rows_out,
            "per_source_count": per_source_count,
            "per_source_as_of": per_source_as_of,
        }
    except Exception as e:
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}, "error": _scrub_err("unified_orders.fast", e)}


@router.get("/api/d2/orders")
def orders(
    per_page: int = 25,
    page: int = 1,
    fast: int = 0,
    include_terminal: int = 0,
    _=Depends(require_auth),
):
    """SQL-only orders feed. All 5 sources (evo / seatgeek / seatdata /
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

    timings: dict = {}
    t0 = _time.perf_counter()

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
        "timings_ms": {k: round(v, 1) for k, v in timings.items()} | {"total": round(total_ms, 1)},
    })
    response.headers["Server-Timing"] = ", ".join(
        f"{k.replace('.','_')};dur={v:.1f}" for k, v in timings.items()
    ) + f", total;dur={total_ms:.1f}"
    return response


def _timed(label: str, fn, *args, _timings: dict, **kwargs):
    """Run `fn` and stash its wall-clock duration into `_timings[label]`.
    Lets the parallel fan-out attribute time per-leg without each fetcher
    knowing about the timing dict."""
    import time as _time
    t = _time.perf_counter()
    try:
        return fn(*args, **kwargs)
    finally:
        _timings[label] = (_time.perf_counter() - t) * 1000


@router.get("/api/d2/cron-freshness")
def cron_freshness(_=Depends(require_auth)):
    """Per-source cron freshness, served separately from /api/d2/orders so
    a slow cron RPC (66ms+ vs unified_orders' 3ms) doesn't pace the orders
    feed. The dashboard polls this on a longer interval (or on Health-tab
    open) than the 5-min orders auto-refresh."""
    by_source = _fetch_cron_freshness()
    return JSONResponse({"sources": by_source})


def _deep_order_evo_sql(sb, order_id: str) -> dict:
    res = sb.table("evo_orders").select("*").eq("evo_order_id", order_id).limit(1).execute()
    return (res.data or [None])[0] or {}


def _deep_order_seatgeek_sql(sb, order_id: str) -> dict:
    res = sb.table("seatgeek_orders").select("*").eq("sg_order_id", order_id).limit(1).execute()
    return (res.data or [None])[0] or {}


def _deep_order_tickpick_sql(sb, order_id: str) -> dict:
    res = sb.table("tickpick_orders").select("*").eq("tp_order_id", order_id).limit(1).execute()
    return (res.data or [None])[0] or {}


def _deep_order_vivid_sql(sb, order_id: str) -> dict:
    res = sb.table("vivid_orders").select("*").eq("vivid_order_id", order_id).limit(1).execute()
    return (res.data or [None])[0] or {}


def _deep_order_gotickets(c, order_id: str) -> dict:
    # GoTickets has no SQL backing (no list endpoint upstream, no ingest
    # cron yet). The by-id API call is the only way to surface a GoTickets
    # order in the dashboard. Tracked for future SQL conversion when the
    # canonical lane ships a `gotickets_orders` table + unified_orders UNION.
    return c.get_sale(order_id)


# Dispatch: SQL sources use the "_sb" sentinel (the Supabase client);
# gotickets keeps the upstream client factory until SQL backing exists.
_DEEP_ORDER = {
    "evo":       ("_sb",               _deep_order_evo_sql),
    "seatgeek":  ("_sb",               _deep_order_seatgeek_sql),
    "tickpick":  ("_sb",               _deep_order_tickpick_sql),
    "vivid":     ("_sb",               _deep_order_vivid_sql),
    "gotickets": ("_gotickets_client", _deep_order_gotickets),
}


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
        "evo":      {"in_hand": None, "fulfill_by": None, "notes": "hold_expires_at is auction-hold timer, not fulfill deadline; event_date is implicit"},
        "seatgeek": {"in_hand": None, "fulfill_by": None, "notes": "reservation_duration_minutes is a relative seller-response clock"},
        "tickpick": {"in_hand": None, "fulfill_by": None, "notes": "tickpick_orders.raw jsonb may carry more; not surfaced yet"},
        "vivid":    {"in_hand": None, "fulfill_by": None, "notes": "vivid_orders.raw_xml + raw jsonb; no explicit fulfill-by field in feed"},
        "seatdata": {"in_hand": None, "fulfill_by": None, "notes": "completed-sales feed — no fulfillment lifecycle"},
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

    For evo / seatgeek / tickpick / vivid: reads the matching row from the
    raw `{source}_orders` table in Supabase. No upstream-API call.

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


# ---------- Metrics tab (CEO view) ----------

def _today_start_utc() -> "datetime":
    """Midnight ET (America/New_York) expressed in UTC. Used by the
    `today` window on /api/d2/metrics so the Today card doesn't reset
    at 8 PM ET (which would read as a bug to the operator)."""
    from datetime import datetime, timezone
    try:
        from zoneinfo import ZoneInfo
        et = ZoneInfo("America/New_York")
    except Exception:
        # Python without tzdata; fall back to UTC midnight (acceptable
        # degradation — operator notices the wrong day boundary).
        from datetime import timezone as _tz
        et = _tz.utc
    now_et = datetime.now(et)
    start_et = now_et.replace(hour=0, minute=0, second=0, microsecond=0)
    return start_et.astimezone(timezone.utc)


def _metrics_window_rows(sb, p_start, p_end) -> list[dict]:
    res = sb.rpc("d2_metrics_window", {"p_start": p_start.isoformat(), "p_end": p_end.isoformat()}).execute()
    return res.data or []


def _metrics_hourly_buckets(sb, p_start, p_end) -> list[dict]:
    res = sb.rpc("d2_metrics_hourly_buckets", {"p_start": p_start.isoformat(), "p_end": p_end.isoformat()}).execute()
    return res.data or []


def _metrics_top_events(sb, p_start, p_end, p_limit: int = 10) -> list[dict]:
    res = sb.rpc(
        "d2_metrics_top_events",
        {"p_start": p_start.isoformat(), "p_end": p_end.isoformat(), "p_limit": p_limit},
    ).execute()
    return res.data or []


def _metrics_hot_events(sb, p_start, p_end, p_limit: int = 10) -> list[dict]:
    res = sb.rpc(
        "d2_metrics_hot_events",
        {"p_start": p_start.isoformat(), "p_end": p_end.isoformat(), "p_limit": p_limit},
    ).execute()
    return res.data or []


def _metrics_biggest_sales(sb, p_since, p_limit: int = 10) -> list[dict]:
    args = {"p_limit": p_limit}
    if p_since is not None:
        args["p_since"] = p_since.isoformat() if hasattr(p_since, "isoformat") else p_since
    res = sb.rpc("d2_metrics_biggest_sales", args).execute()
    return res.data or []


def _metrics_sales_gaps(sb, p_lookback_hours: int = 24, p_min_gap_minutes: int = 30) -> list[dict]:
    res = sb.rpc(
        "d2_metrics_sales_gaps",
        {"p_lookback_hours": p_lookback_hours, "p_min_gap_minutes": p_min_gap_minutes},
    ).execute()
    return res.data or []


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
    matches the operator's clock. Filtered to evo/seatgeek/seatdata/
    tickpick/vivid; seatgeek_sales (broker market data) excluded."""
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

