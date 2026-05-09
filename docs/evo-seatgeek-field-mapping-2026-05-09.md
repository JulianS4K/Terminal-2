# EVO ↔ SeatGeek field mapping (2026-05-09)

> Single map of how to translate between TEvo `listings_snapshots` and SG `/v2/listings` listing rows. Built so cross-source SQL doesn't have to re-derive the join every time. Includes per-category coverage + the SG broker-vs-fan tier model that has no EVO equivalent.

---

## 0. Coverage status — categories with confirmed live samples

Live `/v2/listings` calls ran 2026-05-09 ~10:00 UTC. All 8 calls returned 200 OK. Response IDs in `net._http_response` (transient).

| Category | SG event sampled | Listings | Tix | Pro broker | B2B-only | Fan resale | Box office | Median retail | Response ID |
|---|---|---|---|---|---|---|---|---|---|
| MLB | Rockies @ DBacks 5/22 | 2,093 | 14,133 | 1,790 | 164 | **104** | 35 | $78.67 | 4448 |
| WNBA | Sky @ Liberty 8/29 | 984 | 4,430 | 566 | 303 | 0 | **115** | $122.66 | 4476 |
| MLS | Inter Miami @ Fire 9/9 | 1,828 | 9,912 | 1,431 | 286 | 0 | **111** | $327.45 | 4477 |
| NCAA-FB | LSU @ Kentucky 10/10 | 504 | 1,971 | 493 | 0 | 0 | 11 | $278.72 | 4478 |
| Concert (stadium) | BTS @ Stanford Stadium | 786 | 2,120 | 728 | 28 | 0 | 2 | $344.20 | 4479 |
| Concert (arena) | Jack Harlow @ A.J. Brady | 428 | 1,877 | 364 | 62 | 0 | 2 | $132.65 | 4480 |
| Comedy | Trevor Noah @ SB Bowl | 368 | 1,342 | 277 | 90 | 0 | 1 | $177.12 | 4481 |
| Parking | Marlins @ Mets parking | 37 | 55 | 33 | 2 | 0 | 2 | $128.58 | 4482 |

**Missing categories** (need manual SG event ID lookup — broker API has no search endpoint):
- **NBA** — none in current seller catalog
- **NFL** — none in current seller catalog
- **NHL** — none in current seller catalog
- **Theater / Broadway** — none in current seller catalog

When these are filled, the 8-row table above expands to 12 and the simulation set is complete.

---

## 1. Listing-row field mapping (the crosswalk)

### 1.1 Direct equivalents (1:1)

| EVO `listings_snapshots` | SG `/v2/listings` listing | Notes |
|---|---|---|
| `tevo_ticket_group_id` | `id` (string) + `sglid` (int, broker only) | EVO id is bigint, SG `id` is opaque short string, `sglid` is 11-digit int that joins to `seatgeek_seller_listings.sg_listing_id` for our own inventory |
| `section` | `s` | text both sides; same convention |
| `row` | `r` | text both sides; **GA / pit listings have row=NULL or "GA"** on both |
| `quantity` | `q` | int both sides |
| `splits` (int[]) | `sp` (int[]) | **Same encoding** — array of allowed split sizes. Direct cross-source aggregation possible |
| `wheelchair` | `wa` | bool both sides |
| `eticket` | (always true on SG broker) | SG broker side has no paper-ticket listings |

### 1.2 Pricing — both sources expose dual-price model

| EVO | SG | Meaning |
|---|---|---|
| `retail_price` | `pf` | Price floor / all-in retail (what the buyer sees, fees included) |
| `wholesale_price` | `bp` | Base price / broadcast price (seller payout, fee-stripped) |

**Fee load** (derived metric, comparable across sources):
- EVO: `(retail_price - wholesale_price) / wholesale_price` → typically 10-15%
- SG: `(pf - bp) / bp` → typically 26-37% on the test event

That spread (10% TEvo fee vs ~30% SG fee) is itself a useful signal for arbitrage simulations.

### 1.3 Stock / delivery — overlapping but encoded differently

| EVO `format` | SG `dm` + `st` |
|---|---|
| `TM_mobile` | `dm=electronic` + `st=mobile` (Ticketmaster mobile) |
| `Eticket` | `dm=electronic` + `st=pdf` |
| (varies) | `dm=sg_app` + `st=barcode` (SG-managed barcodes — MLB-dominant) |
| (varies) | `dm=sg_app` + `st=mobile` |

