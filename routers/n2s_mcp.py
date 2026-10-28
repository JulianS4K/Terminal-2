"""S4K N2S MCP server (/n2s-mcp) — the Need-to-Sub desk as MCP tools.

A separate server from the market-data MCP (routers/mcp_api.py, /mcp): different job,
different audience. Internal keys only — an external key gets 403 — and it reuses that
module's key check, rate limit, daily quota and usage stamp (MCPApp).

Tools: the open N2S book with its covers (`n2s_book`), one order end to end (`n2s_order`),
cover history (`n2s_cover_history`), Gmail peddled / Need2Buy orders (`ped_orders`), the
GoTickets auto-buy dry run (`gt_dryrun`, `gt_dryrun_summary`), pipeline health
(`n2s_health`) and a Ticketmaster primary check through TicketsData (`tm_primary`).

READ-ONLY (CLAUDE.md RULE 2): every tool reads our DB or GETs an upstream; nothing creates
an order, hold or listing change anywhere. The dry run only records what an auto-buyer WOULD
send. `tm_primary` spends one TicketsData credit per call.
"""
from __future__ import annotations

import re
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from typing import Any

from routers.mcp_api import INTERNAL, MCPApp, _clamp, _make_server

N2S_INSTRUCTIONS = (
    "S4K Need-to-Sub (N2S) desk, internal. An N2S order is a sale that failed and must be covered "
    "(re-bought) within the marketplace's window; a PED order (`ped`) is a Gmail peddled sale still "
    "to be bought. Start with `n2s_health`, then `n2s_book` for what is open, or `n2s_order` for one "
    "order. Covers carry `cover_gate` 1-6: 1 Index (same section, profitable), 2 S4KTrading (same "
    "section, at a loss), 3-6 move the buyer and need their OK first. `cover_cost` / `profit`: a "
    "negative cover_cost (positive profit) means the cover is cheaper than the sale. "
    "`gt_dryrun_summary` reports the GoTickets auto-buy dry run — nothing was ever sent. "
    "`tm_primary` checks Ticketmaster box-office inventory and costs one TicketsData credit. "
    "Read-only.")

_BOOK_COLS = (
    "n2s_id,order_number,n2s_order_key,s4k_source,n2s_status,status_label,fail_reason,alert_at,"
    "timer_expires_at,in_window,event_name,event_date,event_dt,venue,tevo_event_id,gt_event_id,"
    "section,order_row,quantity,sold_ea,sold_total,has_cover,no_cover_reason,sub_source,"
    "sub_listing_id,sub_section,sub_row,sub_qty,sub_avail,sub_ea,sub_total,cover_cost,cover_gate,"
    "cover_label,sub_view,buy_url,refreshed_at,last_sub_source,last_sub_section,last_sub_row,"
    "last_cover_cost,last_cover_at")


def n2s_book(db, source: str | None = None, with_cover: bool | None = None,
             profitable_only: bool = False, ped_only: bool = False, limit: int = 100) -> dict:
    """The open N2S book (what the subs page shows): every open failed order with its cover
    where one exists, else `no_cover_reason`. `source` filters the marketplace (StubHub, Gametime,
    ...); `with_cover` true/false; `profitable_only` = covers cheaper than the sale; `ped_only` =
    Gmail peddled orders. Cheapest cover first."""
    q = db.table("v_n2s_orders").select(_BOOK_COLS)
    if source:
        q = q.ilike("s4k_source", f"%{str(source)[:40]}%")
    if with_cover is not None:
        q = q.eq("has_cover", bool(with_cover))
    if profitable_only:
        q = q.lt("cover_cost", 0)
    if ped_only:
        q = q.lt("n2s_id", 0)
    rows = q.order("cover_cost", desc=False).limit(_clamp(limit, 1, 500, 100)).execute().data or []
    for r in rows:
        r["ped"] = (r.get("n2s_id") or 0) < 0
        c = r.get("cover_cost")
        r["profit"] = None if c is None else round(-float(c), 2)
    covered = [r for r in rows if r.get("has_cover")]
    return {"count": len(rows), "covered": len(covered), "uncovered": len(rows) - len(covered),
            "profitable": sum(1 for r in covered if (r["profit"] or 0) > 0), "orders": rows}


