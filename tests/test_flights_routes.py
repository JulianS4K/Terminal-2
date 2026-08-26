"""Tests for D0 FLIGHTS — /api/broker/flights/* (routers/flights.py).

Two halves:
  * the pure price math (typical-price baseline, verdicts, scoring, the
    date grid, the live booking-option fold) — called directly, no HTTP;
  * the three routes over a fake Supabase that records the filter chain, so a
    handler's read shape (which table, which filters) is asserted rather than
    assumed.

No real DB / HTTP.
"""
from __future__ import annotations

import os
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402
from routers import flights as fl  # noqa: E402

TestClient = starlette_testclient.TestClient

TODAY = datetime.now(timezone.utc).date()


def _day(offset: int) -> str:
    return (TODAY + timedelta(days=offset)).isoformat()


# --------------------------------------------------------------------------
# fake supabase — records the filter chain, resolves rows through a callback
# --------------------------------------------------------------------------

class _Q:
    def __init__(self, table: str, resolver):
        self._table = table
        self._resolver = resolver
        self.ops: list[tuple] = []

    def _rec(self, name, *args):
        self.ops.append((name,) + args)
        return self

    def select(self, *a, **k):
        return self._rec("select", *a)

    def eq(self, col, val):
        return self._rec("eq", col, val)

    def neq(self, col, val):
        return self._rec("neq", col, val)

    def gte(self, col, val):
        return self._rec("gte", col, val)

    def lt(self, col, val):
        return self._rec("lt", col, val)

    def in_(self, col, vals):
        return self._rec("in_", col, list(vals))

    def ilike(self, col, val):
        return self._rec("ilike", col, val)

    def or_(self, expr):
        return self._rec("or_", expr)

    def order(self, col, **k):
        return self._rec("order", col, k.get("desc", False))

    def limit(self, n):
        return self._rec("limit", n)

    def execute(self):
        data = self._resolver(self._table, self.ops)
        return type("_R", (), {"data": data})()


class _Sb:
    def __init__(self, resolver):
        self._resolver = resolver
        self.seen: list[_Q] = []

    def table(self, name):
        q = _Q(name, self._resolver)
        self.seen.append(q)
        return q


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _wire(monkeypatch, resolver):
    sb = _Sb(resolver)
    monkeypatch.setattr(app_module, "require_sb", lambda: sb)
    return sb


def _has(q: _Q, name, *args) -> bool:
    return (name,) + args in q.ops


# --------------------------------------------------------------------------
# pure helpers
# --------------------------------------------------------------------------

def test_num_coerces_and_rejects():
    assert fl._num("12.5") == 12.5
    assert fl._num(None) is None
    assert fl._num("") is None
    assert fl._num("abc") is None
    assert fl._num(0) is None      # a zero price is missing data, not free
    assert fl._num(-3) is None


def test_median_and_percentile():
    assert fl._median([]) is None
    assert fl._median([5, 1, 3]) == 3
    assert fl._median([4, 1, 3, 2]) == 2.5
    assert fl._pctile([], 0.5) is None
    assert fl._pctile([10, 20, 30, 40], 0.25) == 20
    assert fl._pctile([10, 20], 5) == 20     # p clamps to the last index
    assert fl._pctile([10, 20], -1) == 10    # ...and to the first


def test_clean_term_strips_postgrest_syntax():
    assert fl._clean_term(None) == ""
    assert fl._clean_term("") == ""
    # commas + parens would re-shape an `or=(...)` filter — they must not survive
    assert "," not in fl._clean_term("Knicks,(x)")
    assert fl._clean_term("  O'Neal-Shaq  ") == "O'Neal-Shaq"
    assert len(fl._clean_term("x" * 200)) == 60


