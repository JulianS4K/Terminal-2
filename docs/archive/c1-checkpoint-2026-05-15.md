# C1 Checkpoint — 2026-05-15

First formal checkpoint after the 2026-05-14 reassignment (PR #109). Run at ~04:00 UTC (post-overnight-backfill window, pre-09:00-ET).

## Drift status

- **migration_drift_check**: ~100 rows returned, all with `applied_at: null, has_codified: null, note: 'standard slot'`. Interpreted as no drift — file slots line up with `supabase_migrations.schema_migrations` (handoff §1–3 migrations + format() fix + cron-resume fix all in the list). A1 to confirm null-semantics on next pass.
- **release_health_check**: 4 non-ok rows | new vs yesterday-baseline: 0 net new. Day-over-day delta:
  - `failed_jobs_90min`: 18 → **9** (improvement — the §A syntax-error block cleared after PR #112)
  - `subhourly_jobs_silent_90min`: 8 → 7 (one cleared)
  - `not_valid_fks`: 57 (unchanged, warn-only backlog)
  - `listings_snapshots_age_min`: 249 → **261 min** (REGRESSING — see Open follow-ups)

## PRs landed since yesterday's checkpoint

- **#112** `fix(admin): cron_resume_with_gate trailing-semicolon bug — 4 crons failing` → `6c44198` (A1). Resolves bot_chat 128 §A.

## PRs awaiting action

- **#110** `chore(security): §6 SECDEF retrofit + RLS gap fix on aq venue/performer maps` — opened 03:36 UTC by B1. Age <1h. Next step: leave (B1 lane, <24h).
- **#111** `d1: SQL homepage autopop + movers fix + detail 502 scrub` — opened 03:43 UTC by D1. Age <1h. Next step: leave (D1 lane, <24h).

No stale PRs (nothing >24h with no activity).

## Bot_chat resolution count (last 24h)

- Opened by C1: 4 (id 125 status, 126 status, 127 flag, 128 flag)
- Responses received: 1 (id 129 from A1/Audit-Push lane, in_reply_to=128, addressing §A only)
- `resolved_at`-set on C1-authored rows: 0 — A1 posted a `status` reply rather than calling `bot_chat_resolve()` on id 128. The unresolved-view still shows 128 as open. Either A1 should call `bot_chat_resolve(128)` after addressing §B/C/D, or post a per-subsection resolution. Recommend the latter — §A is closed but §B/C/D are not.
- Unresolved >7d: 0.

## Open follow-ups for A1 / B1

| # | Item | Owner | Source |
|---|---|---|---|
| 1 | **bot_chat 128 §B / promoted to id 131 (severity=high)** — `listings_snapshots` 261 min stale and regressing. `collect-listings-0-24h` shows `status=succeeded` runs at 04:01 UTC return value `'DO'`, but no rows landing. Starter diagnostics in id 131: (a) cron_gate_decisions ~04:01 UTC — body entered or gate skip; (b) cron.job_run_details 04:01 fire — return_message + duration; (c) pg_net._http_response in window — 4xx/5xx swallowed?; (d) count(*) FROM listings_snapshots WHERE captured_at > '2026-05-15 03:50:00+00' vs prior hour. | A1 | release_health_check + bot_chat 131 |
| 2 | **bot_chat 128 §C** — `orphan_event_backfill_queue_15min` FK violation on `evo_event_backfill_pending_tevo_event_id_fkey`. Still failing every 15 min. | A1 | release_health_check (today 04:00) |
| 3 | **bot_chat 128 §D** — `midnight-catchup-sweep` statement timeout (`_sec_norm` during start). Failed at 03:20 UTC. | A1 | release_health_check |
| 4 | **bot_chat 128 §A — partial resolution.** PR #112 fixed the 4 syntax-error crons. A1 to call `bot_chat_resolve(128)` (or post per-subsection resolves) so the unresolved view reflects reality. | A1 | bot_chat 129 |
| 5 | **`orphan_event_backfill_process_15min`** destination bug — known from handoff §3 Open follow-ups. Continues to fail. Low priority per A1, but persistence noted (3+ checkpoints' worth once we have history). | A1 | yesterday's flag carried forward |
| 6 | **Two overnight backfills missed their windows.** `listings_deltas_backfill_overnight` (`30-44 4 * * *`) and `sg_canonical_link_overnight` (`46-59 4 * * *`) both `active=true` but `cron.job_run_details` shows zero runs. The jobs likely got recreated post-cron-resume fix and the resume happened after their UTC window. Either reschedule for tonight or run on-demand. | A1 | cron.job inspection |
| 7 | **`listings_aq_backfill_overnight` paused (`active=false`)** — was this intentional during the resume sweep, or a recovery artifact? Was on yesterday's watch list. | A1 | cron.job inspection |
| 8 | **B1 SECDEF retrofit migration** — PR #110 in progress, will track. | B1 | yesterday's watch list #2 |
| 9 | **Render API key** `rnd_WPA69TmT4vTttGvYa07GdMIqzfXz` rotation — still pending operator action. | Operator | yesterday's watch list #1 |
| 10 | **xlsx re-extract** for AQ Performer UUID — operator action. | Operator | yesterday's watch list #6 |
| 11 | **Runbook vs schema drift** — `docs/c1_daily_checkpoint_runbook.md` Step 8 specifies `bot_chat_log(p_event_type := 'checkpoint')`, but the `bot_chat_event_type_check` constraint allows only `change_log / question / flag / sync / status / collision / broadcast / p0_security`. Today's Step 8 entry landed as `status` (id 133) as the closest match. Either add `'checkpoint'` to the constraint via migration OR update the runbook. | A1 | discovered during today's Step 8 |

## Tomorrow's watch items (2026-05-16 checkpoint)

1. **Listings staleness** — target <60 min (per `sales_freshness_60min` floor). If still >60 min, escalate from `flag` to `severity=high`. The "succeeds but writes nothing" pattern is suspicious — could be a real silent-failure bug.
2. **Overnight backfills** — verify all 3 (`listings_aq_backfill`, `listings_deltas_backfill`, `sg_canonical_link`) ran cleanly in the 04:02–04:59 UTC window, or that they've been rescheduled.
3. **bot_chat 128** — should be fully resolved by tomorrow (§B/C/D addressed).
4. **PR #110 + #111** — at age 24h+ tomorrow; comment if no activity.
5. **B1 SECDEF retrofit** — verify migration applied, advisor count cleared.
6. **`orphan_event_backfill_process_15min`** — second-checkpoint count of persistence (escalate to `severity=high` if seen 3+ checkpoints unresolved per runbook).
7. **Open-Meteo archive retry** — ~6 days out.

## Stale branch sweep

Deferred — no `git for-each-ref` run this session. Will add to tomorrow's checkpoint once the cadence is steady.

## Next checkpoint

2026-05-16 ~09:00 ET (or earlier if listings staleness escalates).
