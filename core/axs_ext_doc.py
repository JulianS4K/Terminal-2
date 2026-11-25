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
    found: dict[str, list] = {"offers": [], "offer_prices": [], "onsale": [], "events": [], "fee_defs": [], "delivery": []}
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
                # inventory_v4 carries the fee definitions beside the price book: {id, components[], applicationMethod}
                found["fee_defs"].extend(f for f in d.get("fees") or [] if isinstance(f, dict) and isinstance(f.get("components"), list))
            dm = d.get("deliveryMethods")
            if isinstance(dm, list):
                found["delivery"].extend(m for m in dm if isinstance(m, dict))
            if "onSaleNow" in d or "onSaleStatus" in d:
                found["onsale"].append(d)
            if isinstance(d.get("venue"), dict) and (d.get("title") or d.get("name")):
                found["events"].append(d)
    return found


def _fee_for(component: dict, face: float) -> float:
    """One fee component for a ticket of `face` dollars, as AXS's inventory_v4 defines it (amounts in cents):
    Fixed `amount`; Lookup `lookupRanges` [{start, end, amount}] matched start < face <= end (end 0 = no upper
    bound); Percentage `rate` of the face, rounded to `roundOff` (0.01). Matches TicketsData's figures: an $80 GA
    ticket at Knockdown Center = 3.00 fixed + 0.54 + 15.28 lookups + 2.47 (3.09%) = 21.29."""
    method = str(component.get("calculationMethod") or "").lower()
    if method == "fixed":
        return (_c2d(component.get("amount")) or 0.0)
    if method == "lookup":
        for r in component.get("lookupRanges") or []:
            start, end = float(r.get("start") or 0), float(r.get("end") or 0)
            if face > start and (end == 0 or face <= end):
                return _c2d(r.get("amount")) or 0.0
        return 0.0
    if method == "percentage":
        step = float(component.get("roundOff") or 0.01) or 0.01
        return round(round(face * float(component.get("rate") or 0) / 100.0 / step) * step, 2)
    return 0.0


def _fees_total(offer_id: str, face: float | None, fee_defs: dict[str, dict], assigned: dict[str, list]) -> float | None:
    """Every per-item fee assigned to the offer, summed; None when the answers carry no fee definitions."""
    if face is None or offer_id not in assigned or not fee_defs:
        return None
    total = 0.0
    for fid in assigned[offer_id]:
        d = fee_defs.get(fid)
        if not d or str(d.get("applicationMethod") or "PerItem").lower() != "peritem":
            continue
        total += sum(_fee_for(c, face) for c in d.get("components") or [] if isinstance(c, dict))
    return round(total, 2)


def _price_book(offer_prices: list[dict], fee_list: list[dict] | None = None) -> dict:
    """What the price book says: price level -> face, price level -> label, offer -> type / name / limits, the fees
    assigned to each offer, and the price levels that report their own availability (GA places)."""
    book: dict[str, Any] = {"face": {}, "label": {}, "otype": {}, "oname": {}, "limits": {}, "assigned": {},
                            "fee_defs": {str(f.get("id")): f for f in fee_list or [] if f.get("id") is not None},
                            "levels": []}
    for op in offer_prices:
        oid = str(op.get("offerID") or op.get("offerId") or "")
        if op.get("offerType"):
            book["otype"][oid] = str(op["offerType"])
        if op.get("offerName") or op.get("name"):
            book["oname"][oid] = str(op.get("offerName") or op.get("name"))
        if op.get("min") is not None or op.get("max") is not None:
            book["limits"][oid] = {"min": op.get("min"), "max": op.get("max")}
        fee_ids = [str(f.get("id")) for f in op.get("fees") or [] if isinstance(f, dict) and f.get("id") is not None]
        if fee_ids:
            book["assigned"][oid] = fee_ids
        for zp in op.get("zonePrices") or []:
            for pl in (zp or {}).get("priceLevels") or []:
                plid = str(pl.get("priceLevelID") or pl.get("priceLevelId") or "")
                if not plid:
                    continue
                if pl.get("priceLevelLabel") or pl.get("label"):
                    book["label"][plid] = str(pl.get("priceLevelLabel") or pl.get("label"))
                prices = pl.get("prices") or []
                p0 = prices[0] if prices and isinstance(prices[0], dict) else {}
                base = _c2d(p0.get("base"))
                if base is not None:
                    book["face"][plid] = base if plid not in book["face"] else max(book["face"][plid], base)   # as the database: the highest base
                avail = pl.get("availability")
                amount = avail.get("amount") if isinstance(avail, dict) else avail
                if isinstance(amount, (int, float)) and not isinstance(amount, bool):
                    book["levels"].append({"offer_id": oid, "price_level_id": plid, "quantity": int(amount),
                                           "sold_out": bool((zp or {}).get("isSoldOut"))})
    return book


def _pricing(book: dict, offer_id: str, plid: str, face: float | None) -> dict:
    out: dict[str, Any] = {"face": face}
    fees = _fees_total(offer_id, face, book["fee_defs"], book["assigned"])
    if fees is not None:
        out["fees_total"] = fees
        out["tax"] = 0
        out["all_in"] = round(face + fees, 2)
    return {k: v for k, v in out.items() if v is not None}


_NON_TRANSFER = re.compile(r"non[- ]?transfer", re.I)


