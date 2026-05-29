# Cross-source entity resolution — 2026-05-11

Methodology for linking TEvo ↔ SeatGeek (and extensible to SeatData) at four entity layers: **Venues → Performers → Brokers → Events → Listings**. Produced by C1 (Data + Chat Bot). Handoff target for git work: A1.

## Motivation

`docs/data-sources-audit-2026-05-11.md` surfaced two blocking gaps:

1. `seatgeek_orders.tevo_event_id` is **0% populated** (400 orders, 0 backfilled). Cross-source sales analysis is impossible.
2. SeatData covers 1 event of 254 sales — dormant per BASIC plan caps, but the dup risk *becomes real* the moment we expand SeatData coverage.

A consistent xref methodology unblocks: cross-source sales rollup, listings arbitrage detection, source-of-truth queries, and the section/row/quantity tracking proposed for performance analytics.

## Live data findings (test before build)

Before writing migrations, we probed the live DB to validate match assumptions. Critical findings that reshape the build:

### Finding 1: Xref infrastructure already exists, partially populated

Tables already in place: `seatgeek_event_xref`, `seatgeek_venue_xref`, `seatgeek_performer_xref`, `sg_events_canonical`, `sg_canonical_match_view`, `sg_event_match_pending`, `sg_event_backfill_pending`. Schema mirrors what this doc proposes (`match_method`, `match_confidence`, `matched_at`).

| table | rows | coverage |
|---|---|---|
| `seatgeek_event_xref` | 11 | 5.9% of 186 distinct sg_event_ids in orders |
| `seatgeek_venue_xref` | 34 | (denominator unknown) |
| `seatgeek_performer_xref` | 130 | (denominator unknown) |
| `sg_events_canonical` | 228 | |

Match methods in use: `auto_seller_inline_v2` (10), `venue_date_unique` (1). The methodology proposed below extends rather than replaces these.

### Finding 2: Existing xref doesn't cover any SG orders

Of the 11 matches in `seatgeek_event_xref`, **zero** overlap with the 186 distinct sg_event_ids that appear in `seatgeek_orders`. The xref pipeline matches events that have no corresponding sales, and misses every event that does.

Likely cause: `auto_seller_inline_v2` matches at *listing* ingest time using inline seller metadata. Most SG orders are historical 2018–2025; their listings were never ingested in real time, so inline matching never had a chance to run.

### Finding 3: TEvo events table doesn't retain history

| metric | count |
|---|---|
| TEvo `events` total | 3,405 |
| Past events | 293 |
| Future events | 3,112 |
| SG order distinct dates with same-day past TEvo event | **0** |

The 400 SG orders span 2018–2025; TEvo's 293 past events don't share a single date with them. **Layer 3 cannot xref historical SG orders against TEvo because the right-hand side doesn't exist.**

Implications for build:
- **Active / future events:** Layer 3 methodology works. SG canonical event + TEvo event both exist; performer/venue/date match resolves cleanly.
- **Historical SG orders:** treat as standalone. Either accept `tevo_event_id` stays NULL forever, or run a one-off TEvo `/v9/events` backfill keyed off SG order dates. The latter is a data-acquisition project, not a methodology fix.

### Finding 4: Sales-side dedup risk is currently theoretical

Cross-source dup detection across `evo_orders` (60 line items / 38 events), `seatgeek_orders` (400 / 186 events), `seatdata_sales_snapshots` (254 / 1 event): **zero matching tuples**. The sources don't overlap at the event level today, so dedup-on-union risk is dormant. It activates the moment Layer 3 starts backfilling tevo_event_id at scale or SeatData expansion broadens coverage.

### Finding 5: Section/row/quantity is not a unique sale fingerprint

Spot-checked SeatGeek's 15 "soft-dup" tuples on `(sg_event_id, section, row, quantity)`: every group's `distinct_orders` count equals `rows_in_group`. These are real distinct sales — GA seating, multi-block in same row, or relistings after returns. Validates the Layer 4 doctrine: never auto-match on (section, row, qty) alone.

### Finding 6: Path B sample fix proves the methodology works

Ran Path B (venue + performer name extraction) against all 400 SG orders using `v_canonical_venue` + `v_canonical_performer` with **exact-name match only — no normalization, no fuzzy, no seller bridge**:

