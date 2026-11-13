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
    def __init__(self, tg=TG, create=None, quote=None):
        self.tg, self.create, self.quote, self.calls = tg, create, quote, []

    def tax_quote(self, tg_id, qty):
        self.calls.append(("quote", tg_id, qty))
        if isinstance(self.quote, Exception):
            raise self.quote
        return self.quote

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


# ---- follow: re-read a bought order until the seller confirms or rejects it ----

ORDER = {"id": 19429767, "state": "completed", "seller_state": "completed", "total": "246.17",
         "seller_rejection_reason": None,
         "items": [{"seats": [12], "quantity": 1,
                    "ticket_group": {"section": "140", "row": "13", "seats": ["12"]}}]}


class FollowRpc:
    def __init__(self, job):
        self.job, self.calls = job, []

    def __call__(self, name, params):
        self.calls.append((name, params))
        return self.job if name == "manual_sub_buy_follow_claim" else "confirmed"


class OrderClient:
    def __init__(self, order):
        self.order, self.calls = order, []

    def get_order(self, order_id):
        self.calls.append(order_id)
        if isinstance(self.order, Exception):
            raise self.order
        return self.order

    def create_order(self, body):  # pragma: no cover - a follow must never reach a write
        raise AssertionError("follow sent a buy")


def test_order_status_reads_state_total_and_real_seats():
    assert mb.order_status(ORDER) == {
        "order_state": "completed", "seller_state": "completed", "order_total_usd": "246.17",
        "bought_section": "140", "bought_row": "13", "seats": ["12"], "rejection_reason": None}
    # EVO sends 0 for a seat the seller has not assigned yet: that is "unknown", not seat 0
    pending = {"state": "pending", "seller_state": "pending",
               "items": [{"seats": [0, 0, 0, 0], "ticket_group": {"section": "134", "row": "G", "seats": []}}]}
    assert mb.order_status(pending)["seats"] == []
    # seats can sit on the ticket group only; a rejection reason is carried
    rej = {"state": "rejected", "seller_state": "rejected", "seller_rejection_reason": "Tickets sold",
           "items": [{"ticket_group": {"seats": ["7", "8"]}}]}
    got = mb.order_status(rej)
    assert got["seats"] == ["7", "8"] and got["rejection_reason"] == "Tickets sold"
    assert mb.order_status({})["seats"] == [] and mb.order_status({"items": [None]})["bought_row"] is None


def test_follow_idle_when_nothing_is_due():
    rpc, client = FollowRpc(None), OrderClient(ORDER)
    assert mb.follow(rpc, client) == {"action": "idle"}
    assert client.calls == [] and [n for n, _ in rpc.calls] == ["manual_sub_buy_follow_claim"]


def test_follow_reads_the_order_and_records_it():
    rpc, client = FollowRpc({"buy_id": 18, "buy_order_id": "19429767"}), OrderClient(ORDER)
    assert mb.follow(rpc, client) == {"action": "follow", "buy_id": 18, "buy_order_id": "19429767",
                                      "outcome": "confirmed"}
    assert client.calls == ["19429767"]
    name, params = rpc.calls[-1]
    assert name == "manual_sub_buy_follow_record" and params["p_buy_id"] == 18
    assert params["p_patch"]["seller_state"] == "completed" and params["p_patch"]["seats"] == ["12"]


@pytest.mark.parametrize("err", [EvoWriteRejected(503, "down"), requests.ConnectionError("x"), ValueError("json")])
def test_follow_read_failure_records_nothing(err):
    rpc = FollowRpc({"buy_id": 18, "buy_order_id": "19429767"})
    out = mb.follow(rpc, OrderClient(err))
    assert out["error"] == type(err).__name__ and "outcome" not in out
    assert [n for n, _ in rpc.calls] == ["manual_sub_buy_follow_claim"]


# ---------- the EVO tax quote (operator 2026-11-13), on only when the config says so ----------

QUOTE = {"tax_signature": "sig-9", "wholesale": {"price": 88.17, "subtotal": 176.34, "tax": 9.70, "total": 186.04}}
TAXED = {**CFG, "tax_quote": True}


