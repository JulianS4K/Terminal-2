# C1 Checkpoint — 2026-06-19

> Baseline diffed against `docs/c1-checkpoint-2026-06-16.md` (PR #577, most recent
> checkpoint; 06-17/06-18 cycles did not run). Origin HEAD: `b0431ca` (#573).

## Drift status

- **migration_drift_check:** 100 rows returned, `applied_at IS NULL` /
  `has_codified IS NULL` / `note='standard slot'` on all rows; no
  applied-but-no-file or file-but-not-applied flag. This is the known MCP
  `apply_migration` auto-versioning artifact (filename timestamp ≠
  `schema_migrations.version`) — **structural, not content-level drift.**
  **Real drift: none.**
- **release_health_check (status≠ok):** 8 rows — **5 fail / 3 warn** (same count
  as 06-16, but composition shifted — 2 escalations, 1 de-escalation below).

### Health checks ≠ ok (today vs 06-16 baseline)

| class | check | status | metric | Δ vs 06-16 | owner | note |
|---|---|---|---|---|---|---|
| cron | `failed_jobs_90min` | **fail** | 17 | 🔴 **worse** (4→17) | A1 | `sweep_duplicate_listings_hourly` + `listings_deltas_backfill_overnight` statement timeouts. **PR #568 fixes the sweep delete** but is still draft/unmerged → fail compounding |
| cron | `subhourly_jobs_silent_90min` | warn | 3 | 🟢 **fail→warn** (5→3) | A1 | `collect-listings-30-60d`, `sweep_duplicate_listings_hourly`, `listings_deltas_backfill_overnight` — improved |
| functions | `pgcrypto_missing_extensions_searchpath` | **fail** | 2 | = | A1 | `exos_check_in_ticket`, `build_watchlist_daily_email` — standing search_path gap |
| views | `security_definer_views` | **fail** | 34 | = | B1 | documented-accepted SECDEF pattern (exos_public_*, v_axs_*, unified_*); persistent baseline, not new surface |
| fks | `not_valid_fks` | warn | 54 | = | A1 | long-standing NOT VALID FK backlog (espn_*/seatgeek_*/seatdata_*) — known watchlist |
| data_freshness | `evo_orders_age_min` | **fail** | 258 | = (still fail) | D2/evo | evo_orders 258 min stale — persists from 06-16 (257) |
| data_freshness | `vivid_orders_age_min` | **fail** | 297 | 🔴 **warn→FAIL** (116→297) | D1/vivid | vivid_orders 297 min stale — **escalation, investigate ingest** |
| queues | `unresolved_pending_total` | warn | 1 | = | A1 | vivid=1, tickpick=0 |

## PRs landed today

- **None merged by C1.** Per runbook escalation ("new `fail` row that wasn't
  there yesterday → pause all merges, page A1"), merges are **held this cycle**
  on account of `vivid_orders` warn→FAIL + the worsening `cron.failed_jobs_90min`
  (4→17). No regression-free window to land into.

## PRs awaiting action (25 open, ↑ from 20)

**Fresh (<24h), lane owners active — leave:**
- #580 `feat(d0): PWA + mobile-friendly terminal` · #579 `feat(d0): 25/page watchlist, exclude EVO-owned`
- #578 `docs(kanban): hourly §5 aging-sweep pause` · #577 `chore(c1): daily checkpoint 2026-06-16` (own C1 self-PR)
- #576 `fix(skills): ship-a-migration links to inventory owner` · #575 `docs(d4): Exos parity build backlog`
- #574 `fix(store): mobile UX header overflow + 44px taps`

**24–72h:**
- #568 `fix(a1): sweep_old_listings deletes by captured_at` — **directly fixes today's cron fail**; A1 lane, fast-track once CI green + escalation clears
- #559–#564 (d0 cron pause, terminal movers, store seat map, security allowlist, d4 Vite8/CI) — lane owners active
- #545 anthropic · #546 fastapi · #547 cryptography (dependabot, 06-16) — A1 batch-review

**>72h, no activity — comment for ETA:**
- #544 (06-13) `chore(deps): bump esbuild/vite/tsx in /d4_bridge` — blocked behind #563
- #543 (06-11) `fix(d4): secure standalone-server checkout`

**>7d, stale-close candidates (warn this cycle, close next if no movement):**
- #536 (06-10) `chore(c1): daily checkpoint 2026-06-10` — own C1 self-PR, never merged
- #514 (06-09) open-notebook publisher POC · #506 (06-09) Render deploy-webhook bridge
- #505 (06-09) seating_chart 'null' poison fix · #502 (06-08) `chore(c1): checkpoint 06-08` self-PR
- #495 (06-08) Fantasy League feature

## Bot_chat resolution count

- opened (24h): **97**
- unresolved (total): **955** (↑ from 753 on 06-16)
- unresolved >7d: **398**
- aging-actionable (p0/flag/question, >2h <7d): **24**
- **Dominant signal:** A1 `SG_BROKER_429_HEALTH` flag flood — SeatGeek listings
  `pct_429` repeatedly over the 15% threshold (16–27%, ~80–170 req/h) across the
  last ~38h (ids 2194–2329). Rate-limit pressure on the SG listings poller —
  A1 lane, worth a cadence/token-budget look. C1's own 06-16 PARTIAL delivery
  flag (id 2230) remains open.

## Stale branch sweep (>14d, excl gh-pages/release-please)

15 remote branches ≥2 weeks stale: `a1/optimize-zone-section-metrics`,
`a1/ticketsdata-integration`, `claude/d4-comprehensive-testing-wPECJ`,
`claude/featured-section-events-pV5kM`, `claude/resume-d0-chat-itUGb`,
`claude/optimistic-brahmagupta-DKiSl`, `claude/d0-deploy-2026-05-27`,
`claude/nice-fermi-UOpKo`, `claude/hopeful-gauss-SQ8iF`,
`claude/great-albattani-pezXQ`, `claude/compassionate-hopper-aFNWL`,
`claude/d0-aq-tevo-bridge`, `claude/nyc-budget-chatbot-test-aDGum`,
`claude/beautiful-albattani-P0JXz`, `claude/bold-ride-XLP9H`.
→ lane owners reclaim or A1 prunes (carryover from 06-16; set largely unchanged).

## Open follow-ups for A1 / B1

- **A1 — cron `failed_jobs_90min` worsening (4→17):** `sweep_duplicate_listings_hourly`
  + `listings_deltas_backfill_overnight` statement timeouts. **PR #568 is the fix —
  needs CI-green + merge to clear.** Top priority.
- **A1 — SG 429 pressure:** sustained `SG_BROKER_429_HEALTH` over-threshold flags
  (16–27%); review SG listings poll cadence / token budget.
- **D1/vivid — vivid_orders ingest:** warn→FAIL (297 min stale). Investigate poller.
- **D2/evo — evo_orders ingest:** still FAIL (258 min stale), 4th+ cycle persisting.
- **B1 — `security_definer_views` (34):** confirm the exos/axs/unified additions
  remain documented-accepted; no action if baseline-expected.

## Tomorrow's watch items

- Did **PR #568** merge and clear `cron.failed_jobs_90min`? (top blocker for resuming merges)
- Did `vivid_orders` + `evo_orders` freshness recover, or escalate to operator (2nd consecutive fail)?
- bot_chat unresolved trend (955 ↑) — is the 429 flag flood being resolved or accreting?
- Stale-close the >7d C1 self-PRs (#502, #536) and POCs (#495, #505, #506, #514) if still idle.
