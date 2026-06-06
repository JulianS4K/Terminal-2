# CRON_HIERARCHY.md

> **Doc version:** v1.2.0 · baseline 2026-05-28 (A1); v1.1.0 2026-05-31 (A1) — §1 job-count + §4b rewritten for the per-event collector-cadence model (`collector_cadence`-driven scan per source; EVO/SG horizon bands; ~12 horizon/blindspot collectors retired, 2–3 pollers added); v1.2.0 2026-06-03 (A1) — §4b: SG `/listings` poller split into owned (`sg_listings_poll_owned_1min`, ON) / non-owned (`sg_listings_poll_nonowned_5min`, once-daily, OFF); `sg_listings_poll_2min` retired; raw listings retention 30d→15d; v1.3.0 2026-06-06 (A1) — **§4c** adds the trading-hours cadence redesign (market-timed two-format + metronome firing across SG `/listings`+`/sales`+SellerDirect + TD 5 platforms), the **peak/off-peak derivation methodology**, and the cadence/budget/firing **reference tables** (design of record, pending migrations). Section-level version + bot-ref convention → [`README.md`](README.md) *Doc-writing rules*.

**Tiered cron-scheduling policy for Terminal-2. Maximize data freshness within bounded concurrency, with explicit headroom for future bot lanes (B2-B4).**

Operator directive 2026-05-14: "create a cron/data hierarchy so we can maximize data freshness without killing out available resources and allow for future projects like b1-4 to use resources."

---

## 1. Resource constraints (hard limits)

- `cron.max_running_jobs = 32` (Supabase default; not raisable without superuser support ticket)
- Total active jobs: was **74** (2026-05-14); the **2026-05-31 collector-cadence cutover** retired ~12 horizon/blindspot collectors (the five `collect-listings-*` windows + `collect-listings-featured-10min` + the SG `sg_blindspot_poll_5min` / `sg_listings_floor_sweep` / `sg_60d_*` ×4 / `sg_broker_sales_queue_5min`) plus ~9 long-inactive jobs, and added 2–3 (`evo_listings_poll_2min`, `sg_listings_poll_2min`, + the re-added low-freq `collect-listings` discovery sweep). **2026-06-03**: `sg_listings_poll_2min` was split into `sg_listings_poll_owned_1min` (ON) + `sg_listings_poll_nonowned_5min` (OFF) — §4b. Net job count **dropped**; re-verify live via `SELECT count(*) FROM cron.job WHERE active`. See **§4b** for the per-event poller model.
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

## 4b. Listings collection — per-event poller model *(v1.2 · A1 · 2026-06-03)*

> **Forward note (2026-06-06):** the SG listings/sales + TD cadences in this section were **superseded by the trading-hours redesign in §4c** (market-timed, metronome firing) — **migrations #1–#3 applied to prod 2026-06-06**. The owned/non split below still holds; the per-event *intervals* and TD firing model are now governed by §4c. SellerDirect pagination (#4) remains pending.

**The horizon-windowed collectors are RETIRED.** Before 2026-05-31, both EVO and SG pulled listings via fixed time-window crons (`collect-listings-0-24h/1-7d/7-30d/30-60d/60d+`, the SG `sg_listings_*` `/v2` jobs, and the `sg_listings_floor_sweep` round-robin). The **collector-cadence cutover** (migs `20260531140000`–`170000`) replaces all of them with **one ≈2-min scan per source** that fires per-event based on each event's date-horizon, driven by config in **`public.collector_cadence`**.

**How it works:** each source has a single tick cron that reads `collector_cadence` (via helper `collector_band(source,scope,hours)` → `(band, required_min)`, peak-aware for ET 12-23), finds events whose per-event clock is due for their horizon band, and fires the collect call for those only. Per-event clocks live in new state tables (see RESOURCES_BIBLE §2.2).

