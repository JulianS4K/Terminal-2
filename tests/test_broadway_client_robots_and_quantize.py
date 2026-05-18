"""Tests for /robots.txt honoring + capture-time quantize helper.

robots.txt:
  BroadwayClient.respect_robots=True (default) fetches /robots.txt on
  first request, caches the parsed policy, and raises BroadwayError on
  any URL disallowed for our UA. Override with respect_robots=False.

quantize_capture_time:
  Module-level helper. Rounds to bucket-appropriate granularity so
  duplicate cron firings within the same dedup window collide on the
  primary key and ON CONFLICT DO NOTHING absorbs them.
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
import requests

from broadway_client import (
    BroadwayClient,
    BroadwayError,
    quantize_capture_time,
)


# ---------- robots.txt — fixture helpers ----------

class _FakeRobotsResponse:
    """Minimal stand-in for urllib.request.urlopen()'s context-manager
    response object."""
    def __init__(self, status: int, body: bytes):
        self.status = status
        self._body = body
    def __enter__(self):
        return self
    def __exit__(self, *args):
        return False
    def read(self):
        return self._body


def _install_fake_robots(monkeypatch, policy_per_host: dict[str, str | None]):
    """Patch urllib.request.urlopen to return canned robots.txt bodies
    keyed by host_base.

    policy_per_host values:
      - str body  → urlopen returns 200 + that body
      - None      → urlopen raises (simulates network error / 4xx that
                    we want to treat as fail-open)
    """
    import urllib.request
    from urllib.parse import urlparse as _urlparse

    def fake_urlopen(req, timeout=None):
        url = req.full_url if hasattr(req, "full_url") else str(req)
        u = _urlparse(url)
        host_base = f"{u.scheme}://{u.netloc}"
        policy = policy_per_host.get(host_base)
        if policy is None:
            raise OSError(f"simulated failure for {url}")
        return _FakeRobotsResponse(200, policy.encode("utf-8"))

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen, raising=True)


def _install_fake_session_200(monkeypatch, body: str = "<html><body>broadway.com hi</body></html>"):
    def fake_get(self, url, timeout=None, allow_redirects=True):
        r = requests.Response()
        r.status_code = 200
        r._content = body.encode("utf-8")
        r.url = url
        return r
    monkeypatch.setattr(requests.Session, "get", fake_get, raising=True)
    monkeypatch.setattr("broadway_client.time.sleep", lambda *_a, **_kw: None)


# ---------- robots.txt — behavior ----------

def test_robots_allow_all_passes(monkeypatch):
    """Empty / Allow-all robots policy → all fetches proceed."""
    _install_fake_robots(monkeypatch, {
        "https://www.broadway.com":     "User-agent: *\nAllow: /\n",
        "https://checkout.broadway.com":"User-agent: *\nAllow: /\n",
    })
    _install_fake_session_200(monkeypatch)
    cli = BroadwayClient()
    status, body = cli._get("https://www.broadway.com/shows/hamilton/")
    assert status == 200


def test_robots_disallow_raises(monkeypatch):
    """A Disallow rule that matches our path should raise BroadwayError
    before the request is sent."""
    _install_fake_robots(monkeypatch, {
        "https://www.broadway.com":     "User-agent: *\nDisallow: /shows/\n",
        "https://checkout.broadway.com":"User-agent: *\nAllow: /\n",
    })
    _install_fake_session_200(monkeypatch)
    cli = BroadwayClient()
    with pytest.raises(BroadwayError) as exc:
        cli._get("https://www.broadway.com/shows/hamilton/")
    assert "robots.txt" in str(exc.value).lower()
    assert "disallow" in str(exc.value).lower() or "shows/hamilton" in str(exc.value)


def test_robots_disallow_only_one_host(monkeypatch):
    """If only www.broadway.com disallows but checkout.broadway.com
    allows, the checkout fetch should still go through."""
    _install_fake_robots(monkeypatch, {
        "https://www.broadway.com":     "User-agent: *\nDisallow: /\n",
        "https://checkout.broadway.com":"User-agent: *\nAllow: /\n",
    })
    _install_fake_session_200(monkeypatch)
    cli = BroadwayClient()
    # www blocked
    with pytest.raises(BroadwayError):
        cli._get("https://www.broadway.com/shows/hamilton/")
    # checkout still works
    status, _ = cli._get("https://checkout.broadway.com/hamilton/14999/2/sections/")
    assert status == 200


def test_robots_override_with_respect_robots_false(monkeypatch):
    """respect_robots=False short-circuits the check entirely."""
    _install_fake_robots(monkeypatch, {
        "https://www.broadway.com": "User-agent: *\nDisallow: /\n",
    })
    _install_fake_session_200(monkeypatch)
    cli = BroadwayClient(respect_robots=False)
    status, _ = cli._get("https://www.broadway.com/shows/hamilton/")
    assert status == 200


def test_robots_fail_open_on_unreadable(monkeypatch):
    """If robots.txt fetch raises (network error, egress block, 403
    from proxy, etc.) we treat that host as 'no policy' and continue.
    Compliance gap if robots is permanently unreachable, but better
    than refusing all work on a transient outage or proxy quirk."""
    _install_fake_robots(monkeypatch, {
        "https://www.broadway.com":      None,  # raise
        "https://checkout.broadway.com": None,  # raise
    })
    _install_fake_session_200(monkeypatch)
    cli = BroadwayClient()
    status, _ = cli._get("https://www.broadway.com/shows/hamilton/")
    assert status == 200


def test_robots_loaded_once_per_session(monkeypatch):
    """_ensure_robots should fetch each host's policy at most once."""
    import urllib.request
    call_count = {"opens": 0}

    real = _install_fake_robots  # reuse the fixture body
    real(monkeypatch, {
        "https://www.broadway.com":      "User-agent: *\nAllow: /\n",
        "https://checkout.broadway.com": "User-agent: *\nAllow: /\n",
    })
    # Wrap to count
    original_urlopen = urllib.request.urlopen
    def counting_urlopen(*args, **kwargs):
        call_count["opens"] += 1
        return original_urlopen(*args, **kwargs)
    monkeypatch.setattr(urllib.request, "urlopen", counting_urlopen, raising=True)
    _install_fake_session_200(monkeypatch)
    cli = BroadwayClient()
    cli._get("https://www.broadway.com/shows/hamilton/")
    cli._get("https://www.broadway.com/shows/wicked/")
    cli._get("https://checkout.broadway.com/hamilton/14999/1/sections/")
    assert call_count["opens"] == 2  # one per host_base, regardless of how many fetches