def _taxed(**kw):
    return {"row": _row(**kw), "cfg": TAXED}


def test_no_quote_is_asked_while_the_switch_is_off():
    rpc, c = Rpc(_job(max_total_usd=1.0)), Client(quote=QUOTE)
    assert mb.tick(rpc, c)["state"] == "bought"
    assert [x[0] for x in c.calls] == ["get", "create"] and "tax_signature" not in c.calls[1][1]["orders"][0]


def test_quote_is_recorded_and_its_signature_sent_with_the_buy():
    rpc, c = Rpc(_taxed()), Client(quote=QUOTE)
    out = mb.tick(rpc, c)
    assert c.calls[1] == ("quote", 6702323811, 2)
    assert c.calls[2][1]["orders"][0]["tax_signature"] == "sig-9"
    assert rpc.records[0]["p_patch"] == {"state": "buying", "quote_tax_usd": 9.7, "quote_total_usd": 186.04}
    assert out["state"] == "bought" and out["bought_total_usd"] == 186.04 and out["bought_price_ea"] == 88.17


def test_quoted_total_within_the_ceiling_buys_and_over_it_stops():
    rpc, c = Rpc(_taxed(max_total_usd=186.04)), Client(quote=QUOTE)
    assert mb.tick(rpc, c)["state"] == "bought"
    rpc, c = Rpc(_taxed(max_total_usd=186.0)), Client(quote=QUOTE)
    out = mb.tick(rpc, c)
    assert out["state"] == "stopped" and out["reasons"] == ["total_above_ceiling"] and out["quote_total_usd"] == 186.04
    assert [x[0] for x in c.calls] == ["get", "quote"]            # nothing was bought


@pytest.mark.parametrize("quote", [
    EvoWriteRejected(403, "no"), EvoWriteUnknown("/v9/tax_quotes: HTTP 502"), requests.ConnectionError("x"),
    {}, {"tax_signature": "s", "wholesale": None}, {"tax_signature": "s", "wholesale": {"tax": "x", "total": 1}},
    {"tax_signature": "", "wholesale": {"tax": 0, "total": 10}},
    {"tax_signature": "s", "wholesale": {"tax": 0, "total": 0}},
    {"tax_signature": "s", "wholesale": {"tax": -1, "total": 10}},
])
def test_no_usable_quote_stops_a_row_with_a_ceiling_and_never_blocks_one_without(quote):
    rpc, c = Rpc(_taxed(max_total_usd=500)), Client(quote=quote)
    out = mb.tick(rpc, c)
    assert out["state"] == "stopped" and out["reasons"] == ["tax_quote_failed"]
    assert [x[0] for x in c.calls] == ["get", "quote"]
    rpc, c = Rpc(_taxed()), Client(quote=quote)                    # no ceiling: bought as before, unsigned
    out = mb.tick(rpc, c)
    assert out["state"] == "bought" and out["bought_total_usd"] == 176.34
    assert "tax_signature" not in c.calls[2][1]["orders"][0]
    assert rpc.records[0]["p_patch"] == {"state": "buying"}


# ---------- the first run is a test: EVO's answer is stored as it came, nothing else changes ----------

def _test_job(**kw):
    return {"row": _row(**kw), "cfg": {**CFG, "tax_quote_test": True}}


@pytest.mark.parametrize("quote, raw", [
    (QUOTE, {"ok": True, "response": QUOTE}),
    ({"odd": "shape"}, {"ok": True, "response": {"odd": "shape"}}),
    (EvoWriteRejected(403, "no access"), {"ok": False, "error": "EvoWriteRejected",
                                          "detail": "EVO rejected the request (403): no access"}),
    (EvoWriteUnknown("/v9/tax_quotes: HTTP 502"), {"ok": False, "error": "EvoWriteUnknown",
                                                   "detail": "/v9/tax_quotes: HTTP 502"}),
    (requests.ConnectionError("down"), {"ok": False, "error": "ConnectionError", "detail": "down"}),
])
def test_test_run_stores_the_raw_answer_and_buys_exactly_as_before(quote, raw):
    rpc, c = Rpc(_test_job(max_total_usd=1.0)), Client(quote=quote)        # a ceiling it would break: ignored
    out = mb.tick(rpc, c)
    assert [x[0] for x in c.calls] == ["get", "quote", "create"]
    assert rpc.records[0]["p_patch"] == {"state": "buying", "quote_raw": raw}
    assert "tax_signature" not in c.calls[2][1]["orders"][0]
    assert out["state"] == "bought" and out["bought_total_usd"] == 176.34


