"""Route-level test for /store/event/{id} server-side meta injection.

Proves the wiring the core/seo.py unit tests can't cover: the crawler
User-Agent gate, the SSR_META marker replacement through the storefront-pages
router, and the defensive fallback when the event lookup fails. Uses a
monkeypatched resolver so no Supabase/TEvo is touched.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_TOKEN", "test-token")
os.environ.setdefault("TEVO_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

import server as app_module  # noqa: E402

client = TestClient(app_module.app)

_FAKE_PAYLOAD = {
    "event": {
        "id": 77,
        "name": "Taylor Swift | The Eras Tour",
        "occurs_at_local": "2026-08-02T19:00:00",
        "venue": {"name": "MetLife Stadium", "city": "East Rutherford", "state": "NJ"},
        "configuration": {},
    },
    "listings": [{"price": 410.0}, {"price": 899.0}],
}


def test_crawler_gets_per_event_meta(monkeypatch):
    monkeypatch.setattr(app_module, "_resolve_event_with_filters", lambda eid, f: _FAKE_PAYLOAD)
    r = client.get("/store/event/77", headers={"User-Agent": "facebookexternalhit/1.1"})
    assert r.status_code == 200
    body = r.text
    # The generic shell title + the marker block are gone, replaced by
    # per-event tags. (The explanatory comment above the marker is retained,
    # so assert on the exact marker token rather than the bare word.)
    assert "<!-- SSR_META_START -->" not in body
    assert "<title>VibePass — event tickets</title>" not in body
    assert "Taylor Swift | The Eras Tour tickets · MetLife Stadium" in body
    assert 'property="og:title"' in body
    assert "application/ld+json" in body
    assert '"startDate": "2026-08-02T19:00:00"' in body
    assert "from $410" in body


def test_human_keeps_static_shell(monkeypatch):
    # Resolver must NOT even be called for a human UA (no extra DB/TEvo cost).
    def _boom(eid, f):  # pragma: no cover - asserts it isn't invoked
        raise AssertionError("resolver should not run for a human UA")
    monkeypatch.setattr(app_module, "_resolve_event_with_filters", _boom)
    r = client.get("/store/event/77", headers={"User-Agent": "Mozilla/5.0 (iPhone)"})
    assert r.status_code == 200
    assert "<!-- SSR_META_START -->" in r.text  # markers intact; store.js fills them client-side
    assert "<title>VibePass — event tickets</title>" in r.text


def test_crawler_fallback_when_lookup_fails(monkeypatch):
    def _raise(eid, f):
        raise RuntimeError("TEvo down")
    monkeypatch.setattr(app_module, "_resolve_event_with_filters", _raise)
    r = client.get("/store/event/77", headers={"User-Agent": "Twitterbot/1.0"})
    assert r.status_code == 200
    # Graceful: shell unchanged (markers still present), generic title.
    assert "<!-- SSR_META_START -->" in r.text
    assert "<title>VibePass — event tickets</title>" in r.text
