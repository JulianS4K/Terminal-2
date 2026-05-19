"""Flow-level tests for broadway_client — discover_shows + snapshot_show.

Both methods chain multiple HTTP calls (one to /shows/ index then
per-show / per-performance fetches), so we mock requests.Session.get
to keep them pure-offline and deterministic.
"""
from __future__ import annotations

import requests
import pytest

from broadway_client import (
    BroadwayClient,
    BroadwayError,
    BroadwayParseError,
    BroadwayShowStub,
    SnapshotShowResult,
)


# ---------- mock plumbing (per-URL routing) ----------

def _install_routed_session(monkeypatch, routes: dict):
    """Install a Session.get that dispatches by URL.

    `routes` is {url_substring: (status, body, headers)}. The first
    matching substring wins. Unmatched URLs return (404, '', {})."""
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


# ---------- discover_shows ----------

VALID_SHOWS_INDEX_HTML = """
<html><head><title>Shows | Broadway.com</title></head>
<body>
  <header><a href="https://www.broadway.com/">Broadway.com</a></header>
  <main>
    <ul class="show-list">
      <li><a href="/shows/hamilton/">Hamilton</a></li>
      <li><a href="/shows/the-lion-king/">The Lion King</a></li>
      <li><a href="/shows/six/">SIX</a></li>
      <li><a href="/shows/the-25th-annual-putnam-county-spelling-bee/">The 25th Annual Putnam County Spelling Bee</a></li>
      <li><a href="/shows/hamilton/">Hamilton (dupe)</a></li>
      <li><a href="/shows/">All shows</a></li>
      <li><a href="https://www.broadway.com/shows/wicked/">Wicked</a></li>
    </ul>
  </main>
</body></html>
"""


def test_discover_shows_extracts_unique_slugs(monkeypatch):
    _install_routed_session(monkeypatch, {
        "/shows/": (200, VALID_SHOWS_INDEX_HTML, {"x-served-by": "cache-fastly-test"}),
    })
    cli = BroadwayClient()
    shows = cli.discover_shows()
    slugs = sorted(s.slug for s in shows)
    assert slugs == [
        "hamilton",
        "six",
        "the-25th-annual-putnam-county-spelling-bee",
        "the-lion-king",
        "wicked",
    ]
    # Titles populated from anchor text
    hamilton = next(s for s in shows if s.slug == "hamilton")
    assert hamilton.title == "Hamilton"
    assert hamilton.show_page_url == "https://www.broadway.com/shows/hamilton/"


def test_discover_shows_skips_bare_shows_anchor(monkeypatch):
    """The `<a href="/shows/">` anchor must not produce an empty-slug
    stub. Regex requires at least one slug character after /shows/."""
    _install_routed_session(monkeypatch, {
        "/shows/": (200, VALID_SHOWS_INDEX_HTML, {}),
    })
    cli = BroadwayClient()
    shows = cli.discover_shows()
    assert all(s.slug for s in shows)
    assert all(s.slug != "" for s in shows)


def test_discover_shows_raises_on_403(monkeypatch):
    _install_routed_session(monkeypatch, {
        "/shows/": (403, "Access Denied — Reference #abc", {"x-fastly-bot-decision": "deny"}),
    })
    cli = BroadwayClient()
    with pytest.raises(BroadwayError) as exc:
        cli.discover_shows()
    assert "403" in str(exc.value)


def test_discover_shows_raises_on_fastly_challenge_200(monkeypatch):
    """200 with a JS challenge body lacks the canonical 'broadway.com'
    substring. Should raise BroadwayParseError, not silently return []."""
    challenge_body = (
        "<html><head><title>Checking your browser</title></head>"
        "<body><script>window.location='/cdn-cgi/challenge';</script></body></html>"
    )
    _install_routed_session(monkeypatch, {
        "/shows/": (200, challenge_body, {}),
    })
    cli = BroadwayClient()
    with pytest.raises(BroadwayParseError) as exc:
        cli.discover_shows()
    assert "no shows" in str(exc.value).lower()


# ---------- snapshot_show — structured result ----------

VALID_SHOW_PAGE_HAMILTON = """
<html><head><title>Hamilton | Broadway.com</title></head>
<body><h1>Hamilton</h1>
<a href="https://checkout.broadway.com/hamilton/14999/2000001/sections/">7pm Wed</a>
<a href="https://checkout.broadway.com/hamilton/14999/2000002/sections/">2pm Sat</a>
</body></html>
"""

