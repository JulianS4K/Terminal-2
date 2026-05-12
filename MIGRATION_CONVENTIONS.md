# MIGRATION_CONVENTIONS.md

Authoritative reference for how migrations are authored, named, reviewed, and shipped across the Terminal-2 multi-bot environment. **Read this before writing any migration.** Read it again before merging one.

---

## TL;DR

1. **Only the audit lane (`mystifying-lederberg-ea407b` worktree, "code" agent in `AGENTS.md`) pushes to production.** Other bots develop in preview branches and open PRs.
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

The audit lane maintains the cron landscape doc at `docs/cron-landscape-2026-05-09.md`. Update it when you add/remove a job.

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
3. If lanes change: update `AGENTS.md` to match

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

Last updated: 2026-05-10 — initial publication.
Owner: audit lane (`mystifying-lederberg-ea407b` worktree, "code" agent in AGENTS.md).