| Job | Cadence | What it does | Status |
|---|---|---|---|
| **`evo_listings_poll_2min`** | `*/2` | `evo_listings_poll_tick(p_max)` — fires `collect-listings?event_id=X` per due event, stamps `evo_listings_poll_state.last_polled_listings_at` on fire | **ACTIVE (new 05-31)** |
| **`sg_listings_poll_owned_1min`** | `*/1` | `sg_listings_poll_tick(5,3,'owned')` — broker `/listings`, **OWNED events only** (`owned_count_last_7d>0`); tight horizon bands, rate-aware, strand-safe | **ACTIVE (split 06-03)** |
| **`sg_listings_poll_nonowned_5min`** | `*/5` | `sg_listings_poll_tick(8,3,'non')` — broker `/listings`, **NON-OWNED events**; once-daily per event (`collector_cadence` owned_kind='non' = 1440) | **OFF — wired, `cron_policy.enabled=false` (06-03); flip to resume** |
| **`sg_sales_poll_5min`** | `*/5` | retuned `sg_sales_poll_tick` (now band-driven) | **ACTIVE (re-enabled 05-31, P0 follow-up)** |
| **`collect-listings`** (discovery) | low-freq | re-added new-event discovery sweep (P0 follow-up; `evo_discover` Phase-2 in KANBAN) | **ACTIVE (re-added 05-31)** |
| `collect-listings-0-24h/1-7d/7-30d/30-60d/60d+` · `collect-listings-featured-10min` | — | EVO horizon windows + featured | **RETIRED 05-31** |
| `sg_listings_*` (53–58, `/v2`) · `sg_blindspot_poll_5min` · `sg_listings_floor_sweep` · `sg_60d_listings_morning/afternoon` · `sg_60d_sales_morning/afternoon` · `sg_broker_sales_queue_5min` | — | SG horizon / blindspot / floor-sweep / 60d / sales-queue | **RETIRED 05-31** |
| `sg_listings_poll_2min` | — | combined SG listings poller (owned+non) | **RETIRED 06-03** — split into the two owned/non pollers above |
| `sg_broker_listings_metrics_refresh_hourly` · `sg_canonical_v2_pull_refresh_30min` · `sweep-old-sg-listings` · `sg_seller_*` · `td_*` (TickPick/TM discovery + enqueue, new 05-29) | various | metrics / reconcile / sweep / seller(owned) / TD platforms | ACTIVE (unchanged) |

**Per-event cadence bands (actual API calls per event, by date-horizon):**

| Horizon | EVO (sole TEvo consumer, ≈unlimited) | SG (listings + sales) |
|---|---|---|
| ≤7d | 15 min | 1 h |
| 8-14d | 30 min peak / 60 min off-peak | 4 h |
| 15-30d | 1 h | 12 h |
| 31-60d | 4 h | 24 h |
| 61d+ | 12 h | 24 h |

**Why EVO and SG differ:** EVO is the *only* consumer of the TEvo broker API (effectively unlimited quota) → aggressive near-event cadence. SG broker is **rate-limited (~5 req / 10s window)**, so `sg_listings_poll_tick` runs `p_max=5` per tick, backs off on the live `ratelimit-remaining` header, and is strand-safe; the SG cadence clock (`sg_event_priority_state.last_fired_listings_at`) advances **only on HTTP 200** (so a 429/timeout re-tries rather than burning the slot). SG reuses `sg_event_priority_state` (gained `last_fired_listings_at`) — there is **no** `sg_listings_poll_state` and **no** `horizon_days` column.

**Owned/non split (2026-06-03):** SG *listings* cadence is now keyed on `owned_kind`. **OWNED** events (we hold inventory, `owned_count_last_7d>0`) use the tight per-horizon bands in `collector_cadence` (≤7d 45/90 min · 8-14d 150/300 min · 15-30d 600/1200 min · 31d+ 1200/1320 min) via `sg_listings_poll_owned_1min` (**ACTIVE**). **NON-OWNED** events are a flat **once-daily (1440 min)** floor via `sg_listings_poll_nonowned_5min` (**OFF for now** — `cron_policy.enabled=false`). The SG column in the table above reflects the pre-split values; SG *sales* (`sg_sales_poll_5min`) is unchanged.