def n2s_order(db, order_number: str) -> dict:
    """One order end to end: its book row (if still open), every cover it has had (newest
    first) and every GoTickets dry-run decision on it. `order_number` is the marketplace's own
    order number (EVO's composite or its order part both work)."""
    num = str(order_number or "").strip()[:64]
    if not num:
        return {"error": "order_number is required"}
    # It goes into a PostgREST or() filter string, so only order-number characters pass.
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", num):
        return {"error": "order_number may only contain letters, digits, '-', '_' and '.'"}
    book = (db.table("v_n2s_orders").select(_BOOK_COLS)
            .or_(f"order_number.eq.{num},n2s_order_key.eq.{num}").limit(5).execute().data) or []
    hist = (db.table("n2s_cover_history").select(_HIST_COLS).eq("order_number", num)
            .order("observed_at", desc=True).limit(100).execute().data) or []
    dry = (db.table("n2s_gt_order_dryrun").select(_GT_DRYRUN_COLS).eq("order_number", num)
           .order("dryrun_id", desc=True).limit(50).execute().data) or []
    return {"order_number": num, "open": book, "cover_history": hist,
            "gt_dryrun": [_gt_dryrun_row(r) for r in dry]}


_HIST_COLS = (
    "observed_at,event_kind,n2s_id,order_number,marketplace,event_name,event_date,sold_section,"
    "sold_row,sold_qty,sold_price_each,sub_source,sub_listing_id,sub_section,sub_row,sub_qty,"
    "sub_price_each,sub_total,cover_cost,cover_gate,cover_label")


def n2s_cover_history(db, days: int = 1, sub_source: str | None = None, gate: int | None = None,
                      event_kind: str | None = None, limit: int = 200) -> dict:
    """Cover changes over the last `days` (newest first): `appeared` / `changed` / `gone`
    per order, with the listing, price, gate and `cover_cost` at that moment. Filter by
    `sub_source` (gotickets, tevo_market, seatgeek, ...), `gate` 1-6 or `event_kind`."""
    since = (datetime.now(timezone.utc) - timedelta(days=_clamp(days, 1, 30, 1))).isoformat()
    q = db.table("n2s_cover_history").select(_HIST_COLS).gte("observed_at", since)
    if sub_source:
        q = q.eq("sub_source", str(sub_source)[:40])
    if gate is not None:
        q = q.eq("cover_gate", _clamp(gate, 1, 6, 1))
    if event_kind in ("appeared", "changed", "gone"):
        q = q.eq("event_kind", event_kind)
    rows = q.order("observed_at", desc=True).limit(_clamp(limit, 1, 1000, 200)).execute().data or []
    return {"count": len(rows), "rows": rows}


def ped_orders(db, days_ahead: int = 7, include_past: bool = False, limit: int = 200) -> dict:
    """Gmail peddled (Need2Buy / WaitToBuy) sales still to be bought, from the inbox feed:
    site, order, event, owed section/row/quantity and sold price each, soonest event first.
    Test orders are excluded. `days_ahead` bounds the event date (max 365)."""
    today = datetime.now(timezone.utc).date()
    q = (db.table("inbox_n2b").select(
        "site,order_no,tevo_event_id,event_name,event_date,venue,section,row,quantity,sold_ea,"
        "sale_total,sale_at,last_reported_at")
        .filter("order_no", "not.like", "TEST%")
        .lte("event_date", (today + timedelta(days=_clamp(days_ahead, 0, 365, 7))).isoformat()))
    if not include_past:
        q = q.gte("event_date", today.isoformat())
    rows = q.order("event_date").limit(_clamp(limit, 1, 1000, 200)).execute().data or []
    return {"count": len(rows), "events": len({r.get("tevo_event_id") for r in rows}), "orders": rows}


