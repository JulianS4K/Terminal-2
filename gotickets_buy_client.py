"""GoTickets BUY client — buy an N2S sub on GoTickets, paid from our GoTickets gift cards.

Operator authorization 2026-11-13: "wire in gotickets similar to evo and set same limits and
same one buy condition" (with: GoTickets gets its own single live run and its own $666 caps).
Exactly one write, path-pinned by ``GT_BUY_WRITES`` (``scripts/check_readonly.py`` requires
the literal):

  GoTickets Pro API  POST gotickets.com/rest/pro/api/orders

Everything else here is a GET: the event's listings and our gift cards (Pro API), and our own
purchase and listing by id (Seller Central: a listing that answers is ours, never bought). There is no cancel, refund, price or listing write, and none
may be added without the operator's written authorization (security-CRIT, CLAUDE.md RULE 2).
The write is never retried: a timeout or 5xx is "unknown outcome" and the caller stops.

A second caller (operator 2026-11-13: "n2s also incorporated gotickets autobuy look at how it
functions and incorporate but modify to match how we use evo"): the manual sub buy path
(core/manual_sub_buy.py) sends the same one write for a GoTickets cover the sub finder filed
(mig 20261113300000; off unless manual_sub_buy_config.gt_enabled). No new write path.

Payment: ``giftCardIds`` only. GoTickets lists a saved card to the API only when it is shared
with the whole account (``global = true``); none is (GET /payment-methods answered ``[]`` on
2026-11-13), so the buy is paid entirely from gift cards or not sent.
"""
from __future__ import annotations

import base64
import re
from typing import Any
from urllib.parse import urlsplit

import requests

from evo_buy_client import EvoWriteRejected, EvoWriteUnknown


class GoTicketsBuyError(Exception):
    """Raised when the guard refuses a request, or a read fails."""


ALLOWED_HTTP_METHODS = frozenset({"GET", "POST"})

# (method, host, path regex): the ONLY write this client may send. Security-CRIT to widen.
GT_BUY_WRITES = (("POST", "gotickets.com", r"^/rest/pro/api/orders$"),)
_WRITES = tuple((m, h, re.compile(p)) for m, h, p in GT_BUY_WRITES)
PRO_HOST = "gotickets.com"        # Pro API: listings, gift cards, the buy
SC_HOST = "sc.gotickets.com"      # Seller Central: our purchase by id (GET only)
PRO_BASE = f"https://{PRO_HOST}/rest/pro/api"
SC_BASE = f"https://{SC_HOST}/rest"


def _assert_readonly_method(method: str, url: str = "") -> None:
    """GET to the Pro API or Seller Central; a write only if it is the one in GT_BUY_WRITES."""
    m = method.upper()
    parts = urlsplit(url)
    if m not in ALLOWED_HTTP_METHODS:
        raise GoTicketsBuyError(f"READ-ONLY violation: method {method} is not allowed. RULE 2 (CLAUDE.md §2).")
    if parts.scheme != "https" or parts.hostname not in (PRO_HOST, SC_HOST):
        raise GoTicketsBuyError(f"READ-ONLY violation: host {parts.hostname!r} is not GoTickets.")
    if m != "GET" and not any(m == wm and parts.hostname == wh and wr.match(parts.path) for wm, wh, wr in _WRITES):
        raise GoTicketsBuyError(f"READ-ONLY violation: {m} {parts.hostname}{parts.path} is not the sanctioned "
                                "GoTickets buy (RULE 2, operator 2026-11-13).")


