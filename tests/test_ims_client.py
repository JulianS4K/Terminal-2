"""The Indy 500's section prices, read from Indianapolis Motor Speedway's public price list (operator
2026-11-24: "build the indy 500 section price poller and show me listings"): ims_client.py, and its
place in the box-office poll's run."""
from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

import ims_client as ims  # noqa: E402
from core import primary_poll_sync as sync  # noqa: E402

RACE_DAY = date(2027, 5, 30)
MENU = ('<a href="#"><span><b>Indianapolis 500 presented by Gainbridge</b></span> '
        '<span class="meta">May 18-30, 2027 | INDYCAR</span></a>')


def _table(rows):
    body = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in row) + "</tr>" for row in rows)
    return f'<table class="ims-table"><tbody>{body}</tbody></table>'


HEADER = ["Location", "Seat Preview&nbsp;", "Oct. 28 - Jan. 3&nbsp;", "Jan. 4 - Feb. 28", "Mar. 1 - May 30"]
VIEW = '<span><a href="https://www.seats3d.com/x">View Seats</a></span>'
PRICES = MENU + _table([
    HEADER,
    ["A Stand", VIEW, "SOLD OUT", "SOLD OUT", "SOLD OUT"],
    ["C Stand", VIEW, "$166", "$171", "$171"],
    ["North Vista", VIEW, "$86 - $112", "$91 - $118", "$96 - $123"],
    ["Tower&nbsp;Terrace (Sec. 1-25)", VIEW, "$1,134.50", "Sold  Out", "$144"],
])
GENERAL = _table([
    ["Location", "Current Prices", "Event Day Prices"],
    ["Practice Days - Tuesday - Friday, May 18-21"],
    ["General Admission", "$25 per day", "$30 per day"],
    ["Indy 500 Race Day - Sunday, May 30"],
    ["Concert VIP", "$270", "$285"],
    ["General Admission", "$55", "$70"],
    ["Coors Light Snake Pit - Sunday, May 30"],
    ["General Admission Wristband*", "$50*", "$110*"],
])


class _Resp:
    def __init__(self, status=200, text=""):
        self.status_code, self.text = status, text


@pytest.fixture(autouse=True)
def _no_page_kept():
    ims._page.update(at=None, html=None)
    yield
    ims._page.update(at=None, html=None)


def _site(monkeypatch, pages, clock=None):
    """The speedway's site: {path: html or status}. Returns the paths asked for, in order."""
    asked = []

    def get(url, headers, timeout):
        assert url.startswith(ims.BASE) and headers["User-Agent"] == ims.USER_AGENT and timeout == ims.TIMEOUT_S
        path = url[len(ims.BASE):]
        asked.append(path)
        page = pages[path]
        return _Resp(page) if isinstance(page, int) else _Resp(200, page)

    monkeypatch.setattr(ims.requests, "get", get)
    if clock is not None:
        monkeypatch.setattr(ims.time, "monotonic", lambda: clock["now"])
    return asked


def test_the_event_is_the_race_day_the_sites_menu_names():
    assert ims.parse_event(PRICES) == {"name": "Indianapolis 500 presented by Gainbridge", "date": RACE_DAY}
    one_day = MENU.replace("May 18-30, 2027", "Sept. 5, 2027")
    assert ims.parse_event(one_day)["date"] == date(2027, 9, 5)
    for page in ("", None, "<b>Brickyard 400</b></span> <span class=\"meta\">July 25, 2027"):
        with pytest.raises(ims.ImsError, match="does not name the Indy 500"):
            ims.parse_event(page)
    with pytest.raises(ims.ImsError, match="not a month: Smarch"):
        ims.parse_event(MENU.replace("May 18-30", "Smarch 18-30"))
    with pytest.raises(ims.ImsError, match="not a date: Feb 30, 2027"):
        ims.parse_event(MENU.replace("May 18-30", "Feb 30"))


def test_the_sales_windows_get_their_years_from_race_day():
    cells = [ims._text(c) for c in HEADER]
    assert ims.parse_windows(cells, RACE_DAY) == [(date(2026, 10, 28), date(2027, 1, 3)),
                                                  (date(2027, 1, 4), date(2027, 2, 28)),
                                                  (date(2027, 3, 1), date(2027, 5, 30))]
    with pytest.raises(ims.ImsError, match="could not be read"):
        ims.parse_windows(["Location", "Seat Preview"], RACE_DAY)                  # no window at all
    with pytest.raises(ims.ImsError, match="could not be read"):
        ims.parse_windows(["Location", "Seat Preview", "Now", "Mar. 1 - May 30"], RACE_DAY)
    with pytest.raises(ims.ImsError, match="does not end on race day"):
        ims.parse_windows(["Location", "Seat Preview", "Mar. 1 - May 29"], RACE_DAY)


