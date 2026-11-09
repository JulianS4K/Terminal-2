"""N2S auto-buy LIVE worker — buy, confirm, accept; never retry, never reject."""
from datetime import datetime, timedelta, timezone

import pytest
import requests

import core.n2s_autobuy_live as lv


@pytest.fixture(autouse=True)
def _no_verify_pause(monkeypatch):
    monkeypatch.setattr(lv, "VERIFY_DELAY_S", 0)
from evo_buy_client import EvoWriteRejected, EvoWriteUnknown

NOW = datetime(2026, 11, 10, 18, 0, tzinfo=timezone.utc)
CFG = {"per_order_cap_usd": 250, "daily_cap_usd": 250, "max_buys_per_day": 3, "max_failures_per_day": 2,
       "approval_over_usd": 1000, "project_cap_usd": 500, "min_event_lead_s": 86400, "min_confirm_window_s": 90,
       "buy_sources": ["tevo"], "evo_buyer_office_id": 42029, "evo_reviewer_id": 53658,
       "evo_email_address_id": 10497966}
TG = {"id": 6744480374, "available_quantity": 4, "splits": [2, 4], "owned": False, "format": "TM_mobile",
      "wholesale_price": 100.0, "office": {"id": 1692, "brokerage": {"id": 1700}},
      "event": {"occurs_at": "2026-11-14T00:00:00Z"}}


def _row(**kw):
    r = {"exec_id": 7, "n2s_id": 325, "state": "live_buy", "phase": "buying", "sub_source": "tevo",
         "sub_listing_id": "6744480374", "qty": 2, "sub_total_usd": 200.0, "sold_total_usd": 260.0,
         "event_dt_local": "2026-11-13T19:00:00", "sub_confirm_by": (NOW + timedelta(minutes=8)).isoformat(),
         "spend_today_before": 0, "project_spent_before": 0, "sale_order_key": "555", "buy_order_id": None,
         "lease_token": "tok-1", "sell_market": "evo"}
    r.update(kw)
    return r


class Rpc:
    """Fake DB: the lease holds (record echoes the phase) unless `lost` names phases it refuses,
    or `boom` names a phase whose record raises."""

    def __init__(self, job, lost=(), boom=()):
        self.job, self.records, self.lost, self.boom = job, [], set(lost), set(boom)

    def __call__(self, name, params):
        if name == "n2s_autobuy_live_claim":
            return self.job
        phase = params["p_patch"].get("phase")
        if phase in self.boom:
            raise RuntimeError("db blip")
        self.records.append(params)
        return "lease_lost" if phase in self.lost else phase


class Client:
    def __init__(self, tg=TG, create=None, orders=None, accept=None, after_accept=None):
        self.tg, self.create, self.orders, self.accept = tg, create, orders or {}, accept
        self.after_accept = after_accept or {"state": "accepted"}
        self.calls = []

    def _maybe(self, v):
        if isinstance(v, Exception):
            raise v
        return v

    def get_ticket_group(self, tid):
        self.calls.append(("tg", tid))
        return self._maybe(self.tg)

    def create_order(self, body):
        self.calls.append(("buy", body))
        return self._maybe(self.create)

    def get_order(self, oid):
        self.calls.append(("get", oid))
        return self._maybe(self.orders[str(oid)])

    def accept_order(self, oid, reviewer):
        self.calls.append(("accept", oid, reviewer))
        out = self._maybe(self.accept)
        self.orders[str(oid)] = self.after_accept   # what the market shows on the re-read
        return out


def _tick(job, client, **rpc_kw):
    rpc = Rpc(job, **rpc_kw)
    out = lv.tick(rpc, client, now=NOW)
    return out, rpc.records, client.calls


def _buy_job(**kw):
    return {"action": "buy", "row": _row(**kw), "cfg": CFG}


def test_idle_when_nothing_to_claim():
    assert lv.tick(Rpc(None), Client(), now=NOW) == {"action": "idle"}


def test_default_now_is_used():
    assert lv.tick(Rpc(None), Client()) == {"action": "idle"}


