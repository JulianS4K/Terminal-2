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
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ---------- Bootstrap ----------

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
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

# Anonymous-by-default. Operator decision 2026-05-13: the dashboard goes
# straight into the orders view with no Google sign-in step. Set
# AUTH_DISABLED=false on the Render service env to restore the Supabase JWT
# gate later (front-end will then surface the login screen). No production
# self-disable — the lack of a gate is the intended posture, not a leak.
AUTH_DISABLED = os.environ.get("AUTH_DISABLED", "true").lower() == "true"

if AUTH_DISABLED:
    import sys as _sys
    print(
        "d2_dashboard: AUTH_DISABLED=true — /api/d2/* endpoints serve "
        "unauthenticated reads of merged broker order data. Set "
        "AUTH_DISABLED=false on the service env to restore the Supabase JWT gate.",
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

app = FastAPI(title="D2 Orders Dashboard — unified broker view")

if STATIC_DIR.is_dir():
    app.mount("/static/d2", StaticFiles(directory=str(STATIC_DIR)), name="d2_static")


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
    return {
        "source": "evo",
        "order_id": str(o.get("id") or ""),
        "event_name": event.get("name"),
        "event_date": event.get("occurs_at"),
        "qty": qty,
        "status": o.get("state"),
        "amount": _to_float(o.get("total")),
        "currency": o.get("currency"),
        "ordered_at": o.get("created_at"),
    }


def _norm_sg(o: dict) -> dict:
    event = o.get("event") or {}
    return {
        "source": "seatgeek",
        "order_id": str(o.get("order_id") or o.get("id") or ""),
        "event_name": event.get("title") or o.get("event_title"),
        "event_date": event.get("datetime_local") or event.get("datetime_utc"),
        "qty": _to_int(o.get("quantity")),
        "status": o.get("status"),
        "amount": _to_float(o.get("total") or o.get("payout")),
        "currency": o.get("currency"),
        "ordered_at": o.get("created_at") or o.get("ordered_at"),
    }


def _norm_tickpick(o: dict) -> dict:
    return {
        "source": "tickpick",
        "order_id": str(o.get("orderId") or o.get("order_id") or o.get("id") or ""),
        "event_name": o.get("eventName") or o.get("event_name"),
        "event_date": o.get("eventDate") or o.get("event_date"),
        "qty": _to_int(o.get("quantity") or o.get("qty")),
        "status": o.get("status"),
        "amount": _to_float(o.get("total") or o.get("payout")),
        "currency": o.get("currency"),
        "ordered_at": o.get("orderDate") or o.get("createdAt"),
    }


def _norm_vivid(o: dict) -> dict:
    # Vivid orders come from XML — flat-dict, all string values. The XML uses
    # a lowercase <event> tag for the event name (not <eventName>); reading
    # the wrong key was leaving event_name blank in the dashboard.
    return {
        "source": "vivid",
        "order_id": str(o.get("orderId") or ""),
        "event_name": o.get("event") or o.get("eventName"),
        "event_date": o.get("eventDate"),
        "qty": _to_int(o.get("quantity")),
        "status": o.get("status"),
        "amount": _to_float(o.get("total") or o.get("price")),
        "currency": o.get("currency"),
        "ordered_at": o.get("orderDate"),
    }


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


def _fetch_evo(per_page: int) -> dict:
    # Mirrors the operator's reference Tkinter app: pull orders in both
    # accepted and pending states, merge + dedupe by id. Evo's list_orders
    # caps per_page at 10 server-side, so per_page maps to "per state".
    c = _evo_client()
    if c is None:
        return {"source": "evo", "ok": False, "error": "no creds", "rows": []}
    try:
        cap = min(per_page, 10)
        seen: dict[str, dict] = {}
        total_any: int | None = None
        for state in ("accepted", "pending"):
            body = c.list_orders(per_page=cap, state=state)
            if total_any is None:
                total_any = body.get("total_entries")
            for o in body.get("orders") or []:
                row = _norm_evo(o)
                if row["order_id"]:
                    seen.setdefault(row["order_id"], row)
        rows = list(seen.values())
        return {"source": "evo", "ok": True, "rows": rows, "total": total_any}
    except Exception as e:
        return {"source": "evo", "ok": False, "error": _scrub_err("evo", e), "rows": []}


def _fetch_sg(per_page: int) -> dict:
    c = _sg_client()
    if c is None:
        return {"source": "seatgeek", "ok": False, "error": "no creds", "rows": []}
    try:
        body = c.seller_orders("open", page=1)
        rows = [_norm_sg(o) for o in (body.get("orders") or [])][:per_page]
        return {"source": "seatgeek", "ok": True, "rows": rows, "total": (body.get("meta") or {}).get("total")}
    except Exception as e:
        return {"source": "seatgeek", "ok": False, "error": _scrub_err("seatgeek", e), "rows": []}


def _fetch_tickpick(per_page: int) -> dict:
    c = _tickpick_client()
    if c is None:
        return {"source": "tickpick", "ok": False, "error": "no creds", "rows": []}
    try:
        body = c.list_orders()
        rows = [_norm_tickpick(o) for o in (body or [])][:per_page]
        return {"source": "tickpick", "ok": True, "rows": rows, "total": len(body or [])}
    except Exception as e:
        return {"source": "tickpick", "ok": False, "error": _scrub_err("tickpick", e), "rows": []}


def _fetch_vivid(per_page: int) -> dict:
    c = _vivid_client()
    if c is None:
        return {"source": "vivid", "ok": False, "error": "no creds", "rows": []}
    try:
        body = c.list_active_orders()
        rows = [_norm_vivid(o) for o in (body or [])][:per_page]
        return {"source": "vivid", "ok": True, "rows": rows, "total": len(body or [])}
    except Exception as e:
        return {"source": "vivid", "ok": False, "error": _scrub_err("vivid", e), "rows": []}


# ---------- Sample fan-out ----------
#
# /api/d2/samples picks one read endpoint per source at random and returns a
# single record. Lets the operator see at a glance what shape each source
# delivers without paging through the full table. All endpoints are GETs
# already covered by the read-only guards; quota cost is one call per source.

def _first_or_none(items):
    return items[0] if items else None


def _sample_evo(c) -> tuple[str, Any, int | None]:
    import random
    candidates = [
        ("list_events",     lambda: (c.list_events(per_page=1),     "events",     "total_entries")),
        ("list_performers", lambda: (c.list_performers(per_page=1), "performers", "total_entries")),
        ("list_venues",     lambda: (c.list_venues(per_page=1),     "venues",     "total_entries")),
        ("list_orders",     lambda: (c.list_orders(per_page=1),     "orders",     "total_entries")),
    ]
    label, fn = random.choice(candidates)
    body, key, total_key = fn()
    return label, _first_or_none(body.get(key) or []), body.get(total_key)


def _sample_seatgeek(c) -> tuple[str, Any, int | None]:
    import random
    candidates = [
        ("seller_listings", lambda: c.seller_listings(per_page=1)),
        ("seller_orders",   lambda: c.seller_orders("open", page=1)),
    ]
    label, fn = random.choice(candidates)
    body = fn() or {}
    if label == "seller_listings":
        return label, _first_or_none(body.get("listings") or []), (body.get("meta") or {}).get("total")
    return label, _first_or_none(body.get("orders") or []), (body.get("meta") or {}).get("total")


def _sample_tickpick(c) -> tuple[str, Any, int | None]:
    body = c.list_orders() or []
    return "list_orders", _first_or_none(body), len(body)


def _sample_vivid(c) -> tuple[str, Any, int | None]:
    import random
    candidates = [
        ("list_active_orders",             lambda: c.list_active_orders()),
        ("list_pending_retransfer_orders", lambda: c.list_pending_retransfer_orders()),
    ]
    label, fn = random.choice(candidates)
    body = fn() or []
    return label, _first_or_none(body), len(body)


def _sample_seatdata(c) -> tuple[str, Any, int | None]:
    import random
    candidates = [
        ("account", lambda: c.account()),
        ("usage",   lambda: c.usage()),
    ]
    label, fn = random.choice(candidates)
    # account() / usage() return a single dict, not a list — surface as-is.
    return label, fn(), None


# Client factories referenced by name (not by direct binding) so tests can
# monkeypatch d2_main._evo_client etc. and have the override take effect at
# call time instead of being shadowed by an early-captured reference.
_SAMPLE_FETCHERS = (
    ("evo",      "_evo_client",      _sample_evo),
    ("seatgeek", "_sg_client",       _sample_seatgeek),
    ("tickpick", "_tickpick_client", _sample_tickpick),
    ("vivid",    "_vivid_client",    _sample_vivid),
    ("seatdata", "_seatdata_client", _sample_seatdata),
)


def _fetch_sample(source: str, client_factory_name: str, sampler) -> dict:
    import sys as _sys
    client_factory = getattr(_sys.modules[__name__], client_factory_name)
    c = client_factory()
    if c is None:
        return {"source": source, "ok": False, "error": "no creds", "method": None, "sample": None}
    try:
        method, sample, total = sampler(c)
        return {
            "source": source,
            "ok": True,
            "method": method,
            "sample": sample,
            "total_available": total,
        }
    except Exception as e:
        return {
            "source": source,
            "ok": False,
            "error": _scrub_err(f"{source}.sample", e),
            "method": None,
            "sample": None,
        }


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
            "evo":      {"token_set": bool(_env_first("TEVO_API_TOKEN", "TEVO_TOKEN")),
                         "secret_set": bool(_env_first("TEVO_API_SECRET", "TEVO_SECRET")),
                         "sandbox": os.environ.get("TEVO_SANDBOX", "false").lower() == "true"},
            "seatgeek": {"token_set": bool(os.environ.get("SEATGEEK_API_TOKEN"))},
            "tickpick": {"token_set": bool(_env_first("TICKPICK_API_TOKEN", "TICKPICK_TOKEN"))},
            "vivid":    {"token_set": bool(os.environ.get("VIVID_API_TOKEN"))},
            "seatdata": {"key_set":   bool(os.environ.get("SEATDATA_API_KEY"))},
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


@app.get("/")
def root():
    if PROD_MISSING_SUPABASE:
        raise HTTPException(503, "d2_dashboard misconfigured: SUPABASE_URL / SUPABASE_ANON_KEY not set")
    if not _DASHBOARD_SHELL:
        raise HTTPException(500, "dashboard.html missing")
    # JSON.stringify equivalent — escape `<` to defuse `</script>` injection
    # from any future config field that ends up reflecting user input.
    blob = json.dumps(_shell_config_blob()).replace("<", "\\u003c")
    html = _DASHBOARD_SHELL.replace(_CONFIG_PLACEHOLDER, blob)
    return HTMLResponse(html)


@app.get("/api/d2/config")
def config(_=Depends(require_auth)):
    """Front-end bootstrap config (no secrets)."""
    return {
        "supabase_url": SUPABASE_URL,
        "supabase_anon_key": SUPABASE_ANON_KEY,
        "allowed_email_domain": ALLOWED_EMAIL_DOMAIN,
    }


@app.get("/api/d2/config-public")
def config_public():
    """Pre-auth bootstrap — mirror of the blob server-rendered into the HTML
    shell. Kept as a JSON endpoint for API consumers and for the front-end's
    fallback path; the shell normally doesn't fetch this on boot. Anon key is
    safe to expose (that's its design)."""
    return _shell_config_blob()


@app.get("/api/d2/orders")
def orders(per_page: int = 25, _=Depends(require_auth)):
    """Fan out to all 4 broker order surfaces in parallel, return one
    normalized table. Each source reports ok/error independently so a
    single dead source doesn't blank the page."""
    per_page = max(1, min(per_page, 100))
    fetchers = (_fetch_evo, _fetch_sg, _fetch_tickpick, _fetch_vivid)
    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=4) as ex:
        futures = [ex.submit(fn, per_page) for fn in fetchers]
        for f in futures:
            results.append(f.result())
    merged: list[dict] = []
    sources_summary = []
    for r in results:
        merged.extend(r.get("rows") or [])
        sources_summary.append({
            "source": r["source"],
            "ok": r.get("ok", False),
            "count": len(r.get("rows") or []),
            "total_reported": r.get("total"),
            "error": r.get("error"),
        })
    # Sort newest first by ordered_at (string ISO compares fine, None last).
    merged.sort(key=lambda x: (x.get("ordered_at") or ""), reverse=True)
    return JSONResponse({"sources": sources_summary, "rows": merged})


