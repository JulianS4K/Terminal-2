# CLAUDE.md — project-wide operating rules for Claude Code sessions

Loaded automatically by Claude Code on every session in this repo. Applies to **all** bots regardless of lane.

> **Doc version:** v1.1.0 · baseline v1.0.0 2026-05-28 (A1); v1.1.0 2026-05-28 (A1) — §5 adds the forward-only SKILL.md structure standard. Section-level version + bot-ref convention → §6 *Documentation discipline* + [`README.md`](README.md) *Doc-writing rules*.

## 🔖 READ PROJECT_BIBLE.md FIRST (token discipline)

**Before doing anything, read [`PROJECT_BIBLE.md`](PROJECT_BIBLE.md).** It consolidates the 80% you need from this file + BOT_HIERARCHY.md + MIGRATION_CONVENTIONS.md + data-source docs into a single per-session reference. Saves ~5× the tokens vs reading every governance file at session start.

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

Per-lane detail — per-bot scope, push-restrictions matrix, and Render service scope — all live in `BOT_HIERARCHY.md` (it absorbed the former `LANE_DISCIPLINE.md` on 2026-05-28). Per-bot self-contracts live at `docs/<bot>_operating_constraints.md`.

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

### 3. Free reign on HTML / wiring within your lane

Each bot has operational latitude on UI files and JS wiring routed to them. Build, iterate, refactor without per-step approval.

Lane assignments per `BOT_HIERARCHY.md`:
- **D0** — Terminal FE (`static/terminal/*` when built)
- **D1** — Consumer Retail (`static/store/*`, `static/store/test/*` sandbox)
- **C1** — supervisor docs + audit harnesses + lane discipline
- Operator may explicitly route HTML work to a bot outside its default lane (this is the override path)

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

### 5. Bot onboarding — mandatory aging-sweep scheduled task (2026-05-15) *(v1.1 · A1 · 2026-05-28)*

Every active bot MUST create its own lane-scoped aging-sweep scheduled task on first activation. Operator-mandated 2026-05-15 (bot_chat 210).

**Spec — each bot's task must:**
- Cadence: **hourly** at a unique minute offset (avoid collisions, see slot registry below)
- Query: `public.bot_chat` for entries addressed to this bot (via `bot_lane = '<this-bot>'` OR `@<this-bot>` substring match) AND `resolved_at IS NULL` AND `event_type IN ('p0_security','flag','question')` AND `created_at < now() - interval '2 hours'` AND `created_at > now() - interval '7 days'`
- **Always post (HEARTBEAT pattern, 2026-05-15 operator directive)** — even on zero findings, fire a short "all clear" line. Silent posts mean we can't distinguish "healthy" from "task dead." Vary content based on findings (full table if hits, one-line OK if not).
- Post to the bot's primary Slack channel (`#terminal-2-d0` for D-tier subordinates, `#terminal-2-admin` for A1/B1/C1, `#terminal-2-alerts` for cross-cutting global sweep)
- Tools required: Supabase MCP `execute_sql` + Slack MCP `slack_send_message` (operator must "Run now" once per task to pre-approve)
- Token discipline: tight payload, table format, no preamble

**Minute slot registry (claim by editing this section in your onboarding PR):**

| Slot | Bot | Task name |
|---|---|---|
| `:00` | A1 | `bot-chat-aging-sweep` (global, posts to `#terminal-2-alerts`) |
| `:15` | B1 | `b1-security-autocheck` |
| `:45` | D2 | `d2-bot-chat-monitor` |
| `:05`, `:10`, `:20`, `:25`, `:30`, `:35`, `:40`, `:50`, `:55` | **available** | — |

**Reference implementation**: `bot-chat-aging-sweep` shipped 2026-05-15 (A1). See `mcp__scheduled-tasks__create_scheduled_task` schema + the prompt embedded in that task's SKILL.md at `C:\Users\julia\.claude\scheduled-tasks\bot-chat-aging-sweep\SKILL.md`.