def test_window_defaults_bounds_and_errors():
    start, end = fl._window(None, None, 30, date(2026, 8, 26))
    assert (start, end) == ("2026-08-26", "2026-09-26")
    # explicit range: upper bound is exclusive on the NEXT day so same-day
    # evening events (text timestamps) stay in range
    assert fl._window("2026-09-01", "2026-09-03", 30, TODAY) == ("2026-09-01", "2026-09-04")
    # a 5-year request clamps to a year
    _s, e = fl._window("2026-01-01", "2031-01-01", 30, TODAY)
    assert e == "2027-01-02"
    with pytest.raises(Exception):
        fl._window("nonsense", None, 30, TODAY)
    with pytest.raises(Exception):
        fl._window("2026-09-10", "2026-09-01", 30, TODAY)


def test_event_day_and_days_out():
    assert fl._event_day("2026-08-28T19:00:00-05:00") == "2026-08-28"
    assert fl._event_day(None) is None
    assert fl._event_day("2026-08") is None
    assert fl._days_out("2026-08-28T19:00:00-05:00", date(2026, 8, 26)) == 2
    assert fl._days_out(None, TODAY) is None


def _row(**kw):
    base = {"event_id": 1, "snapshot_date": _day(-1), "snapshot_slot": "evening",
            "captured_at": _day(-1) + "T20:00:00Z"}
    base.update(kw)
    return base


def test_row_sources_and_best_of():
    row = _row(evo_retail_getin=100, evo_retail_median=180, evo_tickets_count=40,
               td_sh_getin=90, td_sh_median=None, td_sh_listings="not-a-number",
               td_gt_getin=None, td_gt_median=None)
    srcs = fl._row_sources(row)
    keys = {s["source"] for s in srcs}
    assert keys == {"evo", "sh"}            # gt has neither price → dropped
    sh = next(s for s in srcs if s["source"] == "sh")
    assert sh["depth"] is None              # non-numeric depth degrades to None
    price, source = fl._best_of(srcs)
    assert (price, source) == (90.0, "sh")
    assert fl._best_of([]) == (None, None)
    assert fl._best_of([{"source": "x", "getin": None}]) == (None, None)


def test_pick_current_prefers_latest_capture():
    rows = [
        _row(snapshot_date=_day(-1), captured_at="z"),
        _row(snapshot_date=_day(0), captured_at="a"),
        _row(snapshot_date=_day(0), captured_at="b"),
        _row(snapshot_date=None),
    ]
    assert fl._pick_current(rows)["captured_at"] == "b"
    assert fl._pick_current([]) is None
    assert fl._pick_current([_row(snapshot_date=None)]) is None


def test_daily_series_collapses_to_one_point_per_day():
    rows = [
        _row(snapshot_date="2026-08-01", captured_at="a", evo_retail_getin=100, evo_retail_median=150),
        _row(snapshot_date="2026-08-01", captured_at="b", evo_retail_getin=90, evo_retail_median=140),
        _row(snapshot_date="2026-08-01", captured_at="a2", evo_retail_getin=999),  # older capture — ignored
        _row(snapshot_date="2026-08-02", captured_at="c", evo_retail_getin=80, evo_retail_median=None),
        _row(snapshot_date="2026-08-03", captured_at="d"),          # no prices → dropped
        _row(snapshot_date=None, evo_retail_getin=1),               # undated → dropped
    ]
    series = fl._daily_series(rows)
    assert [p["date"] for p in series] == ["2026-08-01", "2026-08-02"]
    assert series[0]["price"] == 90          # later capture on the same day wins
    assert series[1]["median"] is None       # no median column present that day


def _series(prices, start="2026-07-01"):
    d0 = date.fromisoformat(start)
    return [{"date": (d0 + timedelta(days=i)).isoformat(), "price": float(p),
             "source": "evo", "sources": 1, "median": None}
            for i, p in enumerate(prices)]


