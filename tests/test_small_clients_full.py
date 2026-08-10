"""Full line-coverage tests for the three small broker clients:
vivid_client, tickpick_client, gotickets_client. No real HTTP — all
requests.get calls are monkeypatched at the boundary. Mirrors the house
style in tests/test_ticketsdata_client.py (fake responses) and
tests/test_readonly_guards.py (read-only guard assertions).
"""
from __future__ import annotations

import pytest

import vivid_client as vivid
import tickpick_client as tickpick
import gotickets_client as gotickets


# ====================================================================
# Shared fake HTTP response
# ====================================================================

class _FakeResp:
    def __init__(self, status, *, content=b"", json_payload=None,
                 json_raises=False, text="raw-body", headers=None):
        self.status_code = status
        self.ok = 200 <= status < 300
        self.content = content
        self._json_payload = json_payload
        self._json_raises = json_raises
        self.text = text
        self.headers = headers or {}

    def json(self):
        if self._json_raises:
            raise ValueError("no json")
        return self._json_payload


def _patch_get(monkeypatch, module, responses, captured=None):
    """Patch module.requests.get to return queued responses in order.
    If `responses` is a single _FakeResp it is reused for every call.
    `captured` (a list) records (url, kwargs) for assertions."""
    if isinstance(responses, _FakeResp):
        seq = None
        single = responses
    else:
        seq = iter(responses)
        single = None

    def fake_get(url, **kwargs):
        if captured is not None:
            captured.append((url, kwargs))
        return single if single is not None else next(seq)

    monkeypatch.setattr(module.requests, "get", fake_get)


# ====================================================================
# vivid_client
# ====================================================================

ORDERS_XML = b"""<?xml version="1.0"?>
<orders>
  <order>
    <orderId>111</orderId>
    <status> PENDING_SHIPMENT </status>
    <empty></empty>
  </order>
  <order>
    <orderId>222</orderId>
    <status>PENDING_RETRANSFER</status>
  </order>
</orders>"""

SINGLE_ORDER_XML = b"""<?xml version="1.0"?>
<order>
  <orderId>999</orderId>
  <buyer>Jane</buyer>
</order>"""

RETRANSFER_XML = b"""<?xml version="1.0"?>
<orders>
  <order><orderId>222</orderId><status>RETRANSFER</status></order>
  <order><orderId>333</orderId></order>
</orders>"""


def test_vivid_requires_token():
    with pytest.raises(vivid.VividError):
        vivid.VividClient("")


def test_vivid_token_is_stripped():
    c = vivid.VividClient("  tok  ")
    assert c.api_token == "tok"


def test_vivid_readonly_guard():
    vivid._assert_readonly_method("GET")
    for m in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(vivid.VividReadOnlyError):
            vivid._assert_readonly_method(m)


def test_vivid_parse_orders_flattens_list():
    rows = vivid.VividClient._parse_orders(ORDERS_XML)
    assert rows == [
        {"orderId": "111", "status": "PENDING_SHIPMENT", "empty": ""},
        {"orderId": "222", "status": "PENDING_RETRANSFER"},
    ]


def test_vivid_parse_orders_bad_xml_returns_empty():
    assert vivid.VividClient._parse_orders(b"<not-closed") == []


def test_vivid_parse_single_order():
    assert vivid.VividClient._parse_single_order(SINGLE_ORDER_XML) == {
        "orderId": "999", "buyer": "Jane",
    }


def test_vivid_parse_single_order_bad_xml_returns_empty():
    assert vivid.VividClient._parse_single_order(b"<<bad") == {}


def test_vivid_list_orders_happy_and_params(monkeypatch):
    captured = []
    _patch_get(monkeypatch, vivid, _FakeResp(200, content=ORDERS_XML), captured)
    c = vivid.VividClient("tok")
    rows = c.list_orders(extraParam="z")
    assert len(rows) == 2
    url, kwargs = captured[0]
    assert url.endswith("/getOrders")
    params = kwargs["params"]
    # apiToken always present; default status applied; extra forwarded
    assert params["apiToken"] == "tok"
    assert params["status"] == "PENDING_SHIPMENT"
    assert params["extraParam"] == "z"


