"""N2S auto-buy LIVE on GoTickets (operator 2026-11-13): the path-pinned client and the worker's
GoTickets steps — buy once from gift cards, follow the purchase, accept the sale; never retry."""
import base64
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
import requests

import core.n2s_autobuy_live as lv
import gotickets_buy_client as gtb
from evo_buy_client import EvoWriteRejected, EvoWriteUnknown


@pytest.fixture(autouse=True)
def _no_verify_pause(monkeypatch):
    monkeypatch.setattr(lv, "VERIFY_DELAY_S", 0)


NOW = datetime(2026, 11, 10, 18, 0, tzinfo=timezone.utc)
PROFILE = {"gt_buyer_email": "ops@example.com", "gt_buyer_phone": "555-0100",
           "gt_billing_address": {"firstName": "A", "lastName": "B", "address1": "1 Main St", "city": "New York",
                                  "state": "NY", "postalCode": "10001", "country": "US"},
           "gt_recipient": {"firstName": "A", "lastName": "B", "email": "ops@example.com", "phoneNumber": "555-0100"}}
CFG = {"per_order_cap_usd": 666, "daily_cap_usd": 666, "max_buys_per_day": 3, "max_failures_per_day": 2,
       "approval_over_usd": 1000, "project_cap_usd": 666, "min_event_lead_s": 43200, "min_confirm_window_s": 90,
       "buy_sources": ["tevo", "gotickets"], "evo_buyer_office_id": 42029, "evo_reviewer_id": 53658,
       "evo_email_address_id": 10497966, "gt_gift_card_ids": None, **PROFILE}
LISTING = {"id": 7531654667, "quantity": 3, "validSplitQuantities": [1, 2, 3], "displayPrice": 90.0,
           "allInPrice": 96.0, "deliveryMethods": [{"id": 1, "price": 6, "physicalDelivery": False,
                                                    "displayName": "Mobile Transfer"},
                                                   {"id": 2, "price": 0, "physicalDelivery": True,
                                                    "displayName": "FedEx"}],
           "transactionRatePercentage": 2.5}
CARDS = [{"id": 28085, "amount": 200000, "amountRemaining": 13357.69}, {"id": 6055, "amount": 100000,
                                                                         "amountRemaining": 0}]


def _row(**kw):
    r = {"exec_id": 9, "n2s_id": 410, "state": "live_buy", "phase": "buying", "sub_source": "gotickets",
         "sub_listing_id": "7531654667", "gt_event_id": 1356592, "qty": 2, "sub_total_usd": 200.0,
         "sold_total_usd": 260.0, "event_dt_local": "2026-11-13T19:00:00",
         "sub_confirm_by": (NOW + timedelta(minutes=12)).isoformat(), "seller_window_s": 540,
         "seller_window_in_hand_s": 540, "spend_today_before": 0, "project_spent_before": 0,
         "sale_order_key": "555", "buy_order_id": None, "lease_token": "tok-1", "sell_market": "evo"}
    r.update(kw)
    return r


class Rpc:
    def __init__(self, job, lost=()):
        self.job, self.records, self.lost = job, [], set(lost)

    def __call__(self, name, params):
        if name == "n2s_autobuy_live_claim":
            return self.job
        self.records.append(params)
        phase = params["p_patch"].get("phase")
        return "lease_lost" if phase in self.lost else phase


class Evo:
    """The EVO client: here only the sale side (an EVO sale covered by a GoTickets sub)."""

    def __init__(self, orders=None):
        self.orders, self.calls = orders or {"555": {"state": "pending"}}, []

    def get_order(self, oid):
        self.calls.append(("get", oid))
        return self.orders[str(oid)]

    def accept_order(self, oid, reviewer):
        self.calls.append(("accept", oid, reviewer))
        self.orders[str(oid)] = {"state": "accepted"}
        return {"state": "accepted"}

    def get_ticket_group(self, tid):  # an EVO read must never happen on a GoTickets row
        raise AssertionError("EVO listing read on a GoTickets sub")

    def create_order(self, body):
        raise AssertionError("EVO buy on a GoTickets sub")


class Gt:
    def __init__(self, listing=LISTING, own=False, cards=CARDS, create=None, purchases=None, ready=True):
        self.listing, self.own, self.cards, self.create = listing, own, cards, create
        self.purchases, self._ready, self.calls = purchases or {}, ready, []

    def ready(self):
        return self._ready

    def _maybe(self, v):
        if isinstance(v, Exception):
            raise v
        return v

    def get_listing(self, event_id, listing_id):
        self.calls.append(("listing", event_id, listing_id))
        return self._maybe(self.listing)

    def is_own_listing(self, listing_id):
        self.calls.append(("own", listing_id))
        return self._maybe(self.own)

    def get_gift_cards(self):
        self.calls.append(("cards",))
        return self._maybe(self.cards)

    def create_order(self, body):
        self.calls.append(("buy", body))
        return self._maybe(self.create)

    def get_purchase(self, pid):
        self.calls.append(("purchase", pid))
        return self._maybe(self.purchases[str(pid)])


