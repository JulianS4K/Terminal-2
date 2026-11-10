"""Tests for oxylabs_client. No real HTTP: a fake session stands in for requests.Session."""
from __future__ import annotations

from datetime import date

import pytest
import requests

import oxylabs_client as ox

BASE = "https://residential-api.oxylabs.io/v2"
UID = "00000000-0000-0000-0000-000000000001"


class _Resp:
    def __init__(self, status, payload=None, *, json_raises=False, text="", headers=None):
        self.status_code = status
        self.ok = 200 <= status < 300
        self._payload = payload
        self._json_raises = json_raises
        self.text = text
        self.headers = headers or {}

    def json(self):
        if self._json_raises:
            raise ValueError("no json")
        return self._payload


class _Session:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def request(self, method, url, **kw):
        self.calls.append((method, url, kw))
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def _login_ok():
    return _Resp(200, {"user_id": UID, "token": "jwt-1"})


@pytest.fixture(autouse=True)
def _no_env(monkeypatch):
    monkeypatch.delenv("OXYLABS_RESIDENTIAL_USERNAME", raising=False)
    monkeypatch.delenv("OXYLABS_RESIDENTIAL_PASSWORD", raising=False)
    monkeypatch.setattr(ox.time, "sleep", lambda s: None)


def _client(responses, clock=None):
    s = _Session(responses)
    kw = {"clock": clock} if clock else {}
    return ox.OxylabsResidentialClient(" user ", " pw ", session=s, **kw), s


# ---------- credentials ----------

def test_creds_from_args_are_stripped():
    c, _ = _client([])
    assert (c.username, c.password) == ("user", "pw")


def test_creds_from_env(monkeypatch):
    monkeypatch.setenv("OXYLABS_RESIDENTIAL_USERNAME", "eu")
    monkeypatch.setenv("OXYLABS_RESIDENTIAL_PASSWORD", "ep")
    c = ox.OxylabsResidentialClient(session=_Session([]))
    assert (c.username, c.password) == ("eu", "ep")


def test_creds_from_vault_names_as_stored():
    asked = []

    class _Rpc:
        def __init__(self, name):
            self.name = name

        def execute(self):
            return type("R", (), {"data": {"OXY-Test-Username": "vu", "Oxy-Test-PW": "vp"}[self.name]})()

    class _Db:
        def rpc(self, fn, args):
            asked.append((fn, args["p_name"]))
            return _Rpc(args["p_name"])

    c = ox.OxylabsResidentialClient(db=_Db(), session=_Session([]))
    assert (c.username, c.password) == ("vu", "vp")
    assert asked == [("get_app_secret", "OXY-Test-Username"), ("get_app_secret", "Oxy-Test-PW")]


def test_vault_error_is_swallowed_then_missing_creds_raise(capsys):
    class _Db:
        def rpc(self, fn, args):
            raise RuntimeError("boom")

    with pytest.raises(ox.OxylabsError, match="credentials not found"):
        ox.OxylabsResidentialClient(db=_Db(), session=_Session([]))
    assert "vault lookup failed: RuntimeError" in capsys.readouterr().out


def test_blank_creds_raise():
    with pytest.raises(ox.OxylabsError, match="credentials not found"):
        ox.OxylabsResidentialClient("  ", "pw", session=_Session([]))


def test_default_session_is_requests_session():
    c = ox.OxylabsResidentialClient("u", "p")
    assert isinstance(c.session, requests.Session)


# ---------- login ----------

def test_login_posts_basic_auth_and_caches_token():
    c, s = _client([_login_ok()])
    assert c.login() == UID
    method, url, kw = s.calls[0]
    assert (method, url) == ("POST", f"{BASE}/login")
    assert kw["auth"] == ("user", "pw")
    assert "json" not in kw and "data" not in kw


@pytest.mark.parametrize("resp, match", [
    (_Resp(401, {"error": "Invalid credentials"}), "HTTP 401: Invalid credentials"),
    (_Resp(500, json_raises=True, text=" upstream down "), "HTTP 500: upstream down"),
    (_Resp(400, ["odd"], text="bad"), "HTTP 400: bad"),
    (_Resp(200, json_raises=True), "login response was not JSON"),
    (_Resp(200, {"token": "t"}), "missing token/user_id"),
    (_Resp(200, ["not", "a", "dict"]), "missing token/user_id"),
])
def test_login_failures(resp, match):
    c, _ = _client([resp])
    with pytest.raises(ox.OxylabsError, match=match):
        c.login()


def test_login_is_never_retried():
    c, s = _client([_Resp(503, {"error": "busy"})])
    with pytest.raises(ox.OxylabsError, match="HTTP 503"):
        c.login()
    assert len(s.calls) == 1


def test_errors_never_contain_credentials():
    c, _ = _client([_Resp(401, {"error": "nope"})])
    with pytest.raises(ox.OxylabsError) as exc:
        c.login()
    assert "pw" not in str(exc.value) and "user" not in str(exc.value)


def test_network_error_wrapped():
    c, _ = _client([requests.ConnectionError("down")])
    with pytest.raises(ox.OxylabsError, match="network error: ConnectionError"):
        c.login()


# ---------- token lifecycle ----------