| layer | matched | % |
|---|---|---|
| Venue | 271 | 67.8% |
| Performer A (away/sole) | 218 | 54.5% |
| Performer B (home, if present) | 136 | 34.0% |
| Venue + ≥1 performer | 151 | 37.8% |
| Venue + both performers (full Path B) | **79** | **19.8%** |

This is the **floor coverage** with zero matching sophistication. Adding the proposed `norm()` function (strip "The ", punctuation, lowercase) + fuzzy via `pg_trgm` should push venue toward 90%+ and full Path B toward 60%+. The methodology validates.

Concrete worked example — `sg_order_id` for Angels @ Yankees on 2025-06-17:
- `sg_event_name = "Los Angeles Angels at New York Yankees"`
- Parse on " at " → perf_a="Los Angeles Angels", perf_b="New York Yankees"
- Resolve venue "Yankee Stadium" → `tevo_venue_id=5725`
- Resolve perf_a → `tevo_performer_id=15541` (MLB via ESPN bridge)
- Resolve perf_b → `tevo_performer_id=15533` (MLB via ESPN bridge)
- Order now joinable to all TEvo team analytics despite no TEvo event row for that date.

## Existing infrastructure (don't reinvent)

| table | purpose | state |
|---|---|---|
| `cross_source_entity_maps` | central xref | provisioned |
| `seatgeek_event_xref` | TEvo event ↔ SG event | populated 0% on orders side |
| `seatdata_event_xref`, `_venue_xref`, `_performer_xref`, `_section_xref`, `_zone_xref` | SeatData side | partial |
| `performer_external_ids` | TEvo performer ↔ external IDs (ESPN, etc.) | live |
| `sg_events_canonical` | SeatGeek canonical events | live |
| `venue_assets` (lat/lon) | venue geocodes via OSM Nominatim | live (reactive only) |

## Match primitives (shared across all layers)

### Normalization function
```sql
norm(s) = lower(trim(regexp_replace(unaccent(s), '[^a-z0-9 ]', '', 'g')))
```
- Strips accents, lowercases, removes punctuation
- Per-layer extensions: strip "The " prefix for performers, strip "Section "/"Sec " for sections

### Confidence tiers (single numeric, audit-friendly)

| tier | score | trigger |
|---|---|---|
| `exact` | 1.00 | raw strings equal |
| `normalized` | 0.95 | `norm()` strings equal |
| `fuzzy` | 0.85 | `pg_trgm` similarity ≥ 0.8 |
| `composite` | 0.80 | weak name match + strong secondary signal (ESPN id, broker id, geo proximity) |
| `manual` | 1.00 | human override (always wins) |
| (rejected) | < 0.70 | leave unmatched, queue for review |

**Doctrine:** prefer under-matching over over-matching. False positives corrupt analytics; false negatives leave money on the table for analysis to revisit later.

### Universal xref table shape

```sql
CREATE TABLE entity_xref_<layer> (
  tevo_id       <type> NOT NULL,
  sg_id         text   NOT NULL,
  confidence    numeric(3,2) NOT NULL,
  match_method  text   NOT NULL,        -- 'exact'|'normalized'|'fuzzy'|'composite'|'manual'
  matched_at    timestamptz NOT NULL DEFAULT now(),
  matched_by    text NOT NULL DEFAULT 'auto',
  notes         text,
  PRIMARY KEY (tevo_id, sg_id)
);
CREATE UNIQUE INDEX ON entity_xref_<layer>(tevo_id) WHERE confidence >= 0.85;
CREATE UNIQUE INDEX ON entity_xref_<layer>(sg_id)   WHERE confidence >= 0.85;
```

Partial unique indexes prevent ambiguous high-confidence matches but allow low-confidence ones to coexist for review.

### Manual override + conflict log

```sql
CREATE TABLE entity_xref_overrides (
  layer text NOT NULL, tevo_id text NOT NULL, sg_id text NOT NULL,
  reason text, set_by text, set_at timestamptz DEFAULT now(),
  PRIMARY KEY (layer, tevo_id)
);

CREATE TABLE entity_xref_conflicts (
  layer text NOT NULL, tevo_id text NOT NULL,
  candidate_sg_ids text[] NOT NULL,
  confidence_scores numeric[] NOT NULL,
  status text NOT NULL DEFAULT 'needs_review',  -- needs_review | resolved | dismissed
  logged_at timestamptz DEFAULT now()
);
```

