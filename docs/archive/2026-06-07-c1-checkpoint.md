# C1 Checkpoint — 2026-06-07

> Baseline run — no prior `docs/c1-checkpoint-*.md` exists, so health/drift deltas
> are absolute (no yesterday to diff against). Future runs diff against this file.

## Drift status

- **migration_drift_check:** ~95 rows, all `note='standard slot'` with
  `applied_at IS NULL` / `has_codified IS NULL`. This is the known MCP
  `apply_migration` auto-versioning artifact (filename timestamp ≠
  `schema_migrations.version`) — **structural, not content-level drift**.
  No applied-but-divergent-content rows surfaced. **Real drift: none.**
- **release_health_check (status≠ok):** 5 rows — 3 fail / 2 warn (detail below).

### Health checks ≠ ok

| class | check | status | metric | note |
|---|---|---|---|---|
| cron | `subhourly_jobs_silent_90min` | fail | 6 | `sg_canonical_link_overnight`, `zone-backfill-isolated-10min`, `listings_deltas_backfill_overnight`, `collect-listings-7-30d`, `collect-listings-30-60d`, `entity-metrics-daily-refresh` — 3 are *overnight* jobs (expected silent during day); `collect-listings-7-30d/30-60d` + `entity-metrics-daily-refresh` warrant a look |
| functions | `pgcrypto_missing_extensions_searchpath` | fail | 2 | `exos_check_in_ticket`, `build_watchlist_daily_email` — search_path hardening gap |
| views | `security_definer_views` | fail | 24 | Largely standing/accepted (`exos_public_*` documented-accepted per `sec_p3_document_exos_public_views_accepted`); persistent baseline, not new |
| fks | `not_valid_fks` | warn | 54 | Long-standing NOT VALID FK backlog (espn_*, seatgeek_*, seatdata_*) — known watchlist item |
| data_freshness | `evo_orders_age_min` | warn | ~97 | evo_orders 97 min stale (>warn threshold); monitor for trend |

## PRs landed today

- None. (origin/main HEAD `0b26a4b` = #448 security lockdown, landed prior cycle.)

## PRs awaiting action

- **#449** `feat(sg): hard-wire SeatGeek to primary API; kill-switch TD-seatgeek`
  | age: <24h | merge state: **BLOCKED** | CI: 1 FAILURE + 1 CANCELLED check
  | review: none | next step: **not eligible** — fix failing CI + needs lane
  sign-off; A1 is sole pusher to main. Leave for author/A1.

## Bot_chat resolution count

- opened today: 65
- unresolved (total): 1317
- unresolved opened today: 65
- aging unresolved (p0/flag/question, 2h–7d window): 20

## Open follow-ups for A1 / B1

- **#449 CI red** — failing check blocks the SG-primary cutover; author/A1 to triage.
- **pgcrypto search_path (2 fns)** — `exos_check_in_ticket`,
  `build_watchlist_daily_email` need explicit `extensions` search_path pin (B1 sec lane).
- **Local main ↔ worktree** — `main` is pinned to a worktree
  (`.claude/worktrees/agitated-visvesvaraya-27f782`) and local main has diverged
  from origin; checkout/ff-pull blocked in primary tree. Non-blocking for read-only
  checkpoint but worth cleaning up.

## Tomorrow's watch items

- **collect-listings-7-30d / 30-60d + entity-metrics-daily-refresh** silent >90min —
  confirm these are cadence-by-design vs actually stalled.
- **evo_orders freshness** — 97 min now; escalate if it crosses into multi-hour.
- **Aging bot_chat = 20** in the 2h–7d p0/flag/question window — trending; lane
  sweeps should be draining these.
- **Stale-branch threshold** — oldest remote branches are 12d (no >14d yet);
  4 branches (`d4-comprehensive-testing`, `a1/optimize-zone-section-metrics`,
  `featured-section-events`, `resume-d0-chat`) cross 14d tomorrow — sweep then.
