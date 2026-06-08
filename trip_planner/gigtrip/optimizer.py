"""Itinerary optimizer: greedy baselines + an exact Pareto label-setting solver.

Vendored verbatim from axiom-orion/gigtrip (MIT). The exact optimiser is verified against
the brute-force oracle (`brute_force_optimal`) on random instances in the source project.
"""
from __future__ import annotations

import itertools

from .distance import haversine_km
from .model import Constraints, Event, Itinerary, prize

EPS = 1e-9


# --------------------------------------------------------------------------- #
# geometry / feasibility helpers
# --------------------------------------------------------------------------- #
def candidates(events: list[Event], c: Constraints) -> list[Event]:
    """In-window events, in calendar order (the forced visit order)."""
    return sorted((e for e in events if c.start <= e.day <= c.end),
                  key=lambda e: (e.day, e.id))


def feasible_leg(a: Event, b: Event, c: Constraints) -> bool:
    """Can you get from event a to a later event b in time? You have (date_b - date_a) days
    and can cover c.max_km_per_day each; same-day hops only if essentially co-located."""
    gap = (b.day - a.day).days
    if gap < 0:
        return False
    dist = haversine_km(a.lat, a.lon, b.lat, b.lon)
    if gap == 0:
        return dist <= 50.0
    return dist <= gap * c.max_km_per_day + EPS


def route_km(seq: list[Event] | tuple[Event, ...], c: Constraints) -> float:
    """Round-trip kilometres: home -> seq[0] -> ... -> seq[-1] -> home."""
    if not seq:
        return 0.0
    km = haversine_km(c.home_lat, c.home_lon, seq[0].lat, seq[0].lon)
    for a, b in zip(seq, seq[1:], strict=False):
        km += haversine_km(a.lat, a.lon, b.lat, b.lon)
    km += haversine_km(seq[-1].lat, seq[-1].lon, c.home_lat, c.home_lon)
    return km


def evaluate(seq: list[Event] | tuple[Event, ...], prefs: dict[str, float],
             c: Constraints) -> Itinerary:
    value = sum(prize(e, prefs, c.default_pref) for e in seq)
    return Itinerary(tuple(seq), value, route_km(seq, c))


def _legs_feasible(seq: tuple[Event, ...] | list[Event], c: Constraints) -> bool:
    return all(feasible_leg(a, b, c) for a, b in zip(seq, seq[1:], strict=False))


# --------------------------------------------------------------------------- #
# baselines (greedy)
# --------------------------------------------------------------------------- #
def _date_insert(seq: list[Event], e: Event) -> list[Event]:
    out = list(seq)
    i = 0
    while i < len(out) and (out[i].day, out[i].id) < (e.day, e.id):
        i += 1
    out.insert(i, e)
    return out


def _valid_km(seq: list[Event], c: Constraints) -> float | None:
    if c.max_events is not None and len(seq) > c.max_events:
        return None
    if not _legs_feasible(seq, c):
        return None
    km = route_km(seq, c)
    return km if km <= c.max_travel_km + EPS else None


def _greedy(events: list[Event], prefs: dict[str, float], c: Constraints, key) -> Itinerary:
    seq: list[Event] = []
    for e in sorted(candidates(events, c), key=key):
        trial = _date_insert(seq, e)
        if _valid_km(trial, c) is not None:
            seq = trial
    return evaluate(seq, prefs, c)


def plan_by_date(events, prefs, c):
    """Baseline: take events soonest-first while the trip stays feasible + in budget."""
    return _greedy(events, prefs, c, key=lambda e: (e.day, e.id))


def plan_by_prize(events, prefs, c):
    """Baseline: take your most-wanted artists first (date order preserved)."""
    return _greedy(events, prefs, c, key=lambda e: (-prize(e, prefs, c.default_pref), e.day, e.id))


