"""Broadway.com PUBLIC SITE scraper.

Hosts:
  www.broadway.com        — show pages, schedules
  checkout.broadway.com   — per-performance sections / listings (this is
                            where the pricing payload lives)

There is no public API. The checkout page is server-rendered Django and
inlines the entire pricing payload as JSON inside a <script> block:

    var json = {};
    json = {"status": 0, "data": {…payload…}, …}.data || {…fallback…};

So we grab the page with requests, find that assignment, JSON-parse the
wrapper, and read .data. No JS execution, no headless browser, no
Next.js runtime needed.

Listing-data unit of work:
  https://checkout.broadway.com/{slug}/{show_id}/{event_id}/sections/

  slug      Broadway.com show slug (e.g. "six")
  show_id   show.aristotle_id in the payload (e.g. 12885 for SIX).
            Stable per show.
  event_id  one per dated curtain (e.g. 1077629 for SIX 2026-05-14 7pm).

Captured every 24h to compare Broadway.com primary retail against
TEvo broker wholesale (evo_client.py) and SeatGeek secondary
marketplace (seatgeek_client.py). These IDs are independent of TEvo
event_id and SG event_id — cross-source matching happens upstream.

RULE 2 — READ-ONLY. We never POST/PUT/PATCH/DELETE to any broadway.com
host. Any non-GET method here is a bug.

Parser strategy:
  1. inline `var json = {…}.data || …;`         — primary (canonical)
  2. <script id="__NEXT_DATA__"> JSON           — defensive fallback
  3. window.__INITIAL_STATE__ / __PRELOADED_STATE__
  4. heuristic JSON walker over any extracted state
  5. bs4 row selectors

The format has been stable for years (Django + jQuery stack), but if
Broadway.com restructures, update _extract_inline_payload first; the
heuristics are last-resort.
"""
from __future__ import annotations

import json as _json
import os
import random
import re
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse

import requests
from bs4 import BeautifulSoup

from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from supabase import Client  # pragma: no cover


WWW_BASE = "https://www.broadway.com"
CHECKOUT_BASE = "https://checkout.broadway.com"

ALLOWED_HTTP_METHODS = frozenset({"GET"})


def _assert_readonly_method(method: str) -> None:
    if method.upper() not in ALLOWED_HTTP_METHODS:
        raise BroadwayError(
            f"READ-ONLY violation: method {method} is not allowed. "
            "Broadway.com integration is strictly read-only (RULE 2)."
        )


class BroadwayError(Exception):
    pass


class BroadwayParseError(BroadwayError):
    """HTML or embedded JSON did not match expected shape."""


# ---------- dataclasses ----------

@dataclass
class BroadwayShow:
    """Show-level metadata embedded in every sections payload.

    Stable across all performances of the same show, so callers can
    upsert this on a per-show basis instead of writing the same blob
    on every event_id row.
    """
    id: int                          # internal CMS id (596 for SIX)
    aristotle_id: int                # the URL middle segment (12885)
    slug: str
    title: str
    bwy_title: str | None
    venue_name: str | None
    venue_slug: str | None
    venue_address_1: str | None
    venue_city: str | None
    venue_state: str | None
    venue_zip: str | None
    venue_lat: float | None
    venue_lon: float | None
    opening_date: str | None
    closing_date: str | None
    preview_date: str | None
    closing_soon: bool | None
    on_sale: bool | None
    pricing: float | None            # "from" price string → float
    high_price: float | None         # top advertised price
    has_seatmap: bool | None
    has_discount_events: bool | None
    max_discount_amount: float | None
    announcement: str | None         # cast change / closing notes
    categories: list[str] = field(default_factory=list)


@dataclass
class SectionListing:
    """One row from payload.sections[]."""
    name: str                        # "Orchestra" / "Mezzanine"
    price: float                     # face value
    fee: float                       # service fee on top of face
    ticket_type: str                 # "Standard" / "Premium"
    quantities: list[int]            # group sizes still available
    price_ids: list[int]             # bwy internal price-catalog IDs
    area_indexes: list[int]          # 1=Orchestra, 2=Mezzanine, etc.
    price_index: int | None = None   # bwy price-tier identifier

    @property
    def all_in(self) -> float:
        return self.price + self.fee

    @property
    def available(self) -> bool:
        return bool(self.quantities)


