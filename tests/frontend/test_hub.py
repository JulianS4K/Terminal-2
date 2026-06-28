"""Hub (unified landing) behavioral tests — the Render landing page.

`/` (and `/home/`) serve the VibePass hub (static/home/index.html): the 5-surface
selector that is the Render landing for the storefront-test web service
(STOREFRONT_AS_LANDING=false). These assert the hub actually renders its surface
cards with the right routes + wires auth — not just that it loads without a crash.
"""
from __future__ import annotations

import pytest

pytest.importorskip("playwright")

# (card heading, expected href). The 5 surfaces the hub links to.
EXPECTED_CARDS = {
    "Terminal": "/terminal",
    "Undelivered": "/undelivered",
    "Orders": "https://d2-orders-dashboard.onrender.com",
    "Store": "/store",
    "Bridge": "/bridge/",
}

# Substrings that mark a genuine JS defect (vs benign env noise).
_DEFECT = ("is not defined", "is not a function", "syntaxerror", "referenceerror",
           "cannot read prop", "unexpected token")


@pytest.mark.parametrize("path", ["/", "/home/"])
def test_hub_renders_surface_cards(live_server, browser, path):
    """Both / and /home/ serve the hub with all 5 surface cards + correct hrefs."""
    ctx = browser.new_context()
    page = ctx.new_page()
    pageerrors, console_errors = [], []
    page.on("pageerror", lambda e: pageerrors.append(str(e)))
    page.on("console", lambda m: console_errors.append(m.text) if m.type == "error" else None)

    resp = page.goto(live_server + path, wait_until="domcontentloaded", timeout=20000)
    assert resp and resp.status < 400, f"{path}: HTTP {resp.status if resp else 'none'}"
    page.wait_for_selector("body[data-page='home']", timeout=5000)

    cards = page.locator("main.grid a.card")
    found = {}
    for i in range(cards.count()):
        c = cards.nth(i)
        h2 = c.locator("h2").inner_text().strip() if c.locator("h2").count() else ""
        found[h2] = c.get_attribute("href")
    assert found == EXPECTED_CARDS, f"{path}: hub cards/hrefs drifted: {found}"

    page.wait_for_timeout(600)
    ctx.close()
    assert not pageerrors, f"{path}: uncaught JS error on hub: {pageerrors}"
    # No JS-defect console errors. (frame-ancestors-in-meta warning was removed.)
    defects = [m for m in console_errors if any(s in m.lower() for s in _DEFECT)]
    assert not defects, f"{path}: JS-defect console error(s): {defects}"


def test_hub_subtitle_and_auth_control(live_server, browser):
    """Header copy reflects the 5 surfaces + the auth control is wired (auth.js
    populates #auth-ctrl)."""
    ctx = browser.new_context()
    page = ctx.new_page()
    page.goto(live_server + "/", wait_until="domcontentloaded", timeout=20000)
    page.wait_for_selector("body[data-page='home']", timeout=5000)
    page.wait_for_timeout(600)

    subtitle = page.locator(".brand-sub").inner_text()
    assert subtitle.startswith("5-surface"), f"stale surface count in subtitle: {subtitle!r}"
    # auth.js renders a control into #auth-ctrl (sign-in or session state).
    assert page.locator("#auth-ctrl").inner_text().strip() != "", "auth control not wired"

    ctx.close()


def test_hub_no_frame_ancestors_meta_warning(live_server, browser):
    """Regression: the hub must NOT ship a frame-ancestors directive in its
    <meta> CSP (browsers ignore it there + it logs a console warning). Framing
    is enforced by the server's HTTP headers instead."""
    ctx = browser.new_context()
    page = ctx.new_page()
    warnings = []
    page.on("console", lambda m: warnings.append(m.text) if m.type in ("error", "warning") else None)
    page.goto(live_server + "/", wait_until="domcontentloaded", timeout=20000)
    page.wait_for_timeout(600)
    ctx.close()
    fa = [w for w in warnings if "frame-ancestors" in w.lower()]
    assert not fa, f"frame-ancestors meta warning present (should be HTTP-header only): {fa}"