class GoTicketsBuyClient:
    def __init__(self, gt_id: str | None, gt_secret: str | None, *, session: Any = None, timeout: float = 20.0):
        self.gt_id, self.gt_secret = gt_id, gt_secret
        self.session = session or requests.Session()
        self.timeout = timeout

    def ready(self) -> bool:
        return bool(self.gt_id and self.gt_secret)

    def _headers(self, host: str) -> dict:
        if host == PRO_HOST:  # Pro API: base64(accessId:accessSecret), "Pro Access" enabled on the key
            token = base64.b64encode(f"{self.gt_id or ''}:{self.gt_secret or ''}".encode()).decode()
            return {"X-Broker-Api-Token": token, "Accept": "application/json"}
        return {"X-Api-Access-Id": self.gt_id or "", "X-Api-Access-Secret": self.gt_secret or "",
                "Accept": "application/json"}

    def _send(self, method: str, url: str, **kw: Any) -> Any:
        _assert_readonly_method(method, url)  # RULE 2 enforcement, before anything is sent
        path = urlsplit(url).path
        try:
            resp = self.session.request(method, url, timeout=self.timeout,
                                        headers=self._headers(urlsplit(url).hostname or ""), **kw)
        except requests.RequestException as e:
            where = f"{path}: {type(e).__name__}"  # never the request itself: path + error type only
            if method != "GET":
                raise EvoWriteUnknown(where) from None
            raise GoTicketsBuyError(where) from None
        if resp.status_code >= 500 and method != "GET":
            raise EvoWriteUnknown(f"{path}: HTTP {resp.status_code}")
        if resp.status_code >= 400:
            raise EvoWriteRejected(resp.status_code, (resp.text or "")[:500])
        if method == "GET" and not (getattr(resp, "text", None) or "").strip():
            return None  # Seller Central answers 200 with no body for a listing that is not ours
        try:
            return resp.json()
        except ValueError:
            if method != "GET":  # the buy landed (2xx) but we cannot read what it made
                raise EvoWriteUnknown(f"{path}: unreadable response") from None
            raise GoTicketsBuyError(f"{path}: unreadable response") from None

    # ---------- reads ----------

    def get_listing(self, event_id: Any, listing_id: Any) -> dict | None:
        """One listing as the Pro API shows it right now (displayPrice, tax, quantity,
        validSplitQuantities, deliveryMethods), or None when it is no longer listed."""
        got = self._send("GET", f"{PRO_BASE}/events/{int(event_id)}/listings")
        rows = got.get("listings") if isinstance(got, dict) else got  # {"event", "listings", ...}
        for r in rows if isinstance(rows, list) else []:
            if isinstance(r, dict) and str(r.get("id")) == str(listing_id):
                return r
        return None

    def get_gift_cards(self) -> list[dict]:
        got = self._send("GET", f"{PRO_BASE}/gift-cards")
        return [g for g in got if isinstance(g, dict)] if isinstance(got, list) else []

    def is_own_listing(self, listing_id: Any) -> bool:
        """True when the listing is one of OURS: Seller Central's GET /rest/listings/{id} returns our
        own listing, and 200 with an empty body for anyone else's (checked 2026-11-13)."""
        got = self._send("GET", f"{SC_BASE}/listings/{int(listing_id)}")
        return isinstance(got, dict) and got.get("id") is not None

    def get_purchase(self, purchase_id: Any) -> dict:
        """Our purchase as Seller Central holds it (orderStatus, orderTotal)."""
        got = self._send("GET", f"{SC_BASE}/purchases/{int(purchase_id)}")
        return got if isinstance(got, dict) else {}

    # ---------- the one authorized write ----------

    def create_order(self, body: dict) -> dict:
        """POST /orders — buy the sub. Never retried by this client."""
        got = self._send("POST", f"{PRO_BASE}/orders", json=body)
        if not isinstance(got, dict):
            raise EvoWriteUnknown("/rest/pro/api/orders: the answer is not an order")
        return got


# ---------- pure helpers (no network) ----------

GT_PENDING = frozenset({"PENDING_CONFIRMATION"})
GT_REJECTED = frozenset({"CANCELLED", "CANCELED", "REJECTED", "DECLINED", "VOIDED", "FAILED",
                         "EXPIRED", "REFUNDED", "ERROR"})
# The states that mean the seller confirmed our purchase: every non-pending, non-cancelled
# orderStatus seen on our GoTickets purchases (Seller Central, 2026-11-13). An allowlist on
# purpose: confirmed is what lets the worker accept the N2S sale, so a status nobody has seen
# yet reads 'unknown' (wait, then stop with sub_unconfirmed), never 'confirmed'.
GT_CONFIRMED = frozenset({"PENDING_MOBILE_FULFILLMENT", "PENDING_TRANSFER_PROOF", "MOBILE_QR_DELIVERED",
                          "PAH_DELIVERED", "TRANSFER_COMPLETED", "TRANSFER_RECEIPT_CONFIRMED",
                          "TRANSFER_URL_COMPLETED", "TRANSFER_WALLET_URL_COMPLETED"})