def test_vivid_list_orders_status_none_omitted(monkeypatch):
    captured = []
    _patch_get(monkeypatch, vivid, _FakeResp(200, content=ORDERS_XML), captured)
    c = vivid.VividClient("tok")
    c.list_orders(status=None)
    params = captured[0][1]["params"]
    assert "status" not in params  # None-valued params dropped by _get


def test_vivid_get_non_200_raises(monkeypatch):
    _patch_get(monkeypatch, vivid, _FakeResp(500))
    c = vivid.VividClient("tok")
    with pytest.raises(vivid.VividError) as exc:
        c.list_orders()
    assert "HTTP 500" in str(exc.value)


def test_vivid_get_retries_on_429_then_succeeds(monkeypatch):
    monkeypatch.setattr(vivid.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(429, headers={"Retry-After": "1"}),
        _FakeResp(200, content=ORDERS_XML),
    ]
    _patch_get(monkeypatch, vivid, responses)
    c = vivid.VividClient("tok")
    assert len(c.list_orders()) == 2


def test_vivid_get_503_bad_retry_after_falls_back(monkeypatch):
    monkeypatch.setattr(vivid.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(503, headers={"Retry-After": "not-a-number"}),
        _FakeResp(200, content=ORDERS_XML),
    ]
    _patch_get(monkeypatch, vivid, responses)
    c = vivid.VividClient("tok")
    assert len(c.list_orders()) == 2


def test_vivid_get_429_no_retry_after_header(monkeypatch):
    monkeypatch.setattr(vivid.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(429),  # no Retry-After -> exponential backoff branch
        _FakeResp(200, content=ORDERS_XML),
    ]
    _patch_get(monkeypatch, vivid, responses)
    c = vivid.VividClient("tok")
    assert len(c.list_orders()) == 2


def test_vivid_get_exhausts_retries_and_raises(monkeypatch):
    monkeypatch.setattr(vivid.time, "sleep", lambda *_: None)
    _patch_get(monkeypatch, vivid, _FakeResp(503))  # always 503
    c = vivid.VividClient("tok")
    with pytest.raises(vivid.VividError):
        c.list_orders()


def test_vivid_list_pending_retransfer(monkeypatch):
    captured = []
    _patch_get(monkeypatch, vivid, _FakeResp(200, content=RETRANSFER_XML), captured)
    c = vivid.VividClient("tok")
    rows = c.list_pending_retransfer_orders()
    assert len(rows) == 2
    assert captured[0][0].endswith("/getPendingRetransferOrders")


def test_vivid_list_active_dedupes_by_order_id(monkeypatch):
    # First call -> getOrders (111,222); second -> retransfer (222,333 w/o id-less row).
    responses = [
        _FakeResp(200, content=ORDERS_XML),
        _FakeResp(200, content=RETRANSFER_XML),
    ]
    _patch_get(monkeypatch, vivid, responses)
    c = vivid.VividClient("tok")
    rows = c.list_active_orders()
    ids = sorted(r["orderId"] for r in rows)
    # 111, 222 (deduped), 333; the id-less retransfer row is skipped
    assert ids == ["111", "222", "333"]


def test_vivid_get_order(monkeypatch):
    captured = []
    _patch_get(monkeypatch, vivid, _FakeResp(200, content=SINGLE_ORDER_XML), captured)
    c = vivid.VividClient("tok")
    row = c.get_order(999)
    assert row["orderId"] == "999"
    params = captured[0][1]["params"]
    assert params["orderId"] == 999  # coerced to int


# ====================================================================
# tickpick_client
# ====================================================================

def test_tickpick_requires_token():
    with pytest.raises(tickpick.TickPickError):
        tickpick.TickPickClient("")


def test_tickpick_token_stripped():
    assert tickpick.TickPickClient("  t  ").token == "t"


