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
  GET  /api/v1/subs/jobs/{job_id}/orders/{order_number}     one order (e.g. to follow its buy)
  GET  /api/v1/subs/results?updated_since=&limit=&offset=   sync feed of answered orders
  POST /api/v1/subs/jobs/{job_id}/orders/{order_number}/buy ask for a quoted EVO cover
  GET  /api/v1/subs/orders/{order_number}                   the same order, newest job, no job id
  POST /api/v1/subs/orders/{order_number}/buy               the same buy, newest job, no job id
  POST /api/v1/subs/orders/{order_number}/offer-sub         GoTickets orders: yes, offer the customer this sub
  POST /api/v1/subs/orders/{order_number}/needs-sub         the ALERT: "this order needs a sub"
  GET  /api/v1/subs/docs                                    the onboarding guide, current version
  GET  /api/v1/subs/balances                                our EVO balances + GoTickets gift cards, read hourly
  GET  /api/v1/subs/autobuys?updated_since=&limit=&offset=  N2S auto-buys placed: what we bought, for which order, totals

`/ping` names the guide's version (`docs.version`), so a CRM that pings can tell when the guide
changed and fetch it again (operator 2026-11-13: "update it in crm when they ping us").

The alert is the integration we ask the CRM for: one "Needs sub" checkbox on an order, which
fires that last call with nothing but the order number in the URL. It is a one-order submit;
ticking twice within NEEDS_SUB_WINDOW_S returns the same lookup instead of starting another.

Built around how the CRM holds orders: an order can be sent as just its number, or as the CRM's
own row under the CRM's field names (ALIASES); whatever is missing is filled from our mirror of
the CRM's books, which also carries the event our mappers already resolved for it.

All the work is in SQL (mig 20261112000000): `sub_finder_submit` stores the orders and fires
the on-demand listing pulls N2S already uses (GETs to EVO, GoTickets and SeatGeek); reading a
job settles it once those pulls have answered. Orders those three found nothing for then get
one TicketsData /match per event (a GET; only when `sub_finder_config.td_enabled`). This
module validates, authenticates and passes through.

Keys are the existing API keys (mcp_api_keys); a key may call only if its id is listed in
`sub_finder_config.key_ids`, and reads only its own jobs. The usual per-minute rate and daily
quota of the key apply.