def _deep_order_evo(c, order_id: str) -> dict:
    return c.get_order(int(order_id))


def _deep_order_seatgeek(c, order_id: str) -> dict:
    return c.seller_order(order_id)


def _deep_order_tickpick(c, order_id: str) -> dict:
    return c.get_order_details(order_id)


def _deep_order_vivid(c, order_id: str) -> dict:
    return c.get_order(int(order_id))


_DEEP_ORDER = {
    "evo":      ("_evo_client",      _deep_order_evo),
    "seatgeek": ("_sg_client",       _deep_order_seatgeek),
    "tickpick": ("_tickpick_client", _deep_order_tickpick),
    "vivid":    ("_vivid_client",    _deep_order_vivid),
}


@app.get("/api/d2/order/{source}/{order_id}")
def order_detail(source: str, order_id: str, _=Depends(require_auth)):
    """Single-order deep fetch. Hits the source's by-id read endpoint and
    returns the raw response so the dashboard can render seats, customer,
    notes, etc. Read-only — no fulfillment / transfer / write endpoints are
    wired here per the 2026-05-13 lockdown."""
    if source not in _DEEP_ORDER:
        raise HTTPException(404, f"unknown source: {source}")
    import sys as _sys
    factory_name, fetcher = _DEEP_ORDER[source]
    client_factory = getattr(_sys.modules[__name__], factory_name)
    c = client_factory()
    if c is None:
        return JSONResponse({"ok": False, "error": "no creds"}, status_code=200)
    try:
        return JSONResponse({"ok": True, "source": source, "order_id": order_id, "data": fetcher(c, order_id)})
    except Exception as e:
        return JSONResponse(
            {"ok": False, "source": source, "order_id": order_id, "error": _scrub_err(f"{source}.order_detail", e)},
            status_code=200,
        )


