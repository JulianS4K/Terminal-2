"""Frontend smoke-test harness — fixtures (BR-CODE-4 prerequisite).

The shipped frontend (static/terminal/*, static/store/*, static/home/*) has had
ZERO automated coverage — the 100% gate measures Python only (.coveragerc
source=. omits static/). Before the BR-CODE-4 JS/CSS dedup can touch ~5,700 LOC
of untested JS safely, there must be a regression net under it. This harness
boots the real FastAPI app in a background thread and drives the pre-installed
Chromium via Playwright to assert each page loads + initializes without a
JS-defect-class error or a missing asset — exactly the failure modes a careless
dedup introduces (dropped function, broken syntax, deleted-but-referenced file).

Isolation from the main suite:
  * test_smoke.py does `pytest.importorskip("playwright")` so the main CI job
    (which doesn't install playwright) skips this module cleanly at collection.
  * .coveragerc already omits tests/*, so none of this affects the Python
    coverage ratchet.
  * The browser resolves the dev container's pre-installed Chromium
    (/opt/pw-browsers) via executable_path, falling back to Playwright's own
    default browser in CI; if neither launches, the browser fixture skips.
"""
from __future__ import annotations

import glob
import os
import socket
import sys
import threading
import time

import pytest

# Repo root on sys.path so `import server` resolves regardless of pytest's
# import mode / invocation cwd.
_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)


def _set_demo_env() -> None:
    """Demo-mode env, applied INSIDE the live_server fixture (never at module
    import) so merely collecting this package alongside the main suite can't
    contaminate its env. setdefault means: when run standalone, configure the
    no-creds boot path before `import server` (its bootstrap sys.exit()s on
    missing TEvo creds otherwise); when run combined, defer to whatever the main
    conftest already set (and server is already imported anyway, so these are a
    post-import no-op). The Supabase URL is intentionally invalid — API calls
    fail at request time (filtered as network noise by the smoke test) but every
    page's HTML + JS still loads + initializes."""
    os.environ.setdefault("AUTH_DISABLED", "true")
    os.environ.setdefault("STOREFRONT_SQL_ONLY", "true")
    os.environ.setdefault("SUPABASE_URL", "https://example.invalid")
    os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-key")
    os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _find_chromium() -> str | None:
    """Pre-installed Chromium in the dev container (Playwright version may not
    match its own download, so we point executable_path at it). Returns None in
    CI, where Playwright's own installed browser is used by default."""
    hits = sorted(glob.glob("/opt/pw-browsers/chromium-*/chrome-linux/chrome"))
    return hits[-1] if hits else None


@pytest.fixture(scope="session")
def live_server():
    """Boot the real FastAPI app via uvicorn in a daemon thread on a free port;
    yield its base URL; shut it down at session end."""
    _set_demo_env()
    import uvicorn
    import server  # imported after the demo env is applied

    port = _free_port()
    config = uvicorn.Config(server.app, host="127.0.0.1", port=port, log_level="error")
    srv = uvicorn.Server(config)
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()

    deadline = time.time() + 20
    while not srv.started and time.time() < deadline:
        time.sleep(0.05)
    if not srv.started:  # pragma: no cover - boot failure is environmental
        raise RuntimeError("uvicorn did not start within 20s")

    yield f"http://127.0.0.1:{port}"

    srv.should_exit = True
    thread.join(timeout=5)


@pytest.fixture(scope="session")
def browser():
    """Launch headless Chromium for the session. Uses the dev container's
    pre-installed build via executable_path when present, else Playwright's
    default. Skips the whole module if no browser can be launched."""
    from playwright.sync_api import sync_playwright

    chrome = _find_chromium()
    pw = sync_playwright().start()
    launch_kwargs = {"headless": True, "args": ["--no-sandbox"]}
    if chrome:
        launch_kwargs["executable_path"] = chrome
    try:
        b = pw.chromium.launch(**launch_kwargs)
    except Exception as e:  # pragma: no cover - environmental (no browser)
        pw.stop()
        pytest.skip(f"could not launch Chromium: {e!r}")
    yield b
    b.close()
    pw.stop()
