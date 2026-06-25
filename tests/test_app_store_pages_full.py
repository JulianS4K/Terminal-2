"""Coverage closure for the storefront static HTML page routes and the
`_attach_owned_metadata` early-return guards in app.py — the handful of lines
that fell between the per-slice agent boundaries. These are thin
`_render_storefront_page(...)` GET routes plus the root-scoped service worker;
no DB/network involved.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import app as app_module

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
