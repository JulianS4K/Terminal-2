"""GoTickets sub offer worker — sends one substitution request the CRM confirmed.

Operator 2026-11-13: for a GoTickets order the CRM flagged as needing a sub, where the sub
finder found only an "offer" cover (gates 3-5: another section in the same zone, or rows
back), the CRM is asked whether to offer it; on its yes this worker offers the seats to the
customer through GoTickets' substitution-request API. Gates 1-2 need no offer (the seats are
the same or better in the same section) and gate 6 is results only — neither reaches here:
``sub_finder_gt_offer_request`` refuses them.

  claim   ``sub_finder_gt_offer_claim`` hands out one 'requested' row, once, under a lease —
          only while ``sub_finder_config.gt_offer_enabled``
  read    the sale, fresh (GET): still ours, not cancelled, not already delivered, same
          quantity; and its existing substitution requests: none open or accepted
  offer   POST /rest/substitution-requests, once, through gotickets_sub_client (path-pinned)
  follow  afterwards, GET the sale's requests until the customer accepts or it is denied

Nothing is bought here: buying the replacement seats is done by a person, outside this path.
Never retried. A refused offer stops the row; an unknown outcome is recorded as 'unknown'
and blocks another offer for that order until a person has looked at Seller Central.
"""
from __future__ import annotations

from collections.abc import Callable
from typing import Any

import requests

from evo_buy_client import EvoWriteRejected, EvoWriteUnknown
from gotickets_sub_client import GoTicketsSubClient, GoTicketsSubError

Rpc = Callable[[str, dict], Any]

OPEN_REQUEST = frozenset({"PENDING", "CUSTOMER_REVIEW", "ACCEPTED"})
DELIVERED = frozenset({"COMPLETED", "PENDING_TRANSFER_PROOF", "PENDING_PROOF_OF_PICKUP"})


def _record(rpc: Rpc, row: dict, **patch: Any) -> dict:
    got = rpc("sub_finder_gt_offer_record",
              {"p_offer_id": row["offer_id"], "p_token": row.get("lease_token"), "p_patch": patch})
    return {**patch, "recorded": got}


def sale_checks(sale: dict, existing: list[dict], *, qty: int | None) -> list[str]:
    """Reasons the fresh reads say NOT to offer (empty = offer)."""
    reasons = []
    if sale.get("cancelReason"):
        reasons.append("sale_cancelled")
    if sale.get("fulfilled") or sale.get("sellerStatus") in DELIVERED:
        reasons.append("sale_already_delivered")
    if qty is not None and sale.get("quantity") is not None and int(sale["quantity"]) != int(qty):
        reasons.append("quantity_differs")
    if any(r.get("status") in OPEN_REQUEST for r in existing):
        reasons.append("request_already_open")
    return reasons


def offer_body(row: dict, sale: dict) -> dict:
    body = {"orderId": int(row["gt_order_id"]), "section": row["section"], "row": row["seat_row"],
            "notes": row.get("notes") or "", "source": "SELLER_CENTRAL_API"}
    if sale.get("orderItemId"):
        body["orderItemId"] = int(sale["orderItemId"])
    if row.get("rebate_amount") is not None and float(row["rebate_amount"]) > 0:
        body["rebateAmount"] = round(float(row["rebate_amount"]), 2)
    return body


def tick(rpc: Rpc, client: GoTicketsSubClient) -> dict:
    """Claim at most one confirmed offer and send it. Returns what was recorded."""
    row = rpc("sub_finder_gt_offer_claim", {})
    if not row:
        return {"action": "idle"}
    out = {"action": "offer", "offer_id": row["offer_id"]}
    try:
        sale = client.get_sale(row["gt_order_id"])
        existing = client.list_requests(row["gt_order_id"])
    except EvoWriteRejected as e:
        return {**out, **_record(rpc, row, state="stopped", reasons=["sale_not_found"], error=str(e)[:300])}
    except (GoTicketsSubError, requests.RequestException, ValueError) as e:  # nothing was sent
        return {**out, **_record(rpc, row, state="stopped", reasons=["sale_read_failed"], error=type(e).__name__)}
    reasons = sale_checks(sale, existing, qty=row.get("qty"))
    if reasons:
        return {**out, **_record(rpc, row, state="stopped", reasons=reasons)}
    # re-check the lease right before the write: only the worker that still holds the row may offer
    if _record(rpc, row, state="sending")["recorded"] != "sending":
        return {**out, "state": "lease_lost"}
    try:
        made = client.create_request(offer_body(row, sale))
    except EvoWriteRejected as e:
        return {**out, **_record(rpc, row, state="stopped", reasons=["offer_refused"], error=str(e)[:300])}
    except EvoWriteUnknown as e:
        return {**out, **_record(rpc, row, state="unknown", reasons=["offer_unknown"], error=str(e)[:300])}
    except Exception as e:  # noqa: BLE001 - the offer was sent: an unreadable answer is unknown, never silent
        return {**out, **_record(rpc, row, state="unknown", reasons=["offer_unknown"],
                                 error=f"{type(e).__name__}: {e}"[:300])}
    if not made.get("id"):
        return {**out, **_record(rpc, row, state="unknown", reasons=["offer_unknown"], error="no request id")}
    return {**out, **_record(rpc, row, state="sent", gt_request_id=int(made["id"]),
                             gt_status=made.get("status") or "PENDING")}


def follow(rpc: Rpc, client: GoTicketsSubClient) -> dict:
    """Re-read at most one sent offer that is due a status check. Reads only (GET)."""
    job = rpc("sub_finder_gt_offer_follow_claim", {})
    if not job:
        return {"action": "idle"}
    out = {"action": "follow", "offer_id": job["offer_id"]}
    try:
        mine = next((r for r in client.list_requests(job["gt_order_id"])
                     if str(r.get("id")) == str(job["gt_request_id"])), None)
    except (EvoWriteRejected, GoTicketsSubError, requests.RequestException, ValueError) as e:
        return {**out, "error": type(e).__name__}  # the claim stamped the check; it comes round again
    if mine is None:
        return {**out, "error": "request_not_listed"}
    status = rpc("sub_finder_gt_offer_follow_record",
                 {"p_offer_id": job["offer_id"],
                  "p_patch": {"gt_status": mine.get("status"), "denial_reason": mine.get("denialReason")}})
    return {**out, "status": status}
