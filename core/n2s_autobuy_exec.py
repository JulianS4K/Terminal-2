"""N2S auto-buy EXECUTOR step engine — decides the next step, never sends.

Operator direction 2026-11-09 (spec in supabase/migrations/20261109030000_n2s_autobuy_exec.sql):
spend limits ($500 for the whole project, $250 an order, $250 a day), the event more than 24 hours out and not
today, the sub must be CONFIRMED by the selling market's median cutoff or the sale is NOT
accepted, a rejected sub is never retried, no minimum margin, operator approval (text /
WhatsApp) only when the sub is over $1,000.

The database decides who is eligible (``n2s_autobuy_exec``: shadow_buy / awaiting_approval /
approved). This module is what a live worker runs per row, and it re-checks the money and time
guards itself right before each step so a stale row can never spend (defence in depth).

Nothing here can reach a market. The only transport is :class:`RefusingTransport`, which
raises; ``LIVE_ENABLED`` is False. Going live (CLAUDE.md RULE 2) is a separate PR with the
operator's written authorization, buyer credentials and a write client restricted to the
buy/accept endpoints in ``core/n2s_autobuy.py`` — ``scripts/check_readonly.py`` is unchanged.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

LIVE_ENABLED = False

DEFAULTS: dict[str, Any] = {
    "per_order_cap_usd": 250.0,
    "daily_cap_usd": 250.0,
    "max_buys_per_day": 3,
    "max_failures_per_day": 2,
    "approval_over_usd": 1000.0,
    "min_event_lead_s": 24 * 3600,
    "min_confirm_window_s": 90,
    # Operator 2026-11-09: $500 cap on the whole project (every market); auto-stop at the cap.
    "project_cap_usd": 500.0,
}

# Purchase states on the market we bought the sub from.
SUB_CONFIRMED = frozenset({"accepted", "confirmed", "completed", "shipped", "delivered", "fulfilled"})
SUB_REJECTED = frozenset({"rejected", "denied", "declined", "cancelled", "canceled", "failed", "expired"})


class RefusingTransport:
    """The only transport in this module: every send is refused (RULE 2)."""

    def send(self, request: dict) -> dict:
        raise PermissionError(f"live market writes are disabled: {request.get('method')} {request.get('url')}")


def _ts(v: Any) -> datetime | None:
    if v is None or isinstance(v, datetime):
        return v if v is None or v.tzinfo else v.replace(tzinfo=timezone.utc)
    dt = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def buy_guards(row: dict, *, now: datetime, spend_today: float, buys_today: int, failures_today: int,
               project_spent: float = 0.0, stopped: bool = False, cfg: dict | None = None) -> list[str]:
    """Reasons NOT to buy right now (empty = all guards pass). `spend_today` / `buys_today` /
    `failures_today` / `project_spent` (every buy ever, this mode) exclude this row.
    Re-checked by the worker immediately before the buy."""
    c = {**DEFAULTS, **(cfg or {})}
    reasons: list[str] = []
    total = row.get("sub_total_usd")
    if total is None or float(total) <= 0:
        reasons.append("no_price")
    else:
        total = float(total)
        if total > c["per_order_cap_usd"]:
            reasons.append("over_per_order_cap")
        if spend_today + total > c["daily_cap_usd"]:
            reasons.append("over_daily_cap")
        if total > c["approval_over_usd"] and row.get("state") != "approved":
            reasons.append("needs_approval")
        sold = row.get("sold_total_usd")
        if sold is None or total >= float(sold):
            reasons.append("not_profitable")
        if not stopped and project_spent + total > c["project_cap_usd"]:
            reasons.append("over_project_cap")
    if stopped:
        reasons.append("stopped_pending_review")
    if buys_today >= c["max_buys_per_day"]:
        reasons.append("max_buys_today")
    if failures_today >= c["max_failures_per_day"]:
        reasons.append("circuit_breaker")
    event = _ts(row.get("event_start_utc"))
    if event is None:
        reasons.append("event_time_unknown")
    elif event - now < timedelta(seconds=c["min_event_lead_s"]):
        reasons.append("event_within_24h")
    confirm_by = _ts(row.get("sub_confirm_by"))
    if confirm_by is None or confirm_by - now < timedelta(seconds=c["min_confirm_window_s"]):
        reasons.append("not_enough_time_for_market")
    if row.get("state") not in ("shadow_buy", "approved"):
        reasons.append(f"state_{row.get('state')}")
    return reasons


def next_action(row: dict, *, now: datetime, sub_status: str | None = None) -> dict:
    """The next step for one exec row in a live run.

    phase 'ready'    → buy (guards are checked separately, by :func:`buy_guards`)
    phase 'buy_sent' → read the purchase on the sub's market:
        confirmed                      → accept the sale
        rejected                       → stop: sub_rejected (never retried, sale not accepted)
        neither, past sub_confirm_by   → stop: sub_unconfirmed (sale NOT accepted)
        neither, still in time         → wait and read again
    phase 'accepted' / 'stopped'       → done
    """
    phase = row.get("phase") or "ready"
    if phase in ("accepted", "stopped"):
        return {"action": "done", "phase": phase}
    if phase == "ready":
        return {"action": "buy", "phase": "buy_sent"}
    status = (sub_status or "").strip().lower()
    if status in SUB_CONFIRMED:
        return {"action": "accept_sale", "phase": "accepted"}
    if status in SUB_REJECTED:
        return {"action": "stop", "phase": "stopped", "reason": "sub_rejected"}
    confirm_by = _ts(row.get("sub_confirm_by"))
    if confirm_by is None or now >= confirm_by:
        return {"action": "stop", "phase": "stopped", "reason": "sub_unconfirmed"}
    return {"action": "wait_sub", "phase": "buy_sent",
            "seconds_left": int((confirm_by - now).total_seconds())}


def run_step(row: dict, *, now: datetime, sub_status: str | None = None,
             transport: Any = None) -> dict:
    """Decide the step and, for a write step, hand the request to the transport. With the default
    :class:`RefusingTransport` (and ``LIVE_ENABLED`` False) a write step is recorded, not sent."""
    step = next_action(row, now=now, sub_status=sub_status)
    if step["action"] in ("buy", "accept_sale"):
        if not LIVE_ENABLED:
            return {**step, "sent": False, "note": "shadow mode: nothing sent"}
        (transport or RefusingTransport()).send(row.get(f"{step['action']}_request") or {})
        return {**step, "sent": True}  # pragma: no cover - unreachable until a live PR flips LIVE_ENABLED
    return {**step, "sent": False}
