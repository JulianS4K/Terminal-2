# Proposed new tables — review packet for A1

Produced by C1 (Data + Chat Bot, supervisor). Implementation-ready specs for the 7 tables surfaced across the 2026-05-11 audit batch. Pre-implementation review checklist included per table.

**Status:** **AWAITING REVIEW.** No DDL applied. No tables created. Per user directive `pause for system audit before we implement`.

**Branch for implementation:** create a new feature branch from `main`. Do **not** bundle these migrations onto the audit branch `claude/audit-data-sources-b7EGu`.

**Migration ordering:** the 7 proposals are independent except where flagged. Implement in priority order (1 → 7). Each gets its own migration file.

### §9 audit-lane compliance baseline (applies to every spec below)

Per `MIGRATION_CONVENTIONS.md` §9 + §10, every new table must include:
- `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` and `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`
- `BEFORE UPDATE` trigger calling `trg_set_updated_at()` to auto-bump `updated_at`
- `ON CONFLICT` clauses on every UPSERT
- `meta JSONB` column on any table that may evolve (xref tables, governance tables)
- §6 header block at the top of the migration file (lane, touches, pre-reqs)
- No `DROP` operations; if needed, separate rollback migration

The schemas below already incorporate these requirements. Lane / timestamp guidance per proposal indicates whose worktree implements.

---

## Build priority

| # | table | priority | dependency | lane (per §2) |
|---|---|---|---|---|
| 1 | `seatgeek_orders_resolved` | **HIGH** | none | canonical |
| 2 | `v_pg_net_queue_health` (view) | **HIGH** | none | xref+macro (audit) |
| 3 | `event_section_row_snapshots` | medium | none | audit (TEvo ingest) |
| 4 | `entity_xref_overrides` + `entity_xref_conflicts` | medium | precondition for 5–7 | canonical |
| 5 | `broker_xref` | medium | depends on 4 (overrides) | canonical |
| 6 | `listing_xref` | low | depends on 4, 5 | canonical |
| 7 | `tevo_event_archive` | low | optional, defer-able | audit (TEvo) |

---

## #1 — `seatgeek_orders_resolved`

### Purpose
Direct attachment of TEvo venue + performer IDs to historical SeatGeek orders that have no corresponding TEvo event row. Implements Path B from `docs/cross-source-entity-resolution-2026-05-11.md`.

### Why it's needed
- 400 SG orders span 2018–2025
- `seatgeek_orders.tevo_event_id` is 0% backfilled
- TEvo's `events` table only retains 293 past events; **0 share a date with SG orders**
- Path B sample fix (exact-name only, no normalization) resolved venue for **271/400 (67.8%)** and full venue+both performers for **79/400 (19.8%)**

### Lane / suggested slot
- **Lane:** canonical (per §2)
- **Filename:** `20260512100000_canonical_seatgeek_orders_resolved.sql` (or earliest free slot in `20260512` band)
- **Header block:**
  ```sql
  -- ============================================================================
  -- Migration 20260512100000 — seatgeek_orders_resolved (Path B venue+performer)
  --
  -- Lane:     canonical
  -- Touches:  seatgeek_orders_resolved (W), v_canonical_venue (R), v_canonical_performer (R), seatgeek_orders (R)
  -- Pre-reqs: v_canonical_venue, v_canonical_performer must exist
  --
  -- Resolves tevo_venue_id + tevo_performer_ids directly on each SeatGeek
  -- order, bypassing the missing TEvo event row for historical 2018-2025 sales.
  -- Methodology: docs/cross-source-entity-resolution-2026-05-11.md Path B.
  -- ============================================================================
  ```

### Schema

