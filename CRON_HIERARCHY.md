# CRON_HIERARCHY.md

> **Doc version:** v1.0.0 · baseline 2026-05-28 (A1). Section-level version + bot-ref convention → [`README.md`](README.md) *Doc-writing rules*.

**Tiered cron-scheduling policy for Terminal-2. Maximize data freshness within bounded concurrency, with explicit headroom for future bot lanes (B2-B4).**

Operator directive 2026-05-14: "create a cron/data hierarchy so we can maximize data freshness without killing out available resources and allow for future projects like b1-4 to use resources."

---

## 1. Resource constraints (hard limits)

- `cron.max_running_jobs = 32` (Supabase default; not raisable without superuser support ticket)
- Total active jobs (as of 2026-05-14): **74** (was 72 pre-Vivid; +2 for vivid_orders_queue/process)
- `cron.use_background_workers = off` → each cron job uses a regular Postgres backend; competes with app traffic for `max_connections = 60`
- Each backend on a long-running job (`>2 min`) blocks one of the 32 slots until it completes
- pg_cron "job startup timeout" fires when all 32 slots are exhausted at a tick

**Conclusion**: peak concurrent crons must stay **≤ 20** so 12 worker slots remain for future bot lanes + manual ops + safety margin.

---

## 2. Tier definitions

| Tier | Name | Cadence | Max jobs | Use when |
|---|---|---|---|---|
| **T0** | Storefront-critical | every 10 min | **4** | Matview refreshes that back live UI (latest_event_metrics, dashboard); silent failure breaks consumer surface |
| **T1** | Near-live ingest | every 10-20 min | **10** | Time-sensitive data pulls (current-day listings, gameday scoreboards) |
| **T2** | Standard ingest | every 30 min | **30** (staggered) | Most queue/process pairs; orders, listings, wiki, geocode, weather, alerts |
| **T3** | Daily ops | once/day, hours 03-06 UTC | **20** | Sweeps, catchup, daily backfills, low-traffic window |
| **T4** | Weekly | once/week, Sunday morning | **10** | Tournament pulls, climatology, low-frequency seeds |

### Worst-case concurrency at any minute boundary

- T0: 4 jobs × `*/10` cadence → in any minute, at most ⌈4/10⌉ = 1 fires (if minute-offsets are spread)
- T1: 10 jobs × `*/15` cadence → at most ⌈10/15⌉ = 1 fires per minute (spread offsets)
- T2: 30 jobs × `*/30` cadence → 1 fires per minute (spread 0-29)
- T3: 20 jobs daily in a 240-min window (03:00-06:59) → 1 fires per minute peak
- T4: 10 jobs in 60-min Sunday window → 1 fires per minute peak

**Peak concurrent crons across all tiers at any single minute**: ≤ ~5 (T0 + T1 + T2 + maybe one T3) + tail of long-running jobs. **Well under 20.** Headroom: 12+ worker slots for future bots.

---

## 3. Stagger rules

Within each tier, minute offsets are spread so no two jobs land on the exact same minute mark.

- **T0** (4 jobs, `*/10`): offsets `2, 4, 6, 8` (avoiding `0` which is the busiest mark)
- **T1** (10 jobs, `*/15`): offsets `1, 3, 5, 7, 9, 11, 13, 14` — fill the 15-minute window
- **T2** (30 jobs, `*/30`): offsets `0-29` — one job per minute boundary within the 30-min window
- **T3** (20 jobs, daily): one job per minute in 03:00, 03:10, 03:20, ... 05:50 UTC
- **T4** (10 jobs, weekly): Sunday 04:00, 04:05, 04:10, ... 04:45 UTC

---

## 4. Tier assignments — current 74 jobs

