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
    # catch-all and missing zones are never priced
    upcoming += [{**upcoming[0], "zone": "unmapped"}, {**upcoming[0], "zone": None},
                 {**upcoming[0], "zone": "Courtside"}]
    res = tkp.train_and_predict(sales, upcoming)
    assert res["note"] == f"not priced (fewer than {tkp.MIN_LEVEL_COUNT} training sales): Courtside (0)"
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


def test_anchor_takes_first_positive_market_column():
    assert tkp._anchor({"ctx_sg_median": 200, "ctx_evo_median": 300}) == pytest.approx(math.log(200))
    assert tkp._anchor({"ctx_sg_median": 0, "ctx_evo_median": None, "ctx_perf_home_median": 250}) \
        == pytest.approx(math.log(250))
    assert math.isnan(tkp._anchor({}))


def test_blend_carries_game_price_level_and_falls_back_without_anchor():
    rows = _synthetic(games=6, per_game=80)
    for r in rows:   # the game's SeatGeek median ask tracks its demand level
        r["ctx_sg_median"] = 400.0 * OPP[r["opponent"]]
    model = tkp.fit_model(rows)
    assert model[2] is not None
    hot = dict(rows[0], ctx_sg_median=400.0 * 2.0)          # an ask level never seen in training
    plain = float(tkp.predict_log(model[0].matrix([hot]), model[1])[0])
    blended = float(tkp.predict_model(model, [hot])[0])
    assert blended > plain                                   # the anchor lifts the price
    no_anchor = {k: v for k, v in hot.items() if not k.startswith("ctx_")}
    assert float(tkp.predict_model(model, [no_anchor])[0]) == pytest.approx(
        float(tkp.predict_log(model[0].matrix([no_anchor]), model[1])[0]))
    # nothing to anchor on anywhere: the plain ridge alone
    bare = [{k: v for k, v in r.items() if k not in tkp.ANCHOR_COLS} for r in rows]
    spec, plain_beta, anchored = tkp.fit_model(bare)
    assert anchored is None
    assert np.allclose(tkp.predict_model((spec, plain_beta, None), bare[:5]),
                       tkp.predict_log(spec.matrix(bare[:5]), plain_beta))


def test_rolling_backtest_windows_and_metrics():
    rows = _synthetic(games=14, per_game=40)
    windows = tkp.rolling_backtest(rows)
    assert [w["train_games"] for w in windows] == [8, 11]
    assert windows[0]["test_sales"] == 120 and windows[1]["test_sales"] == 120
    assert all(w["mdape_model"] < 20 and w["mdape_plain_ridge"] < 20 for w in windows)
    # a window with fewer than 20 test sales is skipped
    assert tkp.rolling_backtest(_synthetic(games=10, per_game=8)) == []
    res = tkp.train_and_predict(rows, [])
    m = res["metrics"]
    assert m["rolling"] == windows and m["rolling_mean_mdape"] == pytest.approx(
        np.mean([w["mdape_model"] for w in windows]), abs=0.01)
    assert "mdape_plain_ridge" in m and "median_bias_pct" in m
    assert res["feature_spec"]["anchor"] == list(tkp.ANCHOR_COLS) and "anchored" in res["coef"]
    assert tkp.train_and_predict(_synthetic(games=6, per_game=60), [])["metrics"]["rolling_mean_mdape"] is None


def test_recency_weights_halve_per_half_life_and_default_missing():
    rows = [{"sale_at": "2026-10-28T00:00:00Z"}, {"sale_at": "2026-09-28T00:00:00+00:00"},
            {"sale_at": None}, {"sale_at": "2026-10-28T00:00:00"}]
    w = tkp.recency_weights(rows)
    assert w[1] / w[0] == pytest.approx(0.5 ** (30 / tkp.RECENCY_HALF_LIFE_DAYS))
    assert w[2] == 1.0 and w[3] == pytest.approx(w[0])
    assert np.mean(w[[0, 1, 3]]) == pytest.approx(1.0)
    assert np.all(tkp.recency_weights([{"sale_at": "garbage"}, {}]) == 1.0)
    assert math.isnan(tkp._sale_ts({"sale_at": "not a time"}))


def test_weighted_ridge_follows_heavier_rows():
    X = np.zeros((4, 1))
    y = np.log(np.array([100.0, 100.0, 200.0, 200.0]))
    even = tkp.fit_ridge(X, y)
    heavy_new = tkp.fit_ridge(X, y, w=np.array([0.1, 0.1, 1.0, 1.0]))
    assert math.exp(even[0]) == pytest.approx(math.sqrt(100 * 200))
    assert math.exp(heavy_new[0]) > 180


def _dated(rows: list[dict], start_day: int = 1) -> list[dict]:
    """Spread synthetic sales over ~60 days, newest last."""
    for i, r in enumerate(rows):
        r["sale_at"] = f"2026-{8 + (start_day + i * 60 // len(rows)) // 31:02d}-" \
                       f"{1 + (start_day + i * 60 // len(rows)) % 31:02d}T12:00:00Z"
    return rows


def test_forward_backtest_scores_the_next_two_weeks():
    rows = _dated(_synthetic(games=10, per_game=120))
    windows = tkp.forward_backtest(rows)
    assert len(windows) == tkp.FORWARD_WINDOWS
    assert [w["days"] for w in windows] == [14, 14, 14]
    assert windows[0]["from"] < windows[1]["from"] < windows[2]["from"]
    assert all(w["test_sales"] >= 20 and w["train_sales"] >= tkp.MIN_ROWS for w in windows)
    assert all(w["mdape_model"] < 20 and abs(w["median_bias_pct"]) < 10 for w in windows)
    assert tkp.forward_backtest(_synthetic(games=4, per_game=20)) == []          # no sale times
    assert tkp.forward_backtest(_dated(_synthetic(games=4, per_game=20))) == []  # too few sales
    res = tkp.train_and_predict(rows, [])
    assert res["metrics"]["forward"] == windows
    assert res["feature_spec"]["recency_half_life_days"] == tkp.RECENCY_HALF_LIFE_DAYS
