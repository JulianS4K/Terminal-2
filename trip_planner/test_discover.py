"""Offline test of reverse-discovery ranking (pure, no DB)."""
from __future__ import annotations

from .planner import rank_tours_near

HLAT, HLON = 41.881, -87.632   # Chicago


def _ev(eid, pid, name, city, d, lat, lon, etype="concert"):
    return {"tevo_event_id": eid, "tevo_performer_id": pid, "primary_performer_name": name,
            "venue_city": city, "event_date": d, "venue_lat": lat, "venue_lon": lon,
            "event_type": etype}


EVENTS = [
    _ev(1, 100, "Rush", "Chicago", "2026-07-17", 41.88, -87.67),     # ~2 mi
    _ev(2, 100, "Rush", "Chicago", "2026-07-19", 41.88, -87.67),
    _ev(3, 200, "Local Solo", "Chicago", "2026-08-01", 41.88, -87.67),  # only 1 show
    _ev(4, 400, "Far Band", "Dallas", "2026-07-22", 32.78, -96.80),  # ~800 mi (out of radius)
]


def test_rank_near():
    tours = rank_tours_near(EVENTS, HLAT, HLON, within_mi=150, min_shows=2)
    perfs = {t["performer_id"] for t in tours}
    assert 100 in perfs              # Rush: 2 Chicago shows in radius -> a tour
    assert 200 not in perfs          # only 1 show -> not a tour
    assert 400 not in perfs          # Dallas out of radius
    rush = next(t for t in tours if t["performer_id"] == 100)
    assert rush["nearby_shows"] == 2 and rush["nearest_mi"] <= 5 and len(rush["events"]) == 2


def main():
    for t in rank_tours_near(EVENTS, HLAT, HLON, 150, 2):
        print(f"  {t['performer']:11} {t['nearby_shows']} shows / {t['cities']} cities, "
              f"nearest {t['nearest_mi']} mi, soonest {t['soonest']}")
    test_rank_near()
    print("  asserts passed: Rush surfaces; 1-show + out-of-radius excluded")


if __name__ == "__main__":
    main()