# ---------- quantize_capture_time ----------

def test_quantize_hot_bucket_rounds_to_minute():
    t = datetime(2026, 5, 18, 17, 23, 45, 678901, tzinfo=timezone.utc)
    q = quantize_capture_time(t, "0-72h")
    assert q == datetime(2026, 5, 18, 17, 23, 0, 0, tzinfo=timezone.utc)


def test_quantize_cold_bucket_rounds_to_hour():
    t = datetime(2026, 5, 18, 17, 23, 45, 678901, tzinfo=timezone.utc)
    q = quantize_capture_time(t, "72h+")
    assert q == datetime(2026, 5, 18, 17, 0, 0, 0, tzinfo=timezone.utc)


def test_quantize_rejects_unknown_bucket():
    t = datetime(2026, 5, 18, 17, 23, 45, tzinfo=timezone.utc)
    with pytest.raises(ValueError) as exc:
        quantize_capture_time(t, "bogus-bucket")
    assert "unknown bucket" in str(exc.value)


def test_quantize_idempotent():
    """Quantizing an already-quantized value yields the same value."""
    t = datetime(2026, 5, 18, 17, 23, 45, 678901, tzinfo=timezone.utc)
    q1 = quantize_capture_time(t, "0-72h")
    q2 = quantize_capture_time(q1, "0-72h")
    assert q1 == q2


def test_quantize_collision_at_bucket_resolution():
    """Two captures within the same minute (hot) collide on quantize.
    This is the property that makes ON CONFLICT DO NOTHING work."""
    t1 = datetime(2026, 5, 18, 17, 23, 12, tzinfo=timezone.utc)
    t2 = datetime(2026, 5, 18, 17, 23, 58, tzinfo=timezone.utc)
    assert quantize_capture_time(t1, "0-72h") == quantize_capture_time(t2, "0-72h")
    # But not at hour resolution if they cross a minute? Both are in
    # the same hour so they still collide on cold bucket too.
    assert quantize_capture_time(t1, "72h+") == quantize_capture_time(t2, "72h+")


def test_quantize_no_collision_across_buckets():
    """Two captures in adjacent minutes don't collide on hot quantize."""
    t1 = datetime(2026, 5, 18, 17, 23, 12, tzinfo=timezone.utc)
    t2 = datetime(2026, 5, 18, 17, 24, 12, tzinfo=timezone.utc)
    assert quantize_capture_time(t1, "0-72h") != quantize_capture_time(t2, "0-72h")
    # Same hour though, so cold quantize collides.
    assert quantize_capture_time(t1, "72h+") == quantize_capture_time(t2, "72h+")
