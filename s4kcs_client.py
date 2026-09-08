"""S4K CRM API client — marketplace orders + N2S (read-only).

Host: https://crm.s4kcs.com/api/v1
Auth: an `X-API-Key: s4k_…` header, resolved arg → env `S4KCS_API_KEY` →
Supabase Vault (`crm.s4kcs.com`), mirroring the other clients.

Why this exists: our own ingest covers four order books (EVO, SeatGeek,
TickPick, Vivid). The CRM aggregates open sell-side orders from SIX
marketplaces, adding **StubHub and Gametime — which we ingest nowhere**. The
substitution checker's order lookup falls back to it so a broker can paste any
marketplace's order number instead of retyping the sold ticket by hand.

The CRM's SECOND book is **N2S ("Need to Sub")**: orders that need a substitute
— the ones agents add by hand from Order Lookup, plus the ones the CRM picks up
automatically from Automatiq failed-order alerts across every marketplace. Same
host and same `X-API-Key` scheme, but a different scope on the key
(**`n2s:read`**); `ping()` reports the scopes a key actually carries. Unlike the
marketplace book it reads the CRM's own database — no Gmail or marketplace
round-trip — so it answers in milliseconds, has no 10/min live-fetch limit, and
needs no cache. Likewise GET-only.

Endpoints used (all GET — per its own docs the API has no write surface):
  GET /ping                          key check + the key's scopes
  GET /marketplace/marketplaces      the six markets + whether creds are set
  GET /marketplace/columns           the column set every order row carries
  GET /marketplace/orders            live fetch across markets (can take ~60s)
  GET /n2s/meta                      workflow definition (statuses/transitions)
  GET /n2s/intake                    health of the Automatiq intake loop
  GET /n2s/items                     the N2S book — filter / page / CSV
  GET /n2s/items/{id}                one row + history, raw fields, payload
  GET /n2s/items/{id}/history        just that row's events, oldest first
  GET /n2s/orders/{order_number}     the same row by marketplace order number
  GET /n2s/stats                     counts for dashboards

Rate limits are 120 req/min general (which covers all of `/api/v1`, N2S
included) but only **10/min** on the marketplace live-fetch endpoints, and one
fetch returns every open order (tens of thousands of rows, ~10 MB). So
`orders()` memoises per parameter set for `cache_ttl` seconds and `find_order`
scans that cached list — the API has no by-id endpoint. The N2S endpoints are
cheap and filterable, so they are passed straight through.

Timestamps: every instant the CRM returns is UTC with a trailing `Z`. The ONE
exception is `event_dt` — the venue-local show time as printed on the ticket,
with no zone at all. Never read it as UTC.

RULE 2: this is an upstream read source like the order/listing clients. The
runtime guard below raises on any non-GET before a network call is made.
"""
from __future__ import annotations

import os
import time
from datetime import datetime, timezone
from typing import Any, Iterator
from urllib.parse import quote

import requests

from core.http_retry import fetch_with_retry
from core.vault import vault_secret


# RULE 2 — READ-ONLY against crm.s4kcs.com. Every documented endpoint is a GET;
# any non-GET attempt raises before a network call is made. Pairs with the
# static audit in scripts/check_readonly.py and tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class S4KCSError(RuntimeError):
    pass


