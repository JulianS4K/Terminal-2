"""Storefront HTML shell rendering + cache — extracted from server.py
(BR-CODE-1 core/ pass).

`read_storefront_html` reads a static/store/*.html shell, cache-busts the
store.js + style.css refs with the deploy SHA, rewrites the OG share-card base
URL for this deploy's host, and memoizes the result for the container's life.
The server wraps the result in an HTMLResponse (with a revalidate header) via its
own _read_storefront_html wrapper so the test monkeypatch on that name binds.

The deploy identity (version, base URL), the static dir, and the cache dict are
INJECTED by the server wrapper so the test monkeypatches (app._STOREFRONT_VERSION
/ app._STOREFRONT_HTML_CACHE) keep binding through the call.
"""
from __future__ import annotations

import os

_DEFAULT_OG_BASE = "https://vibepass-storefront-test.onrender.com"


def read_storefront_html(name: str, *, static_dir: str, version: str, base_url: str, cache: dict) -> str:
    """Read a `static/store/<name>` HTML shell, rewrite the store.js +
    style.css refs to include `?v=<sha>`, swap the hardcoded OG share-card
    base URL for this deploy's actual host, cache the result for the life
    of the container. The source files don't change mid-process.
    """
    cached = cache.get(name)
    if cached is not None:
        return cached
    path = os.path.join(static_dir, "store", name)
    with open(path, "r", encoding="utf-8") as f:
        html = f.read()
    v = version
    base = base_url
    # Cache-bust asset URLs. Closing-quote specificity prevents accidental
    # matches inside JS strings or CSS url() refs that might be added later.
    html = html.replace(
        '/static/store/store.js"',
        f'/static/store/store.js?v={v}"',
    )
    html = html.replace(
        '/static/store/style.css"',
        f'/static/store/style.css?v={v}"',
    )
    # Replace the hardcoded `https://vibepass-storefront-test.onrender.com`
    # base in OG share-card tags (PR #166) with this deploy's actual host so
    # iMessage/Slack/WhatsApp/Discord/Twitter previews point at the right
    # deploy (Render vs Railway vs custom). When base resolves to the same
    # default this is a no-op string replace.
    if base != _DEFAULT_OG_BASE:
        html = html.replace(_DEFAULT_OG_BASE, base)
    cache[name] = html
    return html
