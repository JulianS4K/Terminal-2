# Anon-Callable Surface Inventory

**Owner**: B1 (Security Manager) · **Last full sweep**: 2026-05-15 · **Update cadence**: per-session sweep step 4 (see [docs/b1_operating_constraints.md](b1_operating_constraints.md))

Living inventory of every Postgres object reachable via the Supabase `anon` role. The per-session diff catches new exposures before they ship as data leaks.

## Inventory criterion

**Effective anon access** is what matters, not raw GRANTs:

- **Function**: `has_function_privilege('anon', oid::regprocedure, 'EXECUTE') = true` AND no body-level shared-secret or `auth.jwt()` gate.
- **Table**: `has_table_privilege('anon', 'public.<t>', 'SELECT') = true` AND (`rowsecurity = false` OR an active policy permits anon).

Tables with anon GRANT *and* RLS-restricted-to-`@s4kent.com`-authenticated policies (PR #115's Tier-1 set) are **not** effectively anon-accessible and are excluded from the active list below.

---

## Active findings (open, 2026-05-15)

| # | Severity | Object | Issue | Action |
|---|---|---|---|---|
| F-1 | SEC-HIGH | `cron_pause_state_20260514` (table) | `rowsecurity=false`, 0 policies, `anon SELECT GRANT` | File [B1-NEXT-7]. Operational data — likely unintentional miss when created during 2026-05-14 cron-pause. Recommend `ENABLE RLS` + admin_only deny-all. |
| F-2 | SEC-HIGH | `sg_event_priority_state` (table) | `rowsecurity=false`, 0 policies, `anon SELECT GRANT` | File [B1-NEXT-7]. Same pattern. SG broker pipeline state. |
| F-3 | SEC-HIGH | `sg_priority_policy` (table) | `rowsecurity=false`, 0 policies, `anon SELECT GRANT` | File [B1-NEXT-7]. SG priority tier config. |
| F-4 | SEC-MED | 11 SECDEF functions (AQ matcher set) | §6 guard missing | **Closed by PR [Terminal-2#110](https://github.com/JulianS4K/terminal-2/pull/110)** (merged 2026-05-15). Migration `20260515300000` ships the guard; operator-apply pending. |
| F-5 | SEC-MED | `_health_check_pg_net_errors()` (fn, added by PR #115) | §6 guard missing | File PR comment on #115 (cross-lane patch protocol). Diagnostic only — read-only body. |
| F-6 | SEC-MED | `get_broker_event_page(integer, integer)` (fn, added by PR #115) | §6 guard missing; body has `auth.jwt()` email gate so effectively gated | File PR comment on #115. Defense-in-depth retrofit. |
| F-7 | SEC-MED | `d2_cron_freshness()` (fn, 20260513230300) | §6 guard missing; REVOKE done | File [B1-NEXT-1]. Cross-lane to D2. |

---

## Section 1 — SECURITY DEFINER functions, anon-callable

These are the real privilege-escalation surface — SECDEF bypasses RLS for the executing user. Each must be either §6-compliant (guard + REVOKE) or body-gated by a shared secret / `auth.jwt()` check.

| # | Function | Args | Gating pattern | Notes |
|---|---|---|---|---|
| 1 | `aq_event_map_ingest` | `(jsonb)` | §6 retrofit pending (PR #110) | Bulk upsert into `aq_event_map` |
| 2 | `create_system_aq_event` | `(text, text, text, timestamptz, bigint)` | §6 retrofit pending (PR #110) | Synthetic AQ row creator |
| 3 | `cron_last_fire` | `(text)` | §6 retrofit pending (PR #110) | Read from `cron_gate_decisions` |
| 4 | `cron_resume_with_gate` | `(text)` | §6 retrofit pending (PR #110) | Cron schedule mutation — high-impact |
| 5 | `cron_should_fire` | `(text)` | §6 retrofit pending (PR #110) | Write to `cron_gate_decisions` |
| 6 | `listings_deltas_backfill_chunked` | `(integer)` | §6 retrofit pending (PR #110) | Batch UPDATE on listings_snapshots |
| 7 | `match_unmatched_listings_chunked` | `(integer, boolean)` | §6 retrofit pending (PR #110) | Cross-source matcher |
| 8 | `match_unmatched_orders_sweep` | `(integer, boolean)` | §6 retrofit pending (PR #110) | Cross-source matcher |
| 9 | `sg_canonical_link_from_tevo_chunked` | `(integer)` | §6 retrofit pending (PR #110) | SG↔TEvo link |
| 10 | `sg_classify_events` | `()` | §6 retrofit pending (PR #110) | SG priority tier reclassification |
| 11 | `sg_priority_poll_tick` | `(integer)` | §6 retrofit pending (PR #110) | SG broker pull executor |
| 12 | `_health_check_pg_net_errors` | `()` | §6 missing — F-5 above | Read-only diagnostic. Body queries `net._http_response`. PR #115. |
| 13 | `get_broker_event_page` | `(p_event_id integer, p_chart_hours integer)` | **Body-gated by `auth.jwt()->>'email'`** | D0 broker terminal RPC. PR #115. §6 guard still recommended (F-6). |
| 14 | `tickpick_orders_ingest_from_apps_script` | `(p_orders jsonb, p_shared_secret text)` | **Body-gated by shared-secret** (`APPSCRIPT_INGEST_SECRET` via `get_app_secret()`) | Apps Script ingest path. Intentional exception. |

**Intentional anon-callable, no body gate**: `release_health_check`, `migration_drift_check`, `audit_cross_source_health` are all SECINVOKER (not DEFINER) — they execute with caller's privileges, so anon-call yields anon-level data. Read-only diagnostics, no privilege-escalation surface. Listed under Section 4.

---

## Section 2 — Tables with raw anon ACL but RLS-gated (NOT effectively anon-readable)

These tables have anon `SELECT GRANT` at table level, but RLS policies deny effective access. They are listed here for tracking — if any policy ever changes, they could flip to anon-readable.

### Tier-1 RLS-gated to `@s4kent.com` authenticated (per A1 PR #115)

10 tables: `events`, `event_xref`, `sg_events_canonical`, `aq_event_map`, `aq_venue_map`, `aq_performer_map`, `performer_metadata`, `cron_policy`, `cron_gate_decisions`, `venue_assets`

### Other RLS-gated (deny-all or service-role-only)

121 tables covered by PR #97's `rls_deny_all_bulk` sweep plus per-table policies. Bulk operational data — orders, listings_snapshots, espn_*, weather_*, fred_*, evo_*, seatgeek_*, seatdata_*, tickpick_*, vivid_*, broker_xref, leads, etc.

Per-session sweep step 6 catches any new table that lacks RLS.

---

## Section 3 — Tables WITHOUT RLS (active finding)

3 tables exposed to anon SELECT with no RLS gate. See active findings F-1, F-2, F-3 above. Fix proposed in [B1-NEXT-7] (KANBAN.md).

| Table | Created in | Anticipated content |
|---|---|---|
| `cron_pause_state_20260514` | 2026-05-14 cron-pause snapshot (uncodified — search migrations) | Snapshot of paused cron jobs (`jobname, schedule, command, active`) |
| `sg_event_priority_state` | [20260515260000_sg_tiered_polling.sql](../supabase/migrations/20260515260000_sg_tiered_polling.sql) | SG poll cadence state per event |
| `sg_priority_policy` | [20260515260000_sg_tiered_polling.sql](../supabase/migrations/20260515260000_sg_tiered_polling.sql) | Tier configuration (interval_seconds, daily budgets) |

---

## Section 4 — Views (anon SELECT, security inheritance)

~124 public views are anon-readable. Views with `security_invoker=true` (the post-PR-#94/#95 sweep state) inherit the caller's RLS — so anon-call against a view of an RLS-gated table returns empty. SECURITY DEFINER views would bypass RLS and return data; the PR #94 sweep eliminated all such public views.

Per-session sweep step 7 catches any new view that lacks `security_invoker=true`.

Categories of currently-exposed views (informational, no active findings):
- **Audit / monitoring**: `v_cron_health`, `v_macro_indicators_health`, `v_pg_net_queue_health`, `v_one_to_one_health`, `v_event_data_freshness`, `v_dashboard_coverage`, `v_dashboard_freshness`
- **Public catalog**: `v_canonical_*`, `v_event_*`, `v_team_*`, `v_performer_*`, `v_macro_indicators_latest`, `v_market_listings_by_event`, `v_s4k_inventoried_events`
- **Cross-source mapping**: `entity_event_map`, `entity_performer_map`, `entity_venue_map`, `cross_source_coverage`, `cross_source_event_audit`, `team_xref`
- **Unified**: `unified_listings`, `unified_orders`, `unified_orders_by_event`
- **ESPN context**: `v_espn_*`, `espn_event_snapshot_latest`, `espn_injury_snapshot_latest`, `espn_team_snapshot_latest`
- **Other**: `retail_*` (storefront-facing), `broker_*` (broker terminal — note these inherit RLS from the new D0 Tier-1 policies)

---

## Section 5 — SECINVOKER public functions, anon EXECUTE GRANT

~190 public SECINVOKER functions have anon EXECUTE. These execute with caller's privileges, so RLS gates apply — they read/write only what anon can read/write. Most are operational helpers (matchers, computers, queue processors) that are effectively gated by RLS on the tables they touch.

**Subcategories** (informational, no active findings):
- **`pg_trgm` extension stdlib** (~30): `similarity*`, `word_similarity*`, `gin_*`, `gtrgm_*`, `show_trgm`, `strict_word_similarity*`, `set_limit`, `show_limit`. Pure SQL utilities — no privilege concern.
- **`unaccent` extension stdlib** (4): `unaccent*`. Pure SQL utilities.
- **Pure computational / classifier helpers** (immutable): `classify_*`, `extract_*`, `haversine_miles`, `map_tevo_*`, `normalize_*`, `_sec_*`, `tournament_*`, `aq_venue_short_id`, `aq_performer_short_id`. No DB access; no privilege concern.
- **Public-RPC wrappers** (`*_public`): `get_event_assets_public`, `get_event_listings_public`, `get_event_zones_public`, `get_events_by_performer_public`, `get_events_by_venue_public`, `get_performer_assets_public`, `get_performer_landing_public`, `get_venue_assets_public`, `submit_lead_public`. Storefront-facing — return retail-safe fields only. Periodically audit response payloads for leakage (see [B1-NEXT-6]).
- **Diagnostics anon-callable by design**: `release_health_check`, `migration_drift_check`, `audit_cross_source_health`, `get_chat_suggestion_chips`, `get_event_movers`, `get_performers_by_league`. Return read-only aggregates.
- **Triggers / system** (`trg_*`, `_alert_*`, `_ingest_*`, `_persist_*`, `tg_*`): trigger functions called by Postgres, not externally invokable.
- **Operational write/sweep fns**: `auto_*`, `backfill_*`, `compute_*`, `refresh_*`, `sync_*`, `sweep_*`, `*_process`, `*_queue`, `match_*`, `seatdata_*`, `nws_*`, `weather_*`, `evo_*`, `sg_*`, `tickpick_*`, `vivid_*`, `espn_*`, `tournament_*`, `fred_*`, `wiki_*`, `reddit_*`, `performer_*`, `venue_*`. Each writes to a specific table set. Anon calls would fail at table-level RLS deny. Worth a sample audit but no active concern.

**Note**: `match_to_aq_event_id` has two overloads (7-arg v1 and 8-arg v2). The v1 is dead code per Section 4.2 of [docs/security-audit-2026-05-14-post-pr101.md](security-audit-2026-05-14-post-pr101.md). Cleanup tracked in [B1-NEXT-2] (KANBAN.md).

---

## Section 6 — Edge function attack surface (separate inventory pending)

16 edge functions deployed (`supabase/functions/*/index.ts`):

`backfill-event-configurations`, `bulk-add-watchlist`, `chat`, `collect`, `collect-listings`, `crawl-espn-team-assets`, `crawl-venues-and-performers`, `espn-collect`, `espn-rosters`, `espn`, `match-sg-performers-to-tevo`, `seed-home-venues`, `tevo-perf-find`, `why-noaa-weather-alerts`, `wiki-collect`

Each was retrofitted with `x-cron-secret` enforcement (PR #57, 2026-05-11) using `supabase/functions/_shared/cron-auth.ts`. Per-function auth posture inventory deferred to [B1-NEXT-3] for a separate doc (`docs/edge_function_auth_inventory.md`).

---

## Section 7 — Update cadence

- **Per-session sweep step 4** runs the GRANT + RLS diff against this doc. New additions get flagged and added.
- **Per-session sweep step 5** runs the SECDEF §6 check. Any new SECDEF function without `current_user NOT IN` triggers a retrofit or PR comment.
- **Per-session sweep step 6** runs the table RLS check. Any new table without RLS triggers a fix migration.
- **Per-session sweep step 7** runs the view `security_invoker` check.
- **Full enumeration** runs at least weekly (or after any PR cluster ≥3 PRs that touch `supabase/migrations/`).

---

## Sweep SQL (reference)

For automation / verification:

```sql
-- SECDEF anon-callable check
SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS fn,
       (pg_get_functiondef(p.oid) ~ 'current_user NOT IN') AS has_guard,
       (pg_get_functiondef(p.oid) ~ 'auth\.jwt|p_shared_secret') AS body_gated
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.prosecdef
   AND has_function_privilege('anon', p.oid::regprocedure::text, 'EXECUTE')
 ORDER BY has_guard, body_gated, p.proname;

-- Tables anon-SELECT without RLS
SELECT t.tablename
  FROM pg_tables t
 WHERE t.schemaname = 'public'
   AND has_table_privilege('anon', 'public.' || quote_ident(t.tablename), 'SELECT') = true
   AND NOT t.rowsecurity
 ORDER BY t.tablename;

-- Views without security_invoker=true
SELECT v.viewname, c.reloptions
  FROM pg_views v
  JOIN pg_class c ON c.relname = v.viewname AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = v.schemaname)
 WHERE v.schemaname = 'public'
   AND (c.reloptions IS NULL OR NOT 'security_invoker=true' = ANY(c.reloptions))
 ORDER BY v.viewname;
```
