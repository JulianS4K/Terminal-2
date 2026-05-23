# LANE_DISCIPLINE.md — per-lane operating rules

Per 2026-05-12 hierarchy restructure. Each bot writes only to its assigned files / tables / crons / edge functions. Out-of-lane writes require PR comment to the lane owner first.

**Companion to `BOT_HIERARCHY.md`** (repo root) — that doc is the quick-reference: hierarchy diagram, push restrictions matrix, single-writer table ownership, fast-path workflow, SECURITY DEFINER convention. **This doc is the detail**: per-lane writes / never-writes / function-call rules / client-response filters.

**Per-bot self-contracts** sit one layer below this. Bots may author their own deep operational detail file at `docs/<bot>_operating_constraints.md`. Known instances:
- `docs/d1_operating_constraints.md` (PR #77) — D1's self-contract: read surface (TEvo endpoints + Supabase tables), write surface (storefront routes only), forbidden actions, Sprint 2 freeze conditions

When a per-bot doc exists, it MUST be consistent with this doc and `BOT_HIERARCHY.md`. If a conflict surfaces, this doc + BOT_HIERARCHY.md win until reconciled.

See also: `docs/bot-hierarchy.mermaid` (visual diagram) and `MIGRATION_CONVENTIONS.md` (migration / commit conventions that overlay this scope map).

## Lane assignments

| ID | Lane | Active bot | Status |
|---|---|---|---|
| A1 | Admin / Audit / Push | `mystifying-lederberg-ea407b` | active |
| B1 | Security Manager | `review-supabase-access-v8Dtl` | active |
| C1 | Drift Monitor + Daily Checkpoint Merger (was: Data + Chat Supervisor) | this session | active |
| D0 | Terminal FE (read-only) | `audit-datasets-schemas-auoc3` | reassigned |
| D1 | Consumer Retail (owns Render service `vibepass-storefront-test`) | `eloquent-chatterjee-aaedf0` | active |
| D2 | Order Clients | `review-unified-order-suite-FA0qA` | active |
| (sub D2) | Undelivered FE | same as D2 (or split when scope activates) | deferred |
| D3 | Broadway (sub of D2) | `broadway-scraper-eChQ6` | active |
| D4 | Our Ticketing Infra | unassigned | future |
| E1 | External Markets (Kalshi, prediction markets, exchanges) | unassigned | future — stub created 2026-05-15 |

## Per-lane restrictions

### A1 — Admin / Audit / Push

**Writes:**
- `app.py` (backend / FastAPI routes shared with D1, coordinate)
- `evo_client.py`, `requirements.txt`, `Procfile`
- `MIGRATION_CONVENTIONS.md`, `SCHEMA.md`, governance docs in `docs/`
- All foundation migrations (ESPN canonical, FRED, listings TTL+dedup+matcher, in-DB matcher)
- `event_xref`, `canonical_external_ids`, `espn_*` ingest tables
- Ledger reconciliation in `supabase_migrations.schema_migrations`
- Cron schedules in `audit-lane` namespace (ESPN, FRED, match_*)

**Reads:** everything.

**Authority:**
- Sole pusher to `main`
- Reviews all PRs against `MIGRATION_CONVENTIONS.md §9` checklist
- Approves merges

### B1 — Security Manager

**Writes (cross-cutting allowed):**
- `KANBAN.md` security backlog
- `docs/security-runbook-*.md`
- `docs/proposed-migrations/*_security_*.sql` (hand-apply gate set)
- `supabase/migrations/*_security_*.sql` (auto-apply set)
- `supabase/functions/_shared/cron-auth.ts`
- Per-lane patches for security CRIT/HIGH (must coordinate via PR comment to lane owner)

**Reads:** everything.

**Authority:**
- Middle-man review between C1 and A1 for security-sensitive PRs
- Resolves `event_type IN ('p0_security', 'flag')` in bot_chat
- Owns hand-apply gate for RLS migrations

### C1 — Drift Monitor + Daily Checkpoint Merger

**Refocused 2026-05-14** from "Data + Chat Supervisor" to drift monitoring + daily checkpoint cadence. Previous supervisor-lane responsibilities (xref governance, queue health migrations) shift to A1 (admin) or B1 (audit/security) depending on scope. The supervisor role function still exists — it's now performed primarily through drift detection rather than custodial writes.

**Primary mission:** keep prod state and repo state from diverging. Catch drift early; close it daily before it compounds.

**Daily checkpoint routine** (per `docs/c1_daily_checkpoint_runbook.md`):
1. Pull latest `main`; run `git fetch --all`
2. Run `SELECT * FROM public.migration_drift_check();` — joins prod-applied migrations against `supabase/migrations/*.sql` on disk
3. For any "applied to prod but no file" row → file follow-up issue to A1 + post `flag` to `bot_chat`
4. For any "file exists but not applied" row → either apply (with operator OK) or revert the file
5. List stale PRs: any PR open >24h gets a comment asking lane owner for ETA or stale-close
6. Run `SELECT * FROM public.release_health_check() WHERE status <> 'ok'` — surface any new fails/warns introduced since yesterday's baseline
7. Merge ready PRs to main per push-protocol (A1 retains final-merge authority on contentious cases)
8. Post a daily checkpoint summary to `bot_chat` (`event_type='checkpoint'`)

**Writes (in lane):**
- `docs/c1-checkpoint-*.md` — daily checkpoint reports
- `docs/c1_daily_checkpoint_runbook.md` — the runbook itself (canonical)
- `bot_chat` checkpoint + drift-flag entries
- `v_bot_chat_unresolved` view migration (resolve-protocol owner, see CLAUDE.md §1 / PR #114 Cluster D-1)
- PR merge commits (within push-protocol)
- Stale PR comments (cross-lane coordination, allowed for C1)

**Writes NOT in lane** (delegate or escalate):
- Migrations to fix drift → A1 (admin / push)
- Security findings → B1 (security manager)
- Bot-lane code changes → respective lane owner via PR comment

**Cross-cutting onboarding requirement (2026-05-15)**: every active bot must create a lane-scoped aging-sweep scheduled task on first activation. Spec in `CLAUDE.md §5`. Minute slot registry maintained there.

**Reads:** everything.

**Authority:**
- Merge PRs that pass discipline checks (matches push-protocol)
- Close stale PRs >7 days with no activity (after warning the lane owner)
- Flag drift to A1 for resolution
- Block merges that introduce health-check regressions (post `flag` to `bot_chat`, route to A1)

**Cadence:** daily checkpoint at 09:00 ET (after overnight backdata processing completes; before US trading-hours peak). One scheduled session per day; ad-hoc sessions if drift gets surfaced by automated alerting between checkpoints.

**Charter expansion 2026-05-15** (operator directive, bot_chat 139): C1 owns **token monitor + minimization** alongside drift monitoring. Scope: migration header audit (≤15 lines), bot_chat length audit (≤1500 chars), token-discipline rulebook (`docs/token-discipline-rules.md`), quarterly efficiency report. Runbook Step 9 added.

**Charter expansion 2026-05-17** (operator directive): C1 owns **Quality & Continuity** — 6 previously-unowned duties, all monitor+surface+route (no new mutate authority): (1) data-quality / semantic validation, (2) cost / burn-rate, (3) DR / backup posture, (4) operator-action queue ledger, (5) credential lifecycle, (6) end-to-end product validation. Full spec: `docs/c1_quality_continuity_charter.md`. Runbook Steps 10-12 added (daily); cost/cred/DR are weekly. C1 detects + routes; fix/execution stays with A1 (apply), operator (rotate/approve), or lane owners (code).

### D0 — Consolidated Frontend Lane (2026-05-15 reorg)

**Role**: lane owner for all customer + operator frontend surfaces. Reviews + signs off on subordinate (D1, D2) PRs before A1 merges. Owns Render write authority on all three frontend services. Authors `static/terminal/*` directly.

**Subordinates**: D1 (storefront implementer), D2 (dashboard implementer). They write code; D0 reviews; A1 merges after green CI.

### D0 — Terminal FE direct surface

**Writes:**
- Future `static/terminal/*` UI files (when built)
- `docs/event-view-wireframe-*.md`
- `docs/performer-view-wireframe-*.md`
- Other Terminal-FE UI spec docs

**NEVER writes:**
- Any database table
- Any cron schedule
- Any edge function that mutates data
- Any other lane's files

**Render workspace authority (2026-05-16 operator directive — "full Render permissions"):**
D0 has full workspace-wide Render permissions, parity with A1. All `mcp__render__*` tools available on every service + workspace-level operations (`create_*`, `select_workspace`, deletion, ownership changes). Standing write on `vibepass-terminal-test`, `vibepass-storefront-test`, `d2-orders-dashboard`, and any future services D0 provisions. Coordination expectation: bot_chat `flag` event when provisioning/deleting customer-facing services for transparency, but no per-call operator approval required.

**Reads:** entire data plane (charts, predictive models, possibly Grok integration)

### D1 — Consumer Retail (subordinate to D0 as of 2026-05-15)

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

### E1 — External Markets (lane stub, 2026-05-15)

**Status**: lane stub. No active bot session yet. Activates when operator assigns + Kalshi work begins (per bot_chat 221 / 223).

**Mission**: integrate external prediction markets and exchanges. First target: Kalshi (sports + macro event contracts). Future: Polymarket, sportsbooks, and — if direction (B) of bot_chat 221 activates — building Kalshi-styled ticket-price prediction markets ourselves.

**Writes (when active)**:
- `kalshi_client.py` (initial) + future `<exchange>_client.py` files
- Edge functions for market data ingest (`supabase/functions/kalshi-*`)
- Migration files matching `*_markets_*.sql` pattern (e.g. `<ts>_markets_kalshi_xref.sql`)
- `markets_*` tables (e.g. `kalshi_event_xref`, `kalshi_market_snapshots`)
- `docs/markets-*.md` design notes

**Reads**: entire data plane (especially `listings_snapshots`, `aq_event_map`, `v_market_listings_by_event`, `events`). Cross-event correlation with our owned inventory is the operating premise.

**NEVER writes**:
- Ticket-ingest pipelines (A1 / D2 territory)
- Frontend code (D-tier)
- Order tables (D2 territory)
- Other lanes' Render services

**Render**: no service provisioned yet. Will spawn `vibepass-markets-*` when MVP needs deploy target. A1 owns provisioning.

**Sign-off model**: A1 reviews + merges per push-protocol. No subordinate lane underneath E1 yet.

**Why E-tier (not extension of D-tier)**: D = ticket data + storefronts. E = external markets + financial integration. Different category and risk profile (esp. if direction B activates — CFTC regulatory considerations on prediction markets); keeps D-tier focused.

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
