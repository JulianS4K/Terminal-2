"""Frontend page smoke tests (BR-CODE-4 regression net).

For each shipped page: load it in a real browser against the live app and assert
(1) the document responds < 400, (2) the correct HTML shell rendered
(body[data-page=...]), (3) no same-origin JS/CSS asset failed to load, and
(4) no JS-defect-class error fired (uncaught SyntaxError/ReferenceError/TypeError
or the console equivalents). Network/API errors are EXPECTED in this
credential-less demo env (Supabase is unreachable) and are deliberately NOT
failed on — only JS-defect signatures are, since those are exactly what a
careless dedup of the page's JS would introduce.

An uncaught exception during load (a `pageerror`) is treated as a defect
UNCONDITIONALLY — not signature-filtered — because (a) there is no legitimate
reason for one (the clean baseline is pageerror-free across every page even with
Supabase unreachable; the shipped JS guards against empty/error API responses),
and (b) signature-filtering provably misses real defects: a `function (){}`
syntax error surfaces as "Function statements require a function name", which
matches no obvious keyword. Console errors, by contrast, carry legitimate
API/network noise in this demo env, so those ARE signature-filtered.
"""
from __future__ import annotations

import pytest

pytest.importorskip("playwright")  # main CI job has no playwright -> skip cleanly

# (url path, expected body[data-page] value). Covers every JS-bearing entry page
# plus the no-JS legal shells. event.html is the BR-CODE-4 dedup target
# (event.js ~5,672 LOC) — loaded with a dummy id so its init path runs.
PAGES = [
    ("/home/", "home"),
    ("/terminal/", "home"),
    ("/terminal/movers.html", "movers"),
    ("/terminal/orders.html", "orders"),
    ("/terminal/performer.html", "performer"),
    ("/terminal/venue.html", "venue"),
    ("/terminal/leagues.html", "leagues"),
    ("/terminal/discovery.html", "discovery"),
    ("/terminal/event.html?id=1", "event"),
    ("/store", "catalog"),
    ("/store/discover", "discover"),
    ("/store/tour", "tour"),
    ("/store/event/1", "event"),
    ("/store/about", "about"),
    ("/store/privacy", "privacy"),
    ("/store/terms", "terms"),
    ("/undelivered", "undelivered"),
]

# Substrings that mark a genuine JS defect (vs benign API/network noise). These
# are the signatures a botched dedup produces: a dropped function, a renamed-but-
# still-referenced symbol, a broken import, a syntax error.
DEFECT_SIGNATURES = (
    "is not defined",
    "is not a function",
    "is not a constructor",
    "cannot read prop",
    "cannot read properties",
    "cannot access",
    "unexpected token",
    "unexpected identifier",
    "syntaxerror",
    "referenceerror",
    "undefined is not",
    "null is not",
)


def _is_defect(msg: str) -> bool:
    low = msg.lower()
    return any(sig in low for sig in DEFECT_SIGNATURES)


def _smoke(browser, base_url, path, data_page):
    """Load one page, return (response_status, diagnostics dict)."""
    diag = {"pageerrors": [], "console_errors": [], "bad_assets": []}
    ctx = browser.new_context()
    page = ctx.new_page()

    page.on("pageerror", lambda exc: diag["pageerrors"].append(str(exc)))

    def _on_console(msg):
        if msg.type == "error":
            diag["console_errors"].append(msg.text)

    def _on_response(resp):
        url = resp.url
        # Only same-origin static JS/CSS — an external CDN 4xx isn't our bug,
        # and non-asset API failures are expected in this demo env.
        if not url.startswith(base_url):
            return
        is_asset = (".js" in url or ".css" in url) and "/api/" not in url
        if is_asset and resp.status >= 400:
            diag["bad_assets"].append(f"{resp.status} {url}")

    page.on("console", _on_console)
    page.on("response", _on_response)

    resp = page.goto(base_url + path, wait_until="domcontentloaded", timeout=20000)
    status = resp.status if resp else 0
    # Let deferred scripts run + any late uncaught errors surface.
    try:
        page.wait_for_selector(f"body[data-page='{data_page}']", timeout=5000)
    except Exception:
        pass  # assertion below gives the clearer message
    page.wait_for_timeout(1000)
    shell_ok = page.locator(f"body[data-page='{data_page}']").count() > 0
    ctx.close()
    return status, shell_ok, diag


@pytest.mark.parametrize("path,data_page", PAGES, ids=[p[0] for p in PAGES])
def test_page_smoke(live_server, browser, path, data_page):
    status, shell_ok, diag = _smoke(browser, live_server, path, data_page)

    assert status and status < 400, f"{path}: document HTTP {status}"
    assert shell_ok, f"{path}: expected body[data-page='{data_page}'] not rendered"
    assert not diag["bad_assets"], f"{path}: static asset load failures: {diag['bad_assets']}"

    # ANY uncaught exception during load is a defect (see module docstring).
    assert not diag["pageerrors"], f"{path}: uncaught JS error(s): {diag['pageerrors']}"

    # Console errors carry API/network noise here, so only JS-defect signatures fail.
    defect_ce = [m for m in diag["console_errors"] if _is_defect(m)]
    assert not defect_ce, f"{path}: JS-defect console error(s): {defect_ce}"
