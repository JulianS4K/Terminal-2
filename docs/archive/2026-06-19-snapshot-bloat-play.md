# Snapshot retention → **data-analysis-speed** play + SG-cron pause (2026-06-19)

> **Non-canonical dated artifact** (per `PROJECT_BIBLE §1` rule 10 / docs rules). Operator-directed. **Reframe (operator 2026-06-19): the primary concern is data-analysis SPEED, not disk cost** — bloat matters only as it slows scans. Records (a) the SG-cron pause, (b) live size/index data, (c) the speed-focused fix. Actionable rows → `KANBAN.md` (`A1-OPS-3`, `A1-OPS-16..21`). **The speed solution is §"Speed solution" below; the storage framing under it is secondary.**

## SG crons PAUSED (2026-06-19, operator-directed, reversible)

Paused the **6 SG-token-consuming** crons (`cron.alter_job(active:=false)` — preserves schedule) to stop the 429 burn + halt SG snapshot growth while the fix lands:

| jobid | jobname | upstream call |
|---|---|---|
| 355 | `sg_listings_poll_owned_1min` | broker `/listings` |
| 248 | `sg_sales_poll_5min` | broker `/sales` |
| 64 | `sg_seller_listings_queue_30min` | seller `/listings` |
| 63 | `sg_seller_orders_queue_30min` | seller `/orders` |
| 381 | `sg_seller_sync_map_15min` | seller book sync |
| 407 | `sg_wc_listings_catchup` | WC force-track `/listings` |

**Kept running** (deliberately): no-upstream processors (`sg_priority_*_process`, metrics refreshes, classify, maps — drain remaining queues, no token), the retention **sweep** `sweep-old-sg-listings` (reduces bloat), the **429 monitor** `sg_broker_429_health_check_15min` (watch recovery), `sg-match-map-tick` (TicketsData credits, not SG token), and **`collect-listings-*`** (TEvo/EVO firehose — not SG, not the 429 source).

**Resume:** `SELECT cron.alter_job(job_id := jobid, active := true) FROM cron.job WHERE jobid IN (355,248,64,63,381,407);`

## Live bloat numbers (2026-06-19 — bible figures were badly stale)

| Table | Size | Live rows | Dead rows | Dead:live |
|---|---|---|---|---|
| `listings_snapshots` (TEvo) | **48 GB** | 123 M | 6.2 M | 0.05 |
| `seatgeek_listings_snapshots` | **13 GB** | 16 M | 92 k | 0.01 |
| `seatgeek_sales_snapshots` | **7.5 GB** | 12.6 M | 34 k | 0.00 |
| `axs_seat_snapshots` | 726 MB | 927 k | 120 k | 0.13 |
| `espn_injuries_snapshots` | 631 MB | **36.7 k** | **593 k** | **16.1** 🚩 |

~76 GB total. (Prior bible figures: `listings_snapshots` 3.6 GB, SG listings 3.2 GB, SG sales 1.18 GB, espn 175 MB — all ~10–13× understated. Refresh `RESOURCES_BIBLE §1`.)

## The fix play — shrink bloat without losing data quality

**Data-quality guarantee:** the *durable analytics layer* is separate from the raw firehoses. `event_listing_snapshot_daily` (3×/day medians, **indefinite**), `event_metrics` (120 d), `seatgeek_event_metrics`, `latest_event_metrics` carry the history the terminal/charts read. Raw firehoses are only needed for (a) latest state ("is this listing live now") and (b) intraday/short-window charts (~7–30 d). So trimming raw beyond ~30 d is **safe** — long-term history lives in the daily layer. **Every trim step is gated on:** no SECDEF RPC/view reads the raw table beyond the new window (grep `pg_proc` + view defs for the table over a date range).

Sequenced safest → structural:

