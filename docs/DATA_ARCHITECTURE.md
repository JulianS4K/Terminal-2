# Data Architecture — Terminal-2

**For other bots, subordinates, and humans new to this codebase.** Read this before touching the data layer. Updated 2026-05-14 after the universal AQ matcher session.

---

## 1. The canonical key system

Every order/sale/listing row in Terminal-2 carries (or should carry) up to three short text IDs. These are the joinable handles for cross-source analytics:

| Key | Type | What it means |
|---|---|---|
| `aq_short_event_id` | text, 7 chars usually (e.g. `Y5DDQDV`) or `SYS-<md5_10>` | Canonical event ID. Curated rows from AQ xlsx import; `SYS-` prefix for synthetic/auto-generated when AQ doesn't carry the event. Every order/sale/listing should resolve to one of these via the matcher. |
| `venue_short_id` | text, 7 chars (`NNY4A2B`) | Canonical venue ID. Deterministic hash of `name+city+state` so same venue across sources collapses. |
| `performer_short_id` | text, 7 chars (`DOA3F2B`) | Canonical performer ID. Deterministic hash of `name`. AQ Performer UUID still TBD. |

**Provenance**: `aq_event_map.aq_source` ∈ {`aq_curated` (5,921 rows from xlsx), `aq_event_map_seed` (bulk from sg_canonical), `system_seed` (auto-created `SYS-` rows when matcher fell through)}.

---

## 2. Table relationship map (high level)

```
                        ┌─────────────────────┐
                        │   aq_event_map      │ ← canonical events, FK target for everything
                        │ aq_short_event_id PK│
                        │ vivid/sg/sh/tm_id   │ ← source-specific IDs (some NULL)
                        │ venue_short_id  FK ─┼──→ aq_venue_map
                        │ performer_short_id  ├──→ aq_performer_map
                        └─────────▲───────────┘
                                  │ (FK aq_short_event_id)
        ┌─────────────────────┬───┴────┬────────────────────────┬─────────────────────┐
        │                     │        │                        │                     │
   vivid_orders        tickpick_orders  seatgeek_orders   seatgeek_sales_snapshots  evo_order_items
        │                     │        │                        │                     │
   ┌────┴──┐              ┌───┴──┐    ┌┴───────┐         ┌──────┴──┐            ┌─────┴────┐
   │ aq_id │              │aq_id │    │ aq_id  │         │ aq_id   │            │ aq_id    │
   │ venue │              │venue │    │ venue  │         │ venue   │            │ venue    │
   │ perf  │              │perf  │    │        │         │         │            │ perf     │
   └───────┘              └──────┘    └────────┘         └─────────┘            └──────────┘

   listings_snapshots ◄── 8.16M rows (TEvo broker network)
   ├ aq_short_event_id            ← linked via match_unmatched_listings_chunked
   ├ venue_short_id
   ├ performer_short_id
   ├ is_owned (S4K=true)
   ├ retail_price, prev_retail_price ← Pattern A delta tracking
   └ quantity, prev_quantity

   seatgeek_listings_snapshots ◄── 144k rows (SG broker)
   ├ aq_short_event_id
   ├ venue_short_id, performer_short_id
   ├ broadcast_price, prev_broadcast_price
   └ quantity, prev_quantity
```

### Cross-source bridge points

| From | To | Via |
|---|---|---|
| Vivid order | AQ event | `vivid_event_id` → `aq_event_map.vivid_event_id` (direct) OR matcher Tier 2-4 |
| TickPick order | AQ event | matcher tiers 2-4 (TickPick has no source event_id) + tier 1.5 via `aq_venue_map.tickpick_venue_id` |
| SG broker sale | AQ event | `sg_event_id` → `aq_event_map.sg_event_id` (Tier 1) OR `sg_canonical.sg_venue_id` → `aq_venue_map.sg_venue_id` (Tier 1.5) |
| Evo order item | AQ event | matcher (no direct ID; uses `aq_venue_map.tevo_venue_id`) |
| TEvo listing | AQ event | `event_id` → `events.id` → matcher via name+venue+date+venue_id |
| TEvo event | SG canonical | `sg_events_canonical.tevo_event_id` (157 mapped) |
| TEvo event | AQ | `aq_event_map` row matches venue+date OR via `sg_event_id` bridge |

