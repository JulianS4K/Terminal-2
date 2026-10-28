"""Tests for the N2S auto-cover PLANNER (core/n2s_autobuy.py) — dry run only.

Pins: the planner has no send path (no HTTP library imported, every write step `sent: False`),
each gate of the operator's flow (order active → 1-1 Index → not ours → buy → purchase
confirmed → accept sale), the endpoint table per market, and the Floor-vs-Loge guard.
"""
from __future__ import annotations

import ast
from datetime import datetime, timezone
from pathlib import Path

from core import n2s_autobuy as a

NOW = datetime(2026, 10, 28, 17, 0, tzinfo=timezone.utc)


def _order(**kw):
    o = {"order_number": "7596791", "n2s_order_key": "7596791", "s4k_source": "GoTickets",
         "n2s_status": "n2s", "in_window": True, "event_live": True, "timer_expired": False,
         "timer_expires_at": "2026-10-28T17:30:00Z", "section": "308", "quantity": 2,
         "sub_source": "gotickets", "sub_listing_id": "7792279723", "sub_section": "Upper 308",
         "sub_row": "C", "sub_qty": 2, "sub_ea": 884.05, "sub_total": 1768.1, "cover_cost": -662.5,
         "cover_gate": 1, "sub_view": "unknown"}
    o.update(kw)
    return o


