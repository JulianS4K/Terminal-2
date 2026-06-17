# BOT_HIERARCHY.md

**Lane guidance — who owns which domain, who can push where, and per-lane write scope.**
**Owner: A1.** Reorg 2026-06-17 (operator directive) — four peer domains by ownership; **not a command chain.** No bot "reports to" another; the lanes are guidance for who writes what, coordinated through `bot_chat`.
**Absorbs former `LANE_DISCIPLINE.md`** (merged 2026-05-28; that file is now in `docs/archive/`).

> **Doc version:** v2.0.0 · baseline 2026-05-28 (A1); v2.0.0 2026-06-17 (operator) — **reframed from a top-down hierarchy to peer-domain lane guidance**: four domains (A1 data plane · B1 git/code · C1 docs/coordination · D0–D4 FE surfaces); push to `main` is per-task (A1 + B1 maintain), not bot-tier-gated; DB security → A1, git security → B1; own-bible model (promote globally-relevant facts to the main set, C1 arbitrates); v2.1.0 2026-06-17 (operator) — **§5.5 full-tree code lane-assignment audit** + **§5.5b shared cross-lane resource register** (venue/seat map, API surface, trip_planner, order data, `*_public` boundary, design tokens, RULE-2, AQ hub); C1 mandate gains shared-resource coordination. Section-level version + bot-ref convention → [`README.md`](README.md) *Doc-writing rules*.

> **This doc owns:** lane domains · push authority · Render service scope · per-bot lane scope (writes / never-writes / reads) · cross-cutting lane rules.
> Migration mechanics → `MIGRATION_CONVENTIONS.md`. Immutable security invariants → `CLAUDE.md`. Per-session playbook → `PROJECT_BIBLE.md`.

---

## 1. Lanes at a glance *(v2.0 · operator · 2026-06-17)*

**Four peer domains** — coordination is lateral (via `bot_chat`), not a chain of command.

