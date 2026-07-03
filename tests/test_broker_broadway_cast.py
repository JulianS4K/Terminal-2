"""Tests for the Broadway cast get-in broker route.

Covers routers/broker.py:
  - /api/broker/event/{id}/broadway-cast

Venue-anchored resolution, the full-roster merge (priced + 'awaiting coverage'
ghosts), the not-a-Broadway-event / no-event empties, the name-guard continue,
and the exception degrade path. Same fake-env-before-import + TestClient pattern
as tests/test_broker_prediction_markets.py; reuses its FakeSupabase.
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

from tests.test_broker_routes import FakeSupabase  # reuse the fluent fake

TestClient = starlette_testclient.TestClient


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _use_db(monkeypatch, fake):
    monkeypatch.setattr(app_module, "require_sb", lambda: fake)


# Non-matching refs come BEFORE the match so both `continue` branches
# (empty pattern, and pattern-not-in-venue) are exercised before the break.
_REFS = [
    {"show_slug": "wicked", "title": "Wicked",
     "venue_name_pattern": "%Gershwin%", "event_name_pattern": None},   # vp not in venue -> continue
    {"show_slug": "junk", "title": "Junk",
     "venue_name_pattern": "", "event_name_pattern": None},             # not vp -> continue
    {"show_slug": "oh-mary", "title": "Oh, Mary!",
     "venue_name_pattern": "%Lyceum%", "event_name_pattern": None},     # match -> break
]


def test_broadway_cast_applicable_with_priced_and_ghost(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "events": [{"id": 1, "name": "Oh Mary", "venue_name": "Lyceum Theatre - New York"}],
        "broadway_show_ref": _REFS,
        "broadway_cast_run": [
            {"performer_name": "Cole Escola", "role": "Mary Todd Lincoln", "engagement_seq": 1,
             "run_start": "2024-07-11", "run_end": "2025-06-21", "is_final_confirmed": True,
             "confidence": 0.9, "source_name": "Variety"},
            {"performer_name": "Maya Rudolph", "role": "Mary Todd Lincoln", "engagement_seq": 1,
             "run_start": "2026-04-28", "run_end": "2026-07-05", "is_final_confirmed": True,
             "confidence": 0.95, "source_name": "Broadway.com"},
        ],
        "v_broadway_performer_getin": [
            {"performer_name": "Maya Rudolph", "engagement_seq": 1, "show_slug": "oh-mary",
             "avg_getin": 133.26, "median_getin": 133.0, "min_getin": 133.0, "max_getin": 136.3,
             "closing_night_getin": None, "perfs_priced": 1, "snapshot_rows": 38},
        ],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/broadway-cast").json()
    assert body["applicable"] is True
    assert body["kind"] == "broadway" and body["metric"] == "get_in_usd"
    assert body["subject"] == {"slug": "oh-mary", "title": "Oh, Mary!"}
    assert len(body["participants"]) == 2
    by_name = {p["name"]: p for p in body["participants"]}
    assert by_name["Maya Rudolph"]["measured"] is True
    assert by_name["Maya Rudolph"]["avg_getin"] == 133.26
    assert by_name["Maya Rudolph"]["snapshot_rows"] == 38
    assert by_name["Cole Escola"]["measured"] is False
    assert by_name["Cole Escola"]["avg_getin"] is None


def test_broadway_cast_name_guard_forces_continue_to_empty(client, monkeypatch):
    # Venue matches Barrymore but the event_name guard fails -> continue -> no
    # match -> empty (covers the `ep and ep not in name` branch + `not slug`).
    fake = FakeSupabase(table_data={
        "events": [{"id": 2, "name": "Elling", "venue_name": "Barrymore Theatre - NY"}],
        "broadway_show_ref": [
            {"show_slug": "joe-turner", "title": "Joe Turner's Come and Gone",
             "venue_name_pattern": "%Barrymore%", "event_name_pattern": "%joe turner%"},
        ],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/2/broadway-cast").json()
    assert body["applicable"] is False
    assert body["participants"] == [] and body["subject"] is None


def test_broadway_cast_not_a_broadway_venue(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "events": [{"id": 3, "name": "Some Concert", "venue_name": "Madison Square Garden"}],
        "broadway_show_ref": [
            {"show_slug": "oh-mary", "title": "Oh, Mary!",
             "venue_name_pattern": "%Lyceum%", "event_name_pattern": None},
        ],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/3/broadway-cast").json()
    assert body == {"event_id": 3, "applicable": False, "kind": "broadway",
                    "metric": "get_in_usd", "subject": None, "participants": []}


def test_broadway_cast_no_event_row(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"events": []}))
    body = client.get("/api/broker/event/999/broadway-cast").json()
    assert body["applicable"] is False and body["participants"] == []


def test_broadway_cast_error_degrades(client, monkeypatch):
    class _Boom(FakeSupabase):
        def table(self, name):
            raise RuntimeError("relation broadway_show_ref does not exist")

    _use_db(monkeypatch, _Boom())
    body = client.get("/api/broker/event/5/broadway-cast").json()
    assert body["event_id"] == 5 and body["applicable"] is False
    assert "does not exist" in body["error"]


# ---------- /api/broker/performer/{id}/broadway-cast (show-as-performer) ----------

def test_performer_broadway_cast_applicable(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "broadway_show_ref": [{"show_slug": "oh-mary", "title": "Oh, Mary!"}],
        "broadway_cast_run": [
            {"performer_name": "Maya Rudolph", "role": "Mary Todd Lincoln", "engagement_seq": 1,
             "run_start": "2026-04-28", "run_end": "2026-07-05", "is_final_confirmed": True,
             "confidence": 0.95, "source_name": "Broadway.com"},
        ],
        "v_broadway_performer_getin": [
            {"performer_name": "Maya Rudolph", "engagement_seq": 1, "show_slug": "oh-mary",
             "avg_getin": 133.26, "median_getin": 133.0, "min_getin": 133.0, "max_getin": 136.3,
             "closing_night_getin": None, "perfs_priced": 1, "snapshot_rows": 38},
        ],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/performer/103169/broadway-cast").json()
    assert body["applicable"] is True
    assert body["subject"] == {"slug": "oh-mary", "title": "Oh, Mary!"}
    assert body["participants"][0]["name"] == "Maya Rudolph"
    assert body["participants"][0]["measured"] is True


def test_performer_broadway_cast_not_a_broadway_performer(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"broadway_show_ref": []}))
    body = client.get("/api/broker/performer/5/broadway-cast").json()
    assert body["applicable"] is False and body["participants"] == []


def test_performer_broadway_cast_error_degrades(client, monkeypatch):
    class _Boom(FakeSupabase):
        def table(self, name):
            raise RuntimeError("relation broadway_show_ref does not exist")

    _use_db(monkeypatch, _Boom())
    body = client.get("/api/broker/performer/9/broadway-cast").json()
    assert body["performer_id"] == 9 and body["applicable"] is False
    assert "does not exist" in body["error"]