Overrides always beat auto-matches. Conflicts surface when two candidates tie within 0.05 confidence.

---

## Layer 1 — Venues (geo-first)

**Why first:** smallest set (~thousands), most stable, foundation for events.

**Match key:** primarily geographic, name as confirmation.

**Logic:**
1. Both have lat/lon AND haversine distance ≤ 100 m → **1.00** (geographic identity, name spelling irrelevant)
2. Distance ≤ 500 m AND `norm(name)` fuzzy similarity ≥ 0.7 → **0.95** (same complex, different building)
3. No coords on one side: exact `(name_norm, city_norm, state)` → **0.90**, fuzzy → **0.80**
4. Distance > 1 km → **reject even if names match** (different venues sharing a name)

**Side benefits:**
- Catches venue rebrands (Staples Center → Crypto.com Arena, same coords)
- Catches near-duplicate venue records within TEvo itself (sometimes "MSG" and "Madison Square Garden" exist as separate IDs)

**Output:** `venue_xref(tevo_venue_id, sg_venue_id, confidence, distance_m, …)`

**Open confirmation:** SeatGeek venue records expose `location.lat/lon` via public API. Need to verify it's persisted in `seatgeek_events` or a sibling table. If absent, fall back to geocoding SG venue addresses through the same OSM Nominatim pipeline already in place.

---

## Layer 2 — Performers

**Match key:** `(name_norm, category_norm)` + ESPN bridge.

**Logic:**
1. Both have ESPN `external_id` set, same id → **1.00** (canonical ID match)
2. Exact `(name, category)` → **1.00**
3. `(name_norm, category_norm)` → **0.95**
4. Fuzzy name within same category → **0.85**
5. **Sport-team bridge:** TEvo performer has `performer_external_ids(source='espn')` and SG performer name fuzzy-matches an ESPN team name → **0.80**
6. Else → unmatched, queue

**Edge cases:**
- Team rebrands (Bobcats → Hornets): handle via `performer_aliases` table
- Tour suffixes ("Taylor Swift" vs "Taylor Swift | The Eras Tour"): strip ` | …$` before compare
- DJ stage names vs legal names: manual xref only

---

## Layer 2.5 — Brokers (cross-source identity, secondary signal)

**Match key:** `(brokerage_name_norm)` — TEvo `office_id`/`brokerage_id`/`brokerage_name` vs SeatGeek SellerDirect seller info.

**Logic:**
1. Exact `(brokerage_name)` → **1.00**
2. Fuzzy `norm(brokerage_name)` ≥ 0.85 → **0.90**
3. Else → unmatched

**Why this layer matters:** when listings don't carry seat numbers (see Layer 4), broker identity becomes the strongest secondary signal for "same physical inventory across marketplaces." Without it, we under-match dramatically.

**Open confirmation:** SeatGeek SellerDirect order schema (`seatgeek_orders`) and listing schema (`seatgeek_seller_listings`) — verify what seller-identity fields are exposed and whether they're stable across the broker's order history.

---

## Layer 3 — Events (two paths: live and historical)

Per Finding 3, TEvo's `events` table doesn't retain history. Layer 3 splits into two paths based on whether a TEvo event row exists.

### Path A — Live / future events (TEvo event exists)

**Match key:** `(performer_xref, venue_xref, occurs_at within ±60 min)`. All three must resolve.

**Logic:**
1. Resolve TEvo event's performer → SG performer via Layer 2 (require confidence ≥ 0.85)
2. Resolve TEvo event's venue → SG venue via Layer 1 (require confidence ≥ 0.85)
3. Find SG events for `(sg_performer, sg_venue)` where `abs(sg_occurs_at - tevo_occurs_at) ≤ 60 min`
4. Exactly one match in window → confidence = `min(performer_conf, venue_conf) × time_score`
   - `time_score = 1.0` (within 5 min) | `0.95` (≤ 30 min) | `0.85` (≤ 60 min)
