"""Gap-closing tests for broadway_client — drives the remaining uncovered
branches (error handling, parse fallbacks, retry/backoff, dataclass
properties, _log_pull, and the CLI _main entrypoint) to 100% line coverage.

Companion to test_broadway_client_flows.py + _robots_and_quantize.py +
_fastly_simulations.py; matches their offline-only convention — no real
network. requests.Session.get and urllib.request.urlopen are monkeypatched;
time.sleep is neutered so retry/backoff loops run instantly.
"""
from __future__ import annotations

import json as _json

import pytest
import requests

import broadway_client
from broadway_client import (
    AvailabilitySnapshot,
    BroadwayClient,
    BroadwayError,
    BroadwayParseError,
    BroadwayPollingRequired,
    SectionListing,
    SectionsSnapshot,
    TicketBlock,
    _assert_readonly_method,
    _main,
    _print_snapshot,
)


# ---------- shared mock plumbing ----------

def _install_routed_session(monkeypatch, routes: dict):
    """{url_substring: (status, body, headers)}; first match wins, else 404."""
    def fake_get(self, url, timeout=None, allow_redirects=True):
        r = requests.Response()
        for needle, (status, body, headers) in routes.items():
            if needle in url:
                r.status_code = status
                r._content = body.encode("utf-8")
                r.url = url
                if headers:
                    r.headers.update(headers)
                return r
        r.status_code = 404
        r._content = b""
        r.url = url
        return r
    monkeypatch.setattr(requests.Session, "get", fake_get, raising=True)
    monkeypatch.setattr("broadway_client.time.sleep", lambda *_a, **_kw: None)


def _no_robots(monkeypatch):
    """Make _ensure_robots a no-op so robots fetch never touches the network."""
    monkeypatch.setattr(BroadwayClient, "_ensure_robots", lambda self: None, raising=True)


# ====================================================================
# _assert_readonly_method (line 94)
# ====================================================================

def test_assert_readonly_method_rejects_non_get():
    for method in ("POST", "put", "Patch", "DELETE"):
        with pytest.raises(BroadwayError) as exc:
            _assert_readonly_method(method)
        assert "READ-ONLY" in str(exc.value)


def test_assert_readonly_method_allows_get():
    assert _assert_readonly_method("get") is None


# ====================================================================
# dataclass properties (172, 176, 268, 286, 290, 294, 298-302)
# ====================================================================

def test_section_listing_all_in_and_available():
    s = SectionListing(
        name="Orchestra", price=100.0, fee=25.0, ticket_type="Standard",
        quantities=[1, 2], price_ids=[7], area_indexes=[1],
    )
    assert s.all_in == 125.0           # line 172
    assert s.available is True         # line 176
    empty = SectionListing(
        name="Mezz", price=50.0, fee=0.0, ticket_type="", quantities=[],
        price_ids=[], area_indexes=[],
    )
    assert empty.available is False


def _ticket(**kw) -> TicketBlock:
    base = dict(
        section_name="Orchestra", area_name="Center", row_name="A",
        ticket_type="Standard", price=120.0, fee=20.0, original_price=None,
        quantity=2, price_id=1, section_id=2, area_id=3, quality=9,
        is_ga=False, can_split=True, price_name="P1",
    )
    base.update(kw)
    return TicketBlock(**base)


def test_ticket_block_all_in():
    t = _ticket(price=120.0, fee=20.0)
    assert t.all_in == 140.0           # line 268


def test_availability_snapshot_props_with_tickets():
    snap = AvailabilitySnapshot(
        event_id=1, event_status=1, requested_quantity=2, score=0.5,
        tickets=[
            _ticket(section_name="Orchestra", price=100.0, fee=10.0),
            _ticket(section_name="Mezzanine", price=200.0, fee=20.0),
            _ticket(section_name="Orchestra", price=150.0, fee=10.0),  # dup section
            _ticket(section_name="", price=80.0, fee=5.0),             # blank skipped
        ],
    )
    assert snap.available is True                  # 286
    assert snap.price_min == 85.0                  # 290 (blank-section block, 80+5)
    assert snap.price_max == 220.0                 # 294
    assert snap.sections == ["Orchestra", "Mezzanine"]  # 298-302 (blank skipped)


