"""scripts/train_knicks_price.py — the ridge fit recovers planted zone / horizon effects,
beats the naive zone baseline on held-out games, and skips cleanly on too little data."""
from __future__ import annotations

import math
import os
import sys

import pytest

np = pytest.importorskip("numpy")  # fitting is numpy-only; skip where numpy is not installed

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import train_knicks_price as tkp  # noqa: E402

ZONES = {"Lower Center": 600.0, "Lower Corner": 380.0, "Upper Center": 140.0, "Upper Corner": 90.0}
OPP = {"BOS": 1.35, "MIA": 1.0, "CHA": 0.75}


def _synthetic(games: int = 12, per_game: int = 120, seed: int = 3) -> list[dict]:
    rng = np.random.default_rng(seed)
    rows = []
    for g in range(games):
        opp = list(OPP)[g % 3]
        tip = f"2026-11-{g + 1:02d}T00:00:00+00:00"
        demand = OPP[opp] * float(rng.normal(1.0, 0.05))
        for _ in range(per_game):
            zone = list(ZONES)[int(rng.integers(0, 4))]
            hours = float(rng.uniform(1, 500))
            ask = ZONES[zone] * demand
            price = ask * (0.9 if hours < 24 else 1.0) * math.exp(float(rng.normal(0, 0.12)))
            rows.append({
                "sg_event_id": 1000 + g, "occurs_at": tip, "price": round(price, 2), "quantity": 2,
                "zone": zone, "level": zone.split()[0], "row_band": "mid", "opponent": opp,
                "horizon_bucket": tkp.horizon_bucket(hours), "game_dow": 1 + g % 7, "game_type": "regular",
                "hours_to_event": hours, "ctx_zone_median": round(ask * float(rng.normal(1.08, 0.05)), 2),
                "ctx_zone_getin": round(ask * 0.8, 2), "ctx_zone_p25": round(ask * 0.9, 2),
                "ctx_evo_median": None, "ctx_sg_median": None, "ctx_perf_home_median": 250.0,
                "ctx_zone_owned_share": 0.1,
            })
    return rows


def test_horizon_bucket_matches_sql_edges():
    assert tkp.horizon_bucket(-1) == "after_tip"
    assert tkp.horizon_bucket(5.9) == "h0_6"
    assert tkp.horizon_bucket(24) == "d1_3"
    assert tkp.horizon_bucket(800) == "d30p"
    assert tkp.horizon_bucket(None) == "__other__"


def test_fit_beats_zone_baseline_and_scores_upcoming():
    sales = _synthetic()
    upcoming = [{"sg_event_id": 9999, "tevo_event_id": 1, "zone": z, "occurs_at": "2026-12-25T17:00:00+00:00",
                 "hours_to_event": 200.0, "opponent": "BOS", "game_dow": 5, "game_type": "regular",
                 "ctx_zone_median": ZONES[z] * 1.35 * 1.08, "ctx_zone_getin": ZONES[z] * 1.35 * 0.8,
                 "ctx_zone_p25": ZONES[z] * 1.35 * 0.9, "ctx_perf_home_median": 250.0} for z in ZONES]
    res = tkp.train_and_predict(sales, upcoming)
    assert res["status"] == "ok"
    m = res["metrics"]
    assert m["mdape_model"] < m["mdape_baseline_zone_train_median"]
    assert m["mdape_model"] < 15
    preds = {p["zone"]: p for p in res["predictions"]}
    assert set(preds) == set(ZONES)
    # ordering of zones is recovered and the band brackets the point estimate
    assert preds["Lower Center"]["predicted_price"] > preds["Lower Corner"]["predicted_price"] \
        > preds["Upper Center"]["predicted_price"] > preds["Upper Corner"]["predicted_price"]
    for p in preds.values():
        assert p["p10"] < p["predicted_price"] < p["p90"]
    # a BOS game's Lower Center pair should price near its ask, not the cross-opponent average
    assert 0.75 * 600 * 1.35 < preds["Lower Center"]["predicted_price"] < 1.25 * 600 * 1.35


def test_skips_with_too_little_data():
    res = tkp.train_and_predict(_synthetic(games=2, per_game=20), [])
    assert res["status"] == "skipped"
    assert "need" in res["note"]


def test_unknown_levels_fold_into_other():
    spec = tkp.FeatureSpec.fit(_synthetic(games=4, per_game=50))
    v = spec.vector({"zone": "Nowhere", "opponent": "ZZZ", "quantity": 9, "hours_to_event": None})
    assert v.shape == (len(spec.names),)
    assert np.isfinite(v).all()
