#!/usr/bin/env python3
"""Fit the GoTickets deal WINNER model and emit deal_model_coef rows.

Input : the JSON that `get_deal_training_set()` returns (mig 20260911160900) —
        or the same shape saved to a file: {"rows": [{"y_win": 0/1, "y_flip": 0/1|null,
        "as_of_flag": bool, "features": {...}}, ...]}.
Model : standardised logistic regression with a small L2 ridge, fitted by IRLS
        (numpy only — no sklearn dependency in this repo). Numeric features are
        z-scored on the training set; the same mean/sd are stored per coefficient
        so `deal_score(features, version)` (mig 20260911160800) reproduces the
        prediction in SQL. Missing feature values impute to the mean (= 0 after
        standardisation), which is exactly what deal_score() does.
Output: SQL — INSERT ... ON CONFLICT rows for public.deal_model_coef under the
        given --version, plus a fit report (n, AUC, calibration by decile) on
        stderr. Nothing is written to any database by this script: apply the
        emitted SQL through the normal operator-gated path.

Usage:
    python3 scripts/fit_deal_scorer.py training.json --version fit_2026_09 > coef.sql
    python3 scripts/fit_deal_scorer.py training.json --label y_flip --backfill-weight 0

Label choice: y_win (market label, default) or y_flip (our own realized flip,
only where we bought the seat). Backfilled rows (as_of_flag=false) carry
--backfill-weight (default 0.5); 0 excludes them.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from typing import Iterable

import numpy as np

# Numeric features the SQL scorer understands (deal_score reads them by name from
# the features jsonb). Booleans are coerced to 0/1; anything absent is imputed.
NUMERIC_FEATURES: tuple[str, ...] = (
    "moneyness", "cost_vs_amalgam", "vs_zone_pct", "mod_z", "vs_section_pct", "zone_n",
    "sigma_14d", "range_pct_14d", "ma7_over_ma14", "degr_excess_pct", "degr_factor", "theta_7d", "dte",
    "gt_listings_n", "sales_7d", "our_inventory_n",
    "home_win_pct", "home_games_back", "home_playoff_seed", "home_streak", "home_injuries_n", "home_att_pct",
    "opp_win_pct", "pm_fut_yes", "pm_fut_volume", "odds_home_win_prob",
    "reddit_posts_7d", "reddit_score_24h", "espn_news_7d", "espn_txn_7d",
    "venue_ratio", "perf_trend_px_30d", "perf_trend_sold_30d", "perf_ask_over_sold", "sentiment_index",
    "weather_alert", "is_weekend", "is_accessible", "pred_win_prob", "pred_net_profit_pct", "anchored",
    "quantity", "cost",
)
# One-hot regime (the strongest single signal in the 2026-09-11 grading). Stored
# as synthetic features the SQL side can't read directly, so they are expanded
# into the features jsonb by snapshot? No — deal_score() only reads keys that
# exist. We therefore emit them as `regime_<X>` coefficients AND the SQL scorer
# treats a missing key as the mean → contributes 0. To make regime effective in
# SQL, snapshot_deal_signals stores `regime` as text only; the fit script maps
# it here and documents that the SQL scorer must gain regime_* keys before a
# fitted version that relies on them is activated (see --emit-regime-note).
REGIMES: tuple[str, ...] = ("DUMPING", "SOFTENING", "STABLE", "RISING")


def _num(v) -> float:
    if v is None:
        return math.nan
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    try:
        return float(v)
    except (TypeError, ValueError):
        return math.nan


def build_matrix(rows: Iterable[dict], label: str, backfill_weight: float,
                 use_regime: bool) -> tuple[np.ndarray, np.ndarray, np.ndarray, list[str]]:
    names = list(NUMERIC_FEATURES) + ([f"regime_{r}" for r in REGIMES] if use_regime else [])
    X, y, w = [], [], []
    for r in rows:
        yv = r.get(label)
        if yv is None:
            continue
        f = r.get("features") or {}
        vec = [_num(f.get(k)) for k in NUMERIC_FEATURES]
        if use_regime:
            reg = (f.get("regime") or "").upper()
            vec += [1.0 if reg == k else 0.0 for k in REGIMES]
        X.append(vec)
        y.append(float(yv))
        w.append(1.0 if r.get("as_of_flag") else backfill_weight)
    if not X:
        raise SystemExit("no labelled rows")
    return np.array(X, dtype=float), np.array(y, dtype=float), np.array(w, dtype=float), names


def standardise(X: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Column z-score with NaN → mean. Returns Z, mean, sd, keep-mask (sd>0)."""
    mean = np.nanmean(X, axis=0)
    mean = np.where(np.isnan(mean), 0.0, mean)
    Xf = np.where(np.isnan(X), mean, X)
    sd = Xf.std(axis=0)
    keep = sd > 1e-12
    Z = np.zeros_like(Xf)
    Z[:, keep] = (Xf[:, keep] - mean[keep]) / sd[keep]
    return Z, mean, sd, keep


