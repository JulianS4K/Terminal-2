# CRON_HIERARCHY.md — cron scheduling policy

> **Doc version:** v2.0.0 (2026-06-19; history in git/CHANGELOG)

Tiered scheduling: maximize freshness within bounded concurrency, leave headroom for future lanes. **Job catalog (live) → `RESOURCES_BIBLE §5` + `SELECT jobname,schedule,active FROM cron.job`** (this doc is policy, not the job list — ~164 jobs / ~151 active; do not maintain a per-job table here, it drifts).

## 1. Resource constraints (hard)
- `cron.max_running_jobs=32` (Supabase default, not raisable without support ticket); `cron.use_background_workers=off` → each job is a regular backend competing for `max_connections=60`.
- A job running >2 min holds a slot until done; all-32-busy at a tick → startup-timeout (the canary you blew the budget).
- **Keep peak concurrent crons ≤20** so ~12 slots stay free for future lanes + manual ops.

## 2. Tiers
| Tier | Cadence | Max | Use |
|---|---|---|---|
| T0 storefront-critical | */10 min | 4 | matview refreshes backing live UI (`latest_event_metrics`, dashboard) |
| T1 near-live ingest | */10–20 min | 10 | current-day listings, gameday scoreboards |
| T2 standard ingest | */30 min (staggered) | 30 | most queue/process pairs; orders, wiki, geocode, weather, alerts |
| T3 daily ops | 1×/day, 03–06 UTC | 20 | sweeps, catchup, daily backfills |
| T4 weekly | Sun morning | 10 | tournament pulls, climatology, seeds |

Worst-case concurrency at any minute ≈ ≤5 (spread offsets) — well under 20.

## 3. Stagger
Spread minute offsets within a tier so no two land on the same mark: T0 `2,4,6,8`; T1 fill the 15-min window; T2 one job per minute across 0–29; T3 one per minute 03:00–05:59; T4 Sun 04:00–04:45.

## 4. Listings collection — per-event poller model (collector-cadence, 2026-05-31)
Horizon-windowed collectors are **RETIRED**. Each source has **one ~2-min tick** that reads **`public.collector_cadence`** (helper `collector_band(source,scope,hours)` → `(band, required_min)`, peak-aware) and fires the collect call only for events whose per-event clock is due for their horizon band. Per-event clocks: `evo_listings_poll_state`; **SG reuses `sg_event_priority_state.last_fired_listings_at`** (no `sg_listings_poll_state`, no `horizon_days` col).

| Job | Cadence | Role |
|---|---|---|
| `evo_listings_poll_2min` | `*/2` | `evo_listings_poll_tick` — EVO, per due event, stamp-on-fire |
| `sg_listings_poll_owned_1min` | `*/1` | `sg_listings_poll_tick(5,3,'owned')` — broker `/listings`, OWNED only, rate-aware, strand-safe. ACTIVE |
| `sg_listings_poll_nonowned_5min` | `*/5` | NON-OWNED, once-daily floor. **OFF** (`cron_policy.enabled=false`; flip to resume) |
| `sg_sales_poll_5min` | `*/5` | band-driven `sg_sales_poll_tick` |

**Per-event cadence by horizon** (EVO is sole TEvo consumer ≈ unlimited → aggressive; SG is rate-limited):

| Horizon | EVO | SG (listings+sales) |
|---|---|---|
| ≤7d | 15 min | 1 h |
| 8–14d | 30/60 min (peak/off) | 4 h |
| 15–30d | 1 h | 12 h |
| 31–60d | 4 h | 24 h |
| 61d+ | 12 h | 24 h |

**Owned/non split:** SG listings cadence keyed on `owned_kind`. OWNED (`owned_count_last_7d>0`) = tight per-horizon bands (ACTIVE); NON-OWNED = once-daily (OFF).

**SG rate limit:** broker token ≈5 req/10s window **shared with a separate external prod program** → `tick(p_max=5)`, backs off on live `ratelimit-remaining`; clock advances **only on HTTP 200** (429/timeout re-tries, doesn't burn the slot). Watch `v_sg_token_budget` + `v_sg_broker_429_health`.

## 4c. Trading-hours cadence (market-timed; applied 2026-06-06)
Cadences live in `collector_cadence` (data → instant revert by row update). Two formats by ET clock, boundary in `collector_band()` (TZ-aware, DST-safe):
- **TRADING (peak)** 09:00–00:59 ET (`13-23,0-4 UTC`) → `peak_interval_min`. **AFTER-HOURS** 01:00–08:59 ET → `offpeak_interval_min`. (~93% of sales fire 9am–1am ET; ~10× heavier ≤2 days out; repricing collapses past ~day 4–5.)
- **No concurrent draws on a shared limit:** each rate-limited account = one serial metronome, consumers phase-offset by minute. SG token: `/listings`(owned) even-min `tick(4,3)`, `/sales` odd-min `tick(4)`, floor-sweep `:05/10`, SellerDirect `:07/10` → token sees ≤1 small batch/min (≪10/8s). TD account: serial drain `td_pull_drain(1)` hottest-band-first, per-platform enqueue staggered `:00–:08`.
- **TD budget:** 300/day + 9,000/mo caps; horizon cadence → ~220 credits/day (was ~950, capped out at noon). Savings = SH/VD stop pulling cold `d31p` 4×/day.

**SellerDirect** (our own ~290k listings): rolling keyset cursor in `sg_seller_listings_queue` (one page/tick via `meta.next_page`, loops, self-heals); `sg_seller_sync_and_map()` registers events into `sg_events_canonical` + backfills `seatgeek_seller_listings.tevo_event_id`. Crons: queue `*/2`, process `1-59/2`, sync `*/15`. FE: `get_event_sg_seller_listings_full()`. `/orders` (`seatgeek_orders`) is OBSOLETE. Shares `SEATGEEK_API_TOKEN` — watch budget.

**Safeguards:** TD caps · SG `ratelimit-remaining`/`v_sg_token_budget` gate · `cron_should_fire` · clock-advance-on-200. `collector_cadence` is data (instant revert); firehose tables untouched.

## 5. Future-bot reservation
New lane (B2/B3/B4): default **T2** (`*/30` staggered); pick a free minute offset (`SELECT schedule FROM cron.job`); to claim T0/T1, demote an existing job to keep the cap; confirm `peak_concurrent_jobs ≤20` before resume.

## 6. Maintenance
A1 owns this doc + the schedule. After any `cron.schedule()`/`cron.alter_job()`, re-verify peak ≤20. Recurring "job startup timeout" in `pg_cron.log` = budget blown. Owner: A1.
