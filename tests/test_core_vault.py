"""Tests for core/vault.vault_secret — the shared Vault secret resolver.

Per-client resolution (env→vault, dict-unwrap, failure messages) is also covered
through each client's tests; this exercises the resolver directly across all
result shapes + the on_error/None paths. BR-CODE-2.
"""
from __future__ import annotations

from core.vault import vault_secret


class _Res:
    def __init__(self, data):
        self.data = data


class _DB:
    def __init__(self, data=None, raises=False):
        self._data = data
        self._raises = raises

    def rpc(self, fn, args):
        assert fn == "get_app_secret"
        self._args = args
        return self

    def execute(self):
        if self._raises:
            raise RuntimeError("boom")
        return _Res(self._data)


def test_none_db_returns_none():
    assert vault_secret(None, "X") is None


def test_scalar_string_value():
    assert vault_secret(_DB("sekret"), "X") == "sekret"


def test_dict_get_app_secret_key():
    assert vault_secret(_DB({"get_app_secret": "v1"}), "X") == "v1"


def test_dict_value_key():
    assert vault_secret(_DB({"value": "v2"}), "X") == "v2"


def test_dict_get_app_secret_takes_precedence_over_value():
    assert vault_secret(_DB({"get_app_secret": "primary", "value": "fallback"}), "X") == "primary"


def test_dict_without_known_keys_returns_none():
    assert vault_secret(_DB({"nope": "x"}), "X") is None


def test_empty_string_is_none():
    assert vault_secret(_DB(""), "X") is None


def test_exception_invokes_on_error_and_returns_none():
    seen = []
    out = vault_secret(_DB(raises=True), "MYKEY", on_error=seen.append)
    assert out is None
    assert len(seen) == 1 and isinstance(seen[0], RuntimeError)


def test_exception_without_on_error_swallowed():
    assert vault_secret(_DB(raises=True), "X") is None


def test_passes_secret_name_to_rpc():
    db = _DB("v")
    vault_secret(db, "THE_NAME")
    assert db._args == {"p_name": "THE_NAME"}