def test_baseline_verdicts():
    flat = _series([100] * 30)
    assert fl._baseline(flat, 100)["verdict"] == "typical"
    band = _series([50, 60, 70, 80, 90, 100, 110, 120])
    assert fl._baseline(band, 55)["verdict"] == "deal"     # at/below p25
    low = fl._baseline(band, 80)
    assert low["verdict"] == "low" and low["delta_pct"] < 0
    assert fl._baseline(band, 200)["verdict"] == "high"
    # exactly between the median and p75 is "typical"
    assert fl._baseline(_series([10, 20, 30, 40, 50]), 35)["verdict"] == "typical"
    # no history / no current price → unknown
    assert fl._baseline([], 100)["verdict"] == "unknown"
    assert fl._baseline(flat, None)["verdict"] == "unknown"


def test_baseline_trend():
    rising = fl._baseline(_series([50] * 14 + [80] * 7), 80)
    assert rising["trend"] == "rising" and rising["trend_pct"] > 0
    assert fl._baseline(_series([100] * 14 + [50] * 7), 50)["trend"] == "falling"
    assert fl._baseline(_series([100] * 21), 100)["trend"] == "flat"
    assert fl._baseline(_series([100] * 3), 100)["trend"] == "flat"   # no prior window


def test_rank_pct_and_score():
    assert fl._rank_pct(10, []) == 0.0
    assert fl._rank_pct(10, [10, 20, 30]) == 1.0
    assert fl._rank_pct(30, [10, 20, 30]) == pytest.approx(1 / 3)
    assert fl._score(None, [1.0], {}, 1) == 0.0
    cheap_deal = fl._score(10, [10.0, 90.0], {"delta_pct": -0.5}, 4)
    pricey = fl._score(90, [10.0, 90.0], {"delta_pct": None}, 1)
    assert cheap_deal == 100.0 and pricey < cheap_deal


def test_reasons_read_like_google_flights():
    item = {"price": 50.0, "source_count": 3,
            "insights": {"delta_pct": -0.20, "trend": "falling"}}
    reasons = fl._reasons(item, 50.0)
    assert "Cheapest in this search" in reasons
    assert "20% below its usual price" in reasons
    assert "Prices falling this week" in reasons
    assert "3 marketplaces compared" in reasons

    pricey = fl._reasons({"price": 90.0, "source_count": 1,
                          "insights": {"delta_pct": 0.4, "trend": "rising"}}, 50.0)
    assert "40% above its usual price" in pricey
    assert "Prices rising this week" in pricey
    assert not any(r.startswith("Cheapest") for r in pricey)

    quiet = fl._reasons({"price": None, "source_count": 1,
                         "insights": {"delta_pct": None, "trend": "flat"}}, None)
    assert quiet == []


def test_calendar_picks_the_cheapest_event_per_day():
    items = [
        {"event_id": 1, "name": "A", "event_date": "2026-09-01", "price": 80.0},
        {"event_id": 2, "name": "B", "event_date": "2026-09-01", "price": 40.0},
        {"event_id": 3, "name": "C", "event_date": "2026-09-02", "price": 95.0},
        {"event_id": 4, "name": "D", "event_date": None, "price": 5.0},
        {"event_id": 5, "name": "E", "event_date": "2026-09-03", "price": None},
    ]
    cal = fl._calendar(items)
    assert [c["date"] for c in cal] == ["2026-09-01", "2026-09-02"]
    assert cal[0]["event_id"] == 2 and cal[0]["events"] == 2
    assert cal[0]["is_cheapest"] is True and cal[1]["is_cheapest"] is False
    assert fl._calendar([]) == []


def _listing(price, qty=2, section="A", parking=False, fees=True):
    row = {"captured_at": "2026-08-26T14:00:00Z", "section": section, "row": "5",
           "quantity": qty, "list_price": price, "is_parking": parking}
    row["price_with_fees"] = price + 10 if fees else None
    return row