1. **Reclaim dead space now (lossless):** `pg_repack` (online, no ACCESS EXCLUSIVE) — or VACUUM FULL in a quiet window — on `espn_injuries_snapshots` (16:1 dead → ~590 MB reclaimed) + `axs_seat_snapshots`. Dead tuples are already-deleted rows → zero data-quality impact. Also fix the injuries collector write pattern (upsert-in-place / only-on-change) so it stops regenerating dead tuples.
2. **Let the paused pollers drain (free, now):** with the 6 SG consumers off, the existing sweeps (`sweep-old-sg-listings` 30 d, `sweep_old_listings` 15 d) shrink the SG tables. Verify deletes via `cron.job_run_details`.
3. **Wave 3 — change-detection write-gate (root cause, biggest lever):** INSERT a snapshot only when the listing actually changed (`content_hash` / price+qty) vs its last. Guardrail: unchanged rows still bump `last_seen_at` (latest row or sidecar) so "still live?" stays answerable; validate with a head-to-head live-listing count (gate vs raw) on a sample of events before rollout.
4. **Wave 4 — range-partition by `captured_at`:** retention becomes `DROP PARTITION` (instant, no dead-tuple churn, no VACUUM). Transparent to queries → data quality preserved. One-time migration: dual-write/backfill, verify counts, swap, keep old table until verified.
5. **Wave 2 — sales dedup rollup:** `seatgeek_sales_snapshots` is 11–23× overcounted (UNIQUE on `pulled_at` re-inserts each sale every poll). Deduped rollup (one row per `sg_sale_id`, keep-latest) + shorter raw TTL; queries already `DISTINCT ON (sg_sale_id)`.

**Apply order is operator/A1-gated** (prod DB). Step 1 (pg_repack `espn_injuries_snapshots`) is the immediate zero-risk win to green-light first.

---

## Speed solution (PRIMARY — operator reframe 2026-06-19)

**Diagnosis (live prod):** analysis is slow because cross-event / wide-window queries scan the raw firehose (`listings_snapshots` 48 GB / 123 M rows, **22 GB indexes = 46%**) instead of the pre-aggregated layer. `min(captured_at)` over the raw table **timed out at 25 s**. Three speed-killers:

1. **Index bloat from delete churn.** `listings_snapshots`: **415 M deletes + 98 M updates** → 22 GB of bloated btrees. Retention `DELETE`s rows but never shrinks indexes → more pages/scan → slower every query, and it re-bloats continuously.
2. **Dead / low-value indexes** (cumulative `idx_scan`) that slow *ingest* + waste buffer cache: `seatgeek_sales_snapshots_tevo_event_id_idx` (109 MB, **0**), `sg_listings_price_change_idx` (9 MB, **0**), `listings_snapshots_price_change_idx` (22 MB, 7), `listings_snapshots_prev_retail_null_idx` (1.2 GB, 116 — partial for the *disabled* aq backfill), `sg_listings_snapshots_prev_bc_null_idx` (101 MB, 179 — disabled backfill), `idx_sg_listings_owned` (8 MB, 9). Candidates to verify-then-drop: `idx_sg_listings_sglid` (703 MB, 65), `sg_listings_tevo_sglid_captured_idx` (502 MB, 158).
3. **No partition pruning** — all 5 firehoses are plain tables.

**Pre-agg layer is ~200× smaller** (route analysis here, never raw): `latest_event_metrics` matview **20 MB / 8.6 k** · `event_listing_snapshot_daily` 97 MB · `event_metrics` + `seatgeek_event_metrics` 251 MB.

**4 pillars (speed-gain ÷ effort):**
1. **Route analysis to the pre-agg layer** — already the SOP (`PROJECT_BIBLE §3`); enforce it + gap-fill any dimension analysts reach to raw for. No migration.
2. **Drop dead/low-value indexes** — faster INSERTs (less write-amp → less bloat) + more buffer cache for hot indexes (`event_tgid_captured` 20.9 M scans, `sg_listings_dedup` 66 M). One migration (file authored: `..._drop_dead_firehose_indexes.sql`).
3. **`REINDEX CONCURRENTLY` the bloated hot indexes** (8.6 GB PK + 8 GB workhorse on listings, ~30–50% bloat) — online, fewer pages/scan.
4. **Partition firehoses by `captured_at`** — partition pruning for time-window analysis; retention becomes `DROP PARTITION` (no churn → indexes never re-bloat → speed *stays*). The permanent fix.

**espn_injuries_snapshots:** 7.18 M updates on 36 k rows → 16:1 dead → bloated hot index (`athlete_team`, 7.2 M scans). Fix: `pg_repack` + per-table `autovacuum_vacuum_scale_factor=0.02`.

**Sequence:** now = pillars 1–3 + espn repack (low-risk, big win); structural = pillar 4. All prod DDL via **ship-a-migration** (operator-gated apply). Pillar-2 migration file is authored (NOT applied) for review.
