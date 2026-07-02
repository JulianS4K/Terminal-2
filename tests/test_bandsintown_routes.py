"""Tests for the /api/broker/bandsintown/tour route (routers/bandsintown.py, #693).

Covers the read-only endpoint that stitches the Bands in Town client to the
Instagram share-card generator: the 503-unconfigured path, the happy path
(artist + events + one share bundle per date), the 502-upstream-failure path,
and both branches of the server.py `_get_bandsintown_client` factory. No real
HTTP / DB.
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

pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient

# A realistic Bands in Town event (shape per /artists/:artist/events).
_EVENT = {
    "url": "https://www.bandsintown.com/e/123",
    "datetime": "2026-08-08T19:00:00",
    "lineup": ["The Body", "BIG|BRAVE"],
    "venue": {"name": "Music Hall of Williamsburg", "location": "Brooklyn, NY"},
}


@pytest.fixture
def client():
    return TestClient(app_module.app)


# ---------- route: /api/broker/bandsintown/tour ----------

def test_tour_503_when_unconfigured(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_bandsintown_client", lambda: None)
    r = client.get("/api/broker/bandsintown/tour", params={"artist": "Metallica"})
    assert r.status_code == 503


def test_tour_happy_path_returns_events_and_shares(client, monkeypatch):
    class _C:
        def get_artist(self, artist):
            return {"name": artist, "tracker_count": 10}

        def get_artist_events(self, artist, date=None):
            assert date == "all"  # query param flows through
            return [_EVENT]

    monkeypatch.setattr(app_module, "_get_bandsintown_client", lambda: _C())
    body = client.get(
        "/api/broker/bandsintown/tour", params={"artist": "The Body", "date": "all"}
    ).json()
    assert body["artist"]["name"] == "The Body"
    assert body["date_filter"] == "all"
    assert body["count"] == 1
    assert body["events"] == [_EVENT]
    # one share bundle per date, each carrying the SVG card
    assert len(body["shares"]) == 1
    assert body["shares"][0]["svg"].startswith("<svg")
    assert body["shares"][0]["url"] == "https://www.bandsintown.com/e/123"


def test_tour_default_date_is_upcoming(client, monkeypatch):
    seen = {}

    class _C:
        def get_artist(self, artist):
            return {}

        def get_artist_events(self, artist, date=None):
            seen["date"] = date
            return []

    monkeypatch.setattr(app_module, "_get_bandsintown_client", lambda: _C())
    body = client.get("/api/broker/bandsintown/tour", params={"artist": "X"}).json()
    assert seen["date"] == "upcoming"
    assert body["count"] == 0 and body["shares"] == []


def test_tour_502_on_upstream_error(client, monkeypatch):
    class _C:
        def get_artist(self, artist):
            raise RuntimeError("boom")

        def get_artist_events(self, artist, date=None):
            return []

    monkeypatch.setattr(app_module, "_get_bandsintown_client", lambda: _C())
    r = client.get("/api/broker/bandsintown/tour", params={"artist": "X"})
    assert r.status_code == 502


# ---------- server.py factory: _get_bandsintown_client ----------

def test_factory_returns_none_without_app_id(monkeypatch):
    monkeypatch.delenv("BANDSINTOWN_APP_ID", raising=False)
    monkeypatch.setattr(app_module, "require_sb", lambda: None)  # vault path → None
    assert app_module._get_bandsintown_client() is None


def test_factory_returns_client_from_env(monkeypatch):
    monkeypatch.setenv("BANDSINTOWN_APP_ID", "env-app")
    monkeypatch.setattr(app_module, "require_sb", lambda: None)
    c = app_module._get_bandsintown_client()
    assert c is not None and c.app_id == "env-app"
