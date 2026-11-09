"""N2S auto-buy executor step engine — guards, the confirm-or-stop flow, and no send path."""
from datetime import datetime, timedelta, timezone

import pytest

import core.n2s_autobuy_exec as ex

NOW = datetime(2026, 11, 9, 20, 0, tzinfo=timezone.utc)


def _row(**kw):
    base = {"state": "shadow_buy", "sub_source": "tevo", "sub_total_usd": 120.0, "sold_total_usd": 160.0,
            "event_start_utc": (NOW + timedelta(days=3)).isoformat(),
            "sub_confirm_by": NOW + timedelta(minutes=8)}
    base.update(kw)
    return base


def _guards(row, spend=0.0, buys=0, fails=0, cfg=None, **kw):
    return ex.buy_guards(row, now=NOW, spend_today=spend, buys_today=buys, failures_today=fails, cfg=cfg, **kw)


def test_clean_row_passes_every_guard():
    assert _guards(_row()) == []


def test_spend_limits():
    assert "over_per_order_cap" in _guards(_row(sub_total_usd=251, sold_total_usd=400))
    assert _guards(_row(), spend=200) == ["over_daily_cap"]          # 200 + 120 > 250
    assert _guards(_row(), spend=130) == []                           # 130 + 120 = 250 is allowed
    assert _guards(_row(), buys=3) == ["max_buys_today"]
    assert _guards(_row(), fails=2) == ["circuit_breaker"]


def test_project_cap_500_on_every_market_and_stop():
    both = {"buy_sources": ("tevo", "gotickets")}
    for src in ("tevo", "gotickets"):
        row = _row(sub_source=src)
        assert _guards(row, project_spent=380, cfg=both) == []            # 380 + 120 = 500 is allowed
        assert _guards(row, project_spent=381, cfg=both) == ["over_project_cap"]
        assert _guards(row, stopped=True, cfg=both) == ["stopped_pending_review"]


def test_soft_launch_buys_evo_subs_only():
    assert _guards(_row(sub_source="tevo")) == []
    assert _guards(_row(sub_source="gotickets")) == ["sub_source_disabled"]
    assert _guards(_row(sub_source="gotickets"), cfg={"buy_sources": ("tevo", "gotickets")}) == []


def test_approval_only_over_1000():
    cfg = {"per_order_cap_usd": 5000, "daily_cap_usd": 5000, "project_cap_usd": 5000}
    assert _guards(_row(sub_total_usd=1000, sold_total_usd=1100), cfg=cfg) == []
    assert _guards(_row(sub_total_usd=1001, sold_total_usd=1100), cfg=cfg) == ["needs_approval"]
    assert _guards(_row(sub_total_usd=1001, sold_total_usd=1100, state="approved"), cfg=cfg) == []


def test_no_minimum_margin_but_never_a_loss():
    assert _guards(_row(sub_total_usd=159.99)) == []                   # a cent of margin is enough
    assert _guards(_row(sub_total_usd=160.0)) == ["not_profitable"]
    assert "not_profitable" in _guards(_row(sold_total_usd=None))
    assert _guards(_row(sub_total_usd=None)) == ["no_price"]
    assert _guards(_row(sub_total_usd=0)) == ["no_price"]


def test_event_must_be_more_than_24h_out():
    assert _guards(_row(event_start_utc=(NOW + timedelta(hours=23)).isoformat())) == ["event_within_24h"]
    assert _guards(_row(event_start_utc=NOW + timedelta(hours=25))) == []      # datetime input
    naive = (NOW + timedelta(days=2)).replace(tzinfo=None)
    assert _guards(_row(event_start_utc=naive)) == []                          # naive = UTC
    assert _guards(_row(event_start_utc="2026-11-12T20:00:00Z")) == []
    assert _guards(_row(event_start_utc="2026-11-12T20:00:00")) == []
    assert _guards(_row(event_start_utc=None)) == ["event_time_unknown"]


def test_time_left_for_the_market_and_state():
    assert _guards(_row(sub_confirm_by=NOW + timedelta(seconds=60))) == ["not_enough_time_for_market"]
    assert _guards(_row(sub_confirm_by=None)) == ["not_enough_time_for_market"]
    assert _guards(_row(state="blocked")) == ["state_blocked"]


def test_flow_confirm_then_accept():
    assert ex.next_action(_row(), now=NOW) == {"action": "buy", "phase": "buy_sent"}
    sent = _row(phase="buy_sent")
    assert ex.next_action(sent, now=NOW, sub_status="Accepted")["action"] == "accept_sale"
    w = ex.next_action(sent, now=NOW, sub_status="pending")
    assert w["action"] == "wait_sub" and w["seconds_left"] == 480


def test_rejected_sub_stops_and_is_not_retried():
    out = ex.next_action(_row(phase="buy_sent"), now=NOW, sub_status="rejected")
    assert out == {"action": "stop", "phase": "stopped", "reason": "sub_rejected"}
    assert ex.next_action(_row(phase="stopped"), now=NOW) == {"action": "done", "phase": "stopped"}


def test_unconfirmed_by_the_cutoff_is_not_accepted():
    late = _row(phase="buy_sent", sub_confirm_by=NOW - timedelta(seconds=1))
    assert ex.next_action(late, now=NOW, sub_status="pending")["reason"] == "sub_unconfirmed"
    assert ex.next_action(_row(phase="buy_sent", sub_confirm_by=None), now=NOW)["reason"] == "sub_unconfirmed"
    assert ex.next_action(_row(phase="accepted"), now=NOW)["action"] == "done"


def test_run_step_never_sends():
    assert ex.LIVE_ENABLED is False
    out = ex.run_step(_row(), now=NOW)
    assert out["action"] == "buy" and out["sent"] is False
    out = ex.run_step(_row(phase="buy_sent"), now=NOW, sub_status="pending")
    assert out == {**out, "action": "wait_sub", "sent": False}


def test_refusing_transport_blocks_even_if_live_flag_flipped(monkeypatch):
    monkeypatch.setattr(ex, "LIVE_ENABLED", True)
    with pytest.raises(PermissionError):
        ex.run_step(_row(buy_request={"method": "POST", "url": "https://example.invalid/orders"}), now=NOW)
    with pytest.raises(PermissionError):
        ex.RefusingTransport().send({})


def test_no_http_library_imported():
    from pathlib import Path
    src = Path(ex.__file__).read_text()
    for lib in ("requests", "httpx", "urllib", "aiohttp", "http.client"):
        assert f"import {lib}" not in src and f"from {lib}" not in src