### T0 (4 max) — storefront-critical
| jobid | name | new cadence |
|---|---|---|
| 91 | `dashboard_writes_24h_refresh_60s` | `8 * * * *` (hourly at :08 — was already de-escalated to */15 by IO-diet; further demote to hourly since dashboard isn't on the storefront critical path) |
| 124 | `latest_event_metrics_refresh_5min` | `2-59/10 * * * *` (every 10 min at :02-style offset, was the *3-58/5* slot already) |
| — | (reserved) | for future cache/matview refresh |
| — | (reserved) | |

### T1 (10 max) — near-live ingest
| jobid | name | new cadence |
|---|---|---|
| 53 | `sg_listings_0-24h` | `*/20 * * * *` (keep) |
| 108 | `collect-listings-0-24h` | `1-59/20 * * * *` (offset 1 to avoid SG pile-up) |
| 58 | `sg_listings_process_5min` | `3-59/15 * * * *` (drain queue every 15 min, was */5 = excessive) |
| 128 | `espn-gameday-10min` | `*/10 * * * *` (keep) |
| 129 | `espn-roster-10min` | `5-59/10 * * * *` (keep) |
| 100 | `espn_scoreboard_process_5min` | `7-59/15 * * * *` |
| 71 | `orphan_event_backfill_queue_15min` | `*/15 * * * *` |
| 72 | `orphan_event_backfill_process_15min` | `5-59/15 * * * *` |
| 92 | `auto_ack_stale_alerts_30min` | `9 * * * *` (demote to hourly — low urgency) |
| 74 | `compute_alerts_tick_15min` | `11-59/15 * * * *` |

### T2 (30 max) — standard ingest @ */30, staggered offsets
| jobid | name | offset |
|---|---|---|
| 61 | `evo_orders_queue_30min` | `0,30` |
| 62 | `evo_orders_process_30min` | `5,35` |
| 63 | `sg_seller_orders_queue_30min` | `2,32` |
| 64 | `sg_seller_listings_queue_30min` | `4,34` |
| 65 | `sg_seller_process_30min` | `7,37` |
| 68 | `cross_source_match_tick_30min` | `9,39` |
| 120 | `match_listings_to_sg_30min` | `11,41` |
| 126 | `tickpick_orders_queue_30min` | `13,43` |
| 127 | `tickpick_orders_process_30min` | `15,45` |
| 130 | `vivid_orders_queue_30min` | `16,46` (queue + 10-min gap to process; collides only with hourly sweep_duplicate_listings :16) |
| 131 | `vivid_orders_process_30min` | `26,56` (collides only with hourly refresh-chat-corpus :26) |
| 43 | `performer_wiki_queue_searches_5min` | `17,47` |
| 44 | `performer_wiki_process_searches_5min` | `19,49` |
| 45 | `performer_wiki_process_summaries_5min` | `21,51` |
| 46 | `venue_geocode_queue_5min` | `23,53` |
| 47 | `venue_geocode_process_5min` | `25,55` |
| 48 | `weather_forecast_queue_30min` | `27,57` |
| 49 | `weather_forecast_process_30min` | `29,59` |
| 93 | `nws_alerts_queue_30min` | `1,31` |
| 94 | `nws_alerts_process_aligned` | `3,33` |
| 104 | `fred_process_5min` | `6,36` (was */30 already; rename suffix is misleading) |
| 105 | `backfill-event-configurations-5min` | `8,38` |
| 106 | `crawl-venues-and-performers-3min` | `10,40` |
| 107 | `crawl-espn-team-assets-3min` | `12,42` |
| 101 | `match_events_to_espn_10min` | `14,44` |
| 117 | `sweep_duplicate_listings_hourly` | `16` (hourly is enough; was every 6 hours) |
| 118 | `sweep_terminal_event_listings_hourly` | `18` |
| 114 | `sweep_expired_pg_net_pending_hourly` | `20` |
| 70 | `event_competitors_refresh_hourly` | `22 * * * *` (hourly) |
| 20 | `sweep_tevo_ticket_groups_cache` | `24 * * * *` (hourly; was every 4 hours) |
| 21 | `refresh-chat-corpus` | `26 * * * *` (hourly) |
| 29 | `refresh-chat-term-freq-split-hourly` | `28 * * * *` (hourly) |

### T3 (20 max) — daily 03:00-05:59 UTC
| jobid | name | cadence |
|---|---|---|
| 6 | `sweep-old-listings` | `0 3 * * *` (keep) |
| 18 | `sweep-bot-messages` | `5 3 * * *` |
| 27 | `run-daily-chat-audit` | `10 3 * * *` |
| 34 | `ensure-watchlist-coverage-daily` | `15 3 * * *` |
| 36 | `midnight-catchup-sweep` | `20 3 * * *` |
| 69 | `wiki_pending_sweep_daily` | `25 3 * * *` |
| 73 | `orphan_backfill_sweep_daily` | `30 3 * * *` |
| 84 | `nws_points_queue_daily` | `35 3 * * *` |
| 95 | `nws_points_process_after_queue` | `40 3 * * *` |
| 90 | `match_tournaments_daily` | `45 3 * * *` |
| 102 | `sweep_inactive_event_states_daily` | `50 3 * * *` |
| 103 | `fred_queue_daily` | `55 3 * * *` |
| 99 | `espn_scoreboard_queue_4h` | `0 4 * * *` (daily is enough; was every 6h) |
| 55 | `sg_listings_7-30d` | `15 4 * * *` |
| 56 | `sg_listings_30-60d` | `30 4 * * *` |
| 57 | `sg_listings_60d+` | `45 4 * * *` |
| 110 | `collect-listings-7-30d` | `20 4 * * *` |
| 111 | `collect-listings-30-60d` | `35 4 * * *` |
| 112 | `collect-listings-60d+` | `50 4 * * *` |
| 113 | `espn-team-daily` | `0 5 * * *` (keep) |
| 54 | `sg_listings_1-7d` | `15 5 * * *` |
| 109 | `collect-listings-1-7d` | `30 5 * * *` |

### T4 (10 max) — weekly Sunday 04:00-04:59 UTC
| jobid | name | cadence |
|---|---|---|
| 50 | `weather_climatology_weekly` | `0 4 * * 0` (keep) |
| 80 | `tournament_search_pending_sweep_weekly` | `10 4 * * 0` |
| 81 | `tournament_pull_queue_weekly` | `20 4 * * 0` |
| 82 | `tournament_pull_process_weekly` | `30 4 * * 0` |
| 83 | `venue_pull_queue_weekly` | `40 4 * * 0` |
| 88 | `espn_tournament_queue_weekly` | `0 5 * * 0` |
| 96 | `espn_tournament_process_after_queue` | `10 5 * * 0` |
| 97 | `venue_pull_process_weekly` | `20 5 * * 0` |

### Special — kept paused
| jobid | name | reason |
|---|---|---|
| 38 | `master-cascade-2min` | Operator decision pending (row 65 advisor) — 15.5% of DB time historically |
| 98 | `zone-backfill-isolated-10min` | Operator decision pending (row 65) — 14.3% of DB time per call |

---

## 5. Future-bot reservation pattern

When a new bot lane (B2/B3/B4) is added:

1. **Default tier**: T2 (every 30 min, staggered).
2. **Slot acquisition**: pick the next free minute offset within the chosen tier (query `SELECT schedule FROM cron.job` and pick a minute not already used).
3. **If the new bot needs T0/T1**: must demote an existing job in that tier to T2 to keep the cap.
4. **Worker budget check before resume**: every new bot must run `bash scripts/check_cron_budget.sh` (forthcoming) and confirm `peak_concurrent_jobs ≤ 20`.

---

## 6. Maintenance

- A1 owns this doc + the schedule migration.
- After any cron `cron.schedule()` / `cron.alter_job()`, the operator should re-verify against this doc.
- If `pg_cron.log` shows recurring "job startup timeout" errors, that's the canary that we've blown past the 20-concurrent budget.

Owner: A1.
