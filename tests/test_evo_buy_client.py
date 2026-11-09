"""evo_buy_client — the path-pinned EVO write client (operator authorization 2026-11-09)."""
import base64
import hashlib
import hmac
import json
from types import SimpleNamespace

import pytest
import requests

import evo_buy_client as eb


class FakeSession:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def request(self, method, url, **kw):
        self.calls.append((method, url, kw))
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def _resp(status=200, body=None):
    content = b"" if body is None else json.dumps(body).encode()
    return SimpleNamespace(status_code=status, content=content, text=content.decode(),
                           json=lambda: json.loads(content))


def _client(*responses):
    return eb.EvoBuyClient("tok", "xyz", session=FakeSession(responses))


def test_guard_allows_get_and_only_the_two_write_paths():
    eb._assert_readonly_method("GET", "/v9/anything")
    eb._assert_readonly_method("post", "/v9/orders")
    eb._assert_readonly_method("POST", "/v9/orders/123/accept")
    for path in ("/v9/orders/123/reject", "/v9/orders/123", "/v9/ticket_groups/1", "/v9/orders/x/accept",
                 "/v9/orders/1/accept/../reject", "/v9/orders?x=1", "", None):
        with pytest.raises(eb.EvoBuyError, match="not sanctioned"):
            eb._assert_readonly_method("POST", path)
    for m in ("PUT", "PATCH", "DELETE"):
        with pytest.raises(eb.EvoBuyError, match="RULE 2"):
            eb._assert_readonly_method(m, "/v9/orders")
    assert eb.ALLOWED_HTTP_METHODS == frozenset({"GET", "POST"})
    assert eb.EVO_WRITE_PATHS == (r"^/v9/orders$", r"^/v9/orders/\d+/accept$")


def test_guard_runs_before_any_request():
    c = _client()
    with pytest.raises(eb.EvoBuyError):
        c._call("POST", "/v9/orders/1/reject", body={})
    with pytest.raises(eb.EvoBuyError):
        c._call("DELETE", "/v9/orders/1")
    assert c.session.calls == []


def test_signature_matches_the_production_read_client():
    from evo_client import (
        EvoClient,  # its signer is what every live EVO read uses today
    )
    c = eb.EvoBuyClient("tok", "xyz", session=FakeSession([]))
    assert c._sign("GET", "/v9/brokerages", "page=1&per_page=1") == \
        EvoClient("tok", "xyz")._sign("GET", "/v9/brokerages", "page=1&per_page=1")


def test_get_signs_the_sorted_query_and_reads():
    c = _client(_resp(200, {"id": 5}), _resp(200, {"state": "pending"}))
    assert c.get_ticket_group("5") == {"id": 5}
    method, url, kw = c.session.calls[0]
    assert (method, url, kw["data"]) == ("GET", "https://api.ticketevolution.com/v9/ticket_groups/5", None)
    assert c._call("GET", "/v9/orders", params={"b": 2, "a": 1}) == {"state": "pending"}
    method, url, kw = c.session.calls[1]
    assert url.endswith("/v9/orders?a=1&b=2")
    assert kw["headers"]["X-Signature"] == c._sign("GET", "/v9/orders", "a=1&b=2")
    assert "Content-Type" not in kw["headers"]


def test_post_signs_the_body_in_place_of_the_query():
    c = _client(_resp(201, {"orders": [{"id": 9, "state": "pending"}]}))
    body = {"orders": [{"seller_id": 1}]}
    assert c.create_order(body)["orders"][0]["id"] == 9
    method, url, kw = c.session.calls[0]
    payload = json.dumps(body, separators=(",", ":"))
    expected = base64.b64encode(hmac.new(b"xyz", f"POST api.ticketevolution.com/v9/orders?{payload}".encode(),
                                         hashlib.sha256).digest()).decode()
    assert (method, url) == ("POST", "https://api.ticketevolution.com/v9/orders")
    assert kw["data"] == payload.encode() and kw["headers"]["X-Signature"] == expected
    assert kw["headers"]["Content-Type"] == "application/json"


def test_accept_posts_the_reviewer():
    c = _client(_resp(200, None))
    assert c.accept_order("77", 53658) == {}
    _method, url, kw = c.session.calls[0]
    assert url.endswith("/v9/orders/77/accept") and json.loads(kw["data"]) == {"reviewer_id": 53658}
    assert c.get_order  # read helper exists
    c2 = _client(_resp(200, {"id": 77}))
    assert c2.get_order(77) == {"id": 77}


def test_write_errors_never_retry_and_say_whether_anything_happened():
    with pytest.raises(eb.EvoWriteUnknown):
        _client(requests.Timeout("t")).create_order({})
    with pytest.raises(eb.EvoWriteUnknown, match="HTTP 502"):
        _client(_resp(502, {"e": 1})).create_order({})
    with pytest.raises(eb.EvoWriteRejected) as ex:
        _client(_resp(422, {"error": "bad"})).create_order({})
    assert ex.value.status == 422 and "bad" in ex.value.detail
    with pytest.raises(requests.ConnectionError):
        _client(requests.ConnectionError("x")).get_order(1)
    with pytest.raises(eb.EvoWriteRejected):
        _client(_resp(503, None)).get_order(1)       # a failed read is a plain rejection


def test_requires_credentials_and_builds_a_default_session():
    with pytest.raises(eb.EvoBuyError):
        eb.EvoBuyClient("", "s")
    assert isinstance(eb.EvoBuyClient("t", "s").session, requests.Session)


def test_buy_order_body():
    b = eb.buy_order_body(ticket_group_id="6744480374", quantity=2, price_ea=139.05, seller_office_id=1692,
                          buyer_office_id=42029, shipment_type="TMMobile", email_address_id=10497966, note="n" * 300)
    o = b["orders"][0]
    assert o["seller_id"] == 1692 and o["buyer_id"] == 42029 and o["payments"] == [{"type": "evopay"}]
    assert o["shipped_items"] == [{"type": "TMMobile", "email_address_id": 10497966,
                                   "items": [{"ticket_group_id": 6744480374, "quantity": 2, "price": "139.05"}]}]
    assert len(o["internal_notes"]) == 250
    fedex = eb.buy_order_body(ticket_group_id=1, quantity=1, price_ea=1, seller_office_id=1, buyer_office_id=2,
                              shipment_type="FedEx", email_address_id=None, note="")
    assert fedex["orders"][0]["shipped_items"][0] == {"type": "FedEx", "service_type": "LEAST_EXPENSIVE",
                                                      "items": [{"ticket_group_id": 1, "quantity": 1,
                                                                 "price": "1.00"}]}
    assert eb.SHIPMENT_FOR_FORMAT["TM_mobile"] == "TMMobile"


def test_an_unreadable_write_response_is_unknown_and_a_read_one_raises():
    bad = SimpleNamespace(status_code=201, content=b"<html>", text="<html>", json=lambda: json.loads("<html>"))
    with pytest.raises(eb.EvoWriteUnknown, match="unreadable"):
        _client(bad).create_order({})
    bad2 = SimpleNamespace(status_code=200, content=b"<html>", text="<html>", json=lambda: json.loads("<html>"))
    with pytest.raises(ValueError):
        _client(bad2).get_order(1)
