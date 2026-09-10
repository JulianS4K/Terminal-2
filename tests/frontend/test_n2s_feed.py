"""N2S covers panel — live-feed behaviour (regression net).

The covers panel is a FEED: it repaints itself every 60s off
`n2s_cover_queue`. That repaint is what makes these tests necessary — three of
the behaviours below are invisible on a page you only ever load once, and two
of them are the difference between a useful panel and a dangerous one:

  * a verify verdict MUST be dropped when the queue reallocates that order to a
    different listing, or it sits there reading "checked and fine" about
    tickets that are no longer on offer;
  * a claim's fill sheet MUST survive the repaint (and not stack), or it
    vanishes from under someone mid-purchase;
  * claiming MUST issue a POST. It previously did not: `Terminal.api()` took
    only a path, so the `{method:'POST'}` the caller passed was silently
    dropped and the claim went out as a GET to a POST-only route. Nothing at
    the call site errored. That is precisely the class of defect a smoke test
    that merely loads the page cannot see, hence this module.

Playwright routing note: routes match MOST-RECENTLY-REGISTERED first, so the
catch-all is registered before the specific stubs, not after.
"""
from __future__ import annotations

import json
import re

import pytest

pytest.importorskip("playwright")

# Python Playwright treats a plain string as a GLOB; only a compiled pattern is
# a regex. Passing a JS-style "/.../" string here matches nothing, silently.
_COVERS_RE = re.compile(r"/api/broker/n2s-covers\?")
_VERIFY_RE = re.compile(r"/api/broker/n2s-covers/verify")
_INTENT_RE = re.compile(r"buy-intent")


def _cover(n2s_id, listing_id="L1", sub_ea=120):
    return {
        "n2s_id": n2s_id, "order_number": f"ORD{n2s_id}", "s4k_source": "StubHub",
        "event_name": f"Event {n2s_id}", "event_date": "2026-10-01",
        "venue": "Test Arena", "tevo_event_id": 9, "section": "101",
        "order_row": "5", "quantity": 2, "sold_ea": 100,
        "sub_source": "gotickets", "sub_listing_id": listing_id,
        "sub_section": "101", "sub_row": "4", "sub_qty": 2, "sub_avail": 2,
        "sub_ea": sub_ea,
        "sub_total": sub_ea * 2, "cover_cost": 40, "rows_closer": 1,
        "buy_url": f"https://example.test/{n2s_id}",
        "captured_at": "2026-09-10T00:00:00Z", "cover_rank": 1,
        "fifo_position": 1, "refreshed_at": "2026-09-10T00:00:00Z",
        # has_cover drives whether the row is actionable at all — a gap row
        # renders its reason and gets no claim button.
        "has_cover": True, "no_cover_reason": None,
        "alert_at": "2026-09-10T00:00:00Z",
        "open_intent_id": None, "open_intent_by": None,
    }


def _gap(n2s_id, reason="no_match"):
    """An open obligation with no cover — kept on screen deliberately."""
    row = _cover(n2s_id)
    row.update({k: None for k in (
        "sub_source", "sub_listing_id", "sub_section", "sub_row", "sub_qty", "sub_avail",
        "sub_ea", "sub_total", "cover_cost", "rows_closer", "buy_url",
        "captured_at", "cover_rank", "fifo_position", "refreshed_at")})
    row.update({"has_cover": False, "no_cover_reason": reason})
    return row


def _payload(rows):
    covered = [r for r in rows if r.get("has_cover")]
    reasons: dict[str, int] = {}
    for r in rows:
        if r.get("no_cover_reason"):
            reasons[r["no_cover_reason"]] = reasons.get(r["no_cover_reason"], 0) + 1
    return json.dumps({
        "rows": rows, "count": len(rows), "covered": len(covered),
        "uncovered": len(rows) - len(covered), "by_no_cover_reason": reasons,
        "at_or_below_sale": 0, "displaced": 0,
        "total_cover_cost": 40 * len(covered),
        "refreshed_at": "2026-09-10T00:00:00Z", "filters": {},
    })


