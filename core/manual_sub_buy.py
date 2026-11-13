"""MANUAL sub buy worker — buys one EVO listing the operator chose for one sale.

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
  buy     POST /v9/orders, once, through evo_buy_client (path-pinned; RULE 2), with the
          quote's tax_signature when there is one

  follow  afterwards, GET /v9/orders/{id} (a read) until the seller has confirmed or rejected
          the order, storing its state, what EVO charged and the seat numbers (mig 20261112000000)

Never retried. A rejected buy stops the row. A buy whose outcome is unknown (timeout / 5xx /
unreadable answer) is recorded as 'unknown', which flips this path's kill switch until a
person has checked EVO.
"""
from __future__ import annotations

from collections.abc import Callable
from typing import Any

import requests

from evo_buy_client import (
    SHIPMENT_FOR_FORMAT,
    EvoBuyClient,
    EvoWriteRejected,
    EvoWriteUnknown,
    buy_order_body,
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


def tax_quote(client: EvoBuyClient, ticket_group_id: Any, qty: int) -> dict | None:
    """EVO's quote for this purchase as {signature, tax, total}, or None when it gives no
    usable one. Nothing is bought by asking, so a failure here is never an unknown outcome."""
    try:
        got = client.tax_quote(ticket_group_id, qty)
        whole = got["wholesale"]
        quote = {"signature": str(got["tax_signature"]), "tax": round(float(whole["tax"]), 2),
                 "total": round(float(whole["total"]), 2)}
    except (EvoWriteRejected, EvoWriteUnknown, requests.RequestException, KeyError, TypeError, ValueError):
        return None
    return quote if quote["signature"] and quote["total"] > 0 and quote["tax"] >= 0 else None


def tick(rpc: Rpc, client: EvoBuyClient) -> dict:
    """Claim at most one requested buy and carry it out. Returns what was recorded."""
    job = rpc("manual_sub_buy_claim", {})
    if not job:
        return {"action": "idle"}
    row, cfg = job["row"], job["cfg"]
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
    quote = tax_quote(client, tg["id"], qty) if cfg.get("tax_quote") else None
    quoted: dict[str, Any] = {}
    if quote:
        quoted = {"quote_tax_usd": quote["tax"], "quote_total_usd": quote["total"]}
    if cfg.get("tax_quote") and ceiling is not None:
        if not quote:
            return {**out, **_record(rpc, job, state="stopped", reasons=["tax_quote_failed"])}
        if quote["total"] > float(ceiling) + 0.005:
            return {**out, **_record(rpc, job, state="stopped", reasons=["total_above_ceiling"], **quoted)}
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


def follow(rpc: Rpc, client: EvoBuyClient) -> dict:
    """Re-read at most one bought order that is due a status check. Reads only (GET)."""
    job = rpc("manual_sub_buy_follow_claim", {})
    if not job:
        return {"action": "idle"}
    out = {"action": "follow", "buy_id": job["buy_id"], "buy_order_id": job["buy_order_id"]}
    try:
        order = client.get_order(job["buy_order_id"])
    except (EvoWriteRejected, requests.RequestException, ValueError) as e:
        return {**out, "error": type(e).__name__}  # the claim already stamped the check; it comes round again
    outcome = rpc("manual_sub_buy_follow_record", {"p_buy_id": job["buy_id"], "p_patch": order_status(order)})
    return {**out, "outcome": outcome}
