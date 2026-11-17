"""GoTickets substitution-request client — offer a customer replacement seats on OUR OWN sale.

Operator authorization 2026-11-13: when a GoTickets order the CRM flagged as needing a sub has
only an "offer" cover (another section in the same zone, or rows back — sub finder gates 3-5),
"ask crm if it should offer sub to go tickets api ... just offer the sub via api if crm
confirms". Exactly one write, path-pinned by ``GT_SUB_WRITES`` (``scripts/check_readonly.py``
requires the literal):

  GoTickets Seller Central  POST sc.gotickets.com/rest/substitution-requests

Everything else here is a GET (the sale, and the sale's substitution requests). There is no
cancel, reject, fulfil, price or listing write, and none may be added without the operator's
written authorization (security-CRIT, CLAUDE.md RULE 2). The write is never retried: a timeout
or 5xx is "unknown outcome" and the caller stops.
"""
from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlsplit

import requests

from evo_buy_client import EvoWriteRejected, EvoWriteUnknown


class GoTicketsSubError(Exception):
    """Raised when the guard refuses a request, or a read fails."""


ALLOWED_HTTP_METHODS = frozenset({"GET", "POST"})

# (method, host, path regex): the ONLY write this client may send. Security-CRIT to widen.
GT_SUB_WRITES = (("POST", "sc.gotickets.com", r"^/rest/substitution-requests$"),)
_WRITES = tuple((m, h, re.compile(p)) for m, h, p in GT_SUB_WRITES)
HOST = "sc.gotickets.com"
BASE = f"https://{HOST}"


def _assert_readonly_method(method: str, url: str = "") -> None:
    """GET to Seller Central; a write only if it is the one in GT_SUB_WRITES."""
    m = method.upper()
    parts = urlsplit(url)
    if m not in ALLOWED_HTTP_METHODS:
        raise GoTicketsSubError(f"READ-ONLY violation: method {method} is not allowed. RULE 2 (CLAUDE.md §2).")
    if parts.scheme != "https" or parts.hostname != HOST:
        raise GoTicketsSubError(f"READ-ONLY violation: host {parts.hostname!r} is not GoTickets Seller Central.")
    if m != "GET" and not any(m == wm and parts.hostname == wh and wr.match(parts.path) for wm, wh, wr in _WRITES):
        raise GoTicketsSubError(f"READ-ONLY violation: {m} {parts.hostname}{parts.path} is not the sanctioned "
                                "substitution request (RULE 2, operator 2026-11-13).")


class GoTicketsSubClient:
    def __init__(self, gt_id: str | None, gt_secret: str | None, *, session: Any = None, timeout: float = 20.0):
        self.gt_id, self.gt_secret = gt_id, gt_secret
        self.session = session or requests.Session()
        self.timeout = timeout

    def ready(self) -> bool:
        return bool(self.gt_id and self.gt_secret)

    def _send(self, method: str, path: str, **kw: Any) -> Any:
        url = BASE + path
        _assert_readonly_method(method, url)  # RULE 2 enforcement, before anything is sent
        headers = {"X-Api-Access-Id": self.gt_id or "", "X-Api-Access-Secret": self.gt_secret or "",
                   "Accept": "application/json"}
        try:
            resp = self.session.request(method, url, timeout=self.timeout, headers=headers, **kw)
        except requests.RequestException as e:
            where = f"{path}: {type(e).__name__}"  # never the request itself: path + error type only
            if method != "GET":
                raise EvoWriteUnknown(where) from None
            raise GoTicketsSubError(where) from None
        if resp.status_code >= 500 and method != "GET":
            raise EvoWriteUnknown(f"{path}: HTTP {resp.status_code}")
        if resp.status_code >= 400:
            raise EvoWriteRejected(resp.status_code, (resp.text or "")[:500])
        return resp

    def get_sale(self, order_id: Any) -> dict:
        """Our sale as Seller Central holds it (status, seats, quantity, order item id)."""
        return self._send("GET", f"/rest/sales/{int(order_id)}").json() or {}

    def list_requests(self, order_id: Any) -> list[dict]:
        """Every substitution request already made for this sale."""
        got = self._send("GET", "/rest/substitution-requests", params={"saleId": int(order_id)}).json()
        return [r for r in got if isinstance(r, dict)] if isinstance(got, list) else []

    def create_request(self, body: dict) -> dict:
        """Offer the customer replacement seats. Never retried by this client."""
        got = self._send("POST", "/rest/substitution-requests", json=body).json()
        if not isinstance(got, dict):
            raise ValueError("GoTickets did not answer with a substitution request")
        return got