---

## 3. The matcher cascade (`public.match_to_aq_event_id`)

Given any source's event metadata, returns `(aq_short_event_id, confidence, match_method)`:

```
Tier 1   tier1_direct_id        1.00  source event_id ↔ aq_event_map (vivid/sg/sh/tm)
Tier 1.5 tier1_5_venue_id_date  0.93  source venue_id ↔ aq_venue_map → venue_short_id + date ±6h
Tier 2   tier2_venue_exact      0.95  lower(trim(venue)) exact + date ±6h
Tier 3   tier3_venue_fuzzy      0.80  pg_trgm similarity ≥0.7 + date ±6h
Tier 4   tier4_coord_date       0.85  haversine ≤1km + date ±6h
∞                                 — falls back to create_system_aq_event() → SYS-<md5>
```

**Use it from any new ingest function** — never write a new one-tier matcher. If a source needs a new field (e.g. an internal event_id that maps directly), add a tier; don't fork the function.

---

## 4. Cron architecture (post-2026-05-14)

### Cron policy gate (`public.cron_policy` + `cron_should_fire(jobname)`)

Every retrofitted cron wraps its body in:
```sql
DO $body$ BEGIN
  IF NOT public.cron_should_fire('<jobname>') THEN RETURN; END IF;
  <original work>;
END $body$;
```

The gate evaluates 4 conservation stages:
1. **Disabled flag** (kill switch)
2. **Daily budget** (`daily_max_fires`)
3. **Min-interval** by peak vs off-peak (`peak_hours_et`)
4. **Work-presence** (`work_check_sql` — fail-OPEN on error)

Decision log at `cron_gate_decisions` (decision ∈ `fire | skip_offpeak | skip_interval | skip_no_work | skip_budget | disabled`).

### Stock-broker-tier polling (SG broker only)

| Tier | When | Interval | Daily cap |
|---|---|---|---|
| HOT | owned + <6h to event | 60s | 360 |
| WARM | owned + <24h | 5min | 96 |
| COOL | owned + <7d | 30min | 24 |
| COLD | owned + <30d | 4h | 6 |
| OBSERVE | upcoming, not owned | 12h | 2 |
| SKIP | far future / no signal | n/a | 0 |

`sg_classify_events()` recomputes tier per event every 5 min. `sg_priority_poll_tick(p_max_polls)` fires due polls.

### Currently-paused cron snapshot

`public.cron_pause_state_20260514` (71 jobs from 2026-05-13 pause). Operator graduates via `SELECT cron_resume_with_gate('<jobname>')`. The wrapped body uses the schedule from this snapshot table — so to change a cron's schedule, UPDATE the snapshot's `schedule` column BEFORE calling resume.

---

## 5. Off-peak window (operator directive)

**All heavy backdata processes run 04:00-11:00 UTC = 12:00-7:00 AM ET.** Current scheduled overnight crons:

| Cron | Schedule UTC | Schedule ET | Purpose |
|---|---|---|---|
| `listings_aq_backfill_overnight` | 04:02-04:14 (every min) | 12:02-12:14 AM | Backfill aq_short_event_id on 8.16M listings rows. Self-unschedules. |
| `listings_deltas_backfill_overnight` | 04:30-04:44 (every min) | 12:30-12:44 AM | Backfill prev_price/prev_qty (Pattern A). Self-unschedules. |
| `cron_gate_decisions_prune_daily` | 09:01 (1/day) | 5:01 AM | Drop skip decisions >30d old |
| `match_unmatched_orders_sweep_hourly` | 22 * * * * | hourly | Match new orders/sales; tier policy pins to 5-7 AM ET window |
| `release_health_check_hourly` | (TBD when resumed) | hourly | Always-on |

