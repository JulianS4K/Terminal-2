"""Build the AXS watch's document from what our Firefox extension captured on an AXS page (operator 2026-11-25:
"build our own" AXS poller, "so we can poll more events and more frequently", then "Build the extension for Firefox,
incorporate containers").

The extension (axs_extension/) opens an event's public AXS page in a tab of its own container and keeps the JSON
answers the page's own script receives: the seat manifest (`offers[].items[]`, one item a seat or a GA place), the
price book (`offerPrices[].zonePrices[].priceLevels[].prices[]`, amounts in cents) and the on-sale state. It sends no
request of its own to AXS. This module turns those answers into the same envelope TicketsData's `/fetch` returns, so
the database settles both readers' reads with one parser (`axs_watch_parse`, through `axs_watch_record_ext`):

    {"status": "ok", "exit_code": 0, "elapsed_seconds": ..., "event": {...}, "onsale": {...},
     "groups": [{"offer_id", "ticket_qty": {"min", "max"}}], "listings": [...]}

A listing is a run of adjacent seats sharing offer, market, section, row, price level, seat type and status, as
TicketsData groups them; a GA place is counted, not seated. The answers are found by their shape, not their URL, so a
renamed endpoint still reads; an answer that matches no shape is ignored.

`build_record(capture)` returns the keyword arguments of `axs_watch_record_ext`: the content and status of a read the
page answered, or the failure (Cloudflare's block, AXS's waiting room, a timeout) the extension saw.
"""
from __future__ import annotations

import re
from typing import Any, Iterator

MAX_DEPTH = 6
PAGE_TEXT_MAX = 4000
ERROR_MAX = 200

# what the page says when there is nothing to read; the not-on-sale words are the ones axs_watch_settle_one looks for
# (mig 20261125010000), so such an event drops to the not_on_sale_every cadence as it does under TicketsData
_NOT_ON_SALE = re.compile(r"coming soon|not (?:currently |yet )?on sale|no tickets are currently available", re.I)
_EXPIRED = re.compile(r"this event has (?:ended|passed)|event is over|past event|no longer available", re.I)


def _c2d(cents: Any) -> float | None:
    try:
        return None if cents is None else round(float(cents) / 100.0, 2)
    except (TypeError, ValueError):
        return None


def _walk(node: Any, depth: int = 0) -> Iterator[dict]:
    """Every dict inside an answer, the answer first, at most MAX_DEPTH deep."""
    if depth > MAX_DEPTH:
        return
    if isinstance(node, dict):
        yield node
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from _walk(v, depth + 1)
    elif isinstance(node, list):
        for v in node:
            if isinstance(v, (dict, list)):
                yield from _walk(v, depth + 1)


def _is_offer_list(v: Any) -> bool:
    """`offers`: a list of offers, each with a list of seat items."""
    return isinstance(v, list) and any(
        isinstance(o, dict) and isinstance(o.get("items"), list)
        and any(isinstance(i, dict) and ("priceLevelID" in i or "sectionLabel" in i) for i in o["items"])
        for o in v)


def classify(answers: list[Any]) -> dict[str, list]:
    """The pieces the document needs, from every captured answer: the offers (with their seat items), the price book's
    offer entries, and the on-sale and event dicts found along the way."""
    found: dict[str, list] = {"offers": [], "offer_prices": [], "onsale": [], "events": []}
    seen_offers: set[int] = set()
    for answer in answers:
        for d in _walk(answer):
            offers = d.get("offers")
            if _is_offer_list(offers) and id(offers) not in seen_offers:
                seen_offers.add(id(offers))
                found["offers"].extend(o for o in offers if isinstance(o, dict))
            prices = d.get("offerPrices")
            if isinstance(prices, list):
                found["offer_prices"].extend(p for p in prices if isinstance(p, dict))
            if "onSaleNow" in d or "onSaleStatus" in d:
                found["onsale"].append(d)
            if isinstance(d.get("venue"), dict) and (d.get("title") or d.get("name")):
                found["events"].append(d)
    return found


