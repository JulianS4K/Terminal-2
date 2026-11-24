"""Open a box office's public page in a browser, once, and report what loads (read-only).

Operator 2026-11-24: "Go ahead, test tickets.com from the production worker". MLB's own ticketer
(mlb.tickets.com, ProVenue) sells 1,376 of the MLB games we hold, and from a session's network the
host dropped every connection before answering, so nobody knows whether its public game page can be
read the way the Timberwolves' is (core/primary_poll_browser.py). This script is that one look,
run from the production network: it opens each URL as a visitor does, waits for the page to settle,
and prints what happened. It stores nothing and changes nothing.

    PROBE_URLS="https://mlb.tickets.com/?agency=MLB_MPV&orgid=56069&pid=9779342" python scripts/primary_page_probe.py

What it does NOT do (RULE 2): no click, no form, no cart, no hold, no seat selection, no login; it
builds no request of its own to any data service, and it does not answer, solve or work around a
CAPTCHA, a queue or a block: it reports one and stops on that URL. For each answer the page itself
receives it prints the host, the path, the status, the type and the size, and for a JSON answer the
names of its top-level fields: enough to tell where a listing would come from, never the content.

One JSON line a URL on stdout (the service's log).
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from typing import Any
from urllib.parse import urlsplit

USER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
              "Chrome/126.0 Safari/537.36")
SETTLE_MS = 20_000
TIMEOUT_MS = 45_000
MAX_ANSWERS = 60
SKIPPED_RESOURCES = frozenset({"image", "font", "media", "stylesheet"})
# what a refusal looks like; seeing one ends the look at that URL. WORDS are looked for in what a visitor
# reads (the title and the visible text): a page that merely loads a queue's or a CDN's script is not a
# refusal. MARKS are looked for in the page's source: they only exist on a challenge page.
WORDS = {
    "captcha": re.compile(r"captcha|are you a robot|verify (that )?you are (a )?human|press & hold", re.I),
    "denied": re.compile(r"access denied|access to this page has been denied|you have been blocked|out of bounds", re.I),
    "queue": re.compile(r"you are (now )?in (the )?(line|queue)|waiting room|your estimated wait", re.I),
    "challenge": re.compile(r"just a moment|checking your browser", re.I),
}
MARKS = {
    "px": re.compile(r"px-captcha|captcha\.px-cdn|perimeterx", re.I),
    "datadome": re.compile(r"captcha-delivery\.com|geo\.captcha", re.I),
    "akamai": re.compile(r"errors\.edgesuite\.net", re.I),
    "cloudflare": re.compile(r"cf-chl-|/cdn-cgi/challenge-platform/h/", re.I),
}


def walls(seen: str, source: str = "") -> list[str]:
    return sorted([name for name, pattern in WORDS.items() if pattern.search(seen or "")]
                  + [name for name, pattern in MARKS.items() if pattern.search(source or "")])


def describe(response: Any) -> dict:
    """One answer the page received: where from, what kind, how big; a JSON answer's field names."""
    url = urlsplit(response.url)
    kind = (response.headers.get("content-type") or "").split(";")[0]
    out = {"host": url.hostname, "path": url.path[:120], "method": response.request.method,
           "status": response.status, "type": kind, "resource": response.request.resource_type}
    try:
        body = response.body()
    except Exception:  # noqa: BLE001 - a redirect or an aborted answer has no body
        return out
    out["bytes"] = len(body)
    if "json" in kind:
        try:
            data = json.loads(body)
        except ValueError:
            return out
        if isinstance(data, dict):
            out["fields"] = sorted(data)[:25]
        elif isinstance(data, list):
            out["items"] = len(data)
            if data and isinstance(data[0], dict):
                out["fields"] = sorted(data[0])[:25]
    return out


def look(context: Any, url: str) -> dict:
    page = context.new_page()
    answers: list = []
    page.on("response", lambda r: answers.append(r) if r.request.resource_type not in SKIPPED_RESOURCES else None)
    report: dict = {"url": url, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        first = page.goto(url, wait_until="domcontentloaded", timeout=TIMEOUT_MS)
        report["status"] = first.status if first else None
        try:
            page.wait_for_load_state("networkidle", timeout=SETTLE_MS)
            report["settled"] = True
        except Exception:  # noqa: BLE001 - a page that keeps talking is still worth describing
            report["settled"] = False
        html, title = page.content(), page.title()
        text = re.sub(r"\s+", " ", page.inner_text("body"))
        report.update({
            "final_url": page.url, "title": title[:120], "html_bytes": len(html),
            "walls": walls(title + " " + text[:4000], html), "text": text[:400],
        })
    except Exception as exc:  # noqa: BLE001 - "could not connect" is the answer we came for
        report["error"] = f"{type(exc).__name__}: {str(exc)[:300]}"
    finally:
        described = [describe(r) for r in answers[:MAX_ANSWERS]]
        report["answers"] = len(answers)
        report["hosts"] = sorted({d["host"] for d in described if d["host"]})
        report["json"] = [d for d in described if "json" in d.get("type", "")][:30]
        report["not_ok"] = [d for d in described if d["status"] >= 400][:15]
        page.close()
    return report


def main(urls: list[str]) -> None:
    from playwright.sync_api import sync_playwright
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        try:
            context = browser.new_context(user_agent=USER_AGENT, viewport={"width": 1400, "height": 900})
            for url in urls:
                print("PROBE " + json.dumps(look(context, url), sort_keys=True), flush=True)
                time.sleep(3)
        finally:
            browser.close()


if __name__ == "__main__":
    wanted = [u.strip() for u in (os.environ.get("PROBE_URLS") or " ".join(sys.argv[1:])).replace(",", " ").split() if u.strip()]
    if not wanted:
        raise SystemExit("PROBE_URLS is empty: nothing to look at")
    main(wanted[:5])
