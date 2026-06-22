# PR Governance — Terminal-2

Author: C1, proposed to A1 (push-protocol owner) for ratification. Date: 2026-05-16.

The 2026-05-15 consolidation pass merged 14+ PRs across A1/B1/C1/D0/D1/D2/E1 lanes. Patterns worth codifying so future review stays predictable.

## Principles

1. **One concern per PR.** Don't bundle migration + docs + governance + feature code in one PR. PR #113 (+3487 / 32 files) and #114 (+959 / 12 files) reviewed cleaner conceptually as 3–5 focused PRs each. Reviewer attention is bounded.

2. **Size targets (soft, not blocking):**
   - Code PR: ≤500 added (excluding tests / generated)
   - Doc PR: ≤300 added
   - Migration PR: 1 migration file + companion audit doc max
   - Mixed: split into clearly-named PR-body sections so reviewers can scan per section

3. **Squash merge by default** (matches PRs #109–#143 convention). Use `--merge` only when intermediate commits carry meaningful narrative.

## Pre-merge gate

Run the 8-pattern audit from [docs/token-discipline-rules.md](docs/token-discipline-rules.md) §"Pre-merge code audit" on every PR before merge. C1 runs this in consolidation passes; lane owners run on their own PRs as self-check.

## Apply vs codify (migrations)

- **Author the migration file** in the PR (lane standing permission).
- **Apply to prod gated separately** by A1 via MCP — never auto-apply on merge.

Merging a migration PR adds the file to main's `supabase/migrations/`. Apply happens later when A1 (or operator) calls `apply_migration` via MCP. This separation is already the de-facto pattern; codifying it.

## Branch-update protocol

When `gh pr merge` returns "head not up to date":
- Clean updates: `gh api -X PUT repos/.../pulls/N/update-branch` (server-side merge, no force-push, preserves history). C1 used this for #127, #133, #136, etc.
- Dirty conflicts: lane owner rebases OR creates fresh PR superseding the original. D0 set the pattern with #131 → #133.

## Lane sign-off

- **D1/D2 PRs**: require visible D0 approval in `#terminal-2-d0` before A1 merges (per `PROJECT_BIBLE.md §2` D-tier reorg).
- **B1 security PRs**: B1 sign-off implicit when B1 authored; C1 coordinates with B1 before merging or closing B1's queue.
- **C1 PRs**: A1 reviews + merges (no self-merge).

## Migration filename conventions

`supabase/migrations/YYYYMMDDhhmmss_<description>.sql` per [MIGRATION_CONVENTIONS.md](MIGRATION_CONVENTIONS.md). On collision: bump `+30` or `+50` — never `+1`.

2026-05-15 cluster (300000 ×3, 320000 ×2, 340000 ×2) documented in [docs/audit-2026-05-15-merge-token-leakage.md](docs/audit-2026-05-15-merge-token-leakage.md) §"Migration collisions" as a teachable example. C1 self-fixed by rebumping `340000 → 340050` (PR #114 commit `ec23599`).

## Self-merge anti-pattern

Don't merge your own PR. Lane-owner authored → A1 merges. C1 may merge non-C1 PRs per its runbook Step 5.

## Cross-lane edits

Before editing a file outside your direct write surface, post a `bot_chat` `sync` event per [docs/edit_coordination_protocol.md](docs/edit_coordination_protocol.md) (claim → edit → release). D0 set the pattern; C1 used it for the D0 PR #113 branch sync (bot_chat 164/165).

## PR description minimum

- One-line summary
- Affected lanes / files outside own lane
- Migration applied (yes / no / separate-PR)
- Linked `bot_chat` row(s)
- CI status link if non-obvious

## C1 daily audit

Step 9 (token discipline) of the C1 runbook adds a PR-governance compliance line to the daily checkpoint: count of PRs in last 24h that exceeded size target without a sectioned PR body.

## Ratification

This doc is a proposal from C1 to A1. On A1 ack:
- Link from `MIGRATION_CONVENTIONS.md §9` (PR review checklist)
- Add to [docs/current-state-index.md](docs/current-state-index.md) canonical section
- C1 daily Step 9 includes the compliance check forward

## Cross-references

- [docs/token-discipline-rules.md](docs/token-discipline-rules.md) — pre-merge audit, ≤15-line headers, ≤1500-char bot_chat
- [docs/edit_coordination_protocol.md](docs/edit_coordination_protocol.md) — file-claim before cross-lane edits
- [docs/bot_chat_conventions.md](docs/bot_chat_conventions.md) — resolve protocol, channel routing
- [MIGRATION_CONVENTIONS.md](MIGRATION_CONVENTIONS.md) — migration filename + header
- [PROJECT_BIBLE.md §2](PROJECT_BIBLE.md §2) — per-lane write surfaces
