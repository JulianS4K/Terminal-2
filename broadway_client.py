"""Broadway.com PUBLIC SITE scraper.

Hosts:
  www.broadway.com        — show pages, schedules
  checkout.broadway.com   — per-performance sections / listings

There is no public API. We scrape rendered HTML. Pages are server-rendered
enough that requests + BeautifulSoup is sufficient (no headless browser).

Listing-data unit of work:
  https://checkout.broadway.com/{slug}/{show_id}/{performance_id}/sections/

This page surfaces what Broadway.com shows the public for a single
performance — the "primary / authorized retail" view. We capture it
every 24h to compare against:
  - TEvo broker wholesale (evo_client.py)
  - SeatGeek secondary marketplace (seatgeek_client.py)

ID model:
  (slug, show_id, performance_id) is Broadway.com's primary key for a
  performance. show_id is stable per show; performance_id is one per
  dated curtain. Both are integers in the URL path.
  These IDs are independent from TEvo event_id and SG event_id —
  cross-source matching happens upstream (manual or fuzzy on
  performer + venue + datetime).

RULE 2 — READ-ONLY. We never POST/PUT/PATCH/DELETE to any broadway.com
host. Any non-GET method here is a bug.

Selectors / JSON paths:
  Broadway.com renders pricing through a Next.js bundle. The parser
  tries, in order:
    1. <script id="__NEXT_DATA__"> JSON  — most stable when present
    2. <script> blocks containing __INITIAL_STATE__ / __PRELOADED_STATE__
    3. bs4 selectors (configurable on BroadwayClient class)
  All three are best-effort. If Broadway.com changes structure, update
  the selector constants at the top of BroadwayClient and the JSON
  walkers in _extract_listings_from_next_data.

Verification:
  This module was authored without live network access to broadway.com
  in the build sandbox. Before relying on it, run:
      python broadway_client.py dump-raw <full-url> <out-path>
  and inspect the saved HTML to confirm the parsing assumptions hold.
"""
from __future__ import annotations

import json
import os
import random
import re
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Any, Iterable
from urllib.parse import urlparse

import requests
from bs4 import BeautifulSoup

from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from supabase import Client  # pragma: no cover


WWW_BASE = "https://www.broadway.com"
CHECKOUT_BASE = "https://checkout.broadway.com"

# RULE 2 — READ-ONLY across all broadway.com surfaces.
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
class Performance:
    slug: str
    show_id: int
    performance_id: int
    # Optional metadata if we can recover it from the page
    starts_at_local: str | None = None  # ISO-ish, page-local; not always tz-stamped
    day_of_week: str | None = None
    sections_url: str | None = None


@dataclass
class SectionListing:
    """One row of broadway.com's per-performance sections page."""
    section_name: str
    price: float | None
    price_min: float | None
    price_max: float | None
    currency: str = "USD"
    # Capacity / status flags surfaced by the page when present
    available: bool | None = None
    # Free-form "row" / "level" / "tier" if shown alongside section
    tier: str | None = None
    # Anything else the parser saw, for forensics
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class SectionsSnapshot:
    slug: str
    show_id: int
    performance_id: int
    captured_at_utc: str
    source_url: str
    starts_at_local: str | None
    show_title: str | None
    venue: str | None
    listings: list[SectionListing]
    # The raw __NEXT_DATA__ blob (or other JSON state) if found, for
    # downstream re-parsing without a re-fetch. Kept opt-in to avoid
    # ballooning storage if/when this is persisted.
    raw_state: dict[str, Any] | None = None


# ---------- client ----------

