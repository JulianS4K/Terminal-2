# MIGRATION_CONVENTIONS.md

> **Doc version:** v1.0.0 · baseline 2026-05-28 (A1). Section-level version + bot-ref convention → [`README.md`](README.md) *Doc-writing rules*.

Authoritative reference for how migrations are authored, named, reviewed, and shipped across the Terminal-2 multi-bot environment. **Read this before writing any migration.** Read it again before merging one.

> **Roster note (2026-05-28):** the "lane" names below (audit lane, canonical, storefront, broadway) predate the current bot roster. **Production push authority is now A1 (sole pusher to `main`)** — see [`BOT_HIERARCHY.md`](BOT_HIERARCHY.md) for the canonical roster + push matrix. The migration *mechanics* in this doc remain current; only the lane→bot naming is historical.

---

## TL;DR

1. **Only the audit lane (now A1 — see [`BOT_HIERARCHY.md`](BOT_HIERARCHY.md)) pushes to production.** Other bots develop in preview branches and open PRs.
2. **Migrations are file-system ordered** by `YYYYMMDDHHMMSS_*.sql`. Bump by `+30` to `+50` on collisions, never `+1`.
3. **Single-writer rule per table.** The bot that introduced the table owns writes. Others read.
4. **Every migration declares its lane** in a standard header block (see §6).
5. **No production push without audit-lane review.** Period.

---

## 1. Environment policy (production push gate)

### Production = Supabase project `vrhrjrqzpsxxfrnchlxh` (`hzrizjeaxlqcxfrtczpq.supabase.co`)