5. Zero matches → unmatched
6. Multiple matches → conflict; pick closest in time, mark `match_method='ambiguous'`

**Output:**
- Populate `seatgeek_event_xref(tevo_event_id, sg_event_id, match_method='live_v1', …)`
- **Backfill `seatgeek_orders.tevo_event_id`** via the xref (fixes the 0%-populated bug from the audit)

### Path B — Historical events (no TEvo event exists)

For SG orders whose `sg_event_date` doesn't match any TEvo event (the 400-order historical archive), don't wait on a TEvo event row that may never exist. Resolve **venue and performers separately**, attach the resolved IDs directly to the SG order, leave `tevo_event_id` NULL.

**Match key:** `(venue_xref, performer_xref[])` + the SG order's inline event metadata as canonical reference.

**Performer extraction from `sg_event_name`:**
- Sports: `"Team A at Team B"` / `"Team A vs Team B"` / `"Team A v Team B"` → two performers (away, home)
- Concert / single act: full name → one performer
- Festival / multi-act with `","`: comma-split → array of performers

**Logic:**
1. Tokenize `sg_event_name` into performers via the separators above
2. Resolve `sg_venue` → `tevo_venue_id` via Layer 1 (require confidence ≥ 0.85)
3. For each parsed performer: resolve to `tevo_performer_id` via Layer 2 (require ≥ 0.85). Drop unmatched performers from the array but don't fail the whole record.
4. Persist resolution on the order itself (or in a sidecar table) — see schema below

**Output schema:**
```sql
CREATE TABLE seatgeek_orders_resolved (
  sg_order_id           text PRIMARY KEY REFERENCES seatgeek_orders(sg_order_id),
  tevo_venue_id         bigint,
  venue_confidence      numeric(3,2),
  tevo_performer_ids    bigint[] NOT NULL DEFAULT '{}',  -- away first, home second for sports
  performer_confidences numeric(3,2)[] NOT NULL DEFAULT '{}',
  occurs_at_resolved    timestamptz,                     -- from sg_event_date + sg_event_time
  resolved_at           timestamptz NOT NULL DEFAULT now(),
  resolution_method     text NOT NULL,                    -- 'historical_venue_performer_v1'
  notes                 text
);
```

**What this unlocks (without needing a TEvo event row):**
- Per-performer historical sales: "Yankees have sold N tickets across X venues 2018–2025"
- Per-venue historical sales: "Yankee Stadium hosted Y events with Z gross 2018–2025"
- Cross-performer rivalry pricing: "Yankees vs Red Sox vs Yankees vs Angels — historical sale-price deltas"
- Date-bucketed performance ("2024 season Yankees @ Yankee Stadium sales pace")

**What stays NULL:** `seatgeek_orders.tevo_event_id` — acceptable, since there's no TEvo event to point at. Downstream consumers querying historical sales join on `tevo_venue_id` + `tevo_performer_ids` + `occurs_at_resolved` instead.

**Optional follow-on (data acquisition, not methodology):** backfill TEvo events for date ranges with unmatched SG orders via `/v9/events?occurs_at.gte=...&occurs_at.lte=...`. Out of scope for this doc — it's a one-off data-pull project.

---

## Layer 4 — Listings

**Doctrine restated:** seats are the only true identity signal. When seats aren't available, prefer leaving listings unmatched over guessing.

**Price is NOT a match key.** TEvo retail vs SeatGeek list diverges 10–30% on marketplace fees alone, and brokers independently mark up across venues. Price kept only as an observability column on the xref (records spread at match time).

**Match key precedence:**

| precedence | signal | required | confidence |
|---|---|---|---|
| 1 | Seat-array intersection (both sides) | seats present both sides | 1.00 (overlap) / locked non-match (disjoint) |
| 2 | Broker identity + `(section_norm, row, qty)` | broker_xref resolves both sides | 0.85 |
| 3 | One side has seats, other doesn't | n/a | **inconclusive — leave unmatched** |
| 4 | Neither side has seats, different brokers | n/a | **assume separate** — no match attempt |

**Section normalizer:**
```
section_norm(s):
  strip prefixes: "Section "|"Sec "|"S "
  strip positional: "Lower "|"Upper "|"L"|"U" (preserve digits)
  uppercase remainder
  GA aliases ("General Admission","Floor GA","Pit GA") → "GA"
  numeric sections → zero-padded 4-digit ("102" → "0102") for sort stability
```