# Section-row selector candidates. Update if Broadway.com restructures.
# Verified mechanically against the URL pattern only — the HTML shape
# must be confirmed against a live capture (run `dump-raw` first).
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
    r"^/(?P<slug>[^/]+)/(?P<show_id>\d+)/(?P<performance_id>\d+)/sections/?$"
)


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
        # Pace between requests so we don't pound the site. Reads only;
        # broadway.com has no published API and we want to stay polite.
        self.pace_s = pace_s
        self._last_request_at: float = 0.0
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": user_agent or os.environ.get(
                "BROADWAY_USER_AGENT",
                # Realistic desktop UA. Override via env when running
                # from a server with a stable contact address.
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 "
                "Safari/537.36",
            ),
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
        performance_id: int | None,
        status: int,
        rows: int | None,
        error: str | None = None,
        meta: dict | None = None,
    ) -> None:
        # Optional: writes to broadway_pull_log if the table exists. Silent
        # no-op otherwise so this client works without a schema migration.
        if not self.db:
            return
        try:
            self.db.table("broadway_pull_log").insert({
                "endpoint": endpoint,
                "slug": slug,
                "show_id": show_id,
                "performance_id": performance_id,
                "http_status": status,
                "rows_returned": rows,
                "error_message": error,
                "request_meta": meta or {},
            }).execute()
        except Exception as e:
            # Don't fail a scrape just because the log table is missing.
            print(f"broadway: pull log skipped: {e}", file=sys.stderr)

    # ---------- URL helpers ----------

    @staticmethod
    def sections_url(slug: str, show_id: int, performance_id: int) -> str:
        return f"{CHECKOUT_BASE}/{slug}/{int(show_id)}/{int(performance_id)}/sections/"

    @staticmethod
    def parse_sections_url(url: str) -> tuple[str, int, int]:
        """Parse a checkout.broadway.com sections URL into its triple.
        Raises BroadwayError if the URL doesn't match the expected shape."""
        u = urlparse(url)
        if u.netloc and u.netloc != "checkout.broadway.com":
            raise BroadwayError(f"unexpected host for sections URL: {u.netloc}")
        m = SECTIONS_PATH_RE.match(u.path)
        if not m:
            raise BroadwayError(
                f"URL does not match /{{slug}}/{{show_id}}/{{performance_id}}/sections/: {url}"
            )
        return m.group("slug"), int(m.group("show_id")), int(m.group("performance_id"))

    # ---------- parsing ----------

    @staticmethod
    def _extract_next_data(html: str) -> dict | None:
        m = NEXT_DATA_RE.search(html)
        if not m:
            return None
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            return None

    @staticmethod
    def _extract_initial_state(html: str) -> dict | None:
        m = INITIAL_STATE_RE.search(html)
        if not m:
            return None
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            return None

    @staticmethod
    def _walk_for_listings(state: Any) -> list[dict]:
        """Walk a JSON state blob looking for objects that look like
        section/price rows. Heuristic: an object with a name-ish key
        (section/sectionName/title) AND a price-ish key (price/minPrice/
        amount/cheapest)."""
        name_keys = {"section", "sectionname", "name", "title", "label"}
        price_keys = {"price", "minprice", "lowprice", "lowestprice",
                      "cheapest", "amount", "facevalue", "from", "fromprice"}
        out: list[dict] = []

        def visit(node: Any) -> None:
            if isinstance(node, dict):
                lower = {k.lower(): k for k in node.keys()}
                if (name_keys & set(lower.keys())) and (price_keys & set(lower.keys())):
                    out.append(node)
                for v in node.values():
                    visit(v)
            elif isinstance(node, list):
                for item in node:
                    visit(item)

        visit(state)
        return out

    @staticmethod
    def _coerce_price(v: Any) -> float | None:
        if v is None:
            return None
        if isinstance(v, (int, float)):
            return float(v)
        if isinstance(v, dict):
            # Common shapes: {amount: 12500, currency: 'USD'} or {value: ...}
            for k in ("amount", "value", "price", "min", "low"):
                if k in v and isinstance(v[k], (int, float, str)):
                    return BroadwayClient._coerce_price(v[k])
            return None
        if isinstance(v, str):
            m = PRICE_REGEX.search(v)
            if m:
                return float(m.group(1).replace(",", ""))
            try:
                return float(v)
            except ValueError:
                return None
        return None

    def _listings_from_state(self, state: dict) -> list[SectionListing]:
        rows = self._walk_for_listings(state)
        out: list[SectionListing] = []
        for r in rows:
            lower = {k.lower(): k for k in r.keys()}
            name_key = next((lower[k] for k in ("section", "sectionname", "name", "title", "label") if k in lower), None)
            name = str(r[name_key]) if name_key else ""
            # Try min then generic price then fromPrice
            price = None
            for cand in ("price", "minprice", "lowprice", "lowestprice", "cheapest", "from", "fromprice", "amount"):
                if cand in lower:
                    price = self._coerce_price(r[lower[cand]])
                    if price is not None:
                        break
            price_max = None
            for cand in ("maxprice", "highprice", "highestprice", "to", "toprice"):
                if cand in lower:
                    price_max = self._coerce_price(r[lower[cand]])
                    if price_max is not None:
                        break
            available = None
            for cand in ("available", "issoldout", "soldout", "isavailable"):
                if cand in lower and isinstance(r[lower[cand]], bool):
                    val = r[lower[cand]]
                    available = (not val) if cand in ("issoldout", "soldout") else val
                    break
            out.append(SectionListing(
                section_name=name.strip(),
                price=price,
                price_min=price,
                price_max=price_max,
                available=available,
                tier=str(r[lower["tier"]]) if "tier" in lower else None,
                raw=r,
            ))
        return out

    def _listings_from_html(self, html: str) -> list[SectionListing]:
        """Best-effort fallback: find rows matching the section selectors
        and extract a price from each. Only fires when no JSON state
        could be located."""
        soup = BeautifulSoup(html, "html.parser")
        rows: list = []
        for sel in self.section_row_selectors:
            rows = soup.select(sel)
            if rows:
                break
        out: list[SectionListing] = []
        for el in rows:
            text = el.get_text(" ", strip=True)
            # Section name: data-section-name → first heading-ish child → leading text
            name = el.get("data-section-name") or ""
            if not name:
                hdr = el.find(["h2", "h3", "h4", "strong", "span"])
                if hdr:
                    name = hdr.get_text(" ", strip=True)
            if not name:
                # Fallback: take text before the first $
                m = PRICE_REGEX.search(text)
                name = (text[: m.start()] if m else text).strip()[:80]
            # Price: try selector, then regex on row text
            price = None
            for psel in self.price_selectors:
                pe = el.select_one(psel)
                if pe:
                    price = self._coerce_price(pe.get_text(" ", strip=True))
                    if price is not None:
                        break
            if price is None:
                price = self._coerce_price(text)
            out.append(SectionListing(
                section_name=name,
                price=price,
                price_min=price,
                price_max=None,
                raw={"html_text": text[:500]},
            ))
        return out

    @staticmethod
    def _extract_meta_from_state(state: dict) -> tuple[str | None, str | None, str | None]:
        """Try to pull (show_title, venue, starts_at_local) from a
        Next.js / Redux state blob. Heuristic — returns (None, None, None)
        if nothing matches."""
        title = venue = starts = None

        def visit(node: Any) -> None:
            nonlocal title, venue, starts
            if isinstance(node, dict):
                lower = {k.lower(): k for k in node.keys()}
                if title is None:
                    for k in ("showtitle", "showname", "producttitle", "title", "name"):
                        if k in lower and isinstance(node[lower[k]], str):
                            title = node[lower[k]]
                            break
                if venue is None:
                    for k in ("venuename", "theatername", "theatre", "theater", "venue"):
                        if k in lower:
                            v = node[lower[k]]
                            if isinstance(v, str):
                                venue = v
                                break
                            if isinstance(v, dict):
                                # Common shape: venue: {name: '...', city: '...'}
                                inner_lower = {ik.lower(): ik for ik in v.keys()}
                                for ik in ("name", "displayname", "title"):
                                    if ik in inner_lower and isinstance(v[inner_lower[ik]], str):
                                        venue = v[inner_lower[ik]]
                                        break
                                if venue:
                                    break
                if starts is None:
                    for k in ("starttime", "performancedatetime", "performancedate",
                              "startsat", "datetime", "starttimelocal"):
                        if k in lower and isinstance(node[lower[k]], str):
                            starts = node[lower[k]]
                            break
                for v in node.values():
                    if title and venue and starts:
                        return
                    visit(v)
            elif isinstance(node, list):
                for item in node:
                    if title and venue and starts:
                        return
                    visit(item)

        visit(state)
        return title, venue, starts

    # ---------- public scrape methods ----------

    def fetch_sections(
        self,
        slug: str,
        show_id: int,
        performance_id: int,
        *,
        keep_raw_state: bool = False,
    ) -> SectionsSnapshot:
        """Fetch and parse the per-performance sections page.

        This is the unit of work for the 24h cadence: one call per
        (slug, show_id, performance_id) triple, captured daily.
        """
        url = self.sections_url(slug, show_id, performance_id)
        status, html = self._get(url)
        captured_at = datetime.now(timezone.utc).isoformat()
        if status != 200:
            self._log_pull(
                "sections", slug=slug, show_id=show_id, performance_id=performance_id,
                status=status, rows=None, error=html[:300],
            )
            raise BroadwayError(f"sections fetch returned {status} for {url}")

        state = self._extract_next_data(html) or self._extract_initial_state(html)
        title = venue = starts_at = None
        listings: list[SectionListing] = []
        if state:
            title, venue, starts_at = self._extract_meta_from_state(state)
            listings = self._listings_from_state(state)
        if not listings:
            listings = self._listings_from_html(html)
            if not listings:
                # Don't raise — return an empty snapshot so callers can log
                # and humans can investigate. Parser drift is the most
                # likely cause and we want visibility, not a hard fail.
                self._log_pull(
                    "sections", slug=slug, show_id=show_id, performance_id=performance_id,
                    status=status, rows=0,
                    error="parser found no listings — selectors may be stale",
                )

        self._log_pull(
            "sections", slug=slug, show_id=show_id, performance_id=performance_id,
            status=status, rows=len(listings),
        )
        return SectionsSnapshot(
            slug=slug,
            show_id=int(show_id),
            performance_id=int(performance_id),
            captured_at_utc=captured_at,
            source_url=url,
            starts_at_local=starts_at,
            show_title=title,
            venue=venue,
            listings=listings,
            raw_state=state if keep_raw_state else None,
        )

    def fetch_sections_url(self, url: str, *, keep_raw_state: bool = False) -> SectionsSnapshot:
        slug, show_id, performance_id = self.parse_sections_url(url)
        return self.fetch_sections(slug, show_id, performance_id, keep_raw_state=keep_raw_state)

    def discover_performances(self, slug: str) -> list[Performance]:
        """Best-effort: pull the list of (show_id, performance_id) pairs
        for a show by scraping its public schedule page.

        Broadway.com's per-show URL is /shows/<slug>/. The schedule grid
        is rendered with anchor tags pointing at checkout.broadway.com
        sections URLs. We harvest those anchors. If the page changes,
        update this method.

        VERIFY locally: a `dump-raw https://www.broadway.com/shows/<slug>/`
        and inspect for anchors with href matching SECTIONS_PATH_RE.
        """
        url = f"{WWW_BASE}/shows/{slug}/"
        status, html = self._get(url)
        if status != 200:
            self._log_pull("show_page", slug=slug, show_id=None, performance_id=None,
                           status=status, rows=None, error=html[:300])
            raise BroadwayError(f"show page fetch returned {status} for {url}")
        soup = BeautifulSoup(html, "html.parser")
        seen: set[tuple[str, int, int]] = set()
        out: list[Performance] = []
        for a in soup.find_all("a", href=True):
            href = a["href"]
            # Accept both absolute and root-relative URLs
            parsed = urlparse(href)
            host_ok = (not parsed.netloc) or parsed.netloc == "checkout.broadway.com"
            if not host_ok:
                continue
            m = SECTIONS_PATH_RE.match(parsed.path)
            if not m:
                continue
            triple = (m.group("slug"), int(m.group("show_id")), int(m.group("performance_id")))
            if triple in seen:
                continue
            seen.add(triple)
            out.append(Performance(
                slug=triple[0],
                show_id=triple[1],
                performance_id=triple[2],
                starts_at_local=a.get("data-datetime") or a.get("data-performance-datetime"),
                day_of_week=a.get("data-dow"),
                sections_url=f"{CHECKOUT_BASE}{parsed.path}",
            ))
        self._log_pull("show_page", slug=slug, show_id=None, performance_id=None,
                       status=status, rows=len(out))
        return out

    # ---------- thin convenience ----------

    def snapshot_show(self, slug: str) -> list[SectionsSnapshot]:
        """Pull every performance's sections snapshot for a single show.
        Intended as the daily-cron unit of work, one show at a time."""
        perfs = self.discover_performances(slug)
        snaps: list[SectionsSnapshot] = []
        for p in perfs:
            try:
                snaps.append(self.fetch_sections(p.slug, p.show_id, p.performance_id))
            except BroadwayError as e:
                print(f"broadway: skipping {p.slug}/{p.show_id}/{p.performance_id}: {e}",
                      file=sys.stderr)
        return snaps


