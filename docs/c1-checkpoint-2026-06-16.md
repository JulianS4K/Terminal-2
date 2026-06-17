# C1 Checkpoint — 2026-06-16

> Baseline diffed against `docs/archive/2026-06-07-c1-checkpoint.md` (most recent
> committed checkpoint on `main`; the 06-08/06-10 checkpoints remain unmerged in
> PRs #502/#536). Origin HEAD: `ce8a970`.

## Drift status

- **migration_drift_check:** 100 rows returned, `applied_at IS NULL` /
  `has_codified IS NULL` on all; `has_codified IS FALSE` count = **0**. This is
  the known MCP `apply_migration` auto-versioning artifact (filename timestamp ≠
  `schema_migrations.version`) — **structural, not content-level drift**.
  **Real drift: none.**
- **release_health_check (status≠ok):** 8 rows — 5 fail / 3 warn (vs 06-07: 5
  rows, 3 fail / 2 warn). **3 regressions this window** (detail below).

### Health checks ≠ ok (today vs 06-07 baseline)

| class | check | status | metric | Δ vs 06-07 | note |
|---|---|---|---|---|---|
| cron | `failed_jobs_90min` | **fail** | 4 | 🔴 **NEW** | deadlocks on `sg_classify_events_5min`; `sweep-old-listings: column "id" does not exist`; `sweep-old-sg-listings: statement timeout` — **PR #568 fixes the `id`-column delete** |
| cron | `subhourly_jobs_silent_90min` | fail | 5 | ↓ from 6 | `sg_canonical_link_overnight`, `listings_deltas_backfill_overnight` (overnight, expected silent); `collect-listings-7-30d`, `collect-listings-30-60d`, `entity-metrics-daily-refresh` warrant a look |
| functions | `pgcrypto_missing_extensions_searchpath` | fail | 2 | = | `exos_check_in_ticket`, `build_watchlist_daily_email` — search_path hardening gap (standing) |
| views | `security_definer_views` | fail | 34 | ↑ from 24 (+10) | new `exos_public_*`, `v_axs_*`, `unified_*` views follow the documented-accepted SECDEF pattern; persistent baseline, not a new attack surface |
| fks | `not_valid_fks` | warn | 54 | = | long-standing NOT VALID FK backlog (espn_*/seatgeek_*/seatdata_*) — known watchlist |
| data_freshness | `evo_orders_age_min` | **fail** | 257 | 🔴 **warn→FAIL** | evo_orders 257 min stale (was ~97 warn) — escalation, investigate ingest |
| data_freshness | `vivid_orders_age_min` | warn | 116 | 🟡 **NEW** | vivid_orders 116 min stale |
| queues | `unresolved_pending_total` | warn | 1 | 🟡 **NEW** | vivid=1, tickpick=0 |

## PRs landed today

- **None merged by C1.** Per runbook escalation ("new `fail` row that wasn't
  there yesterday → pause all merges, page A1"), merges are **held this cycle**
  on account of the new `cron.failed_jobs_90min` fail + `evo_orders` warn→fail.

## PRs awaiting action (20 open)

**Fresh (<24h), lane owners active — leave:**
- #568 `fix(a1): sweep_old_listings deletes by captured_at, not missing id column`
  — **directly fixes today's new cron fail.** A1 lane; fast-track candidate once CI green.
- #567 `feat(d0): ESPN sports player search` · #566 `fix(store): seat-map mount timing`
- #564 `ci(d4): exos migrations + SQL suite` · #563 `fix(d4): Vite 8 manualChunks (unblocks #544)`
- #562 `fix(security): allowlist false-positive secret-scan hits` (B1 lane — needs B1 sign-off)
- #561 `fix(store): venue seat map render` · #560 `fix(terminal): home movers 30d default`
- #559 `chore(d0): pause non-AXS TicketsData crons + budget split`

**24–72h, dependabot — A1 to batch-review:**
- #547 cryptography · #546 fastapi · #545 anthropic (all 06-15)

**>72h, no activity — comment for ETA:**
- #544 (06-13) `chore(deps): bump esbuild/vite/tsx in /d4_bridge` — blocked behind #563
- #543 (06-11) `fix(d4): secure standalone-server checkout`

**>7d, stale-close candidates (warn this cycle, close next if no movement):**
- #536 (06-10) `chore(c1): daily checkpoint 2026-06-10` — own C1 self-PR, never merged
- #514 (06-09) open-notebook publisher POC
- #506 (06-09) Render deploy-webhook → GitHub Actions bridge
- #505 (06-09) seating_chart 'null' poison fix at TEvo ingest
- #502 (06-08) `chore(c1): daily checkpoint 2026-06-08` — own C1 self-PR, never merged
- #495 (06-08) Fantasy League feature

## Bot_chat resolution count

- opened today: 1
- unresolved (total): **753** (↓ from 1317 on 06-07 — a large sweep ran in between)
- unresolved opened today: 1

## Stale branch sweep (>14d, no gh-pages/release-please)

12 remote branches ≥2 weeks stale: `a1/optimize-zone-section-metrics`,
`a1/ticketsdata-integration`, `claude/compassionate-hopper-aFNWL`,
`claude/d0-aq-tevo-bridge`, `claude/d0-deploy-2026-05-27`,
`claude/d4-comprehensive-testing-wPECJ`, `claude/featured-section-events-pV5kM`,
`claude/great-albattani-pezXQ`, `claude/hopeful-gauss-SQ8iF`,
`claude/nice-fermi-UOpKo`, `claude/optimistic-brahmagupta-DKiSl`,
`claude/resume-d0-chat-itUGb`. → lane owners reclaim or A1 prunes.

## Open follow-ups for A1 / B1

- **A1 — new cron fail (`failed_jobs_90min`):** `sweep-old-listings` references a
  non-existent `id` column; `sweep-old-sg-listings` statement-timeout;
  `sg_classify_events_5min` deadlocks. **PR #568 is the fix for the `id` bug** —
  prioritize CI + merge. Deadlock + timeout need separate triage.
- **A1 — `evo_orders` warn→fail (257 min stale):** EVO order ingest stalled;
  confirm collector liveness.
- **A1/D-lane — `vivid_orders` 116 min stale + 1 unresolved vivid pending.**
- **B1 — `security_definer_views` 24→34:** confirm the +10 (`exos_public_*`,
  `v_axs_*`, `unified_*`) all fall under the documented-accepted SECDEF pattern.
- **C1 self:** two unmerged C1 checkpoint PRs (#502, #536) — decide merge-or-close.

## Tomorrow's watch items

- Did `cron.failed_jobs_90min` clear after #568 merges? (target: back to 0)
- `evo_orders_age_min` — back under warn threshold, or trending worse?
- `security_definer_views` count — should plateau, not keep climbing.
- Stale-close the >7d PRs (#495, #502, #505, #506, #514, #536) if still idle.