def _price_book(offer_prices: list[dict]) -> tuple[dict, dict, dict, dict, list]:
    """price level id -> (face, fees), price level id -> label, offer id -> type, offer id -> name; and the GA rows (a
    price level that carries its own availability and no seats)."""
    face: dict[str, float] = {}
    fees: dict[str, float] = {}
    label: dict[str, str] = {}
    otype: dict[str, str] = {}
    oname: dict[str, str] = {}
    ga_rows: list[dict] = []
    for op in offer_prices:
        oid = str(op.get("offerID") or op.get("offerId") or "")
        if op.get("offerType"):
            otype[oid] = str(op["offerType"])
        if op.get("offerName") or op.get("name"):
            oname[oid] = str(op.get("offerName") or op.get("name"))
        for zp in op.get("zonePrices") or []:
            for pl in (zp or {}).get("priceLevels") or []:
                plid = str(pl.get("priceLevelID") or pl.get("priceLevelId") or "")
                if not plid:
                    continue
                if pl.get("priceLevelLabel") or pl.get("label"):
                    label[plid] = str(pl.get("priceLevelLabel") or pl.get("label"))
                prices = pl.get("prices") or []
                p0 = prices[0] if prices and isinstance(prices[0], dict) else {}
                base = _c2d(p0.get("base"))
                if base is not None:
                    face[plid] = base if plid not in face else max(face[plid], base)   # as the database: the highest base
                fee_list = p0.get("fees")
                if isinstance(fee_list, list):
                    total = sum(_c2d(f.get("amount")) or 0.0 for f in fee_list if isinstance(f, dict))
                    if total:
                        fees[plid] = round(total, 2)
                avail = pl.get("availability")
                amount = avail.get("amount") if isinstance(avail, dict) else avail
                if isinstance(amount, (int, float)) and not isinstance(amount, bool):
                    ga_rows.append({"offer_id": oid, "price_level_id": plid, "quantity": int(amount),
                                    "zone": (zp or {}).get("zoneLabel") or (zp or {}).get("label")})
    return {"face": face, "fees": fees}, label, otype, oname, ga_rows


def _qty_limits(offers: list[dict], offer_prices: list[dict]) -> list[dict]:
    """groups[].ticket_qty, from whatever order limits the answers carry for an offer."""
    groups: list[dict] = []
    for o in offers + offer_prices:
        lo = hi = None
        for a, b in (("minQuantity", "maxQuantity"), ("minimumQuantity", "maximumQuantity"), ("minTickets", "maxTickets")):
            if o.get(a) is not None or o.get(b) is not None:
                lo, hi = o.get(a), o.get(b)
                break
        limits = o.get("quantityLimits") or o.get("ticketLimits") or o.get("quantity")
        if lo is None and hi is None and isinstance(limits, dict):
            lo, hi = limits.get("min"), limits.get("max")
        if lo is not None or hi is not None:
            groups.append({"offer_id": str(o.get("offerID") or o.get("offerId") or ""), "ticket_qty": {"min": lo, "max": hi}})
    return groups


def _seat_key(seat: str) -> tuple[int, Any]:
    return (0, int(seat)) if seat.isdigit() else (1, seat)


def _runs(seats: list[str]) -> list[list[str]]:
    """Adjacent numbered seats together; a seat without a number stands alone."""
    out: list[list[str]] = []
    for s in sorted(set(seats), key=_seat_key):
        if out and s.isdigit() and out[-1][-1].isdigit() and int(s) == int(out[-1][-1]) + 1:
            out[-1].append(s)
        else:
            out.append([s])
    return out


def build_listings(offers: list[dict], offer_prices: list[dict]) -> list[dict]:
    book, pl_label, otype, oname, ga_rows = _price_book(offer_prices)
    groups: dict[tuple, dict] = {}
    for o in offers:
        o_id = str(o.get("offerID") or o.get("offerId") or "")
        for it in o.get("items") or []:
            if not isinstance(it, dict):
                continue
            oid = str(it.get("offerID") or o_id)
            plid = str(it.get("priceLevelID") or "")
            resale = "resale" in otype.get(oid, "").lower() or it.get("seatType") == "FLASHSEATS"
            face = book["face"].get(plid)
            if face is None and it.get("originalPrice") is not None:
                try:
                    face = float(it["originalPrice"])
                except (TypeError, ValueError):
                    face = None
            ga = bool(it.get("isGASection"))
            key = (oid, resale, it.get("sectionLabel"), None if ga else it.get("rowLabel"), plid, it.get("seatType"),
                   it.get("statusCodeLabel"), it.get("priceCodeLabel"))
            g = groups.setdefault(key, {
                "kind": "resale" if resale else "primary", "section": it.get("sectionLabel"),
                "row": None if ga else it.get("rowLabel"), "seat_type": it.get("seatType"),
                "status": it.get("statusCodeLabel"), "offer_id": oid,
                "offer_name": oname.get(oid) or o.get("offerName") or o.get("name"),
                "price_level": it.get("priceLevelLabel") or pl_label.get(plid), "price_code": it.get("priceCodeLabel"),
                "neighborhood": it.get("neighborhoodPrintDescription") or it.get("neighborhoodLabel"),
                "general_admission": ga,
                "seller_notes": it.get("sellerNotes") or " | ".join(str(x) for x in (it.get("info1"), it.get("info2")) if x) or None,
                "face": face, "fees": book["fees"].get(plid), "seats": [], "count": 0,
            })
            g["count"] += 1
            if not ga and it.get("number") not in (None, ""):
                g["seats"].append(str(it["number"]))

    listings: list[dict] = []
    for g in groups.values():
        pieces = _runs(g["seats"]) if g["seats"] else [None]
        for run in pieces:
            pricing = {"face": g["face"]}
            if g["fees"] is not None:
                pricing["fees_total"] = g["fees"]
                if g["face"] is not None:
                    pricing["all_in"] = round(g["face"] + g["fees"], 2)
            row = {k: v for k, v in g.items() if k not in ("face", "fees", "seats", "count") and v is not None}
            row["pricing"] = {k: v for k, v in pricing.items() if v is not None}
            if run is None:
                row["quantity"] = g["count"]
            else:
                row["seats"], row["quantity"] = run, len(run)
            listings.append(row)

    # a GA event with no seat items: each price level that reports its own availability is a place to sell
    if not groups:
        for r in ga_rows:
            if r["quantity"] <= 0:
                continue
            plid = r["price_level_id"]
            pricing = {"face": book["face"].get(plid)}
            if book["fees"].get(plid) is not None:
                pricing["fees_total"] = book["fees"][plid]
                if pricing["face"] is not None:
                    pricing["all_in"] = round(pricing["face"] + book["fees"][plid], 2)
            listings.append({k: v for k, v in {
                "kind": "resale" if "resale" in otype.get(r["offer_id"], "").lower() else "primary",
                "section": r.get("zone") or pl_label.get(plid) or "GA", "general_admission": True,
                "offer_id": r["offer_id"], "offer_name": oname.get(r["offer_id"]), "price_level": pl_label.get(plid),
                "quantity": r["quantity"], "pricing": {k: v for k, v in pricing.items() if v is not None},
            }.items() if v is not None})
    listings.sort(key=lambda l: (str(l.get("section")), str(l.get("row")), (l.get("seats") or [""])[0]))
    return listings


