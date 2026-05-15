# CLAUDE.md — project-wide operating rules for Claude Code sessions

Loaded automatically by Claude Code on every session in this repo. Applies to **all** bots regardless of lane.

Per-lane detail in `LANE_DISCIPLINE.md` (per-bot scope) + `BOT_HIERARCHY.md` (push restrictions matrix). Per-bot self-contracts live at `docs/<bot>_operating_constraints.md` (referenced in the top matter of `LANE_DISCIPLINE.md`).

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

Lane assignments per `LANE_DISCIPLINE.md`:
- **D0** — Terminal FE (`static/terminal/*` when built)
- **D1** — Consumer Retail (`static/store/*`, `static/store/test/*` sandbox)
- **C1** — supervisor docs + audit harnesses + lane discipline
- Operator may explicitly route HTML work to a bot outside its default lane (this is the override path)

### 4. Render workspace — per-service scoped access (2026-05-14, reorg 2026-05-15)

Render MCP tools (`mcp__render__*`) are gated per-bot. Cross-service writes are forbidden without operator approval.

**A1 (Admin) — exclusive workspace-wide access:**
- All `mcp__render__*` tools on any service
- Workspace-level operations: `create_web_service`, `create_postgres`, `create_static_site`, `create_cron_job`, `select_workspace`
- A1 is the only bot authorized to provision, delete, or change ownership of services

**D0 — consolidated frontend lane (2026-05-15 reorg):**
- **Write authority on all three frontend services**: `vibepass-terminal-test` (`srv-d839339kh4rs73ac3s20`), `vibepass-storefront-test` (`srv-d8140bnaqgkc73al4asg`), `d2-orders-dashboard` (`srv-d82b4kl7vvec73b4r3r0`)
- Permitted writes (no per-call ask): `update_environment_variables`, `update_web_service`, restart, redeploy triggers
- D0 is sign-off authority on D1/D2 subordinate PRs touching their respective surfaces
- Forbidden: workspace-level operations (A1-only)

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

### 5. Bot onboarding — mandatory aging-sweep scheduled task (2026-05-15)

Every active bot MUST create its own lane-scoped aging-sweep scheduled task on first activation. Operator-mandated 2026-05-15 (bot_chat 210).

**Spec — each bot's task must:**
- Cadence: **hourly** at a unique minute offset (avoid collisions, see slot registry below)
- Query: `public.bot_chat` for entries addressed to this bot (via `bot_lane = '<this-bot>'` OR `@<this-bot>` substring match) AND `resolved_at IS NULL` AND `event_type IN ('p0_security','flag','question')` AND `created_at < now() - interval '2 hours'` AND `created_at > now() - interval '7 days'`
- Silent if zero rows (no Slack noise on healthy state — the absence of pings is the signal)
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
