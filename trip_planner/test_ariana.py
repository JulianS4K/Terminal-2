"""Offline end-to-end test of the planner on a real active touring performer.

Fixture = a snapshot of `public.v_event_base` for Ariana Grande (tevo_performer_id 27474),
17 geocoded upcoming dates 2026-06-14 .. 2026-08-07. Exercises the pure `plan_from_rows`
path (no DB) and asserts the exact optimizer matches the brute-force oracle.

Run from repo root:  python3 -m trip_planner.test_ariana
"""
from __future__ import annotations

from datetime import date

from .budget_optimizer import plan_optimal_2b
from .city_centroids import centroid_for
from .gigtrip.model import Constraints
from .gigtrip.optimizer import (
    brute_force_optimal,
    candidates,
    plan_optimal,
    route_km,
)
from .gigtrip.optimizer import _legs_feasible
from .planner import _ticket_cost, plan_from_rows, row_to_event

ROWS = [
    {"tevo_event_id": 3094846, "primary_performer_name": "Ariana Grande", "venue_name": "Crypto.com Arena",   "venue_city": "Los Angeles", "event_date": "2026-06-14", "venue_lat": 34.042998, "venue_lon": -118.267135},
    {"tevo_event_id": 3094847, "primary_performer_name": "Ariana Grande", "venue_name": "Crypto.com Arena",   "venue_city": "Los Angeles", "event_date": "2026-06-15", "venue_lat": 34.042998, "venue_lon": -118.267135},
    {"tevo_event_id": 3094889, "primary_performer_name": "Ariana Grande", "venue_name": "Amerant Bank Arena", "venue_city": "Sunrise",     "event_date": "2026-06-30", "venue_lat": 26.158370, "venue_lon": -80.325429},
    {"tevo_event_id": 3094890, "primary_performer_name": "Ariana Grande", "venue_name": "Amerant Bank Arena", "venue_city": "Sunrise",     "event_date": "2026-07-02", "venue_lat": 26.158370, "venue_lon": -80.325429},
    {"tevo_event_id": 3110252, "primary_performer_name": "Ariana Grande", "venue_name": "Amerant Bank Arena", "venue_city": "Sunrise",     "event_date": "2026-07-04", "venue_lat": 26.158370, "venue_lon": -80.325429},
    {"tevo_event_id": 3094898, "primary_performer_name": "Ariana Grande", "venue_name": "State Farm Arena",   "venue_city": "Atlanta",     "event_date": "2026-07-06", "venue_lat": 33.757370, "venue_lon": -84.396385},
    {"tevo_event_id": 3094901, "primary_performer_name": "Ariana Grande", "venue_name": "State Farm Arena",   "venue_city": "Atlanta",     "event_date": "2026-07-08", "venue_lat": 33.757370, "venue_lon": -84.396385},
    {"tevo_event_id": 3110254, "primary_performer_name": "Ariana Grande", "venue_name": "State Farm Arena",   "venue_city": "Atlanta",     "event_date": "2026-07-10", "venue_lat": 33.757370, "venue_lon": -84.396385},
    {"tevo_event_id": 3094899, "primary_performer_name": "Ariana Grande", "venue_name": "TD Garden",          "venue_city": "Boston",      "event_date": "2026-07-22", "venue_lat": 42.366299, "venue_lon": -71.062162},
    {"tevo_event_id": 3094900, "primary_performer_name": "Ariana Grande", "venue_name": "TD Garden",          "venue_city": "Boston",      "event_date": "2026-07-24", "venue_lat": 42.366299, "venue_lon": -71.062162},
    {"tevo_event_id": 3110257, "primary_performer_name": "Ariana Grande", "venue_name": "TD Garden",          "venue_city": "Boston",      "event_date": "2026-07-26", "venue_lat": 42.366299, "venue_lon": -71.062162},
    {"tevo_event_id": 3094895, "primary_performer_name": "Ariana Grande", "venue_name": "Centre Bell",        "venue_city": "Montreal",    "event_date": "2026-07-28", "venue_lat": 45.496036, "venue_lon": -73.569203},
    {"tevo_event_id": 3094896, "primary_performer_name": "Ariana Grande", "venue_name": "Centre Bell",        "venue_city": "Montreal",    "event_date": "2026-07-30", "venue_lat": 45.496036, "venue_lon": -73.569203},
    {"tevo_event_id": 3110259, "primary_performer_name": "Ariana Grande", "venue_name": "Centre Bell",        "venue_city": "Montreal",    "event_date": "2026-08-01", "venue_lat": 45.496036, "venue_lon": -73.569203},
    {"tevo_event_id": 3094902, "primary_performer_name": "Ariana Grande", "venue_name": "United Center",      "venue_city": "Chicago",     "event_date": "2026-08-04", "venue_lat": 41.880683, "venue_lon": -87.674185},
    {"tevo_event_id": 3094903, "primary_performer_name": "Ariana Grande", "venue_name": "United Center",      "venue_city": "Chicago",     "event_date": "2026-08-06", "venue_lat": 41.880683, "venue_lon": -87.674185},
    {"tevo_event_id": 3110270, "primary_performer_name": "Ariana Grande", "venue_name": "United Center",      "venue_city": "Chicago",     "event_date": "2026-08-07", "venue_lat": 41.880683, "venue_lon": -87.674185},
]
HOME = {"name": "New York City", "lat": 40.7128, "lon": -74.0060}
START, END = date(2026, 6, 8), date(2026, 8, 31)
BUDGETS = (2000, 4000, 6000, 9000, 14000)


