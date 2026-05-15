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

### 4. Render workspace — per-service scoped access (2026-05-14)

Render MCP tools (`mcp__render__*`) are gated per-bot to their assigned service. Cross-service writes are forbidden without operator approval.

**A1 (Admin) — exclusive workspace-wide access:**
- All `mcp__render__*` tools on any service
- Workspace-level operations: `create_web_service`, `create_postgres`, `create_static_site`, `create_cron_job`, `select_workspace`
- A1 is the only bot authorized to provision, delete, or change ownership of services

**D1 — scoped to `vibepass-storefront-test` (`srv-d8140bnaqgkc73al4asg`):**
- Read freely: `list_services`, `get_service`, `list_deploys`, `get_deploy`, `list_logs`, `get_metrics`
- **Write OK on this service** (no per-call ask): `update_environment_variables`, `update_web_service` (config / branch / build / start commands), restart, redeploy triggers
- Forbidden: any operation on `d2-orders-dashboard` or `hi-events` or workspace-level resources

**D2 — scoped to `d2-orders-dashboard` (`srv-d82b4kl7vvec73b4r3r0`):**
- Same as D1 but for its assigned service
- Write OK on `d2-orders-dashboard` only
- Forbidden: any operation on `vibepass-storefront-test`, `vibepass-terminal-test`, `hi-events`, or workspace-level resources

**D0 — scoped to `vibepass-terminal-test` (provisioned 2026-05-15):**
- Same as D1/D2 but for its assigned service (static-site type, serves `static/terminal/*`)
- Write OK on `vibepass-terminal-test` only
- Forbidden: any operation on other services or workspace-level resources

**All other bots (B1, C1, D3, D4):**
- Read-only across all services (monitoring is universal)
- All writes require explicit operator approval

**Standing rules across all bots:**
- Read ops always OK (no per-call ask)
- Service Tokens are the preferred mechanism for enforcement when feasible (Render's Member-role token can't perform writes by API constraint, providing hard isolation beyond policy). Until tokens are scoped per-bot, the scoping is policy-level and audited via Render's audit log.
- Cross-service writes (D1 touching D2's service or vice versa) = lane violation, surfaces as `flag` in `bot_chat` per existing cross-lane rules

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
