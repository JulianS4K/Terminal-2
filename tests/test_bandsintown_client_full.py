"""Full line-coverage tests for bandsintown_client. No real HTTP — every
requests.get is monkeypatched at the boundary. Mirrors the house style in
tests/test_small_clients_full.py (fake responses) and
tests/test_readonly_guards.py (read-only guard assertions).
"""
from __future__ import annotations

import pytest

import bandsintown_client as bit


# ====================================================================
# Shared fake HTTP response + get patcher
# ====================================================================

class _FakeResp:
    def __init__(self, status, *, json_payload=None, json_raises=False,
                 text="raw-body", headers=None):
        self.status_code = status
        self.ok = 200 <= status < 300
        self._json_payload = json_payload
        self._json_raises = json_raises
        self.text = text
        self.headers = headers or {}

    def json(self):
        if self._json_raises:
            raise ValueError("no json")
        return self._json_payload


def _patch_get(monkeypatch, responses, captured=None):
    if isinstance(responses, _FakeResp):
        seq, single = None, responses
    else:
        seq, single = iter(responses), None

    def fake_get(url, **kwargs):
        if captured is not None:
            captured.append((url, kwargs))
        return single if single is not None else next(seq)

    monkeypatch.setattr(bit.requests, "get", fake_get)


# ====================================================================
# app_id resolution
# ====================================================================

def test_app_id_from_argument(monkeypatch):
    monkeypatch.delenv("BANDSINTOWN_APP_ID", raising=False)
    c = bit.BandsInTownClient("  myapp  ")
    assert c.app_id == "myapp"  # stripped


def test_app_id_from_env(monkeypatch):
    monkeypatch.setenv("BANDSINTOWN_APP_ID", "env-app")
    c = bit.BandsInTownClient()
    assert c.app_id == "env-app"


def test_app_id_from_vault(monkeypatch):
    monkeypatch.delenv("BANDSINTOWN_APP_ID", raising=False)

    class _DB:
        def rpc(self, name, args):
            assert name == "get_app_secret"
            assert args == {"p_name": "BANDSINTOWN_APP_ID"}
            return self

        def execute(self):
            class _R:
                data = "vault-app"
            return _R()

    c = bit.BandsInTownClient(db=_DB())
    assert c.app_id == "vault-app"


def test_missing_app_id_raises(monkeypatch):
    monkeypatch.delenv("BANDSINTOWN_APP_ID", raising=False)
    with pytest.raises(bit.BandsInTownError) as exc:
        bit.BandsInTownClient()
    assert "BANDSINTOWN_APP_ID not found" in str(exc.value)


# ====================================================================
# read-only guard
# ====================================================================

def test_readonly_guard():
    bit._assert_readonly_method("GET")
    for m in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(bit.BandsInTownReadOnlyError):
            bit._assert_readonly_method(m)


# ====================================================================
# _encode_artist
# ====================================================================

def test_encode_artist_percent_encodes_slash_and_spaces():
    assert bit.BandsInTownClient._encode_artist("AC/DC") == "AC%2FDC"
    assert bit.BandsInTownClient._encode_artist("  Tyler, the Creator ") == \
        "Tyler%2C%20the%20Creator"


def test_encode_artist_id_form_passes_through():
    assert bit.BandsInTownClient._encode_artist("id_3TVXtAsR1Inumwj472S9r4") == \
        "id_3TVXtAsR1Inumwj472S9r4"


def test_encode_artist_empty_raises():
    for bad in ("", "   ", None):
        with pytest.raises(bit.BandsInTownError):
            bit.BandsInTownClient._encode_artist(bad)


# ====================================================================
# get_artist
# ====================================================================

def test_get_artist_happy_and_app_id_param(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"name": "Metallica"}),
               captured)
    c = bit.BandsInTownClient("app1")
    artist = c.get_artist("Metallica")
    assert artist == {"name": "Metallica"}
    url, kwargs = captured[0]
    assert url.endswith("/artists/Metallica")
    assert kwargs["params"]["app_id"] == "app1"
    assert kwargs["headers"]["Accept"] == "application/json"


