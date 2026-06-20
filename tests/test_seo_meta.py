"""Tests for core/seo.py — server-side event metadata for link-unfurl + SEO
crawlers, plus the crawler User-Agent gate.

These are pure-function tests (no app, no Supabase, no TEvo). They lock in:
- the crawler UA gate (humans get the fast shell; bots get SSR meta),
- summary extraction from an /api/store/events/:id payload,
- escaping so an event name with quotes/markup can't break out of an
  attribute or the JSON-LD <script>, and
- the schema.org/Event JSON-LD shape Google reads.
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


def test_event_seo_summary_image_falls_back_to_chart():
    p = _payload()
    p["event"]["venue"].pop("hero_image_url")
    assert seo.event_seo_summary(p)["image_url"] == "https://img.example/chart.jpg"


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


def test_json_ld_is_valid_event_schema():
    s = seo.event_seo_summary(_payload())
    out = seo.build_event_meta_tags(s, "https://shop.example/store/event/4242", "https://shop.example/default.png")
    start = out.index('<script type="application/ld+json">') + len('<script type="application/ld+json">')
    end = out.index("</script>", start)
    data = json.loads(out[start:end])
    assert data["@type"] == "Event"
    assert data["name"] == "Knicks vs Celtics"
    assert data["startDate"] == "2026-06-21T19:30:00"
    assert data["location"]["name"] == "Madison Square Garden"
    assert data["location"]["address"]["addressLocality"] == "New York"
    assert data["offers"]["price"] == "145.00"
    assert data["offers"]["priceCurrency"] == "USD"


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
