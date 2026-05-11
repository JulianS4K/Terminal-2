<!--
PR template — every PR must fill this. The admin (level:admin) will reject
PRs that delete fields or leave them blank. See START_HERE.md and
MIGRATION_CONVENTIONS.md before opening.
-->

## Lane identity

- **Level**: <!-- admin | security | supervisor | primary-sales | secondary-sales | data-collection -->
- **Lane (role)**: <!-- e.g. "Terminal Front End" | "Broadway Scraper" | "Retail Storefront" | "Order Clients" -->
- **Worktree / git branch**: <!-- e.g. claude/your-branch-name -->

> If you don't know your level + lane, STOP. Read `START_HERE.md`.

## Summary

<!-- 1-3 bullets on what this PR does and why. -->

## Changes

### Tables touched
<!-- List every table with W (write) or R (read). Example:
- `event_xref` (W) — INSERT in matcher tick
- `events` (R) — joined for name lookup
-->

### Migrations added
<!-- List every new migration. Example:
- `supabase/migrations/20260511010000_bot_chat.sql` — new table for cross-bot logging
-->

### Files modified outside your lane
<!-- If you touched files owned by another lane, list them and link the coordination thread. If none, write "none". -->

## Pre-reqs

<!-- List what must be true before this PR can merge. Example:
- Vault: `FRED_API_KEY` must be seeded before cron yields data
- Prior migration: 20260510130000 (fred_macro_indicators) must be applied
- External service: api.stlouisfed.org must be reachable
-->

## Test plan

<!-- What you verified on your Supabase preview branch. Example:
- [ ] Applied to preview branch `claude/my-feature-preview-xyz`, no errors
- [ ] Smoke query: `SELECT count(*) FROM my_new_table` returns expected N
- [ ] Smoke query: `SELECT * FROM my_view LIMIT 5` returns expected shape
- [ ] No regressions in `pg_stat_statements` after 10 minutes
-->

## Admin review notes
<!-- Optional: anything you specifically want level:admin to look at, or known caveats. -->

---

<!-- Auto-checks before merge (admin lane):
- [ ] Filename follows MIGRATION_CONVENTIONS.md §3
- [ ] Header block present in every migration (§6) — Level / Lane / Touches / Pre-reqs
- [ ] Tables touched match the declaration
- [ ] Lane writes only to owned tables (or via coordination)
- [ ] Cron names lane-prefixed
- [ ] Vault secrets documented
- [ ] No DROP/TRUNCATE on shared tables without rollback plan
- [ ] ON CONFLICT on UPSERTs
- [ ] created_at / updated_at on new tables
- [ ] Preview branch validation confirmed
- [ ] sync-check passes
- [ ] PR carries the correct level:* label
-->
