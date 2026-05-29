# BOT_HIERARCHY.md

**The single source of truth for who-does-what, who-can-push-where, and per-lane write scope.**
**Owner: A1.** Reorg 2026-05-28 — new mandate split, D1–E1 paused until D0 is working.
**Absorbs former `LANE_DISCIPLINE.md`** (merged 2026-05-28; that file is now in `docs/archive/`).

> **Doc version:** v1.1.0 · baseline 2026-05-28 (A1). Section-level version + bot-ref convention → [`README.md`](README.md) *Doc-writing rules*.

> **This doc owns:** bot roster · push authority · Render service scope · per-bot lane scope (writes / never-writes / reads / authority) · cross-cutting lane rules.
> Migration mechanics → `MIGRATION_CONVENTIONS.md`. Immutable security invariants → `CLAUDE.md`. Per-session playbook → `PROJECT_BIBLE.md`.

---

## 1. Hierarchy at a glance

```
                     ┌──────────────────────────────────────────┐
                     │                  A1                        │  ops + infra
                     │  SQL Monitor / DB Ops / Git / Connectors   │
                     │  (sole prod pusher to main)                │
                     └──────────────────┬─────────────────────────┘
                                        │ security audits →
                                        ▼
                     ┌──────────────────────────────────────────┐
                     │                  B1                        │  security + governance
                     │  Security + Bibles / Git / Bot Notes       │
                     └──────────────────┬─────────────────────────┘
                                        │ D-tier coordination →
                                        ▼
                     ┌──────────────────────────────────────────┐
                     │                  C1                        │  project coordinator
                     │  D0–D4 Monitor + Code Drift Prevention     │
                     └──────────────────┬─────────────────────────┘
                                        │ primary product surface ↓
                                        ▼
                     ┌──────────────────────────────────────────┐
                     │             D0  ← PRIORITY                 │  user visual layer
                     │  Terminal FE — visual of A1 for the user   │
                     │  All data flows here. Build this first.    │
                     └────────────────────────────────────────────┘

     ┌──────────────────────────────────────────────────────────────┐
     │   D1 · D2 · D3 · D4 · E1  ─── PAUSED until D0 is working       │
     └──────────────────────────────────────────────────────────────┘
```

---

## 2. Lane roster

| Lane | Role | Mandate (2026-05-28) | Status |
|---|---|---|---|
| **A1** | SQL Monitor / DB Ops | Monitor + fix SQL; Supabase alerts; all data sources (TEvo/SG/TD/etc.); crons; tables; git + syncs; Jira/Asana + connector health. Sole prod pusher. | **ACTIVE** |
| **B1** | Security + Governance | Security (RLS, SECDEF, CRIT patches); monitor Jira/Asana, git, bibles (governance docs), other bot notes/changelogs. | **ACTIVE** |
| **C1** | D-tier Project Coordinator | Monitor + assist D0-D4 related projects and docs; prevent code drift; daily checkpoint cadence. | **ACTIVE** |
| **D0** | Terminal FE — User Visual Layer | Primary user interface for project progress. Visual representation of everything A1 monitors. All data flows through D0. Build this first — D1-E1 paused until D0 is working. Render workspace-wide perms parity with A1. | **ACTIVE — PRIORITY** |
| **D1** | Consumer Retail | Storefront (`static/store/*`, `/api/store/*`). Reports to D0. | **PAUSED** |
| **D2** | Order Clients | 5 order-client SDKs + dashboard. Reports to D0. | **PAUSED** |
| **D3** | Broadway Scraper (sub-D2) | `broadway_client.py`, `broadway_*` tables + crons. | **PAUSED** |
| **D4** | Our Ticketing Infra | Exos schema live (phases 1–5), zero data. BLOCKED: RESEND + Stripe creds. | **PAUSED** |
| **E1** | Integration / Automation | Zapier, WhatsApp/Telegram ops, Slack alerts, webhooks. (Rebrand from Kalshi placeholder.) | **PAUSED** |

---

## 3. Active-lane mandates + scope

