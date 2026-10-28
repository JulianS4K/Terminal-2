"""N2S auto-cover PLANNER — dry run only. Builds, never sends.

Operator plan (2026-10-28): an N2S order comes in → find a sub that is a 1-1 Index match
(gate 1: same section, cheaper than the sale) → confirm the sub is not our own inventory →
buy it → confirm the market we bought from accepted our purchase → only then accept the sale
on the market that sold it. All while the sale order is still active.

Operator directive with it: "build but dont run, dry runs only … NO PUSHING OUT!" So this
module only PLANS. For each step it returns the exact request an executor would make —
method, URL, body — and the read that would confirm it, with ``sent: False``. It imports no
HTTP library and has no send path; RULE 2 (CLAUDE.md: upstream APIs are read-only) is
unchanged, and ``scripts/check_readonly.py`` has nothing new to allow. Turning any write
step into a live call is a separate, operator-authorized change.

Endpoints, checked 2026-10-28 against the vendors' own specs (operator-supplied pages,
TickPick's swagger, the Victory Live / Ticket Evolution Confluence API space). Where a
market's sale-accept endpoint could not be read from its docs it is marked ``verified:
False`` and the plan says the step is manual.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any

DRY_RUN_NOTE = "Dry run only: nothing was sent to any market."

# The market we BUY the sub from, keyed by the cover's sub_source.
BUY_SIDE: dict[str, dict] = {
    "gotickets": {
        "market": "GoTickets",
        "buy": {"method": "POST", "url": "https://gotickets.com/rest/pro/api/orders", "verified": True,
                "doc": "GoTickets Pro API — POST /orders (expectedTotal guards the price; 475 = price changed)"},
        "confirm": {"method": "GET", "url": "https://sc.gotickets.com/rest/purchases/{purchase_id}",
                    "verified": True, "doc": "Seller Central — GET /rest/purchases/{id}"},
        # Read before the buy: per-listing tax + transactionRatePercentage feed expectedTotal.
        "pricing": {"method": "GET",
                    "url": "https://gotickets.com/rest/pro/api/events/{event_id}/listings?paymentMethodCategory=CREDIT_CARD",
                    "verified": True, "doc": "GoTickets Pro API — GET /events/{eventId}/listings"},
    },
    "tevo": {
        "market": "EVO (Ticket Evolution)",
        "buy": {"method": "POST", "url": "https://api.ticketevolution.com/v9/orders", "verified": True,
                "doc": "TEvo v9 Orders / Create — a Buy Order (purchase from another office)"},
        "confirm": {"method": "GET", "url": "https://api.ticketevolution.com/v9/orders/{purchase_id}",
                    "verified": True, "doc": "TEvo v9 Orders / Show — accepted when the seller has accepted"},
    },
    "tickpick": {
        "market": "TickPick",
        "buy": {"method": "POST", "url": "https://api.tickpick.com/1.0/pro/orders", "verified": True,
                "doc": "TickPick API — POST /pro/orders (CreateProOrderRequest)"},
        "confirm": {"method": "GET", "url": "https://api.tickpick.com/1.0/orders/{purchase_id}",
                    "verified": True, "doc": "TickPick API — GET /orders/{orderNumber}"},
    },
    "seatgeek": {
        "market": "SeatGeek",
        "buy": None,  # no buy endpoint: SeatGeek purchases are made on seatgeek.com
        "confirm": {"method": "GET", "url": "https://brokerdata.seatgeek.com/purchases?order_ids={purchase_id}",
                    "verified": True, "doc": "Broker Data — GET /purchases (pending|confirmed|fulfilled)"},
    },
}

# The market that SOLD the ticket (n2s s4k_source) — where we accept the order.
SELL_SIDE: dict[str, dict] = {
    "gotickets": {
        "accept": {"method": "POST", "url": "https://sc.gotickets.com/rest/sales/{order_id}/confirm",
                   "verified": True, "doc": "Seller Central — POST /rest/sales/{orderId}/confirm"},
        "status": {"method": "GET", "url": "https://sc.gotickets.com/rest/sales/{order_id}", "verified": True},
    },
    "evo": {
        "accept": {"method": "POST", "url": "https://api.ticketevolution.com/v9/orders/{order_id}/accept",
                   "verified": True, "doc": "TEvo v9 Orders / Accept — pending orders only; body reviewer_id"},
        "status": {"method": "GET", "url": "https://api.ticketevolution.com/v9/orders/{order_id}", "verified": True},
    },
    "tickpick": {
        "accept": {"method": "POST", "url": "https://api.tickpick.com/1.0/orders/{order_id}/confirmation",
                   "verified": True, "doc": "TickPick API — POST /orders/{orderNumber}/confirmation"},
        "status": {"method": "GET", "url": "https://api.tickpick.com/1.0/orders/{order_id}", "verified": True},
    },
    "seatgeek": {
        "accept": {"method": "PATCH", "url": "https://sellerdirect-api.seatgeek.com/order", "verified": True,
                   "doc": "SellerDirect — PATCH /order (multipart: order_id, status)"},
        "status": {"method": "GET", "url": "https://sellerdirect-api.seatgeek.com/order?order_id={order_id}",
                   "verified": True},
    },
    "vivid": {
        "accept": {"method": "POST", "url": "https://brokers.vividseats.com/webservices/v1/confirmOrder",
                   "verified": True,
                   "doc": "Vivid Broker Portal — POST /v1/confirmOrder; must land within minutes of the order "
                          "notification or a financial penalty applies (reject: POST /v1/rejectOrder)"},
        "status": {"method": "GET", "url": "https://brokers.vividseats.com/webservices/v1/getOrder?orderId={order_id}",
                   "verified": True},
    },
    "stubhub": {"accept": {"method": None, "url": None, "verified": False,
                           "doc": "developer.stubhub.com — accept endpoint not yet read"}, "status": None},
    "gametime": {"accept": {"method": None, "url": None, "verified": False, "doc": "no API read yet"},
                 "status": None},
    "viagogo": {"accept": {"method": None, "url": None, "verified": False, "doc": "no API read yet"},
                "status": None},
    "ticketmaster": {"accept": {"method": None, "url": None, "verified": False, "doc": "no API read yet"},
                     "status": None},
}

# GoTickets has no "owned" flag on the listings we pull; Seller Central only returns a listing
# that belongs to the authenticated broker, so a 404 here means the sub is NOT ours.
GT_OWNERSHIP_READ = {"method": "GET", "url": "https://sc.gotickets.com/rest/listings/{listing_id}",
                     "verified": True, "doc": "Seller Central — GET /rest/listings/{id}: 404 = not ours"}


def sell_market_key(s4k_source: Any) -> str | None:
    """CRM marketplace name → SELL_SIDE key ('Gametime.Co' → gametime, 'Vivid Seats' → vivid)."""
    s = re.sub(r"[^a-z]", "", str(s4k_source or "").lower())
    for key in ("gotickets", "evo", "tickpick", "seatgeek", "vivid", "stubhub", "gametime", "viagogo",
                "ticketmaster"):
        if s.startswith(key):
            return key
    return None


def _level(s: Any) -> str:
    return re.sub(r"[^a-z]", "", str(s or "").lower())


def _parse_ts(v: Any) -> datetime | None:
    if not v:
        return None
    try:
        dt = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def order_active(order: dict, now: datetime | None = None) -> dict:
    """Is the sale still ours to cover? Uses the book's own flags (`v_n2s_orders`):
    `in_window` = n2s_timer_open() (NULL timer — N2B / PED orders — never closes) and
    `event_live` = n2s_event_live() (TRUE while the event can still be sold; it does NOT mean
    "started"). The timer is also re-checked against `now` in case the row is stale."""
    now = now or datetime.now(timezone.utc)
    reasons = []
    exp = _parse_ts(order.get("timer_expires_at"))
    if order.get("in_window") is False or order.get("timer_expired") or (exp is not None and exp <= now):
        reasons.append("timer_closed")
    if order.get("event_live") is False:
        reasons.append("event_over")
    if order.get("n2s_status") not in (None, "n2s", "n2b"):
        reasons.append(f"status_{order.get('n2s_status')}")
    return {"active": not reasons, "reasons": reasons,
            "seconds_left": None if exp is None else max(0, int((exp - now).total_seconds()))}


def not_ours(order: dict, owned: bool | None) -> dict:
    """The sub must not be our own inventory. `owned` comes from the caller's lookup of the
    sub's listing in our pulled inventory (`n2s_evo_current.is_owned` for TEvo,
    `n2s_sg_current.is_broker_owned` for SeatGeek); None = no flag for this source, so the
    live executor must make the ownership read (GoTickets: a 404 from Seller Central)."""
    if owned:
        return {"not_ours": False, "reasons": ["our_own_listing"], "read": None}
    if owned is None:
        read = GT_OWNERSHIP_READ if order.get("sub_source") == "gotickets" else None
        return {"not_ours": None, "reasons": ["checked_live_at_buy"] if read else ["no_ownership_data"],
                "read": _req(read, listing_id=order.get("sub_listing_id"))}
    return {"not_ours": True, "reasons": [], "read": None}


def index_match(order: dict) -> dict:
    """1-1 Index: gate 1 (same section, cover cheaper than the sale), enough tickets, and —
    the Floor-vs-Loge guard — when both sides name a level, the names agree."""
    reasons = []
    if order.get("cover_gate") != 1:
        reasons.append("not_gate_1")
    cost = order.get("cover_cost")
    if cost is None or float(cost) >= 0:
        reasons.append("not_profitable")
    a, b = _level(order.get("section")), _level(order.get("sub_section"))
    if a and b and a != b:
        reasons.append("level_mismatch")
    if (order.get("sub_qty") or 0) < (order.get("quantity") or 0):
        reasons.append("short_quantity")
    if order.get("sub_view") == "obstructed":
        reasons.append("obstructed_view")
    return {"index_1_1": not reasons, "reasons": reasons}


def gt_expected_total(price_ea: Any, qty: Any, tax: Any = 0, rate_pct: Any = 0) -> float | None:
    """GoTickets Pro: (displayPrice + tax) * quantity * (1 + transactionRatePercentage/100).
    The order fails (475) if the real total exceeds this, so it is the price guard."""
    if price_ea is None or not qty:
        return None
    return round((float(price_ea) + float(tax or 0)) * int(qty) * (1 + float(rate_pct or 0) / 100), 2)


def _buy_body(src: str, order: dict, gt_event_id: Any) -> dict | None:
    qty = order.get("sub_qty")
    if src == "gotickets":
        return {"eventId": gt_event_id, "listingId": order.get("sub_listing_id"), "quantity": qty,
                "expectedTotal": gt_expected_total(order.get("sub_ea"), qty, order.get("sub_tax"),
                                                   order.get("gt_rate_pct")),
                "buyerNotes": f"N2S cover for {order.get('s4k_source')} order {order.get('order_number')}",
                "emailAddress": None, "phoneNumber": None, "deliveryMethodId": None,
                "billingAddress": None, "paymentMethodToken": None}
    if src == "tevo":
        return {"orders": [{"ticket_group": {"id": order.get("sub_listing_id"), "price": order.get("sub_ea")},
                            "quantity": qty, "seller_id": None, "external_notes":
                            f"N2S cover for {order.get('s4k_source')} order {order.get('order_number')}"}]}
    # tickpick — the only other source with a buy endpoint (callers pass a BUY_SIDE source).
    return {"event_id": None, "listing_id": order.get("sub_listing_id"), "quantity": qty,
            "unit_price": order.get("sub_ea"), "delivery_type": None, "customer": None,
            "external_id": str(order.get("order_number") or "")[:50]}


def _accept_body(market: str, order: dict) -> dict | None:
    oid = order.get("n2s_order_key") or order.get("order_number")
    if market == "evo":
        return {"reviewer_id": None}
    if market == "tickpick":
        return {"broker_id": None, "seat_numbers": None}
    if market == "seatgeek":
        return {"order_id": oid, "status": "confirmed"}
    if market == "gotickets":
        return {}
    if market == "vivid":
        return {"orderId": oid, "shipNow": False}
    return None


def _req(spec: dict | None, **ids: Any) -> dict | None:
    if not spec or not spec.get("url"):
        return None
    return {"method": spec["method"], "url": spec["url"].format(**{k: (v if v is not None else "{" + k + "}")
                                                                    for k, v in ids.items()}),
            "verified": spec["verified"], "doc": spec.get("doc")}


def plan_cover(order: dict, *, gt_event_id: Any = None, owned: bool | None = None,
               now: datetime | None = None) -> dict:
    """The full cover plan for one N2S order (a `v_n2s_orders` row). Every write step is built,
    not sent: `sent` is always False. A step's `ok` is True (passes), False (blocks) or None
    (decided only at execution, by the read in its `request`/`detail`). `go` is True when no
    step blocks and both the buy and the accept have a verified endpoint — what a live
    executor WOULD attempt, subject to the `live_checks` it must make first."""
    active = order_active(order, now)
    match = index_match(order)
    ours = not_ours(order, owned)
    src = order.get("sub_source")
    buy_spec = BUY_SIDE.get(src or "")
    market = sell_market_key(order.get("s4k_source"))
    sell_spec = SELL_SIDE.get(market or "")
    sale_id = order.get("n2s_order_key") or order.get("order_number")

    steps = [
        {"step": 1, "name": "sale order still active", "kind": "read", "ok": active["active"],
         "detail": active,
         "request": _req((sell_spec or {}).get("status"), order_id=sale_id)},
        {"step": 2, "name": "1-1 Index sub", "kind": "check", "ok": match["index_1_1"], "detail": match},
        {"step": 3, "name": "sub is not ours", "kind": "check" if ours["read"] is None else "read",
         "ok": ours["not_ours"], "detail": ours, "request": ours["read"]},
        {"step": 4, "name": f"buy sub on {buy_spec['market'] if buy_spec else src}", "kind": "write",
         "ok": bool(buy_spec and buy_spec.get("buy")), "sent": False,
         "request": _req((buy_spec or {}).get("buy")),
         "body": _buy_body(src or "", order, gt_event_id) if buy_spec and buy_spec.get("buy") else None,
         "detail": None if buy_spec and buy_spec.get("buy") else
         {"reason": "no buy API for this source — buy by hand" if buy_spec else f"unsupported source {src}"}},
        {"step": 5, "name": "market accepted our purchase (confirmation code)", "kind": "read",
         "ok": None if buy_spec and buy_spec.get("confirm") else False,
         "request": _req((buy_spec or {}).get("confirm"), purchase_id=None),
         "detail": {"confirmed_when": "status confirmed/accepted on the returned purchase id"}},
        {"step": 6, "name": f"accept sale on {order.get('s4k_source')}", "kind": "write",
         "ok": bool(sell_spec and sell_spec["accept"].get("verified")), "sent": False,
         "request": _req((sell_spec or {}).get("accept"), order_id=sale_id),
         "body": _accept_body(market or "", order),
         "detail": None if sell_spec and sell_spec["accept"].get("verified") else
         {"reason": (sell_spec or {}).get("accept", {}).get("doc") or f"unknown market {order.get('s4k_source')}"}},
    ]
    go = all(s["ok"] is not False for s in steps)
    return {"order_number": order.get("order_number"), "selling_market": order.get("s4k_source"),
            "sub_source": src, "go": go, "dry_run": True, "sent": False,
            "blocked_by": [s["name"] for s in steps if s["ok"] is False],
            "live_checks": [s["name"] for s in steps if s["ok"] is None] + ["re-check sale order still active"],
            "profit": None if order.get("cover_cost") is None else round(-float(order["cover_cost"]), 2),
            "steps": steps, "note": DRY_RUN_NOTE}
