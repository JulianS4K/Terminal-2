"""Full-coverage tests for evo_client.EvoClient. No real HTTP calls.

Monkeypatch is applied at the `requests.get` boundary inside the client
module; the client builds a signed URL/header set and we capture it to assert
signature/param-normalization correctness, then return a fake response.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
from urllib.parse import parse_qs, urlencode, urlparse

import pytest

import evo_client
from evo_client import EvoClient, EvoReadOnlyError

SECRET = "32_CHARS_LONG_EXAMPLE_API_SECRET"  # exactly 32 — valid Fernet key
TOKEN = "test-token"


# ---------- fake transport ----------

class _FakeResp:
    def __init__(self, status, payload=None, headers=None, *, reason="reason",
                 text="body", method="GET", url="https://api.ticketevolution.com/x"):
        self.status_code = status
        self._payload = payload if payload is not None else {}
        self.headers = headers or {}
        self.ok = 200 <= status < 300
        self.reason = reason
        self.text = text
        self.url = url

        class _Req:
            pass

        req = _Req()
        req.method = method
        self.request = req

    def __bool__(self):
        return self.ok

    def json(self):
        return self._payload


def _client(secret: str = SECRET) -> EvoClient:
    return EvoClient(token=TOKEN, secret=secret)


@pytest.fixture
def capture(monkeypatch):
    """Capture the single GET the client issues and return a fixed payload."""
    state = {"calls": []}

    def fake_get(url, headers=None, timeout=None):
        state["calls"].append({"url": url, "headers": headers, "timeout": timeout})
        return _FakeResp(200, state.get("payload", {}))

    monkeypatch.setattr(evo_client.requests, "get", fake_get)
    return state


# ---------- construction ----------

def test_init_prod_host():
    c = EvoClient(TOKEN, SECRET)
    assert c.host == "api.ticketevolution.com"
    assert c.base_url == "https://api.ticketevolution.com"
    assert c.timeout == 30
    assert c.token == TOKEN
    assert c._secret == SECRET.encode("utf-8")


def test_init_sandbox_host_and_timeout():
    c = EvoClient(TOKEN, SECRET, sandbox=True, timeout=7)
    assert c.host == "api.sandbox.ticketevolution.com"
    assert c.base_url == "https://api.sandbox.ticketevolution.com"
    assert c.timeout == 7


# ---------- read-only guard ----------

def test_assert_readonly_allows_get():
    evo_client._assert_readonly_method("GET")
    evo_client._assert_readonly_method("get")


def test_assert_readonly_raises_on_writes():
    for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        with pytest.raises(EvoReadOnlyError) as exc:
            evo_client._assert_readonly_method(method)
        assert "READ-ONLY violation" in str(exc.value)


# ---------- _sign ----------

def test_sign_matches_hmac_recipe():
    c = _client()
    sig = c._sign("GET", "/v9/events", "page=1&per_page=100")
    expected = base64.b64encode(
        hmac.new(
            SECRET.encode("utf-8"),
            b"GET api.ticketevolution.com/v9/events?page=1&per_page=100",
            hashlib.sha256,
        ).digest()
    ).decode("utf-8")
    assert sig == expected


def test_sign_includes_question_mark_with_empty_query():
    c = _client()
    sig = c._sign("GET", "/v9/events/1/stats", "")
    expected = base64.b64encode(
        hmac.new(
            SECRET.encode("utf-8"),
            b"GET api.ticketevolution.com/v9/events/1/stats?",
            hashlib.sha256,
        ).digest()
    ).decode("utf-8")
    assert sig == expected


# ---------- _normalize ----------

def test_normalize_drops_none_and_stringifies_bools():
    out = EvoClient._normalize(
        {"a": None, "b": True, "c": False, "d": 5, "e": "x"}
    )
    assert out == {"b": "true", "c": "false", "d": 5, "e": "x"}


def test_normalize_handles_none_input():
    assert EvoClient._normalize(None) == {}


# ---------- _get: headers, signing, sorting ----------

def test_get_builds_signed_request(capture):
    c = _client()
    capture["payload"] = {"ok": True}
    res = c._get("/v9/events", {"page": 1, "per_page": 100, "z": None, "flag": True})
    assert res == {"ok": True}

    call = capture["calls"][0]
    parsed = urlparse(call["url"])
    assert parsed.scheme == "https"
    assert parsed.netloc == "api.ticketevolution.com"
    assert parsed.path == "/v9/events"
    # None dropped, bool stringified, params sorted
    qs = parse_qs(parsed.query)
    assert qs == {"flag": ["true"], "page": ["1"], "per_page": ["100"]}
    assert "z" not in qs

    # query is the sorted urlencode; signature matches it
    query = urlencode(sorted({"flag": "true", "page": 1, "per_page": 100}.items()))
    expected_sig = c._sign("GET", "/v9/events", query)
    headers = call["headers"]
    assert headers["X-Token"] == TOKEN
    assert headers["X-Signature"] == expected_sig
    assert "version=9" in headers["Accept"]
    assert call["timeout"] == 30


def test_get_empty_params(capture):
    c = _client()
    c._get("/v9/events/1/stats")
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.query == ""


# ---------- _get: error handling ----------

def test_get_non_retryable_status_raises_generic(monkeypatch):
    c = _client()
    monkeypatch.setattr(
        evo_client.requests, "get",
        lambda *a, **k: _FakeResp(404, reason="Not Found", text="secret-body"),
    )
    with pytest.raises(RuntimeError) as exc:
        c._get("/v9/events/1")
    # Only the status reaches the caller; no body/url leakage.
    assert "404" in str(exc.value)
    assert "secret-body" not in str(exc.value)


def test_get_retries_then_succeeds(monkeypatch):
    c = _client()
    seq = [_FakeResp(503), _FakeResp(200, {"recovered": True})]
    monkeypatch.setattr(evo_client.requests, "get", lambda *a, **k: seq.pop(0))
    monkeypatch.setattr(evo_client.time, "sleep", lambda s: None)
    assert c._get("/v9/events") == {"recovered": True}


def test_get_retries_exhausted_raises(monkeypatch):
    c = _client()
    monkeypatch.setattr(evo_client.requests, "get", lambda *a, **k: _FakeResp(429))
    slept = []
    monkeypatch.setattr(evo_client.time, "sleep", lambda s: slept.append(s))
    with pytest.raises(RuntimeError) as exc:
        c._get("/v9/events")
    assert "429" in str(exc.value)
    # _MAX_RETRIES retries -> 4 sleeps, exponential capped
    assert slept == [0.5, 1.0, 2.0, 4.0]


def test_get_honors_numeric_retry_after(monkeypatch):
    c = _client()
    seq = [_FakeResp(429, headers={"Retry-After": "3"}), _FakeResp(200, {"ok": 1})]
    monkeypatch.setattr(evo_client.requests, "get", lambda *a, **k: seq.pop(0))
    slept = []
    monkeypatch.setattr(evo_client.time, "sleep", lambda s: slept.append(s))
    assert c._get("/v9/events") == {"ok": 1}
    assert slept == [3.0]


def test_get_retry_after_caps_at_backoff_cap(monkeypatch):
    c = _client()
    seq = [_FakeResp(429, headers={"Retry-After": "9999"}), _FakeResp(200, {"ok": 1})]
    monkeypatch.setattr(evo_client.requests, "get", lambda *a, **k: seq.pop(0))
    slept = []
    monkeypatch.setattr(evo_client.time, "sleep", lambda s: slept.append(s))
    c._get("/v9/events")
    assert slept == [30.0]  # capped at _BACKOFF_CAP_SEC


def test_get_invalid_retry_after_falls_back_to_exponential(monkeypatch):
    c = _client()
    seq = [_FakeResp(429, headers={"Retry-After": "not-a-number"}),
           _FakeResp(200, {"ok": 1})]
    monkeypatch.setattr(evo_client.requests, "get", lambda *a, **k: seq.pop(0))
    slept = []
    monkeypatch.setattr(evo_client.time, "sleep", lambda s: slept.append(s))
    c._get("/v9/events")
    assert slept == [0.5]  # attempt 0 exponential


def test_get_no_response_else_branch(monkeypatch):
    """Cover the defensive `last_resp is None` else branch (lines ~216-220).

    In normal operation the retry loop always executes at least once and
    assigns `last_resp = r`, so this branch is unreachable via the public
    path. It only fires if the loop body never runs — i.e. an empty retry
    range. We force that by setting _MAX_RETRIES to -1 so range(0) is empty,
    exercising the connection-failure ("no response") guard the code keeps
    as a safety net. requests.get is patched to fail loudly if ever called.
    """
    c = _client()
    monkeypatch.setattr(c, "_MAX_RETRIES", -1)

    def _boom(*a, **k):  # pragma: no cover - must never be called
        raise AssertionError("requests.get should not run with empty retry range")

    monkeypatch.setattr(evo_client.requests, "get", _boom)
    with pytest.raises(RuntimeError) as exc:
        c._get("/v9/events")
    assert "no response" in str(exc.value)


# ---------- decrypt_barcode (follows tests/test_evo_barcode.py) ----------

def _encrypt(plaintext: str, secret: str = SECRET) -> str:
    from cryptography.fernet import Fernet

    key = base64.urlsafe_b64encode(secret.encode("utf-8")[:32])
    return Fernet(key).encrypt(plaintext.encode("utf-8")).decode("utf-8")


def test_decrypt_barcode_roundtrip():
    token = _encrypt("723917860")
    assert _client().decrypt_barcode(token) == "723917860"


def test_decrypt_barcode_accepts_bytes_token():
    token = _encrypt("99").encode("utf-8")
    assert _client().decrypt_barcode(token) == "99"


def test_decrypt_barcode_forged_raises():
    with pytest.raises(ValueError):
        _client().decrypt_barcode("gAAAAABnot_a_real_token_invalid==")


def test_decrypt_barcode_short_secret_raises():
    with pytest.raises(ValueError):
        _client("too-short").decrypt_barcode("anything")


# ---------- _iter_paginated ----------

def test_iter_paginated_stops_on_total_reached(monkeypatch):
    c = _client()
    pages = {
        1: {"events": [{"id": 1}, {"id": 2}], "total_entries": 3},
        2: {"events": [{"id": 3}], "total_entries": 3},
    }
    calls = []

    def fake_get(path, params=None):
        calls.append(params["page"])
        return pages[params["page"]]

    monkeypatch.setattr(c, "_get", fake_get)
    items = list(c._iter_paginated("/v9/events", "events", per_page=200))
    assert [i["id"] for i in items] == [1, 2, 3]
    assert calls == [1, 2]  # stopped once seen >= total


def test_iter_paginated_stops_on_empty_batch(monkeypatch):
    c = _client()
    pages = {1: {"events": [{"id": 1}], "total_entries": 99}, 2: {"events": []}}
    monkeypatch.setattr(c, "_get", lambda path, params=None: pages[params["page"]])
    items = list(c._iter_paginated("/v9/events", "events"))
    assert [i["id"] for i in items] == [1]


def test_iter_paginated_respects_max_pages(monkeypatch):
    c = _client()
    # Every page is full and total never reached -> bounded by max_pages.
    monkeypatch.setattr(
        c, "_get",
        lambda path, params=None: {"events": [{"id": params["page"]}], "total_entries": 9999},
    )
    items = list(c._iter_paginated("/v9/events", "events", max_pages=3))
    assert [i["id"] for i in items] == [1, 2, 3]


# ---------- events ----------

def test_list_events_params(capture):
    c = _client()
    c.list_events(
        "yankees", performer_id=5, venue_id=6,
        occurs_at_gte="2026-05-01", occurs_at_lte="2026-06-01",
        only_with_available_tickets=True, order_by="occurs_at",
        per_page=500, page=2, custom="z",
    )
    qs = parse_qs(urlparse(capture["calls"][0]["url"]).query)
    assert qs["q"] == ["yankees"]
    assert qs["performer_id"] == ["5"]
    assert qs["occurs_at.gte"] == ["2026-05-01"]
    assert qs["occurs_at.lte"] == ["2026-06-01"]
    assert qs["only_with_available_tickets"] == ["true"]
    assert qs["per_page"] == ["100"]  # capped at 100
    assert qs["page"] == ["2"]
    assert qs["custom"] == ["z"]


def test_search_events_alias_is_list_events():
    assert EvoClient.search_events is EvoClient.list_events


def test_search_events_fulltext(capture):
    c = _client()
    c.search_events_fulltext("phish", venue_id=9)
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/events/search"
    qs = parse_qs(parsed.query)
    assert qs["q"] == ["phish"]
    assert qs["venue_id"] == ["9"]


def test_get_event(capture):
    c = _client()
    capture["payload"] = {"event": {"id": 42}}
    res = c.get_event(42)
    assert res == {"event": {"id": 42}}
    assert urlparse(capture["calls"][0]["url"]).path == "/v9/events/42"


def test_get_event_stats_with_inventory_type(capture):
    c = _client()
    c.get_event_stats(42, inventory_type="parking")
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/events/42/stats"
    assert parse_qs(parsed.query)["inventory_type"] == ["parking"]


def test_get_event_stats_without_inventory_type(capture):
    c = _client()
    c.get_event_stats(42)
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/events/42/stats"
    assert parsed.query == ""


def test_iter_events_pops_page(monkeypatch):
    c = _client()
    seen = {}

    def fake_iter(path, result_key, *, max_pages, **kwargs):
        seen["path"] = path
        seen["result_key"] = result_key
        seen["kwargs"] = kwargs
        yield {"id": 1}

    monkeypatch.setattr(c, "_iter_paginated", fake_iter)
    items = list(c.iter_events(page=99, q="x"))
    assert items == [{"id": 1}]
    assert "page" not in seen["kwargs"]
    assert seen["kwargs"]["q"] == "x"
    assert seen["path"] == "/v9/events"


def test_search_events_all(monkeypatch):
    c = _client()
    monkeypatch.setattr(c, "iter_events", lambda max_pages=50, **kw: iter([{"id": 1}, {"id": 2}]))
    assert c.search_events_all() == [{"id": 1}, {"id": 2}]


# ---------- search_suggestions ----------

def test_search_suggestions_defaults(capture):
    c = _client()
    c.search_suggestions("yank")
    qs = parse_qs(urlparse(capture["calls"][0]["url"]).query)
    assert qs["q"] == ["yank"]
    assert qs["entities"] == ["events,performers,venues"]
    assert qs["fuzzy"] == ["true"]
    assert qs["limit"] == ["8"]
    assert "occurs_at.gte" not in qs


def test_search_suggestions_caps_limit_and_adds_date(capture):
    c = _client()
    c.search_suggestions("yank", limit=50, fuzzy=False, occurs_at_gte="2026-05-01")
    qs = parse_qs(urlparse(capture["calls"][0]["url"]).query)
    assert qs["limit"] == ["20"]  # capped
    assert qs["fuzzy"] == ["false"]
    assert qs["occurs_at.gte"] == ["2026-05-01"]


# ---------- listings / ticket_groups ----------

def test_get_listings(capture):
    c = _client()
    capture["payload"] = {"ticket_groups": [{"id": 1}]}
    res = c.get_listings(100, type="event", quantity=2, section="A", row="1",
                         owned=True, order_by="retail_price", extra_key="v")
    assert res == {"ticket_groups": [{"id": 1}]}
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/listings"
    qs = parse_qs(parsed.query)
    assert qs["event_id"] == ["100"]
    assert qs["type"] == ["event"]
    assert qs["owned"] == ["true"]
    assert qs["extra_key"] == ["v"]


def test_get_ticket_groups(capture):
    c = _client()
    c.get_ticket_groups(100, owned=False, state="available", order_by="x", k="v")
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/ticket_groups"
    qs = parse_qs(parsed.query)
    assert qs["event_id"] == ["100"]
    assert qs["owned"] == ["false"]
    assert qs["state"] == ["available"]
    assert qs["k"] == ["v"]


# ---------- performers ----------

def test_list_performers_default_per_page(capture):
    c = _client()
    c.list_performers(name="Phish")
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/performers"
    qs = parse_qs(parsed.query)
    assert qs["per_page"] == ["100"]
    assert qs["name"] == ["Phish"]


def test_search_performers(capture):
    c = _client()
    c.search_performers("phish", fuzzy=True, per_page=500, page=3, k="v")
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/performers/search"
    qs = parse_qs(parsed.query)
    assert qs["q"] == ["phish"]
    assert qs["fuzzy"] == ["true"]
    assert qs["per_page"] == ["100"]
    assert qs["page"] == ["3"]


def test_iter_performers(monkeypatch):
    c = _client()
    seen = {}
    monkeypatch.setattr(
        c, "_iter_paginated",
        lambda path, key, *, max_pages, **kw: seen.update(path=path, key=key, kw=kw) or iter([{"id": 1}]),
    )
    items = list(c.iter_performers(page=5, q="x"))
    assert items == [{"id": 1}]
    assert seen["path"] == "/v9/performers"
    assert seen["key"] == "performers"
    assert "page" not in seen["kw"]


def test_get_performer_plain(capture):
    c = _client()
    c.get_performer(7)
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/performers/7"
    assert parsed.query == ""


def test_get_performer_with_opponents(capture):
    c = _client()
    c.get_performer(7, include_opponents=True)
    qs = parse_qs(urlparse(capture["calls"][0]["url"]).query)
    assert qs["include[]"] == ["opponents"]


# ---------- venues ----------

def test_list_venues_default_per_page(capture):
    c = _client()
    c.list_venues(city_state="NY")
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/venues"
    qs = parse_qs(parsed.query)
    assert qs["per_page"] == ["100"]
    assert qs["city_state"] == ["NY"]


def test_search_venues(capture):
    c = _client()
    c.search_venues("garden", fuzzy=False, per_page=200, page=2)
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/venues/search"
    qs = parse_qs(parsed.query)
    assert qs["q"] == ["garden"]
    assert qs["fuzzy"] == ["false"]
    assert qs["per_page"] == ["100"]


def test_iter_venues(monkeypatch):
    c = _client()
    seen = {}
    monkeypatch.setattr(
        c, "_iter_paginated",
        lambda path, key, *, max_pages, **kw: seen.update(path=path, key=key, kw=kw) or iter([{"id": 2}]),
    )
    items = list(c.iter_venues(page=8))
    assert items == [{"id": 2}]
    assert seen["path"] == "/v9/venues"
    assert seen["key"] == "venues"
    assert "page" not in seen["kw"]


def test_get_venue(capture):
    c = _client()
    c.get_venue(11)
    assert urlparse(capture["calls"][0]["url"]).path == "/v9/venues/11"


# ---------- configurations ----------

def test_list_configurations(capture):
    c = _client()
    c.list_configurations(venue_id=3, name="lower", per_page=500, page=2, k="v")
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/configurations"
    qs = parse_qs(parsed.query)
    assert qs["venue_id"] == ["3"]
    assert qs["name"] == ["lower"]
    assert qs["per_page"] == ["100"]
    assert qs["k"] == ["v"]


def test_iter_configurations(monkeypatch):
    c = _client()
    seen = {}
    monkeypatch.setattr(
        c, "_iter_paginated",
        lambda path, key, *, max_pages, **kw: seen.update(path=path, key=key, kw=kw) or iter([{"id": 3}]),
    )
    items = list(c.iter_configurations(page=2))
    assert items == [{"id": 3}]
    assert seen["path"] == "/v9/configurations"
    assert seen["key"] == "configurations"
    assert "page" not in seen["kw"]


def test_get_configuration(capture):
    c = _client()
    c.get_configuration(55)
    assert urlparse(capture["calls"][0]["url"]).path == "/v9/configurations/55"


# ---------- orders ----------

def test_list_orders_caps_per_page_at_10(capture):
    c = _client()
    c.list_orders(q="ref", seller_id=1, buyer_id=2, order_id=3, order_group_id=4,
                  state="completed", type="Order", needs_eticket=True,
                  direct_buyer_type="broker", reference="R", performer_id=5,
                  venue_id=6, event_date="2026-05-01", page=2, per_page=100, k="v")
    parsed = urlparse(capture["calls"][0]["url"])
    assert parsed.path == "/v9/orders"
    qs = parse_qs(parsed.query)
    assert qs["per_page"] == ["10"]  # server-enforced cap
    assert qs["state"] == ["completed"]
    assert qs["type"] == ["Order"]
    assert qs["needs_eticket"] == ["true"]
    assert qs["k"] == ["v"]


def test_iter_orders_stops_on_total(monkeypatch):
    c = _client()
    pages = {
        1: {"orders": [{"id": 1}, {"id": 2}], "total_entries": 3},
        2: {"orders": [{"id": 3}], "total_entries": 3},
    }
    calls = []

    def fake_list_orders(*, page, per_page, **kw):
        calls.append((page, per_page))
        return pages[page]

    monkeypatch.setattr(c, "list_orders", fake_list_orders)
    items = list(c.iter_orders(per_page=50))
    assert [o["id"] for o in items] == [1, 2, 3]
    assert calls == [(1, 10), (2, 10)]  # per_page capped at 10


def test_iter_orders_stops_on_empty(monkeypatch):
    c = _client()
    pages = {1: {"orders": [{"id": 1}], "total_entries": 99}, 2: {"orders": []}}
    monkeypatch.setattr(c, "list_orders", lambda *, page, per_page, **kw: pages[page])
    items = list(c.iter_orders())
    assert [o["id"] for o in items] == [1]


def test_get_order(capture):
    c = _client()
    capture["payload"] = {"order": {"id": 9}}
    res = c.get_order(9)
    assert res == {"order": {"id": 9}}
    assert urlparse(capture["calls"][0]["url"]).path == "/v9/orders/9"