VALID_SECTIONS_PAYLOAD_BODY = (
    "<html><body><script>"
    'var json = {};\n'
    'json = {"status": 0, "data": {'
    '"event_id": 2000001, "event_status": 1, '
    '"show": {"id": 1, "aristotle_id": 14999, "slug": "hamilton", "title": "Hamilton"},'
    ' "performance_time": "2026-06-03T19:00:00-04:00",'
    ' "sections": [{"name": "Orchestra", "price": 250.0, "fee": 30.0,'
    '   "ticket_type": "Standard", "quantities": [1,2,3], "price_ids": [1], "area_indexes": [1]}],'
    ' "areas": [], "premium_areas": [], "types": [], "alerts": []'
    "}}.data;"
    "</script></body></html>"
)


def test_snapshot_show_returns_structured_result_on_success(monkeypatch):
    _install_routed_session(monkeypatch, {
        "/shows/hamilton/": (200, VALID_SHOW_PAGE_HAMILTON, {}),
        # Both event_id URLs get the same payload — close enough for the test
        "/hamilton/14999/": (200, VALID_SECTIONS_PAYLOAD_BODY, {}),
    })
    cli = BroadwayClient()
    result = cli.snapshot_show("hamilton")
    assert isinstance(result, SnapshotShowResult)
    assert result.slug == "hamilton"
    assert result.ok is True
    assert result.discover_error is None
    assert len(result.snapshots) == 2
    assert result.fetch_errors == []
    assert result.attempted == 2


def test_snapshot_show_captures_discover_error(monkeypatch):
    """When the show page returns 403, snapshot_show stores the error
    in discover_error and returns early with empty snapshots."""
    _install_routed_session(monkeypatch, {
        "/shows/hamilton/": (403, "Access Denied", {"x-fastly-bot-decision": "deny"}),
    })
    cli = BroadwayClient()
    result = cli.snapshot_show("hamilton")
    assert result.ok is False
    assert isinstance(result.discover_error, BroadwayError)
    assert "403" in str(result.discover_error)
    assert result.snapshots == []
    assert result.fetch_errors == []
    assert result.attempted == 0


def test_snapshot_show_partial_per_perf_failure(monkeypatch):
    """Discover succeeds, one perf fetch returns 403, the other 200.
    Result should have 1 snapshot + 1 fetch_error, not raise."""
    bad_perf_body = "Access Denied"

    # Per-event-id routing: 2000001 OK, 2000002 fails
    def fake_get(self, url, timeout=None, allow_redirects=True):
        r = requests.Response()
        r.url = url
        if "/shows/hamilton/" in url:
            r.status_code = 200
            r._content = VALID_SHOW_PAGE_HAMILTON.encode("utf-8")
        elif "/hamilton/14999/2000001/" in url:
            r.status_code = 200
            r._content = VALID_SECTIONS_PAYLOAD_BODY.encode("utf-8")
        elif "/hamilton/14999/2000002/" in url:
            r.status_code = 403
            r._content = bad_perf_body.encode("utf-8")
        else:
            r.status_code = 404
            r._content = b""
        return r
    monkeypatch.setattr(requests.Session, "get", fake_get, raising=True)
    monkeypatch.setattr("broadway_client.time.sleep", lambda *_a, **_kw: None)

    cli = BroadwayClient()
    result = cli.snapshot_show("hamilton")
    assert result.ok is True   # discover succeeded
    assert len(result.snapshots) == 1
    assert result.snapshots[0].event_id == 2000001
    assert len(result.fetch_errors) == 1
    err = result.fetch_errors[0]
    assert err["event_id"] == 2000002
    assert err["error_class"] == "BroadwayError"
    assert "403" in err["error_message"]


# ---------- BroadwayShowStub dataclass ----------

def test_broadway_show_stub_minimal_fields():
    stub = BroadwayShowStub(slug="hamilton")
    assert stub.slug == "hamilton"
    assert stub.title is None
    assert stub.show_page_url is None


def test_snapshot_show_result_helpers():
    r = SnapshotShowResult(slug="x")
    assert r.ok is True
    assert r.attempted == 0
    r.fetch_errors.append({"event_id": 1, "error_class": "BroadwayError", "error_message": "x"})
    assert r.attempted == 1
