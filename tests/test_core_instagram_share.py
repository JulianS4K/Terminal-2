"""Full line-coverage tests for core/instagram_share.py — Instagram share-card
generation for Bands in Town tour dates. Pure functions, no I/O.
"""
from __future__ import annotations

from core import instagram_share as ig


# A realistic Bands in Town event (shape per /artists/:artist/events).
EVENT = {
    "url": "https://www.bandsintown.com/e/123",
    "datetime": "2026-08-08T19:00:00",
    "title": "The Body @ Music Hall of Williamsburg",
    "lineup": ["The Body", "BIG|BRAVE", "pSaLm"],
    "venue": {
        "name": "Music Hall of Williamsburg",
        "location": "Brooklyn, NY",
        "city": "Brooklyn",
        "region": "NY",
    },
}


# ---------- _esc ----------

def test_esc_escapes_xml_specials():
    assert ig._esc("AC/DC & <friends>") == "AC/DC &amp; &lt;friends&gt;"


# ---------- _fmt_datetime ----------

def test_fmt_datetime_pm():
    assert ig._fmt_datetime("2026-08-08T19:00:00") == ("August 8, 2026", "7:00 PM")


def test_fmt_datetime_midnight_and_noon():
    assert ig._fmt_datetime("2026-01-01T00:30:00") == ("January 1, 2026", "12:30 AM")
    assert ig._fmt_datetime("2026-01-01T12:00:00") == ("January 1, 2026", "12:00 PM")


def test_fmt_datetime_empty():
    assert ig._fmt_datetime("") == ("", "")
    assert ig._fmt_datetime(None) == ("", "")


def test_fmt_datetime_unparseable_returns_raw():
    assert ig._fmt_datetime("not-a-date") == ("not-a-date", "")


# ---------- parse_event ----------

def test_parse_event_full():
    p = ig.parse_event(EVENT)
    assert p["lineup"] == ["The Body", "BIG|BRAVE", "pSaLm"]
    assert p["headline"] == "The Body · BIG|BRAVE · pSaLm"
    assert p["venue"] == "Music Hall of Williamsburg"
    assert p["location"] == "Brooklyn, NY"
    assert p["date"] == "August 8, 2026"
    assert p["time"] == "7:00 PM"
    assert p["url"] == "https://www.bandsintown.com/e/123"


def test_parse_event_location_falls_back_to_city_region():
    p = ig.parse_event({"venue": {"name": "V", "city": "Austin", "region": "TX"}})
    assert p["location"] == "Austin, TX"


def test_parse_event_empty_lineup_uses_title():
    p = ig.parse_event({"title": "Solo Set", "lineup": []})
    assert p["headline"] == "Solo Set"


def test_parse_event_completely_empty_defaults():
    p = ig.parse_event(None)
    assert p["headline"] == "Live Show"
    assert p["lineup"] == []
    assert p["venue"] == ""
    assert p["location"] == ""
    assert p["url"] == ""


def test_parse_event_drops_falsy_lineup_entries():
    p = ig.parse_event({"lineup": ["A", "", None, "B"]})
    assert p["lineup"] == ["A", "B"]


# ---------- build_hashtags ----------

def test_build_hashtags_from_lineup_and_venue():
    tags = ig.build_hashtags(EVENT)
    assert "#TheBody" in tags
    assert "#BIGBRAVE" in tags  # non-alphanumerics stripped
    assert "#MusicHallofWilliamsburg" in tags
    assert tags[-1] == "#livemusic"


def test_build_hashtags_dedupes_case_insensitively():
    tags = ig.build_hashtags({"lineup": ["Live", "live"], "venue": {"name": "LIVE"}})
    # "Live"/"live"/"LIVE" collapse to one; generic #livemusic stays distinct.
    assert tags == ["#Live", "#livemusic"]


def test_build_hashtags_skips_unsluggable_names():
    tags = ig.build_hashtags({"lineup": ["!!!", "Foo"], "venue": {"name": "***"}})
    assert tags == ["#Foo", "#livemusic"]


# ---------- build_caption ----------

def test_build_caption_full():
    cap = ig.build_caption(EVENT)
    lines = cap.split("\n")
    assert lines[0] == "The Body · BIG|BRAVE · pSaLm"
    assert lines[1] == "Music Hall of Williamsburg · Brooklyn, NY"
    assert lines[2] == "August 8, 2026 · 7:00 PM"
    assert lines[3] == "🎟 https://www.bandsintown.com/e/123"
    assert lines[4].startswith("#")


def test_build_caption_minimal_only_headline_and_tag():
    cap = ig.build_caption({})
    assert cap == "Live Show\n#livemusic"


# ---------- build_share_card_svg ----------

def test_build_share_card_svg_contains_event_text_and_dims():
    svg = ig.build_share_card_svg(EVENT)
    assert svg.startswith("<svg")
    assert svg.endswith("</svg>")
    assert 'width="1080"' in svg and 'height="1080"' in svg
    assert "Music Hall of Williamsburg" in svg
    assert "August 8, 2026 · 7:00 PM" in svg
    # one bold line per act
    for act in ("The Body", "pSaLm"):
        assert act in svg


def test_build_share_card_svg_escapes_and_handles_special_chars():
    svg = ig.build_share_card_svg({"lineup": ["AC/DC & <Co>"], "venue": {"name": "R&B Hall"}})
    assert "AC/DC &amp; &lt;Co&gt;" in svg
    assert "R&amp;B Hall" in svg


def test_build_share_card_svg_custom_dimensions_story():
    svg = ig.build_share_card_svg(EVENT, width=1080, height=1920)
    assert 'height="1920"' in svg


def test_build_share_card_svg_empty_event_uses_headline_fallback():
    svg = ig.build_share_card_svg({})
    assert "Live Show" in svg


# ---------- _filename ----------

def test_filename_slugifies():
    assert ig._filename(EVENT) == "the-body-big-brave-psalm-august-8-2026.svg"


def test_filename_defaults_when_blank():
    assert ig._filename({"title": "!!!"}) == "tour-date.svg"


# ---------- build_event_share / build_tour_shares ----------

def test_build_event_share_bundle_keys():
    bundle = ig.build_event_share(EVENT)
    assert set(bundle) == {"svg", "caption", "hashtags", "url", "filename"}
    assert bundle["svg"].startswith("<svg")
    assert bundle["url"] == "https://www.bandsintown.com/e/123"
    assert bundle["filename"].endswith(".svg")


def test_build_tour_shares_maps_and_skips_falsy():
    # None and the empty dict are both falsy -> both dropped (documented).
    shares = ig.build_tour_shares([EVENT, None, {}, EVENT])
    assert len(shares) == 2
    assert all("caption" in s for s in shares)


def test_build_tour_shares_none_input():
    assert ig.build_tour_shares(None) == []