def test_a_price_cell_is_a_price_a_range_or_sold_out_and_nothing_else():
    assert ims.parse_price("$166") == (166.0, 166.0)
    assert ims.parse_price("$86 - $112") == (86.0, 112.0)
    assert ims.parse_price("$1,134.50") == (1134.5, 1134.5)
    assert ims.parse_price("SOLD OUT") is None and ims.parse_price(" Sold  out ") is None
    for cell in ("", "Call the ticket office", "TBD"):
        with pytest.raises(ims.ImsError, match="not a price"):
            ims.parse_price(cell)


def test_the_areas_on_sale_are_read_at_todays_window_and_a_sold_out_one_is_left_out():
    first = ims.parse_prices(PRICES, RACE_DAY, date(2026, 11, 24))
    assert first == [{"section": "C Stand", "low": 166.0, "high": 166.0},
                     {"section": "North Vista", "low": 86.0, "high": 112.0},
                     {"section": "Tower Terrace (Sec. 1-25)", "low": 1134.5, "high": 1134.5}]
    # before the first window opens its prices stand; in the second window Tower Terrace is sold out
    assert ims.parse_prices(PRICES, RACE_DAY, date(2026, 10, 1)) == first
    second = ims.parse_prices(PRICES, RACE_DAY, date(2027, 1, 4))
    assert [(a["section"], a["low"], a["high"]) for a in second] == [("C Stand", 171.0, 171.0),
                                                                    ("North Vista", 91.0, 118.0)]
    assert [a["low"] for a in ims.parse_prices(PRICES, RACE_DAY, RACE_DAY)] == [171.0, 96.0, 144.0]
    with pytest.raises(ims.ImsError, match="are over"):
        ims.parse_prices(PRICES, RACE_DAY, date(2027, 5, 31))
    with pytest.raises(ims.ImsError, match="no price table"):
        ims.parse_prices("<p>Tickets go on sale soon</p>", RACE_DAY, RACE_DAY)
    for broken in ("<table></table>", _table([["Location", "Seat Preview"]])):
        with pytest.raises(ims.ImsError, match="no sales windows"):
            ims.parse_prices(broken, RACE_DAY, RACE_DAY)
    for row in (["C Stand", VIEW, "$166"], ["", VIEW, "$166", "$171", "$171"]):
        with pytest.raises(ims.ImsError, match="a row of the price table"):
            ims.parse_prices(_table([HEADER, row]), RACE_DAY, RACE_DAY)
    with pytest.raises(ims.ImsError, match="not a price"):
        ims.parse_prices(_table([HEADER, ["C Stand", VIEW, "soon", "soon", "soon"]]), RACE_DAY, RACE_DAY)


def test_general_admission_is_race_days_own_row_at_the_event_day_price_on_the_day():
    assert ims.parse_general_admission(GENERAL, RACE_DAY, date(2026, 11, 24)) == 55.0
    assert ims.parse_general_admission(GENERAL, RACE_DAY, RACE_DAY) == 70.0
    sold_out = GENERAL.replace("<td>$55</td>", "<td>SOLD OUT</td>")
    assert ims.parse_general_admission(sold_out, RACE_DAY, date(2026, 11, 24)) is None
    # race day listed without general admission: none on sale, whether or not another heading follows
    for rows in ([["Indy 500 Race Day - Sunday, May 30"], ["Concert VIP", "$270", "$285"]],
                 [["Indy 500 Race Day - Sunday, May 30"], ["Snake Pit"], ["General Admission", "$50", "$110"]]):
        assert ims.parse_general_admission(_table(rows), RACE_DAY, RACE_DAY) is None
    with pytest.raises(ims.ImsError, match="has no race day"):
        ims.parse_general_admission(_table([["Practice Days"], ["General Admission", "$25", "$30"]]), RACE_DAY, RACE_DAY)
    with pytest.raises(ims.ImsError, match="general admission row"):
        ims.parse_general_admission(_table([["Race Day"], ["General Admission", "$55"]]), RACE_DAY, RACE_DAY)


