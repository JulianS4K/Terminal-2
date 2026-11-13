"""EVO (Ticket Evolution) BUY client — the one sanctioned write path to a listing source.

Operator authorization 2026-11-09: "I authorize EVO only, build the live executor, limit to
only 1 live run for testing". That authorizes exactly two TEvo writes, both for N2S
auto-cover:

  POST /v9/orders               buy the sub (a purchase order from Office 3, paid by evopay)
  POST /v9/orders/{id}/accept   accept our own pending EVO sale once the sub is confirmed

Operator authorization 2026-11-11: the buy (POST /v9/orders, nothing else) may also be sent by
the manual sub buy path (core/manual_sub_buy.py): one EVO listing the operator chose for one
sale, kept separate from N2S. No path was added for it.

Operator authorization 2026-11-13 ("build the evo tax quote"): POST /v9/tax_quotes, EVO's own
pre-purchase calculation of what it will charge for a ticket group and quantity, tax included.
It buys, holds and changes nothing; its ``tax_signature`` is sent with the buy so the order is
charged what was quoted.

Everything else stays read-only (CLAUDE.md RULE 2). The guard below is path-scoped like
seatdata_client's: any method other than GET/POST raises, and a POST raises unless its path
matches one of ``EVO_WRITE_PATHS``. There is no reject, cancel, reprice or listing write,
and none may be added without the operator's written authorization (security-CRIT).
``scripts/check_readonly.py`` pins both the method set and the exact path allowlist.

Writes are never retried: a timeout or 5xx on a POST is reported as "unknown outcome" and
the caller stops (a retried buy could buy twice).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
from typing import Any
from urllib.parse import urlencode

import requests


class EvoBuyError(Exception):
    """Raised when the guard refuses a request."""


class EvoWriteUnknown(Exception):
    """A write was sent but its outcome is unknown (timeout / connection drop / 5xx).
    The caller must NOT retry; a person checks the order on EVO."""


class EvoWriteRejected(Exception):
    """EVO answered a write with a 4xx: nothing was created. ``status`` and ``detail`` say why."""

    def __init__(self, status: int, detail: str):
        super().__init__(f"EVO rejected the request ({status}): {detail}")
        self.status = status
        self.detail = detail


ALLOWED_HTTP_METHODS = frozenset({"GET", "POST"})

# The ONLY paths a POST may target. Adding one is a security-CRIT change (CLAUDE.md §2)
# that needs the operator's written authorization; check_readonly.py pins this literal.
EVO_WRITE_PATHS = (r"^/v9/orders$", r"^/v9/orders/\d+/accept$", r"^/v9/tax_quotes$")
_WRITE_RE = tuple(re.compile(p) for p in EVO_WRITE_PATHS)


def _assert_readonly_method(method: str, path: str | None = None) -> None:
    """GET anywhere; POST only to the buy, accept and tax-quote endpoints; nothing else."""
    m = method.upper()
    if m not in ALLOWED_HTTP_METHODS:
        raise EvoBuyError(f"READ-ONLY violation: method {method} is not allowed. "
                          "RULE 2 read-only lockdown (CLAUDE.md §2).")
    if m == "POST" and not any(r.match(path or "") for r in _WRITE_RE):
        raise EvoBuyError(f"READ-ONLY violation: POST to {path!r} is not sanctioned. EVO writes are "
                          "limited to /v9/orders, /v9/orders/{id}/accept and /v9/tax_quotes (RULE 2, operator "
                          "2026-11-09 / 2026-11-13).")


class EvoBuyClient:
    """Signed TEvo v9 requests (X-Token + HMAC-SHA256 X-Signature over
    ``METHOD host path?query`` — for a POST the JSON body takes the query's place)."""

    host = "api.ticketevolution.com"

    def __init__(self, token: str, secret: str, *, session: Any = None, timeout: float = 20.0):
        if not token or not secret:
            raise EvoBuyError("EVO token and secret are required")
        self.token = token
        self._secret = secret.encode("utf-8")
        self.session = session or requests.Session()
        self.timeout = timeout

    def _sign(self, method: str, path: str, tail: str) -> str:
        msg = f"{method} {self.host}{path}?{tail}".encode()
        return base64.b64encode(hmac.new(self._secret, msg, hashlib.sha256).digest()).decode("utf-8")

    def _call(self, method: str, path: str, *, params: dict | None = None, body: dict | None = None) -> dict:
        _assert_readonly_method(method, path)  # RULE 2 enforcement, before anything is built
        query = urlencode(sorted((params or {}).items()))
        payload = json.dumps(body, separators=(",", ":")) if body is not None else ""
        sig = self._sign(method, path, payload if method == "POST" else query)
        headers = {"X-Token": self.token, "X-Signature": sig,
                   "Accept": "application/vnd.ticketevolution.api+json; version=9"}
        if method == "POST":
            headers["Content-Type"] = "application/json"
        url = f"https://{self.host}{path}" + (f"?{query}" if query else "")
        try:
            resp = self.session.request(method, url, headers=headers, timeout=self.timeout,
                                        data=payload.encode("utf-8") if method == "POST" else None)
        except requests.RequestException as e:
            if method == "POST":
                raise EvoWriteUnknown(f"{path}: {type(e).__name__}") from e
            raise
        if resp.status_code >= 500 and method == "POST":
            raise EvoWriteUnknown(f"{path}: HTTP {resp.status_code}")
        if resp.status_code >= 400:
            raise EvoWriteRejected(resp.status_code, (resp.text or "")[:500])
        try:
            return resp.json() if resp.content else {}
        except ValueError as e:
            if method == "POST":  # the write landed (2xx) but we cannot read what it made
                raise EvoWriteUnknown(f"{path}: unreadable response") from e
            raise

    # ---------- reads ----------

    def get_ticket_group(self, ticket_group_id: Any) -> dict:
        return self._call("GET", f"/v9/ticket_groups/{int(ticket_group_id)}")

    def get_order(self, order_id: Any) -> dict:
        return self._call("GET", f"/v9/orders/{int(order_id)}")

    # ---------- the authorized POSTs ----------

    def tax_quote(self, ticket_group_id: Any, quantity: int) -> dict:
        """POST /v9/tax_quotes — what EVO will charge for this purchase, tax included, paid by
        evopay. A calculation only: nothing is bought or held. Never retried by this client."""
        return self._call("POST", "/v9/tax_quotes",
                          body={"ticket_group_id": int(ticket_group_id), "quantity": int(quantity),
                                "payment_type": "evopay"})

    def create_order(self, body: dict) -> dict:
        """POST /v9/orders — buy the sub. Never retried by this client."""
        return self._call("POST", "/v9/orders", body=body)

    def accept_order(self, order_id: Any, reviewer_id: int) -> dict:
        """POST /v9/orders/{id}/accept — accept our pending sale. Never retried by this client."""
        return self._call("POST", f"/v9/orders/{int(order_id)}/accept", body={"reviewer_id": int(reviewer_id)})


def buy_order_body(*, ticket_group_id: Any, quantity: int, price_ea: float, seller_office_id: int,
                   buyer_office_id: int, shipment_type: str, email_address_id: int | None, note: str,
                   tax_signature: str | None = None) -> dict:
    """The Orders / Create body for a brokerage purchase paid from our EVO balance, mirroring
    the shape of Office 3's own purchase orders (evopay, a TMMobile / Eticket shipment to the
    office email, LEAST_EXPENSIVE). ``tax_signature`` is the one a tax quote for this same
    ticket group and quantity returned; EVO then charges what it quoted."""
    shipped: dict[str, Any] = {"type": shipment_type,
                               "items": [{"ticket_group_id": int(ticket_group_id), "quantity": int(quantity),
                                          "price": f"{float(price_ea):.2f}"}]}
    if email_address_id is not None:
        shipped["email_address_id"] = int(email_address_id)
    if shipment_type == "FedEx":
        shipped["service_type"] = "LEAST_EXPENSIVE"
    order: dict[str, Any] = {"seller_id": int(seller_office_id), "buyer_id": int(buyer_office_id),
                             "shipped_items": [shipped], "payments": [{"type": "evopay"}],
                             "service_fee": 0, "shipping": 0, "tax": 0, "additional_expense": 0, "discount": 0,
                             "internal_notes": note[:250]}
    if tax_signature:
        order["tax_signature"] = str(tax_signature)
    return {"orders": [order]}


# ticket_group.format → shipment type (TEvo 11.1 "Creating Orders": Physical/Paperless ship FedEx).
SHIPMENT_FOR_FORMAT = {"Eticket": "Eticket", "TM_mobile": "TMMobile", "Flash_seats": "FlashSeats",
                       "Guest_list": "GuestList", "Physical": "FedEx", "Paperless": "FedEx"}
