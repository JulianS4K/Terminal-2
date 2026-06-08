"""Offline end-to-end test of the planner on a real active touring performer.

Fixture = a snapshot of `public.v_event_base` for Ariana Grande (tevo_performer_id 27474),
17 geocoded upcoming dates 2026-06-14 .. 2026-08-07. Exercises the pure `plan_from_rows`
path (no DB) and asserts the exact optimizer matches the brute-force oracle.

Run from repo root:  python3 -m trip_planner.test_ariana
"""
from __future__ import annotations

from datetime import date

from .gigtrip.model import Constraints
from .gigtrip.optimizer import brute_force_optimal, plan_optimal
from .planner import plan_from_rows, row_to_event

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
    print("\n  asserts passed: optimal == brute-force oracle; optimal > baseline at 9000 km\n")


if __name__ == "__main__":
    main()