def test_buy_happy_path_sends_one_order():
    c = Client(create={"orders": [{"id": 9001, "state": "pending", "total": "200.0"}]})
    out, recs, calls = _tick(_buy_job(), c)
    assert out["phase"] == "buy_sent" and out["buy_order_id"] == "9001" and out["live_error"] is None
    assert [k[0] for k in calls] == ["tg", "buy"]
    body = calls[1][1]["orders"][0]
    assert body["seller_id"] == 1692 and body["buyer_id"] == 42029
    assert body["shipped_items"][0]["type"] == "TMMobile"
    assert body["shipped_items"][0]["items"] == [{"ticket_group_id": 6744480374, "quantity": 2, "price": "100.00"}]
    assert [r["p_patch"]["phase"] for r in recs] == ["buying", "buy_sent"]
    assert recs[1] == {"p_exec_id": 7, "p_token": "tok-1", "p_patch": {"phase": "buy_sent", "buy_order_id": "9001",
                                                                       "buy_state": "pending", "live_error": None}}
    assert out["recorded"] == "buy_sent"


def test_buy_notes_a_total_above_the_quote_and_a_flat_response():
    c = Client(create={"id": 9002, "state": "pending", "total": "250.0"})
    out, _, _ = _tick(_buy_job(), c)
    assert out["buy_order_id"] == "9002" and "above the quoted" in out["live_error"]
    out, _, _ = _tick(_buy_job(), Client(create={"id": 9003}))
    assert out["live_error"] is None


def test_buy_guards_stop_before_any_market_call():
    out, _recs, calls = _tick(_buy_job(sub_total_usd=300.0, sold_total_usd=400.0), Client())
    assert out["phase"] == "stopped" and "over_per_order_cap" in out["reasons"] and calls == []


@pytest.mark.parametrize("tg,reason", [
    ({**TG, "owned": True}, "our_own_listing"),
    ({**TG, "office": {"id": 1, "brokerage": {"id": 1768}}}, "our_own_listing"),
    ({**TG, "available_quantity": 1}, "short_quantity"),
    ({**TG, "splits": [4]}, "split_not_allowed"),
    ({**TG, "wholesale_price": 100.01}, "price_rose"),
    ({**TG, "wholesale_price": None}, "price_rose"),
    ({**TG, "format": "Mystery"}, "unknown_format"),
    ({**TG, "event": {"occurs_at": "2026-11-11T00:00:00Z"}}, "event_within_24h"),
    ({**TG, "event": None}, "event_within_24h"),
])
def test_fresh_ticket_group_read_can_stop_the_buy(tg, reason):
    out, _, calls = _tick(_buy_job(), Client(tg=tg))
    assert out["phase"] == "stopped" and reason in out["reasons"] and [k[0] for k in calls] == ["tg"]


def test_ticket_group_checks_tolerate_sparse_reads():
    assert lv.ticket_group_checks({**TG, "splits": None, "office": None}, qty=2, sub_total=200, now=NOW,
                                  min_lead_s=0) == []


def test_listing_gone_or_unreadable_stops_without_buying():
    out, _, calls = _tick(_buy_job(), Client(tg=EvoWriteRejected(404, "nf")))
    assert out["reasons"] == ["listing_gone"] and [k[0] for k in calls] == ["tg"]
    out, _, _ = _tick(_buy_job(), Client(tg=requests.Timeout()))
    assert out["reasons"] == ["listing_read_failed"] and out["live_error"] == "Timeout"


def test_buy_rejected_stops_and_unknown_flags_it():
    out, _, _ = _tick(_buy_job(), Client(create=EvoWriteRejected(422, "bad seller")))
    assert out["phase"] == "stopped" and out["reasons"] == ["buy_failed"]
    out, _, _ = _tick(_buy_job(), Client(create=EvoWriteUnknown("timeout")))
    assert out["phase"] == "buy_unknown"
    out, _, _ = _tick(_buy_job(), Client(create={"orders": [{"state": "pending"}]}))
    assert out["phase"] == "buy_unknown" and "no order id" in out["live_error"]