**Category-level pattern** (from samples):
- MLB: 92% `barcode` (MLB Ballpark app dominant)
- WNBA / MLS / NCAA-FB / Concert / Comedy: ~100% `mobile`
- Parking: 100% `mobile`

So if you query "barcode-only listings" on SG, you're effectively filtering to MLB.

### 1.4 The big asymmetries — fields that exist on ONE side only

| EVO has · SG doesn't | Why it matters |
|---|---|
| `office_id`, `office_name`, `brokerage_id`, `brokerage_name` | **Identifies competing broker by name.** "VividSeats listed at $X" — visible on EVO, opaque on SG. Big intelligence delta. |
| `is_owned` | Direct flag. SG requires sglid join to `seatgeek_seller_listings` |
| `is_ancillary` + `type` | Parking/merch/etc. flag. SG encodes parking only at the event-level `category` field |
| `wholesale_price` distinct from `retail_price` for non-owned | EVO exposes both prices for every listing. SG bp/pf gap is fee-only |

| SG has · EVO doesn't | Why it matters |
|---|---|
| `m` (marketplace tier: exchange / marketplace) | **Broker-network vs fan-resale split** — see §2 |
| `is_b2b` | Wholesale tier hidden from consumers |
| `bo` (box office) | Direct-from-venue listings |
| `ada` (text details) | EVO only has wheelchair bool |
| `sro` (standing room) | Concert / parking signal — never on EVO |
| `lv` (live, still bookable) | Pre-purchase staleness flag |
| `idl` (instant deliverable) | Subset of EVO `instant_delivery` semantics |
| `ihd` (in-hand date, per-listing) | EVO exposes only at event level |
| `pn` (partner name) | Sparse + inconsistent — see §3 |
| `ds` (deal quality score) | SG-computed score; no EVO analog |

---

## 2. The SG broker-vs-fan tier model (no EVO equivalent)

EVO's universe is **all-broker** — every row is a brokerage listing. SG mixes 4 tiers in one feed:

```
SG /v2/listings response
├── m='exchange' + is_b2b=false + bo=false   →  PRO_BROKER (consumer-facing brokers)
├── m='exchange' + is_b2b=true                →  B2B_ONLY (wholesale tier, hidden from consumers)
├── m='exchange' + bo=true                    →  BOX_OFFICE (venue direct)
└── m='marketplace'                           →  FAN_RESALE (consumers re-listing)

  /listings (v1) returns only the 'exchange' subset (PRO_BROKER + B2B + BOX_OFFICE)
  /v2/listings adds the 'marketplace' tier (FAN_RESALE)
```

### 2.1 The 4-tier SQL helper (paste into simulations)

```sql
-- Bucket SG /v2 listings into the 4 canonical tiers
CASE
  WHEN listing->>'m' = 'marketplace' THEN 'FAN_RESALE'
  WHEN (listing->>'bo')::bool        THEN 'BOX_OFFICE'
  WHEN (listing->>'is_b2b')::bool    THEN 'B2B_ONLY'
  ELSE                                    'PRO_BROKER'
END AS sg_tier
```

### 2.2 Tier presence varies by category

| Category | Pro broker | B2B-only | Fan resale | Box office | Notes |
|---|---|---|---|---|---|
| MLB | dominant | small | **5%** | small | Only category with material fan resale |
| WNBA | dominant | 31% | 0 | **12%** | Big primary supply still active |
| MLS | dominant | 16% | 0 | **6%** | Soccer = international club ticketing artifacts |
| NCAA-FB | dominant | 0 | 0 | small | Athletic dept controls supply tightly |
| Concert (stadium) | dominant | small | 0 | small | Brokers dominate stadium tour resale |
| Concert (arena) | dominant | 14% | 0 | small | 21% SRO listings (pit/floor) |
| Comedy | dominant | 24% | 0 | small | Large B2B tier — comedy speculation common |
| Parking | dominant | small | 0 | small | Tiny totals (37 listings) |

### 2.3 Why this matters for simulation views

- **"Market median" filtered to PRO_BROKER only** is the closest comp to EVO `nonowned_median_retail`. Other tiers are noise for that comparison.
- **Fan-resale band growing** = consumer-side dump signal (only meaningful for MLB right now).
- **B2B-only median vs PRO_BROKER median** = wholesale-vs-retail spread on a single platform. Big simulation input.
- **Box-office band shrinking over time** = primary supply absorption rate, useful for sellout prediction.