def n2s_health(db) -> dict:
    """Is the N2S pipeline alive? CRM ingest over the last hour (fetches, failures, new
    orders), the newest order we hold, when the cover queue last rebuilt and how many open
    orders have a cover, and the newest GoTickets dry-run row."""
    hour = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    log = (db.table("n2s_crm_direct_log").select("fetched_at,status,new_orders")
           .gte("fetched_at", hour).limit(1000).execute().data) or []
    newest = (db.table("n2s_items").select("alert_at").gt("n2s_id", 0)
              .order("alert_at", desc=True).limit(1).execute().data) or []
    queue = (db.table("n2s_cover_queue").select("refreshed_at,sub_source,cover_gate")
             .limit(2000).execute().data) or []
    dry = (db.table("n2s_gt_order_dryrun").select("dryrun_id,captured_at")
           .order("dryrun_id", desc=True).limit(1).execute().data) or []
    by_src: dict[str, int] = {}
    for r in queue:
        by_src[r.get("sub_source") or "?"] = by_src.get(r.get("sub_source") or "?", 0) + 1
    return {
        "crm_last_hour": {"fetches": len(log),
                          "failed": sum(1 for r in log if r.get("status") != 200),
                          "new_orders": sum(int(r.get("new_orders") or 0) for r in log),
                          "last_fetch": max((r["fetched_at"] for r in log), default=None)},
        "newest_order_at": newest[0]["alert_at"] if newest else None,
        "cover_queue": {"rows": len(queue), "by_source": by_src,
                        "refreshed_at": max((r["refreshed_at"] for r in queue if r.get("refreshed_at")),
                                            default=None)},
        "gt_dryrun_newest": dry[0] if dry else None,
    }


_GT_DRYRUN_COLS = (
    "dryrun_id,captured_at,n2s_id,order_number,s4k_source,event_name,event_date,"
    "sold_section,sold_row,sold_qty,sold_ea,sub_section,sub_row,sub_qty,quoted_ea,quoted_total,"
    "cover_cost,cover_gate,cover_label,live_price_ea,live_qty,sub_view,decision,skip_reasons,payload")


def _level_word(s: Any) -> str:
    return re.sub(r"[^a-z]", "", str(s or "").lower())


def _gt_dryrun_row(r: dict) -> dict:
    """One dry-run row for a caller: profit sign flipped to read naturally, PED and the
    Floor-vs-Loge level check made explicit, and the would-be order body kept."""
    a, b = _level_word(r.get("sold_section")), _level_word(r.get("sub_section"))
    cost = r.get("cover_cost")
    out = {k: r.get(k) for k in (
        "dryrun_id", "captured_at", "order_number", "s4k_source", "event_name", "event_date",
        "sold_section", "sold_row", "sold_qty", "sold_ea", "sub_section", "sub_row", "sub_qty",
        "quoted_ea", "quoted_total", "cover_gate", "cover_label", "decision", "skip_reasons",
        "sub_view")}
    out["profit"] = None if cost is None else round(-float(cost), 2)
    out["ped"] = (r.get("n2s_id") or 0) < 0
    out["level_mismatch"] = r.get("cover_gate") == 1 and bool(a) and bool(b) and a != b
    payload = r.get("payload") or {}
    out["gt_event_id"] = payload.get("eventId")
    out["gt_listing_id"] = payload.get("listingId")
    out["would_send"] = payload
    return out


