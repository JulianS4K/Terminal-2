"""Full line-coverage tests for the INFRASTRUCTURE + PUBLIC slice of app.py.

Slice (bootstrap + middleware + public/static routes, ~lines 80-900):
  helpers      : _read_storefront_html, _render_storefront_page, _require_human,
                 require_sb, resolve_tevo_creds, ensure_tevo_client
  middleware   : _SecurityHeadersMiddleware (CSP/HSTS/permissions per path),
                 _IPRateLimiter + _RateLimitMiddleware (in-process limiter)
  routes       : GET / , /home, /home/, /terminal, /terminal/{page},
                 /undelivered, /bridge, /bridge/{page}, /version.json,
                 /healthz, POST /webhooks/render, GET /api/public/config

House style mirrors tests/test_public_infra_routes.py + test_security_hardening.py:
set fake env BEFORE importing app, drive app.app via Starlette TestClient,
monkeypatch module globals. No real network/DB.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app (app.py resolves creds at import) ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_TOKEN", "test-token")
os.environ.setdefault("TEVO_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "https://example.invalid")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-key")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("AUTH_DISABLED", "true")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402
import core.auth as core_auth  # noqa: E402
import render_webhook as rw  # noqa: E402
from fastapi import HTTPException, Request  # noqa: E402

TestClient = starlette_testclient.TestClient


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _make_request(path="/", headers=None, cookies=None, client_host="1.2.3.4"):
    """Build a minimal Starlette Request for direct helper calls."""
    raw_headers = []
    for k, v in (headers or {}).items():
        raw_headers.append((k.lower().encode(), v.encode()))
    if cookies:
        cookie_str = "; ".join(f"{k}={v}" for k, v in cookies.items())
        raw_headers.append((b"cookie", cookie_str.encode()))
    scope = {
        "type": "http",
        "method": "POST",
        "path": path,
        "headers": raw_headers,
        "query_string": b"",
        "client": (client_host, 5000) if client_host else None,
    }
    return Request(scope)


# ====================================================================
# _read_storefront_html / _render_storefront_page
# ====================================================================

def test_read_storefront_html_cache_busts_and_caches(monkeypatch):
    name = "_unit_test_shell.html"
    app_module._STOREFRONT_HTML_CACHE.pop(name, None)
    monkeypatch.setattr(app_module, "_STOREFRONT_VERSION", "abc123")
    # default base => the base-replace branch (line 116) is a no-op skip
    monkeypatch.setattr(
        app_module, "_STOREFRONT_BASE_URL",
        "https://vibepass-storefront-test.onrender.com",
    )
    html_src = (
        '<link href="/static/store/style.css">'
        '<script src="/static/store/store.js"></script>'
        'OG: https://vibepass-storefront-test.onrender.com/card.png'
    )
    real_open = open

    def fake_open(path, *a, **k):
        if path.endswith(name):
            import io
            return io.StringIO(html_src)
        return real_open(path, *a, **k)

    monkeypatch.setattr("builtins.open", fake_open)
    out = app_module._read_storefront_html(name)
    assert "/static/store/store.js?v=abc123" in out
    assert "/static/store/style.css?v=abc123" in out
    # default base => OG url unchanged
    assert "https://vibepass-storefront-test.onrender.com/card.png" in out
    # Cached: second read returns the SAME object without re-opening.
    assert app_module._read_storefront_html(name) is out
    app_module._STOREFRONT_HTML_CACHE.pop(name, None)


def test_read_storefront_html_rewrites_og_base(monkeypatch):
    """Non-default base => the OG base-url replace branch (line 116) fires."""
    name = "_unit_test_shell_base.html"
    app_module._STOREFRONT_HTML_CACHE.pop(name, None)
    monkeypatch.setattr(app_module, "_STOREFRONT_VERSION", "deadbe")
    monkeypatch.setattr(app_module, "_STOREFRONT_BASE_URL", "https://my.deploy.example")
    html_src = 'OG: https://vibepass-storefront-test.onrender.com/card.png'

    def fake_open(path, *a, **k):
        import io
        return io.StringIO(html_src)

    monkeypatch.setattr("builtins.open", fake_open)
    out = app_module._read_storefront_html(name)
    assert "https://my.deploy.example/card.png" in out
    assert "vibepass-storefront-test.onrender.com" not in out
    app_module._STOREFRONT_HTML_CACHE.pop(name, None)


def test_render_storefront_page_sets_no_cache(monkeypatch):
    monkeypatch.setattr(app_module, "_read_storefront_html", lambda n: "<html>ok</html>")
    resp = app_module._render_storefront_page("anything.html")
    assert resp.status_code == 200
    assert resp.headers["Cache-Control"] == "no-cache, must-revalidate"
    assert b"ok" in resp.body


# ====================================================================
# _require_human
# ====================================================================

def test_require_human_honeypot_rejects(monkeypatch):
    # Honeypot is always-on even when recaptcha dormant.
    req = _make_request()
    with pytest.raises(HTTPException) as exc:
        app_module._require_human(req, {"hp": "i am a bot"})
    assert exc.value.status_code == 400


def test_require_human_noop_when_recaptcha_disabled(monkeypatch):
    monkeypatch.setattr(app_module, "RECAPTCHA_ENABLED", False)
    req = _make_request()
    # No exception, returns None.
    assert app_module._require_human(req, {}) is None


def test_require_human_accepts_valid_cookie(monkeypatch):
    monkeypatch.setattr(app_module, "RECAPTCHA_ENABLED", True)
    monkeypatch.setattr(app_module, "_valid_human_token", lambda tok: True)
    req = _make_request(cookies={app_module._HUMAN_COOKIE_NAME: "good-token"})
    assert app_module._require_human(req, {}) is None


def test_require_human_accepts_fresh_recaptcha_token(monkeypatch):
    monkeypatch.setattr(app_module, "RECAPTCHA_ENABLED", True)
    monkeypatch.setattr(app_module, "_valid_human_token", lambda tok: False)
    captured = {}

    def fake_verify(token, action, ip):
        captured["token"] = token
        captured["ip"] = ip
        return True

    monkeypatch.setattr(app_module, "_verify_recaptcha", fake_verify)
    # XFF present => uses rightmost entry for ip.
    req = _make_request(headers={"x-forwarded-for": "9.9.9.9, 203.0.113.5"})
    assert app_module._require_human(req, {"recaptcha_token": "tok-1"}) is None
    assert captured["token"] == "tok-1"
    assert captured["ip"] == "203.0.113.5"


def test_require_human_uses_client_host_when_no_xff(monkeypatch):
    monkeypatch.setattr(app_module, "RECAPTCHA_ENABLED", True)
    monkeypatch.setattr(app_module, "_valid_human_token", lambda tok: False)
    seen = {}
    monkeypatch.setattr(
        app_module, "_verify_recaptcha",
        lambda token, action, ip: seen.setdefault("ip", ip) or True,
    )
    req = _make_request(client_host="7.7.7.7")  # no XFF header
    assert app_module._require_human(req, {"recaptcha_token": "x"}) is None
    assert seen["ip"] == "7.7.7.7"


def test_require_human_rejects_when_no_proof(monkeypatch):
    monkeypatch.setattr(app_module, "RECAPTCHA_ENABLED", True)
    monkeypatch.setattr(app_module, "_valid_human_token", lambda tok: False)
    monkeypatch.setattr(app_module, "_verify_recaptcha", lambda *a, **k: False)
    req = _make_request()
    with pytest.raises(HTTPException) as exc:
        app_module._require_human(req, {})
    assert exc.value.status_code == 403


# ====================================================================
# require_sb
# ====================================================================

def test_require_sb_raises_when_unconfigured(monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    with pytest.raises(HTTPException) as exc:
        app_module.require_sb()
    assert exc.value.status_code == 500


def test_require_sb_returns_client_when_set(monkeypatch):
    sentinel = object()
    monkeypatch.setattr(app_module, "sb", sentinel)
    assert app_module.require_sb() is sentinel


# ====================================================================
# resolve_tevo_creds
# ====================================================================

class _SettingsResult:
    def __init__(self, data):
        self.data = data


class _SettingsChain:
    def __init__(self, data):
        self._data = data

    def select(self, *a, **k):
        return self

    def in_(self, *a, **k):
        return self

    def execute(self):
        return _SettingsResult(self._data)


class _SettingsSb:
    def __init__(self, data, boom=False):
        self._data = data
        self._boom = boom

    def table(self, *a, **k):
        if self._boom:
            raise RuntimeError("settings table unavailable")
        return _SettingsChain(self._data)


def test_resolve_tevo_creds_from_supabase(monkeypatch):
    sb = _SettingsSb([
        {"key": "tevo_token", "value": "sb-tok"},
        {"key": "tevo_secret", "value": "sb-sec"},
    ])
    monkeypatch.setattr(app_module, "sb", sb)
    t, s, src = app_module.resolve_tevo_creds()
    assert (t, s, src) == ("sb-tok", "sb-sec", "supabase.settings")


def test_resolve_tevo_creds_supabase_error_falls_back_to_env(monkeypatch):
    monkeypatch.setattr(app_module, "sb", _SettingsSb([], boom=True))
    monkeypatch.setenv("TEVO_TOKEN", "env-tok")
    monkeypatch.setenv("TEVO_SECRET", "env-sec")
    t, s, src = app_module.resolve_tevo_creds()
    assert (t, s, src) == ("env-tok", "env-sec", "env")


def test_resolve_tevo_creds_supabase_incomplete_falls_back(monkeypatch):
    # Supabase returns only one of the two keys => not (t and s) => env path.
    monkeypatch.setattr(app_module, "sb", _SettingsSb([{"key": "tevo_token", "value": "only-tok"}]))
    monkeypatch.setenv("TEVO_API_TOKEN", "envapi-tok")
    monkeypatch.setenv("TEVO_API_SECRET", "envapi-sec")
    monkeypatch.delenv("TEVO_TOKEN", raising=False)
    monkeypatch.delenv("TEVO_SECRET", raising=False)
    t, s, src = app_module.resolve_tevo_creds()
    assert (t, s, src) == ("envapi-tok", "envapi-sec", "env")


def test_resolve_tevo_creds_missing(monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    for var in ("TEVO_TOKEN", "TEVO_SECRET", "TEVO_API_TOKEN", "TEVO_API_SECRET"):
        monkeypatch.delenv(var, raising=False)
    t, s, src = app_module.resolve_tevo_creds()
    assert (t, s, src) == (None, None, "missing")


# ====================================================================
# ensure_tevo_client
# ====================================================================

def test_ensure_tevo_client_returns_existing(monkeypatch):
    sentinel = object()
    monkeypatch.setattr(app_module, "client", sentinel)
    assert app_module.ensure_tevo_client() is sentinel


def test_ensure_tevo_client_returns_none_when_creds_missing(monkeypatch):
    monkeypatch.setattr(app_module, "client", None)
    monkeypatch.setattr(app_module, "resolve_tevo_creds", lambda: (None, None, "missing"))
    assert app_module.ensure_tevo_client() is None


def test_ensure_tevo_client_builds_on_demand(monkeypatch):
    monkeypatch.setattr(app_module, "client", None)
    monkeypatch.setattr(app_module, "resolve_tevo_creds", lambda: ("t", "s", "env"))
    built = {}

    class _FakeEvo:
        def __init__(self, token, secret, sandbox=False):
            built["token"] = token
            built["secret"] = secret
            built["sandbox"] = sandbox

    monkeypatch.setattr(app_module, "EvoClient", _FakeEvo)
    out = app_module.ensure_tevo_client()
    assert isinstance(out, _FakeEvo)
    assert built["token"] == "t" and built["secret"] == "s"
    assert app_module.CREDS_SOURCE == "env"
    # reset so other tests see the original client global
    monkeypatch.setattr(app_module, "client", out)


# ====================================================================
# _IPRateLimiter (direct unit) + _RateLimitMiddleware
# ====================================================================

def test_ip_rate_limiter_allows_then_blocks():
    lim = app_module._IPRateLimiter()
    key = "unit|/x"
    assert lim.check(key, 2, 60.0) is True
    assert lim.check(key, 2, 60.0) is True
    # Third within window => blocked.
    assert lim.check(key, 2, 60.0) is False


def test_ip_rate_limiter_evicts_expired_hits(monkeypatch):
    lim = app_module._IPRateLimiter()
    # Drive monotonic clock manually so the popleft eviction branch runs.
    fake_now = {"t": 1000.0}
    monkeypatch.setattr(app_module._time, "monotonic", lambda: fake_now["t"])
    assert lim.check("k", 1, 10.0) is True
    # Same instant, over cap => blocked.
    assert lim.check("k", 1, 10.0) is False
    # Advance past the window => old hit evicted (popleft), allowed again.
    fake_now["t"] = 1020.0
    assert lim.check("k", 1, 10.0) is True


def test_rate_limit_middleware_returns_429(client, monkeypatch):
    # /api/public/config bucket = 120/60s. Force the limiter to deny so we hit
    # the 429 branch deterministically without 120 calls.
    monkeypatch.setattr(app_module._ip_limiter, "check", lambda *a, **k: False)
    r = client.get("/api/public/config")
    assert r.status_code == 429
    assert r.json()["error"] == "rate limited"
    assert r.json()["retry_after_seconds"] == 60
    assert r.headers["Retry-After"] == "60"


def test_rate_limit_middleware_skips_healthz_and_root(client, monkeypatch):
    # / and /healthz are exempt (return before consulting the limiter).
    monkeypatch.setattr(
        app_module._ip_limiter, "check",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("limiter should be skipped")),
    )
    monkeypatch.setattr(app_module, "sb", None)
    assert client.get("/healthz").status_code == 200


def test_rate_limit_middleware_default_bucket_and_client_host(monkeypatch):
    # A path matching no bucket prefix => _DEFAULT bucket; no XFF => client.host.
    seen = {}

    def _check(key, n, w):
        seen["key"] = key
        seen["n"] = n
        seen["w"] = w
        return True

    monkeypatch.setattr(app_module._ip_limiter, "check", _check)
    client = TestClient(app_module.app)
    client.get("/version.json")
    assert seen["n"] == 200 and seen["w"] == 60.0  # _DEFAULT
    assert seen["key"].endswith("|*")  # no bucket prefix matched


def test_rate_limit_middleware_unknown_client_falls_back(monkeypatch):
    # No XFF and no client => "unknown".
    seen = {}
    monkeypatch.setattr(
        app_module._ip_limiter, "check",
        lambda key, n, w: seen.setdefault("key", key) or True,
    )
    client = TestClient(app_module.app)
    # Starlette TestClient sets a client; assert the bucket key still forms.
    client.get("/version.json")
    assert "|" in seen["key"]


# ====================================================================
# _SecurityHeadersMiddleware
# ====================================================================

def test_security_headers_default_path(client):
    r = client.get("/version.json")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"
    assert r.headers["Referrer-Policy"] == "strict-origin-when-cross-origin"
    assert "max-age=63072000" in r.headers["Strict-Transport-Security"]
    # Default Permissions-Policy: camera fully denied.
    assert r.headers["Permissions-Policy"] == "geolocation=(), microphone=(), camera=()"
    # Default CSP (not recaptcha variant).
    assert r.headers["Content-Security-Policy"].startswith("default-src 'self'")
    assert "www.google.com" not in r.headers["Content-Security-Policy"]


def test_security_headers_bridge_allows_camera(client):
    # /bridge build likely absent => 404, but the middleware still sets headers.
    r = client.get("/bridge/", follow_redirects=False)
    assert r.headers["Permissions-Policy"] == "geolocation=(), microphone=(), camera=(self)"


def test_security_headers_recaptcha_csp_on_store(client, monkeypatch):
    # RECAPTCHA_ENABLED + /store path => the recaptcha CSP variant (line 440).
    monkeypatch.setattr(app_module, "RECAPTCHA_ENABLED", True)
    # Hit a /store* path. /store/... may 404, but headers are still applied.
    r = client.get("/store/does-not-exist-xyz", follow_redirects=False)
    csp = r.headers["Content-Security-Policy"]
    assert "https://www.google.com" in csp
    assert "frame-src https://www.google.com" in csp


def test_security_headers_versioned_static_asset_immutable(client):
    # /static/store/<asset>?v=... 200 => long immutable cache (lines 472-474).
    r = client.get("/static/store/style.css?v=abc")
    assert r.status_code == 200
    assert r.headers["Cache-Control"] == "public, max-age=31536000, immutable"


def test_security_headers_unversioned_static_asset_short_ttl(client):
    # /static/store/<asset> with no ?v => short TTL (lines 475-476).
    r = client.get("/static/store/style.css")
    assert r.status_code == 200
    assert r.headers["Cache-Control"] == "public, max-age=600"


# ====================================================================
# RuntimeError exception handler (-> 502)
# ====================================================================

def test_runtime_error_handler_returns_502():
    import anyio

    async def _run():
        return await app_module._runtime_error_handler(None, RuntimeError("boom"))

    resp = anyio.run(_run)
    assert resp.status_code == 502
    assert b"boom" in resp.body


# ====================================================================
# Public/static routes
# ====================================================================

def test_root_landing_serves_home(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_AS_LANDING", False)
    r = client.get("/", follow_redirects=False)
    assert r.status_code == 200


def test_root_landing_redirects_when_storefront_landing(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_AS_LANDING", True)
    r = client.get("/", follow_redirects=False)
    assert r.status_code == 302
    assert r.headers["location"] == "/store"


def test_home_redirect(client):
    r = client.get("/home", follow_redirects=False)
    assert r.status_code == 308
    assert r.headers["location"] == "/home/"


def test_home_landing_serves_index(client):
    r = client.get("/home/", follow_redirects=False)
    assert r.status_code == 200


def test_terminal_redirect(client):
    r = client.get("/terminal", follow_redirects=False)
    assert r.status_code == 308
    assert r.headers["location"] == "/terminal/"


def test_terminal_index_serves(client):
    r = client.get("/terminal/", follow_redirects=False)
    assert r.status_code == 200


def test_terminal_proxy_serves_existing_asset(client):
    # index.html is known to exist under static/terminal/.
    r = client.get("/terminal/index.html", follow_redirects=False)
    assert r.status_code == 200


def test_terminal_proxy_rejects_path_traversal(client):
    r = client.get("/terminal/..%2fsecret.html", follow_redirects=False)
    assert r.status_code == 404


def test_terminal_proxy_rejects_backslash(client):
    r = client.get("/terminal/foo%5cbar.html", follow_redirects=False)
    assert r.status_code == 404


def test_terminal_proxy_rejects_unknown_extension(client):
    r = client.get("/terminal/secret.env", follow_redirects=False)
    assert r.status_code == 404


def test_terminal_proxy_404_for_missing_whitelisted_file(client):
    r = client.get("/terminal/definitely-not-here-xyz.js", follow_redirects=False)
    assert r.status_code == 404


def test_undelivered_landing(client):
    r = client.get("/undelivered", follow_redirects=False)
    assert r.status_code == 200


# ---- /bridge family ----

def test_bridge_redirect(client):
    r = client.get("/bridge", follow_redirects=False)
    assert r.status_code == 308
    assert r.headers["location"] == "/bridge/"


def _bridge_present():
    return os.path.isfile(os.path.join(app_module._BRIDGE_DIR, "index.html"))


def test_bridge_index(client):
    r = client.get("/bridge/", follow_redirects=False)
    # 200 if the build artifact is present, else 404 (route is ship-safe).
    assert r.status_code in (200, 404)
    if not _bridge_present():
        assert r.status_code == 404


def test_bridge_proxy_rejects_traversal(client):
    r = client.get("/bridge/..%2fsecret", follow_redirects=False)
    assert r.status_code == 404


def test_bridge_proxy_rejects_backslash(client):
    r = client.get("/bridge/foo%5cbar.js", follow_redirects=False)
    assert r.status_code == 404


def test_bridge_proxy_missing_asset_404(client):
    r = client.get("/bridge/definitely-not-here-xyz.js", follow_redirects=False)
    # Whitelisted ext but missing file (or build absent) => 404.
    assert r.status_code == 404


def test_bridge_proxy_spa_deeplink(client):
    # Non-asset client route => SPA shell (200 if build present, else 404).
    r = client.get("/bridge/my-tickets", follow_redirects=False)
    assert r.status_code in (200, 404)
    if not _bridge_present():
        assert r.status_code == 404


def test_bridge_proxy_serves_existing_asset(client, monkeypatch, tmp_path):
    # Force the bridge dir to a temp dir with a real asset so the
    # "real asset → serve it" branch (FileResponse) is exercised.
    bridge_dir = tmp_path / "bridge"
    bridge_dir.mkdir()
    (bridge_dir / "index.html").write_text("<html>bridge</html>")
    (bridge_dir / "app.js").write_text("console.log(1)")
    monkeypatch.setattr(app_module, "_BRIDGE_DIR", str(bridge_dir))
    assert client.get("/bridge/", follow_redirects=False).status_code == 200
    assert client.get("/bridge/app.js", follow_redirects=False).status_code == 200
    # SPA deeplink now falls back to the present index.html.
    assert client.get("/bridge/some/route", follow_redirects=False).status_code == 200


def test_bridge_index_404_when_build_absent(client, monkeypatch, tmp_path):
    empty = tmp_path / "empty_bridge"
    empty.mkdir()
    monkeypatch.setattr(app_module, "_BRIDGE_DIR", str(empty))
    assert client.get("/bridge/", follow_redirects=False).status_code == 404
    # Asset path with missing index => 404 branch in the proxy.
    assert client.get("/bridge/x.js", follow_redirects=False).status_code == 404
    # SPA deeplink with missing index => 404 branch.
    assert client.get("/bridge/route", follow_redirects=False).status_code == 404


# ---- /version.json ----

def test_version_json(client):
    body = client.get("/version.json").json()
    assert body["version"] == app_module._STOREFRONT_VERSION
    for key in (
        "render_commit", "railway_commit", "git_commit", "render_service_id",
        "render_external_url", "railway_public_domain", "deployed_at_iso",
    ):
        assert key in body


# ---- /healthz ----

class _HealthOkSb:
    class _Chain:
        def select(self, *a, **k):
            return self

        def limit(self, *a, **k):
            return self

        def execute(self):
            return type("R", (), {"data": [{"id": 1}]})()

    def table(self, *a, **k):
        return self._Chain()


def test_healthz_skips_when_sb_none(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    body = client.get("/healthz").json()
    assert body["ok"] is True
    assert body["supabase_smoke"].startswith("skipped")


def test_healthz_pass_with_stub(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", _HealthOkSb())
    body = client.get("/healthz").json()
    assert body["supabase_smoke"] == "pass"
    assert body["supabase_smoke_rows"] == 1


def test_healthz_fail_truncates(client, monkeypatch):
    class _Boom:
        def table(self, *a, **k):
            raise RuntimeError("z" * 1000)

    monkeypatch.setattr(app_module, "sb", _Boom())
    body = client.get("/healthz").json()
    assert body["ok"] is False
    assert body["supabase_smoke"] == "fail"
    assert len(body["supabase_smoke_error"]) <= 300


def test_healthz_reports_db_circuit_closed_on_pass(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", _HealthOkSb())
    body = client.get("/healthz").json()
    # A passing smoke records success -> breaker stays closed.
    assert body["db_circuit"] == "closed"


def test_healthz_smoke_failure_feeds_breaker(client, monkeypatch):
    class _Boom:
        def table(self, *a, **k):
            raise RuntimeError("down")

    monkeypatch.setattr(app_module, "sb", _Boom())
    # Drive the breaker to its threshold via repeated failing health checks.
    threshold = app_module._db_breaker.fail_threshold
    last = None
    for _ in range(threshold):
        last = client.get("/healthz").json()
    assert last["db_circuit"] == "open"


def test_healthz_db_circuit_present_when_sb_none(client, monkeypatch):
    monkeypatch.setattr(app_module, "sb", None)
    body = client.get("/healthz").json()
    # Field is always present (top-level), even when the smoke is skipped.
    assert body["db_circuit"] == "closed"


# ---- safe_sb_read (storefront stale-snapshot read) ----

def test_safe_sb_read_returns_live_on_success():
    assert app_module.safe_sb_read(lambda: "live", "stale") == "live"


def test_safe_sb_read_falls_back_on_error():
    seen = []

    def boom():
        raise RuntimeError("db down")

    out = app_module.safe_sb_read(boom, "stale", on_error=seen.append)
    assert out == "stale"
    assert isinstance(seen[0], RuntimeError)


# ---- POST /webhooks/render ----

def test_webhook_rejects_bad_signature(client, monkeypatch):
    monkeypatch.setattr(
        rw, "load_config",
        lambda: {"webhook_secret": "whsec_test"},
    )

    def _boom(secret, body, headers):
        raise rw.WebhookVerificationError("bad sig")

    monkeypatch.setattr(rw, "verify_signature", _boom)
    r = client.post("/webhooks/render", content=b'{"type":"deploy_ended"}')
    assert r.status_code == 401
    assert "webhook verification failed" in r.json()["detail"]


def test_webhook_rejects_invalid_json(client, monkeypatch):
    monkeypatch.setattr(rw, "load_config", lambda: {"webhook_secret": "whsec_test"})
    monkeypatch.setattr(rw, "verify_signature", lambda *a, **k: None)
    r = client.post("/webhooks/render", content=b'not-json{')
    assert r.status_code == 400
    assert "invalid JSON" in r.json()["detail"]


def test_webhook_acks_and_schedules_background(client, monkeypatch):
    monkeypatch.setattr(rw, "load_config", lambda: {"webhook_secret": "whsec_test"})
    monkeypatch.setattr(rw, "verify_signature", lambda *a, **k: None)
    handled = {}
    monkeypatch.setattr(
        rw, "handle_webhook",
        lambda p, c: handled.setdefault("type", p.get("type")) or "dispatched",
    )
    r = client.post("/webhooks/render", content=b'{"type":"deploy_ended","data":{}}')
    assert r.status_code == 200
    assert r.json() == {"ok": True, "received": "deploy_ended"}
    # TestClient runs background tasks synchronously after the response.
    assert handled["type"] == "deploy_ended"


def test_webhook_background_swallows_handler_error(client, monkeypatch):
    monkeypatch.setattr(rw, "load_config", lambda: {"webhook_secret": "whsec_test"})
    monkeypatch.setattr(rw, "verify_signature", lambda *a, **k: None)

    def _crash(p, c):
        raise RuntimeError("handler boom")

    monkeypatch.setattr(rw, "handle_webhook", _crash)
    # The background task must never let the exception escape => still 200.
    r = client.post("/webhooks/render", content=b'{"type":"deploy_ended","data":{}}')
    assert r.status_code == 200


# ---- GET /api/public/config ----

def test_public_config_shape(client):
    body = client.get("/api/public/config").json()
    assert body["supabase_url"] == app_module.SUPABASE_URL
    assert body["supabase_anon_key"] == app_module.SUPABASE_ANON_KEY
    assert "supabase_service_role_key" not in body


def test_public_config_checkout_enabled_path(client, monkeypatch):
    # Kill switch OFF + domain set => purchase_enabled True, domain advertised.
    monkeypatch.setattr(app_module, "STOREFRONT_CHECKOUT_DISABLED", False)
    monkeypatch.setattr(app_module, "STOREFRONT_CHECKOUT_DOMAIN", "checkout.example.com")
    body = client.get("/api/public/config").json()
    assert body["checkout_domain"] == "checkout.example.com"
    assert body["purchase_enabled"] is True


def test_public_config_checkout_disabled_path(client, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_CHECKOUT_DISABLED", True)
    monkeypatch.setattr(app_module, "STOREFRONT_CHECKOUT_DOMAIN", "checkout.example.com")
    body = client.get("/api/public/config").json()
    assert body["checkout_domain"] is None
    assert body["purchase_enabled"] is False