def plan_by_ratio(events, prefs, c):
    """Baseline: distance-aware greedy — repeatedly add the event with the best marginal
    value-per-kilometre that keeps the trip feasible + in budget."""
    seq: list[Event] = []
    remaining = list(candidates(events, c))
    cur_km = 0.0
    while True:
        best = None  # (key, event, trial, km)
        for e in remaining:
            p = prize(e, prefs, c.default_pref)
            if p <= 0:
                continue
            trial = _date_insert(seq, e)
            km = _valid_km(trial, c)
            if km is None:
                continue
            dkm = max(km - cur_km, EPS)
            key = (p / dkm, p)
            if best is None or key > best[0]:
                best = (key, e, trial, km)
        if best is None:
            break
        _, e, trial, km = best
        seq, cur_km = trial, km
        remaining.remove(e)
    return evaluate(seq, prefs, c)


# --------------------------------------------------------------------------- #
# exact optimiser — Pareto label-setting on the date-DAG
# --------------------------------------------------------------------------- #
def _pareto(labels: list[tuple[float, int, float, tuple[int, ...]]]):
    """Keep labels not dominated on (open_km ↓, count ↓, value ↑)."""
    labels = sorted(labels, key=lambda lab: (lab[0], lab[1], -lab[2]))
    kept: list[tuple[float, int, float, tuple[int, ...]]] = []
    for lab in labels:
        okm, cnt, val, _ = lab
        if not any(k[0] <= okm + EPS and k[1] <= cnt and k[2] >= val - 1e-12 for k in kept):
            kept.append(lab)
    return kept


def plan_optimal(events: list[Event], prefs: dict[str, float], c: Constraints) -> Itinerary:
    """Exact maximum-value itinerary within the travel budget (and optional event cap)."""
    cand = candidates(events, c)
    n = len(cand)
    p = [prize(e, prefs, c.default_pref) for e in cand]
    home_km = [haversine_km(c.home_lat, c.home_lon, e.lat, e.lon) for e in cand]
    labels: list[list[tuple[float, int, float, tuple[int, ...]]]] = [[] for _ in range(n)]
    best = Itinerary((), 0.0, 0.0)  # the empty trip is always feasible

    def consider(open_km: float, value: float, path: tuple[int, ...]) -> None:
        nonlocal best
        last = cand[path[-1]]
        total = open_km + haversine_km(last.lat, last.lon, c.home_lat, c.home_lon)
        if total > c.max_travel_km + EPS:
            return
        if value > best.value + 1e-12 or (
                abs(value - best.value) <= 1e-12 and total < best.travel_km - 1e-12):
            best = Itinerary(tuple(cand[i] for i in path), value, total)

    for i in range(n):
        new: list[tuple[float, int, float, tuple[int, ...]]] = []
        if home_km[i] <= c.max_travel_km + EPS and (c.max_events is None or c.max_events >= 1):
            new.append((home_km[i], 1, p[i], (i,)))
        for j in range(i):
            if not feasible_leg(cand[j], cand[i], c):
                continue
            leg = haversine_km(cand[j].lat, cand[j].lon, cand[i].lat, cand[i].lon)
            for okm, cnt, val, path in labels[j]:
                if c.max_events is not None and cnt + 1 > c.max_events:
                    continue
                nokm = okm + leg
                if nokm > c.max_travel_km + EPS:   # adding the return leg can only grow km
                    continue
                new.append((nokm, cnt + 1, val + p[i], path + (i,)))
        labels[i] = _pareto(new)
        for okm, _, val, path in labels[i]:
            consider(okm, val, path)
    return best


def brute_force_optimal(events: list[Event], prefs: dict[str, float],
                        c: Constraints) -> Itinerary:
    """Ground-truth optimum by enumerating every feasible subset. Tests only (exponential)."""
    cand = candidates(events, c)
    best = Itinerary((), 0.0, 0.0)
    max_r = len(cand) if c.max_events is None else min(c.max_events, len(cand))
    for r in range(1, max_r + 1):
        for combo in itertools.combinations(cand, r):  # cand is date-sorted -> combo is too
            if not _legs_feasible(combo, c):
                continue
            it = evaluate(list(combo), prefs, c)
            if it.travel_km > c.max_travel_km + EPS:
                continue
            if it.value > best.value + 1e-12 or (
                    abs(it.value - best.value) <= 1e-12 and it.travel_km < best.travel_km - 1e-12):
                best = it
    return best


# rungs the eval ablates, in order
PLANNERS = {
    "by-date": plan_by_date,
    "by-prize": plan_by_prize,
    "distance-aware": plan_by_ratio,
    "optimal": plan_optimal,
}
