# C1 Checkpoint — 2026-05-20

Resumed checkpoint cadence after a 5-day gap (last formal doc: `docs/c1-checkpoint-2026-05-15.md`). Run ~15:21 UTC. Comparisons in this doc are vs the 2026-05-15 baseline, so deltas span ~5 days of activity — interpret accordingly.

## Drift status

- **migration_drift_check**: 100 rows returned, **all** with `applied_at: null, has_codified: null, note: 'standard slot'`. Same structural pattern observed on 2026-05-15 (100 rows then, 100 now). Per the runbook caveat — MCP `apply_migration` auto-versions, so filename ≠ `schema_migrations.version` is structural, not real content drift. **No real drift.** Function semantics still need an A1 confirmation pass; carrying forward as low-priority.
- **release_health_check** (non-ok rows, 5 total):

| check_class | check_name | status | metric | Δ vs 2026-05-15 |
|---|---|---|---|---|
| cron | failed_jobs_90min | fail | 35 | 9 → **35** ⚠️ REGRESSING |
| cron | subhourly_jobs_silent_90min | fail | 13 | 7 → **13** ⚠️ REGRESSING |
| views | security_definer_views | fail | 16 | **NEW** vs 2026-05-15 |
| fks | not_valid_fks | warn | 56 | 57 → 56 (warn-only backlog) |
| queues | unresolved_pending_total | warn | 1 | vivid=1, tickpick=0 — **NEW** |

  Hot spots from `failed_jobs_90min` detail:
  - `sg_classify_events_5min` — statement-timeout loop (17 errors in window)
  - `compute_alerts_tick_15min` — statement-timeout (6 errors)
  - `match_listings_to_sg_30min` — statement-timeout (3 errors)
  - `sg_priority_listings_process_5min`, `orphan_event_backfill_queue_15min`, `match_unmatched_orders_sweep_hourly`, `sweep_duplicate_listings_hourly` — recurring timeouts

  `subhourly_jobs_silent_90min` list (13 jobs not posting): sg_classify_events_5min, compute_alerts_tick_15min, match_listings_to_sg_30min, listings_aq_backfill_overnight, sg_60d_sales_morning, sg_canonical_link_overnight, sg_60d_listings_afternoon, sg_60d_sales_afternoon, match_unmatched_orders_sweep_hourly, sweep_duplicate_listings_hourly, sg_60d_listings_morning, sg_blindspot_poll_5min, listings_deltas_backfill_overnight.

  `security_definer_views` (16): `espn_injury_snapshot_latest, order_status_coverage, seatgeek_event_latest, unified_orders, unified_orders_by_event, v_aq_match_quality, v_event_full_sports, v_event_full_v2, v_event_price_arbitrage, v_event_velocity_windows, v_orphan_seatgeek_data, v_returning_entities, v_sg_blindspot_movers, v_sg_broker_429_health, v_sg_broker_429_starved_events, v_tevo_blindspot_movers`. Likely owners: A1 + C1 (security-invoker phase A was migration `20260518170321_c1_security_invoker_views_phase_a`; phase B not yet authored). Tracking as C1 next item.

## PRs landed since 2026-05-15

`gh pr list --state open` returned **0**. Open queue is clean (consistent with bot_chat 326 "PR queue CLEAR" from 2026-05-18). Recent merges to `main` (sample of last 15 commits):

- #288 `feat(tevo/cron): 10-min TEvo refresh for Featured-eligible NYC events`
- #287 `fix(d1/store): Weekend suffix limited to actual Sat/Sun`
- #286 `feat(d1/store): holiday day-of vs weekend-of rail labels`
- #285 `feat(d1/store): populate away-team assets across catalog + home + movers`
- #284 `chore(d1/store): Featured cap 12→20 + title "Featured in NYC"`
- #283 `fix(d1/store): Featured 3 fixes`
- #282 `feat(d1/store): Featured multi-signal`
- #281 `feat(d1/store): Featured narrow criteria`
- #280 `fix(d0/terminal): define BLIND_SPOT_MIN_SG_SALES`
- #279 `feat(d1/store): Featured rail`
- #277 `feat(a1/movers): TEvo blindspot detection RPC`
- #278 `feat(d0/landing): static-site root serves unified selector`

5-day window dominated by D1 Featured-rail iteration + a1 blindspot detection.

## PRs awaiting action

None — open count = 0.

## bot_chat resolution count (rolling 14d)

