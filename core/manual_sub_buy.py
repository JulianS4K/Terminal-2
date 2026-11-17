"""MANUAL sub buy worker — buys one EVO (or GoTickets) listing chosen for one sale.

Operator 2026-11-11: "build the path so i can auto buy these if i choose outside of set
conditions but keep separate from n2s". This is that path. It shares nothing with the N2S
auto-buy except the EVO buy client: no n2s_* table, config, cap, kill switch or rule is read
or written here, and it never accepts or rejects a sale (these sales are already accepted
on their markets).

The operator's request is the decision, so none of the N2S judgement rules run (no profit,
lead-time, Index-gate, view or timer check). What does run protects against a wrong or
doubled purchase:

  claim   ``manual_sub_buy_claim`` hands out one 'requested' row, once, under a lease — only
          while the config is enabled, not killed, and within its own order / day ceilings
  read    the ticket group, fresh: still listed, not ours, enough tickets, a split that fits,
          a known delivery format, and a price at or under the ceiling the operator approved
  quote   when the config's tax_quote is on: POST /v9/tax_quotes (EVO's own calculation of what
          it will charge, tax included; buys nothing). A row with a total ceiling
          (max_total_usd: the sub finder's automatic buys) stops when the quoted total is over
          it, or when EVO gives no usable quote; a row without one is bought either way
          (tax_quote_test: on the first buy only, the quote is asked and its raw answer stored
          for a person to read; it decides nothing and no signature is sent)
  buy     POST /v9/orders, once, through evo_buy_client (path-pinned; RULE 2), with the
          quote's tax_signature when there is one

  follow  afterwards, GET /v9/orders/{id} (a read) until the seller has confirmed or rejected
          the order, storing its state, what EVO charged and the seat numbers (mig 20261112000000)

GoTickets rows (operator 2026-11-13: "n2s also incorporated gotickets autobuy look at how it
functions and incorporate but modify to match how we use evo"; mig 20261113300000). A row whose
``market`` is 'gotickets' takes the same steps with GoTickets' own reads and its one write:

  read    the listing from the Pro API, fresh: still listed, NOT one of ours (Seller Central
          answers only for our own listings; if that check cannot be made the row stops), enough
          tickets, a split that fits, an electronic delivery method
  price   GoTickets' own total (display price, delivery fee, tax): never above what was quoted
          (max_price_ea x qty, a cent of rounding allowed), nor above the row's total ceiling
  pay     gift cards only, enough balance on the cards this path may use
  buy     POST /rest/pro/api/orders, once, through gotickets_buy_client (path-pinned; RULE 2)
  follow  GET /rest/purchases/{id} until GoTickets shows the seller confirmed or the purchase
          was cancelled / refunded

Never retried. A rejected buy stops the row. A buy whose outcome is unknown (timeout / 5xx /
unreadable answer) is recorded as 'unknown', which flips this path's kill switch until a
person has checked EVO.
"""
from __future__ import annotations

from collections.abc import Callable
from typing import Any

import requests

import gotickets_buy_client as gtb
from evo_buy_client import (
    SHIPMENT_FOR_FORMAT,
    EvoBuyClient,
    EvoWriteRejected,
    EvoWriteUnknown,
    buy_order_body,
    probe_tax_quote,
    read_tax_quote,
)

OUR_BROKERAGE_ID = 1768  # S4K Entertainment

Rpc = Callable[[str, dict], Any]


def _record(rpc: Rpc, job: dict, **patch: Any) -> dict:
    """Record one step under this worker's lease; the DB answers 'lease_lost' if it no longer holds."""
    row = job["row"]
    got = rpc("manual_sub_buy_record",
              {"p_buy_id": row["buy_id"], "p_token": row.get("lease_token"), "p_patch": patch})
    return {**patch, "recorded": got}


def listing_checks(tg: dict, *, qty: int, max_price_ea: float) -> list[str]:
    """Reasons the fresh ticket-group read says NOT to buy (empty = buy)."""
    reasons = []
    brokerage = ((tg.get("office") or {}).get("brokerage") or {}).get("id")
    if tg.get("owned") or brokerage == OUR_BROKERAGE_ID:
        reasons.append("our_own_listing")
    if (tg.get("available_quantity") or 0) < qty:
        reasons.append("short_quantity")
    if tg.get("splits") and qty not in tg["splits"]:
        reasons.append("split_not_allowed")
    price = tg.get("wholesale_price")
    if price is None or float(price) > float(max_price_ea) + 0.005:
        reasons.append("price_above_ceiling")
    if tg.get("format") not in SHIPMENT_FOR_FORMAT:
        reasons.append("unknown_format")
    if not (tg.get("office") or {}).get("id"):
        reasons.append("no_seller_office")
    return reasons


