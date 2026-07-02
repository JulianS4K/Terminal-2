"""Instagram share-card generation for artist tour dates (A1 backend).

Turns a Bands in Town event dict (see `bandsintown_client.get_artist_events`)
into shareable assets a surface can hand to a user to post on Instagram:

  - `build_share_card_svg(event)` — a square (1080×1080 by default) SVG
    announcement card (dependency-free vector; rasterize downstream if a PNG
    is needed).
  - `build_caption(event)` — the post caption (lineup · venue · when · link).
  - `build_hashtags(event)` — derived hashtags (lineup + venue + #livemusic).
  - `build_event_share(event)` — the bundle of all three + a filename hint.
  - `build_tour_shares(events)` — map a whole tour (list of events) to bundles.

This is OUTBOUND share-asset generation only — it never calls Instagram or
any external service, so it sits cleanly inside the RULE 2 read-only model.
Every public function accepts the raw Bands in Town event dict and normalizes
it internally via `parse_event`, so callers don't pre-shape anything.
"""
from __future__ import annotations

import re
from datetime import datetime
from typing import Any

_MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)


def _esc(text: Any) -> str:
    """Minimal XML escaping for text placed inside SVG <text> nodes."""
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def _fmt_datetime(dt_str: Any) -> tuple[str, str]:
    """Bands in Town `datetime` is local 'YYYY-MM-DDTHH:MM:SS'.

    Returns `(date, time)` e.g. ("August 8, 2026", "7:00 PM"). On an empty
    value returns ("", ""); on an unparseable value returns (raw, "") so the
    card still shows whatever the source gave us.
    """
    if not dt_str:
        return ("", "")
    try:
        dt = datetime.strptime(str(dt_str)[:19], "%Y-%m-%dT%H:%M:%S")
    except (ValueError, TypeError):
        return (str(dt_str), "")
    date_s = f"{_MONTHS[dt.month - 1]} {dt.day}, {dt.year}"
    hour12 = dt.hour % 12 or 12
    ampm = "AM" if dt.hour < 12 else "PM"
    return (date_s, f"{hour12}:{dt.minute:02d} {ampm}")


def parse_event(event: dict | None) -> dict[str, Any]:
    """Normalize a Bands in Town event dict into flat card fields."""
    event = event or {}
    venue = event.get("venue") or {}
    lineup = [str(a) for a in (event.get("lineup") or []) if a]
    location = venue.get("location")
    if not location:
        parts = [venue.get("city"), venue.get("region")]
        location = ", ".join(p for p in parts if p)
    date_s, time_s = _fmt_datetime(event.get("datetime"))
    headline = " · ".join(lineup) if lineup else (event.get("title") or "Live Show")
    return {
        "lineup": lineup,
        "headline": headline,
        "venue": venue.get("name") or "",
        "location": location or "",
        "date": date_s,
        "time": time_s,
        "url": event.get("url") or "",
    }


def build_hashtags(event: dict | None) -> list[str]:
    """Instagram hashtags from the lineup + venue, plus a generic anchor.

    Names are stripped to alphanumerics ("BIG|BRAVE" -> "#BIGBRAVE") and
    deduped case-insensitively while preserving order.
    """
    p = parse_event(event)
    raw = [*p["lineup"], p["venue"]]
    tags: list[str] = []
    for name in raw:
        slug = re.sub(r"[^0-9A-Za-z]", "", name)
        if slug:
            tags.append("#" + slug)
    tags.append("#livemusic")
    seen: set[str] = set()
    out: list[str] = []
    for t in tags:
        k = t.lower()
        if k not in seen:
            seen.add(k)
            out.append(t)
    return out


def build_caption(event: dict | None) -> str:
    """Ready-to-paste Instagram caption for a tour date."""
    p = parse_event(event)
    lines = [p["headline"]]
    venue_line = " · ".join(x for x in (p["venue"], p["location"]) if x)
    if venue_line:
        lines.append(venue_line)
    when = " · ".join(x for x in (p["date"], p["time"]) if x)
    if when:
        lines.append(when)
    if p["url"]:
        lines.append(f"🎟 {p['url']}")
    # build_hashtags always returns at least "#livemusic" — unconditional.
    lines.append(" ".join(build_hashtags(event)))
    return "\n".join(lines)


def build_share_card_svg(
    event: dict | None, *, width: int = 1080, height: int = 1080
) -> str:
    """Square SVG announcement card for a tour date.

    Dependency-free vector output — return it directly from an endpoint as
    `image/svg+xml`, or rasterize to PNG downstream for an Instagram post.
    """
    p = parse_event(event)
    parts: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" font-family="Helvetica, Arial, sans-serif">',
        f'<rect width="{width}" height="{height}" fill="#0b0b14"/>',
        f'<rect x="0" y="0" width="{width}" height="18" fill="#6c5ce7"/>',
        f'<text x="{width // 2}" y="170" fill="#9b8cff" font-size="44" '
        'font-weight="700" letter-spacing="14" text-anchor="middle">LIVE</text>',
    ]
    # Lineup block — one bold line per act (or the headline fallback).
    names = p["lineup"] or [p["headline"]]
    y = 340
    for name in names:
        parts.append(
            f'<text x="{width // 2}" y="{y}" fill="#ffffff" font-size="84" '
            f'font-weight="800" text-anchor="middle">{_esc(name)}</text>'
        )
        y += 110
    # Venue / location / when / url stack below the lineup.
    y = max(y + 40, 720)
    for text, size, color in (
        (p["venue"], 52, "#ffffff"),
        (p["location"], 40, "#b9b6cc"),
        (" · ".join(x for x in (p["date"], p["time"]) if x), 48, "#9b8cff"),
        (p["url"], 34, "#7a7790"),
    ):
        if text:
            parts.append(
                f'<text x="{width // 2}" y="{y}" fill="{color}" font-size="{size}" '
                f'text-anchor="middle">{_esc(text)}</text>'
            )
            y += size + 36
    parts.append("</svg>")
    return "".join(parts)


def _filename(event: dict | None) -> str:
    """A safe, lowercase slug filename hint for the share card."""
    p = parse_event(event)
    base = "-".join(x for x in (p["headline"], p["date"]) if x) or "tour-date"
    slug = re.sub(r"[^0-9a-z]+", "-", base.lower()).strip("-")
    return f"{slug or 'tour-date'}.svg"


def build_event_share(event: dict | None) -> dict[str, Any]:
    """Bundle every share asset for one tour date."""
    return {
        "svg": build_share_card_svg(event),
        "caption": build_caption(event),
        "hashtags": build_hashtags(event),
        "url": parse_event(event)["url"],
        "filename": _filename(event),
    }


def build_tour_shares(events: list[dict] | None) -> list[dict[str, Any]]:
    """Map a list of tour dates (e.g. `client.get_tour_dates(...)`) to bundles.

    `None`/falsy entries are skipped so a sparse upstream response is safe.
    """
    return [build_event_share(e) for e in (events or []) if e]
