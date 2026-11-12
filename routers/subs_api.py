"""Sub finder API (/api/v1/subs) — a CRM user sends orders and gets substitutes back.

Operator 2026-11-12: "turn this into an out bound api trigger where crm user can auto get
subs for orders". The CRM calls us; we never call the CRM.

The shape copies the CRM's own API (s4kcs_client.py) so its developers meet nothing new: an
`X-API-Key` header (a Bearer token works too), `/ping` reporting what the key may do, list
answers in a `count / total / limit / offset / items / generated_at` envelope, and
`updated_since` as the sync cursor — feed each answer's `generated_at` back as the next call's
`updated_since`, paging oldest-change-first so a row touched mid-walk is not skipped.

  GET  /api/v1/subs/ping                                    key check + what it may do
  POST /api/v1/subs/jobs                                    submit orders -> job id (202)
  GET  /api/v1/subs/jobs/{job_id}                           one job: status + every order
  GET  /api/v1/subs/results?updated_since=&limit=&offset=   sync feed of answered orders
  POST /api/v1/subs/jobs/{job_id}/orders/{order_number}/buy ask for a quoted EVO cover

All the work is in SQL (mig 20261112000000): `sub_finder_submit` stores the orders and fires
the on-demand listing pulls N2S already uses (GETs to EVO, GoTickets and SeatGeek); reading a
job settles it once those pulls have answered. This module validates, authenticates and
passes through.

Keys are the existing API keys (mcp_api_keys); a key may call only if its id is listed in
`sub_finder_config.key_ids`, and reads only its own jobs. The usual per-minute rate and daily
quota of the key apply.

RULE 2: this module makes no upstream call. The buy route sends nothing either — it files a
`manual_sub_buy` request for an EVO cover this API quoted, and that path (core/manual_sub_buy.py,
its switches, ceilings and one-per-sale rule) decides whether a buy is sent. It is refused
unless `sub_finder_config.buy_enabled` is on and the key is in `buy_key_ids`.
"""
from __future__ import annotations

import re
import uuid
from collections.abc import Callable
from datetime import date, datetime, timezone
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from routers.mcp_api import DEFAULT_DAILY_QUOTA, DEFAULT_RATE_PER_MIN, hash_key

MAX_ORDERS = 200           # hard ceiling here; sub_finder_config.max_orders_per_job can only be lower
MAX_LIMIT = 1000           # the CRM's own page ceiling
_ORDER_NO = re.compile(r"[A-Za-z0-9_.\-]{1,64}")
_ERROR_STATUS = {"forbidden": 403, "invalid": 422, "not_found": 404, "conflict": 409}


def _err(status: int, error: str, detail: str | None = None, **extra: Any) -> JSONResponse:
    body = {"error": error, **({"detail": detail} if detail else {}), **extra}
    return JSONResponse(body, status_code=status)


def _text(v: Any, limit: int) -> str | None:
    s = str(v).strip() if v is not None and not isinstance(v, (dict, list)) else ""
    return s[:limit] or None


def clean_order(raw: Any, i: int) -> tuple[dict | None, str | None]:
    """One submitted order -> (the row for SQL, None) or (None, why it was refused)."""
    if not isinstance(raw, dict):
        return None, f"orders[{i}] must be an object"
    num = _text(raw.get("order_number"), 64)
    if not num or not _ORDER_NO.fullmatch(num):
        return None, f"orders[{i}].order_number is required (letters, digits, '-', '_', '.')"
    section, row = _text(raw.get("section"), 40), _text(raw.get("row"), 20)
    if not section or not row:
        return None, f"orders[{i}] needs section and row"
    try:
        qty = int(str(raw.get("qty")).strip())
    except (TypeError, ValueError):
        qty = 0
    if isinstance(raw.get("qty"), bool) or not 1 <= qty <= 50:
        return None, f"orders[{i}].qty must be a whole number from 1 to 50"
    sold = raw.get("sold_ea")
    if sold is not None:
        try:
            sold = round(float(sold), 2)
        except (TypeError, ValueError):
            sold = -1
        if isinstance(raw.get("sold_ea"), bool) or not 0 < sold < 100000:
            return None, f"orders[{i}].sold_ea must be a positive price per ticket"
    out = {"order_number": num, "site": _text(raw.get("site"), 40), "venue": _text(raw.get("venue"), 120),
           "section": section, "row": row, "qty": qty, "sold_ea": sold}
    ev = raw.get("tevo_event_id")
    if ev is not None:
        if isinstance(ev, bool) or not str(ev).strip().isdigit():
            return None, f"orders[{i}].tevo_event_id must be a number"
        out["tevo_event_id"] = int(str(ev).strip())
        return out, None
    name, day = _text(raw.get("event_name"), 200), _text(raw.get("event_date"), 10)
    try:
        date.fromisoformat(day or "")
    except ValueError:
        day = None
    if not name or not day:
        return None, f"orders[{i}] needs tevo_event_id, or event_name with event_date (YYYY-MM-DD)"
    out.update(event_name=name, event_date=day)
    return out, None


def parse_instant(value: str | None) -> tuple[str | None, bool]:
    """`updated_since` -> (UTC ISO string or None, ok). A value with no zone is read as UTC."""
    if value is None or not value.strip():
        return None, True
    try:
        dt = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None, False
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat(), True


