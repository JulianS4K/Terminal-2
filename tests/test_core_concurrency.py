"""Tests for core/concurrency.run_parallel — the fan-out helper used by the
broker analytics handlers to run independent DB reads concurrently.

Covers every branch: empty input, single-thunk inline path, the multi-thunk
pool path (results returned in input order), and exception propagation.
"""
from __future__ import annotations

import threading

import pytest

from core.concurrency import run_parallel


def test_empty_returns_empty_without_running():
    assert run_parallel([]) == []


def test_single_thunk_runs_inline():
    # The len==1 branch returns [thunk()] without spinning up a pool.
    assert run_parallel([lambda: 42]) == [42]


def test_multiple_thunks_preserve_input_order():
    # Even though execution is concurrent, results come back in input order.
    results = run_parallel([lambda: "a", lambda: "b", lambda: "c"])
    assert results == ["a", "b", "c"]


def test_thunks_actually_run_concurrently():
    # Two thunks that each wait on a barrier only complete if they run on
    # separate threads at the same time — proves the pool path is parallel.
    barrier = threading.Barrier(2, timeout=5)
    out = run_parallel([lambda: barrier.wait(), lambda: barrier.wait()])
    # Barrier.wait() returns a distinct index per waiter (0 and 1).
    assert sorted(out) == [0, 1]


def test_exception_in_thunk_propagates():
    def boom():
        raise ValueError("kaboom")

    with pytest.raises(ValueError, match="kaboom"):
        run_parallel([lambda: 1, boom])