def _job(action="buy", cfg=None, **kw):
    return {"action": action, "row": _row(**kw), "cfg": {**CFG, **(cfg or {})}}


def _tick(job, gt, evo=None, **rpc_kw):
    rpc = Rpc(job, **rpc_kw)
    out = lv.tick(rpc, evo or Evo(), now=NOW, gt=gt)
    return out, rpc.records, gt.calls if gt else []


def _buys(calls):
    return [c for c in calls if c[0] == "buy"]


# ------------------------------------------------------------------ the client guard

def test_guard_allows_reads_and_only_the_order_post():
    g = gtb._assert_readonly_method
    g("GET", "https://gotickets.com/rest/pro/api/events/1/listings")
    g("GET", "https://gotickets.com/rest/pro/api/gift-cards")
    g("GET", "https://sc.gotickets.com/rest/purchases/8337008")
    g("GET", "https://sc.gotickets.com/rest/listings/7531654667")
    g("POST", "https://gotickets.com/rest/pro/api/orders")
    for m, u in (("POST", "https://gotickets.com/rest/pro/api/orders/1"),
                 ("POST", "https://gotickets.com/rest/pro/api/gift-cards"),
                 ("POST", "https://sc.gotickets.com/rest/pro/api/orders"),
                 ("POST", "https://sc.gotickets.com/rest/purchases/1/cancel"),
                 ("PUT", "https://gotickets.com/rest/pro/api/orders"),
                 ("DELETE", "https://gotickets.com/rest/pro/api/orders"),
                 ("GET", "https://evil.example.com/rest/pro/api/orders"),
                 ("POST", "http://gotickets.com/rest/pro/api/orders")):
        with pytest.raises(gtb.GoTicketsBuyError):
            g(m, u)


def test_the_write_literal_is_the_one_the_audit_pins():
    assert gtb.GT_BUY_WRITES == (("POST", "gotickets.com", r"^/rest/pro/api/orders$"),)
    assert gtb.ALLOWED_HTTP_METHODS == frozenset({"GET", "POST"})


class Session:
    def __init__(self, *responses):
        self.responses, self.calls = list(responses), []

    def request(self, method, url, **kw):
        self.calls.append((method, url, kw))
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def _resp(status=200, data=None, text=None):
    return SimpleNamespace(status_code=status, text=text if text is not None else ("x" if data is not None else ""),
                           json=lambda: data)


def test_client_sends_the_pro_token_and_reads_listings_from_the_wrapper_object():
    s = Session(_resp(data={"event": {}, "listings": [{"id": 5}, LISTING]}))
    c = gtb.GoTicketsBuyClient("gid", "gsec", session=s)
    assert c.get_listing(1356592, "7531654667") == LISTING
    method, url, kw = s.calls[0]
    assert (method, url) == ("GET", "https://gotickets.com/rest/pro/api/events/1356592/listings")
    assert kw["headers"]["X-Broker-Api-Token"] == base64.b64encode(b"gid:gsec").decode()


def test_client_listing_gone_is_none():
    c = gtb.GoTicketsBuyClient("gid", "gsec", session=Session(_resp(data={"listings": [{"id": 5}]})))
    assert c.get_listing(1, 7531654667) is None


def test_own_listing_check_reads_seller_central():
    s = Session(_resp(text=""), _resp(data={"id": 7892132238, "section": "102"}))
    c = gtb.GoTicketsBuyClient("gid", "gsec", session=s)
    assert c.is_own_listing(7531654667) is False      # 200 with no body: not ours
    assert c.is_own_listing(7892132238) is True       # our listing comes back
    _method, url, kw = s.calls[1]
    assert url == "https://sc.gotickets.com/rest/listings/7892132238"
    assert kw["headers"]["X-Api-Access-Id"] == "gid" and "X-Broker-Api-Token" not in kw["headers"]


