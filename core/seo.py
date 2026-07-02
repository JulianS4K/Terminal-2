"""Server-side SEO + social-share metadata for the storefront.

Why this exists
---------------
The event page (`static/store/event.html`) sets its Open Graph / Twitter
tags **client-side** in `store.js` once `/api/store/events/:id` resolves.
That works for a human in a browser, but link-unfurling crawlers
(facebookexternalhit, Twitterbot, Slackbot, WhatsApp, Discordbot,
LinkedInBot, TikTok, Googlebot, Bingbot) **do not run JavaScript** — they
read the raw HTML and stop. So every shared event link historically
unfurled to the generic "VibePass — event tickets" card instead of the
event's actual name / venue / date / price.

This module produces crawler-visible `<head>` metadata server-side so
share links to Meta / X / iMessage / Slack / WhatsApp / TikTok render a
real per-event preview, and Google sees `schema.org/Event` structured
data for rich results.

Everything here is pure (no app imports, no I/O of its own) so it
unit-tests cleanly. `inject_event_meta` takes the event resolver as a
parameter, so the route layer (routers/storefront_pages.py) stays thin:
it reads the HTML shell, and — gated on `is_link_crawler` — hands the
shell + the live resolver here to splice the per-event tags in.
"""
from __future__ import annotations

import html
import json
from datetime import datetime
from typing import Callable

# ---- SSR marker + default-image constants (shared with event.html) ----
# The event-page shell delimits its replaceable head block with these markers;
# `inject_event_meta` swaps everything between them for per-event tags.
SSR_META_START = "<!-- SSR_META_START -->"
SSR_META_END = "<!-- SSR_META_END -->"
OG_DEFAULT_IMAGE = "/static/store/og-default.svg"

# User-Agent substrings (lowercased) for the link-unfurl / SEO crawlers we
# want to serve server-rendered metadata to. Matched as substrings so version
# suffixes don't matter. Kept deliberately tight — humans get the fast static
# shell + JS path; only these bots pay for the server-side event fetch.
_CRAWLER_UA_TOKENS = (
    "facebookexternalhit",   # Facebook / Messenger
    "facebookcatalog",
    "meta-externalagent",    # Meta's newer unfurl agent
    "twitterbot",            # X / Twitter
    "slackbot",              # Slack unfurl
    "whatsapp",              # WhatsApp preview
    "discordbot",            # Discord unfurl
    "telegrambot",           # Telegram unfurl
    "linkedinbot",           # LinkedIn unfurl
    "pinterest",             # Pinterest rich pin
    "redditbot",             # Reddit unfurl
    "googlebot",             # Google Search
    "google-inspectiontool",
    "bingbot",               # Bing Search
    "applebot",              # Apple / Siri / Spotlight + iMessage
    "tiktok",                # TikTok in-app browser + bytespider unfurl
    "bytespider",
    "embedly",               # generic unfurl service (used by many apps)
    "vkshare",
    "skypeuripreview",
)


def is_link_crawler(user_agent: str | None) -> bool:
    """True if the UA looks like a link-unfurl / SEO crawler that won't run JS.

    Used to gate the server-side event fetch: only these callers get SSR
    metadata, so a human browsing the storefront never pays the extra
    per-page event lookup.
    """
    if not user_agent:
        return False
    ua = user_agent.lower()
    return any(tok in ua for tok in _CRAWLER_UA_TOKENS)


def _fmt_event_date(date_iso: str | None) -> str | None:
    """Human-readable 'Sat, Jun 21 · 7:30 PM' from an ISO timestamp.

    Returns None on anything unparseable so callers can omit the date
    fragment rather than render a broken string.
    """
    if not date_iso:
        return None
    raw = str(date_iso).strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        # Fall back to a date-only prefix if present (e.g. "2026-06-21").
        head = str(date_iso)[:10]
        try:
            dt = datetime.fromisoformat(head)
        except ValueError:
            return None
    return dt.strftime("%a, %b %-d · %-I:%M %p") if (dt.hour or dt.minute) else dt.strftime("%a, %b %-d")


def event_seo_summary(payload: dict) -> dict | None:
    """Reduce an `/api/store/events/:id` response dict to the fields the
    share/SEO tags need. Returns None when there's no usable event name
    (caller then serves the generic shell).

    Pure: tolerant of missing keys, never raises on a well-formed payload.
    """
    if not isinstance(payload, dict):
        return None
    ev = payload.get("event") or {}
    name = (ev.get("name") or "").strip()
    if not name:
        return None
    venue = ev.get("venue") or {}
    venue_name = (venue.get("name") or "").strip() or None
    city = (venue.get("city") or "").strip() or None
    state = (venue.get("state") or "").strip() or None
    date_iso = ev.get("occurs_at_local") or ev.get("occurs_at")

    # from_price: cheapest available listing (parking excluded — it lives on a
    # separate tab and isn't part of the seat-price story). The payload doesn't
    # carry a top-level from_price on the detail route, so derive it.
    prices = [
        p for p in (
            (lst.get("price") if isinstance(lst, dict) else None)
            for lst in (payload.get("listings") or [])
        ) if isinstance(p, (int, float)) and p > 0
    ]
    from_price = min(prices) if prices else None

    # og:image — prefer a real event/venue image so unfurls aren't all the
    # same default card. Order: venue hero, seating chart, config image.
    config = ev.get("configuration") or {}
    image_url = (
        venue.get("hero_image_url")
        or config.get("seating_chart_large")
        or config.get("seating_chart_medium")
        or None
    )

    return {
        "id": ev.get("id"),
        "name": name,
        "venue_name": venue_name,
        "city": city,
        "state": state,
        "date_iso": date_iso,
        "from_price": from_price,
        "image_url": image_url,
    }


