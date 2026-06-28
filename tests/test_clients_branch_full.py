"""Branch-coverage gap closers for the API clients + render_webhook.

Line coverage of these modules is already 100% (see the matching
tests/test_*_client_full.py suites); this file drives the remaining
PARTIAL branches to full branch coverage. Offline-only, matching house
style: requests / session.get are monkeypatched at the boundary, time.sleep
is neutered for any retry path, and no test ever issues a real network call
or POST/write to an upstream.

Branches closed here (the genuinely-unreachable loop-exhaustion / invariant
arcs are pragma'd in the source instead — see each `# pragma: no branch`):

  - broadway_client.py 802->798  (price-selector loop continues past a
                                   matched-but-non-coercible element)
  - evo_client.py      585->exit (iter_orders runs to max_pages w/o break)
  - seatgeek_client.py 469->exit (iter_seller_orders runs to max_pages)
  - seatgeek_client.py 612->603  (duplicate event id -> events_seen skip)
  - vivid_client.py    141->139  (active-orders dedupe skips id-less row)
  - render_webhook.py  279->281  (enrich resource present but lacks 'name')
"""
from __future__ import annotations

import pytest

import broadway_client
from broadway_client import BroadwayClient, SectionListing

import evo_client
from evo_client import EvoClient

import seatgeek_client as sg

import vivid_client as vivid

import render_webhook as rw


# ====================================================================
# broadway_client 802->798 — inner price-selector loop *continues*
# ====================================================================
#
# In _listings_from_html the inner `for psel in self.price_selectors` loop
# breaks once it coerces a non-None price (802->803). The 802->798 arc is the
# *continue* path: a selector matched an element, but its text did not coerce
# to a float, so price stays None and the loop advances to the next selector.

def test_broadway_listings_price_selector_continues_then_matches():
    # Row matches the first SECTION_ROW_SELECTORS entry. Inside it:
    #   - [data-testid='price']  matches an element whose text ("Sold Out")
    #     does NOT coerce -> price stays None -> loop CONTINUES (802->798).
    #   - .price                 matches "$87.50" -> coerces -> break.
    html = """
    <div data-testid='section-row' data-section-name='Orchestra'>
      <span data-testid='price'>Sold Out</span>
      <span class='price'>$87.50</span>
    </div>
    """
    c = BroadwayClient()
    out = c._listings_from_html(html)
    assert len(out) == 1
    row = out[0]
    assert isinstance(row, SectionListing)
    assert row.name == "Orchestra"
    # The first selector's garbage text was skipped; the .price value won.
    assert row.price == 87.50


def test_broadway_listings_price_selector_all_uncoercible_falls_back():
    # Sanity companion: every price selector matches but none coerces, so the
    # loop exhausts (price None) and we fall back to coercing the row text.
    html = """
    <div data-section-id='12' data-section-name='Mezzanine'>
      <span data-testid='price'>n/a</span>
      Section priced at $42
    </div>
    """
    c = BroadwayClient()
    out = c._listings_from_html(html)
    assert len(out) == 1
    assert out[0].name == "Mezzanine"
    assert out[0].price == 42.0  # from PRICE_REGEX over the row text


# ====================================================================
# evo_client 585->exit — iter_orders exhausts max_pages without breaking
# ====================================================================
#
# The `for page in range(1, max_pages + 1)` loop normally breaks on an empty
# page or on `seen >= total`. The 585->exit arc is the loop running to
# completion (max_pages reached) without ever taking a break: every page is
# full and `seen` never reaches `total`.

def test_evo_iter_orders_runs_to_max_pages(monkeypatch):
    c = EvoClient(token="t", secret="s")
    # Every page returns a full, non-empty batch with a huge total so
    # `seen >= total` is never satisfied -> loop runs to max_pages and falls
    # through to the implicit return (no break ever fires).
    def fake_list_orders(*, page, per_page, **kw):
        return {"orders": [{"id": page}], "total_entries": 10_000}

    monkeypatch.setattr(c, "list_orders", fake_list_orders)
    items = list(c.iter_orders(max_pages=3))
    assert [o["id"] for o in items] == [1, 2, 3]  # all 3 pages, no early stop


# ====================================================================
# seatgeek_client 469->exit — iter_seller_orders exhausts max_pages
# ====================================================================

def test_seatgeek_iter_seller_orders_runs_to_max_pages(monkeypatch):
    monkeypatch.setenv("SEATGEEK_API_TOKEN", "tok")
    c = sg.SeatGeekClient()
    # Every page non-empty, no total -> the `if total and seen >= total` break
    # never fires and pages are never empty, so the loop runs to max_pages.
    def fake_seller_orders(status_filter, *, page=1):
        return {"orders": [{"id": page}], "meta": {}}

    monkeypatch.setattr(c, "seller_orders", fake_seller_orders)
    out = list(c.iter_seller_orders("open", max_pages=3))
    assert [o["id"] for o in out] == [1, 2, 3]


# ====================================================================
# seatgeek_client 612->603 — duplicate event id skips the events_seen add
# ====================================================================
#
# In store_seller_orders the dedupe loop only adds a new event when
# `sg_eid_i not in events_seen` (612->613). The 612->603 arc is the *skip*:
# a second order with the SAME event id finds it already present and loops on.

