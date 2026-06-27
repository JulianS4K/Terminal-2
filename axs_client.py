"""AXS event-data client (read-only).

AXS is a PRIMARY box-office ticketer (api backend: "veritix"). It is the
hardest platform to read — even a fan can't see an event's seat map / price
book without driving the live purchase flow. We reach it only through an
operator-provided data endpoint that drives that flow server-side and returns
a single fully-generated JSON document per event (~20–40s, credit-metered).

There is NO write surface here and there must never be one: AXS has order /
hold / checkout endpoints and this client must NEVER touch them. Like every
other *_client.py (evo/seatgeek/tickpick/vivid/seatdata/ticketsdata/broadway)
we enforce GET-only at the transport layer so scripts/check_readonly.py +
tests/test_readonly_guards.py can prove the read-only contract (CLAUDE.md §2).

Endpoint (confirmed live 2026-06-09): TicketsData /fetch with platform=axs and
the axs.com event URL — GET https://ticketsdata.com/fetch?platform=axs&
event_url=<axs url>&username=&password= . Uses the SHARED TicketsData account.

Config (never hardcoded; env -> Supabase Vault, never logged):
  TICKETSDATA_USERNAME / TICKETSDATA_PASSWORD   shared account (preferred)
  AXS_USERNAME / AXS_PASSWORD   AXS-specific override (optional)
  AXS_ENDPOINT_URL   override (default https://ticketsdata.com/fetch)
  AXS_PLATFORM       override (default 'axs')
  AXS_API_KEY        alternative bearer/key auth (used if no user/pass)

Pegging: pull() resolves the event's venue against public.axs_venues (the
AXS.com venue catalog we ingested) and attaches the match — including the
canonical tevo_venue_id when one exists — so every AXS pull is tied to that
reference list.
"""
from __future__ import annotations

import os
import re
import time
from typing import Any

import requests


# Read-only by design — mirrors the RULE 2 guard the other clients use.
# AXS has write endpoints (orders/holds); this client can issue NONE of them.
ALLOWED_HTTP_METHODS = frozenset({"GET"})

# Only these event links are supported, per the operator:
#   https://www.axs.com/events/<id>/<slug>-event-tickets
AXS_EVENT_URL_RE = re.compile(r"^https?://(?:www\.)?axs\.com/events/\d+(?:/|$)", re.I)

# Retry on transient statuses; never on deterministic ones.
_RETRY_STATUSES = (429, 503, 504)


class AXSError(RuntimeError):
    pass


class AXSReadOnlyError(AXSError):
    """Raised when a non-GET method is attempted against AXS."""


class AXSConfigError(AXSError):
    """Missing endpoint or credentials."""


class AXSAuthError(AXSError):
    """401 — bad credentials."""


