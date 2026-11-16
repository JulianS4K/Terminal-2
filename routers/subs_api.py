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
  GET  /api/v1/subs/buys?updated_since=&limit=&offset=      every purchase either buyer placed (N2S auto-buyer + this API), one feed
  GET  /api/v1/subs/settings/auto-buy-loss                  the automatic buy's loss limits (need2buy orders), by marketplace
  PUT  /api/v1/subs/settings/auto-buy-loss                  set them: percent of the sale total, 100 to 200
  GET  /api/v1/subs/settings/limits                         the CRM's own limits on a rebate and on a buy's cost, percent of the sale
  PUT  /api/v1/subs/settings/limits                         set them (a key that may buy or offer, from its registered address)
  GET  /api/v1/subs/audit?since=&limit=&offset=             every buy, offer and limit change asked here, with its source address

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

One account can hold several keys (mig 20261116000000, asked for by the CRM): a key listed in
`sub_finder_key` acts for its `account_id` (the key id the jobs are filed under) with only the
rights its row gives it, so a key that syncs results cannot spend. `_auth` enforces that, and
the addresses a key is accepted from, before anything reaches the SQL: past it, `key["id"]` is
the account. Every buy, offer and limit change is written to `sub_finder_audit` with the
address it came from, and an accepted one is repeated from there for the same Idempotency-Key.

