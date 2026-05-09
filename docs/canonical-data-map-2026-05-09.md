# Canonical data map — 1:1 mapping across all sources (2026-05-09)

> **Purpose**: single reference for how every entity (event / performer / venue / listing / sale) maps across our 5 read-only sources, so cross-source queries don't keep re-deriving the join. Built to be **extensible** — adding a 6th source is a single INSERT into `data_sources` + a few rows in `data_source_field_map`.

---

## 0. The 5 sources, in one table

| `source_key` | Display | Kind | Host | Auth | What it gives |
|---|---|---|---|---|---|
| `tevo` | Ticket Evolution | pricing | api.ticketevolution.com | hmac_sha256 | **Hub source.** Events, performers, venues, listings, orders. `events.id` is canonical. |
| `sg_broker` | SeatGeek (broker data) | pricing | brokerdata.seatgeek.com | token query-string | `/listings`, `/v2/listings`, `/sales`. Broker-vs-fan tier flags. |
| `sg_seller` | SeatGeek (seller direct) | pricing | sellerdirect-api.seatgeek.com | token query-string | `/listings`, `/orders` for our own SG catalog. Cost basis + order history. |
| `seatdata` | SeatData | pricing | api.seatdata.io | api_key header | Sold listings (transacted). Multi-marketplace get-in. |
| `espn` | ESPN | enrichment | site.api.espn.com | public | Sports only. Standings, injuries, news, players. |
| `wikipedia` | Wikipedia | enrichment | en.wikipedia.org | public | Performer descriptions, extracts, images. |

Live in `data_sources` table. RULE 2: every source `read_only = true`.

---

## 1. The hub-and-spoke model

```
                  ┌──────────────────────────────┐
                  │       TEvo events.id          │   ← canonical anchor
                  └──────────┬───────────────────┘
                             │
        ┌──────────┬─────────┼─────────┬─────────────────┐
        │          │         │         │                 │
   event_xref  sd_event   sg_event   sg_events    espn_event_xref
   (ESPN)       _xref      _xref      _canonical    (deprecated; data
                                                     in event_xref)
        │          │         │         │
        v          v         v         v
   espn_event  seatdata    seatgeek  rich SG metadata + has_*
     _id         _event     _event    flags + tevo back-ref
                  _id         _id

                  ┌──────────────────────────────┐
                  │     TEvo performer_id         │   ← performer anchor
                  └──────────┬───────────────────┘
                             │
        ┌──────────┬─────────┼─────────┬─────────────┐
        │          │         │         │             │
   performer_   sd_perf    sg_perf   espn_team    performer_
    external                                       wikipedia
    _ids (espn)                                    (wiki_pageid)

                  ┌──────────────────────────────┐
                  │     TEvo venue_id (events.    │   ← venue anchor
                  │      venue_id reference)      │
                  └──────────┬───────────────────┘
                             │
                ┌────────────┼────────────┐
                │            │            │
            sd_venue      sg_venue   (ESPN does not
             _xref         _xref     expose venues)
```

**Read this rule once: TEvo's id is always the canonical key. Every other source xrefs *back* to TEvo. Never join two non-TEvo sources directly.** Always go through TEvo.

---

## 2. Field-by-field crosswalk

All cross-walks are queryable via the `data_source_field_map` table:

```sql
-- "Where does retail_price live across all sources?"
SELECT source_key, source_field, source_table, notes
FROM data_source_field_map
WHERE entity_kind='listing' AND canonical_field='retail_price';
```

The table is pre-seeded with **62 mappings** covering events, performers, venues, listings, and sales across all current sources. Adding a new source field = one INSERT.

### 2.1 Event

| Canonical field | tevo | sg_broker | seatdata | espn |
|---|---|---|---|---|
| `id` | `events.id` (bigint) | `sg_events_canonical.sg_event_id` | `seatdata_event_xref.sd_event_id` | `event_xref.espn_event_id` |
| `name` | `events.name` | `sg_events_canonical.sg_event_name` | (in raw_jsonb) | `event_xref.espn_name` |
| `date` | `events.occurs_at_local` (local TZ) | `sg_events_canonical.sg_event_date` | — | — |
| `datetime_utc` | (derive from occurs_at_local) | `sg_events_canonical.sg_datetime_utc` | — | — |
| `venue_id` | `events.venue_id` | `sg_events_canonical.sg_venue_id` | `seatdata_event_xref.sd_std_venue_id` | (not exposed) |
| `venue_name` | `events.venue_name` | `sg_events_canonical.sg_venue_name` | (in raw_jsonb) | (not exposed) |
| `event_type` / `category` | `events.event_type` (game/concert/comedy/show) | `sg_events_canonical.sg_category` (mlb/nba/concert/...) | `sd_event_type` | `espn_league` |

