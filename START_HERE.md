# START_HERE.md

**Bot? Read this in 2 minutes, then `MIGRATION_CONVENTIONS.md` for the rules.**

## Identify yourself
- **Level**: `admin` | `security` | `supervisor` | `primary-sales` | `secondary-sales` | `data-collection`
- **Lane**: descriptive role (e.g. "Terminal Front End", "Broadway Scraper")
- Assigned by Julian out-of-band. If you don't know, ask. Do not guess.

## Hard rules (5)
1. **Only `level:admin` pushes to prod.** Exception: `level:security` for CRIT patches. You develop on a Supabase preview branch.
2. **Single-writer per table.** The lane that made it owns writes. Others read or trigger.
3. **Every migration starts with this header** (one line):
   `-- Migration <ts> · level:<X> · lane:<Y> · writes:<table,table> · reads:<table,table> · pre:<vault.KEY,migration_ts>`
4. **Log to `bot_chat`** after every meaningful action: `SELECT bot_chat_log('<level>', '<lane>', '<event_type>', '<message>', <pr#>);`
5. **No secrets in repo.** Vault or Railway env only.

## Required reading
1. `docs/bot-hierarchy.mermaid` — where you fit
2. `MIGRATION_CONVENTIONS.md` — the full rules
3. `KANBAN.md` — what's in flight

## Your environment
- Git branch: `claude/<lane>-<purpose>-<id>`
- Supabase preview branch: `mcp__bccd...__create_branch(name=<git-branch>)`
- Never apply migrations to the prod project_id. Use a branch_id.

## PR rules
- Use `.github/PULL_REQUEST_TEMPLATE.md` — declares Level + Lane + Tables + Pre-reqs + Test plan
- Admin applies `level:<X>` label on review
- Admin merges per `MIGRATION_CONVENTIONS.md` §9

## Confused?
`bot_chat` `event_type='question'`. Admin responds.

## Token discipline
- Short PR descriptions, short comments, single-line headers
- Don't re-render the hierarchy — link `docs/bot-hierarchy.mermaid`
- Skip closers like "Standing by"

Owner: `level:admin`.
