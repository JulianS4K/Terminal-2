"""D4 / Bridge crawler pre-render + events sitemap (routers/pages.py, Stage 5).

Exercises the two new routes through the real app with the Supabase REST call
monkeypatched, so no network. Covers: JSON-LD + OG injection on a published
event, the untouched shell on a bad id / empty result / REST failure / no keys,
route precedence over the SPA catch-all, and the sitemap shape.
"""
from __future__ import annotations

import json
import os

import pytest
from fastapi.testclient import TestClient

import routers.pages as pages_mod
import server as app_module

client = TestClient(app_module.app)

SHELL = """<!doctype html><html><head>
<meta charset="UTF-8" />
<title>Exos | Live the Moment</title>
<meta name="description" content="Bridge — independent venue ticketing." />
<meta property="og:type" content="website" />
<meta property="og:title" content="Exos | Live the Moment" />
<meta property="og:description" content="Bridge — independent venue ticketing." />
<meta property="og:image" content="/bridge/icon-512.png" />
<meta name="twitter:card" content="summary" />
<meta name="twitter:title" content="Exos | Live the Moment" />
</head><body><div id="root"></div></body></html>"""

EVENT = {
    "id": "11111111-2222-4333-8444-555555555555",
    "name": "Friday <Night>",
    "description": "Line 1\nLine 2",
    "starts_at": "2026-10-30T20:00:00-04:00",
    "ends_at": None,
    "doors_at": "2026-10-30T19:00:00-04:00",
    "timezone": "America/New_York",
    "currency": "USD",
    "venue_name": "Brooklyn Steel",
    "venue_address": {"street": "319 Frost St", "city": "Brooklyn", "region": "NY", "country": "US", "postal": "11222"},
    "performer_names": ["Band A", "Band B"],
    "image_url": "https://cdn/x.png",
    "total_tickets": 100,
    "tickets_sold": 100,
    "google_place_id": "ChIJabc123",
    "venue_lat": 40.7167,
    "venue_lng": -73.9420,
    "updated_at": "2026-09-11T12:00:00+00:00",
}


class _Resp:
    def __init__(self, status: int, payload):
        self.status_code = status
        self._payload = payload

    def json(self):
        return self._payload


@pytest.fixture
def bridge_dir(tmp_path, monkeypatch):
    (tmp_path / "index.html").write_text(SHELL, encoding="utf-8")
    monkeypatch.setattr(app_module, "_BRIDGE_DIR", str(tmp_path))
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://proj.supabase.co")
    monkeypatch.setattr(app_module, "SUPABASE_ANON_KEY", "anon-key")
    return tmp_path


def _fake_get(rows, *, status=200, calls=None):
    def get(url, params=None, headers=None, timeout=None):
        if calls is not None:
            calls.append({"url": url, "params": params, "headers": headers, "timeout": timeout})
        return _Resp(status, rows)
    return get


def test_event_page_injects_json_ld_and_og(bridge_dir, monkeypatch):
    calls = []
    monkeypatch.setattr(pages_mod.requests, "get", _fake_get([EVENT], calls=calls))
    r = client.get(f"/bridge/event/{EVENT['id']}", headers={"host": "bridge.example.com", "x-forwarded-proto": "https"})
    assert r.status_code == 200
    body = r.text
    # REST call shape: anon key, published-only view, bounded timeout.
    assert calls and calls[0]["url"].endswith("/rest/v1/exos_public_events")
    assert calls[0]["params"]["id"] == f"eq.{EVENT['id']}"
    assert calls[0]["headers"]["apikey"] == "anon-key"
    assert calls[0]["timeout"] == 2.0
    # Title + OG swapped, escaped.
    assert "<title>Friday &lt;Night&gt; | Exos</title>" in body
    assert 'property="og:type" content="event"' in body
    assert 'property="og:image" content="https://cdn/x.png"' in body
    assert 'name="twitter:card" content="summary_large_image"' in body
    assert '<link rel="canonical" href="https://bridge.example.com/bridge/event/' in body
    # JSON-LD present with the Google Events fields.
    start = body.index('id="vibepass-jsonld">') + len('id="vibepass-jsonld">')
    ld = json.loads(body[start: body.index("</script>", start)])
    assert ld["@type"] == "Event" and ld["name"] == "Friday <Night>"
    assert ld["location"]["geo"] == {"@type": "GeoCoordinates", "latitude": 40.7167, "longitude": -73.942}
    assert "query_place_id=ChIJabc123" in ld["location"]["hasMap"]
    assert ld["location"]["address"]["postalCode"] == "11222"
    assert ld["offers"]["availability"] == "https://schema.org/SoldOut"
    assert [p["name"] for p in ld["performer"]] == ["Band A", "Band B"]
    assert ld["doorTime"] == EVENT["doors_at"]
    assert ld["url"] == f"https://bridge.example.com/bridge/event/{EVENT['id']}"
    # The SPA shell is otherwise intact.
    assert '<div id="root"></div>' in body


