# docs/archive/ — historical, non-canonical

Everything in this folder is **superseded or point-in-time**. It is kept only for the **decision trail** — to show *why* the project is the way it is. **Do not treat anything here as current.** None of it is loaded at session start, and none of it is part of the closed canonical doc set.

**For current truth, start at the repo root:** [`../../README.md`](../../README.md) holds the canonical doc registry (the closed set of ~11 root docs) and the reading order. If a fact here conflicts with a canonical doc, the canonical doc wins.

## What landed here (2026-05-28 documentation consolidation)

- **Stale root docs** that contradicted the canonical set or duplicated an entry point — `START_HERE.md`, `DOCUMENTATION_INDEX.md`, `AGENTS.md`, `COWORKER_ONBOARDING.md`, `SESSION_2026-05-07.md`, `SESSION_2026-05-13.md`, `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md`, `INSTRUCTIONS_FOR_COPILOT.md`.
- **Two docs folded into a canonical owner** (their live content now lives in the owner; the original is preserved here):
  - `LANE_DISCIPLINE.md` → folded into [`../../BOT_HIERARCHY.md`](../../BOT_HIERARCHY.md) (roster · push authority · per-lane scope).
  - `SCHEMA.md` → its event taxonomy + RULES folded into [`../../RESOURCES_BIBLE.md`](../../RESOURCES_BIBLE.md).
- **Dated / working-note files** from `docs/` — audits, checkpoints, handoffs, session logs, dated snapshots, and the earlier (failed) consolidation attempts (`markdown_inventory.md`, `audit-2026-05-15-consolidation-plan.md`, `audit-2026-05-15-schema-sprawl.md`). Subtree structure is preserved (e.g. `coworker-handoff/`).

## Why a gate now exists

The sprawl this folder cleaned up had regrown **once before** because nothing stopped new docs from being created. It won't regrow silently again: `bin/check-docs.sh` + `.github/workflows/docs-registry-check.yml` fail any PR that adds an off-registry root `*.md` or drops a dated/working-note file into `docs/` outside this archive. See `../../README.md` *Doc-writing rules* and `CLAUDE.md §6`.

**Adding history here is fine** — that's what this folder is for. Use the form `docs/archive/YYYY-MM-DD-<topic>.md` for a durable dated artifact. **Never** add a new doc at the repo root or in `docs/` proper.
