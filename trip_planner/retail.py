"""Retail "tour with the artist" pricing — turns a routed multi-city itinerary into a
priced consumer package, with two auto-selected sourcing modes:

  * **owned-splits** (we hold >= qty at the stop): price our owned inventory, clearing toward
    the market median in proportion to how much of the listed supply WE are. Moderate
    overhang -> we hold a premium; heavy overhang -> we clear to market (validated: concerts
    capture a premium, team home stands don't).
  * **market-sourced** (we hold < qty — e.g. a team's away games, where road owned ~ 0):
    buy-to-fulfill at the market get-in plus a fulfillment margin; the fan still beats the
    browse-median while we earn the spread.

Pure functions — no DB, unit-testable. The DB wiring + routing live in `planner.py`.
"""
from __future__ import annotations

# tunable dials (qualitative outcomes are robust to these; exact dollars move with them)
DEFAULT_CLEAR_AT = 0.15      # owned share of listed supply at which we clear FULLY to market
DEFAULT_AWAY_MARGIN = 0.18   # fulfillment margin over get-in when buying to fulfill
DEFAULT_BUNDLE = 0.05        # extra multi-city discount applied to the package (>= 3 cities)


def price_leg(qty: int, owned, our_ask, getin, market_median, market_qty,
              clear_at: float = DEFAULT_CLEAR_AT,
              away_margin: float = DEFAULT_AWAY_MARGIN) -> dict:
    """Price one show for `qty` tickets. Returns a dict with unit price, sourcing, economics.

    owned-splits when we hold >= qty AND have an ask + market context; else market-sourced.
    `unit_price` is None only when neither our ask nor a market price exists (unpriceable).
    """
    qty = max(1, int(qty))
    owned = int(owned or 0)

    if owned >= qty and our_ask is not None and market_median is not None and market_qty:
        share = owned / market_qty if market_qty else 1.0
        clear = min(1.0, share / clear_at) if clear_at > 0 else 1.0
        unit = our_ask - clear * (our_ask - market_median)
        unit = round(max(unit, 0.0), 2)
        return {
            "unit_price": unit,
            "sourcing": "owned",
            "owned": owned,
            "our_ask": round(float(our_ask), 2),
            "market_median": round(float(market_median), 2),
            "supply_share": round(share, 4),
            # we move `qty` of our own seats; margin vs our standalone ask (positive = discount given)
            "moved": qty,
        }

    basis = getin if getin is not None else market_median
    if basis is None:
        return {"unit_price": None, "sourcing": "unpriceable", "owned": owned, "moved": 0}
    unit = round(float(basis) * (1 + away_margin), 2)
    return {
        "unit_price": unit,
        "sourcing": "market",
        "owned": owned,
        "acquire_basis": round(float(basis), 2),
        "getin": round(float(getin), 2) if getin is not None else None,
        "market_median": round(float(market_median), 2) if market_median is not None else None,
        "margin": away_margin,
        "moved": 0,                     # buy-to-fulfill: none of our inventory
    }


def summarize_package(legs: list[dict], qty: int, bundle: float = DEFAULT_BUNDLE) -> dict:
    """Roll a list of priced+selected legs into a package: fan total, vs-market, our economics.

    Each leg dict must carry the `price_leg(...)` output plus `event_id`. `legs` are the
    optimizer-selected stops (the package), in date order.
    """
    qty = max(1, int(qty))
    fan = 0.0
    market = 0.0          # what the fan would pay at market median, qty each
    our_ask_total = 0.0   # our standalone asks on owned legs
    acquire = 0.0         # our acquisition cost on market legs
    owned_moved = 0
    for lg in legs:
        up = lg.get("unit_price")
        if up is None:
            continue
        fan += up * qty
        mm = lg.get("market_median")
        if mm is not None:
            market += mm * qty
        if lg.get("sourcing") == "owned":
            our_ask_total += lg.get("our_ask", up) * qty
            owned_moved += qty
        elif lg.get("sourcing") == "market":
            acquire += lg.get("acquire_basis", up) * qty

    cities = len({lg.get("city") for lg in legs if lg.get("city")})
    bundle_rate = bundle if cities >= 3 else 0.0
    fan_after = round(fan * (1 - bundle_rate), 2)
    return {
        "fan_total": round(fan, 2),
        "fan_total_bundled": fan_after,
        "bundle_rate": bundle_rate,
        "market_total": round(market, 2),               # fan's market-median alternative
        "vs_market": round(fan_after - market, 2),       # + = premium over market, - = fan saves
        "our_standalone_ask": round(our_ask_total, 2),   # owned legs at our list price
        "our_acquisition": round(acquire, 2),            # market legs we'd buy
        "owned_moved": owned_moved,
        "gross_margin": round(fan_after - acquire, 2) if acquire else None,  # market-sourced profit
    }