def test_the_event_and_its_section_prices_come_from_two_public_pages(monkeypatch):
    clock = {"now": 1000.0}
    asked = _site(monkeypatch, {ims.PRICES_PATH: PRICES, ims.GA_PATH: GENERAL}, clock)
    (event,) = ims.events()
    assert event == {"id": "indy500-2027", "name": "Indianapolis 500 presented by Gainbridge",
                     "local_date": "2027-05-30", "local_time": None, "start_utc": None, "timezone": None,
                     "venue": "Indianapolis Motor Speedway", "city": "Indianapolis", "state": "IN",
                     "url": "https://www.indianapolismotorspeedway.com/events/indy500/buy-tickets/tickets-race-day",
                     "offer_id": None, "order_min": None, "order_max": None,
                     "total_available": None, "price_min": None, "price_max": None}
    rows = ims.listings(event, date(2026, 11, 24))
    assert [(r["id"], r["section"], r["price"], r["ticket_type"], r["ga"]) for r in rows] == [
        ("c-stand", "C Stand", 166.0, "Reserved seat: section price", False),
        ("north-vista:from", "North Vista", 86.0, "Reserved seat: lowest price in the section", False),
        ("north-vista:to", "North Vista", 112.0, "Reserved seat: highest price in the section", False),
        ("tower-terrace-sec-1-25", "Tower Terrace (Sec. 1-25)", 1134.5, "Reserved seat: section price", False),
        ("general-admission", "General Admission", 55.0, "General admission", True)]
    # a section price, not a seat block: no quantity or seats, and nothing the page does not say about fees
    for row in rows:
        assert row["market"] == "primary" and row["qty"] is None and row["seats"] is None and row["row"] is None
        assert row["fee"] is None and row["tax"] is None and row["all_in"] is None
        assert row["price_estimated"] is False and row["obstructed"] is False
    assert (event["price_min"], event["price_max"]) == (55.0, 1134.5)
    # the price page was read once: the listings reused the page the event came from
    assert asked == [ims.PRICES_PATH, ims.GA_PATH]


def test_the_price_page_is_read_again_only_when_the_one_kept_is_too_old(monkeypatch):
    clock = {"now": 0.0}
    asked = _site(monkeypatch, {ims.PRICES_PATH: PRICES, ims.GA_PATH: GENERAL}, clock)
    (event,) = ims.events()
    for clock["now"] in (600.0, ims.LIST_TTL_S):
        ims.events()                                             # the worker's wakes in between: no read
    assert asked == [ims.PRICES_PATH]
    ims.listings(event, RACE_DAY)                                # due an hour later: a new read of both pages
    assert asked == [ims.PRICES_PATH, ims.PRICES_PATH, ims.GA_PATH]
    clock["now"] += ims.LIST_TTL_S + 1
    ims.events()
    assert asked.count(ims.PRICES_PATH) == 3


def test_a_sold_out_race_has_no_rows_and_no_prices(monkeypatch):
    sold = MENU + _table([HEADER, ["A Stand", VIEW, "SOLD OUT", "SOLD OUT", "SOLD OUT"]])
    no_ga = _table([["Indy 500 Race Day - Sunday, May 30"], ["General Admission", "SOLD OUT", "SOLD OUT"]])
    _site(monkeypatch, {ims.PRICES_PATH: sold, ims.GA_PATH: no_ga})
    monkeypatch.setattr(ims, "_today", lambda: date(2027, 5, 1))  # no date given: today at the speedway
    (event,) = ims.events()
    assert ims.listings(event) == [] and (event["price_min"], event["price_max"]) == (None, None)


def test_today_is_the_speedways_date():
    assert isinstance(ims._today(), date)


def test_a_page_the_site_does_not_serve_fails_the_read(monkeypatch):
    _site(monkeypatch, {ims.PRICES_PATH: 503})
    with pytest.raises(ims.ImsError, match="HTTP 503 for /events/indy500/buy-tickets/ticket-prices"):
        ims.events()
    _site(monkeypatch, {ims.PRICES_PATH: PRICES, ims.GA_PATH: 404})
    (event,) = ims.events()
    with pytest.raises(ims.ImsError, match="HTTP 404"):
        ims.listings(event, RACE_DAY)


def test_the_run_polls_the_indy_500_when_it_is_given_its_client(monkeypatch):
    _site(monkeypatch, {ims.PRICES_PATH: PRICES, ims.GA_PATH: GENERAL})
    monkeypatch.setattr(ims, "_today", lambda: date(2026, 11, 24))
    sent = []

    class _None:
        @staticmethod
        def events(*_a):
            return []

        all_events = events
        listings = None

    out = sync.run(lambda name, params: sent.append((name, params)), _None(), _None(), ("ims",), ims)
    assert out == {"ims": {"events": 1, "ok": 1, "failed": 0, "listings": 5, "not_stored": 0, "skipped": 0}}
    stored = next(p for n, p in sent if n == "primary_poll_ingest")
    assert stored["p_source"] == "ims" and stored["p_events"][0]["id"] == "indy500-2027"
    assert stored["p_events"][0]["price_min"] == 55.0 and stored["p_events"][0]["ok"] is True
    # no source named: every source the run has a client for, the Indy 500 among them only when given
    assert list(sync.run(lambda name, params: None, _None(), _None(), ims=ims)) == ["sitickets", "timberwolves", "ims"]
    assert list(sync.run(lambda name, params: None, _None(), _None())) == ["sitickets", "timberwolves"]
    assert sync.sources_from("sitickets,ims") == ("sitickets", "ims")