**Shared-token note (unchanged):** all SG broker crons **+ a separate external prod program** draw on ONE SeatGeek token. Watch `v_sg_token_budget` + `v_sg_broker_429_health`.

---

## 4c. Trading-hours cadence redesign — market-timed, distributed firing *(v1.3 · A1 · 2026-06-06)*

> **Status: migrations #1–#4 APPLIED to prod 2026-06-06** (operator-authorized; versions `20260606191854` / `192104` / `192416` / `194100` + `get_event_sg_seller_listings_full` RPC). These supersede the §4b SG/TD cadences (now **live**). #4 = SellerDirect full-book pull + AQ map + D0 FE (operator reversed the earlier hold) — see *SellerDirect finding* below. **EVO is unchanged** (sole TEvo consumer, ≈unlimited → keep §4b bands). Scope: SG broker `/listings` (owned), SG `/sales`, TicketsData (TD) 5 platforms (SH/VD/GT/TP/TM — covered; SeatGeek incl. any TD→SG discovery stays on its native feeds, never routed through TD).

### Problem
TD's flat "≤4×/day per event" enqueue is **horizon-blind** → ~950 credits/day of demand against a **300/day cap** → exhausts ~12:24 ET, starving US afternoon/evening (the highest-activity window). SG sales fired **20-request bursts every 5 min** → concurrent token hits → 429s. Both ignored *when* the market actually trades.

### How the peak/off-peak + cadence metrics were generated *(reproducible)*
All figures below come from two read-only sample weeks (**2026-05-05→11** and **2026-05-19→25**), analyzed in **`America/New_York`** (the US resale clock). Run via MCP `execute_sql` (service_role; `SET statement_timeout`):

- **Sales timing** — `seatgeek_sales_snapshots`, **deduped by `sg_sale_id`** (mandatory — 11–23× re-insert factor, PROJECT_BIBLE §3) on `sale_at_utc`; bucket by `extract(hour FROM sale_at_utc AT TIME ZONE 'America/New_York')` and `isodow`.
- **Time-to-event** — join deduped sales → `sg_events_canonical.sg_datetime_utc`; bucket `floor((sg_datetime_utc - sale_at)/86400)` days (0–30); per-event = `count(*) / count(DISTINCT sg_event_id)`.
- **Price-change timing (cheap proxy)** — do **NOT** scan the 70M-row `seatgeek_listings_snapshots` firehose (a 2-week scan blows the MCP 60s limit). Instead detect **median moves** on the precomputed `seatgeek_event_metrics` series (~27k rows/wk): `listings_all_median IS DISTINCT FROM lag(listings_all_median) OVER (PARTITION BY sg_event_id ORDER BY captured_at)`. A median move = a real repricing event; bucket by ET hour and by days-to-event.

### Findings — market-timing reference

**Hour-of-day (ET), sales — peak/trough ≈ 19×:**

| ET window | Activity | Share |
|---|---|---|
| 1–8am (after-hours) | 340–1,000/hr (3–6am dead) | ~7% |
| 9am–noon | ramp 3.2k→5k/hr | — |
| noon–7pm | plateau ~5.5–5.9k/hr | — |
| 8–10pm (peak) | 6.3–6.5k/hr | 20% in 3h |
| **net: 9am–1am ET** | | **~93%** |

**Day-of-week:** flat (~16% spread, Fri high / Wed low) → **not** a scheduling factor.

**Time-to-event (≤30d) — dominant signal:**

