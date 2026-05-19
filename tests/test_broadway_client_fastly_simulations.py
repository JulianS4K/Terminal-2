"""Simulate Fastly-edge block responses and characterize broadway_client's
behavior against each.

Broadway.com is fronted by Fastly's CDN/WAF. When a real fetch reaches
the origin, the Django inline-JSON parser is well-tested
(test_broadway_client.py covers it). But before that, Fastly can return
any of several block patterns. This file pins down — by simulation —
exactly what broadway_client does in each case, so:

  1. We catch regressions in error handling.
  2. Operators reading logs can map a status / body shape to an
     expected client outcome.
  3. The "silent empty" failure mode (bot challenge that returns 200
     with no inline JSON) is loudly documented as a known gap.

These tests are pure-offline: requests.Session.get is monkeypatched.
No network, no fixtures, no LIVE_BROADWAY needed.
"""
from __future__ import annotations

import requests
import pytest

from broadway_client import BroadwayClient, BroadwayError, BroadwayParseError


# ---------- mock plumbing ----------

def _install_fake_session(monkeypatch, status: int, body: str, headers: dict | None = None):
    """Replace requests.Session.get so every call returns the same
    canned response. Also stubs time.sleep so 429/503 retry loops
    don't actually sleep."""
    def fake_get(self, url, timeout=None, allow_redirects=True):
        r = requests.Response()
        r.status_code = status
        r._content = body.encode("utf-8")
        r.url = url
        r.headers.update(headers or {})
        return r
    monkeypatch.setattr(requests.Session, "get", fake_get, raising=True)
    monkeypatch.setattr("broadway_client.time.sleep", lambda *_a, **_kw: None)


# ---------- canonical Fastly block bodies ----------

FASTLY_PROXY_DENY_BODY = (
    "Fastly error: unknown domain: checkout.broadway.com. "
    "Please check that this domain has been added to a service."
)

FASTLY_RATELIMIT_BODY = (
    "<html><body><h1>429 Too Many Requests</h1>"
    "<p>You have exceeded the rate limit.</p></body></html>"
)

FASTLY_ORIGIN_503_BODY = (
    "<html><head><title>Fastly error: unable to forward request</title></head>"
    "<body><h1>Fastly error: unable to forward request</h1>"
    "<p>Details: connection timed out</p></body></html>"
)

FASTLY_BOT_DENY_BODY = (
    "<html><body><h1>Access Denied</h1>"
    "<p>You don't have permission to access this resource.</p>"
    "<p>Reference #18.abc123.1779124060.def456</p></body></html>"
)

# The dangerous one: HTTP 200 with HTML that doesn't contain the
# Django inline-JSON. Mimics a Fastly bot-challenge page or an A/B
# variant that wraps the real page.
FASTLY_BOT_CHALLENGE_200_BODY = (
    "<html><head><title>Checking your browser</title></head>"
    "<body><script>/* challenge script, no var json = ... */"
    "window.location='/cdn-cgi/challenge';</script>"
    "<noscript>Enable JavaScript and cookies.</noscript></body></html>"
)

# Control case: looks like a real Broadway.com checkout page payload,
# trimmed to the minimum the parser needs.
VALID_INLINE_PAYLOAD_BODY = (
    "<html><body><script>"
    'var json = {};\n'
    'json = {"status": 0, "data": {'
    '"event_id": 1085713, "event_status": 1, '
    '"show": {"id": 1, "aristotle_id": 13193, "slug": "the-25th-annual-putnam-county-spelling-bee",'
    ' "title": "The 25th Annual Putnam County Spelling Bee"},'
    ' "performance_time": "2026-06-01T19:00:00-04:00",'
    ' "sections": [{"name": "Orchestra", "price": 95.0, "fee": 25.0,'
    '   "ticket_type": "Standard", "quantities": [1,2,3], "price_ids": [1],'
    '   "area_indexes": [1]}],'
    ' "areas": [], "premium_areas": [], "types": [], "alerts": []'
    "}}.data;"
    "</script></body></html>"
)


# ---------- scenarios ----------

SECTIONS_KWARGS = dict(
    slug="the-25th-annual-putnam-county-spelling-bee",
    show_id=13193,
    event_id=1085713,
)


def test_fastly_proxy_deny_403(monkeypatch):
    """Fastly returns 403 'unknown domain' (proxy-level deny).
    Expected: BroadwayError surfaces the 403."""
    _install_fake_session(
        monkeypatch, 403, FASTLY_PROXY_DENY_BODY,
        headers={"x-served-by": "cache-fastly-test"},
    )
    cli = BroadwayClient()
    with pytest.raises(BroadwayError) as exc:
        cli.fetch_sections(**SECTIONS_KWARGS)
    assert "403" in str(exc.value)


def test_fastly_ratelimit_429_exhausts_retries(monkeypatch):
    """Fastly returns 429 with Retry-After. _get retries up to
    max_retries=3 then surfaces as BroadwayError.
    Expected: BroadwayError after retries, status 429 in the message."""
    _install_fake_session(
        monkeypatch, 429, FASTLY_RATELIMIT_BODY,
        headers={"Retry-After": "1", "x-served-by": "cache-fastly-test"},
    )
    cli = BroadwayClient()
    with pytest.raises(BroadwayError) as exc:
        cli.fetch_sections(**SECTIONS_KWARGS)
    assert "429" in str(exc.value)