def test_tickpick_readonly_guard():
    tickpick._assert_readonly_method("GET")
    for m in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(tickpick.TickPickReadOnlyError):
            tickpick._assert_readonly_method(m)


def test_tickpick_list_orders_array_and_auth_header(monkeypatch):
    captured = []
    _patch_get(monkeypatch, tickpick,
               _FakeResp(200, json_payload=[{"id": 1}, {"id": 2}]), captured)
    c = tickpick.TickPickClient("tok")
    rows = c.list_orders(extra="e")
    assert rows == [{"id": 1}, {"id": 2}]
    url, kwargs = captured[0]
    assert url.endswith("/orders")
    assert kwargs["headers"]["Authorization"] == "Bearer tok"
    assert kwargs["params"]["status"] == "unfulfilled"
    assert kwargs["params"]["extra"] == "e"


def test_tickpick_list_orders_status_none_omitted(monkeypatch):
    captured = []
    _patch_get(monkeypatch, tickpick, _FakeResp(200, json_payload=[]), captured)
    c = tickpick.TickPickClient("tok")
    c.list_orders(status=None)
    assert "status" not in captured[0][1]["params"]


def test_tickpick_list_orders_dict_wrapper(monkeypatch):
    _patch_get(monkeypatch, tickpick,
               _FakeResp(200, json_payload={"orders": [{"id": 9}]}))
    c = tickpick.TickPickClient("tok")
    assert c.list_orders() == [{"id": 9}]


def test_tickpick_list_orders_unexpected_shape_returns_empty(monkeypatch):
    _patch_get(monkeypatch, tickpick,
               _FakeResp(200, json_payload={"nope": 1}))
    c = tickpick.TickPickClient("tok")
    assert c.list_orders() == []


def test_tickpick_get_json_fallback_to_raw_text(monkeypatch):
    _patch_get(monkeypatch, tickpick,
               _FakeResp(200, json_raises=True, text="plain"))
    c = tickpick.TickPickClient("tok")
    # body is {"raw_text": "plain"} which is a dict -> list_orders sees no
    # list, returns []
    assert c.list_orders() == []


def test_tickpick_get_non_200_raises(monkeypatch):
    _patch_get(monkeypatch, tickpick, _FakeResp(404))
    c = tickpick.TickPickClient("tok")
    with pytest.raises(tickpick.TickPickError) as exc:
        c.list_orders()
    assert "HTTP 404" in str(exc.value)


def test_tickpick_retry_on_503_then_ok(monkeypatch):
    monkeypatch.setattr(tickpick.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(503, headers={"Retry-After": "2"}),
        _FakeResp(200, json_payload=[]),
    ]
    _patch_get(monkeypatch, tickpick, responses)
    c = tickpick.TickPickClient("tok")
    assert c.list_orders() == []


def test_tickpick_retry_bad_retry_after(monkeypatch):
    monkeypatch.setattr(tickpick.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(429, headers={"Retry-After": "soon"}),
        _FakeResp(200, json_payload=[]),
    ]
    _patch_get(monkeypatch, tickpick, responses)
    c = tickpick.TickPickClient("tok")
    assert c.list_orders() == []


def test_tickpick_retry_no_header(monkeypatch):
    monkeypatch.setattr(tickpick.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(429),
        _FakeResp(200, json_payload=[]),
    ]
    _patch_get(monkeypatch, tickpick, responses)
    c = tickpick.TickPickClient("tok")
    assert c.list_orders() == []


def test_tickpick_retry_exhausted(monkeypatch):
    monkeypatch.setattr(tickpick.time, "sleep", lambda *_: None)
    _patch_get(monkeypatch, tickpick, _FakeResp(503))
    c = tickpick.TickPickClient("tok")
    with pytest.raises(tickpick.TickPickError):
        c.list_orders()


def test_tickpick_get_order_details_happy(monkeypatch):
    captured = []
    _patch_get(monkeypatch, tickpick,
               _FakeResp(200, json_payload={"id": 77, "seats": 2}), captured)
    c = tickpick.TickPickClient("tok")
    detail = c.get_order_details("77")
    assert detail == {"id": 77, "seats": 2}
    assert captured[0][0].endswith("/orders/77/details")


