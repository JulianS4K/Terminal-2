# CLAUDE.md — project-wide operating rules for Claude Code sessions

Loaded automatically by Claude Code on every session in this repo. Applies to **all** bots regardless of lane.

> **Doc version:** v2.0.0 (2026-06-19; history in git/CHANGELOG)

## 🔖 READ PROJECT_BIBLE.md FIRST (token discipline)

**Before doing anything, read [`PROJECT_BIBLE.md`](PROJECT_BIBLE.md).** It consolidates the 80% you need from this file + lane ownership (its §2, which absorbed `BOT_HIERARCHY.md`) + MIGRATION_CONVENTIONS.md + data-source docs into a single per-session reference. Saves ~5× the tokens vs reading every governance file at session start.

The bible has:
- Hard rules (no-mutation, read-only-upstream, lane scope)
- Bot hierarchy + Render service ownership per lane
- Canonical SECDEF RPCs (`get_broker_event_page_v2`, matchers, bot_chat_log, etc.)
- Key tables + freshness expectations + **column-name landmines** (catch schema bugs before authoring)
- MCP tool scope per lane
- SQL macros / common patterns (cancel filter, SG dedupe, sports gate, outdoor gate, email gate, cron wrapper)
- Workflow recipes ("I want to author a migration", "I want to wire a UI panel", etc.)
- Recent landmark migrations (don't re-do work already shipped)
- Drift watchlist (known gaps — don't waste cycles rediscovering)
- Self-check (10-item pre-task checklist)

This file (CLAUDE.md) remains the canonical source for security rules + lockdown invariants. The bible is the operational handbook bots read once per session.

Per-lane detail — per-bot scope, push-restrictions matrix, and Render service scope — all live in `PROJECT_BIBLE.md §2` (which absorbed `BOT_HIERARCHY.md` on 2026-06-19, itself having absorbed `LANE_DISCIPLINE.md`). The per-bot self-contracts were retired into §2 (2026-06-19); only `docs/b1_operating_constraints.md` remains, kept for its security severity matrix (referenced by `.github/SECURITY.md` + the secret-scan workflow).

## Global operator rules (2026-05-13 lockdown)

These three rules supersede prior MCP-applied autonomy. They apply to every bot in every lane.

### 1. SQL data is read-only by default

Read freely: `SELECT`, `information_schema`, `pg_*` views, log inspection, MCP `list_*`/`get_*` calls.

**Need explicit operator permission before:**
- `apply_migration` against any prod project
- `execute_sql` with `INSERT` / `UPDATE` / `DELETE` / `DDL` on prod
- Cron schedule changes (`cron.schedule`, `cron.unschedule`)
- Edge function deploys that mutate data
- Any change to `vault.*` / `auth.*` / `cron.*` schemas

**Standing permissions (no per-call ask):**
- `bot_chat` writes via `bot_chat_log()` / `bot_chat_resolve()` — these are the designed cross-lane coordination surface
- Supabase **branch** creation (`create_branch` produces a copy-on-write fork — no prod-data mutation)
- Author migrations as files in `supabase/migrations/` — application to prod is gated separately

**Resolve-protocol semantics (2026-05-15 — C1 / A1 convention):**
A `bot_chat` reply with `event_type='status'` and `p_in_reply_to` set is the **canonical closure signal** for its parent thread. The `v_bot_chat_unresolved` view (C1-owned, see PR #114 Cluster D-1) auto-excludes any row that has a `status` reply pointing at it via `in_reply_to`. Implications for bot authors:
- If you are CLOSING a thread (work shipped, question answered), use `event_type='status'`. This will mark the parent as resolved automatically.
- If you are still working on a thread (acknowledging without fixing), use `event_type='flag'` or `'question'`. These do NOT close the parent — the unresolved view still surfaces it.
- Premature `status` replies that conflate "I saw this" with "I fixed this" defeat the resolve hygiene. When in doubt, use `flag`.

### 2. Upstream third-party APIs are read-only

Applies to **every** external API the project integrates with — TEvo, SeatGeek, SeatData, TickPick, Vivid, and any future client (`*_client.py`).

OK: search / suggestions / events / performers / venues / ticket_groups / listings — any GET / read endpoint.

**Forbidden without explicit operator authorization:**
- Order creation (`POST /orders`, `POST /v9/orders`, equivalent on SG / TP / Vivid)
- Holds, locks, reservations, inventory mutations
- Any write / mutation endpoint on any upstream API
- Webhook subscription changes
- Account / seller-side configuration changes

**Listing-source lockdown — price changes + force-pulls cannot influence upstream, no bypass *(operator directive 2026-06-01)*:**
- **EVO and SeatGeek (and every listing source) listing prices cannot be changed.** There is no reprice / set-price / update-listing code path anywhere, and none may be added. Each `*_client.py` is GET-only *by construction* — `ALLOWED_HTTP_METHODS = frozenset({"GET"})` + `_assert_readonly_method()` that **raises** on any non-GET — so a price/inventory mutation is impossible, not merely discouraged. (Lone carve-out: SeatData permits one non-data metadata POST, `/event-request-add`, which writes none of our data and touches no price/inventory.)
- **On-demand / "force-pull" refresh paths may READ but must NEVER influence a listing-source API.** The force/sync triggers (`raw-tevo?force=true`, `/api/seatgeek/.../sync-listings`, `/sync-sales`, `/api/seatdata/.../sync-sales`, `/auto-search`, `/api/collect/run`, `/api/admin/collect-*`) pull data **in**; they never push an order, hold, write, or price/inventory change **out** to TEvo / SG / SeatData / TP / Vivid. Refreshing the data is fine; influencing the source is forbidden.
- **No bypass — enforced mechanically.** `scripts/check_readonly.py` (CI static audit: fails the build on any write to a broker host, or a removed guard token) + `tests/test_readonly_guards.py` (asserts every client raises on POST/PUT/PATCH/DELETE). Weakening, deleting, or routing around either guard is a **security-CRIT** change (RULE-2 is **A1**'s DB/API-security domain as of the 2026-06-17 reorg; B1 owns git/code security) and is forbidden without explicit operator authorization.

### 3. Free reign on HTML / wiring within your lane

Each bot has operational latitude on UI files and JS wiring routed to them. Build, iterate, refactor without per-step approval.

Lane assignments per `PROJECT_BIBLE.md §2` (4-domain reorg 2026-06-17 — peer domains, not a chain):
- **A1** — data plane (DB + full ingest pipeline + DB security + crons)
- **B1** — git + code (git/code security, drift, freshness, compartmentalization, tests)
- **C1** — docs + coordination (`bot_chat`, the main bible set, promotions)
- **D0–D4** — distinct frontend surfaces (D0 terminal · D1 store · D2 dashboard · D3 broadway · D4 Exos/Bridge), each owning its Render service + UX/speed testing
- Operator may explicitly route work to a bot outside its default lane (this is the override path)

### 4. Render workspace — per-service scoped access (2026-05-14, reorg 2026-05-15; testing-unified 2026-05-16)

**Testing-unified architecture (2026-05-16, PR #168)**: During dev/test, all runtime traffic flows through `vibepass-storefront-test` (starter plan, no cold-start drag). It hosts D0 terminal + D1 storefront + D2 dashboard via `app.include_router` mounts in `app.py`. `vibepass-terminal-test` remains as the D0 static CDN host; `d2-orders-dashboard` stays alive as an idle placeholder. At beta, each surface migrates back to its own service via dedicated DNS + un-mounting from `app.py`.

Render MCP tools (`mcp__render__*`) are gated per-bot. Cross-service writes are forbidden without operator approval.

**A1 (Admin) — workspace-wide access:**
- All `mcp__render__*` tools on any service
- Workspace-level operations: `create_web_service`, `create_postgres`, `create_static_site`, `create_cron_job`, `select_workspace`
- Provisioning, deletion, ownership changes

**D0 — workspace-wide access (2026-05-16, operator directive — "full Render permissions"):**
- **Parity with A1 on Render**: all `mcp__render__*` tools on any service in the workspace, plus workspace-level operations (`create_*`, `select_workspace`, deletion, ownership changes)
- Standing write authority on all three frontend services (`vibepass-terminal-test`, `vibepass-storefront-test`, `d2-orders-dashboard`) + any future services D0 provisions
- D0 is sign-off authority on D1/D2 subordinate PRs touching their respective surfaces
- No restrictions — full Render parity with A1
- Coordination expectation: provisioning/deletion of customer-facing services is high-impact; D0 posts a `bot_chat` `flag` event for transparency, but no per-call operator approval required

**D1, D2 — subordinate coding arm under D0 (2026-05-15 reorg):**
- D1 still authors `static/store/*`, `app.py /api/store/*`, `render.yaml` (storefront IaC)
- D2 still authors `d2_dashboard/*`, order client code, `render-d2-dashboard.yaml`
- Render MCP **read-only** across all services; writes route through D0 approval + A1 merge
- Cross-service writes (e.g., D1 touching D2's surface) require D0 sign-off in PR comment

**All other bots (B1, C1, D3, D4):**
- Read-only across all services (monitoring is universal)
- All writes require explicit operator approval

**Standing rules across all bots:**
- Read ops always OK (no per-call ask)
- Service Tokens are the preferred mechanism for enforcement when feasible (Render's Member-role token can't perform writes by API constraint, providing hard isolation beyond policy). Until tokens are scoped per-bot, the scoping is policy-level and audited via Render's audit log.
- Cross-service writes (D1 touching D2's service or vice versa) = lane violation, surfaces as `flag` in `bot_chat` per existing cross-lane rules

### 5. Skill conventions (SKILL.md structure + discoverability)

Recurring procedures are encoded as **workflow skills** under `.claude-plugins/terminal2-governance/skills/<name>/SKILL.md` — the executable form of the `PROJECT_BIBLE.md §8` recipes. Shipped: `ship-a-migration`.

**SKILL.md structure** (four labeled sections, trimmed for token discipline; keep ≤~80 lines):
- **frontmatter** — `name`, `description`.
- **Process** — the numbered operative steps (check → act → tools).
- **Red flags** — the must-NOT list.
- **Verification** — a one-line evidence-based self-check the skill *reasons about* before finishing (phrase as a check, never an action). A `Rationalizations` table (excuse→rebuttal, wired to §3 landmines) is encouraged.

**Procedures → skills, facts → bibles, link don't copy** — a skill points to `§3`/`§0`/`§14`, never restates them.

**Discoverability is mechanical, not memory.** `.claude-plugins/terminal2-governance/hooks/hooks.json` runs a **PreToolUse** router (`scripts/skill_router.py`) that matches a tool call to a skill and injects a **non-blocking** nudge (editing `supabase/migrations/*.sql`, `apply_migration`, or DDL via `execute_sql` → surfaces `ship-a-migration`). Fires once per (session, skill); `ROUTES` is the single source of truth.

### 6. Documentation discipline — the canonical doc set is CLOSED (2026-05-28)

The repo's governance/reference docs are a **closed set**. The registry table in [`README.md`](README.md) lists every canonical root doc and exactly what it owns. This rule exists because the prior consolidation regrew into sprawl — nothing gated new-doc creation. Now there is a gate.

- **Do NOT create new root or governance `.md` files.** To add a fact, edit the doc that already owns that topic (the README registry names the owner). A genuinely new top-level doc is an operator decision — ask first.
- **No lane-specific bibles (2026-06-19).** Bots don't pre-know their lane at session start, so a per-lane `<BOT>_BIBLE.md` goes unread while the universal facts inside it get missed. Everything universal lives in the **main set** (`PROJECT_BIBLE`/`RESOURCES_BIBLE`); lane-specific *procedure* (e.g. building the D0 terminal) is an on-demand `docs/` reference, not a session-start read. (The former `D0_BIBLE.md` was split 2026-06-19: cross-source architecture → `PROJECT_BIBLE §5`, build manual → `docs/d0_terminal_build.md`.)
- **One fact, one home — never duplicate; link.** If a fact already lives somewhere, point to it (`see <DOC> §<n>`) rather than restating it. Duplicated facts are exactly how these docs drifted out of sync.
- **Ephemeral work never becomes a new doc.** Audits, checkpoints, session logs, handoffs, status snapshots → use `bot_chat` (durable cross-lane record) or `KANBAN.md` (open work). Only if a durable dated artifact is genuinely needed: `docs/archive/YYYY-MM-DD-<topic>.md` (historical, non-canonical).
- **Enforcement is a hard CI gate** (server-side; `--no-verify` cannot skip). `docs-registry-check` (`bin/check-docs.sh`) fails a PR that adds a root `*.md` not in the README registry, or a dated/working-note file in `docs/` outside `docs/archive/`. *(Keeping the bible current when a change adds a catalogued resource (RULE 0) is a judgment prompt — `PROJECT_BIBLE` self-check #12 + the PR checklist — deliberately NOT a gate: a mechanical check can't distinguish a change that needs a doc from one that doesn't, so forcing it would just spam no-op edits.)*
- **One `**Doc version:**` line per doc; no per-section tags (2026-06-19).** Bump the doc-version line on material change; the gate fails any registry doc (except `CHANGELOG.md`) missing it. Per-heading `(vX · BOT · date)` tags are removed — git blame is the audit trail. Full convention in [`README.md`](README.md) *Doc-writing rules*.

## Cross-lane writes

If your work needs to touch another lane's surface:
1. Propose via PR comment to the lane owner first
2. If owner offline, surface as `flag` in `bot_chat` for B1/A1 resolution
3. **Never silently write across lanes** — even read-only-looking writes (e.g. cache files, logs) count

## Push protocol *(reorg 2026-06-17)*

- **Push to `main` is per-task/per-agent, not bot-tier-gated.** A1 + B1 jointly maintain `main`; each task is pushed by the bot it's delegated to, after green CI. (Supersedes the prior "A1 sole pusher" immutable rule, operator directive 2026-06-17. See `PROJECT_BIBLE.md §2.3`.)
- **Prod-DB apply stays centralized on A1** — D-tier has zero Supabase mutation authority; a DB change is filed as a migration + `bot_chat` to A1, who applies it. (Git push ≠ DB apply; only the latter is centralized.)
- Open a PR per task; CI must be green before merge.

## When in doubt

- Ask via `AskUserQuestion` for a quick clarification
- Use `bot_chat` `question` event_type for cross-lane queries
- Read-only investigation is always safe; mutation is never safe by default
