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

import server as app_module  # noqa: E402

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


# ---------- section-map crosswalk bridge (venue_section_map) ----------

class _FakeTable:
    """Minimal supabase-py fluent stub: .table().select().eq()*.execute().data,
    keyed by (configuration_id, platform) so config-fallback can be exercised."""
    def __init__(self, data_by_cfg_plat, calls):
        self._data = data_by_cfg_plat
        self._calls = calls
        self._eq = {}

    def select(self, *a, **k):
        return self

    def eq(self, col, val):
        self._eq[col] = val
        return self

    def execute(self):
        cfg = self._eq.get("configuration_id")
        plat = self._eq.get("platform")
        self._calls.append((cfg, plat))
        rows = self._data.get((cfg, plat), [])
        return type("R", (), {"data": rows})()


class _FakeSB:
    def __init__(self, data_by_cfg_plat):
        self.data = data_by_cfg_plat
        self.calls = []

    def table(self, name):
        assert name == "venue_section_map"
        return _FakeTable(self.data, self.calls)


def test_section_map_returns_crosswalk(client, monkeypatch):
    sb = _FakeSB({(53, "evo"): [
        {"section_raw": "Field Box 112A", "seatmap_key": "field box 112"},
        {"section_raw": "Grandstand 405", "seatmap_key": "grandstand 405"},
        {"section_raw": "  ", "seatmap_key": "x"},          # blank raw — dropped
        {"section_raw": "Bleacher 1", "seatmap_key": None},  # null key — dropped
    ]})
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/seatmap/896/53/section-map")
    assert r.status_code == 200
    body = r.json()
    assert body["config_used"] == 53
    assert body["count"] == 2
    assert body["sections"]["Field Box 112A"] == "field box 112"
    assert "Bleacher 1" not in body["sections"]


def test_section_map_falls_back_to_union_bucket(client, monkeypatch):
    # No rows for the event's config → retry configuration_id = 0 (union bucket).
    sb = _FakeSB({(0, "evo"): [{"section_raw": "GA", "seatmap_key": "ga floor"}]})
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/seatmap/896/9999/section-map")
    body = r.json()
    assert body["config_used"] == 0
    assert body["sections"] == {"GA": "ga floor"}
    assert sb.calls == [(9999, "evo"), (0, "evo")]  # primary then fallback


def test_section_map_no_double_fallback_when_config_is_zero(client, monkeypatch):
    sb = _FakeSB({})  # nothing anywhere
    monkeypatch.setattr(app_module, "sb", sb)
    r = client.get("/api/store/seatmap/896/0/section-map")
    assert r.json() == {"sections": {}, "config_used": 0, "count": 0}
    assert sb.calls == [(0, "evo")]  # config 0 → no second query


def test_section_map_unsupported_platform_rejected(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", _FakeSB({}))
    assert client.get("/api/store/seatmap/896/53/section-map?platform=tp").status_code == 400


def test_section_map_degrades_when_sb_missing(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    r = client.get("/api/store/seatmap/896/53/section-map")
    assert r.status_code == 200
    assert r.json()["count"] == 0