@dataclass
class Performance:
    slug: str
    show_id: int
    event_id: int
    starts_at_local: str | None = None
    day_of_week: str | None = None
    sections_url: str | None = None


@dataclass
class BroadwayShowStub:
    """Minimal show pointer returned by discover_shows().

    Just enough to drive a follow-up discover_performances(slug) call.
    Full metadata arrives later via fetch_sections payload.show."""
    slug: str
    title: str | None = None
    show_page_url: str | None = None


@dataclass
class SnapshotShowResult:
    """Structured result from snapshot_show().

    discover_error is set when discover_performances raised; in that
    case snapshots and fetch_errors are empty. Otherwise both lists
    are populated per-performance.
    """
    slug: str
    discover_error: "BroadwayError | None" = None
    snapshots: list["SectionsSnapshot"] = field(default_factory=list)
    fetch_errors: list[dict] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.discover_error is None

    @property
    def attempted(self) -> int:
        return len(self.snapshots) + len(self.fetch_errors)


@dataclass
class SectionsSnapshot:
    slug: str
    show_id: int                     # = show.aristotle_id (URL middle)
    event_id: int                    # = URL last segment
    captured_at_utc: str
    source_url: str
    performance_time: str | None     # ISO with TZ offset, e.g. 2026-05-14T19:00:00-04:00
    performance_secondary_time: str | None
    event_status: int | None
    scatter_available: bool | None
    inquiry_type_id: int | None
    show: BroadwayShow | None
    sections: list[SectionListing]
    # Aggregated price bands surfaced by the same payload. Useful for
    # quick lo/hi without scanning sections[].
    areas: list[SectionListing]
    premium_areas: list[SectionListing]
    types: list[SectionListing]
    alerts: list[Any]
    raw_payload: dict[str, Any] | None = None


# ---------- client ----------

# bs4 fallback selectors — only used if inline payload extraction fails.
SECTION_ROW_SELECTORS = (
    "[data-testid='section-row']",
    "[data-testid='sections-list-item']",
    "li[data-section-id]",
    "div[data-section-id]",
    "tr[data-section-id]",
)

PRICE_SELECTORS = (
    "[data-testid='price']",
    ".price",
    "[class*='Price']",
)

PRICE_REGEX = re.compile(r"\$\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)")
NEXT_DATA_RE = re.compile(
    r'<script[^>]+id=["\']__NEXT_DATA__["\'][^>]*>(\{.*?\})</script>',
    re.DOTALL,
)
INITIAL_STATE_RE = re.compile(
    r'window\.__(?:INITIAL_STATE|PRELOADED_STATE)__\s*=\s*(\{.*?\})\s*;',
    re.DOTALL,
)
SECTIONS_PATH_RE = re.compile(
    r"^/(?P<slug>[^/]+)/(?P<show_id>\d+)/(?P<event_id>\d+)/sections/?$"
)
# Matches the inline assignment "json = {" but skips the empty init
# "var json = {};" by requiring the next char after "{" to not be "}".
# The JSON decoder filters out the empty case anyway via the "data" check,
# but this trims work.
INLINE_JSON_RE = re.compile(r"\bjson\s*=\s*\{")