def test_event_page_plain_shell_when_not_found_or_failing(bridge_dir, monkeypatch):
    monkeypatch.setattr(pages_mod.requests, "get", _fake_get([]))
    r = client.get(f"/bridge/event/{EVENT['id']}")
    assert r.status_code == 200 and "vibepass-jsonld" not in r.text and "<title>Exos | Live the Moment</title>" in r.text

    def boom(*a, **k):
        raise RuntimeError("db down")
    monkeypatch.setattr(pages_mod.requests, "get", boom)
    r = client.get(f"/bridge/event/{EVENT['id']}")
    assert r.status_code == 200 and "vibepass-jsonld" not in r.text

    monkeypatch.setattr(pages_mod.requests, "get", _fake_get([EVENT], status=500))
    r = client.get(f"/bridge/event/{EVENT['id']}")
    assert r.status_code == 200 and "vibepass-jsonld" not in r.text


def test_event_page_skips_lookup_for_non_uuid(bridge_dir, monkeypatch):
    calls = []
    monkeypatch.setattr(pages_mod.requests, "get", _fake_get([EVENT], calls=calls))
    r = client.get("/bridge/event/not-a-uuid")
    assert r.status_code == 200 and not calls and "vibepass-jsonld" not in r.text


def test_event_page_without_keys_serves_shell(bridge_dir, monkeypatch):
    calls = []
    monkeypatch.setattr(pages_mod.requests, "get", _fake_get([EVENT], calls=calls))
    monkeypatch.setattr(app_module, "SUPABASE_ANON_KEY", None)
    r = client.get(f"/bridge/event/{EVENT['id']}")
    assert r.status_code == 200 and not calls and "vibepass-jsonld" not in r.text


def test_sitemap_lists_events_with_lastmod(bridge_dir, monkeypatch):
    rows = [{"id": EVENT["id"], "updated_at": "2026-09-11T12:00:00+00:00", "starts_at": EVENT["starts_at"]},
            {"id": "22222222-2222-4333-8444-555555555555", "updated_at": None, "starts_at": "2026-12-01T00:00:00+00:00"}]
    monkeypatch.setattr(pages_mod.requests, "get", _fake_get(rows))
    r = client.get("/bridge/sitemap-events.xml", headers={"host": "bridge.example.com", "x-forwarded-proto": "https"})
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/xml")
    assert f"<loc>https://bridge.example.com/bridge/event/{EVENT['id']}</loc><lastmod>2026-09-11</lastmod>" in r.text
    assert "<lastmod>2026-12-01</lastmod>" in r.text
    assert r.text.count("<url>") == 2


def test_sitemap_empty_on_failure(bridge_dir, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("db down")
    monkeypatch.setattr(pages_mod.requests, "get", boom)
    r = client.get("/bridge/sitemap-events.xml")
    assert r.status_code == 200 and "<url>" not in r.text and "<urlset" in r.text


def test_other_bridge_routes_still_fall_through(bridge_dir, monkeypatch):
    calls = []
    monkeypatch.setattr(pages_mod.requests, "get", _fake_get([EVENT], calls=calls))
    r = client.get("/bridge/my-tickets")
    assert r.status_code == 200 and not calls and "<title>Exos | Live the Moment</title>" in r.text
    assert os.path.isfile(os.path.join(str(bridge_dir), "index.html"))
