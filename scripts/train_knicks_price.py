#!/usr/bin/env python3
"""Train the Knicks home-game sale-price model and score upcoming games.

Runs daily as the Render cron job `ml-knicks-price-train` (render.yaml); also runnable
by hand. Reads and writes Supabase over PostgREST with the service-role key.

Input : v_ml_knicks_sales_train   one row per SeatGeek / SeatData sale of a Knicks home
                                  game (regular season + Cup only; mig 20261027010830)
        v_ml_knicks_predict_input upcoming home games × zones listed now, with the same
                                  context columns (mig 20261027050000)
Model : ridge regression on log(price), numpy only (no sklearn in this repo, same as
        fit_deal_scorer.py). Categorical: zone, level, row band, opponent, horizon bucket,
        game weekday, game type, quantity bucket (levels seen < MIN_LEVEL_COUNT times fold
        into "__other__"). Numeric: log of the zone / event / Knicks-home market at sale
        time, log hours-to-tip, zone owned share; missing values impute to the training
        mean with a missing flag. Numerics are z-scored.
Eval  : the most recent TEST_SHARE of games (by tip-off) are held out. Reported errors:
        median absolute % error of the model vs two baselines (the zone's median ask at
        sale time, and the zone's median training price). The final model is refit on all
        games; p10/p90 bands come from the held-out log residuals.
Output: one ml_model_runs row (status ok | skipped | failed) and, when ok, one
        ml_price_predictions row per upcoming game × zone: the expected sale price for a
        pair sold now. Nothing upstream is called.

Usage:
    SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... python3 scripts/train_knicks_price.py
    python3 scripts/train_knicks_price.py --dry-run          # fit + report, write nothing
    python3 scripts/train_knicks_price.py --from-file sales.json --dry-run
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict
from collections.abc import Iterable
from typing import Any

import numpy as np

MODEL = "knicks_price_ridge_v1"
TRAIN_VIEW = "v_ml_knicks_sales_train"
PREDICT_VIEW = "v_ml_knicks_predict_input"
PAGE = 1000
MIN_LEVEL_COUNT = 20
MIN_GAMES = 4
MIN_ROWS = 300
TEST_SHARE = 0.2
LAMBDA = 3.0
# zones that are a catch-all, not a seating area: never priced
UNPRICED_ZONES = frozenset({"unmapped"})

CATEGORICAL = ("zone", "level", "row_band", "opponent", "horizon_bucket", "game_dow", "game_type", "qty_bucket")
# feature name → (column, transform)
NUMERIC: dict[str, tuple[str, str]] = {
    "log_zone_median": ("ctx_zone_median", "log"),
    "log_zone_getin": ("ctx_zone_getin", "log"),
    "log_zone_p25": ("ctx_zone_p25", "log"),
    "log_evo_median": ("ctx_evo_median", "log"),
    "log_sg_median": ("ctx_sg_median", "log"),
    "log_perf_home_median": ("ctx_perf_home_median", "log"),
    "log_hours_to_event": ("hours_to_event", "log1p_pos"),
    "zone_owned_share": ("ctx_zone_owned_share", "raw"),
}
TRAIN_COLUMNS = sorted({"sg_event_id", "occurs_at", "price", "quantity", "level", "row_band", "zone",
                        "opponent", "horizon_bucket", "game_dow", "game_type"} | {c for c, _ in NUMERIC.values()})


# ---------------------------------------------------------------------------
# features
# ---------------------------------------------------------------------------
def horizon_bucket(hours: float | None) -> str:
    """Same buckets as v_ml_knicks_sales_train.horizon_bucket."""
    if hours is None:
        return "__other__"
    for limit, name in ((0, "after_tip"), (6, "h0_6"), (24, "h6_24"), (72, "d1_3"),
                        (168, "d3_7"), (336, "d7_14"), (720, "d14_30")):
        if hours < limit:
            return name
    return "d30p"


def qty_bucket(q: Any) -> str:
    try:
        q = int(q)
    except (TypeError, ValueError):
        return "__other__"
    return "4+" if q >= 4 else str(max(q, 1))


def _num(v: Any) -> float | None:
    if v is None or isinstance(v, bool):
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _transform(v: float | None, how: str) -> float | None:
    if v is None:
        return None
    if how == "log":
        return math.log(v) if v > 0 else None
    if how == "log1p_pos":
        return math.log1p(max(v, 0.0))
    return v


def _cat(row: dict, name: str) -> str:
    if name == "qty_bucket":
        return qty_bucket(row.get("quantity"))
    v = row.get(name)
    return "__other__" if v is None or v == "" else str(v)


class FeatureSpec:
    """Learned from training rows; turns any row into a design vector."""

    def __init__(self, levels: dict[str, list[str]], means: dict[str, float], sds: dict[str, float]):
        self.levels = levels
        self.means = means
        self.sds = sds
        self.names: list[str] = []
        for c in CATEGORICAL:
            self.names += [f"{c}={lv}" for lv in levels[c][1:]]          # first level = reference
        for n in NUMERIC:
            self.names += [n, f"{n}__missing"]

    @classmethod
    def fit(cls, rows: list[dict]) -> FeatureSpec:
        levels: dict[str, list[str]] = {}
        for c in CATEGORICAL:
            counts = Counter(_cat(r, c) for r in rows)
            keep = sorted((lv for lv, k in counts.items() if k >= MIN_LEVEL_COUNT and lv != "__other__"),
                          key=lambda lv: (-counts[lv], lv))
            levels[c] = ["__other__"] + keep
        means, sds = {}, {}
        for n, (col, how) in NUMERIC.items():
            vals = [x for x in (_transform(_num(r.get(col)), how) for r in rows) if x is not None]
            means[n] = float(np.mean(vals)) if vals else 0.0
            sd = float(np.std(vals)) if len(vals) > 1 else 1.0
            sds[n] = sd if sd > 1e-9 else 1.0
        return cls(levels, means, sds)

    def vector(self, row: dict) -> np.ndarray:
        out: list[float] = []
        for c in CATEGORICAL:
            lv = _cat(row, c)
            if lv not in self.levels[c]:
                lv = "__other__"
            out += [1.0 if lv == ref else 0.0 for ref in self.levels[c][1:]]
        for n, (col, how) in NUMERIC.items():
            x = _transform(_num(row.get(col)), how)
            out += [0.0, 1.0] if x is None else [(x - self.means[n]) / self.sds[n], 0.0]
        return np.asarray(out, dtype=float)

    def matrix(self, rows: Iterable[dict]) -> np.ndarray:
        return np.vstack([self.vector(r) for r in rows])

    def to_json(self) -> dict:
        return {"categorical": self.levels, "numeric": {n: {"column": c, "transform": t, "mean": self.means[n],
                                                             "sd": self.sds[n]} for n, (c, t) in NUMERIC.items()},
                "lambda": LAMBDA, "min_level_count": MIN_LEVEL_COUNT}


# ---------------------------------------------------------------------------
# model
# ---------------------------------------------------------------------------
def fit_ridge(X: np.ndarray, y: np.ndarray, lam: float = LAMBDA) -> np.ndarray:
    """Ridge with an unpenalised intercept; returns [intercept, coef...]."""
    Xi = np.hstack([np.ones((X.shape[0], 1)), X])
    P = lam * np.eye(Xi.shape[1])
    P[0, 0] = 0.0
    return np.linalg.solve(Xi.T @ Xi + P, Xi.T @ y)


def predict_log(X: np.ndarray, beta: np.ndarray) -> np.ndarray:
    return beta[0] + X @ beta[1:]


def clean_rows(rows: list[dict]) -> list[dict]:
    """Drop non-positive prices and log-price outliers beyond 5 MADs."""
    rows = [r for r in rows if (_num(r.get("price")) or 0) > 0]
    if not rows:
        return rows
    lp = np.log([float(r["price"]) for r in rows])
    med = float(np.median(lp))
    mad = float(np.median(np.abs(lp - med))) or 1e-9
    return [r for r, v in zip(rows, lp) if abs(v - med) <= 5 * 1.4826 * mad]


def split_by_game(rows: list[dict]) -> tuple[list[dict], list[dict], list, list]:
    first_tip: dict[Any, str] = {}
    for r in rows:
        g = r["sg_event_id"]
        first_tip[g] = min(first_tip.get(g, r.get("occurs_at") or ""), r.get("occurs_at") or "")
    games = sorted(first_tip, key=lambda g: (first_tip[g], g))
    n_test = max(1, round(len(games) * TEST_SHARE))
    test_games = set(games[-n_test:])
    train = [r for r in rows if r["sg_event_id"] not in test_games]
    test = [r for r in rows if r["sg_event_id"] in test_games]
    return train, test, games[:-n_test], games[-n_test:]


def mdape(actual: np.ndarray, pred: np.ndarray) -> float | None:
    ok = np.isfinite(pred) & (actual > 0)
    if not ok.any():
        return None
    return round(float(np.median(np.abs(pred[ok] - actual[ok]) / actual[ok])) * 100, 2)


def evaluate(train: list[dict], test: list[dict]) -> tuple[dict, np.ndarray]:
    spec = FeatureSpec.fit(train)
    beta = fit_ridge(spec.matrix(train), np.log([float(r["price"]) for r in train]))
    y_test = np.array([float(r["price"]) for r in test])
    p_test = np.exp(predict_log(spec.matrix(test), beta))
    resid = np.log(y_test) - np.log(p_test)

    zone_ask = np.array([_num(r.get("ctx_zone_median")) or np.nan for r in test])
    by_zone: dict[str, list[float]] = defaultdict(list)
    for r in train:
        by_zone[_cat(r, "zone")].append(float(r["price"]))
    zone_train_med = {z: float(np.median(v)) for z, v in by_zone.items()}
    zone_hist = np.array([zone_train_med.get(_cat(r, "zone"), np.nan) for r in test])

    covered = np.isfinite(zone_ask)
    metrics = {
        "mdape_model": mdape(y_test, p_test),
        "mdape_baseline_zone_ask_median": mdape(y_test, zone_ask),
        "mdape_baseline_zone_train_median": mdape(y_test, zone_hist),
        "mdape_model_where_zone_ask": mdape(y_test[covered], p_test[covered]) if covered.any() else None,
        "test_rows_with_zone_ask": int(covered.sum()),
        "log_resid_sd": round(float(np.std(resid)), 4),
        "within_band_p10_p90": None,
    }
    return metrics, resid


def train_and_predict(sales: list[dict], upcoming: list[dict]) -> dict:
    sales = clean_rows(sales)
    games = {r["sg_event_id"] for r in sales}
    if len(sales) < MIN_ROWS or len(games) < MIN_GAMES:
        return {"status": "skipped", "note": f"{len(sales)} usable sales over {len(games)} games "
                                             f"(need {MIN_ROWS} / {MIN_GAMES})", "n_train": len(sales)}

    train, test, g_train, g_test = split_by_game(sales)
    metrics, resid = evaluate(train, test)
    lo, hi = (float(np.quantile(resid, 0.1)), float(np.quantile(resid, 0.9))) if len(resid) >= 30 else (-0.35, 0.35)
    metrics["within_band_p10_p90"] = round(float(np.mean((resid >= lo) & (resid <= hi))), 3) if len(resid) else None
    metrics["band_log"] = [round(lo, 4), round(hi, 4)]

    # final model on every game
    spec = FeatureSpec.fit(sales)
    beta = fit_ridge(spec.matrix(sales), np.log([float(r["price"]) for r in sales]))

    # predictions: a pair sold now, at the zone's most common level / row band
    mode: dict[str, dict[str, str]] = {}
    for c in ("level", "row_band"):
        per_zone: dict[str, Counter] = defaultdict(Counter)
        for r in sales:
            per_zone[_cat(r, "zone")][_cat(r, c)] += 1
        mode[c] = {z: cnt.most_common(1)[0][0] for z, cnt in per_zone.items()}
    # only zones the model has learned (>= MIN_LEVEL_COUNT sales); a rarer zone folds into
    # "__other__" and its price would be a cross-zone guess (2026-10-28: Courtside at $650
    # against a $2,300 get-in, with 0 Courtside sales in training)
    zone_sales = Counter(r.get("zone") for r in sales)
    preds, unpriced = [], Counter()
    for u in upcoming:
        if not u.get("zone") or u["zone"] in UNPRICED_ZONES:
            continue
        if zone_sales[u["zone"]] < MIN_LEVEL_COUNT:
            unpriced[u["zone"]] += 1
            continue
        z = _cat(u, "zone")
        row = dict(u)
        row["quantity"] = 2
        row["horizon_bucket"] = horizon_bucket(_num(u.get("hours_to_event")))
        row["level"] = mode["level"].get(z)
        row["row_band"] = mode["row_band"].get(z)
        lp = float(predict_log(spec.vector(row)[None, :], beta)[0])
        preds.append({
            "sg_event_id": u["sg_event_id"], "tevo_event_id": u.get("tevo_event_id"), "zone": u["zone"],
            "occurs_at": u.get("occurs_at"), "hours_to_event": _num(u.get("hours_to_event")),
            "predicted_price": round(math.exp(lp), 2),
            "p10": round(math.exp(lp + lo), 2), "p90": round(math.exp(lp + hi), 2),
            "ctx_zone_getin": _num(u.get("ctx_zone_getin")), "ctx_zone_median": _num(u.get("ctx_zone_median")),
        })

    return {
        "status": "ok", "n_train": len(train), "n_test": len(test),
        "games_train": len(g_train), "games_test": len(g_test), "metrics": metrics,
        "feature_spec": spec.to_json(),
        "coef": {"(intercept)": round(float(beta[0]), 6),
                 **{n: round(float(b), 6) for n, b in zip(spec.names, beta[1:])}},
        "predictions": preds,
        "note": (f"not priced (fewer than {MIN_LEVEL_COUNT} training sales): "
                 + ", ".join(f"{z} ({zone_sales[z]})" for z in sorted(unpriced))) if unpriced else None,
    }


# ---------------------------------------------------------------------------
# PostgREST I/O (service role) — only our own tables / views
# ---------------------------------------------------------------------------
class Rest:
    def __init__(self, url: str, key: str):
        import requests  # imported lazily so the model can be tested without it
        self.base = url.rstrip("/") + "/rest/v1"
        self.s = requests.Session()
        self.s.headers.update({"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"})

    def read_all(self, view: str, columns: Iterable[str] | None = None, order: str | None = None) -> list[dict]:
        rows: list[dict] = []
        params = {"select": ",".join(columns) if columns else "*"}
        if order:
            params["order"] = order
        while True:
            r = self.s.get(f"{self.base}/{view}", params={**params, "limit": PAGE, "offset": len(rows)}, timeout=120)
            r.raise_for_status()
            page = r.json()
            rows += page
            if len(page) < PAGE:
                return rows

    def insert(self, table: str, rows: list[dict] | dict, returning: bool = False) -> list[dict]:
        headers = {"Prefer": "return=representation" if returning else "return=minimal"}
        r = self.s.post(f"{self.base}/{table}", data=json.dumps(rows, default=str), headers=headers, timeout=120)
        r.raise_for_status()
        return r.json() if returning else []


def write_run(api: Rest, result: dict) -> int:
    run = {k: result.get(k) for k in ("n_train", "n_test", "games_train", "games_test",
                                      "metrics", "feature_spec", "coef", "note")}
    run.update({"model": MODEL, "status": result["status"]})
    run_id = api.insert("ml_model_runs", run, returning=True)[0]["run_id"]
    preds = [{**p, "run_id": run_id} for p in result.get("predictions") or []]
    for i in range(0, len(preds), 500):
        api.insert("ml_price_predictions", preds[i:i + 500])
    return run_id


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="fit and report; write nothing")
    ap.add_argument("--from-file", help="JSON file {sales: [...], upcoming: [...]} instead of the database")
    args = ap.parse_args(argv)

    api = None
    if args.from_file:
        with open(args.from_file) as fh:
            data = json.load(fh)
        sales, upcoming = data.get("sales", []), data.get("upcoming", [])
    else:
        url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        if not url or not key:
            print("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required", file=sys.stderr)
            return 2
        api = Rest(url, key)
        sales = api.read_all(TRAIN_VIEW, TRAIN_COLUMNS, order="sale_key.asc,source.asc")
        upcoming = api.read_all(PREDICT_VIEW)

    try:
        result = train_and_predict(sales, upcoming)
    except Exception as exc:  # recorded, then re-raised so the Render run shows as failed
        result = {"status": "failed", "note": f"{type(exc).__name__}: {exc}"[:500]}
        if api and not args.dry_run:
            write_run(api, result)
        raise

    summary = {k: result.get(k) for k in ("status", "note", "n_train", "n_test", "games_train", "games_test", "metrics")}
    summary["predictions"] = len(result.get("predictions") or [])
    if api and not args.dry_run:
        summary["run_id"] = write_run(api, result)
    print(json.dumps(summary, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