def gt_dryrun(db, decision: str | None = None, gate: int | None = None, ped_only: bool = False,
              since: str | None = None, limit: int = 50) -> dict:
    """GoTickets auto-buy DRY RUN rows (internal), newest first: what an auto-buyer WOULD have
    ordered for each new GoTickets cover, and why it would or would not. Nothing was ever sent.
    `decision` would_buy|skip; `gate` 1-6 (1 = Index, same section, the only gate that buys);
    `ped_only` = Gmail peddled (Need2Buy) orders; `since` YYYY-MM-DD. Each row has `profit`
    (+ = cover cheaper than the sale), `level_mismatch` (gate-1 match whose named level differs,
    e.g. sold Floor 6 vs listing Loge 6 — check by hand) and `would_send` (the order body)."""
    q = db.table("n2s_gt_order_dryrun").select(_GT_DRYRUN_COLS)
    if decision in ("would_buy", "skip"):
        q = q.eq("decision", decision)
    if gate is not None:
        q = q.eq("cover_gate", _clamp(gate, 1, 6, 1))
    if ped_only:
        q = q.lt("n2s_id", 0)
    if since:
        try:
            q = q.gte("captured_at", datetime.strptime(str(since)[:10], "%Y-%m-%d").replace(tzinfo=timezone.utc).isoformat())
        except ValueError:
            return {"error": "since must be YYYY-MM-DD"}
    rows = q.order("dryrun_id", desc=True).limit(_clamp(limit, 1, 500, 50)).execute().data or []
    return {"rows": [_gt_dryrun_row(r) for r in rows], "count": len(rows),
            "note": "Dry run only: no order was sent to GoTickets."}


def gt_dryrun_summary(db, days: int = 7) -> dict:
    """GoTickets auto-buy DRY RUN summary (internal) over the last `days`: totals, would-buy
    spend and profit, results per gate (how many covers were profitable and how much profit the
    gate-only-1 rule left on the table), skip reasons, every would-buy with its level check,
    the most profitable skips, and GoTickets listings offered to more than one order (the dry
    run has no cross-order listing lock). Nothing was ever sent."""
    since = (datetime.now(timezone.utc) - timedelta(days=_clamp(days, 1, 90, 7))).isoformat()
    rows = (db.table("n2s_gt_order_dryrun").select(_GT_DRYRUN_COLS).gte("captured_at", since)
            .order("dryrun_id", desc=True).limit(5000).execute().data) or []
    items = [_gt_dryrun_row(r) for r in rows]
    buys = [r for r in items if r["decision"] == "would_buy"]
    gates: dict[int, dict] = {}
    reasons: dict[str, int] = {}
    listings: dict[str, set] = {}
    for r, raw in zip(items, rows):
        g = gates.setdefault(r["cover_gate"] or 0, {"rows": 0, "would_buy": 0, "profitable": 0,
                                                    "profit_available": 0.0, "loss": 0.0})
        g["rows"] += 1
        g["would_buy"] += r["decision"] == "would_buy"
        p = r["profit"]
        if p is not None and p > 0:
            g["profitable"] += 1
            g["profit_available"] = round(g["profit_available"] + p, 2)
        elif p is not None and p < 0:
            g["loss"] = round(g["loss"] + p, 2)
        for why in r["skip_reasons"] or []:
            reasons[why] = reasons.get(why, 0) + 1
        if r["gt_listing_id"]:
            listings.setdefault(str(r["gt_listing_id"]), set()).add(raw.get("n2s_id"))
    shared = sorted(((lid, len(ids)) for lid, ids in listings.items() if len(ids) > 1),
                    key=lambda x: -x[1])[:10]
    skips = sorted((r for r in items if r["decision"] == "skip" and (r["profit"] or 0) > 0),
                   key=lambda r: -r["profit"])[:10]
    slim = ("dryrun_id", "captured_at", "s4k_source", "event_name", "event_date", "sold_section",
            "sold_row", "sold_qty", "sold_ea", "sub_section", "sub_row", "quoted_total", "profit",
            "cover_gate", "cover_label", "skip_reasons", "ped", "level_mismatch")
    return {
        "days": _clamp(days, 1, 90, 7),
        "rows": len(items), "would_buy": len(buys), "skip": len(items) - len(buys),
        "ped_rows": sum(r["ped"] for r in items),
        "would_buy_spend": round(sum(float(r["quoted_total"] or 0) for r in buys), 2),
        "would_buy_profit": round(sum(r["profit"] or 0 for r in buys), 2),
        "level_mismatches": sum(r["level_mismatch"] for r in buys),
        "by_gate": {str(k): v for k, v in sorted(gates.items())},
        "skip_reasons": reasons,
        "would_buys": [{k: r[k] for k in slim} for r in buys],
        "top_profitable_skips": [{k: r[k] for k in slim} for r in skips],
        "listings_on_multiple_orders": [{"gt_listing_id": lid, "orders": n} for lid, n in shared],
        "note": "Dry run only: no order was sent to GoTickets. Gates 2-6 are skipped by rule "
                "(gate_moves_buyer); profit is sale minus listing total.",
    }




