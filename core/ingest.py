"""Ingest helpers — extracted from server.py (BR-CODE-1 core/ pass).

Pure(ish) data-shaping + fire-and-forget helpers for the admin/ingest routes
(routers/admin.py): kick the collector edge function, upsert a TEvo event-detail
dict into our `events` table, and project a TEvo /v9/orders row to our
`evo_orders` schema. Read/transform + write-our-own-DB only — never an upstream
write (RULE 2). Depends outward only on core.helpers + stdlib + requests
(one-directional).

`requests` is the same module object the server uses, so the test patch
(monkeypatch app.requests.post) reaches fire_collect here directly.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone

import requests

from core.helpers import (
    parse_iso_or_none as _parse_iso_or_none,
    to_int_or_none as _to_int_or_none,
    to_num_or_none as _to_num_or_none,
)

_log = logging.getLogger("core.ingest")


def fire_collect(url: str, secret: str) -> None:
    """Fire-and-forget POST to the collector edge function (cron trigger). Errors
    are swallowed — the caller runs this in a daemon thread and only cares that
    it was kicked, not the result."""
    try:
        requests.post(
            url,
            headers={"X-Cron-Secret": secret, "Content-Type": "application/json"},
            json={},
            timeout=180,
        )
    except Exception as e:
        _log.warning(f"collect fire error: {e}")


def upsert_tevo_event_into_events(db, ev: dict) -> int | None:
    """Upsert a TEvo event-detail dict into our `events` table. Returns the
    event id if upserted, None otherwise."""
    eid = ev.get("id")
    if not eid:
        return None
    venue = ev.get("venue") or {}
    perfs = ev.get("performances") or []
    primary = next((p.get("performer") for p in perfs if p.get("primary")), None) \
              or (perfs[0].get("performer") if perfs else None) \
              or {}
    row = {
        "id": int(eid),
        "name": ev.get("name"),
        "occurs_at_local": ev.get("occurs_at_local") or ev.get("occurs_at"),
        "state": ev.get("state"),
        "venue_id": venue.get("id"),
        "venue_name": venue.get("name"),
        "venue_location": venue.get("location"),
        "primary_performer_id": primary.get("id"),
        "primary_performer_name": primary.get("name"),
        "performer_ids": [
            p.get("performer", {}).get("id")
            for p in perfs
            if isinstance(p.get("performer", {}).get("id"), int)
        ],
        "popularity_score": ev.get("popularity_score"),
        "long_term_popularity_score": ev.get("long_term_popularity_score"),
        "configuration_id": (ev.get("configuration") or {}).get("id"),
        "configuration_name": (ev.get("configuration") or {}).get("name"),
        "event_type": ev.get("category", {}).get("slug")
                      if isinstance(ev.get("category"), dict)
                      else ev.get("category"),
    }
    try:
        db.table("events").upsert(row, on_conflict="id").execute()
        return int(eid)
    except Exception as e:
        _log.warning(f"events upsert failed for {eid}: {e}")
        return None


def flatten_order(order: dict) -> dict:
    """Project a TEvo /v9/orders row to our evo_orders schema."""
    buyer = order.get("buyer") or {}
    buyer_brk = buyer.get("brokerage") or {}
    seller = order.get("seller") or {}
    seller_brk = seller.get("brokerage") or {}
    cl = order.get("client") or {}
    return {
        "evo_order_id": _to_int_or_none(order.get("id")),
        "state": order.get("state"),
        "type": order.get("type"),
        "fraud_check_status": order.get("fraud_check_status"),
        "total":               _to_num_or_none(order.get("total")),
        "subtotal":            _to_num_or_none(order.get("subtotal")),
        "tax":                 _to_num_or_none(order.get("tax")),
        "shipping":            _to_num_or_none(order.get("shipping")),
        "service_fee":         _to_num_or_none(order.get("service_fee")),
        "refunded":            _to_num_or_none(order.get("refunded")),
        "balance":             _to_num_or_none(order.get("balance")),
        "additional_expense":  _to_num_or_none(order.get("additional_expense")),
        "reference":           order.get("reference"),
        "invoice_number":      order.get("invoice_number"),
        "po_number":           order.get("po_number"),
        "instructions":        order.get("instructions"),
        "partner":             order.get("partner"),
        "buyer_id":            _to_int_or_none(buyer.get("id")),
        "buyer_name":          buyer.get("name"),
        "buyer_brokerage_id":  _to_int_or_none(buyer_brk.get("id")),
        "buyer_brokerage_name": buyer_brk.get("name"),
        "seller_id":           _to_int_or_none(seller.get("id")),
        "seller_name":         seller.get("name"),
        "seller_brokerage_id": _to_int_or_none(seller_brk.get("id")),
        "seller_brokerage_name": seller_brk.get("name"),
        "client_id":           _to_int_or_none(cl.get("id")),
        "client_name":         cl.get("name"),
        "client_phone":        ((cl.get("phone_numbers") or [{}])[0] or {}).get("number") if cl.get("phone_numbers") else None,
        "client_email":        ((cl.get("email_addresses") or [{}])[0] or {}).get("address") if cl.get("email_addresses") else None,
        "evo_created_at":      _parse_iso_or_none(order.get("created_at")),
        "evo_updated_at":      _parse_iso_or_none(order.get("updated_at")),
        "hold_placed_at":      _parse_iso_or_none(order.get("hold_placed_at")),
        "hold_expires_at":     _parse_iso_or_none(order.get("hold_expires_at")),
        "raw":                 order,
        "last_seen_at":        datetime.now(timezone.utc).isoformat(),
    }