def test_availability_snapshot_props_empty():
    snap = AvailabilitySnapshot(
        event_id=1, event_status=None, requested_quantity=None, score=None,
        tickets=[],
    )
    assert snap.available is False
    assert snap.price_min is None
    assert snap.price_max is None
    assert snap.sections == []


# ====================================================================
# __init__ UA CR/LF guard (line 397)
# ====================================================================

def test_invalid_user_agent_crlf_rejected():
    with pytest.raises(ValueError):
        BroadwayClient(user_agent="Bad\r\nInjected: header")
    with pytest.raises(ValueError):
        BroadwayClient(user_agent="Bad\nInjected")


# ====================================================================
# _ensure_robots non-200 status branch (line 441)
# ====================================================================

class _FakeRobotsResponse:
    def __init__(self, status, body):
        self.status = status
        self._body = body
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False
    def read(self):
        return self._body


def test_ensure_robots_skips_non_200(monkeypatch):
    """A non-200 robots.txt response is treated as 'no policy' (continue),
    so no RobotFileParser is cached for that host."""
    import urllib.request

    def fake_urlopen(req, timeout=None):
        return _FakeRobotsResponse(404, b"User-agent: *\nDisallow: /\n")

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen, raising=True)
    cli = BroadwayClient()
    cli._ensure_robots()
    assert cli._robots == {}  # nothing cached → fail-open


# ====================================================================
# _check_robots no-netloc early return (line 460)
# ====================================================================

def test_check_robots_returns_on_relative_url(monkeypatch):
    monkeypatch.setattr(BroadwayClient, "_ensure_robots", lambda self: None, raising=True)
    cli = BroadwayClient()
    # urlparse("/relative").netloc == "" → early return, no raise
    assert cli._check_robots("/relative/path") is None


# ====================================================================
# _get retry/backoff + Retry-After parsing (482-490, 486-487)
# ====================================================================

def test_get_retries_on_503_then_succeeds(monkeypatch):
    _no_robots(monkeypatch)
    calls = {"n": 0}

    def fake_get(self, url, timeout=None, allow_redirects=True):
        calls["n"] += 1
        r = requests.Response()
        r.url = url
        if calls["n"] == 1:
            r.status_code = 503
            r._content = b"busy"
            r.headers["Retry-After"] = "2"   # numeric → float branch
        else:
            r.status_code = 200
            r._content = b"ok"
        return r

    monkeypatch.setattr(requests.Session, "get", fake_get, raising=True)
    monkeypatch.setattr("broadway_client.time.sleep", lambda *_a, **_kw: None)
    cli = BroadwayClient()
    status, body = cli._get("https://www.broadway.com/x")
    assert status == 200
    assert calls["n"] == 2


def test_get_retry_after_non_numeric_falls_back(monkeypatch):
    """Non-numeric Retry-After (e.g. HTTP-date) hits the ValueError path
    and falls back to the exponential backoff value (lines 486-487)."""
    _no_robots(monkeypatch)
    calls = {"n": 0}

    def fake_get(self, url, timeout=None, allow_redirects=True):
        calls["n"] += 1
        r = requests.Response()
        r.url = url
        if calls["n"] == 1:
            r.status_code = 429
            r._content = b"slow down"
            r.headers["Retry-After"] = "Wed, 21 Oct 2026 07:28:00 GMT"  # non-float
        else:
            r.status_code = 200
            r._content = b"ok"
        return r

    monkeypatch.setattr(requests.Session, "get", fake_get, raising=True)
    monkeypatch.setattr("broadway_client.time.sleep", lambda *_a, **_kw: None)
    cli = BroadwayClient()
    status, _ = cli._get("https://www.broadway.com/x")
    assert status == 200
    assert calls["n"] == 2