@app.get("/api/d2/samples")
def samples(_=Depends(require_auth)):
    """Pull one randomly-picked record per source. Fans out in parallel; each
    source surfaces its own ok/error so a single dead source doesn't blank
    the response. Useful for sanity-checking which sources are wired and what
    record shape each one delivers."""
    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=len(_SAMPLE_FETCHERS)) as ex:
        futures = [ex.submit(_fetch_sample, src, cf_name, sf) for src, cf_name, sf in _SAMPLE_FETCHERS]
        for f in futures:
            results.append(f.result())
    return JSONResponse({"samples": results})


@app.get("/api/d2/seatdata")
def seatdata(_=Depends(require_auth)):
    """SeatData analytics tab — account info + budget usage. Not an order
    surface; reads the same SeatData client D2 owns."""
    c = _seatdata_client()
    if c is None:
        return JSONResponse({"ok": False, "error": "no creds"}, status_code=200)
    payload: dict[str, Any] = {"ok": True}
    try:
        payload["account"] = c.account()
    except Exception as e:
        payload["account_error"] = _scrub_err("seatdata.account", e)
    try:
        payload["usage"] = c.usage()
    except Exception as e:
        payload["usage_error"] = _scrub_err("seatdata.usage", e)
    return JSONResponse(payload)
