"""Parser tests for broadway_client.

Asserts that _extract_inline_payload + _snapshot_from_payload correctly
read the canonical Django inline-JSON format that checkout.broadway.com
serves on /{slug}/{show_id}/{event_id}/sections/.

Fixture is a trimmed real capture; see tests/fixtures/checkout_sections_six.html.
No network calls — these tests are offline.
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest

from broadway_client import (
    BroadwayClient,
    BroadwayError,
    SECTIONS_PATH_RE,
)


FIXTURE = Path(__file__).parent / "fixtures" / "checkout_sections_six.html"


# ---------- URL parsing ----------

def test_parse_sections_url_round_trip():
    url = "https://checkout.broadway.com/six/12885/1077629/sections/"
    slug, show_id, event_id = BroadwayClient.parse_sections_url(url)
    assert (slug, show_id, event_id) == ("six", 12885, 1077629)
    assert BroadwayClient.sections_url(slug, show_id, event_id) == url


def test_parse_sections_url_rejects_wrong_host():
    with pytest.raises(BroadwayError):
        BroadwayClient.parse_sections_url(
            "https://www.broadway.com/six/12885/1077629/sections/"
        )


def test_parse_sections_url_rejects_wrong_path():
    with pytest.raises(BroadwayError):
        BroadwayClient.parse_sections_url(
            "https://checkout.broadway.com/six/12885/1077629/seats/"
        )


def test_sections_path_re_named_groups():
    m = SECTIONS_PATH_RE.match("/six/12885/1077629/sections/")
    assert m
    assert m.group("slug") == "six"
    assert m.group("show_id") == "12885"
    assert m.group("event_id") == "1077629"


# ---------- inline payload extraction ----------

def test_extract_inline_payload_finds_data():
    html = FIXTURE.read_text(encoding="utf-8")
    payload = BroadwayClient._extract_inline_payload(html)
    assert payload is not None
    assert payload["event_id"] == 1077629
    assert payload["event_status"] == 1
    assert payload["show"]["aristotle_id"] == 12885
    assert payload["show"]["slug"] == "six"
    assert payload["performance_time"] == "2026-05-14T19:00:00-04:00"
    # 15 distinct section/price-tier rows in the captured page
    assert len(payload["sections"]) == 15


def test_extract_inline_payload_skips_empty_init():
    """The page has both `var json = {};` and the data assignment; we
    must skip the empty one and return the populated payload."""
    html = (
        "<html><body><script>"
        "var json = {};\n"
        'json = {"status": 0, "data": {"event_id": 99, "show": {"aristotle_id": 1, "slug": "x"}, "sections": []}}.data;'
        "</script></body></html>"
    )
    payload = BroadwayClient._extract_inline_payload(html)
    assert payload is not None
    assert payload["event_id"] == 99


def test_extract_inline_payload_returns_none_when_absent():
    assert BroadwayClient._extract_inline_payload("<html><body>nope</body></html>") is None


# ---------- snapshot construction ----------

def _build_snapshot():
    html = FIXTURE.read_text(encoding="utf-8")
    payload = BroadwayClient._extract_inline_payload(html)
    assert payload is not None
    return BroadwayClient._snapshot_from_payload(
        slug="six",
        show_id=12885,
        event_id=1077629,
        payload=payload,
        captured_at=datetime.now(timezone.utc).isoformat(),
        source_url="https://checkout.broadway.com/six/12885/1077629/sections/",
        keep_raw=False,
    )


def test_snapshot_show_metadata():
    snap = _build_snapshot()
    assert snap.show is not None
    assert snap.show.title == "SIX"
    assert snap.show.bwy_title == "SIX: The Musical"
    assert snap.show.venue_name == "Lena Horne Theatre"
    assert snap.show.venue_state == "NY"
    assert snap.show.opening_date == "2021-10-03"
    assert snap.show.high_price == 373.24
    assert snap.show.pricing == 72.42
    assert snap.show.max_discount_amount == 61.0
    assert snap.show.has_discount_events is True
    assert snap.show.on_sale is True
    assert "Broadway" in snap.show.categories
    assert "Musicals" in snap.show.categories
    assert "Kirstin Maldonado" in (snap.show.announcement or "")


def test_snapshot_sections_shape():
    snap = _build_snapshot()
    assert len(snap.sections) == 15
    # The Premium-Mezzanine row at $199 with quantities [1..5]
    premium_mezz = next(
        s for s in snap.sections
        if s.name == "Mezzanine" and s.ticket_type == "Premium"
    )
    assert premium_mezz.price == 199.0
    assert premium_mezz.fee == 77.11
    assert premium_mezz.quantities == [1, 2, 3, 4, 5]
    assert premium_mezz.area_indexes == [2]
    assert premium_mezz.price_index == 211801
    # all_in convenience
    assert premium_mezz.all_in == pytest.approx(276.11)
    assert premium_mezz.available is True


def test_snapshot_top_level_fields():
    snap = _build_snapshot()
    assert snap.event_id == 1077629
    assert snap.show_id == 12885
    assert snap.performance_time == "2026-05-14T19:00:00-04:00"
    assert snap.event_status == 1
    assert snap.scatter_available is True
    assert snap.inquiry_type_id == 4
    assert snap.alerts == []
    # Aggregated bands
    assert len(snap.areas) == 2
    assert {a.name for a in snap.areas} == {"Orchestra", "Mezzanine"}
    assert len(snap.premium_areas) == 2
    assert len(snap.types) == 2
    assert {t.name for t in snap.types} == {"Premium", "Standard"}


def test_section_listing_available_flag():
    """A section with empty quantities[] should be marked unavailable."""
    from broadway_client import SectionListing
    sold_out = SectionListing(
        name="Box", price=300.0, fee=50.0, ticket_type="Premium",
        quantities=[], price_ids=[], area_indexes=[1],
    )
    assert sold_out.available is False
    assert sold_out.all_in == 350.0


# ---------- RULE 2: read-only ----------

def test_assert_readonly_raises_on_post():
    from broadway_client import _assert_readonly_method
    with pytest.raises(BroadwayError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)
    assert "RULE 2" in str(exc.value)


def test_assert_readonly_allows_get():
    from broadway_client import _assert_readonly_method
    _assert_readonly_method("GET")  # must not raise