def test_client_write_outcomes():
    c = gtb.GoTicketsBuyClient("gid", "gsec", session=Session(_resp(status=475, text="Price Changed")))
    with pytest.raises(EvoWriteRejected):
        c.create_order({})
    c = gtb.GoTicketsBuyClient("gid", "gsec", session=Session(_resp(status=502, text="bad gateway")))
    with pytest.raises(EvoWriteUnknown):
        c.create_order({})
    c = gtb.GoTicketsBuyClient("gid", "gsec", session=Session(requests.Timeout("slow")))
    with pytest.raises(EvoWriteUnknown):
        c.create_order({})
    s = Session(_resp(data={"id": 8400001, "orderStatus": "PENDING_CONFIRMATION"}))
    c = gtb.GoTicketsBuyClient("gid", "gsec", session=s)
    assert c.create_order({"listingId": 1})["id"] == 8400001
    assert s.calls[0][:2] == ("POST", "https://gotickets.com/rest/pro/api/orders")
    assert s.calls[0][2]["json"] == {"listingId": 1}


# ------------------------------------------------------------------ pure helpers

def test_expected_total_is_gotickets_formula_without_card_rate():
    d = gtb.pick_delivery(LISTING)
    assert d["id"] == 1                                            # the electronic one, not FedEx
    assert gtb.expected_total(LISTING, 2, d) == 186.0             # 90*2 + 6
    taxed = {**LISTING, "tax": 8.1}
    assert gtb.expected_total(taxed, 2, {**d, "additionalDeliveryFeeTax": 0.54}) == 202.74


def test_pick_delivery_needs_an_electronic_method_with_an_id():
    assert gtb.pick_delivery({"deliveryMethods": [{"id": 2, "price": 0, "physicalDelivery": True}]}) is None
    assert gtb.pick_delivery({"deliveryMethods": [{"price": 0, "physicalDelivery": False}]}) is None
    cheap = gtb.pick_delivery({"deliveryMethods": [{"id": 1, "price": 6}, {"id": 3, "price": 0}]})
    assert cheap["id"] == 3


def test_gift_cards_largest_first_allowlist_and_shortfall():
    cards = [{"id": 1, "amountRemaining": 50}, {"id": 2, "amountRemaining": 120}, {"id": 3, "amountRemaining": 0}]
    assert gtb.pick_gift_cards(cards, 100) == [2]
    assert gtb.pick_gift_cards(cards, 150) == [2, 1]
    assert gtb.pick_gift_cards(cards, 171) is None
    assert gtb.pick_gift_cards(cards, 40, allowed=[1]) == [1]
    assert gtb.pick_gift_cards(cards, 60, allowed=[1]) is None


def test_purchase_state_reads_gotickets_statuses():
    assert gtb.purchase_state("PENDING_CONFIRMATION") == "pending"
    assert gtb.purchase_state("CANCELLED") == "rejected"
    for s in ("PENDING_MOBILE_FULFILLMENT", "TRANSFER_COMPLETED", "PAH_DELIVERED", "PENDING_TRANSFER_PROOF"):
        assert gtb.purchase_state(s) == "confirmed"
    assert gtb.purchase_state(None) == "unknown"


def test_order_id_reads_the_usual_keys():
    assert gtb.order_id({"id": 5}) == "5"
    assert gtb.order_id({"orderId": 6}) == "6"
    assert gtb.order_id({"order": {"id": 7}}) == "7"
    assert gtb.order_id({"status": "ok"}) is None


# ------------------------------------------------------------------ the worker: buy

def test_buys_once_from_gift_cards_and_records_the_purchase():
    gt = Gt(create={"id": 8400001, "orderStatus": "PENDING_CONFIRMATION", "orderTotal": 186.0})
    out, recs, calls = _tick(_job(), gt)
    assert out["phase"] == "buy_sent" and out["buy_order_id"] == "8400001"
    (_, body), = _buys(calls)
    assert body["eventId"] == 1356592 and body["listingId"] == 7531654667 and body["quantity"] == 2
    assert body["expectedTotal"] == 186.0 and body["deliveryMethodId"] == 1
    assert body["giftCardIds"] == [28085] and "paymentMethodToken" not in body
    assert body["recipient"] == PROFILE["gt_recipient"] and body["billingAddress"] == PROFILE["gt_billing_address"]
    assert [r["p_patch"]["phase"] for r in recs] == ["buying", "buy_sent"]   # lease held right before the POST
    assert ("own", "7531654667") in calls