def _poll_job(**kw):
    return {"action": "poll", "row": _row(phase="buy_sent", buy_order_id="9001", **kw), "cfg": CFG}


def test_poll_waits_while_the_sub_is_pending():
    out, _recs, calls = _tick(_poll_job(), Client(orders={"9001": {"state": "pending"}}))
    assert out == {"action": "poll", "exec_id": 7, "phase": "buy_sent", "buy_state": "pending",
                   "recorded": "buy_sent"}
    assert calls == [("get", "9001")]


def test_poll_rejected_or_late_sub_stops_and_never_accepts():
    out, _, calls = _tick(_poll_job(), Client(orders={"9001": {"state": "rejected"}}))
    assert out["phase"] == "stopped" and out["reasons"] == ["sub_rejected"]
    late = _poll_job(sub_confirm_by=(NOW - timedelta(seconds=1)).isoformat())
    out, _, calls = _tick(late, Client(orders={"9001": {"state": "pending"}}))
    assert out["reasons"] == ["sub_unconfirmed"] and not any(k[0] == "accept" for k in calls)


def test_poll_accepted_sub_then_accepts_the_pending_sale():
    c = Client(orders={"9001": {"state": "accepted"}, "555": {"state": "pending"}}, accept={"state": "accepted"})
    out, recs, calls = _tick(_poll_job(), c)
    assert out["phase"] == "accepted" and out["sale_state"] == "accepted"
    assert calls[-2:] == [("accept", "555", 53658), ("get", "555")]    # accept, then the re-read
    assert [r["p_patch"]["phase"] for r in recs] == ["sub_accepted", "accepted"]
    c = Client(orders={"555": {"state": "pending"}}, accept={})
    out, _, calls = _tick({**_poll_job(), "row": _row(phase="sub_accepted", buy_order_id="9001")}, c)
    assert out["sale_state"] == "accepted" and calls[0] == ("get", "555")


def test_lost_lease_never_sends_a_write():
    c = Client(create={"id": 1})
    out, _, calls = _tick(_buy_job(), c, lost={"buying"})
    assert out == {"action": "buy", "exec_id": 7, "phase": "lease_lost"} and [k[0] for k in calls] == ["tg"]
    c = Client(orders={"9001": {"state": "accepted"}, "555": {"state": "pending"}}, accept={})
    out, _, calls = _tick(_poll_job(), c, lost={"sub_accepted"})
    assert out["phase"] == "lease_lost" and not any(k[0] == "accept" for k in calls)


def test_anything_failing_after_a_sent_buy_is_unknown():
    out, _, _ = _tick(_buy_job(), Client(create={"orders": [{"id": 5, "total": "abc"}]}))
    assert out["phase"] == "buy_unknown" and out["live_error"].startswith("ValueError")
    out, recs, _ = _tick(_buy_job(), Client(create={"id": 5}), boom={"buy_sent"})
    assert out["phase"] == "buy_unknown" and "db blip" in out["live_error"]


def test_sale_no_longer_pending_is_left_alone():
    c = Client(orders={"9001": {"state": "accepted"}, "555": {"state": "rejected"}})
    out, _, calls = _tick(_poll_job(), c)
    assert out["phase"] == "stopped" and out["reasons"] == ["sale_not_pending"]
    assert not any(k[0] == "accept" for k in calls)


def test_accept_failures_are_recorded_not_retried():
    orders = {"9001": {"state": "accepted"}, "555": {"state": "pending"}}
    out, _, _ = _tick(_poll_job(), Client(orders=orders, accept=EvoWriteRejected(422, "no")))
    assert out["phase"] == "accept_failed"
    out, _, _ = _tick(_poll_job(), Client(orders=orders, accept=EvoWriteUnknown("t")))
    assert out["phase"] == "accept_unknown"


