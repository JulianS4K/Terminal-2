"""scripts/fit_deal_scorer.py — the numpy IRLS fit recovers a planted signal and
emits SQL that deal_score() can consume (one row per informative feature + intercept)."""
from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest

np = pytest.importorskip("numpy")  # fitting is numpy-only; skip where numpy is not installed

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import fit_deal_scorer as fds  # noqa: E402


def _synthetic(n: int = 400, seed: int = 7) -> list[dict]:
    rng = np.random.default_rng(seed)
    rows = []
    for _ in range(n):
        moneyness = float(rng.uniform(0.5, 1.6))
        sigma = float(rng.uniform(0.0, 0.2))
        regime = str(rng.choice(["DUMPING", "STABLE", "RISING"]))
        z = -2.5 * (moneyness - 1.0) - 6.0 * sigma + (-1.2 if regime == "DUMPING" else 0.3 if regime == "RISING" else 0.0)
        p = 1 / (1 + np.exp(-z))
        rows.append({
            "y_win": int(rng.random() < p),
            "y_flip": None,
            "as_of_flag": bool(rng.random() < 0.7),
            "features": {"moneyness": moneyness, "sigma_14d": sigma, "regime": regime,
                         "is_weekend": bool(rng.random() < 0.3), "sales_7d": int(rng.integers(0, 30))},
        })
    return rows


def test_fit_recovers_signs_and_ranks():
    rows = _synthetic()
    X, y, w, names = fds.build_matrix(rows, "y_win", 0.5, use_regime=True)
    Z, mean, sd, keep = fds.standardise(X)
    beta = fds.fit_logistic(Z, y, w, l2=0.5)
    p = fds.predict(Z, beta)
    assert fds.auc(y, p) > 0.7
    coef = dict(zip(names, beta[1:]))
    assert coef["moneyness"] < 0          # cheaper vs anchor → more wins
    assert coef["sigma_14d"] < 0          # volatility hurts
    assert coef["regime_DUMPING"] < coef["regime_RISING"]
    # constant / absent columns carry no information and are dropped from the SQL
    assert not keep[names.index("home_win_pct")]


def test_emit_sql_shape(tmp_path):
    rows = _synthetic(150)
    path = tmp_path / "train.json"
    path.write_text(json.dumps({"rows": rows}))
    out = subprocess.run(
        [sys.executable, os.path.join(os.path.dirname(__file__), "..", "scripts", "fit_deal_scorer.py"),
         str(path), "--version", "test_v", "--min-rows", "50"],
        capture_output=True, text=True, check=True,
    )
    sql = out.stdout
    assert "INSERT INTO public.deal_model_coef" in sql
    assert "('test_v', '__intercept__'" in sql
    assert "('test_v', 'moneyness'" in sql
    assert "ON CONFLICT (model_version, feature) DO UPDATE" in sql
    assert "auc=" in out.stderr


def test_refuses_tiny_training_set(tmp_path):
    path = tmp_path / "tiny.json"
    path.write_text(json.dumps({"rows": _synthetic(10)}))
    rc = fds.main([str(path), "--version", "x"])
    assert rc == 2


@pytest.mark.parametrize("v,expected", [(None, "NULL"), (float("nan"), "NULL"), (1.23456789012, "1.23456789")])
def test_sql_literal(v, expected):
    assert fds.sql_literal(v) == expected
