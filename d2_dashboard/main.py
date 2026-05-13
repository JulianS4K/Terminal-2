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
  AUTH_DISABLED                 "true" to bypass the Supabase JWT gate entirely.
                                Works regardless of platform — operator opts in
                                explicitly. Loud startup stderr warning when on.
                                TESTING ONLY; unset for production.

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

import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import requests
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, JSONResponse

# ---------- Bootstrap ----------

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
ALLOWED_EMAIL_DOMAIN = os.environ.get("ALLOWED_EMAIL_DOMAIN", "s4kent.com")

AUTH_DISABLED = os.environ.get("AUTH_DISABLED", "false").lower() == "true"


def _is_production() -> bool:
    """Production detector mirrored from app.py:54-66. If ANY indicator says
    production, treat as production and deny the AUTH_DISABLED kill switch."""
    return bool(
        (os.environ.get("RAILWAY_ENVIRONMENT") or "").lower() == "production"
        or (os.environ.get("ENVIRONMENT") or "").lower() == "production"
        or (os.environ.get("NODE_ENV") or "").lower() == "production"
        or (os.environ.get("PYTHON_ENV") or "").lower() == "production"
        or os.environ.get("FLY_APP_NAME")
        or os.environ.get("RENDER")
    )


_AUTH_DISABLED_REQUESTED = AUTH_DISABLED
AUTH_DISABLED = AUTH_DISABLED and not _is_production()
if _AUTH_DISABLED_REQUESTED and not AUTH_DISABLED:
    import sys as _sys
    print(
        "WARNING: AUTH_DISABLED=true ignored — production indicator detected "
        "(RAILWAY_ENVIRONMENT / ENVIRONMENT / NODE_ENV / PYTHON_ENV / "
        "FLY_APP_NAME / RENDER). The Supabase JWT gate stays on.",
        file=_sys.stderr,
        flush=True,
    )
elif AUTH_DISABLED:
    import sys as _sys
    print(
        "WARNING: AUTH_DISABLED=true — /api/d2/* endpoints are unauthenticated. "
        "TESTING ONLY. Unset AUTH_DISABLED to restore the Supabase JWT gate.",
        file=_sys.stderr,
        flush=True,
    )

TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"

app = FastAPI(title="D2 Orders Dashboard — unified broker view")


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
    event = o.get("event") or {}
    items = o.get("items") or []
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
    # Vivid orders come from XML — flat-dict, all string values.
    return {
        "source": "vivid",
        "order_id": str(o.get("orderId") or ""),
        "event_name": o.get("eventName"),
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

def _scrub_err(source: str, exc: Exception) -> str:
    """Log full exception server-side (operator sees in Render logs); return a
    stable, generic message to the client so upstream error text — which can
    include URLs, partial tokens, internal IDs — never makes it to the wire."""
    import sys as _sys
    print(f"[d2_dashboard] {source} fetch failed: {exc!r}", file=_sys.stderr, flush=True)
    return "upstream error"


def _fetch_evo(per_page: int) -> dict:
    c = _evo_client()
    if c is None:
        return {"source": "evo", "ok": False, "error": "no creds", "rows": []}
    try:
        body = c.list_orders(per_page=min(per_page, 10))
        rows = [_norm_evo(o) for o in (body.get("orders") or [])]
        return {"source": "evo", "ok": True, "rows": rows, "total": body.get("total_entries")}
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


@app.get("/")
def root():
    path = TEMPLATES_DIR / "dashboard.html"
    if not path.exists():
        raise HTTPException(500, "dashboard.html missing")
    return FileResponse(str(path), media_type="text/html")


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
    """Pre-auth bootstrap — front-end needs SUPABASE_URL + ANON_KEY to show
    the login UI. These are public values (anon key is safe to expose;
    that's its design). `auth_disabled` lets the front-end skip the login
    screen when the server is in testing mode."""
    return {
        "supabase_url": SUPABASE_URL,
        "supabase_anon_key": SUPABASE_ANON_KEY,
        "allowed_email_domain": ALLOWED_EMAIL_DOMAIN,
        "auth_disabled": AUTH_DISABLED,
    }


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