# ---------- CLI for smoke-testing ----------

def _print_snapshot(snap: SectionsSnapshot) -> None:
    d = asdict(snap)
    # raw_state would dwarf the output; show a marker only
    if d.get("raw_state") is not None:
        d["raw_state"] = f"<{len(json.dumps(d['raw_state']))} bytes>"
    print(json.dumps(d, indent=2, default=str))


def _main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        print("\nUsage:")
        print("  python broadway_client.py sections <slug> <show_id> <performance_id>")
        print("  python broadway_client.py sections-url <full-url>")
        print("  python broadway_client.py discover <slug>")
        print("  python broadway_client.py snapshot <slug>")
        print("  python broadway_client.py dump-raw <url> <out-path>")
        return 1
    cmd = argv[1]
    cli = BroadwayClient()
    if cmd == "sections":
        slug, show_id, perf_id = argv[2], int(argv[3]), int(argv[4])
        _print_snapshot(cli.fetch_sections(slug, show_id, perf_id))
    elif cmd == "sections-url":
        _print_snapshot(cli.fetch_sections_url(argv[2]))
    elif cmd == "discover":
        for p in cli.discover_performances(argv[2]):
            print(json.dumps(asdict(p), default=str))
    elif cmd == "snapshot":
        for s in cli.snapshot_show(argv[2]):
            _print_snapshot(s)
    elif cmd == "dump-raw":
        url, out_path = argv[2], argv[3]
        status, html = cli._get(url)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(html)
        print(f"HTTP {status}  bytes={len(html)}  → {out_path}")
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
