"""Tests for core/seo.py — server-side event metadata for link-unfurl + SEO
crawlers, the crawler User-Agent gate, and the shell-injection splice.

These are pure-function tests (no app, no Supabase, no TEvo). They lock in:
- the crawler UA gate (humans get the fast shell; bots get SSR meta),
- summary extraction from an /api/store/events/:id payload,
- date formatting edge cases,
- escaping so an event name with quotes/markup can't break out of an
  attribute or the JSON-LD <script>,
- the schema.org/Event JSON-LD shape Google reads, and
- inject_event_meta's marker/fallback/success branches.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import seo  # noqa: E402


def _payload():
    return {
        "event": {
            "id": 4242,
            "name": "Knicks vs Celtics",
            "occurs_at_local": "2026-06-21T19:30:00",
            "venue": {
                "name": "Madison Square Garden",
                "city": "New York",
                "state": "NY",
                "hero_image_url": "https://img.example/msg-hero.jpg",
            },
            "configuration": {"seating_chart_large": "https://img.example/chart.jpg"},
        },
        "listings": [
            {"price": 320.0},
            {"price": 145.0},
            {"price": 0},        # ignored (not > 0)
            {"price": None},     # ignored
            "not-a-dict",        # ignored (defensive)
        ],
    }


# ---- crawler gate ----

def test_is_link_crawler_matches_known_bots():
    for ua in [
        "facebookexternalhit/1.1",
        "Twitterbot/1.0",
        "Mozilla/5.0 (compatible; Googlebot/2.1)",
        "WhatsApp/2.23",
        "TikTok 30.1.0 rv:301",
        "Slackbot-LinkExpanding 1.0",
    ]:
        assert seo.is_link_crawler(ua) is True, ua


def test_is_link_crawler_rejects_humans_and_empty():
    assert seo.is_link_crawler(None) is False
    assert seo.is_link_crawler("") is False
    assert seo.is_link_crawler(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Safari/605.1.15"
    ) is False


# ---- date formatting edge cases ----

def test_fmt_event_date_variants():
    assert seo._fmt_event_date(None) is None
    # Has a time component -> includes the time suffix.
    assert seo._fmt_event_date("2026-06-21T19:30:00") == "Sun, Jun 21 · 7:30 PM"
    # Midnight -> date only (no 12:00 AM noise).
    assert seo._fmt_event_date("2026-06-21T00:00:00") == "Sun, Jun 21"
    # Trailing 'Z' is normalized to an offset and still parses.
    assert seo._fmt_event_date("2026-06-21T19:30:00Z") == "Sun, Jun 21 · 7:30 PM"
    # Unparseable-in-full but a valid date prefix -> date-only fallback.
    assert seo._fmt_event_date("2026-06-21 (rescheduled)") == "Sun, Jun 21"
    # Fully unparseable -> None so the caller omits the date fragment.
    assert seo._fmt_event_date("someday soon") is None


# ---- summary extraction ----

def test_event_seo_summary_extracts_fields_and_min_price():
    s = seo.event_seo_summary(_payload())
    assert s is not None
    assert s["name"] == "Knicks vs Celtics"
    assert s["venue_name"] == "Madison Square Garden"
    assert s["city"] == "New York" and s["state"] == "NY"
    assert s["from_price"] == 145.0          # cheapest positive listing
    assert s["image_url"] == "https://img.example/msg-hero.jpg"  # hero preferred


def test_event_seo_summary_none_without_name():
    assert seo.event_seo_summary({"event": {"name": "   "}}) is None
    assert seo.event_seo_summary({}) is None
    assert seo.event_seo_summary("nope") is None


def test_event_seo_summary_image_falls_back_to_chart_large():
    p = _payload()
    p["event"]["venue"].pop("hero_image_url")
    assert seo.event_seo_summary(p)["image_url"] == "https://img.example/chart.jpg"


def test_event_seo_summary_image_falls_back_to_chart_medium():
    p = _payload()
    p["event"]["venue"].pop("hero_image_url")
    p["event"]["configuration"] = {"seating_chart_medium": "https://img.example/med.jpg"}
    assert seo.event_seo_summary(p)["image_url"] == "https://img.example/med.jpg"


def test_event_seo_summary_no_image_no_price_blank_venue_fields():
    # No venue image, no charts -> image None; no listings -> from_price None;
    # blank venue name/city/state -> those fields None; occurs_at fallback used.
    p = {
        "event": {
            "id": 9,
            "name": "Open Mic Night",
            "occurs_at": "2026-07-04T20:00:00",
            "venue": {"name": "  ", "city": "", "state": ""},
            "configuration": {},
        },
        "listings": [],
    }
    s = seo.event_seo_summary(p)
    assert s["image_url"] is None
    assert s["from_price"] is None
    assert s["venue_name"] is None and s["city"] is None and s["state"] is None
    assert s["date_iso"] == "2026-07-04T20:00:00"   # occurs_at fallback


# ---- tag building ----

def test_build_event_meta_tags_has_core_tags():
    s = seo.event_seo_summary(_payload())
    out = seo.build_event_meta_tags(
        s, "https://shop.example/store/event/4242", "https://shop.example/static/store/og-default.svg"
    )
    assert "<title>Knicks vs Celtics tickets · Madison Square Garden" in out
    assert 'property="og:title"' in out
    assert 'property="og:url" content="https://shop.example/store/event/4242"' in out
    assert 'property="og:image" content="https://img.example/msg-hero.jpg"' in out
    assert 'name="twitter:card" content="summary_large_image"' in out
    assert 'rel="canonical" href="https://shop.example/store/event/4242"' in out
    assert "from $145" in out  # description carries the price


def test_build_event_meta_tags_uses_default_image_when_missing():
    s = seo.event_seo_summary(_payload())
    s["image_url"] = None
    out = seo.build_event_meta_tags(s, "https://shop.example/store/event/1", "https://shop.example/default.png")
    assert 'og:image" content="https://shop.example/default.png"' in out


def test_build_tags_minimal_summary_no_venue_date_or_price():
    # Exercises the omit-branches: no venue name, no date, no price.
    s = {
        "id": 5, "name": "Mystery Show", "venue_name": None,
        "city": None, "state": None, "date_iso": None, "from_price": None,
        "image_url": None,
    }
    out = seo.build_event_meta_tags(s, "https://shop.example/store/event/5", "https://shop.example/default.png")
    assert "<title>Mystery Show tickets · VibePass</title>" in out
    # description falls back to "the venue" and carries no price fragment.
    assert "at the venue on VibePass" in out
    assert "from $" not in out
    data = _extract_json_ld(out)
    assert "startDate" not in data
    assert "location" not in data     # no name + no address -> location omitted
    assert "offers" not in data


def test_description_uses_city_state_when_no_venue_name():
    s = {
        "id": 6, "name": "Fair", "venue_name": None,
        "city": "Austin", "state": "TX", "date_iso": None, "from_price": None,
        "image_url": None,
    }
    out = seo.build_event_meta_tags(s, "https://shop.example/store/event/6", "https://shop.example/d.png")
    assert "at Austin, TX on VibePass" in out


def _extract_json_ld(out: str) -> dict:
    start = out.index('<script type="application/ld+json">') + len('<script type="application/ld+json">')
    end = out.index("</script>", start)
    return json.loads(out[start:end])


def test_json_ld_is_valid_event_schema():
    s = seo.event_seo_summary(_payload())
    out = seo.build_event_meta_tags(s, "https://shop.example/store/event/4242", "https://shop.example/default.png")
    data = _extract_json_ld(out)
    assert data["@type"] == "Event"
    assert data["name"] == "Knicks vs Celtics"
    assert data["startDate"] == "2026-06-21T19:30:00"
    assert data["location"]["name"] == "Madison Square Garden"
    assert data["location"]["address"]["addressLocality"] == "New York"
    assert data["offers"]["price"] == "145.00"
    assert data["offers"]["priceCurrency"] == "USD"


def test_json_ld_location_from_address_only():
    # No venue name, but city/state present -> location built from address only.
    s = {
        "id": 7, "name": "Rodeo", "venue_name": None,
        "city": "Houston", "state": "TX", "date_iso": None, "from_price": None,
        "image_url": None,
    }
    out = seo.build_event_meta_tags(s, "https://shop.example/store/event/7", "https://shop.example/d.png")
    data = _extract_json_ld(out)
    assert data["location"]["address"]["addressRegion"] == "TX"
    assert "name" not in data["location"]


def test_escaping_prevents_attribute_and_script_breakout():
    p = _payload()
    p["event"]["name"] = 'Hack" /><script>alert(1)</script>'
    s = seo.event_seo_summary(p)
    out = seo.build_event_meta_tags(s, "https://shop.example/store/event/9", "https://shop.example/default.png")
    # No raw closing-script or unescaped attribute-breaking quote+bracket.
    assert "</script><script>" not in out
    assert '"/><script>' not in out
    assert "&quot;" in out  # the quote was escaped in attribute context
    # JSON-LD escaped the '<' so it can't terminate the script element early.
    assert "\\u003cscript" in out


# ---- inject_event_meta (shell splice + defensive branches) ----

_SHELL = (
    "<head>\n"
    f"  {seo.SSR_META_START}\n"
    "  <title>VibePass — event tickets</title>\n"
    '  <link rel="canonical" href="" />\n'
    f"  {seo.SSR_META_END}\n"
    "</head>"
)


def test_inject_replaces_block_for_resolvable_event():
    out = seo.inject_event_meta(_SHELL, 4242, "https://shop.example", lambda eid, f: _payload())
    assert seo.SSR_META_START not in out
    assert "VibePass — event tickets" not in out
    assert "<title>Knicks vs Celtics tickets" in out
    assert 'og:url" content="https://shop.example/store/event/4242"' in out
    # default image path is derived from base_url + OG_DEFAULT_IMAGE when the
    # payload has no image; here the payload DOES carry a hero image.
    assert "https://img.example/msg-hero.jpg" in out


def test_inject_uses_default_image_path_from_base_url():
    p = _payload()
    p["event"]["venue"].pop("hero_image_url")
    p["event"]["configuration"] = {}
    out = seo.inject_event_meta(_SHELL, 1, "https://shop.example", lambda eid, f: p)
    assert f'content="https://shop.example{seo.OG_DEFAULT_IMAGE}"' in out


def test_inject_returns_shell_when_markers_missing():
    assert seo.inject_event_meta("<head></head>", 1, "b", lambda e, f: _payload()) == "<head></head>"
    only_start = f"<head>{seo.SSR_META_START}</head>"
    assert seo.inject_event_meta(only_start, 1, "b", lambda e, f: _payload()) == only_start
    reversed_markers = f"{seo.SSR_META_END}...{seo.SSR_META_START}"
    assert seo.inject_event_meta(reversed_markers, 1, "b", lambda e, f: _payload()) == reversed_markers


def test_inject_falls_back_when_resolver_raises(capsys):
    def _boom(eid, f):
        raise RuntimeError("TEvo down")
    out = seo.inject_event_meta(_SHELL, 77, "https://shop.example", _boom)
    assert out == _SHELL  # unchanged shell
    assert "SSR meta fetch failed" in capsys.readouterr().out


def test_inject_falls_back_when_no_usable_summary():
    # Resolver returns a payload with no event name -> summary None -> shell kept.
    out = seo.inject_event_meta(_SHELL, 5, "https://shop.example", lambda eid, f: {"event": {}})
    assert out == _SHELL