def _json_route(route, body):
    route.fulfill(status=200, content_type="application/json", body=body)


@pytest.fixture()
def feed_page(browser, live_server):
    """Covers page with the API stubbed and the clock under our control."""
    page = browser.new_page()
    page.clock.install()
    # Registered first => lowest precedence; the specific stubs below win.
    page.route("**/api/**", lambda r: _json_route(r, '{"rows":[],"count":0}'))
    yield page
    page.close()


def test_claim_issues_a_post_not_a_get(feed_page, live_server):
    """The buy-intent route is POST-only; a dropped method makes claim a no-op."""
    methods = []
    feed_page.route(_COVERS_RE,
                    lambda r: _json_route(r, _payload([_cover(1)])))

    def _claim(route):
        methods.append(route.request.method)
        _json_route(route, json.dumps({
            "intent": {"intent_id": 7, "payload_ready": True, "payload_gaps": [],
                       "operator_fills": ["paymentMethodToken"]},
            "bought": False}))

    feed_page.route(_INTENT_RE, _claim)
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector('#n2sTable tr[data-n2s]')
    feed_page.click('#n2sTable tr[data-n2s="1"] .n2s-claim')
    feed_page.wait_for_selector("tr.n2s-sheet")
    assert methods == ["POST"]
    # The sheet names what the operator still types at checkout.
    assert "paymentMethodToken" in feed_page.eval_on_selector("tr.n2s-sheet td",
                                                              "e => e.textContent")


def test_an_already_claimed_row_offers_no_claim_button(feed_page, live_server):
    """One open intent per order is enforced by a unique index, so a row someone
    else already claimed can only 409. Show who has it instead of offering a
    button whose sole outcome is an error."""
    taken = _cover(2)
    taken.update({"open_intent_id": 7, "open_intent_by": "someone@s4kent.com"})
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload([_cover(1), taken])))
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable tr[data-n2s]")

    assert len(feed_page.query_selector_all("#n2sTable .n2s-claim")) == 1
    assert feed_page.query_selector('#n2sTable tr[data-n2s="1"] .n2s-claim')
    assert feed_page.query_selector('#n2sTable tr[data-n2s="2"] .n2s-claim') is None
    row2 = feed_page.eval_on_selector('#n2sTable tr[data-n2s="2"]', "e => e.textContent")
    assert "claimed" in row2


def test_claim_records_who_asked(feed_page, live_server):
    """requested_by is the audit trail the one-intent-per-order rule exists to
    provide. Without it every intent stores NULL and the row reads 'claimed by
    someone' forever."""
    seen = {}

    def _claim(route):
        seen["url"] = route.request.url
        _json_route(route, json.dumps({"intent": {"intent_id": 7, "payload_ready": True,
                                                  "payload_gaps": [], "operator_fills": []},
                                       "bought": False}))

    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload([_cover(1)])))
    feed_page.route(_INTENT_RE, _claim)
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector('#n2sTable tr[data-n2s="1"] .n2s-claim')
    # Override AFTER load: auth.js assigns window.TerminalAuth on script
    # execution, so an init script would just be overwritten by the real one.
    feed_page.evaluate(
        "() => { window.TerminalAuth = Object.assign({}, window.TerminalAuth,"
        "        { getEmail: () => 'julian@s4kent.com' }); }")
    feed_page.click('#n2sTable tr[data-n2s="1"] .n2s-claim')
    feed_page.wait_for_selector("tr.n2s-sheet")
    assert "requested_by=julian%40s4kent.com" in seen["url"]


