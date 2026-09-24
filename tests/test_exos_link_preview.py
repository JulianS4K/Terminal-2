"""Exos /bridge link previews for unfurl bots (core/exos_seo.py, D4-OPS-38)."""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_TOKEN", "test-token")
os.environ.setdefault("TEVO_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import exos_seo  # noqa: E402

EV = "11111111-1111-4111-8111-111111111111"
TIER = "22222222-2222-4222-8222-222222222222"


@pytest.mark.parametrize("page,query,expected", [
    (f"event/{EV}", "", ("event", EV)),
    (f"event/{EV.upper()}/", "", ("event", EV)),
    ("e/fall-party", "", ("event_slug", "fall-party")),
    ("o/brooklyn-nights", "", ("org", "brooklyn-nights")),
    (f"promoter/{EV}/dj-kay", "", ("promoter", EV)),
    ("checkout", f"event={EV}&products={TIER}:2", ("checkout_event", EV)),
    ("checkout", f"products={TIER}%3A2%2C{EV}%3A1", ("checkout_tier", TIER)),
    ("checkout", "products=junk", None),
    ("my-tickets", "", None),
    ("event/not-a-uuid", "", None),
    ("o/../../etc", "", None),
])
def test_preview_target(page, query, expected):
    assert exos_seo.preview_target(page, query) == expected


def test_from_price_is_all_in_and_follows_the_schedule():
    now = datetime(2026, 10, 1, tzinfo=timezone.utc)
    tiers = [
        {"price": 30, "price_schedule": [{"startsAt": "2026-09-01T00:00:00Z", "price": 20}], "exclusive_tax_percent": 8.875},
        {"price": 50, "price_schedule": None, "exclusive_tax_percent": 0},
    ]
    # $20 early-bird is live; + 8.875% tax = 2000 + Math.round(177.5) = 2178.
    assert exos_seo.from_price_cents(tiers, now) == 2178
    # Halves round up like the storefront (Python's round(176.5) would give 176).
    assert exos_seo.from_price_cents([{"price": 17.65, "exclusive_tax_percent": 10}], now) == 1765 + 177
    assert exos_seo.from_price_cents([], now) is None
    assert exos_seo.from_price_cents([{"price": 0}], now) == 0


def _summary(**over):
    ev = {"id": EV, "name": 'DJ "Kay" <live>', "starts_at": "2026-10-03T02:00:00Z",
          "occurs_at_local": "2026-10-02T22:00:00", "venue_name": "Elsewhere",
          "venue_address": {"city": "Brooklyn", "region": "NY"}, "image_url": "https://img.example/p.jpg",
          "currency": "USD"}
    ev.update(over)
    return exos_seo.event_summary(ev, [{"price": 25, "exclusive_tax_percent": 0}], {"name": "Brooklyn Nights"})


def test_event_tags_escape_and_describe():
    tags = exos_seo.event_tags(_summary(), f"https://x.example/bridge/event/{EV}", "https://x.example/bridge/icon-512.png")
    assert "<live>" not in tags.split("application/ld+json")[0]
    assert "DJ &quot;Kay&quot; &lt;live&gt;" in tags
    assert "Fri Oct 2 · 10 PM · Elsewhere · from $25 all-in" in tags or "Elsewhere · from $25 all-in" in tags
    assert 'og:image" content="https://img.example/p.jpg"' in tags
    assert '"@type": "Event"' in tags and "\\u003clive>" in tags
    assert "index, follow" in tags


def test_promoter_preview_is_noindex_without_json_ld():
    tags = exos_seo.event_tags(_summary(), "https://x.example/e", "https://x.example/i.png", noindex=True)
    assert "noindex, nofollow" in tags and "application/ld+json" not in tags


def test_inject_needs_markers():
    shell = "<head><!-- SSR_META_START --><title>x</title><!-- SSR_META_END --></head>"
    assert exos_seo.inject(shell, "<title>y</title>") == "<head><title>y</title></head>"
    assert exos_seo.inject("<head></head>", "<title>y</title>") == "<head></head>"
    assert exos_seo.inject(shell, None) == shell


class _FakeSB:
    def __init__(self, data):
        self.data = data

    def table(self, name):
        rows = self.data.get(name, [])
        q = SimpleNamespace()
        filt = {}

        def select(_cols):
            return q

        def eq(col, val):
            filt[col] = val
            return q

        def limit(_n):
            return q

        def execute():
            return SimpleNamespace(data=[r for r in rows if all(r.get(k) == v for k, v in filt.items())])

        q.select, q.eq, q.limit, q.execute = select, eq, limit, execute
        return q


def _sb():
    return _FakeSB({
        "exos_public_events": [{"id": EV, "org_id": "o1", "name": "Fall Party", "slug": "fall-party",
                                "starts_at": "2026-10-03T02:00:00Z", "venue_name": "Elsewhere", "currency": "USD"}],
        "exos_public_tiers": [{"id": TIER, "event_id": EV, "price": 25, "exclusive_tax_percent": 0}],
        "exos_public_orgs": [{"id": "o1", "name": "Brooklyn Nights", "slug": "bk-nights", "description": "Parties."}],
    })


def test_build_preview_resolves_every_target_kind():
    base = "https://x.example"
    assert "Fall Party" in exos_seo.build_preview(_sb(), ("event", EV), base)
    assert "Fall Party" in exos_seo.build_preview(_sb(), ("event_slug", "fall-party"), base)
    checkout = exos_seo.build_preview(_sb(), ("checkout_tier", TIER), base)
    assert f'canonical" href="{base}/bridge/event/{EV}"' in checkout
    assert "noindex" in exos_seo.build_preview(_sb(), ("promoter", EV), base)
    assert "Brooklyn Nights" in exos_seo.build_preview(_sb(), ("org", "bk-nights"), base)
    assert exos_seo.build_preview(_sb(), ("event", "33333333-3333-4333-8333-333333333333"), base) is None


# ---- route: only crawlers get the server-side preview ----------------------

pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

import server as app_module  # noqa: E402

SHELL = "<html><head><!-- SSR_META_START --><title>Exos</title><!-- SSR_META_END --></head><body></body></html>"


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    (tmp_path / "index.html").write_text(SHELL, encoding="utf-8")
    monkeypatch.setattr(app_module, "_BRIDGE_DIR", str(tmp_path))
    monkeypatch.setattr(app_module, "_exos_link_preview",
                        lambda page, query: "<title>Fall Party</title>" if page.startswith("event/") else None)
    return TestClient(app_module.app)


def test_crawler_gets_the_event_preview(bridge):
    r = bridge.get(f"/bridge/event/{EV}", headers={"user-agent": "facebookexternalhit/1.1"})
    assert r.status_code == 200 and "<title>Fall Party</title>" in r.text and "SSR_META" not in r.text


def test_human_gets_the_plain_shell(bridge):
    r = bridge.get(f"/bridge/event/{EV}", headers={"user-agent": "Mozilla/5.0 (iPhone) Safari"})
    assert r.status_code == 200 and "<title>Exos</title>" in r.text


def test_crawler_on_a_page_without_preview_gets_the_shell(bridge):
    r = bridge.get("/bridge/my-tickets", headers={"user-agent": "WhatsApp/2.23"})
    assert "<title>Exos</title>" in r.text


def test_preview_errors_fall_back_to_the_shell(bridge, monkeypatch):
    def boom(page, query):
        raise RuntimeError("db down")
    monkeypatch.setattr(app_module, "_exos_link_preview", boom)
    r = bridge.get(f"/bridge/event/{EV}", headers={"user-agent": "Twitterbot/1.0"})
    assert r.status_code == 200 and "<title>Exos</title>" in r.text
