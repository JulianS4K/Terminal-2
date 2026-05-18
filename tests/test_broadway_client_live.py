"""Live-network tests for broadway_client.

Opt-in: set LIVE_BROADWAY=1 to enable. Without it, every test here skips,
so this file is safe to run on egress-restricted environments (CI,
Claude Code on the web with the default network policy) without noise.

    LIVE_BROADWAY=1 pytest tests/test_broadway_client_live.py -v

All requests are GET (RULE 2 / read-only, asserted at runtime by
_assert_readonly_method). If the local egress proxy denies the request
(typical Claude Code on web symptom: HTTP 403 host_not_allowed), tests
skip with a clear reason instead of failing — that signals "env
misconfigured", not "parser regression".

Default target slug: "the-25th-annual-putnam-county-spelling-bee".
Override with BROADWAY_LIVE_SLUG=<slug> for a different show. We
auto-discover the first current performance rather than hard-coding an
event_id so the test doesn't bitrot when shows close or schedules shift.
"""
from __future__ import annotations

import os

import pytest
import requests

LIVE = os.environ.get("LIVE_BROADWAY") == "1"
pytestmark = pytest.mark.skipif(
    not LIVE,
    reason="set LIVE_BROADWAY=1 to enable live-network tests (see docs/broadway-live-testing.md)",
)

SLUG = os.environ.get(
    "BROADWAY_LIVE_SLUG", "the-25th-annual-putnam-county-spelling-bee"
)


def _skip_if_egress_blocked(exc: Exception, probe_url: str) -> None:
    """Translate a known egress-proxy denial into a skip.

    Container egress proxies (Claude Code on web, some corp networks)
    return HTTP 403 with header `x-deny-reason: host_not_allowed` or
    body `Host not in allowlist`. broadway_client wraps non-200s in a
    BroadwayError that only carries the status code, so we re-probe the
    URL here to inspect headers / body and distinguish proxy denial
    (skip) from a real Broadway.com 403 (fail).
    """
    if "403" not in str(exc):
        return
    try:
        r = requests.get(probe_url, timeout=5, allow_redirects=False)
    except requests.RequestException:
        return
    deny = r.headers.get("x-deny-reason", "").lower()
    body = (r.text or "")[:200].lower()
    if "host_not_allowed" in deny or "not in allowlist" in body:
        pytest.skip(f"egress proxy blocked {probe_url}: {deny or body!r}")


def test_discover_performances_returns_some():
    from broadway_client import BroadwayClient, BroadwayError

    cli = BroadwayClient()
    try:
        perfs = cli.discover_performances(SLUG)
    except BroadwayError as e:
        _skip_if_egress_blocked(e, f"https://www.broadway.com/shows/{SLUG}/")
        raise
    assert perfs, f"no performances discovered for slug={SLUG!r} — show may have closed"
    p = perfs[0]
    assert p.slug == SLUG
    assert p.show_id > 0
    assert p.event_id > 0


def test_fetch_sections_first_performance():
    from broadway_client import BroadwayClient, BroadwayError

    cli = BroadwayClient()
    try:
        perfs = cli.discover_performances(SLUG)
    except BroadwayError as e:
        _skip_if_egress_blocked(e, f"https://www.broadway.com/shows/{SLUG}/")
        raise
    if not perfs:
        pytest.skip(f"no performances for slug={SLUG!r}")
    p = perfs[0]
    sections_url = BroadwayClient.sections_url(p.slug, p.show_id, p.event_id)
    try:
        snap = cli.fetch_sections(p.slug, p.show_id, p.event_id)
    except BroadwayError as e:
        _skip_if_egress_blocked(e, sections_url)
        raise

    assert snap.event_id == p.event_id
    assert snap.show_id == p.show_id
    assert snap.slug == SLUG
    assert snap.show is not None
    assert snap.show.title
    # A sold-out or cancelled performance can legitimately return zero
    # sections — only assert the shape, not the count.
    assert isinstance(snap.sections, list)
