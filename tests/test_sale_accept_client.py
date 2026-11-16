"""sale_accept_client — confirm our own pending sale on GoTickets / SeatGeek / Vivid (operator 2026-11-10)."""
from types import SimpleNamespace

import pytest
import requests

import sale_accept_client as sa
from evo_buy_client import EvoWriteRejected, EvoWriteUnknown


class FakeSession:
    def __init__(self, *responses):
        self.responses, self.calls = list(responses), []

    def request(self, method, url, **kw):
        self.calls.append((method, url, kw))
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def _resp(status=200, text="", data=None):
    return SimpleNamespace(status_code=status, text=text, json=lambda: data)


def _client(*responses, **creds):
    creds = {"gt_id": "gid", "gt_secret": "gsec", "sg_token": "sgt", "vivid_token": "vvt", **creds}
    return sa.SaleAcceptClient(session=FakeSession(*responses), **creds)


def test_guard_allows_reads_and_only_the_three_confirms():
    g = sa._assert_readonly_method
    g("GET", "https://sc.gotickets.com/rest/sales/1")
    g("GET", "https://brokers.vividseats.com/webservices/v1/getOrder")
    g("POST", "https://sc.gotickets.com/rest/sales/123/confirm")
    g("patch", "https://sellerdirect-api.seatgeek.com/order")
    g("POST", "https://brokers.vividseats.com/webservices/v1/confirmOrder")
    for m, u in (("POST", "https://sc.gotickets.com/rest/sales/123/reject"),
                 ("POST", "https://sc.gotickets.com/rest/pro/api/orders"),
                 ("POST", "https://brokers.vividseats.com/webservices/v1/rejectOrder"),
                 ("PATCH", "https://sc.gotickets.com/rest/sales/123/confirm"),
                 ("POST", "https://sellerdirect-api.seatgeek.com/order"),
                 ("PUT", "https://sellerdirect-api.seatgeek.com/v3/order"),
                 ("DELETE", "https://sc.gotickets.com/rest/sales/1"),
                 ("GET", "https://api.ticketevolution.com/v9/orders"),
                 ("GET", "http://sc.gotickets.com/rest/sales/1")):
        with pytest.raises(sa.SaleAcceptError):
            g(m, u)
    assert sa.ALLOWED_HTTP_METHODS == frozenset({"GET", "PATCH", "POST"})


def test_has_market():
    c = sa.SaleAcceptClient(gt_id="a", sg_token="t")
    assert (c.has_market("gotickets"), c.has_market("seatgeek"), c.has_market("vivid"), c.has_market("x")) == \
        (False, True, False, False)
    assert isinstance(c.session, requests.Session)


def test_sale_state_reads_each_market_like_the_order_timer():
    c = _client(_resp(data={"sellerStatus": "UNCONFIRMED"}), _resp(data={"status": "submitted"}),
                _resp(text="<order><status>UNCONFIRMED</status></order>"), _resp(text="<order/>"))
    assert c.sale_state("gotickets", "77") == "UNCONFIRMED"
    assert c.sale_state("seatgeek", "ab12") == "submitted"
    assert c.sale_state("vivid", 9) == "UNCONFIRMED"
    assert c.sale_state("vivid", 9) is None
    (m1, u1, k1), (m2, u2, k2), (m3, u3, k3), _ = c.session.calls
    assert u1 == "https://sc.gotickets.com/rest/sales/77" and k1["headers"]["X-Api-Access-Id"] == "gid"
    assert k2["params"] == {"order_id": "ab12"} and k2["headers"] == {"token": "sgt"}
    assert k3["params"] == {"apiToken": "vvt", "orderId": "9"}
    assert all(m == "GET" for m, _, _ in c.session.calls)
    with pytest.raises(sa.SaleAcceptError):
        c.sale_state("stubhub", 1)


def test_accept_sends_one_pinned_write_per_market():
    c = _client(_resp(200, "{}"), _resp(200, '{"status":"confirmed"}'), _resp(200, "<response><success>true</success></response>"))
    assert c.accept("gotickets", "77")["state"] == "accepted"
    assert c.accept("seatgeek", "ab12")["http"] == 200
    assert c.accept("vivid", 9)["state"] == "accepted"
    (m1, u1, k1), (m2, u2, k2), (m3, u3, k3) = c.session.calls
    assert (m1, u1) == ("POST", "https://sc.gotickets.com/rest/sales/77/confirm")
    assert (m2, u2) == ("PATCH", "https://sellerdirect-api.seatgeek.com/order")
    assert k2["files"] == {"order_id": (None, "ab12"), "status": (None, "confirmed")}
    assert (m3, u3) == ("POST", "https://brokers.vividseats.com/webservices/v1/confirmOrder")
    assert k3["data"] == {"apiToken": "vvt", "orderId": "9", "shipNow": "false"}
    with pytest.raises(sa.SaleAcceptError):
        c.accept("stubhub", 1)