**Output:** `listing_xref(tevo_ticket_group_id, sg_listing_id, captured_at_tevo, captured_at_sg, confidence, price_spread_pct, …)`. Do NOT unique on this — the same physical block re-listed over time is a legitimate sequence of new matches.

**What this prevents:**
- The 15 "soft-dup" patterns we found in `seatgeek_orders` (same `(section, row, qty)` selling multiple times) → correctly identified as separate sales because seat arrays don't intersect (or broker xref differs)
- GA seating dedup nightmares — "General Admission row GA7 qty 1" selling 50 times is 50 distinct sales by design

**What this won't catch (acceptable):**
- Same broker, same block, no seat data exposed on either side → matches as 0.85 but might be a false positive. The price spread column lets downstream consumers spot suspicious matches.

---

## Build order

| step | layer | est. effort | unblocks |
|---|---|---|---|
| 1 | Section normalizer SQL function | tiny | re-used in Layers 1, 4 |
| 2 | Venue xref (geo-first) | small (~thousands of rows) | foundation |
| 3 | Performer xref + ESPN bridge | medium | foundation |
| 3.5 | Broker xref | small | enables Layer 4 fallback |
| 4a | Event xref Path A (live/future) + backfill | medium | unlocks cross-source sales for active inventory |
| 4b | Event xref Path B (historical venue+performer resolve) | medium | unlocks 2018–2025 SG order analytics without waiting on TEvo history |
| 5 | Listing xref (seats > broker > unmatched) | large, separate design pass | unlocks dedup, arbitrage detection |

Each step lands as its own migration. Verify match accuracy at each level before depending on it downstream. Steps 1–4 are ~a day of work; Step 5 deserves its own follow-up doc once 4 is real.

## Cross-cutting decisions

1. **Manual overrides table** — single source of truth for "the system got this wrong; here's the right answer." Always beats auto-matches.
2. **Conflict log** — when two candidates tie within 0.05 confidence, log both with status `needs_review` and leave unmatched.
3. **Reactive refresh** — triggers on `events` / `performers` / `venues` inserts fire a match attempt. Nightly full re-scan catches independently-updated sources.
4. **Audit columns everywhere** — `matched_at`, `matched_by`, `match_method`, `notes`. Match decisions must be reproducible: if the matching rule changes, audit columns tell us what to invalidate.
5. **Confidence floor of 0.70** for any downstream consumer query. Rows below stay in xref tables but aren't trusted for sale dedup, listing union, or revenue rollups.

## Open confirmations before Step 2 migration

1. **SeatGeek venue coordinates** — are `lat/lon` persisted in `seatgeek_events` or a sibling table, or do we need to geocode SG venue addresses through the existing Nominatim pipeline?
2. **SeatGeek listing seat-level fields** — what does `seatgeek_seller_listings` expose? Need to know whether a `seats[]` array, `low_seat`, or any seat-level identifier is captured.
3. **SeatGeek SellerDirect seller identity** — what seller fields are on `seatgeek_orders` and listings? Stability of the seller identifier across a broker's history determines whether Layer 2.5 is viable.

## Handoff

| owner | action |
|---|---|
| **C1** (in-lane) | Verify the three open confirmations via MCP probes when Supabase connectivity stabilizes |
| **A1** (push) | Land migrations in step order. Each migration is a single layer; do not bundle. |
| **B1** (audit views) | Receives match-accuracy reports via S1 once Layer 4 has volume |

## Appendix — failure modes deliberately accepted

- **Venue with no coords on either side, two cities sharing a name** ("Springfield Arena" in MA and IL): Layer 1 will mis-match if `(name_norm, state)` is incomplete. Mitigated by requiring state on both sides.
- **Performer who changes name mid-season**: lands as unmatched until manual override.
- **Listings without seat numbers and different brokers**: never auto-match. Cross-marketplace dedup for this scenario is out of scope until a seat-level data source exists.
- **Time-zone bugs in event matching**: `occurs_at` is `timestamptz`. Storing in UTC consistently across sources is a precondition; mismatches surface as ±60 min misses and queue for review.