def test_get_artist_non_dict_returns_empty(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=[1, 2]))
    c = bit.BandsInTownClient("app1")
    assert c.get_artist("Unknown") == {}


def test_get_artist_json_fallback_to_raw_text(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_raises=True, text="plain"))
    c = bit.BandsInTownClient("app1")
    assert c.get_artist("x") == {"raw_text": "plain"}


def test_get_artist_non_200_raises(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(404))
    c = bit.BandsInTownClient("app1")
    with pytest.raises(bit.BandsInTownError) as exc:
        c.get_artist("x")
    assert "HTTP 404" in str(exc.value)


# ====================================================================
# get_artist_events / get_tour_dates
# ====================================================================

def test_get_artist_events_happy_and_date_param(monkeypatch):
    captured = []
    _patch_get(monkeypatch,
               _FakeResp(200, json_payload=[{"id": "1"}, {"id": "2"}]),
               captured)
    c = bit.BandsInTownClient("app1")
    events = c.get_artist_events("AC/DC", date="upcoming", extra="z")
    assert events == [{"id": "1"}, {"id": "2"}]
    url, kwargs = captured[0]
    assert url.endswith("/artists/AC%2FDC/events")
    params = kwargs["params"]
    assert params["app_id"] == "app1"
    assert params["date"] == "upcoming"
    assert params["extra"] == "z"


def test_get_artist_events_date_none_omitted(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=[]), captured)
    c = bit.BandsInTownClient("app1")
    c.get_artist_events("Metallica")
    assert "date" not in captured[0][1]["params"]  # None dropped by _get


def test_get_artist_events_non_list_returns_empty(monkeypatch):
    # Unknown artist -> Bands in Town returns an error object, not a list.
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"errorMessage": "no"}))
    c = bit.BandsInTownClient("app1")
    assert c.get_artist_events("Nobody") == []


def test_get_tour_dates_uses_date_all(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=[{"id": "1"}]), captured)
    c = bit.BandsInTownClient("app1")
    assert c.get_tour_dates("Metallica") == [{"id": "1"}]
    assert captured[0][1]["params"]["date"] == "all"


# ====================================================================
# transport: retry + network errors
# ====================================================================

def test_retry_on_429_then_ok(monkeypatch):
    monkeypatch.setattr(bit.time, "sleep", lambda *_: None)
    _patch_get(monkeypatch, [
        _FakeResp(429, headers={"Retry-After": "1"}),
        _FakeResp(200, json_payload={"name": "X"}),
    ])
    c = bit.BandsInTownClient("app1")
    assert c.get_artist("X") == {"name": "X"}


def test_retry_exhausted_raises(monkeypatch):
    monkeypatch.setattr(bit.time, "sleep", lambda *_: None)
    _patch_get(monkeypatch, _FakeResp(503))
    c = bit.BandsInTownClient("app1")
    with pytest.raises(bit.BandsInTownError):
        c.get_artist("X")


def test_connection_error_wrapped(monkeypatch):
    def boom(*a, **k):
        raise bit.requests.ConnectionError("down")
    monkeypatch.setattr(bit.requests, "get", boom)
    c = bit.BandsInTownClient("app1")
    with pytest.raises(bit.BandsInTownError) as exc:
        c.get_artist("X")
    assert "network error" in str(exc.value)
    assert "ConnectionError" in str(exc.value)


def test_timeout_error_wrapped(monkeypatch):
    def boom(*a, **k):
        raise bit.requests.Timeout("slow")
    monkeypatch.setattr(bit.requests, "get", boom)
    c = bit.BandsInTownClient("app1")
    with pytest.raises(bit.BandsInTownError) as exc:
        c.get_artist("X")
    assert "Timeout" in str(exc.value)
