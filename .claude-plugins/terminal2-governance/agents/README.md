# Lane agents — the bots, made real

These are the Terminal-2 lanes encoded as **real, scoped Claude Code subagents**
(not prose conventions a session adopts). Invoke one with the `Agent` tool, e.g.
`subagent_type: b1-security` — or let a scheduled runner drive it (below).

Each agent carries its lane's mandate, write surface, and **hard limits** from
`BOT_HIERARCHY.md` + `CLAUDE.md`. The PostToolUse governance hooks (RULE-2 scanner,
docs gate) still enforce the immutable limits regardless of which agent runs.

## Roster

| Agent (`subagent_type`) | Lane | Owns | Recurring runner? |
|---|---|---|---|
| `a1-data-plane` | A1 | DB · pipeline · crons · DB-security · AQ mapper | freshness/cron sweep (planned) |
| `b1-git-code` | B1 | git history · code security · drift · tests · CI · deps | security sweep (planned) |
| `c1-docs-coord` | C1 | bible set · registry · promotions · shared-resource register · drift | docs/drift sweep (planned) |
| `d0-terminal` | D0 | broker terminal FE + `/api/broker/*` | none (interactive product work) |

D1–D4 are PAUSED (add `d1-store` … `d4-exos` on reactivation, same pattern).

## Autonomy matrix — what's autonomous vs operator-gated

Default autonomy is **Tier 2: propose via draft PR**. Nothing below crosses an
operator gate without a human. This is the lever for "reduce operator gating" —
widen the *Autonomous* column deliberately, one row at a time, once trusted.

| Action | Autonomous (Tier 2) | Operator-gated |
|---|---|---|
| Read / investigate / SELECT | ✅ any agent | — |
| Author a migration FILE | ✅ A1 | — |
| **Apply** a migration to prod | ❌ | ✅ A1 applies (CLAUDE.md §1) |
| Open a DRAFT PR | ✅ any agent | — |
| Merge a PR / push to main | ❌ | ✅ green-CI, per-task (humans for now) |
| Auto-merge green lower-bound Dependabot | ❌ (Tier 3 upgrade) | ✅ flip when trusted |
| Bump a dependency UPPER bound | ❌ | ✅ human verifies the major |
| Change branch protection / rotate secrets / edit a guard | ❌ | ✅ operator only (CLAUDE.md §2) |
| Edit another lane's surface | ❌ | coordinate via `bot_chat` / C1 |

## Scheduled runners (automate hygiene)

`.github/workflows/claude-maintenance.yml` is the **template** — a weekly,
Tier-2, draft-PR-only Claude run. The Direction-B plan adds per-lane runners
that drive a specific agent on a cron:

- **`b1-security-sweep`** (weekly) → drives `b1-git-code`: secret-scan review, dependabot triage digest, CI-gate health, aging-PR flags.
- **`a1-data-freshness`** (daily) → drives `a1-data-plane`: cron-failure / 429 / freshness / drift report (read-only; flags to `bot_chat`, never applies).
- **`c1-docs-drift`** (weekly) → drives `c1-docs-coord`: registry + bible-vs-reality drift, `graph-drift.mjs` fold-in.

Each runner: least-privilege perms, the credential-guard skip-if-unset step, and
the same hard-limits prompt block. These are **operator-gated to add** because they
need write permissions + the Claude credential secret — propose, don't self-enable.

## Adding / changing an agent
Edit the `*.md` here (frontmatter `name`/`description`/`tools` + the prompt body).
Keep `tools` least-privilege; encode hard limits explicitly — the prompt is the
real guardrail, tool-scoping is the second belt.