### 2.2 Performer

| Canonical field | tevo | sg_broker | seatdata | espn | wikipedia |
|---|---|---|---|---|---|
| `id` | `performer_metadata.performer_id` | (name only) | `seatdata_performer_xref.sd_performer_id` | `espn_team_id` | `wiki_pageid` |
| `name` | `performer_metadata.name` | `seatgeek_performer_xref.sg_performer_name` | — | (in performer_metadata.name) | `wiki_title` |
| `event_type` | `performer_metadata.what_event_type` | (inferred from event) | `sd_event_type` | (always 'sports') | — |
| `genre` (concert) | `performer_metadata.genre` | — | — | — | — |
| `league` (sports) | (derived) | — | — | `espn_league` | — |
| `description` | (none) | — | — | — | `description` |
| `extract` | (none) | — | — | — | `extract` |
| `image_url` | logos in performer_metadata | — | — | logos in performer_metadata | `image_url` |

### 2.3 Venue

| Canonical field | tevo | sg_broker | seatdata | espn |
|---|---|---|---|---|
| `id` | `events.venue_id` | `sg_events_canonical.sg_venue_id` | `seatdata_venue_xref.sd_std_venue_id` | (not exposed) |
| `name` | `events.venue_name` | `sg_events_canonical.sg_venue_name` | (in raw) | — |
| `city` | (in venue_assets if hydrated) | `sg_events_canonical.sg_venue_city` | (in raw) | — |
| `state` | — | `sg_events_canonical.sg_venue_state` | — | — |
| `address` | — | `sg_events_canonical.sg_venue_address` | — | — |

### 2.4 Listing (per-row inventory snapshot)

| Canonical field | tevo (listings_snapshots) | sg_broker (seatgeek_listings_snapshots) | sg_seller (seatgeek_seller_listings) | seatdata (seatdata_listings_snapshots) |
|---|---|---|---|---|
| `id` | `tevo_ticket_group_id` | `display_id` | `seller_listing_id` | `content_hash` |
| `sg_join_key` | — | `sglid` | `sg_listing_id` | — |
| `section` | `section` | `section` | `section` | `section` |
| `row` | `row` | `row` | `row` | `row` |
| `quantity` | `quantity` | `quantity` | `quantity` | `quantity` |
| `retail_price` | `retail_price` (all-in) | `retail_price_all_in` (=`pf`) | `cost` (our cost basis) | `price` |
| `wholesale_price` | `wholesale_price` | `broadcast_price` (=`bp`) | (no separate) | (none) |
| `splits` | `splits int[]` | `splits jsonb int[]` | (single qty implied) | (single qty implied) |
| `wheelchair` | `wheelchair` | `is_wheelchair_acc` | — | — |
| `instant_delivery` | `instant_delivery` | `is_instant_download` | `is_instant` | — |
| `eticket` | `eticket` | (always electronic) | `is_edelivery` | — |
| `is_owned` | `is_owned` | `is_broker_owned` (when known) | (always true — our seller catalog) | — |
| `broker_name` | `brokerage_name` | (opaque on SG) | (none) | — |
| `tier_b2b` | (no concept) | `is_b2b` | (no concept) | — |
| `tier_market` | (no concept) | `market_source` (`exchange`/`marketplace`) | `'exchange'` | — |

### 2.5 Sale (transacted / order)