def test_tickpick_get_order_details_non_dict_returns_empty(monkeypatch):
    _patch_get(monkeypatch, tickpick, _FakeResp(200, json_payload=[1, 2]))
    c = tickpick.TickPickClient("tok")
    assert c.get_order_details(5) == {}


# ====================================================================
# gotickets_client
# ====================================================================

def test_gotickets_requires_both_creds():
    with pytest.raises(gotickets.GoTicketsError):
        gotickets.GoTicketsClient("", "secret")
    with pytest.raises(gotickets.GoTicketsError):
        gotickets.GoTicketsClient("id", "")


def test_gotickets_creds_stripped():
    c = gotickets.GoTicketsClient("  id  ", "  sec  ")
    assert c.access_id == "id"
    assert c.api_secret == "sec"


def test_gotickets_readonly_guard():
    gotickets._assert_readonly_method("GET")
    for m in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(gotickets.GoTicketsReadOnlyError):
            gotickets._assert_readonly_method(m)


def test_gotickets_get_sale_happy_and_headers(monkeypatch):
    captured = []
    _patch_get(monkeypatch, gotickets,
               _FakeResp(200, json_payload={"fulfilled": True}), captured)
    c = gotickets.GoTicketsClient("id", "sec")
    sale = c.get_sale("abc123")
    assert sale == {"fulfilled": True}
    url, kwargs = captured[0]
    assert url.endswith("/rest/sales/abc123")
    assert kwargs["headers"]["X-Api-Access-Id"] == "id"
    assert kwargs["headers"]["X-Api-Access-Secret"] == "sec"


def test_gotickets_get_sale_non_dict_returns_empty(monkeypatch):
    _patch_get(monkeypatch, gotickets, _FakeResp(200, json_payload=[1]))
    c = gotickets.GoTicketsClient("id", "sec")
    assert c.get_sale("x") == {}


def test_gotickets_json_fallback_to_raw_text(monkeypatch):
    _patch_get(monkeypatch, gotickets,
               _FakeResp(200, json_raises=True, text="oops"))
    c = gotickets.GoTicketsClient("id", "sec")
    assert c.get_sale("x") == {"raw_text": "oops"}


def test_gotickets_non_200_raises(monkeypatch):
    _patch_get(monkeypatch, gotickets, _FakeResp(403))
    c = gotickets.GoTicketsClient("id", "sec")
    with pytest.raises(gotickets.GoTicketsError) as exc:
        c.get_sale("x")
    assert "HTTP 403" in str(exc.value)


def test_gotickets_params_none_dropped(monkeypatch):
    # get_sale passes no params, but exercise _get's param-clean via a direct
    # call with a None-valued param.
    captured = []
    _patch_get(monkeypatch, gotickets, _FakeResp(200, json_payload={}), captured)
    c = gotickets.GoTicketsClient("id", "sec")
    c._get("/rest/sales/1", {"keep": "v", "drop": None})
    params = captured[0][1]["params"]
    assert params == {"keep": "v"}


def test_gotickets_retry_on_429_then_ok(monkeypatch):
    monkeypatch.setattr(gotickets.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(429, headers={"Retry-After": "3"}),
        _FakeResp(200, json_payload={"ok": 1}),
    ]
    _patch_get(monkeypatch, gotickets, responses)
    c = gotickets.GoTicketsClient("id", "sec")
    assert c.get_sale("x") == {"ok": 1}


def test_gotickets_retry_bad_retry_after(monkeypatch):
    monkeypatch.setattr(gotickets.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(503, headers={"Retry-After": "later"}),
        _FakeResp(200, json_payload={"ok": 1}),
    ]
    _patch_get(monkeypatch, gotickets, responses)
    c = gotickets.GoTicketsClient("id", "sec")
    assert c.get_sale("x") == {"ok": 1}