def test_get_returns_503_after_exhausting_retries(monkeypatch):
    """Once attempts exceed max_retries the loop returns the last response
    without an extra sleep (covers the loop-exit return path)."""
    _no_robots(monkeypatch)

    def fake_get(self, url, timeout=None, allow_redirects=True):
        r = requests.Response()
        r.url = url
        r.status_code = 503
        r._content = b"still busy"
        # no Retry-After → backoff branch
        return r

    monkeypatch.setattr(requests.Session, "get", fake_get, raising=True)
    monkeypatch.setattr("broadway_client.time.sleep", lambda *_a, **_kw: None)
    cli = BroadwayClient()
    status, _ = cli._get("https://www.broadway.com/x", max_retries=2)
    assert status == 503


# ====================================================================
# _log_pull — db insert success + exception (507-519)
# ====================================================================

class _OKTable:
    def insert(self, row):
        self._row = row
        return self
    def execute(self):
        return {"ok": True}


class _OKDB:
    def __init__(self):
        self.inserted = []
    def table(self, name):
        t = _OKTable()
        self.inserted.append((name, t))
        return t


class _BoomDB:
    def table(self, name):
        raise RuntimeError("db is down")


def test_log_pull_writes_to_db():
    db = _OKDB()
    cli = BroadwayClient(db=db)
    cli._log_pull("sections", slug="six", show_id=1, event_id=2,
                  status=200, rows=3, meta={"k": "v"})
    assert db.inserted
    name, table = db.inserted[0]
    assert name == "broadway_pull_log"
    assert table._row["endpoint"] == "sections"
    assert table._row["request_meta"] == {"k": "v"}


def test_log_pull_swallows_db_exception(capsys):
    cli = BroadwayClient(db=_BoomDB())
    # Must not raise even though table() blows up.
    cli._log_pull("sections", slug="six", show_id=1, event_id=2,
                  status=200, rows=3)
    err = capsys.readouterr().err
    assert "pull log skipped" in err


def test_log_pull_noop_without_db():
    cli = BroadwayClient()  # db is None
    assert cli._log_pull("sections", slug=None, show_id=None, event_id=None,
                         status=200, rows=0) is None


# ====================================================================
# parse_sections_url — bad host + bad path (529-537)
# ====================================================================

def test_parse_sections_url_rejects_bad_host():
    with pytest.raises(BroadwayError) as exc:
        BroadwayClient.parse_sections_url("https://evil.example.com/six/1/2/sections/")
    assert "unexpected host" in str(exc.value)


def test_parse_sections_url_rejects_bad_path():
    with pytest.raises(BroadwayError) as exc:
        BroadwayClient.parse_sections_url("https://checkout.broadway.com/not/a/sections/url")
    assert "does not match" in str(exc.value)


def test_parse_sections_url_ok():
    slug, show_id, event_id = BroadwayClient.parse_sections_url(
        "https://checkout.broadway.com/six/12885/1077629/sections/"
    )
    assert (slug, show_id, event_id) == ("six", 12885, 1077629)


# ====================================================================
# _extract_inline_payload edge branches (558-559, 561, 569-570)
# ====================================================================

def test_extract_inline_payload_skips_bad_json_then_finds_good():
    """First `json = {` is malformed (JSONDecodeError → continue), second
    is the real payload."""
    html = (
        "<script>json = {this is not json;</script>"
        '<script>json = {"status":0,"data":{"event_id":1,"sections":[]}};</script>'
    )
    payload = BroadwayClient._extract_inline_payload(html)
    assert payload == {"event_id": 1, "sections": []}


def test_extract_inline_payload_skips_dict_without_data():
    """A `json = {...}` dict lacking a `data` key and not sections-shaped is
    skipped; the next match (the real payload) wins."""
    html = (
        '<script>json = {"junk": true};</script>'
        '<script>json = {"status":0,"data":{"event_id":9,"sections":[]}};</script>'
    )
    payload = BroadwayClient._extract_inline_payload(html)
    assert payload == {"event_id": 9, "sections": []}


def test_extract_inline_payload_bare_payload_form():
    """No `data` wrapper but a sections-shaped dict → returned directly
    (lines 569-570)."""
    html = '<script>json = {"event_id": 42, "sections": [{"name":"Orch"}]};</script>'
    payload = BroadwayClient._extract_inline_payload(html)
    assert payload["event_id"] == 42


def test_extract_inline_payload_empty_init_returns_none():
    html = "<script>var json = {};</script>"
    assert BroadwayClient._extract_inline_payload(html) is None


