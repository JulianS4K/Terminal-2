"""Sale-accept client for GoTickets, SeatGeek, Vivid and TickPick — confirm OUR OWN pending sale.

Operator authorization 2026-11-10: "not just evo sales, any sales that have an active token and
ability to confirm order". With evo_buy_client.py (EVO accept), this lets the N2S live worker
accept the sale it just covered on the market that sold it. Exactly one write per market, each
path-pinned by ``SALE_ACCEPT_WRITES`` (``scripts/check_readonly.py`` requires the literal):

  GoTickets Seller Central  POST  sc.gotickets.com/rest/sales/{orderId}/confirm
  SeatGeek SellerDirect     PATCH sellerdirect-api.seatgeek.com/order   (order_id, status=confirmed)
  Vivid Broker Portal       POST  brokers.vividseats.com/webservices/v1/confirmOrder
  TickPick seller API       POST  api.tickpick.com/1.0/orders/{orderNumber}/confirmation
                                  (operator 2026-11-10: "add tickpick to auto-accept markets",
                                  "build tickpick now", after N2S's TickPick sales were shown to
                                  be visible to our TickPick seller login while open)

There is no reject, cancel, price or listing write, and none may be added without the operator's
written authorization (security-CRIT, CLAUDE.md RULE 2). Writes are never retried: a timeout or
5xx is "unknown outcome" and the caller stops.

TickPick through the database (operator 2026-11-16): TickPick refuses API calls from the web
service's address, while the database's calls get through (first live attempt, exec 8). With
``tickpick_db`` set, TickPick's sale read and confirm are database calls instead:
n2s_tickpick_sale_state (a GET) and n2s_tickpick_confirm (the same single confirm, sent at most
once per N2S row, only for a row whose lease the caller holds; mig 20261116181000).
"""
from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any
from urllib.parse import urlsplit

import requests

from evo_buy_client import EvoWriteRejected, EvoWriteUnknown


class SaleAcceptError(Exception):
    """Raised when the guard refuses a request."""


ALLOWED_HTTP_METHODS = frozenset({"GET", "PATCH", "POST"})

# (method, host, path regex): the ONLY writes this client may send. Security-CRIT to widen.
SALE_ACCEPT_WRITES = (("POST", "sc.gotickets.com", r"^/rest/sales/\d+/confirm$"), ("PATCH", "sellerdirect-api.seatgeek.com", r"^/order$"), ("POST", "brokers.vividseats.com", r"^/webservices/v1/confirmOrder$"), ("POST", "api.tickpick.com", r"^/1\.0/orders/\d+/confirmation$"))
_WRITES = tuple((m, h, re.compile(p)) for m, h, p in SALE_ACCEPT_WRITES)
READ_HOSTS = frozenset({"sc.gotickets.com", "sellerdirect-api.seatgeek.com", "brokers.vividseats.com", "api.tickpick.com"})


def _assert_readonly_method(method: str, url: str = "") -> None:
    """GET to the four sale hosts; a write only if it is one of SALE_ACCEPT_WRITES."""
    m = method.upper()
    parts = urlsplit(url)
    if m not in ALLOWED_HTTP_METHODS:
        raise SaleAcceptError(f"READ-ONLY violation: method {method} is not allowed. RULE 2 (CLAUDE.md §2).")
    if parts.scheme != "https" or parts.hostname not in READ_HOSTS:
        raise SaleAcceptError(f"READ-ONLY violation: host {parts.hostname!r} is not a sale host.")
    if m != "GET" and not any(m == wm and parts.hostname == wh and wr.match(parts.path) for wm, wh, wr in _WRITES):
        raise SaleAcceptError(f"READ-ONLY violation: {m} {parts.hostname}{parts.path} is not a sanctioned "
                              "sale accept (RULE 2, operator 2026-11-10).")