RULE 2: this module makes no upstream call. The buy route sends nothing either — it files a
`manual_sub_buy` request for an EVO cover this API quoted, and that path (core/manual_sub_buy.py,
its switches, ceilings and one-per-sale rule) decides whether a buy is sent. It is refused
unless `sub_finder_config.buy_enabled` is on and the key is in `buy_key_ids`. That worker then
follows the EVO order until the seller confirms or rejects it; every read of the order here
carries the result (`buy.outcome`, EVO order number, total charged, seat numbers once known).
"""
from __future__ import annotations

import functools
import re
import time
import uuid
from collections.abc import Callable
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, PlainTextResponse

from routers.mcp_api import DEFAULT_DAILY_QUOTA, DEFAULT_RATE_PER_MIN, hash_key

MAX_ORDERS = 200           # hard ceiling here; sub_finder_config.max_orders_per_job can only be lower
MAX_LIMIT = 1000           # the CRM's own page ceiling
NEEDS_SUB_WINDOW_S = 600   # a repeated "needs sub" alert inside this window is the same lookup
_ORDER_NO = re.compile(r"[A-Za-z0-9_.\-]{1,64}")
_ERROR_STATUS = {"forbidden": 403, "invalid": 422, "not_found": 404, "conflict": 409,
                 "confirm_needed": 409}   # a flagged cover: resend with "confirm": true


NOTES_MAX = 500  # characters of a CRM note kept (sub_finder_order.crm_notes)

# RPCs that only read, or whose repeat changes nothing: safe to send a second time when the
# connection to the database API dropped under the first (about 1 call in 30 did, 2026-11-13).
# A buy, an offer, a submit or a note is never repeated: the first may have gone through.
RETRY_ONCE_RPCS = frozenset({"mcp_verify_key", "sub_finder_access", "sub_finder_latest_job",
                             "sub_finder_order_read", "sub_finder_job_json", "sub_finder_results",
                             "sub_finder_autobuys"})


def dropped_connection(exc: BaseException) -> bool:
    """True for an HTTP transport failure (httpx.TransportError and its kin: the connection
    reset, closed or timed out), as opposed to an answer from the database."""
    return any(c.__name__ == "TransportError" for c in type(exc).__mro__)

DOC_PATH = Path(__file__).resolve().parent.parent / "docs" / "sub_finder_api_onboarding.md"
DOCS_ROUTE = "/api/v1/subs/docs"
_DOC_VERSION = re.compile(r"\*\*Doc version:\*\*\s*v([0-9]+(?:\.[0-9]+)*)\s*\((\d{4}-\d{2}-\d{2})\)")
_DOC_OPERATORS = re.compile(r"^## 9\. For S4K operators.*?(?=^## )", re.DOTALL | re.MULTILINE)   # internal switches
_DOC_OPERATORS_LINK = re.compile(r"\s*·\s*\[9 Operators\]\([^)]*\)")                              # its contents entry


def render_crm_doc(text: str) -> dict:
    """The onboarding guide as the CRM gets it: its version and date, the long version history
    cut to that one version, and the operators' section (our own switches and SQL) left out."""
    m = _DOC_VERSION.search(text)
    version, updated = (m.group(1), m.group(2)) if m else (None, None)
    lines = []
    for line in text.splitlines():
        if line.startswith("> **Doc version:**"):
            line = f"> **Doc version:** v{version} ({updated})" if version else "> **Doc version:** unknown"
        elif line.startswith("Code: `routers/subs_api.py`"):
            continue
        lines.append(line)
    markdown = _DOC_OPERATORS_LINK.sub("", _DOC_OPERATORS.sub("", "\n".join(lines) + "\n"))
    return {"version": version, "updated": updated, "markdown": markdown}


@functools.lru_cache(maxsize=4)
def crm_doc(path: Path = DOC_PATH) -> dict | None:
    """The guide shipped with this deploy (read once), or None when the file is not there."""
    try:
        return render_crm_doc(path.read_text(encoding="utf-8"))
    except OSError:
        return None


def _err(status: int, error: str, detail: str | None = None, **extra: Any) -> JSONResponse:
    body = {"error": error, **({"detail": detail} if detail else {}), **extra}
    return JSONResponse(body, status_code=status)


def _text(v: Any, limit: int) -> str | None:
    s = str(v).strip() if v is not None and not isinstance(v, (dict, list)) else ""
    return s[:limit] or None


# The CRM's own field names, mapped onto ours, so one of its rows can be posted unchanged
# (s4kcs_client.py: /n2s/items rows and /marketplace/orders rows). First name present wins.
# `source` comes last for the site: on an N2S row it is the intake source, not the marketplace.
ALIASES = {
    "order_number": ("order_number", "s4k_order_id", "order_id", "order_no"),
    "site": ("site", "marketplace", "source"),
    "qty": ("qty", "quantity"),
    "sold_ea": ("sold_ea", "price_per_ticket"),
    "venue": ("venue", "venue_name"),
    "event_date": ("event_date", "event_dt"),
}


def _pick(raw: dict, name: str) -> Any:
    for k in ALIASES.get(name, (name,)):
        v = raw.get(k)
        if v is not None and not (isinstance(v, str) and not v.strip()):
            return v
    return None