Each active lane below lists its **mandate**, **writes**, **never-writes**, **reads**, and **authority**. Paused lanes (D1–E1) are in the [Appendix](#appendix--paused-lane-scope-preserved-for-reactivation).

### A1 — SQL Monitor / DB Ops / Git / Connectors
**Mission:** monitor the entire operational stack, detect issues, fix them fast, keep git + prod in sync.

- **Monitors (continuous — flags to `bot_chat` on alert):** Supabase cron `job_run_details` (failures/timeouts/consecutive errors); `v_sg_broker_429_health` (alert >15%); table sizes + growth (`listings_snapshots`, `seatgeek_listings_snapshots`, `ticketsdata_listings_snapshots`); data-source freshness (TEvo cadence, SG priority pipeline, TD batch timing); migration drift (`migration_drift_check()`); `bot_chat` unresolved (aging sweep); Jira/Asana stale items; git sync (`main` vs deployed, stale PRs).
- **Writes:** all foundation + ops migrations (sweep functions, xref, cron schedules, ingest tables); `app.py` backend/FastAPI routes (coordinate with D0/D1); `evo_client.py`, `requirements.txt`, `Procfile`; `MIGRATION_CONVENTIONS.md` + governance docs in `docs/`; `event_xref`, `canonical_external_ids`, `espn_*`, `event_movers_index`, sweep functions; ledger reconciliation in `supabase_migrations.schema_migrations`.
- **Reads:** everything.
- **Authority:** sole pusher to `main` (immutable, CLAUDE.md); reviews all PRs per `MIGRATION_CONVENTIONS.md §9`; applies migrations to prod via MCP; approves merges.

### B1 — Security + Governance Monitor
**Mission:** own security AND governance monitoring — keep code safe, docs accurate, bot coordination healthy.

- **Security:** RLS coverage audits, SECURITY DEFINER audit, anon-exposure harness; CRIT/HIGH patches (cross-cutting write authority for security fixes); reviews security-sensitive PRs; owns hand-apply gate for RLS migrations.
- **Governance:** monitor bibles (PROJECT_BIBLE, BOT_HIERARCHY) + governance docs for drift vs actual state, flag discrepancies to A1; monitor repo for secret leaks / insecure patterns; read + audit `bot_chat` aging items; track security + governance tickets.
- **Writes (cross-cutting allowed):** `KANBAN.md` security backlog; `docs/security-runbook-*.md`; `docs/proposed-migrations/*_security_*.sql` (hand-apply gate); `supabase/migrations/*_security_*.sql`; `supabase/functions/_shared/cron-auth.ts`; per-lane patches for security CRIT/HIGH (coordinate via PR comment to lane owner).
- **Reads:** everything.
- **Authority:** resolves `event_type IN ('p0_security','flag')` in `bot_chat`; middle-man review between C1 and A1 for security-sensitive PRs; flags governance-doc drift to A1.

### C1 — D-tier Project Coordinator + Code Drift Prevention
**Mission:** ensure D0-D4 projects move forward, docs stay accurate, and code/prod don't diverge. *Refocused 2026-05-28 — narrowed from a 6-function overload to 3 clear responsibilities.*

- **D-tier monitoring:** track open PRs for D0-D4 (flag stale >24h to A1); read `bot_chat` items addressed to D-tier bots and surface blockers; track D0 deliverable status (priority lane); coordinate D1-E1 project docs + PR routing when they reactivate.
- **Docs assistance:** keep D-tier design docs, wireframes, runbooks consistent with implementation; flag doc-reality drift; assist D-tier bots with cross-lane doc questions.
- **Code drift (daily checkpoint):** `git fetch --all` + compare `main` vs deployed → `migration_drift_check()` → `release_health_check() WHERE status <> 'ok'` → post checkpoint to `bot_chat` (`event_type='checkpoint'`) → route fixes (migrations→A1, security→B1, code→lane owner via PR comment).
- **Writes (in lane):** `docs/c1_daily_checkpoint_runbook.md` (durable runbook); `bot_chat` checkpoint + drift-flag entries (the canonical checkpoint home); PR stale-close comments. *(Dated checkpoint snapshots go to `bot_chat` or `docs/archive/YYYY-MM-DD-*` — never `docs/` root, which the docs gate blocks.)*
- **NOT in lane (delegate):** drift-fix migrations → A1; security findings → B1; bot-lane code → lane owner via PR comment; connector integrations → E1 (when active).
- **Removed from C1 scope (2026-05-28):** PR management / merge authority → D0; connector integrations → E1; health-check regression blocking → B1 + A1.
- **Reads:** everything. **Authority:** flag drift to A1; post stale-PR comments.

### D0 — Terminal FE — User Visual Layer (PRIORITY)
**Mission: be the user's single window into project health and trading intelligence.** D0 is the gating condition for D1-E1 reactivation.

D0 renders two kinds of surfaces:
1. **Ops health** — visual of everything A1 monitors: cron status (last fire / last success / consecutive failures), 429 rates by scope, table freshness, `bot_chat` feed, data-source pipeline status, sync state.
2. **Trading intelligence** — event detail pages, movers v2 index, discovery gaps, performer/venue pages with all multi-source data (EVO/SG/TD).

**"D0 is working" =** operator opens the terminal and immediately sees: all pipelines running, 429 rates in budget, which sources are fresh vs stale, recent `bot_chat` activity, and can navigate to any event/mover/discovery surface with live data (no stale/empty panels).

- **Writes:** `static/terminal/*.html`, `static/terminal/*.js`, `static/terminal/*.css`; `docs/event-view-wireframe-*.md`, `docs/d0-*.md`; `app.py` `/api/broker/*` routes (coordinate with A1).
- **Never writes:** any DB table directly; any cron schedule (author migration, A1 applies); any data-mutating edge function; D1-E1 lane files (paused).
- **Reads:** entire data plane.
- **Render authority (2026-05-16, confirmed 2026-05-28):** full workspace-wide parity with A1 — all `mcp__render__*` tools, `create_*`, `select_workspace`, provisioning/deletion/ownership. No per-call operator approval; post a `bot_chat` `flag` for transparency on customer-facing service changes.
- **Build reference:** the cold-start build manual for the terminal FE lives in `D0_BIBLE.md` (PART 1).

### D1–E1 — PAUSED
All paused until D0 is working. No new work, PRs, migrations, or deploys in these lanes. Existing deployed code stays running. Full scope preserved in the [Appendix](#appendix--paused-lane-scope-preserved-for-reactivation).

---

## 4. Push restrictions matrix

| | Prod DB (Supabase) | Prod git (`main`) | Render workspace | Edge functions | Vault / secrets |
|---|---|---|---|---|---|
| **A1** | ✅ via MCP | ✅ sole merger | ✅ workspace-wide | ✅ deploy | ✅ rotate/set |
| **B1** | ✅ CRIT security only | ✅ sec PRs only | ❌ | ✅ sec only | ✅ |
| **C1** | ❌ (author files only; A1 applies) | ❌ (A1 merges) | ❌ | ❌ | ❌ |
| **D0** | ❌ (author files only; A1 applies) | ❌ (A1 merges) | ✅ **workspace-wide parity with A1** | ❌ | ❌ |
| **D1–D4, E1** | ❌ (PAUSED) | ❌ (PAUSED) | ❌ (PAUSED) | ❌ | ❌ |

**Hard rules (immutable, per `CLAUDE.md`):**
- A1 is sole pusher to `main`.
- B1's prod-DB write is CRIT security only — no routine ops.
- D0 has full workspace-wide Render permissions (all `mcp__render__*`, `create_*`, `select_workspace`, provisioning/deletion/ownership). No per-call operator approval required; post a `bot_chat` flag for transparency on customer-facing service changes.

---

## 5. Single-writer table ownership

Each table has exactly one owning lane that writes; all others read. (Full mechanics: `MIGRATION_CONVENTIONS.md §4`.)

| Lane | Tables they write |
|---|---|
| **A1** | `event_xref`, `*_xref`, `event_listing_snapshot_daily`, sweep functions, `latest_event_metrics` matview, FRED macro, ESPN tables, `event_movers_index`, `event_movers_index_history`, `discovery_gap_alerts` |
| **B1** | `pg_policies` (via migrations), RLS configs |
| **C1** | `bot_chat`, `*_canonical`, `*_resolved` sidecars, `seatgeek_event_xref` |
| **D0** | `static/terminal/*` UI files (read-only from DB perspective) |
| **D1** | `share_links` (PAUSED) |
| **D2** | `evo_orders`, `seatgeek_orders`, `tickpick_orders`, `vivid_orders`, `seatdata_sales_snapshots` (PAUSED) |
| **D3** | `broadway_*` tables (PAUSED) |

---

## 6. Code-review + push workflow *(v1.1 · A1 · 2026-05-28)*

1. **Branch** off `main`: `claude/<lane>-<purpose>-<id>`
2. **Migration header** (required): `-- Migration <ts> · level:<X> · lane:<Y> · writes:<...> · reads:<...>`
3. **PR** — use `.github/PULL_REQUEST_TEMPLATE.md`
4. **Apply to preview branch** via MCP — never directly to main `project_id` without operator OK
5. **`bot_chat` log** — `change_log` event with PR# linked
6. **A1 review + push** — applies migration to prod via MCP, merges PR

**No exception.** D-tier lanes (D0–D4, E1) have **zero Supabase mutation authority — including emergency apply**. A DB change discovered by D0 is filed as a migration file + `bot_chat` to A1 → A1 applies → A1 pushes (matches the §4 push matrix: D0 Prod DB ❌, and `PROJECT_BIBLE.md §1` rule 1 + `CLAUDE.md §1` lockdown). Per operator clarification 2026-05-28; supersedes the prior per-session-authorization carve-out and the `bot_chat` #740/742/745 D0 apply pattern.

**Deploy gating (2026-05-15):** backend test workflow (`.github/workflows/tests.yml`) must pass on a PR before A1 merges to `main`. Auto-deploy fires only after green CI lands on `main`. No exceptions.

---

## 7. Deploy infrastructure ownership

| Render service | Service ID | Lane owner | Sub-implementer | Source code | IaC |
|---|---|---|---|---|---|
| `vibepass-terminal-test` | `srv-d839339kh4rs73ac3s20` | **D0** | D0 | `static/terminal/*` | `render-d0-terminal.yaml` |
| `vibepass-storefront-test` | `srv-d8140bnaqgkc73al4asg` | **D0** | D1 (PAUSED) | `app.py`, `static/store/*` | `render.yaml` |
| `d2-orders-dashboard` | `srv-d82b4kl7vvec73b4r3r0` | **D0** | D2 (PAUSED) | `d2_dashboard/*` | `render-d2-dashboard.yaml` |
| `hi-events` (separate repo) | `srv-d7g0cev7f7vs73blkc70` | n/a (not Terminal-2) | — | — | — |

**Testing-unified architecture (2026-05-16, PR #168):** during dev/test, all runtime traffic flows through `vibepass-storefront-test` (starter plan, no cold-start drag). It hosts D0 terminal + D1 storefront + D2 dashboard via `app.include_router` mounts in `app.py`. `vibepass-terminal-test` remains the D0 static CDN host; `d2-orders-dashboard` is an idle placeholder. At beta, each surface migrates back to its own service via dedicated DNS + un-mounting from `app.py`.

**Per-bot Render access scope:**
- **A1** — workspace-wide: all read + write, plus `create_*` / `select_workspace`, provisioning, deletion, ownership.
- **D0** — **workspace-wide parity with A1** (2026-05-16): all read + write on any service, plus `create_*`, deletion, ownership, future-service provisioning. No restrictions.
- **D1, D2** (PAUSED) — read-only on all Render surfaces; writes route through D0 review + A1 merge.
- **B1 / C1 / D3 / D4** — read-only across all services; writes require operator approval.

Both live services auto-deploy from `main`. **Railway** is the legacy deploy home (A1 governs migration off Railway → Render). **Supabase** is shared; per-table ownership via `MIGRATION_CONVENTIONS §4`; RLS maintained by B1.

---

## 8. Cross-cutting lane rules

1. **Shared files** — propose changes via PR comment to the owner before editing:
   - `app.py` (A1 owns; D0 has `/api/broker/*`; D1 has `/api/store/*` — PAUSED)
   - `requirements.txt` (A1 owns pinning shape; lanes add their own deps)
   - `MIGRATION_CONVENTIONS.md`, governance docs (A1 / shared)
   - `KANBAN.md` (B1 + A1 share)
2. **Single-writer per table** — see §5 + `MIGRATION_CONVENTIONS.md §4`.
3. **Security cross-cutting exception** — B1 may patch any file when fixing a security CRIT/HIGH, but must surface the patch via PR comment to the affected lane.
4. **Out-of-lane writes** — require PR comment to lane owner before push. If owner offline, surface as `flag` in `bot_chat` for B1 / A1 resolution. **Never silently write across lanes** — even read-only-looking writes (cache files, logs) count.
5. **SECURITY DEFINER convention** — every new SECURITY DEFINER function ships in one migration with:
   - `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`
   - explicit `GRANT EXECUTE ... TO service_role`
   - `IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN RAISE EXCEPTION` at body start

**Enforcement:** A1 catches violations during §9 review; B1 catches security-class violations; C1 catches lane-discipline violations in supervised work. All violations logged as `flag` in `bot_chat`; resolved by B1 (security) or A1 (governance).

---

## Appendix — PAUSED lane scope (preserved for reactivation)

> D1 · D2 · D3 · D4 · E1 are **PAUSED until D0 is working** (2026-05-28). No new PRs / migrations / deploys. Existing deployed code stays running. Scope below is retained verbatim for clean reactivation. Per-bot self-contracts (when present) live at `docs/<bot>_operating_constraints.md` and must stay consistent with this section.

### D1 — Consumer Retail (subordinate to D0)
**Reports to D0.** Authors storefront code; D0 reviews + approves PRs; A1 merges after green CI.
- **Writes:** `app.py` `/api/store/*` + `/store/*` routes (coordinate with A1); `static/store/*.{html,js,css}`; `share_links` migrations; `bot_messages` (if D1 owns chat).
- **Never writes:** broker terminal HTML (`static/terminal/*`, `static/index.html`); order client `.py` (D2: `seatdata_client.py`, `evo_client.py`, `seatgeek_client.py`, `tickpick_client.py`, `vivid_client.py`); Broadway scraper (D3); edge functions outside `chat`; listings / xref infrastructure migrations.
- **May invoke:** `evo_client.py` retail search/browse/availability functions (D2 owns file; D1 imports); `*_public` RPCs (`get_event_zones_public`, `get_event_listings_public`, `get_events_by_performer_public`, `submit_lead_public`, `get_cached_ticket_groups`); `retail_*` views; `chat` edge function.
- **Never invokes:** broker-private RPCs (`get_broker_*`, `broker_*_dashboard`, `audit_*`); direct TEvo paths returning wholesale fields.
- **Must filter from any client response:** `wholesale_price`/`wholesale_*`; `brokerage_id`/`brokerage_name`/`office_id`/`office_name`; `is_owned`/`is_ancillary` provenance flags (see carveout below); TEvo signing/API tokens, vault secrets; raw `broker_*` rows; any column not whitelisted by a `*_public` RPC.

  **Storefront-product carveout (`/api/store/*` only, codified 2026-05-18 from B1 war-games W-3 / bot_chat 308):** the storefront is a "100% we-own catalog" by design — every event surfaced is one S4K holds inventory for, no "browse market" fallthrough (see `store_events()` docstring in `app.py`). Under this model these fields are **intentionally exposed** on `/api/store/*` and power the retail availability UX: `we_own` (bool, drives `/api/store/search` prioritization), `owned_tix`/`owned_tickets_count` (int), `owned_groups_count` (int). These are retail-availability signals (like "5 tickets left"), not wholesale-side broker flags — the broader `is_owned`/`is_ancillary` rule still applies to terminal / portfolio / broker API responses. RULE 7 (retail product = S4K-owned only; see `RESOURCES_BIBLE.md` event taxonomy RULES) applies.
- **Reads:** events, listings_snapshots, event_metrics, performer/venue context, share_links.
- **Owns deploy infra:** `vibepass-storefront-test` (`srv-d8140bnaqgkc73al4asg`) — env vars, deploy config, log monitoring, `render.yaml` IaC. Render MCP write authority on this service only (no per-call ask): `update_environment_variables`, `update_web_service`, redeploy, restart. Does NOT own `d2-orders-dashboard`. *(Under the 2026-05-15 reorg, while paused, write authority routes through D0 + A1.)*

### D2 — Order Clients (subordinate to D0)
**Reports to D0.** Authors order-client + dashboard code; D0 reviews + approves PRs; A1 merges after green CI.
- **Writes:** `seatdata_client.py`, `seatgeek_client.py`, `evo_client.py` (order paths only); `tickpick_client.py`, `vivid_client.py`, `gotickets_client.py`; `d2_dashboard/` (standalone FastAPI rendering broker order surfaces, PR #85); `tests/test_readonly_guards.py`, `tests/test_d2_dashboard.py`, `scripts/check_readonly.py`; order tables (`evo_orders`, `evo_order_items`, `evo_orders_pending`, `evo_event_backfill_pending`, `seatgeek_orders`, `seatgeek_order_tickets`, `sg_seller_pending`, `seatdata_sales_snapshots`, `seatdata_pull_budget`, `seatdata_pull_log`); order crons (evo_orders_*, sg_seller_orders_*, seatdata sales); `requirements.txt` (D2-specific deps).
- **Never writes:** listings infrastructure (`sg_listings_*`, `seatgeek_listings_snapshots`, `seatdata_listings_snapshots`, `seatgeek_seller_listings` — A1/canonical); storefront files; broker terminal files; Broadway code; `RESOURCES_BIBLE.md` (propose via PR comment to A1); D1's Render service.
- **Reads:** events, performer/venue context for joins, A1's listings tables for cross-validation.
- **Owns deploy infra:** `d2-orders-dashboard` (`srv-d82b4kl7vvec73b4r3r0`) — env vars, deploy config, log monitoring, `render-d2-dashboard.yaml`. Render MCP write authority on this service only (no per-call ask). Does NOT own `vibepass-storefront-test`.
- **Undelivered FE (sub of D2):** future `static/undelivered/*` UI when scope activates; same scope as D2 order data **excluding** seatdata. Reads D2 order tables (evo + sg + tickpick + vivid), NOT seatdata.

### D3 — Broadway (sub of D2)
- **Writes:** `broadway_client.py`; `tests/test_broadway_client.py`, `tests/fixtures/checkout_sections_*.html`; future `supabase/functions/broadway_collect/index.ts`; future `broadway_*` tables (`broadway_shows`, `broadway_performances`, `broadway_sections_snapshots`, `broadway_pull_log`, `broadway_event_xref`); `broadway_collect_daily` cron; optional vault secret `BROADWAY_USER_AGENT`.
- **Never writes:** order clients; storefront; other ingest clients; edge functions outside `broadway_collect/`; D1's Render service.
- **Reads:** `canonical_external_ids` for xref propagation (writes into own `broadway_event_xref`; propagation handled by drift triggers in A1/canonical lane).

### D4 — Our Ticketing Infra (The Bridge / Exos)
Greenfield primary-ticketing (Exos schema live phases 1–5, zero data; BLOCKED on RESEND + Stripe creds). D4-owned `exos_*` tables in prod project; A1 applies migrations; B1 reviews RLS.
- **Writes:** AR codes, custom ticketing infra in its own `exos_*` / future namespace (TBD as scope activates).
- **Never writes:** anything outside its own namespace; D1's Render service (D4 gets its own deploy target when scoped — Render workspace / Cloudflare Workers / custom, deferred).

### E1 — Integration / Automation (rebrand 2026-05-28)
Repurposed from "Kalshi/prediction-markets placeholder" to **Integration / Automation**. Reactivates after D0 is working.
- **First deliverables when active:** Zapier→Slack (429 + cron-failure alerts); Zapier→Gmail (D4 transactional email relay); Zapier→Sheets (order tracking); WhatsApp/Telegram ops bot; future Kalshi integration (same external-API integration pattern).
- **Writes (when active):** `docs/e1-*.md`; webhook-routing edge functions (`supabase/functions/webhook-*`); migrations matching `*_integrations_*.sql`; `integrations_*` tables.
- **Never writes:** ticket-ingest pipelines (A1); frontend code (D-tier); order tables (D2).

---

## 9. Quick links

- `PROJECT_BIBLE.md` — canonical per-session playbook (read first)
- `D0_BIBLE.md` — D0 cross-source ID architecture + cold-start terminal build manual
- `RESOURCES_BIBLE.md` — table/view/function inventory + event taxonomy & RULES
- `MIGRATION_CONVENTIONS.md` — migration + commit rules
- `CLAUDE.md` — immutable security + lockdown rules

Owner: A1. Update when a lane assignment changes or a new bot is rostered.
Last updated: 2026-05-28 reorg + LANE_DISCIPLINE merge (operator directive).
