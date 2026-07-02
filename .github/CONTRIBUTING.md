# Contributing to Terminal-2

Terminal-2 is a multi-bot orchestrated ticket-trading intelligence platform. The contributor population is:

- **Internal bots** (A1, B1, C1, D0, D1, D2, D3, D4, E1) — most commits land via this path
- **Human operator** (`@JulianS4K`) — sole approver / sole pusher to `main`
- **Outside contributors** — rare, but welcomed for security disclosures + bug reports

## If you're a bot

Read these in order:

1. [`PROJECT_BIBLE.md`](../PROJECT_BIBLE.md) — operating playbook (hard rules, **§2 lane assignment / your write surface** — roster · push authority · per-lane scope, absorbed `BOT_HIERARCHY.md`; SQL macros; column-name landmines)
2. [`KANBAN.md §🟢 OPEN`](../KANBAN.md) — what's actionable right now (severity-sorted)
3. [`CLAUDE.md`](../CLAUDE.md) — security rules + 2026-05-13 lockdown
4. [`MIGRATION_CONVENTIONS.md`](../MIGRATION_CONVENTIONS.md) — if authoring migrations
5. Your lane scope is in **`PROJECT_BIBLE.md §2`** (per-bot self-contracts were retired there 2026-06-19; only `docs/b1_operating_constraints.md` remains, for the security severity matrix)

## If you're a human contributor

### Reporting bugs

1. For **security** vulnerabilities: see [`SECURITY.md`](SECURITY.md) — use Private Vulnerability Reporting, do NOT open a public issue.
2. For **non-security** bugs: open a GitHub Issue using the "Bug report" template. Include reproduction steps + expected vs actual behavior + which hosted surface (terminal / storefront / dashboard).

### Proposing features

Open a GitHub Issue with the "Feature request" template. For larger architectural proposals, open a GitHub Discussion in the "Ideas" category (when enabled) instead — it allows threaded conversation before code lands.

### Pull request flow

We don't accept code PRs from outside contributors in the general case (single-operator product). If you have a focused fix:

1. Fork the repo
2. Branch off `main` with prefix `external/<your-handle>-<slug>`
3. Follow [`MIGRATION_CONVENTIONS.md`](../MIGRATION_CONVENTIONS.md) if your change touches `supabase/migrations/`
4. Open a PR using the [PR template](PULL_REQUEST_TEMPLATE.md)
5. CI must pass (`forbidden-paths-check`, `secret-scan`, `pytest`)
6. Wait for `@JulianS4K` review — turnaround ~1 week

Note: PRs that touch backend code (`app.py`, `supabase/*`, `*_client.py`) require CODEOWNERS review per [`.github/CODEOWNERS`](CODEOWNERS).

## Code style

- Python: follow existing patterns in `server.py`; no formal `black`/`ruff` enforcement currently
- SQL: lowercase keywords are fine; column names match the table they read from (see `PROJECT_BIBLE.md §3` landmines)
- TypeScript (edge functions): match the style of `supabase/functions/_shared/cron-auth.ts`

### Code reference conventions (stable references)

Comments that cite *where* something lives are only useful if the citation
survives a refactor. Cite things that are stable, never things that move:

- **Do** reference migration IDs (`mig 20260520130000`), PR numbers (`PR #114`),
  audit dates (`audit 2026-05-16`), test names, and function/symbol names
  (`the safe_q re.sub above`). These survive file moves and line shifts.
- **Don't** reference line numbers (`line ~4467`) or the names of files that no
  longer exist (e.g. the pre-decomposition `app.py` monolith). They rot the
  instant code moves — and this repo has already decomposed `app.py` into
  `server.py` + `routers/*`, so any `app.py:NNNN` comment is now a dead pointer.
- When you touch a comment carrying a stale line/file reference, fix it to a
  stable anchor rather than updating the number.

## Commit messages

Format: `<type>(<lane>): <short imperative>` per [`docs/pr_governance.md`](../docs/archive/pr_governance.md).

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`.

Lane shorthand: `a1`, `b1`, `c1`, `d0`, `d1`, `d2`, `security`, `bibles`, `governance`.

Example: `chore(security): GitHub capabilities audit 2026-05-17 — 11 new findings`

## Communication

- **Cross-lane coordination**: `bot_chat` table (Supabase) — durable, append-only
- **Long-form decisions / RFC**: GitHub Discussions → "Ideas" or "Decisions" category (when enabled)
- **Operator broadcasts**: bot_chat `event_type='broadcast'` OR Slack `#terminal-2-alerts` (per [`CLAUDE.md §4`](../CLAUDE.md))

## Code of conduct

Be excellent to each other. This project is single-operator-led; disagreements get resolved by the operator. No tolerance for harassment, doxxing, or deliberately misleading bot behavior (impersonation).