class Sales:
    def __init__(self, state="UNCONFIRMED", accept=None, has=True, after="CONFIRMED"):
        self.state, self.acc, self.has, self.calls, self.after = state, accept, has, [], after

    def has_market(self, m):
        return self.has

    def sale_state(self, market, key):
        self.calls.append(("state", market, key))
        return self.state

    def accept(self, market, key):
        self.calls.append(("accept", market, key))
        if isinstance(self.acc, Exception):
            raise self.acc
        self.state = self.after
        return self.acc or {"state": "accepted"}


def test_other_sell_markets_accept_through_the_sale_client():
    for market, pending in (("gotickets", "UNCONFIRMED"), ("seatgeek", "submitted"), ("vivid", "UNCONFIRMED")):
        s = Sales(state=pending)
        c = Client(orders={"9001": {"state": "accepted"}})
        out = lv.tick(Rpc(_poll_job(sell_market=market)), c, now=NOW, sales=s)
        assert out["phase"] == "accepted" and out["sale_state"] == "CONFIRMED"
        assert s.calls == [("state", market, "555"), ("accept", market, "555"), ("state", market, "555")]
        assert not any(k[0] == "accept" for k in c.calls)       # nothing sent to EVO's accept


def test_other_market_sale_not_pending_or_accept_failing():
    s = Sales(state="CONFIRMED")
    out = lv.tick(Rpc(_poll_job(sell_market="vivid")), Client(orders={"9001": {"state": "accepted"}}), now=NOW, sales=s)
    assert out["reasons"] == ["sale_not_pending"] and s.calls == [("state", "vivid", "555")]
    s = Sales(accept=EvoWriteRejected(400, "late"))
    out = lv.tick(Rpc(_poll_job(sell_market="gotickets")), Client(orders={"9001": {"state": "accepted"}}), now=NOW, sales=s)
    assert out["phase"] == "accept_failed"


def test_no_buy_when_the_selling_market_cannot_be_accepted():
    c = Client(create={"id": 1})
    out = lv.tick(Rpc(_buy_job(sell_market="vivid")), c, now=NOW, sales=Sales(has=False))
    assert out["reasons"] == ["no_sale_accept_token"] and c.calls == []
    out = lv.tick(Rpc(_buy_job(sell_market="seatgeek")), c, now=NOW)            # no sale client at all
    assert out["reasons"] == ["no_sale_accept_token"]
    out = lv.tick(Rpc(_buy_job(sell_market="gotickets")), Client(create={"id": 3}), now=NOW, sales=Sales())
    assert out["phase"] == "buy_sent"


def test_accept_is_only_counted_when_the_re_read_shows_it():
    orders = {"9001": {"state": "accepted"}, "555": {"state": "pending"}}
    out = lv.tick(Rpc(_poll_job()), Client(orders=dict(orders), accept={}, after_accept={"state": "pending"}), now=NOW)
    assert out["phase"] == "accept_failed" and out["reasons"] == ["accept_unverified"]
    out = lv.tick(Rpc(_poll_job()), Client(orders=dict(orders), accept={}, after_accept={"state": "rejected"}), now=NOW)
    assert out["phase"] == "accept_failed" and out["reasons"] == ["sale_rejected_after_accept"]
    s = Sales(after=None)
    out = lv.tick(Rpc(_poll_job(sell_market="vivid")), Client(orders={"9001": {"state": "accepted"}}), now=NOW, sales=s)
    assert out["phase"] == "accepted" and out["sale_state"] is None     # left UNCONFIRMED, no status text


def test_an_unreadable_re_read_is_unverified():
    class FlakySales(Sales):
        def sale_state(self, market, key):
            if any(c[0] == "accept" for c in self.calls):
                raise RuntimeError("timeout")
            return super().sale_state(market, key)
    out = lv.tick(Rpc(_poll_job(sell_market="seatgeek")), Client(orders={"9001": {"state": "accepted"}}), now=NOW,
                  sales=FlakySales(state="submitted"))
    assert out["phase"] == "accept_failed" and out["reasons"] == ["accept_unverified"]
    assert "re-read failed: RuntimeError" in out["live_error"]
