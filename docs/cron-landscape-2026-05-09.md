# Cron landscape across all data sources (2026-05-09)

> **Audience**: anyone (human or AI session) who needs to understand what background jobs are running, on what cadence, against which APIs, with what rate limits and rules. Run `SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;` for a live view.

---

## TL;DR — 28 active crons across 6 sources

| Source | Crons | Cadence range |
|---|---|---|
| **TEvo (Ticket Evolution)** | 8 | 2 min → daily |
| **SeatGeek** | 2 | 10 min, 30 min |
| **SeatData** | 0 dedicated (gated by master-cascade + on-demand only) | n/a |
| **ESPN** | 2 | 3 min, daily |
| **Wikipedia** | 3 | every 5 min |
| **Open-Meteo + Nominatim** | 5 | 5 min, 30 min, weekly |
| Internal sweeps + cascades | 8 | 2 min → daily |

---

## TEvo (Ticket Evolution) — 8 crons

Read-only via HMAC-SHA256 signed requests against `api.ticketevolution.com`. Server-side calls go through Railway's FastAPI app (TEvo creds are Railway env vars; also now in Vault for SQL-side access).

| Cron | Cadence | What it does | Window |
|---|---|---|---|
| `collect-listings-0-24h` | every 20 min | Pull listings for events in next 0-24h | 0-24h |
| `collect-listings-1-7d` | every hour at :05 | Pull listings for events 1-7d out | 1-7d |
| `collect-listings-7-30d` | every 4h at :10 | Pull listings for events 7-30d out | 7-30d |
| `collect-listings-30-60d` | every 12h at :15 | Pull listings for events 30-60d out | 30-60d |
| `collect-listings-60d+` | daily at 02:20 UTC | Pull listings for events 60d+ out | 60d+ |
| `evo-orders-collect-10min` | every 10 min | Pull TEvo orders via Railway POST | rolling |
| `crawl-venues-and-performers-3min` | every 3 min | Refresh TEvo dim tables (performers/venues) | continuous |
| `backfill-event-configurations-5min` | every 5 min | Fill missing seating configurations | continuous |

**`min_age_seconds` rule**: Each `collect-listings-*` job carries a `min_age_seconds` param so it skips events that were pulled recently. Cadence and min-age are paired:
- 0-24h: 1100s (~18 min) min age — always-fresh
- 1-7d: 3300s (55 min)
- 7-30d: 13200s (3.7h)
- 30-60d: 39600s (11h)
- 60d+: 82800s (23h)

**Rate limit**: TEvo doesn't publish hard limits per token. Empirically generous. The `_iter_paginated()` client method paginates at 100/page, max 50 pages. No 429 retry currently — relies on cadence pacing.

**Rules**:
- RULE 2 read-only (GET only, runtime-guarded by `_assert_readonly_method` in `evo_client.py`)
- HMAC includes `?` even when query is empty (otherwise 401 on `/v9/events/:id/stats`)
- `events.occurs_at_local` has misleading `Z` suffix — actually local-TZ-with-offset

---

## SeatGeek — 2 crons

Read-only against two SG hosts:
- `brokerdata.seatgeek.com` — `/listings`, `/v2/listings`, `/sales`
- `sellerdirect-api.seatgeek.com` — our own SG inventory + orders

Auth is `?token=` query string. Token in vault as `SEATGEEK_API_TOKEN`.

| Cron | Cadence | What it does |
|---|---|---|
| `seatgeek-seller-collect-10min` | every 10 min | Hits Railway `/api/admin/collect-sg-seller` → pulls SG `/listings` + `/orders` from sellerdirect, persists to `seatgeek_seller_listings` + `seatgeek_orders` |
| `sg_canonical_auto_match_30min` | every 30 min | Server-side: syncs `sg_events_canonical` from seller_listings + orders + broker_sales, runs auto-matcher against TEvo events |

**Rate limit observed**:
- Forecast endpoint generally tolerant (saw 9 of 17 rapid bursts get 429 once; serial 1.5s pacing recovered)
- Archive endpoint stricter
- Client retries 429 with `Retry-After` header + exponential backoff capped at 60s

**Rules**:
- RULE 2 — `_assert_readonly_method('GET')` in both `_get` (broker) and `_get_seller` (sellerdirect)
- `cursor` pagination for `/listings` (page= deprecated)

