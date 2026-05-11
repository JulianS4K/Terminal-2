# START_HERE.md

> **If you are a bot looking at this repo for the first time: STOP. Read this entire file before doing anything.**
>
> This is the "you can't miss it" door. Get this wrong and you'll break things or get blocked at the PR gate.

---

## 1. Identify yourself

You should already know **your level** and **your lane (role)**. They were assigned to you out-of-band by the operator (Julian).

The 6 levels are:

| Level | Authority | Who fits here |
|---|---|---|
| **admin** | Full repo + prod write + merge | The audit/push role — singleton (only one bot at this level) |
| **security** | Push only for CRIT security patches; veto power on P0 security flags | Security Manager — singleton |
| **supervisor** | SQL writes for data fix + matching; supervises secondary-sales and data-collection lanes | Data + Chat Supervisor — singleton |
| **primary-sales** | Full-stack admin in own domain (storefront), Admin reviews cross-domain changes | Retail Ticket System bot |
| **secondary-sales** | Read-only on prod; Admin has final say on any change | Frontend bots consuming Supervisor's data |
| **data-collection** | No main-code access; scoped to own scraper/client tables | Scrapers and read-only API clients feeding Supervisor |

Your lane is the specific role within your level (e.g., "Terminal Front End", "Broadway Scraper", "Retail Storefront").

**If you don't know your level + lane, STOP.** Ask Julian. Do not pick one. Do not invent one. Do not "just use admin" — that level is singleton, and there's only one.

If you are a brand-new bot with no assigned level, do not write any code or open any PR until Julian assigns you. Read `AGENTS.md` and `docs/bot-hierarchy.mermaid` first, then ping Julian with your proposed scope.

---

## 2. Read these in this order (≈30 min)

1. **`docs/bot-hierarchy.mermaid`** — command structure and where you fit
2. **`AGENTS.md`** — lane roster, ACCESS MATRIX, status board, WIP claims
3. **`MIGRATION_CONVENTIONS.md`** — production-push gate, filename conventions, mandatory migration header, lane discipline
4. **`DOCUMENTATION_INDEX.md`** — lane-to-doc reading list map
5. **`SCHEMA.md`** — schema source of truth
6. **`KANBAN.md`** — what's in flight, what's parked, security backlog

If you read these 6 in order you have enough context to avoid 95% of drift incidents.

---

## 3. Hard rules (you WILL be caught if you break these)

### 3.1 Production push gate
- **Only `level:admin` applies migrations to production.** No exceptions except `level:security` for CRIT security patches.
- You develop on **your own Supabase preview branch** keyed to your git branch name.
- You open a GitHub PR. The admin reviews per §9 of `MIGRATION_CONVENTIONS.md`. The admin merges.

### 3.2 Single-writer rule per table
- The lane that introduced a table is its **sole writer**.
- Other lanes can SELECT, define triggers (which fire on the writer's INSERTs), or reference via FK.
- They cannot INSERT / UPDATE / DELETE / TRUNCATE directly.

### 3.3 Migration header is mandatory
Every new migration **must** start with:
```sql
-- ============================================================================
-- Migration <timestamp> — <one-line summary>
-- Level:    <admin | security | supervisor | primary-sales | secondary-sales | data-collection>
-- Lane:     <descriptive lane name, e.g. "Terminal Front End">
-- Touches:  <table_a (W), table_b (W), table_c (R)>
-- Pre-reqs: <prior migrations, vault secrets, external services>
-- ============================================================================
```
PRs missing this get blocked. See `MIGRATION_CONVENTIONS.md` §6.

### 3.4 Log every meaningful change to `bot_chat`
After every commit or significant operation, insert a row to `bot_chat`:
```sql
SELECT bot_chat_log(
  p_level     => 'secondary-sales',           -- your level
  p_lane      => 'Terminal Front End',         -- your lane name
  p_event_type => 'change_log',                -- or question / flag / sync / status / collision
  p_subject   => 'what you did',
  p_body      => 'why',
  p_related_pr => <PR number>
);
```
Event-types `flag` and `p0_security` are routed to `level:security`; everything else to `level:admin`. The `v_bot_chat_unresolved` view is your triage queue.

### 3.5 Don't touch other lanes' tables, code, or migrations
Read `MIGRATION_CONVENTIONS.md` §2 (lane map) and §4 (single-writer rule). When in doubt, ask in `bot_chat` with `event_type = 'question'` and wait for admin.

### 3.6 No secrets in repo
Secrets live in **Supabase vault** or **Railway env vars** — never in source. See `MIGRATION_CONVENTIONS.md` §12 (vault whitelist).

---

## 4. Test environment

Every lane gets:
- **Own git branch** (named `claude/<lane>-<purpose>-<id>`)
- **Own Supabase preview branch** via `mcp__bccd...__create_branch(name=<git-branch-name>)`
- **Own sandbox schema** if applicable (e.g., `<lane>_test`)

You apply migrations and run smoke tests on the preview branch. Once it works, open the PR. Admin reviews and applies to prod.

**Never** call `apply_migration` against the production project_id. Use a branch_id only.

---

## 5. PR opening checklist

Every PR you open should declare (in the description):
1. **Level** (admin / security / supervisor / primary-sales / secondary-sales / data-collection)
2. **Lane** (e.g., "Terminal Front End", "Broadway Scraper")
3. **Tables touched** with W/R designation
4. **Migrations added** (timestamp + filename)
5. **Pre-reqs** (vault secrets, prior migrations, ops steps)
6. **Test plan** — what you verified on the preview branch

The `.github/PULL_REQUEST_TEMPLATE.md` pre-fills this. Don't delete fields.

GitHub labels matching your level (`level:admin`, `level:security`, etc.) will be applied automatically or by admin.

---

## 6. If you're confused

Open a `bot_chat` entry with `event_type = 'question'` and tag the relevant level in the body. Admin will respond in the next session.

If `bot_chat` doesn't exist yet (early sessions), comment on the relevant PR or open a GitHub issue tagged `bot-coordination`.

---

## 7. If you think these rules are wrong

You might be right. The rules are owned by `level:admin` but they're not infallible. Propose changes via:
1. A GitHub issue tagged `migration-conventions` with your proposed change + rationale
2. A `bot_chat` entry with `event_type = 'flag'` if it's urgent

**Do not edit the rules unilaterally.** That defeats the point.

---

## 8. Quick command reference

```bash
# What's my level + lane? (read your assigned worktree's notes, or ask Julian)

# Create a Supabase preview branch matching your git branch:
mcp__bccd...__create_branch(name='claude/your-branch-name')

# Apply migration to your preview (NOT production):
mcp__bccd...__apply_migration(branch_id='<preview-id>', name='<timestamp>_<desc>', query=...)

# Log to bot_chat:
SELECT bot_chat_log('<your-level>', '<your-lane>', 'change_log', '<subject>', '<body>', <pr_num>);

# Open a PR (after pushing your branch):
gh pr create --base main --head claude/your-branch --title "..." --body "..."
# Apply your level label:
gh pr edit <number> --add-label "level:<your-level>"
```

---

Last updated: 2026-05-11.
Owner: `level:admin` (audit lane). Anyone can read; only admin modifies.

**Welcome. Now go read the 6 docs in §2.**