def test_module_has_no_send_path():
    tree = ast.parse(Path(a.__file__).read_text())
    imported = {n.names[0].name.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.Import)}
    imported |= {(n.module or "").split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
    assert not imported & {"requests", "httpx", "urllib", "aiohttp", "http"}


def test_gotickets_cover_full_plan():
    p = a.plan_cover(_order(), gt_event_id=1883123, owned=None, now=NOW)
    assert p["go"] is True and p["dry_run"] is True and p["sent"] is False and p["profit"] == 662.5
    s = {x["step"]: x for x in p["steps"]}
    assert s[1]["request"]["url"] == "https://sc.gotickets.com/rest/sales/7596791"
    # GoTickets has no owned flag: decided live by a Seller Central read (empty 200 / 404 = not ours).
    assert s[3]["ok"] is None and s[3]["request"]["url"].endswith("/rest/listings/7792279723")
    assert s[4]["request"] == {"method": "POST", "url": "https://gotickets.com/rest/pro/api/orders",
                               "verified": True, "doc": a.BUY_SIDE["gotickets"]["buy"]["doc"]}
    assert s[4]["body"]["eventId"] == 1883123 and s[4]["body"]["expectedTotal"] == 1768.1
    assert s[4]["sent"] is False and s[6]["sent"] is False
    assert s[5]["request"]["url"] == "https://sc.gotickets.com/rest/purchases/{purchase_id}"
    assert s[6]["request"]["url"] == "https://sc.gotickets.com/rest/sales/7596791/confirm"
    assert p["live_checks"] == ["sub is not ours", "market accepted our purchase (confirmation code)",
                                "re-check sale order still active"]


def test_blocks_level_mismatch_loss_short_obstructed_and_inactive():
    p = a.plan_cover(_order(section="Floor 6", sub_section="Loge 6", cover_cost=40, cover_gate=2,
                            sub_qty=1, sub_view="obstructed", in_window=False, event_live=False,
                            n2s_status="cancelled"), owned=False, now=NOW)
    s = {x["step"]: x for x in p["steps"]}
    assert p["go"] is False and p["profit"] == -40.0
    assert set(s[2]["detail"]["reasons"]) == {"not_gate_1", "not_profitable", "level_mismatch",
                                              "short_quantity", "obstructed_view"}
    assert s[1]["detail"]["reasons"] == ["timer_closed", "event_over", "status_cancelled"]
    assert p["blocked_by"] == ["sale order still active", "1-1 Index sub"]


def test_gt_expected_total_formula():
    # (displayPrice + tax) * quantity * (1 + transactionRatePercentage/100)
    assert a.gt_expected_total(100, 2, tax=8, rate_pct=3) == 222.48
    assert a.gt_expected_total(884.05, 2) == 1768.1
    assert a.gt_expected_total(None, 2) is None and a.gt_expected_total(10, 0) is None
    p = a.plan_cover(_order(sub_tax=10, gt_rate_pct=2.5), gt_event_id=1, owned=None, now=NOW)
    assert {x["step"]: x for x in p["steps"]}[4]["body"]["expectedTotal"] == 1832.8
    assert a.BUY_SIDE["gotickets"]["pricing"]["method"] == "GET"


def test_order_active_timer_and_ped():
    assert a.order_active({"timer_expires_at": "2026-10-28T16:53:45+00:00"}, NOW)["reasons"] == ["timer_closed"]
    # PED (Need2Buy) orders are never covered — non-PED only.
    ped = a.order_active({"n2s_status": "n2b", "timer_expires_at": None})
    assert ped == {"active": False, "reasons": ["ped_order"], "seconds_left": None}
    assert a.order_active({"n2s_id": -8814259}, NOW)["reasons"] == ["ped_order"]
    assert a.order_active({"n2s_id": 5932, "n2s_status": "n2s"}, NOW)["active"] is True
    # A naive timestamp is read as UTC; garbage is ignored.
    assert a.order_active({"timer_expires_at": "2026-10-28T17:05:00"}, NOW)["seconds_left"] == 300
    assert a.order_active({"timer_expires_at": "soon"}, NOW)["active"] is True


def test_not_ours_and_other_markets():
    own = a.plan_cover(_order(sub_source="tevo", s4k_source="EVO"), owned=True, now=NOW)
    assert own["go"] is False and "sub is not ours" in own["blocked_by"]
    evo = a.plan_cover(_order(sub_source="tevo", s4k_source="EVO", n2s_order_key="473339"),
                       owned=False, now=NOW)
    s = {x["step"]: x for x in evo["steps"]}
    assert evo["go"] is True and s[3]["ok"] is True and s[3]["kind"] == "check"
    assert s[4]["request"]["url"] == "https://api.ticketevolution.com/v9/orders"
    assert s[4]["body"]["orders"][0]["ticket_group"]["id"] == "7792279723"
    assert s[6]["request"]["url"].endswith("/v9/orders/473339/accept") and s[6]["body"] == {"reviewer_id": None}
    # TickPick sub sold on TickPick.
    tp = a.plan_cover(_order(sub_source="tickpick", s4k_source="TickPick"), owned=False, now=NOW)
    s = {x["step"]: x for x in tp["steps"]}
    assert s[4]["body"]["external_id"] == "7596791" and s[6]["body"] == {"broker_id": None, "seat_numbers": None}
    # TickPick's token is not working: neither buying there nor accepting a TickPick sale goes.
    assert tp["go"] is False and s[4]["detail"]["reason"] == "TickPick API token not working"
    assert s[6]["detail"]["reason"] == "TickPick API token not working"
    # SeatGeek sub: no buy API → manual; sold on SeatGeek: SellerDirect PATCH /order.
    sg = a.plan_cover(_order(sub_source="seatgeek", s4k_source="Seatgeek"), owned=False, now=NOW)
    s = {x["step"]: x for x in sg["steps"]}
    assert sg["go"] is False and s[4]["detail"]["reason"].startswith("no buy API")
    assert s[6]["request"]["method"] == "PATCH" and s[6]["body"]["status"] == "confirmed"
    # No ownership data for a non-GoTickets source without a flag.
    assert a.not_ours({"sub_source": "tevo"}, None)["reasons"] == ["no_ownership_data"]


def test_unverified_and_unknown_markets_block_the_accept():
    for src in ("StubHub", "Gametime.Co", "Viagogo", "Ticketmaster"):
        p = a.plan_cover(_order(s4k_source=src), owned=False, now=NOW)
        assert p["go"] is False and p["blocked_by"] == [f"accept sale on {src}"]
    vp = a.plan_cover(_order(s4k_source="Vivid Seats"), owned=False, now=NOW)
    vivid = {x["step"]: x for x in vp["steps"]}
    assert vp["go"] is True and vivid[1]["request"]["url"].endswith("getOrder?orderId=7596791")
    assert vivid[6]["request"]["url"].endswith("/webservices/v1/confirmOrder") and vivid[6]["sent"] is False
    assert vivid[6]["body"] == {"orderId": "7596791", "shipNow": False}
    odd = a.plan_cover(_order(s4k_source="Somewhere", sub_source="weird"), owned=False, now=NOW)
    s = {x["step"]: x for x in odd["steps"]}
    assert s[4]["detail"]["reason"] == "unsupported source weird" and s[5]["ok"] is False
    assert s[6]["detail"]["reason"] == "unknown market Somewhere" and s[6]["body"] is None
    assert a.sell_market_key(None) is None