**Why mandatory**: today's cron cascade incident (bot_chat 195) was caught in 3h by B1's interactive sweep. A1 missed it for that whole window because A1 only had a global aging sweep (every bot's items, no lane-specific focus). Per-bot sweeps catch lane-addressed work fast.

**SKILL.md structure (forward-only, 2026-05-28).** New or revised task `SKILL.md` files use the four labeled sections below. Existing tasks are **grandfathered** — owners upgrade their own opportunistically (lane-scoped; A1 does not rewrite another bot's task file). Adapted from the public `agent-skills` pattern, deliberately trimmed to keep our token discipline: keep the parts that catch real failure modes, drop the verbose boilerplate.
- **frontmatter** — `name`, `description` (unchanged).
- **Process** — the numbered operative steps (query → act → tools); same content, just labeled.
- **Red flags** — the must-NOT list, e.g. "never post to `bot_chat` (feedback loop)"; "a silent run looks identical to a dead task."
- **Verification** — a one-line self-check the task *reasons about* before finishing, e.g. "confirm exactly one Slack post fired." Phrase as a check, **never an action** — wording it as a step can trigger a duplicate post.

Keep payloads ≤1500 chars and the file ≤~80 lines — brevity beats ceremony; omit any section that doesn't apply.

### 6. Documentation discipline — the canonical doc set is CLOSED (2026-05-28)

The repo's governance/reference docs are a **closed set**. The registry table in [`README.md`](README.md) lists every canonical root doc and exactly what it owns. This rule exists because the prior consolidation regrew into sprawl — nothing gated new-doc creation. Now there is a gate.

- **Do NOT create new root or governance `.md` files.** To add a fact, edit the doc that already owns that topic (the README registry names the owner). A genuinely new top-level doc is an operator decision — ask first.
- **One fact, one home — never duplicate; link.** If a fact already lives somewhere, point to it (`see <DOC> §<n>`) rather than restating it. Duplicated facts are exactly how these docs drifted out of sync.
- **Ephemeral work never becomes a new doc.** Audits, checkpoints, session logs, handoffs, status snapshots → use `bot_chat` (durable cross-lane record) or `KANBAN.md` (open work). Only if a durable dated artifact is genuinely needed: `docs/archive/YYYY-MM-DD-<topic>.md` (historical, non-canonical).
- **Enforcement is a hard CI gate.** `.github/workflows/docs-registry-check.yml` (via `bin/check-docs.sh`) fails any PR that adds a root `*.md` not in the README registry, or drops a dated/working-note file into `docs/` outside `docs/archive/`. It runs server-side — `--no-verify` cannot skip it.
- **Version docs + tag section changes (2026-05-28).** Each canonical doc carries a `**Doc version:**` line (semver, baseline `v1.0.0`). When you add or materially change a section, tag its heading `(vX.Y · <BOT> · YYYY-MM-DD)` and bump the doc-version line — full convention in [`README.md`](README.md) *Doc-writing rules*. `CHANGELOG.md` is exempt. The gate also fails any registry doc missing its `**Doc version:**` line.

## Cross-lane writes

If your work needs to touch another lane's surface:
1. Propose via PR comment to the lane owner first
2. If owner offline, surface as `flag` in `bot_chat` for B1/A1 resolution
3. **Never silently write across lanes** — even read-only-looking writes (e.g. cache files, logs) count

## Push protocol

- **A1 is sole pusher to `main`** (see `MIGRATION_CONVENTIONS.md §9`)
- **B1 = test prod** (active integration; under the 2026-05-13 protocol, lands subordinate work before A1 promotes to main)
- Subordinate bots open PRs against the supervisor branch first, never directly against main

## When in doubt

- Ask via `AskUserQuestion` for a quick clarification
- Use `bot_chat` `question` event_type for cross-lane queries
- Read-only investigation is always safe; mutation is never safe by default