```sql
CREATE TABLE seatgeek_orders_resolved (
  sg_order_id           text PRIMARY KEY REFERENCES seatgeek_orders(sg_order_id) ON DELETE CASCADE,
  tevo_venue_id         bigint,
  venue_confidence      numeric(3,2),
  venue_match_method    text,
  tevo_performer_ids    bigint[]      NOT NULL DEFAULT '{}',
  performer_confidences numeric(3,2)[] NOT NULL DEFAULT '{}',
  performer_match_methods text[]      NOT NULL DEFAULT '{}',
  occurs_at_resolved    timestamptz,
  resolution_method     text          NOT NULL,    -- 'historical_venue_performer_v1' etc.
  notes                 text,
  meta                  jsonb         NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz   NOT NULL DEFAULT now(),
  updated_at            timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX ON seatgeek_orders_resolved (tevo_venue_id) WHERE tevo_venue_id IS NOT NULL;
CREATE INDEX ON seatgeek_orders_resolved USING GIN (tevo_performer_ids);
CREATE INDEX ON seatgeek_orders_resolved (occurs_at_resolved);

CREATE TRIGGER seatgeek_orders_resolved_updated_at
  BEFORE UPDATE ON seatgeek_orders_resolved
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
```

### Population
- One-time backfill via SQL function that walks `seatgeek_orders`, parses `sg_event_name` for sports separators (` at `, ` vs `, ` v `), resolves via `v_canonical_venue` + `v_canonical_performer`.
- Reactive trigger on `seatgeek_orders` INSERT to populate new rows.
- Optional: nightly re-scan to catch xref updates.

### Acceptance criteria
- [ ] At least 79 orders (19.8%) get full match (venue + both performers)
- [ ] At least 271 orders (67.8%) get venue match
- [ ] Re-run is idempotent (`ON CONFLICT (sg_order_id) DO UPDATE`)
- [ ] No row written with `venue_confidence < 0.70` or `performer_confidences[i] < 0.70`

### Reviewer checks
- [ ] Foreign key to `seatgeek_orders` confirmed (ON DELETE CASCADE)
- [ ] Array columns kept length-aligned (`tevo_performer_ids` and `performer_confidences` same length)
- [ ] No accidental write to `public.seatgeek_orders` itself (this is a sidecar, not a column add)
- [ ] Performer ordering convention documented (away first, home second for sports)

---

## #2 — `v_pg_net_queue_health` (view)

### Purpose
Aggregate monitoring across all `*_pending` tables to detect the pg_net retention bug class found on `nws_alert_pending`.

### Why it's needed
- 94 NWS pending rows stuck for 24+ hours, all unjoinable to `net._http_response` (responses GC'd)
- 11 SG seller pending rows showing similar pattern
- 14 other `*_pending` tables clean today — but they're at risk of the same failure mode

### Schema

```sql
CREATE OR REPLACE VIEW v_pg_net_queue_health AS
WITH q AS (
  SELECT 'nws_alert_pending' AS queue,
         COUNT(*) FILTER (WHERE resolved_at IS NULL) AS unresolved,
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours') AS stale_12h,
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours') AS stale_24h,
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL) AS oldest_unresolved
    FROM nws_alert_pending
  UNION ALL SELECT 'sg_seller_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM sg_seller_pending
  -- ...repeat UNION ALL for each of the 14 remaining *_pending tables
)
SELECT queue, unresolved, stale_12h, stale_24h, oldest_unresolved,
       CASE WHEN unresolved = 0 THEN 'clean'
            WHEN stale_24h > 100 THEN 'critical'
            WHEN stale_24h > 25 THEN 'warning'
            WHEN unresolved > 0 THEN 'monitoring'
       END AS status
FROM q;
```

### Acceptance criteria
- [ ] One row per `*_pending` table — confirm with `SELECT COUNT(*) FROM v_pg_net_queue_health` returns 16
- [ ] Today's known states reflected: `nws_alert_pending` shows `critical`, `sg_seller_pending` shows `monitoring`
- [ ] View doesn't reference non-existent tables (fred_pending and sg_sales_pending referenced in some migrations but don't exist — exclude)

