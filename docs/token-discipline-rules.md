# Token Discipline Rules

Author: C1. Charter: bot_chat 139 (operator directive 2026-05-15).

Token cost is real and additive across every bot session. Each rule below comes from an observed bloat pattern. Compliance is enforced via C1 daily Step 9 audit; non-compliance flagged in `bot_chat`, original author re-compresses on next post.

## Migration headers

**≤15 lines.** Include only: top matter (`-- Migration ts · level · lane · writes:X · pre:Y`), AUTH gate (if any), structural intent (what the migration does in 2–4 lines), composes/touches list. Defer rationale, design notes, and post-apply verification SQL to `docs/release-discipline.md` or the PR description.

Model example: [supabase/migrations/20260515330000_health_check_pg_net_errors.sql](supabase/migrations/20260515330000_health_check_pg_net_errors.sql) — 7-line header. Anti-examples + proposed trims: see [docs/audit-2026-05-15-migration-header-bloat.md](docs/audit-2026-05-15-migration-header-bloat.md).

## `bot_chat` posts

**≤1500 chars per row.** Long entries should be linked to a doc or PR; the row is the pointer + tldr. Specific anti-patterns:
- Restating context already in the parent thread (`in_reply_to` is enough).
- Re-listing items already in a referenced doc.
- Multi-section preamble before the substantive point.

Compress at write time; if a post must exceed 1500 chars, split into a `change_log` (history) + a `flag` (action).

## Response shape

These apply to every bot's prose output, not just bot_chat:
- **Drop "Want me to do X next?"** — either do it (if in lane and safe) or ask one direct question.
- **Skip affirmation preamble** ("Great question!", "I'll get right on that") — silence after a directive = agreement.
- **No re-summarizing state at top of multi-section responses** — assume the reader has the prior turn.
- **Plan review pattern**: deltas only. If something is unchanged, omit it.

## MCP / SQL queries

- **Count + aggregate first**, full rows only on demand.
- **Narrow columns**: don't `SELECT *` from `bot_chat` or `cron.job` when you need 4 columns.
- **`LIMIT 5–10` by default**; raise only if the analysis requires more rows.
- **Batch parallel queries in one message** — the harness can run 5+ MCP calls in parallel.

## File I/O

- **Don't re-read files just edited** — Edit/Write errors if state diverges.
- **Glob before Read** when fishing for a file; saves a Read on a wrong path.
- **Use Grep `output_mode='count'` or `files_with_matches`** before reaching for `'content'`.

## Pre-merge code audit (added 2026-05-15)

C1 runs this audit on every PR being merged as part of consolidation. Findings flagged in `bot_chat` (or PR comments); blocking is reserved for genuine waste, not edge cases.

**Scan the diff for:**

1. **File-header docstrings >15 lines** (Python, SQL, JS). Same budget as migration headers. The header should state purpose + auth/security gate + key invariants. Bug history, PR rationale, audit refs → PR description or commit message.
2. **`pre:` dependency list mega-strings in migrations.** If a migration lists 10+ prerequisites in one line, only the truly load-bearing ones (functions/tables the migration touches) belong. The chronological "everything since X" is noise.
3. **Inline comments that restate the code in English.** If a 2-line `if` is preceded by a 3-line comment describing what the `if` does, the comment is waste. Comments should explain *why*, not *what*.
4. **Near-duplicate functions** (e.g., `fetch_evo()`, `fetch_seatgeek()`, `fetch_tickpick()` all calling `fetch_one("name")`). Collapse into the parametric form.
5. **Commented-out code.** Delete it; git remembers.
6. **Unused imports / dead variables** flagged by linting.
7. **Audit refs / "see doc §X" cross-references in code.** Useful in PRs and bot_chat, redundant in code that lives forever. The code IS the audit ref once merged.
8. **Verbose error messages** that include "consult bot X" or "see runbook §Y" — those don't reach the next bot anyway; throw cleanly with the structural error.

**Disposition:** if findings exist, file a `flag` in `bot_chat` addressed to the lane owner; merge proceeds unless the finding is structural (e.g., genuine dead code or near-duplicate functions). Lane owner re-compresses on next PR.

## C1 daily Step 9 — token discipline audit

Added to [docs/c1_daily_checkpoint_runbook.md](docs/c1_daily_checkpoint_runbook.md). Each checkpoint:
1. Scan `supabase/migrations/*.sql` modified in the last 24h for headers >15 lines. Flag with line count + proposed trim.
2. `SELECT id, length(message) FROM bot_chat WHERE created_at > now() - interval '24 hours' AND length(message) > 1500` — flag oversized rows.
3. Note any anti-pattern responses from the daily checkpoint review (self-audit; C1 is not exempt).

## Quarterly token efficiency report

C1 produces `docs/token-efficiency-YYYY-QN.md` 4×/year. Top 5 bloat patterns observed + remediation status. Pairs with the rule-update review.

## When to break a rule

These rules optimize for the common case. Genuinely required context (a security boundary, a non-obvious invariant, a one-time root-cause writeup) can exceed budgets — but the exception must be load-bearing and named in the deviation.