| Days to event | Sales/event | Median moves/event/day |
|---|---|---|
| 0 | 39 | 3.9 (≈ every capture) |
| 1 / 2 / 3 | 21 / 18 / 13 | 3.7–3.9 |
| 4 → 7 | 12 → 7 | 1.7 → 1.0 |
| 8–14 | ~5 | ≤1.0 |
| 15–30 | ~3.5 | rare |

→ ~10× heavier at ≤2 days than 3+ weeks out; repricing collapses past ~day 4–5.

### Model — two formats × metronome firing
- **TRADING (peak):** 09:00–00:59 ET = `13-23,0-4 UTC` → use `peak_interval_min`.
- **AFTER-HOURS (off):** 01:00–08:59 ET = `5-12 UTC` → use `offpeak_interval_min`.
- Peak/off boundary stays in `collector_band()` (TZ-aware → **DST-safe**); widen its peak-hour set `{12–23}` → **`{9–23,0}` ET**.
- **No concurrency per shared limit:** each rate-limited account = one serial metronome; consumers **phase-offset by minute**. TD account and SG token are independent upstreams → may overlap freely.

### Reference — `collector_cadence` target (peak / off-peak minutes)

**SG broker `/listings` (owned_kind=`owned`):**

| Band | Hrs | Peak | Off |
|---|---|---|---|
| le3d | 0–72 | 30 | 90 |
| d4_7 | 72–168 | 60 | 180 |
| d8_14 | 168–336 | 150 | 480 |
| d15_30 | 336–720 | 600 | 1440 |
| d31p | 720+ | 1200 | 1440 |

**SG `/sales` (owned_kind=`any`):**

| Band | Hrs | Peak | Off |
|---|---|---|---|
| le3d | 0–72 | 30 | 90 |
| d4_7 | 72–168 | 90 | 240 |
| d8_14 | 168–336 | 240 | 720 |
| d15_30 | 336–720 | 720 | 1440 |

**TD — new rows (owned_kind=`any`), after-hours off:**

| Band | Hrs | Peak | Off |
|---|---|---|---|
| le3d | 0–72 | 240 | 1× floor @04:00 ET |
| d4_7 | 72–168 | 480 | off |
| d8_14 | 168–336 | 720 | off |
| d15_30 | 336–720 | 1440 | off |
| d31p | 720+ | 2880 | off |

- SG **non-owned** listings: stays **OFF / once-daily** (unchanged). `le3d`=0–72h, `d4_7`=72–168h split the old flat `le7d` band.

