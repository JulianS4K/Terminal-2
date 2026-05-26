"""TicketsData client + MVP budget-guard tests. No real HTTP calls."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path

import pytest

import ticketsdata_client as td


# ---------- read-only guard ----------

def test_assert_readonly_allows_get():
    td._assert_readonly_method("GET")  # no raise


def test_assert_readonly_raises_on_writes():
    for method in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(td.TicketsDataReadOnlyError):
            td._assert_readonly_method(method)


# ---------- construction / validation ----------

def test_requires_credentials():
    with pytest.raises(td.TicketsDataError):
        td.TicketsDataClient("", "")


def test_fetch_rejects_unsupported_platform():
    c = td.TicketsDataClient("u@example.com", "pw")
    with pytest.raises(td.TicketsDataError):
        c.fetch("nope", "https://x")


def test_events_requires_a_page_url():
    c = td.TicketsDataClient("u@example.com", "pw")
    with pytest.raises(td.TicketsDataError):
        c.events("seatgeek")


def test_credit_costs():
    assert td.CREDIT_COST == {"fetch": 1, "events": 1, "match": 12}


# ---------- transport (mocked) ----------

class _FakeResp:
    def __init__(self, status, payload=None, headers=None):
        self.status_code = status
        self._payload = payload if payload is not None else {}
        self.headers = headers or {}
        self.ok = 200 <= status < 300
        self.text = "x"

    def json(self):
        return self._payload


def test_fetch_parses_and_passes_creds(monkeypatch):
    captured = {}

    def fake_get(url, params=None, timeout=None):
        captured["url"] = url
        captured["params"] = params
        return _FakeResp(200, {"status": 200, "platform": "seatgeek",
                               "body": {"offers": [1, 2, 3]}, "quota_remaining": 9999})

    monkeypatch.setattr(td.requests, "get", fake_get)
    c = td.TicketsDataClient("u@example.com", "secret-pw")
    env = c.fetch("seatgeek", "https://seatgeek.com/concert/1")
    assert env["quota_remaining"] == 9999
    # creds travel in params, never baked into the URL string
    assert "secret-pw" not in captured["url"]
    assert captured["params"]["username"] == "u@example.com"
    assert captured["params"]["password"] == "secret-pw"


def test_auth_error_does_not_leak_credentials(monkeypatch):
    monkeypatch.setattr(td.requests, "get", lambda *a, **k: _FakeResp(401))
    c = td.TicketsDataClient("u@example.com", "secret-pw")
    with pytest.raises(td.TicketsDataAuthError) as exc:
        c.fetch("seatgeek", "https://seatgeek.com/concert/1")
    assert "secret-pw" not in str(exc.value)


def test_quota_exhausted_maps_to_402(monkeypatch):
    monkeypatch.setattr(td.requests, "get", lambda *a, **k: _FakeResp(402))
    c = td.TicketsDataClient("u@example.com", "pw")
    with pytest.raises(td.TicketsDataQuotaError):
        c.events("seatgeek", performer_url="https://seatgeek.com/x")


# ---------- MVP budget guard ----------

def _load_mvp():
    path = Path(__file__).resolve().parent.parent / "scripts" / "ticketsdata_mvp.py"
    spec = importlib.util.spec_from_file_location("ticketsdata_mvp", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_budget_refuses_over_cap():
    mvp = _load_mvp()
    b = mvp.Budget(max_credits=5, min_quota_floor=10)
    b.check(1)
    b.record(1, quota_remaining=9000)
    with pytest.raises(mvp.BudgetExceeded):
        b.check(12)  # a /match would blow the 5-credit cap


def test_budget_refuses_below_quota_floor():
    mvp = _load_mvp()
    b = mvp.Budget(max_credits=100, min_quota_floor=50)
    b.record(1, quota_remaining=51)
    with pytest.raises(mvp.BudgetExceeded):
        b.check(2)  # 51 - 2 = 49 < floor 50