| Canonical field | tevo (evo_orders) | sg_broker (seatgeek_orders, sg_seller) | seatdata SoldAPI (seatdata_sales_snapshots) |
|---|---|---|---|
| `id` | `order_id` | `sg_order_id` | (synthetic `content_hash`) |
| `price` | `price` | `sale_price` | **`price`** (was incorrectly mapped as `sold_price` — fixed in mig 220000) |
| `qty` | `quantity` | `sale_quantity` | `quantity` |
| `section` | (in evo_order_items) | `sale_section` | `section` |
| `row` | (in evo_order_items) | `sale_row` | `row` |
| `zone` | (none) | (none) | `zone` (SD coarse zone label) |
| `sale_timestamp` | (in evo_order_items) | `created_at_sg` | `sale_timestamp` (when transaction cleared) |
| `status` | `status` (canonical via order_status_xref) | `status` | (always sold) |
| `event_id` (TEvo) | `tevo_event_id` (via evo_order_items) | `tevo_event_id` | `tevo_event_id` |
| `payment_total` | (in evo_order_items) | `payment_total` (gross paid by buyer) | (none) |
| `payment_fees` | — | `payment_fees` (SG cut) | — |

Canonical state machine (6-state) defined in `order_status_xref`. Use `unified_orders` view to get one rowset across all 3 sources.

### 2.6 SeatData SoldAPI (`/v0.3/salesdata/get`) — full feed shape

The "SoldAPI" is SeatData's `/v0.3/salesdata/get` endpoint — sold-listings history. Always charged when rows are returned (per BASIC plan budget enforcement). Persisted to `seatdata_sales_snapshots` with these columns:

| Column | Source field in SD response | Notes |
|---|---|---|
| `tevo_event_id` | (joined via `seatdata_event_xref`) | Hub join key |
| `sd_event_id` | `event_id` | SD's id space |
| `sale_timestamp` | `sale_timestamp` | When the transaction cleared |
| `quantity` | `quantity` | Number of tickets sold |
| `price` | `price` | Realized retail price (per ticket) |
| `zone` | `zone` | Coarse zone (e.g. "Lower Bowl") |
| `section` | `section` | Section number/name |
| `row` | `row` | Row label |
| `content_hash` | (computed) | Dedup key |

We have **254 rows** for 1 event (Knicks G5) currently — every row is a transacted sale, not a listing. Also persisted: `seatdata_event_stats` (pricing time series with `sold_median`, `sold_mean`, `getin_min`, `getin_listings_count`, `total_count`, `total_sold` — see field-map for full list).

---

## 3. Canonical entry-point views

### 3.1 `v_canonical_event`
One row per TEvo event with **every** known cross-source ID + label inline. Joins:
- `entity_event_map` (the existing TEvo+ESPN+SD+SG xref view)
- `sg_events_canonical` (SG metadata + has_* provenance flags)
- `taxonomy_xref` (canonical league label)

```sql
SELECT * FROM v_canonical_event WHERE tevo_event_id = 3092720;
```

### 3.2 `v_canonical_performer`
One row per TEvo performer with **every** known cross-source ID + Wikipedia content. Joins:
- `entity_performer_map` (TEvo + ESPN + SD + SG)
- `performer_wikipedia` (Wikipedia summary)

```sql
SELECT tevo_performer_name, espn_league, wiki_extract
FROM v_canonical_performer WHERE tevo_performer_id = 1234;
```

### 3.3 `unified_orders` (existing) + `unified_listings` (new)
**Sales side**: 1 row per sale, UNIONed across `evo_orders` + `seatgeek_orders` + `seatdata_sales_snapshots`. Canonical 6-state status.

**Listings side**: 1 row per listing snapshot, UNIONed across `listings_snapshots` (TEvo) + `seatgeek_listings_snapshots` (SG broker /v2) + `seatgeek_seller_listings` (our SG catalog) + `seatdata_listings_snapshots`. Carries `source_key` tag so cross-source pivots work.

### 3.4 `v_canonical_coverage`
Quick health-check counts — how many events / performers have N+ sources matched. Use as a daily smoke test.

---

## 4. Adding a new data source — checklist

To bring a 6th source online (Twitter / Reddit / Google Trends / NOAA / your-favorite-API):

