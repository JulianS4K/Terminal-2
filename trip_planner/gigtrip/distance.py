"""Great-circle (haversine) distance between venues, in kilometres.

This is a straight-line distance, **not** road or flight routing — stated plainly because
the optimizer's travel budget is only as honest as its cost model. It is monotonic in true
travel cost, which is what the selection needs; swap in a real routing/airfare API to make
the kilometre budget a dollar budget without touching the optimizer.

Vendored verbatim from axiom-orion/gigtrip (MIT).
"""
from __future__ import annotations

import math

EARTH_RADIUS_KM = 6371.0088


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(min(1.0, math.sqrt(a)))