def test_optimal_matches_oracle():
    events = [row_to_event(r) for r in ROWS]
    prefs = {"ariana grande": 1.0}
    for b in BUDGETS:
        c = Constraints(HOME["name"], HOME["lat"], HOME["lon"], START, END, b)
        o = plan_optimal(events, prefs, c)
        g = brute_force_optimal(events, prefs, c)
        assert abs(o.value - g.value) < 1e-9, f"budget {b}: optimal {o.value} != oracle {g.value}"


def test_optimal_beats_baseline_at_binding_budget():
    # At 9000 km from NYC, sort-by-date wastes budget flying to the earliest (LA) date;
    # the optimizer clusters the eastern + Chicago legs for strictly more shows.
    p = plan_from_rows(ROWS, HOME, 9000, START, END)
    assert p["optimal"]["count"] > p["baseline_by_date"]["count"]
    assert p["shows_gained"] >= 1


def test_city_centroid_fallback():
    # The two real venues the planner was silently dropping (no precise geocode) are now
    # recoverable from their EVO "City, ST" text via the centroid gazetteer.
    assert centroid_for("Inglewood, CA") is not None
    assert centroid_for("Brooklyn, NY") is not None
    assert centroid_for("Brooklyn, NY, USA") is not None        # tolerant of trailing country
    assert centroid_for("Nowhere, ZZ") is None

    # A row with no precise coords but a city-centroid fill is counted + included; a row that
    # resolves to neither is reported as dropped (not silently lost).
    rows = list(ROWS) + [
        {"tevo_event_id": 9001, "primary_performer_name": "Ariana Grande", "venue_name": "Kia Forum",
         "venue_city": "Inglewood", "event_date": "2026-06-20",
         "venue_lat": 33.9617, "venue_lon": -118.3531, "_coord_source": "city"},
        {"tevo_event_id": 9002, "primary_performer_name": "Ariana Grande", "venue_name": "Mystery Hall",
         "venue_city": None, "event_date": "2026-06-21", "venue_lat": None, "venue_lon": None},
    ]
    p = plan_from_rows(rows, HOME, 14000, START, END)
    assert p["coord_coverage"]["city_fallback"] == 1
    assert p["coord_coverage"]["dropped_no_coords"] == 1
    assert p["tour_date_count"] == len(ROWS) + 1   # the centroid row counts, the coord-less one doesn't