class S4KCSReadOnlyError(S4KCSError):
    """Raised when a non-GET method is attempted against the S4K CRM."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    S4KCSReadOnlyError, ALLOWED_HTTP_METHODS,
    "Reading marketplace orders only — never write back to crm.s4kcs.com.",
)

# The single Vault name carrying the key. It was also seeded as
# `EVENUEDESK_API_KEY`; that duplicate was deleted so one name owns the secret
# and a rotation has exactly one place to land.
VAULT_SECRET_NAME = "crm.s4kcs.com"

# N2S vocabulary, mirrored from `GET /n2s/meta` so a typo is a ValueError here
# instead of a 400/422 round trip. `/meta` stays the source of truth: if the CRM
# ships a new status or sort key, widen these — never silently drop the filter.
N2S_STATUSES = frozenset({"n2s", "subbed", "resolved", "no_subs", "allocated"})
N2S_SOURCES = frozenset({"manual", "automatiq"})
N2S_SORT_KEYS = frozenset({"updated_at", "created_at", "alert_at", "event_dt"})
N2S_ORDER_BYS = frozenset({"asc", "desc"})
N2S_MAX_LIMIT = 1000  # the API's own ceiling; over it answers 422

# {(markets, ev_from, ev_to): (fetched_at_monotonic, rows)}. Module-level so the
# cache survives per-request client construction in the route.
_ORDERS_CACHE: dict[tuple, tuple[float, list[dict[str, Any]]]] = {}


def _resolve_key(api_key: str | None, db: Any | None) -> str | None:
    """arg → env → vault. Never logs the value."""
    if api_key:
        return api_key
    env = os.environ.get("S4KCS_API_KEY")
    if env:
        return env
    return vault_secret(
        db, VAULT_SECRET_NAME,
        on_error=lambda e: print(f"s4kcs: vault lookup failed: {e}"),
    )


def _error_detail(resp: Any) -> str:
    """`": <detail>"` from an error body, or `""`.

    The CRM answers every error with `{"detail": "…"}` and that text names the
    actual problem — a 403 says the key lacks the `n2s:read` scope, a 422 says
    which parameter is out of range. Worth carrying into the exception; the
    request (and so the key) is never included.
    """
    try:
        body = resp.json()
    except ValueError:
        return ""
    detail = body.get("detail") if isinstance(body, dict) else None
    return f": {detail}" if isinstance(detail, str) and detail.strip() else ""


def _instant(value: Any) -> str | None:
    """Render a datetime as the UTC `…Z` instant the API expects; pass strings
    through untouched (a bare `YYYY-MM-DD` is valid for the alert window).

    A naive datetime is read as UTC — the CRM's own screens render Eastern, so
    a local-time value passed here without a tzinfo would silently shift the
    window; attach a tzinfo when that matters.
    """
    if value is None:
        return None
    if isinstance(value, datetime):
        aware = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return aware.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    text = str(value).strip()
    return text or None


class S4KCSClient:
    BASE_URL = "https://crm.s4kcs.com/api/v1"

    def __init__(self, api_key: str | None = None, db: Any | None = None,
                 *, timeout: int = 120, cache_ttl: float = 600.0):
        key = _resolve_key(api_key, db)
        if not key:
            raise S4KCSError(
                "S4KCS API key not found. Either pass api_key, set the "
                "S4KCS_API_KEY env var, or store it in Supabase Vault as "
                "'crm.s4kcs.com' (whitelisted in public.get_app_secret())."
            )
        # The vault copy was seeded with a leading space, which makes the
        # header invalid. That value has been normalized, but a re-paste can
        # reintroduce it and the failure is an opaque 401 — so strip rather
        # than depend on the stored value being clean (as TEVO_SECRET does).
        self.api_key = key.strip()
        self.timeout = timeout
        self.cache_ttl = cache_ttl

    # ---------- transport ----------

    def _get(self, path: str, params: dict | None = None, *,
             raw: bool = False, not_found_ok: bool = False) -> Any:
        """One GET. `raw` returns the body as text (the CSV export is not
        JSON); `not_found_ok` turns a 404 into `None` for the lookups whose
        documented answer to "no such row" is a 404, not an error."""
        _assert_readonly_method("GET")  # RULE 2 enforcement
        url = f"{self.BASE_URL}{path}"
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        headers = {"X-API-Key": self.api_key, "Accept": "application/json"}
        try:
            r = fetch_with_retry(
                lambda: requests.get(url, headers=headers, params=clean,
                                     timeout=self.timeout),
                max_retries=4, retry_statuses=frozenset({429, 503}),
                base_backoff=0.5, max_backoff=30.0, sleep=time.sleep,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            raise S4KCSError(f"network error: {type(e).__name__}") from e
        if r.status_code == 404 and not_found_ok:
            return None
        if not r.ok:
            raise S4KCSError(f"HTTP {r.status_code}{_error_detail(r)}")
        if raw:
            return r.text
        try:
            return r.json()
        except ValueError:
            return {"raw_text": r.text}

    # ---------- endpoints ----------

    def ping(self) -> dict[str, Any]:
        """GET /ping — confirms the key works. `{ok, key, scopes, expires_at}`."""
        body = self._get("/ping")
        return body if isinstance(body, dict) else {}

    def marketplaces(self) -> list[dict[str, Any]]:
        """GET /marketplace/marketplaces — `[{name, key, configured}, …]`."""
        body = self._get("/marketplace/marketplaces")
        return (body or {}).get("marketplaces", []) if isinstance(body, dict) else []

    def columns(self) -> list[str]:
        """GET /marketplace/columns — the column set every order row carries."""
        body = self._get("/marketplace/columns")
        return (body or {}).get("columns", []) if isinstance(body, dict) else []

    def orders(self, *, markets: str | None = None, ev_from: str | None = None,
               ev_to: str | None = None, use_cache: bool = True) -> list[dict[str, Any]]:
        """GET /marketplace/orders — open sell-side orders across marketplaces.

        Memoised for `cache_ttl` seconds per parameter set: the live fetch is
        rate-limited to 10/min and returns the whole book, so repeated lookups
        must not each hit it. `use_cache=False` forces a refresh.

        A marketplace that fails its own fetch is reported in the response's
        `errors` and simply contributes no rows — the others still return, so
        this never raises on a partial outage.
        """
        cache_key = (markets, ev_from, ev_to)
        now = time.monotonic()
        if use_cache:
            hit = _ORDERS_CACHE.get(cache_key)
            if hit is not None and (now - hit[0]) < self.cache_ttl:
                return hit[1]
        body = self._get("/marketplace/orders", {
            "markets": markets, "ev_from": ev_from, "ev_to": ev_to,
        })
        rows = body.get("rows", []) if isinstance(body, dict) else []
        rows = rows if isinstance(rows, list) else []
        _ORDERS_CACHE[cache_key] = (now, rows)
        return rows

    def find_order(self, order_id: str, **kwargs: Any) -> dict[str, Any] | None:
        """The open order with this marketplace order id, or None.

        The API has no by-id endpoint, so this scans the (cached) order list.
        Ids are strings there; compared as trimmed strings so a caller passing
        an int or a padded value still matches.
        """
        wanted = str(order_id or "").strip()
        if not wanted:
            return None
        for row in self.orders(**kwargs):
            if str(row.get("id") or "").strip() == wanted:
                return row
        return None

    # ---------- N2S (Need to Sub) ----------
    #
    # A key must carry the `n2s:read` scope for any of these; a 403 means the
    # key is valid but unscoped (`ping()["scopes"]` says which it has). Every
    # instant returned is UTC `…Z` — except `event_dt`, which is venue-local.

    def _n2s_query(self, *, status: str | None = None, source: str | None = None,
                   marketplace: str | None = None, search: str | None = None,
                   order: str | None = None, include_allocated: bool = False,
                   alert_from: Any = None, alert_to: Any = None,
                   updated_since: Any = None, sort: str | None = None,
                   order_by: str | None = None, limit: int | None = None,
                   offset: int | None = None) -> dict[str, Any]:
        """Validate + render the `/n2s/items` filter set. Unknown values raise
        `ValueError` locally rather than spending a request on a 400/422."""
        if status is not None and status not in N2S_STATUSES:
            raise ValueError(f"status must be one of {sorted(N2S_STATUSES)}")
        if source is not None and source not in N2S_SOURCES:
            raise ValueError(f"source must be one of {sorted(N2S_SOURCES)}")
        if sort is not None and sort not in N2S_SORT_KEYS:
            raise ValueError(f"sort must be one of {sorted(N2S_SORT_KEYS)}")
        if order_by is not None and order_by not in N2S_ORDER_BYS:
            raise ValueError("order_by must be 'asc' or 'desc'")
        if limit is not None and not 1 <= limit <= N2S_MAX_LIMIT:
            raise ValueError(f"limit must be between 1 and {N2S_MAX_LIMIT}")
        if offset is not None and offset < 0:
            raise ValueError("offset must not be negative")
        return {
            "status": status, "source": source, "marketplace": marketplace,
            "search": search, "order": order,
            # Sent only when set: `false` is the server's own default, and the
            # flag is ignored outright when `status` is given.
            "include_allocated": "true" if include_allocated else None,
            "alert_from": _instant(alert_from), "alert_to": _instant(alert_to),
            "updated_since": _instant(updated_since),
            "sort": sort, "order_by": order_by,
            "limit": limit, "offset": offset,
        }

    def n2s_meta(self) -> dict[str, Any]:
        """GET /n2s/meta — the workflow definition: statuses (+ their Gmail
        labels and which are terminal), legal transitions, sources, the seven
        marketplaces, `csv_columns`, `sort_keys` and `timer_minutes`.

        It changes only with a CRM deploy, so cache it caller-side rather than
        re-fetching per poll.
        """
        body = self._get("/n2s/meta")
        return body if isinstance(body, dict) else {}

    def n2s_intake(self) -> dict[str, Any]:
        """GET /n2s/intake — health of the automated Automatiq intake loop.

        Read this before trusting an empty `n2s_items()`: `running` or
        `gmail_connected` false, or a `last_pass.error`, means the absence of
        rows is the loop's, not the book's.
        """
        body = self._get("/n2s/intake")
        return body if isinstance(body, dict) else {}

    def n2s_items(self, **filters: Any) -> dict[str, Any]:
        """GET /n2s/items — one page of the N2S book.

        Filters (all optional, all validated by `_n2s_query`): `status`,
        `source`, `marketplace`, `search`, `order`, `include_allocated`,
        `alert_from`, `alert_to`, `updated_since`, `sort`, `order_by`,
        `limit`, `offset`.

        Returns the API's own envelope — `count` / `total` / `limit` /
        `offset` / `items` / `filters` / `generated_at` — not just the rows:
        `total` is what drives paging, and `generated_at` is the cursor for an
        incremental mirror (feed it back as the next call's `updated_since`).
        `items` is always a list.

        Allocated rows (filled from our own inventory, no sub needed) are
        excluded unless asked for by `status="allocated"` or
        `include_allocated=True`.
        """
        body = self._get("/n2s/items", self._n2s_query(**filters))
        body = body if isinstance(body, dict) else {}
        rows = body.get("items")
        body["items"] = rows if isinstance(rows, list) else []
        return body

    def n2s_iter_items(self, *, page_size: int = 200,
                       max_items: int | None = None,
                       **filters: Any) -> Iterator[dict[str, Any]]:
        """Yield every matching row, paging by offset until the book runs out.

        The loop owns `limit`/`offset`, so passing either raises. Page with a
        stable ascending sort (`sort="updated_at", order_by="asc"` for the
        mirror recipe) — under the default descending `updated_at` a row
        touched mid-walk moves between pages and can be seen twice or skipped.
        """
        if "limit" in filters or "offset" in filters:
            raise ValueError("n2s_iter_items owns limit/offset — filter without them")
        if not 1 <= page_size <= N2S_MAX_LIMIT:
            raise ValueError(f"page_size must be between 1 and {N2S_MAX_LIMIT}")
        offset = yielded = 0
        while True:
            page = self.n2s_items(limit=page_size, offset=offset, **filters)
            rows = page["items"]
            if not rows:
                return
            for row in rows:
                yield row
                yielded += 1
                if max_items is not None and yielded >= max_items:
                    return
            if len(rows) < page_size:
                return
            offset += len(rows)
            total = page.get("total")
            # Belt-and-braces: without this, a server that ignored `offset`
            # would hand back a full page forever and the walk never ends.
            if isinstance(total, int) and offset >= total:
                return

    def n2s_items_csv(self, **filters: Any) -> str:
        """GET /n2s/items?format=csv — the same rows flattened to CSV text,
        columns per `/meta`'s `csv_columns`. Returned as the raw body: it is
        not JSON, so it never goes near the JSON decoder."""
        params = self._n2s_query(**filters)
        params["format"] = "csv"
        return self._get("/n2s/items", params, raw=True)

    def _n2s_one(self, path: str, include_body: bool) -> dict[str, Any] | None:
        body = self._get(path, {"include": "body"} if include_body else None,
                         not_found_ok=True)
        if body is None:
            return None
        return body if isinstance(body, dict) else {}

    def n2s_item(self, item_id: Any, *, include_body: bool = False) -> dict[str, Any] | None:
        """GET /n2s/items/{id} — one row by CRM id, with everything the list
        returns plus `events` (its history), `deliveries`, `raw_fields` (the
        raw parsed tables, keyed by where they came from) and `payload_json`
        (the webhook envelope the CRM would send). `None` when there is no
        such row.

        `include_body=True` also pulls `body_html` / `source_body_html` — the
        sales-email and alert HTML, which are large; leave it off for polling.
        """
        ident = str(item_id or "").strip()
        if not ident:
            return None
        return self._n2s_one(f"/n2s/items/{quote(ident, safe='')}", include_body)

    def n2s_order(self, order_number: Any, *, include_body: bool = False) -> dict[str, Any] | None:
        """GET /n2s/orders/{order_number} — the same item addressed by the
        marketplace's order number instead of the CRM id.

        `None` means the order was never in N2S. That is the API's documented
        404 and a normal answer here, not a failure — it is how the broker's
        order lookup asks "does this one need a sub?".
        """
        ident = str(order_number or "").strip()
        if not ident:
            return None
        return self._n2s_one(f"/n2s/orders/{quote(ident, safe='')}", include_body)

    def n2s_history(self, item_id: Any) -> list[dict[str, Any]]:
        """GET /n2s/items/{id}/history — that row's events, oldest first.

        Unlike `n2s_item`, an unknown id raises: every real row carries at
        least its `created` event, so an empty list means "no history", never
        "no such row", and conflating the two would hide a bad id.
        """
        ident = str(item_id or "").strip()
        if not ident:
            return []
        body = self._get(f"/n2s/items/{quote(ident, safe='')}/history")
        events = body.get("events") if isinstance(body, dict) else None
        return events if isinstance(events, list) else []

    def n2s_stats(self, *, alert_from: Any = None, alert_to: Any = None) -> dict[str, Any]:
        """GET /n2s/stats — counts for dashboards.

        `by_status` / `by_source` always cover every row; `alert_from` /
        `alert_to` bound only the `automated_window` section, which otherwise
        defaults to the intake window (since yesterday midnight Eastern).
        """
        body = self._get("/n2s/stats", {"alert_from": _instant(alert_from),
                                        "alert_to": _instant(alert_to)})
        return body if isinstance(body, dict) else {}
