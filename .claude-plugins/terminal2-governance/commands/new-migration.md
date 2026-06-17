---
description: Scaffold a Supabase migration file with the repo's required filename + header conventions (MIGRATION_CONVENTIONS.md §3 + §6). Authors the FILE only — applying to prod stays operator-gated.
---

Scaffold a new migration in `supabase/migrations/` for: $ARGUMENTS

> Scaffolds the FILE only. For the **full lifecycle** (check-don't-rebuild → sample-test → operator-gated apply → verify → PR), use the **`ship-a-migration`** skill (`../skills/ship-a-migration/`), which calls this command at its authoring step.

## Process

1. **Timestamp**: 14-digit UTC `YYYYMMDDHHMMSS` (`date -u +%Y%m%d%H%M%S`). Check `ls supabase/migrations/ | tail` for collisions — if the slot is taken, bump by `+30` (tight follow-up) or `+50` (leave room). NEVER bump by `+1` or `+100` (MIGRATION_CONVENTIONS.md §3).
2. **Filename**: `<timestamp>_<lane-prefix-if-applicable>_<snake_case_description>.sql`. Lane prefixes (optional but encouraged): `xref_`/`macro_` (audit), `phase<N>_`/`canonical_`, `store_`/`share_`, `broadway_`.
3. **Header** — every migration MUST start with this block (MIGRATION_CONVENTIONS.md §6):

```sql
-- ============================================================================
-- Migration <timestamp> — <one-line summary>
--
-- Lane:     <xref+macro | canonical | broadway | storefront>
-- Touches:  <table_a (W), table_b (R)>   -- every table written (W) or read (R)
-- Pre-reqs: <prior migration timestamps, vault.* secrets, external services>
--
-- <2-5 line description: what + why>
-- ============================================================================
```

4. **Before authoring SQL**, check column names against `PROJECT_BIBLE.md §3` (landmines) and whether the object already exists in `RESOURCES_BIBLE.md` — don't re-ship (132 tables / 152 views already exist).
5. Write the file, then re-read it to confirm the header fields are filled in (no `<placeholders>` left).

## Red flags

- Authoring the file is standing-permitted; **applying it to prod (`apply_migration` / `execute_sql` DDL) requires explicit operator permission per call** (CLAUDE.md §1). Never apply as part of this command.
- New crons inside the migration must be wrapped with `cron_should_fire` (PROJECT_BIBLE §11 item 6) and respect `CRON_HIERARCHY.md` tiers.
- No literal secrets in SQL — vault references only (`get_app_secret` pattern).

## Verification

Confirm: filename matches the regex `^\d{14}_[a-z0-9_]+\.sql$`, the header block parses (`grep "^-- Lane:" <file>` hits), and no prod apply was attempted.