RULE 2: this module makes no upstream call. The buy route sends nothing either — it files a
`manual_sub_buy` request for an EVO cover this API quoted, and that path (core/manual_sub_buy.py,
its switches, ceilings and one-per-sale rule) decides whether a buy is sent. It is refused
unless `sub_finder_config.buy_enabled` is on and the key is in `buy_key_ids`. That worker then
follows the EVO order until the seller confirms or rejects it; every read of the order here
carries the result (`buy.outcome`, EVO order number, total charged, seat numbers once known).
"""
from __future__ import annotations

import functools
import hashlib
import ipaddress
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
                             "sub_finder_autobuys", "sub_finder_loss_limits", "sub_finder_buys",
                             "sub_finder_key_gate", "sub_finder_idem", "sub_finder_audit_read",
                             "sub_finder_limits"})

# what a call needs from its key beyond reading: _auth refuses it before any SQL runs
_NEED_REFUSAL = {"buy": "this key may not buy", "offer": "this key may not offer subs",
                 "write": "this key may not change settings"}


def ip_allowed(ip: str | None, allowed: list) -> bool:
    """True when `ip` is one of `allowed` (single addresses or CIDR ranges, IPv4 or IPv6).
    Anything unreadable on either side is a no."""
    try:
        addr = ipaddress.ip_address((ip or "").strip())
    except ValueError:
        return False
    for a in allowed:
        try:
            if addr in ipaddress.ip_network(str(a).strip(), strict=False):
                return True
        except ValueError:
            continue
    return False


def forwarded_ip(xff: str | None, hops: int, trusted: list) -> str | None:
    """The caller's address from X-Forwarded-For when `hops` proxies of ours stand in front: the
    entry that many from the end (1 = the last). Each of our proxies appends the address that
    connected to it, so entries further left were written by the caller and prove nothing.
    The count is not taken on faith: every entry after the caller's was written by one of our
    proxies about another, so each must be inside `trusted` (our edge's published ranges). A
    request that skipped a proxy, or carries a made-up chain, fails that and has no address.
    None also when the chain is shorter than `hops`: never fall back to a part a caller can write."""
    parts = [p.strip() for p in (xff or "").split(",") if p.strip()]
    if not 1 <= hops <= len(parts):
        return None
    if any(not ip_allowed(p, trusted) for p in parts[len(parts) - hops + 1:]):
        return None
    return parts[-hops]


# the request headers a proxy may put the caller's address in; shown by /ping while ping_shows_headers is on
FORWARDING_HEADERS = ("x-forwarded-for", "cf-connecting-ip", "true-client-ip", "x-real-ip", "forwarded",
                      "cf-connecting-ipv6", "cf-ray", "x-forwarded-proto", "x-forwarded-host", "via")


# The only headers the caller's address may be read from: ones Cloudflare itself writes on every
# request and does not let a caller, a Worker or a rule set. Any other name is refused, whatever
# the setting says.
EDGE_ADDRESS_HEADERS = frozenset({"cf-connecting-ip", "true-client-ip"})


def header_ip(name: str, values: list, xff: str | None, trusted: list) -> str | None:
    """The caller's address from the one header our edge writes it in (mig 20261116020000). It is
    believed only on a request our edge handed to the host: the last X-Forwarded-For entry, which
    the host's router writes itself, must be inside `trusted`. Anything else is no address: a
    header name outside EDGE_ADDRESS_HEADERS, the header sent more than once, or a value that is
    not exactly one address."""
    parts = [p.strip() for p in (xff or "").split(",") if p.strip()]
    if name not in EDGE_ADDRESS_HEADERS or not parts or not ip_allowed(parts[-1], trusted):
        return None
    if len(values) != 1:
        return None
    v = values[0].strip()
    try:
        return str(ipaddress.ip_address(v))
    except ValueError:
        return None


def dropped_connection(exc: BaseException) -> bool:
    """True for an HTTP transport failure (httpx.TransportError and its kin: the connection
    reset, closed or timed out), as opposed to an answer from the database."""
    return any(c.__name__ == "TransportError" for c in type(exc).__mro__)

DOC_PATH = Path(__file__).resolve().parent.parent / "docs" / "sub_finder_api_onboarding.md"
DOCS_ROUTE = "/api/v1/subs/docs"
_DOC_VERSION_MARK = "\x00doc-version\x00"   # stands in for the fingerprint while it is being worked out
_DOC_OPERATORS = re.compile(r"^## 9\. For S4K operators.*?(?=^## )", re.DOTALL | re.MULTILINE)   # internal switches
_DOC_OPERATORS_LINK = re.compile(r"\s*·\s*\[9 Operators\]\([^)]*\)")                              # its contents entry


def render_crm_doc(text: str) -> dict:
    """The onboarding guide as the CRM gets it, with the operators' section (our own switches and
    SQL) left out. Its version is a fingerprint of exactly what is served, so it changes when,
    and only when, the guide the CRM reads changes. Nobody numbers it by hand (the doc's version
    line is not edited, README *Doc-writing rules* §5). `updated` is kept as a key for older
    clients and is always None: compare `version` for equality."""
    lines = []
    for line in text.splitlines():
        if line.startswith("> **Doc version:**"):
            line = f"> **Doc version:** {_DOC_VERSION_MARK}"
        elif line.startswith("Code: `routers/subs_api.py`"):
            continue
        lines.append(line)
    markdown = _DOC_OPERATORS_LINK.sub("", _DOC_OPERATORS.sub("", "\n".join(lines) + "\n"))
    version = hashlib.sha256(markdown.encode("utf-8")).hexdigest()[:12]
    return {"version": version, "updated": None, "markdown": markdown.replace(_DOC_VERSION_MARK, version)}


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

    def _audit(key: dict, action: str, order_number: str | None, listing: str | None,
               status: int, out: Any, requested_by: Any = None, idem: str | None = None) -> None:
        """One row in sub_finder_audit. Never fails the call it records."""
        try:
            _rpc("sub_finder_audit_log", {
                "p_account_id": key["id"], "p_key_id": key["key_id"], "p_key_label": key.get("label"),
                "p_action": action, "p_order_number": order_number, "p_listing_id": listing,
                "p_source_ip": key.get("ip"), "p_requested_by": _text(requested_by, 80), "p_idem_key": idem,
                "p_http_status": status, "p_response": out if isinstance(out, dict) else None})
        except Exception:  # noqa: BLE001 - the buy or offer already happened; its own table holds it
            pass

    def _refuse(key: dict, need: str | None, request: Request, why: str) -> JSONResponse:
        """403, recorded when the call was a buy, an offer or a settings change."""
        out = {"error": "forbidden", "detail": why}
        if need:
            _audit(key, {"write": "settings"}.get(need, need), request.path_params.get("order_number"),
                   None, 403, out)
        return JSONResponse(out, status_code=403)

    def _auth(request: Request, tool: str, need: str | None = None) -> dict | JSONResponse:
        """The key, or the refusal to send. Counts the call against the key's quota. `need` is
        what the call does beyond reading: "buy", "offer" or "write" (a settings change).
        In the answer `id` is the ACCOUNT the key acts for (what every SQL call is given),
        `key_id` the key itself and `ip` the address the call came from."""
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
        gate = _rpc("sub_finder_key_gate", {"p_key_id": row["id"]}) or {}   # no answer: the key acts for itself
        # the address the call came from: the X-Forwarded-For entry our own proxies vouch for (mig
        # 20261116010000; the last entry alone is our edge, not the caller). No header: a direct connection.
        xff = request.headers.get("x-forwarded-for")
        trusted = gate.get("trusted_proxies") or []
        if gate.get("client_ip_header"):          # the header our edge writes the caller's address in
            ip = header_ip(gate["client_ip_header"], request.headers.getlist(gate["client_ip_header"]), xff, trusted)
        else:
            ip = (forwarded_ip(xff, int(gate.get("client_ip_hops") or 1), trusted) if xff
                  else request.client.host if request.client else None)
        key = dict(row, id=gate.get("account_id") or row["id"], key_id=row["id"], ip=ip, gate=gate)
        allowed = gate.get("allowed_ips") or []
        if allowed and not ip_allowed(ip, allowed):
            return _refuse(key, need, request, "this key is accepted only from its registered addresses")
        if need and gate.get("listed") and not (
                gate.get(need) if need != "write" else gate.get("buy") or gate.get("offer")):
            return _refuse(key, need, request, _NEED_REFUSAL[need])
        if need and gate.get("write_requires_ip") and not allowed:
            return _refuse(key, need, request, "this key cannot buy, offer or change settings until S4K "
                                               "registers the address it calls from")
        return key

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
        gate = key["gate"]
        # what THIS key may do: its account's rights, narrowed by the key's own row and addresses
        writes = not (gate.get("write_requires_ip") and not gate.get("allowed_ips"))
        scopes = [s for s, on in (
            ("subs:find", access.get("find")),
            ("subs:buy", access.get("buy") and writes and gate.get("buy", True)),
            ("subs:offer", access.get("offer") and writes and gate.get("offer", True))) if on]
        doc = crm_doc(DOC_PATH) or {}
        # an operator's aid for choosing where the caller's address is read from; off unless switched on
        seen = ({"forwarding_headers": {h: request.headers.get(h) for h in FORWARDING_HEADERS}}
                if gate.get("ping_shows_headers") else {})
        return {**seen, "ok": True, "key_label": key.get("label"), "scopes": scopes,
                "max_orders_per_job": min(int(access.get("max_orders_per_job") or MAX_ORDERS), MAX_ORDERS),
                "ticketsdata_fallback": bool(access.get("ticketsdata_fallback")),
                # the address we saw this call come from, and the ones this key is accepted from ([] = any)
                "your_ip": key.get("ip"), "allowed_ips": gate.get("allowed_ips") or [],
                # dollars a buy asked with this key is held to, and the most a rebate may be; null = no limit
                "limits": access.get("limits") or {},
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

    @router.get("/settings/auto-buy-loss")
    def loss_limits(request: Request):
        """The automatic buy's loss limit for need2buy orders: the default and each marketplace's
        own, as a percent of the sale total (mig 20261113320000)."""
        key = _auth(request, "loss_limits")
        if isinstance(key, JSONResponse):
            return key
        return _answer(_rpc("sub_finder_loss_limits", {"p_key_id": key["id"]}))

    @router.put("/settings/auto-buy-loss")
    async def set_loss_limits(request: Request):
        """Set the limits: {"default_max_cost_pct": 100-200 | null, "by_marketplace": {name: 100-200 | null}}.
        Only for keys in `sub_finder_config.loss_limit_key_ids`; the SQL validates every value and
        changes nothing unless all are valid. It moves no money by itself: it widens or narrows what
        the automatic buy may take for need2buy orders, inside the same spend ceilings."""
        key = _auth(request, "loss_limits_set", "write")
        if isinstance(key, JSONResponse):
            return key
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - any unreadable body is the caller's error
            body = None
        if not isinstance(body, dict):
            return _err(422, "invalid", "send a JSON object: {\"default_max_cost_pct\": 105, "
                                        "\"by_marketplace\": {\"stubhub\": 110}}")
        by = body.get("set_by")
        out = _rpc("sub_finder_loss_limits_set", {
            "p_key_id": key["id"], "p_key_label": key.get("label"),
            "p_body": {k: v for k, v in body.items() if k in ("default_max_cost_pct", "by_marketplace")},
            "p_by": by if isinstance(by, str) else None})
        resp = _answer(out)
        _audit(key, "settings", None, None, resp.status_code, out, by if isinstance(by, str) else None)
        return resp

    @router.get("/settings/limits")
    def limits(request: Request):
        """The limits the CRM has put on its own inputs, each a percent of the sale total, with a
        default and its own value per marketplace sold on (mig 20261116030000): `rebate_max_pct`
        on an offer's rebate and `buy_max_cost_pct` on the cost of a cover it asks us to buy."""
        key = _auth(request, "limits")
        if isinstance(key, JSONResponse):
            return key
        return _answer(_rpc("sub_finder_limits", {"p_key_id": key["id"]}))

    @router.put("/settings/limits")
    async def set_limits(request: Request):
        """Set them: {"rebate_max_pct": {"default": 0-100 | null, "by_marketplace": {name: 0-100 | null}},
        "buy_max_cost_pct": {"default": 1-1000 | null, "by_marketplace": {...}}}; either may be left out.
        Only a key that may buy or offer, from its registered address. The SQL validates every value
        and changes nothing unless all are valid. The change is recorded with who made it."""
        key = _auth(request, "limits_set", "write")
        if isinstance(key, JSONResponse):
            return key
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - any unreadable body is the caller's error
            body = None
        if not isinstance(body, dict):
            return _err(422, "invalid", "send a JSON object: {\"rebate_max_pct\": {\"default\": 40}, "
                                        "\"buy_max_cost_pct\": {\"default\": 110}}")
        by = body.get("set_by")
        out = _rpc("sub_finder_limits_set", {
            "p_key_id": key["id"], "p_key_label": key.get("label"),
            "p_body": {k: v for k, v in body.items() if k in ("rebate_max_pct", "buy_max_cost_pct")},
            "p_by": by if isinstance(by, str) else None})
        resp = _answer(out)
        _audit(key, "settings", None, None, resp.status_code, out, by if isinstance(by, str) else None)
        return resp

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

    @router.get("/buys")
    def buys(request: Request, updated_since: str | None = None, limit: int = 200, offset: int = 0):
        """Every purchase either buyer placed, in one sync feed (mig 20261113430000): the N2S
        auto-buyer's (`buyer` = 'n2s_auto', the same items as /autobuys) and this API's
        (`buyer` = 'sub_finder'). Same envelope, same keys as /autobuys
        (`sub_finder_config.autobuys_key_ids`). Reads our own tables; calls no market."""
        key = _auth(request, "buys")
        if isinstance(key, JSONResponse):
            return key
        since, ok = parse_instant(updated_since)
        if not ok:
            return _err(422, "invalid", "updated_since must be an ISO-8601 instant")
        if not 1 <= limit <= MAX_LIMIT:
            return _err(422, "invalid", f"limit must be between 1 and {MAX_LIMIT}")
        if offset < 0:
            return _err(422, "invalid", "offset must not be negative")
        return _answer(_rpc("sub_finder_buys", {"p_key_id": key["id"], "p_updated_since": since,
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
        key = _auth(request, "buy", "buy")
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
        key = _auth(request, "offer", "offer")
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
        idem, again = _replay(key, request, body, "offer", order_number, listing)
        if again is not None:
            return again
        out = _rpc("sub_finder_gt_offer_confirmed", {
            "p_key_id": key["id"], "p_key_label": key.get("label"), "p_order_number": order_number,
            "p_listing_id": listing, "p_market": _text(body.get("market"), 20),
            "p_requested_by": _text(body.get("requested_by"), 80), "p_rebate_amount": rebate,
            "p_confirm": body.get("confirm") is True})
        resp = _answer(out, ok_status=202)
        _audit(key, "offer", order_number, listing, resp.status_code, out, body.get("requested_by"), idem)
        return resp

    @router.get("/audit")
    def audit(request: Request, since: str | None = None, limit: int = 200, offset: int = 0):
        """Every buy, offer and loss-limit change asked through this API for the account, newest
        first, refusals included: time, key, source address, order, listing, amount, outcome
        (mig 20261116000000). Reads our own table; calls no market."""
        key = _auth(request, "audit")
        if isinstance(key, JSONResponse):
            return key
        at, ok = parse_instant(since)
        if not ok:
            return _err(422, "invalid", "since must be an ISO-8601 instant")
        if not 1 <= limit <= MAX_LIMIT:
            return _err(422, "invalid", f"limit must be between 1 and {MAX_LIMIT}")
        if offset < 0:
            return _err(422, "invalid", "offset must not be negative")
        return _answer(_rpc("sub_finder_audit_read", {"p_key_id": key["id"], "p_since": at,
                                                      "p_limit": limit, "p_offset": offset}))

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
        key = _auth(request, "buy", "buy")
        return key if isinstance(key, JSONResponse) else await _request_buy(key, job_id, order_number, request)

    def _replay(key: dict, request: Request, body: dict, action: str, order_number: str,
                listing: str) -> tuple[str | None, JSONResponse | None]:
        """(the call's Idempotency-Key, the answer to send instead of acting). A key that already
        got a buy or offer accepted gets that same answer again, so a retry after a timeout is
        safe; the same key on a different order or listing is the caller's mistake."""
        idem = _text(request.headers.get("idempotency-key") or body.get("idempotency_key"), 80)
        if not idem:
            return None, None
        first = _rpc("sub_finder_idem", {"p_account_id": key["id"], "p_idem_key": idem})
        if not first:
            return idem, None
        if (first.get("action"), first.get("order_number"), first.get("listing_id")) != (action, order_number, listing):
            return idem, _err(422, "invalid", "this Idempotency-Key was already used for a different buy or offer")
        return idem, JSONResponse(first.get("response"), status_code=202, headers={"Idempotent-Replay": "true"})

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
        idem, again = _replay(key, request, body, "buy", order_number, listing)
        if again is not None:
            return again
        out = _rpc("sub_finder_buy_confirmed", {
            "p_key_id": key["id"], "p_key_label": key.get("label"), "p_job_id": jid,
            "p_order_number": order_number, "p_listing_id": listing,
            "p_requested_by": _text(body.get("requested_by"), 80),
            "p_confirm": body.get("confirm") is True})
        resp = _answer(out, ok_status=202)
        _audit(key, "buy", order_number, listing, resp.status_code, out, body.get("requested_by"), idem)
        return resp

    return router
