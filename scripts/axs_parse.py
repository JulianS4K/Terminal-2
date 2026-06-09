#!/usr/bin/env python3
"""Distill a raw AXS event payload (the ~1.8MB endpoint JSON) into a compact,
storable summary. Read-only: parses a local/echoed document, never calls out.

AXS amounts are in CENTS; we render dollars. Resale (AXS Marketplace / FlashSeats
resale) is identified by an offerID that carries a `resale-fee-<offerID>` entry
in prices.fees (these are the 16-digit 9e15 offerIDs); everything else is primary
box-office inventory.
"""
from __future__ import annotations
import json, sys, pathlib

def c2d(cents):  # cents -> dollars
    return None if cents is None else round(cents / 100.0, 2)

def distill(doc: dict) -> dict:
    body = doc.get("body", {})
    meta = body.get("meta", {})
    sections = body.get("sections", {}) or {}
    prices = body.get("prices", {}) or {}
    offers = (body.get("offers", {}) or {}).get("offers", []) or []
    startflow = body.get("startflow", {}) or {}

    # resale offerIDs = those with a dedicated resale-fee in the fee schedule
    resale_ids = {
        f["id"].split("resale-fee-", 1)[1]
        for f in prices.get("fees", []) if str(f.get("id", "")).startswith("resale-fee-")
    }

    # priceLevelID -> min primary base price ($), from offerPrices.zonePrices
    pl_base: dict[str, float] = {}
    for op in prices.get("offerPrices", []):
        if str(op.get("offerID")) in resale_ids:
            continue
        for zp in op.get("zonePrices", []):
            for pl in zp.get("priceLevels", []):
                plid = str(pl.get("priceLevelID"))
                for pr in pl.get("prices", []):
                    b = c2d(pr.get("base"))
                    if b is not None:
                        pl_base[plid] = min(b, pl_base.get(plid, b))

    sec_rows, getins = [], []
    for label, s in sections.items():
        avail = s.get("availability", {}) or {}
        qty = sum(p.get("amount", 0) or 0 for p in avail.get("prices", []))
        pls = [str(p.get("priceLevel")) for p in avail.get("prices", [])]
        bases = [pl_base[p] for p in pls if p in pl_base]
        is_resale = any(str(o) in resale_ids for o in s.get("offerIDs", []))
        if qty > 0 and bases:
            getins.append(min(bases))
        sec_rows.append({
            "section": label,
            "neighborhood": s.get("neighborhoodDescription"),
            "ga": s.get("isGeneralAdmission"),
            "sold_out": avail.get("isSoldOut"),
            "avail_qty": qty,
            "price_min": min(bases) if bases else None,
            "price_max": max(bases) if bases else None,
            "seat_types": s.get("seatTypes"),
            "has_resale": is_resale,
            "connection_fee": s.get("connectionFee"),
        })

    seats_primary = seats_resale = 0
    for o in offers:
        n = len(o.get("items", []))
        if str(o.get("offerID")) in resale_ids:
            seats_resale += n
        else:
            seats_primary += n

    dms = [d.get("name") or d.get("label") for d in (startflow.get("deliveryMethods") or [])]

    return {
        "event": meta.get("event"),
        "venue": meta.get("venue"),
        "event_date": meta.get("event_date"),
        "tz": meta.get("event_date_zone"),
        "api": meta.get("api"),
        "onsale_status": startflow.get("onSaleStatus"),
        "currency": prices.get("currency"),
        "response_s": doc.get("response_s"),
        "quota_remaining": doc.get("quota_remaining"),
        "totals": {
            "listings": meta.get("listings"),
            "sections": meta.get("sections_count"),
            "offers": meta.get("offer_groups"),
            "price_min": meta.get("price_min"),
            "price_max": meta.get("price_max"),
            "get_in_available": min(getins) if getins else None,
            "seats_primary": seats_primary,
            "seats_resale": seats_resale,
            "resale_offer_ids": len(resale_ids),
        },
        "delivery_methods": dms,
        "sections": sorted(sec_rows, key=lambda r: (r["price_min"] is None, r["price_min"] or 0)),
    }

if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "axs_sample.json"
    doc = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    out = distill(doc)
    secs = out.pop("sections")
    print(json.dumps(out, indent=2, ensure_ascii=False))
    print("\nPER-SECTION:")
    print(f"{'section':<14}{'neigh':<13}{'avail':>6}{'min$':>8}{'max$':>8}{'resale':>8}  seat_types")
    for r in secs:
        print(f"{(r['section'] or ''):<14}{(r['neighborhood'] or ''):<13}"
              f"{r['avail_qty']:>6}{(r['price_min'] or 0):>8.0f}{(r['price_max'] or 0):>8.0f}"
              f"{('yes' if r['has_resale'] else '-'):>8}  {','.join(r['seat_types'] or [])}")