def test_write_failures_never_retry():
    with pytest.raises(EvoWriteRejected):
        _client(_resp(200, "<response><success>false</success><message>late</message></response>")).accept("vivid", 1)
    with pytest.raises(EvoWriteRejected):
        _client(_resp(409, "already confirmed")).accept("gotickets", 1)
    with pytest.raises(EvoWriteUnknown):
        _client(_resp(502, "")).accept("seatgeek", "x")
    with pytest.raises(EvoWriteUnknown):
        _client(requests.Timeout()).accept("gotickets", 1)
    leak = requests.ConnectionError("GET https://brokers.vividseats.com/webservices/v1/getOrder?apiToken=SECRET")
    with pytest.raises(sa.SaleAcceptError) as ex:
        _client(leak).sale_state("vivid", 1)
    assert "SECRET" not in str(ex.value) and ex.value.__cause__ is None and ex.value.__suppress_context__
    assert str(ex.value) == "/webservices/v1/getOrder: ConnectionError"
    with pytest.raises(EvoWriteUnknown) as ex:
        _client(requests.Timeout("https://brokers.vividseats.com/x?apiToken=SECRET")).accept("vivid", 1)
    assert "SECRET" not in str(ex.value) and ex.value.__suppress_context__
    with pytest.raises(EvoWriteRejected):
        _client(_resp(503, "")).sale_state("seatgeek", "x")  # a failed read is a plain rejection


def test_tickpick_guard_allows_only_the_confirm():
    g = sa._assert_readonly_method
    g("GET", "https://api.tickpick.com/1.0/orders/1074266885")
    g("POST", "https://api.tickpick.com/1.0/orders/1074266885/confirmation")
    for m, u in (("POST", "https://api.tickpick.com/1.0/token"),          # login lives in plpgsql only
                 ("POST", "https://api.tickpick.com/1.0/orders/1/rejection"),
                 ("POST", "https://api.tickpick.com/1.0/orders/abc/confirmation"),
                 ("PUT", "https://api.tickpick.com/1.0/orders/1/confirmation"),
                 ("PATCH", "https://api.tickpick.com/1.0/listings/1"),
                 ("POST", "https://api.tickpick.com/1.0/orders/1/confirmation/x"),
                 ("POST", "https://api.tickpick.com/1x0/orders/1/confirmation")):
        with pytest.raises(sa.SaleAcceptError):
            g(m, u)


def test_tickpick_token_is_read_on_every_use():
    toks = iter(["t1", "t2", None])
    c = _client(_resp(data={"seller_status": "Unconfirmed"}), _resp(200, ""), tickpick_token=lambda: next(toks))
    assert c.sale_state("tickpick", "1074266885") == "Unconfirmed"
    assert c.accept("tickpick", 1074266885) == {"state": "accepted", "http": 200, "body": ""}
    assert not c.has_market("tickpick")
    (m1, u1, k1), (m2, u2, k2) = c.session.calls
    assert (m1, u1) == ("GET", "https://api.tickpick.com/1.0/orders/1074266885")
    assert k1["headers"] == {"Authorization": "Bearer t1", "Accept": "application/json"}
    assert (m2, u2) == ("POST", "https://api.tickpick.com/1.0/orders/1074266885/confirmation")
    assert k2["headers"]["Authorization"] == "Bearer t2" and k2["json"] == {}
    assert _client(tickpick_token="fixed").has_market("tickpick") and not _client().has_market("tickpick")


def test_tickpick_lapsed_sale_is_a_rejection_never_a_retry():
    with pytest.raises(EvoWriteRejected):
        _client(_resp(404, "Not Found"), tickpick_token="t").accept("tickpick", 1)
    with pytest.raises(EvoWriteUnknown):
        _client(requests.Timeout(), tickpick_token="t").accept("tickpick", 1)
    with pytest.raises(EvoWriteRejected):
        _client(_resp(404, ""), tickpick_token="t").sale_state("tickpick", 1)


# ---------- TickPick through the database (operator 2026-11-16; mig 20261116181000) ----------