def purchase_state(order_status: Any) -> str:
    """GoTickets orderStatus as the live worker reads a sub: 'pending' until the seller confirms,
    'rejected' when cancelled / refunded / expired, 'confirmed' only for a state in GT_CONFIRMED,
    and 'unknown' for anything else (so the sale is never accepted on a status we do not know)."""
    s = str(order_status or "").strip().upper()
    if not s:
        return "unknown"
    if s in GT_PENDING:
        return "pending"
    if s in GT_REJECTED or any(w in s for w in ("CANCEL", "REJECT", "REFUND", "EXPIRE")):
        return "rejected"
    if s in GT_CONFIRMED:
        return "confirmed"
    return "unknown"


def pick_delivery(listing: dict) -> dict | None:
    """The cheapest electronic delivery method that carries an id (Mobile Transfer, PDF, ...)."""
    methods = [d for d in listing.get("deliveryMethods") or []
               if isinstance(d, dict) and d.get("id") is not None and not d.get("physicalDelivery")]
    return min(methods, key=lambda d: float(d.get("price") or 0)) if methods else None


def expected_total(listing: dict, qty: int, delivery: dict) -> float:
    """GoTickets' own formula, paid by gift card (no credit-card rate):
    displayPrice × qty + delivery fee + tax × qty + the delivery fee's tax."""
    return round(float(listing["displayPrice"]) * qty + float(delivery.get("price") or 0)
                 + float(listing.get("tax") or 0) * qty + float(delivery.get("additionalDeliveryFeeTax") or 0), 2)


def gift_card_balance(card: dict) -> float:
    """amountRemaining (what the API returns, 2026-11-13); remainingBalance (what its docs show)."""
    value = card.get("amountRemaining")
    if value is None:
        value = card.get("remainingBalance")
    return float(value or 0)


def pick_gift_cards(cards: list[dict], need: float, allowed: list | None = None) -> list[int] | None:
    """The fewest gift cards (largest balance first) that together cover ``need``; None if they cannot."""
    usable = [c for c in cards if c.get("id") is not None and gift_card_balance(c) > 0
              and (not allowed or int(c["id"]) in {int(a) for a in allowed})]
    usable.sort(key=gift_card_balance, reverse=True)
    picked, total = [], 0.0
    for c in usable:
        picked.append(int(c["id"]))
        total += gift_card_balance(c)
        if total >= need:
            return picked
    return None


def order_body(*, event_id: Any, listing_id: Any, qty: int, expected: float, delivery_id: Any,
               email: str, phone: str, billing: dict, recipient: dict, gift_card_ids: list[int]) -> dict:
    """The POST /orders body: gift cards only (no paymentMethodToken), shipping = billing.
    No ``buyerNotes`` (operator 2026-11-13 asked whether the note is internal or external):
    GoTickets does not say who reads it, and its purchases keep a separate ``internalNotes``,
    so it may reach the seller. Which sale a purchase covers lives in n2s_autobuy_exec."""
    return {"eventId": int(event_id), "listingId": int(listing_id), "quantity": int(qty),
            "expectedTotal": round(float(expected), 2), "emailAddress": email, "phoneNumber": phone,
            "deliveryMethodId": int(delivery_id), "giftCardIds": [int(g) for g in gift_card_ids],
            "billingAddress": billing, "shippingIsBilling": True, "recipient": recipient}


def order_id(resp: dict) -> str | None:
    """The purchase id in the POST /orders answer (shape not documented: read the usual keys)."""
    for key in ("id", "orderId", "purchaseId"):
        if resp.get(key):
            return str(resp[key])
    inner = resp.get("order") or resp.get("purchase")
    if isinstance(inner, dict) and inner.get("id"):
        return str(inner["id"])
    return None
