# DOCUMENTATION_INDEX.md

Authoritative map of every doc in the Terminal-2 repo, organized by which bot reads what. Read this before searching for a doc by filename. Updated 2026-05-10.

---

## TL;DR

- **59 markdown files total** across the repo (9 root, 26 `docs/`, 6 `docs/coworker-handoff/`, 2 `docs/seatgeek/`, 16 `design/`).
- **6 bot lanes** active or paused (see §2). Three documented in `AGENTS.md`, three new arrivals from today's session not yet rostered.
- **5 universal must-reads** for any bot before doing anything (see §1).
- **2 governance docs landed today**: `MIGRATION_CONVENTIONS.md` (new), and the migrations behind PRs #50/#53/#54 (3 new migration files, 1 modified `app.py`).

---

## 1. Universal must-reads (every bot, in this order)

| # | Doc | Why |
|---|---|---|
| 1 | `AGENTS.md` | Lane roster, status board, WIP claims, ACCESS MATRIX. Read start-to-finish before touching anything. |
| 2 | `MIGRATION_CONVENTIONS.md` | **NEW today.** Production push gate (audit lane only), lane discipline, migration filename/header convention. Required reading before any migration. |
| 3 | `KANBAN.md` | What's in flight, what's parked. Proxy-commit pattern documented here. |
| 4 | `SCHEMA.md` | Current schema reference. Updated as part of every backend commit by the audit lane. |
| 5 | `README.md` | Top-level orientation. |

If you read these five (≈30 min) you have enough context to avoid 95% of drift incidents.

---

## 2. Bot roster (current state — supersedes `AGENTS.md` until it's updated)

