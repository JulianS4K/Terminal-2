"""Core datatypes for the gigtrip itinerary optimizer.

An itinerary is an ordered set of live events (concerts / games / comedy) you attend on a
trip out of a home base. Because every event has a *fixed date*, the visit order is forced
by the calendar — so planning is a **selection** problem under travel constraints, not a
travelling-salesman ordering problem. See `optimizer.py`.

Vendored verbatim from axiom-orion/gigtrip (MIT).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class Event:
    """A dated live event at a geocoded venue."""
    id: str
    title: str            # band / team / comedian
    kind: str             # "music" | "sports" | "comedy"
    day: date
    city: str
    venue: str
    lat: float
    lon: float


@dataclass(frozen=True)
class Constraints:
    """A trip request: where you start, the window, and the travel budget."""
    home_name: str
    home_lat: float
    home_lon: float
    start: date
    end: date
    max_travel_km: float                 # round-trip km budget (home -> events -> home)
    max_events: int | None = None        # optional cap on number of events
    max_km_per_day: float = 1200.0       # how far you can travel between consecutive events per day
    default_pref: float = 0.0            # prize for an artist/team not in your preferences


@dataclass(frozen=True)
class Itinerary:
    """A planned trip: events in date order, with its total value and round-trip distance."""
    events: tuple[Event, ...]
    value: float
    travel_km: float

    @property
    def count(self) -> int:
        return len(self.events)

    def ids(self) -> tuple[str, ...]:
        return tuple(e.id for e in self.events)


def prize(event: Event, prefs: dict[str, float], default: float = 0.0) -> float:
    """Preference-weighted value of attending an event (keyed on lowercased title)."""
    return prefs.get(event.title.lower(), default)