1. **Register**: `INSERT INTO data_sources (source_key, display_name, kind, host, auth_method, notes) VALUES (...)`.
2. **Decide on per-source xref or universal**: either create a dedicated `{src}_event_xref` table (legacy pattern, more typed columns) OR use the universal `canonical_external_ids` table (fewer schema changes).
3. **Document the field map**: `INSERT INTO data_source_field_map (...)` rows for every (entity_kind, canonical_field) the source contributes.
4. **Plumb the listing/sale side**: if it has price data, add a UNION branch to `unified_listings` or `unified_orders`.
5. **Plumb the entity-view side**: add the new source's ids/columns to `v_canonical_event` and/or `v_canonical_performer` LEFT JOINs.
6. **Cron + ingest**: add a pg_cron job that calls the new client (Python via Railway, or pg_net + vault if read-only-from-Postgres). Follow RULE 2 (`scripts/check_readonly.py` will scream if you POST).
7. **Verify**: `SELECT * FROM v_canonical_coverage` should now show counts going up for the new source.

That's it. Step 1+2+3 take 5 minutes. Step 4-7 depend on the source.

---

## 5. RULE 2 compliance for all sources

Every source above is **read-only**. The enforcement stack (per `SCHEMA.md` RULE 2 section):

1. **Runtime guards** in Python clients (`evo_client.py`, `seatgeek_client.py`, `seatdata_client.py`)
2. **Static analysis** (`scripts/check_readonly.py`) scans Python + TS for non-GET to forbidden hosts
3. **Unit tests** (`tests/test_readonly_guards.py`) assert guards raise on non-GET
4. **plpgsql convention**: all server-side fetches use `net.http_get` only. The audit script will be extended to scan `supabase/migrations/*.sql` for non-GET pg_net calls to those hosts in a follow-up.
5. **`data_sources.read_only = true`** is the declarative source of truth. Any future source that violates this should not be registered.

---

## 6. Coverage snapshot (live counts as of 2026-05-09)

| Entity | Total canonical rows | with ESPN | with SeatData | with SeatGeek | 2+ sources |
|---|---|---|---|---|---|
| Event | 1,538 | 430 | 1 | 3 | 4 |
| Performer | 183 | 119 | 0 | 57 | 121 |

Plus 25 SG events tracked in `sg_events_canonical` (211 if you count the 186 historical orders-only rows). 8.5M TEvo listings rows + 200 SG seller catalog rows in `unified_listings` today.

**`data_source_field_map` coverage**: 190 mappings across 25 tables, **0 unmapped**.

| source_key | mappings | entity_kinds covered |
|---|---|---|
| `tevo` | 50 | event, event_metrics, performer, venue, listing, sale, derived |
| `sg_broker` | 39 | event, performer, venue, listing, sale, sale_broker, derived |
| `seatdata` | 33 | event, event_stats, performer, venue, section, zone, listing, sale (SoldAPI) |
| `espn` | 31 | event, performer, snapshot, event_snapshot, injury, news, athlete |
| `sg_seller` | 30 | event, listing, sale, order_ticket |
| `wikipedia` | 7 | performer |

Refresh anytime:

```sql
SELECT * FROM v_canonical_coverage;
SELECT * FROM data_source_field_map_audit;  -- drift detector
```

---

## 7. Files / migrations involved

| Migration | Concern |
|---|---|
| `20260509120000_cross_source_entity_maps.sql` | original `entity_event_map` / `entity_performer_map` / `entity_venue_map` |
| `20260509150000_sg_events_canonical_and_performer_wiki.sql` | `sg_events_canonical` table + `performer_wikipedia` table |
| `20260509170000_performer_wikipedia_enrichment.sql` | Wikipedia ingest cron |
| `20260509180000_sg_canonical_orders_sales_sync.sql` | extend canonical sync to orders + broker sales |
| `20260509190000_seatgeek_historic_sales.sql` | historic-data fabric (performer + season + section) |
| `20260509200000_seatgeek_historic_views.sql` | analytical views on historic |
| `20260509210000_canonical_data_map.sql` | initial registry + field map (62 rows) + universal external_ids + unified_listings + v_canonical_event/performer/coverage |
| **`20260509220000_full_field_map_coverage.sql`** | **THIS migration** — 128 added field mappings (SoldAPI complete + sg_seller complete + ESPN snapshots/injuries/news/athlete + TEvo extras + Wikipedia extras + drift-detection audit view). Bug-fix: SD sale price was incorrectly mapped to `sold_price`; corrected to `price`. |

---

## 8. Status

Filed by: code · 2026-05-09
RULE 2: read-only across all sources, declarative + runtime + static + tested.
Next: TEvo creds in vault → SQL function for `tevo_search_events_for_unmatched_sg()` → close the 22-event gap from canonical.