---

## 3. Per-listing fields that look useful but aren't reliable

| Field | Why it looks useful | Why it isn't |
|---|---|---|
| `pn` (partner name) | Could ID the broker | Population varies wildly: 53% on arena concerts, 22% on MLB, 0.4% on NCAA-FB. Not deterministic. Treat as supplementary at most. |
| `idl` (instant_deliverable) | Sounds like EVO's instant_delivery | Semantics ambiguous in SG docs; some `idl=true` listings have `ihd` future-dated. Don't rely on it for "available right now" filtering — use `lv` (live) instead. |
| `ihd` empty string vs null | One should mean "in-hand now," the other "unknown" | In samples both empty-string and missing values exist for the same event; treat them as equivalent unknowns |

---

## 4. Event-level mapping (header, not listing rows)

| EVO `events` | SG `/v2/listings` event block | Notes |
|---|---|---|
| `events.id` | `event.id` | Independent ID spaces — manual xref via `seatgeek_event_xref` |
| `events.name` | `event.name` | Same string in 80%+ cases; `sg_attempt_event_xref()` does fuzzy matching |
| `events.event_type` | `event.category` | See §4.1 — hand-built crosswalk |
| `events.venue_name` | `event.venue.name` | |
| `events.occurs_at_local` (local time) | `event.datetime_utc` (UTC) | TZ conversion required |

### 4.1 Category crosswalk (from `taxonomy_xref` table)

| Canonical label | TEvo `event_type` | SG `event.category` | ESPN league | SeatData type |
|---|---|---|---|---|
| MLB | `game` | `mlb` | MLB | `baseball` |
| NBA | `game` | `nba` | NBA | `basketball` |
| WNBA | `game` | `wnba` | WNBA | `basketball` |
| NFL | `game` | `nfl` | NFL | `football` |
| NHL | `game` | `nhl` | NHL | `hockey` |
| MLS | `game` | `mls` | MLS | `soccer` |
| NCAA-FB | `game` | `ncaa_football` | NCAAF | `football` |
| NCAA-MBB | `game` | `ncaa_basketball` | NCAA | `basketball` |
| Concert | `concert` | `concert` | (none) | `concert` |
| Comedy | `concert` (!) | `comedy` | (none) | `comedy` |
| Theater | `concert` (!) | `theater` | (none) | `theater` |
| Parking | (varies) | `parking` | (none) | (none) |

**Two important quirks**:
1. TEvo lumps Concert + Comedy + Theater all under `event_type='concert'`. To split cleanly you must use SG `event.category` OR derive from venue (Broadway theater names) + performer (comedian roster).
2. TEvo's NCAA games tag as `event_type='game'` with no league sub-field. SG's `category` is the only reliable league-level sport identifier in our cross-source data.

---

## 5. Recommended simulation-ready helpers (suggested follow-on work)

1. **`unified_listings` view** — UNIONs `listings_snapshots` (EVO) + `seatgeek_listings_snapshots` (SG when populated) with normalized columns (`source`, `event_id`, `tier`, `section`, `row`, `quantity`, `retail_price`, `wholesale_price`, `splits`, etc.). One simulation query → both sources.

2. **`event_category_dimensions` view** — Pre-joined `events` × `taxonomy_xref` by event_type, with both `evo_label` and `sg_category` columns. Avoids re-joining `taxonomy_xref` on every query.

3. **`sg_market_summary_by_event` materialized view** — Per-event aggregations grouped by SG tier (pro_broker / b2b / fan / box_office), refreshed alongside the SG listings cron. Mirror of `event_metrics` but tier-aware.

4. **Persistence cron for `/v2/listings`** — currently zero rows in `seatgeek_listings_snapshots`. Daily sweep over the 25 events with seller listings would populate it; the schema is already a perfect match.

5. **`broker_office_dim` lookup** — EVO exposes `office_name` / `brokerage_name` strings. Building a dimension table over `(office_id, brokerage_id)` lets simulation queries roll up by competing broker. SG can't contribute to this (sglid is opaque) but it's an EVO-only insight worth surfacing.

---

## 6. Status

Filed by: code · 2026-05-09
Follow-ups: NBA / NFL / NHL / Theater sample IDs needed for full category parity (manual SG event ID lookup — no broker search API). All persistence helpers above are read-only; RULE 2 preserved.