def test_live_options_uses_only_the_newest_capture():
    xrefs = [{"platform": "SH", "event_id": 11, "event_url": "https://sh/x"},
             {"platform": "GT", "event_id": 12, "event_url": None},
             {"platform": "VD", "event_id": 13, "event_url": None},
             {"platform": None, "event_id": 14, "event_url": None}]
    stale = _listing(10)
    stale["captured_at"] = "2026-08-20T00:00:00Z"
    batches = [
        [_listing(100), _listing(60, qty=4), stale],
        [_listing(50, parking=True)],                       # parking only → no option
        [],                                                  # never polled
        [dict(_listing(30), list_price=None, price_with_fees=None)],  # unpriced
    ]
    options, pooled = fl._live_options(xrefs, batches)
    assert [o["platform"] for o in options] == ["SH"]
    sh = options[0]
    assert sh["getin"] == 70 and sh["listings"] == 2 and sh["tickets"] == 6
    assert sh["label"] == "StubHub" and sh["live"] is True
    assert len(pooled) == 2

    # a listing with no fee-inclusive price falls back to the list price
    opts2, pooled2 = fl._live_options(
        [{"platform": "TP", "event_id": 9, "event_url": None}],
        [[_listing(25, fees=False)]])
    assert opts2[0]["getin"] == 25 and pooled2[0]["price"] == 25


def test_live_options_skips_unpriced_rows_inside_a_priced_batch():
    unpriced = dict(_listing(30), list_price=None, price_with_fees=None)
    options, pooled = fl._live_options(
        [{"platform": "SH", "event_id": 1, "event_url": None}],
        [[_listing(40), unpriced]])
    assert options[0]["listings"] == 2   # both rows are current inventory…
    assert len(pooled) == 1              # …but only one has a usable price


def test_cheapest_listings_respects_quantity():
    pooled = [
        {"price": 10.0, "quantity": 1}, {"price": 20.0, "quantity": 4},
        {"price": 30.0, "quantity": 2}, {"price": 20.0, "quantity": 2},
    ]
    out = fl._cheapest_listings(pooled, 2, 10)
    assert [p["price"] for p in out] == [20.0, 20.0, 30.0]
    assert out[0]["quantity"] == 4       # same price → the bigger block first
    assert len(fl._cheapest_listings(pooled, 2, 1)) == 1


# --------------------------------------------------------------------------
# /api/broker/flights/search
# --------------------------------------------------------------------------

EVENTS = [
    {"id": 1, "name": "Knicks at Celtics", "occurs_at_local": _day(3) + "T19:00:00-04:00",
     "venue_name": "TD Garden", "venue_location": "Boston, MA",
     "primary_performer_id": 7, "primary_performer_name": "Boston Celtics",
     "event_type": "sports", "state": "normal"},
    {"id": 2, "name": "Knicks at Nets", "occurs_at_local": _day(9) + "T20:00:00-04:00",
     "venue_name": "Barclays", "venue_location": "Brooklyn, NY",
     "primary_performer_id": 8, "primary_performer_name": "Brooklyn Nets",
     "event_type": "sports", "state": "normal"},
    {"id": 3, "name": "No prices here", "occurs_at_local": _day(5) + "T20:00:00-04:00",
     "venue_name": "Nowhere", "venue_location": "Reno, NV",
     "primary_performer_id": 9, "primary_performer_name": "Nobody",
     "event_type": "concert", "state": "normal"},
]


def _price_resolver(current_rows, history_rows, events=None):
    """Split the two event_listing_snapshot_daily reads by their slot filter."""
    def resolve(table, ops):
        if table == "events":
            return events if events is not None else EVENTS
        if table == "event_listing_snapshot_daily":
            slot_filtered = any(op[0] == "eq" and op[1] == "snapshot_slot" for op in ops)
            return history_rows if slot_filtered else current_rows
        return []
    return resolve