| Environment | Who can write | How |
|---|---|---|
| **Production** | Audit lane only (this worktree's bot) | `apply_migration` MCP call, or merge to `main` GitHub branch (CI auto-deploys) |
| **Preview branches** | Any bot, any lane | Supabase database branch keyed to the bot's git branch name (`mcp__bccd...__create_branch`) |
| **Local sandbox** | Any bot | `supabase start` against a local container |

### Workflow for non-audit-lane bots

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. Bot creates feature branch in git                                 │
│    git checkout -b claude/<feature-name>                             │
│                                                                      │
│ 2. Bot creates matching Supabase preview branch                      │
│    mcp__bccd...__create_branch(name='claude/<feature-name>')         │
│                                                                      │
│ 3. Bot writes migration file in supabase/migrations/                 │
│    Header declares lane (see §6)                                     │
│                                                                      │
│ 4. Bot applies migration to PREVIEW branch only                      │
│    mcp__bccd...__apply_migration(branch_id=preview, ...)             │
│    Validates schema works, runs smoke queries                        │
│                                                                      │
│ 5. Bot opens GitHub PR with migration file                           │
│    Tags audit lane for review                                        │
│                                                                      │
│ 6. Audit lane reviews:                                               │
│    - Migration header (lane, tables touched, pre-reqs)               │
│    - Schema diff (no surprise column drops, no dangerous TRUNCATEs)  │
│    - Cross-bot collision check (timestamp, table writers)            │
│    - Cron + vault secret hygiene                                     │
│                                                                      │
│ 7. Audit lane merges PR → CI applies migration to PRODUCTION         │
│    Preview branch is reset/deleted post-merge                        │
└──────────────────────────────────────────────────────────────────────┘
```

### Hard rules

- **Non-audit-lane bots NEVER call `apply_migration` against the production project_id.** Use a branch_id.
- **Non-audit-lane bots NEVER call `execute_sql` writes against production.** Reads OK; writes only via reviewed migrations.
- **Audit lane verifies preview branch state before merging.** A PR that hasn't been applied to a preview branch is not reviewable.
- **Existing CI gates (`forbidden-paths-check.yml`, `sync-check.yml`) stay in force.** This doc supplements them, doesn't replace them.

### Emergency override

If the audit lane is unavailable and a production write is genuinely urgent (data corruption, security incident, paid feature broken):
1. Open a GitHub issue tagged `urgent-prod-write` with the proposed change
2. Wait for human (Julian) approval
3. Human applies the change directly
4. Audit lane backfills the migration file + retroactive review when available

**This path is for genuine emergencies only.** "I want to ship faster" is not an emergency.

---

## 2. Lane map (who owns what)

| Lane | Worktree | Tables / domains owned (writes) |
|---|---|---|
| **xref + macro** *(audit lane)* | `mystifying-lederberg-ea407b` | `event_xref` (W), `espn_event_date_lookup`, `espn_teams_canonical`, `performer_espn_team_xref`, `espn_scoreboard_pending`, `match_events_to_espn_tick()`, `v_event_xref_collisions`, `macro_indicators`, `macro_series_config`, `fred_pending`, all FRED + ESPN scoreboard ingestion |
| **canonical** | `audit-datasets-schemas-auoc3` | `canonical_external_ids`, `seatgeek_event_xref`, all drift triggers, `v_event_overlay_summary`, `audit_cross_source_health()`, SG candidate normalization, `v_event_sales_combined`, event/performer view wireframe SQL |
| **broadway** | `broadway-scraper-eChQ6` | `broadway_client.py`, scraper tests, `requirements.txt` Broadway entries (no DB writes currently — when they start, Broadway-prefixed xref tables only) |
| **storefront** | `eloquent-chatterjee-aaedf0` | `app.py`, `static/store/*`, `share_links` table + endpoints |

### Read-only access (everyone)

These tables are everyone's reads, single owner's writes:

| Table | Owner | Why others read it |
|---|---|---|
| `events` | TEvo ingest (audit lane) | Event metadata, joining everywhere |
| `performers` | TEvo ingest (audit lane) | Performer joins |
| `venues` | TEvo ingest (audit lane) | Venue joins |
| `listings_snapshots` | TEvo cron (audit lane) | Sales velocity, freshness |
| `orders` | TEvo cron + storefront | Cohort analysis, dashboard |
| `event_xref` | audit lane | Cross-source ID lookup |
| `canonical_external_ids` | canonical lane | Generalized cross-source lookup |
| `macro_indicators` | audit lane (FRED) | Regime context for any view |

If you find yourself wanting to write to a table you don't own, **stop** and open a coordination thread.

---

## 3. Migration filename convention

### Format
```
YYYYMMDDHHMMSS_<lane>_<short_description>.sql
```

- `YYYYMMDDHHMMSS` — 14-digit timestamp, UTC. The hour/minute portion is for ordering, not actual clock time.
- `<lane>` — short lane identifier. **Optional but encouraged** for readability:
  - `xref_*`, `macro_*` — audit lane (xref + macro)
  - `phase<N>_*`, `canonical_*` — canonical lane
  - `store_*`, `share_*` — storefront lane
  - `broadway_*` — broadway lane
- `<short_description>` — snake_case, descriptive

### Examples
```
20260510120000_in_db_event_matcher_v1.sql        ← audit lane (xref)
20260510120030_phase1_backfill_event_xrefs.sql   ← canonical
20260510120150_share_links.sql                   ← storefront
20260510130000_fred_macro_indicators_umcsent.sql ← audit lane (macro)
```

### Collision resolution

When two bots target the same timestamp:
- **Whoever flagged first owns the slot** (precedent set 2026-05-10).
- The second bot bumps by `+30` or `+50`. Use `+30` for a tight follow-up, `+50` to leave room for an interleaved migration.
- **Never bump by `+1`** (too tight, easy to collide on the next round).
- **Never bump by `+100`** unless you genuinely want a whole-hour gap (rare; the hour-spaced gaps are reserved for major schema phases).

### Free slots in the `20260510` band (current state)
```
120160-120190   open
120210-120290   open
120310-120390   open
120410-120490   open
120510-125900   open
130001-135900   open
140100+         open
```

**Always grep `supabase/migrations/` for your timestamp before pushing:**
```bash
ls supabase/migrations/ | grep "^20260510120"
```

---

## 4. Single-writer rule per table

The bot that introduces a table is its **sole writer**. Other bots can:
- ✅ `SELECT` from it
- ✅ Define triggers on it (e.g., canonical lane's drift triggers on `event_xref`) — fire on the writer's INSERTs/UPDATEs
- ✅ Reference it in foreign keys
- ❌ `INSERT` / `UPDATE` / `DELETE` / `TRUNCATE` it directly

**Why:** preserves a clean mental model of "who writes what when." If two bots write to the same table, neither can reason about what's there at any given moment.

### Triggers as the escape hatch

If lane B needs lane A's table to populate something in lane B's domain, lane B writes a **trigger on lane A's table** that fires on lane A's writes and propagates. The propagation logic lives in lane B (writes only to lane B's tables). This is the canonical lane's pattern — drift triggers on `event_xref` propagate to `canonical_external_ids` without canonical lane ever writing to `event_xref`.

### Exceptions (require coordination thread)

- **Adding a column** to a table you don't own: ask the owner. Owner adds it (in their own migration).
- **Backfilling rows** during a one-time data migration: coordinate with owner; ideally owner runs the backfill.
- **Schema-wide refactors** (e.g., split a table into two): the owner drives, others adapt.

---

## 5. Cron schedules

### Naming
Prefix every cron job with the owning lane's domain:
```
espn_*       audit lane (ESPN scoreboard ingestion)
fred_*       audit lane (FRED macro)
match_*      audit lane (xref matching)
canonical_*  canonical lane
broadway_*   broadway lane
store_*      storefront lane
collect_*    TEvo ingest (audit lane)
```

### Discipline

- **Don't `cron.unschedule` jobs you don't own.**
- **Don't `cron.alter_job` jobs you don't own** (especially `active := false`).
- **Document cadence in the migration header** so collisions at peak hours are auditable.
- **Avoid round-hour stampedes.** If your cron runs hourly, schedule on an offset minute (`5 * * * *`, `17 * * * *`) — see existing patterns.

### Existing cron landscape (as of 2026-05-10)

Cron scheduling policy + job ownership lives in [`CRON_HIERARCHY.md`](CRON_HIERARCHY.md) (the canonical cron owner). Update it when you add/remove a job.

---

## 6. Migration file header (required)

Every migration **must** start with a comment block in this format:

```sql
-- ============================================================================
-- Migration <timestamp> — <one-line summary>
--
-- Lane:     <xref+macro | canonical | broadway | storefront>
-- Touches:  <table_a (W), table_b (W), table_c (R)>
-- Pre-reqs: <prior migration timestamp(s), vault secrets, external services>
--
-- <Optional 2-5 line description of what this does and why>
-- ============================================================================
```

### Field guide

- **Lane:** the lane name from §2. Drives the audit-lane review checklist.
- **Touches:** every table the migration writes to (W) or reads from (R). Used for collision detection and impact analysis.
- **Pre-reqs:**
  - Other migrations this depends on (e.g., `Pre-reqs: 20260510110000 (espn_teams_canonical must exist)`)
  - Vault secrets that must be set (e.g., `Pre-reqs: vault.FRED_API_KEY`)
  - External services that must be reachable (e.g., `Pre-reqs: api.stlouisfed.org`)

### Example
```sql
-- ============================================================================
-- Migration 20260510130000 — FRED macro indicators (UMCSENT seed)
--
-- Lane:     xref+macro
-- Touches:  macro_indicators (W), macro_series_config (W), fred_pending (W)
-- Pre-reqs: vault.FRED_API_KEY (free signup at fred.stlouisfed.org)
--
-- Adds generic macro-economic indicator pipeline pulling from FRED.
-- Seeds with UMCSENT (Michigan Consumer Sentiment) — leads discretionary
-- spending 1-2 months, directly relevant to event-ticket demand.
-- ============================================================================
```

### Why this matters

A simple grep produces a complete ownership + dependency map:

```bash
grep -h "^-- Lane:" supabase/migrations/*.sql | sort | uniq -c
grep -h "^-- Touches:" supabase/migrations/*.sql
grep -B1 "FRED_API_KEY" supabase/migrations/*.sql
```

When a migration breaks production, the first 30 seconds of debugging is reading the header. Make those 30 seconds productive.

---

## 7. Vault secrets

### Naming
```
<DOMAIN>_<PURPOSE>
```

Examples:
- `FRED_API_KEY` — audit lane (macro)
- `ESPN_API_KEY` — audit lane (ESPN ingest)
- `TEVO_BROKER_TOKEN` — audit lane (TEvo)
- `BROADWAY_SCRAPER_USER_AGENT` — broadway lane
- `STRIPE_API_KEY` — storefront lane (when added)

### Rules

- **One secret per service per lane.** Don't share keys across bots even for the same upstream service — auditing access becomes impossible.
- **Document new secrets in the migration header** (`Pre-reqs: vault.YOUR_SECRET`).
- **Rotation policy:** keys rotate annually or on suspected compromise. Audit lane drives rotation.
- **Never check secrets into git.** If a secret leaks into a migration file, the audit lane rejects the PR and rotates the key.

---

## 8. Coordination triggers (when to flag the others)

**Open a coordination thread (or ping in chat) BEFORE any of:**

1. Adding a column to a table you don't own
2. Modifying a function you don't own
3. Disabling/modifying a cron you don't own
4. Creating a parallel data pipeline for something an existing pipeline covers
5. Touching `events`, `event_xref`, `performers`, `venues`, `orders`, `listings_snapshots`, `canonical_external_ids` (high-traffic shared tables)
6. Schema-wide refactors (renaming, splitting, dropping)
7. Anything that changes API contracts visible to retail / chat / store frontends

**The cost of coordinating is 5 minutes. The cost of drift is hours of cleanup. Always pick the 5 minutes.**

---

## 9. Review checklist (audit lane uses this)

> **See also**: [`docs/pr_governance.md`](docs/pr_governance.md) — A1-ratified 2026-05-16. Codifies one-concern-per-PR, size targets, squash-merge convention, branch-update protocol, lane sign-off requirements, and self-merge anti-pattern. Read the governance doc for principles; this checklist is the mechanical pre-merge audit.

Before merging any non-audit-lane PR, the audit lane verifies:

### File hygiene
- [ ] Migration filename follows §3 convention
- [ ] No timestamp collision with existing or pending PRs
- [ ] Header block present and accurate (§6)
- [ ] No secrets in the file

### Schema safety
- [ ] No `DROP TABLE` / `DROP COLUMN` without explicit migration plan + rollback path
- [ ] No `TRUNCATE` on shared tables (use scoped `DELETE` if needed)
- [ ] No `DROP CONSTRAINT` / `DROP INDEX` without justification
- [ ] All new tables have `created_at` / `updated_at` columns
- [ ] `ON CONFLICT` clauses on every UPSERT
- [ ] Foreign keys to existing tables don't introduce circular deps

### Cross-bot impact
- [ ] Tables touched match `Touches:` declaration
- [ ] Lane writes only to its owned tables (or via owner's API)
- [ ] No parallel pipeline for an existing capability
- [ ] Cron names prefixed correctly (§5)
- [ ] Vault secrets documented (§7)

### Preview branch validation
- [ ] PR author confirmed migration applied cleanly to a Supabase preview branch
- [ ] Smoke queries from PR description return expected results
- [ ] No errors in `pg_stat_statements` after the migration

### Sync-check
- [ ] `bin/sync-check.sh` passes locally on the PR's HEAD

If any check fails: comment on the PR with the failure, request fix. Don't merge.

---

## 10. Schema drift prevention

### Use upserts, not delete-then-insert
```sql
-- BAD: race window where row doesn't exist
DELETE FROM xref WHERE id = $1;
INSERT INTO xref (id, ...) VALUES ($1, ...);

-- GOOD: atomic, no gap
INSERT INTO xref (id, ...) VALUES ($1, ...)
ON CONFLICT (id) DO UPDATE SET ...;
```

### Don't TRUNCATE shared tables
The canonical lane's drift triggers will resync, but it's expensive and briefly breaks referential reads.

### Always have `created_at` / `updated_at` from day one
```sql
CREATE TABLE my_new_table (
  id BIGSERIAL PRIMARY KEY,
  ...,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Auto-update updated_at on row modification
CREATE TRIGGER my_new_table_updated_at
  BEFORE UPDATE ON my_new_table
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
```

(`trg_set_updated_at()` exists; if not, add it in the same migration.)

### Add `meta JSONB` for forward-compat
For tables you expect to evolve, leave a `meta JSONB` column you can stuff things into without a migration. Example: `event_xref.meta` already holds match-method debugging data without schema changes.

---

## 11. Operational overrides

Some scenarios need to break the rules. The audit lane decides; others propose.

| Scenario | Allowed? | Process |
|---|---|---|
| Hot-fix a broken cron | Audit lane: yes, immediate. Others: no, escalate. | Apply, then file migration to backfill the change |
| Backfill data after schema change | Audit lane: yes. Others: only against preview branch. | Migration file + verification queries |
| Disable a cron during incident | Audit lane: yes. Others: no. | `cron.alter_job(..., active := false)`, restore via migration when resolved |
| Rollback a bad migration | Audit lane only | Write a new migration that reverts; don't `git revert` an applied migration |

**Never `DROP TABLE` to "start over."** The data on the production table is real and other bots may depend on it.

---

## 12. Document maintenance

This document is owned by the audit lane. Updates require:
1. Audit-lane-authored PR
2. Brief mention of the change at the top of `KANBAN.md`
3. If lanes change: update [`BOT_HIERARCHY.md`](BOT_HIERARCHY.md) (the roster + push-authority owner) to match

If you (any bot) think this doc is wrong or incomplete, open an issue tagged `migration-conventions` — don't edit it yourself unless you're the audit lane.

---

## 12. Vault secrets — whitelist + rotation policy (added 2026-05-11 security chat)

Every secret used by any code path in this repo must live in **one of two places**:
1. **Supabase vault** (`vault.secrets`) — preferred; rotation is one SQL call, no migration cycle, no env redeploy.
2. **Railway / Supabase Edge Function env vars** — for things the runtime needs at boot before it can talk to Postgres (the bootstrap secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `CRON_SECRET`).

NEVER place a secret directly in repo source (this includes migration DDL, KANBAN/AGENTS notes, edge function code, HTML, `.env.example` with real values).

### 12.1 The `get_app_secret` whitelist (single source of truth)

`public.get_app_secret(name)` and `public.upsert_app_secret(name, value)` are SECURITY DEFINER + service-role-only. Both enforce a hardcoded **whitelist** of allowed secret names. To add a new secret you must:

1. Modify the whitelist constant inside both functions (additive — never remove a name without auditing callers).
2. Seed the secret via `vault.create_secret(value, name)` or `upsert_app_secret(name, value)`.
3. Add a row to the `vault.secret_metadata` view (see §12.3).
4. Document in this file under §12.4.

### 12.2 Rotation procedure

```sql
-- 1. Generate a new value (out-of-band, do NOT log it).
-- 2. Update vault:
SELECT vault.update_secret(s.id, '<new value>')
FROM vault.secrets s WHERE s.name = '<SECRET_NAME>';
-- 3. If the secret is also pinned to an env var (e.g. CRON_SECRET):
--    - railway variables --set "<NAME>=<new value>"
--    - supabase secrets set <NAME>="<new value>"
-- 4. Update the metadata view (§12.3) so the next audit shows fresh rotation.
-- 5. Bounce any worker that caches at boot (FastAPI on Railway redeploys automatically).
```

**Never rotate by inserting a new row with the same name** — `vault.secrets.name` is unique, and the helpers read by name. Always `update_secret`.

### 12.3 Audit query

A migration should land a `vault.secret_metadata` view (or table if vault doesn't allow views over `secrets`) of the shape:

```sql
CREATE OR REPLACE VIEW public.v_vault_secret_metadata AS
SELECT
  s.name,
  s.created_at,
  s.updated_at,
  m.owner_lane,
  m.last_rotated_at,
  m.notes
FROM vault.secrets s
LEFT JOIN public.vault_secret_metadata m ON m.name = s.name;
GRANT SELECT ON public.v_vault_secret_metadata TO service_role;
-- DO NOT GRANT to anon / authenticated / coworker_readonly.
```

(Migration to land this is a follow-up — tracked in KANBAN as `[SEC-LOW] Document get_app_secret whitelist`.)

### 12.4 Current whitelist (as of 2026-05-11)

| Secret name | Owner lane | Reader | Purpose |
|---|---|---|---|
| `CRON_SECRET` | xref+macro | app.py + edge fns + cron jobs | Cron-driven endpoint auth |
| `EDGE_FN_ANON_JWT` | xref+macro | cron jobs | Bearer auth for edge fn invocation |
| `SEATDATA_API_KEY` | canonical | seatdata_client | Upstream API auth |
| `TEVO_API_TOKEN` | canonical | evo_client | Upstream API auth |
| `TEVO_SECRET` | canonical | evo_client | Upstream API auth |
| `SEATGEEK_API_TOKEN` | canonical | seatgeek_client | Upstream API auth |
| `FRED_API_KEY` | xref+macro | macro fn | Upstream API auth |
| `anthropic_api_key` | canonical | chat edge fn | LLM auth |

Adding a new entry requires both the whitelist update AND a row in this table (same migration).

---

## 13. Quick reference card

```
Production push     → audit lane only
Migration timestamp → YYYYMMDDHHMMSS, bump +30/+50 on collision
Filename            → <timestamp>_<lane>_<desc>.sql
Header              → Lane / Touches / Pre-reqs (mandatory)
Single-writer       → owner of table writes; others read or trigger
Cron prefix         → <lane>_*  (espn_, fred_, canonical_, store_, broadway_)
Vault secret        → <DOMAIN>_<PURPOSE>, one per service per lane
Coordinate before   → touching shared tables, parallel pipelines, schema refactors
Review checklist    → §9 before any merge
Emergency override  → tag `urgent-prod-write`, human approval, audit-lane backfill
```

---

## 14. Landmark migration log (don't re-do shipped work)

> Migrated here from `PROJECT_BIBLE.md §9` (2026-05-28) to keep the per-session playbook lean. This is the durable, curated record of migrations that shipped meaningful schema/behavior changes — **check it before authoring** to avoid re-doing work that already landed. It is **not** auto-generated: `CHANGELOG.md` (owned by release-please, generated from conventional commits) is the machine record; this appendix is the hand-curated landmark subset with the "why." A1 appends a row when a landmark migration lands.

| Date | Migration | Effect |
|---|---|---|
| 2026-05-13 | cron policy gate | 4-stage conservation (budget/interval/work-check/window) |
| 2026-05-14 | universal AQ matcher | 4-tier `match_to_aq_event_id` + `create_system_aq_event` |
| 2026-05-14 | tiered polling | `sg_event_priority_state` + HOT/WARM/COOL/COLD tiers |
| 2026-05-15 | `get_broker_event_page` v1 RPC | D0 Phase 1 Path C foundation |
| **2026-05-16** | 20260516030000 | D0 Phase 2a prep: cancelled-filter + `tevo_event_id` col + `_v_d0_event_index` view |
| 2026-05-16 | 20260516040000 | Resume `listings_aq_backfill_overnight` cron |
| 2026-05-16 | 20260516050000 | `get_broker_event_page_v2` RPC (7 new keys, 185ms) |
| 2026-05-16 | 20260516060000 | SG `sg_event_id` indexes (perf for v2) |
| 2026-05-16 | 20260516070000 | NFL ESPN→TEvo→AQ→SG bridge + v2 RPC fallback fix |
| 2026-05-16 | 20260516080000 | Multi-sport bridge (MLB/MLS/WNBA/NBA/NHL) |
| 2026-05-16 | 20260516090000 | `espn_scoreboard_queue` default 90d → 270d |
| 2026-05-16 | 20260516100000 | `evo_orders` event-mapping columns (tevo_event_id + aq_short_event_id) + backfill |
| 2026-05-16 | 20260516110000 | NEW RPC `refresh_sg_broker_sales_event_metrics` + hourly cron; populates `seatgeek_event_metrics.sold_*` from `seatgeek_sales_snapshots` |
| 2026-05-16 | 20260516120000 | 3 analytics views: `v_event_sales_velocity`, `v_event_sales_metrics_filtered`, `v_event_price_arbitrage` |
| **2026-05-17** | 20260517160000 | **sg_broker_{listings,sales}_process bounded drain** — added `p_limit int DEFAULT 50` + lifted aq_event_map + seatgeek_event_xref into LEFT JOIN (drops per-row correlated subqueries). New rows born with `tevo_event_id` populated where xref exists. Unscheduled 30-min variants (redundant with 1-min priority). Drains 50 pendings in ~5s; was timing out at 2min draining unbounded. |
| 2026-05-17 | 20260517160001 | Partial indexes `(*_prev_*_null_idx)` on `listings_snapshots` + `seatgeek_listings_snapshots` — fixes the seq-scan in `listings_deltas_backfill_chunked` that A1 PR #189 didn't address. Backfill of 15 events now <1s (was 5min timeout). |
| 2026-05-17 | 20260517160002 | `match_listings_to_sg_tick` narrow + indexes — D2's bot_chat 225 sketch shipped: window 24h→6h, `ROW_NUMBER()` uniqueness instead of triple `NOT EXISTS`, helper indexes. 591ms vs prior 5min timeout. |
| 2026-05-17 | 20260517160003 | `sweep_all_expired_pg_net_pending` now covers `sg_broker_pending` + one-shot drain of 1,595 zombies (orphaned by `net._http_response` prune). |
| 2026-05-17 | 20260517160004 | Hotfix: drop legacy 0-arg overloads of `sg_broker_{listings,sales}_process`. Mig 20260517160000's `DEFAULT 50` addition created an overload not a replacement; cron `SELECT fn()` resolved ambiguously. Same class as A1 bot_chat 258 lesson. |
| 2026-05-17 | 20260517260000 | **SG broker-listings event metrics** — 18 new cols on `seatgeek_event_metrics`: `listings_all_*` (full firehose) + `listings_owned_*` (`is_broker_owned=true` subset), both from `broadcast_price`. New `refresh_sg_broker_listings_event_metrics(p_max_events int)` hourly cron @ :47. Companion to PR #161 sales-side @ :17. Also DROP NOT NULL on `tevo_event_id` to allow SG-only events. |
| **2026-05-18** | 20260518010000 | **event_sentiment cron**: schedule existing `backfill_event_sentiment(200)` @ :15,:45 via cron_should_fire gate. Fn existed since mig 20260509130000, never had a cron. |
| 2026-05-18 | 20260518020000 | **event_competitors cron re-schedule**: re-schedule `refresh_event_competitors()` @ :40 hourly (was scheduled in mig 20260509350000 and lost). Sparse coverage by-design — only events with 20mi/24h venue neighbors. |
| 2026-05-18 | 20260518030000 | **event_section_row_snapshots batch + cron**: new `rollup_event_section_row_batch(p_max_events int)` wrapper around existing single-event `rollup_event_section_row` (mig 20260512100150). Hourly cron @ :03. Writes source=tevo only; SG mirror pending future PR. |
| 2026-05-18 | 20260518040000–040004 | **cost_* reader migration (5 readers)**: `v_event_price_arbitrage` + `v_event_full_v2` + `v_event_velocity_windows` + v2 RPC + v3 RPC all swap `cost_*` → `listings_all_*` (or `listings_owned_*` for arbitrage). Payload key names also renamed. |
| 2026-05-18 | 20260518050000 | **cost_* columns DROP** + retire `compute_seatgeek_event_metrics` (legacy SellerDirect-only populator). 8 deprecated cost_* cols removed from `seatgeek_event_metrics`. |
| 2026-05-18 | 20260518060000 | **event_metrics owned distribution DDL**: ADD COLUMN `owned_p25/p75/p90` numeric. Writer (Python app.py event-processor) is cross-lane — bot_chat handoff posted. Cols sit at NULL until writer-side ship. |
| **2026-05-19** | 20260519000000 | **D0 weather localized RPC**: `get_event_weather_localized(p_event_id)` returns venue-localized forecast (`v_event_weather_with_fallback`) + NWS alerts filtered to event's UGC zones (`v_event_nws_alerts`). Replaces v3 RPC's global-alert behavior. Email-gated. |
| 2026-05-19 | 20260519010000 | **D0 SG zones/splits RPC**: `get_event_sg_zones_splits(p_event_id)` per-section rollup (min/median/max broadcast_price + listings + tickets) + per-quantity-bucket splits (singles/pairs/triples/quads/five_plus) over 24h deduped SG listings. Bridge via `seatgeek_event_xref`. Email-gated. |
| 2026-05-19 | 20260519100000 | **SG sales DISTINCT ON view cleanup**: 4 views (`seatgeek_event_latest`, `unified_orders`, `v_aq_match_quality`, `v_orphan_seatgeek_data`) were aggregating without DISTINCT ON sg_sale_id, silently 11–23× overcounting. Rebuilt with proper dedup. 2 dependents (`unified_orders_by_event`, `order_status_coverage`) recreated unchanged. Spot-check: event 3091415 sales_count went 8,431 → 368; unified_orders sg_sales rows went 1.82M → 121K. |
| 2026-05-19 | 20260519110000 | **SG broker 429-aware pipeline**: processors set `sg_broker_pending.rows_persisted = -429` (re-queueable) vs `-1` (terminal failure) vs `>=0` (success row count). 429 rows auto-retry on next firing instead of staying terminal. Sentinel feeds the 429 monitoring views in mig 130000. |
| 2026-05-19 | 20260519120000 | **SG priority crons 1min→5min**: `sg_priority_poll_tick_5min`, `sg_priority_listings_process_5min`, `sg_priority_sales_process_5min` renamed with staggered minute offsets. Reduces pg_cron load + 429 collision risk. Tier policy (240s/300s/1800s) still governs per-event cadence; cron just wakes the driver. |
| 2026-05-19 | 20260519130000 | **SG broker 429 monitoring protocol**: `v_sg_broker_429_health` (hourly pct_429 rollup over 24h), `v_sg_broker_429_starved_events` (events 429'd 3+ times with no recent success), `check_sg_broker_429_health()` with hysteresis-protected bot_chat flag @ pct_429 > 15%. 15-min cron `sg_broker_429_health_check_15min`. |
| **2026-05-19** | 20260519140000 | **🔥 SG broker burst-size emergency hotfix (PR #228)**: caps burst to 8 events/call on `sg_broker_listings_queue` + `sg_broker_sales_queue` (3+3 polls on `sg_priority_poll_tick`) — under SG's 10-token bucket. Drops broken `PERFORM pg_sleep(0.9)` calls (no-op given pg_net async dispatch — see §3 landmine + §7 macro). New schedules: listings `*/5`, sales `2-57/5`, poll_tick `4-59/5`. pct_429 went 70.7% (02:00 hour) → 0.0% on every firing 02:50 onward. Sustained 0.73 req/sec << 1.25 req/sec quota. |
| 2026-05-19 | 20260519150000 | **D0 chart expansion RPC (PR #237)**: `get_event_chart_extended(p_event_id, p_chart_hours DEFAULT 168, p_espn_home_team text, p_espn_away_team text)` returns 5 SG-side series (listings_median/owned_median/listings_count/sales_median/sales_count over adaptive 15min..1d buckets) + 2 ESPN annotation arrays (injuries LAG(status) per athlete league-scoped; game_state LAG(status_short) per espn_event_id). Auto-resolves home/away from `espn_event_date_lookup` (forward-look) → `espn_event_snapshots` (gameday) when not passed. SECDEF + email gate. Landmine surfaced: `espn_team_id` collides cross-league (id=28 = MLB + NHL); RPC scopes by `espn_league`. Codified in §3 + §4. Latency 308ms warm @ 7d. |
| 2026-05-19 | _(app code, no migration)_ | **D1 storefront movers reshape (PR #275)**: `/api/store/movers` response shape changed from `{events, rest}` (single strip + grid + label-bucket round-robin from PR #273/#274) to **4 themed-slider arrays**: `moving_fast` (SG sales ≥10 OR TEvo d24h ≤ -50), `price_drops` (retail_min < 0.7× SG median), `climbing` (TEvo `getin +5%` AND d24h<0, OR SG median +5% AND listings -5%), `specials` (`v_event_holidays` window match OR `v_rivalry_events` match, gated `owned > 100`). First 3 sections gate `owned > 50`. `_compute_movers` builds one candidate pool; each section filter is independent (event can appear in 0-2 sections). Label-bucket helpers (`_movers_compute_labels`, `_round_robin_pop_by_label`, `_LABEL_PRIORITY`, etc.) retired. v_rivalry_events dedupe rule codified in §3. |
| **2026-05-20** | 20260520400000 | **Featured-pricing 10-min cron (PR #288)**: `collect_listings_featured_refresh(p_max_events int DEFAULT 50)` + cron `collect-listings-featured-10min` (`3-53/10`). Refreshes TEvo `/v9/ticket_groups` for NYC venue + `owned>100` + 24h–90d events (superset of the storefront Featured rail) every 10 min, fixing the ~6h–multi-day pricing staleness from the twice-daily windowed crons. Round-robins oldest-`captured_at`-first, skips <9min-fresh + 0-24h events. Writes land in `event_metrics`; matview `latest_event_metrics_refresh_5min` (@`:2`) makes them visible. ~5,760 extra TEvo calls/day. |
| 2026-05-20 | 20260520410000 | **`compute_event_breakdowns` non-fatal (PR #289)**: self-caps zone+section steps at 6s (under the 8s `authenticator` ceiling), traps **`query_canceled` explicitly** (bare `WHEN OTHERS` misses 57014 — see §3 landmine), soft-fails a slow step → returns status jsonb instead of erroring. Stops the false 502s on heavy events (`collect-listings` calls this AFTER pricing persists; the RPC timeout was 502-ing pulls whose pricing already succeeded). |
| 2026-05-20 | 20260520420000 | **Breakdowns backfill re-enable + extend (PR #290)**: re-enables `zone-backfill-isolated-10min` cron + upgrades `backfill_stale_zone_metrics` to recompute BOTH zone+section (was zones only), detect staleness via the `latest_event_metrics` matview (not an 8M-row `listings_snapshots` scan), and trap `query_canceled`. Out-of-band catch-up for heavy events that soft-fail the inline 6s RPC. **Known gap**: the heaviest events (1300+ listings) exceed even the 90s cap — `compute_event_zone_metrics`'s per-row `match_performer_zone()` LATERAL needs dedup optimization (tracked, KANBAN A1-OPS-2). |
| **2026-05-22** | 20260520120000 | **D4/Exos phase-1 — APPLIED to prod 2026-05-22** (B1 sign-off PR #304). `exos_*` orgs+events schema (profiles/orgs/org_secrets/memberships/invites/events/ticket_tiers/discount_codes + `bridge_event_xref`). Deny-by-default RLS, all 9 tables RLS-enabled; base-table grants REVOKE'd from anon + re-GRANT CRUD to authenticated (own-org only per RLS). Cross-org browse via `exos_public_*` VIEWs. Org bootstrap via `exos_create_org()` SECDEF. 0 rows — schema ready, data cut-over pending. |
| **2026-05-22** | 20260520130000 | **D4/Exos phase-2 — APPLIED to prod 2026-05-22** (B1 sign-off PR #304). `exos_tickets`/`exos_transfers` + check-in + scan-reject audit logs + 6 write-path SECDEF RPCs (mint/check-in/transfer/cancel/claim/void). Atomic tier-claim closes oversell; atomic status-flip closes double-scan. All 8 write-path RPCs: anon-EXECUTE revoked (mig 20260520230000 same day). 0 rows — ready for first mint. See §8 D4 write-path recipe. |
| **2026-05-22** | 20260520200000 | **SG broker 60d+ polling — APPLIED (PR #251)**. `sg_events_canonical.last_60d_pulled_at` column + `sg_broker_60d_plus_{listings,sales}_queue(p_max_events int DEFAULT 8)`. 4 crons: `sg_60d_listings_morning` / `sg_60d_sales_morning` (UTC 4-9, ~576 events/day each) + `sg_60d_listings_afternoon` / `sg_60d_sales_afternoon` (UTC 17-19, ~288 events/day each). Round-robins oldest-`last_60d_pulled_at`-first; drains via existing priority process crons. Closes the 60d+ gap: Yankees-Mets/Dodgers/Red Sox (35 games had 0 SG data before). 98.8% event coverage within 24h. |
| **2026-05-23** | 20260520140000 | **D4/Exos phase-3 — org follow graph — APPLIED (PR #308, B1-cleared)**. `exos_org_follows(follower_uid, org_id)` PK + `exos_orgs.{description, followers_count}` + `exos_public_orgs` view refresh (adds bio + count). `exos_follow_org` / `exos_unfollow_org` SECDEF RPCs — idempotent `ON CONFLICT DO NOTHING`, counter updated atomically only on real change. anon REVOKE'd from table; SELECT granted to authenticated. |
| 2026-05-23 | 20260520150000 | **D4/Exos phase-4 — media storage bucket — APPLIED (PR #308, B1-cleared)**. `exos-media` public bucket (5 MB cap). SVG excluded — SVG carries executable script; on a public bucket a direct object URL executes in the storage origin (hosted XSS, B1 SEC-MED bot_chat #438). Path-scoped RLS: `event-images/{uid}/…` → own-uid gate; `org-logos/{orgId}/…` → org-membership gate. Update/delete limited to object owner. |
| 2026-05-23 | 20260520160000 | **D4/Exos phase-5 — transactional mail queue — APPLIED (PR #308, B1-cleared)**. `exos_mail` table (RLS on, zero client policies — service_role drainer only). `exos_queue_mail(p_template, p_ref_id)` SECDEF RPC server-derives `to_email` + body from the related record — open relay closed (B1 SEC-HIGH bot_chat #438, commit 3dc943f fixed 5 column/role refs). 5 templates: transfer-initiated/claimed, org-invite, event-cancelled/updated. Mail rows land as `status='pending'`; drainer (edge fn + email provider) is the next D4 milestone. |
| 2026-05-23 | _(app code, no migration)_ | **D4/Bridge blank-app fix (PR #316)**: previous `static/bridge/` builds had `VITE_SUPABASE_URL`/`VITE_SUPABASE_ANON_KEY` unset at build time — Supabase client initialised with empty strings, app rendered blank. Rebuilt with prod keys baked in via `d4_bridge/.env.local` (gitignored). **Landmine**: these Vite env vars must be present in `.env.local` whenever a new Bridge build is cut. |
| 2026-05-23 | _(app code, no migration)_ | **Bridge as 4th hub surface (PR #318)**: `static/home/index.html` gets a Bridge card (violet `#c084fc`, always unlocked — Bridge handles own auth). Grid updated 3-col → 2×2. `static/home/home.js` shows a soft note when signed out; hides it when any session exists. |
| 2026-05-23 | _(app code, no migration)_ | **Railway as Bridge primary host (PR #319)**: Bridge card now links to `/bridge/` (same Railway origin) instead of the external Render URL. Same-origin `localStorage` means the hub's Supabase session auto-carries-over to Bridge — one sign-in for all four surfaces. `app.py` route comment updated. |
| 2026-05-23 | 20260523120000 | **D4/Bridge Realtime multi-lane check-in + SW scope fix (PR #322)**: `exos_event_checkins` added to `supabase_realtime` publication (idempotent). `OrganizerCheckIn` subscribes to `postgres_changes` INSERT — remote check-ins propagate to all door lanes in ~1s (RLS-gated to org staff, closes double-admit race D4-OPS-10). Reconnect re-pull (offline→online) closes offline gap. SW `BASE` now derived from `self.location.href` — `/bridge/` prefix handled correctly. manifest.json paths all prefixed. CSV voided label fixed. Load harness validated: 6-lane stampede on 50 tickets → 0 double-admits. |
| **2026-05-24/25** | 20260523130000–20260524160000 | **D4 free-first batch — APPLIED to prod (A1 session 2026-05-25).** 10 migrations in dependency order: |
| | 20260523130000 | **Mail drainer schema**: `exos_mail` adds `sending` status + `attempts`/`claimed_at`/`last_attempt_at` cols + `exos_mail_claimable_idx`. `exos_mail_claim_batch(p_limit, p_max_attempts)` + `exos_mail_mark(p_id, p_ok, p_error, p_max_attempts)` — service_role-only, FOR UPDATE SKIP LOCKED for concurrent-safe drain. |
| | 20260523150000 | **Event-level oversell cap**: `exos_events.total_tickets` int (0 = uncapped). `exos_mint_tickets` enforces cap before minting. |
| | 20260523160000 | **Server HMAC barcode verify**: `exos_check_in_ticket` upgraded to 4 args (adds `p_event_id uuid`, `p_barcode_payload text DEFAULT NULL`). When payload present, verifies rotating-QR HMAC server-side via `extensions.hmac()` with ±2-bucket tolerance — rejects forged/expired QRs before the DB write. |
| | 20260523180000 | **Per-person purchase limits**: `exos_assert_purchase_limit(p_event_id, p_buyer, p_qty)` pre-check (raises on breach). `exos_mint_tickets` superset: enforces tier cap + event cap + purchase limit atomically; admin/service-role bypasses all caps. |
| | 20260523200000 | **Growth primitives** (applied modified — `exos_distribution_listings` ALTER skipped, dormant table): `exos_orgs.marketing jsonb` (social handles, pixels, shareImageUrl); `exos_redeem_discount_code(p_event_id, p_code)` → validity + type + unlock tier IDs; `exos_announce_to_followers(p_event_id)` → bulk-queues `event-announce` mail to all org followers (staff-gated, published events only). |
| | 20260523210000 | **Ticket-issued mail**: `exos_queue_ticket_issued(p_ticket_id uuid)` → queues purchase-confirmation `ticket-issued` mail to owner. Extends `exos_mail_template_check` with `ticket-issued`. Caller must be owner OR org staff. |
| | 20260523220000 | **Notify holders**: `exos_notify_event_holders(p_event_id, p_template)` → bulk-queues `event-cancelled` or `event-updated` to all non-voided ticket holders (org staff / admin only). |
| | 20260523230000 | **Issue to email**: `exos_issue_ticket_to_email(p_event_id, p_tier_id, p_recipient_email, p_qty, p_order_ref)` → looks up or creates Supabase user by email, mints `p_qty` tickets, queues confirmation. Idempotent on `order_ref`. Admin / org staff only. |
| | 20260524150000 | **Public marketing view**: `exos_public_orgs` refreshed to expose `marketing` jsonb (social handles + pixel IDs + shareImageUrl). Anon-readable. |
| | 20260524160000 | **Security hardening**: `exos_touch_updated_at()` trigger fn pinned `search_path = public, pg_temp` (Supabase advisor: `function_search_path_mutable`). `exos_has_org_role` anon-EXECUTE revoked via `REVOKE FROM anon, PUBLIC` (Supabase advisor: `anon_security_definer_function_executable`). Internal RLS/SECDEF callers unaffected. |
| 2026-05-24/25 | _(edge fn)_ | **`exos-mail-drain` deployed** (v1, ACTIVE, `verify_jwt=false`): reads `exos_mail` claim batch → Resend API → `exos_mail_mark`. Cron `exos-mail-drain-2min` (`*/2 * * * *`) work-check-gated via `cron_policy.work_check_sql`. ⚠️ Awaiting operator: `RESEND_API_KEY` + `EXOS_MAIL_FROM` secrets in Supabase edge-fn dashboard. |
| 2026-05-25 | _(app code, no migration)_ | **static/bridge rebuild**: `d4_bridge/` rebuilt locally and synced to `static/bridge/` — captures PRs #336 (consent banner basename + spinner), #338 (CreateEvent doors→show/end auto-fill), #339 (back-camera scanner + wallet QR timer). Render now serves current bundle; Railway redundant. |
| **2026-05-25** | _(app.py, no migration)_ | **Camera Permissions-Policy for `/bridge` (PR #340)**: `app.py` shell now includes `camera` in the `Permissions-Policy` response header for the `/bridge/*` route, enabling the door-scanner's `getUserMedia` camera prompt. Without it, the browser silently blocked the API regardless of FE code. |
| **2026-05-25** | _(FE only, needs rebuild)_ | **D4/Bridge FE batch — PRs #341–342** (static/bridge must be rebuilt+deployed): **#341** — wallet QR stamp `REDEEMED` renamed to **`ENTERED`** with "Scanned \<time\>" subline (fallback "SCANNED") on both `TicketDetail` + `WalletPass`; wording only, mute+auto-refresh unchanged. **#342** — (a) TRANSFER link disabled (greyed, with reason label) for `used`/`voided`/`pending` tickets — UX mirror of server-side `exos_create_transfer` `status='active'` guard; (b) "Inside Venue" counter on `OrganizerCheckIn` now shows `countEventCheckins(eventId)` (realtime scanned-in head-count via existing Realtime subscription) instead of `ticketsSold`. |
| **2026-05-25** | 20260523170000 _(dormant — not applied, not deployed)_ | **D4 Stripe backend completion (PR #344)**: two gaps closed in the scaffold. (1) `exos_fulfill_checkout` now queues `ticket-issued` mail to buyer after minting — exception-safe (mail hiccup can't unwind the mint). (2) New `exos_refund_checkout(p_session_id, p_reason)` service-role RPC: voids still-**active** tickets, frees inventory (`tier.sold` + `event.tickets_sold` decremented), idempotent, leaves scanned tickets untouched; wired to `stripe-webhook` on `charge.refunded`. `'refunded'` added to session status CHECK. **All dormant — gated on Stripe creds.** Activation checklist: apply mig (branch-validate first), deploy `exos-checkout`/`stripe-webhook`/`exos-connect-onboard` (`--no-verify-jwt`), set `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET`, add `charge.refunded` + `checkout.session.completed` to webhook endpoint, B1 review. |
| 2026-05-25 | _(docs only)_ | **D-tier governance docs (PRs #347/#348)**: `docs/d_tier_goals.md` — operator-ratified north-star per lane (D0=trading desk, D1=secondary→D4-discovery eventual, D2=sales-data backend, D3=data source, D4=venue arm+ticket infra, E1=betting pool). `docs/d_tier_unification_plan.md` — B1-reviewed + goals aligned; §0.5 adds D1 sequencing reconcile flag (secondary-first vs v1 D1↔D4 loop; pending operator confirm). |
| 2026-05-25 | _(app code)_ | **TEvo Fernet barcode decrypt (PR #351)**: `evo_client.decrypt_barcode(barcode, secret)` — Fernet-decodes encrypted barcodes from TEvo `/v9/orders` + `/v9/listings` (key = `base64url(secret[:32])`). Lazy `cryptography` import so broker read pipeline loads without dep; only the call site needs it. `requirements.txt`: `cryptography>=46.0.5,<49.0` — clears `GHSA-r6ph-v2qm-q3c2` (SECT curve subgroup attack, HIGH, first-patched 46.0.5). Tests: `tests/test_evo_barcode.py`. No consuming surface wired yet. |
| **2026-05-25** | _(security — migrations + harness)_ | **B1 anon data-leak sweep (PRs #350/#354 + harness PR #352)**: Full enumeration of ~150 anon-readable view/matview surface found 14 SECDEF objects owned by `postgres` (`rolbypassrls=true`) readable by anon (publishable key) — live broker-intel leak (3,681 rows from `v_event_price_arbitrage`, 1,411 from `latest_event_metrics` matview) + latent order-PII (`unified_orders` 0 rows now; activates when orders flow). Root cause: Supabase auto-grants `ALL` to `anon` on every new public view/matview; PR #298 (functions/tables) never swept views/matviews. **PR #350**: `REVOKE ALL … FROM anon` on 12 views + 2 matviews (`authenticated`/`service_role` untouched; D2 dashboard + storefront unaffected). **PR #354**: `REVOKE EXECUTE FROM anon` on 5 residual ungated SECDEF functions (advisor sweep). **PR #352**: new harness `anon_secdef_relation_audit()` + Phase-2 KANBAN policy-gate — detects future anon-on-SECDEF regressions. Verify fix: `SET ROLE anon; SELECT * FROM public.v_event_price_arbitrage LIMIT 1;` → `permission denied`. |
| 2026-05-25 | _(app code, D1, DORMANT)_ | **D1 TEvo Hosted Checkout — wired but dormant (PR #353)**: `app.py` + `static/store/` wired to redirect secondary-market purchases to TEvo's hosted checkout page. **Env-gated**: fires only when `TEVO_CHECKOUT_ENABLED=true` (not set in prod). Activation = set the env var on `vibepass-storefront-test` + verify TEvo checkout URL scheme. No DB migration; no B1 gate (read-only redirect). |
| **2026-05-26** | _(security — applied to prod)_ | **B1 anon REVOKE sweep applied (PRs #350/#352/#354)**: `20260525170000` REVOKE anon SELECT on 14 SECDEF views/matviews (3 order-PII + 11 broker-intel, incl. `latest_event_metrics` matview which was live-leaking 1,411 rows). `20260525180000` new `_health_check_anon_exposed_relations()` fn (covers relkind='m' matviews, which `release_health_check.security_definer_views` missed). `20260525190000` REVOKE anon/authenticated EXECUTE on 5 ungated SECDEF fns (`cron_resume_with_gate`, `rollup_event_section_row_batch`, `tevo_blindspot_metrics_refresh`, `cron_last_fire`, `cross_source_venue_resolve`). Post-apply: `has_table_privilege('anon','v_event_price_arbitrage','SELECT')=false`. Health check: `warn/4` = 4 Tier-2 event-metadata views intentionally deferred (D0/D1 must confirm no anon/SEO page reads them). |
| 2026-05-26 | 20260526000000 _(applied)_ | **fix_broken_crons**: `midnight-catchup-sweep` (SELECT→PERFORM + `SET LOCAL statement_timeout='5min'`), `weather_climatology_weekly` (two SELECT→PERFORM), `listings_aq_backfill_overnight` (chunk 100→25 + `SET LOCAL statement_timeout='3min'`). All 3 jobs now `active=true` with correct bodies. First successful runs after creation. |
| 2026-05-26 | 20260526010000 _(applied)_ | **sg_429_rate_mitigation**: Reduces all 4 `sg_60d_*` crons from `queue(8)`→`queue(4)` halving burst. Root cause: 60d+ crons introduced 2026-05-22 each fired 8 events/slot, stacking with priority pipeline and exceeding SG's 10-req/8s bucket. Expected: 429 rate drops from 58% CRITICAL to <20%. Monitor via `v_sg_broker_429_health`. |
| 2026-05-26 | 20260526020000 _(applied)_ | **fix_checkins_scanned_by_nullable**: `ALTER TABLE exos_event_checkins ALTER COLUMN scanned_by DROP NOT NULL`. Resolves P1 schema contradiction: `NOT NULL` + `ON DELETE SET NULL` on the same FK column — blocked auth user deletion. |
| **2026-05-26** | _(CI/automation + code)_ | **v1.0.0-beta checkpoint (PR #369)**. (1) `.github/workflows/tests.yml` extended: new `typescript` job (`npm ci` + `tsc --noEmit` + `vite build` on every PR — D4 bridge type errors caught in CI for first time); mypy warn-only step on Python files. (2) `.github/workflows/uptime-check.yml` — pings `/healthz` every 5min from GitHub Actions, opens GitHub issue on failure, optional Slack alert via `SLACK_BOT_TOKEN` secret. (3) `.github/workflows/release-please.yml` + `release-please-config.json` + `.release-please-manifest.json` + `version.txt` — auto-generates CHANGELOG + GitHub Release from conventional commit titles on every `main` push. (4) `d4_bridge/tsconfig.json` + `noImplicitReturns` + `noFallthroughCasesInSwitch` — surfaced 13 real bugs (4 Express middleware missing `return next()`/`return res.json()`, 9 useEffect early-returns); all fixed. (5) `static/bridge/` rebuilt — captures PRs #341 (ENTERED stamp) + #342 (transfer gate + inside-venue counter). |
| 2026-05-25 | _(app code, D4, DORMANT)_ | **D4 Stripe fulfillment idempotency (PR #359)**: `exos_fulfill_checkout` / `stripe-webhook` tightened — persists `'failed'` status on crash (no dangling session), idempotent terminal-state guard (replay `checkout.session.completed` on already-`fulfilled`/`failed` = no-op; closes double-mint on webhook replay). Cherry-picked orphan from `claude/d4-stripe-backend` (committed post-PR-#344 merge). Still dormant — same gate as PR #344. |
| 2026-05-25 | _(deps)_ | **Dependabot dep bumps (PRs #355–#358)**: `actions/setup-python` 5→6; `uvicorn` patch; `anthropic` patch; `fastapi` patch. All within `requirements.txt` pinned `<` ranges; no API surface changes. |
| **2026-05-27** | 20260527240000 | **🚨 sg_classify_events emergency fix**: function was scanning `listings_snapshots` (12.7M rows, 6.8 GB) for a 24h window — timing out at 120s on every 5-min fire (95+ consecutive failures since 08:40 UTC). Replaced with DISTINCT ON join on `event_listing_snapshot_daily` (latest snapshot per event — a few thousand rows, sub-second). Fallback to `event_metrics` for events not yet in snapshot table. Also: `sweep-old-listings` cron 1×/day → 4×/day (listings_snapshots growing ~400K rows/day, 30-day TTL now active). |
| 2026-05-27 | 20260527250000 | **event_movers_index v2 infrastructure**: new tables `event_movers_index` (source × window_days × category, top-25 events per combo; PK source/window_days/category/event_id), `event_movers_index_history` (enter/exit/rank_change), `discovery_gap_alerts` (10 gap types, UNIQUE event_id+gap_type). TD columns added to `event_listing_snapshot_daily`: `td_sh/gt/vd_listings+median`, `td_combined_median`. `compute_event_listing_snapshot()` updated to populate TD columns via ticketsdata_listings_snapshots. New fns: `compute_event_movers_index(p_source, p_window_days)` + `compute_event_movers_index_all()` + `evo_sg_discovery_gaps()`. Crons: `compute_movers_index_post_snapshot` (3×/day at 7:35/13:35/19:35 UTC) + `discovery_gap_refresh` (daily 9am UTC). Seeded on apply: 49 active combos, 228 discovery gap alerts. Key bug fixed: `v_now := now()` not `clock_timestamp()` (see §3 landmine below). |
| 2026-05-27 | 20260527260000 | **movers v2 RPCs + app.py update**: `get_event_movers_v2(source, window_days, category, limit)` — per-event index rows with cross-source medians + platform spreads (sh_vs_evo, gt_vs_sh, vd_vs_sh) from latest `event_listing_snapshot_daily`. `get_event_movers_index_summary(source, window_days)` — one row per (source, window_days, category): size, 24h entry/exit turnover, avg signal score, data coverage. `/api/broker/movers` gains `source`/`window_days`/`category` params; `window_days` set → v2 index path; `window_hours` legacy path unchanged. |
| 2026-05-27 | 20260527270000 | **event_listing_snapshot_daily broker read access**: `GRANT SELECT … TO authenticated` + `s4k_broker_select` RLS policy (email LIKE `%@s4kent.com`). Enables `loadTdFreshness()` in event.js to query the table directly via Supabase client. Pattern matches subsequent broker-read grants. |
| **2026-05-28** | 20260528280000 | **ticketsdata_listings_snapshots broker read access**: same grant+RLS pattern as 270000. Enables `loadTdMarketsListings()` + `loadTdSplits()` + `loadTdPlatformListings()` in event.js (PR #383 TD Listings tab + TD Splits column). |
| 2026-05-28 | 20260528290000 | **Movers past-event filter fix**: (A) `get_event_movers_v2` — added `sg_datetime_utc > now()` JOIN filter to exclude events that already occurred; replaced `GREATEST(0,...)` clip with plain `FLOOR()` so `days_to_event` is accurate for today. (B) `compute_event_movers_index_all()` — added global past-event DELETE purge at top of loop (clears stale rows between cron fires and after partial failures). |
| 2026-05-28 | 20260528300000 | **SG null-listings vicious-cycle fix**: `sg_classify_events()` rewritten with 30d ownership fallback CTE — when snapshot + latest event_metrics both return NULL, looks for any `owned_tickets_count > 0` within 30 days; prevents owned events from being demoted to TRACK_BLINDSPOT during transient data gaps. Also: COLD→COOL floor for events within 30d missing listings data (belt-and-suspenders). Snapshot `cron_policy` min_interval 1440→1200 min (blocked at 21.5h < 24h). `sweep-old-sg-listings` TTL 24h→48h (buffer for metrics refresh). One-time re-queue reset for stale TRACK_BLINDSPOT/WATCH/COLD/OBSERVE events within 14d. |
| 2026-05-28 | 20260528310000–340000 | **TD xref + snapshot + AQ maps batch**: (310000) `td_xref_backfill_via_aq_mapper` — inserts 27 new `ticketsdata_event_xref` rows using `aq_event_map.sh_event_id`/`vivid_event_id`/`sg_event_id` direct-ID columns; method=`aq_event_map_tier1`. (320000) `sg_lifetime_sales_and_fill_rate` — `refresh_sg_broker_sales_event_metrics_lifetime()` aggregates all-time SG sales (not 24h window); `compute_sg_fill_rate()` UPDATE pass joins latest sales+listings per event to write fill_rate (had stopped populating after May 13). Both crons added. (330000) `aq_maps_backfill_and_tevo_link` — adds `aq_event_map.tevo_event_id` column + tier-0 direct lookup in `match_to_aq_event_id()`; backfills 4,413 rows via `sg_events_canonical`; `backfill_aq_maps()` daily cron. (340000) `fix_td_snapshot_12h_window` — `compute_event_listing_snapshot()` TD window changed from flat 12h to "latest batch per platform+event within 25h ± 15min" — captures SH 03:00 UTC batch for midday snapshot without double-counting. |
| 2026-05-28 | 20260528350000 | **🔥 SG peak burst P0 fix**: `sg_broker_listings_queue_5min_peak` cron (`*/5 16-23,0-3`) burst reduced 25→8 (aligns with safe limit from mig 20260519140000). Root cause: at 16:00 UTC peak cron activated dispatching 25 simultaneous pg_net async requests vs SG's 10-token/8s bucket → 78–81% 429 rate sustained for 8+ hours. Expected total_fired/hr: 692→192; pct_429 <15%. |
| 2026-05-28 | 20260528360000 | **Sweep functions P1 dual fix**: (A) `sweep_old_listings` — DROP ambiguous 0-arg overload (DEFAULT parameter made it callable as 0-arg — same class as §3 landmine; caused "not unique" error on every cron call, 100% failure rate). Rebuild 1-arg to actually use `p_days` (body was hardcoded to 24h). Add 50K-chunk/80s batched loop. Reschedule cron to explicit `sweep_old_listings(30)`. (B) `sweep_old_sg_listings` — replace single unbounded DELETE on 9.2M-row/8GB table (always exceeded 120s) with 10K-chunk/90s time-bounded loop (~5M rows/day capacity). Both crons 4×/day, now functional. |
| 2026-05-28 | 20260528370000 | **Movers horizon DISTINCT ON dedup**: `sg_events_canonical` has 22 `tevo_event_id` values appearing 2–3× (45 total rows). `horizon` CTE in `compute_event_movers_index` propagated duplicates → "ON CONFLICT DO UPDATE cannot affect row a second time" on final INSERT (100% failure for td_sh all 5 windows). Fix: `DISTINCT ON (sgc.tevo_event_id) ORDER BY sgc.tevo_event_id, sgc.sg_datetime_utc DESC` in horizon CTE. All td_sh windows re-seeded on apply. |
| 2026-05-28 | 20260528380000 | **TD↔TEvo event linkage + AQ tevo fill**: `refresh_td_event_links()` 5-step resolution chain (aq_event_map direct → sg_canonical → text performer+date → bridge cron → parking/intl NULL classification); `ticketsdata_event_xref.tevo_event_id` + `tevo_match_method` columns. Daily cron @ 06:05 UTC. Day-1 coverage 417/575 (72.5%). |
| **2026-05-29** | 20260529120000 *(prod ledger: 20260529053242)* | **TicketsData FOCUS → next 20 Yankees home + Knicks playoff** (operator directive; pushed to main 2026-05-29). `td_target_events()` (Yankees `%at New York Yankees%` non-parking next-20-by-date + Knicks playoff) + `td_apply_targets()` (upsert SH/VD `always_on`, deactivate non-targets, GT `always_on`, enrich owned/median); `td_watchlist_refresh()` now calls it. **Key fix**: `td_enqueue_peak` `INNER JOIN`→`LEFT JOIN aq_event_map/sg_events_canonical` + `COALESCE(sg_datetime_utc, event_date::timestamptz)` date fallback so the sg-less Knicks placeholders can enqueue. Footprint 228→55 active rows; verified ~101k listings across SH/VD/GT. |
| 2026-05-29 | 20260529170000 *(prod ledger: 20260529162349)* | **SeatGeek listings floor-sweep** (per-event fair coverage; pushed to main). `sg_listings_floor_sweep(p_max,p_min_remaining)` — most-overdue-first round-robin (no tier starvation); bands near(≤7d)/matched = 8h (3×/day), blindspot>7d = 24h (1×/day), SKIP excluded. **Adaptive-gated on a FRESH `ratelimit-remaining`** read (≤10s; stale-read deadlock found+fixed in smoke). New `v_sg_token_budget` view. **Disabled** `sg_broker_listings_queue_5min`+`_peak`+`sg_priority_poll_tick_5min` (starved low tiers + burst-collided). Cron `*/2 × 4` (conservative; ramp `*/1 × 5` after `sg-floor-sweep-watch` confirms headroom). |
| 2026-05-29 | 20260529180000 | **TickPick TD platform (focus-scoped; pushed to main)**. `td_api_platform` `TP→tickpick` + `ticketsdata_normalize_listings` `items.offers[]` branch + `ticketsdata_event_xref.platform` CHECK +`'TP'`; `td_tp_performers` allowlist (Yankees/Knicks) + `td_tp_discover`/`_drain` (venue+datetime matched → home games only) + **`td_enqueue_peak_tp`** cron (`0 16,22,4`) — without it TP rows never enqueue→pull; `td_apply_targets` preserves TP focus rows. Result: 22 TP xref (20 Yankee Stadium + 2 MSG, 0 away-mismatch); normalizer validated on 1,271-listing response. Companion (DML, no migration): 3 SeatGeek Knicks Finals **home** games wired into `sg_events_canonical` via TD `/events?platform=seatgeek` (sg 18068093/096/098 → tevo 3346011/12/26). |
| 2026-05-29 | 20260529190000 | **TP+TM listing metrics** (pushed to main). `event_listing_snapshot_daily` +`td_tp_listings/td_tp_median`+`td_tm_listings/td_tm_median`; `compute_event_listing_snapshot` now aggregates all 5 TD platforms (SH/GT/VD/TP/TM) and `td_combined_median = LEAST()` across all five. Verified TP+TM medians populate per focus event. |
| 2026-05-29 | 20260529200000 | **Ticketmaster TD platform** (mirrors TickPick; pushed to main). `ticketsdata_normalize_listings` TM branch parses ISMDS EventFacets (`body.facets[]` × `body._embedded.offer[]` → section/count/listPrice/totalPrice); `td_tm_performers` (NYY artist/805992 + NYK artist/805988) + `td_tm_discover`/`_drain` (primary-listing filter, venue+datetime match, **hex→bigint** event_id via `('x'\|\|lpad(id,16,'0'))::bit(64)::bigint`); `td_apply_targets` TM keep-clause; crons `td_tm_discover` (`45 9`) / `_drain` (`50 9`) / **`td_enqueue_peak_tm`** (`30 16,22,4`). Verified: 21 TM xref (20 NYY home + 1 Knicks Finals), pulled+normalized 1.3k+ listings, metrics flowing alongside SH/TP/VD. |
| 2026-05-29 | 20260529210000 | **TM post-test fixes** (pushed to main). `td_pull_queue.platform` CHECK +`'TM'` — the queue's CHECK is *separate* from the xref CHECK, TM was missing from it → `td_enqueue_peak('TM')` raised 23514. Relaxed `td_tm_discover_drain` filter to capture Knicks Finals (`"TBD at New York Knicks"` titles, not just `"vs."`) with a canonical-title DISTINCT ON tiebreak so Yankees still resolve to the standard listing. |
| 2026-05-29 | 20260529220000 | **TM primary/resale split + aq mapping** (pushed to main). TM `/fetch` carries two inventory pools (`inventoryType` `primary` vs `resale`) in one response — verified live on Spurs@Thunder WCF (997 resale @ med $700). `compute_event_listing_snapshot` now splits TM by reading `raw->'offer'->>'inventoryType'` (no firehose column → no 489MB rewrite): `td_tm_listings/median` = primary, new `td_tm_resale_listings/median` = resale; combined-median stays primary-only. `td_tm_discover_drain` + a one-time backfill map the 21 focus events' real **hex→bigint** TM ids into `aq_event_map.tm_event_id` for direct-id processing. |
| **2026-05-30** | 20260530120000 _(applied via apply_migration; repo branch `a1/terminal-sql-audit-fixes`, not yet pushed)_ | **Terminal event-page chain timeout audit (A1)**. Audited all SQL pulls into the d0 terminal; `get_broker_event_page` v1→v2→v3 ran 0.5–19s and intermittently exceeded the 8s PostgREST timeout on heavy events. 3 causes, same family (wide scan where one slice is wanted): **(1) dominant** — v1 freshness ran `max(last_seen_at) FROM espn_injuries_snapshots` with **no WHERE** → full **175 MB** seq scan on EVERY page load (max()→index optimization won't match a `(col DESC)` index; replaced with `ORDER BY last_seen_at DESC NULLS LAST LIMIT 1` + new index; v1 18.8s→~0.5s); **(2)** v2 `splits` + **(3)** v3 `recent_listings` both did a 24h `DISTINCT ON` over `listings_snapshots` (25.5M rows) → pinned to latest batch (`captured_at >= max(captured_at) - 30min`). Same session, separate file: `get_event_evo_listings_full` 7d→latest-batch (mig 240000). After: v3 ~0.35–2.5s, no >8s. Codified in §3 landmine. **Data-health follow-up**: `espn_injuries_snapshots` is 175 MB for ~16.5k live rows (wide/bloated) — VACUUM FULL / collector dedup tracked separately (KANBAN). |

---

Last updated: 2026-05-30 — terminal event-page chain timeout audit (mig 20260530120000; branch `a1/terminal-sql-audit-fixes`, applied to prod, not yet pushed to main). | 2026-05-29 — added 7 landmark migs (TD focus 20260529120000, SG floor-sweep …170000, TickPick platform …180000, TP+TM metrics …190000, Ticketmaster platform …200000, TM fixes …210000, TM resale split …220000); all pushed to main. | prior: 2026-05-28 — added §14 landmark migration log (migrated from `PROJECT_BIBLE.md §9`); added roster note reconciling "audit lane" → A1.
Owner: A1 (formerly "audit lane"; see `BOT_HIERARCHY.md` for the current roster).