def make_router(get_db: Callable[[], Any], limiter: Any | None = None) -> APIRouter:
    router = APIRouter(prefix="/api/v1/subs", tags=["subs-api"])

    def _rpc(name: str, args: dict) -> Any:
        return get_db().rpc(name, args).execute().data

    def _auth(request: Request, tool: str) -> dict | JSONResponse:
        """The key's row, or the refusal to send. Counts the call against the key's quota."""
        auth = request.headers.get("authorization", "")
        key = (auth[7:].strip() if auth.lower().startswith("bearer ")
               else request.headers.get("x-api-key", "").strip())
        row = None
        if key:
            try:
                rows = _rpc("mcp_verify_key", {"p_key_hash": hash_key(key)}) or []
                row = rows[0] if rows else None
            except Exception:  # noqa: BLE001 - a key we cannot verify is a key we refuse
                row = None
        if not row or row.get("id") is None:
            return _err(401, "unauthorized", "missing or invalid API key (send it as X-API-Key)")
        rate = int(row.get("rate_per_min") or DEFAULT_RATE_PER_MIN)
        if limiter is not None and not limiter.check(f"subs:{row['id']}", rate, 60.0):
            return _err(429, "rate_limited", retry_after_seconds=60, rate_per_min=rate)
        quota = int(row.get("daily_quota") or DEFAULT_DAILY_QUOTA)
        if int(row.get("calls_today") or 0) >= quota:
            return _err(429, "quota_exhausted", "daily quota used up; resets at 00:00 UTC",
                              daily_quota=quota)
        try:
            _rpc("mcp_count_call", {"p_key_id": row["id"], "p_tool": f"subs.{tool}"})
        except Exception:  # noqa: BLE001 - a usage stamp must never fail the request
            pass
        return row

    def _answer(out: Any, ok_status: int = 200) -> JSONResponse:
        """A SQL answer -> HTTP: its own error code picks the status; NULL is a 404."""
        if out is None:
            return _err(404, "not_found", "no such job for this key")
        if isinstance(out, dict) and out.get("error"):
            return JSONResponse(out, status_code=_ERROR_STATUS.get(out["error"], 400))
        return JSONResponse(out, status_code=ok_status)

    @router.get("/ping")
    def ping(request: Request):
        key = _auth(request, "ping")
        if isinstance(key, JSONResponse):
            return key
        access = _rpc("sub_finder_access", {"p_key_id": key["id"]}) or {}
        scopes = [s for s, on in (("subs:find", access.get("find")), ("subs:buy", access.get("buy"))) if on]
        return {"ok": True, "key_label": key.get("label"), "scopes": scopes,
                "max_orders_per_job": min(int(access.get("max_orders_per_job") or MAX_ORDERS), MAX_ORDERS),
                "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")}

    @router.post("/jobs")
    async def submit(request: Request):
        key = _auth(request, "submit")
        if isinstance(key, JSONResponse):
            return key
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - any unreadable body is the caller's error
            body = None
        orders = body.get("orders") if isinstance(body, dict) else None
        if not isinstance(orders, list) or not orders:
            return _err(422, "invalid", "send {\"orders\": [...]} with at least one order")
        if len(orders) > MAX_ORDERS:
            return _err(422, "invalid", f"at most {MAX_ORDERS} orders per job")
        rows = []
        for i, raw in enumerate(orders):
            row, why = clean_order(raw, i)
            if why:
                return _err(422, "invalid", why)
            rows.append(row)
        idem = _text(request.headers.get("idempotency-key") or body.get("idempotency_key"), 80)  # type: ignore[union-attr]
        out = _rpc("sub_finder_submit", {"p_key_id": key["id"], "p_key_label": key.get("label"),
                                         "p_orders": rows, "p_idempotency_key": idem})
        return _answer(out, ok_status=202)

    @router.get("/jobs/{job_id}")
    def job(job_id: str, request: Request):
        key = _auth(request, "job")
        if isinstance(key, JSONResponse):
            return key
        try:
            jid = str(uuid.UUID(job_id))
        except ValueError:
            return _err(404, "not_found", "no such job for this key")
        return _answer(_rpc("sub_finder_job_json", {"p_key_id": key["id"], "p_job_id": jid}))

    @router.get("/results")
    def results(request: Request, updated_since: str | None = None, limit: int = 200, offset: int = 0):
        key = _auth(request, "results")
        if isinstance(key, JSONResponse):
            return key
        since, ok = parse_instant(updated_since)
        if not ok:
            return _err(422, "invalid", "updated_since must be an ISO-8601 instant")
        if not 1 <= limit <= MAX_LIMIT:
            return _err(422, "invalid", f"limit must be between 1 and {MAX_LIMIT}")
        if offset < 0:
            return _err(422, "invalid", "offset must not be negative")
        return _answer(_rpc("sub_finder_results", {"p_key_id": key["id"], "p_updated_since": since,
                                                   "p_limit": limit, "p_offset": offset}))

    @router.post("/jobs/{job_id}/orders/{order_number}/buy")
    async def buy(job_id: str, order_number: str, request: Request):
        key = _auth(request, "buy")
        if isinstance(key, JSONResponse):
            return key
        try:
            jid = str(uuid.UUID(job_id))
        except ValueError:
            return _err(404, "not_found", "no such order in this job")
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - any unreadable body is the caller's error
            body = None
        if not isinstance(body, dict):
            body = {}
        listing = _text(body.get("listing_id"), 20)
        if not listing or not listing.isdigit() or not _ORDER_NO.fullmatch(order_number):
            return _err(422, "invalid", "send {\"listing_id\": \"<EVO listing id from this job>\"}")
        out = _rpc("sub_finder_buy", {
            "p_key_id": key["id"], "p_key_label": key.get("label"), "p_job_id": jid,
            "p_order_number": order_number, "p_listing_id": listing,
            "p_requested_by": _text(body.get("requested_by"), 80)})
        return _answer(out, ok_status=202)

    return router
