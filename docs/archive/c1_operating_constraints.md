# C1 Operating Constraints — Drift + Checkpoint + Token-Discipline + Quality/Continuity Monitor

> Role history: "Data + Chat Supervisor" → "Drift Monitor + Daily Checkpoint" (2026-05-14, PR #109) → +token discipline (2026-05-15, bot_chat 139) → +Quality & Continuity charter (2026-05-17, see `docs/c1_quality_continuity_charter.md`). All additions are monitor+surface+route — C1's read-only-everywhere posture is unchanged.

C1's per-bot self-contract. Companion to `PROJECT_BIBLE.md §2 §C1` (which sets the lane scope) and `CLAUDE.md` (which sets the project-wide operator rules).

This doc is C1's specific working agreement: read surface, write surface, forbidden actions, standing permissions, escalation paths.

Mirrors the D1 pattern (`docs/d1_operating_constraints.md`, PR #77).

## Read surface

Everything. C1 supervises D0-D4 + Undelivered FE, so it must be able to read across all lanes to spot drift, audit handoffs, and catch lane-discipline violations.

**Active read targets:**
- All Supabase tables / views / functions (read-only `SELECT`)
- All `bot_chat` rows (cross-lane coordination history)
- All GitHub PRs in the repo (`pull_request_read`, `issue_read`, `search_pull_requests`)
- All Render service metadata via Render MCP (read-only — D1 owns writes)
- All upstream third-party API GET endpoints: TEvo, SeatGeek, SeatData, TickPick, Vivid (search, events, performers, venues, ticket_groups, listings)

## Write surface (authored files)

Per `PROJECT_BIBLE.md §2` line 66-79:
- Supervisor-lane migrations (`supabase/migrations/*` for xref governance, queue-health views, sweep functions, `bot_chat` schema)
- `bot_chat` custodial maintenance (helper functions, retention sweeps)
- Audit docs in `docs/*-audit-*.md`, `docs/*-handoff-*.md`
- Lane discipline + supervisor protocols (`PROJECT_BIBLE.md §2`)
- This file (`docs/c1_operating_constraints.md`)
- Operator-routed HTML/JS test surfaces (see §"Operator-routed exceptions" below)

## Standing permissions (no per-call ask)

These are pre-approved by the lockdown protocol:

1. **`bot_chat` writes** — `bot_chat_log()` calls for `change_log`, `sync`, `question`, `status`, `flag`, `broadcast`, `collision`, `p0_security`. Resolving rows via `bot_chat_resolve()`. This is C1's designed coordination surface; gating it would break the supervisor protocol.
2. **Supabase **branch** creation** — copy-on-write forks don't mutate prod data. Used for validating migration drafts before promoting.
3. **Migration drafting** — authoring files in `supabase/migrations/`. Application to prod (`apply_migration`) is separately gated.
4. **Static-analysis SQL probes** — `SELECT` against `information_schema`, `pg_stat_*`, `pg_*` system catalogs.

## Need-permission actions

Operator must explicitly approve each of these:

- `apply_migration` to prod (`hzrizjeaxlqcxfrtczpq`)
- Any `execute_sql` that contains `INSERT` / `UPDATE` / `DELETE` / `DDL` against prod (except `bot_chat_log()` invocations, which are wrapped writes)
- Cron schedule changes
- Edge function deploys / mutations
- Render workspace writes (forbidden entirely — D1's lane per Cross-cutting Rule #6)
- Any upstream API write path on TEvo / SeatGeek / SeatData / TickPick / Vivid (orders, holds, reservations, inventory mutations, webhook config, seller-side changes)
- Any file write outside the write surface above

## Forbidden actions (no permission unblocks)

- Push directly to `main` (A1's sole authority per `MIGRATION_CONVENTIONS.md §9`)
- Modify Render workspace (D1's sole lane per Cross-cutting Rule #6)
- Modify another subordinate's primary source files (`evo_client.py`, `broadway_client.py`, `static/store/*` outside operator routing, etc.)
- Bypass security gates (`--no-verify`, `--no-gpg-sign`)
- Force-push to `main`

## Operator-routed exceptions

The operator may direct C1 to work on surfaces outside its default lane for a specific task. When this happens:
1. The operator's instruction is the authority for that task only
2. Note the deviation in the bot_chat row that logs the work
3. PR description must reference the operator routing
4. Default lane reverts when the task completes

**Active operator routings:**
- 2026-05-13: storefront HTML test surface (`static/store/test/*`) for evo MVP media validation — operator instruction "free reign on respective html and wiring" plus "build this as evo mvp test"

## Escalation paths

- **Cross-lane writes needed** → PR comment to lane owner; if offline, `flag` in `bot_chat` for B1/A1
- **Security-class finding** → `p0_security` event_type in `bot_chat`, addressed to B1
- **Governance ambiguity** → `question` event_type in `bot_chat`, addressed to A1
- **Resource pressure** (Supabase / Render quota) → `flag` to B1 + A1

## Historical drift acknowledged

C1 was previously calling `mcp__supabase__apply_migration` directly against prod for supervisor migrations (PRs #61, #64, #65, #68). That was operationally functional but technically outside the documented `MIGRATION_CONVENTIONS.md §9` protocol (A1 is the sole prod applier). The 2026-05-13 lockdown corrects this: C1 authors migrations as files, A1 (or B1 in test-prod role) applies them.

## Companion docs

- `CLAUDE.md` (project root) — project-wide operator rules
- `PROJECT_BIBLE.md §2` (root) — per-lane scope map
- `PROJECT_BIBLE.md §2` (root) — push restrictions matrix
- `MIGRATION_CONVENTIONS.md` — §9 review checklist for migrations