### Reviewer checks
- [ ] All 16 `*_pending` tables enumerated (cross-check with `grep -roEh "CREATE TABLE.*_pending" migrations/`)
- [ ] Reads are cheap — UNION ALL of count queries, no expensive joins
- [ ] Status thresholds (25 / 100) align with operational expectations; tune if needed

---

## #3 — `event_section_row_snapshots`

### Purpose
Per-event-per-snapshot rollup at `(section, row, quantity)` grain. Source-tagged to avoid cross-marketplace double-counting.

### Why it's needed
- User requested section/row/qty performance tracking
- `listings_snapshots` has the raw data but at per-ticket-group grain (7M rows historically)
- A rollup table answers "how did section 102 row 5 behave over time" in one index hit
- Test query on event 3345912 showed clean section/row data (100% non-null) and meaningful 20-min deltas (829 → 104 tix in 140 min)

### Schema

### Lane / suggested slot
- **Lane:** audit (TEvo ingest extension)
- **Filename:** `20260512120000_audit_event_section_row_snapshots.sql`
- **Header block:**
  ```sql
  -- ============================================================================
  -- Migration 20260512120000 — event_section_row_snapshots (per-event section/row rollup)
  --
  -- Lane:     xref+macro (audit)
  -- Touches:  event_section_row_snapshots (W), listings_snapshots (R), events (R)
  -- Pre-reqs: section_norm() function (created in this migration if absent)
  --
  -- Source-tagged rollup at (event_id, source, section_norm, row, quantity) grain.
  -- Change-only insert via content_hash. Feeds section/row/qty performance views.
  -- ============================================================================
  ```

### Schema

```sql
CREATE TABLE event_section_row_snapshots (
  event_id        bigint      NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  source          text        NOT NULL,            -- 'tevo' | 'seatgeek'
  captured_at     timestamptz NOT NULL,
  section_norm    text        NOT NULL,            -- output of section_norm() function
  row             text        NOT NULL,
  quantity        int         NOT NULL,
  listings_count  int         NOT NULL,
  min_price       numeric(10,2),
  median_price    numeric(10,2),
  max_price       numeric(10,2),
  owned_quantity  int         NOT NULL DEFAULT 0,
  content_hash    text        NOT NULL,            -- change-only insert key
  meta            jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, source, captured_at, section_norm, row)
);

CREATE INDEX ON event_section_row_snapshots (event_id, section_norm, row, captured_at DESC);
CREATE INDEX ON event_section_row_snapshots (captured_at DESC);

CREATE TRIGGER event_section_row_snapshots_updated_at
  BEFORE UPDATE ON event_section_row_snapshots
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- Helper function (also reused by xref work)
CREATE OR REPLACE FUNCTION section_norm(s text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT upper(regexp_replace(regexp_replace(coalesce(s,''),
           '^(section\s+|sec\s+|s\s+)', '', 'i'),
           '^(lower\s+|upper\s+|l|u)([0-9])', '\2', 'i'));
$$;
```

### Population
- Trigger on `listings_snapshots` after-insert that rolls up to `(event_id, captured_at, section_norm, row, quantity)`.
- Content_hash = `md5(quantity || '|' || listings_count || '|' || coalesce(median_price::text,''))` — only insert if changed from last snapshot for the same (event, source, section_norm, row).

### Acceptance criteria
- [ ] Storage ≤ 100 MB after 30 days (change-only insert effective)
- [ ] Test query for event 3345912 returns at least the 8 snapshots we observed
- [ ] Re-run idempotent

### Reviewer checks
- [ ] Section normalization handles GA / floor / parking edge cases
- [ ] Parking rows (`is_ancillary=true`) excluded from rollup
- [ ] Trigger doesn't blow up storage on the hot path

---

## #4 — `entity_xref_overrides` + `entity_xref_conflicts`

### Purpose
Governance layer for the 4-layer entity resolution methodology. Manual overrides always beat auto-matches; conflicts are logged for review.

