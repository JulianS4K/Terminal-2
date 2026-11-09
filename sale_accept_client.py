"""Sale-accept client for GoTickets, SeatGeek and Vivid — confirm OUR OWN pending sale.

Operator authorization 2026-11-10: "not just evo sales, any sales that have an active token and
ability to confirm order". With evo_buy_client.py (EVO accept), this lets the N2S live worker
accept the sale it just covered on the market that sold it. Exactly one write per market, each
path-pinned by ``SALE_ACCEPT_WRITES`` (``scripts/check_readonly.py`` requires the literal):

  GoTickets Seller Central  POST  sc.gotickets.com/rest/sales/{orderId}/confirm
  SeatGeek SellerDirect     PATCH sellerdirect-api.seatgeek.com/order   (order_id, status=confirmed)
  Vivid Broker Portal       POST  brokers.vividseats.com/webservices/v1/confirmOrder

There is no reject, cancel, price or listing write, and none may be added without the operator's
written authorization (security-CRIT, CLAUDE.md RULE 2). Writes are never retried: a timeout or
5xx is "unknown outcome" and the caller stops.
"""
from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlsplit

import requests

from evo_buy_client import EvoWriteRejected, EvoWriteUnknown


class SaleAcceptError(Exception):
    """Raised when the guard refuses a request."""


ALLOWED_HTTP_METHODS = frozenset({"GET", "PATCH", "POST"})

# (method, host, path regex): the ONLY writes this client may send. Security-CRIT to widen.
SALE_ACCEPT_WRITES = (("POST", "sc.gotickets.com", r"^/rest/sales/\d+/confirm$"), ("PATCH", "sellerdirect-api.seatgeek.com", r"^/order$"), ("POST", "brokers.vividseats.com", r"^/webservices/v1/confirmOrder$"))
_WRITES = tuple((m, h, re.compile(p)) for m, h, p in SALE_ACCEPT_WRITES)
READ_HOSTS = frozenset({"sc.gotickets.com", "sellerdirect-api.seatgeek.com", "brokers.vividseats.com"})


def _assert_readonly_method(method: str, url: str = "") -> None:
    """GET to the three sale hosts; a write only if it is one of SALE_ACCEPT_WRITES."""
    m = method.upper()
    parts = urlsplit(url)
    if m not in ALLOWED_HTTP_METHODS:
        raise SaleAcceptError(f"READ-ONLY violation: method {method} is not allowed. RULE 2 (CLAUDE.md §2).")
    if parts.scheme != "https" or parts.hostname not in READ_HOSTS:
        raise SaleAcceptError(f"READ-ONLY violation: host {parts.hostname!r} is not a sale host.")
    if m != "GET" and not any(m == wm and parts.hostname == wh and wr.match(parts.path) for wm, wh, wr in _WRITES):
        raise SaleAcceptError(f"READ-ONLY violation: {m} {parts.hostname}{parts.path} is not a sanctioned "
                              "sale accept (RULE 2, operator 2026-11-10).")


# Sale states that mean "still waiting for us to accept" (from our order-timer log).
PENDING = {"gotickets": frozenset({"UNCONFIRMED"}), "seatgeek": frozenset({"submitted", "pending", "open"}),
           "vivid": frozenset({"UNCONFIRMED"})}


class SaleAcceptClient:
    def __init__(self, *, gt_id: str | None = None, gt_secret: str | None = None, sg_token: str | None = None,
                 vivid_token: str | None = None, session: Any = None, timeout: float = 20.0):
        self.gt_id, self.gt_secret, self.sg_token, self.vivid_token = gt_id, gt_secret, sg_token, vivid_token
        self.session = session or requests.Session()
        self.timeout = timeout

    def has_market(self, market: str) -> bool:
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
        raise SaleAcceptError(f"no sale-accept support for {market!r}")

    def accept(self, market: str, order_id: Any) -> dict:
        """Confirm our pending sale. Never retried by this client."""
        oid = str(order_id)
        if market == "gotickets":
            r = self._send("POST", f"https://sc.gotickets.com/rest/sales/{int(oid)}/confirm", headers=self._gt_headers())
        elif market == "seatgeek":
            r = self._send("PATCH", "https://sellerdirect-api.seatgeek.com/order", headers={"token": self.sg_token or ""},
                           files={"order_id": (None, oid), "status": (None, "confirmed")})
        elif market == "vivid":
            r = self._send("POST", "https://brokers.vividseats.com/webservices/v1/confirmOrder",
                           data={"apiToken": self.vivid_token or "", "orderId": oid, "shipNow": "false"})
        else:
            raise SaleAcceptError(f"no sale-accept support for {market!r}")
        text = (r.text or "")[:300]
        if re.search(r"<success>\s*false\s*</success>", text, re.I):  # Vivid answers errors with HTTP 200
            raise EvoWriteRejected(r.status_code, text)
        return {"state": "accepted", "http": r.status_code, "body": text}
