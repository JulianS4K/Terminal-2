"""N2S auto-buy LIVE worker — an EVO sub covering a sale on EVO, GoTickets, SeatGeek, Vivid or TickPick.

Operator authorization 2026-11-09: "I authorize EVO only, build the live executor, limit to
only 1 live run for testing". The database decides what may run (``n2s_autobuy_live_claim``:
mode 'live', not killed, the live-run allowance not used up, EVO sale + EVO sub, state
live_buy / approved, enough time left) and hands out one row at a time under a lease, so two
web workers can never act on the same row. This module does the market steps:

  buy    re-check the guards → (TickPick sale: our seller login still shows it Unconfirmed) →
         read the ticket group fresh (not ours, enough tickets, a split that fits, price not
         above our quote, event further out than min_event_lead, enough time left for the
         seller to accept: the window for an in-hand listing or not, from our own EVO history,
         20261112020000) → POST /v9/orders once
  poll   read our purchase: accepted → read the sale, still pending → accept it (reviewer
         53658); rejected → stop; not accepted by sub_confirm_by → stop, sale NOT accepted

Never retried: a write that fails is recorded and the row stops. A write whose outcome is
unknown (timeout / 5xx) stops the row AND flips the kill switch until a person checks EVO.
Never rejects a sale (operator: "dont auto reject"). Only a database call is retried, once, and
only when the connection dropped (:func:`retrying`); a repeated record is a no-op in the DB.
"""
from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

import httpx
import requests

import time

from core.n2s_autobuy_exec import SUB_REJECTED, _ts, buy_guards, next_action
from sale_accept_client import PENDING, SaleAcceptClient
from evo_buy_client import (
    SHIPMENT_FOR_FORMAT,
    EvoBuyClient,
    EvoWriteRejected,
    EvoWriteUnknown,
    buy_order_body,
)

OUR_BROKERAGE_ID = 1768  # S4K Entertainment
VERIFY_DELAY_S = 3.0      # pause before re-reading the sale after an accept (operator 2026-11-10)

Rpc = Callable[[str, dict], Any]

# A database call that never got an answer because the connection dropped: Supabase closes idle
# HTTP/2 connections, and the next call on one fails with "Server disconnected" (5 times on
# 2026-11-11). Timeouts are NOT here: the call may have run.
TRANSIENT_DB_ERRORS: tuple[type[BaseException], ...] = (httpx.RemoteProtocolError, httpx.ConnectError)
DB_RETRY_PAUSE_S = 0.5


def retrying(rpc: Rpc) -> Rpc:
    """``rpc`` with one retry when the connection dropped. Safe because a repeated record of a step
    that already landed returns that phase and changes nothing (n2s_autobuy_live_record,
    20261112020000), and a hold still needs the live lease."""
    def call(name: str, params: dict) -> Any:
        try:
            return rpc(name, params)
        except TRANSIENT_DB_ERRORS:
            time.sleep(DB_RETRY_PAUSE_S)
            return rpc(name, params)
    return call


def _record(rpc: Rpc, job: dict, **patch: Any) -> dict:
    """Record one step under this worker's lease. The DB refuses ('lease_lost') once the lease
    has run out or another claim holds the row."""
    row = job["row"]
    got = rpc("n2s_autobuy_live_record",
              {"p_exec_id": row["exec_id"], "p_token": row.get("lease_token"), "p_patch": patch})
    return {**patch, "recorded": got}


def _hold(rpc: Rpc, job: dict, phase: str, **patch: Any) -> bool:
    """Re-check the lease right before a market write: True only if this worker still holds it."""
    return _record(rpc, job, phase=phase, **patch)["recorded"] == phase


def _event_start(event: dict) -> datetime | None:
    """The event's real start. EVO's occurs_at is local time with a misleading "Z" (evo_client.py);
    occurs_at_local carries the real offset. Without it, occurs_at read as UTC is never later than
    the real start for US venues, so the fallback can only block a buy, never allow a late one."""
    for key in ("occurs_at_local", "occurs_at"):
        try:
            start = _ts(event.get(key))
        except ValueError:
            continue
        if start is not None:
            return start
    return None


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
    start = _event_start(tg.get("event") or {})
    if start is None or (start - now).total_seconds() < min_lead_s:
        reasons.append("event_within_24h")
    return reasons