def test_empty_page_explains_the_timer_filter(feed_page, live_server):
    """The default hides every order past its 15-minute CRM timer — measured at
    108 of 108. An empty table that just said "no orders" would report a clear
    book while 108 obligations sat unhandled, so the count and the way back
    must both be on screen."""
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, json.dumps({
        "rows": [], "count": 0, "covered": 0, "uncovered": 0,
        "by_no_cover_reason": {}, "at_or_below_sale": 0, "displaced": 0,
        "total_cover_cost": 0, "hidden_late": 108, "truncated": False,
        "refreshed_at": None, "filters": {}})))
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable .empty")
    txt = feed_page.eval_on_selector("#n2sTable", "e => e.textContent")
    assert "108" in txt
    assert "timer expired" in txt
    assert "include late" in txt
    # and the control that reverses it is present
    assert feed_page.query_selector("#n2sLate")


def test_poll_marks_only_new_arrivals(feed_page, live_server):
    """First load flashes nothing; the next poll flashes only what arrived."""
    state = {"n": 0}

    def _covers(route):
        state["n"] += 1
        rows = ([_cover(1), _cover(2)] if state["n"] == 1
                else [_cover(1), _cover(2), _cover(3)])
        _json_route(route, _payload(rows))

    feed_page.route(_COVERS_RE, _covers)
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector('#n2sTable tr[data-n2s]')
    # Nothing is "new" on a first load — every row flashing is noise.
    assert feed_page.query_selector_all("#n2sTable tr.n2s-row-new") == []

    feed_page.clock.fast_forward(61_000)
    feed_page.wait_for_function(
        "() => document.querySelectorAll('#n2sTable tr[data-n2s]').length === 3")
    flagged = feed_page.eval_on_selector_all(
        "#n2sTable tr.n2s-row-new", "t => t.map(x => x.dataset.n2s)")
    assert flagged == ["3"]
    assert state["n"] == 2, "the 60s poll did not fire"


def test_orders_without_a_sub_are_shown_and_are_not_actionable(feed_page, live_server):
    """The rewrite's whole point: an uncovered obligation stays on screen, names
    WHY there is no sub, and offers no claim button — claiming would 409, which
    is a worse way to learn there is no cover than simply not offering it."""
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload(
        [_cover(1), _gap(2), _gap(3, "unmapped")])))
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable tr[data-n2s]")

    assert len(feed_page.query_selector_all("#n2sTable tr[data-n2s]")) == 3
    assert len(feed_page.query_selector_all("#n2sTable tr.n2s-row-gap")) == 2
    # Only the covered row can be claimed.
    assert len(feed_page.query_selector_all("#n2sTable .n2s-claim")) == 1
    # Each gap says which of the three situations it is.
    reasons = feed_page.eval_on_selector_all(
        # Addressed by class, not position: a positional selector silently
        # re-points at a different column the next time one is added.
        "#n2sTable tr.n2s-row-gap .n2s-sub",
        "t => t.map(x => x.textContent.trim())")
    assert sorted(reasons) == ["no match", "unmapped"]
    meta = feed_page.eval_on_selector("#n2sMeta", "e => e.textContent")
    assert "3 open" in meta and "1 with a sub" in meta and "2 without" in meta