def test_gotickets_retry_no_header(monkeypatch):
    monkeypatch.setattr(gotickets.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(503),
        _FakeResp(200, json_payload={"ok": 1}),
    ]
    _patch_get(monkeypatch, gotickets, responses)
    c = gotickets.GoTicketsClient("id", "sec")
    assert c.get_sale("x") == {"ok": 1}


def test_gotickets_retry_exhausted(monkeypatch):
    monkeypatch.setattr(gotickets.time, "sleep", lambda *_: None)
    _patch_get(monkeypatch, gotickets, _FakeResp(503))
    c = gotickets.GoTicketsClient("id", "sec")
    with pytest.raises(gotickets.GoTicketsError):
        c.get_sale("x")


def test_gotickets_network_error_wrapped(monkeypatch):
    def boom(*a, **k):
        raise gotickets.requests.ConnectionError("down")
    monkeypatch.setattr(gotickets.requests, "get", boom)
    c = gotickets.GoTicketsClient("id", "sec")
    with pytest.raises(gotickets.GoTicketsError) as exc:
        c.get_sale("x")
    assert "network error" in str(exc.value)
    assert "ConnectionError" in str(exc.value)


def test_gotickets_timeout_error_wrapped(monkeypatch):
    def boom(*a, **k):
        raise gotickets.requests.Timeout("slow")
    monkeypatch.setattr(gotickets.requests, "get", boom)
    c = gotickets.GoTicketsClient("id", "sec")
    with pytest.raises(gotickets.GoTicketsError) as exc:
        c.get_sale("x")
    assert "Timeout" in str(exc.value)


# ---- events-controller (sc.gotickets.com/rest/events*) ----

def test_gotickets_get_events_list_and_params(monkeypatch):
    captured = []
    events = [{"id": 1}, {"id": 2}]
    _patch_get(monkeypatch, gotickets, _FakeResp(200, json_payload=events), captured)
    c = gotickets.GoTicketsClient("id", "sec")
    out = c.get_events({"page": 1, "skip": None})
    assert out == events
    url, kwargs = captured[0]
    assert url.endswith("/rest/events")
    assert kwargs["params"] == {"page": 1}  # None dropped


def test_gotickets_get_event_detail_and_non_dict(monkeypatch):
    captured = []
    _patch_get(monkeypatch, gotickets,
               _FakeResp(200, json_payload={"id": 9, "name": "X"}), captured)
    c = gotickets.GoTicketsClient("id", "sec")
    assert c.get_event(9) == {"id": 9, "name": "X"}
    assert captured[0][0].endswith("/rest/events/9")
    # non-dict body -> {}
    _patch_get(monkeypatch, gotickets, _FakeResp(200, json_payload=[1, 2]))
    assert c.get_event(9) == {}


def test_gotickets_get_events_venues(monkeypatch):
    captured = []
    _patch_get(monkeypatch, gotickets,
               _FakeResp(200, json_payload=[{"venue": "MSG"}]), captured)
    c = gotickets.GoTicketsClient("id", "sec")
    assert c.get_events_venues() == [{"venue": "MSG"}]
    assert captured[0][0].endswith("/rest/events/venues")


def test_gotickets_get_events_delta(monkeypatch):
    captured = []
    _patch_get(monkeypatch, gotickets,
               _FakeResp(200, json_payload={"changed": []}), captured)
    c = gotickets.GoTicketsClient("id", "sec")
    assert c.get_events_delta({"since": "2026-08-01T00:00:00Z"}) == {"changed": []}
    url, kwargs = captured[0]
    assert url.endswith("/rest/events/delta")
    assert kwargs["params"] == {"since": "2026-08-01T00:00:00Z"}


# ====================================================================
# gotickets_client — Pro API (GoTicketsProClient, listings read slice)
# ====================================================================

import base64 as _base64  # noqa: E402  (module-scope import mirrors gotickets)


def test_gotickets_pro_requires_both_creds():
    with pytest.raises(gotickets.GoTicketsError):
        gotickets.GoTicketsProClient("", "secret")
    with pytest.raises(gotickets.GoTicketsError):
        gotickets.GoTicketsProClient("id", "")