### Reference — TD per-platform budget (recalculated)
Trading-hours only (after-hours off); pulls/day = `960 ÷ peak_interval`. Active events by platform × band → **~220 credits/day total** (vs the 300 cap; today's ~950 demand caps out at noon):

| Platform | le3d | d4_7 | d8_14 | d15_30 | d31p | ~cr/day | (today) |
|---|---|---|---|---|---|---|---|
| VD | 6 | 2 | 8 | 11 | 39 | ~59 | 96 |
| SH | 6 | 2 | 8 | 10 | 38 | ~58 | 133 |
| GT | 3 | 1 | 6 | 7 | 5 | ~28 | 26 |
| TM | 3 | 0 | 6 | 7 | 6 | ~27 | 22 |
| TP | 3 | 0 | 6 | 7 | 6 | ~27 | 23 |
| **Total** | | | | | | **~220** | 300 (capped) |

Savings come entirely from SH/VD no longer pulling their ~38 cold `d31p` events 4×/day.

### Reference — firing / phase map (no concurrent draws on a shared limit)

**TD account — one serial metronome:** drain `* 13-23,0-4 * * *`, `td_pull_drain(1)`, ordered hottest-band-first → **≤1 `/fetch`/min**. Per-platform enqueue (queue-fill only; `collector_band('TD',…)` throttles), staggered: SH `:00/10` · VD `:02/12` · GT `:04/14` · TM `:06/16` · TP `:08/18`.

**SG brokerdata token — interleaved (fixes 429 bursts):**

| Consumer | Trading | Batch | Phase |
|---|---|---|---|
| Broker `/listings` (owned) | `*/2 13-23,0-4` | `tick(4,3)` | even min |
| `/sales` | `1-59/2 13-23,0-4` | `tick(4)` ← was burst-20/5min | odd min |
| Floor sweep | `5-59/10 13-23,0-4` | small, gated | `:05,:15…` |
| SellerDirect #3 (separate host) | `7-59/10 13-23,0-4` | bulk 1 | `:07,:17…` |

Token now sees **≤1 small batch/min** (~4 ≪ 10/8s budget), alternating listings/sales. **Process** crons `sg_priority_*_process` → `*/2` (was `*/5`) so snapshots land continuously (DB-only). After-hours: same phases, sparse (`*/10` listings, `*/12` sales).

**SellerDirect (#3) — full-book pull + AQ map (operator directive 2026-06-06, APPLIED `20260606194100`).** The feed is *our own* **~290,710** listings (fields carry `cost`/`barcodes`/`seller_subaccount_id`), cursor-paginated; we'd been ingesting page 1 only (~0.17%). Implemented a **rolling keyset cursor** in `sg_seller_listings_queue` — advances one page/tick via the prior page's `meta.next_page`, loops at end, self-heals stale pendings, and does **not** touch the working `sg_seller_process`. Plus `sg_seller_sync_and_map()`: registers seller events into `sg_events_canonical` (`has_seller_listings`) + backfills `seatgeek_seller_listings.tevo_event_id` from canonical (SG→TEvo resolved by `auto_match_sg_canonical_v3_hourly`). Crons: queue `*/2` (guarded), process `1-59/2`, sync+map `*/15`. **FE:** `get_event_sg_seller_listings_full(p_event_id)` RPC + an "OUR SG INVENTORY" sub-section in the event page Our-Orders tab. First map run mapped **1,825/1,977** listings; the full book fills over ~1 day. **`/orders` (`seatgeek_orders`) is OBSOLETE** (stale to 2025-06, no payment data) — not maintained; UI label tagged obsolete. The push-based **webhook receiver (D2-OPS-3, merged/undeployed)** remains the eventual real-time upgrade over this polling. *Watch `v_sg_token_budget` / 429 health — SellerDirect shares `SEATGEEK_API_TOKEN`.*

### Safeguards retained
TD 300/day + 9,000/mo caps · SG `ratelimit-remaining` / `v_sg_token_budget` gate · `cron_should_fire` · clock-advance-on-200 strand-safety. `collector_cadence` is **data** → instant revert by row update; no schema drops; firehose tables untouched.

### Migration staging
1. ✅ **APPLIED** `20260606191854` — `collector_cadence` re-tune + widen peak window `{9–23,0}` ET (SG listings/sales bands).
2. ✅ **APPLIED** `20260606192104` — SG token interleave: `/sales`→`tick(4)` odd-min, `/listings` even-min, `*_process`→`*/2` (429-burst fix).
3. ✅ **APPLIED** `20260606192416` — TD fold: `td_enqueue_peak`→`collector_band`-driven; metronome drain `p_max=1` (+resolved_at guard); staggered per-platform enqueue; retire flat 4×/day; add TD bands.
4. ✅ **APPLIED** `20260606194100` + `get_event_sg_seller_listings_full` RPC — SellerDirect full-book rolling-cursor pull + AQ map + D0 event-page "OUR SG INVENTORY" panel. `/orders` marked obsolete. (Operator reversed the earlier hold; webhook D2-OPS-3 remains the eventual real-time upgrade.)

**Cutover note:** TD budget was already exhausted (300/300) under the old flat system when #3 landed, so TD firing resumes under the new horizon cadence at the next 00:00 UTC budget reset — clean, no double-spend. SG changes take effect on the next tick.

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
