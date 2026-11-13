"""GoTickets sub offer: the path-pinned client and the worker (operator 2026-11-13)."""
from types import SimpleNamespace

import pytest
import requests

import gotickets_sub_client as gc
from core import gt_sub_offer as w
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


def _resp(status=200, data=None, text=""):
    return SimpleNamespace(status_code=status, text=text, json=lambda: data)


def _client(*responses):
    return gc.GoTicketsSubClient("gid", "gsec", session=FakeSession(*responses))


# ------------------------------------------------------------------ client

def test_guard_allows_reads_and_only_the_substitution_request():
    g = gc._assert_readonly_method
    g("GET", "https://sc.gotickets.com/rest/sales/1")
    g("get", "https://sc.gotickets.com/rest/substitution-requests")
    g("POST", "https://sc.gotickets.com/rest/substitution-requests")
    for m, u in (("POST", "https://sc.gotickets.com/rest/substitution-requests/5/cancel"),
                 ("POST", "https://sc.gotickets.com/rest/sales/1/reject"),
                 ("POST", "https://sc.gotickets.com/rest/sales/1/modify-fulfillment"),
                 ("POST", "https://sc.gotickets.com/rest/listings"),
                 ("PUT", "https://sc.gotickets.com/rest/listings/1"),
                 ("DELETE", "https://sc.gotickets.com/rest/listings/1"),
                 ("GET", "https://evil.example/rest/sales/1"),
                 ("GET", "http://sc.gotickets.com/rest/sales/1"),
                 ("POST", "https://pro.gotickets.com/rest/substitution-requests")):
        with pytest.raises(gc.GoTicketsSubError):
            g(m, u)


def test_client_reads_and_sends_with_the_seller_headers():
    c = _client(_resp(data={"id": 9, "sellerStatus": "PENDING_FULFILLMENT"}), _resp(data=[{"id": 1}, "junk"]),
                _resp(data={"oops": 1}), _resp(data={"id": 77, "status": "PENDING"}), _resp(data=None))
    assert c.ready() and not gc.GoTicketsSubClient(None, "x").ready()
    assert c.get_sale("9")["sellerStatus"] == "PENDING_FULFILLMENT"
    assert c.list_requests(9) == [{"id": 1}] and c.list_requests(9) == []
    assert c.create_request({"orderId": 9})["id"] == 77
    method, url, kw = c.session.calls[3]
    assert (method, url) == ("POST", "https://sc.gotickets.com/rest/substitution-requests")
    assert kw["headers"]["X-Api-Access-Id"] == "gid" and kw["json"] == {"orderId": 9}
    assert c.session.calls[1][2]["params"] == {"saleId": 9}
    with pytest.raises(ValueError):
        c.create_request({})
    assert _client(_resp(data=None)).get_sale(1) == {}


def test_client_maps_failures_without_leaking_the_request():
    with pytest.raises(EvoWriteRejected):
        _client(_resp(404, text="nope")).get_sale(1)
    with pytest.raises(gc.GoTicketsSubError) as e:
        _client(requests.ConnectionError("https://sc.gotickets.com/secret")).get_sale(1)
    assert "secret" not in str(e.value)
    with pytest.raises(EvoWriteUnknown):
        _client(requests.Timeout("t")).create_request({})
    with pytest.raises(EvoWriteUnknown):
        _client(_resp(503)).create_request({})
    with pytest.raises(EvoWriteRejected):
        _client(_resp(400, text="bad")).create_request({})


# ------------------------------------------------------------------ worker

ROW = {"offer_id": 4, "lease_token": "tok", "gt_order_id": 1001, "section": "102", "seat_row": "4", "qty": 2,
       "notes": "note", "rebate_amount": 60}
SALE = {"id": 1001, "sellerStatus": "PENDING_FULFILLMENT", "quantity": 2, "orderItemId": 55}


class Rpc:
    def __init__(self, claim=None, follow=None, lease_ok=True):
        self.claim, self.follow_job, self.lease_ok, self.calls = claim, follow, lease_ok, []

    def __call__(self, name, args):
        self.calls.append((name, args))
        if name == "sub_finder_gt_offer_claim":
            return self.claim
        if name == "sub_finder_gt_offer_follow_claim":
            return self.follow_job
        if name == "sub_finder_gt_offer_record":
            return args["p_patch"]["state"] if self.lease_ok else "lease_lost"
        return args["p_patch"].get("gt_status")

    def patches(self):
        return [a["p_patch"] for n, a in self.calls if n == "sub_finder_gt_offer_record"]


class Client:
    def __init__(self, sale=None, existing=None, made=None):
        self.sale, self.existing, self.made, self.sent = sale, existing or [], made, []

    def get_sale(self, _id):
        if isinstance(self.sale, Exception):
            raise self.sale
        return self.sale

    def list_requests(self, _id):
        if isinstance(self.existing, Exception):
            raise self.existing
        return self.existing

    def create_request(self, body):
        self.sent.append(body)
        if isinstance(self.made, Exception):
            raise self.made
        return self.made


def test_tick_idle_and_happy_path_sends_once_with_rebate():
    assert w.tick(Rpc(), Client()) == {"action": "idle"}
    rpc, c = Rpc(claim=ROW), Client(SALE, [{"id": 1, "status": "DENIED"}], {"id": 900, "status": "PENDING"})
    out = w.tick(rpc, c)
    assert out["state"] == "sent" and out["gt_request_id"] == 900 and out["offer_id"] == 4
    assert c.sent == [{"orderId": 1001, "section": "102", "row": "4", "notes": "note",
                       "source": "SELLER_CENTRAL_API", "orderItemId": 55, "rebateAmount": 60.0}]
    assert [p["state"] for p in rpc.patches()] == ["sending", "sent"]
    assert rpc.calls[1][1]["p_token"] == "tok"