class BroadwayClient:
    section_row_selectors = SECTION_ROW_SELECTORS
    price_selectors = PRICE_SELECTORS

    def __init__(
        self,
        db: "Client | None" = None,
        timeout_s: int = 25,
        user_agent: str | None = None,
        pace_s: float = 1.5,
    ):
        self.db = db
        self.timeout_s = timeout_s
        self.pace_s = pace_s
        self._last_request_at: float = 0.0
        self.session = requests.Session()
        _ua = user_agent or os.environ.get(
            "BROADWAY_USER_AGENT",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 "
            "Safari/537.36",
        )
        if "\r" in _ua or "\n" in _ua:
            raise ValueError("invalid User-Agent: CR/LF not allowed")
        self.session.headers.update({
            "User-Agent": _ua,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
        })

    # ---------- internal HTTP ----------

    def _pace(self) -> None:
        elapsed = time.monotonic() - self._last_request_at
        if elapsed < self.pace_s:
            time.sleep(self.pace_s - elapsed + random.uniform(0, 0.25))

    def _get(self, url: str, *, max_retries: int = 3) -> tuple[int, str]:
        _assert_readonly_method("GET")
        attempt = 0
        backoff = 1.5
        while True:
            self._pace()
            attempt += 1
            r = self.session.get(url, timeout=self.timeout_s, allow_redirects=True)
            self._last_request_at = time.monotonic()
            if r.status_code in (429, 503) and attempt <= max_retries:
                ra = r.headers.get("Retry-After")
                try:
                    sleep_s = float(ra) if ra else backoff
                except ValueError:
                    sleep_s = backoff
                time.sleep(min(60.0, sleep_s + random.random()))
                backoff = min(60.0, backoff * 2)
                continue
            return r.status_code, r.text

    def _log_pull(
        self,
        endpoint: str,
        *,
        slug: str | None,
        show_id: int | None,
        event_id: int | None,
        status: int,
        rows: int | None,
        error: str | None = None,
        meta: dict | None = None,
    ) -> None:
        if not self.db:
            return
        try:
            self.db.table("broadway_pull_log").insert({
                "endpoint": endpoint,
                "slug": slug,
                "show_id": show_id,
                "event_id": event_id,
                "http_status": status,
                "rows_returned": rows,
                "error_message": error,
                "request_meta": meta or {},
            }).execute()
        except Exception as e:
            print(f"broadway: pull log skipped: {e}", file=sys.stderr)

    # ---------- URL helpers ----------

    @staticmethod
    def sections_url(slug: str, show_id: int, event_id: int) -> str:
        return f"{CHECKOUT_BASE}/{slug}/{int(show_id)}/{int(event_id)}/sections/"

    @staticmethod
    def parse_sections_url(url: str) -> tuple[str, int, int]:
        u = urlparse(url)
        if u.netloc and u.netloc != "checkout.broadway.com":
            raise BroadwayError(f"unexpected host for sections URL: {u.netloc}")
        m = SECTIONS_PATH_RE.match(u.path)
        if not m:
            raise BroadwayError(
                f"URL does not match /{{slug}}/{{show_id}}/{{event_id}}/sections/: {url}"
            )
        return m.group("slug"), int(m.group("show_id")), int(m.group("event_id"))

    # ---------- inline payload extraction (PRIMARY) ----------

    @staticmethod
    def _extract_inline_payload(html: str) -> dict | None:
        """Find the `json = {…wrapper…}.data || …;` assignment and return
        the data dict.

        The wrapper looks like:
            {"status": 0, "messages": [...], "data": {...payload...},
             "bapi_cart_token": "...", "ga_code": "", "ga_track_errors": false}
        We greedily JSON-decode the first {…} after each `json = ` we
        find, then return wrapper["data"]. Falls back to the wrapper
        itself if "data" is absent (matches the JS `|| ` semantics)."""
        decoder = _json.JSONDecoder()
        for m in INLINE_JSON_RE.finditer(html):
            # Position of the opening brace
            brace = html.index("{", m.end() - 1)
            try:
                obj, _end = decoder.raw_decode(html, brace)
            except _json.JSONDecodeError:
                continue
            if not isinstance(obj, dict):
                continue
            if "data" in obj and isinstance(obj["data"], dict):
                return obj["data"]
            # Empty init {} — keep looking
            if not obj:
                continue
            # Possible bare-payload form (no "data" wrapping). Accept
            # only if it looks like a sections payload.
            if "event_id" in obj and "sections" in obj:
                return obj
        return None

    @staticmethod
    def _coerce_float(v: Any) -> float | None:
        if v is None:
            return None
        if isinstance(v, (int, float)):
            return float(v)
        if isinstance(v, str):
            try:
                return float(v)
            except ValueError:
                m = PRICE_REGEX.search(v)
                return float(m.group(1).replace(",", "")) if m else None
        return None

    @classmethod
    def _show_from_payload(cls, payload: dict) -> BroadwayShow | None:
        s = payload.get("show")
        if not isinstance(s, dict):
            return None
        return BroadwayShow(
            id=int(s.get("id") or 0),
            aristotle_id=int(s.get("aristotle_id") or 0),
            slug=str(s.get("slug") or ""),
            title=str(s.get("title") or ""),
            bwy_title=s.get("bwy_title"),
            venue_name=s.get("venue_name"),
            venue_slug=s.get("venue_slug"),
            venue_address_1=s.get("venue_address_1"),
            venue_city=s.get("venue_city"),
            venue_state=s.get("venue_state"),
            venue_zip=s.get("venue_zip"),
            venue_lat=cls._coerce_float(s.get("venue_latitude")),
            venue_lon=cls._coerce_float(s.get("venue_longitude")),
            opening_date=s.get("opening_date"),
            closing_date=s.get("closing_date"),
            preview_date=s.get("preview_date"),
            closing_soon=s.get("closing_soon"),
            on_sale=s.get("on_sale"),
            pricing=cls._coerce_float(s.get("pricing")),
            high_price=cls._coerce_float(s.get("high_price")),
            has_seatmap=s.get("has_seatmap"),
            has_discount_events=s.get("has_discount_events"),
            max_discount_amount=cls._coerce_float(s.get("max_discount_amount")),
            announcement=s.get("announcement"),
            categories=[c.get("name", "") for c in (s.get("categories") or []) if isinstance(c, dict)],
        )

    @staticmethod
    def _row_to_listing(r: dict) -> SectionListing:
        return SectionListing(
            name=str(r.get("name") or ""),
            price=float(r.get("price") or 0.0),
            fee=float(r.get("fee") or 0.0),
            ticket_type=str(r.get("ticket_type") or ""),
            quantities=list(r.get("quantities") or []),
            price_ids=list(r.get("price_ids") or []),
            area_indexes=list(r.get("area_indexes") or []),
            price_index=r.get("price_index"),
        )

    @classmethod
    def _snapshot_from_payload(
        cls,
        slug: str,
        show_id: int,
        event_id: int,
        payload: dict,
        captured_at: str,
        source_url: str,
        keep_raw: bool,
    ) -> SectionsSnapshot:
        sections = [cls._row_to_listing(r) for r in (payload.get("sections") or []) if isinstance(r, dict)]
        areas = [cls._row_to_listing(r) for r in (payload.get("areas") or []) if isinstance(r, dict)]
        premium_areas = [cls._row_to_listing(r) for r in (payload.get("premium_areas") or []) if isinstance(r, dict)]
        types_ = [cls._row_to_listing(r) for r in (payload.get("types") or []) if isinstance(r, dict)]
        return SectionsSnapshot(
            slug=slug,
            show_id=int(show_id),
            event_id=int(event_id),
            captured_at_utc=captured_at,
            source_url=source_url,
            performance_time=payload.get("performance_time"),
            performance_secondary_time=payload.get("performance_secondary_time") or None,
            event_status=payload.get("event_status"),
            scatter_available=payload.get("scatter_available"),
            inquiry_type_id=payload.get("inquiry_type_id"),
            show=cls._show_from_payload(payload),
            sections=sections,
            areas=areas,
            premium_areas=premium_areas,
            types=types_,
            alerts=list(payload.get("alerts") or []),
            raw_payload=payload if keep_raw else None,
        )

    # ---------- defensive fallbacks ----------

    @staticmethod
    def _extract_next_data(html: str) -> dict | None:
        m = NEXT_DATA_RE.search(html)
        if not m:
            return None
        try:
            return _json.loads(m.group(1))
        except _json.JSONDecodeError:
            return None

    @staticmethod
    def _extract_initial_state(html: str) -> dict | None:
        m = INITIAL_STATE_RE.search(html)
        if not m:
            return None
        try:
            return _json.loads(m.group(1))
        except _json.JSONDecodeError:
            return None

    def _listings_from_html(self, html: str) -> list[SectionListing]:
        """Last-resort: bs4-scrape rows. The inline payload should always
        be present on a real checkout page; this exists so a parser-drift
        regression returns something rather than nothing."""
        soup = BeautifulSoup(html, "html.parser")
        rows: list = []
        for sel in self.section_row_selectors:
            rows = soup.select(sel)
            if rows:
                break
        out: list[SectionListing] = []
        for el in rows:
            text = el.get_text(" ", strip=True)
            name = el.get("data-section-name") or ""
            if not name:
                hdr = el.find(["h2", "h3", "h4", "strong", "span"])
                if hdr:
                    name = hdr.get_text(" ", strip=True)
            if not name:
                m = PRICE_REGEX.search(text)
                name = (text[: m.start()] if m else text).strip()[:80]
            price = None
            for psel in self.price_selectors:
                pe = el.select_one(psel)
                if pe:
                    price = self._coerce_float(pe.get_text(" ", strip=True))
                    if price is not None:
                        break
            if price is None:
                price = self._coerce_float(text)
            out.append(SectionListing(
                name=name,
                price=float(price or 0.0),
                fee=0.0,
                ticket_type="",
                quantities=[],
                price_ids=[],
                area_indexes=[],
            ))
        return out

    # ---------- public scrape methods ----------

    def fetch_sections(
        self,
        slug: str,
        show_id: int,
        event_id: int,
        *,
        keep_raw_payload: bool = False,
    ) -> SectionsSnapshot:
        """Fetch and parse the per-performance sections page.

        Daily-cron unit of work: one call per (slug, show_id, event_id).
        """
        url = self.sections_url(slug, show_id, event_id)
        status, html = self._get(url)
        captured_at = datetime.now(timezone.utc).isoformat()
        if status != 200:
            self._log_pull(
                "sections", slug=slug, show_id=show_id, event_id=event_id,
                status=status, rows=None, error=html[:300],
            )
            raise BroadwayError(f"sections fetch returned {status} for {url}")

        payload = self._extract_inline_payload(html)
        if payload is not None:
            snap = self._snapshot_from_payload(
                slug, show_id, event_id, payload,
                captured_at, url, keep_raw_payload,
            )
            self._log_pull(
                "sections", slug=slug, show_id=show_id, event_id=event_id,
                status=status, rows=len(snap.sections),
            )
            return snap

        # Fallbacks — should rarely fire on a healthy page.
        listings = self._listings_from_html(html)
        if not listings:
            # HTTP 200 + no inline payload + no bs4 matches = either Fastly
            # bot-challenge deflection (real Broadway origin never reached)
            # or a page redesign. Either way, returning an empty snapshot
            # is indistinguishable from a legitimately-empty performance,
            # which silently corrupts downstream drift signals. Raise loud.
            self._log_pull(
                "sections", slug=slug, show_id=show_id, event_id=event_id,
                status=status, rows=0,
                error="200 OK but no inline payload and no listings — likely Fastly bot challenge or page redesign",
            )
            raise BroadwayParseError(
                f"HTTP 200 but no inline payload and no listings for {url}. "
                "Likely Fastly bot challenge or page redesign."
            )
        self._log_pull(
            "sections", slug=slug, show_id=show_id, event_id=event_id,
            status=status, rows=len(listings),
        )
        return SectionsSnapshot(
            slug=slug,
            show_id=int(show_id),
            event_id=int(event_id),
            captured_at_utc=captured_at,
            source_url=url,
            performance_time=None,
            performance_secondary_time=None,
            event_status=None,
            scatter_available=None,
            inquiry_type_id=None,
            show=None,
            sections=listings,
            areas=[],
            premium_areas=[],
            types=[],
            alerts=[],
            raw_payload=None,
        )

    def fetch_sections_url(
        self, url: str, *, keep_raw_payload: bool = False,
    ) -> SectionsSnapshot:
        slug, show_id, event_id = self.parse_sections_url(url)
        return self.fetch_sections(slug, show_id, event_id,
                                   keep_raw_payload=keep_raw_payload)

    def discover_performances(self, slug: str) -> list[Performance]:
        """Best-effort: harvest sections-URL anchors from /shows/<slug>/.

        VERIFY locally: a `dump-raw https://www.broadway.com/shows/<slug>/`
        and inspect for anchors with href matching SECTIONS_PATH_RE.
        """
        url = f"{WWW_BASE}/shows/{slug}/"
        status, html = self._get(url)
        if status != 200:
            self._log_pull("show_page", slug=slug, show_id=None, event_id=None,
                           status=status, rows=None, error=html[:300])
            raise BroadwayError(f"show page fetch returned {status} for {url}")
        soup = BeautifulSoup(html, "html.parser")
        seen: set[tuple[str, int, int]] = set()
        out: list[Performance] = []
        for a in soup.find_all("a", href=True):
            parsed = urlparse(a["href"])
            host_ok = (not parsed.netloc) or parsed.netloc == "checkout.broadway.com"
            if not host_ok:
                continue
            m = SECTIONS_PATH_RE.match(parsed.path)
            if not m:
                continue
            triple = (m.group("slug"), int(m.group("show_id")), int(m.group("event_id")))
            if triple in seen:
                continue
            seen.add(triple)
            out.append(Performance(
                slug=triple[0],
                show_id=triple[1],
                event_id=triple[2],
                starts_at_local=a.get("data-datetime") or a.get("data-performance-datetime"),
                day_of_week=a.get("data-dow"),
                sections_url=f"{CHECKOUT_BASE}{parsed.path}",
            ))
        if not out:
            # Zero sections-URL anchors on a 200 response. Two cases:
            # (a) real Broadway.com show page but the show legitimately
            #     has no upcoming performances (closed/dark week);
            # (b) Fastly bot-challenge or error page deflected as 200,
            #     so we never hit the real origin.
            # Distinguish by looking for any Broadway.com brand marker
            # in the body — challenge pages don't have these. Conservative
            # fingerprint: the slug itself appears in the HTML, or the
            # canonical brand string "broadway.com" appears outside of
            # script/href noise (cheap substring check is fine here).
            html_lower = html.lower()
            looks_like_broadway = (
                slug.lower() in html_lower
                or "broadway.com" in html_lower
            )
            if not looks_like_broadway:
                self._log_pull(
                    "show_page", slug=slug, show_id=None, event_id=None,
                    status=status, rows=0,
                    error="200 OK but no sections anchors and no Broadway.com markers — likely Fastly bot challenge or page redesign",
                )
                raise BroadwayParseError(
                    f"HTTP 200 but no performances and no Broadway.com markers for {url}. "
                    "Likely Fastly bot challenge or page redesign."
                )
        self._log_pull("show_page", slug=slug, show_id=None, event_id=None,
                       status=status, rows=len(out))
        return out

    def discover_shows(self) -> list[BroadwayShowStub]:
        """Harvest all current show slugs from /shows/.

        Returns one stub per unique slug found on the index page. Cron
        calls this once daily; results upsert into broadway_shows so
        the pull queue can enumerate "all current Broadway shows"
        without an operator-maintained slug list.

        Same drift-detection guards as discover_performances:
          - non-200 → BroadwayError
          - 200 with zero anchors AND no Broadway.com markers in body
            → BroadwayParseError (Fastly challenge / page redesign)
          - 200 with zero anchors but markers present → returns []
            (cold-start edge case — should not happen on a real
            Broadway.com index, but tolerate it without raising)
        """
        url = f"{WWW_BASE}/shows/"
        status, html = self._get(url)
        if status != 200:
            self._log_pull("shows_index", slug=None, show_id=None, event_id=None,
                           status=status, rows=None, error=html[:300])
            raise BroadwayError(f"shows index fetch returned {status} for {url}")
        soup = BeautifulSoup(html, "html.parser")
        seen: dict[str, BroadwayShowStub] = {}
        # Match /shows/<slug>/ anchors (anywhere on the index). Skip the
        # bare /shows/ link itself and any anchor whose slug contains
        # non-slug characters.
        show_path_re = re.compile(r"^/shows/(?P<slug>[a-z0-9][a-z0-9-]+)/?$", re.I)
        for a in soup.find_all("a", href=True):
            parsed = urlparse(a["href"])
            host_ok = (not parsed.netloc) or parsed.netloc == "www.broadway.com"
            if not host_ok:
                continue
            m = show_path_re.match(parsed.path)
            if not m:
                continue
            slug = m.group("slug").lower()
            if slug in seen:
                continue
            title = a.get_text(" ", strip=True) or None
            seen[slug] = BroadwayShowStub(
                slug=slug,
                title=title,
                show_page_url=f"{WWW_BASE}/shows/{slug}/",
            )
        out = list(seen.values())
        if not out:
            html_lower = html.lower()
            if "broadway.com" not in html_lower:
                self._log_pull(
                    "shows_index", slug=None, show_id=None, event_id=None,
                    status=status, rows=0,
                    error="200 OK but no show anchors and no Broadway.com markers — likely Fastly bot challenge or page redesign",
                )
                raise BroadwayParseError(
                    f"HTTP 200 but no shows and no Broadway.com markers for {url}. "
                    "Likely Fastly bot challenge or page redesign."
                )
        self._log_pull("shows_index", slug=None, show_id=None, event_id=None,
                       status=status, rows=len(out))
        return out

    def snapshot_show(self, slug: str) -> SnapshotShowResult:
        """Pull every performance's sections snapshot for a single show.

        Returns a SnapshotShowResult that distinguishes:
          - discover_error (whole-show failure: show page 403, parse error)
          - per-performance fetch_errors (individual perf failed but
            others may have succeeded)
          - snapshots (successful captures)

        Designed for cron use: caller iterates over a list of slugs and
        aggregates SnapshotShowResults into a run-level summary.
        """
        out = SnapshotShowResult(slug=slug)
        try:
            perfs = self.discover_performances(slug)
        except BroadwayError as e:
            out.discover_error = e
            return out
        for p in perfs:
            try:
                out.snapshots.append(
                    self.fetch_sections(p.slug, p.show_id, p.event_id)
                )
            except BroadwayError as e:
                out.fetch_errors.append({
                    "slug": p.slug,
                    "show_id": p.show_id,
                    "event_id": p.event_id,
                    "error_class": type(e).__name__,
                    "error_message": str(e),
                })
        return out


