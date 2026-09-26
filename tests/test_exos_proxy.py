"""/bridge/* reverse proxy to the exos-web Render service (core/exos_proxy.py, D4).

Exos (JulianS4K/EXP) runs on its own service; with EXOS_ORIGIN set this app
forwards /bridge/* there so the Render link + origin + shared login stay the
same, and falls back to static/bridge/ when exos-web is down.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest
import requests

os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_TOKEN", "test-token")
os.environ.setdefault("TEVO_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

pytest.importorskip("fastapi")
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from starlette.requests import Request  # noqa: E402

from core import exos_proxy  # noqa: E402

ORIGIN = "https://exos-web.example"
SHELL = "<html><head><title>Exos</title></head><body>static copy</body></html>"


class _Upstream:
    """Stands in for requests.Response."""

    def __init__(self, status=200, content=b"<html>exos-web</html>", headers=None):
        self.status_code = status
        self.content = content
        self.headers = headers if headers is not None else {
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'",
            "Cache-Control": "no-cache",
            "Content-Encoding": "gzip",
            "Content-Length": "999",
            "Connection": "keep-alive",
        }


def _recorder(result):
    calls = []

    def fetch(method, url, **kw):
        calls.append({"method": method, "url": url, **kw})
        if isinstance(result, Exception):
            raise result
        return result

    return fetch, calls


# ---- exos_origin -----------------------------------------------------------

def test_exos_origin(monkeypatch):
    monkeypatch.delenv("EXOS_ORIGIN", raising=False)
    assert exos_proxy.exos_origin() is None
    monkeypatch.setenv("EXOS_ORIGIN", "ftp://nope")
    assert exos_proxy.exos_origin() is None
    monkeypatch.setenv("EXOS_ORIGIN", " https://exos-web.example/ ")
    assert exos_proxy.exos_origin() == ORIGIN


# ---- proxy_bridge ----------------------------------------------------------

def _app(fetch):
    app = FastAPI()

    @app.api_route("/bridge/{page:path}", methods=["GET", "HEAD"])
    def route(page: str, request: Request):
        return exos_proxy.proxy_bridge(request, ORIGIN, fetch=fetch) or {"fallback": True}

    return TestClient(app)


def test_forwards_path_query_and_client_headers():
    fetch, calls = _recorder(_Upstream())
    r = _app(fetch).get(
        "/bridge/event/abc?ref=ig",
        headers={"user-agent": "facebookexternalhit/1.1", "x-forwarded-for": "1.2.3.4",
                 "x-forwarded-proto": "https", "cookie": "secret=1"},
    )
    assert r.status_code == 200 and r.text == "<html>exos-web</html>"
    call = calls[0]
    assert call["method"] == "GET" and call["url"] == f"{ORIGIN}/bridge/event/abc?ref=ig"
    assert call["allow_redirects"] is False and call["timeout"] == 10.0
    h = call["headers"]
    assert h["user-agent"] == "facebookexternalhit/1.1"
    assert h["X-Forwarded-For"] == "1.2.3.4, testclient"
    assert h["X-Forwarded-Proto"] == "https" and h["X-Forwarded-Host"] == "testserver"
    assert "cookie" not in {k.lower() for k in h}
    # Upstream security headers pass through; decoded-body headers don't.
    assert r.headers["content-security-policy"] == "default-src 'self'; frame-ancestors 'none'"
    assert r.headers["cache-control"] == "no-cache"
    assert "content-encoding" not in r.headers


def test_without_query_or_prior_forwarded_for():
    fetch, calls = _recorder(_Upstream(headers={}))
    _app(fetch).get("/bridge/")
    assert calls[0]["url"] == f"{ORIGIN}/bridge/"
    assert calls[0]["headers"]["X-Forwarded-For"] == "testclient"
    assert calls[0]["headers"]["X-Forwarded-Proto"] == "http"


def test_forwarded_for_without_a_client_address():
    fetch, calls = _recorder(_Upstream(headers={}))
    scope = {"type": "http", "method": "GET", "path": "/bridge/x", "query_string": b"",
             "headers": [(b"x-forwarded-for", b"9.9.9.9")], "client": None,
             "scheme": "https", "server": ("t", 443)}
    exos_proxy.proxy_bridge(Request(scope), ORIGIN, fetch=fetch)
    assert calls[0]["headers"]["X-Forwarded-For"] == "9.9.9.9"
    scope["headers"] = []
    exos_proxy.proxy_bridge(Request(scope), ORIGIN, fetch=fetch)
    assert calls[1]["headers"]["X-Forwarded-For"] == ""


def test_head_has_no_body_and_redirects_pass_through():
    fetch, calls = _recorder(_Upstream(headers={"Location": "/bridge/"}, status=308))
    head = _app(fetch).head("/bridge/x", follow_redirects=False)
    assert calls[0]["method"] == "HEAD"
    assert head.status_code == 308 and head.headers["location"] == "/bridge/" and head.content == b""


def test_upstream_errors_pass_through_except_unavailable():
    fetch, _ = _recorder(_Upstream(status=404, content=b"nope", headers={}))
    r = _app(fetch).get("/bridge/assets/old.js")
    assert r.status_code == 404 and r.text == "nope"


@pytest.mark.parametrize("result", [
    requests.ConnectionError("refused"),
    _Upstream(status=502, headers={}),
    _Upstream(status=503, headers={}),
    _Upstream(status=504, headers={}),
])
def test_unreachable_or_unavailable_falls_back(result):
    fetch, _ = _recorder(result)
    assert _app(fetch).get("/bridge/x").json() == {"fallback": True}


# ---- the real routes -------------------------------------------------------

import server as app_module  # noqa: E402


def _use_fetch(monkeypatch, fetch):
    real = exos_proxy.proxy_bridge
    monkeypatch.setattr(exos_proxy, "proxy_bridge", lambda request, origin: real(request, origin, fetch=fetch))


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    (tmp_path / "index.html").write_text(SHELL, encoding="utf-8")
    monkeypatch.setattr(app_module, "_BRIDGE_DIR", str(tmp_path))
    monkeypatch.setattr(app_module, "_exos_sitemap", lambda: "<urlset>local</urlset>")
    return TestClient(app_module.app)


def test_routes_serve_static_when_exos_origin_unset(bridge, monkeypatch):
    monkeypatch.delenv("EXOS_ORIGIN", raising=False)
    assert "static copy" in bridge.get("/bridge/").text
    assert "static copy" in bridge.get("/bridge/my-tickets").text
    assert bridge.get("/bridge/sitemap.xml").text == "<urlset>local</urlset>"


def test_routes_proxy_when_exos_origin_set(bridge, monkeypatch):
    monkeypatch.setenv("EXOS_ORIGIN", ORIGIN)
    fetch, calls = _recorder(_Upstream(headers={"Content-Security-Policy": "from-exos", "Content-Type": "text/html"}))
    _use_fetch(monkeypatch, fetch)
    for path in ("/bridge/", "/bridge/event/abc", "/bridge/sitemap.xml"):
        r = bridge.get(path)
        assert r.status_code == 200 and r.text == "<html>exos-web</html>", path
        # server.py's security middleware only fills in missing headers.
        assert r.headers["content-security-policy"] == "from-exos"
    assert [c["url"] for c in calls] == [f"{ORIGIN}/bridge/", f"{ORIGIN}/bridge/event/abc", f"{ORIGIN}/bridge/sitemap.xml"]


def test_routes_fall_back_to_static_when_exos_is_down(bridge, monkeypatch):
    monkeypatch.setenv("EXOS_ORIGIN", ORIGIN)
    fetch, _ = _recorder(requests.ConnectionError("down"))
    _use_fetch(monkeypatch, fetch)
    r = bridge.get("/bridge/event/abc")
    assert r.status_code == 200 and "static copy" in r.text
