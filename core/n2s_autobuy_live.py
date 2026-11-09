"""N2S auto-buy LIVE worker — EVO sub covering an EVO sale, one step per tick.

Operator authorization 2026-11-09: "I authorize EVO only, build the live executor, limit to
only 1 live run for testing". The database decides what may run (``n2s_autobuy_live_claim``:
mode 'live', not killed, the live-run allowance not used up, EVO sale + EVO sub, state
live_buy / approved, enough time left) and hands out one row at a time under a lease, so two
web workers can never act on the same row. This module does the market steps:

  buy    re-check the guards → read the ticket group fresh (not ours, enough tickets, a split
         that fits, price not above our quote, event > 24 h out) → POST /v9/orders once
  poll   read our purchase: accepted → read the sale, still pending → accept it (reviewer
         53658); rejected → stop; not accepted by sub_confirm_by → stop, sale NOT accepted

Never retried: a write that fails is recorded and the row stops. A write whose outcome is
unknown (timeout / 5xx) stops the row AND flips the kill switch until a person checks EVO.
Never rejects a sale (operator: "dont auto reject").
"""
from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

import requests

from core.n2s_autobuy_exec import _ts, buy_guards, next_action
from evo_buy_client import (
    SHIPMENT_FOR_FORMAT,
    EvoBuyClient,
    EvoWriteRejected,
    EvoWriteUnknown,
    buy_order_body,
)

OUR_BROKERAGE_ID = 1768  # S4K Entertainment

Rpc = Callable[[str, dict], Any]


def _record(rpc: Rpc, exec_id: int, **patch: Any) -> dict:
    rpc("n2s_autobuy_live_record", {"p_exec_id": exec_id, "p_patch": patch})
    return patch


def ticket_group_checks(tg: dict, *, qty: int, sub_total: float, now: datetime, min_lead_s: int) -> list[str]:
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
    if price is None or round(float(price) * qty, 2) > round(sub_total + 0.01, 2):
        reasons.append("price_rose")
    if tg.get("format") not in SHIPMENT_FOR_FORMAT:
        reasons.append("unknown_format")
    start = _ts((tg.get("event") or {}).get("occurs_at"))
    if start is None or (start - now).total_seconds() < min_lead_s:
        reasons.append("event_within_24h")
    return reasons


def _buy(rpc: Rpc, client: EvoBuyClient, job: dict, now: datetime) -> dict:
    row, cfg, eid = job["row"], job["cfg"], job["row"]["exec_id"]
    guard_row = {**row, "event_start_utc": row.get("event_dt_local")}  # venue-local read as UTC: earlier, so safe
    reasons = buy_guards(guard_row, now=now, spend_today=float(row.get("spend_today_before") or 0),
                         buys_today=0, failures_today=0, project_spent=float(row.get("project_spent_before") or 0),
                         cfg=cfg)
    if reasons:
        return _record(rpc, eid, phase="stopped", reasons=reasons)
    try:
        tg = client.get_ticket_group(row["sub_listing_id"])
    except EvoWriteRejected as e:
        return _record(rpc, eid, phase="stopped", reasons=["listing_gone"], live_error=str(e))
    except requests.RequestException as e:  # nothing was sent; the row stops (no retry)
        return _record(rpc, eid, phase="stopped", reasons=["listing_read_failed"], live_error=type(e).__name__)
    reasons = ticket_group_checks(tg, qty=int(row["qty"]), sub_total=float(row["sub_total_usd"]), now=now,
                                  min_lead_s=int(cfg["min_event_lead_s"]))
    if reasons:
        return _record(rpc, eid, phase="stopped", reasons=reasons)
    body = buy_order_body(ticket_group_id=tg["id"], quantity=int(row["qty"]), price_ea=float(tg["wholesale_price"]),
                          seller_office_id=tg["office"]["id"], buyer_office_id=int(cfg["evo_buyer_office_id"]),
                          shipment_type=SHIPMENT_FOR_FORMAT[tg["format"]],
                          email_address_id=cfg.get("evo_email_address_id"),
                          note=f"N2S auto-cover for EVO sale {row.get('sale_order_key')} (n2s {row['n2s_id']})")
    try:
        resp = client.create_order(body)
    except EvoWriteRejected as e:
        return _record(rpc, eid, phase="stopped", reasons=["buy_failed"], live_error=str(e))
    except EvoWriteUnknown as e:
        return _record(rpc, eid, phase="buy_unknown", reasons=["buy_unknown"], live_error=str(e))
    order = (resp.get("orders") or [resp])[0]
    if not order.get("id"):
        return _record(rpc, eid, phase="buy_unknown", reasons=["buy_unknown"],
                       live_error="no order id in the EVO response")
    total = order.get("total")
    note = None if total is None or float(total) <= float(row["sub_total_usd"]) + 0.01 else \
        f"EVO total ${total} is above the quoted ${row['sub_total_usd']}"
    return _record(rpc, eid, phase="buy_sent", buy_order_id=str(order["id"]), buy_state=order.get("state"),
                   live_error=note)


def _poll(rpc: Rpc, client: EvoBuyClient, job: dict, now: datetime) -> dict:
    row, cfg, eid = job["row"], job["cfg"], job["row"]["exec_id"]
    if row["phase"] == "buy_sent":
        st = client.get_order(row["buy_order_id"]).get("state")
        step = next_action(row, now=now, sub_status=st)
        if step["action"] == "wait_sub":
            return _record(rpc, eid, phase="buy_sent", buy_state=st)
        if step["action"] == "stop":
            return _record(rpc, eid, phase="stopped", buy_state=st, reasons=[step["reason"]])
        _record(rpc, eid, phase="sub_accepted", buy_state=st)
    sale = client.get_order(row["sale_order_key"]).get("state")
    if sale != "pending":
        return _record(rpc, eid, phase="stopped", sale_state=sale, reasons=["sale_not_pending"])
    try:
        out = client.accept_order(row["sale_order_key"], int(cfg["evo_reviewer_id"]))
    except EvoWriteRejected as e:
        return _record(rpc, eid, phase="accept_failed", sale_state=sale, reasons=["accept_failed"], live_error=str(e))
    except EvoWriteUnknown as e:
        return _record(rpc, eid, phase="accept_unknown", sale_state=sale, reasons=["accept_unknown"],
                       live_error=str(e))
    return _record(rpc, eid, phase="accepted", sale_state=out.get("state") or "accepted")


def tick(rpc: Rpc, client: EvoBuyClient, now: datetime | None = None) -> dict:
    """Claim at most one row and take its next step. Returns what was recorded."""
    now = now or datetime.now(timezone.utc)
    job = rpc("n2s_autobuy_live_claim", {})
    if not job:
        return {"action": "idle"}
    step = _buy if job["action"] == "buy" else _poll
    return {"action": job["action"], "exec_id": job["row"]["exec_id"], **step(rpc, client, job, now)}