def test_verdict_is_dropped_when_the_cover_is_reallocated(feed_page, live_server):
    """FIFO can move an order to another listing between polls. A verdict about
    the OLD listing must not survive that — it would read as reassurance about
    tickets that are no longer being offered here."""
    state = {"n": 0}

    def _covers(route):
        state["n"] += 1
        rows = ([_cover(1, "LA"), _cover(2, "LB")] if state["n"] == 1
                else [_cover(1, "LA"), _cover(2, "LZ", 150)])
        _json_route(route, _payload(rows))

    feed_page.route(_COVERS_RE, _covers)
    feed_page.route(_VERIFY_RE, lambda r: _json_route(r, json.dumps({
        "rows": [{"n2s_id": 1, "verdict": "ok", "buyable": True, "price_delta_ea": 0},
                 {"n2s_id": 2, "verdict": "ok", "buyable": True, "price_delta_ea": 0}],
        "count": 2, "buyable": 2, "by_verdict": {"ok": 2}})))

    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector('#n2sTable tr[data-n2s]')
    feed_page.click("#n2sVerify")
    feed_page.wait_for_function(
        "() => document.querySelector('#n2sTable tr[data-n2s=\\\"2\\\"] .n2s-verdict')"
        ".textContent.includes('ok')")

    feed_page.clock.fast_forward(61_000)
    feed_page.wait_for_function(
        "() => document.querySelector('#n2sTable tr[data-n2s=\\\"2\\\"]')"
        ".dataset.fp.includes('LZ')")

    kept = feed_page.eval_on_selector(
        '#n2sTable tr[data-n2s="1"] .n2s-verdict', "e => e.textContent.trim()")
    dropped = feed_page.eval_on_selector(
        '#n2sTable tr[data-n2s="2"] .n2s-verdict', "e => e.textContent.trim()")
    assert "ok" in kept, "an unchanged cover should keep its verdict"
    assert dropped == "—", "a reallocated cover must lose its stale verdict"


def test_a_split_take_names_the_lot_it_comes_from(feed_page, live_server):
    """Buying 2 of a 4-seat listing is only legal because the seller's splits
    allow it. The row must say so — otherwise "2" reads as a 2-seat listing and
    the operator has no way to tell the vendor console will show four."""
    split = _cover(1)
    split["sub_avail"] = 4
    exact = _cover(2)
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload([split, exact])))
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable tr[data-n2s]")

    assert "of 4" in feed_page.eval_on_selector(
        '#n2sTable tr[data-n2s="1"]', "e => e.textContent")
    # An exact-quantity cover has no lot to disclose, so it stays unadorned.
    assert "of " not in feed_page.eval_on_selector(
        '#n2sTable tr[data-n2s="2"]', "e => e.textContent")


def test_an_over_delivery_says_how_many_seats_are_actually_bought(feed_page, live_server):
    """When nothing sells the owed quantity we buy the whole lot and eat the
    spare seat. The row shows the OWED quantity next to the seat, so without a
    second marker the operator sends a buy for 2 and is charged for 3."""
    over = _cover(1)
    over.update({"quantity": 2, "sub_qty": 3, "sub_avail": 3})
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload([over])))
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable tr[data-n2s]")

    text = feed_page.eval_on_selector('#n2sTable tr[data-n2s="1"]', "e => e.textContent")
    assert "buy 3" in text
    # A whole-lot buy is not a split take; "of 3" would claim the opposite.
    assert "of 3" not in text



def test_row_shows_the_marketplace_order_number(feed_page, live_server):
    """Knowing StubHub failed is useless without knowing WHICH StubHub order.
    EVO additionally shows its bare order key, because its order_number is an
    <invoice>-<order> composite that its console will not match."""
    sh = _cover(1)
    sh.update({"s4k_source": "StubHub", "order_number": "653320088",
               "n2s_order_key": "653320088"})
    evo = _cover(2)
    evo.update({"s4k_source": "EVO", "order_number": "8047273-19083928",
                "n2s_order_key": "19083928"})
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload([sh, evo])))
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable tr[data-n2s]")

    assert "653320088" in feed_page.eval_on_selector(
        '#n2sTable tr[data-n2s="1"] .n2s-ord', "e => e.textContent")
    evo_cell = feed_page.eval_on_selector(
        '#n2sTable tr[data-n2s="2"] .n2s-ord', "e => e.textContent")
    assert "8047273-19083928" in evo_cell and "19083928" in evo_cell
    # A source whose key equals its order number gets no redundant second line.
    assert feed_page.eval_on_selector(
        '#n2sTable tr[data-n2s="1"] .n2s-ord',
        "e => e.querySelectorAll('div').length") == 0


