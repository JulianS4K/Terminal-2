# C1 Checkpoint — 2026-06-20

> Baseline diffed against `docs/archive/c1-checkpoint-2026-06-19.md` (PR #582).
> Origin HEAD: `4a7691a` (#655). Runbook: `docs/archive/c1_daily_checkpoint_runbook.md`.

## Drift status

- **migration_drift_check:** 100 rows, all `applied_at IS NULL` / `has_codified IS NULL` /
  `note='standard slot'`. Known MCP `apply_migration` auto-versioning artifact (filename
  timestamp ≠ `schema_migrations.version`) — **structural, not content-level drift. Real
  drift: none.** Newest file slots are A1's 06-20 alert/forecast view batch
  (`a1_alert_*`, `a1_event_price_*`, `get_event_market_context_public`).
- **release_health_check (status≠ok):** 5 rows — **4 fail / 1 warn** (down from 8 rows /
  5 fail-3 warn on 06-19). Net composition improved: 3 freshness/queue rows cleared, but
  one cron check regressed warn→fail.

### Health checks ≠ ok (today vs 06-19 baseline)

| class | check | status | metric | Δ vs 06-19 | owner | note |
|---|---|---|---|---|---|---|
| cron | `failed_jobs_90min` | **fail** | 8 | 🟢 **better** (17→8) | A1 | orphan_event_backfill, tevo_blindspot_refresh, match_listings_to_sg, compute_alerts_tick, sweep_duplicate_listings — all statement-timeouts. Improved but still failing |
| cron | `subhourly_jobs_silent_90min` | **fail** | 6 | 🔴 **warn→FAIL** (3→6) | A1 | **NEW escalation.** Silent: sg_canonical_link_overnight, sweep_duplicate_listings_hourly, listings_deltas_backfill_overnight, collect-listings-7-30d, collect-listings-30-60d, entity-metrics-daily-refresh |
| functions | `pgcrypto_missing_extensions_searchpath` | **fail** | 2 | = | A1 | `exos_check_in_ticket`, `build_watchlist_daily_email` — standing search_path gap |
| views | `security_definer_views` | **fail** | 37 | 🔴 **+3** (34→37) | B1 | documented-accepted SECDEF baseline; +3 are A1's new 06-20 alert views (v_event_price_vol/arbitrage etc.). New surface — B1 to confirm intended SECDEF |
| fks | `not_valid_fks` | warn | 54 | = | A1 | long-standing NOT VALID FK backlog (espn_*/seatgeek_*/seatdata_*) — known watchlist |

**De-escalations (dropped to ok since 06-19):** `data_freshness.evo_orders_age_min`
(was fail 258), `data_freshness.vivid_orders_age_min` (was FAIL 297), `queues.unresolved_pending_total`
(was warn 1). 🟢 All three cleared — orders ingest recovered.

## PRs landed today

- **None merged by C1.** Per runbook escalation rule (new `fail` row vs yesterday → hold
  merges, defer to A1), `cron.subhourly_jobs_silent_90min` warn→FAIL holds merges this
  cycle. A1 is sole pusher to `main` regardless; C1 does not self-merge during a regression.

## PRs awaiting action (36 open, ↑ from 25)

**Fresh (<24h), lane owners active — leave:**
- #657 subs lookup from order # · #656 unmapped-section tracker · #651 d4 browse filters
- #649 a1 cross-market signal views/RPC · #647 store SEO meta + share · #632 store tour-guard 500-fix

**24–72h:**
- #585 retail-chat cost guards · #582 (own C1 06-19 checkpoint self-PR) · #581 governance maintenance agent
- #580 d0 PWA/mobile terminal · #579 d0 25/page watchlist · #578 kanban aging-sweep pause
- #568 **fix(a1) sweep_old_listings by captured_at** — still OPEN; partially relevant to today's
  cron timeouts; A1 fast-track once silent-jobs escalation clears
- #545/#546/#547 dependabot (anthropic/fastapi/cryptography, 06-15) — A1 batch-review
- #591/#592/#593 dependabot d4_bridge (babel/ws/protobufjs, 06-19) — D4 batch

**>72h, no activity — comment for ETA:**
- #577 (06-16) C1 checkpoint self-PR · #576 skills ship-a-migration · #575 d4 Exos backlog
- #574 store mobile UX · #568 (above) · #559–#564 d0/store/security/d4 batch
- #544 (06-13) d4_bridge esbuild/vite/tsx — blocked behind #563

**>7d, stale-close candidates (warn, close next cycle if no movement):**
- #543 (06-11) d4 secure standalone checkout · #536 (06-10) C1 checkpoint self-PR
- #514 (06-09) open-notebook POC · #506 (06-09) Render deploy-webhook bridge
- #505 (06-09) seating_chart 'null' poison · #502 (06-08) C1 checkpoint self-PR · #495 (06-08) Fantasy League

## Bot_chat resolution count

- opened (24h): **80**
- unresolved (total): **1103** (↑ from 955 on 06-19)
- unresolved >7d: **494**
- aging-actionable (p0/flag/question, >2h <7d): **35**; p0_security: **0**
- **Dominant signal (unchanged from 06-19):** A1 `SG_BROKER_429_HEALTH` flood — SeatGeek
  **listings** `pct_429` over the 15% threshold all day (16–31%, 100–168 req/h); sales leg
  clean (0%). 6 of 8 A1 24h flags. Rate-limit pressure on the SG listings poller persists —
  A1 lane, cadence/token-budget look overdue.
- **Two A1 handoffs need prod apply:** D0→A1 (PR #633) two operator-gated read RPCs
  (`get_owned_events_upcoming` …); D1→A1 (PR #623) Grok/xAI provider adapter in
  `supabase/functions/chat/index.ts`.

## Stale branch sweep (>14d, excl gh-pages/release-please)

15 remote branches ≥2 weeks stale (unchanged set from 06-19):
`a1/optimize-zone-section-metrics`, `a1/ticketsdata-integration`,
`claude/beautiful-albattani-P0JXz`, `claude/bold-ride-XLP9H`,
`claude/compassionate-hopper-aFNWL`, `claude/d0-aq-tevo-bridge`,
`claude/d0-deploy-2026-05-27`, `claude/d4-comprehensive-testing-wPECJ`,
`claude/featured-section-events-pV5kM`, `claude/great-albattani-pezXQ`,
`claude/hopeful-gauss-SQ8iF`, `claude/nice-fermi-UOpKo`,
`claude/nyc-budget-chatbot-test-aDGum`, `claude/optimistic-brahmagupta-DKiSl`,
`claude/resume-d0-chat-itUGb`. No churn in 2+ days → recommend A1 prune-or-revive pass.

## Open follow-ups

1. **A1** — `cron.subhourly_jobs_silent_90min` warn→FAIL (6 silent jobs). New escalation,
   investigate scheduler/timeout. Pairs with the still-failing `failed_jobs_90min` (8).
2. **A1** — SG listings 429 flood unresolved 2nd day running; needs cadence/budget change,
   not just heartbeat flags.
3. **B1** — confirm the 3 new SECDEF views (06-20 alert batch) are intended SECDEF (34→37).
4. **A1** — two pending prod-apply handoffs (PR #633 RPCs, PR #623 Grok adapter).
5. **Self/C1** — older C1 checkpoint self-PRs (#502/#536/#577/#582) never merge; consider
   batch-closing or a merge convention so they stop accumulating in the >7d bucket.

## Tomorrow's watch

- Did `subhourly_jobs_silent_90min` clear, or did the silent-job set grow? (escalation gate
  for whether merges resume).
- `failed_jobs_90min` trend (8 → ?) — does #568 land and help.
- SG 429 listings: any cadence change land, or 3rd-day flood.
- bot_chat unresolved total (1103) trajectory — D0 status heartbeats (94/24h) dominate
  noise; worth a resolve-hygiene/auto-resolve pass.