```
  ── CROSS-CUTTING (no surface; serve every lane) ─────────────────────────┐
  ┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐   │
  │        A1          │  │        B1          │  │        C1          │   │
  │   DATA PLANE       │  │    GIT + CODE      │  │ DOCS + COORD       │   │
  │ DB · pipeline ·    │  │ history · git-sec ·│  │ bot_chat · main    │   │
  │ crons · DB-security│  │ drift · compart.   │  │ bible · promotions │   │
  └────────────────────┘  └────────────────────┘  └────────────────────┘   │
        A1 + B1 maintain `main` (push per-task, not by tier)                │
  ─────────────────────────────────────────────────────────────────────────┘

  ── FRONTEND SURFACES (distinct per surface; own Render + UX/speed testing) ┐
  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
  │   D0 ★   │  │    D1    │  │    D2    │  │    D3    │  │      D4       │  │
  │ Terminal │  │Storefront│  │ Orders   │  │ Broadway │  │ Exos/Bridge — │  │
  │   FE     │  │   FE     │  │dashboard │  │   FE     │  │ full app      │  │
  └──────────┘  └──────────┘  └──────────┘  └──────────┘  └───────────────┘  │
   ★ PRIORITY        D1 · D2 · D3 · D4 PAUSED until D0 ships                 │
  ──────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Lane roster

**Reorg 2026-06-17 (operator directive) — four clean domains by ownership.** The prior 9-lane split mixed verb (lifecycle) and noun (surface) axes; this collapses to four domains: **A1 = data plane, B1 = git/code, C1 = docs/coordination, D0–D4 = distinct frontend surfaces.** Each bot maintains **its own bible**; only globally-relevant facts get promoted to the main set (C1 arbitrates). Push to `main` is **per-task/per-agent, not bot-tier-gated** — A1 + B1 both maintain `main`.

| Lane | Role (domain) | Mandate (2026-06-17 reorg) | Status |
|---|---|---|---|
| **A1** | Data plane (DB + full pipeline + DB security) | Supabase tables/migrations/crons; the **AQ mapper** + cross-source xref; the 9 read-only source clients + edge functions + **order ingestion** + `app.py` data routes; **DB-layer security** (RLS, SECURITY DEFINER, the RULE-2 read-only lockdown); data-source freshness + 429/cron monitoring + alerting. Maintains `main` (per-task). | **ACTIVE** |
| **B1** | Git + code | Git history + **git/code security** (secret leaks, insecure patterns), drift prevention, code freshness, module compartmentalization, test-suite health. Maintains `main` (per-task). | **ACTIVE** |
| **C1** | Docs + coordination | `bot_chat`; the **main bible set** + closed registry + structure; **arbiter of what gets promoted** from a bot's own bible to the main set. | **ACTIVE** |
| **D0** | Terminal FE (surface) | Broker terminal (`static/terminal/*` + `/api/broker/*`); UX + speed testing; owns its Render service. Priority lane; Render workspace-wide parity with A1. | **ACTIVE — PRIORITY** |
| **D1** | Storefront FE (surface) | Consumer storefront (`static/store/*`, `/api/store/*`); UX + speed testing; owns `vibepass-storefront-test`. | **PAUSED** |
| **D2** | Orders dashboard FE (surface) | `d2_dashboard/*`; UX + speed testing; owns `d2-orders-dashboard`. | **PAUSED** |
| **D3** | Broadway FE (surface, sub-D2) | Broadway surface + `broadway_*`. | **PAUSED** |
| **D4** | Exos/Bridge — **full app** (not just UX) | Primary-ticketing app: Stripe checkout + transactional mail + `exos_*` schema; own deploy target. | **PAUSED** |

> **E1 (Integration/Automation) folded (2026-06-17):** cron/429/Slack alerting + the mandatory hourly aging-sweeps (`CLAUDE.md §5`) → **A1** (it already monitors); per-surface webhooks (`stripe-webhook` → D4, `sg-seller-webhook` → A1). No standalone E1 lane. Reintroduce only if a cross-cutting automation surface (Zapier/Telegram) is greenlit.
>
> **Own-bible model:** each active bot keeps a `<BOT>_BIBLE.md` (e.g. `D0_BIBLE.md` already exists) for lane-local facts/procedures; a fact only enters the **main** set when it's relevant to all bots, via a C1-reviewed promotion. *(Registry/CI mechanics for per-bot bibles are a tracked follow-up — see `KANBAN.md` C1-OPS-2.)*

---

## 3. Active-lane mandates + scope

Each active lane below lists its **mandate**, **writes**, **never-writes**, **reads**, and **authority**. Paused lanes (D1–E1) are in the [Appendix](#appendix--paused-lane-scope-preserved-for-reactivation).

### A1 — Data plane (DB + full pipeline + DB security) *(v2.0 · operator · 2026-06-17)*
**Mission:** own everything from upstream API → table → cron, and keep the DB safe and fresh.

- **Owns (the data plane):** Supabase tables/migrations/crons; the **AQ mapper** (`aq_event_map`) + cross-source xref; the **full ingest pipeline** — the 9 read-only `*_client.py`, the edge functions, **order ingestion**, and `app.py` `/api/*` data routes; **DB-layer security** — RLS coverage, SECURITY DEFINER audits, and the RULE-2 read-only upstream lockdown (`check_readonly.py` / `test_readonly_guards.py`).
- **Monitors (continuous — flags to `bot_chat`/Slack on alert):** cron `job_run_details` (failures/timeouts); `v_sg_broker_429_health` (>15%); table growth; data-source freshness (TEvo/SG/TD cadence); migration drift (`migration_drift_check()`); plus the folded **E1 alerting** (429/cron Slack alerts + the mandatory aging-sweeps).
- **Writes:** all migrations (incl. RLS/SECDEF + `*_security_*.sql`); ingest tables + order tables; `supabase/functions/*`; the 9 `*_client.py`; `app.py` data routes; `requirements.txt`, `Procfile`; `MIGRATION_CONVENTIONS.md` + governance docs A1 owns.
- **Reads:** everything.
- **Authority:** maintains `main` jointly with B1 (push is per-task, not by tier); applies migrations to prod via MCP; reviews data-plane PRs.

### B1 — Git + code *(v2.0 · operator · 2026-06-17)*
**Mission:** keep the repo's code and git history healthy, safe, and well-compartmentalized.

- **Owns:** git history hygiene; **git/code security** (secret-leak scans, insecure-pattern review — *not* DB-layer RLS/SECDEF, which is now A1's); drift prevention (`main` vs deployed); code freshness; module compartmentalization / lane-boundary enforcement; test-suite health (`tests/`, the CI gates).
- **Writes:** `KANBAN.md` security backlog; `docs/security-runbook-*.md`; `supabase/functions/_shared/cron-auth.ts`; CI workflow + `bin/`/`scripts/` guard code; cross-cutting patches for code-security CRIT/HIGH (coordinate via PR comment to the file's owner).
- **Reads:** everything.
- **Authority:** maintains `main` jointly with A1 (push is per-task, not by tier); resolves `event_type IN ('p0_security','flag')` in `bot_chat`; reviews security-sensitive PRs. *(DB-layer security findings route to A1, who owns RLS/SECDEF/RULE-2.)*

### C1 — Docs + coordination *(v2.0 · operator · 2026-06-17)*
**Mission:** keep the docs accurate and coordination healthy; arbitrate what's shared vs lane-local.

- **Owns:** `bot_chat`; the **main bible set** + the closed registry + doc structure; the **promotion gate** — deciding which facts graduate from a bot's own `<BOT>_BIBLE.md` into the main set (each bot owns its own bible; only globally-relevant facts get promoted).
- **Shared cross-lane resources (operator directive 2026-06-17):** C1 also owns the **register of resources that span lanes** — the venue/seat map (D0 + store), the shared API surface (`/api/broker/*` + `/api/store/*` in one `app.py`), the `trip_planner` module (D0 + D1 routes), order data (D0 tiles + D2 dashboard, via `unified_orders`), `static/_shared/`, the `*_public` RPC boundary, and the AQ mapper hub. C1 keeps these in §5.5 and **reviews any change touching a shared resource for cross-consumer impact** (a D0 venue-map change must not break store; an order-view schema change must serve both D0 and D2). Catalog **future crosses** here as they appear.
- **Drift watch:** compare `main` vs deployed + bibles vs reality (`migration_drift_check()`, `release_health_check()`); post checkpoints to `bot_chat`; route fixes (data→A1, code/security→B1, surface→the owning D-bot).
- **Writes (in lane):** the main bible set + registry; `bot_chat` checkpoints/drift flags; `docs/c1_daily_checkpoint_runbook.md`. *(Dated snapshots → `bot_chat` or `docs/archive/` — never `docs/` root.)*
- **Reads:** everything. **Authority:** owns the doc registry + promotion decisions; flags drift to the owning lane.

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

## 4. Push authority matrix *(v2.0 · operator · 2026-06-17)*

**Push to `main` is per-task/per-agent, not bot-tier-gated** — the bot the task is delegated to pushes its own work; A1 + B1 are the joint maintainers of `main`. (Supersedes the prior "A1 sole pusher" immutable rule, operator directive 2026-06-17.)

| | Prod DB (Supabase) | Prod git (`main`) | Render workspace | Edge functions | Vault / secrets |
|---|---|---|---|---|---|
| **A1** | ✅ via MCP | ✅ maintainer (per-task) | ✅ workspace-wide | ✅ deploy | ✅ rotate/set |
| **B1** | ✅ DB-security migrations | ✅ maintainer (per-task) | ❌ | ✅ sec only | ✅ |
| **C1** | ❌ (author files only) | ✅ docs (per-task) | ❌ | ❌ | ❌ |
| **D0** | ❌ (author files only; A1 applies) | ✅ own surface (per-task) | ✅ **workspace-wide parity with A1** | ❌ | ❌ |
| **D1–D4** | ❌ (PAUSED) | ✅ own surface when active (per-task) | own service when active | ❌ | ❌ |

**Hard rules (per `CLAUDE.md`):**
- **Push is per-task.** A1 + B1 maintain `main`; each task is pushed by its delegated owner after green CI. No single sole-pusher.
- **D-tier has zero Supabase mutation authority** — a DB change is filed as a migration file + `bot_chat` to A1; **A1 applies** (the read-only-by-default lockdown, `CLAUDE.md §1`, is unchanged).
- **DB security is A1; git/code security is B1.**
- D0 has full workspace-wide Render permissions; post a `bot_chat` flag for transparency on customer-facing service changes.

---

## 5. Single-writer table ownership

Each table has exactly one owning lane that writes; all others read. (Full mechanics: `MIGRATION_CONVENTIONS.md §4`.)

| Lane | Tables they write |
|---|---|
| **A1** | `event_xref`, `*_xref`, `event_listing_snapshot_daily`, sweep functions, `latest_event_metrics` matview, FRED macro, ESPN tables, `event_movers_index(_history)`, `discovery_gap_alerts`, **order/ingest tables**, **`pg_policies` / RLS configs** (DB security moved from B1, 2026-06-17) |
| **B1** | *(no prod tables)* — git history, CI/guard code, `cron-auth.ts`, test suite |
| **C1** | `bot_chat`, the main bible set + registry, `*_canonical`, `*_resolved` sidecars, `seatgeek_event_xref` |
| **D0** | `static/terminal/*` UI files (read-only from DB perspective) |
| **D1** | `share_links` (PAUSED) |
| **D2** | `evo_orders`, `seatgeek_orders`, `tickpick_orders`, `vivid_orders`, `seatdata_sales_snapshots` (PAUSED) |
| **D3** | `broadway_*` tables (PAUSED) |

---

## 5.5 Code lane-assignment map (full-tree audit) *(v1.0 · operator · 2026-06-17)*

Every code path assigned to an owning lane under the 4-domain model. Audit of the whole tree (2026-06-17). **Single-writer holds:** one lane writes; others read/consume. Cross-lane seams are in §5.5b.

| Path / component | Owner | Notes |
|---|---|---|
| `supabase/migrations/*` (596) | **A1** | all schema/data/cron/RLS migrations |
| `supabase/functions/*` (ingest + drains: `collect*`, `espn*`, `seatdata-poll`, `wiki-collect`, `nws*`, `seatmap-manifest-sync`, `*-search-bridge`, `sg-seller-webhook`, …) | **A1** | data pipeline |
| `supabase/functions/exos-*` (api, checkout, connect-onboard, distribute, mail-drain, webhook-drain), `stripe-webhook` | **D4** | Exos app edge fns |
| `evo/seatgeek/seatdata/ticketsdata/axs/tickpick/vivid/gotickets_client.py` (8 read-only clients) | **A1** | ingest; GET-only by construction |
| `broadway_client.py`, `broadway_extension/`, `broadway_*` tables | **D3** | Broadway scraper |
| `app.py` | **A1** (file) | shared — D0 owns `/api/broker/*`, D1 owns `/api/store/*` (§5.5b) |
| order tables (`evo_orders`, `seatgeek_orders`, `tickpick_orders`, `vivid_orders`, `sd_sales_normalized`) + ingestion | **A1** | consumed by D0 + D2 (§5.5b) |
| AQ mapper (`aq_event_map`, matchers) + `*_xref` + metrics matviews | **A1** | cross-source hub (§5.5b) |
| RLS / SECURITY DEFINER / RULE-2 policy | **A1** | DB/API security (moved from B1) |
| `bin/` (sync-check, check-docs, graph-drift), `.github/workflows/*`, `.gitleaks*` | **B1** | CI + git guards |
| `scripts/check_readonly.py`, `tests/test_readonly_guards.py` | **B1** (code) | enforce **A1**'s RULE-2 policy (§5.5b) |
| `tests/*` (pytest suite) | **B1** | test-suite health |
| canonical `*.md` registry (main bible set), `.understand-anything/` | **C1** | docs + knowledge graph |
| `bot_chat` + the §5.5b shared-resource register | **C1** | coordination |
| `static/terminal/*`, `/api/broker/*`, `render-d0-terminal.yaml` | **D0** | terminal FE + own Render |
| `static/store/*`, `/api/store/*`, `render.yaml` | **D1** | storefront FE + own Render |
| `d2_dashboard/*`, `render-d2-dashboard.yaml` | **D2** | orders dashboard + own Render |
| `d4_bridge/*`, `static/bridge/`, `exos_*` schema | **D4** | Exos/Bridge full app |
| `static/home/`, `static/undelivered/` | **D0** | hub / D2 placeholder surface |
| `requirements.txt`, `Procfile` | **A1** (shape) | lanes add their own deps |
| `design/`, `docs/archive/` | — | historical / non-canonical |

### 5.5b Shared cross-lane resources — C1-coordinated register *(v1.0 · operator · 2026-06-17)*

The seams where one lane's change can break another's surface. **C1 reviews any change touching these for cross-consumer impact.** (The default rule still holds — one writer, many readers — but here the readers are *other lanes*, so coordination is mandatory, not optional.)

| Shared resource | Writer / owner | Consumers (cross-lane) | Coordination rule |
|---|---|---|---|
| **Venue / seat map** — `static/terminal/lib/tevomaps.bundle.js` + `venue.js`/`event.js`; data `cross_source_venue_map`/`aq_venue_map`/`venue_assets` | D0 (component) · A1 (data) | **D0** terminal + **D1** `store.js` | a D0 map change must keep store rendering; tail-remap landmine (`PROJECT_BIBLE §3`) applies to both |
| **API surface** — single `app.py` | A1 (file) | **D0** `/api/broker/*` · **D1** `/api/store/*` · A1 `/api/public/*` | route blocks are lane-owned; shared helpers + `/api/public/config` change → PR comment to both FE lanes |
| **`trip_planner/`** module | shared (D0+D1) | `/api/broker/.../trip-plan` (**D0**) + `/api/store/.../trip-plan` (**D1**) | one engine, two routes; change once, regression-test both (`KANBAN` D0-PROD-8) |
| **Order data** — `unified_orders`/`cross_source_orders` views over the order tables | A1 (ingest + view) | **D0** `orders.js` event tiles + **D2** dashboard (`unified_orders` ×36) | a view/schema change must serve both consumers; D-tier keys on `tevo_event_id` (unmapped = invisible, `§3`) |
| **`*_public` RPCs** — the wholesale-filtered read boundary | A1 | **D1** store (only path) | D1 may never read `broker_*`/wholesale fields; the `*_public` whitelist is the contract |
| **`static/_shared/design-tokens.css`** | shared (FE) | **D0 · D1 · D2 · D4** surfaces | a token change ripples to every surface — coordinate via C1 |
| **RULE-2 read-only lockdown** — `check_readonly.py` / `test_readonly_guards.py` | B1 (guard code) · A1 (policy) | every `*_client.py` (A1) + CI (B1) | weakening = security-CRIT; B1 maintains the scanner, A1 owns what counts as a write |
| **AQ mapper** — `aq_event_map` hub | A1 | **every lane** that resolves cross-source IDs | the #1 architectural fact (`PROJECT_BIBLE §0`); never join raw source IDs |

**Future crosses:** as a new shared resource appears (a surface consuming another lane's data/component), add a row here and flag it in `bot_chat` so the owner + consumers agree the contract before it hardens. This register is the single place to answer "who else breaks if I change this?"

---

## 6. Code-review + push workflow *(v1.1 · A1 · 2026-05-28)*

1. **Branch** off `main`: `claude/<lane>-<purpose>-<id>`
2. **Migration header** (required): `-- Migration <ts> · level:<X> · lane:<Y> · writes:<...> · reads:<...>`
3. **PR** — use `.github/PULL_REQUEST_TEMPLATE.md`
4. **Apply to preview branch** via MCP — never directly to main `project_id` without operator OK
5. **`bot_chat` log** — `change_log` event with PR# linked
6. **Review + push (per-task)** — the delegated owner pushes its own work after green CI; A1 applies any migration to prod via MCP. Reviewer is the relevant maintainer (A1 for data-plane, B1 for code/security).

**No exception on DB mutation.** D-tier lanes (D0–D4) have **zero Supabase mutation authority — including emergency apply**. A DB change discovered by a D-bot is filed as a migration file + `bot_chat` to A1 → A1 applies (matches the §4 matrix: D-tier Prod DB ❌, and `PROJECT_BIBLE.md §1` rule 1 + `CLAUDE.md §1` lockdown). Git push to `main`, by contrast, is per-task (the bot pushes its own merged code after CI) — only *prod-DB apply* is centralized on A1.

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