def test_profit_filter_says_gaps_are_hidden(feed_page, live_server):
    """Showing "0 without" under this filter would read as a clean book. The
    uncovered rows are gone by construction — a gap has no cover_cost."""
    def _covers(route):
        body = json.loads(_payload([_cover(1)]))
        body["filters"] = {"profitable": True}
        body["uncovered"] = 0
        _json_route(route, json.dumps(body))

    feed_page.route(_COVERS_RE, _covers)
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable tr[data-n2s]")
    meta = feed_page.eval_on_selector("#n2sMeta", "e => e.textContent")
    assert "gaps hidden by this filter" in meta
    assert "without" not in meta


def test_empty_profitable_book_does_not_blame_the_timer(feed_page, live_server):
    """Under the profit filter the honest reading is "nothing settles below its
    sale", which the 15-minute timer has nothing to do with. Pointing at the
    Timer control there sends the operator to a switch that cannot help."""
    def _covers(route):
        _json_route(route, json.dumps({
            "rows": [], "count": 0, "covered": 0, "uncovered": 0,
            "by_no_cover_reason": {}, "at_or_below_sale": 0, "displaced": 0,
            "total_cover_cost": 0, "hidden_late": 108,
            "refreshed_at": "2026-09-10T05:00:00Z",
            "filters": {"profitable": True}}))

    feed_page.route(_COVERS_RE, _covers)
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable .empty")
    txt = feed_page.eval_on_selector("#n2sTable .empty", "e => e.textContent")
    assert "settles for less than the seat sold for" in txt
    assert "timer" not in txt.lower()


def test_uncatalogued_event_does_not_claim_we_searched(feed_page, live_server):
    """'no match' means listings were searched and none fit. An event we never
    ingested was never searched, and the fix is to ingest it — not to go
    hunting inventory that was never queried."""
    gap = _gap(1, "event_not_catalogued")
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload([gap])))
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable tr[data-n2s]")
    cell = feed_page.eval_on_selector('#n2sTable tr[data-n2s="1"] .n2s-sub',
                                      "e => e.textContent")
    assert "event not in catalogue" in cell
    assert "no match" not in cell


def test_profitable_only_is_an_option_of_the_sub_filter(feed_page, live_server):
    """"profitable" is a SUBSET of "has sub", not an independent axis. Two
    separate selects let the operator ask for "no sub" AND "profitable only",
    a contradiction that can only return an empty page — so it is one control,
    and picking it sends profitable=true and no with_sub."""
    urls = []

    def _covers(route):
        urls.append(route.request.url)
        _json_route(route, _payload([_cover(1)]))

    feed_page.route(_COVERS_RE, _covers)
    feed_page.goto(f"{live_server}/terminal/subs.html", wait_until="domcontentloaded")
    feed_page.wait_for_selector("#n2sTable tr[data-n2s]")

    # The retired standalone control must be gone, not merely hidden.
    assert feed_page.query_selector("#n2sProfit") is None
    opts = feed_page.eval_on_selector_all(
        "#n2sHas option", "o => o.map(x => x.value)")
    assert opts == ["", "true", "false", "profit"]

    feed_page.select_option("#n2sHas", "profit")
    feed_page.wait_for_function(
        "() => window.__n2sLast !== undefined || true")
    feed_page.wait_for_timeout(300)
    last = urls[-1]
    assert "profitable=true" in last
    assert "with_sub" not in last