def gt_profile(cfg: dict) -> dict | None:
    """The buyer details GoTickets requires on every order, from this path's own config;
    None when any is missing (the row then stops, nothing is sent)."""
    billing, recipient = cfg.get("gt_billing_address") or {}, cfg.get("gt_recipient") or {}
    if not (cfg.get("gt_buyer_email") and cfg.get("gt_buyer_phone")):
        return None
    if not all(billing.get(k) for k in ("firstName", "lastName", "address1", "city", "state", "postalCode", "country")):
        return None
    if not all(recipient.get(k) for k in ("firstName", "lastName", "email", "phoneNumber")):
        return None
    return {"email": cfg["gt_buyer_email"], "phone": cfg["gt_buyer_phone"], "billing": billing, "recipient": recipient}


def gt_listing_checks(listing: dict, *, qty: int) -> list[str]:
    """Reasons the fresh GoTickets listing read says NOT to buy (empty = go on to pricing)."""
    reasons = []
    if int(listing.get("quantity") or 0) < qty:
        reasons.append("short_quantity")
    if listing.get("validSplitQuantities") and qty not in listing["validSplitQuantities"]:
        reasons.append("split_not_allowed")
    if gtb.pick_delivery(listing) is None:
        reasons.append("no_electronic_delivery")
    if listing.get("displayPrice") is None:
        reasons.append("price_unknown")
    return reasons


def _buy_gt(rpc: Rpc, gt: gtb.GoTicketsBuyClient | None, job: dict) -> dict:
    """One GoTickets row: read, check, price, pay from gift cards, POST once. Everything before
    the POST only reads, and a stop there has sent nothing."""
    row, cfg = job["row"], job["cfg"]
    out = {"action": "buy", "buy_id": row["buy_id"], "market": "gotickets"}
    qty = int(row["qty"])
    if gt is None or not gt.ready():
        return {**out, **_record(rpc, job, state="stopped", reasons=["no_gt_buy_client"])}
    profile = gt_profile(cfg)
    if profile is None:
        return {**out, **_record(rpc, job, state="stopped", reasons=["gt_buyer_profile_missing"])}
    if not row.get("gt_event_id"):
        return {**out, **_record(rpc, job, state="stopped", reasons=["no_gt_event_id"])}
    listing_id = row["ticket_group_id"]
    try:
        listing = gt.get_listing(row["gt_event_id"], listing_id)
    except (EvoWriteRejected, gtb.GoTicketsBuyError) as e:  # nothing was sent; the row stops (no retry)
        return {**out, **_record(rpc, job, state="stopped", reasons=["listing_read_failed"], error=str(e)[:300])}
    if listing is None:
        return {**out, **_record(rpc, job, state="stopped", reasons=["listing_gone"])}
    try:
        if gt.is_own_listing(listing_id):
            return {**out, **_record(rpc, job, state="stopped", reasons=["our_own_listing"])}
    except (EvoWriteRejected, gtb.GoTicketsBuyError) as e:  # fail closed: never buy what may be ours
        return {**out, **_record(rpc, job, state="stopped", reasons=["own_listing_check_failed"],
                                 error=str(e)[:300])}
    try:  # a listing we cannot read as numbers is a stop, never a crash that leaves the row mid-buy
        reasons = gt_listing_checks(listing, qty=qty)
        delivery = gtb.pick_delivery(listing) or {}
        total = gtb.expected_total(listing, qty, delivery) if not reasons else 0.0
        delivery_id = int(delivery["id"]) if not reasons else 0
    except (ValueError, TypeError, KeyError, AttributeError) as e:
        return {**out, **_record(rpc, job, state="stopped", reasons=["listing_unreadable"],
                                 error=f"{type(e).__name__}: {e}"[:300])}
    if reasons:
        return {**out, **_record(rpc, job, state="stopped", reasons=reasons)}
    quoted = {"quote_total_usd": total}
    if total > round(float(row["max_price_ea"]) * qty + 0.01, 2):
        return {**out, **_record(rpc, job, state="stopped", reasons=["price_above_ceiling"], **quoted)}
    ceiling = row.get("max_total_usd")
    if ceiling is not None and total > float(ceiling) + 0.005:
        return {**out, **_record(rpc, job, state="stopped", reasons=["total_above_ceiling"], **quoted)}
    try:
        cards = gt.get_gift_cards()
    except (EvoWriteRejected, gtb.GoTicketsBuyError) as e:
        return {**out, **_record(rpc, job, state="stopped", reasons=["gift_card_read_failed"], error=str(e)[:300])}
    try:  # GoTickets accepts an actual total up to $0.01 per ticket above expectedTotal: cover that too
        cards_used = gtb.pick_gift_cards(cards, total + 0.01 * qty, cfg.get("gt_gift_card_ids"))
    except (ValueError, TypeError, KeyError, AttributeError) as e:
        return {**out, **_record(rpc, job, state="stopped", reasons=["gift_card_read_failed"],
                                 error=f"{type(e).__name__}: {e}"[:300])}
    if not cards_used:
        return {**out, **_record(rpc, job, state="stopped", reasons=["gift_card_balance_short"], **quoted)}
    body = gtb.order_body(event_id=row["gt_event_id"], listing_id=listing_id, qty=qty, expected=total,
                          delivery_id=delivery_id, email=profile["email"], phone=profile["phone"],
                          billing=profile["billing"], recipient=profile["recipient"], gift_card_ids=cards_used)
    # re-check the lease right before the write: only the worker that still holds the row may buy
    if _record(rpc, job, state="buying", **quoted)["recorded"] != "buying":
        return {**out, "state": "lease_lost"}
    try:
        resp = gt.create_order(body)
    except EvoWriteRejected as e:
        return {**out, **_record(rpc, job, state="stopped", reasons=["buy_failed"], error=str(e))}
    except EvoWriteUnknown as e:
        return {**out, **_record(rpc, job, state="unknown", reasons=["buy_unknown"], error=str(e))}
    try:  # the buy was sent: anything going wrong from here is an unknown outcome, never a silent one
        oid = gtb.order_id(resp)
        if not oid:
            raise ValueError("no purchase id in the GoTickets response")
        charged = resp.get("orderTotal")
        return {**out, **_record(rpc, job, state="bought", buy_order_id=oid, buy_state=resp.get("orderStatus"),
                                 bought_price_ea=float(listing["displayPrice"]),
                                 bought_total_usd=round(float(charged), 2) if charged is not None else total)}
    except Exception as e:  # noqa: BLE001 - fail closed on any parse / record error after a sent buy
        return {**out, **_record(rpc, job, state="unknown", reasons=["buy_unknown"],
                                 error=f"{type(e).__name__}: {e}"[:300])}


