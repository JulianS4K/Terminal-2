"""Behavioral frontend tests — assert pages render real CONTENT, not just that
they don't crash (BR-CODE-4 net, deeper tier than test_smoke.py).

test_smoke.py proves every page loads + initializes without a JS error. This
file goes one level deeper for the storefront catalog: it stubs the
`/api/store/home` API with a fixture (Playwright route interception) and asserts
store.js actually renders the returned inventory into the grid — the core
customer-facing function. This catches a render regression (dropped card, wrong
field) that a crash-level smoke test cannot.
"""
from __future__ import annotations

import json

import pytest

pytest.importorskip("playwright")

# Minimal event shape matching the fields store.js's render() reads for a card
# (see static/store/store.js render()). Two distinct events so we can assert the
# grid renders exactly what the API returned.
_FIXTURE_EVENTS = [
    {
        "id": 991001,
        "name": "Smoke Test Knicks vs Celtics",
        "occurs_at_local": "2026-09-01T19:00:00-04:00",
        "venue_name": "Madison Square Garden",
        "venue_location": "New York, NY",
        "from_price": 175,
        "primary_performer_name": "Knicks",
    },
    {
        "id": 991002,
        "name": "Smoke Test Phish at MSG",
        "occurs_at_local": "2026-09-05T20:00:00-04:00",
        "venue_name": "Madison Square Garden",
        "venue_location": "New York, NY",
        "from_price": 95,
        "primary_performer_name": "Phish",
    },
]


def test_store_home_renders_catalog_cards(live_server, browser):
    """Stub /api/store/home → assert store.js renders one card per returned
    event, with the event names visible. Proves the catalog render path works
    end-to-end against a known payload."""
    ctx = browser.new_context()
    page = ctx.new_page()

    pageerrors = []
    page.on("pageerror", lambda exc: pageerrors.append(str(exc)))

    def _fulfill_home(route):
        route.fulfill(
            status=200,
            content_type="application/json",
            body=json.dumps({
                "count": len(_FIXTURE_EVENTS),
                "events": _FIXTURE_EVENTS,
                "limit": 60,
                "source": "sql",
            }),
        )

    # Intercept the catalog source endpoint with our fixture. Other endpoints
    # (movers/concierge rails) fall through to the live demo server and are
    # handled gracefully by store.js (verified by the smoke baseline).
    page.route("**/api/store/home*", _fulfill_home)

    page.goto(live_server + "/store", wait_until="domcontentloaded", timeout=20000)

    # store.js renders real cards as <a class="card"> (skeletons are <div>s).
    page.wait_for_selector("#grid a.card", timeout=8000)
    cards = page.locator("#grid a.card")
    assert cards.count() == len(_FIXTURE_EVENTS), (
        f"expected {len(_FIXTURE_EVENTS)} catalog cards, got {cards.count()}"
    )

    grid_text = page.locator("#grid").inner_text()
    for ev in _FIXTURE_EVENTS:
        assert ev["name"] in grid_text, f"card for {ev['name']!r} not rendered"

    # Each card must link to its event detail page.
    hrefs = cards.evaluate_all("els => els.map(e => e.getAttribute('href'))")
    assert sorted(hrefs) == [f"/store/event/{e['id']}" for e in _FIXTURE_EVENTS]

    ctx.close()
    assert not pageerrors, f"uncaught JS error rendering catalog: {pageerrors}"


def test_store_home_empty_renders_empty_state(live_server, browser):
    """Stub /api/store/home → 0 events → assert the empty-state message renders
    (not a crash, not a stuck skeleton). The complementary path to the populated
    grid above."""
    ctx = browser.new_context()
    page = ctx.new_page()
    pageerrors = []
    page.on("pageerror", lambda exc: pageerrors.append(str(exc)))

    page.route(
        "**/api/store/home*",
        lambda route: route.fulfill(
            status=200,
            content_type="application/json",
            body=json.dumps({"count": 0, "events": [], "limit": 60, "source": "sql"}),
        ),
    )
    page.goto(live_server + "/store", wait_until="domcontentloaded", timeout=20000)
    # The empty-state node (#empty) becomes visible; no real cards render.
    page.wait_for_selector("#empty", state="visible", timeout=8000)
    assert page.locator("#grid a.card").count() == 0
    ctx.close()
    assert not pageerrors, f"uncaught JS error on empty catalog: {pageerrors}"