def _tm_primary_sections(body: dict, sections: list[str]) -> dict:
    """Ticketmaster ISMDS facets + offers -> primary seats and cheapest all-in price per
    section (all sections when `sections` is empty)."""
    offers = {o.get("offerId"): o for o in ((body.get("_embedded") or {}).get("offer") or [])}
    want = {s.upper() for s in sections}
    out: dict[str, dict] = {}
    for f in body.get("facets") or []:
        if "primary" not in (f.get("inventoryTypes") or []) or not f.get("available", True):
            continue
        sec = str(f.get("section") or "")
        if want and sec.upper() not in want:
            continue
        prices = [float(offers[o]["totalPrice"]) for o in f.get("offers") or []
                  if o in offers and offers[o].get("totalPrice") is not None]
        d = out.setdefault(sec, {"section": sec, "seats": 0, "min_total_each": None})
        d["seats"] += int(f.get("count") or 0)
        if prices:
            lo = min(prices)
            d["min_total_each"] = lo if d["min_total_each"] is None else min(d["min_total_each"], lo)
    return out


def tm_primary(db, event_url: str, sections: list[str] | None = None) -> dict:
    """Ticketmaster PRIMARY (box-office) inventory for one event, via TicketsData — costs one
    TicketsData credit per call. `event_url` is the ticketmaster.com event URL; `sections`
    narrows to the sections you owe (default: all). Returns seats and the cheapest all-in price
    each per section, plus the credits left. Read-only: nothing is held or bought."""
    url = str(event_url or "").strip()
    if not re.match(r"^https://www\.ticketmaster\.com/.+/event/[0-9A-Fa-f]+", url):
        return {"error": "event_url must be a https://www.ticketmaster.com/.../event/<id> URL"}
    from ticketsdata_client import TicketsDataClient, TicketsDataError

    try:
        res = TicketsDataClient.from_vault(db, timeout=90).fetch("ticketmaster", url)
    except TicketsDataError as e:
        return {"error": str(e)}
    body = res.get("body") or {}
    secs = _tm_primary_sections(body, [str(s) for s in (sections or [])][:20])
    return {"event_url": url, "quota_remaining": res.get("quota_remaining"),
            "primary_sections": sorted(secs.values(), key=lambda d: (d["min_total_each"] is None,
                                                                    d["min_total_each"] or 0))}


N2S_TOOLS: tuple[Callable, ...] = (
    n2s_health, n2s_book, n2s_order, n2s_cover_history, ped_orders, gt_dryrun, gt_dryrun_summary,
    tm_primary)


def make_n2s_app(get_db: Callable[[], Any], limiter: Any | None = None) -> MCPApp:
    """The /n2s-mcp ASGI app: internal-tier keys only (external keys get 403)."""
    return MCPApp(get_db, limiter=limiter, servers={
        INTERNAL: _make_server("s4k-n2s", N2S_TOOLS, get_db, instructions=N2S_INSTRUCTIONS,
                               onboarding=False)})
