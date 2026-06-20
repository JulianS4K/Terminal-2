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


def test_team_side_away_groups_by_visiting_team():
    # Two home venues near Chicago. The HOME teams differ (pid 100 in Chicago,
    # pid 101 in Milwaukee), but the SAME visiting team (away id 900) plays both —
    # a road trip through the user's area. team_side='away' should surface ONE tour
    # keyed on the visiting team (900), not two home-team tours.
    events = [
        _ev(10, 100, "Chicago Home", "Chicago", "2026-07-10", 41.88, -87.67, "game"),
        _ev(11, 101, "Milwaukee Home", "Milwaukee", "2026-07-12", 43.04, -87.91, "game"),
    ]
    away_map = {10: (900, "Road Warriors"), 11: (900, "Road Warriors")}
    tours = rank_tours_near(events, HLAT, HLON, within_mi=150, min_shows=2,
                            team_side="away", away_map=away_map)
    assert len(tours) == 1
    t = tours[0]
    assert t["performer_id"] == 900 and t["performer"] == "Road Warriors"
    assert t["kind"] == "sports" and t["team_side"] == "away"
    assert t["nearby_shows"] == 2 and t["cities"] == 2

    # Legacy default (team_side='home') still groups by the home team -> two tours
    # of one game each, so neither clears min_shows=2.
    home = rank_tours_near(events, HLAT, HLON, within_mi=150, min_shows=2)
    assert home == []


def test_team_side_away_skips_unresolved_visitor():
    # A sports event whose away team can't be resolved is dropped (can't show as away).
    events = [
        _ev(20, 100, "Home A", "Chicago", "2026-07-10", 41.88, -87.67, "game"),
        _ev(21, 101, "Home B", "Chicago", "2026-07-12", 41.88, -87.67, "game"),
    ]
    tours = rank_tours_near(events, HLAT, HLON, within_mi=150, min_shows=2,
                            team_side="away", away_map={20: (900, "Visitor")})  # 21 unmapped
    assert tours == []  # only one resolvable away game -> below min_shows


def main():
    for t in rank_tours_near(EVENTS, HLAT, HLON, 150, 2):
        print(f"  {t['performer']:11} {t['nearby_shows']} shows / {t['cities']} cities, "
              f"nearest {t['nearest_mi']} mi, soonest {t['soonest']}")
    test_rank_near()
    print("  asserts passed: Rush surfaces; 1-show + out-of-radius excluded")


if __name__ == "__main__":
    main()