CURRENT = [
    _row(event_id=1, snapshot_date=_day(0), captured_at=_day(0) + "T18:00:00Z",
         evo_retail_getin=120, evo_retail_median=200, evo_tickets_count=50,
         td_sh_getin=95, td_sh_median=180, td_sh_listings=40,
         td_gt_getin=99, td_gt_median=190, td_gt_listings=12),
    _row(event_id=2, snapshot_date=_day(0), captured_at=_day(0) + "T18:00:00Z",
         evo_retail_getin=310, evo_retail_median=460, evo_tickets_count=20),
    _row(event_id=3, snapshot_date=_day(0), captured_at=_day(0) + "T18:00:00Z"),
]
HISTORY = (
    [_row(event_id=1, snapshot_date=(TODAY - timedelta(days=i)).isoformat(),
          captured_at="x", evo_retail_getin=150 + i, td_sh_getin=140 + i)
     for i in range(4, 25)]
    + [_row(event_id=2, snapshot_date=(TODAY - timedelta(days=i)).isoformat(),
            captured_at="x", evo_retail_getin=300) for i in range(4, 25)]
)


def test_search_ranks_prices_and_builds_the_date_grid(client, monkeypatch):
    sb = _wire(monkeypatch, _price_resolver(CURRENT, HISTORY))
    r = client.get("/api/broker/flights/search?q=Knicks&city=Boston&days=30")
    assert r.status_code == 200
    body = r.json()

    ids = [x["event_id"] for x in body["results"]]
    assert ids == [1, 2]                      # event 3 has no priced source
    top = body["results"][0]
    assert top["price"] == 95.0 and top["price_source"] == "sh"
    assert top["source_count"] == 3
    assert top["insights"]["verdict"] == "deal"      # 95 vs a ~150 typical
    assert "Cheapest in this search" in top["reasons"]
    assert top["days_out"] == 3
    assert body["meta"]["cheapest"] == 95.0
    assert body["meta"]["candidates"] == 3 and body["meta"]["priced"] == 2

    cal = body["calendar"]
    assert [c["date"] for c in cal] == [_day(3), _day(9)]
    assert cal[0]["is_cheapest"] is True

    # the event read is windowed on the TEXT timestamp + filtered to both boxes
    ev_q = next(q for q in sb.seen if q._table == "events")
    assert _has(ev_q, "neq", "state", "ignored")
    assert _has(ev_q, "gte", "occurs_at_local", TODAY.isoformat())
    assert any(op[0] == "or_" and "Knicks" in op[1] for op in ev_q.ops)
    assert any(op[0] == "or_" and "Boston" in op[1] for op in ev_q.ops)


def test_search_sorts(client, monkeypatch):
    for sort, first in (("price", 1), ("date", 1), ("deal", 1), ("best", 1)):
        _wire(monkeypatch, _price_resolver(CURRENT, HISTORY))
        body = client.get(f"/api/broker/flights/search?sort={sort}").json()
        assert body["results"][0]["event_id"] == first
        assert body["meta"]["sort"] == sort


def test_search_deal_sort_puts_the_biggest_discount_first(client, monkeypatch):
    # event 2 priced far BELOW its history, event 1 slightly above → 2 first
    current = [
        _row(event_id=1, snapshot_date=_day(0), captured_at="c", evo_retail_getin=160),
        _row(event_id=2, snapshot_date=_day(0), captured_at="c", evo_retail_getin=150),
    ]
    _wire(monkeypatch, _price_resolver(current, HISTORY))
    body = client.get("/api/broker/flights/search?sort=deal").json()
    assert [x["event_id"] for x in body["results"]] == [2, 1]


def test_search_filters(client, monkeypatch):
    _wire(monkeypatch, _price_resolver(CURRENT, HISTORY))
    cheap = client.get("/api/broker/flights/search?max_price=100").json()
    assert [x["event_id"] for x in cheap["results"]] == [1]

    _wire(monkeypatch, _price_resolver(CURRENT, HISTORY))
    broad = client.get("/api/broker/flights/search?min_sources=3").json()
    assert [x["event_id"] for x in broad["results"]] == [1]


def test_search_skips_events_with_no_recent_snapshot(client, monkeypatch):
    _wire(monkeypatch, _price_resolver([CURRENT[0]], HISTORY))
    body = client.get("/api/broker/flights/search").json()
    assert [x["event_id"] for x in body["results"]] == [1]