class FakeDb:
    """(rpc name, params) -> each answer in turn; an Exception answer is raised."""
    def __init__(self, *answers):
        self.answers, self.calls = list(answers), []

    def __call__(self, name, params):
        self.calls.append((name, params))
        a = self.answers.pop(0)
        if isinstance(a, Exception):
            raise a
        return a


def _db_client(*answers):
    db = FakeDb(*answers)
    return _client(tickpick_token="t", tickpick_db=db), db


def test_tickpick_db_read_never_goes_out_from_the_web_service():
    c, db = _db_client({"http": 200, "seller_status": "Unconfirmed", "order_status": "UNCONFIRMED", "error": None})
    assert c.sale_state("tickpick", "1074350318") == "Unconfirmed"
    assert db.calls == [("n2s_tickpick_sale_state", {"p_order_number": "1074350318"})]
    assert c.session.calls == []                                   # nothing sent from here


def test_tickpick_db_read_failures_carry_tickpicks_answer():
    c, _ = _db_client({"http": 403, "error": "IP not allowed"})
    with pytest.raises(EvoWriteRejected) as e:
        c.sale_state("tickpick", 1)
    assert (e.value.status, e.value.detail) == (403, "IP not allowed")
    for answer, text in (({"http": -1, "error": "Operation timed out"}, "HTTP -1: Operation timed out"),
                         ({"http": 0, "error": "no_token"}, "HTTP 0: no_token"),
                         ({"http": 502, "error": None}, "HTTP 502: "),
                         (None, "HTTP None: ")):
        c, _ = _db_client(answer)
        with pytest.raises(sa.SaleAcceptError, match=text):
            c.sale_state("tickpick", 1)
    c, _ = _db_client(RuntimeError("Server disconnected"))
    with pytest.raises(sa.SaleAcceptError, match="via the database: RuntimeError"):
        c.sale_state("tickpick", 1)


def test_tickpick_db_confirm_sends_the_row_and_its_lease():
    c, db = _db_client({"http": 200, "body": ""})
    assert c.accept("tickpick", "1074350318", exec_id=8, lease_token="tok-1") == \
        {"state": "accepted", "http": 200, "body": ""}
    assert db.calls == [("n2s_tickpick_confirm",
                         {"p_exec_id": 8, "p_token": "tok-1", "p_order_number": "1074350318"})]
    assert c.session.calls == []
    c, db = _db_client({"http": 200, "body": "{}", "repeat": True})   # a retried call: the first answer
    assert c.accept("tickpick", 1, exec_id=8, lease_token="tok-1")["http"] == 200


def test_tickpick_db_confirm_needs_the_row_and_lease():
    for kw in ({}, {"exec_id": 8}, {"lease_token": "tok-1"}, {"exec_id": 8, "lease_token": ""}):
        c, db = _db_client()
        with pytest.raises(sa.SaleAcceptError):
            c.accept("tickpick", 1, **kw)
        assert db.calls == []


def test_tickpick_db_confirm_outcomes():
    c, _ = _db_client({"refused": "row_not_held"})                   # the DB sent nothing
    with pytest.raises(EvoWriteRejected) as e:
        c.accept("tickpick", 1, exec_id=8, lease_token="tok-1")
    assert (e.value.status, e.value.detail) == (409, "not sent: row_not_held")
    c, _ = _db_client({"http": 422, "body": "already confirmed"})
    with pytest.raises(EvoWriteRejected) as e:
        c.accept("tickpick", 1, exec_id=8, lease_token="tok-1")
    assert (e.value.status, e.value.detail) == (422, "already confirmed")
    # sent but no readable answer, a 5xx, a failure in flight (also on a repeat), or no answer: unknown
    for answer in ({"http": 503, "body": ""}, {"http": -1, "body": "timeout"},
                   {"http": -1, "body": "timeout", "repeat": True}, {"http": None}, None, [],
                   RuntimeError("Server disconnected")):
        c, _ = _db_client(answer)
        with pytest.raises(EvoWriteUnknown):
            c.accept("tickpick", 1, exec_id=8, lease_token="tok-1")


def test_without_tickpick_db_the_direct_calls_are_unchanged():
    c = _client(_resp(data={"seller_status": "Unconfirmed"}), _resp(200, ""), tickpick_token="t")
    assert c.sale_state("tickpick", 5) == "Unconfirmed"
    assert c.accept("tickpick", 5, exec_id=8, lease_token="tok-1")["http"] == 200
    assert [k[0] for k in c.session.calls] == ["GET", "POST"]