def seller_time_checks(tg: dict, row: dict, *, now: datetime, floor_s: int) -> list[str]:
    """Stop when the sub's seller may not accept before we must confirm the sale. The window is our
    own EVO history at the configured percentile, stored on the row at enqueue: shorter for a
    listing the seller holds in hand (20261112020000). Rows without windows keep the floor."""
    in_hand = str(tg.get("in_hand")).strip().lower() == "true"
    window = row.get("seller_window_in_hand_s") if in_hand else row.get("seller_window_s")
    confirm_by = _ts(row.get("sub_confirm_by"))
    if confirm_by is None or (confirm_by - now).total_seconds() < max(floor_s, int(window or 0)):
        return ["not_enough_time_for_seller"]
    return []


def _buy(rpc: Rpc, client: EvoBuyClient, sales: SaleAcceptClient | None, job: dict, now: datetime) -> dict:
    row, cfg = job["row"], job["cfg"]
    market = row.get("sell_market")
    if market != "evo" and not (sales and sales.has_market(market)):
        # never buy a sub we could not accept the sale for
        return _record(rpc, job, phase="stopped", reasons=["no_sale_accept_token"])
    # the real start the DB stored (20261111000000); else venue-local read as UTC (earlier, so safe)
    guard_row = {**row, "event_start_utc": row.get("event_start_utc") or row.get("event_dt_local")}
    reasons = buy_guards(guard_row, now=now, spend_today=float(row.get("spend_today_before") or 0),
                         buys_today=0, failures_today=0, project_spent=float(row.get("project_spent_before") or 0),
                         cfg=cfg)
    if reasons:
        return _record(rpc, job, phase="stopped", reasons=reasons)
    if market == "tickpick":
        # An unconfirmed TickPick sale lapses and vanishes after 10-60 min, and N2S's TickPick sales
        # were only shown visible to our seller login on 2026-11-10: buy only for a sale that login
        # can read right now as Unconfirmed. Nothing has been sent yet, so a failed read stops.
        try:
            sale = sales.sale_state(market, row["sale_order_key"])  # type: ignore[union-attr]
        except Exception as e:  # noqa: BLE001 - fail closed: never buy for a sale we cannot see
            return _record(rpc, job, phase="stopped", reasons=["sale_read_failed"], live_error=type(e).__name__)
        if sale not in PENDING[market]:
            return _record(rpc, job, phase="stopped", sale_state=sale, reasons=["sale_not_pending"])
    try:
        tg = client.get_ticket_group(row["sub_listing_id"])
    except EvoWriteRejected as e:
        return _record(rpc, job, phase="stopped", reasons=["listing_gone"], live_error=str(e))
    except requests.RequestException as e:  # nothing was sent; the row stops (no retry)
        return _record(rpc, job, phase="stopped", reasons=["listing_read_failed"], live_error=type(e).__name__)
    reasons = ticket_group_checks(tg, qty=int(row["qty"]), sub_total=float(row["sub_total_usd"]), now=now,
                                  min_lead_s=int(cfg["min_event_lead_s"]))
    reasons += seller_time_checks(tg, row, now=now, floor_s=int(cfg["min_confirm_window_s"]))
    if reasons:
        return _record(rpc, job, phase="stopped", reasons=reasons)
    body = buy_order_body(ticket_group_id=tg["id"], quantity=int(row["qty"]), price_ea=float(tg["wholesale_price"]),
                          seller_office_id=tg["office"]["id"], buyer_office_id=int(cfg["evo_buyer_office_id"]),
                          shipment_type=SHIPMENT_FOR_FORMAT[tg["format"]],
                          email_address_id=cfg.get("evo_email_address_id"),
                          note=f"N2S auto-cover for {market} sale {row.get('sale_order_key')} (n2s {row['n2s_id']})")
    if not _hold(rpc, job, "buying"):
        return {"phase": "lease_lost"}  # nothing sent; the claim sweep decides what happens to the row
    try:
        resp = client.create_order(body)
    except EvoWriteRejected as e:
        return _record(rpc, job, phase="stopped", reasons=["buy_failed"], live_error=str(e))
    except EvoWriteUnknown as e:
        return _record(rpc, job, phase="buy_unknown", reasons=["buy_unknown"], live_error=str(e))
    try:  # the buy was sent: anything going wrong from here is an unknown outcome, never a silent one
        order = (resp.get("orders") or [resp])[0]
        if not order.get("id"):
            raise ValueError("no order id in the EVO response")
        total = order.get("total")
        quoted = round(float(row["sub_total_usd"]) + float(row.get("est_tax_usd") or 0), 2)  # with tax
        note = None if total is None or float(total) <= quoted + 0.01 else \
            f"EVO total ${total} is above the quoted ${quoted:.2f}"
        return _record(rpc, job, phase="buy_sent", buy_order_id=str(order["id"]), buy_state=order.get("state"),
                       live_error=note)
    except Exception as e:  # noqa: BLE001 - fail closed on any parse / record error after a sent buy
        return _record(rpc, job, phase="buy_unknown", reasons=["buy_unknown"],
                       live_error=f"{type(e).__name__}: {e}"[:300])