| # | Bot | Worktree | Status | Owns |
|---|---|---|---|---|
| 1 | **code** (audit lane / xref+macro) | `mystifying-lederberg-ea407b` | ACTIVE | Backend, all migrations, ESPN/TEvo/Wiki/NOAA ingest, FRED macro, schema audit, **sole git pusher to production** |
| 2 | **claude design** | (no separate worktree — works through `code` proxy) | ACTIVE | All `static/*.html`, design system, `design/*`. No push, no prod writes. |
| 3 | ~~**copilot**~~ | (paused) | PAUSED | Retail chat edge function, chat ingest helpers, chatbot NLU pipeline |
| 4 | **canonical** | `audit-datasets-schemas-auoc3` | ACTIVE (PR #51 DRAFT) | `canonical_external_ids`, `seatgeek_event_xref`, all drift triggers, cross-source overlays, event/performer view wireframe SQL |
| 5 | **broadway** | `broadway-scraper-eChQ6` | ACTIVE (PR #52 DRAFT) | `broadway_client.py`, Broadway.com scraper, related tests |
| 6 | **storefront** | `eloquent-chatterjee-aaedf0` | ACTIVE (PR #54 MERGED) | `app.py` storefront routes, `static/store/*`, `share_links` table + endpoints |

**Gap to fix**: `AGENTS.md` only documents bots 1-3. Bots 4-6 (canonical / broadway / storefront) emerged from parallel sessions and need a roster update. Audit lane should refresh `AGENTS.md` to match.

---

## 3. Per-bot reading lists

### 3.1 — code (audit lane / xref + macro)

**Must-read** (in addition to the 5 universal):
- `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md` — knows what design needs from you
- `INSTRUCTIONS_FOR_COPILOT.md` — knows the chat lane when it returns
- `docs/full-audit-2026-05-09.md` — most recent full system audit
- `docs/database-audit-2026-05-09.md` + `docs/database-map-2026-05-09.md` — DB state
- `docs/cron-landscape-2026-05-09.md` — current cron landscape (you maintain this)
- `docs/audit-2026-05-09.md` — cross-source audit
- `docs/canonical-data-map-2026-05-09.md` — what canonical is doing
- `docs/evo-seatgeek-field-mapping-2026-05-09.md` — TEvo↔SG field mapping
- `docs/coworker-handoff/QUERY_CATALOG.md` — query patterns you've built

**Reference** (read when relevant):
- `docs/tevo-api-workflow.md`, `docs/data-sources-terminal-uses.md`, `docs/terminal-data-inventory.md`
- `docs/concerts-broadway-tours-residencies.md`, `docs/tournament-event-detection.md`, `docs/mlb-game-series-detection.md`
- `docs/storage-audit-2026-05-08.md`, `docs/sync-audit-2026-05-08.md`, `docs/workflow-audit-2026-05-08.md`
- `docs/historical-data-and-multi-view-strategy-2026-05-09.md`
- `docs/seatdata-blocker-2026-05-09.md`, `docs/weather-sources-2026-05-09.md`, `docs/wikipedia-usage-2026-05-09.md`
- `docs/seatgeek/migration-guide.md`, `docs/seatgeek/kanban-tasks.md`
- `SESSION_2026-05-07.md`, `docs/broker-audit-2026-05-08.md` (historical context)

### 3.2 — claude design (frontend)

**Must-read**:
- `COWORKER_ONBOARDING.md` — your dedicated onboarding (full setup)
- `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md` — your lane spec
- `design/main.fig.md` — design system source of truth
- `design/README.md` — design folder orientation
- `docs/retail-ui-kit.md` — retail surface design tokens
- `docs/terminal-redesign-2026-05-09.md` — current redesign direction
- `docs/phase2-ui-kanban.md` — UI roadmap
- `docs/coworker-handoff/HANDOFF_INSTRUCTIONS.md` — proxy-commit pattern

**Reference**:
- All `design/*.md` (16 files — design memos, simulations, wireframes)
- `docs/interactive-venue-maps-options.md`
- `docs/coworker-handoff/SCOPE.md`, `docs/coworker-handoff/PHASE_2_HANDOFF.md`

### 3.3 — copilot (PAUSED — retail chat)

**Must-read when reactivated**:
- `INSTRUCTIONS_FOR_COPILOT.md` — lane spec, schema sandbox rules
- `docs/coworker-handoff/QUERY_COOKBOOK.md` — query patterns
- `docs/data-sources-terminal-uses.md`
- `docs/canonical-data-map-2026-05-09.md` — for chat-side retrieval

### 3.4 — canonical (PR #51 / audit-datasets-schemas-auoc3)

**Must-read**:
- All 5 universal
- `docs/canonical-data-map-2026-05-09.md` — your own primary reference
- `docs/database-map-2026-05-09.md` — table inventory
- `docs/evo-seatgeek-field-mapping-2026-05-09.md` — your cross-source mapping work
- `docs/coworker-handoff/QUERY_CATALOG.md` — query patterns to mirror

**Reference**:
- `SCHEMA.md` — read-only on most tables
- `docs/seatgeek/migration-guide.md`
- `docs/audit-2026-05-09.md` and `docs/full-audit-2026-05-09.md` — context on what was already audited

### 3.5 — broadway (PR #52 / broadway-scraper-eChQ6)

**Must-read**:
- All 5 universal
- `docs/concerts-broadway-tours-residencies.md` — your primary reference
- `docs/tevo-api-workflow.md` — how TEvo events get ingested (your scraped data will sit alongside)

**Reference**:
- `docs/canonical-data-map-2026-05-09.md` — when you eventually need to xref Broadway events to TEvo
- `MIGRATION_CONVENTIONS.md` §4 (single-writer rule) — when you start adding `broadway_*` tables

### 3.6 — storefront (PR #54 / eloquent-chatterjee-aaedf0)

**Must-read**:
- All 5 universal
- `docs/retail-ui-kit.md` — design system you'll consume
- `INSTRUCTIONS_FOR_COPILOT.md` — when copilot returns, you'll share retail surface area
- `docs/data-sources-terminal-uses.md` — what data flows through retail

**Reference**:
- `design/retail-site-2026-05-08.md` — retail design direction
- `design/terminal-only-redesign-2026-05-08.md` — broker terminal context
- `docs/coworker-handoff/DATA_QUALITY_DASHBOARD.md` — UI quality patterns

---

## 4. Categorized inventory (full)

### 4.1 — Governance + cross-bot (9 docs, all root-level)
| File | Purpose | Updated |
|---|---|---|
| `AGENTS.md` | Bot roster, ACCESS MATRIX, status board | 2026-05-09 (needs refresh for bots 4-6) |
| **`MIGRATION_CONVENTIONS.md`** | **Production push gate + lane discipline (NEW)** | **2026-05-10** |
| `KANBAN.md` | Active work board, proxy-commit pattern | live |
| `README.md` | Top-level orientation | live |
| `SCHEMA.md` | Schema reference | live |
| `COWORKER_ONBOARDING.md` | Design coworker onboarding | 2026-05-09 |
| `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md` | Design lane spec | 2026-05-09 |
| `INSTRUCTIONS_FOR_COPILOT.md` | Copilot lane spec (paused) | live |
| `SESSION_2026-05-07.md` | Historical session log | static |

### 4.2 — Audit + system state (8 docs, `docs/`)
- `docs/audit-2026-05-09.md` — cross-source audit
- `docs/broker-audit-2026-05-08.md`, `docs/full-audit-2026-05-09.md`, `docs/workflow-audit-2026-05-08.md`
- `docs/storage-audit-2026-05-08.md`, `docs/sync-audit-2026-05-08.md`
- `docs/database-audit-2026-05-09.md`, `docs/database-map-2026-05-09.md`

### 4.3 — Schema + data flow (10 docs, `docs/`)
- `docs/canonical-data-map-2026-05-09.md`
- `docs/data-sources-terminal-uses.md`
- `docs/evo-seatgeek-field-mapping-2026-05-09.md`
- `docs/historical-data-and-multi-view-strategy-2026-05-09.md`
- `docs/terminal-data-inventory.md`
- `docs/tevo-api-workflow.md`
- `docs/concerts-broadway-tours-residencies.md`
- `docs/mlb-game-series-detection.md`
- `docs/tournament-event-detection.md`
- `docs/knicks-next-home-event-snapshot-2026-05-09.md` (point-in-time debug snapshot)

### 4.4 — Operations (4 docs, `docs/`)
- `docs/cron-landscape-2026-05-09.md`
- `docs/weather-sources-2026-05-09.md`
- `docs/wikipedia-usage-2026-05-09.md`
- `docs/seatdata-blocker-2026-05-09.md`

### 4.5 — Design + UI (16 design/ + 3 docs/)
- All `design/*.md` (16 files — wireframes, simulations, redesign memos, code-reply notes)
- `docs/retail-ui-kit.md`, `docs/terminal-redesign-2026-05-09.md`, `docs/phase2-ui-kanban.md`, `docs/interactive-venue-maps-options.md`

### 4.6 — SeatGeek subdir (2 docs, `docs/seatgeek/`)
- `docs/seatgeek/kanban-tasks.md`
- `docs/seatgeek/migration-guide.md`

### 4.7 — Coworker handoff (6 docs, `docs/coworker-handoff/`)
- `docs/coworker-handoff/SCOPE.md`
- `docs/coworker-handoff/HANDOFF_INSTRUCTIONS.md`
- `docs/coworker-handoff/QUERY_CATALOG.md`
- `docs/coworker-handoff/QUERY_COOKBOOK.md`
- `docs/coworker-handoff/DATA_QUALITY_DASHBOARD.md`
- `docs/coworker-handoff/PHASE_2_HANDOFF.md`

---

## 5. New additions this session (2026-05-10)

### 5.1 — Files added (10 new, 1 modified)

| File | Lane | Lines | Status |
|---|---|---|---|
| `MIGRATION_CONVENTIONS.md` | audit | 413 | ✅ Merged (#55) |
| `supabase/migrations/20260510120000_in_db_event_matcher_v1.sql` | audit | 222 | ✅ Merged (#50) |
| `supabase/migrations/20260510130000_fred_macro_indicators_umcsent.sql` | audit | 279 | ✅ Merged (#53) |
| `supabase/migrations/20260510120150_share_links.sql` | storefront | 103 | ✅ Merged (#54) |
| `static/store/event.html` | storefront | 93 | ✅ Merged (#54) |
| `static/store/index.html` | storefront | 49 | ✅ Merged (#54) |
| `static/store/shares.html` | storefront | 65 | ✅ Merged (#54) |
| `static/store/store.js` | storefront | 853 | ✅ Merged (#54) |
| `static/store/style.css` | storefront | 553 | ✅ Merged (#54) |
| `app.py` (modified) | storefront | +600 | ✅ Merged (#54) |
| **`DOCUMENTATION_INDEX.md`** *(this file)* | audit | TBD | pending PR |

### 5.2 — Reviews

#### `MIGRATION_CONVENTIONS.md` — audit lane
- **Verdict**: ✅ Ships clean. Codifies what was previously implicit chat-driven coordination.
- **Strength**: Production push gate is explicit and enforceable. Header convention makes audits grep-able.
- **Watch for**: Bots 4-6 haven't been onboarded to these rules yet — make sure first follow-up PR after this lands gets reviewed against §9 checklist visibly so the precedent is set.

#### Migration `20260510120000_in_db_event_matcher_v1.sql` — audit lane
- **Verdict**: ✅ Live in production, draining backlog as designed.
- **Strength**: Pacific TZ date join eliminates the UTC/ET ambiguity that caused the 60-collision bug.
- **Watch for**: Doesn't overwrite existing `team_date_legacy` rows. Game 7 verification showed a `team_date_legacy` xref that happened to be correct by luck — for systemic cleanup, need the "re-match-legacy mode" follow-up (already in todos).

#### Migration `20260510130000_fred_macro_indicators_umcsent.sql` — audit lane
- **Verdict**: ✅ Schema clean, cron scheduled, generic enough to add more series later.
- **Strength**: Revision history preserved (`realtime_start`) for backtest integrity.
- **Watch for**: **Pre-req `FRED_API_KEY` in vault is still pending** — until set, cron writes sentinel rows. Operator (Julian) action required.

#### Migration `20260510120150_share_links.sql` + storefront UI — storefront lane
- **Verdict**: ✅ Migration follows conventions (renamed to clear collision with phase2). UI is large (~1,700 lines) but lives in clean storefront namespace.
- **Strength**: Storefront bot demonstrated correct cross-bot etiquette when the collision was flagged.
- **Watch for**: First PR from this lane that lands SQL. `share_links` schema not reviewed against `MIGRATION_CONVENTIONS.md` §6 header requirement (predates that doc). Audit lane should retrospectively spot-check.

#### `app.py` modifications — storefront lane
- **Verdict**: ⚠️ Worth a deeper review.
- **Concern**: 600 lines added to `app.py` (the broker terminal backend). Per `AGENTS.md` and `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md`, `app.py` is the audit lane's. Storefront lane writing to `app.py` crosses lane boundaries.
- **Mitigation**: The new code is presumably storefront-specific routes (the `static/store/*` UI needs backend endpoints). The right pattern going forward is to either: (a) move storefront routes to a separate `store_app.py` or `app/store.py` module that the storefront lane owns, or (b) leave them in `app.py` but explicitly carve out storefront-route ownership in `MIGRATION_CONVENTIONS.md` §2.
- **Follow-up**: Audit lane should review `app.py` diff for cross-lane regressions and propose a refactor if scale warrants.

### 5.3 — PRs landed today

| PR | Title | Merged | SHA |
|---|---|---|---|
| #50 | feat(xref): in-DB strict matcher v1 + self-paced cron | 16:47 UTC | `f9bfa58` |
| #53 | feat(macro): FRED ingestion + UMCSENT seed | 16:48 UTC | `ce7e906` |
| #54 | feat(store): MVP storefront + revocable share links | 16:48 UTC | `6a9c5cc` |
| #55 | docs(governance): MIGRATION_CONVENTIONS.md | 16:47 UTC | `24f4be8` |

### 5.4 — Still open

| PR | Title | Status | Blocker |
|---|---|---|---|
| #51 | canonical phases 7-13 | DRAFT | Awaiting canonical bot's rebase + filename bump |
| #52 | Broadway scraper | DRAFT | Awaiting their CI green |

---

## 6. Gaps + recommendations

### 6.1 — `AGENTS.md` is stale
Documents bots 1-3 only. Bots 4-6 (canonical / broadway / storefront) have shipped code today but aren't rostered. **Audit lane should refresh `AGENTS.md`** to reflect the actual current bot landscape, with updated ACCESS MATRIX entries for the new lanes.

### 6.2 — `SCHEMA.md` post-merge update needed
3 new migrations landed today (xref strict matcher, FRED macro, share_links). `SCHEMA.md` needs new sections for `macro_indicators`, `macro_series_config`, `fred_pending`, `espn_scoreboard_pending`, `share_links`, plus updated entries for `event_xref` (new match_method values) and `v_event_xref_collisions` (refined definition).

### 6.3 — `KANBAN.md` cleanup
Many today's todos are done but may still be listed. Audit lane should sweep.

### 6.4 — Cross-lane `app.py` ownership
Per §5.2 above — the storefront lane wrote 600 lines into the audit lane's `app.py`. Either formalize storefront-routes-in-`app.py` as a permitted exception in `MIGRATION_CONVENTIONS.md` §2, or factor out a `app/store.py` module the storefront lane owns cleanly.

### 6.5 — Stale dated docs
Several docs are dated `2026-05-08` or `2026-05-09` and may be superseded. Audit lane should evaluate whether to:
- Mark obsolete docs `ARCHIVED` (move to `docs/archive/`)
- Update in place with current dates
- Leave as-is for historical context

Recommend a quarterly doc-pruning pass to keep the index from drifting.

### 6.6 — No bot-specific README in each lane's worktree
Each bot's worktree could benefit from a `WORKTREE_README.md` at the worktree root that:
- Names the lane
- Links the must-read reading list from this index
- Has a "session resume" checklist
- Documents the bot's local conventions

---

## 7. Maintenance

This doc lives at root level next to `AGENTS.md`. **Audit lane owns updates.** When a new doc is added:
1. Add to §4 (categorized inventory) in the correct subsection
2. Add to relevant bots' reading lists in §3
3. If new this session: add to §5
4. Update §1 TL;DR counts

When a bot is added or paused:
1. Update §2 roster
2. Add/update §3 reading list
3. Update `AGENTS.md` in lockstep

Last updated: 2026-05-10.
Owner: audit lane (`mystifying-lederberg-ea407b` worktree, "code" agent in AGENTS.md).