# Sale states that mean "still waiting for us to accept" (from our order-timer log; TickPick's
# seller_status from the N2S TickPick watch, 20261110040000).
PENDING = {"gotickets": frozenset({"UNCONFIRMED"}), "seatgeek": frozenset({"submitted", "pending", "open"}),
           "vivid": frozenset({"UNCONFIRMED"}), "tickpick": frozenset({"Unconfirmed"})}

TokenSource = Callable[[], "str | None"]
DbCall = Callable[[str, dict], Any]


class SaleAcceptClient:
    def __init__(self, *, gt_id: str | None = None, gt_secret: str | None = None, sg_token: str | None = None,
                 vivid_token: str | None = None, tickpick_token: TokenSource | str | None = None,
                 tickpick_db: DbCall | None = None, session: Any = None, timeout: float = 20.0):
        self.gt_id, self.gt_secret, self.sg_token, self.vivid_token = gt_id, gt_secret, sg_token, vivid_token
        # TickPick's token is replaced about daily (tickpick_token_refresh): pass a callable so each
        # use reads the current one instead of a token cached at start-up.
        self.tickpick_token = tickpick_token
        # (rpc name, params) -> the database function's JSON answer. Set: TickPick's read and
        # confirm go out from the database (see the module docstring).
        self.tickpick_db = tickpick_db
        self.session = session or requests.Session()
        self.timeout = timeout

    def _tp_token(self) -> str | None:
        t = self.tickpick_token
        return t() if callable(t) else t

    def has_market(self, market: str) -> bool:
        if market == "tickpick":
            return bool(self._tp_token())
        return {"gotickets": bool(self.gt_id and self.gt_secret), "seatgeek": bool(self.sg_token),
                "vivid": bool(self.vivid_token)}.get(market, False)

    def _send(self, method: str, url: str, **kw: Any) -> Any:
        _assert_readonly_method(method, url)  # RULE 2 enforcement, before anything is sent
        try:
            resp = self.session.request(method, url, timeout=self.timeout, **kw)
        except requests.RequestException as e:
            # Never let the requests error (its message holds the full URL, Vivid's apiToken
            # included) reach logs or the status route: path + error type only, no chain.
            where = f"{urlsplit(url).path}: {type(e).__name__}"
            if method != "GET":
                raise EvoWriteUnknown(where) from None
            raise SaleAcceptError(where) from None
        if resp.status_code >= 500 and method != "GET":
            raise EvoWriteUnknown(f"{urlsplit(url).path}: HTTP {resp.status_code}")
        if resp.status_code >= 400:
            raise EvoWriteRejected(resp.status_code, (resp.text or "")[:500])
        return resp

    def _gt_headers(self) -> dict:
        return {"X-Api-Access-Id": self.gt_id or "", "X-Api-Access-Secret": self.gt_secret or "",
                "Accept": "application/json"}

    def _tp_headers(self) -> dict:
        return {"Authorization": f"Bearer {self._tp_token() or ''}", "Accept": "application/json"}

    def sale_state(self, market: str, order_id: Any) -> str | None:
        """The market's own status of our sale (as the order timer reads it)."""
        oid = str(order_id)
        if market == "gotickets":
            r = self._send("GET", f"https://sc.gotickets.com/rest/sales/{int(oid)}", headers=self._gt_headers())
            return (r.json() or {}).get("sellerStatus")
        if market == "seatgeek":
            r = self._send("GET", "https://sellerdirect-api.seatgeek.com/order",
                           params={"order_id": oid}, headers={"token": self.sg_token or ""})
            return (r.json() or {}).get("status")
        if market == "vivid":
            r = self._send("GET", "https://brokers.vividseats.com/webservices/v1/getOrder",
                           params={"apiToken": self.vivid_token or "", "orderId": oid})
            m = re.search(r"<status>([^<]*)</status>", r.text or "")
            return m.group(1) if m else None
        if market == "tickpick":
            if self.tickpick_db is not None:
                return self._tp_db_sale_state(int(oid))
            r = self._send("GET", f"https://api.tickpick.com/1.0/orders/{int(oid)}", headers=self._tp_headers())
            return (r.json() or {}).get("seller_status")
        raise SaleAcceptError(f"no sale-accept support for {market!r}")

    def _tp_db_sale_state(self, order_number: int) -> str | None:
        try:
            out = self.tickpick_db("n2s_tickpick_sale_state", {"p_order_number": str(order_number)})  # type: ignore[misc]
        except Exception as e:  # noqa: BLE001 - a read: the caller treats any failure as "cannot see the sale"
            raise SaleAcceptError(f"TickPick read via the database: {type(e).__name__}") from None
        out = out if isinstance(out, dict) else {}
        status, detail = out.get("http"), str(out.get("error") or "")[:500]
        if status == 200:
            return out.get("seller_status")
        if isinstance(status, int) and 400 <= status < 500:
            raise EvoWriteRejected(status, detail)
        raise SaleAcceptError(f"TickPick read via the database: HTTP {status}: {detail}"[:500])

    def _tp_db_confirm(self, order_number: int, exec_id: Any, lease_token: Any) -> dict:
        """The confirm, from the database. Any answer we cannot read as TickPick's is unknown."""
        if exec_id is None or not lease_token:
            raise SaleAcceptError("a TickPick confirm needs the N2S row and its lease")
        try:
            out = self.tickpick_db("n2s_tickpick_confirm", {  # type: ignore[misc]
                "p_exec_id": int(exec_id), "p_token": str(lease_token), "p_order_number": str(order_number)})
        except Exception as e:  # noqa: BLE001 - the database may have sent it: unknown, never retried here
            raise EvoWriteUnknown(f"/1.0/orders/{order_number}/confirmation via the database: {type(e).__name__}") from None
        if not isinstance(out, dict):
            raise EvoWriteUnknown(f"/1.0/orders/{order_number}/confirmation via the database: no answer")
        if out.get("refused"):  # the database's own checks stopped it: nothing was sent
            raise EvoWriteRejected(409, f"not sent: {out['refused']}")
        status, body = out.get("http"), str(out.get("body") or "")
        if isinstance(status, int) and 200 <= status < 300:
            return {"state": "accepted", "http": status, "body": body[:300]}
        if isinstance(status, int) and 400 <= status < 500:
            raise EvoWriteRejected(status, body[:500])
        raise EvoWriteUnknown(f"/1.0/orders/{order_number}/confirmation via the database: HTTP {status}")

    def accept(self, market: str, order_id: Any, *, exec_id: Any = None, lease_token: Any = None) -> dict:
        """Confirm our pending sale. Never retried by this client. ``exec_id`` and ``lease_token``
        (the N2S row and this worker's lease) are what the database checks for a TickPick confirm."""
        oid = str(order_id)
        if market == "tickpick" and self.tickpick_db is not None:
            return self._tp_db_confirm(int(oid), exec_id, lease_token)
        if market == "gotickets":
            r = self._send("POST", f"https://sc.gotickets.com/rest/sales/{int(oid)}/confirm", headers=self._gt_headers())
        elif market == "seatgeek":
            r = self._send("PATCH", "https://sellerdirect-api.seatgeek.com/order", headers={"token": self.sg_token or ""},
                           files={"order_id": (None, oid), "status": (None, "confirmed")})
        elif market == "vivid":
            r = self._send("POST", "https://brokers.vividseats.com/webservices/v1/confirmOrder",
                           data={"apiToken": self.vivid_token or "", "orderId": oid, "shipNow": "false"})
        elif market == "tickpick":  # ConfirmOrderRequest: no required fields
            r = self._send("POST", f"https://api.tickpick.com/1.0/orders/{int(oid)}/confirmation",
                           headers=self._tp_headers(), json={})
        else:
            raise SaleAcceptError(f"no sale-accept support for {market!r}")
        text = (r.text or "")[:300]
        if re.search(r"<success>\s*false\s*</success>", text, re.I):  # Vivid answers errors with HTTP 200
            raise EvoWriteRejected(r.status_code, text)
        return {"state": "accepted", "http": r.status_code, "body": text}