# ====================================================================
# _coerce_float branches (577-585) + _show_from_payload None (591)
# ====================================================================

def test_coerce_float_variants():
    cf = BroadwayClient._coerce_float
    assert cf(None) is None
    assert cf(5) == 5.0
    assert cf(2.5) == 2.5
    assert cf("3.14") == 3.14
    assert cf("$1,250.50") == 1250.50   # regex fallback path
    assert cf("not-a-price") is None    # regex miss → None
    assert cf(object()) is None         # non-str/num → None


def test_show_from_payload_returns_none_when_no_show():
    assert BroadwayClient._show_from_payload({"sections": []}) is None
    assert BroadwayClient._show_from_payload({"show": "not-a-dict"}) is None


# ====================================================================
# _ticket_from_row (670-681) + parse_availability (725-741)
# ====================================================================

def test_ticket_from_row_full_and_coercions():
    row = {
        "SectionName": "Orchestra", "AreaName": "Center", "RowName": "F",
        "TicketTypeName": "Premium", "TicketPrice": "199.50", "ServiceFee": "25",
        "OriginalTicketPrice": "250", "Quantity": "4", "PriceId": "11",
        "SectionId": "22", "AreaId": "33", "Quality": "bad-int",  # → None
        "IsGA": 1, "CanSplitBlock": 0, "PriceName": "Front Mezz",
        "TicketBlockId": "tbid-1", "seatsStr": ["F1", "F2"],
    }
    t = BroadwayClient._ticket_from_row(row)
    assert t.section_name == "Orchestra"
    assert t.price == 199.50
    assert t.fee == 25.0
    assert t.original_price == 250.0
    assert t.quantity == 4
    assert t.price_id == 11
    assert t.quality is None          # int() raised → None
    assert t.is_ga is True
    assert t.can_split is False
    assert t.seats == ["F1", "F2"]


def test_ticket_from_row_handles_missing_seats_and_none_ids():
    row = {"seatsStr": "not-a-list", "PriceId": None}
    t = BroadwayClient._ticket_from_row(row)
    assert t.seats == []
    assert t.price_id is None
    assert t.price == 0.0


def test_parse_availability_rejects_non_dict():
    with pytest.raises(BroadwayParseError):
        BroadwayClient.parse_availability(["nope"])  # type: ignore[arg-type]


def test_parse_availability_rejects_payload_without_tickets():
    with pytest.raises(BroadwayParseError) as exc:
        BroadwayClient.parse_availability({"status": 0, "data": {"event_id": 1}})
    assert "no data.tickets" in str(exc.value)


def test_parse_availability_full_with_wrapper():
    obj = {
        "status": 0,
        "messages": ["m1", 2],
        "data": {
            "event_id": "1077629", "event_status": 1, "score": "0.9",
            "tickets": [
                {"SectionName": "Orchestra", "TicketPrice": "100", "ServiceFee": "10", "Quantity": 2},
                "bad-row-skipped",
            ],
        },
    }
    snap = BroadwayClient.parse_availability(
        obj, requested_quantity=2, captured_at="2026-06-25T00:00:00Z",
        source_url="https://checkout.broadway.com/x", keep_raw=True,
    )
    assert snap.event_id == 1077629
    assert snap.status == 0
    assert snap.messages == ["m1", "2"]
    assert len(snap.tickets) == 1
    assert snap.score == 0.9
    assert snap.raw_payload is obj


def test_parse_availability_inner_data_form():
    """obj IS the data dict (no wrapper); status absent → None."""
    snap = BroadwayClient.parse_availability(
        {"event_id": 5, "tickets": []}
    )
    assert snap.status is None
    assert snap.event_id == 5
    assert snap.messages == []


# ====================================================================
# _extract_next_data + _extract_initial_state (758-774)
# ====================================================================

def test_extract_next_data_ok():
    html = '<script id="__NEXT_DATA__" type="application/json">{"a": 1}</script>'
    assert BroadwayClient._extract_next_data(html) == {"a": 1}


def test_extract_next_data_missing_returns_none():
    assert BroadwayClient._extract_next_data("<html>nope</html>") is None


