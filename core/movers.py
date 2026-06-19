"""The storefront "movers" engine — extracted from app.py (BR-CODE-1, the heavy
helper). Self-contained subsystem: builds the home/movers payload (Featured +
moving_fast / price_drops / climbing / specials rails) from owned TEvo inventory.

One-directional imports only: this module depends on core.helpers +
core.broker_helpers (never on app.py). app.py imports `compute_movers` and calls
it from the store/broker movers routes; everything else here is module-private.

Moved verbatim from app.py (the cluster was movers-exclusive): the 5 _section_*
builders, the 3 classifiers (_classify_marquee_competition / _has_canadian_team /
_classify_holiday_proximity) + their constants, and _compute_movers itself.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone, timedelta

# Shared helpers keep their historical _-prefixed names here so the moved bodies
# are byte-for-byte unchanged (one-directional: movers -> core, never reverse).
from core.helpers import (
    classify_playoff as _classify_playoff,
    classify_world_cup as _classify_world_cup,
    or_ilike_clause as _or_ilike_clause,
    is_speculative_event_name as _is_speculative_event_name,
)
from core.broker_helpers import bulk_performer_assets as _bulk_performer_assets


# ───────────────────────── classifiers + their constants ─────────────────────

_MARQUEE_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"^US\s+Open\s+Tennis\b", re.I),                 "US Open Tennis"),
    (re.compile(r"\bFormula\s*1\b|\bGrand\s+Prix\b", re.I),      "F1"),
    # Inter Miami AWAY only — when the matchup is "Inter Miami CF at <home>".
    # Home games carry less narrative interest (we're not catering to local
    # Miami buyers in this storefront's scope).
    (re.compile(r"^Inter\s+Miami\s+CF\s+at\s+", re.I),           "Inter Miami away"),
]


def _classify_marquee_competition(event_name: str | None) -> str | None:
    """Return a marquee-competition label for the event name, or None.
    Used by `_section_featured` to flag US Open / F1 / Inter Miami away
    games into the Featured rail regardless of pricing signals.
    """
    if not event_name:
        return None
    for pat, label in _MARQUEE_PATTERNS:
        if pat.search(event_name):
            return label
    return None


# Canadian team detection (2026-05-19 v4) — operator directive: Canadian
# holidays (Canada Day, Civic Holiday, etc.) should only tag events where
# a Canadian team is visiting an NYC venue. Otherwise the holiday window
# leaks "Canada Day" tags onto Yankees-Tigers games which is nonsensical
# for the consumer.
_CANADIAN_TEAM_RE = re.compile(
    r"\b("
    r"Toronto\s+(?:Blue\s+Jays|Raptors|FC|Maple\s+Leafs)|"
    r"Montréal?\s+Canadiens|CF\s+Montr|"
    r"Vancouver\s+(?:Canucks|Whitecaps)|"
    r"Edmonton\s+Oilers|Calgary\s+Flames|"
    r"Ottawa\s+Senators|Winnipeg\s+Jets"
    r")\b",
    re.IGNORECASE,
)


def _has_canadian_team(event_name: str | None) -> bool:
    """True if the event name mentions a Canadian major-league team. Used
    to gate Canadian holiday tagging in the NYC storefront."""
    if not event_name:
        return False
    return bool(_CANADIAN_TEAM_RE.search(event_name))


# Holiday priority — higher wins on same-day conflicts (operator directive
# 2026-05-19 v4: "Father's Day over Juneteenth when they conflict on same
# day"). Generic ranking favors family-celebration holidays (typically
# associated with attending sports together) over administrative holidays.
_HOLIDAY_PRIORITY: dict[str, int] = {
    "Father's Day":     100,
    "Mother's Day":     100,
    "Memorial Day":      95,
    "Independence Day":  95,
    "Labor Day":         95,
    "Thanksgiving":      95,
    "Christmas":         95,
    "New Year's Day":    90,
    "Juneteenth":        50,
}


def _classify_holiday_proximity(candidate_date_iso: str,
                                observed_date_iso: str) -> str | None:
    """Decide whether a candidate event date earns a holiday tag, and what
    flavor. Returns one of:
      - "day_of"     → candidate == observed_date           (tag "Memorial Day")
      - "weekend_of" → candidate is Sat/Sun in ±2 window    (tag "Memorial Day Weekend")
      - None         → candidate is a non-holiday weekday   (no tag)

    Operator directive 2026-05-19 v6: "suffix only when weekend = true,
    not for a tuesday event". A Tuesday after Memorial Day Monday is NOT
    Memorial Day Weekend — the holiday window-expansion (±2 from observed_date)
    only earns a weekend tag for actual weekend days. Other weekdays in
    the window fall back to the non-holiday Featured branches (premium,
    market-anchor) or land in other rails (moving_fast, etc.).

    Pure function — accepts ISO date strings, returns a string or None.
    Caller is expected to have already verified the candidate's date is
    within ±2 days of observed_date (i.e. the holiday is in range).
    """
    from datetime import date as _date_cls
    try:
        cand_d = _date_cls.fromisoformat(candidate_date_iso)
    except (TypeError, ValueError):
        return None
    if candidate_date_iso == observed_date_iso:
        return "day_of"
    # weekday(): 0=Mon..6=Sun; 5=Sat, 6=Sun
    if cand_d.weekday() in (5, 6):
        return "weekend_of"
    return None


# ───────────────────────────── section builders ──────────────────────────────

def _section_moving_fast(candidates: list[dict], cap: int = 10) -> list[dict]:
    """Demand velocity (TEvo): supply leaving our broker market fast — a 24h
    ticket-count drop of ≥50. EVO-only; no SeatGeek sales signal."""
    out = []
    for c in candidates:
        d24h = c.get("tix_d24h")
        if isinstance(d24h, int) and d24h <= -50:
            out.append(c)
    out.sort(key=lambda c: (
        -abs(c.get("tix_d24h") or 0),
        c.get("occurs_at_local") or "9999",
    ))
    return out[:cap]


def _section_price_drops(candidates: list[dict], cap: int = 10) -> list[dict]:
    """Our get-in price fell ≥10% in the last 24h (TEvo get-in movement).
    EVO-only — no SeatGeek market comparison. Displayed as "↓ X% in 24h"."""
    out = []
    for c in candidates:
        getin_pct = c.get("getin_pct_24h")
        if isinstance(getin_pct, (int, float)) and getin_pct <= -10.0:
            c["_discount_pct"] = round(abs(getin_pct), 1)
            out.append(c)
    out.sort(key=lambda c: (-c.get("_discount_pct", 0.0),
                            c.get("occurs_at_local") or "9999"))
    return out[:cap]


def _section_climbing(candidates: list[dict], cap: int = 10) -> list[dict]:
    """Price firming (TEvo): tickets dropping AND get-in climbing ≥5% in 24h.
    EVO-only; the former SeatGeek-median path was removed."""
    out = []
    for c in candidates:
        d24h = c.get("tix_d24h")
        getin_pct = c.get("getin_pct_24h")
        tevo_climb = (isinstance(d24h, int) and d24h < 0
                      and isinstance(getin_pct, (int, float)) and getin_pct >= 5.0)
        if tevo_climb:
            c["_climb_pct"] = round(getin_pct, 1)
            out.append(c)
    out.sort(key=lambda c: (-(c.get("_climb_pct") or 0),
                            c.get("occurs_at_local") or "9999"))
    return out[:cap]


def _section_specials(candidates: list[dict],
                      holiday_by_eid: dict[int, dict],
                      rivalry_by_eid: dict[int, str],
                      cap: int = 10) -> list[dict]:
    """Curated rail — events that qualify on a non-market basis. Two
    sources fold in here:
      1. v_event_holidays + holiday-window expansion: day-of OR ±2 day
         (Memorial Day vs Memorial Day Weekend, etc.)
      2. v_rivalry_events: known rivalry games (Yankees-Red Sox, etc.)
    Both gated to owned > 100 — same depth bar the operator set for
    the "specials" rail. Each card is tagged with `_special` describing
    what earned its slot (e.g. "Memorial Day", "Memorial Day Weekend",
    or "Yankees vs Red Sox").
    """
    out = []
    for c in candidates:
        if (c.get("owned_tickets_count") or 0) <= 100:
            continue
        eid = c.get("id")
        try:
            eid_int = int(eid) if eid is not None else None
        except (TypeError, ValueError):
            eid_int = None
        if eid_int is None:
            continue
        holiday = holiday_by_eid.get(eid_int)
        rivalry = rivalry_by_eid.get(eid_int)
        if holiday or rivalry:
            # Prefer rivalry tag when both apply — more specific narrative.
            if rivalry:
                c["_special"] = rivalry
            else:
                hname = (holiday or {}).get("name") or ""
                # Weekend-of holidays get "Memorial Day Weekend" framing;
                # day-of keeps the bare holiday name.
                c["_special"] = f"{hname} Weekend" if (holiday or {}).get("weekend") else hname
            c["_special_kind"] = "rivalry" if rivalry else "holiday"
            out.append(c)
    out.sort(key=lambda c: c.get("occurs_at_local") or "9999")
    return out[:cap]


def _section_featured(candidates: list,
                      holiday_by_eid: dict,
                      rivalry_by_eid: dict,
                      cap: int = 20) -> list:
    """Featured rail — operator directive 2026-05-19 v3. Multi-signal
    curation. All branches require `owned_tickets_count > 100`. Tag
    selection: playoff > world_cup > rivalry > holiday > marquee > premium.

      1. Playoff games           — `_classify_playoff()` regex hit
      2. World Cup matches       — `_classify_world_cup()` (D3 2026-06-16).
                                   FIFA World Cup 2026 soccer matches we own,
                                   tagged "World Cup". Exempt from the owned>100
                                   gate (marquee international inventory is thin
                                   per match, like playoffs).
      3. Holiday calendar games  — date within holiday window (±2 days
                                   from observed_date; weekend coverage).
                                   Tag = "Memorial Day" for day-of,
                                   "Memorial Day Weekend" for ±1/±2.
      4. Rivalry games           — `v_rivalry_events` membership
      5. Marquee competitions    — US Open Tennis / F1 / Inter Miami away
      6. Other category          — `owned_median_retail > $50` catch-all
                                   (concerts, regular-season home games,
                                   anything not in 1-5)

    Premium-only events show no tag (section title "Featured" carries the
    framing). Internal owned-count labels not exposed.
    """
    out = []
    for c in candidates:
        eid = c.get("id")
        if eid is None:
            continue
        try:
            eid_int = int(eid)
        except (TypeError, ValueError):
            continue
        owned = c.get("owned_tickets_count") or 0
        playoff = _classify_playoff(c.get("name") or "")
        world_cup = _classify_world_cup(c.get("name"), c.get("primary_performer_name"))
        if owned <= 100 and not playoff and not world_cup:
            # Global depth gate for non-playoff events. Playoff games are
            # exempt (operator directive 2026-05-26) — they're the highest-
            # value NYC inventory even at thin owned counts (e.g. Knicks
            # Game 7 sits at owned ~60, well under the regular-season bar).
            # World Cup matches share the exemption (D3 2026-06-16): marquee
            # international inventory is thin per match (e.g. Match 72 owned
            # ~62) but exactly what the Featured rail is for.
            continue
        rivalry = rivalry_by_eid.get(eid_int)
        holiday = holiday_by_eid.get(eid_int)
        marquee = _classify_marquee_competition(c.get("name") or "")
        # Branches 1-5: specific narrative signals (any of) → always Featured
        if playoff:
            c["_featured_tag"] = (playoff.get("label") or "Playoff")
            c["_featured_kind"] = "playoff"
        elif world_cup:
            c["_featured_tag"] = "World Cup"
            c["_featured_kind"] = "world_cup"
        elif rivalry:
            c["_featured_tag"] = rivalry
            c["_featured_kind"] = "rivalry"
        elif holiday:
            # Holiday tag — day-of keeps bare name ("Memorial Day"); ±1/±2
            # gets the weekend framing ("Memorial Day Weekend").
            hname = (holiday or {}).get("name") or ""
            c["_featured_tag"] = f"{hname} Weekend" if (holiday or {}).get("weekend") else hname
            c["_featured_kind"] = "holiday"
        elif marquee:
            c["_featured_tag"] = marquee
            c["_featured_kind"] = "marquee"
        else:
            # Branch 5a: "any other category" — requires median > $50
            # Branch 5b: market-anchor fallback (operator 2026-05-19 v4):
            #   owned > 200 AND owned_share >= 20% catches bargain-tier
            #   games where we dominate inventory but pricing is consumer-
            #   friendly. Threshold based on Yankees distribution audit:
            #   regular games sit 12-22% share; >=20% = "we are the market".
            med = c.get("owned_median_retail")
            try:
                med_f = float(med) if med is not None else None
            except (TypeError, ValueError):
                med_f = None
            share = c.get("owned_share")
            try:
                share_f = float(share) if share is not None else None
            except (TypeError, ValueError):
                share_f = None
            is_premium = (med_f is not None and med_f > 50.0)
            is_market_anchor = (owned > 200) and (share_f is not None and share_f >= 0.20)
            if not (is_premium or is_market_anchor):
                continue
            c["_featured_tag"] = ""  # no internal-metric chip on consumer UI
            c["_featured_kind"] = "premium" if is_premium else "market_anchor"
        out.append(c)
    out.sort(key=lambda c: c.get("occurs_at_local") or "9999")
    return out[:cap]


# ───────────────────────────── the engine entry ──────────────────────────────

def _compute_movers(db, city: str, day_cap: int, cap: int) -> dict:
    """Pure compute path for the movers endpoint. Extracted from the route
    handler so both the cold-cache code path AND the background-refresh
    task call the same implementation. Returns the exact response dict
    the route emits (`city`, `days`, `count`, `events`).
    """
    # City filter — hardcoded NYC venue patterns for v1. Matches everywhere
    # the storefront would consider "New York metro" inventory.
    city_norm = (city or "").upper()
    if city_norm in ("NYC", "NEW YORK", "NEW YORK CITY"):
        venue_patterns = ("%New York%", "%Brooklyn%", "%Bronx%",
                          "%Queens%", "%Manhattan%", "%, NY%")
    else:
        # Unknown city → empty result; cleaner than a 400 for the home view.
        return {"city": city, "days": day_cap, "count": 0, "events": []}

    today_iso = datetime.now(timezone.utc).date().isoformat()
    horizon_iso = (datetime.now(timezone.utc) + timedelta(days=day_cap)).date().isoformat()

    # Pull events in the window with owned inventory + active lifecycle.
    # Two queries + merge (consistent with the catalog pattern; view-to-
    # table FK inference under PostgREST has been flaky).
    try:
        ev_q = db.table("events").select(
            "id,name,occurs_at_local,venue_id,venue_name,venue_location,"
            "primary_performer_id,primary_performer_name,performer_ids"
        ).gte("occurs_at_local", today_iso).lte("occurs_at_local", horizon_iso + "T23:59:59")
        # PostgREST `or_()` with a comma-separated list of `<col>.ilike.<pat>`
        # supports OR filters across multiple patterns. Use _or_ilike_clause so
        # patterns containing literal commas (e.g. "%, NY%") are double-quoted
        # and don't get split by PostgREST's clause parser — that bug silently
        # returned 0 movers for ~309 owned NYC events until the fix landed.
        or_clauses = ",".join(_or_ilike_clause("venue_location", p) for p in venue_patterns)
        ev_q = ev_q.or_(or_clauses)
        events_rows = ev_q.limit(800).execute().data or []
    except Exception as e:
        # Conservative fallback: don't break the homepage if the filter
        # syntax ever drifts.
        print(f"store_movers events query failed: {e}")
        return {"city": city, "days": day_cap, "count": 0, "events": []}

    # ----- World Cup inclusion (D3, 2026-06-16) -----
    # The Featured rail is NYC-anchored (venue_patterns above), but FIFA World
    # Cup 2026 matches are a national draw and our owned WC inventory can sit
    # at any host venue (e.g. Match 72 at Mercedes-Benz Stadium, Atlanta —
    # which the NYC venue filter would exclude). Pull owned World Cup events
    # regardless of city and merge them into events_rows so they flow through
    # the same metrics/lifecycle/curation pipeline and can reach Featured.
    # Wrapped so a failure here degrades to NYC-only behavior, never 500s.
    try:
        wc_rows = (db.table("events").select(
            "id,name,occurs_at_local,venue_id,venue_name,venue_location,"
            "primary_performer_id,primary_performer_name,performer_ids"
        ).gte("occurs_at_local", today_iso)
         .lte("occurs_at_local", horizon_iso + "T23:59:59")
         .ilike("primary_performer_name", "%World Cup Soccer%")
         .limit(100).execute().data) or []
        seen_eids = {int(e["id"]) for e in events_rows if e.get("id")}
        for e in wc_rows:
            eid = e.get("id")
            if eid is not None and int(eid) not in seen_eids:
                events_rows.append(e)
                seen_eids.add(int(eid))
    except Exception as e:
        print(f"store_movers world-cup pull failed: {e}")

    if not events_rows:
        return {"city": city, "days": day_cap, "count": 0, "events": []}
    # Drop speculative names (CANCELLED / (If Necessary)) — playoff "may not
    # happen" placeholders normally shouldn't surface to consumers. EXCEPTION
    # (operator directive 2026-05-26): playoff games keep their "(If Necessary)"
    # slot in the movers strip — they're the highest-value NYC inventory (e.g.
    # Knicks Game 7, $5,880 median) and are exactly what the Featured rail is
    # for. Genuine CANCELLED games still drop, even playoff ones. This relaxes
    # the filter ONLY for the movers strip; search + home still hide these.
    events_rows = [
        e for e in events_rows
        if not _is_speculative_event_name(e.get("name"))
        or (_classify_playoff(e.get("name"))
            and "CANCELLED" not in (e.get("name") or "").upper())
    ]
    if not events_rows:
        return {"city": city, "days": day_cap, "count": 0, "events": []}
    events_by_id = {int(e["id"]): e for e in events_rows if e.get("id")}
    ev_ids = list(events_by_id.keys())

    # Owned-only metrics so we don't list events we can't actually sell.
    metrics = (db.table("latest_event_metrics")
                 .select("event_id,owned_tickets_count,owned_groups_count,"
                         "tickets_count,retail_min,owned_median_retail,owned_share,"
                         "captured_at")
                 .gt("owned_tickets_count", 0)
                 .in_("event_id", ev_ids)
                 .execute().data) or []
    if not metrics:
        return {"city": city, "days": day_cap, "count": 0, "events": []}
    metrics_by_id = {int(m["event_id"]): m for m in metrics if m.get("event_id")}

    # Lifecycle filter — drop ghost/cancelled/postponed.
    try:
        lc = (db.table("event_lifecycle")
                .select("event_id,is_active")
                .in_("event_id", list(metrics_by_id.keys()))
                .execute().data) or []
        inactive = {int(r["event_id"]) for r in lc if not r.get("is_active")}
    except Exception:
        inactive = set()

    # World Cup exemption (D3, 2026-06-16): the ghost detector eliminates events
    # whose TEvo event row hasn't been re-polled recently (e.g. Match 72 flagged
    # `ghost_eliminated` / `sports_stale_135hr`). That recency signal is about
    # the events-feed cadence, NOT inventory — and we have live owned listings on
    # these matches, so dropping them is a false negative. Keep owned World Cup
    # matches out of `inactive`. Genuinely cancelled ones are still removed by the
    # speculative-name filter above ("CANCELLED" never qualifies as WC here).
    for _eid in list(inactive):
        _ev = events_by_id.get(_eid) or {}
        if _classify_world_cup(_ev.get("name"), _ev.get("primary_performer_name")):
            inactive.discard(_eid)

    # Velocity windows for the 1h/24h ticket delta + getin pct moves.
    try:
        vw = (db.table("v_event_velocity_windows")
                .select("tevo_event_id,tevo_tix_now,tevo_tix_d24h,"
                        "tevo_getin_now,tevo_getin_d24h_pct,tevo_now_at")
                .in_("tevo_event_id", list(metrics_by_id.keys()))
                .execute().data) or []
    except Exception:
        vw = []
    velocity_by_id = {int(v["tevo_event_id"]): v for v in vw if v.get("tevo_event_id") is not None}

    # Performer assets (logos + colors) for every performer across the pool.
    perf_ids_set: set[int] = set()
    for _e in events_by_id.values():
        pp = _e.get("primary_performer_id")
        try:
            if pp:
                perf_ids_set.add(int(pp))
        except (TypeError, ValueError):
            pass
        for raw_pid in (_e.get("performer_ids") or []):
            try:
                perf_ids_set.add(int(raw_pid))
            except (TypeError, ValueError):
                pass
    perf_assets = _bulk_performer_assets(db, list(perf_ids_set)) if perf_ids_set else {}

    _VELOCITY_FRESH_MAX_AGE_SEC = 48 * 3600  # 48 hours — matches collector cadence

    def _is_velocity_fresh(v: dict) -> bool:
        ts = v.get("tevo_now_at")
        if not ts:
            return False
        try:
            captured = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
            age = (datetime.now(timezone.utc) - captured).total_seconds()
            return 0 <= age <= _VELOCITY_FRESH_MAX_AGE_SEC
        except (TypeError, ValueError):
            return False

    # ----- EVO-only storefront (operator directive 2026-06-16) -----
    # The consumer store features EVO/TEvo inventory ONLY — no SeatGeek
    # information or values surface to customers. The former SG enrichment
    # (xref + sales + listings windows) was removed; the discovery rails below
    # (moving_fast / price_drops / climbing) run purely off TEvo velocity
    # signals (ticket-count delta + get-in price movement).

    # ----- Build candidate pool with all signal data attached -----
    # Every owned (>=1) event lands in `candidates` with its full signal
    # payload. Each section helper below filters this pool independently;
    # an event can qualify for 0, 1, or multiple sections.
    # `all_owned_cards` collects EVERY owned event (incl. owned<=50) so the
    # empty-rail fallback below has a pool to draw from when nothing clears
    # the curation gates (operator directive 2026-05-26).
    candidates: list[dict] = []
    all_owned_cards: list[dict] = []
    for eid, m in metrics_by_id.items():
        if eid in inactive:
            continue
        ev = events_by_id.get(eid) or {}
        v = velocity_by_id.get(eid) or {}
        velocity_fresh = _is_velocity_fresh(v)
        tix_d24h = v.get("tevo_tix_d24h") if velocity_fresh else None
        getin_pct_24h = v.get("tevo_getin_d24h_pct") if velocity_fresh else None
        getin_now = v.get("tevo_getin_now")
        from_price = m.get("retail_min") if m.get("retail_min") is not None else getin_now

        try:
            d24h_val = int(tix_d24h) if tix_d24h is not None else None
        except (TypeError, ValueError):
            d24h_val = None
        try:
            pct_val = float(getin_pct_24h) if getin_pct_24h is not None else None
        except (TypeError, ValueError):
            pct_val = None

        # Home-team assets (primary performer)
        primary_pid_raw = ev.get("primary_performer_id")
        primary_pid: int | None = None
        try:
            primary_pid = int(primary_pid_raw) if primary_pid_raw else None
        except (TypeError, ValueError):
            primary_pid = None
        a = perf_assets.get(primary_pid) if primary_pid else None
        # Away-team assets — first performer_id in array that's NOT primary.
        # Sports matchups: events.performer_ids = [home_id, away_id, ...].
        # Playoff/single-team entries may have only the primary; in that
        # case away_* fields stay null (graceful no-op on FE).
        away_pid: int | None = None
        for raw_pid in (ev.get("performer_ids") or []):
            try:
                pid_int = int(raw_pid)
            except (TypeError, ValueError):
                continue
            if primary_pid is not None and pid_int == primary_pid:
                continue
            away_pid = pid_int
            break
        b = perf_assets.get(away_pid) if away_pid else None
        owned_tickets = m.get("owned_tickets_count") or 0
        card = {
            "id": ev.get("id"),
            "name": ev.get("name"),
            "occurs_at_local": ev.get("occurs_at_local"),
            "venue_name": ev.get("venue_name"),
            "venue_location": ev.get("venue_location"),
            "primary_performer_name": ev.get("primary_performer_name"),
            "primary_performer_logo": (a or {}).get("logo_default_url"),
            "primary_performer_color": (a or {}).get("color_primary"),
            # Away-team assets — 2026-05-19: "populate all store events
            # with team assets where available". Null when no away
            # performer in array (e.g. playoff placeholder events).
            "away_performer_id":    away_pid,
            "away_performer_name":  (b or {}).get("name"),
            "away_performer_logo":  (b or {}).get("logo_default_url"),
            "away_performer_color": (b or {}).get("color_primary"),
            "from_price": from_price,
            "tix_d24h": d24h_val,
            "getin_pct_24h": pct_val,
            "owned_tickets_count": owned_tickets,
            "owned_median_retail": m.get("owned_median_retail"),
            "owned_share": m.get("owned_share"),
        }
        all_owned_cards.append(card)
        if owned_tickets > 50:
            # Sections (except holidays) require owned > 50 for inventory depth;
            # holidays/specials are tighter at > 100, applied in the section
            # helpers. Playoff games additionally bypass the owned>100 Featured
            # gate (see _section_featured).
            candidates.append(card)

    # ----- Specials enrichment: pull holiday-window matches + rivalry
    # tags. Both wrapped in try/except so a view-side failure degrades
    # to no-specials rather than killing the whole movers response.
    candidate_ids = [int(c["id"]) for c in candidates if c.get("id") is not None]
    # holiday_by_eid value shape (2026-05-19): {"name": str, "weekend": bool}
    # weekend=False → event is ON the holiday's observed_date (label "Memorial Day")
    # weekend=True  → event is ±1/±2 days from observed_date (label "Memorial Day Weekend")
    # Operator directive: distinguish day-of from weekend-of so the actual
    # holiday day stands apart in the rail badges.
    holiday_by_eid: dict[int, dict] = {}
    rivalry_by_eid: dict[int, str] = {}
    if candidate_ids:
        try:
            hrows = (db.table("v_event_holidays")
                       .select("tevo_event_id,holiday_name")
                       .in_("tevo_event_id", candidate_ids)
                       .execute().data) or []
            # First match wins per event — v_event_holidays can emit
            # multiple rows when a date hits multiple holidays. The view
            # already orders by match_specificity DESC server-side. This
            # view is exact-date only (see line 5856 landmine note), so
            # all matches from here are day-of → weekend=False.
            for r in hrows:
                eid = r.get("tevo_event_id")
                if eid is None:
                    continue
                key = int(eid)
                if key not in holiday_by_eid and r.get("holiday_name"):
                    holiday_by_eid[key] = {"name": r["holiday_name"], "weekend": False}
        except Exception as e:
            print(f"store_movers v_event_holidays query failed: {e}")
        try:
            rrows = (db.table("v_rivalry_events")
                       .select("tevo_event_id,rivalry_name,rivalry_intensity")
                       .in_("tevo_event_id", candidate_ids)
                       .execute().data) or []
            # v_rivalry_events emits duplicate rows when both teams in a
            # matchup are competitors (app.py:1198 bible landmine).
            # Dedupe Python-side; first row wins.
            for r in rrows:
                eid = r.get("tevo_event_id")
                if eid is None:
                    continue
                key = int(eid)
                if key not in rivalry_by_eid and r.get("rivalry_name"):
                    rivalry_by_eid[key] = r["rivalry_name"]
        except Exception as e:
            print(f"store_movers v_rivalry_events query failed: {e}")

    # ----- Build the 4 themed sliders. Each section is independent and
    # gets its own copy of qualifying candidates (cards may appear in
    # more than one section, e.g. a rivalry game that's also moving fast).
    # Cross-list dedup (operator directive 2026-05-19 v2): an event appears
    # in at most ONE rail. Process in priority order; each rail consumes
    # events from a shared `seen` set, so subsequent rails skip them.
    # Priority: Featured > moving_fast > price_drops > climbing > specials.
    seen: set = set()
    def _consume(items: list) -> list:
        out = []
        for c in items:
            eid = c.get("id")
            try:
                eid_int = int(eid) if eid is not None else None
            except (TypeError, ValueError):
                eid_int = None
            if eid_int is None or eid_int in seen:
                continue
            seen.add(eid_int)
            out.append(c)
        return out

    # Holiday-window expansion (operator directive 2026-05-19 v3, refined v4):
    # base `v_event_holidays` exact-date join misses weekend games. Pull all
    # in-window holidays + apply per-event applicability rules:
    #   - US country-level     → tag (storefront is NYC)
    #   - US state=NY or city=New York → tag
    #   - US state/city != NY  → skip
    #   - CA country-level     → tag ONLY when event has a Canadian team
    #   - CA province-level (QC etc.) → never tag
    # Priority: Father's/Mother's Day > Memorial/Independence/Labor/Thanks/
    # Christmas > New Year's > Juneteenth > everything else.
    try:
        cand_dates = sorted({
            (c.get("occurs_at_local") or "")[:10]
            for c in candidates if c.get("occurs_at_local")
        })
        if cand_dates:
            from datetime import date as _date_cls
            win_lo = (_date_cls.fromisoformat(cand_dates[0])  - timedelta(days=2)).isoformat()
            win_hi = (_date_cls.fromisoformat(cand_dates[-1]) + timedelta(days=2)).isoformat()
            holiday_rows = (db.table("holidays")
                              .select("observed_date,holiday_name,country,state,city")
                              .gte("observed_date", win_lo)
                              .lte("observed_date", win_hi)
                              .execute().data) or []
            # Group: date_str → list of (holiday_row) within ±2 day window
            date_to_options: dict[str, list[dict]] = {}
            for h in holiday_rows:
                obs = h.get("observed_date")
                if not obs:
                    continue
                try:
                    obs_d = _date_cls.fromisoformat(obs)
                except (TypeError, ValueError):
                    continue
                # Window: -2 day through +1 day inclusive.
                # observed_date itself is included (dd=0) — used to flag
                # day-of matches that v_event_holidays may have missed.
                for dd in range(-2, 2):
                    ds = (obs_d + timedelta(days=dd)).isoformat()
                    date_to_options.setdefault(ds, []).append(h)
            # Resolve per candidate. Apply applicability + priority.
            for c in candidates:
                eid = c.get("id")
                if eid is None:
                    continue
                try:
                    eid_int = int(eid)
                except (TypeError, ValueError):
                    continue
                if eid_int in holiday_by_eid:
                    continue  # exact-date join from v_event_holidays already set
                cd = (c.get("occurs_at_local") or "")[:10]
                options = date_to_options.get(cd, [])
                if not options:
                    continue
                ev_name = c.get("name") or ""
                applicable: list[dict] = []
                for h in options:
                    country = h.get("country")
                    state = h.get("state")
                    city = h.get("city")
                    if country == "US":
                        # NY-state / New-York-city restrictions OK (storefront
                        # is NYC). Skip other-city / other-state US holidays.
                        if city and city != "New York":
                            continue
                        if state and state != "NY":
                            continue
                        applicable.append(h)
                    elif country == "CA":
                        # Canadian holiday — only tag when a Canadian team
                        # is visiting NYC. Skip province-specific holidays.
                        if state:
                            continue
                        if not _has_canadian_team(ev_name):
                            continue
                        applicable.append(h)
                    # other countries → silently skip
                if not applicable:
                    continue
                # Priority sort: higher _HOLIDAY_PRIORITY wins; tie-break to US
                applicable.sort(key=lambda hh: (
                    -_HOLIDAY_PRIORITY.get(hh.get("holiday_name", ""), 0),
                    0 if hh.get("country") == "US" else 1,
                ))
                chosen = applicable[0]
                hname = chosen.get("holiday_name", "")
                # Day-of vs weekend-of vs skip: see _classify_holiday_proximity
                # docstring. Operator 2026-05-19 v6: Tuesday after Memorial Day
                # Monday is NOT "Memorial Day Weekend" — only Sat/Sun in the
                # ±2 window earn the weekend tag.
                proximity = _classify_holiday_proximity(cd, chosen.get("observed_date") or "")
                if proximity == "day_of":
                    holiday_by_eid[eid_int] = {"name": hname, "weekend": False}
                elif proximity == "weekend_of":
                    holiday_by_eid[eid_int] = {"name": hname, "weekend": True}
                # else: non-weekend weekday in window → no tag
    except Exception as e:
        print(f"store_movers holiday-window expansion failed: {e}")

    # Featured = playoff OR holiday-weekend OR rivalry OR marquee competition
    # OR (other category with owned_median > $50). Owned > 100 required globally.
    # Runs FIRST so curated picks win over generic-velocity rails.
    featured = _consume(_section_featured(candidates, holiday_by_eid, rivalry_by_eid))
    moving_fast = _consume(_section_moving_fast(candidates))
    price_drops = _consume(_section_price_drops(candidates))
    climbing = _consume(_section_climbing(candidates))
    # Specials brought back as its own rail (was folded into Featured in
    # PR #279; operator narrowed Featured + asked specials to "populate to
    # other lists we have"). Holiday/rivalry events with owned > 100 that
    # don't qualify for Featured land here.
    specials = _consume(_section_specials(candidates, holiday_by_eid, rivalry_by_eid))

    # Empty-rail fallback (operator directive 2026-05-26): never render a blank
    # homepage. When nothing clears the curation gates — common in thin-
    # inventory windows (offseason, between playoff rounds) — surface the
    # soonest upcoming owned NYC events in the Featured rail so it always has
    # something bookable. These qualify on recency + owned inventory alone, so
    # they carry no curation chip (_featured_tag = "").
    if not (featured or moving_fast or price_drops or climbing or specials):
        fallback = sorted(all_owned_cards,
                          key=lambda c: c.get("occurs_at_local") or "9999")[:cap]
        for fc in fallback:
            fc.setdefault("_featured_tag", "")
            fc["_featured_kind"] = "fallback"
        featured = fallback

    return {
        "city": city,
        "days": day_cap,
        "count": len(featured) + len(moving_fast) + len(price_drops) + len(climbing) + len(specials),
        "featured": featured,
        "moving_fast": moving_fast,
        "price_drops": price_drops,
        "climbing": climbing,
        "specials": specials,
    }


# Public entry point app.py imports (aliased to the historical _compute_movers).
compute_movers = _compute_movers