@pytest.mark.parametrize("gt_kw, row_kw, cfg_kw, reason", [
    ({"own": True}, {}, {}, "our_own_listing"),
    ({"listing": None}, {}, {}, "listing_gone"),
    ({"listing": {**LISTING, "quantity": 1}}, {}, {}, "short_quantity"),
    ({"listing": {**LISTING, "validSplitQuantities": [1, 3]}}, {}, {}, "split_not_allowed"),
    ({"listing": {**LISTING, "deliveryMethods": [{"id": 2, "price": 0, "physicalDelivery": True}]}}, {}, {},
     "no_electronic_delivery"),
    ({"listing": {**LISTING, "displayPrice": 99.0}}, {}, {}, "price_rose"),            # 198 + 6 > 200
    ({"cards": [{"id": 1, "amountRemaining": 100}]}, {}, {}, "gift_card_balance_short"),
    ({}, {}, {"gt_recipient": None}, "gt_buyer_profile_missing"),
    ({}, {"gt_event_id": None}, {}, "no_gt_event_id"),
    ({}, {}, {"per_order_cap_usd": 150}, "over_per_order_cap"),                       # GoTickets' own cap
    ({}, {"spend_today_before": 500}, {}, "over_daily_cap"),
    ({}, {"sold_total_usd": 180.0}, {}, "not_profitable"),                            # real total 186
    ({}, {"sub_confirm_by": (NOW + timedelta(minutes=5)).isoformat()}, {}, "not_enough_time_for_seller"),
    ({"own": gtb.GoTicketsBuyError("timeout")}, {}, {}, "own_listing_check_failed"),
    ({"listing": gtb.GoTicketsBuyError("timeout")}, {}, {}, "listing_read_failed"),
])
def test_stops_before_sending(gt_kw, row_kw, cfg_kw, reason):
    gt = Gt(**gt_kw)
    out, recs, calls = _tick(_job(cfg=cfg_kw, **row_kw), gt)
    assert out["phase"] == "stopped" and reason in out["reasons"]
    assert not _buys(calls)
    assert [r["p_patch"]["phase"] for r in recs] == ["stopped"]      # never 'buying': the run is given back


def test_no_gotickets_client_stops_without_a_buy():
    out, _, _ = _tick(_job(), Gt(ready=False))
    assert out["phase"] == "stopped" and out["reasons"] == ["no_gt_buy_client"]
    rpc = Rpc(_job())
    assert lv.tick(rpc, Evo(), now=NOW)["reasons"] == ["no_gt_buy_client"]       # gt not passed at all


def test_gotickets_refusal_stops_and_unknown_outcome_fails_closed():
    out, _, _ = _tick(_job(), Gt(create=EvoWriteRejected(475, "Price Changed")))
    assert out["phase"] == "stopped" and out["reasons"] == ["buy_failed"]
    out, _, _ = _tick(_job(), Gt(create=EvoWriteUnknown("/rest/pro/api/orders: HTTP 502")))
    assert out["phase"] == "buy_unknown"
    out, _, _ = _tick(_job(), Gt(create={"status": "ok"}))                       # no purchase id in the answer
    assert out["phase"] == "buy_unknown"


def test_lease_lost_before_the_post_sends_nothing():
    gt = Gt(create={"id": 1})
    out, _, calls = _tick(_job(), gt, lost={"buying"})
    assert out["phase"] == "lease_lost" and not _buys(calls)


def test_a_charge_above_expected_is_noted():
    gt = Gt(create={"id": 8400001, "orderTotal": 190.0})
    out, _, _ = _tick(_job(), gt)
    assert out["phase"] == "buy_sent" and "above the expected" in out["live_error"]


# ------------------------------------------------------------------ the worker: follow + accept

def _poll(status, **row_kw):
    return _job(action="poll", phase="buy_sent", buy_order_id="8400001", **row_kw), \
        Gt(purchases={"8400001": {"orderStatus": status}})


def test_waits_while_the_seller_has_not_confirmed():
    job, gt = _poll("PENDING_CONFIRMATION")
    out, _, _ = _tick(job, gt)
    assert out["phase"] == "buy_sent" and out["buy_state"] == "PENDING_CONFIRMATION"


def test_cancelled_purchase_stops_and_the_sale_is_not_accepted():
    job, gt = _poll("CANCELLED")
    evo = Evo()
    out, _, _ = _tick(job, gt, evo=evo)
    assert out["phase"] == "stopped" and out["reasons"] == ["sub_rejected"]
    assert not [c for c in evo.calls if c[0] == "accept"]


def test_confirmed_purchase_accepts_the_evo_sale():
    job, gt = _poll("PENDING_MOBILE_FULFILLMENT")
    evo = Evo()
    out, _, _ = _tick(job, gt, evo=evo)
    assert out["phase"] == "accepted"
    assert ("accept", "555", 53658) in evo.calls


def test_unconfirmed_past_the_deadline_stops():
    job, gt = _poll("PENDING_CONFIRMATION", sub_confirm_by=(NOW - timedelta(seconds=1)).isoformat())
    out, _, _ = _tick(job, gt)
    assert out["phase"] == "stopped" and out["reasons"] == ["sub_unconfirmed"]


def test_poll_without_a_gotickets_client_fails_the_tick_not_the_row():
    job, _ = _poll("PENDING_CONFIRMATION")
    with pytest.raises(RuntimeError):
        lv.tick(Rpc(job), Evo(), now=NOW)
