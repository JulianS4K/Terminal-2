# Sync Check — code's audit procedure

**Purpose**: detect drift between prod (Supabase + edge fns + crons) and git. Run before every prod push, and weekly minimum.

**Run by**: code (auditor role). Other agents don't have prod-write access so they can't introduce drift directly — but they can hand off changes that haven't been promoted yet, and code's job is to catch the gap.

**Automation status**: not yet automated. Doing so requires a Supabase PAT in a CI secret. Until then this is a manual checklist code follows. The `2026-05-08` sync audit (`docs/sync-audit-2026-05-08.md`) is an example of a full pass.

---

## Quick pre-push check (~2 min)

Before code commits and pushes anything to `main`:

```sql
-- 1. Migration drift
select count(*) as prod_count from supabase_migrations.schema_migrations;
-- vs:
ls supabase/migrations/ | wc -l

-- 2. List any prod migrations whose `name` doesn't appear in git filenames
select name from supabase_migrations.schema_migrations
where name not in (
  -- paste the list of git filenames (without .sql) here, OR
  -- export it via shell:  ls supabase/migrations/ | sed 's/.sql//'
);
```

If counts match and no rows return from query 2, migrations are clean.

```bash
# 3. Edge fn drift — any function deployed with no source in git?
ls supabase/functions/   # what's in git
# vs
mcp list_edge_functions  # what's deployed
# Compare. Anything deployed but not in git → capture.
```

If both clean: OK to push. If either dirty: stop and capture into git first, then push.

---

## Full sync audit (~20 min)

Run weekly, or any time work has been quiet for a few days. Output goes in `docs/sync-audit-YYYY-MM-DD.md` so the trail is preserved.

### A · Migration alignment
1. Pull prod migration list via MCP.
2. Diff against `ls supabase/migrations/`.
3. For any prod-only versions: pull SQL via `select statements from supabase_migrations.schema_migrations where version = ...` and write to git verbatim.

### B · Edge fn alignment
1. List deployed edge fns via MCP `list_edge_functions`.
2. For each, check if `supabase/functions/<slug>/index.ts` exists in git.
3. For ones that exist, compare `ezbr_sha256` against a local sha if you can. Mismatches → pull source via `get_edge_function`, diff in head, capture if real.
4. For ones that DON'T exist locally — copy from prod via `get_edge_function`.

### C · Cron alignment
```sql
select jobname, schedule, command, active from cron.job order by jobname;
```
- Any cron pointing at a function not in git? → fix.
- Any cron with `active=false` that should be on? → flag.
- Any cron command with placeholder secrets (e.g. `'pick-any-random-string-and-save-it'`)? → that's the espn-collect bug from 2026-05-08; verify the function is `verify_jwt=false` or fix the auth header.

### D · Config drift
- `select * from settings;` — any prod-only secrets that should be in `.env.example` (with REDACTED) for setup parity?
- Edge fn env vars set in Supabase dashboard but not documented anywhere?

### E · Strategic-context drift
- Anything in `docs/` (especially `docs/seatgeek/`) that AGENTS.md `STRATEGIC` block doesn't reference? Promote.
- Anyone added a new feature surface that AGENTS.md `OWN` doesn't cover? Promote.

### F · Test-schema drift
- Anyone left objects in `code_staging` / `copilot_test` / `design_test` that should have been promoted to `public` weeks ago?
  ```sql
  select schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
  from pg_tables where schemaname in ('code_staging','copilot_test','design_test')
  order by pg_total_relation_size(schemaname||'.'||tablename) desc;
  ```
- Big tables there that aren't in `public` are a hint someone forgot to promote.

### G · Static / front-end drift
- `ls static/` — any files claude design added that AGENTS.md `OWN` doesn't list?
- Any inline styles / classes that don't match the design system tokens in `static/index.html`?

---

## When drift is found

1. **Capture into git verbatim** — don't rewrite, don't refactor in the same commit. The capture commit is read-only history.
2. **Write up findings** in `docs/sync-audit-YYYY-MM-DD.md`.
3. **Update AGENTS.md `STATE` block** with current truth (migration count, fn versions, etc.).
4. **Append LOG entry** under today's date with `DONE <SHA> sync audit — captured N migrations, M fns, ...`.
5. **If drift recurred frequently**: log the cause + propose a process change. Don't just keep capturing.

---

## Future automation

When ready to automate (rough plan):

1. Create a Supabase Personal Access Token, add as GitHub secret `SUPABASE_PAT`.
2. Write `bin/sync-check.sh` that hits the Supabase Management API:
   ```
   GET /v1/projects/{ref}/database/migrations
   GET /v1/projects/{ref}/functions
   GET /v1/projects/{ref}/database/extensions
   ```
3. Compare against git, exit non-zero on drift.
4. `.github/workflows/sync-check.yml` runs it nightly + on every push to `main`. Opens a GitHub issue when drift detected.

Until then: this manual checklist is the audit procedure.
