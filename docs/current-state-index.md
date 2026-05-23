# Current-State Index — 2026-05-15

Author: C1 (part of Cluster E of the [audit + consolidation plan](docs/audit-2026-05-15-consolidation-plan.md)).

Single entry-point to the authoritative docs describing prod state today. Prior point-in-time audits are referenced but **not deleted** — they remain valid snapshots of their date.

## Canonical (read these first)

| Doc | Purpose | Last refresh |
|---|---|---|
| [CLAUDE.md](CLAUDE.md) | Global operator rules, standing permissions, lane scoping | 2026-05-13 |
| [LANE_DISCIPLINE.md](LANE_DISCIPLINE.md) | Per-bot scope; C1 section refactored 2026-05-14 (PR #109) | 2026-05-14 |
| [BOT_HIERARCHY.md](BOT_HIERARCHY.md) | Push restrictions matrix | — |
| [MIGRATION_CONVENTIONS.md](MIGRATION_CONVENTIONS.md) | Filename, header, lane rules; PR #55 (2026-05-10) | 2026-05-10 |
| [PROJECT_BIBLE.md](PROJECT_BIBLE.md) | Operating playbook (rules + hierarchy + RPCs + column landmines + macros + recipes). Read FIRST every session. | 2026-05-16 |
| [RESOURCES_BIBLE.md](RESOURCES_BIBLE.md) | Living inventory (services, tables, matviews, views, crons, edge fns, vault, extensions, HTTP surface). | 2026-05-16 |
| [docs/pr_governance.md](docs/pr_governance.md) | PR governance principles: one-concern-per-PR, size targets, squash-merge, branch-update protocol, lane sign-off. **A1-ratified 2026-05-16** (PR #145). | 2026-05-16 |
| [docs/release-discipline.md](docs/release-discipline.md) | "Apply-then-codify" discipline; PR #94 anti-drift example | — |
| [docs/bot_chat_conventions.md](docs/bot_chat_conventions.md) | `bot_chat` event types, resolve protocol | 2026-05-15 (NEW) |
| [docs/c1_daily_checkpoint_runbook.md](docs/c1_daily_checkpoint_runbook.md) | C1's daily 8-step routine | 2026-05-14 |
| [docs/c1_operating_constraints.md](docs/c1_operating_constraints.md) | C1 self-contract | 2026-05-14 |
| [docs/c1_quality_continuity_charter.md](docs/c1_quality_continuity_charter.md) | C1 Quality & Continuity charter — 6 monitor+route duties (data-quality, cost, DR, operator-queue, credential-lifecycle, E2E). Operator-directed 2026-05-17. | 2026-05-17 |

## Today's working docs

| Doc | Purpose |
|---|---|
| [docs/c1-checkpoint-2026-05-15.md](docs/c1-checkpoint-2026-05-15.md) | First C1 daily checkpoint post-reassignment |
| [docs/audit-2026-05-15-consolidation-plan.md](docs/audit-2026-05-15-consolidation-plan.md) | This week's audit + consolidation plan (6 clusters) |
| [docs/bot_chat_conventions.md](docs/bot_chat_conventions.md) | bot_chat conventions (Cluster D-3) |

## Point-in-time audits (historical, valid for their date)

These remain accurate **as of their date**. Where today's state differs, this index supersedes; the audit doc is not edited retroactively.

| Doc | Date | Topic | Still relevant? |
|---|---|---|---|
| [docs/audit-2026-05-14-data-stability.md](docs/audit-2026-05-14-data-stability.md) | 2026-05-14 | Advisor 486→5 sweep; ESPN/cross-source FKs | **Yes** — most A1 work today builds on this |
| [docs/state-delta-since-c1-audit-2026-05-12.md](docs/state-delta-since-c1-audit-2026-05-12.md) | 2026-05-12 | Delta log post-merge-wave | Partial — superseded by 5/14 audit on advisor counts |
| [docs/audit-handoff-2026-05-11.md](docs/audit-handoff-2026-05-11.md) | 2026-05-11 | Handoff anchor | Archived |
| [docs/data-sources-audit-2026-05-11.md](docs/data-sources-audit-2026-05-11.md) | 2026-05-11 | Ingest health + freshness inventory | Partial — freshness data outdated; structure valid |
| [docs/audit-2026-05-09.md](docs/audit-2026-05-09.md) | 2026-05-09 | General audit | Archived |
| [docs/full-audit-2026-05-09.md](docs/full-audit-2026-05-09.md) | 2026-05-09 | Full audit | Archived |
| [docs/database-audit-2026-05-09.md](docs/database-audit-2026-05-09.md) | 2026-05-09 | Schema + RLS + SECDEF state | Superseded by 5/14 |
| [docs/broker-audit-2026-05-08.md](docs/broker-audit-2026-05-08.md) | 2026-05-08 | Data source API surface | Partial — broker pipeline changed since |
| [docs/sync-audit-2026-05-08.md](docs/sync-audit-2026-05-08.md) | 2026-05-08 | Repo-to-prod alignment | Archived |
| [docs/storage-audit-2026-05-08.md](docs/storage-audit-2026-05-08.md) | 2026-05-08 | Storage state | Archived |
| [docs/workflow-audit-2026-05-08.md](docs/workflow-audit-2026-05-08.md) | 2026-05-08 | Workflow | Archived |

## Archival policy

**Non-destructive** (the choice per plan §"Open questions" Q3 default): old audits stay in `docs/` with their original name; this index annotates them. No `git mv`. Rationale: past `bot_chat` rows reference these paths; moving them breaks history.

If operator chooses destructive later, the `git mv docs/audit-2026-05-{08,09,11,12,14}-*.md docs/archive/` is a one-shot that updates these table paths.

## How to use this index

- **Onboarding a new bot session**: read all entries in §"Canonical" + the most recent checkpoint and audit plan.
- **Investigating a regression**: cross-reference today's checkpoint with the prior 5/14 audit for the day-over-day delta.
- **Planning new work**: consult [LANE_DISCIPLINE.md](LANE_DISCIPLINE.md) + this index's §"Today's working docs" first.

## Maintenance

Updated by C1 daily as part of the checkpoint routine (whenever a new audit or checkpoint doc lands).