def test_test_run_truncates_a_huge_answer_and_yields_to_the_real_switch():
    rpc, c = Rpc(_test_job()), Client(quote={"blob": "x" * 9000})
    mb.tick(rpc, c)
    raw = rpc.records[0]["p_patch"]["quote_raw"]
    assert raw["ok"] and raw["truncated"] and len(raw["text"]) == 4000
    # with the real check on, the test flag does nothing
    rpc, c = Rpc({"row": _row(), "cfg": {**TAXED, "tax_quote_test": True}}), Client(quote=QUOTE)
    mb.tick(rpc, c)
    assert "quote_raw" not in rpc.records[0]["p_patch"] and c.calls[2][1]["orders"][0]["tax_signature"] == "sig-9"


# ---- GoTickets rows (operator 2026-11-13, mig 20261113300000) ------------------------------------

import gotickets_buy_client as gtb  # noqa: E402

GT_CFG = {**CFG, "gt_buyer_email": "buyer@example.test", "gt_buyer_phone": "5550100",
          "gt_billing_address": {"firstName": "A", "lastName": "B", "address1": "1 Main St", "city": "NYC",
                                 "state": "NY", "postalCode": "10001", "country": "US"},
          "gt_recipient": {"firstName": "A", "lastName": "B", "email": "buyer@example.test",
                           "phoneNumber": "5550100"},
          "gt_gift_card_ids": [28085]}
GT_LISTING = {"id": 51001, "quantity": 2, "validSplitQuantities": [2], "displayPrice": 85.0, "tax": 2.5,
              "deliveryMethods": [{"id": 7, "price": 3.0, "additionalDeliveryFeeTax": 0.5},
                                  {"id": 9, "price": 20.0, "physicalDelivery": True}]}
GT_CARDS = [{"id": 28085, "amountRemaining": 500.0}, {"id": 5, "amountRemaining": 9000.0}]
GT_TOTAL = 178.5  # 85 x 2 + 3 delivery + 2.5 x 2 tax + 0.5 delivery tax


def _gt_job(cfg=None, **kw):
    row = _row(market="gotickets", gt_event_id=9110, ticket_group_id=51001, max_price_ea=89.25)
    row.update(kw)
    return {"row": row, "cfg": GT_CFG if cfg is None else cfg}


class GtClient:
    def __init__(self, listing=GT_LISTING, own=False, cards=GT_CARDS, create=None, purchase=None, is_ready=True):
        self.listing, self.own, self.cards, self.create = listing, own, cards, create
        self.purchase, self.is_ready, self.calls = purchase, is_ready, []

    def ready(self):
        return self.is_ready

    def _answer(self, name, value, *args):
        self.calls.append((name, *args))
        if isinstance(value, Exception):
            raise value
        return value

    def get_listing(self, event_id, listing_id):
        return self._answer("listing", self.listing, event_id, listing_id)

    def is_own_listing(self, listing_id):
        return self._answer("own", self.own, listing_id)

    def get_gift_cards(self):
        return self._answer("cards", self.cards)

    def get_purchase(self, purchase_id):
        return self._answer("purchase", self.purchase, purchase_id)

    def create_order(self, body):
        return self._answer("create", self.create if self.create is not None
                            else {"id": 880001, "orderStatus": "PENDING_CONFIRMATION", "orderTotal": 178.5}, body)


def _gt_tick(job, gt):
    rpc, evo = Rpc(job), Client()
    out = mb.tick(rpc, evo, gt)
    assert evo.calls == []  # a GoTickets row never touches EVO
    return out, rpc