def test_offer_body_leaves_out_what_is_not_there():
    body = w.offer_body({**ROW, "rebate_amount": None, "notes": None}, {})
    assert body == {"orderId": 1001, "section": "102", "row": "4", "notes": "", "source": "SELLER_CENTRAL_API"}
    assert "rebateAmount" not in w.offer_body({**ROW, "rebate_amount": 0}, {})


@pytest.mark.parametrize("sale,existing,reason", [
    ({**SALE, "cancelReason": "CANCELLED"}, [], "sale_cancelled"),
    ({**SALE, "fulfilled": True}, [], "sale_already_delivered"),
    ({**SALE, "sellerStatus": "COMPLETED"}, [], "sale_already_delivered"),
    ({**SALE, "quantity": 3}, [], "quantity_differs"),
    (SALE, [{"id": 1, "status": "CUSTOMER_REVIEW"}], "request_already_open"),
])
def test_tick_stops_before_sending_when_the_fresh_read_says_no(sale, existing, reason):
    rpc, c = Rpc(claim=ROW), Client(sale, existing, {"id": 1})
    out = w.tick(rpc, c)
    assert out["state"] == "stopped" and out["reasons"] == [reason] and c.sent == []
    assert w.sale_checks({"quantity": None}, [], qty=None) == []


def test_tick_read_failures_send_nothing():
    for sale, reason in ((EvoWriteRejected(404, "x"), "sale_not_found"), (gc.GoTicketsSubError("x"), "sale_read_failed"),
                         (requests.ConnectionError("x"), "sale_read_failed")):
        c = Client(sale)
        out = w.tick(Rpc(claim=ROW), c)
        assert out["reasons"] == [reason] and c.sent == []


def test_tick_lease_lost_refused_and_unknown():
    c = Client(SALE, [], {"id": 1})
    assert w.tick(Rpc(claim=ROW, lease_ok=False), c)["state"] == "lease_lost" and c.sent == []
    out = w.tick(Rpc(claim=ROW), Client(SALE, [], EvoWriteRejected(400, "no")))
    assert out["state"] == "stopped" and out["reasons"] == ["offer_refused"]
    for made in (EvoWriteUnknown("t"), ValueError("bad json"), {"status": "PENDING"}):
        out = w.tick(Rpc(claim=ROW), Client(SALE, [], made))
        assert out["state"] == "unknown" and out["reasons"] == ["offer_unknown"]


def test_follow_reads_the_request_status():
    assert w.follow(Rpc(), Client()) == {"action": "idle"}
    job = {"offer_id": 4, "gt_order_id": 1001, "gt_request_id": 900}
    rpc = Rpc(follow=job)
    out = w.follow(rpc, Client(existing=[{"id": 1, "status": "DENIED"},
                                         {"id": 900, "status": "DENIED", "denialReason": "CUSTOMER_REJECTED"}]))
    assert out == {"action": "follow", "offer_id": 4, "status": "DENIED"}
    assert rpc.calls[-1] == ("sub_finder_gt_offer_follow_record",
                             {"p_offer_id": 4, "p_patch": {"gt_status": "DENIED", "denial_reason": "CUSTOMER_REJECTED"}})
    assert w.follow(Rpc(follow=job), Client(existing=[]))["error"] == "request_not_listed"
    assert w.follow(Rpc(follow=job), Client(existing=requests.Timeout("t")))["error"] == "Timeout"


# ---------- a denied offer: the sale is read before the order is polled again ----------

@pytest.mark.parametrize("sale, extra", [
    ({"quantity": 2}, {"sale_checked": True}),                                             # still live
    ({"cancelReason": "BUYER"}, {"sale_checked": True, "sale_closed": "cancelled"}),
    ({"fulfilled": True}, {"sale_checked": True, "sale_closed": "fulfilled"}),
    ({"sellerStatus": "COMPLETED"}, {"sale_checked": True, "sale_closed": "fulfilled"}),
    (requests.Timeout("t"), {}),                                                           # unread: DB decides
    (None, {}),
])
def test_follow_reads_the_sale_when_the_offer_ended_without_a_sub(sale, extra):
    job = {"offer_id": 4, "gt_order_id": 1001, "gt_request_id": 900}
    for status in ("DENIED", "cancelled"):
        rpc = Rpc(follow=job)
        w.follow(rpc, Client(sale=sale, existing=[{"id": 900, "status": status}]))
        assert rpc.calls[-1][1]["p_patch"] == {"gt_status": status, "denial_reason": None, **extra}


def test_follow_does_not_read_the_sale_for_other_statuses():
    class NoSale(Client):
        def get_sale(self, _id):
            raise AssertionError("the sale is read only after a denial or cancellation")

    job = {"offer_id": 4, "gt_order_id": 1001, "gt_request_id": 900}
    for status in ("PENDING", "ACCEPTED", None):
        rpc = Rpc(follow=job)
        w.follow(rpc, NoSale(existing=[{"id": 900, "status": status}]))
        assert rpc.calls[-1][1]["p_patch"] == {"gt_status": status, "denial_reason": None}
