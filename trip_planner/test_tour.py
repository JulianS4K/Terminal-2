"""Offline test of the retail tour-package planner — both sourcing modes.

Fixtures are real snapshots: Megan Moroney (we own deep -> owned-splits, premium capture) and
Yankees away games (road owned ~0 -> market-sourced, fan beats market, we earn the spread).

Run from repo root:  python3 -m trip_planner.test_tour
"""
from __future__ import annotations

from datetime import date

from .planner import plan_tour_package
from .retail import price_leg

HOME = {"name": "NYC", "lat": 40.7128, "lon": -74.0060}
START, END = date(2026, 6, 1), date(2026, 9, 1)


def _row(eid, name, city, d, lat, lon, owned, ask, getin, med, qty):
    return {"tevo_event_id": eid, "event_name": name,
            "primary_performer_name": name.split(" at ")[0],
            "venue_city": city, "venue_state": "XX", "event_date": d,
            "venue_lat": lat, "venue_lon": lon, "_coord_source": "venue",
            "_owned": owned, "_our_ask": ask, "_getin": getin, "_med": med, "_qty": qty}

CONCERT = [  # Megan Moroney NE run — we own deep
    _row(1, "Megan Moroney", "Boston",       "2026-07-06", 42.36, -71.06,  88, 542.29, 140, 302.82, 1480),
    _row(2, "Megan Moroney", "Newark",       "2026-07-09", 40.73, -74.17, 143, 455.26, 138, 301.23, 1510),
    _row(3, "Megan Moroney", "Philadelphia", "2026-07-11", 39.95, -75.16, 116, 594.83, 202, 422.30, 737),
]
AWAY = [  # Yankees road trip — owned ~0
    _row(11, "New York Yankees at Detroit Tigers", "Detroit", "2026-06-22", 42.33, -83.04, 0, None, 20.19, 55.14, 659),
    _row(12, "New York Yankees at Boston Red Sox", "Boston",  "2026-06-26", 42.36, -71.06, 0, None, 131.54, 208.98, 2205),
]


def test_price_leg_modes():
    o = price_leg(3, 88, 542.29, 140, 302.82, 1480)
    assert o["sourcing"] == "owned" and 302 < o["unit_price"] < 542
    m = price_leg(3, 0, None, 20.19, 55.14, 659)
    assert m["sourcing"] == "market" and abs(m["unit_price"] - 20.19 * 1.18) < 0.5
    assert price_leg(3, 0, None, None, None, 0)["unit_price"] is None
    # heavy overhang clears fully to market (team home-stand behaviour)
    heavy = price_leg(3, 682, 97.72, None, 67.32, 3851)   # share 18% > 15% -> clear=1
    assert abs(heavy["unit_price"] - 67.32) < 0.01


def test_concert_owned_splits():
    pk = plan_tour_package(CONCERT, HOME, 3, 20000, START, END)["package"]
    assert all(l["sourcing"] == "owned" for l in pk["legs"])
    assert pk["owned_moved"] == 3 * len(pk["legs"])
    assert pk["vs_market"] > 0                       # premium over market median
    assert pk["fan_total"] < pk["our_standalone_ask"]  # but below our standalone ask


def test_team_away_market_sourced():
    pk = plan_tour_package(AWAY, HOME, 3, 20000, START, END, mode="team_away")["package"]
    assert all(l["sourcing"] == "market" for l in pk["legs"])
    assert pk["owned_moved"] == 0
    assert pk["vs_market"] < 0                        # fan beats market median
    assert pk["gross_margin"] > 0                     # we earn the fulfillment spread


def main():
    print("\nRetail tour-package — dual mode, qty=3\n")
    for label, rows, mode in [("concert", CONCERT, "concert"), ("team-away", AWAY, "team_away")]:
        pk = plan_tour_package(rows, HOME, 3, 20000, START, END, mode=mode)["package"]
        gm = pk["gross_margin"]
        print(f"  {label:9} {pk['count']} stops / {pk['cities']} cities  "
              f"fan ${pk['fan_total_bundled']:>6,.0f}  vs market ${pk['vs_market']:>+6,.0f}  "
              f"owned moved {pk['owned_moved']:>2}  margin {('$'+format(gm,',.0f')) if gm else '—'}")
    test_price_leg_modes()
    test_concert_owned_splits()
    test_team_away_market_sourced()
    print("\n  asserts passed: owned-splits premium (concert) + market-sourced spread (team away)\n")


if __name__ == "__main__":
    main()
