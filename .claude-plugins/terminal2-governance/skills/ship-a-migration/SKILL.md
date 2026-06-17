---
name: ship-a-migration
description: >-
  End-to-end workflow for taking a Supabase schema/data change from idea to shipped:
  check-don't-rebuild, scaffold, sample-test, operator-gated apply, post-apply verify,
  and PR. Use whenever a task needs a new/changed table, view, RPC, cron, or backfill.
  Authoring is standing-permitted; APPLYING to prod is operator-gated per call (CLAUDE.md §1).
allowed-tools: Read, Grep, Glob, Bash, Edit, Write, AskUserQuestion, mcp__Supabase__execute_sql, mcp__Supabase__apply_migration, mcp__Supabase__list_migrations
---

# Ship a migration

## Overview
One disciplined path for every prod DB change, replacing the steps scattered across
`PROJECT_BIBLE §8`, `MIGRATION_CONVENTIONS.md §3/§6/§9/§14`, and the `CLAUDE.md` lockdown.
The `/new-migration` command scaffolds the FILE; this skill is the whole lifecycle around it.

## When to use
- A task needs a new or changed **table / view / RPC / cron / index / backfill**.
- You are about to write `supabase/migrations/*.sql`, call `apply_migration`, or run DDL/DML on prod.
- **Not for**: pure `SELECT` investigation (just query), or `bot_chat` writes (standing-permitted).

## Process

1. **Don't rebuild it.** Before designing anything, confirm it doesn't already exist —
   132 tables / 152 views / 75+ crons are live. Grep `RESOURCES_BIBLE.md` for the keyword;
   check `MIGRATION_CONVENTIONS.md §14` so you don't re-ship landmark work.
   `SELECT relname FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace
    WHERE nspname='public' AND relkind IN ('r','v','m') AND relname ILIKE '%<kw>%';`
   → **Checkpoint:** name the existing object you ruled out, or state none exists.

2. **Clear the column landmines.** Read `PROJECT_BIBLE.md §3` for every table you'll touch.
   IDs never line up cross-source — resolve through `aq_event_map` (`§0`), never raw source IDs.
   → **Checkpoint:** list each table + the exact column names you'll use (not assumed names).

3. **Prove the query shape on real rows — before writing the file.** Run the core
   SELECT/JOIN against 5–10 sample rows via read-only `execute_sql`
   (`SET statement_timeout='5s'`; prefer indexed predicates over seq-scans on firehose tables).
   → **Checkpoint:** paste the sample output; the shape matches what the migration assumes.

4. **Scaffold the file** (use `/new-migration` or by hand): 14-digit UTC timestamp
   (`date -u +%Y%m%d%H%M%S`, bump +30/+50 on collision, never +1/+100), filename
   `^\d{14}_[a-z0-9_]+\.sql$`, and the required header block (Lane / Touches W,R / Pre-reqs).
   SECURITY DEFINER fns get the `REVOKE…FROM PUBLIC,anon,authenticated` + `GRANT…service_role`
   + `current_user NOT IN (...)` guard (`BOT_HIERARCHY §8.5`). New crons wrap `cron_should_fire`.
   → **Checkpoint:** `grep '^-- Lane:'` hits and no `<placeholders>` remain.

5. **Get explicit operator permission to apply.** Applying is NOT standing-permitted.
   Ask via `AskUserQuestion` (state: what it touches, W/R surfaces, reversibility).
   → **Checkpoint:** operator said yes for THIS migration, this call.

6. **Apply** via MCP `apply_migration` (or a Supabase branch first for risky DDL).
   → **Checkpoint:** apply returned success; `list_migrations` shows it landed.

7. **Verify on the same samples from step 3** — prove the change did what step 3 predicted,
   with the same rows. For a cron, confirm it's scheduled + within the `CRON_HIERARCHY` budget.
   → **Checkpoint:** post-apply output matches the intended shape on the same IDs.

8. **Record + ship.** Add `-- Already applied to prod · via MCP YYYY-MM-DD` to the header;
   `bot_chat_log` a `change_log` event with PR#; commit on a `claude/<lane>-<purpose>` branch;
   open the PR. Push to `main` per the task's delegated owner (CI must be green first).

## Rationalizations — excuse → why it's wrong
| "I'll just…" | Reality |
|---|---|
| "…skip the sample test, the SQL looks right." | Column-name + null-key bugs (`occurs_at_local` is TEXT; `tevo_event_id` often NULL) only show on real rows. Step 3 is the cheapest place to catch them. |
| "…apply now, it's a tiny change." | Apply is operator-gated **per call** regardless of size (CLAUDE.md §1). Tiny DDL still mutates prod. |
| "…it's NOT VALID so the FK won't block inserts." | `NOT VALID` skips *existing* rows but still enforces every new INSERT. Drop it, don't mark it. |
| "…I'll reuse this name, feels new." | 132 tables / 152 views exist; re-implementing `event_metrics`/`*_xref`/`v_event_*` is the #1 waste. Step 1 exists for this. |
| "…verify later, apply succeeded." | "Applied" ≠ "correct." A function can return 20 and write 0 rows (clock_timestamp vs now() bug). Re-run the samples. |

## Red flags — stop if any are true
- You're about to `apply_migration` / DDL / DML on prod **without** a yes from step 5.
- A literal secret is in the SQL (use vault `get_app_secret` — never inline).
- You're joining two sources on a raw numeric/text event ID (→ 0 rows; go via `aq_event_map`).
- A new cron has no `cron_should_fire` gate, or pushes peak concurrency over the `CRON_HIERARCHY` budget.
- An unconditional `max()` / wide-window `DISTINCT ON` over a firehose inside an event-page RPC (timeout).

## Verification
Reason about — do not blindly re-run — that all are true before declaring done:
filename matches `^\d{14}_[a-z0-9_]+\.sql$`; header has Lane + Touches; the **same sample IDs**
from step 3 were re-checked post-apply and match; apply happened only after an explicit step-5 yes;
PR opened with a `change_log` `bot_chat` entry. If any is false, the migration is not shipped.