def _brute_2b(events, prefs, c, costs, budget_usd):
    """Ground-truth 2-budget optimum (max value within km AND spend) by enumeration."""
    from itertools import combinations
    cand = candidates(events, c)
    best_val, best_km = 0.0, 0.0
    for r in range(1, len(cand) + 1):
        for combo in combinations(cand, r):
            if not _legs_feasible(combo, c):
                continue
            km = route_km(combo, c)
            if km > c.max_travel_km + 1e-9:
                continue
            if sum(costs.get(int(e.id), 0.0) for e in combo) > budget_usd + 1e-9:
                continue
            val = sum(prefs.get(e.title.lower(), 0.0) for e in combo)
            if val > best_val + 1e-12 or (abs(val - best_val) <= 1e-12 and km < best_km - 1e-12):
                best_val, best_km = val, km
    return best_val


def test_two_budget():
    # attach EVO price + owned to the real fixture: $500 get-in, we own 2 at every 5th show.
    rows = [dict(r) for r in ROWS]
    for i, r in enumerate(rows):
        r["_getin"] = 500.0
        r["_owned"] = 2 if i % 5 == 0 else 0
    qty = 1

    # owned >= qty -> that show is free (ticket_cost 0); otherwise getin * (qty - owned).
    assert _ticket_cost(500.0, 2, 1) == (0.0, True)
    assert _ticket_cost(500.0, 0, 2) == (1000.0, True)
    assert _ticket_cost(None, 0, 1) == (0.0, False)      # unknown price doesn't block

    p = plan_from_rows(rows, HOME, 14000, START, END, budget_usd=2000, qty=qty)
    assert p["budget_usd"] == 2000 and p["qty_per_show"] == 1
    assert p["optimal"]["spend_usd"] <= 2000 + 1e-6           # spend budget respected
    assert p["baseline_by_date"]["spend_usd"] <= 2000 + 1e-6
    owned_ev = next(e for e in p["all_dates"] if (e["owned"] or 0) >= 1)
    assert owned_ev["ticket_cost"] == 0.0                     # owned tickets are free

    # exact 2-budget optimum matches the brute-force oracle on value.
    events = [row_to_event(r) for r in rows]
    prefs = {"ariana grande": 1.0}
    costs = {int(r["tevo_event_id"]): _ticket_cost(r["_getin"], r["_owned"], qty)[0] for r in rows}
    c = Constraints(HOME["name"], HOME["lat"], HOME["lon"], START, END, 14000)
    opt, spend = plan_optimal_2b(events, prefs, c, costs, 2000)
    assert abs(opt.value - _brute_2b(events, prefs, c, costs, 2000)) < 1e-9
    assert spend <= 2000 + 1e-6


def main():
    print(f"\nPer-performer trip planner — Ariana Grande (home {HOME['name']})")
    print(f"window {START}..{END}  ·  {len(ROWS)} geocoded tour dates\n")
    for b in BUDGETS:
        p = plan_from_rows(ROWS, HOME, b, START, END)
        o, base = p["optimal"], p["baseline_by_date"]
        cities = ", ".join(dict.fromkeys(e["city"] for e in o["events"]))
        print(f"  budget {b:>6} km | optimal {o['count']:>2} shows / {o['travel_km']:>6.0f} km"
              f"  vs by-date {base['count']:>2} / {base['travel_km']:>6.0f} km"
              f"  -> +{p['shows_gained']} shows  [{cities}]")
    test_optimal_matches_oracle()
    test_optimal_beats_baseline_at_binding_budget()
    test_city_centroid_fallback()
    test_two_budget()
    print("\n  asserts passed: optimal == brute-force oracle; optimal > baseline at 9000 km;")
    print("  city-centroid fallback recovers un-geocoded shows (Inglewood/Brooklyn)\n")


if __name__ == "__main__":
    main()