def test_a_gotickets_row_is_bought_once_from_gift_cards():
    gt = GtClient()
    out, rpc = _gt_tick(_gt_job(), gt)
    assert out["state"] == "bought" and out["market"] == "gotickets" and out["buy_order_id"] == "880001"
    assert out["bought_total_usd"] == GT_TOTAL and out["bought_price_ea"] == 85.0
    assert out["buy_state"] == "PENDING_CONFIRMATION"
    assert [c[0] for c in gt.calls] == ["listing", "own", "cards", "create"]
    assert gt.calls[0][1:] == (9110, 51001) and gt.calls[1][1:] == (51001,)
    body = gt.calls[3][1]
    assert body["eventId"] == 9110 and body["listingId"] == 51001 and body["quantity"] == 2
    assert body["expectedTotal"] == GT_TOTAL and body["deliveryMethodId"] == 7   # the electronic method
    assert body["giftCardIds"] == [28085] and "paymentMethodToken" not in body   # only the allowed card
    assert body["emailAddress"] == "buyer@example.test" and "buyerNotes" not in body
    states = [r["p_patch"]["state"] for r in rpc.records]
    assert states == ["buying", "bought"] and rpc.records[0]["p_patch"]["quote_total_usd"] == GT_TOTAL
    assert all(r["p_token"] == "tok-1" for r in rpc.records)


def test_a_gotickets_answer_without_a_total_records_our_own_total():
    out, _ = _gt_tick(_gt_job(), GtClient(create={"order": {"id": 5}}))
    assert out["state"] == "bought" and out["buy_order_id"] == "5" and out["bought_total_usd"] == GT_TOTAL


@pytest.mark.parametrize("gt, reason", [
    (None, "no_gt_buy_client"),
    (GtClient(is_ready=False), "no_gt_buy_client"),
    (GtClient(listing=None), "listing_gone"),
    (GtClient(listing=gtb.GoTicketsBuyError("x")), "listing_read_failed"),
    (GtClient(listing=EvoWriteRejected(404, "x")), "listing_read_failed"),
    (GtClient(own=True), "our_own_listing"),
    (GtClient(own=gtb.GoTicketsBuyError("x")), "own_listing_check_failed"),
    (GtClient(listing={**GT_LISTING, "quantity": 1}), "short_quantity"),
    (GtClient(listing={**GT_LISTING, "validSplitQuantities": [1, 3]}), "split_not_allowed"),
    (GtClient(listing={**GT_LISTING, "deliveryMethods": [{"id": 9, "physicalDelivery": True}]}), "no_electronic_delivery"),
    (GtClient(listing={**GT_LISTING, "displayPrice": None}), "price_unknown"),
    (GtClient(listing={**GT_LISTING, "displayPrice": 85.01}), "price_above_ceiling"),
    (GtClient(cards=gtb.GoTicketsBuyError("x")), "gift_card_read_failed"),
    (GtClient(cards=[{"id": 28085, "amountRemaining": 100.0}, {"id": 5, "amountRemaining": 9000.0}]),
     "gift_card_balance_short"),
])
def test_gotickets_checks_stop_the_row_before_anything_is_sent(gt, reason):
    out, rpc = _gt_tick(_gt_job(), gt)
    assert out["state"] == "stopped" and out["reasons"] == [reason]
    assert [r["p_patch"]["state"] for r in rpc.records] == ["stopped"]
    assert gt is None or "create" not in [c[0] for c in gt.calls]


@pytest.mark.parametrize("patch, reason", [
    ({"cfg": {**GT_CFG, "gt_buyer_phone": None}}, "gt_buyer_profile_missing"),
    ({"cfg": {**GT_CFG, "gt_billing_address": {"firstName": "A"}}}, "gt_buyer_profile_missing"),
    ({"cfg": {**GT_CFG, "gt_recipient": None}}, "gt_buyer_profile_missing"),
    ({"gt_event_id": None}, "no_gt_event_id"),
    ({"max_total_usd": 178.0}, "total_above_ceiling"),
])
def test_gotickets_row_and_config_problems_stop_the_row(patch, reason):
    gt = GtClient()
    out, _ = _gt_tick(_gt_job(**patch), gt)
    assert out["state"] == "stopped" and out["reasons"] == [reason]
    assert "create" not in [c[0] for c in gt.calls]