def test_extract_next_data_bad_json_returns_none():
    html = '<script id="__NEXT_DATA__">{not valid json}</script>'
    assert BroadwayClient._extract_next_data(html) is None


def test_extract_initial_state_ok():
    html = 'window.__INITIAL_STATE__ = {"x": 2};'
    assert BroadwayClient._extract_initial_state(html) == {"x": 2}


def test_extract_initial_state_preloaded_variant():
    html = 'window.__PRELOADED_STATE__ = {"y": 3};'
    assert BroadwayClient._extract_initial_state(html) == {"y": 3}


def test_extract_initial_state_missing_returns_none():
    assert BroadwayClient._extract_initial_state("<html>none</html>") is None


def test_extract_initial_state_bad_json_returns_none():
    html = 'window.__INITIAL_STATE__ = {bad json};'
    assert BroadwayClient._extract_initial_state(html) is None


# ====================================================================
# _listings_from_html bs4 fallback (785, 788-806)
# ====================================================================

def test_listings_from_html_extracts_rows():
    html = """
    <html><body>
      <li data-section-id="1" data-section-name="Orchestra">
        <span class="price">$199.00</span>
      </li>
      <li data-section-id="2">
        <h3>Mezzanine</h3>
        <span>row text $89.50 here</span>
      </li>
    </body></html>
    """
    cli = BroadwayClient()
    listings = cli._listings_from_html(html)
    names = {l.name for l in listings}
    assert "Orchestra" in names
    # Second row gets name from <h3> header, price from text fallback.
    mezz = next(l for l in listings if l.name == "Mezzanine")
    assert mezz.price == 89.50


def test_listings_from_html_name_from_price_split():
    """Row with no data-section-name and no header — name derived from
    the text before the first price match."""
    html = """
    <html><body>
      <div data-section-id="9">Front Orchestra $150.00</div>
    </body></html>
    """
    cli = BroadwayClient()
    listings = cli._listings_from_html(html)
    assert listings
    assert listings[0].name == "Front Orchestra"
    assert listings[0].price == 150.0


def test_listings_from_html_no_rows_returns_empty():
    cli = BroadwayClient()
    assert cli._listings_from_html("<html><body>nothing</body></html>") == []


# ====================================================================
# fetch_sections — polling-required branch (848-857)
# ====================================================================

POLLING_BODY = (
    "<html><body><script>"
    'json = {"status":0,"data":{'
    '"event_id": 2000001, "event_polling_enabled": true,'
    '"show": {"id":1,"aristotle_id":14999,"slug":"hamilton","title":"Hamilton"},'
    '"sections": [], "areas": [], "premium_areas": [], "types": []'
    "}}.data;"
    "</script></body></html>"
)


def test_fetch_sections_raises_polling_required(monkeypatch):
    _no_robots(monkeypatch)
    _install_routed_session(monkeypatch, {
        "/hamilton/14999/2000001/": (200, POLLING_BODY, {}),
    })
    db = _OKDB()
    cli = BroadwayClient(db=db)
    with pytest.raises(BroadwayPollingRequired) as exc:
        cli.fetch_sections("hamilton", 14999, 2000001)
    assert "event_polling_enabled" in str(exc.value)
    # The polling branch logs a rows=0 pull.
    assert db.inserted


# ====================================================================
# fetch_sections — bs4 fallback listings success (891-895)
# ====================================================================

FALLBACK_BODY = """
<html><body>
  <li data-section-id="1" data-section-name="Orchestra">
    <span class="price">$199.00</span>
  </li>
</body></html>
"""


def test_fetch_sections_uses_bs4_fallback_when_no_inline(monkeypatch):
    _no_robots(monkeypatch)
    _install_routed_session(monkeypatch, {
        "/six/12885/1/": (200, FALLBACK_BODY, {}),
    })
    cli = BroadwayClient()
    snap = cli.fetch_sections("six", 12885, 1)
    assert isinstance(snap, SectionsSnapshot)
    assert snap.show is None
    assert len(snap.sections) == 1
    assert snap.sections[0].name == "Orchestra"


