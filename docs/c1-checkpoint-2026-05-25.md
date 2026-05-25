# C1 Checkpoint — 2026-05-25

Run ~auto-slot (scheduled `c1-daily-checkpoint`). Last formal doc: `docs/c1-checkpoint-2026-05-20.md` — **5-day gap** (no docs for 05-21..05-24), so deltas below span ~5 days. main HEAD: `860e5d7` (#344). Local `a1/docs-prs-340-344` carries 1 unpushed A1 commit (`6d8262b`) + staged PROJECT_BIBLE/README edits — A1 in-progress, left untouched; this checkpoint was authored from an isolated worktree off `origin/main`.

## Drift status

- **migration_drift_check**: 100 rows, **all** `applied_at: null, has_codified: null, note: 'standard slot'`. Identical structural pattern to 05-15 and 05-20. Per runbook caveat (MCP `apply_migration` auto-versions → filename ≠ `schema_migrations.version` is structural, not content drift). **No real drift.** Function-semantics confirmation still owed by A1 (carried follow-up, low priority).
- New migrations applied since 05-20 (top of drift list): `venue_mlb_resilience` (+`_state_fix`), `v3_sg_broker_sales_7d_window`, `fix_performer_index_league_scope`, `sg_blindspot_movers_matview`, and the **exos/D4 batch** (`exos_security_hardening`, `exos_public_marketing`, `exos_issue_to_email`, `exos_notify_holders`, `exos_mail_ticket_issued`, `exos_growth_primitives`, `exos_purchase_limits`, `exos_check_in_verify`, `exos_mint_event_cap`, `exos_mail_drainer`). All have files. No applied-but-no-file ghosts.

## release_health_check — non-ok rows (4 fail / 3 warn)

| check_class | check_name | status | metric | Δ vs 2026-05-20 |
|---|---|---|---|---|
| cron | failed_jobs_90min | fail | **51** | 35 → 51 ⚠️ **STILL REGRESSING** (9→35→51 over 3 checkpoints) |
| cron | subhourly_jobs_silent_90min | fail | **16** | 13 → 16 (worse) |
| functions | pgcrypto_missing_extensions_searchpath | fail | 1 | **NEW** — `exos_check_in_ticket` |
| views | security_definer_views | fail | **19** | 16 → 19 (+3: `exos_public_events/orgs/tiers`) |
| fks | not_valid_fks | warn | 56 | 56 (unchanged warn-backlog) |
| data_freshness | evo_orders_age_min | warn | 109 min | **NEW** warn (evo orders 109 min stale) |
| queues | unresolved_pending_total | warn | 1 | vivid=1, tickpick=0 (unchanged) |

### Cron cascade detail (ongoing, not transient)
Last-30-min `cron.job_run_details`: these jobs have **zero successes** in-window (every run failing on `statement timeout`):
`sg_classify_events_5min` (5✗), `sg_blindspot_mv_refresh` (3✗), `orphan_event_backfill_queue_15min` (2✗), `compute_alerts_tick_15min` (1✗), `match_listings_to_sg_30min` (1✗), `sg_broker_listings_metrics_refresh_hourly` (1✗), `sg_canonical_v2_pull_refresh_30min` (1✗).

The SG classify → match → blindspot → alerts pipeline is effectively stalled. This is the same loop flagged 05-15 (9) and 05-20 (35), now 51 and worse. Per the 05-20 watch item ("if still ≥20, escalate to severity=high"), **escalated `severity=high` to A1** this run. Likely the `data_freshness.evo_orders_age_min` warn is downstream of the same timeout pressure.

## PRs landed / awaiting

- **Open PR queue: 0** (`gh pr list --state open` → empty). Nothing to merge; nothing stale. The D4 batch (#336–#344) + SG/venue work landed to main since 05-20 via normal flow.
- No merge actions taken this run (queue empty). Pre-merge token-leakage audit N/A.

## bot_chat resolution count

| metric | value | Δ vs 05-20 |
|---|---|---|
| unresolved total | **442** | 293 → 442 ⚠️ |
| └ flag | 214 | 92 → 214 ⚠️ |
| └ question | 12 | 10 |
| └ p0_security | **0** | 0 (clean) |
| opened (24h) | 34 | 21 |
| **resolved (24h)** | **0** | ⚠️ nothing closed in 24h |
| unresolved >7d | 251 | — |

Backlog grew ~150 in 5 days, almost entirely `flag` (+122). Consistent with the `SG_BROKER_429_HEALTH` autoposter-noise problem (open follow-up #3 from 05-20 — still no auto-resolve/TTL path) plus the cron-cascade alert flags. `resolved_24h = 0` indicates resolve-hygiene has lapsed across all lanes — threads aren't being closed with `status` replies.

## Operator-action queue

ILIKE sweep (`@operator` / `operator action` / `rotat`) returns ~20 rows, but all are **stale historical change_logs/status** from 05-12..05-15 (>239h old) — credential-rotation logs, P1 go-live handoff, first-checkpoint watch list (#127). No genuinely *live* operator ask surfaced; the matches are resolve-hygiene debt, not pending work. Recommend C1 add an explicit `@operator-pending` tag convention so this queue stops aliasing on historical "rotated" mentions.

## Open follow-ups for A1 / B1

| # | Item | Owner |
|---|---|---|
| 1 | **`failed_jobs_90min` 51 — severity=high.** Statement-timeout cascade across SG classify/match/blindspot/alerts; zero successes in 30-min window. Needs explain-plan + index/relation-size investigation. Regressing 3 checkpoints straight. | **A1** |
| 2 | **`subhourly_jobs_silent_90min` (16)** — same root cause; silent jobs include the timing-out 5/15/30-min crons. | A1 |
| 3 | **`pgcrypto_missing_extensions_searchpath` — `exos_check_in_ticket`** (NEW). exos check-in fn missing `extensions` in search_path for pgcrypto. | A1 (+ D4 author) |
| 4 | **`security_definer_views` 16→19** — 3 new exos views (`exos_public_events/orgs/tiers`). Phase-B security-invoker conversion still unwritten (carried from 05-20 #2). | B1 / C1 |
| 5 | **bot_chat resolve hygiene** — 0 resolved/24h, 442 unresolved (214 flags). Need autoposter TTL/auto-resolve for `SG_BROKER_429_HEALTH` + cron-cascade flags. | A1 |
| 6 | **`evo_orders_age_min` 109 min** (NEW warn) — confirm whether downstream of cron timeouts or separate evo ingest blocker. | D2 (evo) |
| 7 | **`migration_drift_check` semantics** — still 100 `applied_at:null` rows every run; re-spec so clean = 0 rows. | A1 / C1 |

## Stale branch sweep

Only 2 working remote branches after a large prune (50+ merged branches deleted this run): `origin/a1/docs-prs-340-344` and `origin/claude/d4-scanner-timer-fix`, **both dated 2026-05-25**. **0 branches >14d stale.** Clean.

## Tomorrow's watch items

1. **Cron cascade** — must trend down from 51. If unchanged/worse, this is an incident, not a flag. Confirm A1 picked up the severity=high escalation.
2. **exos health rows** — does `pgcrypto` fail clear + do exos views move to phase-B queue?
3. **bot_chat backlog** — is `resolved_24h` still 0? If autoposter noise unaddressed, backlog will cross 500.
4. **PR queue** — should stay near 0; the 2 open branches may produce PRs.
5. **evo_orders freshness** — recovered or persistent?