class _RpcResult:
    def __init__(self, data):
        self.data = data


class _Table:
    def __init__(self, owner, name):
        self._owner = owner
        self._name = name
        self._pending = None

    def insert(self, payload):
        self._owner.ops.append((self._name, "insert", payload))
        return self

    def upsert(self, rows, on_conflict=None):
        self._owner.ops.append((self._name, "upsert", rows, on_conflict))
        self._pending = self._owner.upsert_data
        return self

    def update(self, payload):
        self._owner.ops.append((self._name, "update", payload))
        return self

    def delete(self):
        self._owner.ops.append((self._name, "delete"))
        return self

    def eq(self, *a, **k):
        return self

    def in_(self, *a, **k):
        return self

    def execute(self):
        return _RpcResult(getattr(self, "_pending", None))


class _Rpc:
    def __init__(self, owner, name, params):
        self._owner = owner

    def execute(self):
        # Resolve every xref to a tevo id so the path is exercised fully.
        return _RpcResult(777)


class _FakeDB:
    def __init__(self):
        self.ops = []
        self.upsert_data = [{"ok": 1}]

    def table(self, name):
        return _Table(self, name)

    def rpc(self, name, params):
        return _Rpc(self, name, params)


def test_seatgeek_store_seller_orders_duplicate_event_id(monkeypatch):
    monkeypatch.setenv("SEATGEEK_API_TOKEN", "tok")
    db = _FakeDB()
    c = sg.SeatGeekClient(db=db)
    # TWO orders carrying the SAME seatgeek_event_id (5). The first adds it to
    # events_seen; the second hits `if sg_eid_i not in events_seen` == False and
    # CONTINUES (612->603) instead of re-adding.
    orders = [
        {"id": "o1", "event": {"seatgeek_event_id": 5, "name": "Show"},
         "tickets": []},
        {"id": "o2", "event": {"seatgeek_event_id": 5, "name": "Show"},
         "tickets": []},
    ]
    out = c.store_seller_orders(orders, "open")
    assert out["received"] == 2
    # Deduped: the shared event id is counted exactly once.
    assert out["events_seen"] == 1


# ====================================================================
# vivid_client 141->139 — active-orders dedupe skips an id-less row
# ====================================================================
#
# list_active_orders dedupes by orderId; `if oid:` (141) gates the assignment.
# The 141->139 arc is the *skip*: a row with no/empty orderId is dropped and
# the loop advances. RETRANSFER_XML's id-less row already exercises this in the
# small-clients suite, but we drive it explicitly through monkeypatched HTTP.

class _VividResp:
    def __init__(self, content):
        self.status_code = 200
        self.ok = True
        self.content = content
        self.headers = {}


def test_vivid_active_orders_skips_id_less_row(monkeypatch):
    pending_xml = b"""<?xml version="1.0"?>
<orders>
  <order><orderId>111</orderId></order>
</orders>"""
    # Second feed has a row with an EMPTY orderId -> `if oid:` False -> skipped.
    retransfer_xml = b"""<?xml version="1.0"?>
<orders>
  <order><orderId></orderId><status>X</status></order>
  <order><orderId>222</orderId></order>
</orders>"""
    seq = iter([_VividResp(pending_xml), _VividResp(retransfer_xml)])
    monkeypatch.setattr(vivid.requests, "get", lambda url, **kw: next(seq))
    c = vivid.VividClient("tok")
    rows = c.list_active_orders()
    ids = sorted(r["orderId"] for r in rows)
    # 111 + 222; the empty-id row was dropped by the `if oid:` gate.
    assert ids == ["111", "222"]


# ====================================================================
# render_webhook 279->281 — enrich resource present but missing 'name'
# ====================================================================
#
# describe_event enriches via _render_get when a path template + api key exist.
# `if resource and resource.get("name")` (279) returns the named summary
# (279->280); the 279->281 arc is when the lookup yields a resource WITHOUT a
# usable name, so we fall through to the bare "type: sid" summary.

def test_describe_event_resource_without_name_falls_through(monkeypatch):
    # render_api_key present + deploy_started has an _ENRICH_PATH entry, so we
    # enter the enrich block; _render_get returns a dict lacking 'name' ->
    # 279 is False -> fall through to the bare summary (279->281).
    monkeypatch.setattr(rw, "_render_get", lambda path, key: {"id": "srv-1"})
    payload = {"type": "deploy_started", "data": {"serviceId": "srv-1"}}
    out = rw.describe_event(payload, {"render_api_key": "rnd_key"})
    assert out == "deploy_started: srv-1"


def test_describe_event_resource_none_falls_through(monkeypatch):
    # Companion: _render_get returns None (resource falsy) -> same fall-through.
    monkeypatch.setattr(rw, "_render_get", lambda path, key: None)
    payload = {"type": "server_failed", "data": {"serviceId": "srv-9"}}
    out = rw.describe_event(payload, {"render_api_key": "rnd_key"})
    assert out == "server_failed: srv-9"
