# DOCUMENTATION_INDEX.md

Authoritative map of every doc in the Terminal-2 repo, organized by what each bot needs to read.
**Anchored to checkpoint** `main-checkpoint-2026-05-13-post-cleanup` (commit `70fbbdf`).

> Updated 2026-05-13 after the cleanup sweep that landed 9 PRs (#70, #73, #81, #82, #84, #85, #86, #87, #88), closed 4 (#69, #76, #77, #79), reset the bot roster to the A1/B1/C1/D1/D2 hierarchy, and codified the operator lockdown protocol.

---

## TL;DR

- **One umbrella, three layers**:
  - **Universal must-reads** (§1) — every bot reads these.
  - **Per-bot self-contracts** (`docs/<bot>_operating_constraints.md`) — each bot owns its own.
  - **Coordination surface** — `bot_chat` table (cross-bot append-only log).
- **70+ markdown files total** across the repo. New since 2026-05-10: `BOT_HIERARCHY.md`, `RESOURCES_BIBLE.md`, `SYNC_PROTOCOL.md`, `LANE_DISCIPLINE.md`, `CLAUDE.md`, `START_HERE.md`, `docs/c1_operating_constraints.md`, `docs/d1_operating_constraints.md`, `docs/d1_pending_merge_back.md`, plus two templates.
- **Operator lockdown protocol** (active since 2026-05-13): SQL data, TEvo, SeatGeek, TickPick, Vivid, GoTickets, SeatData are **all read-only by default**. Standing permissions: `bot_chat_log()`, Supabase branch creation, migration-file authoring. Everything else needs explicit operator OK each time. See `CLAUDE.md` + `docs/c1_operating_constraints.md`.
- **Bot roster has changed** since the 2026-05-10 version of this doc: `code` / `canonical` / `broadway` / `storefront` are replaced by **A1 / B1 / C1 / D1 / D2** (see §2). Old worktree-name references are obsolete.

---

## 1. Universal must-reads (every bot, in this order)

| # | Doc | Why | Updated |
|---|---|---|---|
| 1 | **`START_HERE.md`** | 2-minute onboarding. Hard rules, required reading list, environment setup. Read FIRST. | 2026-05-13 |
| 2 | **`BOT_HIERARCHY.md`** | Push restrictions matrix, single-writer table ownership, fast-path workflow, lane chart. | 2026-05-12 |
| 3 | **`LANE_DISCIPLINE.md`** | Per-lane operating rules (detail). Companion to `BOT_HIERARCHY.md`. | 2026-05-13 |
| 4 | **`SYNC_PROTOCOL.md`** | Track choice (Fast / Careful / Emergency), slot reservation, apply-before-PR, broadcast format. | 2026-05-13 |
| 5 | **`MIGRATION_CONVENTIONS.md`** | Migration header convention, single-writer rule, A1 push gate. | 2026-05-10 |
| 6 | **`RESOURCES_BIBLE.md`** | Living inventory: tables, views, crons, edge fns, vault secrets, external services. | 2026-05-13 |
| 7 | **`CLAUDE.md`** | Auto-loaded by Claude Code on every session — operator lockdown protocol summary. | 2026-05-13 |
| 8 | **`KANBAN.md`** | Live work board, proxy-commit pattern, parked items. | live |

If you read these eight (~45 min) you have enough context to avoid 95% of drift incidents.

**Then read your own self-contract**: `docs/<lane>_operating_constraints.md` (see §3).

---

## 2. Bot roster (current — supersedes `AGENTS.md` which is stale)

The 2026-05-12 hierarchy restructure (PR #74) renamed lanes to a single-letter+digit scheme:

| Lane | Level | Owns | Active worktree pattern |
|---|---|---|---|
| **A1** | admin | DB schema, **sole prod migration applier**, cron, edge fns (admin-owned), governance docs, push to `main` | `claude/resume-a1-*` |
| **B1** | security | RULE 2 audits, SECURITY DEFINER hardening, vault grants, `_security_*` migrations | `claude/fix-security-*`, `claude/security-*` |
| **C1** | supervisor | Schema canonical (xref, drift triggers, overlays), audit reports, supervisor-authored migrations | `claude/audit-data-sources-*`, `claude/feat-c1-*` |
| **D1** | data-collection | Consumer Retail storefront: `app.py` storefront routes, `static/store/*`, `share_links`, Render (sole owner) | `claude/d1-*`, `claude/resume-d1-*`, `claude/store-*` |
| **D2** | data-collection | Broker order pulls (Evo, SG, TickPick, Vivid, GoTickets, SeatData), `*_client.py`, `_pending` tables, `tests/`, `d2_dashboard/` | `claude/d2-*`, `claude/resume-d2-*`, `claude/continue-d2-*` |

**Paused / superseded** (pre-rename): `code` lane → became A1+C1 split. `claude design` and `copilot` not in current rotation.

**Coordination surface**: `bot_chat` table (`bot_chat_log()` RPC). Append-only, all lanes can write. Used for cross-lane sync, change_log, flag, question events. Latest row: 91 (B1 get_app_secret lockdown).

---

## 3. Per-bot self-contracts

Each bot has its own contract under `docs/`. These layer **below** `LANE_DISCIPLINE.md` — they're operational detail, not authority. Always-must-match: `BOT_HIERARCHY.md` > `LANE_DISCIPLINE.md` > `docs/<bot>_operating_constraints.md`.

| Lane | Contract doc | Highlights |
|---|---|---|
| **A1** | _(implicit — A1 is the authority layer; no self-contract needed)_ | |
| **B1** | _(none yet — recommend adding `docs/b1_operating_constraints.md` for the security lane)_ | |
| **C1** | `docs/c1_operating_constraints.md` | Read/write surface, forbidden actions, historical drift (#61/#64/#65/#68 prod migrations) ack |
| **D1** | `docs/d1_operating_constraints.md` | Read surface (TEvo + 15 Supabase tables), write surface (storefront routes only), Sprint 2 freeze conditions |
| **D2** | _(implicit via `LANE_DISCIPLINE.md` + per-`*_client.py` RULE 2 guards)_ | |

**Pattern template**: `docs/templates/bot_lane_constraints_template.md` (D1-authored, PR #84).
**Cross-bot template**: `docs/templates/LANE_DISCIPLINE.template.md` (C1-authored, PR #82) — skeleton for future multi-bot projects.

---

## 4. Categorized inventory (full)

### 4.1 — Governance + cross-bot (root, **all must-read**)

| File | Purpose | Updated |
|---|---|---|
| `START_HERE.md` | 2-min onboarding | 2026-05-13 |
| `BOT_HIERARCHY.md` | Push matrix, lane chart, hierarchy diagram | 2026-05-12 |
| `LANE_DISCIPLINE.md` | Per-lane operating rules | 2026-05-13 |
| `SYNC_PROTOCOL.md` | Track + sync rules | 2026-05-13 |
| `MIGRATION_CONVENTIONS.md` | Migration rules | 2026-05-10 |
| `RESOURCES_BIBLE.md` | Living resource inventory | 2026-05-13 |
| `CLAUDE.md` | Operator lockdown protocol (auto-loaded) | 2026-05-13 |
| `KANBAN.md` | Live work board | live |
| `README.md` | Top-level orientation | live |
| `SCHEMA.md` | Schema reference | live |
| `AGENTS.md` | **STALE** — pre-A1/B1/C1/D1/D2 rename. Pending refresh. | 2026-05-09 |
| `COWORKER_ONBOARDING.md` | Design coworker onboarding (historical) | 2026-05-09 |
| `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md` | Design lane spec (paused) | 2026-05-09 |
| `INSTRUCTIONS_FOR_COPILOT.md` | Copilot spec (paused) | live |
| `SESSION_2026-05-07.md` | Historical session log | static |

### 4.2 — Per-bot self-contracts + templates (`docs/`)

| File | Owner | Updated |
|---|---|---|
| `docs/c1_operating_constraints.md` | C1 | 2026-05-13 |
| `docs/d1_operating_constraints.md` | D1 | 2026-05-13 |
| `docs/d1_pending_merge_back.md` | D1 | 2026-05-13 — known-deferred work |
| `docs/templates/LANE_DISCIPLINE.template.md` | C1 (cross-project template) | 2026-05-13 |
| `docs/templates/bot_lane_constraints_template.md` | D1 (per-bot template) | 2026-05-13 |

### 4.3 — Punch lists / next-steps (`docs/`)

| File | Purpose |
|---|---|
| `docs/d1_retail_finish_punchlist.md` | A1-authored: what D1 needs to finish for retail MVP |
| `docs/evo_store_next_steps.md` | A1-authored: next-steps notes for evo-store integration |

### 4.4 — Audit + system state (`docs/`)

`docs/audit-2026-05-09.md`, `docs/audit-handoff-2026-05-11.md`, `docs/broker-audit-2026-05-08.md`, `docs/cron-and-queue-health-2026-05-11.md`, `docs/cron-landscape-2026-05-09.md`, `docs/data-sources-audit-2026-05-11.md`, `docs/database-audit-2026-05-09.md`, `docs/database-map-2026-05-09.md`, `docs/full-audit-2026-05-09.md`, `docs/function-inventory-2026-05-11.md`, `docs/storage-audit-2026-05-08.md`, `docs/sync-audit-2026-05-08.md`, `docs/workflow-audit-2026-05-08.md`

### 4.5 — Schema + data flow (`docs/`)

`docs/canonical-data-map-2026-05-09.md`, `docs/canonical-mapping-notes-2026-05-10.md`, `docs/cross-source-entity-resolution-2026-05-11.md`, `docs/data-sources-terminal-uses.md`, `docs/evo-seatgeek-field-mapping-2026-05-09.md`, `docs/historical-data-and-multi-view-strategy-2026-05-09.md`, `docs/terminal-data-inventory.md`, `docs/tevo-api-workflow.md`, `docs/concerts-broadway-tours-residencies.md`, `docs/mlb-game-series-detection.md`, `docs/tournament-event-detection.md`, `docs/knicks-next-home-event-snapshot-2026-05-09.md`

### 4.6 — Operations (`docs/`)

`docs/seatdata-blocker-2026-05-09.md`, `docs/weather-sources-2026-05-09.md`, `docs/wikipedia-usage-2026-05-09.md`

### 4.7 — Design + UI

`docs/retail-ui-kit.md`, `docs/terminal-redesign-2026-05-09.md`, `docs/phase2-ui-kanban.md`, `docs/interactive-venue-maps-options.md`, `docs/event-view-wireframe-v3.md`, `docs/event-view-wireframe-v4.md`, `docs/performer-view-wireframe-v5.md`, all `design/*.md` (16 files)

### 4.8 — SeatGeek subdir

`docs/seatgeek/kanban-tasks.md`, `docs/seatgeek/migration-guide.md`

### 4.9 — Coworker handoff (`docs/coworker-handoff/`)

`SCOPE.md`, `HANDOFF_INSTRUCTIONS.md`, `QUERY_CATALOG.md`, `QUERY_COOKBOOK.md`, `DATA_QUALITY_DASHBOARD.md`, `PHASE_2_HANDOFF.md`

### 4.10 — Visual

`docs/bot-hierarchy.mermaid` — companion to `BOT_HIERARCHY.md` (rendered diagram)

---

## 5. Checkpoint tags

| Tag | Commit | Notes |
|---|---|---|
| `phase1-baseline` | `b1ab0c4` | PR #49 era (ESPN xref + performer matcher) |
| `d1-mvp-prod-checkpoint-2026-05-13` | `7913c20` | D1 MVP TEvo-direct, on now-closed `claude/d1-mvp-tevo-direct` |
| `main-checkpoint-2026-05-13-pre-cleanup` (local only) | `e1ad31e` | Anchor BEFORE the 2026-05-13 cleanup sweep |
| **`main-checkpoint-2026-05-13-post-cleanup`** (local only) | `70fbbdf` | Anchor AFTER the cleanup sweep — **all new bot_chat coordination references this** |

Remote tag push currently 403s on the proxy — local tags only. Commit SHAs are the authoritative rollback anchors.

---

## 6. The 2026-05-13 cleanup sweep (what just landed)

### 6.1 — PRs merged (9)

| PR | Title | Squash SHA |
|---|---|---|
| #81 | `fix(evo_client)`: correct Response truthiness in error logger | `cadd966` |
| #70 | `feat(infra)`: Render MCP server config | `bcab8fa` |
| #73 | `docs(session)`: D2 session note 2026-05-13 | `b94b916` |
| #87 | `fix(security)`: REVOKE get_app_secret from anon/authenticated + body assert | `78673c5` |
| #86 | `feat(admin)+feat(d2)`: cron IO diet (P0) + GoTickets client (1/3) | `0237f20` |
| #84 | `feat(store)`: D1 MVP TEvo-direct + Sprint 1.5 UX + D1 self-contract | `3971416` |
| #85 | `feat(d2)`: unified orders dashboard | `99cf145` |
| #82 | `feat(c1)`: lockdown protocol + CLAUDE.md + media test surface | `5c6b8e7` |
| #88 | `docs(governance)`: LANE_DISCIPLINE.md — cherry-pick from #69 | `70fbbdf` |

### 6.2 — PRs closed as superseded (4)

| PR | Reason |
|---|---|
| #76 | Static commits landed via #84 cherry-pick. 4 app.py polish commits deferred to follow-up D1 PR (see `docs/d1_pending_merge_back.md`). |
| #77 | `docs/d1_operating_constraints.md` landed via #84 cherry-pick. |
| #79 | Full diff landed as #84's bundle base. Prod tag preserved. |
| #69 | `LANE_DISCIPLINE.md` cherry-picked via #88. Other content already in main via #82 + #84. |

### 6.3 — P0 incident timeline (cron IO budget)

| Time (UTC) | Event |
|---|---|
| 17:34 | `jobid 98 zone-backfill-isolated-10min` begins failing — `backfill_stale_zone_metrics(3)` seq-scans `listings_snapshots` (2.4 GB / 2.7M rows) every 10 min for `MAX(captured_at) GROUP BY event_id` driver CTE |
| 17:44, 17:54 | Statement timeouts after 132s, 203s |
| 18:04:21 | **Postgres server restart** (IO budget exhausted) |
| 18:07 | Cloudflare 522 surfaces on `d2_dashboard` (PR #85) sign-in flow |
| 18:25 | A1 pauses all 70 active cron jobs (`bot_chat` row 88) |
| 18:50 | A1 applies `cron_io_diet` migration (version `20260513185058`) — 69 jobs re-enabled at leaner cadences, job 98 stays paused |
| 18:53 | B1 (from D2 session) applies `security_get_app_secret_lockdown` (version `20260513185248`) — REVOKE EXECUTE from anon/authenticated |
| 19:00–19:05 | A1 cleanup-sweep merges land |
| 19:10 | Post-sweep: 69 crons active, 0 failures since diet, IO recovered |

### 6.4 — Follow-up work tracked

1. **Index migration on `listings_snapshots(event_id, captured_at DESC)`** so `backfill_stale_zone_metrics` driver CTE can use an index-only scan. Re-enable job 98 after.
2. **D1 follow-up PR**: reconcile #76's 4 deferred app.py polish commits (`b5258f7`, `46ee738`, `d0ffaac`, `669ed59`) against post-#84 TEvo-direct codebase.
3. **D2 follow-up commits**: sources 2 + 3 in the GoTickets-series PR pattern. Vault entries `GOTICKETS_ACCESS_ID` + `GOTICKETS_API_SECRET` pending operator.
4. **Operator action**: repoint Render service source `claude/store-sql-only-demo-mode → main` per #84 (render.yaml IaC now declares `branch: main`).
5. **Operator action**: provision second Render service for `d2_dashboard` per `d2_dashboard/DEPLOY.md` (PR #85).
6. **B1 audit**: how did `anon`/`authenticated` get re-granted EXECUTE on `get_app_secret` after the 2026-05-09 lockdown? No migration in repo did it. One-pass audit of every SECURITY DEFINER fn with `anon` EXECUTE.

---

## 7. Maintenance

This doc lives at root level. **A1 owns updates.** When a new doc is added:
1. Add to §4 (categorized inventory)
2. If a must-read: add to §1 (universal) or §3 (per-bot)
3. Update §2 if bot roster changes
4. Update §5 if a new checkpoint tag is cut
5. Update §6 if a significant batch of work lands

When a bot is added or paused: update §2, §3, and `BOT_HIERARCHY.md` in lockstep.

Last updated: 2026-05-13.
Owner: A1 (admin lane).
Anchor: `main-checkpoint-2026-05-13-post-cleanup` (commit `70fbbdf`).