def test_gotickets_pro_creds_stripped_and_token():
    c = gotickets.GoTicketsProClient("  id  ", "  sec  ")
    assert c.access_id == "id"
    assert c.api_secret == "sec"
    # X-Broker-Api-Token = base64("id:sec"), no trailing newline.
    assert c.api_token == _base64.b64encode(b"id:sec").decode("ascii")


def test_gotickets_pro_listings_happy_and_headers(monkeypatch):
    captured = []
    listings = [{"displayPrice": 100.0, "tax": 5.0, "quantity": 2}]
    _patch_get(monkeypatch, gotickets,
               _FakeResp(200, json_payload=listings), captured)
    c = gotickets.GoTicketsProClient("id", "sec")
    out = c.get_event_listings(123456)
    assert out == listings
    url, kwargs = captured[0]
    assert url.endswith("/rest/pro/api/events/123456/listings")
    assert kwargs["headers"]["X-Broker-Api-Token"] == c.api_token
    # payment_method_token omitted by default -> dropped from params.
    assert kwargs["params"] == {}


def test_gotickets_pro_listings_with_payment_method_token(monkeypatch):
    captured = []
    _patch_get(monkeypatch, gotickets, _FakeResp(200, json_payload=[]), captured)
    c = gotickets.GoTicketsProClient("id", "sec")
    c.get_event_listings(7, payment_method_token="abc123xyz")
    assert captured[0][1]["params"] == {"paymentMethodToken": "abc123xyz"}


def test_gotickets_pro_listings_non_list_returns_empty(monkeypatch):
    _patch_get(monkeypatch, gotickets, _FakeResp(200, json_payload={"err": 1}))
    c = gotickets.GoTicketsProClient("id", "sec")
    assert c.get_event_listings("x") == []


def test_gotickets_pro_non_200_raises(monkeypatch):
    _patch_get(monkeypatch, gotickets, _FakeResp(403))
    c = gotickets.GoTicketsProClient("id", "sec")
    with pytest.raises(gotickets.GoTicketsError) as exc:
        c.get_event_listings("x")
    assert "HTTP 403" in str(exc.value)


def test_gotickets_pro_json_fallback_to_raw_text(monkeypatch):
    # Exercise _get's ValueError branch directly (get_event_listings would
    # coerce the dict to []).
    _patch_get(monkeypatch, gotickets,
               _FakeResp(200, json_raises=True, text="oops"))
    c = gotickets.GoTicketsProClient("id", "sec")
    assert c._get("/events/1/listings") == {"raw_text": "oops"}


def test_gotickets_pro_retry_on_429_then_ok(monkeypatch):
    monkeypatch.setattr(gotickets.time, "sleep", lambda *_: None)
    responses = [
        _FakeResp(429, headers={"Retry-After": "3"}),
        _FakeResp(200, json_payload=[{"ok": 1}]),
    ]
    _patch_get(monkeypatch, gotickets, responses)
    c = gotickets.GoTicketsProClient("id", "sec")
    assert c.get_event_listings("x") == [{"ok": 1}]


def test_gotickets_pro_network_error_wrapped(monkeypatch):
    def boom(*a, **k):
        raise gotickets.requests.ConnectionError("down")
    monkeypatch.setattr(gotickets.requests, "get", boom)
    c = gotickets.GoTicketsProClient("id", "sec")
    with pytest.raises(gotickets.GoTicketsError) as exc:
        c.get_event_listings("x")
    assert "network error" in str(exc.value)
    assert "ConnectionError" in str(exc.value)


def test_gotickets_pro_timeout_error_wrapped(monkeypatch):
    def boom(*a, **k):
        raise gotickets.requests.Timeout("slow")
    monkeypatch.setattr(gotickets.requests, "get", boom)
    c = gotickets.GoTicketsProClient("id", "sec")
    with pytest.raises(gotickets.GoTicketsError) as exc:
        c.get_event_listings("x")
    assert "Timeout" in str(exc.value)
