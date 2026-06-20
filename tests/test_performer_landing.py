"""Tests for the programmatic performer SEO landing pages (#6):
- /api/store/performers/{id} data route (consumer-safe projection),
- /store/performer/{id} crawler-gated server-side collection meta,
- the dynamic /sitemap.xml provider wiring.

All Supabase access is monkeypatched — no live DB.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("STOREFRONT_SQL_ONLY", "true")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

import app as app_module  # noqa: E402
from core import seo  # noqa: E402

client = TestClient(app_module.app)

_LANDING = [{
    "performer_id": 123, "name": "Taylor Swift", "slug": "taylor-swift",
    "category_name": "Pop", "top_category": "Music", "genre": "Pop",
    "home_venue_id": None, "home_venue_name": None,
    "upcoming_first": "2026-08-02T19:00:00+00:00", "upcoming_last": "2026-09-01T19:00:00+00:00",
}]
_EVENTS = [{
    "event_id": 77, "name": "Taylor Swift | Eras Tour", "what": "Concert",
    "when_local": "2026-08-02T19:00:00", "where_venue": "MetLife Stadium",
    "where_city": "East Rutherford", "min_price": 410.0,
    "s4k_total_tickets": 18, "has_seating_chart": True, "popularity": 0.9,
}]


class _FakeSb:
    def __init__(self, landing=_LANDING, events=_EVENTS):
        self._landing, self._events = landing, events

    def rpc(self, name, params):
        data = {
            "get_performer_landing_public": self._landing,
            "get_events_by_performer_public": self._events,
            "get_events_by_venue_public": self._events,
            "get_venue_assets_public": None,
        }.get(name, [])
        return type("Q", (), {"execute": lambda s: type("R", (), {"data": data})()})()


def test_performer_landing_api_projection(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeSb())
    r = client.get("/api/store/performers/123")
    assert r.status_code == 200
    body = r.json()
    assert body["performer"]["name"] == "Taylor Swift"
    assert body["events_count"] == 1
    ev = body["events"][0]
    assert ev["id"] == 77 and ev["from_price"] == 410.0
    # Wall: our inventory depth must NOT be exposed on the public surface.
    assert "s4k_total_tickets" not in ev


def test_performer_landing_api_404_when_no_landing(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeSb(landing=[]))
    assert client.get("/api/store/performers/999").status_code == 404


def test_performer_page_crawler_gets_collection_meta(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeSb())
    r = client.get("/store/performer/123", headers={"User-Agent": "Googlebot/2.1"})
    assert r.status_code == 200
    html = r.text
    assert "<!-- SSR_META_START -->" not in html
    assert "Taylor Swift tickets · 1 upcoming tour dates" in html
    assert "CollectionPage" in html and "ItemList" in html


def test_performer_page_human_keeps_shell(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeSb())
    r = client.get("/store/performer/123", headers={"User-Agent": "Mozilla/5.0 (iPhone)"})
    assert r.status_code == 200
    assert "<!-- SSR_META_START -->" in r.text


def test_venue_landing_api_derives_name_from_events(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeSb())
    r = client.get("/api/store/venues/55")
    assert r.status_code == 200
    body = r.json()
    # venue name/city derived from the event rows (assets RPC returns null)
    assert body["venue"]["name"] == "MetLife Stadium"
    assert body["venue"]["city"] == "East Rutherford"
    assert body["events_count"] == 1
    assert "s4k_total_tickets" not in body["events"][0]


def test_venue_landing_api_404_when_no_events(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeSb(events=[]))
    assert client.get("/api/store/venues/999").status_code == 404


def test_venue_page_crawler_gets_collection_meta(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeSb())
    r = client.get("/store/venue/55", headers={"User-Agent": "facebookexternalhit/1.1"})
    assert r.status_code == 200
    assert "<!-- SSR_META_START -->" not in r.text
    assert "MetLife Stadium tickets" in r.text and "CollectionPage" in r.text


def test_sitemap_includes_dynamic_paths(monkeypatch):
    monkeypatch.setattr(app_module, "_sitemap_dynamic_paths",
                        lambda: ["/store/event/77", "/store/performer/123"])
    # rebuild the router so it picks up the patched provider
    from routers.site_essentials import build_site_essentials_router
    body = build_site_essentials_router(
        "https://shop.example", app_module._sitemap_dynamic_paths
    )
    # exercise the route function directly
    fn = [r.endpoint for r in body.routes if r.path == "/sitemap.xml"][0]
    xml = fn().body.decode()
    assert "/store/event/77" in xml and "/store/performer/123" in xml
    assert "/store</loc>" in xml  # static surface still present


def test_sitemap_survives_provider_error():
    from routers.site_essentials import build_site_essentials_router

    def _boom():
        raise RuntimeError("db down")
    body = build_site_essentials_router("https://shop.example", _boom)
    fn = [r.endpoint for r in body.routes if r.path == "/sitemap.xml"][0]
    xml = fn().body.decode()
    assert "<urlset" in xml and "/store</loc>" in xml  # static-only, no 500


def test_collection_meta_escaping():
    out = seo.build_collection_meta_tags(
        {"kind": "performer", "name": 'Bad" /><script>x</script>', "count": 1,
         "events": [{"name": "E", "url": "https://x/store/event/1", "date_iso": "2026-08-02T19:00:00"}]},
        "https://x/store/performer/1", "https://x/d.png")
    assert '"/><script>' not in out
    assert "\\u003cscript" in out  # JSON-LD '<' escaped