def test_search_empty_and_invalid(client, monkeypatch):
    _wire(monkeypatch, _price_resolver([], [], events=[]))
    body = client.get("/api/broker/flights/search?q=nothing").json()
    assert body == {"results": [], "calendar": [],
                    "meta": {"candidates": 0, "priced": 0,
                             "window": [TODAY.isoformat(),
                                        (TODAY + timedelta(days=61)).isoformat()],
                             "sort": "best"}}

    _wire(monkeypatch, _price_resolver(CURRENT, HISTORY))
    assert client.get("/api/broker/flights/search?sort=nope").status_code == 400
    assert client.get("/api/broker/flights/search?date_from=13-13-13").status_code == 400


def test_search_clamps_days_and_limit(client, monkeypatch):
    sb = _wire(monkeypatch, _price_resolver(CURRENT, HISTORY))
    body = client.get("/api/broker/flights/search?days=9999&limit=9999").json()
    ev_q = next(q for q in sb.seen if q._table == "events")
    assert _has(ev_q, "limit", fl.MAX_CANDIDATES)
    assert body["meta"]["window"][1] == (TODAY + timedelta(days=366)).isoformat()

    _wire(monkeypatch, _price_resolver(CURRENT, HISTORY))
    small = client.get("/api/broker/flights/search?days=0&limit=1").json()
    assert len(small["results"]) == 1


# --------------------------------------------------------------------------
# /api/broker/flights/event/{id}
# --------------------------------------------------------------------------

def _detail_resolver(*, event=EVENTS[0], daily=None, aq=None, xrefs=None,
                     listings=None, evo=None):
    def resolve(table, ops):
        if table == "events":
            return [event] if event else []
        if table == "event_listing_snapshot_daily":
            return daily or []
        if table == "aq_event_map":
            return aq or []
        if table == "latest_event_metrics":
            return evo or []
        if table == "ticketsdata_event_xref":
            return xrefs or []
        if table == "ticketsdata_listings_snapshots":
            td_id = next(op[2] for op in ops if op[0] == "eq" and op[1] == "event_id")
            return (listings or {}).get(td_id, [])
        return []
    return resolve


DAILY = [
    _row(event_id=1, snapshot_date=(TODAY - timedelta(days=i)).isoformat(),
         captured_at="x", evo_retail_getin=150 + i, td_sh_getin=140 + i,
         td_sh_median=200, td_sh_listings=30, sg_all_getin=160)
    for i in range(0, 20)
]


def test_event_detail_prefers_live_listings_over_daily_columns(client, monkeypatch):
    resolver = _detail_resolver(
        daily=DAILY,
        aq=[{"aq_short_event_id": "ABC1234"}],
        xrefs=[{"platform": "SH", "event_id": 111, "event_url": "https://sh/e",
                "last_fetched_at": "2026-08-26T14:00:00Z"},
               {"platform": "GT", "event_id": 222, "event_url": None,
                "last_fetched_at": "2026-08-26T14:00:00Z"}],
        listings={111: [_listing(80), _listing(120, qty=4)],
                  222: [_listing(95, qty=1)]},
        evo=[{"event_id": 1, "captured_at": "2026-08-26T14:30:00Z", "getin_price": 110,
              "retail_median": 210, "tickets_count": 44, "groups_count": 12}],
    )
    sb = _wire(monkeypatch, resolver)
    body = client.get("/api/broker/flights/event/1?qty=2&history_days=30").json()

    by_source = {o["source"]: o for o in body["options"]}
    assert by_source["sh"]["live"] is True and by_source["sh"]["getin"] == 90
    assert by_source["gt"]["live"] is True
    assert by_source["evo"]["getin"] == 110 and by_source["evo"]["label"] == "EVO (our book)"
    assert by_source["sg"]["live"] is False           # daily-column fallback
    assert body["price"] == 90 and body["price_source"] == "sh"
    assert body["options"] == sorted(body["options"], key=lambda o: o["getin"])
    assert body["live_platforms"] == ["gt", "sh"]

    # only listings that seat 2 survive, cheapest first
    assert [x["price"] for x in body["listings"]] == [90.0, 130.0]
    assert body["listings_qty"] == 2
    assert len(body["history"]) == 20
    assert body["insights"]["days_observed"] == 19   # today is excluded from the baseline
    assert body["event"]["venue"] == "TD Garden"

    # the live layer is reached through the aq hub, never on a tevo id
    xref_q = next(q for q in sb.seen if q._table == "ticketsdata_event_xref")
    assert _has(xref_q, "in_", "aq_short_event_id", ["ABC1234"])
    listing_q = next(q for q in sb.seen if q._table == "ticketsdata_listings_snapshots")
    assert _has(listing_q, "order", "captured_at", True)