The 04:02-04:14 + 04:30-04:44 slots avoid existing 04:00 / 04:15 / 04:20 / 04:30 / 04:35 / 04:45 / 04:50 crons.

---

## 6. Key views (analytics surfaces)

| View | What | Filter |
|---|---|---|
| `unified_orders` | All 5 sales sources unioned with canonical IDs | WHERE source_key + aq_short_event_id |
| `unified_orders_by_event` | Per-event sales rollup | GROUP BY aq_short_event_id |
| `unified_listings` | All 4 listings sources unioned | Where filterable by source/event |
| `v_aq_match_quality` | Per-table match coverage + synthetic % | Monitor pipeline health |
| `v_market_listings_by_event` | Per (event, hour, source) price/qty stats | Market tracking charts |

**Adding a new view?** Always `ALTER VIEW ... SET (security_invoker = true);` after `CREATE OR REPLACE` — otherwise it reverts to SECURITY DEFINER and `release_health_check.views.security_definer_views` fires.

---

## 7. For new bots picking up the codebase

### How to add a new sales source (10 min)

1. Build the ingest function — calls upstream API, INSERTs into a new `*_orders` or `*_sales_snapshots` table
2. Add `aq_short_event_id text`, `venue_short_id text`, `performer_short_id text` columns + FKs to `aq_event_map` / `aq_venue_map` / `aq_performer_map`
3. In the ingest function: `SELECT m.aq_short_event_id FROM match_to_aq_event_id('<source>', ...) m` — set the canonical ID inline
4. Add a branch to `match_unmatched_orders_sweep()` as a catch-up
5. Add the source to `unified_orders` view

### How to add a new listings source

Same pattern as orders, plus:
- Set up the per-window (or tiered) polling cron + policy row
- Add to `unified_listings` view
- Decide change-only (use content_hash dedupe pattern) or full-snapshot

### How to add a new analytics dimension

1. Add column to `aq_event_map` (or a parallel xref table)
2. Use the matcher to backfill — never wire it into the ingest one-off
3. Propagate to order/sale/listing tables via the sweep (it auto-pulls from `aq_event_map`)

### How to debug a "no AQ match" complaint

```sql
-- 1. Check the row state
SELECT aq_short_event_id, event_name, venue_name, event_date FROM <table> WHERE id = X;

-- 2. Run matcher manually with the same inputs
SELECT * FROM public.match_to_aq_event_id('<source>', <source_event_id>, <name>, <venue>, <date>);

-- 3. If still empty, check matcher's tier-by-tier reasoning
--    (no direct ID match? try fuzzy threshold. no coord? venue not geocoded.)
```

---

## 8. What NOT to do

- **Don't write a new matching function per source.** Use `match_to_aq_event_id`.
- **Don't `CREATE OR REPLACE VIEW` without setting `security_invoker = true` after.** Reverts to definer; trips the health check.
- **Don't backfill 8.16M-row tables in one statement.** Use the chunked pattern (event_id LOOP + pg_sleep + per-event UPDATE).
- **Don't poll upstream APIs from inside cron without a work-check.** Adds load with no benefit.
- **Don't bypass `cron_resume_with_gate` to re-enable a paused cron.** Schedule the work through the gate so the policy stays the source of truth.
- **Don't add `aq_short_event_id` without an FK.** The FK to `aq_event_map(aq_short_event_id)` is what prevents drift.

---

## 9. Open follow-ups (priority)

1. Build per-event ESPN summary ingest (`espn_event_snapshots` for scores/odds/win-prob)
2. AQ Performer UUID — re-extract operator xlsx with cols 7/35/44
3. Auto-reconcile `SYS-` IDs to real AQ rows when operator adds curated entries later
4. SG event-discovery for owned events NOT yet in `sg_events_canonical` (search-then-upsert pipeline)

Owner: A1 → handed off via `bot_chat` + `docs/SESSION_2026-05-14_HANDOFF.md`.