def test_gate_label_distinguishes_actionable_from_offer(feed_page, live_server):
    """Gates 1-2 and 3-6 must NOT render the same.

    The label is a workflow instruction, not a badge: gates 1-2 keep the buyer
    in the section they purchased and are directly actionable, gates 3-6 MOVE
    them and need consent before purchase. One uniform chip would erase exactly
    the distinction the label exists to carry, so this asserts the two get
    different classes rather than merely that some text appears.
    """
    a = _cover(1); a.update({"cover_gate": 1, "cover_label": "Index"})
    b = _cover(2, listing_id="L2")
    b.update({"cover_gate": 4, "cover_label": "offer subs s4ktrading"})
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload([a, b])))
    feed_page.goto(f"{live_server}/static/terminal/subs.html")
    cells = feed_page.locator(".n2s-gate-cell .n2s-gate")
    cells.first.wait_for()
    assert cells.count() == 2
    assert "n2s-gate-direct" in cells.nth(0).get_attribute("class")
    assert "n2s-gate-offer" in cells.nth(1).get_attribute("class")
    # the offer variant must SAY so, not just be a colour
    assert "offer" in (cells.nth(1).get_attribute("title") or "").lower()


def test_gate_label_absent_on_uncovered_row(feed_page, live_server):
    """No cover means no gate — labelling a gap row would invent work."""
    feed_page.route(_COVERS_RE, lambda r: _json_route(r, _payload([_gap(3)])))
    feed_page.goto(f"{live_server}/static/terminal/subs.html")
    cell = feed_page.locator(".n2s-gate-cell").first
    cell.wait_for()
    assert cell.locator(".n2s-gate").count() == 0


def test_zone_unverified_suffix_renders_as_its_own_chip(feed_page, live_server):
    """The caveat must be separable from the gate name, and stay a caveat.

    " zone unverified" is not part of the gate's identity — it says the
    same-zone rule could not be CHECKED at this venue, which is a different
    claim from a gate. Rendered inside the label it reads as a longer gate
    name; rendered beside it, it reads as the qualifier it is. The title must
    also rule out the reading a reader will reach for on their own — that a
    zone was crossed — because those rows are refused and never arrive.
    """
    r = _cover(1)
    r.update({"cover_gate": 5,
              "cover_label": "Index Down offer subs zone unverified"})
    feed_page.route(_COVERS_RE, lambda route: _json_route(route, _payload([r])))
    feed_page.goto(f"{live_server}/static/terminal/subs.html")
    chips = feed_page.locator(".n2s-gate-cell .n2s-gate")
    chips.first.wait_for()
    assert chips.count() == 2
    # the gate keeps its own name, without the suffix trailing on the end
    assert chips.nth(0).inner_text().strip() == "Index Down offer subs"
    assert "n2s-gate-offer" in chips.nth(0).get_attribute("class")
    # the caveat is styled apart from both gate variants
    caveat_cls = chips.nth(1).get_attribute("class")
    assert "n2s-gate-unver" in caveat_cls
    assert "n2s-gate-offer" not in caveat_cls
    title = (chips.nth(1).get_attribute("title") or "").lower()
    assert "not mean" in title and "crossed" in title


def test_both_suffixes_on_one_label_keep_the_gate_name_intact(feed_page, live_server):
    """Two suffixes can co-occur, and the second must not swallow the first.

    A label built as gate + " zone unverified" + " repost single" is the case
    that breaks any consumer testing the whole label for equality. The gate
    chip must still show the bare gate name, and " repost single" must survive
    on it rather than being stripped along with the zone suffix.
    """
    r = _cover(1)
    r.update({"cover_gate": 6,
              "cover_label": "Down offer subs S4KTrading zone unverified repost single"})
    feed_page.route(_COVERS_RE, lambda route: _json_route(route, _payload([r])))
    feed_page.goto(f"{live_server}/static/terminal/subs.html")
    chips = feed_page.locator(".n2s-gate-cell .n2s-gate")
    chips.first.wait_for()
    assert chips.count() == 2
    assert chips.nth(0).inner_text().strip() == "Down offer subs S4KTrading repost single"
    assert chips.nth(1).inner_text().strip() == "zone unverified"