def fit_logistic(Z: np.ndarray, y: np.ndarray, w: np.ndarray, l2: float = 1.0,
                 iters: int = 50) -> np.ndarray:
    """Weighted L2 logistic regression by IRLS. Returns [intercept, coefs...]."""
    n, p = Z.shape
    A = np.hstack([np.ones((n, 1)), Z])
    beta = np.zeros(p + 1)
    ridge = np.eye(p + 1) * l2
    ridge[0, 0] = 0.0  # no penalty on the intercept
    for _ in range(iters):
        eta = np.clip(A @ beta, -30, 30)
        mu = 1 / (1 + np.exp(-eta))
        s = w * mu * (1 - mu) + 1e-9
        grad = A.T @ (w * (y - mu)) - ridge @ beta
        H = A.T @ (A * s[:, None]) + ridge
        step = np.linalg.solve(H, grad)
        beta = beta + step
        if np.max(np.abs(step)) < 1e-8:
            break
    return beta


def predict(Z: np.ndarray, beta: np.ndarray) -> np.ndarray:
    return 1 / (1 + np.exp(-np.clip(beta[0] + Z @ beta[1:], -30, 30)))


def auc(y: np.ndarray, p: np.ndarray) -> float:
    """Rank AUC (Mann–Whitney), ties averaged."""
    order = np.argsort(p)
    ranks = np.empty(len(p), dtype=float)
    ranks[order] = np.arange(1, len(p) + 1)
    # average ranks for ties
    for v in np.unique(p):
        idx = np.where(p == v)[0]
        if len(idx) > 1:
            ranks[idx] = ranks[idx].mean()
    pos = y == 1
    n1, n0 = pos.sum(), (~pos).sum()
    if n1 == 0 or n0 == 0:
        return float("nan")
    return float((ranks[pos].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))


def calibration(y: np.ndarray, p: np.ndarray, bins: int = 5) -> list[tuple[float, float, int]]:
    edges = np.quantile(p, np.linspace(0, 1, bins + 1))
    out = []
    for i in range(bins):
        lo, hi = edges[i], edges[i + 1]
        m = (p >= lo) & ((p <= hi) if i == bins - 1 else (p < hi))
        if m.sum():
            out.append((float(p[m].mean()), float(y[m].mean()), int(m.sum())))
    return out


def sql_literal(v: float | None) -> str:
    if v is None or (isinstance(v, float) and (math.isnan(v) or math.isinf(v))):
        return "NULL"
    return repr(round(float(v), 8))


def emit_sql(version: str, names: list[str], beta: np.ndarray, mean: np.ndarray, sd: np.ndarray,
             keep: np.ndarray, n_train: int, note: str) -> str:
    lines = [
        f"-- deal_model_coef · version {version} · n_train={n_train} · emitted by scripts/fit_deal_scorer.py",
        "INSERT INTO public.deal_model_coef (model_version, feature, coef, mean, sd, n_train, notes) VALUES",
    ]
    vals = [f"  ('{version}', '__intercept__', {sql_literal(beta[0])}, NULL, NULL, {n_train}, '{note}')"]
    for j, name in enumerate(names):
        if not keep[j]:
            continue  # constant column: no information, skip
        vals.append(f"  ('{version}', '{name}', {sql_literal(beta[j + 1])}, {sql_literal(mean[j])}, {sql_literal(sd[j])}, {n_train}, NULL)")
    lines.append(",\n".join(vals))
    lines.append("ON CONFLICT (model_version, feature) DO UPDATE SET coef = excluded.coef, mean = excluded.mean, sd = excluded.sd, n_train = excluded.n_train, notes = excluded.notes, fitted_at = now();")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("training_json", help="file with {'rows': [...]} as returned by get_deal_training_set()")
    ap.add_argument("--version", required=True, help="model_version to emit, e.g. fit_2026_09")
    ap.add_argument("--label", default="y_win", choices=["y_win", "y_flip"])
    ap.add_argument("--backfill-weight", type=float, default=0.5)
    ap.add_argument("--l2", type=float, default=1.0)
    ap.add_argument("--no-regime", action="store_true", help="drop the regime one-hots")
    ap.add_argument("--min-rows", type=int, default=60)
    args = ap.parse_args(argv)

    with open(args.training_json) as fh:
        payload = json.load(fh)
    rows = payload["rows"] if isinstance(payload, dict) else payload
    X, y, w, names = build_matrix(rows, args.label, args.backfill_weight, not args.no_regime)
    if len(y) < args.min_rows:
        print(f"refusing to fit: {len(y)} labelled rows < --min-rows {args.min_rows}", file=sys.stderr)
        return 2
    Z, mean, sd, keep = standardise(X)
    beta = fit_logistic(Z, y, w, l2=args.l2)
    p = predict(Z, beta)

    print(f"n={len(y)} pos_rate={y.mean():.3f} auc={auc(y, p):.3f} (in-sample)", file=sys.stderr)
    for pm, ym, n in calibration(y, p):
        print(f"  pred {pm:.3f}  actual {ym:.3f}  n={n}", file=sys.stderr)
    top = sorted(((abs(beta[j + 1]), names[j], beta[j + 1]) for j in range(len(names)) if keep[j]), reverse=True)[:12]
    for _, nm, b in top:
        print(f"  {nm:>22s} {b:+.3f}", file=sys.stderr)
    if not args.no_regime:
        print("note: regime_* coefficients need regime_<X> keys in the features jsonb; "
              "snapshot_deal_signals stores `regime` as text — add the one-hots before activating "
              "this version, or refit with --no-regime.", file=sys.stderr)

    sys.stdout.write(emit_sql(args.version, names, beta, mean, sd, keep, int(len(y)),
                              f"label={args.label} l2={args.l2} backfill_w={args.backfill_weight}"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