def tick(rpc: Rpc, client: EvoBuyClient, gt: gtb.GoTicketsBuyClient | None = None) -> dict:
    """Claim at most one requested buy and carry it out. Returns what was recorded."""
    job = rpc("manual_sub_buy_claim", {})
    if not job:
        return {"action": "idle"}
    row, cfg = job["row"], job["cfg"]
    if row.get("market") == "gotickets":
        return _buy_gt(rpc, gt, job)
    out = {"action": "buy", "buy_id": row["buy_id"]}
    qty = int(row["qty"])
    try:
        tg = client.get_ticket_group(row["ticket_group_id"])
    except EvoWriteRejected as e:
        return {**out, **_record(rpc, job, state="stopped", reasons=["listing_gone"], error=str(e))}
    except requests.RequestException as e:  # nothing was sent; the row stops (no retry)
        return {**out, **_record(rpc, job, state="stopped", reasons=["listing_read_failed"],
                                 error=type(e).__name__)}
    reasons = listing_checks(tg, qty=qty, max_price_ea=float(row["max_price_ea"]))
    if reasons:
        return {**out, **_record(rpc, job, state="stopped", reasons=reasons)}
    price = float(tg["wholesale_price"])
    ceiling = row.get("max_total_usd")
    quote = read_tax_quote(client, tg["id"], qty) if cfg.get("tax_quote") else None
    quoted: dict[str, Any] = {}
    if quote:
        quoted = {"quote_tax_usd": quote["tax"], "quote_total_usd": quote["total"]}
    if cfg.get("tax_quote") and ceiling is not None:
        if not quote:
            return {**out, **_record(rpc, job, state="stopped", reasons=["tax_quote_failed"])}
        if quote["total"] > float(ceiling) + 0.005:
            return {**out, **_record(rpc, job, state="stopped", reasons=["total_above_ceiling"], **quoted)}
    if cfg.get("tax_quote_test") and not cfg.get("tax_quote"):
        # the first run is a test (operator 2026-11-13): keep EVO's answer as it came so its shape
        # can be confirmed. Nothing is decided from it and no signature is sent.
        quoted = {"quote_raw": probe_tax_quote(client, tg["id"], qty)}
    body = buy_order_body(ticket_group_id=tg["id"], quantity=qty, price_ea=price,
                          seller_office_id=tg["office"]["id"], buyer_office_id=int(cfg["evo_buyer_office_id"]),
                          shipment_type=SHIPMENT_FOR_FORMAT[tg["format"]],
                          email_address_id=cfg.get("evo_email_address_id"),
                          note=f"Manual sub for {row['sale_site']} sale {row['sale_order_number']} "
                               f"(manual_sub_buy {row['buy_id']}, by {row['requested_by']})",
                          tax_signature=quote["signature"] if quote else None)
    # re-check the lease right before the write: only the worker that still holds the row may buy
    if _record(rpc, job, state="buying", **quoted)["recorded"] != "buying":
        return {**out, "state": "lease_lost"}
    try:
        resp = client.create_order(body)
    except EvoWriteRejected as e:
        return {**out, **_record(rpc, job, state="stopped", reasons=["buy_failed"], error=str(e))}
    except EvoWriteUnknown as e:
        return {**out, **_record(rpc, job, state="unknown", reasons=["buy_unknown"], error=str(e))}
    try:  # the buy was sent: anything going wrong from here is an unknown outcome, never a silent one
        order = (resp.get("orders") or [resp])[0]
        if not order.get("id"):
            raise ValueError("no order id in the EVO response")
        return {**out, **_record(rpc, job, state="bought", buy_order_id=str(order["id"]),
                                 buy_state=order.get("state"), bought_price_ea=price,
                                 bought_total_usd=quote["total"] if quote else round(price * qty, 2))}
    except Exception as e:  # noqa: BLE001 - fail closed on any parse / record error after a sent buy
        return {**out, **_record(rpc, job, state="unknown", reasons=["buy_unknown"],
                                 error=f"{type(e).__name__}: {e}"[:300])}