def test_a_gotickets_total_at_the_ceiling_buys_and_a_listing_without_a_split_list_too():
    gt = GtClient(listing={**GT_LISTING, "validSplitQuantities": None})
    out, _ = _gt_tick(_gt_job(max_total_usd=178.5), gt)
    assert out["state"] == "bought"


def test_gotickets_lost_lease_sends_nothing():
    gt = GtClient()
    rpc = Rpc(_gt_job(), lost={"buying"})
    assert mb.tick(rpc, Client(), gt) == {"action": "buy", "buy_id": 3, "market": "gotickets", "state": "lease_lost"}
    assert "create" not in [c[0] for c in gt.calls]


def test_gotickets_rejected_buy_stops_and_an_unclear_one_is_unknown():
    out, _ = _gt_tick(_gt_job(), GtClient(create=EvoWriteRejected(422, "no")))
    assert out["state"] == "stopped" and out["reasons"] == ["buy_failed"]
    out, _ = _gt_tick(_gt_job(), GtClient(create=EvoWriteUnknown("timeout")))
    assert out["state"] == "unknown" and out["reasons"] == ["buy_unknown"]
    # the buy went out but the answer names no purchase: unknown, never a silent success
    out, rpc = _gt_tick(_gt_job(), GtClient(create={"orderStatus": "PENDING_CONFIRMATION"}))
    assert out["state"] == "unknown" and "no purchase id" in out["error"]
    assert [r["p_patch"]["state"] for r in rpc.records] == ["buying", "unknown"]


def test_gt_purchase_status_maps_the_seller_state_from_the_allowlist():
    assert mb.gt_purchase_status({"orderStatus": "MOBILE_QR_DELIVERED", "orderTotal": 178.5}) == {
        "order_state": "MOBILE_QR_DELIVERED", "seller_state": "accepted", "order_total_usd": 178.5}
    assert mb.gt_purchase_status({"orderStatus": "REFUNDED"})["seller_state"] == "rejected"
    assert mb.gt_purchase_status({"orderStatus": "PENDING_CONFIRMATION"})["seller_state"] is None
    assert mb.gt_purchase_status({"orderStatus": "SOMETHING_NEW"})["seller_state"] is None   # never 'accepted'
    assert mb.gt_purchase_status({}) == {"order_state": None, "seller_state": None, "order_total_usd": None}


def test_follow_asks_gotickets_for_a_gotickets_purchase():
    job = {"buy_id": 3, "buy_order_id": "880001", "market": "gotickets"}
    rpc, evo = FollowRpc(job), OrderClient(ORDER)
    gt = GtClient(purchase={"orderStatus": "TRANSFER_COMPLETED", "orderTotal": 178.5})
    out = mb.follow(rpc, evo, gt)
    assert out["outcome"] == "confirmed" and evo.calls == [] and gt.calls == [("purchase", "880001")]
    assert rpc.calls[1] == ("manual_sub_buy_follow_record", {"p_buy_id": 3, "p_patch": {
        "order_state": "TRANSFER_COMPLETED", "seller_state": "accepted", "order_total_usd": 178.5}})


@pytest.mark.parametrize("gt, err", [
    (None, "no_gt_buy_client"),
    (GtClient(is_ready=False), "no_gt_buy_client"),
    (GtClient(purchase=gtb.GoTicketsBuyError("x")), "GoTicketsBuyError"),
    (GtClient(purchase=EvoWriteRejected(404, "x")), "EvoWriteRejected"),
])
def test_follow_of_a_gotickets_purchase_that_cannot_be_read_records_nothing(gt, err):
    rpc = FollowRpc({"buy_id": 3, "buy_order_id": "880001", "market": "gotickets"})
    assert mb.follow(rpc, OrderClient(ORDER), gt)["error"] == err
    assert [n for n, _ in rpc.calls] == ["manual_sub_buy_follow_claim"]
