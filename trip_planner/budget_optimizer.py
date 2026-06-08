"""Two-budget itinerary optimizer — extends the (vendored) gigtrip selection model with a
second resource constraint: a ticket-spend budget, alongside the travel-km budget.

The base gigtrip optimizer constrains only round-trip km. Brokers also care about ticket
outlay, so here a trip must satisfy BOTH `max_travel_km` AND `max_spend_usd`. Per-event cost
is supplied externally (get-in price x tickets-to-buy, with owned tickets free) via a
`costs` map keyed on event id.

The vendored engine is left untouched; this reuses its geometry helpers (candidates,
feasible_leg, route_km, haversine) and reimplements the Pareto label-setting DP with the
extra cost dimension. Exact, same dominance idea as upstream, plus a sort-by-date baseline
that honours both budgets.
"""
from __future__ import annotations

from .gigtrip.distance import haversine_km
from .gigtrip.model import Constraints, Event, Itinerary, prize
from .gigtrip.optimizer import candidates, feasible_leg, route_km

EPS = 1e-9


def trip_cost(seq, costs: dict[int, float]) -> float:
    return round(sum(costs.get(int(e.id), 0.0) for e in seq), 2)


# --------------------------------------------------------------------------- #
# exact — Pareto label-setting on (open_km, spend, count) ↓ vs value ↑
# --------------------------------------------------------------------------- #
def _pareto2(labels):
    labels = sorted(labels, key=lambda l: (l[0], l[1], l[2], -l[3]))
    kept = []
    for lab in labels:
        okm, oc, cnt, val, _ = lab
        if not any(k[0] <= okm + EPS and k[1] <= oc + EPS and k[2] <= cnt
                   and k[3] >= val - 1e-12 for k in kept):
            kept.append(lab)
    return kept


def plan_optimal_2b(events, prefs, c: Constraints, costs: dict[int, float],
                    max_spend_usd: float):
    """Exact max-value itinerary within BOTH the km budget and the spend budget.

    Returns (Itinerary, total_spend).
    """
    cand = candidates(events, c)
    n = len(cand)
    p = [prize(e, prefs, c.default_pref) for e in cand]
    cst = [costs.get(int(e.id), 0.0) for e in cand]
    home_km = [haversine_km(c.home_lat, c.home_lon, e.lat, e.lon) for e in cand]
    labels = [[] for _ in range(n)]
    best = Itinerary((), 0.0, 0.0)
    best_spend = 0.0

    def consider(open_km, spend, value, path):
        nonlocal best, best_spend
        last = cand[path[-1]]
        total_km = open_km + haversine_km(last.lat, last.lon, c.home_lat, c.home_lon)
        if total_km > c.max_travel_km + EPS or spend > max_spend_usd + EPS:
            return
        if value > best.value + 1e-12 or (
                abs(value - best.value) <= 1e-12 and total_km < best.travel_km - 1e-12):
            best = Itinerary(tuple(cand[i] for i in path), value, total_km)
            best_spend = round(spend, 2)

    for i in range(n):
        new = []
        if (home_km[i] <= c.max_travel_km + EPS and cst[i] <= max_spend_usd + EPS
                and (c.max_events is None or c.max_events >= 1)):
            new.append((home_km[i], cst[i], 1, p[i], (i,)))
        for j in range(i):
            if not feasible_leg(cand[j], cand[i], c):
                continue
            leg = haversine_km(cand[j].lat, cand[j].lon, cand[i].lat, cand[i].lon)
            for okm, oc, cnt, val, path in labels[j]:
                if c.max_events is not None and cnt + 1 > c.max_events:
                    continue
                nokm = okm + leg
                noc = oc + cst[i]
                if nokm > c.max_travel_km + EPS or noc > max_spend_usd + EPS:
                    continue
                new.append((nokm, noc, cnt + 1, val + p[i], path + (i,)))
        labels[i] = _pareto2(new)
        for okm, oc, _, val, path in labels[i]:
            consider(okm, oc, val, path)
    return best, best_spend


def plan_by_date_2b(events, prefs, c: Constraints, costs: dict[int, float],
                    max_spend_usd: float):
    """Baseline: take shows soonest-first while the trip stays inside BOTH budgets."""
    seq: list[Event] = []
    spend = 0.0
    for e in candidates(events, c):          # already (day, id) sorted -> seq stays in order
        trial = seq + [e]
        if c.max_events is not None and len(trial) > c.max_events:
            continue
        if not all(feasible_leg(a, b, c) for a, b in zip(trial, trial[1:])):
            continue
        if route_km(trial, c) > c.max_travel_km + EPS:
            continue
        ncost = spend + costs.get(int(e.id), 0.0)
        if ncost > max_spend_usd + EPS:
            continue
        seq, spend = trial, ncost
    value = sum(prize(e, prefs, c.default_pref) for e in seq)
    return Itinerary(tuple(seq), value, route_km(seq, c)), round(spend, 2)