# ---------- CLI for smoke-testing ----------

def _print_snapshot(snap: SectionsSnapshot) -> None:
    d = asdict(snap)
    if d.get("raw_payload") is not None:
        d["raw_payload"] = f"<{len(_json.dumps(d['raw_payload']))} bytes>"
    print(_json.dumps(d, indent=2, default=str))


def _main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        print("\nUsage:")
        print("  python broadway_client.py sections <slug> <show_id> <event_id>")
        print("  python broadway_client.py sections-url <full-url>")
        print("  python broadway_client.py discover <slug>")
        print("  python broadway_client.py shows")
        print("  python broadway_client.py snapshot <slug>")
        print("  python broadway_client.py dump-raw <url> <out-path>")
        print("  python broadway_client.py parse-file <html-path>")
        return 1
    cmd = argv[1]
    cli = BroadwayClient()
    if cmd == "sections":
        slug, show_id, event_id = argv[2], int(argv[3]), int(argv[4])
        _print_snapshot(cli.fetch_sections(slug, show_id, event_id))
    elif cmd == "sections-url":
        _print_snapshot(cli.fetch_sections_url(argv[2]))
    elif cmd == "discover":
        for p in cli.discover_performances(argv[2]):
            print(_json.dumps(asdict(p), default=str))
    elif cmd == "shows":
        for s in cli.discover_shows():
            print(_json.dumps(asdict(s), default=str))
    elif cmd == "snapshot":
        result = cli.snapshot_show(argv[2])
        if result.discover_error:
            print(f"discover failed: {result.discover_error}", file=sys.stderr)
            return 4
        for s in result.snapshots:
            _print_snapshot(s)
        for err in result.fetch_errors:
            print(_json.dumps({"fetch_error": err}), file=sys.stderr)
    elif cmd == "dump-raw":
        import pathlib as _pl
        url, out_arg = argv[2], argv[3]
        out_path = _pl.Path(out_arg).resolve()
        cwd = _pl.Path.cwd().resolve()
        try:
            out_path.relative_to(cwd)
        except ValueError:
            raise SystemExit("dump-raw output path must be inside the current working directory")
        status, html = cli._get(url)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(html)
        print(f"HTTP {status}  bytes={len(html)}  → {out_path}")
    elif cmd == "parse-file":
        # Offline parse of a saved HTML file — no network. Useful for
        # iterating on the parser against captured pages.
        with open(argv[2], "r", encoding="utf-8") as f:
            html = f.read()
        payload = BroadwayClient._extract_inline_payload(html)
        if not payload:
            print("no inline payload found", file=sys.stderr)
            return 3
        u = payload.get("show", {}).get("slug") or "unknown"
        snap = BroadwayClient._snapshot_from_payload(
            slug=u,
            show_id=int(payload.get("show", {}).get("aristotle_id") or 0),
            event_id=int(payload.get("event_id") or 0),
            payload=payload,
            captured_at=datetime.now(timezone.utc).isoformat(),
            source_url=f"file://{argv[2]}",
            keep_raw=False,
        )
        _print_snapshot(snap)
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
