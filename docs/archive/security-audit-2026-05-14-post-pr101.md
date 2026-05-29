# Security Audit 2026-05-14 — Post-PR-#101 Pass (B1)

Pass over admin work that landed after [docs/audit-2026-05-14-data-stability.md](audit-2026-05-14-data-stability.md). A1 merged 14 more commits (PRs #100–#103 + admin-lane series) without a B1 post-merge security check; the 2026-05-14 audit doc explicitly noted "No open B1 backlog tracked here" but was written before that follow-on work landed.

## TL;DR

- **1 SEC-HIGH** finding: `aq_venue_map` and `aq_performer_map` were created without RLS or policies and `anon` has full INSERT/SELECT/UPDATE/DELETE/**TRUNCATE** privileges. 712 + 863 rows of curated cross-source mapping data exposed via PostgREST anon today.
- **1 SEC-MED**-class finding (defense-in-depth): 11 SECURITY DEFINER functions added 2026-05-14/15 have `SET search_path` set but lack the §6 `current_user` body guard and explicit `REVOKE EXECUTE ... FROM PUBLIC` / `GRANT EXECUTE ... TO service_role` closure. Not an active vuln — all callers are `service_role` crons — but forecloses the future-caller drift case.
- **1 SEC-LOW** D2-lane note: `d2_cron_freshness()` is half-compliant — REVOKE done, guard missing. Out of A1's authoring scope.
- **All else clean**: 4 new views all have `security_invoker=true`; 6 of 8 new tables have proper RLS + policies; anon-callable surface is intentionally gated; no hardcoded secrets in cron schedules.

Recommended action: ship `supabase/migrations/<ts>_security_secdef_post_pr101_compliance.sql` covering both the §6 retrofit (11 fns) and the RLS gap fix (2 tables). Migration file authored by B1; prod-apply gated on operator per 2026-05-13 lockdown.

---

## Section 1 — Migration inventory

Range: `f47074e..origin/main` (HEAD `53e3a55`). 24 new migration files; security-relevant declarations:

| Migration | Adds |
|---|---|
| [20260515100000_vivid_pull_machinery.sql](../supabase/migrations/20260515100000_vivid_pull_machinery.sql) | 2 SECINVOKER fns (`vivid_orders_queue`, `vivid_orders_process`) |
| [20260515120000_tickpick_orders_ingest_from_apps_script.sql](../supabase/migrations/20260515120000_tickpick_orders_ingest_from_apps_script.sql) | 1 SECDEF fn (`tickpick_orders_ingest_from_apps_script`, shared-secret gated) + `get_app_secret` allowlist expansion |
| [20260515140000_phase15b_security_invoker_views.sql](../supabase/migrations/20260515140000_phase15b_security_invoker_views.sql) | Re-applies `security_invoker=true` to 7 phase-15b views regressed by CREATE OR REPLACE (R2 pattern fix) |
| [20260515150000_tickpick_order_status_and_wholesale_price.sql](../supabase/migrations/20260515150000_tickpick_order_status_and_wholesale_price.sql) | Schema-only + REPLACE of tickpick_orders_ingest_from_apps_script |
| [20260515170000_release_health_check_function.sql](../supabase/migrations/20260515170000_release_health_check_function.sql) | 2 SECINVOKER diagnostic fns (`release_health_check`, `migration_drift_check`) |
| [20260515180000_aq_event_map_short_id_pk.sql](../supabase/migrations/20260515180000_aq_event_map_short_id_pk.sql) | New table `aq_event_map` (✓ RLS+policy) + **1 SECDEF fn `aq_event_map_ingest` — §6 gap** |
| [20260515190000_aq_event_map_revert_pk_to_bigserial.sql](../supabase/migrations/20260515190000_aq_event_map_revert_pk_to_bigserial.sql) | Schema-only revert |
| [20260515200000_sg_broker_data_pipeline.sql](../supabase/migrations/20260515200000_sg_broker_data_pipeline.sql) | New table `sg_broker_pending` (✓ RLS+policy) + 4 SECINVOKER fns |
| [20260515210000_universal_aq_matcher_sweep.sql](../supabase/migrations/20260515210000_universal_aq_matcher_sweep.sql) | 1 SECINVOKER fn + **2 SECDEF fns (`create_system_aq_event`, `match_unmatched_orders_sweep`) — §6 gap** |
| [20260515220000_aq_venue_performer_maps.sql](../supabase/migrations/20260515220000_aq_venue_performer_maps.sql) | **2 new tables `aq_venue_map`/`aq_performer_map` — NO RLS, NO policies, anon has full ACL — SEC-HIGH** + 2 IMMUTABLE SECINVOKER helpers |
| [20260515230000_matcher_v2_tier_1_5.sql](../supabase/migrations/20260515230000_matcher_v2_tier_1_5.sql) | REPLACE of `match_unmatched_orders_sweep` (still SECDEF, still missing guard) |
| [20260515240000_listings_aq_linkage.sql](../supabase/migrations/20260515240000_listings_aq_linkage.sql) | **1 SECDEF fn `match_unmatched_listings_chunked` — §6 gap** + 2 new SECINVOKER views (`unified_listings`, `v_market_listings_by_event` — ✓) |
| [20260515250000_cron_policy_gate.sql](../supabase/migrations/20260515250000_cron_policy_gate.sql) | **3 SECDEF fns (`cron_should_fire`, `cron_last_fire`, `cron_resume_with_gate`) — §6 gap** |
| [20260515250001..250003] | Cron policy/cadence configuration only, no new code |
| [20260515260000_sg_tiered_polling.sql](../supabase/migrations/20260515260000_sg_tiered_polling.sql) | **2 SECDEF fns (`sg_classify_events`, `sg_priority_poll_tick`) — §6 gap** |
| [20260515270000_sg_classifier_v2_owned_via_tevo_xref.sql](../supabase/migrations/20260515270000_sg_classifier_v2_owned_via_tevo_xref.sql) | REPLACE of `sg_classify_events` (still missing guard) |
| [20260515270100_listings_delta_columns.sql](../supabase/migrations/20260515270100_listings_delta_columns.sql) | **1 SECDEF fn `listings_deltas_backfill_chunked` — §6 gap** |
| [20260515280000_tevo_to_sg_matcher.sql](../supabase/migrations/20260515280000_tevo_to_sg_matcher.sql) | 1 SECINVOKER fn + **1 SECDEF fn `sg_canonical_link_from_tevo_chunked` — §6 gap** |
| [20260515290000_release_health_check_format_fix.sql](../supabase/migrations/20260515290000_release_health_check_format_fix.sql) | REPLACE of `release_health_check` (SECINVOKER, no concern) |

Plus, in the same git range but pre-dating PR #100's audit doc by a few hours: [20260513230300_d2_cron_freshness_function.sql](../supabase/migrations/20260513230300_d2_cron_freshness_function.sql) — D2-lane SECDEF function, REVOKE done but guard missing. Flagged here, not in scope for retrofit (cross-lane to D2).

---

## Section 2 — SEC-HIGH: RLS gap on `aq_venue_map` and `aq_performer_map`

### Finding

`pg_tables.rowsecurity = false` on both. `pg_policies` rowcount = 0. `information_schema.role_table_grants` shows `anon` and `authenticated` each hold:

```
{INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER}
```

### Impact

- 712 rows in `aq_venue_map`, 863 rows in `aq_performer_map` of curated cross-source venue/performer canonical IDs.
- Anyone with the anon JWT (it's published to web clients via `/api/public/config`) can:
  - **READ** the entire canonical mapping (proprietary cross-source bridge data).
  - **INSERT/UPDATE** rows to corrupt matching (e.g., flip `tevo_venue_id` mappings so listings/orders route to wrong events).
  - **DELETE** specific rows to break matching for targeted events.
  - **TRUNCATE** to wipe all 1575 rows in one call — the matcher (`match_to_aq_event_id`, `aq_venue_short_id`) silently returns NULL until rebuilt.

### Root cause

[20260514183000_rls_deny_all_bulk.sql](../supabase/migrations/20260514183000_rls_deny_all_bulk.sql) (PR #97) applied RLS+deny-all to 121 internal/operational tables. [20260515220000_aq_venue_performer_maps.sql](../supabase/migrations/20260515220000_aq_venue_performer_maps.sql) created the two new tables ~24h later and missed the deny-all pattern. The sibling `aq_event_map` (in the previous-day migration `20260515180000`) has RLS+admin_only policy applied. The omission is local to migration `20260515220000`.

### Fix

Add to retrofit migration (Section 7):

```sql
ALTER TABLE public.aq_venue_map     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aq_performer_map ENABLE ROW LEVEL SECURITY;

CREATE POLICY admin_only ON public.aq_venue_map
  FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);
CREATE POLICY admin_only ON public.aq_performer_map
  FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);

REVOKE ALL ON public.aq_venue_map     FROM anon, authenticated;
REVOKE ALL ON public.aq_performer_map FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON public.aq_venue_map     TO service_role;
GRANT  SELECT, INSERT, UPDATE, DELETE ON public.aq_performer_map TO service_role;
```

This matches the pattern in [aq_event_map setup at 20260515180000_aq_event_map_short_id_pk.sql:67](../supabase/migrations/20260515180000_aq_event_map_short_id_pk.sql).

---

## Section 3 — SEC-MED (defense-in-depth): §6 SECDEF convention gaps

### Inventory (11 functions)

Confirmed against `pg_proc` (`prosecdef=true, has_guard=false, public_exec=true` on all 11):

| # | Function | Args | Migration | Latest replace |
|---|---|---|---|---|
| 1 | `aq_event_map_ingest` | `(jsonb)` | 20260515180000 | (none) |
| 2 | `create_system_aq_event` | `(text, text, text, timestamp with time zone, bigint)` | 20260515210000 | (none) |
| 3 | `cron_last_fire` | `(text)` | 20260515250000 | (none) |
| 4 | `cron_resume_with_gate` | `(text)` | 20260515250000 | (none) |
| 5 | `cron_should_fire` | `(text)` | 20260515250000 | (none) |
| 6 | `listings_deltas_backfill_chunked` | `(integer)` | 20260515270100 | (none) |
| 7 | `match_unmatched_listings_chunked` | `(integer, boolean)` | 20260515240000 | (none) |
| 8 | `match_unmatched_orders_sweep` | `(integer, boolean)` | 20260515210000 | 20260515230000 |
| 9 | `sg_canonical_link_from_tevo_chunked` | `(integer)` | 20260515280000 | (none) |
| 10 | `sg_classify_events` | `()` | 20260515260000 | 20260515270000 |
| 11 | `sg_priority_poll_tick` | `(integer)` | 20260515260000 | (none) |

All 11 have `SET search_path` correctly (the primary mitigation). All callers are crons running as `service_role` (verified against `cron.job` — see [Section 6](#section-6--cron-surface)), so the body guard would pass for them.

### Why retrofit anyway

§6 (PR #67/#68, adopted 2026-05-13) is belt-and-suspenders: search_path defends against schema-prepend injection, the body guard defends against accidental cross-role invocation, and REVOKE/GRANT defends against PostgREST anon discovery. Three independent defenses; today only one is in place.

The release-discipline.md §10 R2 pattern (PR #94/#92 sequencing) shows how grant gates can drift in either direction. Closing all three §6 elements now forecloses that class of regression.

### Fix

For each of the 11 functions, the retrofit migration:
1. `CREATE OR REPLACE FUNCTION ...` re-emits the current body with the standard guard prepended.
2. `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated;`
3. `GRANT EXECUTE ... TO service_role;`

Signatures must be preserved byte-for-byte (parameter names, types, defaults). See Section 7.

---

## Section 4 — Other findings (lower-severity / notes)

### 4.1 D2-lane half-compliance (SEC-LOW)

[`d2_cron_freshness()`](../supabase/migrations/20260513230300_d2_cron_freshness_function.sql) is SECDEF with `SET search_path = public, cron` ✓ and `REVOKE ALL ... FROM PUBLIC, anon, authenticated` ✓ + `GRANT EXECUTE ... TO service_role` ✓, but the body guard is missing.

The REVOKE is the primary mitigation (anon can't EXECUTE), so the guard is purely defense-in-depth here. D2 lane; recommend filing a PR comment for D2 to add the guard in their next pass. Not in scope for this retrofit migration.

### 4.2 Two coexisting overloads of `match_to_aq_event_id`

`pg_proc` shows two SECINVOKER overloads:

- `(text, bigint, text, text, timestamp with time zone, numeric, numeric)` — from [20260515210000](../supabase/migrations/20260515210000_universal_aq_matcher_sweep.sql)
- `(text, bigint, text, text, timestamp with time zone, numeric, numeric, bigint)` — added by [20260515230000](../supabase/migrations/20260515230000_matcher_v2_tier_1_5.sql) (the v2 with `p_source_venue_id`)

The v1 wasn't explicitly dropped. Both are valid Postgres overloads. Confirmed callers: only `match_unmatched_orders_sweep` and `match_unmatched_listings_chunked`, both of which call the v2 8-arg form. The v1 7-arg form is now dead code in prod.

Not security-relevant (both SECINVOKER, no escalation surface). Filed as a cleanup note for A1: drop the v1 overload to avoid future-reader confusion. Not retrofitted here.

### 4.3 Other tables: RLS coverage

Confirmed `rowsecurity=true` + ≥1 policy on: `aq_event_map`, `sg_broker_pending`, `tickpick_orders`, `tickpick_orders_pending`, `vivid_orders`, `vivid_orders_pending`. Clean.

### 4.4 New views

All 4 new views have `security_invoker=true` ✓:
- `unified_listings`
- `unified_orders`
- `v_aq_match_quality`
- `v_market_listings_by_event`

R2-class regression (CREATE OR REPLACE resetting security_invoker) actively monitored by `release_health_check().views.security_definer_views` — clean.

### 4.5 Anon-callable functions

Only `tickpick_orders_ingest_from_apps_script(jsonb, text)` is anon-callable (`anon_exec=true`). Intentional: gated by shared-secret body check against `APPSCRIPT_INGEST_SECRET` via `get_app_secret()`. Documented in [KANBAN.md security backlog](../KANBAN.md). Not §6 scope (different gating pattern). No action.

---

## Section 5 — Cron surface

All 5 active cron jobs that invoke the retrofit-set functions use the `cron_should_fire()` gating pattern and run as `service_role`:

| Job | Schedule | Calls |
|---|---|---|
| `match_unmatched_orders_sweep_hourly` | `22 * * * *` | `match_unmatched_orders_sweep(500, true)` |
| `sg_priority_poll_tick_1min` | `* * * * *` | `sg_priority_poll_tick(50)` |
| `listings_aq_backfill_overnight` | `2-14 4 * * *` | `match_unmatched_listings_chunked(100, true)` *(currently inactive — self-unscheduled on completion)* |
| `tickpick_orders_queue_30min` | `13,43 * * * *` | `tickpick_orders_queue(1)` *(SECINVOKER — not retrofit scope)* |
| `tickpick_orders_process_30min` | `15,45 * * * *` | `tickpick_orders_process()` *(SECINVOKER — not retrofit scope)* |

CREATE OR REPLACE preserves function `oid`. Cron commands reference functions by name and resolve at execution time → **no cron rescheduling needed after retrofit applies**.

---

## Section 6 — Secret allowlist

`get_app_secret()` allowlist (per [20260515120000](../supabase/migrations/20260515120000_tickpick_orders_ingest_from_apps_script.sql) and [20260513230400](../supabase/migrations/20260513230400_get_app_secret_add_tickpick_vivid.sql)) includes only documented entries: `TICKPICK_API_TOKEN`, `VIVID_API_TOKEN`, `APPSCRIPT_INGEST_SECRET`, `CRON_SECRET`, `EDGE_FN_ANON_JWT`. No orphans observed in vault references in the new migrations. Per release-discipline.md §7, a `vault_orphans` check is still a punch-list item — out of scope for this audit.

---

## Section 7 — Proposed retrofit migration

File: `supabase/migrations/<ts>_security_secdef_post_pr101_compliance.sql` (`<ts>` set at authoring time per [MIGRATION_CONVENTIONS.md](../MIGRATION_CONVENTIONS.md) §3 + B1's `*_security_*` naming).

**Scope**:
1. **Section A** — RLS + deny-all + GRANTs on `aq_venue_map` and `aq_performer_map` (Section 2 fix).
2. **Section B** — 11 × CREATE OR REPLACE FUNCTION re-emit with `current_user` guard prepended, plus REVOKE EXECUTE / GRANT EXECUTE TO service_role for each.

**Pattern reference**: [BOT_HIERARCHY.md §6](../BOT_HIERARCHY.md), [supabase/migrations/20260513230300_d2_cron_freshness_function.sql](../supabase/migrations/20260513230300_d2_cron_freshness_function.sql) (REVOKE/GRANT shape — body guard needs to be added per §6).

**Cron-safety**: confirmed in Section 5 — no rescheduling needed; existing `DO $body$` blocks unchanged.

**Lockdown compliance**: file authored to disk under B1's `supabase/migrations/*_security_*.sql` write surface per [LANE_DISCIPLINE.md §B1](../LANE_DISCIPLINE.md). Prod-apply via `apply_migration` requires explicit operator OK per CLAUDE.md "2026-05-13 lockdown" §1.

---

## Section 8 — Verification

| # | Step | Query / Action | Pass condition |
|---|---|---|---|
| 1 | Pre-baseline (already captured) | `SELECT * FROM public.release_health_check() WHERE status <> 'ok';` | Record current state. |
| 2 | RLS gap confirmed | `SELECT tablename, rowsecurity FROM pg_tables WHERE tablename IN ('aq_venue_map','aq_performer_map');` | Both `rowsecurity=false` today. |
| 3 | §6 gap confirmed | `SELECT proname, pg_get_functiondef(oid) ~ 'current_user NOT IN' FROM pg_proc WHERE proname IN (...list of 11...) AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname='public');` | All 11 show `false` today. |
| 4 | After operator applies retrofit | rerun queries 2 + 3 | Tables show `rowsecurity=true`; 11 fns show `has_guard=true`; `has_function_privilege('public', ..., 'EXECUTE')` = false. |
| 5 | Smoke harness re-run | `SELECT * FROM public.release_health_check() WHERE status <> 'ok';` | No new `warn`/`fail` rows vs. baseline. |
| 6 | Cron continuity | `SELECT jobname, active FROM cron.job WHERE jobname IN ('match_unmatched_orders_sweep_hourly','sg_priority_poll_tick_1min','tickpick_orders_queue_30min','tickpick_orders_process_30min');` then wait one tick. | All `active=true` post-apply; next firing succeeds (no auth-related failures in `cron.job_run_details`). |
| 7 | Negative test (optional) | As `coworker_readonly`: `SELECT public.match_unmatched_orders_sweep();` → expect permission denied. As anon: `INSERT INTO public.aq_venue_map(...) VALUES (...);` → expect deny. | Both deny. |

---

## Section 9 — Open items kicked back to lanes

### → A1
- Drop the dead v1 overload of `match_to_aq_event_id` (7-arg form) per Section 4.2. Cleanup, not security.

### → D2
- Add the `current_user NOT IN` body guard to `d2_cron_freshness()` per Section 4.1. PR comment from B1 to be filed alongside this retrofit PR.

### → Operator
- Authorize `apply_migration` for the retrofit file once landed.
- Decision on whether to backport the §6 guard convention into a CI-enforced check (e.g., a pre-commit hook that greps any new `SECURITY DEFINER` block for the guard pattern). Punch-list item P5 in [docs/release-discipline.md](release-discipline.md) covers this generically.

---

**Owner**: B1 (Security Manager)
**Filed**: 2026-05-14
**PR**: TBD (will be cross-referenced once opened)
