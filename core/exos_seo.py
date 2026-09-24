"""Server-side link previews for the Exos SPA (/bridge/*, D4; source in JulianS4K/EXP).

Why: Exos sells through Instagram bios, stories, WhatsApp and iMessage, and the
unfurl bots behind those (facebookexternalhit, WhatsApp, Applebot, Twitterbot,
...) don't run JavaScript. The SPA sets per-event tags client-side
(EXP src/lib/meta.ts), so every shared Exos link unfurled as the generic "Exos"
card. core/seo.py solved this for /store; this module does the same for the
Exos routes, reusing its crawler gate.

Pure: no app imports and no I/O. The route (routers/pages.py) gates on
is_link_crawler, picks a target with `preview_target`, calls an injected
resolver for the data, and splices `build_tags` output between the
SSR_META markers in the SPA's index.html. Any failure returns the shell
unchanged, so a crawler never sees less than today's static card.
"""
from __future__ import annotations

import html
import json
import math
import re
from datetime import datetime, timezone
from urllib.parse import parse_qs

from core.seo import SSR_META_END, SSR_META_START

_UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
_SLUG = r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}"
_EVENT_RE = re.compile(rf"^event/({_UUID})/?$")
_EVENT_SLUG_RE = re.compile(rf"^e/({_SLUG})/?$")
_ORG_RE = re.compile(rf"^o/({_SLUG})/?$")
_PROMOTER_RE = re.compile(rf"^promoter/({_UUID})/[A-Za-z0-9_-]{{1,64}}/?$")
# Promoter link-in-bio (/l/:orgSlug/:code) previews as the organizer.
_BIO_RE = re.compile(rf"^l/({_SLUG})/[A-Za-z0-9_-]{{1,64}}/?$")
_UUID_RE = re.compile(rf"^{_UUID}$")


def preview_target(page: str, query: str = "") -> tuple[str, str] | None:
    """Which record a /bridge/<page>?<query> link previews, or None.

    ("event", id) · ("event_slug", slug) · ("org", slug) · ("promoter", event_id)
    · ("checkout_event", event_id) · ("checkout_tier", tier_id).
    """
    if m := _EVENT_RE.match(page):
        return ("event", m.group(1).lower())
    if m := _EVENT_SLUG_RE.match(page):
        return ("event_slug", m.group(1))
    if m := _ORG_RE.match(page) or _BIO_RE.match(page):
        return ("org", m.group(1))
    if m := _PROMOTER_RE.match(page):
        return ("promoter", m.group(1).lower())
    if page.rstrip("/") == "checkout":
        q = parse_qs(query or "")
        ev = (q.get("event") or [""])[0]
        if _UUID_RE.match(ev):
            return ("checkout_event", ev.lower())
        first = ((q.get("products") or [""])[0].split(",")[0]).split(":")[0].strip()
        if _UUID_RE.match(first):
            return ("checkout_tier", first.lower())
    return None


def _effective_price(base: float, schedule, now: datetime) -> float:
    """Mirror of EXP src/lib/pricing.ts effectiveTierPrice (latest started step)."""
    price = base
    if isinstance(schedule, list):
        steps = []
        for st in schedule:
            if not isinstance(st, dict):
                continue
            p, at = st.get("price"), st.get("startsAt")
            if not isinstance(p, (int, float)) or p < 0 or not isinstance(at, str):
                continue
            try:
                t = datetime.fromisoformat(at.replace("Z", "+00:00"))
            except ValueError:
                continue
            if t.tzinfo is None:
                t = t.replace(tzinfo=timezone.utc)
            steps.append((t, float(p)))
        for t, p in sorted(steps):
            if t <= now:
                price = p
    return price


def _js_round(x: float) -> int:
    """JavaScript Math.round (halves up), so cents match the storefront; Python's
    round() is banker's rounding and would differ by a cent on .5."""
    return int(math.floor(x + 0.5))


