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

Everything here is pure (no I/O, no app imports) so it unit-tests cleanly
and the route layer stays in app.py. The route fetches the event payload
(the same dict `/api/store/events/:id` returns), passes it through
`event_seo_summary`, and injects `build_event_meta_tags(...)` into the
HTML shell — gated on `is_link_crawler` so human page loads keep the fast
static-shell path.
"""
from __future__ import annotations

import html
import json
from datetime import datetime, timezone

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


def _esc(v) -> str:
    return html.escape(str(v), quote=True)


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
    t, d, u, img = _esc(title), _esc(desc), _esc(canonical_url), _esc(image)
    lines = [
        f"<title>{_esc(title)}</title>",
        f'<meta name="description" content="{d}" />',
        f'<meta property="og:type" content="event" />',
        f'<meta property="og:site_name" content="VibePass" />',
        f'<meta property="og:title" content="{t}" />',
        f'<meta property="og:description" content="{d}" />',
        f'<meta property="og:url" content="{u}" />',
        f'<meta property="og:image" content="{img}" />',
        f'<meta name="twitter:card" content="summary_large_image" />',
        f'<meta name="twitter:title" content="{t}" />',
        f'<meta name="twitter:description" content="{d}" />',
        f'<meta name="twitter:image" content="{img}" />',
        f'<link rel="canonical" href="{u}" />',
        _json_ld(summary, canonical_url, image),
    ]
    return "\n  ".join(lines)


def build_collection_meta_tags(
    summary: dict,
    canonical_url: str,
    default_image_url: str,
) -> str:
    """Build the `<head>` block for a COLLECTION landing page (performer or
    venue) listing upcoming events: title, description, Open Graph, Twitter,
    canonical, and schema.org JSON-LD (the entity + an ItemList of its events).

    `summary` keys: kind ('performer'|'venue'), name, subtitle (optional),
    count (int), image_url (optional), events (list of {name, url, date_iso}).
    All attribute values HTML-escaped; JSON-LD '<' escaped against breakout.
    """
    name = str(summary.get("name") or "").strip() or "VibePass"
    kind = summary.get("kind") or "performer"
    count = summary.get("count") or 0
    noun = "tour dates" if kind == "performer" else "events"
    title = f"{name} tickets · {count} upcoming {noun} · VibePass" if count \
        else f"{name} tickets · VibePass"
    where = summary.get("subtitle")
    desc = (
        f"Buy {name} tickets on VibePass — {count} upcoming {noun}"
        + (f" {where}" if where else "")
        + ". Direct-inventory seats, transparent all-in pricing, no daisy chains."
    )
    image = summary.get("image_url") or default_image_url
    t, d, u, img = _esc(title), _esc(desc), _esc(canonical_url), _esc(image)

    # schema.org: the entity (MusicGroup/SportsTeam fold to a generic Thing via
    # 'Organization' for performers, 'Place' for venues) + an ItemList of events.
    entity_type = "Place" if kind == "venue" else "PerformingGroup"
    items = []
    for i, ev in enumerate(summary.get("events") or [], start=1):
        ev_obj = {"@type": "Event", "name": ev.get("name"), "url": ev.get("url")}
        if ev.get("date_iso"):
            ev_obj["startDate"] = str(ev["date_iso"])
        items.append({"@type": "ListItem", "position": i, "item": ev_obj})
    ld = {
        "@context": "https://schema.org",
        "@type": "CollectionPage",
        "name": title,
        "url": canonical_url,
        "about": {"@type": entity_type, "name": name},
        "mainEntity": {"@type": "ItemList", "itemListElement": items},
    }
    raw = json.dumps(ld, ensure_ascii=False).replace("<", "\\u003c")
    lines = [
        f"<title>{_esc(title)}</title>",
        f'<meta name="description" content="{d}" />',
        f'<meta property="og:type" content="website" />',
        f'<meta property="og:site_name" content="VibePass" />',
        f'<meta property="og:title" content="{t}" />',
        f'<meta property="og:description" content="{d}" />',
        f'<meta property="og:url" content="{u}" />',
        f'<meta property="og:image" content="{img}" />',
        f'<meta name="twitter:card" content="summary_large_image" />',
        f'<meta name="twitter:title" content="{t}" />',
        f'<meta name="twitter:description" content="{d}" />',
        f'<meta name="twitter:image" content="{img}" />',
        f'<link rel="canonical" href="{u}" />',
        f'<script type="application/ld+json">{raw}</script>',
    ]
    return "\n  ".join(lines)