def test_fetch_sections_non_200_raises(monkeypatch):
    _no_robots(monkeypatch)
    _install_routed_session(monkeypatch, {
        "/six/12885/1/": (403, "Access Denied", {}),
    })
    cli = BroadwayClient()
    with pytest.raises(BroadwayError) as exc:
        cli.fetch_sections("six", 12885, 1)
    assert "403" in str(exc.value)


def test_fetch_sections_no_payload_no_listings_raises(monkeypatch):
    _no_robots(monkeypatch)
    _install_routed_session(monkeypatch, {
        "/six/12885/1/": (200, "<html><body>challenge</body></html>", {}),
    })
    cli = BroadwayClient()
    with pytest.raises(BroadwayParseError):
        cli.fetch_sections("six", 12885, 1)


# ====================================================================
# fetch_sections_url (918-919)
# ====================================================================

def test_fetch_sections_url_dispatches(monkeypatch):
    _no_robots(monkeypatch)
    _install_routed_session(monkeypatch, {
        "/six/12885/1/": (200, FALLBACK_BODY, {}),
    })
    cli = BroadwayClient()
    snap = cli.fetch_sections_url("https://checkout.broadway.com/six/12885/1/sections/")
    assert snap.event_id == 1


# ====================================================================
# discover_performances continue branches (944, 947) + discover_shows
# host_ok continue (1019)
# ====================================================================

def test_discover_performances_skips_nonmatching_and_dup_anchors(monkeypatch):
    _no_robots(monkeypatch)
    html = """
    <html><body>broadway.com hamilton
      <a href="/about/">About (no match → 944)</a>
      <a href="https://checkout.broadway.com/hamilton/14999/2000001/sections/">A</a>
      <a href="https://checkout.broadway.com/hamilton/14999/2000001/sections/">A dup → 947</a>
      <a href="https://other.example.com/hamilton/1/2/sections/">offhost skipped</a>
    </body></html>
    """
    _install_routed_session(monkeypatch, {
        "/shows/hamilton/": (200, html, {}),
    })
    cli = BroadwayClient()
    perfs = cli.discover_performances("hamilton")
    assert len(perfs) == 1
    assert perfs[0].event_id == 2000001


def test_discover_shows_skips_offhost_anchor(monkeypatch):
    _no_robots(monkeypatch)
    html = """
    <html><body>broadway.com
      <a href="https://evil.example.com/shows/hamilton/">off-host → 1019</a>
      <a href="/shows/six/">SIX</a>
    </body></html>
    """
    _install_routed_session(monkeypatch, {
        "/shows/": (200, html, {}),
    })
    cli = BroadwayClient()
    shows = cli.discover_shows()
    assert [s.slug for s in shows] == ["six"]


def test_discover_shows_empty_but_markers_present_returns_empty(monkeypatch):
    """200 with no show anchors but 'broadway.com' marker present → []
    (no raise)."""
    _no_robots(monkeypatch)
    _install_routed_session(monkeypatch, {
        "/shows/": (200, "<html><body>broadway.com but no anchors</body></html>", {}),
    })
    cli = BroadwayClient()
    assert cli.discover_shows() == []


# ====================================================================
# CLI _main + _print_snapshot (1086-1173)
# ====================================================================

def _stub_snapshot():
    return SectionsSnapshot(
        slug="six", show_id=12885, event_id=1, captured_at_utc="2026-06-25T00:00:00Z",
        source_url="https://checkout.broadway.com/six/12885/1/sections/",
        performance_time=None, performance_secondary_time=None, event_status=None,
        scatter_available=None, inquiry_type_id=None, show=None,
        sections=[], areas=[], premium_areas=[], types=[], alerts=[],
        raw_payload={"k": "v"},
    )


def test_print_snapshot_redacts_raw_payload(capsys):
    _print_snapshot(_stub_snapshot())
    out = capsys.readouterr().out
    assert "bytes>" in out  # raw_payload summarized, not dumped


def test_main_no_args_prints_usage():
    assert _main(["broadway_client.py"]) == 1


def test_main_unknown_command(capsys):
    assert _main(["broadway_client.py", "frobnicate"]) == 2
    assert "unknown command" in capsys.readouterr().err