def build_body(capture: dict) -> dict:
    """The TicketsData-shaped body for one page the extension read."""
    found = classify([c.get("json") for c in capture.get("captures") or [] if isinstance(c, dict)])
    elapsed = capture.get("elapsed_s")
    if not found["offers"] and not found["offer_prices"]:
        text = str(capture.get("page_text") or "")[:PAGE_TEXT_MAX]
        hit = _NOT_ON_SALE.search(text)
        if hit:
            return {"status": "error", "error": f"not on sale yet: the AXS page says {hit.group(0)!r}", "elapsed_seconds": elapsed}
        if _EXPIRED.search(text):
            return {"status": "expired", "elapsed_seconds": elapsed}
        return {"status": "error", "error": "the AXS page showed no seat inventory", "elapsed_seconds": elapsed}

    onsale_src = found["onsale"][0] if found["onsale"] else {}
    status = onsale_src.get("onSaleStatus") if isinstance(onsale_src.get("onSaleStatus"), dict) else onsale_src
    ev = found["events"][0] if found["events"] else {}
    offer_ids = [str(o.get("offerID") or o.get("offerId")) for o in found["offers"] if o.get("offerID") or o.get("offerId")]
    listings = build_listings(found["offers"], found["offer_prices"])
    return {
        "status": "ok", "exit_code": 0, "elapsed_seconds": elapsed,
        "event": {"id": str(capture.get("event_id") or ""), "title": ev.get("title") or ev.get("name") or capture.get("title"),
                  "venue": {"name": (ev.get("venue") or {}).get("name")} if ev else None,
                  "timezone": ev.get("timezone")},
        "onsale": {"offer_id": offer_ids[0] if offer_ids else None, "flow": onsale_src.get("flow"),
                   "status": {"onSaleNow": status.get("onSaleNow"), "onSaleDate": status.get("onSaleDate"),
                              "offSaleDate": status.get("offSaleDate")}},
        "groups": _qty_limits(found["offers"], found["offer_prices"]),
        "listings": listings,
        "listings_summary": {"listings": len(listings), "seats": sum(int(l.get("quantity") or 0) for l in listings),
                             "answers": len(capture.get("captures") or []), "reader": "extension"},
    }


def build_record(capture: dict) -> dict:
    """The arguments of axs_watch_record_ext for one capture: what the page answered, or how it failed."""
    out: dict[str, Any] = {"p_event_id": str(capture.get("event_id") or ""), "p_status_code": None, "p_content": None,
                           "p_timed_out": False, "p_error_msg": None, "p_fired_at": capture.get("fired_at")}
    outcome = capture.get("outcome") or "loaded"
    why = str(capture.get("error") or "")[:ERROR_MAX]
    if outcome == "blocked":                  # Cloudflare's "AXS Access Info" page or a challenge the extension does not answer
        out["p_status_code"] = int(capture.get("http_status") or 403)
    elif outcome == "queue":                  # AXS's waiting room: the extension does not wait in it
        out["p_error_msg"] = ("queue: the AXS page put the read in its waiting room " + why).strip()[:ERROR_MAX]
    elif outcome in ("timeout", "error"):
        out["p_timed_out"] = outcome == "timeout"
        out["p_error_msg"] = (f"{outcome}: {why}" if why else outcome)[:ERROR_MAX]
    elif capture.get("http_status") in (404, 410):
        out["p_status_code"] = int(capture["http_status"])
    else:
        out["p_status_code"] = 200
        out["p_content"] = {"response_s": capture.get("elapsed_s"), "body": build_body(capture)}
    return out
