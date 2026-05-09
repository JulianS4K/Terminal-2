# Hand-off package — what to send the coworker

This is the doc you forward to your UI coworker. Everything below is
ready to copy/paste into Slack, email, or a Notion page.

---

## What to send (the message)

> Hey — Phase 2 of Terminal-2 (the broker tool) is starting. Phase 1
> built the data plane; you're owning the UI from here.
>
> Three things you need to read **before** building anything:
>
> 1. https://github.com/JulianS4K/Terminal-2-ui — your repo. Clone this. The README points to everything else.
> 2. https://github.com/JulianS4K/Terminal-2/blob/main/COWORKER_ONBOARDING.md — the contract. Read top-to-bottom.
> 3. https://github.com/JulianS4K/Terminal-2/blob/main/docs/coworker-handoff/DATA_QUALITY_DASHBOARD.md — your first card.
>
> Frontend stack is your choice (React/Svelte/Vue/Astro/HTMX/vanilla — whatever you'll be productive in). Commit your stack decision in `Terminal-2-ui/docs/stack.md` once you pick.
>
> Access shapes:
> - **Read-only Supabase Postgres role** `coworker_readonly` — credentials in the encrypted message I sent you separately.
> - **JSON API Bearer token** for the FastAPI backend — also encrypted message.
> - **GitHub push** on `Terminal-2-ui` only. Backend repo blocks your PRs at CODEOWNERS + branch protection + CI guard.
>
> Workflow: branch off `main` in `Terminal-2-ui`, build, PR. I review and merge — don't self-merge. If you need a backend change, open an issue in `Terminal-2`.
>
> Questions: open an issue (in whichever repo applies), tag `@JulianS4K`. Don't DM Slack — issues keep the discussion attached to the work.

---

## What to send out-of-band (encrypted / 1Password / similar)

**Never put these in Slack/email plaintext.** Use 1Password sharing,
encrypted message, or in-person.

### Supabase connection

```
SUPABASE_URL=https://hzrizjeaxlqcxfrtczpq.supabase.co
SUPABASE_ANON_KEY=<the anon JWT from Supabase dashboard - Project Settings - API>
DATABASE_URL=postgresql://coworker_readonly:<ROTATED_PASSWORD>@db.hzrizjeaxlqcxfrtczpq.supabase.co:6543/postgres?sslmode=require
```

**You must rotate the password before sending.** The migration created
the role with placeholder password `CHANGE_ME_BEFORE_HANDOFF`. To
rotate:

```sql
ALTER ROLE coworker_readonly PASSWORD '<strong-random-string>';
```

(Do this in Supabase SQL Editor as a service-role user.)

### Backend API

```
API_BASE_URL=https://<your-railway-deploy>.railway.app
API_BEARER_TOKEN=<bearer token used by /api/* routes>
```

Generate the token in `app.py`'s auth config or whatever your auth
flow expects. If you haven't set up Bearer auth yet, the `coworker`
just hits the API with whatever's currently configured.

---

## What you (Julian) need to do in the GitHub UI

These can't be done via CLI; settings live in the GitHub web app.

### On `Terminal-2` (the backend):

1. **Settings → Branches → Branch protection rules → Add rule**
   - Pattern: `main`
   - Check: ✅ Require a pull request before merging
   - Check: ✅ Require approvals (1)
   - Check: ✅ Require review from Code Owners
   - Check: ✅ Require status checks to pass before merging
   - Status check: select `forbidden-paths-check / check`
   - Save.

2. **Settings → Collaborators and teams**
   - Do NOT add the coworker here. They get no push access on the
     backend repo. CODEOWNERS does the rest.

### On `Terminal-2-ui` (the new UI repo):

1. **Settings → Collaborators**
   - Add the coworker as collaborator with **Write** role.

2. **Settings → Branches → Branch protection rules → Add rule**
   - Pattern: `main`
   - Check: ✅ Require a pull request before merging
   - Check: ✅ Require approvals (1) — this forces audit-lane review
   - (Optional) Check: ✅ Require linear history if you want squash-only

3. **Settings → General → Default branch** — confirm it's `main`.

---

## What I (audit lane) commit to

- Review every PR in `Terminal-2-ui` within 24h on weekdays
- Reject PRs that try to write to forbidden paths in `Terminal-2`
- Open an issue in `Terminal-2` for any backend gap the coworker reports;
  ack within 24h, ship within a week unless flagged otherwise
- Keep `docs/coworker-handoff/*.md` up to date as the canonical contract
- Run `scripts/check_readonly.py` on every backend PR (already in CI)
- Tag a new `phase1-baseline` if any backend change preserves stability;
  otherwise create a new tag (`phase2-r1`, etc.)

---

## Where everything lives (quick reference for you)

| Where | What | Coworker reads? | Coworker writes? |
|---|---|---|---|
| `Terminal-2/COWORKER_ONBOARDING.md` | The contract | Yes | No |
| `Terminal-2/docs/coworker-handoff/SCOPE.md` | Scope rules in prose | Yes | No |
| `Terminal-2/docs/coworker-handoff/QUERY_COOKBOOK.md` | Ready SQL examples | Yes | No |
| `Terminal-2/docs/coworker-handoff/DATA_QUALITY_DASHBOARD.md` | First card scope | Yes | No |
| `Terminal-2/docs/coworker-handoff/HANDOFF_INSTRUCTIONS.md` | This file | No | No (your reference) |
| `Terminal-2/docs/database-map-2026-05-09.md` | Schema topology | Yes | No |
| `Terminal-2/docs/phase2-ui-kanban.md` | Backlog | Yes | No |
| `Terminal-2/SCHEMA.md` | Per-table column reference | Yes | No |
| `Terminal-2/.github/CODEOWNERS` | Enforces backend ownership | n/a | No (CI rejects) |
| `Terminal-2/.github/workflows/forbidden-paths-check.yml` | CI guard | n/a | No (CI rejects) |
| `Terminal-2/supabase/migrations/20260509460000_coworker_readonly_role.sql` | DB role definition | n/a | No (cannot apply) |
| `Terminal-2-ui/README.md` | Their repo's quick start | Yes | Yes |
| `Terminal-2-ui/.env.example` | Env shape | Yes | Yes (if they need to add vars) |
| `Terminal-2-ui/docs/scope.md` | Mirror of backend SCOPE.md | Yes | No (kept in sync from backend) |

---

## Sanity checklist before you send the message

- [ ] `coworker_readonly` password rotated from placeholder
- [ ] Branch protection enabled on `Terminal-2` `main`
- [ ] Branch protection enabled on `Terminal-2-ui` `main`
- [ ] Coworker invited to `Terminal-2-ui` (Settings → Collaborators)
- [ ] Coworker NOT added to `Terminal-2`
- [ ] Out-of-band encrypted message contains: Supabase DB URL +
      password, API base URL, API Bearer token
- [ ] Coworker has working access to Supabase MCP / their preferred
      query tool (their problem to solve, but mention it)

After sending, Phase 2 is officially in their hands. You and I move to
backend-only work.
