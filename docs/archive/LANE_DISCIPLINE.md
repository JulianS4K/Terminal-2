# LANE_DISCIPLINE.md — per-lane operating rules

**Reorg 2026-05-28** — new mandate split (A1=ops/SQL monitor, B1=security+governance, C1=D-tier coordinator, D0=user visual layer). D1-E1 PAUSED until D0 is working.

Per 2026-05-12 hierarchy restructure (updated 2026-05-28). Each bot writes only to its assigned files / tables / crons / edge functions. Out-of-lane writes require PR comment to the lane owner first.

**Companion to `BOT_HIERARCHY.md`** (repo root) — that doc is the quick-reference: hierarchy diagram, push restrictions matrix, single-writer table ownership, fast-path workflow, SECURITY DEFINER convention. **This doc is the detail**: per-lane writes / never-writes / function-call rules.

**Per-bot self-contracts** sit one layer below this. Bots may author their own deep operational detail file at `docs/<bot>_operating_constraints.md`. Known instances:
- `docs/d1_operating_constraints.md` (PR #77) — D1's self-contract (PAUSED; preserved for reactivation)

When a per-bot doc exists, it MUST be consistent with this doc and `BOT_HIERARCHY.md`. If a conflict surfaces, this doc + BOT_HIERARCHY.md win until reconciled.

See also: `docs/bot-hierarchy.mermaid` (visual diagram) and `MIGRATION_CONVENTIONS.md` (migration / commit conventions that overlay this scope map).

## Lane assignments

| ID | Lane | Mandate | Status |
|---|---|---|---|
| A1 | SQL Monitor / DB Ops / Git / Connectors | Monitor + fix SQL, Supabase alerts, all data sources, crons, tables, git + syncs, Jira/Asana + connectors | **ACTIVE** |
| B1 | Security + Governance Monitor | Security (RLS/SECDEF/CRIT), bibles, git, Jira/Asana, other bot notes | **ACTIVE** |
| C1 | D-tier Project Coordinator + Drift Prevention | Monitor + assist D0-D4 projects + docs; prevent code drift; daily checkpoint | **ACTIVE** |
| D0 | Terminal FE — User Visual Layer | Primary user interface for project progress; visual of A1 for user; Render workspace-wide perms | **ACTIVE — PRIORITY** |
| D1 | Consumer Retail | Storefront + /api/store/* | **PAUSED** |
| D2 | Order Clients | 5 order SDKs + dashboard | **PAUSED** |
| D3 | Broadway (sub-D2) | broadway_client.py + broadway_* | **PAUSED** |
| D4 | Our Ticketing Infra | Exos schema live, data dormant; blocked on creds | **PAUSED** |
| E1 | Integration / Automation | Zapier, WhatsApp, Slack alerts, webhooks (rebrand from Kalshi placeholder) | **PAUSED** |

## Per-lane restrictions

### A1 — SQL Monitor / DB Ops / Git / Connectors (2026-05-28 mandate)

**Primary mission:** monitor the entire operational stack, detect issues, fix them fast, keep git + prod in sync.

**Monitors (continuous — flags to bot_chat on alert):**
- Supabase cron `job_run_details` — failures, timeouts, consecutive errors
- `v_sg_broker_429_health` — 429 rate per scope; alert threshold >15%
- Table sizes + growth rates — `listings_snapshots`, `seatgeek_listings_snapshots`, `ticketsdata_listings_snapshots`
- Data source freshness — TEvo polling cadence, SG priority pipeline health, TD batch timing
- Migration drift — prod-applied vs repo files (via `migration_drift_check()`)
- `bot_chat` unresolved flags (aging sweep)
- Jira/Asana task status — surface stale operator-action items
- Git sync — `main` vs deployed branches; stale PRs

**Writes:**
- All foundation + ops migrations (sweep functions, xref, cron schedules, ingest tables)
- `app.py` (backend / FastAPI routes — coordinate with D0/D1)
- `evo_client.py`, `requirements.txt`, `Procfile`
- `MIGRATION_CONVENTIONS.md`, `SCHEMA.md`, governance docs in `docs/`
- `event_xref`, `canonical_external_ids`, `espn_*`, `event_movers_index`, sweep functions
- Ledger reconciliation in `supabase_migrations.schema_migrations`

**Reads:** everything.

**Authority:**
- Sole pusher to `main` (immutable — CLAUDE.md)
- Reviews all PRs against `MIGRATION_CONVENTIONS.md §9`
- Applies migrations to prod via MCP
- Approves merges

### B1 — Security + Governance Monitor (2026-05-28 mandate)

**Primary mission:** own security AND governance monitoring — keeps code safe, docs accurate, and bot coordination healthy.

**Security (existing):**
- RLS coverage audits, SECURITY DEFINER function audit, anon-exposure harness
- CRIT/HIGH patches (cross-cutting write authority for security fixes)
- Reviews security-sensitive PRs; owns hand-apply gate for RLS migrations

**Governance monitoring (expanded 2026-05-28):**
- **Bibles**: monitor PROJECT_BIBLE, LANE_DISCIPLINE, BOT_HIERARCHY, AGENTS.md for drift vs actual state. Flag discrepancies to A1.
- **Git**: monitor repo for secret leaks, insecure patterns; review open PRs for security
- **Bot notes**: read + audit `bot_chat` aging items; flag stale unresolved threads to A1
- **Jira/Asana**: track security + governance tickets; surface blockers

**Writes (cross-cutting allowed):**
- `KANBAN.md` security backlog
- `docs/security-runbook-*.md`
- `docs/proposed-migrations/*_security_*.sql` (hand-apply gate)
- `supabase/migrations/*_security_*.sql` (auto-apply set)
- `supabase/functions/_shared/cron-auth.ts`
- Per-lane patches for security CRIT/HIGH (coordinate via PR comment to lane owner)

**Reads:** everything.

**Authority:**
- Resolves `event_type IN ('p0_security', 'flag')` in bot_chat
- Middle-man review between C1 and A1 for security-sensitive PRs
- Flag governance-doc drift to A1 for correction

### C1 — D-tier Project Coordinator + Code Drift Prevention (2026-05-28 mandate)

**Refocused 2026-05-28** — narrowed from 6-function overload to 3 clear responsibilities: D-tier project monitoring + docs assistance + drift prevention.

**Primary mission:** ensure D0-D4 projects move forward, docs stay accurate, and code/prod don't diverge.

**D-tier project monitoring:**
- Track open PRs for D0-D4 lanes; flag stale (>24h without activity) to A1
- Read `bot_chat` items addressed to D-tier bots; surface blockers to A1/B1
- Track task status for D0-specific deliverables (the priority lane)
- When D1-E1 reactivate: coordinate their project docs and PR routing

**Docs assistance:**
- Keep D-tier design docs, wireframes, runbooks consistent with actual implementation
- Flag doc-reality drift (e.g., LANE_DISCIPLINE says D0 does X but D0 actually does Y)
- Assist D-tier bots with cross-lane doc questions

**Code drift prevention (daily checkpoint):**
1. `git fetch --all`; compare `main` vs last-known deployed state
2. `SELECT * FROM public.migration_drift_check()` — flag any prod-applied-but-no-file or file-but-unapplied
3. `SELECT * FROM public.release_health_check() WHERE status <> 'ok'` — surface new failures
4. Post daily checkpoint summary to `bot_chat` (`event_type='checkpoint'`)
5. Route fixes: migrations → A1, security → B1, code → lane owner via PR comment

**Writes (in lane):**
- `docs/c1-checkpoint-*.md` — daily checkpoint reports
- `docs/c1_daily_checkpoint_runbook.md` — the runbook
- `bot_chat` checkpoint + drift-flag entries
- PR stale-close comments (cross-lane coordination)

**Writes NOT in lane** (delegate):
- Migrations to fix drift → A1
- Security findings → B1
- Bot-lane code changes → lane owner via PR comment
- Connector integrations → E1 (when activated)

**Removed from C1 scope (2026-05-28):**
- PR management / merge authority → D0 (for D-tier PRs)
- Connector integrations (Zapier/Slack/WhatsApp) → E1
- Health-check regression blocking → B1 + A1

**Reads:** everything.

**Authority:**
- Flag drift to A1 for resolution
- Post stale-PR comments (surface for A1 close decision)

### D0 — Terminal FE — User Visual Layer (PRIORITY, 2026-05-28 mandate)

**Mission:** be the user's single window into project health and trading intelligence.
- **Visual of A1 for user**: D0 renders everything A1 monitors so the operator can see at a glance whether infra is healthy.
- **Trading intelligence**: event detail, movers index, discovery gaps, performer/venue pages with live multi-source data.
- **D0 is the gating condition** for D1-E1 reactivation.

**What "D0 is working" means:**
The operator opens the terminal and sees:
1. Ops health dashboard — cron status (all jobs: last fire, last success, consecutive failures), 429 rates by scope, table sizes, pipeline freshness per data source (TEvo/SG/TD), recent bot_chat activity
2. Trading surfaces — event detail with TD/SG/EVO panels, movers v2 index, discovery gaps
3. All live data (no stale/empty panels) for the active event set

**Writes:**
- `static/terminal/*.html`, `static/terminal/*.js`, `static/terminal/*.css`
- `docs/event-view-wireframe-*.md`, `docs/d0-*.md`
- `app.py` `/api/broker/*` routes (coordinate with A1)

**NEVER writes:**
- Any database table directly
- Any cron schedule (author migration; A1 applies)
- Any edge function that mutates data
- D1-E1 lane files (those lanes are PAUSED; don't touch them)

**Render workspace authority (2026-05-16, confirmed 2026-05-28):**
Full workspace-wide parity with A1. All `mcp__render__*` tools, `create_*`, `select_workspace`, provisioning/deletion/ownership. Post `bot_chat flag` for transparency on customer-facing service changes; no per-call operator approval required.

**Reads:** entire data plane.

---

## ⏸ D1 · D2 · D3 · D4 · E1 — PAUSED (2026-05-28)

**All lanes below are paused until D0 is working.** No new PRs, no new migrations, no new deploys. Existing deployed code stays running. These sections are preserved as reference for reactivation.

---

### D1 — Consumer Retail (PAUSED — subordinate to D0)

**Reports to D0.** Authors storefront code; D0 reviews + approves PRs; A1 merges after green CI.

**Writes (source files):**
- `app.py` `/api/store/*` + `/store/*` routes (coordinate with A1)
- `static/store/*.html`, `static/store/*.js`, `static/store/*.css`
- `share_links` table migrations
- `bot_messages` (chat write surface — if D1 owns chat)

**Never writes (source files):**
- Broker terminal HTML (`static/index.html`, `static/event.html`, `static/movers.html`)
- Order client `.py` files (D2 territory: `seatdata_client.py`, `evo_client.py`, `seatgeek_client.py`, `tickpick_client.py`, `vivid_client.py`)
- Broadway scraper (D3)
- Edge functions outside `chat`
- Listings / xref infrastructure migrations

**May invoke (server-side function calls):**
- `evo_client.py` functions for retail-facing search / browse / availability (D2 owns the file; D1 imports + calls)
- `*_public` RPCs from Supabase (e.g., `get_event_zones_public`, `get_event_listings_public`, `get_events_by_performer_public`, `submit_lead_public`, `get_cached_ticket_groups`)
- `retail_*` views — designed for consumer surface
- `chat` edge function

**Never invokes:**
- Broker-private RPCs (anything tagged `get_broker_*`, `broker_*_dashboard`, `audit_*`)
- Direct TEvo paths that return wholesale fields (use the public-RPC wrappers)

**Must filter from any client response:**
- `wholesale_price`, `wholesale_min`, `wholesale_*`
- `brokerage_id`, `brokerage_name`, `office_id`, `office_name`
- `is_owned`, `is_ancillary` provenance flags that reveal S4K's inventory position (see storefront carveout below)
- TEvo signing tokens, API tokens, secrets from vault
- Raw broker_* table rows
- Any column not whitelisted by a `*_public` RPC

**Storefront-product carveout (`/api/store/*` only, codified 2026-05-18 from B1 war-games W-3 / bot_chat 308):**

The storefront is a "100% we-own catalog" by product design — every event surfaced is one S4K holds inventory for, with no "browse market" fallthrough (see `store_events()` docstring in `app.py`). Under this model the following fields are **intentionally exposed** on `/api/store/*` responses and power the retail availability UX ("X tix · Y listings" badge in `static/store/store.js`, buyable-vs-browse split):

- `we_own` (bool) — drives result prioritization in `/api/store/search`
- `owned_tix` / `owned_tickets_count` (int) — inventory-availability count
- `owned_groups_count` (int) — listings count for the same event

These are retail-availability signals (analogous to "5 tickets left" on any consumer ticket marketplace), not wholesale-side broker flags. The broader `is_owned` / `is_ancillary` rule above still applies to terminal / portfolio / broker API responses where the field carries wholesale-position semantics.

**Filter pattern:** call public-RPC → response only contains retail-safe fields → serialize that to client. Never dump raw broker rows. RULE 7 (retail product = S4K-owned only) applies: listings exposed must be filtered to S4K-owned where applicable.

**Reads:** events, listings_snapshots, event_metrics, performer / venue context, share_links

**Owns deploy infra:**
- **Render service: `vibepass-storefront-test`** (`srv-d8140bnaqgkc73al4asg`). D1 manages env vars, deploy config, log monitoring, and `render.yaml` IaC for this service exclusively. Auto-deploys from `main` branch.
- **Render MCP write authority on this service** (no per-call operator ask): `update_environment_variables`, `update_web_service`, redeploy triggers, restart. Cross-service ops (anything touching `d2-orders-dashboard` or workspace-level) remain forbidden without operator approval.
- D1 does **NOT** own `d2-orders-dashboard` — that surface is D2's (see below).

### D2 — Order Clients (subordinate to D0 as of 2026-05-15)

**Reports to D0.** Authors order-client code + dashboard code; D0 reviews + approves PRs; A1 merges after green CI.

**Writes:**
- `seatdata_client.py`, `seatgeek_client.py`, `evo_client.py` (order paths only)
- `tickpick_client.py`, `vivid_client.py`, `gotickets_client.py`
- `d2_dashboard/` — standalone FastAPI service rendering all broker order surfaces (PR #85). D2-exclusive write surface.
- `tests/test_readonly_guards.py`, `tests/test_d2_dashboard.py`, `scripts/check_readonly.py` (RULE 2 enforcement)
- Order tables: `evo_orders`, `evo_order_items`, `evo_orders_pending`, `evo_event_backfill_pending`, `seatgeek_orders`, `seatgeek_order_tickets`, `sg_seller_pending`, `seatdata_sales_snapshots`, `seatdata_pull_budget`, `seatdata_pull_log`
- Order-related crons (evo_orders_*, sg_seller_orders_*, seatdata sales)
- `requirements.txt` (when adding D2-specific deps; pinning shape per A1 convention)

**NEVER writes:**
- Listings infrastructure (`sg_listings_*`, `seatgeek_listings_snapshots`, `seatdata_listings_snapshots`, `seatgeek_seller_listings`) — A1 / canonical
- Storefront files
- Broker terminal files
- Broadway code
- `SCHEMA.md` (propose updates via PR comment to A1)
- D1's Render service (`vibepass-storefront-test`) — D1 owns

**Reads:** events, performer / venue context for join purposes, A1's listings tables for cross-validation

**Owns deploy infra:**
- **Render service: `d2-orders-dashboard`** (`srv-d82b4kl7vvec73b4r3r0`). D2 manages env vars, deploy config, log monitoring, and `render-d2-dashboard.yaml` IaC for this service exclusively. Auto-deploys from `main` branch; D2's order-related PRs that affect `d2_dashboard/` trigger auto-redeploys on merge.
- **Render MCP write authority on this service** (no per-call operator ask): `update_environment_variables`, `update_web_service`, redeploy triggers, restart. Cross-service ops (anything touching `vibepass-storefront-test` or workspace-level) remain forbidden without operator approval.
- D2 does **NOT** own `vibepass-storefront-test` — that surface is D1's.

### Undelivered FE (sub of D2)

**Writes:**
- Future `static/undelivered/*` UI when scope activates
- Same scope as D2's order data, **excluding** seatdata

**Reads:** D2's order tables (evo + sg + tickpick + vivid), **NOT** seatdata

### D3 — Broadway (sub of D2)

**Writes:**
- `broadway_client.py`
- `tests/test_broadway_client.py`, `tests/fixtures/checkout_sections_*.html`
- Future `supabase/functions/broadway_collect/index.ts`
- Future `broadway_*` tables (`broadway_shows`, `broadway_performances`, `broadway_sections_snapshots`, `broadway_pull_log`, `broadway_event_xref`)
- `broadway_collect_daily` cron
- Optional vault secret `BROADWAY_USER_AGENT`

**NEVER writes:**
- Order clients
- Storefront
- Other ingest clients
- Edge functions outside `broadway_collect/`
- D1's Render service (`vibepass-storefront-test`) — D1 owns; touch only D1's surface

**Reads:** `canonical_external_ids` for xref propagation (write into own `broadway_event_xref`, propagation handled by drift triggers in A1 / canonical lane)

### D4 — Our Ticketing Infra (future)

**Writes:** TBD when scope activates. AR codes, custom ticketing infrastructure.

**NEVER writes:**
- Anything outside its own future namespace
- D1's Render service (`vibepass-storefront-test`) — D1 owns; touch only D1's surface — D4 gets its own deploy target when scoped, not Render

### E1 — Integration / Automation (PAUSED — rebrand 2026-05-28)

**Status**: PAUSED. Reactivates after D0 is working.

**Rebrand (2026-05-28)**: lane repurposed from "Kalshi/prediction markets placeholder" to **Integration / Automation**. First deliverables when activated:
- Zapier → Slack: 429+cron failure alerts (was delegated to C1 via bot_chat #779)
- Zapier → Gmail: D4 transactional email relay
- Zapier → Sheets: order tracking spreadsheet
- WhatsApp / Telegram: ops notification bot
- Future: Kalshi integration (fits naturally in this lane — same external-API integration pattern)

**Writes (when active)**:
- `docs/e1-*.md` integration design notes
- Edge functions for webhook routing (`supabase/functions/webhook-*`)
- Migration files matching `*_integrations_*.sql`
- `integrations_*` tables

**NEVER writes**:
- Ticket-ingest pipelines (A1 territory)
- Frontend code (D-tier territory)
- Order tables (D2 territory)

## Cross-cutting rules

1. **Shared files** — propose changes via PR comment to the owner before editing:
   - `app.py` (A1 owns, D1 has /api/store/*)
   - `requirements.txt` (A1 owns pinning shape; lanes add their own deps)
   - `MIGRATION_CONVENTIONS.md`, `SCHEMA.md`, `AGENTS.md` (A1 / shared)
   - `docs/bot-hierarchy.mermaid` (C1 maintains for restructures)
   - `KANBAN.md` (B1 + A1 share)

2. **Single-writer per table** — see `MIGRATION_CONVENTIONS.md §4`. Each table has one owning lane that writes; others read.

3. **Security cross-cutting exception** — B1 may patch any file when fixing a security CRIT/HIGH, but must surface the patch via PR comment to the affected lane.

4. **Out-of-lane writes** — require PR comment to lane owner before push. If lane owner is offline, surface as `flag` in bot_chat for B1 / A1 resolution.

5. **SECURITY DEFINER convention** — every new SECURITY DEFINER function must ship in one migration with:
   - `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`
   - Explicit `GRANT EXECUTE ... TO service_role`
   - `IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN RAISE EXCEPTION` at body start

6. **Deploy infrastructure ownership** — D0 consolidates all frontend services (2026-05-15 reorg):

   | Render service | ID | Lane owner (D0) | Subordinate implementer | Source code | IaC file |
   |---|---|---|---|---|---|
   | `vibepass-terminal-test` | `srv-d839339kh4rs73ac3s20` | **D0** | D0 | `static/terminal/*` | `render-d0-terminal.yaml` |
   | `vibepass-storefront-test` | `srv-d8140bnaqgkc73al4asg` | **D0** | D1 (subord) | `app.py`, `static/store/*` | `render.yaml` |
   | `d2-orders-dashboard` | `srv-d82b4kl7vvec73b4r3r0` | **D0** | D2 (subord) | `d2_dashboard/*` | `render-d2-dashboard.yaml` |
   | `hi-events` (separate repo) | `srv-d7g0cev7f7vs73blkc70` | n/a (not Terminal-2) | — | — | — |

   - **D0 is the lane owner** across all three frontend services as of 2026-05-15. D0 manages env vars, deploy config, log monitoring, and IaC for every frontend service.
   - **D1 and D2 are subordinate coding arms.** They still author code in their respective directories (D1 → storefront, D2 → dashboard) but their PRs require **D0 sign-off** in a PR comment before A1 merges. D1/D2 have Render MCP **read-only** access; writes route through D0 + A1.
   - Per-bot Render access scope (per CLAUDE.md §4, updated 2026-05-16 with D0 full-permissions directive):
     - **A1** — workspace-wide access: all read + write ops on any service, plus `create_*` / `select_workspace`, provisioning, deletion, ownership changes
     - **D0** — **workspace-wide parity with A1** (2026-05-16): all read + write ops on any service, plus `create_*`, deletion, ownership changes, future-service provisioning. No restrictions.
     - **D1, D2** — read-only on all Render surfaces; writes route through D0 review + A1 merge
     - **B1 / C1 / D3 / D4** — read-only across all services; writes require operator approval
   - **Deploy gating (2026-05-15)**: backend test workflow (`.github/workflows/tests.yml`) must pass on a PR before A1 merges to `main`. Auto-deploy fires only after green CI lands on `main`. No exceptions.
   - Both services auto-deploy from `main`. A1 (sole pusher to main) merges PRs; each push triggers auto-deploys on both services since both watch `main`. If a PR only touches one service's surface, the other service still redeploys (no-op for it but burns build minutes — acceptable for free tier).
   - **Future split** option if build-time waste becomes painful: each service moves to a bot-specific deploy branch (e.g. `d1/release`, `d2/release`), and A1 fast-forwards each one when their respective code paths change. Deferred until volume justifies the merge-coordination cost.

   - **Railway** — current legacy deploy home for the broker terminal + backend. A1 governs migration off Railway → Render as scope warrants. Subordinates do not touch Railway configuration.
   - **Supabase** — shared platform; per-table ownership via `MIGRATION_CONVENTIONS §4`. RLS coverage maintained by B1.
   - **Future D4 infra** — when scope activates, D4 gets its own deploy target. Choice (Render workspace, Cloudflare Workers, custom) deferred until then.

## Enforcement

- A1 catches violations during §9 review
- B1 catches security-class violations
- C1 catches lane-discipline violations in supervised work
- All violations logged as `flag` in `bot_chat`; resolved by B1 (security findings) or A1 (governance)