def _sale_state(client: EvoBuyClient, sales: SaleAcceptClient | None, market: str, key: Any) -> tuple[str | None, bool]:
    """(the sale's state on the market that sold it, whether that state means it still awaits our accept)."""
    if market == "evo":
        st = client.get_order(key).get("state")
        return st, st == "pending"
    st = sales.sale_state(market, key)  # type: ignore[union-attr]
    return st, st in PENDING[market]


def _poll(rpc: Rpc, client: EvoBuyClient, sales: SaleAcceptClient | None, job: dict, now: datetime) -> dict:
    row, cfg = job["row"], job["cfg"]
    market = row.get("sell_market") or "evo"
    st = row.get("buy_state")
    if row["phase"] == "buy_sent":
        st = client.get_order(row["buy_order_id"]).get("state")
        step = next_action(row, now=now, sub_status=st)
        if step["action"] == "wait_sub":
            return _record(rpc, job, phase="buy_sent", buy_state=st)
        if step["action"] == "stop":
            return _record(rpc, job, phase="stopped", buy_state=st, reasons=[step["reason"]])
    sale, pending = _sale_state(client, sales, market, row["sale_order_key"])
    if not pending:
        return _record(rpc, job, phase="stopped", buy_state=st, sale_state=sale, reasons=["sale_not_pending"])
    if not _hold(rpc, job, "sub_accepted", buy_state=st, sale_state=sale):
        return {"phase": "lease_lost"}  # another worker may hold the row now: do not accept
    try:
        if market == "evo":
            out = client.accept_order(row["sale_order_key"], int(cfg["evo_reviewer_id"]))
        else:
            out = sales.accept(market, row["sale_order_key"])  # type: ignore[union-attr]
    except EvoWriteRejected as e:
        return _record(rpc, job, phase="accept_failed", sale_state=sale, reasons=["accept_failed"], live_error=str(e))
    except EvoWriteUnknown as e:
        return _record(rpc, job, phase="accept_unknown", sale_state=sale, reasons=["accept_unknown"],
                       live_error=str(e))
    # Re-read the sale (operator 2026-11-10): an accept counts only when the market itself shows
    # the sale has left pending and was not rejected or cancelled.
    time.sleep(VERIFY_DELAY_S)
    try:
        after, still_pending = _sale_state(client, sales, market, row["sale_order_key"])
    except Exception as e:  # noqa: BLE001 - an unreadable re-read is unverified, never "accepted"
        return _record(rpc, job, phase="accept_failed", sale_state=sale, reasons=["accept_unverified"],
                       live_error=f"accept returned OK ({out.get('state')}); re-read failed: {type(e).__name__}")
    if still_pending:
        return _record(rpc, job, phase="accept_failed", sale_state=after, reasons=["accept_unverified"],
                       live_error="accept returned OK but the market still shows the sale pending")
    if str(after or "").strip().lower() in SUB_REJECTED:
        return _record(rpc, job, phase="accept_failed", sale_state=after, reasons=["sale_rejected_after_accept"])
    return _record(rpc, job, phase="accepted", sale_state=after)


def tick(rpc: Rpc, client: EvoBuyClient, now: datetime | None = None,
         sales: SaleAcceptClient | None = None) -> dict:
    """Claim at most one row and take its next step. Returns what was recorded."""
    now = now or datetime.now(timezone.utc)
    job = rpc("n2s_autobuy_live_claim", {})
    if not job:
        return {"action": "idle"}
    step = _buy if job["action"] == "buy" else _poll
    return {"action": job["action"], "exec_id": job["row"]["exec_id"], **step(rpc, client, sales, job, now)}