---

## SeatData — 0 dedicated crons

By design: SeatData has **hard budget caps** (BASIC plan: 100 paid pulls/day, 2000/month). All paid pulls are on-demand only, gated through:

1. `seatdata_check_budget()` RPC before every paid call
2. `seatdata_increment_budget()` after success
3. `seatdata_pull_log` for audit

Triggered manually via app routes (`/api/seatdata/event/{id}/sales`, etc.) or by `master_cascade_2min` for high-priority events.

**Rate limit**:
- Per-minute rate limits per endpoint (advisory; server-authoritative via headers)
- HARD CAP: 100 paid pulls/day, 2000/month. Bumping requires changing BOTH `seatdata_client.py` constants AND migration values (two-key change so accidental overage is unlikely)

**Rules**:
- RULE 2 — read-only with one exception: `POST /v0.4/events/event-request-add` (metadata only — asks SD to add an event to their catalog; doesn't push our data)
- 429 backoff respects `Retry-After`, exponential to 60s cap
- `was_charged` derived per endpoint:
  - `/listings/get`: charged only if `has_refreshed=1`
  - `/events/{id}/stats`: charged only on first per-period pull
  - `/salesdata/get`: always charged when rows returned

---

## ESPN — 2 crons

Read-only against `site.api.espn.com` (public, no auth required).

| Cron | Cadence | What it does |
|---|---|---|
| `espn-team-daily` | daily at 05:00 UTC | Refresh team standings + injuries + news for all tracked teams |
| `crawl-espn-team-assets-3min` | every 3 min | ESPN logo / image assets crawl |

**Rate limit**: ESPN doesn't publish documented limits for `site.api.espn.com`. We've never hit issues at our volume.

**Rules**:
- All GET, no auth
- `is_baseline` field is broken for NBA/NFL/MLS/WNBA/WC (works only for MLB/NHL) — known bug. Workaround: `v_espn_team_state` and `v_espn_injuries_current` use `DISTINCT ON ... ORDER BY captured_at DESC` to sidestep.
- Live game state (espn_event_snapshots) state field: `pre` | `in` | `post`

---

## Wikipedia — 3 crons (just added)

Read-only against `en.wikipedia.org` REST + opensearch APIs. Public, UA-required.

| Cron | Cadence | What it does |
|---|---|---|
| `performer_wiki_queue_searches_5min` | every 5 min | Fire opensearch for unmapped performers (20 per tick, 0.5s gap = 2 req/s) |
| `performer_wiki_process_searches_5min` | every 5 min, offset +1m | Parse search results, fire summary fetches for hits |
| `performer_wiki_process_summaries_5min` | every 5 min, offset +2m | Finalize performer_wikipedia rows (pageid, extract, image_url) |

**Rate limit**:
- 200 req/min unauthenticated
- 5,000 req/h with proper User-Agent
- We pace at 0.5s = 120 req/min — well under cap

**Rules**:
- User-Agent header REQUIRED per Wikipedia policy: `Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)`
- Three offset cron jobs because pg_net responses aren't visible mid-transaction (MVCC) — must split queue/process across separate transactions

---

## Open-Meteo + Nominatim — 5 crons (just added)

Read-only public APIs (no key for either).

| Cron | Cadence | Source | What it does |
|---|---|---|---|
| `venue_geocode_queue_5min` | every 5 min | Nominatim | Fire geocode for ungeocoded venues (30/tick, 1.1s gap) |
| `venue_geocode_process_5min` | every 5 min, offset +1m | n/a | Parse Nominatim responses, update `venue_assets.latitude/longitude` |
| `weather_forecast_queue_30min` | every 30 min | Open-Meteo forecast | Fire 16-day forecast for venues with coords + events in next 16d |
| `weather_forecast_process_30min` | every 30 min, offset +5m | n/a | Persist 384 hourly rows per venue |
| `weather_climatology_weekly` | Sundays 06:00 UTC | Open-Meteo archive | Throttled retry of any 429s + new-venue backfill (3 years) |

**Rate limits**:
- **Open-Meteo forecast**: ~10K req/day per IP soft cap. Generous. We send ~30-50 req/day total.
- **Open-Meteo archive**: stricter. Got 25/30 429s when firing rapidly; **must throttle to 5s gap** (12 req/min).
- **Nominatim**: 1 req/sec hard cap per their usage policy. Cron paces 1.1s. UA required.

**Rules**:
- UA header on Nominatim (per their policy)
- Forecast cap: only fetch for events ≤16 days out (Open-Meteo's free forecast horizon)
- Climatology fallback for events >16d: derived from 3-year archive at same venue
- `is_indoor=true` venues skip weather entirely (no point)

**Time-to-weather for any new event**:
- Venue already geocoded: ≤30 min (next forecast tick)
- Venue new (no coords): ≤5 min geocode + ≤30 min weather = ≤35 min total

---

## Internal cascades + sweeps — 8 crons

| Cron | Cadence | Purpose |
|---|---|---|
| `master-cascade-2min` | every 2 min | Coordinated freshness across SG xref + SD/ESPN cascades |
| `midnight-catchup-sweep` | daily 00:00 UTC | Catch up anything stale from prior day |
| `sweep-old-listings` | daily 03:00 UTC | Clean stale listings_snapshots (>N days old) |
| `sweep_tevo_ticket_groups_cache` | hourly :15 | Drop expired TEvo ticket-group cache rows |
| `sweep-bot-messages` | daily 04:10 UTC | Chat bot message cleanup |
| `zone-backfill-isolated-10min` | every 10 min, offset +4m | Backfill stale zone_metrics |
| `refresh-chat-corpus` | hourly :30 | Refresh chat training corpus |
| `refresh-chat-term-freq-split-hourly` | hourly :15 | Recompute chat term-frequency splits |
| `run-daily-chat-audit` | daily 04:00 UTC | Daily chat audit |
| `ensure-watchlist-coverage-daily` | daily 06:00 UTC | Ensure major-league watchlist coverage |

---

## RULE 2 enforcement summary

All 28 crons are read-only against external sources. The 3-layer enforcement stack (per `SCHEMA.md`):

1. **Runtime guards** in clients (`evo_client.py`, `seatgeek_client.py`, `seatdata_client.py`) — `_assert_readonly_method('GET')`
2. **Static analysis** — `scripts/check_readonly.py` scans Python + TS/JS for non-GET to forbidden hosts
3. **Unit tests** (`tests/test_readonly_guards.py`, 12 cases) — assert guards raise on non-GET

The 3-layer stack means flipping the rule requires editing client + audit + tests — visible in any code review.

---

## Common failure modes + remediation

| Symptom | Likely cause | Fix |
|---|---|---|
| pg_net response stuck without `status_code` | Background worker queue backlog (slow request blocking) | Wait — usually clears in <5 min; investigate via `net.http_request_queue` |
| 429s on SG /v2/listings | Burst pacing too tight | Client already retries with Retry-After; for batch jobs slow to 1.5s gap |
| 429s on Open-Meteo archive | Archive endpoint stricter than forecast | Use `weather_historical_retry_throttled` (5s gap) |
| Zero Wikipedia hits | UA header missing or rate cap hit | Confirm UA header in queue function; cron paces 0.5s already |
| ESPN `is_baseline` always true on NBA/NFL etc. | Known writer-side bug | Use `v_espn_team_state` / `v_espn_injuries_current` views (DISTINCT ON workaround) |
| SeatData budget exhausted | Hit 100 paid pulls/day cap | Wait until midnight UTC reset OR upgrade plan + bump constants |
| TEvo 401 on `/events/:id/stats` | Forgot `?` in HMAC canonical string | Already handled in client; if seen, check signing logic |

---

## Live-state queries

```sql
-- All active crons
SELECT jobid, jobname, schedule, active FROM cron.job
WHERE active = true ORDER BY jobname;

-- Recent cron runs + outcomes
SELECT jobname, status, start_time, end_time, return_message
FROM cron.job_run_details
ORDER BY start_time DESC LIMIT 20;

-- pg_net queue depth (in-flight requests)
SELECT count(*) FROM net.http_request_queue;

-- SeatData budget remaining today
SELECT * FROM seatdata_pull_budget WHERE budget_date = current_date;
```

---

## Status

Filed by: code · 2026-05-09
Snapshot: 28 active crons, 0 paused, 0 failing as of last health check.
