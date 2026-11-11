"""MANUAL sub buy worker — one operator-chosen EVO listing, bought once, never retried."""
import pytest
import requests

import core.manual_sub_buy as mb
from evo_buy_client import EvoWriteRejected, EvoWriteUnknown

CFG = {"evo_buyer_office_id": 42029, "evo_email_address_id": 10497966}
TG = {"id": 6702323811, "available_quantity": 2, "splits": [2], "owned": False, "format": "TM_mobile",
      "wholesale_price": 88.17, "office": {"id": 1692, "brokerage": {"id": 1700}}}


def _row(**kw):
    r = {"buy_id": 3, "sale_site": "Vivid Seats", "sale_order_number": "82393067", "ticket_group_id": 6702323811,
         "qty": 2, "max_price_ea": 88.17, "requested_by": "operator", "lease_token": "tok-1"}
    r.update(kw)
    return r


class Rpc:
    """Fake DB: record echoes the state unless `lost` names states it refuses or `boom` raises on them."""

    def __init__(self, job, lost=(), boom=()):
        self.job, self.records, self.lost, self.boom = job, [], set(lost), set(boom)

    def __call__(self, name, params):
        if name == "manual_sub_buy_claim":
            return self.job
        assert name == "manual_sub_buy_record"
        state = params["p_patch"]["state"]
        if state in self.boom:
            raise RuntimeError("db blip")
        self.records.append(params)
        return "lease_lost" if state in self.lost else state


class Client:
    def __init__(self, tg=TG, create=None):
        self.tg, self.create, self.calls = tg, create, []

    def get_ticket_group(self, tg_id):
        self.calls.append(("get", tg_id))
        if isinstance(self.tg, Exception):
            raise self.tg
        return self.tg

    def create_order(self, body):
        self.calls.append(("create", body))
        if isinstance(self.create, Exception):
            raise self.create
        return self.create if self.create is not None else {"orders": [{"id": 991, "state": "pending"}]}


def _job(**kw):
    return {"row": _row(**kw), "cfg": CFG}


def test_idle_when_nothing_is_claimed():
    c = Client()
    assert mb.tick(Rpc(None), c) == {"action": "idle"}
    assert c.calls == []


def test_buys_once_and_records_the_order():
    rpc, c = Rpc(_job()), Client()
    out = mb.tick(rpc, c)
    assert out["state"] == "bought" and out["buy_order_id"] == "991" and out["bought_total_usd"] == 176.34
    assert [k for k, _ in c.calls] == ["get", "create"]
    body = c.calls[1][1]["orders"][0]
    assert body["buyer_id"] == 42029 and body["seller_id"] == 1692 and body["payments"] == [{"type": "evopay"}]
    assert body["shipped_items"][0]["items"] == [{"ticket_group_id": 6702323811, "quantity": 2, "price": "88.17"}]
    assert "Vivid Seats sale 82393067" in body["internal_notes"] and "N2S" not in body["internal_notes"]
    assert [r["p_patch"]["state"] for r in rpc.records] == ["buying", "bought"]
    assert all(r["p_token"] == "tok-1" and r["p_buy_id"] == 3 for r in rpc.records)


def test_a_bare_order_response_is_read_too():
    out = mb.tick(Rpc(_job()), Client(create={"id": 5, "state": "pending"}))
    assert out["state"] == "bought" and out["buy_order_id"] == "5"


@pytest.mark.parametrize("patch,reason", [
    ({"owned": True}, "our_own_listing"),
    ({"office": {"id": 3, "brokerage": {"id": mb.OUR_BROKERAGE_ID}}}, "our_own_listing"),
    ({"available_quantity": 1}, "short_quantity"),
    ({"available_quantity": None}, "short_quantity"),
    ({"splits": [1, 4], "available_quantity": 4}, "split_not_allowed"),
    ({"wholesale_price": 88.5}, "price_above_ceiling"),
    ({"wholesale_price": None}, "price_above_ceiling"),
    ({"format": "Carrier_pigeon"}, "unknown_format"),
    ({"office": None}, "no_seller_office"),
])
def test_listing_checks_stop_the_buy(patch, reason):
    rpc, c = Rpc(_job()), Client(tg={**TG, **patch})
    out = mb.tick(rpc, c)
    assert out["state"] == "stopped" and reason in out["reasons"]
    assert [k for k, _ in c.calls] == ["get"]          # nothing was sent


def test_a_cheaper_listing_and_no_split_list_still_buy():
    out = mb.tick(Rpc(_job()), Client(tg={**TG, "wholesale_price": 80, "splits": None}))
    assert out["state"] == "bought" and out["bought_price_ea"] == 80.0


def test_no_judgement_rules_run():
    """Outside the N2S conditions: no profit, lead-time or view rule can stop an operator's buy."""
    tg = {**TG, "event": {"occurs_at": "2020-01-01T00:00:00Z"}, "public_notes": "Obstructed View"}
    assert mb.tick(Rpc(_job(sold_ea=1.0)), Client(tg=tg))["state"] == "bought"


def test_listing_gone_and_read_failure_stop_without_sending():
    for tg, reason in ((EvoWriteRejected(404, "not found"), "listing_gone"),
                       (requests.ConnectionError("x"), "listing_read_failed")):
        rpc, c = Rpc(_job()), Client(tg=tg)
        out = mb.tick(rpc, c)
        assert out["state"] == "stopped" and out["reasons"] == [reason]
        assert [k for k, _ in c.calls] == ["get"]


def test_lost_lease_sends_nothing():
    rpc, c = Rpc(_job(), lost={"buying"}), Client()
    assert mb.tick(rpc, c)["state"] == "lease_lost"
    assert [k for k, _ in c.calls] == ["get"]


def test_rejected_buy_stops_and_unknown_outcome_is_recorded_unknown():
    out = mb.tick(Rpc(_job()), Client(create=EvoWriteRejected(422, "no")))
    assert out["state"] == "stopped" and out["reasons"] == ["buy_failed"]
    rpc, c = Rpc(_job()), Client(create=EvoWriteUnknown("/v9/orders: HTTP 502"))
    out = mb.tick(rpc, c)
    assert out["state"] == "unknown" and out["reasons"] == ["buy_unknown"]
    assert [k for k, _ in c.calls] == ["get", "create"]   # never retried


def test_a_sent_buy_with_an_unreadable_answer_is_unknown():
    out = mb.tick(Rpc(_job()), Client(create={"orders": [{"state": "pending"}]}))
    assert out["state"] == "unknown" and "no order id" in out["error"]
    out = mb.tick(Rpc(_job(), boom={"bought"}), Client())
    assert out["state"] == "unknown" and "db blip" in out["error"]
