"""Fixtures for the deployed-preview Playwright smoke (testing-recommendation #5).

Unlike tests/frontend (which boots the app in-process), this suite drives the
REAL deployed composition at DEPLOY_SMOKE_BASE_URL — so it catches the class of
bug the in-process suite can't: the deploy looked fine but the browser fetched
stale JS/CSS (the exact failure the server.py cache-busting workaround exists
for), or a route 500s only against the live DB/CDN.

Gated by DEPLOY_SMOKE_BASE_URL (skipped everywhere else, incl. the main pytest
job which passes --ignore=tests/deploy_smoke). Runs from .github/workflows/
post-deploy.yml against the storefront right after a Render deploy settles.
"""
from __future__ import annotations

import glob
import os

import pytest

pytest.importorskip("playwright")
from playwright.sync_api import sync_playwright  # noqa: E402

BASE_URL = os.environ.get("DEPLOY_SMOKE_BASE_URL")


def _find_chromium() -> str | None:
    """Dev-container pre-installed Chromium; None in CI (Playwright's own)."""
    hits = sorted(glob.glob("/opt/pw-browsers/chromium-*/chrome-linux/chrome"))
    return hits[-1] if hits else None


@pytest.fixture(scope="session")
def base_url():
    if not BASE_URL:
        pytest.skip("DEPLOY_SMOKE_BASE_URL unset — deploy smoke runs post-deploy only")
    return BASE_URL.rstrip("/")


@pytest.fixture(scope="session")
def browser():
    with sync_playwright() as p:
        exe = _find_chromium()
        try:
            b = p.chromium.launch(executable_path=exe) if exe else p.chromium.launch()
        except Exception as e:  # pragma: no cover - env-dependent
            pytest.skip(f"no launchable Chromium: {e}")
        try:
            yield b
        finally:
            b.close()


class _PageProbe:
    """Wraps a page + records console errors and failed responses so every flow
    can assert the deployed composition served non-stale, error-free assets."""

    def __init__(self, page, base_url: str):
        self.page = page
        self.base_url = base_url
        self.console_errors: list[str] = []
        self.failed_assets: list[str] = []
        page.on("console", lambda m: m.type == "error" and self.console_errors.append(m.text))
        page.on("response", self._on_response)

    def _on_response(self, resp):
        # A stale-JS deploy classically 404s a hashed asset the HTML references.
        if resp.status >= 400 and any(
            resp.url.endswith(ext) for ext in (".js", ".css", ".mjs")
        ):
            self.failed_assets.append(f"{resp.status} {resp.url}")

    def goto(self, path: str):
        return self.page.goto(self.base_url + path, wait_until="domcontentloaded")

    def assert_clean(self):
        assert not self.failed_assets, f"stale/failed assets: {self.failed_assets}"
        assert not self.console_errors, f"console errors: {self.console_errors}"


@pytest.fixture
def probe(browser, base_url):
    context = browser.new_context()
    page = context.new_page()
    pr = _PageProbe(page, base_url)
    try:
        yield pr
    finally:
        context.close()
