"""Tests for the public, non-DB infra routes in app.py.

Covers a previously-untested surface (BR-CODE-3, bottleneck research
2026-06-19): /version.json, /healthz, /api/public/config, /robots.txt,
/sitemap.xml, /favicon.ico. These routes return only boot/config facts or
static content — no upstream HTTP, no data mutation — so they are the
lowest-risk slice to lock behind a test before the larger app.py refactor
(BR-CODE-1) begins.

Pattern mirrors tests/test_store_events.py: set fake env BEFORE importing
app (app.py resolves creds + sys.exit()'s at import without them), then
drive app.app via Starlette's TestClient. No real HTTP is made.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")  # don't gate routes in tests

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

# Skip the module if the fastapi/starlette test stack isn't installed
# (keeps the bare-Python readonly-guards env green).
pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


@pytest.fixture
def client():
    return TestClient(app_module.app)


# ---------- /version.json ----------

def test_version_json_shape(client):
    r = client.get("/version.json")
    assert r.status_code == 200
    body = r.json()
    # Always present; equals the module's resolved storefront version.
    assert body["version"] == app_module._STOREFRONT_VERSION
    # Deploy-indicator keys are always present (null when env unset).
    for key in (
        "render_commit", "railway_commit", "git_commit",
        "render_service_id", "render_external_url",
        "railway_public_domain", "deployed_at_iso",
    ):
        assert key in body


def test_version_json_reads_render_commit_env(client, monkeypatch):
    monkeypatch.setenv("RENDER_GIT_COMMIT", "deadbeef123")
    r = client.get("/version.json")
    assert r.json()["render_commit"] == "deadbeef123"


# ---------- /healthz ----------

def test_healthz_smoke_skips_when_sb_none(client, monkeypatch):
    # When the supabase client never initialized, the smoke step is skipped
    # and the endpoint still reports ok=True (boot facts only).
    monkeypatch.setattr(app_module, "sb", None)
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["supabase_smoke"].startswith("skipped")
    assert body["supabase_client_initialized"] is False
    # Privacy invariant: never leak key *lengths*, only set/unset booleans.
    assert isinstance(body["supabase_url_set"], bool)
    assert "supabase_service_role_key_len" not in body


def test_healthz_smoke_pass_with_stubbed_sb(client, monkeypatch):
    class _FakeResult:
        data = [{"id": 1}]

    class _FakeChain:
        def select(self, *_a, **_k):
            return self

        def limit(self, *_a, **_k):
            return self

        def execute(self):
            return _FakeResult()

    class _FakeSb:
        def table(self, *_a, **_k):
            return _FakeChain()

    monkeypatch.setattr(app_module, "sb", _FakeSb())
    body = client.get("/healthz").json()
    assert body["ok"] is True
    assert body["supabase_smoke"] == "pass"
    assert body["supabase_smoke_rows"] == 1


def test_healthz_smoke_fail_is_truncated_and_flips_ok(client, monkeypatch):
    long_err = "x" * 1000

    class _BoomSb:
        def table(self, *_a, **_k):
            raise RuntimeError(long_err)

    monkeypatch.setattr(app_module, "sb", _BoomSb())
    body = client.get("/healthz").json()
    assert body["ok"] is False
    assert body["supabase_smoke"] == "fail"
    # Truncated to <=300 chars so a public endpoint can't leak full traces.
    assert len(body["supabase_smoke_error"]) <= 300


# ---------- /api/public/config ----------

def test_public_config_exposes_no_secret_keys(client):
    body = client.get("/api/public/config").json()
    # Browser-safe surface: anon key + url are intentional; service-role and
    # cron secrets must never appear here.
    assert body["supabase_anon_key"] == app_module.SUPABASE_ANON_KEY
    assert "supabase_service_role_key" not in body
    assert "service_role" not in body
    assert "cron_secret" not in body


def test_public_config_checkout_forced_off(client, monkeypatch):
    # Kill switch ON => no checkout domain advertised and purchase disabled,
    # regardless of STOREFRONT_CHECKOUT_DOMAIN.
    monkeypatch.setattr(app_module, "STOREFRONT_CHECKOUT_DISABLED", True)
    monkeypatch.setattr(app_module, "STOREFRONT_CHECKOUT_DOMAIN", "checkout.example.com")
    body = client.get("/api/public/config").json()
    assert body["checkout_domain"] is None
    assert body["purchase_enabled"] is False


# ---------- /robots.txt + /sitemap.xml + /favicon.ico ----------

def test_robots_txt_denies_api(client):
    r = client.get("/robots.txt")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    assert "/api/" in r.text  # /api/ is disallowed for crawlers


def test_sitemap_lists_store_entry_points(client):
    r = client.get("/sitemap.xml")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/xml")
    assert "<urlset" in r.text
    for path in ("/store", "/store/about", "/store/privacy", "/store/terms"):
        assert path in r.text


def test_favicon_redirects_to_svg(client):
    r = client.get("/favicon.ico", follow_redirects=False)
    assert r.status_code == 308
    assert r.headers["location"].endswith("/static/store/favicon.svg")
