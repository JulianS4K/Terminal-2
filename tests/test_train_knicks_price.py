"""scripts/train_knicks_price.py — the ridge fit recovers planted zone / horizon effects,
beats the naive zone baseline on held-out games, and skips cleanly on too little data."""
from __future__ import annotations

import json
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


def test_form_features_switch_and_attach(monkeypatch):
    for v, on in (("1", True), ("on", True), ("TRUE", True), ("", False), ("0", False)):
        monkeypatch.setenv("ML_FORM_FEATURES", v)
        assert tkp.form_features_enabled() is on
    monkeypatch.delenv("ML_FORM_FEATURES")
    assert tkp.form_features_enabled() is False
    rows = [{"source": "seatgeek", "sale_key": "a", "price": 100}, {"source": "seatgeek", "sale_key": "b", "price": 90}]
    form = [{"source": "seatgeek", "sale_key": "a", "knicks_win_pct": 0.6, "knicks_games": 10, "knicks_streak": -2,
             "knicks_out": 1, "opp_win_pct": 0.4, "opp_games": 10, "opp_streak": 3, "opp_out": 0, "extra": "x"}]
    out = tkp.attach_form(rows, form, ("source", "sale_key"))
    assert out[0]["knicks_win_pct"] == 0.6 and out[0]["opp_streak"] == 3 and "extra" not in out[0]
    assert out[1] == rows[1]                                  # no form row: left as it was
    numeric = dict(tkp.NUMERIC)
    monkeypatch.setattr(tkp, "NUMERIC", numeric)
    tkp.enable_form_features()
    tkp.enable_form_features()
    assert set(tkp.FORM_NUMERIC) <= set(numeric) and len(numeric) == len(tkp.FORM_NUMERIC) + 8


def test_form_features_feed_the_model(monkeypatch):
    rows = _synthetic(games=8, per_game=60)
    for r in rows:   # a winning streak lifts prices 20%
        r["knicks_streak"] = 4 if r["sg_event_id"] % 2 else -4
        r["price"] = r["price"] * (1.2 if r["sg_event_id"] % 2 else 1.0)
    monkeypatch.setattr(tkp, "NUMERIC", dict(tkp.NUMERIC))
    tkp.enable_form_features()
    spec = tkp.FeatureSpec.fit(rows)
    assert "knicks_streak" in spec.names and "opp_win_pct" in spec.names
    hot, cold = dict(rows[0], knicks_streak=4), dict(rows[0], knicks_streak=-4)
    model = tkp.fit_model(rows)
    assert float(tkp.predict_model(model, [hot])[0]) > float(tkp.predict_model(model, [cold])[0]) + 0.1


def test_game_zone_mdape_scores_group_medians():
    test = [{"sg_event_id": 1, "zone": "A", "price": p} for p in (100, 100, 100, 100, 100)] \
        + [{"sg_event_id": 1, "zone": "B", "price": p} for p in (50, 60)]          # too few: ignored
    pred = np.array([110.0] * 5 + [1.0, 1.0])
    assert tkp.game_zone_mdape(test, pred) == (10.0, 1)
    assert tkp.game_zone_mdape(test[5:], pred[5:]) == (None, 0)
    res = tkp.train_and_predict(_synthetic(games=10, per_game=60), [])
    assert res["metrics"]["game_zone_groups"] >= 4 and res["metrics"]["mdape_game_zone"] < 15


class _FakeRest:
    """Stands in for the PostgREST client: serves the views, records writes."""
    instances: list = []

    def __init__(self, url, key):
        self.reads, self.inserts = [], []
        rows = _synthetic(games=8, per_game=60)
        for i, r in enumerate(rows):
            r["source"], r["sale_key"] = "seatgeek", str(i)
        self.views = {
            tkp.TRAIN_VIEW: rows,
            tkp.PREDICT_VIEW: [{"sg_event_id": 9999, "zone": "Lower Center", "occurs_at": "2026-12-25T17:00:00+00:00",
                                "hours_to_event": 200.0, "opponent": "BOS", "game_dow": 5, "game_type": "regular",
                                "ctx_zone_median": 800.0, "ctx_perf_home_median": 250.0}],
            tkp.FORM_TRAIN_VIEW: [{"source": "seatgeek", "sale_key": r["sale_key"], "knicks_win_pct": 0.5,
                                   "knicks_streak": 1} for r in rows],
            tkp.FORM_PREDICT_VIEW: [{"sg_event_id": 9999, "knicks_win_pct": 0.5, "knicks_streak": 2}],
        }
        _FakeRest.instances.append(self)

    def read_all(self, view, columns=None, order=None):
        self.reads.append(view)
        return [dict(r) for r in self.views[view]]

    def insert(self, table, rows, returning=False):
        self.inserts.append((table, rows))
        return [{"run_id": 7}] if returning else []

    def save_run(self, run, preds):
        self.inserts.append(("ml_model_runs", run))
        if preds:
            self.inserts.append(("ml_price_predictions", preds))
        return 7


