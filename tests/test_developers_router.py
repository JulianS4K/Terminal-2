"""Tests for routers/developers.py — the /developers portal shell + the public
/api/mcp/catalog (tool list + per-feed freshness, cached in-process)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
testclient = pytest.importorskip("fastapi.testclient")

from fastapi import FastAPI  # noqa: E402

from routers import mcp_api  # noqa: E402
from routers.developers import build_developers_router  # noqa: E402

STATIC_DIR = os.path.join(str(REPO_ROOT), "static")


class _Rpc:
    def __init__(self, data=None, exc=None):
        self._data, self._exc = data, exc

    def execute(self):
        if self._exc:
            raise self._exc
        return type("R", (), {"data": self._data})()


class FakeDB:
    def __init__(self, data=None, exc=None):
        self.calls = []
        self.data, self.exc = data, exc

    def rpc(self, fn, params):
        self.calls.append((fn, params))
        return _Rpc(self.data, self.exc)


def _client(db, ttl=60.0):
    app = FastAPI()
    app.include_router(build_developers_router(STATIC_DIR, get_require_sb=lambda: (lambda: db), cache_ttl=ttl))
    return testclient.TestClient(app)


def test_page_shell():
    c = _client(FakeDB())
    r = c.get("/developers")
    assert r.status_code == 200 and 'data-page="developers"' in r.text
    assert r.headers["cache-control"].startswith("no-cache")
    assert c.head("/developers").status_code == 200
    d = c.get("/developers/docs.md")
    assert d.status_code == 200 and d.headers["content-type"].startswith("text/markdown")
    assert d.text.startswith("# S4K Market MCP") and "claude mcp add" in d.text
    assert c.head("/developers/docs.md").status_code == 200


def test_catalog_shape_and_cache():
    db = FakeDB(data={"generated_at": "2026-10-21T18:00:00Z", "feeds": [{"feed": "news", "age_minutes": 3}]})
    c = _client(db)
    cat = c.get("/api/mcp/catalog").json()
    assert cat["endpoint"] == "/mcp" and cat["transport"] == "streamable-http"
    assert cat["docs"] == "/developers/docs.md"
    assert cat["limits"] == {"rate_per_min": 60, "daily_quota": 2000, "max_rows_per_query": 500}
    assert {t["name"] for t in cat["tools"]} == {f.__name__ for f in mcp_api.EXTERNAL_TOOLS}
    assert "v_s4kcs_orders" not in cat["views"] and "events" in cat["views"]
    assert cat["freshness"]["feeds"][0]["feed"] == "news"
    assert db.calls == [("mcp_data_freshness", {})]
    c.get("/api/mcp/catalog")
    assert len(db.calls) == 1  # cached


def test_catalog_survives_db_outage():
    c = _client(FakeDB(exc=RuntimeError("down")))
    cat = c.get("/api/mcp/catalog").json()
    assert cat["freshness"]["feeds"] == [] and "unavailable" in cat["freshness"]["error"]
    assert cat["tools"]  # the static half still renders


def test_catalog_empty_freshness_defaults():
    c = _client(FakeDB(data=None))
    assert c.get("/api/mcp/catalog").json()["freshness"] == {"feeds": []}
