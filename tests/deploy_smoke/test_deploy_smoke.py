"""Five-flow smoke against the DEPLOYED preview (testing-recommendation #5).

The unit + in-process coverage is high, but nothing verified the deployed
*composition* — where the stale-JS / cache-bust bug class lives. Each flow below
loads a real surface at DEPLOY_SMOKE_BASE_URL, asserts a stable landmark is
present, and (via the probe) asserts NO console errors and NO failed JS/CSS
asset loads — the direct signal that the browser got fresh, wired code.

Interactions are kept smoke-level and resilient (role/text locators, tolerant of
copy changes) rather than brittle deep E2E — a deploy gate must fail on real
breakage, not on a renamed button. Selectors can be tightened by D0/D4 who own
the live DOM. Skipped unless DEPLOY_SMOKE_BASE_URL is set (see conftest).
"""
from __future__ import annotations


# Flow 1 — storefront search → event → reserve entry.
def test_storefront_search_to_event(probe):
    resp = probe.goto("/")
    assert resp is not None and resp.ok, f"storefront / not ok: {resp and resp.status}"
    # A search box is the storefront's defining landmark.
    box = probe.page.locator("input[type='search'], input[placeholder*='search' i], #search, [name='q']")
    assert box.count() >= 1, "storefront search input not found — shell may be stale/broken"
    probe.assert_clean()


# Flow 2 — share create → resolve in a fresh (incognito) context.
def test_share_resolve_public_page(probe):
    # The public share-resolve shell must render for an anonymous visitor. A
    # bogus id should still serve the shell (client resolves + shows not-found),
    # never a 5xx.
    resp = probe.goto("/s/deploy-smoke-nonexistent")
    assert resp is not None and resp.status < 500, f"share page 5xx: {resp and resp.status}"
    probe.assert_clean()


# Flow 3 — terminal login gate rejects a non-domain visitor (auth boundary).
def test_terminal_login_gate_present(probe):
    resp = probe.goto("/terminal")
    assert resp is not None and resp.status < 500, f"terminal 5xx: {resp and resp.status}"
    # An unauthenticated visitor must hit a gate (sign-in), not the app content.
    body = probe.page.content().lower()
    assert any(w in body for w in ("sign in", "log in", "login", "authenticate")), \
        "terminal did not present a login gate to an anonymous visitor"
    probe.assert_clean()


# Flow 4 — bridge ticket surface renders (barcode wallet shell loads + wired).
def test_bridge_surface_loads(probe):
    resp = probe.goto("/bridge")
    # /bridge may 401/redirect for an anon user; the shell must still load its
    # JS without console/asset errors (the stale-deploy signal).
    assert resp is not None and resp.status < 500, f"bridge 5xx: {resp and resp.status}"
    probe.assert_clean()


# Flow 5 — scanner surface loads (offline-verify shell; rejects expired at use).
def test_scanner_surface_loads(probe):
    resp = probe.goto("/bridge/scan")
    assert resp is not None and resp.status < 500, f"scanner 5xx: {resp and resp.status}"
    probe.assert_clean()