def test_main_reads_form_views_only_when_switched_on(monkeypatch, capsys):
    monkeypatch.setenv("SUPABASE_URL", "https://x.invalid")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "k")
    monkeypatch.setattr(tkp, "Rest", _FakeRest)
    monkeypatch.setattr(tkp, "NUMERIC", dict(tkp.NUMERIC))
    monkeypatch.delenv("ML_FORM_FEATURES", raising=False)
    assert tkp.main([]) == 0
    off = _FakeRest.instances[-1]
    assert tkp.FORM_TRAIN_VIEW not in off.reads and "knicks_streak" not in tkp.NUMERIC
    run = off.inserts[0][1]
    assert run["status"] == "ok" and "form features on" not in (run.get("note") or "")
    monkeypatch.setenv("ML_FORM_FEATURES", "1")
    assert tkp.main(["--dry-run"]) == 0
    on = _FakeRest.instances[-1]
    assert on.reads == [tkp.TRAIN_VIEW, tkp.PREDICT_VIEW, tkp.FORM_TRAIN_VIEW, tkp.FORM_PREDICT_VIEW]
    assert on.inserts == [] and "knicks_streak" in tkp.NUMERIC
    printed = capsys.readouterr().out
    assert "form features on" in printed and '"predictions": 1' in printed


class _FakeCursor:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, params=None):
        self.conn.executed.append((sql, params))
        self.sql = sql

    def fetchall(self):
        return [(dict(r),) for r in self.conn.rows]

    def fetchone(self):
        return (42,)


class _FakeConn:
    def __init__(self, rows):
        self.rows, self.executed, self.commits = rows, [], 0

    def cursor(self):
        return _FakeCursor(self)

    def commit(self):
        self.commits += 1


def test_pg_reads_through_ml_io_and_saves_in_one_call():
    conn = _FakeConn([{"source": "seatgeek", "sale_key": "1", "price": 250.0, "extra": "x"}])
    seen = {}

    def connect(dsn, **kw):
        seen.update(dsn=dsn, **kw)
        return conn

    pg = tkp.Pg("postgresql://ml_trainer.x:pw@pooler:5432/postgres", connect=connect)
    assert seen["prepare_threshold"] is None
    rows = pg.read_all(tkp.TRAIN_VIEW, ["source", "sale_key", "price"])
    assert conn.executed[-1][0] == "SELECT * FROM ml_io.sales_train()"
    assert rows == [{"source": "seatgeek", "sale_key": "1", "price": 250.0}]
    assert pg.read_all(tkp.FORM_PREDICT_VIEW)[0]["extra"] == "x"
    assert conn.executed[-1][0] == "SELECT * FROM ml_io.form_predict()"
    run_id = pg.save_run({"model": tkp.MODEL, "status": "ok"}, [{"sg_event_id": 1, "zone": "z"}])
    sql, (run_json, preds_json) = conn.executed[-1]
    assert run_id == 42 and sql.startswith("SELECT ml_io.save_run(")
    assert json.loads(run_json)["status"] == "ok" and json.loads(preds_json) == [{"sg_event_id": 1, "zone": "z"}]
    assert conn.commits == 3


def test_main_prefers_the_ml_trainer_login(monkeypatch):
    made = []

    class _FakePg(_FakeRest):
        def __init__(self, dsn):
            made.append(dsn)
            super().__init__(None, None)

    monkeypatch.setattr(tkp, "Pg", _FakePg)
    monkeypatch.setattr(tkp, "Rest", _FakeRest)
    monkeypatch.setattr(tkp, "NUMERIC", dict(tkp.NUMERIC))
    monkeypatch.delenv("ML_FORM_FEATURES", raising=False)
    monkeypatch.setenv("SUPABASE_URL", "https://x.invalid")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "k")
    monkeypatch.setenv("ML_TRAINER_DATABASE_URL", "postgresql://ml_trainer.x@h/postgres")
    assert tkp.main(["--dry-run"]) == 0
    assert made == ["postgresql://ml_trainer.x@h/postgres"]
    for var in ("ML_TRAINER_DATABASE_URL", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"):
        monkeypatch.delenv(var)
    assert tkp.main([]) == 2