def clean_order(raw: Any, i: int) -> tuple[dict | None, str | None]:
    """One submitted order -> (the row for SQL, None) or (None, why it was refused).

    Only the order number is required: anything else left out is filled from our mirror of the
    CRM's books (SQL, sub_finder_submit). What IS sent is checked here. A bare string is an
    order number; a CRM row is accepted under its own field names (ALIASES)."""
    if isinstance(raw, str):
        raw = {"order_number": raw}
    if not isinstance(raw, dict):
        return None, f"orders[{i}] must be an order number or an object"
    num = _text(_pick(raw, "order_number"), 64)
    if not num or not _ORDER_NO.fullmatch(num):
        return None, f"orders[{i}].order_number is required (letters, digits, '-', '_', '.')"
    out: dict[str, Any] = {"order_number": num}
    for name, limit in (("site", 40), ("venue", 120), ("section", 40), ("row", 20)):
        v = _text(_pick(raw, name), limit)
        if v:
            out[name] = v
    qty = _pick(raw, "qty")
    if qty is not None:
        try:
            n = int(str(qty).strip())
        except ValueError:
            n = 0
        if isinstance(qty, bool) or not 1 <= n <= 50:
            return None, f"orders[{i}].qty must be a whole number from 1 to 50"
        out["qty"] = n
    sold = _pick(raw, "sold_ea")
    if sold is None and out.get("qty") and raw.get("grand_total") is not None:
        try:  # the CRM's N2S rows always carry the total; per ticket is total / quantity
            sold = float(raw["grand_total"]) / out["qty"]
        except (TypeError, ValueError):
            sold = None
    if sold is not None:
        try:
            price = round(float(sold), 2)
        except (TypeError, ValueError):
            price = -1.0
        if isinstance(sold, bool) or not 0 < price < 100000:
            return None, f"orders[{i}].sold_ea must be a positive price per ticket"
        out["sold_ea"] = price
    ev = raw.get("tevo_event_id")
    if ev is not None:
        if isinstance(ev, bool) or not str(ev).strip().isdigit():
            return None, f"orders[{i}].tevo_event_id must be a number"
        out["tevo_event_id"] = int(str(ev).strip())
    ev_name = _text(raw.get("event_name"), 200)
    day = _pick(raw, "event_date")
    if day is not None:
        day = str(day).strip()[:10]  # the CRM's event_dt is a venue-local "YYYY-MM-DDTHH:MM:SS"
        try:
            date.fromisoformat(day)
        except ValueError:
            return None, f"orders[{i}].event_date must be YYYY-MM-DD"
        out["event_date"] = day
    if ev_name:
        out["event_name"] = ev_name
    notes = _text(raw.get("notes"), NOTES_MAX)  # free text of the CRM's own, stored and shown back
    if notes:
        out["notes"] = notes
    return out, None