### Why it's needed
- Methodology requires reproducible audit trail for match decisions
- Currently the existing xref tables (`seatgeek_event_xref`, `_venue_xref`, `_performer_xref`) have no override mechanism
- When two candidates tie within 0.05 confidence, current pipeline either silently picks one or rejects both — no review path

### Schema

### Lane / suggested slot
- **Lane:** canonical
- **Filename:** `20260512140000_canonical_entity_xref_governance.sql`
- **Header block:**
  ```sql
  -- ============================================================================
  -- Migration 20260512140000 — entity_xref governance (overrides + conflicts)
  --
  -- Lane:     canonical
  -- Touches:  entity_xref_overrides (W), entity_xref_conflicts (W)
  -- Pre-reqs: none (precondition for broker_xref, listing_xref migrations)
  --
  -- Manual override + conflict log for the 4.5-layer xref methodology.
  -- Overrides always beat auto-matches; conflicts logged when candidates tie.
  -- ============================================================================
  ```

### Schema

```sql
CREATE TABLE entity_xref_overrides (
  layer       text NOT NULL CHECK (layer IN ('venue', 'performer', 'broker', 'event', 'listing')),
  tevo_id     text NOT NULL,
  sg_id       text NOT NULL,
  reason      text,
  set_by      text NOT NULL,
  meta        jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (layer, tevo_id)
);

CREATE TRIGGER entity_xref_overrides_updated_at
  BEFORE UPDATE ON entity_xref_overrides
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

CREATE TABLE entity_xref_conflicts (
  id                   bigserial PRIMARY KEY,
  layer                text NOT NULL,
  tevo_id              text NOT NULL,
  candidate_sg_ids     text[] NOT NULL,
  confidence_scores    numeric(3,2)[] NOT NULL,
  status               text NOT NULL DEFAULT 'needs_review'
                       CHECK (status IN ('needs_review', 'resolved', 'dismissed')),
  resolved_at          timestamptz,
  resolution_note      text,
  meta                 jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON entity_xref_conflicts (layer, status, created_at);

CREATE TRIGGER entity_xref_conflicts_updated_at
  BEFORE UPDATE ON entity_xref_conflicts
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
```

### Acceptance criteria
- [ ] Inserting into `entity_xref_overrides` rejects a duplicate `(layer, tevo_id)` — only one canonical override per (layer, entity)
- [ ] `entity_xref_conflicts.status` constrained to enum
- [ ] No FK to specific entity tables — `tevo_id` and `sg_id` are text for polymorphism across all 5 layers

### Reviewer checks
- [ ] `set_by` column required — every override traceable
- [ ] Overrides surface in all 5 layer-specific xref-resolution queries (downstream work, not in this migration)

---

## #5 — `broker_xref`

### Purpose
Map TEvo brokerages to SeatGeek SellerDirect sellers. Layer 2.5 from methodology. Enables Layer 4 (listing match) to fall back on broker identity when seat numbers aren't available.

### Why it's needed
- Most TEvo `listings_snapshots` rows lack seat numbers
- Without seat data, broker identity is the strongest cross-source key
- No broker xref currently exists in schema

### Schema

### Lane / suggested slot
- **Lane:** canonical
- **Filename:** `20260512160000_canonical_broker_xref.sql`
- **Header block:**
  ```sql
  -- ============================================================================
  -- Migration 20260512160000 — broker_xref (TEvo brokerage ↔ SG seller)
  --
  -- Lane:     canonical
  -- Touches:  broker_xref (W), listings_snapshots (R), seatgeek_seller_listings (R)
  -- Pre-reqs: 20260512140000 (entity_xref_overrides for manual overrides)
  --
  -- Layer 2.5 xref enabling Layer 4 (listing match) to fall back on broker
  -- identity when seat numbers aren't available.
  -- ============================================================================
  ```

### Schema

