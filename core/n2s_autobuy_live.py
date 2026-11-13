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

GoTickets subs (operator 2026-11-13: "wire in gotickets similar to evo and set same limits and
same one buy condition"; its own single live run and its own $666 caps, kept by the database):

  buy    the same guards → read the listing fresh on the Pro API (still listed, not ours per
         Seller Central's GET /rest/listings/{id}, enough tickets, a split that fits, an
         electronic delivery method) → GoTickets' own total (display price,
         delivery fee, tax) no higher than our quote and inside this source's caps → enough gift
         card balance → POST /rest/pro/api/orders once, paid by gift cards (gotickets_buy_client)
  poll   read our purchase on Seller Central: PENDING_CONFIRMATION = waiting, CANCELLED =
         rejected, any later state = the seller confirmed → the sale is accepted as above

Never retried: a write that fails is recorded and the row stops. A write whose outcome is
unknown (timeout / 5xx) stops the row AND flips the kill switch until a person checks the market.
Never rejects a sale (operator: "dont auto reject"). Only a database call is retried, once, and
only when the connection dropped (:func:`retrying`); a repeated record is a no-op in the DB.
"""
from __future__ import annotations

import time
from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

import httpx
import requests

import gotickets_buy_client as gtb
from core.n2s_autobuy_exec import SUB_REJECTED, _ts, buy_guards, next_action
from evo_buy_client import (
    SHIPMENT_FOR_FORMAT,
    EvoBuyClient,
    EvoWriteRejected,
    EvoWriteUnknown,
    buy_order_body,
    read_tax_quote,
)
from sale_accept_client import PENDING, SaleAcceptClient

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


def gt_profile(cfg: dict) -> dict | None:
    """The buyer details GoTickets requires on every order (email, phone, billing address, and the
    recipient a Mobile Transfer / PDF is sent to), from the config; None when any is missing."""
    billing, recipient = cfg.get("gt_billing_address") or {}, cfg.get("gt_recipient") or {}
    if not (cfg.get("gt_buyer_email") and cfg.get("gt_buyer_phone")):
        return None
    if not all(billing.get(k) for k in ("firstName", "lastName", "address1", "city", "state", "postalCode", "country")):
        return None
    if not all(recipient.get(k) for k in ("firstName", "lastName", "email", "phoneNumber")):
        return None
    return {"email": cfg["gt_buyer_email"], "phone": cfg["gt_buyer_phone"], "billing": billing, "recipient": recipient}


def _buy_gt(rpc: Rpc, gt: gtb.GoTicketsBuyClient | None, job: dict, now: datetime, guard_row: dict) -> dict:
    """A GoTickets sub (operator 2026-11-13): read the listing fresh, price the order with GoTickets'
    own formula, re-run every money guard on that total, pay it from gift cards, POST /orders once.
    Everything before the POST only reads; a stop there gives the GoTickets live run back."""
    row, cfg = job["row"], job["cfg"]
    qty = int(row["qty"])
    if gt is None or not gt.ready():
        return _record(rpc, job, phase="stopped", reasons=["no_gt_buy_client"])
    profile = gt_profile(cfg)
    if profile is None:
        return _record(rpc, job, phase="stopped", reasons=["gt_buyer_profile_missing"])
    if not row.get("gt_event_id"):
        return _record(rpc, job, phase="stopped", reasons=["no_gt_event_id"])
    try:
        listing = gt.get_listing(row["gt_event_id"], row["sub_listing_id"])
    except (EvoWriteRejected, gtb.GoTicketsBuyError) as e:  # nothing was sent; the row stops (no retry)
        return _record(rpc, job, phase="stopped", reasons=["listing_read_failed"], live_error=str(e)[:300])
    if listing is None:
        return _record(rpc, job, phase="stopped", reasons=["listing_gone"])
    try:  # operator 2026-11-13: Seller Central GET /rest/listings/{id} answers only for OUR listings
        if gt.is_own_listing(row["sub_listing_id"]):
            return _record(rpc, job, phase="stopped", reasons=["our_own_listing"])
    except (EvoWriteRejected, gtb.GoTicketsBuyError) as e:  # fail closed: never buy what may be ours
        return _record(rpc, job, phase="stopped", reasons=["own_listing_check_failed"], live_error=str(e)[:300])
    reasons = []
    if int(listing.get("quantity") or 0) < qty:
        reasons.append("short_quantity")
    if listing.get("validSplitQuantities") and qty not in listing["validSplitQuantities"]:
        reasons.append("split_not_allowed")
    delivery = gtb.pick_delivery(listing)
    if delivery is None:
        reasons.append("no_electronic_delivery")
    if listing.get("displayPrice") is None:
        reasons.append("price_unknown")
    if reasons or delivery is None:  # (delivery None is already a reason; the test narrows the type)
        return _record(rpc, job, phase="stopped", reasons=reasons)
    total = gtb.expected_total(listing, qty, delivery)
    quoted = float(row["sub_total_usd"])
    if total > round(quoted + 0.01, 2):
        return _record(rpc, job, phase="stopped", reasons=["price_rose"],
                       live_error=f"GoTickets total ${total:.2f} is above the quoted ${quoted:.2f}")
    # every money guard again, on the real total (tax and delivery included) and this source's caps
    reasons = buy_guards({**guard_row, "sub_total_usd": total, "est_tax_usd": 0}, now=now,
                         spend_today=float(row.get("spend_today_before") or 0), buys_today=0, failures_today=0,
                         project_spent=float(row.get("project_spent_before") or 0), cfg=cfg)
    reasons += seller_time_checks(listing, row, now=now, floor_s=int(cfg["min_confirm_window_s"]))
    if reasons:
        return _record(rpc, job, phase="stopped", reasons=reasons, live_error=f"GoTickets total ${total:.2f}")
    try:
        cards = gt.get_gift_cards()
    except (EvoWriteRejected, gtb.GoTicketsBuyError) as e:
        return _record(rpc, job, phase="stopped", reasons=["gift_card_read_failed"], live_error=str(e)[:300])
    # GoTickets accepts an actual total up to $0.01 per ticket above expectedTotal: cover that too
    cards_used = gtb.pick_gift_cards(cards, total + 0.01 * qty, cfg.get("gt_gift_card_ids"))
    if not cards_used:
        return _record(rpc, job, phase="stopped", reasons=["gift_card_balance_short"],
                       live_error=f"gift cards cannot cover ${total:.2f}")
    body = gtb.order_body(event_id=row["gt_event_id"], listing_id=row["sub_listing_id"], qty=qty, expected=total,
                          delivery_id=delivery["id"], email=profile["email"], phone=profile["phone"],
                          billing=profile["billing"], recipient=profile["recipient"], gift_card_ids=cards_used,
                          note=f"N2S auto-cover for {row.get('sell_market')} sale {row.get('sale_order_key')} "
                               f"(n2s {row['n2s_id']})")
    if not _hold(rpc, job, "buying"):
        return {"phase": "lease_lost"}  # nothing sent; the claim sweep decides what happens to the row
    try:
        resp = gt.create_order(body)
    except EvoWriteRejected as e:
        return _record(rpc, job, phase="stopped", reasons=["buy_failed"], live_error=str(e))
    except EvoWriteUnknown as e:
        return _record(rpc, job, phase="buy_unknown", reasons=["buy_unknown"], live_error=str(e))
    try:  # the buy was sent: anything going wrong from here is an unknown outcome, never a silent one
        oid = gtb.order_id(resp)
        if not oid:
            raise ValueError("no purchase id in the GoTickets response")
        charged = resp.get("orderTotal")
        note = None if charged is None or float(charged) <= total + 0.01 * qty else \
            f"GoTickets total ${charged} is above the expected ${total:.2f}"
        return _record(rpc, job, phase="buy_sent", buy_order_id=oid, buy_state=resp.get("orderStatus"),
                       live_error=note)
    except Exception as e:  # noqa: BLE001 - fail closed on any parse / record error after a sent buy
        return _record(rpc, job, phase="buy_unknown", reasons=["buy_unknown"],
                       live_error=f"{type(e).__name__}: {e}"[:300])


def _buy(rpc: Rpc, client: EvoBuyClient, sales: SaleAcceptClient | None, job: dict, now: datetime,
         gt: gtb.GoTicketsBuyClient | None = None) -> dict:
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
    if row.get("sub_source") == "gotickets":
        return _buy_gt(rpc, gt, job, now, guard_row)
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
    # Pre-check 3 (operator 2026-11-13, when the config's tax_quote is on): EVO's own total for
    # this purchase, tax included (POST /v9/tax_quotes: a calculation, nothing is bought). Every
    # money guard is run again on that total in place of our venue estimate; no quote, no buy.
    quote = None
    if cfg.get("tax_quote"):
        quote = read_tax_quote(client, tg["id"], int(row["qty"]))
        if not quote:
            return _record(rpc, job, phase="stopped", reasons=["tax_quote_failed"])
        real_tax = round(quote["total"] - float(row["sub_total_usd"]), 2)
        reasons = buy_guards({**guard_row, "est_tax_usd": real_tax}, now=now,
                             spend_today=float(row.get("spend_today_before") or 0), buys_today=0, failures_today=0,
                             project_spent=float(row.get("project_spent_before") or 0), cfg=cfg)
        if reasons:
            return _record(rpc, job, phase="stopped", reasons=reasons,
                           live_error=f"EVO quoted ${quote['total']:.2f} with tax")
    body = buy_order_body(ticket_group_id=tg["id"], quantity=int(row["qty"]), price_ea=float(tg["wholesale_price"]),
                          seller_office_id=tg["office"]["id"], buyer_office_id=int(cfg["evo_buyer_office_id"]),
                          shipment_type=SHIPMENT_FOR_FORMAT[tg["format"]],
                          email_address_id=cfg.get("evo_email_address_id"),
                          note=f"N2S auto-cover for {market} sale {row.get('sale_order_key')} (n2s {row['n2s_id']})",
                          tax_signature=quote["signature"] if quote else None)
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
        quoted = quote["total"] if quote else \
            round(float(row["sub_total_usd"]) + float(row.get("est_tax_usd") or 0), 2)  # with tax
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


def _sub_status(client: EvoBuyClient, gt: gtb.GoTicketsBuyClient | None, row: dict) -> tuple[Any, str | None]:
    """(our purchase's state as its market reports it, that state as next_action reads it)."""
    if row.get("sub_source") == "gotickets":
        if gt is None:  # a sent GoTickets buy must keep being followed: fail the tick, never stop the row
            raise RuntimeError("GoTickets client missing for a GoTickets purchase")
        raw = gt.get_purchase(row["buy_order_id"]).get("orderStatus")
        return raw, gtb.purchase_state(raw)
    st = client.get_order(row["buy_order_id"]).get("state")
    return st, st


def _poll(rpc: Rpc, client: EvoBuyClient, sales: SaleAcceptClient | None, job: dict, now: datetime,
          gt: gtb.GoTicketsBuyClient | None = None) -> dict:
    row, cfg = job["row"], job["cfg"]
    market = row.get("sell_market") or "evo"
    st = row.get("buy_state")
    if row["phase"] == "buy_sent":
        st, read_as = _sub_status(client, gt, row)
        step = next_action(row, now=now, sub_status=read_as)
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
         sales: SaleAcceptClient | None = None, gt: gtb.GoTicketsBuyClient | None = None) -> dict:
    """Claim at most one row and take its next step. Returns what was recorded."""
    now = now or datetime.now(timezone.utc)
    job = rpc("n2s_autobuy_live_claim", {})
    if not job:
        return {"action": "idle"}
    step = _buy if job["action"] == "buy" else _poll
    return {"action": job["action"], "exec_id": job["row"]["exec_id"], **step(rpc, client, sales, job, now, gt=gt)}