def orders_of(body: Any) -> Any:
    """The order list of a submit body: {"orders": [...]}, {"order_numbers": [...]}, the CRM's
    own list envelope {"items": [...]}, or a bare list."""
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        for k in ("orders", "order_numbers", "items"):
            if body.get(k) is not None:
                return body[k]
    return None


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
        try:
            return get_db().rpc(name, args).execute().data
        except Exception as exc:  # noqa: BLE001 - re-raised unless it is a dropped connection on a read
            if name not in RETRY_ONCE_RPCS or not dropped_connection(exc):
                raise
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
        scopes = [s for s, on in (("subs:find", access.get("find")), ("subs:buy", access.get("buy")),
                                  ("subs:offer", access.get("offer"))) if on]
        doc = crm_doc(DOC_PATH) or {}
        return {"ok": True, "key_label": key.get("label"), "scopes": scopes,
                "max_orders_per_job": min(int(access.get("max_orders_per_job") or MAX_ORDERS), MAX_ORDERS),
                "ticketsdata_fallback": bool(access.get("ticketsdata_fallback")),
                # the guide's version: when it differs from the one you hold, fetch `docs.url` again
                "docs": {"version": doc.get("version"), "updated": doc.get("updated"), "url": DOCS_ROUTE},
                "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")}

    @router.get("/docs")
    def docs(request: Request, format: str = "json"):
        """The onboarding guide, current with this deploy. `?format=md` answers the Markdown itself."""
        key = _auth(request, "docs")
        if isinstance(key, JSONResponse):
            return key
        doc = crm_doc(DOC_PATH)
        if doc is None:
            return _err(404, "not_found", "the guide is not available on this deploy; ask S4K")
        if format == "md":
            return PlainTextResponse(doc["markdown"], media_type="text/markdown; charset=utf-8",
                                     headers={"X-Doc-Version": str(doc["version"])})
        return {"version": doc["version"], "updated": doc["updated"], "format": "markdown",
                "markdown": doc["markdown"]}

    @router.get("/balances")
    def balances(request: Request):
        """Our EVO office balances and GoTickets gift cards as last read (hourly, mig
        20261113270000). Only for keys in `sub_finder_config.balances_key_ids`."""
        key = _auth(request, "balances")
        if isinstance(key, JSONResponse):
            return key
        return _answer(_rpc("sub_finder_balances", {"p_key_id": key["id"]}))

    @router.get("/autobuys")
    def autobuys(request: Request, updated_since: str | None = None, limit: int = 200, offset: int = 0):
        """Every N2S auto-buy that placed a purchase (operator 2026-11-13): `buy_ref` =
        '<market we bought on>-<its order number>', `for_order` = the order the sub covers, the
        seats bought and the totals. A sync feed like /results (mig 20261113410000); only for keys
        in `sub_finder_config.autobuys_key_ids`. Reads our own tables; calls no market."""
        key = _auth(request, "autobuys")
        if isinstance(key, JSONResponse):
            return key
        since, ok = parse_instant(updated_since)
        if not ok:
            return _err(422, "invalid", "updated_since must be an ISO-8601 instant")
        if not 1 <= limit <= MAX_LIMIT:
            return _err(422, "invalid", f"limit must be between 1 and {MAX_LIMIT}")
        if offset < 0:
            return _err(422, "invalid", "offset must not be negative")
        return _answer(_rpc("sub_finder_autobuys", {"p_key_id": key["id"], "p_updated_since": since,
                                                    "p_limit": limit, "p_offset": offset}))

    @router.post("/jobs")
    async def submit(request: Request):
        key = _auth(request, "submit")
        if isinstance(key, JSONResponse):
            return key
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - any unreadable body is the caller's error
            body = None
        orders = orders_of(body)
        if not isinstance(orders, list) or not orders:
            return _err(422, "invalid", "send {\"orders\": [...]} or {\"order_numbers\": [...]}")
        if len(orders) > MAX_ORDERS:
            return _err(422, "invalid", f"at most {MAX_ORDERS} orders per job")
        rows = []
        for i, raw in enumerate(orders):
            row, why = clean_order(raw, i)
            if why:
                return _err(422, "invalid", why)
            rows.append(row)
        idem = _text(request.headers.get("idempotency-key")
                     or (body.get("idempotency_key") if isinstance(body, dict) else None), 80)
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

    def _read_order(key: dict, job_id: str, order_number: str) -> JSONResponse:
        try:
            jid = str(uuid.UUID(job_id))
        except ValueError:
            jid = ""
        if not jid or not _ORDER_NO.fullmatch(order_number):
            return _err(404, "not_found", "no such order in this job")
        out = _rpc("sub_finder_order_read", {"p_key_id": key["id"], "p_job_id": jid,
                                              "p_order_number": order_number})
        return _err(404, "not_found", "no such order in this job") if out is None else _answer(out)

    @router.get("/jobs/{job_id}/orders/{order_number}")
    def order(job_id: str, order_number: str, request: Request):
        key = _auth(request, "order")
        return key if isinstance(key, JSONResponse) else _read_order(key, job_id, order_number)

    def _latest(key: dict, order_number: str) -> str | None:
        """The newest job of this key holding that order number (so callers need no job ids)."""
        if not _ORDER_NO.fullmatch(order_number):
            return None
        return _rpc("sub_finder_latest_job", {"p_key_id": key["id"], "p_order_number": order_number})

    @router.get("/orders/{order_number}")
    def order_latest(order_number: str, request: Request):
        key = _auth(request, "order")
        if isinstance(key, JSONResponse):
            return key
        jid = _latest(key, order_number)
        if not jid:
            return _err(404, "not_found", "no job holds this order number; submit it first")
        return _read_order(key, str(jid), order_number)

    @router.post("/orders/{order_number}/needs-sub")
    async def needs_sub(order_number: str, request: Request):
        """The alert behind the CRM's "Needs sub" checkbox. The order number in the URL is
        enough; a body may carry the CRM's own row for an order we do not mirror yet."""
        key = _auth(request, "needs_sub")
        if isinstance(key, JSONResponse):
            return key
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - no body is the normal case
            body = None
        raw = dict(body) if isinstance(body, dict) else {}
        raw = {k: v for k, v in raw.items() if k not in ALIASES["order_number"]}
        row, why = clean_order({**raw, "order_number": order_number}, 0)
        if why:
            return _err(422, "invalid", why.replace("orders[0].", "").replace("orders[0] ", ""))
        bucket = int(time.time() // NEEDS_SUB_WINDOW_S)
        out = _rpc("sub_finder_submit", {
            "p_key_id": key["id"], "p_key_label": key.get("label"), "p_orders": [row],
            "p_idempotency_key": f"needs-sub:{row['order_number']}:{bucket}"})  # type: ignore[index]
        return _answer(out, ok_status=202)

    @router.post("/orders/{order_number}/notes")
    async def set_notes(order_number: str, request: Request):
        """Write, replace or clear ("") the CRM's own note on an order. Stored and shown back in
        the order's `notes`; nothing here reads it to decide anything."""
        key = _auth(request, "notes")
        if isinstance(key, JSONResponse):
            return key
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - any unreadable body is the caller's error
            body = None
        notes = body.get("notes") if isinstance(body, dict) else None
        if not isinstance(notes, str) or not _ORDER_NO.fullmatch(order_number):
            return _err(422, "invalid", "send {\"notes\": \"<text, up to 500 characters; empty to clear>\"}")
        if len(notes.strip()) > NOTES_MAX:
            return _err(422, "invalid", f"notes can be at most {NOTES_MAX} characters")
        out = _rpc("sub_finder_set_notes", {"p_key_id": key["id"], "p_order_number": order_number,
                                            "p_notes": notes.strip()})
        return _answer(out)

    @router.post("/orders/{order_number}/buy")
    async def buy_latest(order_number: str, request: Request):
        key = _auth(request, "buy")
        if isinstance(key, JSONResponse):
            return key
        jid = _latest(key, order_number)
        if not jid:
            return _err(404, "not_found", "no job holds this order number; submit it first")
        return await _request_buy(key, str(jid), order_number, request)

    @router.post("/orders/{order_number}/offer-sub")
    async def offer_sub(order_number: str, request: Request):
        """The CRM's yes to `sub_offer.ask_crm`: offer the customer this cover through GoTickets.
        Files a request only; core/gt_sub_offer.py sends it (RULE 2: this module calls no upstream)."""
        key = _auth(request, "offer")
        if isinstance(key, JSONResponse):
            return key
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - any unreadable body is the caller's error
            body = None
        if not isinstance(body, dict):
            body = {}
        listing = _text(body.get("listing_id"), 40)
        if not listing or not _ORDER_NO.fullmatch(listing) or not _ORDER_NO.fullmatch(order_number):
            return _err(422, "invalid", "send {\"listing_id\": \"<listing id from this order's sub_offer>\"}")
        rebate = body.get("rebate_amount")  # the CRM sets the rebate; we only suggest one
        if rebate is not None and (isinstance(rebate, bool) or not isinstance(rebate, (int, float))
                                   or not 0 <= rebate <= 100000):
            return _err(422, "invalid", "rebate_amount must be a number of dollars, 0 or more")
        out = _rpc("sub_finder_gt_offer_confirmed", {
            "p_key_id": key["id"], "p_key_label": key.get("label"), "p_order_number": order_number,
            "p_listing_id": listing, "p_market": _text(body.get("market"), 20),
            "p_requested_by": _text(body.get("requested_by"), 80), "p_rebate_amount": rebate,
            "p_confirm": body.get("confirm") is True})
        return _answer(out, ok_status=202)

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
        return key if isinstance(key, JSONResponse) else await _request_buy(key, job_id, order_number, request)

    async def _request_buy(key: dict, job_id: str, order_number: str, request: Request) -> JSONResponse:
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
        out = _rpc("sub_finder_buy_confirmed", {
            "p_key_id": key["id"], "p_key_label": key.get("label"), "p_job_id": jid,
            "p_order_number": order_number, "p_listing_id": listing,
            "p_requested_by": _text(body.get("requested_by"), 80),
            "p_confirm": body.get("confirm") is True})
        return _answer(out, ok_status=202)

    return router
