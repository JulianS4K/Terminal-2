# Storage audit — 2026-05-08

## Top tables by size

| table | total | heap | index | rows |
|---|---|---|---|---|
| **listings_snapshots** | **1,876 MB** | 1,287 MB | 589 MB | **7.18 M** |
| **section_metrics** | **353 MB** | 176 MB | 177 MB | **1.83 M** |
| event_metrics | 7.4 MB | 5.3 MB | 2.1 MB | 21,985 |
| espn_injuries_snapshots | 1.9 MB | 1.5 MB | 416 KB | 1,972 |
| zone_metrics | 1.1 MB | 696 KB | 352 KB | 3,061 |
| (everything else) | < 1 MB each | | | |

`listings_snapshots` + `section_metrics` together = **2.18 GB / ~99% of total DB.**

## Per-event distribution (listings_snapshots)

| metric | value |
|---|---|
| events tracked | 458 |
| total rows | 7,578,398 |
| avg rows/event | 16,547 |
| median rows/event | 2,982 |
| **max rows/event** | **178,478** |

The collect-listings cron inserts a row per ticket-group per run. With 0–24h events polled every 20 minutes (72 runs/day) and a popular event having ~500 ticket groups, we burn 36k rows/day per event. The current heap is on track to hit Supabase's tier limit fast.

## Where the waste lives

**Row-level duplicates from one snapshot to the next.** TEvo's `/v9/ticket_groups` doesn't change every 20 min for most listings — sections, rows, qty, and prices are stable for hours at a time. We're storing the exact same row repeatedly with only a different `captured_at`.

Quick spot-check on Patriots @ Gillette (event 71xx): consecutive snapshots 20 min apart show >90% identical (section,row,qty,retail_price,is_owned) tuples. The actual deltas — price moves, sells, adds — are <10% per cycle.

## Proposals (impact-ranked)

### 1. **Change-only listings ingest** — biggest win, 80–95% reduction estimate

Same pattern as `espn-collect` v3 (migration 17). For each TEvo `ticket_group_id`:

- Compute `content_hash = md5(section || '|' || row || '|' || quantity || '|' || retail_price || '|' || wholesale_price || '|' || is_owned)`
- On insert, check the latest row for that ticket_group_id
  - If hash matches → `UPDATE last_seen_at = now()` only
  - If hash differs → `INSERT` new row with new captured_at + `is_change = true`
  - If ticket_group_id disappeared (sold/removed) → mark prior row `removed_at = now()`

This makes `listings_snapshots` a true change-log instead of a re-insert log. Storage growth shifts from O(events × ticket_groups × cron_runs) to O(events × ticket_groups × actual_state_changes).

**Migration cost:** 1 fn refactor (collect-listings) + 1 schema migration to add `content_hash`, `last_seen_at`, `is_change`, `removed_at`. Backfill existing rows with computed hashes + mark them all `is_change = true` (baseline). cowork's lane (collect-listings is theirs).

**Risk:** If we're consuming `captured_at` somewhere expecting a row at every cron tick, that'll break. Need a `latest_listings_snapshot` view that handles the new semantics. Most consumers already only read `latest_*` views — should be transparent.

### 2. **Native partitioning by month**

`PARTITION BY RANGE (captured_at)` with monthly partitions. Drop old months in O(1) via `DETACH PARTITION`. Indexes get smaller per partition (currently 589 MB single index — would be ~50 MB per month).

**Migration cost:** Postgres-native, ~30 min downtime to convert existing table. Or do online via dump+restore to a new partitioned table, swap with `ALTER TABLE RENAME`.

**Risk:** Cross-partition queries (e.g. trailing-90d analysis) need a careful WHERE on `captured_at`. PostgreSQL handles this transparently with constraint exclusion when the planner sees the timestamp filter.

### 3. **Aggregate + archive snapshots > 30 days old**

We don't need 20-min granularity for 90-day-old data — for chart x-axis at that zoom, daily resolution is fine. Aggregate into a `listings_snapshots_daily` table (one row per event×section×day with min/median/max prices, sum quantity, owned_count) and drop the raw rows.

This combined with #1 gets us long-term ~50 MB/month growth instead of 500 MB/month.

### 4. **Drop redundant indexes**

589 MB of indexes on listings_snapshots is suspicious — that's almost half the heap. Likely some indexes were added speculatively and never used. Run `pg_stat_user_indexes` and drop anything with `idx_scan = 0` after a week of representative load.

### 5. **`section_metrics`** — same change-only treatment

353 MB, 1.83 M rows. The metric values are aggregations of listings_snapshots, so they shift in tandem. After #1 lands, section_metrics will naturally shrink because the source has fewer rows. Or: regenerate section_metrics on-demand from a partitioned listings_snapshots view instead of materializing every snapshot tick.

## Chat-side audit

| table | rows | size |
|---|---|---|
| bot_messages | 108 | 232 KB |
| chat_corpus | 57 | 224 KB |
| chat_term_freq_in / out | (just seeded) | 208 KB |
| chat_aliases | 917 | 368 KB |
| chat_audit_findings | (variable) | — |

Chat-side storage is fine — under 2 MB total. Cowork's recent corpus mining v2 (mig 010000) split incoming/outgoing terms cleanly. The `tokenize_chat_text` + `chat_stopwords` pipeline is efficient. No action needed.

The only thing worth watching: `chat_audit_findings` will grow as the daily audit cron runs. Currently small (108 bot_messages so far), but if the chat fn handles 1000s of messages/day, audit findings could grow to MBs/month. Add an archive policy (`audited_at < now() - 90 days` → drop) when it gets above 50 MB.

## What I'd do next

1. **Land #1 (change-only listings)** — this is the only item that prevents the database from blowing past tier limits in the next month.
2. **Add #2 (partitioning)** as a follow-up so we can prune by month painlessly.
3. **Defer #3, #4, #5** — they're cleanup, not required.

Both #1 and #2 are squarely cowork's lane (collect-listings + listings_snapshots schema). Leaving WAIT note in AGENTS.md asking them to pick this up.

— code (auditor), 2026-05-08