- Unresolved total: **293** (`flag`=92, `question`=10, `p0_security`=**0**, rest split across `change_log`/`status`/`sync`/`broadcast`/`collision`).
- Opened in last 24h: 21.
- **Dominant noise source**: `SG_BROKER_429_HEALTH` hourly monitor flag from A1 — 23+ rows in last 24h, each posted by the autoposter cron. PR #228 (2026-05-18) addressed the underlying `pg_net` request leak, but the threshold-cross alerts continue to fire (sales `pct_429` regularly 60–80%, listings highly variable). These are unresolved-view pollution, not real new findings. Recommend either: (a) autoresolve via `bot_chat_resolve()` after N hours, (b) consolidate into a single rolling-window flag, or (c) raise the threshold if 429s are now expected.
- Non-429 top unresolved within 48h:
  - **332** (A1, flag, 46h open) — `@espn-collect`: ingest hardening for Layer 2 of Arias notification flood (Layer 1 was PR #260 RPC-side partition fix).
  - **330** (A1, question, 47h open) — `@B1`: spec clarification on B1-NEXT-31 (§6 retrofit on 7 JWT-gated SECDEF RPCs).
  - **318** (D0, flag, ~61h open) — `@A1`: PR #218 fix for SG Splits/Zones panels not rendering on event page (race vs PR #210).

## Open follow-ups

| # | Item | Owner | Source |
|---|---|---|---|
| 1 | **`failed_jobs_90min` regression (9→35)** — statement-timeout loop across `sg_classify_events_5min`, `compute_alerts_tick_15min`, `match_listings_to_sg_30min`, `match_unmatched_orders_sweep_hourly`, `sweep_duplicate_listings_hourly`. Top suspect: planner regression or growing relation size. Needs A1 investigation of explain plans + index health on the underlying queries. | A1 | release_health_check today |
| 2 | **`security_definer_views` (16) — phase B** — migration `20260518170321_c1_security_invoker_views_phase_a` shipped phase A; the 16 listed views were not in scope. Author phase B (security-invoker conversion + tests) — C1 lane. | C1 | release_health_check today |
| 3 | **`SG_BROKER_429_HEALTH` autoposter noise** — 23+ rows/day with no resolution path. Propose either auto-resolve via TTL trigger or threshold tuning so the flag fires only on **net-new** breaches, not every hourly probe. | A1 | bot_chat unresolved view |
| 4 | **bot_chat 332** — Arias ingest hardening Layer 2 awaiting espn-collect lane owner (~46h). Needs ack. | A1 / espn-collect | bot_chat 332 |
| 5 | **bot_chat 330** — B1 owes A1 spec clarification on B1-NEXT-31 (§6 SECDEF retrofit, 7 JWT-gated RPCs, ~47h open). | B1 | bot_chat 330 |
| 6 | **bot_chat 318 / PR #218** — SG Splits/Zones rendering race regression. May already be shipped (PR #218 referenced as the fix); confirm by checking `git log --grep=#218` and resolve the thread. | A1 / D0 | bot_chat 318 |
| 7 | **`vivid_orders_pending` queue = 1** — single stuck row; check `vivid_orders` for ingest blocker. Carrying as `warn`. | A1 (orders lane) | release_health_check today |
| 8 | **`not_valid_fks` (56)** — long-running warn-only backlog. No change in cadence; no action requested unless someone proposes a structured validation campaign. | — | release_health_check |
| 9 | **`migration_drift_check` semantics confirmation** — 100 rows of `applied_at: null` on every checkpoint. Either re-spec the function so a "clean" run returns 0 rows, or document the structural-noise expectation in the runbook. | A1 / C1 | carried from 2026-05-15 |

## Tomorrow's watch items (2026-05-21 checkpoint)

1. **`failed_jobs_90min` — must trend back toward single digits.** If still ≥20 tomorrow, escalate from `flag` to `severity=high`.
2. **`subhourly_jobs_silent_90min`** — same trajectory; 13 silent jobs is too many.
3. **`security_definer_views` phase B** — does the 16-view list shrink? C1 to begin authoring.
4. **`SG_BROKER_429_HEALTH` autoposter** — confirm noise reduction plan landed.
5. **bot_chat 332 / 330** — both at ~70h tomorrow if no movement; escalate.
6. **PR queue** — should remain clear; flag if open count >5 with no activity 24h+.

## Stale branch sweep

`git for-each-ref refs/remotes/origin/ | awk '$2 < "2026-05-06"'` → **0 branches >14d stale.** All remote heads dated 2026-05-16 or later. Clean.

## Next checkpoint

2026-05-21 ~daily slot (per `c1-daily-checkpoint` scheduled task).
