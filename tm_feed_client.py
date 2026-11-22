"""Ticketmaster Discovery Feed file reader (read-only).

The Discovery Feed is Ticketmaster's whole public catalogue as one file per country
(https://developer.ticketmaster.com/products-and-docs/apis/discovery-feed/). The list of files is
asked for inside the database (`tm_feed_check()`, mig 20261122030530), where the API key lives; the
list names a `.csv.gz` on S3 that needs no key. This module only downloads that file and reads it:

  download(uri, dest, md5)   GET the file the list named, to disk, checking the address against one
                             fixed pattern and the content against the list's checksum
  rows(path)                 the rows of the file, the columns we keep, under short keys

Nothing here holds or sends a key, and nothing is ever written to Ticketmaster or to its bucket
(RULE 2). The same address pattern is enforced in SQL by `tm_feed_uri_ok()`.
"""
from __future__ import annotations

import csv
import gzip
import hashlib
import re
from typing import Any, Iterator

import requests

from core.readonly_guard import build_readonly_guard

# RULE 2 — READ-ONLY. One GET of a public feed file; any other method raises before a network call.
# Paired with the static check in scripts/check_readonly.py and tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class TmFeedError(RuntimeError):
    pass


class TmFeedReadOnlyError(TmFeedError):
    """Raised when a non-GET method is attempted against the Ticketmaster feed."""


# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    TmFeedReadOnlyError, ALLOWED_HTTP_METHODS,
    "Downloading the feed file only — never write to Ticketmaster or its feed bucket.",
)

# the only address a feed file may come from: Ticketmaster's feed bucket, a US or CA events file
URI_OK = re.compile(r"^https://s3\.amazonaws\.com/[A-Za-z0-9.-]+\.tmaws-feeds/[0-9]{8}/"
                    r"EVENTS_RAW-(US|CA)-[0-9a-f-]{36}-[0-9_-]+\.csv\.gz$")
MAX_BYTES = 400 * 1024 * 1024          # the US file is about 52 MB; refuse anything absurd
CHUNK = 1 << 20

# short key -> the feed's column. Prices and the resale link are columns of the feed but empty in
# every row (checked 2026-11-22), and images are not wanted, so none of those is read.
COLUMNS = {
    "id": "EVENT_ID", "name": "EVENT_NAME", "st": "EVENT_STATUS", "start": "EVENT_START_DATETIME",
    "end": "EVENT_END_DATETIME", "ld": "EVENT_START_LOCAL_DATE", "lt": "EVENT_START_LOCAL_TIME",
    "on": "ONSALE_START_DATETIME", "on_end": "ONSALE_END_DATETIME",
    "seg": "CLASSIFICATION_SEGMENT", "gen": "CLASSIFICATION_GENRE", "sub": "CLASSIFICATION_SUB_GENRE",
    "typ": "CLASSIFICATION_TYPE", "styp": "CLASSIFICATION_SUB_TYPE",
    "aname": "ATTRACTION_NAME", "aid": "ATTRACTION_ID", "laid": "LEGACY_ATTRACTION_ID",
    "vid": "VENUE_ID", "lvid": "LEGACY_VENUE_ID", "vname": "VENUE_NAME", "vaddr": "VENUE_STREET",
    "vcity": "VENUE_CITY", "vstate": "VENUE_STATE_CODE", "vcc": "VENUE_COUNTRY_CODE",
    "vzip": "VENUE_ZIP_CODE", "vlat": "VENUE_LATITUDE", "vlon": "VENUE_LONGITUDE", "vtz": "VENUE_TIMEZONE",
    "url": "PRIMARY_EVENT_URL", "lid": "LEGACY_EVENT_ID", "src": "SOURCE", "prom": "PROMOTER_NAME",
    "brand": "BRAND_NAME", "off": "OFFICIAL_SELLER", "tx": "TRANSACTABLE", "hot": "HOT_EVENT",
}
BOOLS = ("off", "tx", "hot")


def _bool(value: str) -> bool | None:
    """The feed writes 'true' / 'false' / nothing."""
    return {"true": True, "false": False}.get((value or "").strip().lower())


def download(uri: str, dest: str, md5: str | None = None, *, session: Any = None, timeout: int = 300) -> int:
    """GET one feed file to `dest`; returns its size in bytes. Refuses any address but a US or CA
    events file in Ticketmaster's feed bucket, a redirect, a file larger than MAX_BYTES, and content
    whose MD5 is not the one the file list gave."""
    _assert_readonly_method("GET")
    if not URI_OK.match(uri or ""):
        raise TmFeedError("not a Ticketmaster feed file address")
    http = session or requests
    digest, size = hashlib.md5(), 0  # noqa: S324 - the feed publishes an MD5; it is a transfer check, not security
    with http.get(uri, stream=True, timeout=timeout, allow_redirects=False) as resp:
        if resp.status_code != 200:
            raise TmFeedError(f"feed file answered http {resp.status_code}")
        with open(dest, "wb") as out:
            for chunk in resp.iter_content(CHUNK):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise TmFeedError("feed file is larger than expected")
                digest.update(chunk)
                out.write(chunk)
    if md5 and digest.hexdigest() != md5.strip().lower():
        raise TmFeedError("feed file checksum does not match the file list")
    return size


def rows(path: str) -> Iterator[dict]:
    """The rows of a downloaded feed file as dicts under the short keys of COLUMNS. A row with a
    different number of fields than the header, or with no event id, is left out: the database
    compares the count it received with the count the file list gave, so a damaged file is refused
    as a whole rather than half loaded."""
    csv.field_size_limit(1 << 30)          # EVENT_INFO runs to 10,000 characters and more
    with gzip.open(path, "rt", encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.reader(handle)
        head = next(reader, None) or []
        index: dict[str, int] = {}
        for i, name in enumerate(head):
            index.setdefault(name, i)      # PRESALE_NAME is there twice: the first one counts
        missing = sorted(col for col in COLUMNS.values() if col not in index)
        if missing:
            raise TmFeedError(f"feed file is missing columns: {', '.join(missing)}")
        for rec in reader:
            if len(rec) != len(head) or not rec[index["EVENT_ID"]]:
                continue
            row: dict = {key: rec[index[col]] for key, col in COLUMNS.items()}
            for key in BOOLS:
                row[key] = _bool(row[key])
            yield row
