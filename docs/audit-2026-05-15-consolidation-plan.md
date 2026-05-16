# Audit + Consolidation Plan — 2026-05-15

Author: C1 (Drift Monitor lane). Status: **plan, not execution**. Read by A1 + B1 + operator for sequencing decisions.

This doc inventories prod state today and proposes 6 consolidation clusters with sequencing. It supersedes the point-in-time observations in [audit-2026-05-14-data-stability.md](docs/audit-2026-05-14-data-stability.md) where state has changed; it does **not** replace that doc as a record of yesterday's work.

---

## Today's snapshot (read-only, ~04:20 UTC 2026-05-15)

| Surface | Count / state |
|---|---|
| Schemas: tables / views / matviews | public=144 / 149 / 2 — close 1:1 table:view ratio suggests view sprawl |
| Public functions: SECDEF w/ search_path | 28 |
| Public functions: SECINVOKER w/ search_path | 234 |
| Public functions: SECINVOKER **without** search_path | **35** (B1 retrofit target) |
| Crons: active / paused | 78 / 11 |
| Crons failing in 24h | 3 (`orphan_event_backfill_process_15min`, `orphan_event_backfill_queue_15min`, `midnight-catchup-sweep`) |
| `release_health_check` non-ok rows | 4 (cron.failed_jobs, cron.silent, fks.not_valid, data_freshness.listings_snapshots) |
| `listings_snapshots_age_min` | **261 min** and regressing (bot_chat 131) |
| Security advisors open | ~22 (7 ERROR RLS-disabled, 2 WARN ext-in-public, 2 WARN matview-in-API, ~11 WARN anon/authenticated SECDEF rpc, 1 WARN auth) |
| `bot_chat` unresolved entries | 80+ across 4 days; **0** rows have `resolved_at` set |
| Audit docs in `docs/*audit*.md` | 11 (5/8 → 5/14), most point-in-time |
| Open PRs | 2 (#110 B1 SECDEF retrofit; #111 D1 storefront) — both <24h |

---

## Consolidation clusters (6) — sequenced

### Cluster B (do first) — Cron landscape cleanup

**Why first**: data outages right now. Listings 4h stale, 3 crons failing every 15 min, overnight backfills missed.

| Item | Owner | Action |
|---|---|---|
| `collect-listings-0-24h` returns `'DO'` but inserts zero rows | A1 | bot_chat 131 starter diagnostics: cron_gate_decisions, run_details duration, pg_net._http_response, count(*) delta |
| `orphan_event_backfill_process_15min` — `query has no destination for result data` | A1 | Add `PERFORM` or `INTO _discard` to the SELECT; known low-pri carried since handoff |
| `orphan_event_backfill_queue_15min` — FK violation on `evo_event_backfill_pending_tevo_event_id_fkey` | A1 | Investigate: which tevo_event_id is failing? Add ON CONFLICT or filter to declared FKs |
| `midnight-catchup-sweep` — statement timeout in `_sec_norm` | A1 | Either bump timeout or split work; runs daily at 03:20 UTC |
| `listings_deltas_backfill_overnight` (04:30-44 UTC) — active=true but never ran | A1 | Job recreated post-cron-resume after window passed. Re-fire manually OR confirm tonight's run |
| `sg_canonical_link_overnight` (04:46-59 UTC) — same | A1 | Same |
| `listings_aq_backfill_overnight` (04:02-14 UTC) — active=**false** | A1 | Was this intentional pause, or recovery artifact? Decide resume/retire |
| `master-cascade-2min`, `zone-backfill-isolated-10min` — paused, last fired 5/13 | A1 | Retire or document why kept paused |
| sg_seller_* / sg_listings_* (paused but had recent activity 5/14) | A1 | Confirm intentional (likely yes per cron-resume migration; document) |

**Exit criteria**: `release_health_check().cron.failed_jobs_90min` = 0 (or only documented expected failures); `listings_snapshots_age_min` < 60 min (sales_freshness floor).

### Cluster A (parallel to B) — Drift-detection infrastructure

**Why parallel**: B's diagnostics surface gaps that A should close so future B-class outages don't go silent for hours.

| Item | Owner | Action |
|---|---|---|
| Silent-success detection: add a `data_freshness_writes_60min` check to `release_health_check()` that counts rows inserted into ingest tables per 60-min window, fails if 0 | A1 | New check function; updates `release_health_check` view |
| `migration_drift_check()` returns 100+ rows with null `applied_at` / `has_codified` — semantics unclear | A1 | Either fix the function to populate these from `supabase_migrations.schema_migrations` + filesystem, or document that nulls mean "no drift" |
| Runbook says `bot_chat_log(event_type='checkpoint')` but constraint disallows | A1 | Pick one: migration to add `'checkpoint'` to the check OR runbook patch to use `'status'`. Today's Step 8 used `status` as workaround (id 133) |
| Pre-merge advisor gate | A1 + B1 | CI step: run `get_advisors` on the preview branch, fail if ERROR or new WARN classes appear |
| `release_health_check` `format()` post-mortem doc | A1 | Yesterday's bug + fix is undocumented; add to `docs/release-discipline.md` as a case study |

### Cluster C (parallel, B1 lane) — Security advisor backlog

**Why parallel**: B1 already has PR #110 open. Track to completion + add the items not covered.

| Item | Owner | Action |
|---|---|---|
| 7 ERROR `rls_disabled_in_public` tables: `aq_venue_map`, `aq_performer_map`, `sg_priority_policy`, `sg_event_priority_state`, `cron_pause_state_20260514`, `cron_policy`, `cron_gate_decisions` | B1 | Apply RLS deny-all policy (or scoped policy if reads are needed). PR #110 covers the two AQ maps; 5 cron-policy tables additional |
| ~11 WARN `anon/authenticated SECDEF rpc executable`: `aq_event_map_ingest`, `create_system_aq_event`, `cron_last_fire`, `cron_resume_with_gate`, `cron_should_fire`, `listings_deltas_backfill_chunked`, `match_unmatched_listings_chunked`, `match_unmatched_orders_sweep`, `sg_canonical_link_from_tevo_chunked`, `sg_classify_events`, `sg_priority_poll_tick`, `tickpick_orders_ingest_from_apps_script` | B1 | Per function: REVOKE EXECUTE from anon+authenticated (keep service_role), OR convert to SECURITY INVOKER. `tickpick_orders_ingest_from_apps_script` keeps `anon` execute (designed entry point) but should add a non-spoofable check |
| 35 SECINVOKER functions without `search_path` | B1 | §6 SECDEF retrofit migration (in flight per PR #110); confirm scope covers all 35 |
| 2 WARN `extension_in_public` (pg_trgm, unaccent) | A1 | Move to `extensions` schema; documented as deferred in 5/14 audit. Schedule? |
| 2 WARN `materialized_view_in_api` (latest_event_metrics, v_dashboard_writes_24h) | — | Documented intentional in 5/14 audit; no action |
| 1 WARN auth_leaked_password_protection | Operator | Toggle in Supabase Auth settings |

**Exit criteria**: advisor count back to ≤7 (only the documented-intentional 5/14 baseline plus auth toggle pending).

### Cluster D — `bot_chat` governance

**Why mid-priority**: not user-facing, but the coordination surface is degrading. Unresolved view shows everything since 2026-05-12 → noise drowns signal.

| Item | Owner | Action |
|---|---|---|
| 80+ entries with `resolved_at = null` since 5/12 | C1 + A1 | Two-phase: (a) sweep + resolve closed items via `bot_chat_resolve(id)` for change_logs / broadcasts older than 24h; (b) document the new protocol so reply-with-status doesn't accumulate |
| A1 pattern: `status` reply with `in_reply_to` instead of `bot_chat_resolve` (today's id 129 is example) | A1 | Pick one: (i) update `v_bot_chat_unresolved` to auto-close rows that have a `status` reply, (ii) require A1 to also call `bot_chat_resolve` after each `status` reply, (iii) restructure to use `bot_chat_resolve` as the canonical close |
| Bot_lane field has casing drift: `c1` vs `C1`, `Audit/Push` vs `A1` | C1 | Pick canonical names; document in `docs/bot_chat_conventions.md`; backfill via UPDATE (one-time, operator-authorized) |
| `event_type='checkpoint'` not in constraint allowlist despite CLAUDE.md saying so | A1 | Settle: either add to constraint or update CLAUDE.md + runbook |

**Exit criteria**: `v_bot_chat_unresolved` returns only entries genuinely needing action; daily count <20.

### Cluster E — Documentation consolidation

**Why later**: should reflect the post-cleanup state, not capture the in-flight one.

| Item | Owner | Action |
|---|---|---|
| 11 audit docs in `docs/*audit*.md` from 5/8-5/14 | C1 | Roll the still-relevant content into `docs/current-state-2026-05-15.md`; move the rest to `docs/archive/` |
| `LANE_DISCIPLINE.md` — verify C1 section matches post-PR-#109 reality | C1 | Already merged but cross-check |
| `docs/c1_daily_checkpoint_runbook.md` — patch event_type drift (Cluster A) | A1 | After A's decision lands |
| `MIGRATION_CONVENTIONS.md` — does it cover the AQ-cluster migrations that introduced today's advisor regressions? | C1 + A1 | Add a §"new tables = new RLS policy" reminder; explicit advisor check before commit |
| `docs/release-discipline.md` — add the cron-resume trailing-semicolon bug as a case study | A1 | Done by example, write up the lesson |

### Cluster F (opportunistic) — Schema sprawl audit

**Why lowest priority**: not blocking; useful long-term.

| Item | Owner | Action |
|---|---|---|
| 149 public views vs 144 tables — survey for dead/duplicated views | C1 | Use `pg_stat_user_tables` + `pg_views` join; rank by last-read time |
| 297 public functions — which are dead code? | C1 + A1 | `pg_stat_user_functions.calls` over the past 7 days; functions with 0 calls + no cron/edge reference = candidates for removal |
| 35 SECINVOKER no-search_path inventory — confirm B1's retrofit scope | B1 | Cross-check the 35 against PR #110's diff |
| 57 NOT VALID FKs (warn-only, unchanged since yesterday) | A1 | Validate in low-traffic window: `ALTER TABLE ... VALIDATE CONSTRAINT ...` |

---

## Open questions for the operator

1. **Cluster B priority** — does the `collect-listings-0-24h` silent-success bug warrant pulling A1 off other work, or wait for normal C1-flagged escalation? Listings 4h stale; sales freshness floor is 60 min.

2. **bot_chat resolve protocol (Cluster D)** — pick one of the three options for closing entries: (i) auto-close on `status` reply via view change, (ii) require explicit `bot_chat_resolve` after status replies, (iii) refactor everything to use `bot_chat_resolve` as the canonical close. Each has tradeoffs. C1's preference: (i) — least friction, but masks "A1 acknowledged but didn't fix" cases.

3. **Audit doc archive (Cluster E)** — destructive (`git mv docs/audit-* docs/archive/`) or non-destructive (leave + new index doc)? C1's preference: non-destructive — the audits are referenced by past `bot_chat` entries.

4. **Pre-merge advisor gate (Cluster A)** — should this be a hard fail (blocks PR merge) or a soft warn (comment only)? Hard fail forces the issue but adds friction.

5. **Cron retire decisions (Cluster B)** — for `master-cascade-2min` and `zone-backfill-isolated-10min` (paused >48h, no run history): retire (DELETE FROM cron.job) or keep paused as documentation? C1's preference: retire if A1 confirms unused.

---

## Sequencing (recommended)

Today / tomorrow:
- **Cluster B-1** (silent-success listings) — A1 picks up bot_chat 131 today
- **Cluster B-2** (3 failing crons) — A1, today or tomorrow
- **Cluster C-1** (7 ERROR RLS) — B1 expands PR #110 scope to cover all 7 (currently 2)

This week:
- **Cluster A** (drift infrastructure) — A1, sequenced after B-1 fix so the new check is calibrated against real data
- **Cluster C-2** (12 WARN SECDEF rpc) — B1, follow-on PR
- **Cluster D-1** (bot_chat sweep) — C1 + A1, batch resolve

Next week:
- **Cluster E** (doc consolidation) — C1, after Clusters A/B/C land
- **Cluster F** (schema sprawl) — opportunistic; can be a Sunday weekly job

---

## Exit definition

The audit + consolidation pass is "done" when:
- `release_health_check()` returns 0 non-ok rows (or only documented-acceptable ones)
- Security advisor count back to ≤7 (5/14 baseline + auth toggle)
- `bot_chat` unresolved view < 20 rows; all rows <72h old
- One canonical `docs/current-state-2026-05-15.md` exists; old audit docs archived or indexed
- `docs/release-discipline.md` + `MIGRATION_CONVENTIONS.md` updated with this week's lessons
- Runbook drift items (event_type='checkpoint') closed

Estimated total work: ~3 sessions for A1, 1 session for B1, 1 session for C1 (this doc + consolidation execution).
