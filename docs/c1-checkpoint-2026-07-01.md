# C1 Checkpoint — 2026-07-01

_Autonomous scheduled run. Read-only investigation + escalation; no merges, no mutations (per push-protocol + CLAUDE.md §1)._

## Headline

🔴 **Cron scheduler gap** — pg_cron went silent for ~8h (06:00→14:00 UTC), briefly resumed at 14:00, then silent again since **14:33:59 UTC** (33 min at checkpoint time, 15:07 UTC). Corroborated by two `data_freshness` **fail** rows (evo_orders 602 min / vivid_orders 581 min stale ≈ 10h). **Not yet flagged in bot_chat** — C1 is surfacing it. Owner: **A1** (scheduler) + ingest lanes (D2 evo / D1 vivid).

## Drift status

- `migration_drift_check`: 100 rows, **all** `applied_at=NULL / has_codified=NULL / note="standard slot"`.
  → Structural only (MCP `apply_migration` auto-versions, so filename ≠ `schema_migrations.version`). **No content-level drift.**
- `release_health_check` (non-ok): 7 rows — see table.

| Class | Check | Status | Detail | Owner |
|---|---|---|---|---|
| cron | subhourly_jobs_silent_90min | **fail** | 50 jobs silent — the outage window | A1 |
| data_freshness | evo_orders_age_min | **fail** | 602 min stale (~10h) | D2 |
| data_freshness | vivid_orders_age_min | **fail** | 581 min stale (~9.7h) | D1 |
| views | security_definer_views | **fail** | 19 d0_*/unified/v_td_* views SECDEF — **persistent structural**, not new | B1 |
| cron | failed_jobs_90min | warn | orphan_event_backfill_queue_15min canceled | A1 |
| fks | not_valid_fks | warn | 5 NOT VALID FKs (perf_wiki, sg xref, venue_pulls) — persistent | A1 |
| queues | unresolved_pending_total | warn | vivid=1, tickpick=0 | A1 |

**New vs prior baseline:** the three cron/freshness **fail** rows are the acute incident. `security_definer_views` (19) and `not_valid_fks` (5) are carried-over structural items, not escalations. (No `docs/c1-checkpoint-2026-06-30.md` present in-tree for line-by-line diff — checkpoint docs live on their own branches; baseline taken from health-check semantics.)

## Cron timeline (UTC, 2026-07-01)

| Hour | Runs | Failed |
|---|---|---|
| 01:00 | 580 | 7 |
| 02:00 | 686 | 8 |
| 03:00 | 708 | 4 |
| 04:00 | 729 | 16 |
| 05:00 | 699 | 0 |
| 06:00 | 231 | 3 |
| 07:00–13:00 | **0** | — (gap) |
| 14:00 | 70 | 1 |
| 14:34–15:07 | **0** | — (silent again) |

155 active jobs registered. Self-recovered once at 14:00 then stalled — looks intermittent, not fully healed.

## PRs landed today

- None. **No merges this cycle** — push-protocol blocks merges while health-check `fail` rows are active (cron silence + order-freshness). A1 remains sole pusher to `main`.

## PR backlog (37 open)

- **<72h (7):** #697, #696, #693 (features, 06-29); #692/#691/#690 (dependabot, 06-29); #689 (perf, 06-29). Leave — lane owners active.
- **72h–7d (3):** #686 (06-26), #684 (06-25), #683 (06-24). Comment-for-ETA next cycle.
- **>7d (27):** incl. #582 (stale C1 checkpoint 06-19), #681/#680/#678/#676/#672 (06-22/23), #649/#647/#632 (06-20), #585/#580/#579/#576/#575/#574/#564/#562/#560/#559/#543/#514/#495. **Backlog growing** — recommend a dedicated stale-close sweep (needs lane-owner/A1 sign-off; not auto-closed here).

## Bot_chat resolution count

- Unresolved total: **1787** | created today: 0 | p0_security: 0 | older than 72h: **1656**
- Backlog is chronic and large; the aging-sweep tasks feed it faster than it drains. Flagging as a standing follow-up, not a today-regression.

## Open follow-ups for A1 / B1

1. **A1** — investigate pg_cron 06:00–14:00 UTC silence + recurring stall since 14:33; confirm scheduler/compute health. (bot_chat flag posted.)
2. **D2 / D1** — evo & vivid order freshness fails are downstream of #1; should clear once cron drains queues. Verify no independent order-client breakage.
3. **B1** — 19 SECURITY DEFINER views (`d0_*`, `unified_listings`, `v_td_credit_*`, `v_event_full_sports`) still flagged; carry-over from prior checkpoints.
4. **A1** — 5 NOT VALID FKs pending VALIDATE; #603-era backlog.
5. **C1/A1** — 30 PRs >72h with no activity; schedule a stale-close pass.

## Tomorrow's watch items

- Did the cron scheduler stay up past 15:00 UTC? Re-check `cron.job_run_details` gap.
- evo/vivid order freshness back <60 min once crons drain?
- `subhourly_jobs_silent_90min` back to ok.
- bot_chat unresolved trend (1787 → ?).