def test_event_detail_without_live_coverage(client, monkeypatch):
    _wire(monkeypatch, _detail_resolver(daily=DAILY, aq=[], evo=[]))
    body = client.get("/api/broker/flights/event/1").json()
    assert body["live_platforms"] == []
    assert body["listings"] == []
    assert {o["source"] for o in body["options"]} == {"evo", "sh", "sg"}
    assert all(o["live"] is False for o in body["options"])
    assert body["price"] == 140.0


def test_event_detail_with_no_prices_at_all(client, monkeypatch):
    _wire(monkeypatch, _detail_resolver(daily=[], aq=[{"aq_short_event_id": None}]))
    body = client.get("/api/broker/flights/event/1").json()
    assert body["options"] == [] and body["price"] is None
    assert body["insights"]["verdict"] == "unknown"


def test_event_detail_404(client, monkeypatch):
    _wire(monkeypatch, _detail_resolver(event=None))
    assert client.get("/api/broker/flights/event/999").status_code == 404


def test_event_detail_clamps_qty_and_history(client, monkeypatch):
    sb = _wire(monkeypatch, _detail_resolver(daily=DAILY, aq=[]))
    body = client.get("/api/broker/flights/event/1?qty=99&history_days=1").json()
    assert body["listings_qty"] == 12
    daily_q = next(q for q in sb.seen if q._table == "event_listing_snapshot_daily")
    since = next(op[2] for op in daily_q.ops if op[0] == "gte")
    assert since == (TODAY - timedelta(days=7)).isoformat()


# --------------------------------------------------------------------------
# /api/broker/flights/suggest
# --------------------------------------------------------------------------

def test_suggest_ranks_performers_by_upcoming_event_count(client, monkeypatch):
    rows = [
        {"primary_performer_id": 7, "primary_performer_name": "Boston Celtics", "event_type": "sports"},
        {"primary_performer_id": 7, "primary_performer_name": "Boston Celtics", "event_type": "sports"},
        {"primary_performer_id": 8, "primary_performer_name": "Boston Bruins", "event_type": "sports"},
        {"primary_performer_id": None, "primary_performer_name": "orphan", "event_type": None},
        {"primary_performer_id": 9, "primary_performer_name": None, "event_type": None},
    ]
    sb = _wire(monkeypatch, lambda table, ops: rows if table == "events" else [])
    body = client.get("/api/broker/flights/suggest?q=bos").json()
    assert [s["performer_id"] for s in body["suggestions"]] == [7, 8]
    assert body["suggestions"][0]["events"] == 2
    q = next(q for q in sb.seen if q._table == "events")
    assert _has(q, "ilike", "primary_performer_name", "*bos*")


def test_suggest_needs_two_characters(client, monkeypatch):
    _wire(monkeypatch, lambda table, ops: [])
    assert client.get("/api/broker/flights/suggest?q=b").json() == {"suggestions": []}


def test_suggest_limit_is_clamped(client, monkeypatch):
    rows = [{"primary_performer_id": i, "primary_performer_name": f"Team {i}",
             "event_type": "sports"} for i in range(30)]
    _wire(monkeypatch, lambda table, ops: rows if table == "events" else [])
    body = client.get("/api/broker/flights/suggest?q=team&limit=999").json()
    assert len(body["suggestions"]) == 20