def from_price_cents(tiers: list[dict], now: datetime | None = None) -> int | None:
    """Lowest all-in (price + exclusive tax) tier price in cents, matching what
    the storefront shows. None when there are no tiers."""
    now = now or datetime.now(timezone.utc)
    best = None
    for t in tiers or []:
        try:
            base = float(t.get("price") or 0)
        except (TypeError, ValueError):
            continue
        unit = _js_round(_effective_price(base, t.get("price_schedule"), now) * 100)
        rate = float(t.get("exclusive_tax_percent") or 0)
        all_in = unit + _js_round(unit * rate / 100)
        best = all_in if best is None else min(best, all_in)
    return best


def _money(cents: int, currency: str) -> str:
    if cents == 0:
        return "Free"
    sym = {"USD": "$", "EUR": "€", "GBP": "£", "CAD": "CA$", "AUD": "A$"}.get((currency or "USD").upper())
    amount = f"{cents / 100:,.2f}".replace(".00", "")
    return f"{sym}{amount}" if sym else f"{amount} {(currency or '').upper()}"


def _date_label(starts_at: str | None, local: str | None) -> str | None:
    """Prefer the event's local wall-clock time (what the organizer typed)."""
    raw = local or starts_at
    if not raw:
        return None
    try:
        d = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d.strftime("%a %b %-d · %-I:%M %p").replace(":00 ", " ")


def event_summary(event: dict, tiers: list[dict], org: dict | None = None) -> dict | None:
    """Normalize a public event row (+ its public tiers, + its org) for tags."""
    name = (event or {}).get("name")
    if not name:
        return None
    addr = event.get("venue_address") if isinstance(event.get("venue_address"), dict) else {}
    cents = from_price_cents(tiers)
    return {
        "id": event.get("id"),
        "name": str(name)[:200],
        "date": _date_label(event.get("starts_at"), event.get("occurs_at_local")),
        "starts_at": event.get("starts_at"),
        "venue": (event.get("venue_name") or event.get("venue_location") or "")[:200] or None,
        "city": addr.get("city"),
        "region": addr.get("region"),
        "street": addr.get("street"),
        "image": event.get("image_url"),
        "description": (event.get("description") or "")[:300],
        "from": _money(cents, event.get("currency") or "USD") if cents is not None else None,
        "from_cents": cents,
        "currency": (event.get("currency") or "USD").upper(),
        "org_name": (org or {}).get("name"),
    }


def _esc(v) -> str:
    return html.escape(str(v), quote=True)


def _tags(title: str, desc: str, url: str, image: str, og_type: str, noindex: bool, extra: str = "") -> str:
    t, d, u, img = _esc(title), _esc(desc), _esc(url), _esc(image)
    lines = [
        f"<title>{t}</title>",
        f'<meta name="description" content="{d}" />',
        f'<meta name="robots" content="{"noindex, nofollow" if noindex else "index, follow"}" />',
        '<meta property="og:site_name" content="Exos" />',
        f'<meta property="og:type" content="{og_type}" />',
        f'<meta property="og:title" content="{t}" />',
        f'<meta property="og:description" content="{d}" />',
        f'<meta property="og:url" content="{u}" />',
        f'<meta property="og:image" content="{img}" />',
        '<meta property="og:locale" content="en_US" />',
        '<meta name="twitter:card" content="summary_large_image" />',
        f'<meta name="twitter:title" content="{t}" />',
        f'<meta name="twitter:description" content="{d}" />',
        f'<meta name="twitter:image" content="{img}" />',
        f'<link rel="canonical" href="{u}" />',
    ]
    if extra:
        lines.append(extra)
    return "\n    ".join(lines)


