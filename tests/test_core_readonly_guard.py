"""Tests for core/readonly_guard.py — the single-sourced RULE-2 guard factory.

The per-client guards (evo/seatgeek/tickpick/gotickets/vivid/ticketsdata/axs/
broadway) are exercised by tests/test_readonly_guards.py; this covers the factory
directly. BR-CODE-2.
"""
from __future__ import annotations

import pytest

from core.readonly_guard import build_readonly_guard


class _Boom(RuntimeError):
    pass


def test_get_passes_silently():
    guard = build_readonly_guard(_Boom, frozenset({"GET"}))
    assert guard("GET") is None
    assert guard("get") is None      # case-insensitive


def test_non_get_raises_with_canonical_message():
    guard = build_readonly_guard(_Boom, frozenset({"GET"}), "never write to example.com.")
    for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        with pytest.raises(_Boom) as exc:
            guard(method)
        msg = str(exc.value)
        assert "READ-ONLY violation" in msg
        assert "RULE 2" in msg
        assert method in msg
        assert "never write to example.com." in msg   # detail appended


def test_raises_chosen_error_class():
    class Other(Exception):
        pass
    guard = build_readonly_guard(Other, frozenset({"GET"}))
    with pytest.raises(Other):
        guard("POST")


def test_detail_optional_omitted_cleanly():
    guard = build_readonly_guard(_Boom, frozenset({"GET"}))
    with pytest.raises(_Boom) as exc:
        guard("POST")
    msg = str(exc.value)
    assert "READ-ONLY violation" in msg and "RULE 2" in msg
    # No trailing space / dangling detail when detail="".
    assert msg.endswith("(CLAUDE.md §2).")


def test_multi_method_allowlist_allows_each():
    guard = build_readonly_guard(_Boom, frozenset({"GET", "POST"}))
    assert guard("GET") is None
    assert guard("POST") is None
    with pytest.raises(_Boom):
        guard("DELETE")