def test_token_reused_then_refreshed_near_expiry():
    now = [1000.0]
    c, s = _client([_login_ok(), _Resp(200, {"traffic": 1.5}), _Resp(200, {"traffic": 2.0}),
                    _Resp(200, {"user_id": UID, "token": "jwt-2"}), _Resp(200, {"traffic": 3.0})],
                   clock=lambda: now[0])
    assert c.get_client_stats() == {"traffic": 1.5}
    now[0] += 60
    assert c.get_client_stats() == {"traffic": 2.0}
    now[0] += ox.TOKEN_TTL_SECONDS - ox.TOKEN_REFRESH_MARGIN
    assert c.get_client_stats() == {"traffic": 3.0}
    assert [m for m, _, _ in s.calls] == ["POST", "GET", "GET", "POST", "GET"]
    assert s.calls[4][2]["headers"]["Authorization"] == "Bearer jwt-2"


def test_401_on_read_relogs_once_then_succeeds():
    c, s = _client([_login_ok(), _Resp(401, {"error": "expired"}),
                    _Resp(200, {"user_id": UID, "token": "jwt-2"}), _Resp(200, [])])
    assert c.list_sub_users() == []
    assert [m for m, _, _ in s.calls] == ["POST", "GET", "POST", "GET"]


def test_second_401_raises():
    c, _ = _client([_login_ok(), _Resp(401, {"error": "x"}), _login_ok(), _Resp(401, {"error": "still"})])
    with pytest.raises(ox.OxylabsError, match="HTTP 401: still"):
        c.list_sub_users()


def test_read_retries_429():
    c, s = _client([_login_ok(), _Resp(429, {"error": "slow"}, headers={"Retry-After": "1"}),
                    _Resp(200, {"traffic": 1})])
    assert c.get_client_stats() == {"traffic": 1}
    assert len(s.calls) == 3


# ---------- reads ----------

def test_client_stats_path_and_bearer():
    c, s = _client([_login_ok(), _Resp(200, {"traffic": 1.76, "date_from": "2026-11-01"})])
    assert c.get_client_stats()["traffic"] == 1.76
    method, url, kw = s.calls[1]
    assert (method, url) == ("GET", f"{BASE}/users/{UID}/client-stats")
    assert kw["headers"]["Authorization"] == "Bearer jwt-1"


def test_user_id_property_logs_in():
    c, _ = _client([_login_ok()])
    assert c.user_id == UID


def test_non_dict_and_non_list_bodies_are_normalised():
    c, _ = _client([_login_ok(), _Resp(200, []), _Resp(200, {"x": 1}), _Resp(200, []), _Resp(200, [])])
    assert c.get_client_stats() == {}
    assert c.list_sub_users() == []
    assert c.get_sub_user_stats(1) == {}
    assert c.get_sub_user_target_stats(1, "2026-11-01") == {}


def test_read_non_json_raises():
    c, _ = _client([_login_ok(), _Resp(200, json_raises=True)])
    with pytest.raises(ox.OxylabsError, match="response was not JSON"):
        c.list_sub_users()


def test_sub_user_stats_params():
    c, s = _client([_login_ok(), _Resp(200, {"traffic": 9}), _Resp(200, {"traffic": 1})])
    c.get_sub_user_stats(12345, type="week", time_zone="Europe/Berlin")
    url, params = s.calls[1][1], s.calls[1][2]["params"]
    assert url == f"{BASE}/users/{UID}/sub-users/12345"
    assert params == {"type": "week", "time_zone": "Europe/Berlin"}
    c.get_sub_user_stats("12345", type="custom", date_from=date(2026, 11, 1), date_to="2026-11-02 15")
    assert s.calls[2][2]["params"] == {"type": "custom", "date_from": "2026-11-01", "date_to": "2026-11-02 15"}


def test_sub_user_stats_validation():
    c, s = _client([])
    with pytest.raises(ox.OxylabsError, match="type must be one of"):
        c.get_sub_user_stats(1, type="year")
    with pytest.raises(ox.OxylabsError, match="needs date_from and date_to"):
        c.get_sub_user_stats(1, type="custom", date_from="2026-11-01")
    assert s.calls == []


def test_sub_user_id_must_be_numeric():
    c, _ = _client([_login_ok()])
    with pytest.raises(ox.OxylabsError, match="numeric id"):
        c.get_sub_user_target_stats("1/../2", "2026-11-01")


def test_target_stats_date_formats():
    c, s = _client([_login_ok(), _Resp(200, {"requests": 5})])
    assert c.get_sub_user_target_stats(7, date(2026, 11, 3)) == {"requests": 5}
    assert s.calls[1][1].endswith("/sub-users/7/target-stats")
    assert s.calls[1][2]["params"] == {"date": "2026-11-03"}


def test_no_sub_user_write_methods_exist():
    names = [n.lower() for n in dir(ox.OxylabsResidentialClient)]
    assert not [n for n in names if any(w in n for w in ("create", "update", "delete", "disable", "patch"))]


def test_guard_runs_before_network():
    c, s = _client([])
    with pytest.raises(ox.OxylabsReadOnlyError):
        c._send("DELETE", f"{BASE}/users/{UID}/sub-users/1", retry=False)
    assert s.calls == []