```sql
CREATE TABLE broker_xref (
  tevo_brokerage_id   bigint NOT NULL,
  tevo_brokerage_name text,
  sg_seller_id        text   NOT NULL,
  sg_seller_name      text,
  confidence          numeric(3,2) NOT NULL,
  match_method        text         NOT NULL,
  matched_by          text         NOT NULL DEFAULT 'auto',
  notes               text,
  meta                jsonb        NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz  NOT NULL DEFAULT now(),
  updated_at          timestamptz  NOT NULL DEFAULT now(),
  PRIMARY KEY (tevo_brokerage_id, sg_seller_id)
);

CREATE UNIQUE INDEX ON broker_xref (tevo_brokerage_id) WHERE confidence >= 0.85;
CREATE UNIQUE INDEX ON broker_xref (sg_seller_id) WHERE confidence >= 0.85;

CREATE TRIGGER broker_xref_updated_at
  BEFORE UPDATE ON broker_xref
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
```

### Population
Single SQL function that walks `listings_snapshots.brokerage_id`/`brokerage_name` and matches against SG seller fields (need to confirm SG seller-id schema once that table is identified — `seatgeek_seller_listings.seller_id` likely).

### Acceptance criteria
- [ ] Partial UNIQUE indexes allow low-confidence dupes for review but enforce uniqueness at ≥ 0.85
- [ ] At least 5 broker matches on first backfill (small list; brokerages are stable)

### Reviewer checks
- [ ] **Confirm SG seller-id source field** — needs verification against `seatgeek_seller_listings` schema before applying
- [ ] Manual override path via `entity_xref_overrides` works (`layer='broker'`)

---

## #6 — `listing_xref`

### Purpose
TEvo ticket_group ↔ SeatGeek listing match. Layer 4 from methodology. Enables cross-marketplace dedup + arbitrage detection.

### Why it's needed
- 15 "soft dups" found in SeatGeek orders on `(section, row, qty)` — each was a legitimate distinct sale (GA, multi-block, relistings)
- Naive aggregation would over-count cross-source
- Seat-array intersection is the only safe match key; broker+section/row/qty is the fallback; price is never a match key

### Schema

### Lane / suggested slot
- **Lane:** canonical
- **Filename:** `20260512180000_canonical_listing_xref.sql`
- **Header block:**
  ```sql
  -- ============================================================================
  -- Migration 20260512180000 — listing_xref (TEvo ticket_group ↔ SG listing)
  --
  -- Lane:     canonical
  -- Touches:  listing_xref (W), listings_snapshots (R), seatgeek_seller_listings (R), broker_xref (R)
  -- Pre-reqs: 20260512140000 (governance), 20260512160000 (broker_xref)
  --
  -- Layer 4 cross-source listing match. Seat-array intersection is the only
  -- safe key; broker_xref+section/row/qty is fallback; price is NEVER a key.
  -- ============================================================================
  ```

### Schema

```sql
CREATE TABLE listing_xref (
  id                    bigserial PRIMARY KEY,
  tevo_ticket_group_id  bigint NOT NULL,
  sg_listing_id         text   NOT NULL,
  captured_at_tevo      timestamptz NOT NULL,
  captured_at_sg        timestamptz NOT NULL,
  confidence            numeric(3,2) NOT NULL,
  match_method          text NOT NULL CHECK (match_method IN
                            ('seat_array_intersect','seat_array_disjoint',
                             'broker_section_row_qty','inconclusive')),
  price_spread_pct      numeric(5,2),                  -- observability only, NOT a match key
  notes                 text,
  meta                  jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON listing_xref (tevo_ticket_group_id, captured_at_tevo DESC);
CREATE INDEX ON listing_xref (sg_listing_id, captured_at_sg DESC);
CREATE INDEX ON listing_xref (match_method, confidence);

CREATE TRIGGER listing_xref_updated_at
  BEFORE UPDATE ON listing_xref
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
```

### Population
Periodic SQL function that walks paired listings (TEvo + SG) for the same event, applies the precedence chain:
1. Both have seat arrays AND intersect → match with confidence 1.0
2. Both have seat arrays AND disjoint → record as `seat_array_disjoint` (locked non-match)
3. Neither has seats AND broker_xref resolves both → match at confidence 0.85
4. Else → `inconclusive`, no row

