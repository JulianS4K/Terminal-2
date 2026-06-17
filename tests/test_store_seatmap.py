"""Tests for the /api/store/seatmap/* same-origin proxy.

The interactive storefront seat map uses the Tevomaps bundle, which builds
every asset URL as `${mapsDomain}/${venueId}/${configurationId}/<file>` and
fetches BOTH `map.svg` and `manifest.json`. Pointing the bundle's mapsDomain at
this proxy (static/store/lib/seatmap.js) routes those fetches same-origin —
without it the cross-origin fetch to maps.ticketevolution.com is CORS-blocked,
SeatmapFactory.build() rejects, and the map falls back to the static image on
every event.

These tests stub app.requests.get so no real maps.ticketevolution.com call is
made, and assert the proxy passes the body/content-type/cache headers through
and maps upstream 404/5xx to the right status codes. Read-only (RULE 2): the
proxy only ever issues GETs to the public maps host.
"""
from __future__ import annotations

import os
import sys
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

fastapi = pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


class _FakeResp:
    def __init__(self, status_code=200, json_body=None, content=b"", is_json=True):
        self.status_code = status_code
        self._json = json_body
        self.content = content
        self._is_json = is_json

    @property
    def ok(self):
        return 200 <= self.status_code < 300

    def json(self):
        if not self._is_json:
            raise ValueError("not JSON")
        return self._json


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _stub_get(monkeypatch, resp, capture):
    def fake_get(url, *args, **kwargs):
        capture["url"] = url
        capture["headers"] = kwargs.get("headers")
        return resp
    monkeypatch.setattr(app_module.requests, "get", fake_get)


def test_manifest_proxy_passes_json_and_cache(client, monkeypatch):
    cap = {}
    _stub_get(monkeypatch, _FakeResp(200, json_body={"sections": {"100": {}}}), cap)
    r = client.get("/api/store/seatmap/896/14341/manifest.json")
    assert r.status_code == 200
    assert r.json() == {"sections": {"100": {}}}
    assert "max-age=86400" in r.headers.get("cache-control", "")
    # proxies the canonical CDN URL the bundle would otherwise fetch cross-origin
    assert cap["url"] == "https://maps.ticketevolution.com/896/14341/manifest.json"


def test_map_svg_proxy_passes_through(client, monkeypatch):
    cap = {}
    svg = b'<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>'
    _stub_get(monkeypatch, _FakeResp(200, content=svg, is_json=False), cap)
    r = client.get("/api/store/seatmap/896/14341/map.svg")
    assert r.status_code == 200
    assert r.content == svg
    assert r.headers["content-type"].startswith("image/svg+xml")
    assert "max-age=86400" in r.headers.get("cache-control", "")
    assert cap["url"] == "https://maps.ticketevolution.com/896/14341/map.svg"


def test_map_svg_carries_xss_hardening_headers(client, monkeypatch):
    # SVG is the only same-origin route returning image/svg+xml; opened directly
    # as a document it would execute embedded scripts. sandbox + nosniff
    # neutralize that on direct navigation (the inline-injection path is
    # unaffected — it reads .text(), not the response as a document).
    _stub_get(monkeypatch, _FakeResp(200, content=b"<svg/>", is_json=False), {})
    r = client.get("/api/store/seatmap/896/14341/map.svg")
    assert "sandbox" in r.headers.get("content-security-policy", "")
    assert r.headers.get("x-content-type-options") == "nosniff"


def test_upstream_404_maps_to_404(client, monkeypatch):
    _stub_get(monkeypatch, _FakeResp(404, is_json=False), {})
    assert client.get("/api/store/seatmap/1/2/map.svg").status_code == 404
    _stub_get(monkeypatch, _FakeResp(404, is_json=False), {})
    assert client.get("/api/store/seatmap/1/2/manifest.json").status_code == 404


def test_upstream_5xx_maps_to_502(client, monkeypatch):
    _stub_get(monkeypatch, _FakeResp(403, is_json=False), {})
    assert client.get("/api/store/seatmap/1/2/map.svg").status_code == 502


def test_request_exception_maps_to_502(client, monkeypatch):
    def boom(*a, **k):
        raise app_module.requests.RequestException("conn reset")
    monkeypatch.setattr(app_module.requests, "get", boom)
    assert client.get("/api/store/seatmap/1/2/manifest.json").status_code == 502


def test_non_int_ids_rejected(client, monkeypatch):
    # int-typed path params guarantee the upstream path can't be injected.
    _stub_get(monkeypatch, _FakeResp(200, content=b"x", is_json=False), {})
    assert client.get("/api/store/seatmap/abc/14341/map.svg").status_code == 422