def _delivery_notes(delivery: list[dict]) -> dict[str, str]:
    """offer -> a note when every delivery method offered for it says it cannot be transferred ("AXS Mobile ID -
    Free (Non-Transferable)"), so the database's non-transferable rule (mig 20261124233030) withholds its seats."""
    labels: dict[str, list[str]] = {}
    for m in delivery:
        offer_ids = m.get("offerIDs") or m.get("offerIds") or m.get("offers") or [m.get("offerID") or m.get("offerId") or m.get("offer_id")]
        for o in offer_ids if isinstance(offer_ids, list) else [offer_ids]:
            if isinstance(o, dict):
                o = o.get("offerID") or o.get("id")
            if o is not None and m.get("label"):
                labels.setdefault(str(o), []).append(str(m["label"]))
    return {o: "Delivery: " + "; ".join(ls) for o, ls in labels.items() if ls and all(_NON_TRANSFER.search(l) for l in ls)}


def _qty_limits(book: dict) -> list[dict]:
    """groups[].ticket_qty: AXS puts an offer's order limits on its price book entry (offerPrices[].min / max)."""
    return [{"offer_id": oid, "ticket_qty": lim} for oid, lim in book["limits"].items()]


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


def build_listings(offers: list[dict], offer_prices: list[dict], fee_defs: list[dict] | None = None,
                   delivery: list[dict] | None = None) -> list[dict]:
    book = _price_book(offer_prices, fee_defs)
    notes = _delivery_notes(delivery or [])
    groups: dict[tuple, dict] = {}
    seated_levels: set[str] = set()
    for o in offers:
        o_id = str(o.get("offerID") or o.get("offerId") or "")
        for it in o.get("items") or []:
            if not isinstance(it, dict):
                continue
            oid = str(it.get("offerID") or o_id)
            plid = str(it.get("priceLevelID") or "")
            seated_levels.add(plid)
            resale = "resale" in book["otype"].get(oid, "").lower() or it.get("seatType") == "FLASHSEATS"
            face = book["face"].get(plid)
            if face is None and it.get("originalPrice") is not None:
                try:
                    face = float(it["originalPrice"])
                except (TypeError, ValueError):
                    face = None
            ga = bool(it.get("isGASection"))
            seat_type = it.get("seatType")
            # an accessible seat: AXS lists its disability types on the item; the feed withholds ticket_type ACCESSIBLE
            # (mig 20261125180000), as TicketsData typed such seats
            if it.get("disabilityTypes") and not re.search(r"ada|access|wheelchair", str(seat_type or ""), re.I):
                seat_type = "ACCESSIBLE"
            key = (oid, resale, it.get("sectionLabel"), None if ga else it.get("rowLabel"), plid, seat_type,
                   it.get("statusCodeLabel"), it.get("priceCodeLabel"))
            g = groups.setdefault(key, {
                "kind": "resale" if resale else "primary", "section": it.get("sectionLabel"),
                "row": None if ga else it.get("rowLabel"), "seat_type": seat_type,
                "status": it.get("statusCodeLabel"), "offer_id": oid,
                "offer_name": book["oname"].get(oid) or o.get("offerName") or o.get("name"),
                "price_level": it.get("priceLevelLabel") or book["label"].get(plid), "price_code": it.get("priceCodeLabel"),
                "neighborhood": it.get("neighborhoodPrintDescription") or it.get("neighborhoodLabel"),
                "general_admission": ga,
                "seller_notes": " | ".join(str(x) for x in (it.get("sellerNotes"), it.get("info1"), it.get("info2"), notes.get(oid)) if x) or None,
                "pricing": _pricing(book, oid, plid, face), "seats": [], "count": 0,
            })
            g["count"] += 1
            if not ga and it.get("number") not in (None, ""):
                g["seats"].append(str(it["number"]))

    listings: list[dict] = []
    for g in groups.values():
        for run in (_runs(g["seats"]) if g["seats"] else [None]):
            row = {k: v for k, v in g.items() if k not in ("seats", "count") and v is not None}
            if run is None:
                row["quantity"] = g["count"]
            else:
                row["seats"], row["quantity"] = run, len(run)
            listings.append(row)

    # a price level that reports its own availability and has no seat items is general admission: the whole of a
    # BEST_AVAILABLE event, or the GA floor of a reserved one
    for lv in book["levels"]:
        plid, oid = lv["price_level_id"], lv["offer_id"]
        if lv["quantity"] <= 0 or lv["sold_out"] or plid in seated_levels:
            continue
        listings.append({k: v for k, v in {
            "kind": "resale" if "resale" in book["otype"].get(oid, "").lower() else "primary",
            "section": book["label"].get(plid) or "General Admission", "general_admission": True,
            "offer_id": oid, "offer_name": book["oname"].get(oid), "price_level": book["label"].get(plid),
            "seller_notes": notes.get(oid), "quantity": lv["quantity"],
            "pricing": _pricing(book, oid, plid, book["face"].get(plid)),
        }.items() if v is not None})
    listings.sort(key=lambda l: (str(l.get("section")), str(l.get("row")), _seat_key((l.get("seats") or [""])[0])))
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
    listings = build_listings(found["offers"], found["offer_prices"], found["fee_defs"], found["delivery"])
    return {
        "status": "ok", "exit_code": 0, "elapsed_seconds": elapsed,
        "event": {"id": str(capture.get("event_id") or ""), "title": ev.get("title") or ev.get("name") or capture.get("title"),
                  "venue": {"name": (ev.get("venue") or {}).get("name")} if ev else None,
                  "timezone": ev.get("timezone")},
        "onsale": {"offer_id": str(onsale_src.get("offerID") or (offer_ids[0] if offer_ids else "")) or None, "flow": onsale_src.get("flow"),
                   "status": {"onSaleNow": status.get("onSaleNow"), "onSaleDate": status.get("onSaleDate"),
                              "offSaleDate": status.get("offSaleDate")}},
        "groups": _qty_limits(_price_book(found["offer_prices"])),
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