def test_main_sections(monkeypatch, capsys):
    monkeypatch.setattr(BroadwayClient, "fetch_sections",
                        lambda self, slug, sid, eid, **kw: _stub_snapshot())
    rc = _main(["broadway_client.py", "sections", "six", "12885", "1"])
    assert rc == 0


def test_main_sections_url(monkeypatch):
    monkeypatch.setattr(BroadwayClient, "fetch_sections_url",
                        lambda self, url, **kw: _stub_snapshot())
    assert _main(["broadway_client.py", "sections-url",
                  "https://checkout.broadway.com/six/12885/1/sections/"]) == 0


def test_main_discover(monkeypatch, capsys):
    from broadway_client import Performance
    monkeypatch.setattr(BroadwayClient, "discover_performances",
                        lambda self, slug: [Performance(slug="six", show_id=1, event_id=2)])
    assert _main(["broadway_client.py", "discover", "six"]) == 0
    assert "six" in capsys.readouterr().out


def test_main_shows(monkeypatch, capsys):
    from broadway_client import BroadwayShowStub
    monkeypatch.setattr(BroadwayClient, "discover_shows",
                        lambda self: [BroadwayShowStub(slug="six", title="SIX")])
    assert _main(["broadway_client.py", "shows"]) == 0
    assert "six" in capsys.readouterr().out


def test_main_snapshot_success(monkeypatch):
    from broadway_client import SnapshotShowResult
    res = SnapshotShowResult(slug="six")
    res.snapshots.append(_stub_snapshot())
    res.fetch_errors.append({"event_id": 9, "error_class": "BroadwayError", "error_message": "boom"})
    monkeypatch.setattr(BroadwayClient, "snapshot_show", lambda self, slug: res)
    assert _main(["broadway_client.py", "snapshot", "six"]) == 0


def test_main_snapshot_discover_error(monkeypatch, capsys):
    from broadway_client import SnapshotShowResult
    res = SnapshotShowResult(slug="six")
    res.discover_error = BroadwayError("403")
    monkeypatch.setattr(BroadwayClient, "snapshot_show", lambda self, slug: res)
    assert _main(["broadway_client.py", "snapshot", "six"]) == 4
    assert "discover failed" in capsys.readouterr().err


def test_main_dump_raw_writes_file(monkeypatch, tmp_path, capsys):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(BroadwayClient, "_get",
                        lambda self, url, **kw: (200, "<html>hi</html>"))
    out_file = tmp_path / "dump.html"
    rc = _main(["broadway_client.py", "dump-raw",
                "https://checkout.broadway.com/six/12885/1/sections/", str(out_file)])
    assert rc == 0
    assert out_file.read_text() == "<html>hi</html>"
    assert "HTTP 200" in capsys.readouterr().out


def test_main_dump_raw_rejects_outside_cwd(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(BroadwayClient, "_get",
                        lambda self, url, **kw: (200, "x"))
    with pytest.raises(SystemExit):
        _main(["broadway_client.py", "dump-raw",
               "https://checkout.broadway.com/six/12885/1/sections/", "/etc/escape.html"])


def test_main_parse_file(tmp_path, capsys):
    p = tmp_path / "page.html"
    p.write_text(
        '<script>json = {"status":0,"data":{'
        '"event_id":1,"show":{"slug":"six","aristotle_id":12885},'
        '"sections":[]}};</script>'
    )
    assert _main(["broadway_client.py", "parse-file", str(p)]) == 0
    assert "six" in capsys.readouterr().out


def test_main_parse_file_no_payload(tmp_path, capsys):
    p = tmp_path / "empty.html"
    p.write_text("<html>no payload</html>")
    assert _main(["broadway_client.py", "parse-file", str(p)]) == 3
    assert "no inline payload" in capsys.readouterr().err


def test_main_parse_availability(tmp_path, capsys):
    p = tmp_path / "avail.json"
    p.write_text(_json.dumps({"status": 0, "data": {"event_id": 1, "tickets": []}}))
    assert _main(["broadway_client.py", "parse-availability", str(p)]) == 0
    out = capsys.readouterr().out
    assert "event_id" in out
