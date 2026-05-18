# Markdown Inventory — Terminal-2 docs catalogue

**Owner**: B1 (Security Manager — librarian/archivist role per operator directive 2026-05-16)
**Last full sweep**: 2026-05-17 ~02:30 UTC — 126 tracked `.md` files (+2 since 2026-05-16 afternoon: war-games playbook + code-review audit, both from PR #172)
**Update cadence**: per-session sweep step 17 (new-file detection); quarterly full re-cat

Catalogue of every tracked `.md` file in the repo, grouped by audience/purpose. B1 maintains; A1 merges drift PRs.

**Regenerate full list**: `git ls-files '*.md'`
**Detect new since last sweep**: `git log --since='<date>' --diff-filter=A --name-only --pretty=format: -- '*.md' | sort -u`

---

## Audience legend

- 🌍 = read by every bot (start here)
- 🛡️ = lane-scoped self-contract or B1-owned living inventory
- 📋 = active operational state (KANBAN, current crons, etc.)
- 📜 = governance bibles (canonical refs B1 curates)
- 🗂️ = point-in-time snapshots (audits, checkpoints, handoffs)
- 🎨 = design / wireframes
- 📊 = data / schema / reference
- 🧰 = template / scaffolding

---

## §1 — Read this first 🌍

| File | Purpose | Owner |
|---|---|---|
| [`README.md`](../README.md) | Repo intro | A1 |
| [`START_HERE.md`](../START_HERE.md) | 2-minute bootstrap | A1 |
| [`PROJECT_BIBLE.md`](../PROJECT_BIBLE.md) | Single-source-of-truth for the 80% bots need (RPC table, hierarchy, drift watchlist) | A1 / B1 co-curator |
| [`RESOURCES_BIBLE.md`](../RESOURCES_BIBLE.md) | What exists, who owns it, where it came from | A1 / B1 co-curator |
| [`COWORKER_ONBOARDING.md`](../COWORKER_ONBOARDING.md) | New-bot bootstrap protocol | A1 |
| [`AGENTS.md`](../AGENTS.md) | Agent assignments + historical context | A1 |
| [`DOCUMENTATION_INDEX.md`](../DOCUMENTATION_INDEX.md) | Doc map (2026-05-10 vintage; partial drift) | A1 |
| [`INSTRUCTIONS_FOR_CLAUDE_DESIGN.md`](../INSTRUCTIONS_FOR_CLAUDE_DESIGN.md) | Design-bot ops | A1 / design |
| [`INSTRUCTIONS_FOR_COPILOT.md`](../INSTRUCTIONS_FOR_COPILOT.md) | Copilot instructions | A1 |

## §2 — Governance bibles (B1 co-curated) 📜

| File | Purpose | Refresh trigger |
|---|---|---|
| [`CLAUDE.md`](../CLAUDE.md) | Project-wide rules + 2026-05-13 lockdown | Global rule changes |
| [`BOT_HIERARCHY.md`](../BOT_HIERARCHY.md) | Push restrictions + lane roster + §6 SECDEF convention | Lane reassignments, push policy |
| [`LANE_DISCIPLINE.md`](../LANE_DISCIPLINE.md) | Per-lane write surface detail | Lane scope changes |
| [`MIGRATION_CONVENTIONS.md`](../MIGRATION_CONVENTIONS.md) | Migration filename / header / apply protocol | Migration protocol changes |
| [`SYNC_PROTOCOL.md`](../SYNC_PROTOCOL.md) | PR / merge tracks (fast / careful / emergency) | PR-flow protocol changes |
| [`SCHEMA.md`](../SCHEMA.md) | DB schema reference | Schema-shape changes |
| [`CRON_HIERARCHY.md`](../CRON_HIERARCHY.md) | Cron tier budgets (T0–T4) | Cron policy changes |
| [`docs/pr_governance.md`](pr_governance.md) | PR governance ratified 2026-05-16 (commit `a83f80b`); fast/careful/emergency tracks per its own spec | PR-flow rule changes |
| [`docs/bot_chat_conventions.md`](bot_chat_conventions.md) | bot_chat event_type semantics + resolve protocol + closure-by-status rules | bot_chat schema changes |
| [`docs/token-discipline-rules.md`](token-discipline-rules.md) | Token-discipline rules (companion to PROJECT_BIBLE.md §7 codified by B1 2026-05-16) | Token-budget conventions change |

## §3 — Per-bot self-contracts 🛡️

| File | Lane |
|---|---|
| [`docs/b1_operating_constraints.md`](b1_operating_constraints.md) | B1 — Security Manager / Librarian |
| [`docs/c1_operating_constraints.md`](c1_operating_constraints.md) | C1 — Data + Chat Supervisor |
| [`docs/d0_operating_constraints.md`](d0_operating_constraints.md) | D0 — Terminal FE (consolidated frontend lead post-PR-#126) |
| [`docs/d1_operating_constraints.md`](d1_operating_constraints.md) | D1 — Consumer Retail Storefront |

(No A1 self-contract yet — A1 operates from CLAUDE.md + LANE_DISCIPLINE.md §A1; D2/D3/D4 self-contracts pending.)

## §4 — Living inventories (B1-owned unless noted) 🛡️

| File | Purpose | Update cadence |
|---|---|---|
| [`docs/anon_callable_surface_inventory.md`](anon_callable_surface_inventory.md) | Effective anon-access surface (fns + tables + views) | Per-session sweep step 4 |
| [`docs/git_repo_security_posture.md`](git_repo_security_posture.md) | Branch protection + repo settings + Actions config + alerts | Per-session sweep step 12 |
| [`docs/render_security_posture.md`](render_security_posture.md) | Render workspace + 3 services config | Per-session sweep step 13 |
| [`docs/markdown_inventory.md`](markdown_inventory.md) | **This doc** — every `.md` file catalogued | Per-session sweep step 17 (new); quarterly full re-cat |
| [`docs/security-runbook-2026-05-11.md`](security-runbook-2026-05-11.md) | Security incident response playbook | When new playbook step is added |
| [`docs/war_games_playbook.md`](war_games_playbook.md) | 10 adversarial scenarios (W-1..W-10) with read-only probe templates for idle-time rotation | When new scenario surface emerges; rotate scenarios per sweep step 19 |
| [`docs/b1_open_findings.md`](b1_open_findings.md) | Live ledger of OPEN B1 security findings (severity-sorted; fixing bots delete their row) | Per-session sweep (B1 populates new findings; fixing bots prune) |

## §5 — Active operational state 📋

| File | Purpose |
|---|---|
| [`KANBAN.md`](../KANBAN.md) | Active work board + B1-NEXT security backlog |
| [`docs/cron-landscape-2026-05-09.md`](cron-landscape-2026-05-09.md) | All scheduled jobs by lane (somewhat stale; cron set has churned since) |
| [`docs/cron-and-queue-health-2026-05-11.md`](cron-and-queue-health-2026-05-11.md) | Cron + pg_net queue health snapshot |
| [`docs/release-discipline.md`](release-discipline.md) | Anti-drift practices + smoke harness discipline |
| [`docs/edit_coordination_protocol.md`](edit_coordination_protocol.md) | Cross-lane file-claim protocol |
| [`docs/c1_daily_checkpoint_runbook.md`](c1_daily_checkpoint_runbook.md) | C1's daily checkpoint runbook |
| [`docs/d1_pending_merge_back.md`](d1_pending_merge_back.md) | D1's pending merge-back state |
| [`docs/d1_retail_finish_punchlist.md`](d1_retail_finish_punchlist.md) | D1 retail finish punchlist |
| [`docs/evo_store_next_steps.md`](evo_store_next_steps.md) | EVO storefront next-steps |
| [`docs/D0_PHASE_2A_HANDOFF.md`](D0_PHASE_2A_HANDOFF.md) | D0 Phase 2a handoff doc |
| [`docs/d0_frontend_consolidation_plan.md`](d0_frontend_consolidation_plan.md) | D0 frontend consolidation plan |
| [`docs/phase2-ui-kanban.md`](phase2-ui-kanban.md) | Phase 2 UI work board |
| [`docs/retail-ui-kit.md`](retail-ui-kit.md) | Retail UI component kit |
| [`bin/sync-check.md`](../bin/sync-check.md) | Sync-check tool docs |
| [`d2_dashboard/DEPLOY.md`](../d2_dashboard/DEPLOY.md) | D2 dashboard deploy notes |
| [`docs/seatgeek/kanban-tasks.md`](seatgeek/kanban-tasks.md) | SG-specific work board |
| [`docs/current-state-index.md`](current-state-index.md) | Operational index of current-state docs (added 2026-05-16) |
| [`docs/seatgeek/migration-guide.md`](seatgeek/migration-guide.md) | SG migration guide |

## §6 — Point-in-time snapshots (audits, checkpoints, handoffs) 🗂️

Each file is a frozen record of state at a moment in time. NOT a living source-of-truth — refer to current bibles + inventories for current state. B1's archivist role: catalogue these, don't refresh them.

**Audits**:
- [`docs/audit-2026-05-09.md`](audit-2026-05-09.md)
- [`docs/audit-2026-05-14-data-stability.md`](audit-2026-05-14-data-stability.md)
- [`docs/audit-handoff-2026-05-11.md`](audit-handoff-2026-05-11.md)
- [`docs/broker-audit-2026-05-08.md`](broker-audit-2026-05-08.md)
- [`docs/data-sources-audit-2026-05-11.md`](data-sources-audit-2026-05-11.md)
- [`docs/database-audit-2026-05-09.md`](database-audit-2026-05-09.md)
- [`docs/full-audit-2026-05-09.md`](full-audit-2026-05-09.md)
- [`docs/storage-audit-2026-05-08.md`](storage-audit-2026-05-08.md)
- [`docs/sync-audit-2026-05-08.md`](sync-audit-2026-05-08.md)
- [`docs/workflow-audit-2026-05-08.md`](workflow-audit-2026-05-08.md)
- [`docs/security-audit-2026-05-14-post-pr101.md`](security-audit-2026-05-14-post-pr101.md) — B1's
- [`docs/audit-2026-05-15-consolidation-plan.md`](audit-2026-05-15-consolidation-plan.md) — C1's consolidation plan
- [`docs/audit-2026-05-15-merge-token-leakage.md`](audit-2026-05-15-merge-token-leakage.md) — pre-merge token leakage scan
- [`docs/audit-2026-05-15-migration-header-bloat.md`](audit-2026-05-15-migration-header-bloat.md) — migration-header bloat audit
- [`docs/audit-2026-05-15-schema-sprawl.md`](audit-2026-05-15-schema-sprawl.md) — schema-sprawl audit
- [`docs/security-audit-2026-05-16-code-review.md`](security-audit-2026-05-16-code-review.md) — B1's edge-function code audit (PR #172, CRIT+HIGH+MED retrofitted by PR #174)

**Checkpoints / handoffs**:
- [`docs/checkpoint-2026-05-15-friday.md`](checkpoint-2026-05-15-friday.md)
- [`docs/checkpoint-2026-05-15-evening.md`](checkpoint-2026-05-15-evening.md)
- [`docs/checkpoint-2026-05-16-evening.md`](checkpoint-2026-05-16-evening.md) — 2026-05-16 EOD (testing-unified architecture landed)
- [`docs/c1-checkpoint-2026-05-15.md`](c1-checkpoint-2026-05-15.md) — C1's daily checkpoint
- [`docs/c1-ownership-takeover-2026-05-14.md`](c1-ownership-takeover-2026-05-14.md)
- [`docs/A1_HANDOFF_2026-05-15.md`](A1_HANDOFF_2026-05-15.md) — A1 → C1 handoff
- [`docs/SESSION_2026-05-14_HANDOFF.md`](SESSION_2026-05-14_HANDOFF.md)
- [`SESSION_2026-05-07.md`](../SESSION_2026-05-07.md)
- [`SESSION_2026-05-13.md`](../SESSION_2026-05-13.md)
- [`docs/project-kanban-2026-05-14.md`](project-kanban-2026-05-14.md)
- [`docs/state-delta-since-c1-audit-2026-05-12.md`](state-delta-since-c1-audit-2026-05-12.md)
- [`docs/d1-render-perf-2026-05-15.md`](d1-render-perf-2026-05-15.md)

**Coworker handoffs**:
- [`docs/coworker-handoff/HANDOFF_INSTRUCTIONS.md`](coworker-handoff/HANDOFF_INSTRUCTIONS.md)
- [`docs/coworker-handoff/PHASE_2_HANDOFF.md`](coworker-handoff/PHASE_2_HANDOFF.md)
- [`docs/coworker-handoff/DATA_QUALITY_DASHBOARD.md`](coworker-handoff/DATA_QUALITY_DASHBOARD.md)
- [`docs/coworker-handoff/QUERY_CATALOG.md`](coworker-handoff/QUERY_CATALOG.md)
- [`docs/coworker-handoff/QUERY_COOKBOOK.md`](coworker-handoff/QUERY_COOKBOOK.md)
- [`docs/coworker-handoff/SCOPE.md`](coworker-handoff/SCOPE.md)

## §7 — Design docs 🎨

Mostly D0 / design-bot owned; ~16 files at `design/` and `docs/event-view-wireframe-*`.

- [`design/README.md`](../design/README.md)
- [`design/main.fig.md`](../design/main.fig.md)
- [`design/preliminary-event-views-2026-05-08.md`](../design/preliminary-event-views-2026-05-08.md) — 6 broker-terminal templates
- [`design/retail-site-2026-05-08.md`](../design/retail-site-2026-05-08.md) — retail buying site spec
- [`design/undelivered-window-2026-05-08.md`](../design/undelivered-window-2026-05-08.md) — fulfillment ops view spec
- [`design/terminal-only-redesign-2026-05-08.md`](../design/terminal-only-redesign-2026-05-08.md)
- [`design/auto-populate-2026-05-08.md`](../design/auto-populate-2026-05-08.md)
- [`design/data-reality-2026-05-08.md`](../design/data-reality-2026-05-08.md)
- [`design/media-placement-2026-05-08.md`](../design/media-placement-2026-05-08.md)
- [`design/MEDIA_ASSETS_2026-05-08.md`](../design/MEDIA_ASSETS_2026-05-08.md)
- [`design/CODE_NOTES_2026-05-08.md`](../design/CODE_NOTES_2026-05-08.md)
- [`design/simulations-edge-and-ui-2026-05-08.md`](../design/simulations-edge-and-ui-2026-05-08.md)
- [`design/simulations-non-sports-2026-05-08.md`](../design/simulations-non-sports-2026-05-08.md)
- [`design/simulations-sports-2026-05-08.md`](../design/simulations-sports-2026-05-08.md)
- [`design/code-reply-mapping-and-coverage-2026-05-09.md`](../design/code-reply-mapping-and-coverage-2026-05-09.md)
- [`design/code-reply-seatgeek-v2-listings-2026-05-09.md`](../design/code-reply-seatgeek-v2-listings-2026-05-09.md)
- [`docs/event-view-wireframe-v3.md`](event-view-wireframe-v3.md)
- [`docs/event-view-wireframe-v4.md`](event-view-wireframe-v4.md) — current Phase 2a target
- [`docs/performer-view-wireframe-v5.md`](performer-view-wireframe-v5.md)
- [`docs/terminal-redesign-2026-05-09.md`](terminal-redesign-2026-05-09.md)

## §8 — Reference data + schema 📊

| File | Purpose |
|---|---|
| [`docs/data-sources-terminal-uses.md`](data-sources-terminal-uses.md) | Data sources catalogue |
| [`docs/DATA_ARCHITECTURE.md`](DATA_ARCHITECTURE.md) | Data architecture diagram + flow |
| [`docs/database-map-2026-05-09.md`](database-map-2026-05-09.md) | DB map snapshot |
| [`docs/canonical-data-map-2026-05-09.md`](canonical-data-map-2026-05-09.md) | Canonical entity map |
| [`docs/canonical-mapping-notes-2026-05-10.md`](canonical-mapping-notes-2026-05-10.md) | Canonical mapping notes |
| [`docs/cross-source-entity-resolution-2026-05-11.md`](cross-source-entity-resolution-2026-05-11.md) | Cross-source ER notes |
| [`docs/evo-seatgeek-field-mapping-2026-05-09.md`](evo-seatgeek-field-mapping-2026-05-09.md) | EVO ↔ SG field mapping |
| [`docs/table-inventory-and-gaps-2026-05-11.md`](table-inventory-and-gaps-2026-05-11.md) | Table inventory snapshot |
| [`docs/function-inventory-2026-05-11.md`](function-inventory-2026-05-11.md) | Function inventory snapshot |
| [`docs/view-deps-and-rls-2026-05-11.md`](view-deps-and-rls-2026-05-11.md) | View deps + RLS snapshot |
| [`docs/proposed-tables-2026-05-11.md`](proposed-tables-2026-05-11.md) | Proposed-table backlog |
| [`docs/terminal-data-inventory.md`](terminal-data-inventory.md) | Terminal data inventory |
| [`docs/historical-data-and-multi-view-strategy-2026-05-09.md`](historical-data-and-multi-view-strategy-2026-05-09.md) | Multi-view strategy |
| [`docs/tevo-api-workflow.md`](tevo-api-workflow.md) | TEvo API workflow |
| [`docs/weather-sources-2026-05-09.md`](weather-sources-2026-05-09.md) | Weather data sources |
| [`docs/wikipedia-usage-2026-05-09.md`](wikipedia-usage-2026-05-09.md) | Wikipedia API usage |
| [`docs/mlb-game-series-detection.md`](mlb-game-series-detection.md) | MLB series detection logic |
| [`docs/tournament-event-detection.md`](tournament-event-detection.md) | Tournament detection logic |
| [`docs/concerts-broadway-tours-residencies.md`](concerts-broadway-tours-residencies.md) | Concert/tour modeling |
| [`docs/seatdata-blocker-2026-05-09.md`](seatdata-blocker-2026-05-09.md) | SeatData blocker writeup |
| [`docs/knicks-next-home-event-snapshot-2026-05-09.md`](knicks-next-home-event-snapshot-2026-05-09.md) | Specific-event snapshot example |
| [`docs/interactive-venue-maps-options.md`](interactive-venue-maps-options.md) | Venue map options writeup |

## §9 — Templates 🧰

| File | Purpose |
|---|---|
| [`docs/templates/LANE_DISCIPLINE.template.md`](templates/LANE_DISCIPLINE.template.md) | Lane discipline doc template |
| [`docs/templates/bot_lane_constraints_template.md`](templates/bot_lane_constraints_template.md) | Per-bot self-contract template |
| [`.github/PULL_REQUEST_TEMPLATE.md`](../.github/PULL_REQUEST_TEMPLATE.md) | PR template |

## §10 — Inventory health metrics

| Metric | Current value | Threshold |
|---|---|---|
| Total tracked `.md` | 126 (+2 since 2026-05-16 afternoon — both from PR #172) | n/a |
| New since 2026-05-14 | ~26 (within expected churn for governance-write sprint) | flag if >30/week |
| Bibles drift entries (PROJECT_BIBLE.md §9) | 10 | review when >20 |
| Per-bot self-contracts | 4 of expected 6 (missing A1, D2; D3/D4 deferred) | track gap |
| Architecture-snapshot freshness | render_security_posture.md updated 2026-05-16 for testing-unified (PR #168/#169) | re-sync on each PR touching `app.py` mount points |

---

## How B1 maintains this catalogue

**Per-session sweep step 17** (added 2026-05-16):
```bash
# Detect newly-added .md files since last B1 sweep
git log --since='<last sweep date>' --diff-filter=A --name-only --pretty=format: -- '*.md' | sort -u
```
For each new file: classify into §1-§9, append to appropriate section, note 1-line purpose + owner.

**Quarterly full re-cat**: re-run `git ls-files '*.md'`, diff against this doc, reclassify any moved/renamed files.

**Bible / self-contract / inventory drift detection**: separate per-session sweep step 15 — verify spot-claims against live state.

Updates ship as drift PRs against this file; A1 merges per standard PR protocol.