def event_tags(s: dict, canonical_url: str, default_image: str, noindex: bool = False) -> str:
    """Per-event preview: '<name>' / 'Fri Oct 3 · 10 PM · Elsewhere · from $25 all-in'."""
    bits = [b for b in (s.get("date"), s.get("venue"), f"from {s['from']} all-in" if s.get("from") and s["from"] != "Free" else ("Free" if s.get("from") == "Free" else None)) if b]
    desc = " · ".join(bits) or (s.get("description") or "Tickets on Exos")
    image = s.get("image") or default_image
    ld = {
        "@context": "https://schema.org",
        "@type": "Event",
        "name": s["name"],
        "url": canonical_url,
        "image": [image],
        "eventStatus": "https://schema.org/EventScheduled",
        "eventAttendanceMode": "https://schema.org/OfflineEventAttendanceMode",
    }
    if s.get("starts_at"):
        ld["startDate"] = s["starts_at"]
    if s.get("venue"):
        loc = {"@type": "Place", "name": s["venue"]}
        addr = {k: v for k, v in (("streetAddress", s.get("street")), ("addressLocality", s.get("city")), ("addressRegion", s.get("region"))) if v}
        if addr:
            addr["@type"] = "PostalAddress"
            loc["address"] = addr
        ld["location"] = loc
    if s.get("org_name"):
        ld["organizer"] = {"@type": "Organization", "name": s["org_name"]}
    if s.get("from_cents") is not None:
        ld["offers"] = {
            "@type": "Offer", "url": canonical_url,
            "price": f"{s['from_cents'] / 100:.2f}", "priceCurrency": s.get("currency") or "USD",
            "availability": "https://schema.org/InStock",
        }
    raw = json.dumps(ld, ensure_ascii=False).replace("<", "\\u003c")
    extra = "" if noindex else f'<script type="application/ld+json">{raw}</script>'
    return _tags(s["name"], desc, canonical_url, image, "event", noindex, extra)


def org_tags(org: dict, canonical_url: str, default_image: str) -> str | None:
    name = (org or {}).get("name")
    if not name:
        return None
    marketing = org.get("marketing") if isinstance(org.get("marketing"), dict) else {}
    theme = org.get("theme") if isinstance(org.get("theme"), dict) else {}
    image = marketing.get("shareImageUrl") or theme.get("logoUrl") or default_image
    desc = (org.get("description") or f"Upcoming events from {name}.")[:300]
    return _tags(str(name)[:200], desc, canonical_url, image, "website", False)


def inject(shell: str, tags: str | None) -> str:
    """Swap the SSR_META block in the SPA shell for `tags`; no-op on any miss."""
    if not tags:
        return shell
    start = shell.find(SSR_META_START)
    end = shell.find(SSR_META_END)
    if start == -1 or end == -1 or end < start:
        return shell
    return shell[:start] + tags + shell[end + len(SSR_META_END):]


def build_preview(sb, target: tuple[str, str], base_url: str) -> str | None:
    """Resolve a preview target against the PUBLIC views (published events,
    public orgs only) and return the tag block. `sb` is a supabase-py client;
    only .table().select().eq()/in_().limit().execute() are used, so tests can
    pass a fake. Returns None on anything unexpected."""
    kind, key = target
    default_image = f"{base_url}/bridge/icon-512.png"

    def rows(table: str, cols: str, col: str, val: str, limit: int = 1) -> list[dict]:
        res = sb.table(table).select(cols).eq(col, val).limit(limit).execute()
        return list(getattr(res, "data", None) or [])

    if kind == "org":
        orgs = rows("exos_public_orgs", "id,name,slug,theme,description,marketing", "slug", key)
        if not orgs:
            return None
        return org_tags(orgs[0], f"{base_url}/bridge/o/{orgs[0]['slug']}", default_image)

    event_cols = ("id,org_id,name,slug,description,occurs_at_local,starts_at,timezone,currency,"
                  "venue_name,venue_location,venue_address,image_url")
    if kind == "checkout_tier":
        tiers = rows("exos_public_tiers", "event_id", "id", key)
        if not tiers:
            return None
        kind, key = "event", tiers[0]["event_id"]
    if kind == "event_slug":
        events = rows("exos_public_events", event_cols, "slug", key)
    else:
        events = rows("exos_public_events", event_cols, "id", key)
    if not events:
        return None
    ev = events[0]
    tiers = rows("exos_public_tiers", "price,price_schedule,exclusive_tax_percent", "event_id", ev["id"], 50)
    orgs = rows("exos_public_orgs", "name", "id", ev["org_id"]) if ev.get("org_id") else []
    s = event_summary(ev, tiers, orgs[0] if orgs else None)
    if not s:
        return None
    # Checkout and promoter links preview the event but point search engines
    # at the event page, and promoter kits stay out of the index.
    canonical = f"{base_url}/bridge/event/{ev['id']}"
    return event_tags(s, canonical, default_image, noindex=(target[0] == "promoter"))