def test_fastly_origin_503_exhausts_retries(monkeypatch):
    """Fastly returns 503 because origin is down / timed out.
    Same retry path as 429. Expected: BroadwayError after retries."""
    _install_fake_session(
        monkeypatch, 503, FASTLY_ORIGIN_503_BODY,
        headers={"x-served-by": "cache-fastly-test"},
    )
    cli = BroadwayClient()
    with pytest.raises(BroadwayError) as exc:
        cli.fetch_sections(**SECTIONS_KWARGS)
    assert "503" in str(exc.value)


def test_fastly_bot_deny_403(monkeypatch):
    """Fastly bot management deny — 403 + 'Access Denied' body +
    reference id. Same outcome as proxy deny from the client's view."""
    _install_fake_session(
        monkeypatch, 403, FASTLY_BOT_DENY_BODY,
        headers={
            "x-served-by": "cache-fastly-test",
            "x-fastly-bot-decision": "deny",
        },
    )
    cli = BroadwayClient()
    with pytest.raises(BroadwayError) as exc:
        cli.fetch_sections(**SECTIONS_KWARGS)
    assert "403" in str(exc.value)


def test_fastly_bot_challenge_200_raises(monkeypatch):
    """Fastly returns HTTP 200 with a JS challenge page (no Django
    inline JSON, no bs4-matching listings). Previously this fell
    through to an empty SectionsSnapshot indistinguishable from a
    legitimately-empty show.

    Fixed 2026-05-18 (D3): fetch_sections now raises
    BroadwayParseError on 200 + no inline payload + no listings.
    Raises loudly so cron drift signals don't get corrupted."""
    _install_fake_session(
        monkeypatch, 200, FASTLY_BOT_CHALLENGE_200_BODY,
        headers={"x-served-by": "cache-fastly-test"},
    )
    cli = BroadwayClient()
    with pytest.raises(BroadwayParseError) as exc:
        cli.fetch_sections(**SECTIONS_KWARGS)
    assert "no inline payload" in str(exc.value).lower()
    assert "fastly" in str(exc.value).lower() or "redesign" in str(exc.value).lower()


def test_fastly_clean_200_valid_payload(monkeypatch):
    """Control: Fastly serves the real origin response (cache hit or
    pass-through). Parser produces a proper snapshot."""
    _install_fake_session(
        monkeypatch, 200, VALID_INLINE_PAYLOAD_BODY,
        headers={
            "x-served-by": "cache-fastly-test",
            "x-cache": "HIT",
            "x-timer": "S1779124060.000000,VS0,VE12",
        },
    )
    cli = BroadwayClient()
    snap = cli.fetch_sections(**SECTIONS_KWARGS)
    assert snap.event_id == 1085713
    assert snap.show is not None
    assert snap.show.title == "The 25th Annual Putnam County Spelling Bee"
    assert len(snap.sections) == 1
    assert snap.sections[0].name == "Orchestra"
    assert snap.sections[0].price == 95.0


# ---------- discover_performances against same patterns ----------

def test_discover_against_fastly_bot_challenge_raises(monkeypatch):
    """Fixed 2026-05-18 (D3): discover_performances raises
    BroadwayParseError on 200 + zero anchors + no Broadway.com brand
    markers in the body. A challenge page has no slug / no
    'broadway.com' string outside of script noise — that's the
    fingerprint we key on."""
    _install_fake_session(
        monkeypatch, 200, FASTLY_BOT_CHALLENGE_200_BODY,
        headers={"x-served-by": "cache-fastly-test"},
    )
    cli = BroadwayClient()
    with pytest.raises(BroadwayParseError) as exc:
        cli.discover_performances("the-25th-annual-putnam-county-spelling-bee")
    assert "no performances" in str(exc.value).lower()


def test_discover_legit_empty_show_page_does_not_raise(monkeypatch):
    """Counter-case: a real Broadway.com show page that legitimately
    has no upcoming performances (closed run, dark week) still
    returns [] without raising. Distinguished by the presence of
    Broadway.com brand markers in the HTML (slug or 'broadway.com'
    substring)."""
    legit_empty_html = (
        "<html><head><title>Hamilton | Broadway.com</title></head>"
        "<body><h1>Hamilton</h1>"
        "<p>This show is currently between performance weeks. "
        "Check back at <a href='https://www.broadway.com'>broadway.com</a> "
        "for updated schedules.</p></body></html>"
    )
    _install_fake_session(
        monkeypatch, 200, legit_empty_html,
        headers={"x-served-by": "cache-fastly-test"},
    )
    cli = BroadwayClient()
    perfs = cli.discover_performances("hamilton")
    assert perfs == []


def test_discover_against_fastly_403(monkeypatch):
    """403 in discover surfaces as BroadwayError."""
    _install_fake_session(monkeypatch, 403, FASTLY_BOT_DENY_BODY)
    cli = BroadwayClient()
    with pytest.raises(BroadwayError) as exc:
        cli.discover_performances("the-25th-annual-putnam-county-spelling-bee")
    assert "403" in str(exc.value)