def _title(summary: dict) -> str:
    """`{Event} tickets · {Venue} · {Date} · VibePass` — the SEO title pattern
    from the punch list (better than the bare 'VibePass — tickets')."""
    bits = [f"{summary['name']} tickets"]
    if summary.get("venue_name"):
        bits.append(summary["venue_name"])
    date_h = _fmt_event_date(summary.get("date_iso"))
    if date_h:
        bits.append(date_h)
    bits.append("VibePass")
    return " · ".join(bits)


def _description(summary: dict) -> str:
    loc = ", ".join([b for b in (summary.get("city"), summary.get("state")) if b])
    where = summary.get("venue_name") or loc or "the venue"
    price = ""
    if isinstance(summary.get("from_price"), (int, float)) and summary["from_price"] > 0:
        price = f" from ${int(round(summary['from_price']))}"
    return (
        f"Tickets to {summary['name']} at {where}{price} on VibePass — "
        "direct-inventory seats, transparent pricing, no daisy chains."
    )


def _json_ld(summary: dict, canonical_url: str, image_url: str) -> str:
    """schema.org/Event JSON-LD for Google rich results.

    `<` is escaped to `\\u003c` so a stray '</script>' in any field can't
    break out of the script element (the standard JSON-LD-in-HTML guard).
    """
    data: dict = {
        "@context": "https://schema.org",
        "@type": "Event",
        "name": summary["name"],
        "url": canonical_url,
        "image": [image_url],
        "eventStatus": "https://schema.org/EventScheduled",
        "eventAttendanceMode": "https://schema.org/OfflineEventAttendanceMode",
    }
    if summary.get("date_iso"):
        data["startDate"] = str(summary["date_iso"])
    location: dict = {"@type": "Place"}
    if summary.get("venue_name"):
        location["name"] = summary["venue_name"]
    addr = {
        k: v for k, v in (
            ("addressLocality", summary.get("city")),
            ("addressRegion", summary.get("state")),
        ) if v
    }
    if addr:
        addr["@type"] = "PostalAddress"
        location["address"] = addr
    if len(location) > 1:
        data["location"] = location
    if isinstance(summary.get("from_price"), (int, float)) and summary["from_price"] > 0:
        data["offers"] = {
            "@type": "Offer",
            "url": canonical_url,
            "price": f"{summary['from_price']:.2f}",
            "priceCurrency": "USD",
            "availability": "https://schema.org/InStock",
        }
    raw = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
    return f'<script type="application/ld+json">{raw}</script>'


def build_event_meta_tags(
    summary: dict,
    canonical_url: str,
    default_image_url: str,
) -> str:
    """Build the per-event `<head>` block: title, description, Open Graph,
    Twitter card, canonical, and schema.org/Event JSON-LD.

    All attribute values are HTML-escaped (quote=True) so an event name with
    quotes / angle brackets can't break out of an attribute or inject markup.
    Returns a newline-joined string ready to splice into the HTML shell.
    """
    title = _title(summary)
    desc = _description(summary)
    image = summary.get("image_url") or default_image_url

    def esc(v: str) -> str:
        return html.escape(str(v), quote=True)

    t, d, u, img = esc(title), esc(desc), esc(canonical_url), esc(image)
    lines = [
        f"<title>{esc(title)}</title>",
        f'<meta name="description" content="{d}" />',
        '<meta property="og:type" content="event" />',
        '<meta property="og:site_name" content="VibePass" />',
        f'<meta property="og:title" content="{t}" />',
        f'<meta property="og:description" content="{d}" />',
        f'<meta property="og:url" content="{u}" />',
        f'<meta property="og:image" content="{img}" />',
        '<meta name="twitter:card" content="summary_large_image" />',
        f'<meta name="twitter:title" content="{t}" />',
        f'<meta name="twitter:description" content="{d}" />',
        f'<meta name="twitter:image" content="{img}" />',
        f'<link rel="canonical" href="{u}" />',
        _json_ld(summary, canonical_url, image),
    ]
    return "\n  ".join(lines)


def inject_event_meta(
    shell: str,
    event_id: int,
    base_url: str,
    resolve_event: Callable[..., dict],
) -> str:
    """Replace the SSR_META block in the event-page shell with per-event Open
    Graph / Twitter / JSON-LD tags so link-unfurl + SEO crawlers (which don't
    run JS) see the real event preview.

    Fully defensive: any failure to resolve the event (DB/TEvo down, bad id,
    missing markers, no usable name) returns the shell unchanged, so the crawler
    path can never be worse than the existing static-shell behavior. Humans
    never reach here — the caller gates on the crawler User-Agent.

    `resolve_event` is injected (the app's `_resolve_event_with_filters`) so
    this module stays pure and app-import-free.
    """
    start = shell.find(SSR_META_START)
    end = shell.find(SSR_META_END)
    if start == -1 or end == -1 or end < start:
        return shell
    try:
        payload = resolve_event(
            event_id,
            {"section": None, "min_price": None, "max_price": None,
             "min_qty": None, "zones": None},
        )
    except Exception as e:  # noqa: BLE001 — never let SEO break the page
        print(f"[store_event_page] SSR meta fetch failed for {event_id}: {e!r}")
        return shell
    summary = event_seo_summary(payload)
    if not summary:
        return shell
    canonical = f"{base_url}/store/event/{event_id}"
    default_image = f"{base_url}{OG_DEFAULT_IMAGE}"
    tags = build_event_meta_tags(summary, canonical, default_image)
    return shell[:start] + tags + shell[end + len(SSR_META_END):]