def test_gate_without_the_suffix_renders_one_chip(feed_page, live_server):
    """A verified in-zone downgrade must NOT pick up the caveat.

    Gates 5/6 now guarantee the substitute resolves to the same zone, so the
    plain label is the strong claim. If the caveat leaked onto it the guarantee
    would be invisible exactly where we do have it.
    """
    r = _cover(1)
    r.update({"cover_gate": 5, "cover_label": "Index Down offer subs"})
    feed_page.route(_COVERS_RE, lambda route: _json_route(route, _payload([r])))
    feed_page.goto(f"{live_server}/static/terminal/subs.html")
    chips = feed_page.locator(".n2s-gate-cell .n2s-gate")
    chips.first.wait_for()
    assert chips.count() == 1
    assert feed_page.locator(".n2s-gate-unver").count() == 0


def test_obstructed_view_is_flagged_on_a_gate_1_row(feed_page, live_server):
    """The dangerous case is precisely gate 1 + obstructed.

    Gate 1 says "same section the buyer purchased — actionable directly", so a
    reader who trusts the gate buys without asking. An obstructed seat is a
    downgrade the buyer has to accept. If the flag only appeared on "offer
    subs" gates it would never appear on the row that needs it most, so this
    asserts it on gate 1 specifically, and that the seller's own wording rides
    along rather than only our classification of it.
    """
    r = _cover(1)
    r.update({"cover_gate": 1, "cover_label": "Index",
              "sub_view": "obstructed", "sub_notes": "Obstructed view - pole"})
    feed_page.route(_COVERS_RE, lambda route: _json_route(route, _payload([r])))
    feed_page.goto(f"{live_server}/static/terminal/subs.html")
    gate = feed_page.locator(".n2s-gate-cell .n2s-gate").first
    gate.wait_for()
    flag = feed_page.locator(".n2s-gate-obstructed")
    assert flag.count() == 1
    # the gate itself is untouched — this is a separate axis, not a re-label
    assert gate.inner_text().strip() == "Index"
    assert "n2s-gate-direct" in gate.get_attribute("class")
    title = flag.get_attribute("title") or ""
    assert "Obstructed view - pole" in title      # the seller's words, verbatim
    assert "before purchasing" in title


def test_unknown_view_renders_differently_from_clear(feed_page, live_server):
    """"Not checked" must not look like "checked and fine".

    Every TEvo row is 'unknown' because public_notes is not mirrored into
    listings_snapshots, so this is the majority case, not an edge one. Showing
    nothing would let the absence of a warning read as an all-clear — the exact
    inversion this field exists to prevent.
    """
    unknown = _cover(1)
    unknown.update({"cover_gate": 1, "cover_label": "Index", "sub_view": "unknown"})
    clear = _cover(2, listing_id="L2")
    clear.update({"cover_gate": 1, "cover_label": "Index", "sub_view": "clear"})
    feed_page.route(_COVERS_RE, lambda route: _json_route(route, _payload([unknown, clear])))
    feed_page.goto(f"{live_server}/static/terminal/subs.html")
    feed_page.locator(".n2s-gate-cell .n2s-gate").first.wait_for()
    assert feed_page.locator(".n2s-gate-noview").count() == 1
    assert feed_page.locator(".n2s-gate-obstructed").count() == 0
    assert "NOT been checked" in (
        feed_page.locator(".n2s-gate-noview").get_attribute("title") or "")


def test_clear_view_adds_no_chip(feed_page, live_server):
    """A checked-and-clear seat is the quiet case — no chip, no noise."""
    r = _cover(1)
    r.update({"cover_gate": 1, "cover_label": "Index", "sub_view": "clear"})
    feed_page.route(_COVERS_RE, lambda route: _json_route(route, _payload([r])))
    feed_page.goto(f"{live_server}/static/terminal/subs.html")
    feed_page.locator(".n2s-gate-cell .n2s-gate").first.wait_for()
    assert feed_page.locator(".n2s-gate-cell .n2s-gate").count() == 1
    assert feed_page.locator(".n2s-gate-noview").count() == 0
