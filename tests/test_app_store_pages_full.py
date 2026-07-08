"""Coverage closure for the storefront static HTML page routes and the
`_attach_owned_metadata` early-return guards in app.py — the handful of lines
that fell between the per-slice agent boundaries. These are thin
`_render_storefront_page(...)` GET routes plus the root-scoped service worker;
no DB/network involved.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import server as app_module

client = TestClient(app_module.app)


@pytest.mark.parametrize("path", [
    "/store/chat",
    "/store",
    "/store/event/123",
    "/store/discover",
    "/store/tour",
    "/store/about",
    "/store/privacy",
    "/store/terms",
])
def test_storefront_pages_render(path):
    r = client.get(path)
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]


def test_store_service_worker_served_from_root():
    r = client.get("/store-sw.js")
    assert r.status_code == 200
    # Must advertise the broader-than-directory scope so it can claim '/store'.
    assert r.headers.get("Service-Worker-Allowed") == "/store"
    assert "javascript" in r.headers["content-type"].lower()


# ---- Ivory Editorial theme (default light theme + dark toggle) ----

@pytest.mark.parametrize("path", [
    "/store", "/store/event/123", "/store/discover", "/store/tour",
    "/store/chat", "/store/about", "/store/privacy", "/store/terms",
])
def test_storefront_pages_default_to_ivory_theme(path):
    """Every storefront page ships with the Ivory default applied pre-paint:
    a static data-theme="ivory" on <html>, the render-blocking theme.js, and a
    header toggle. theme.js must load before style.css to avoid a flash."""
    body = client.get(path).text
    assert 'data-theme="ivory"' in body
    assert "/static/store/theme.js" in body
    assert 'class="theme-toggle"' in body
    # Blocking theme.js must precede the stylesheet so the attribute resolves
    # before the first paint.
    assert body.index("theme.js") < body.index("style.css")


def test_theme_js_served_and_cache_busted():
    """theme.js is a real static asset, and the page reference is version-
    stamped so a deploy never serves a stale copy (same treatment as store.js)."""
    r = client.get("/static/store/theme.js")
    assert r.status_code == 200
    assert "javascript" in r.headers["content-type"].lower()
    assert "vp-theme" in r.text  # the localStorage key — proves it's our file
    # The page reference carries the ?v= cache-bust.
    assert "/static/store/theme.js?v=" in client.get("/store").text


# ---- Branded storefront error page (site-level 404 / 5xx) ----

def test_unknown_storefront_route_renders_branded_404_html():
    """An unknown /store/* path on an HTML navigation returns the branded
    error shell (404 status, HTML body) instead of the default JSON."""
    r = client.get("/store/does-not-exist", headers={"accept": "text/html"})
    assert r.status_code == 404
    assert "text/html" in r.headers["content-type"]
    body = r.text
    assert "404" in body
    assert "wrong turn" in body
    # Tokens must be filled, never leaked to the client.
    assert "{{ERR_" not in body


def test_unknown_api_route_stays_json_404():
    """The /api/* JSON surface must keep returning JSON 404s — store.js parses
    those status codes (describeFetchError); it must never get HTML."""
    r = client.get("/api/store/does-not-exist", headers={"accept": "text/html"})
    assert r.status_code == 404
    assert "application/json" in r.headers["content-type"]
    assert "{{ERR_" not in r.text


def test_unknown_storefront_route_non_html_client_stays_json():
    """A non-HTML client hitting an unknown /store path gets the default JSON
    404, not the branded page (the branded shell is for browser navigations)."""
    r = client.get("/store/does-not-exist", headers={"accept": "application/json"})
    assert r.status_code == 404
    assert "application/json" in r.headers["content-type"]


# ---- _attach_owned_metadata early returns (app.py 4120, 4147) ----

def test_attach_owned_metadata_empty_candidates_returns_empty():
    # candidate_ids empty -> short-circuit (line 4120); db is never touched.
    assert app_module._attach_owned_metadata(None, [], 0.0, 0.0) == []


class _Result:
    def __init__(self, data):
        self.data = data


class _Query:
    def __init__(self, data):
        self._data = data
    def select(self, *a, **k): return self
    def gt(self, *a, **k): return self
    def in_(self, *a, **k): return self
    def execute(self): return _Result(self._data)


class _FakeDB:
    def __init__(self, by_table):
        self._by_table = by_table
    def table(self, name):
        return _Query(self._by_table.get(name, []))


def test_attach_owned_metadata_no_joined_rows_returns_empty():
    """metrics rows exist but no matching events row -> merged rows empty (4147)."""
    db = _FakeDB({
        "latest_event_metrics": [{"event_id": 1, "owned_tickets_count": 2, "retail_min": 10}],
        "events": [],  # no join target -> events_by_id empty -> rows == []
    })
    assert app_module._attach_owned_metadata(db, [1], 40.0, -73.0) == []