### Acceptance criteria
- [ ] No row written with confidence < 0.70
- [ ] No UNIQUE on `(tevo_ticket_group_id, sg_listing_id)` — re-listings over time create new legitimate rows
- [ ] Auto-match never fires on `(section, row, qty)` alone — prevents the false-positive pattern

### Reviewer checks
- [ ] **Confirm SG listing seat-array field** — needs verification before applying. `seatgeek_seller_listings.seats[]` likely
- [ ] `price_spread_pct` clearly marked as observability column
- [ ] Section normalizer (#3 helper) reused

---

## #7 — `tevo_event_archive` (DEFER)

### Purpose
Frozen historical TEvo events that the cron-driven `events` table doesn't retain. Enables Layer 3 Path A retroactively across SG orders.

### Why it's needed (low urgency)
- TEvo `events` has 293 past events vs 400 SG historical orders, 0 date overlap
- Path B (#1) works around this without needing this table
- Only relevant if we want full TEvo-event-row attribution for historical SG sales

### Schema

### Lane / suggested slot (if built)
- **Lane:** audit (TEvo ingest)
- **Filename:** `20260513100000_audit_tevo_event_archive.sql`
- **Header block:**
  ```sql
  -- ============================================================================
  -- Migration 20260513100000 — tevo_event_archive (historical events retention)
  --
  -- Lane:     xref+macro (audit)
  -- Touches:  tevo_event_archive (W)
  -- Pre-reqs: TEvo /v9/events API access
  --
  -- Snapshot store for events that age out of `events` cron tracking.
  -- One-off backfill via date-range queries; daily cron archives expiring rows.
  -- ============================================================================
  ```

### Schema

```sql
CREATE TABLE tevo_event_archive (
  tevo_event_id           bigint PRIMARY KEY,
  name                    text NOT NULL,
  occurs_at               timestamptz NOT NULL,
  venue_id                bigint,
  venue_name              text,
  primary_performer_id    bigint,
  primary_performer_name  text,
  raw                     jsonb,
  source_pull             text,                         -- which backfill job populated it
  meta                    jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON tevo_event_archive (occurs_at);
CREATE INDEX ON tevo_event_archive (venue_id);
CREATE INDEX ON tevo_event_archive (primary_performer_id);

CREATE TRIGGER tevo_event_archive_updated_at
  BEFORE UPDATE ON tevo_event_archive
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
```

### Population
One-off backfill via `/v9/events?occurs_at.gte=...&occurs_at.lte=...` for date ranges covering SG orders. Then a daily cron that archives events as they age out of `events`.

### Recommend
**Defer** until cross-source historical analytics demand justifies the API cost. Path B (#1) covers 67.8% of the same need with zero API spend.

---

## Out-of-scope (intentionally not proposed)

The audit batch surfaced these but decided against new tables:

| considered | decision | why |
|---|---|---|
| `venue_xref` | not needed | `v_canonical_venue` already unifies TEvo + SeatData + SG + ESPN |
| `performer_xref` | not needed | `v_canonical_performer` exists; `performer_external_ids` covers IDs |
| `section_normalized` | function only | the `section_norm()` SQL function is enough; no need to persist normalized values |
| `data_freshness` table | view only | `v_data_freshness` view querying max(captured_at) per source is sufficient |
| `event_history` | covered | `event_metrics` + `section_metrics` + `zone_metrics` already retain time-series |

---

## Hand-off

| owner | action |
|---|---|
| **A1** (review + apply) | Review this packet. Apply migrations 1–6 in order on a new feature branch. Defer #7. |
| **B1** (audit views) | Once #2 (`v_pg_net_queue_health`) is live, point S1's drift-report generator at it. |
| **C1** (data) | Available to clarify any spec item. The Path B match accuracy in particular can be re-tested if A1 wants higher than 67.8% before greenlight — adding `norm()` + pg_trgm should push it past 90% venue. |