class AXSQuotaError(AXSError):
    """402 — plan quota exhausted."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    AXSReadOnlyError, ALLOWED_HTTP_METHODS,
    "Pulling event data only — never drive the AXS order/hold flow.",
)


def venue_norm(name: str) -> str:
    """Normalize a venue name the SAME way public.axs_venues.axs_name_norm is
    generated, so a lookup is a plain equality: lower -> strip leading 'the '
    -> drop non-[a-z0-9]. Empty (CJK/accent-only) falls back to a 'cjk:' key."""
    s = re.sub(r"[^a-z0-9]+", "", re.sub(r"^the ", "", (name or "").strip().lower()))
    return s if s else ("cjk:" + (name or "").strip().lower())


def _vault_secret(db: Any, name: str) -> str | None:
    """Resolve a secret from Supabase Vault via get_app_secret (service-role db),
    matching seatgeek_client / ticketsdata_client. Never surfaces the value."""
    if db is None:
        return None
    try:
        res = db.rpc("get_app_secret", {"p_name": name}).execute()
        return getattr(res, "data", None) or None
    except Exception as e:  # only the failure, never the value
        print(f"axs: vault lookup for {name} failed: {e}")
        return None


# --------------------------------------------------------------------------
# Distiller — canonical parser for the raw ~1.8MB AXS document. Kept here so
# the client owns its data contract; scripts/axs_parse.py is a thin CLI over it.
# AXS amounts are in CENTS. Resale (AXS Marketplace / FlashSeats resale) is
# identified by a `resale-fee-<offerID>` entry in prices.fees.
# --------------------------------------------------------------------------

def _c2d(cents: Any) -> float | None:
    return None if cents is None else round(cents / 100.0, 2)


def distill(doc: dict) -> dict:
    body = doc.get("body", {}) or {}
    meta = body.get("meta", {}) or {}
    sections = body.get("sections", {}) or {}
    prices = body.get("prices", {}) or {}
    offers = (body.get("offers", {}) or {}).get("offers", []) or []
    startflow = body.get("startflow", {}) or {}

    resale_ids = {
        str(f["id"]).split("resale-fee-", 1)[1]
        for f in prices.get("fees", []) or []
        if str(f.get("id", "")).startswith("resale-fee-")
    }

    pl_base: dict[str, float] = {}
    for op in prices.get("offerPrices", []) or []:
        if str(op.get("offerID")) in resale_ids:
            continue
        for zp in op.get("zonePrices", []) or []:
            for pl in zp.get("priceLevels", []) or []:
                plid = str(pl.get("priceLevelID"))
                for pr in pl.get("prices", []) or []:
                    b = _c2d(pr.get("base"))
                    if b is not None:
                        pl_base[plid] = min(b, pl_base.get(plid, b))

    sec_rows: list[dict] = []
    getins: list[float] = []
    for label, s in sections.items():
        avail = s.get("availability", {}) or {}
        qty = sum(p.get("amount", 0) or 0 for p in avail.get("prices", []) or [])
        pls = [str(p.get("priceLevel")) for p in avail.get("prices", []) or []]
        bases = [pl_base[p] for p in pls if p in pl_base]
        is_resale = any(str(o) in resale_ids for o in s.get("offerIDs", []) or [])
        if qty > 0 and bases:
            getins.append(min(bases))
        sec_rows.append({
            "section": label,
            "neighborhood": s.get("neighborhoodDescription"),
            "ga": s.get("isGeneralAdmission"),
            "sold_out": avail.get("isSoldOut"),
            "avail_qty": qty,
            "price_min": min(bases) if bases else None,
            "price_max": max(bases) if bases else None,
            "seat_types": s.get("seatTypes"),
            "has_resale": is_resale,
            "connection_fee": s.get("connectionFee"),
        })

    seats_primary = seats_resale = 0
    for o in offers:
        n = len(o.get("items", []) or [])
        if str(o.get("offerID")) in resale_ids:
            seats_resale += n
        else:
            seats_primary += n

    return {
        "event": meta.get("event"),
        "venue": meta.get("venue"),
        "event_date": meta.get("event_date"),
        "tz": meta.get("event_date_zone"),
        "api": meta.get("api"),
        "onsale_status": startflow.get("onSaleStatus"),
        "currency": prices.get("currency"),
        "response_s": doc.get("response_s"),
        "quota_remaining": doc.get("quota_remaining"),
        "totals": {
            "listings": meta.get("listings"),
            "sections": meta.get("sections_count"),
            "offers": meta.get("offer_groups"),
            "price_min": meta.get("price_min"),
            "price_max": meta.get("price_max"),
            "get_in_available": min(getins) if getins else None,
            "seats_primary": seats_primary,
            "seats_resale": seats_resale,
        },
        "sections": sorted(
            sec_rows, key=lambda r: (r["price_min"] is None, r["price_min"] or 0)
        ),
    }


# --------------------------------------------------------------------------
# Normalization — distilled payload -> rows for public.axs_event_snapshots +
# public.axs_section_snapshots (fits the per-source snapshot convention).
# --------------------------------------------------------------------------

AXS_EVENT_ID_RE = re.compile(r"/events/(\d+)", re.I)


def axs_event_id_from_url(url: str | None) -> str | None:
    m = AXS_EVENT_ID_RE.search(url or "")
    return m.group(1) if m else None


def _parse_dt(s: Any) -> str | None:
    """AXS on-sale dates look like '2026-05-29 14:00:00 +0000' -> ISO tz string."""
    if not s:
        return None
    from datetime import datetime
    for fmt in ("%Y-%m-%d %H:%M:%S %z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.strptime(str(s), fmt).isoformat()
        except ValueError:
            continue
    return str(s)


def _occurs_at_local(event_date: Any, tz: Any) -> str | None:
    """Render the event's local datetime offset-bearing, matching public.events
    .occurs_at_local. meta.event_date is naive local ('2026-10-04T19:00:00');
    apply the IANA tz to get the offset. Falls back to the naive text."""
    if not event_date:
        return None
    try:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        dt = datetime.fromisoformat(str(event_date).replace("Z", ""))
        if tz:
            dt = dt.replace(tzinfo=ZoneInfo(str(tz)))
        return dt.isoformat()
    except Exception:
        return str(event_date)


def normalize(
    doc: dict,
    *,
    event_url: str | None = None,
    tevo_venue_id: int | None = None,
    tevo_event_id: int | None = None,
    aq_short_event_id: str | None = None,
    venue_short_id: str | None = None,
    in_axs_list: bool | None = None,
    canonical_matched: bool | None = None,
) -> dict[str, Any]:
    """Turn a raw AXS document into insert-ready rows:
    {"event_snapshot": {<axs_event_snapshots cols>},
     "sections":       [<axs_section_snapshots cols>, ...]}."""
    s = distill(doc)
    t = s.get("totals", {})
    onsale = s.get("onsale_status") or {}
    axs_event_id = axs_event_id_from_url(event_url)

    event_snapshot = {
        "axs_event_id": axs_event_id,
        "event_url": event_url,
        "tevo_event_id": tevo_event_id,
        "tevo_venue_id": tevo_venue_id,
        "aq_short_event_id": aq_short_event_id,
        "venue_short_id": venue_short_id,
        "event_name": s.get("event"),
        "venue_name": s.get("venue"),
        "occurs_at_local": _occurs_at_local(s.get("event_date"), s.get("tz")),
        "event_tz": s.get("tz"),
        "api": s.get("api"),
        "onsale_now": onsale.get("onSaleNow"),
        "onsale_at": _parse_dt(onsale.get("onSaleDate")),
        "offsale_at": _parse_dt(onsale.get("offSaleDate")),
        "currency": s.get("currency"),
        "price_min": t.get("price_min"),
        "price_max": t.get("price_max"),
        "getin": t.get("get_in_available"),
        "listings_count": t.get("listings"),
        "sections_count": t.get("sections"),
        "offers_count": t.get("offers"),
        "seats_primary": t.get("seats_primary"),
        "seats_resale": t.get("seats_resale"),
        "in_axs_list": in_axs_list,
        "canonical_matched": canonical_matched,
        "response_s": s.get("response_s"),
        "quota_remaining": s.get("quota_remaining"),
        "raw": doc,
    }
    sections = [{
        "tevo_event_id": tevo_event_id,
        "tevo_venue_id": tevo_venue_id,
        "axs_event_id": axs_event_id,
        "section_label": r["section"],
        "neighborhood": r["neighborhood"],
        "is_ga": r["ga"],
        "sold_out": r["sold_out"],
        "avail_qty": r["avail_qty"],
        "price_min": r["price_min"],
        "price_max": r["price_max"],
        "seat_types": r["seat_types"],
        "has_resale": r["has_resale"],
        "connection_fee": r["connection_fee"],
    } for r in s.get("sections", [])]
    return {"event_snapshot": event_snapshot, "sections": sections}


class AXSClient:
    # Confirmed live 2026-06-09: AXS is served by TicketsData's /fetch with
    # platform=axs, using the SAME TICKETSDATA_* account creds.
    DEFAULT_ENDPOINT = "https://ticketsdata.com/fetch"

    def __init__(
        self,
        endpoint: str | None = None,
        username: str | None = None,
        password: str | None = None,
        api_key: str | None = None,
        *,
        db: Any = None,
        timeout: int = 90,            # AXS generation is slow (20–40s, sometimes more)
        platform: str | None = None,
        url_param: str | None = None,
    ):
        # Resolution order mirrors the other clients: arg -> env -> Vault, then
        # the confirmed default endpoint.
        self.endpoint = (
            endpoint or os.environ.get("AXS_ENDPOINT_URL")
            or _vault_secret(db, "AXS_ENDPOINT_URL") or self.DEFAULT_ENDPOINT
        )
        # AXS shares the TicketsData account — fall back to TICKETSDATA_* creds.
        self._user = (username or os.environ.get("AXS_USERNAME")
                      or os.environ.get("TICKETSDATA_USERNAME")
                      or _vault_secret(db, "AXS_USERNAME")
                      or _vault_secret(db, "TICKETSDATA_USERNAME"))
        self._pass = (password or os.environ.get("AXS_PASSWORD")
                      or os.environ.get("TICKETSDATA_PASSWORD")
                      or _vault_secret(db, "AXS_PASSWORD")
                      or _vault_secret(db, "TICKETSDATA_PASSWORD"))
        self._key = api_key or os.environ.get("AXS_API_KEY") or _vault_secret(db, "AXS_API_KEY")
        if not (self._user and self._pass) and not self._key:
            raise AXSConfigError(
                "AXS credentials required. Set TICKETSDATA_USERNAME + "
                "TICKETSDATA_PASSWORD (shared account), AXS_USERNAME/AXS_PASSWORD, "
                "or AXS_API_KEY (env or Vault)."
            )
        self.timeout = timeout
        self.platform = platform or os.environ.get("AXS_PLATFORM", "axs")
        # The event URL is passed as this query param (TicketsData /fetch uses event_url).
        self.url_param = url_param or os.environ.get("AXS_URL_PARAM", "event_url")
        self._db = db

    @classmethod
    def from_env(cls, *, timeout: int = 60) -> "AXSClient":
        return cls(timeout=timeout)

    @classmethod
    def from_vault(cls, db: Any, *, timeout: int = 60) -> "AXSClient":
        return cls(db=db, timeout=timeout)

    # ---------- transport ----------

    def _get(self, params: dict) -> dict[str, Any]:
        _assert_readonly_method("GET")
        clean = {k: v for k, v in params.items() if v is not None}
        # Credentials live in params/headers, never in a logged/raised URL.
        headers = {}
        if self._user and self._pass:
            clean["username"] = self._user
            clean["password"] = self._pass
        elif self._key:  # pragma: no branch  (always true when reached: ctor guarantees a key when user/pass absent, so the elif-False arc is unreachable)
            headers["Authorization"] = f"Bearer {self._key}"

        r = None
        delays = [2.0, 5.0]
        for attempt in range(len(delays) + 1):  # pragma: no branch  (loop never exhausts: the final attempt always breaks, since attempt < len(delays) is False there)
            r = requests.get(self.endpoint, params=clean, headers=headers, timeout=self.timeout)
            if r.status_code in _RETRY_STATUSES and attempt < len(delays):
                retry_after = r.headers.get("Retry-After")
                try:
                    delay = float(retry_after) if retry_after else delays[attempt]
                except (TypeError, ValueError):
                    delay = delays[attempt]
                time.sleep(min(delay, 30.0))
                continue
            break

        if r.status_code == 401:
            raise AXSAuthError("HTTP 401 — invalid AXS credentials")
        if r.status_code == 402:
            raise AXSQuotaError("HTTP 402 — AXS plan quota exhausted")
        if not r.ok:
            raise AXSError(f"HTTP {r.status_code} on GET AXS endpoint")
        try:
            body = r.json()
        except ValueError:
            return {"raw_text": r.text}
        return body if isinstance(body, dict) else {"body": body}

    # ---------- endpoints ----------

    def fetch(self, event_url: str) -> dict[str, Any]:
        """GET the full live AXS document for one event URL (raw envelope:
        status / body / response_s / quota_remaining). 1 credit, ~20–40s."""
        if not event_url or not AXS_EVENT_URL_RE.match(event_url.strip()):
            raise AXSError(
                f"unsupported AXS event URL {event_url!r}; expected "
                "https://www.axs.com/events/<id>/<slug>-event-tickets"
            )
        return self._get({self.url_param: event_url.strip(), "platform": self.platform})

    # ---------- pegging to the axs_venues catalog ----------

    def resolve_venue(self, venue_name: str, *, db: Any = None) -> dict[str, Any]:
        """Look the event's venue up in public.axs_venues (the AXS.com catalog
        we ingested), keyed on the shared normalized name. Returns the match +
        canonical tevo_venue_id, or in_axs_list=False if the venue isn't there."""
        db = db or self._db
        norm = venue_norm(venue_name)
        miss = {"in_axs_list": False, "axs_name": None, "tevo_venue_id": None,
                "canonical_matched": False, "section": None, "venue_norm": norm}
        if db is None:
            return {**miss, "note": "no db client — venue not resolved"}
        try:
            res = (
                db.table("axs_venues")
                .select("axs_name, axs_name_norm, section, tevo_venue_id, match_method")
                .eq("axs_name_norm", norm)
                .limit(1)
                .execute()
            )
            rows = getattr(res, "data", None) or []
        except Exception as e:
            return {**miss, "note": f"axs_venues lookup failed: {e}"}
        if not rows:
            return miss
        row = rows[0]
        return {
            "in_axs_list": True,
            "axs_name": row.get("axs_name"),
            "section": row.get("section"),
            "tevo_venue_id": row.get("tevo_venue_id"),
            "canonical_matched": row.get("match_method") == "exact_norm",
            "venue_norm": norm,
        }

    def pull(self, event_url: str, *, db: Any = None, with_rows: bool = False) -> dict[str, Any]:
        """Fetch -> distill -> peg to axs_venues. One call, fully resolved.
        with_rows=True also attaches `normalized` (insert-ready snapshot rows)."""
        raw = self.fetch(event_url)
        summary = distill(raw)
        url = event_url.strip()
        summary["event_url"] = url
        peg = self.resolve_venue(summary.get("venue") or "", db=db)
        summary["axs_venue"] = peg
        if with_rows:
            summary["normalized"] = normalize(
                raw,
                event_url=url,
                tevo_venue_id=peg.get("tevo_venue_id"),
                in_axs_list=peg.get("in_axs_list"),
                canonical_matched=peg.get("canonical_matched"),
            )
        return summary

    def persist(self, db: Any, normalized: dict) -> int:
        """Insert one normalized pull into public.axs_event_snapshots (+ section
        rows). Returns the new snapshot_id. Requires a service-role db client.
        Writes to OUR Supabase only — never back to AXS."""
        if db is None:
            raise AXSConfigError("persist() requires a service-role db client")
        res = db.table("axs_event_snapshots").insert(normalized["event_snapshot"]).execute()
        rows = getattr(res, "data", None) or []
        snap_id = rows[0]["id"] if rows else None
        if snap_id is None:
            raise AXSError("axs_event_snapshots insert returned no id")
        secs = normalized.get("sections") or []
        if secs:
            db.table("axs_section_snapshots").insert(
                [{**r, "snapshot_id": snap_id} for r in secs]
            ).execute()
        return snap_id