def order_status(order: dict) -> dict:
    """What a fresh GET /v9/orders/{id} says, in the shape manual_sub_buy_follow_record stores.
    Seat numbers are kept only when real: EVO sends 0 for a seat the seller has not assigned."""
    item = ((order.get("items") or [None])[0]) or {}
    tg = item.get("ticket_group") or {}
    seats = [str(x) for x in (item.get("seats") or tg.get("seats") or []) if str(x).strip() not in ("", "0")]
    reason = next((str(order[k]) for k in ("seller_rejection_reason", "seller_cancellation_reason",
                                           "buyer_cancellation_reason", "buyer_rejection_reason")
                   if order.get(k)), None)
    return {"order_state": order.get("state"), "seller_state": order.get("seller_state"),
            "order_total_usd": order.get("total"), "bought_section": tg.get("section"),
            "bought_row": tg.get("row"), "seats": seats, "rejection_reason": reason}


def gt_purchase_status(purchase: dict) -> dict:
    """What a fresh GoTickets purchase read says, in the shape manual_sub_buy_follow_record stores.
    Both final answers come from exact lists (gotickets_buy_client.GT_CONFIRMED / GT_REJECTED):
    'rejected' releases the sale for another buy, so a status that only resembles a cancellation
    (or one nobody has seen yet) leaves the buy pending for a person to read."""
    raw = purchase.get("orderStatus")
    status = str(raw or "").strip().upper()
    seller = "accepted" if status in gtb.GT_CONFIRMED else "rejected" if status in gtb.GT_REJECTED else None
    return {"order_state": raw, "seller_state": seller, "order_total_usd": purchase.get("orderTotal")}


def follow(rpc: Rpc, client: EvoBuyClient, gt: gtb.GoTicketsBuyClient | None = None) -> dict:
    """Re-read at most one bought order that is due a status check. Reads only (GET)."""
    job = rpc("manual_sub_buy_follow_claim", {})
    if not job:
        return {"action": "idle"}
    out = {"action": "follow", "buy_id": job["buy_id"], "buy_order_id": job["buy_order_id"]}
    try:
        if job.get("market") == "gotickets":
            if gt is None or not gt.ready():
                return {**out, "error": "no_gt_buy_client"}  # it comes round again once the client is back
            patch = gt_purchase_status(gt.get_purchase(job["buy_order_id"]))
        else:
            patch = order_status(client.get_order(job["buy_order_id"]))
    except (EvoWriteRejected, gtb.GoTicketsBuyError, requests.RequestException, ValueError) as e:
        return {**out, "error": type(e).__name__}  # the claim already stamped the check; it comes round again
    outcome = rpc("manual_sub_buy_follow_record", {"p_buy_id": job["buy_id"], "p_patch": patch})
    return {**out, "outcome": outcome}
