# PROJECT_BIBLE.md — operating playbook for all bots

> **Doc version:** v2.18.0 (2026-07-04; §2 consistency — dropped the stale `C1` from the §2 ownership-label list (line now `A1/B1/D0–D4`, matching the hierarchy-dissolved statement; C1/D2 are retired historical tokens). Companion sweep in peripheral docs retired the last A1-centralization / four-domain / "supervisor" language (README, release-discipline, open_notebook, bot_chat_conventions, b1_operating_constraints, KANBAN routing note).) · v2.17.0 (2026-07-03; §1.5/§2.1 — retired "today only A1 sessions" gatekeeper language: the **Applier** action (prod-DB apply, Render writes, cron/Vault, edge-fn deploys) is taken **per-task by any session under operator direction**, not centralized on A1. The A1/B1/D0 codes are naming conventions for surface ownership, not a chain of command — hierarchy stays dissolved.) · v2.16.0 (2026-07-02; §2.5 code map: added the `bandsintown` router (#693) + shifted the shared-client counts (9 GET-only · 7/9 http_retry · 5 vault) for the new Bands in Town client) · v2.15.0 (2026-07-02; accuracy sweep — reconciled storefront-service ownership (§2.3/§2.5 ⇄ §2.7 deploy table), added `d0_sales` router + `core/concurrency`·`core/seo` to the §2.5 code map, corrected the server.py inline-routes claim, marked `auto_match_sg_canonical_v3` + `sg_listings_poll_owned_1min` inactive, repointed the `_compute_movers` exemplar to `routers/broker.py`/`core/movers`) · v2.14.0 (2026-07-02; §3 landmines refreshed from the 2026-07-01/02 cron incident — pg_cron in-string `SET` DOES arm per-statement but LEAKS across jobs via persistent pooled connections (own-prefix or `BEGIN/SET LOCAL/COMMIT`), migs 20260702075500/20260701224500; + per-row trigger index-probes stall firehose ingest, mig 20260702000500) · v2.13.0 (2026-07-02) — **tier-2 lane consolidation (KANBAN C1-OPS-3):** retired two vestigial first-class lanes — **C1 folded into B1** (docs governance *is* the Auditor principal's work, so its surface — bibles, registry, `bot_chat`, seam register — belongs with the Auditor's home lane; B1 = build + guards + governance) and **D2 folded into D0** (both broker-facing; D2 wrote no tables). C1's former DB sidecars (`*_canonical`/`*_resolved`/`seatgeek_event_xref`) moved to A1, reconciling the cross-source-xref contradiction. Net: **6 lanes** — substrate A1·B1 + products D0·D1·D3·D4. `c1`/`d2` survive only as historical branch/KANBAN/`bot_chat`-tier tokens (the `p_level` DB constraint is untouched). · v2.12.0 (2026-07-02) — **§2 restructured to finish the ownership/permission/priority convergence:** permission collapsed to **3 principals** (Applier/Auditor/Builder, §2.1) with a dated **exceptions ledger** (§2.2) and an **ownership-label legend** (§2.3); priority/status (ACTIVE/PAUSED/★) evicted to `KANBAN.md`; §2.4 order tables reconciled to A1 (single-writer); §2.6 seam review mechanized as the non-blocking `seam-review` CI job; §6 MCP scope stated by principal; hard rules §1.4/§1.5 aligned. **The actor hierarchy is dissolved** — A1/B1/C1/D0–D4 are now flat *lane identifiers* (regions of the ownership map), with no ranks or chain of command (`A1→B1→C1` / "under" / "sub of" removed; `docs/bot-hierarchy.mermaid` reframed to a flat map). §2.3 recut from a flat 8-peer list into a **platform substrate (A1/B1/C1) × products (D0–D4)** grid with the `(product block) × (substrate layer)` ownership rule — the `server.py` route-block carve-out is now the stated rule, not an exception. §2.2 exceptions ledger made **CI-enforced** — `.github/permission-exceptions.yml` + the blocking `permission-exceptions` job (`scripts/check_permission_exceptions.py`): an expired/malformed entry fails the build, so a grant can't silently become permanent. Ownership paths (§2.5 code map + §2.6 seam register) unchanged. Full prior doc-version history → [`docs/archive/2026-07-02-doc-version-history.md`](docs/archive/2026-07-02-doc-version-history.md).

**Read FIRST every session — but this doc is large; do NOT linear-read it.** Priority read = **§0** (the AQ hub — the #1 fact most sessions miss) + **§1** (hard rules). Then determine your lane (§2) and **jump to the one section your task needs**:

| Your task / need | Go to |
|---|---|
| Hard rules · what I can't do | **§1** (+ `CLAUDE.md` = security/lockdown invariants) |
| **Which lane am I?** | **§2** — lane is *derived from what you touch + what it affects*, not pre-assigned |
| Cross-source IDs · joins · mapping | **§0 → §5** (full architecture) |
| Authoring / querying SQL | **§3** column landmines → **§4** canonical RPCs |
| MCP tool scope · SQL macros | **§6 · §7** |
| Ship a migration / cron / PR | **§8** + `MIGRATION_CONVENTIONS.md` |
| **What already exists** (before creating a table/view/RPC/cron/edge-fn — reuse, don't rebuild) | `RESOURCES_BIBLE.md` (212 tables · 178 views · 164 crons · 29 edge fns) |
| What's open right now (all lanes, severity-sorted) | `KANBAN.md §🟢 OPEN WORK` |
| Build the terminal frontend (file map, contracts, deploy) | `docs/d0_terminal_build.md` (on-demand) |
| Where each lane is headed (north-star) | `docs/d_tier_goals.md` |

Full section list → the Table of contents below (Ctrl-F `## N.` to jump).

---

## Table of contents

Sections are numbered so you can Ctrl-F `## N.` to jump. **Read §0 first — it's the one architectural fact most sessions miss.**

| § | Section | What it gives you |
|---|---|---|
| **0** | **The AQ mapper is THE hub** | the #1 cross-source fact — read before any cross-source SQL |
| 1 | Hard rules | the lines you can't cross (mirrors `CLAUDE.md`) |
| 2 | Lane assignment — who owns what | ownership (substrate × product grid) vs permission (3 principals), kept separate; exceptions ledger; shared seams |
| 3 | Column-name landmines | exact wrong→right names — check BEFORE authoring SQL |
| 4 | Canonical SECDEF RPCs | the hot RPC subset + args + when to call |
| 5 | Cross-source bridge — full architecture | namespaces · hub · TD/performer/venue chains · orders/sales · don't-rebuild |
| 6 | MCP tool scope | scope by principal (§2.1); 6a color-commentary layer; 6b terminal-link rule |
| 7 | SQL macros | copy-paste patterns (bot_chat, dedupe, gates, pg_net, TEvo search) |
| 8 | Workflow recipes | step-by-steps (author a migration, wire a panel, spawn a cron…) |
| 9 | Recent landmark migrations | → `MIGRATION_CONVENTIONS.md §14` (don't re-ship work) |
| 10 | Drift watchlist | → `KANBAN.md` (known gaps — don't rediscover) |
| 11 | Self-check | 11-item pre-task checklist |

---

## 0. AQ mapper is THE hub — read before any cross-source SQL

**#1 fact most sessions miss.** Source IDs are source-internal, NEVER align: TEvo `event_id` (3.0–3.4M), SG `sg_event_id` (17M+), TD `event_id` (per-platform), ESPN `espn_event_id` (text), TickPick/Vivid/SeatData. Cross-source join on a raw id = **0 rows**, silently misleads audits.

`aq_event_map` (~7,271 rows) is the hub: carries every source id (tevo/sg/sh/vivid/tm + `venue_short_id` + `performer_short_id`), resolves to canonical **`tevo_event_id`/`tevo_performer_id`/`tevo_venue_id`** (bigint). Join key INTO it = **`aq_short_event_id`** (7-char), NOT a source id.

Hub-and-spoke. Siblings (NOT in hub): ESPN → `event_xref` (`tevo_event_id↔espn_event_id`+`espn_league`; hub has no espn id); venue → `aq_venue_map` (via `venue_short_id`); performer → `aq_performer_map`/`entity_performer_map` (via `performer_short_id`). `ticketsdata_event_xref` joins in on `aq_short_event_id` (~100%).

**⚠ NOT `canonical_external_ids`** — name looks right, but DORMANT (passive `event_xref` drift feed only). Use `aq_event_map`.

**Orders/sales/listings are source-native-keyed; `tevo_event_id` is DERIVED, often NULL on fresh rows** (`evo_orders` — EVO native id IS tevo id; `tickpick_orders`, `vivid_orders`, `seatgeek_orders`, `sd_sales_normalized`, SG seller book). Terminal views key on `tevo_event_id` → unmapped = INVISIBLE. Never hand-map by name/date — mappers run:

| Mapper / job | Maps | Cadence |
|---|---|---|
| `match_to_aq_event_id(...)` / `create_system_aq_event(...)` | any source event → `aq_short_event_id` (4-tier + SYS-md5 fallback) | on demand |
| `auto_match_sg_canonical_v3()` / `sg_attempt_event_xref_v3(...)` | SG canonical → TEvo (±24h window, **same-date-first + off-date-series reject**, name/league + parking guards) | on-demand (`_hourly` cron DISABLED 2026-06-19, see §3) |
| `backfill_order_tevo_from_aq()` | orders/sales native → `tevo_event_id` | hourly :40 |
| `sg_seller_sync_and_map()` | SG SellerDirect → canonical + `tevo_event_id` | `*/15` |
| `sg_to_tevo_search_bridge` / `aq_tevo_search_candidates(...)` | cold events missing from `events` → TEvo `/v9/events` | cron/drained |
| `refresh_td_event_links()` | TD xref → TEvo (5-step chain) | nightly |
| `sg_match_map_tick()` | SG-mapped event → other-platform `sh`/`vivid` ids via TD `/match` (**SeatGeek-URL-anchored** — see §3) | `*/10`, budget-gated 50% |

**Map can be WRONG.** PK `aq_short_event_id` → N rows can share one `tevo_event_id` (un-merged TBD/`system_seed` dupes + venue+date false matches). `aq_name_consistent` guard blocks most; residual same-city TBD collisions remain. Dedupe per `tevo_event_id` + confirm performer/opponent before trusting a row.

Deeper: §3 column traps · §4 RPC args · §5 (full cross-source architecture — namespaces, hub, chains, orders/sales).

---

## 1. Hard rules (you can't override these)

1. **SQL data is read-only by default.** Any `INSERT`/`UPDATE`/`DELETE`/DDL on prod requires explicit operator permission per call. Standing exceptions: `bot_chat` writes via `bot_chat_log()`, Supabase branch creation (copy-on-write fork, no prod mutation), authoring migration files (apply gated separately).
2. **Upstream third-party APIs are READ-ONLY.** TEvo, SeatGeek, SeatData, TickPick, Vivid — GET endpoints only. No order POSTs, holds, webhook config changes without explicit operator authorization.
3. **HTML / JS in your assigned lane is free reign** — no per-step approval.
4. **Render writes are an Applier action** (§2.1) — reads are open to every session; a write to any service requires the Applier principal (today A1 sessions). Surface *ownership* (§2.7) ≠ standing write authority; the former "D0 workspace-wide parity" was retired 2026-07-02.
5. **Push to `main` is per-task** — the delegated **Builder** (§2.1) pushes its own work after green CI; `main` is maintained per-task, no sole-pusher lane (reorg 2026-06-17, supersedes "A1 sole pusher"). **Prod-DB mutation is an Applier action** taken per-task by any session under operator direction (no A1 gate — the codes are naming conventions, not a chain of command; author a migration → an Applier applies it). See §2.1.
6. **Cross-lane file edits require coordination** via `bot_chat` `question` or PR comment to the lane owner.
7. **Edge function auth: platform `verify_jwt=true` is NOT sufficient.** It accepts ANY valid Supabase JWT — including the publishable anon JWT exposed at `/api/public/config`. Edge functions that mutate data or burn paid upstream APIs MUST add body-level `requireCronSecret(req)` from `supabase/functions/_shared/cron-auth.ts`. Pattern verified across 12 existing functions; 3 exceptions caught in B1 audit PR #172 (2026-05-16) and patched in PR #174.
8. **Check `KANBAN.md §🟢 OPEN WORK` before claiming new work.** It is the single-source-of-truth for what's currently actionable across all lanes — severity-sorted, with the smallest fix for each finding. **Fixing bot DELETES its row from that section in the same PR as the fix** (row's absence IS the closure signal; archive sections below preserve the historical detail). Populate as you go — anyone can add a row; B1 maintains for security findings, each lane for its own. Broadcast: bot_chat 311 (2026-05-17).
9. **Work in your OWN git worktree — never the shared root checkout.** A `checkout`/branch-switch/`reset` on the shared clone strands other sessions. Each session uses its own worktree on a per-session branch cut from `origin/main`.
10. **When a change adds/alters a *documented* resource, update the bible in the same PR** (RULE 0 — judgment, not a gate; **most changes need no doc edit**). Update only when you add a NEW external service/secret, a new table/view/RPC/cron/edge-fn worth cataloguing, a new column landmine (§3), or a hot RPC (§4) → edit the owning doc (`RESOURCES_BIBLE`; §2.7 for deploy). Routine work (bugfix, index, refactor, a migration that catalogues nothing new) needs none. Prompted by self-check #12 + the PR checklist — not CI-forced (a gate can't tell "needs a doc" from "doesn't").

When in doubt → ask via `AskUserQuestion` or post a `bot_chat` question.

---

## 2. Lane assignment — who owns what

> **This section is the single source of truth for ownership** (absorbed `BOT_HIERARCHY.md` 2026-06-19). It answers "which lane owns this tool, table, route, or service" and "what does this action require." Immutable security invariants → `CLAUDE.md`. Migration mechanics → `MIGRATION_CONVENTIONS.md`. The resource catalog → `RESOURCES_BIBLE.md`. **Current priorities are NOT here — they live at the top of `KANBAN.md`** (fast-moving focus; this doc holds slow-moving invariants).

**Two orthogonal things, deliberately kept separate** (they used to be conflated in one table — that was the drift generator):
- **Ownership = *which surface*.** Who authors a given file/table/route/service. The lane labels (A1/B1/D0–D4; C1/D2 are retired historical tokens, folded into B1/D0) are an ownership map (§2.3 legend · §2.4 tables · §2.5 code map · §2.6 seams), **not** a roster of actors. Any session can work in any lane.
- **Permission = *which capability*.** What an action is allowed to do. This collapses to **three principals** (§2.1). Permission attaches to the *action*, not the session: one session is a **Builder** editing a surface and an **Applier** for the single step that applies its migration to prod.

### Determining your lane + principal — both derived, neither pre-assigned
A fresh session has no built-in identity. Derive both from the task:
1. **Lane (ownership)** — the path/surface you touch → its owner in the **§2.5 code map** (e.g. `supabase/migrations/*`→A1, `static/terminal/*`→D0, `static/store/*`→D1).
2. **Principal (permission)** — the *action* you take → **§2.1**. Editing a surface you own = **Builder**. Applying to prod DB / Vault / Render / cron = **Applier**. Guard / security-migration / docs-governance work = **Auditor**.
3. **Blast radius** — if that path is a **shared seam in §2.6** (or its output feeds another lane's surface), your change is **cross-lane** → the §2.6 `seam-review` CI checklist fires; coordinate with the named consumers before it hardens.

If the task prompt or your branch prefix (`claude/<lane>-…`) already names a lane, that's your ownership starting point — still run steps 2–3. **CI enforces this after the fact:** path/branch labeler → `area:`/`level:` labels · `surface-boundary-check` flags out-of-lane paths · the §2.5 **no-orphan invariant** (every path resolves to exactly one owner). When unsure, ask via `bot_chat` `question` or the operator.

**There is no hierarchy — the labels are lane identifiers, nothing more.** A1/B1/D0–D4 name *regions of the ownership map* (which surface), not actors, ranks, or teams. No lane reports to, sits "under", or is a manager/lead/arbiter of another — the old command chain (`A1→B1→C1`, "data lanes under C1", "D3 sub of D2") was **dissolved 2026-07-02**; only the naming convention survives, as a flat index into the surface map. Coordination is lateral (via `bot_chat`); `main` is jointly maintained (§2.1 Builder push rule); permission is per-action (§2.1), never per-label. Flat map: `docs/bot-hierarchy.mermaid`.

```
LANE MAP (codes name cells in a layer × product grid — flat, no ranks; §2.1 sets permission, §2.3 the grid):
  PLATFORM SUBSTRATE (the shared foundation every product sits on — not products themselves):
    A1  data + framework          — DB · migrations · crons · ingest pipeline · AQ mapper · server.py/routers/core · DB security
    B1  build + guards + governance — git/code security · CI + guards · drift · tests · docs (bibles + registry) · bot_chat  [Auditor surface]
  PRODUCTS (each a distinct surface + deploy target that sits on the substrate):
    D0 terminal + orders-dashboard   D1 store   D3 broadway   D4 Bridge/Exos (full app)
  Retired as lanes 2026-07-02 (KANBAN C1-OPS-3): C1→B1 (docs=Auditor work) · D2→D0 (both broker) · E1→A1 (2026-06-17).
```

### 2.1 Three principals — the permission model

Permission attaches to the **action**, not the session. A session picks up whichever principal each step requires; **most work is Builder**. This table is the whole permission surface — **zero inline exceptions**. Any deviation is a dated row in §2.2, so privilege creep is visible instead of ambient.

| Principal | Powers (what the action may do) | Who acts as it |
|---|---|---|
| **Applier** | Mutate prod: apply migrations to prod DB · `execute_sql` INSERT/UPDATE/DELETE/DDL · cron `schedule`/`unschedule` · Vault `rotate`/`set` · Render **writes** on any service · data-mutating edge-fn deploys | the session applying a reviewed change to prod — **any session, operator-directed** (the codes are naming conventions, not a hierarchy — no A1 gate) |
| **Auditor** | Guard + ledger authority: CI workflows + `bin/`/`scripts/` guard code · RULE-2 readonly guards · `cron-auth.ts` · **DB-security migrations (author + apply)** · the canonical doc registry + `bot_chat` + the §2.6 shared-resource register · security patches across **any** lane's files | a session doing security / guard / docs-governance work — today A1 (DB-security) + B1 (git/code security) + the former C1 registry duty |
| **Builder** | Author-only, per-task: edit any surface it **owns** in §2.5 (html/js/css/routes/migration *files*) · open a PR · push its own work to `main` after green CI. **No prod mutation** — a DB change is a migration *file* handed to an Applier | every session building on a surface — all D-tier + daily A1/B1 coding |

**Reads are always open** — SQL `SELECT`/`information_schema`/`pg_*`, Render + Supabase `list_*`/`get_*`, logs — no principal required. Standing Builder actions that need no ask: `bot_chat` writes (`bot_chat_log`), Supabase branch creation (copy-on-write fork), authoring migration files. `main` is maintained **per-task by whichever session does the work, after green CI** — not tier-gated, no sole-pusher lane (supersedes "A1 sole pusher", reorg 2026-06-17).

### 2.2 Permission exceptions — a CI-enforced ledger

Every deviation from the §2.1 principals lives in ONE machine-readable file — **`.github/permission-exceptions.yml`** — never in prose elsewhere (one fact, one home). The **`permission-exceptions` CI job** (`scripts/check_permission_exceptions.py`, blocking) **fails the build** when any entry is malformed or its `review_by` date has passed. So a privilege grant cannot silently become permanent: it is renewed — deliberately, by re-approving and bumping `review_by` — or it turns the build red and is removed. That is the ledger's teeth; a review date only means something if a machine reads it (contrast §2.6's seam job, which is a non-blocking nudge — this one gates).

**Today the ledger is empty.** The two prior inline exceptions were resolved 2026-07-02: **B1's security-migration apply** folded into **Auditor** (§2.1); **D0's "workspace-wide Render parity with A1"** was retired (Render write is an Applier power, and D0 is an ownership label (§2.3), not an actor with standing prod authority).

To grant an exception, add an entry (`id` · `grants` = Applier/Auditor/Builder · `to` · `rationale` · `granted` · `review_by`) to that file. An exception that maps cleanly onto a §2.1 principal is *not* an exception — fold it into the principal instead.

### 2.3 Ownership map — one platform substrate, N products

A surface map, **not** a roster of workers. Any session may work in any lane — B1 executed BR-CODE-1 across D0/D1/A1 route surfaces with no violation, because permission is per-action (§2.1), not per-label. Status/priority is not tracked here — see `KANBAN.md`.

**The codes are not a flat peer list.** They name cells in a **layer × product** grid: a two-area **platform substrate** (the shared foundation) and the **products** that sit on it — **six lanes** (substrate A1·B1 + products D0·D1·D3·D4). Two codes were retired as first-class lanes on 2026-07-02 (see the note below the tables).

**Platform substrate** — the shared foundation every product consumes; *not* a product itself, and its two areas are not competing lanes (a cross-substrate task is normal, not a boundary crossing):

| Code | Substrate layer | Owns |
|---|---|---|
| **A1** | data + framework | Supabase tables/migrations/crons; the **AQ mapper** + cross-source xref (incl. `*_canonical`/`*_resolved`/`seatgeek_event_xref`); the 9 read-only `*_client.py` + edge functions + **order ingestion**; `server.py`/`routers/*`/`core/*` as a package; DB-layer security (RLS/SECDEF/RULE-2); data-freshness + 429/cron monitoring |
| **B1** | build + guards + governance | git history; git/code security (secret leaks, insecure patterns — *not* DB RLS/SECDEF); `bin/`, `.github/workflows/*`, `scripts/` guards; drift · freshness · compartmentalization; the test suite + CI gates; **and the docs/coordination surface** — the **main bible set** + closed registry + structure, `bot_chat`, the §2.6 shared-resource register. This is the **Auditor** principal's home surface (§2.1). |

**Products** — each a distinct surface + deploy target that sits on the substrate:

| Code | Product | Owns |
|---|---|---|
| **D0** | Terminal + orders dashboard (broker) | `static/terminal/*` + the `/api/broker/*` route block; **`d2_dashboard/*`** (orders dashboard, folded in 2026-07-02); UX + speed testing; owns its Render services |
| **D1** | Store (consumer) | `static/store/*` + the `/api/store/*` block (the store surface hosted on the D0-owned `vibepass-storefront-test` service — surface ≠ service, see §2.7) |
| **D3** | Broadway | Broadway surface + `broadway_*` |
| **D4** | Bridge/Exos (full app) | primary-ticketing: Stripe checkout + transactional mail + `exos_*` schema; own deploy target |

> **Retired as first-class lanes (2026-07-02, tier-2 convergence — KANBAN C1-OPS-3):** **C1** (docs + coordination) folded into **B1** — docs governance *is* the **Auditor** principal's work (§2.1), so its surface belongs with the Auditor's home lane; **D2** (orders dashboard) folded into **D0** — both broker-facing, and D2 wrote no tables. C1's former DB sidecars (`*_canonical`/`*_resolved`/`seatgeek_event_xref`) moved to **A1**, whose mandate already owned cross-source xref (reconciling a contradiction, like the order-table fix in the §2 convergence PR). The `c1`/`d2` tokens survive only as historical branch-prefixes, KANBAN IDs (`C1-OPS-*`, `D2-*`), and `bot_chat` tiers — the `p_level` DB constraint is **unchanged** — not as ownership labels.

**Ownership rule — (product block) × (substrate layer).** A product owns its *block* (its routes, its static tree, its schema); the substrate owns the *framework* the block lives in (the file, the DB, the CI). Where they meet — `server.py`, shared `core/*` helpers, a shared table, the RULE-2 guard (`B1` guard × `A1` policy) — **the product owns behavior, the substrate owns structure**, and that intersection is a §2.6 seam by definition. This is why `/api/broker/*` is D0's even though `server.py` is A1's package: the route block is D0 behavior inside A1 structure — not an exception to ownership but the *shape* of it.

> **E1 folded (2026-06-17):** cron/429/Slack alerting → **A1**; per-surface webhooks (`stripe-webhook` → D4, `sg-seller-webhook` → A1). **No lane-specific bibles (2026-06-19):** everything universal lives in this main set; lane-specific *procedure* (e.g. the D0 terminal build) is an on-demand `docs/` reference, not a session-start read.

### 2.4 Single-writer table ownership

One lane writes each table; all others read (mechanics: `MIGRATION_CONVENTIONS.md §4`).

| Lane | Tables they write |
|---|---|
| **A1** | `event_xref`, `*_xref`, `event_listing_snapshot_daily`, sweep fns, `latest_event_metrics` matview, FRED macro, ESPN tables, `event_movers_index(_history)`, `discovery_gap_alerts`, **the order + ingest tables** (`evo_orders`, `seatgeek_orders`, `tickpick_orders`, `vivid_orders`, `seatdata_sales_snapshots` — order *ingestion* is A1's data plane, §2.3), **`*_canonical`/`*_resolved` sidecars + `seatgeek_event_xref`** (cross-source data, moved from C1 2026-07-02), **`pg_policies`/RLS** |
| **B1** | `bot_chat` (schema/structure; all lanes append via `bot_chat_log()` — standing permission, §2.1) + the main bible set + registry (docs surface, absorbed from C1 2026-07-02); otherwise git history, CI/guard code, `cron-auth.ts`, test suite |
| **D0** | `static/terminal/*` + `d2_dashboard/*` (read-only from DB) |
| **D1** | `share_links` |
| **D3** | `broadway_*` |

### 2.5 Code lane-assignment map (full-tree)

**No-orphan invariant:** every tracked top-level path resolves to exactly one owning lane here (or an explicit shared seam in §2.6); add a new top-level path here in the PR that introduces it (unassigned = cross-contamination risk).

| Path / component | Owner | Notes |
|---|---|---|
| `supabase/migrations/*` | **A1** | all schema/data/cron/RLS migrations |
| `supabase/functions/*` (ingest/drains: `collect*`, `espn*`, `seatdata-poll`, `wiki-collect`, `*-search-bridge`, `seatmap-manifest-sync`, `sg-seller-webhook`, …) | **A1** | data pipeline |
| `supabase/functions/chat` | **A1** (fn) · D0+D1 consume | retail-chat NL price/inventory edge fn (#583); cross-surface → §2.6 |
| `supabase/functions/exos-*` + `stripe-webhook` | **D4** | Exos app edge fns |
| 9 read-only `*_client.py` (evo/seatgeek/seatdata/ticketsdata/axs/tickpick/vivid/gotickets) | **A1** | GET-only by construction |
| `broadway_client.py`, `broadway_extension/`, `broadway_*` | **D3** | Broadway scraper |
| `server.py` + `routers/*` + `core/*` | **A1** (file/package) | decomposition (BR-CODE-1): `routers/*` = `APIRouter` modules `include_router`'d back (`shares`/`seatmap`/`retail_chat`/`catalog`/`lists`/`broker`/`seatdata`/`axs`/`seatgeek`/`d0_sales`/`bandsintown`/`misc`/`site_essentials`/`store`/`pages`/`store_test`/`admin`/`storefront_pages` — **route decomposition COMPLETE: the API/page/domain route blocks live in routers; server.py holds `/healthz`+`/webhooks/render`+`/api/admin/scheduler-watchdog/status`+`/` hub (plus the still-inline broker/store event-detail blocks)**); `core/*` = shared runtime both import (`config`·`auth`·`helpers`·`broker_helpers`·`movers`·`search`·`substitutions`·`store_events`·`observability`·`db`·`resilience`·`ratelimit`·`readonly_guard`·`http_retry`·`vault`·`concurrency`·`seo`·`discovery`·`trip_payloads`·`ingest`·`storefront_html`·`canonical_refresh` — the last 5 + `search`'s `search_live`/`search_players`/`search_cache_*` are the BR-CODE-1 core/ helper pass: business-logic bodies moved out of server.py, each injected back via a thin server wrapper so live-symbol monkeypatches keep binding); `db`/`resilience`/`ratelimit` = production-readiness infra (bounded-timeout Supabase client · DB circuit breaker + retry + storefront stale-read · Redis-or-in-process limiter); **`readonly_guard`/`http_retry`/`vault` = the shared `*_client.py` layer (BR-CODE-2)** — `readonly_guard.build_readonly_guard` single-sources the RULE-2 GET-only guard (all 9 GET-only clients; **security-CRIT, never weaken**), `http_retry.fetch_with_retry` the 429/5xx Retry-After+backoff loop (7/9 clients; axs fixed-delay + broadway scraper opt out), `vault.vault_secret` the Supabase-Vault `get_app_secret` resolver (5 vault clients); env knobs → `RESOURCES_BIBLE §7`; **one-directional import** (`server.py`/`routers`/`*_client.py` → `core`, never reverse); per-surface route blocks are product-owned inside A1's package — D0 `/api/broker/*`, D1 `/api/store/*` — the §2.3 (product block × substrate layer) rule, surfaced in §2.6. Full per-module route map → `RESOURCES_BIBLE §9`. |
| order tables + ingestion; AQ mapper + `*_xref` + metrics matviews; RLS/SECDEF/RULE-2 | **A1** | cross-source hub + DB security |
| `bin/*`, `.github/workflows/*`, `.gitleaks*`, `.gitignore`/`.mcp.json`/release plumbing; `scripts/check_readonly.py`, `tests/*` (incl. `tests/frontend/` = Playwright browser net — smoke + behavioral; runs as its own `frontend-smoke` CI job, self-skips via `pytest.importorskip` so the main 100%-coverage `pytest tests/` run ignores it) | **B1** | CI + git guards + tests |
| canonical `*.md` registry, `.understand-anything/`, `.claude*` governance (hook/scanner code); `bot_chat` + shared-resource register | **B1** | docs governance + coordination + harness (absorbed from C1 2026-07-02 — the Auditor surface) |
| `static/terminal/*`, `/api/broker/*`, `render-d0-terminal.yaml`; `static/{home,undelivered,index.html,favicon.svg,version.json}`; `docs/d0_terminal_build.md` | **D0** | terminal FE + own Render + root hub + build manual |
| `static/store/*`, `/api/store/*` (store surface; `render.yaml` is the shared `vibepass-storefront-test` service IaC — D0-owned per §2.7, not a D1 surface file) | **D1** | storefront FE |
| `static/_shared/` + `static/shared/` | shared (FE) | cross-surface assets (design tokens, retail-chat widget) — seams in §2.6 |
| `d2_dashboard/*`, `render-d2-dashboard.yaml` | **D0** | orders dashboard (folded from D2 2026-07-02 — broker-facing) |
| `d4_bridge/*`, `static/bridge/`, `exos_*` schema | **D4** | Exos/Bridge full app |
| `requirements.txt`, `Procfile`, data `*.csv` seeds | **A1** (shape) | lanes add their own deps |
| `design/`, `docs/archive/` | — | historical / non-canonical |

### 2.6 Shared cross-lane resources — seam register (CI-mechanized)

The seams where one lane's change can break another's surface. **A PR touching any path below trips the `seam-review` CI job (`.github/workflows/seam-review-check.yml`), which auto-comments a consumer-impact checklist naming the cross-lane consumers to verify** — the mechanized form of the seam review (it replaced the unstaffed "C1 reviews every seam" rule 2026-07-02: the arbiter was honored in the breach, so the check is now a job, not a person). Coordinate with the named consumers before merging; the job is non-blocking (visibility + nudge, not a hard gate).

| Shared resource | Writer | Cross-lane consumers | Rule |
|---|---|---|---|
| **Venue/seat map** (`lib/tevomaps.bundle.js`, `venue.js`/`event.js`; `cross_source_venue_map`/`aq_venue_map`/`venue_assets`) | D0 (component) · A1 (data) | D0 terminal + D1 `store.js` | a D0 map change must keep store rendering; tail-remap landmine (§3) applies to both |
| **API surface** — single `server.py` | A1 (file) | D0 `/api/broker/*` · D1 `/api/store/*` · A1 `/api/public/*` | route blocks lane-owned; shared helpers + `/api/public/config` → PR comment to both FE lanes |
| **`trip_planner/`** | shared (D0+D1) | `/api/broker/.../trip-plan` (D0) + `/api/store/.../trip-plan` (D1) | one engine, two routes; regression-test both |
| **Order data** — `unified_orders`/`cross_source_orders` | A1 (ingest+view) | D0 `orders.js` tiles + the `d2_dashboard` (both D0 since 2026-07-02) | a view/schema change must serve both surfaces; keys on `tevo_event_id` (unmapped = invisible, §0) |
| **`*_public` RPCs** — wholesale-filtered read boundary | A1 | D1 store (only path) | D1 may never read `broker_*`/wholesale fields; the whitelist is the contract |
| **`static/_shared/design-tokens.css`** | shared (FE) | D0 (terminal + dashboard) · D1 · D4 | token change ripples to every surface — the `seam-review` job flags it; coordinate across all products |
| **Retail-chat** — `static/shared/retail-chat-widget.js` + `supabase/functions/chat` (#583) | A1 (edge fn + widget) | D0 `static/terminal/retail-chat.*` + D1 `static/store/chat.html` | one widget + one edge fn, two surfaces — a contract change must keep both working |
| **RULE-2 lockdown** — `check_readonly.py`/`test_readonly_guards.py`; guard body single-sourced in `core/readonly_guard.py` (BR-CODE-2) | B1 (guard) · A1 (policy) | every `*_client.py` + CI | weakening = security-CRIT. Each client still declares its own `ALLOWED_HTTP_METHODS`+`frozenset({"GET"})`+`_assert_readonly_method` tokens (the static audit requires them in-file); only the assertion *body* is shared. Never re-inline or widen. |
| **AQ mapper** — `aq_event_map` | A1 | **every lane** resolving cross-source IDs | the #1 fact (§0); never join raw source IDs |

### 2.7 Deploy infrastructure (Render)

| Service | Service ID | Owner | Sub-implementer | Source | IaC |
|---|---|---|---|---|---|
| `vibepass-terminal-test` | `srv-d839339kh4rs73ac3s20` | **D0** | D0 | `static/terminal/*` | `render-d0-terminal.yaml` |
| `vibepass-storefront-test` | `srv-d8140bnaqgkc73al4asg` | **D0** | D1 | `server.py`, `static/store/*` | `render.yaml` |
| `d2-orders-dashboard` | `srv-d82b4kl7vvec73b4r3r0` | **D0** | D0 | `d2_dashboard/*` | `render-d2-dashboard.yaml` |

*Owner* = which lane owns the service **surface**; a *write* to any of them is an **Applier** action (§2.1), today performed by A1 sessions (the former "D0 workspace-wide Render parity" was retired 2026-07-02 — surface ownership ≠ standing prod write authority).

**Testing-unified (2026-05-16, PR #168):** all runtime traffic flows through `vibepass-storefront-test` (starter, no cold starts) — it mounts D0 terminal + D1 storefront + D2 dashboard via `app.include_router`. `vibepass-terminal-test` is the D0 static CDN; `d2-orders-dashboard` is an idle placeholder. Both live services auto-deploy from `main` after green CI. **Render access:** reads open to all; **writes = Applier (§2.1)**. Full deploy chain → `docs/d0_terminal_build.md`.

### 2.8 Cross-cutting lane rules + D-tier scope

1. **Shared files** (`server.py`, `requirements.txt`, `MIGRATION_CONVENTIONS.md`, `KANBAN.md`) — propose via PR comment to the owner before editing.
2. **Single-writer per table** (§2.4 + `MIGRATION_CONVENTIONS.md §4`).
3. **Security cross-cutting** — an **Auditor** (§2.1) may patch any lane's file for a security CRIT/HIGH, surfaced via PR comment to the affected lane. This is a principal power, not a per-lane exception — no §2.2 row needed.
4. **Out-of-lane writes** require a PR comment to the lane owner; if offline, `flag` in `bot_chat`. **Never silently write across lanes** — even cache files/logs count.
5. **SECURITY DEFINER convention** — every new SECDEF fn ships in one migration with `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE … TO service_role` + a `current_user NOT IN ('service_role','postgres','supabase_admin')` guard at body start.

**D-tier scope (D1–D4)** is this §2 + `docs/d4_bridge_charter.md` (D4 full charter); the old per-lane self-contracts are archived (`docs/archive/d{0,1,4}_operating_constraints.md`) — a D-tier session reads §2.3/§2.5/§2.6 for its surface, not those snapshots. As **Builders** (§2.1) D-tier writes only its own surface; never DB tables directly (file a migration *file* → an **Applier** applies it). **D4/Exos** is primary-market ticketing on its own `exos_*` schema, served at `/bridge/`, linking to canonical events **by value** via `bridge_event_xref` — never writes D0 tables.

---

## 3. Column-name landmines (catch SQL bugs before you author)

Every entry here cost real session time when discovered. CHECK column names against this table FIRST.

| Table | Wrong name | Correct name |
|---|---|---|
| `seatgeek_sales_snapshots` | `sold_at`, `price`, `captured_at` | `sale_at_utc`, `broadcast_price`, `pulled_at` |
| `seatgeek_listings_snapshots` | `price` | `broadcast_price` (+ `retail_price_all_in` for all-in display) |
| `seatgeek_event_metrics` | `cost_min/median/p90` (DROPPED 2026-05-18) | `listings_all_min/median/p90` (full firehose) or `listings_owned_min/median/p90` (broker-owned subset) — PR-4a/4b |
| `seatgeek_event_metrics.listings_all_count` (via the hourly `refresh_sg_broker_listings_event_metrics`) | trust it as the live listing count | **Under-counted ~9× (411 vs 3,560 live, verified head-to-head 2026-06-08).** The broker DEDUPES raw `seatgeek_listings_snapshots` by `content_hash` (`event:id:bp:q`) — a stable listing is written ONCE and never again, so a `DISTINCT ON (sglid)`-over-24h refresh counts only listings that *changed* in the window, not the live book. **FIX (mig 20260608030000): `sg_broker_listings_process` now computes the FULL count + price/owned aggregates from the WHOLE `/listings` response at process time** and writes them straight to `seatgeek_event_metrics`; the redundant hourly listings-metrics refresh is retired. Raw-snapshot dedup (storage saving) is unchanged — only the metric path was corrected. (A1 2026-06-08) |
| `event_alerts` | `event_id`, `created_at` | `tevo_event_id`, `fired_at` |
| `nws_alerts` | `expires` | `expires_at` |
| `weather_observations` | `captured_at` | `observed_at` (reading) + `fetched_at` (ingest) |
| `venue_assets` | `is_outdoor`, 882 rows | `is_indoor`, **111 rows** (outdoor = `is_indoor = false`) |
| `sd_sales_normalized` | `observed_at`, `aq_short_event_id` | `sale_timestamp`, `tevo_event_id` |
| `events` | `is_classified`, `tbd` | (neither exists — use `EXISTS(event_xref...)` for sports; parse `(Date TBD)` from name) |
| `public.events` time column | `occurs_at` (no such column) | **`occurs_at_local` is the ONLY event-time column — and it's `TEXT`** (offset-bearing `"YYYY-MM-DDTHH:MM:SS±HH:MM"`, nullable). There is NO `occurs_at timestamptz`. Cast/parse the text if you need a real timestamp. Verified vs prod 2026-05-28. |
| `bid_ask_proxy` | reference the table / view / column anywhere | **Permanently dropped — does not exist** (no table, no view, no column). Verified absent in prod 2026-05-28. Don't reintroduce reads against it; derive spread-style signals from `event_metrics` / `listings_*`. |
| `listings_snapshots` (TEvo firehose 8M rows) | filter by `aq_short_event_id` | **0% populated** — query by `event_id` only. Filter ours: `is_owned=true AND brokerage_id=1768` |
| `seatgeek_sales/listings_snapshots.tevo_event_id` | use as join key | **0% populated** — always query by `sg_event_id` (indexes added 2026-05-16) |
| Order/sales tables' `tevo_event_id` (`evo_orders`, `tickpick_orders`, `vivid_orders`, `seatgeek_orders`, `sd_sales_normalized`) | filter/join by `tevo_event_id` assuming it's set | **Source-native-keyed; `tevo_event_id` is DERIVED via the AQ mapper and is often NULL on fresh rows.** Each row has the source's own event id (TP `raw->>'event_id'`, `vivid_event_id`, `sg_event_id`, `sd_event_id`; EVO `event_id` = TEvo id). Populate by running/awaiting `backfill_order_tevo_from_aq()` (hourly @ :40); never hand-map by name/date. Terminal order views key on `tevo_event_id` → unmapped = invisible. Full rule: §5 (orders/sales). (A1 2026-05-30) |
| `axs_*_snapshots` (AXS primary box office) | treat raw amounts as dollars; trust `tevo_event_id`; assume axs.com = resale | **Raw amounts are CENTS** (`/100`); `tevo_event_id` is **AQ-derived (often NULL until `axs_apply_aq` runs)** — snapshots key on it, so unmapped = invisible; `occurs_at_local` is offset-naive AXS-local (±1 day vs TEvo on reschedules — `axs_aq_match` uses a ±48h window); the `9000000…` offerIDs are **resale**, everything else is **primary box office**. AXS is a PRIMARY ticketer, not a resale feed. Map: `axs_aq_match()` → `tevo_event_id`. (A1 2026-06-10) |
| `seatgeek_sales_snapshots` aggregates | `count(*)` / `SUM(broadcast_price)` directly | **11–23× overcount** — UNIQUE `(sg_event_id, sg_sale_id, pulled_at)` means each logical sale re-inserts every poll. **MANDATORY**: `DISTINCT ON (sg_sale_id) ORDER BY sg_sale_id, pulled_at DESC` before any aggregate. `MAX()` alone is safe (idempotent). Exemplars: `v_event_sales_metrics_filtered`, `v_event_sales_velocity` (PR #161); v3 RPC `sg_broker_sales` (PR #191). |
| `v_rivalry_events` aggregates | `count(*)` / first-row per `tevo_event_id` | **Duplicate rows emitted when both teams are competitors** — view joins both home + away through `sporting_rivalries`. Dedupe Python-side keyed on `tevo_event_id` (first match wins) before consuming. Exemplars: `routers/broker.py` event-page enrichment + `core/movers._compute_movers` Specials rail (PR #275; moved out of the old `app.py`/`server.py` inline in the BR-CODE-1 decomposition). |
| `v_event_weather_with_fallback.is_climo_fallback` | (column doesn't exist) | Derive `weather_kind = 'climatology_outdoor'`. Values: `'none' / 'forecast_indoor' / 'forecast_outdoor' / 'climatology_outdoor'`. |
| `v_event_weather_with_fallback.climo_temp_f` | wrong name (no `_avg`) | Actual is `climo_avg_temp_f`. Sibling climo cols: `climo_avg_precip_in`, `climo_avg_wind_mph`, `climo_stddev_temp_f`, `climo_precip_pct`. The view also exposes top-level pre-resolved `temp_f / precip_in / precip_pct / wind_mph / weather_summary` — use those if you don't need a forecast-vs-climo badge. |
| `sg_events_canonical` Parking pseudo-events | match against TEvo | **TEvo merges parking into main listing** — skip `sg_category IN ('Parking','parking')` and `*venue_name ILIKE '%parking%'` rows. Matcher v3 enforces this. |
| TEvo `/v9/events` date filter | `occurs_at_gte` (underscore) | **`"occurs_at.gte"` (dotted)** — underscore returns 422 Invalid Parameters |
| `pg_net.http_get()` inside a loop | `PERFORM pg_sleep(N)` between calls to pace upstream rate limits | **NO-OP for rate limiting** — pg_net is **asynchronous**. The function returns a request_id immediately; HTTP fire happens in a background dispatch worker that doesn't honor function-side `pg_sleep`. Evidence: 50 queued GETs fired with IDENTICAL `_http_response.created` timestamp `02:34:45.137759`. PR #212/#214 pg_sleep stagger never worked. **Right pattern**: cap burst size to ≤ upstream token quota and use cron frequency for throughput. Codified as macro in §7. Discovered via PR #228 / mig 20260519140000. |
| `espn_team_id` / `espn_event_id` cross-table reads | filter by id alone | **Cross-league collision** — espn_team_id `"28"` maps to BOTH MLB Atlanta Braves AND an NHL team (`28` had 1,400 NHL injury rows vs 3 MLB rows in 7-day window). Always **scope by `espn_league`** when reading `espn_injuries_snapshots` / `espn_event_snapshots` / cross-team joins. `event_xref.espn_league` carries it through from the TEvo side. Discovered via PR #237 / mig 20260519150000. |
| ESPN team-ID resolution for forward-look events | `espn_event_snapshots` | **Snapshot pipeline is gameday-scope only** (§10 drift). For future events use `espn_event_date_lookup` (forward-look home/away/game_at_utc) first, fall back to snapshots only for past games. |
| PL/pgSQL `EXCEPTION WHEN OTHERS` to swallow a `statement_timeout` | `WHEN OTHERS THEN ...` | **Does NOT trap `query_canceled` (SQLSTATE 57014)** — that's exactly what `statement_timeout` raises, and `OTHERS` deliberately excludes it (so users can always cancel). A function meant to soft-fail on timeout MUST list `WHEN query_canceled THEN ...` explicitly (then optionally `WHEN OTHERS`). Reset `statement_timeout` to a safe value before any trailing work in the handler or the next statement re-cancels. Discovered live: `compute_event_breakdowns` non-fatal fix (mig 20260520410000) — first cut used `OTHERS`, still 502'd; `query_canceled` caught it cleanly. Exemplar: `backfill_stale_zone_metrics`. |
| MCP `execute_sql` heavy ad-hoc scans (audit queries) | run unbounded against prod | **MCP runs as `service_role` (NO `statement_timeout` cap); PostgREST anon/auth has 3s/8s.** Heavy seq-scans over `listings_snapshots` (8M rows) / `seatgeek_*_snapshots` compete for shared_buffers + IO and can tip otherwise-fast user-facing RPCs past their 8s ceiling (observed: `/api/broker/movers` 500 while an MCP 7-day scan ran). **Mitigations**: `SET statement_timeout='Ns'` on audit queries; prefer indexed predicates (`WHERE event_id IN (...)`, `event_id + captured_at`) over date-range seq-scans; use `latest_event_metrics` (matview, ~1k rows) instead of scanning `listings_snapshots` for "latest per event". |
| Capping pg_cron jobs: what actually bounds a cron statement | `SET LOCAL …` inside the fn; or assuming the whole multi-statement command shares one timer | **Probe-verified semantics (2026-07-01, throwaway cron `SET statement_timeout='5s'; SELECT pg_sleep(10);` → failed at exactly 5.0s):** (a) an **in-string `SET statement_timeout` in a pg_cron command DOES arm per-statement** — it caps the following statements in the same command; (b) `SET LOCAL` **inside a running function** is still a NO-OP on the in-flight statement (verified: nested `pg_sleep(4)` under `SET LOCAL '2s'` ran full); (c) the **role-level default is the reliable floor**: pg_cron runs every job as **`postgres`**, which had `statement_timeout=0` → any cron without its own SET ran UNBOUNDED. **FIX (mig 20260701213000): `ALTER ROLE postgres SET statement_timeout='900s'`** — 15-min backstop on every cron statement; MCP/PostgREST/app override per-session. **CAUTION — a cancel can be swallowed:** a per-event `EXCEPTION WHEN query_canceled` handler catches the timeout's cancel and the statement keeps running with the timer spent (suspected factor in the 2026-07-01 70-min zone-backfill hang that ran far past its 90s prefix). So: per-statement SETs give per-step budgets (exemplar: `refresh_movers_agg` split into 5 per-window statements, mig 20260701224500); loops still need a wall-clock `EXIT WHEN clock_timestamp()-v_start > 'Ns'`; and heavy per-event fns must be fast by construction (`compute_event_zone_metrics`/`_section_metrics` rewrites, migs 20260701215000/220000). NB: the durable FastAPI watchdog (`server.py`) is NOT confirmed running in prod — do not rely on it. **(d) SET LEAK (2026-07-02, root-caused from 3 straight `refresh_movers_agg` failures at exactly 120s with NO 120s config anywhere):** with `use_background_workers=off`, pg_cron reuses PERSISTENT pooled connections across jobs — a plain in-string `SET statement_timeout` survives its job's implicit-transaction commit and stays on the connection, so **every later prefix-less job on that connection inherits it** (movers inherited the chart jobs' 120s). Rule: a cron that needs a real budget carries its OWN `SET` prefix (movers now `840s`, mig 20260702075500); a cron that sets a tight budget scopes it `BEGIN; SET LOCAL …; …; COMMIT;` so it can't pollute the pool (chart jobs converted, same mig). 126/138 active jobs are prefix-less — they run at "whatever leaked last", between 90s and 900s. (A1 2026-07-02) |
| Unconditional `max(col)` / wide-window `DISTINCT ON` over a big or bloated table inside an event-page-style RPC | `max(last_seen_at) FROM espn_injuries_snapshots` (no WHERE); `DISTINCT ON (tg) … WHERE captured_at > now()-24h` | **Scans the whole table/window even when one row is wanted → timeout.** `espn_injuries_snapshots` is **175 MB for ~16.5k live rows** (wide/bloated), so a no-WHERE `max()` = full seq scan on EVERY event-page load (≤18s, wildly variable w/ cache). Postgres' `max()`→index optimization **will not match a `(col DESC)` index** here — use explicit `ORDER BY col DESC NULLS LAST LIMIT 1` (+ a matching index). For firehose `DISTINCT ON`, resolve `max(captured_at)` first then dedup only `captured_at >= max - 30min` (prev_* deltas are precomputed, no history needed). Fixed the whole `get_broker_event_page` v1→v2→v3 chain (mig 20260530120000): 18.8s→~0.5s. (A1 2026-05-30) |
| `exos_events.occurs_at_local` (D4/Exos) | naive wall-clock timestamp | **Offset-bearing TEXT** `"YYYY-MM-DDTHH:MM:SS±HH:MM"` (e.g. `2026-05-21T20:00:00-04:00`) — mirrors `public.events`; derive via `utcToOccursAtLocal()`. The create flow MUST set `occurs_at_local` + `event_type` or they land NULL (shape-consistent ≠ value-consistent). |
| `exos_events.event_type` (D4/Exos) | fine-grained map / "complete" every row | **Coarse category map only**: Sports→`game`, Music→`concert`, Arts→`show`; Nightlife/Tech/Food→`NULL` (matches the ~60% of TEvo rows that are NULL — don't backfill it). |
| `exos_tickets` barcode/QR (D4/Exos) | store the barcode or QR payload | **Not stored** — only `barcode_secret` (plaintext HMAC key, RLS-gated to owner/buyer/staff). QR is computed + rotated **client-side** as `HMAC-SHA256(secret, "ticketId:ownerId:bucket")`. |
| `INSERT ... ON CONFLICT ... RETURNING` + separate DELETE to expire old rows — use `clock_timestamp()` as `v_now` | `v_now := clock_timestamp()` in DECLARE; UPSERT sets col `= now()` (transaction start) | **Transaction-start-time vs wall-clock mismatch kills the index.** `clock_timestamp()` advances continuously; `now()` is fixed for the entire transaction. If DECLARE captures `clock_timestamp()` at `T+0ms`, but the UPSERT sets `last_computed_at = now()` (transaction start, necessarily ≤ `T+0ms`), then the DELETE `WHERE last_computed_at < v_now` fires immediately after and removes every row just inserted. **Fix**: use `v_now := now()` everywhere — DECLARE + UPSERT SET + DELETE WHERE all use the same fixed transaction timestamp; rows inserted in this tx have `last_computed_at = v_now` exactly, so the DELETE condition `< v_now` is false. Diagnosed on `compute_event_movers_index` 2026-05-27: function returned 20 (inserted) but table stayed empty. |
| A per-ROW trigger doing an index probe on a firehose insert path | `BEFORE INSERT ... FOR EACH ROW` on `listings_snapshots` with a prior-row lookup | **Stalled EVO ingest for ~4 min (2026-07-02).** At ~80k rows/10min, one cold index probe per row (37GB table, random IO) pushed the collect-listings edge fn's per-event batch inserts past its timeout — and the edge fn SWALLOWS insert errors and returns 200, so the only symptom was zero rows landing. Single-row tests pass (hot cache) — they do NOT validate batch-volume cost. **Rule: on firehose tables, per-row triggers must be pure in-memory (e.g. the `espn_athletes` jsonb-compare suppressor is fine); anything needing a lookup belongs in a STATEMENT-level trigger with transition tables (one set-based pass per batch) or in the edge fn.** Reverted in mig 20260702000500 (post-mortem in header). (A1 2026-07-02) |
| Postgres `format()` with float placeholders | `format('%.1f', v)` or `format('%.0f', v)` | **Only `%s`, `%I`, `%L` are valid.** `%.1f` → `unrecognized format() type specifier "."`. Numeric formatting: `round(v::numeric, 1) \|\| '%'` or `'val = ' \|\| round(v, 0)`. Discovered in `evo_sg_discovery_gaps()` 2026-05-27. |
| `SELECT DISTINCT ON (…) … UNION ALL …` | direct UNION member | **Illegal in Postgres** — `DISTINCT ON` with `ORDER BY` cannot be a direct UNION/UNION ALL member. Wrap in a subquery: `SELECT * FROM (SELECT DISTINCT ON (x) … ORDER BY x, y) qN UNION ALL …`. Discovered in `evo_sg_discovery_gaps()` 2026-05-27. |
| `bot_chat_log` first arg | `'status'`, `'info'` | **`p_level` is a bot tier, not severity**: valid values are `'admin','security','supervisor','primary-sales','secondary-sales','data-collection'`. D0 uses `'data-collection'`. Passing `'info'` → `bot_chat_bot_level_check` constraint violation. Discovered 2026-05-27. |
| FK marked `NOT VALID` assumed to skip insert enforcement | `ADD CONSTRAINT … NOT VALID` (or "it's NOT VALID, so it won't block") | **`NOT VALID` only skips validating PRE-EXISTING rows — it STILL enforces every new INSERT/UPDATE.** To stop insert-time FK failures on a raw, async-mapped ingest table you must **DROP** the constraint, not mark it NOT VALID. Cost a round 2026-06-03: `seatgeek_seller_listings` had 4 FKs (2 VALID + 2 NOT VALID); seller ingest failed 100% on the *NOT VALID* `sg_event_id_fkey` (`sg_event_id` not in `sg_events_canonical`) until **all 4** were dropped. Raw seller/firehose tables reference events/venues not in our canonical/map tables — FKs at insert time are the wrong model there. (A1 2026-06-03) |
| SeatGeek listings = **THREE feeds, one shared token** | assume a single "SG listings" pull | **broker `/listings`** (`sg_broker_listings_*`, driven by `sg_listings_poll_tick` — **split owned/non-owned 2026-06-03**, see next row — ACTIVE; marketplace view w/ `is_broker_owned` flag) · **broker `/v2/listings`** (legacy `sg_listings_*` jobs 53–58, **DISABLED since ~2026-05-14**, superseded by `sg_listings_floor_sweep`; empirically ~identical data to `/listings`) · **seller `/listings`** (`sg_seller_*`, ACTIVE — our own S4K inventory → `listings_owned_*`). (A1 2026-05-29) |
| SG broker poll cadence = **config-driven + rate-limited** | hard-code an interval, or pull every event every tick | **SG broker is a ~5-req/10s window.** `sg_listings_poll_tick(p_max,p_min_remaining,p_owned_kind)` is **rate-aware** (backs off on the live `ratelimit-remaining` header) and runs **`p_max=5` per tick**; pull cadence is **per-event, config-driven** in `public.collector_cadence` (band by date-horizon × `owned_kind` — see RESOURCES_BIBLE §5), **not** a fixed schedule. **Split into two pollers 2026-06-03** (operator directive, token-spend/429 fix): `sg_listings_poll_owned_1min` (`p_owned_kind='owned'`, tight horizon bands, was `*/1`; **PAUSED 2026-07-02 — the entire SG listings path is now dark; listing context comes from EVO + TD-SH, see `RESOURCES_BIBLE §5`**) and `sg_listings_poll_nonowned_5min` (`p_owned_kind='non'`, all bands **once-daily** =1440, **OFF for now** — `cron_policy.enabled=false`; flip to true to resume). The combined `sg_listings_poll_2min` is **RETIRED**. "owned" = we hold inventory at the event (`owned_count_last_7d>0`), a cadence flag — NOT the seller feed (`sg_seller_*` is a separate source, still ACTIVE). The SG cadence clock (`sg_event_priority_state.last_fired_listings_at`) **advances only on HTTP 200** — strand-safe, so a 429/timeout re-tries instead of burning the event's slot. (EVO is the sole TEvo consumer → effectively unlimited; only SG is gated.) There is **no** `sg_listings_poll_state` / `horizon_days` column. (A1 2026-05-31; split A1 2026-06-03) · **trading-hours cadence redesign (market-timed + metronome firing) APPLIED 2026-06-06 for SG listings/sales + TD; SellerDirect pagination held → `RESOURCES_BIBLE §5`** · **owned-focus redesign APPLIED 2026-06-08 (mig 20260608030000, operator-directed): listings poll OWNED events only at 2× their band interval (½ frequency); the league + non-owned pollers are DROPPED; SG sales = flat 24h per non-SKIP event ≤90d + post-event final flush. Net broker load ≈3,600→1,800 listings/day, which clears the 10-req/10s burst contention (the 429 source) without a shared gate. (A1 2026-06-08)** |
| SeatGeek rate limit | per-endpoint, or hourly quota | **per-TOKEN burst ≈10 req/8s, SHARED with a separate prod program** (its draw is invisible to our crons but real → 429s appear at LOW volume from burst collisions, not hourly volume). Live budget is in every broker response header **`ratelimit-remaining`** → the **`v_sg_token_budget`** view. An adaptive gate must honor only a **FRESH** reading (≤~10s ≈ the window) — a stale low reading deadlocks it (backs off → fires nothing → no new reading). (A1 2026-05-29, `sg_listings_floor_sweep`) |
| `sg_event_priority_state.tier = 'TRACK_BLINDSPOT'` | "unmatched / mapping gap" | **ownership tier, NOT a mapping problem** — 99%+ of these ARE aq+tevo mapped. `sg_classify_events` assigns it to US events 1d–1yr out where **`owned_cnt = 0`** (we hold no inventory). "Blindspot" = a market we don't trade, not an unknown event. Per-event fair-coverage floor = `sg_listings_floor_sweep` (`*/2`, adaptive-gated). (A1 2026-05-29) |
| TicketsData platforms | SH/VD/GT only (or "TM is just a stub") | **5 platforms live: SH/VD/GT + TickPick (TP) + Ticketmaster (TM)**, all via TD `/events` (search by `performer_url`) + `/fetch`. `td_api_platform` maps `TP→tickpick`, `TM→ticketmaster`. **A new TD platform needs its own `td_enqueue_peak_<plat>` cron** (else active xref rows never enqueue→pull) AND must be added to **BOTH** the `ticketsdata_event_xref.platform` CHECK **and** the *separate* `td_pull_queue.platform` CHECK — TM was missing from the queue's CHECK → enqueue raised 23514 even though the xref CHECK allowed it. Discovery mirrors GT: `td_<plat>_performers` allowlist + `td_<plat>_discover/_drain`, matched by venue+datetime. (A1 2026-05-29, `td_tickpick_platform` + `td_ticketmaster_platform`) · **TickPick DEMOTED to per-event opt-in 2026-06-07 (mig 20260607170000, operator directive "demote tickpick, replace with ticketmaster everywhere it was"): new `ticketsdata_event_xref.manual_opt_in` (DEFAULT false) — on apply ALL TP rows → false, so `td_enqueue_peak()` stops enqueuing TP unless `manual_opt_in=true`; toggle per event with `td_tp_set_opt_in(tevo_event_id, bool)`. TM already covers TP's event set (same performers/cadence) so "TM everywhere TP was" needed no new TM wiring. Other platforms unaffected. (A1 2026-06-07)** · NEW low-cost discovery path: **`td_sg_discover()`/`td_sg_discover_drain()`** use TD's `/events?platform=seatgeek` (which DOES search SG by performer, unlike our search-less SG broker token) to fill `sg_event_id` for high-value unmapped TEvo performers — manual, `td_budget_ok()`-gated, no cron (mig 20260606170000). |
| `td_pull_drain` row selection | assume `resolved_at` stops a row from firing | **drain filters only `WHERE fired_at IS NULL`** — a soft-cancelled row (`resolved_at` set, `fired_at` still NULL) stays fireable and gets re-fetched (normalize then skips it = wasted upstream call + token). When soft-cancelling, set `fired_at` too; or add `AND resolved_at IS NULL` to the drain's SELECT. (A1 2026-05-29) |
| Ticketmaster TD data shape | flat priced-listing array like SH/VD/GT/TP | **TM is PRIMARY (box-office) inventory in ISMDS EventFacets shape**: `/fetch` → `body.facets[]` (`section`, `count` seats, `offers:[offerId]`) joined to `body._embedded.offer[]` (offerId → `listPrice` face / `totalPrice` w/fees). Normalizer emits one row per facet×offer. TM event **id is hex** (`1D006323F57B42E4`) while `xref.event_id` is bigint → map via `('x'\|\|lpad(id,16,'0'))::bit(64)::bigint`. `/events` returns many variants per game (Group/Premium/Pinstripe are `*`-tagged, Group uses gofevo URLs) — keep only the primary (`ticketmaster.com/.../event/<hex>`, no `*`, not parking); Knicks Finals title as `"TBD at New York Knicks"`, not `"vs."`. (A1 2026-05-29, `td_ticketmaster_platform`) |
| `event_listing_snapshot_daily` TD columns | `td_sh/gt/vd_*` only | **Now all 5 TD platforms**: `td_tp_listings/td_tp_median` + `td_tm_listings/td_tm_median` added 2026-05-29; `compute_event_listing_snapshot` aggregates SH/GT/VD/TP/TM, and `td_combined_median = LEAST()` across all five. TM medians are PRIMARY-market (face value), not resale floors — interpret accordingly. (A1 2026-05-29, mig `td_listing_metrics_tp_tm`) |
| Ticketmaster = TWO inventory pools | one TM dataset | **TM `/fetch` returns PRIMARY + RESALE in the same response**, split by each offer's `inventoryType`: `'primary'` (box-office face) vs `'resale'` (verified fan-to-fan). MLB (Yankees) is primary-only; sold-out / NBA games show resale (verified live on Spurs@Thunder WCF: 997 resale offers, all priced, med $700). Catalogued + metricized **separately**: `td_tm_listings/td_tm_median` = PRIMARY (`inventoryType<>'resale'`), `td_tm_resale_listings/td_tm_resale_median` = RESALE (`='resale'`). `td_combined_median` uses PRIMARY only (resale ≠ floor). Discriminator read from `raw->'offer'->>'inventoryType'` (no firehose column — avoids a 489MB rewrite). (A1 2026-05-29, mig `td_tm_resale_split`) |
| TEvo seat-map section names (Tevomaps overlay) | join a source's bare `section` (`"104"`) straight to the map manifest | **The seatmap manifest keys sections by FULL descriptive names** (`Lower Level Corner 104`, `Chase Bridges 316`, `Floor 2`) while every source (EVO/SG/SH/GT/VD `listings_snapshots`-style tables) stores only the trailing token (`104`). `@ticketevolution/seatmaps-client` matches `tevo_section_name` **exactly** (lowercased) → a bare-token feed colors **0** sections. Reduce both sides to a **tail** (trailing digits + ≤4-letter suffix: `"105 WC"`→`105wc`) and remap token→full name; tail collisions (`2`→`Floor 2` *and* `Event Level Suites 2`) prefer `Floor N`. Map availability per event = `venue_id`+`configuration_id` present (≈100% upcoming) AND a real CDN map (`v_broker_configurations.fanvenues_key` proxy ≈79 configs). Full detail: `docs/d0_terminal_build.md §B11`. (D0 2026-06-02, PRs #406-410) |
| `ticketsdata_event_xref.event_id` | join to a TEvo `events.id` / canonical `tevo_event_id` | **It is the PLATFORM-NATIVE event id, NOT the canonical tevo id** — GT/SH/VD/TP carry the source's own numeric id (e.g. GT `18068096`, SH `160286428`, TP `7728988`); TM is the hex→bigint. `WHERE event_id = <tevo_id>` returns **0 rows** (this silently misled a live audit). The canonical link is **`aq_short_event_id` → `aq_event_map`**; the daily metrics in `event_listing_snapshot_daily` ARE tevo-keyed, but the xref is not. (audit 2026-06-01) |
| TicketsData `/match` (cross-market resolver) | feed it any marketplace URL · use it to *discover* an SG id · batch-fire it | **`/match` resolves ONLY from a SeatGeek event URL** (`seatgeek.com/e/events/<id>`) → returns sh/vivid/tm/tp/gt ids at ~84–88 'probable' (verified live 2026-06-19). **Every other input fails**: StubHub `/x/event/` + VividSeats `/production/` bare URLs → `500 "could not resolve performer cluster"`; Ticketmaster/Gametime → `500 "invalid/unsupported marketplace URL"`; AXS → `400 "unsupported input_url"`. So `/match` only **fills** other-platform ids onto an already-SG-mapped `aq_event_map` row — it can NOT discover an SG id for an SG-absent event (use `td_sg_discover` for that). **Serialized per account** (concurrent fires → `429 retry_after 5s`; pg_net batches sends, so fire ONE at a time) and costs **12 credits + 1 scarce report/call** (charged only on HTTP 200; plan = 2,000 reports/mo). Driver: **`sg_match_map_tick()`** (cron `sg-match-map-tick` `*/10`, gated to <300 reports/mo = 50% cap via `td_match_cron_budget_ok()`, priority owned→AXS→soonest, 14-day success **and** failure cooldown). Staging: `td_match_queue`/`td_match_results`; apply via `td_match_apply(conf, p_apply)` (COALESCE-fills NULLs only, conflicts flagged). The legacy `td_match_enqueue('fill')` seeds the WRONG (SH/VD) urls, so its cron + 3 now-redundant siblings (`td_match_fill_enqueue`, `td_match_drain`, `td_match_apply_cron`, `auto_match_sg_canonical_v3_hourly`) were **DISABLED 2026-06-19 — don't re-enable**. (A1 2026-06-19) |
| `aq_event_map` rows per `tevo_event_id` | assume one map row per TEvo event | **PK is `aq_short_event_id`, so N rows can share one `tevo_event_id`** (221 events had ≥2 on 2026-06-01). Two failure modes: **(a) un-merged duplicates** — a TBD/`(If Necessary)` `aq_curated` placeholder + a later `system_seed` `SYS-*` row both resolve to the same game and are never collapsed, so platform IDs (sg/sh/vivid/tm/tp) scatter across the rows and the TD daily snapshot reads only ONE → the sibling's platforms look "missing" (e.g. Knicks Finals G3 `3346011` had TM stranded on `77QZKV6` while SG/SH/VD/TP/TM-hex sat on `SYS-9b0abcf107`); **(b) false matches** — venue+date matching with NO opponent/performer guard binds a *different* event to the tevo id (live finds: *Forrest Frank* concert→Knicks G4 `3346012`; *Salsa Spectacular*→*LA Philharmonic* `3215151`; *Braves@Giants*→*Athletics@Giants* `3100002`, +several MLB/WNBA wrong-opponent rows). **Always dedupe per `tevo_event_id` and validate opponent/performer before trusting a single row.** Note: a `23:59`/`00:00` date-only delta is usually a harmless TBD sentinel or reschedule (names match), NOT a false match — discriminate on the name, not the date. (audit 2026-06-01) · **GUARD NOW IMPLEMENTED (migs 20260601173000 + league guard): `aq_name_consistent(tevo_name, aq_name)` — token-overlap + away-side check for "X at Y" sports, fast-path for identical/substring names — was added to the two offending matchers (`resolve_aq_tevo_from_sources()`, `backfill_aq_maps()` step 2) and a one-time cleanup unbound the bad rows. `link_aq_tevo_from_events()` was already safe (exact name match). RESIDUAL (tracked in KANBAN, NOT yet fixed): same-city TBD-placeholder collisions where the away side is "TBD" and only the home-city token matches (e.g. "TBD at Minnesota Timberwolves" → a Lynx game) — needs league/team-level validation. So still dedupe + validate before trusting a row. (A1 2026-06-08)** |

---

## 4. Canonical SECDEF RPCs (the hot subset)

| RPC | Args | When to call |
|---|---|---|
| `get_broker_event_page_v2(p_event_id, p_chart_hours)` | int, int (default 720) | **D0 Phase 2a primary**. 11 payload keys incl. sales_tape/weather/espn/sg_side_by_side/splits/freshness. Email-gated `@s4kent.com`. ~185ms. |
| `get_broker_event_page(p_event_id, p_chart_hours)` | — | v1; v2 composes it for base payload |
| `get_event_chart_extended(p_event_id, p_chart_hours, p_espn_home_team, p_espn_away_team)` | int, int (default 168), text, text | **D0 chart expansion (PR #237 / mig 20260519150000)**. 5 SG-side time-series (listings_median/owned_median/listings_count/sales_median/sales_count) + 2 ESPN annotation arrays (injuries LAG(status) per athlete league-scoped + game_state LAG(status_short)). Adaptive bucket (15min..1d). Auto-resolves home/away from `espn_event_date_lookup` if not passed. Returns `sg_hidden:true` for TEvo-only events. ~308ms warm @ 7d. |
| `match_to_aq_event_id(source, src_id, name, venue, date, lat, lon, [src_venue_id])` | — | 4-tier matcher (direct id / venue+id / venue-exact / venue-fuzzy) |
| `create_system_aq_event(source, name, venue, date, src_id)` | — | SYS-md5 fallback when matcher returns NULL |
| `match_unmatched_orders_sweep(max, create_synth)` | int, bool | Cron-driven order sweep across 5 surfaces |
| `match_unmatched_listings_chunked(max_events, create_synth)` | int, bool | Listings firehose backfill (per-event chunked) |
| `bot_chat_log(level, lane, type, msg, pr, mig, in_reply_to, meta)` | — | **Standing permission**. Cross-lane coordination. |
| `bot_chat_resolve(id, level, lane, note)` | — | Standing permission. Close out a question/flag. **As of 2026-06-08 (mig 20260608032000) `v_bot_chat_unresolved` *implements* the documented status-reply auto-resolve** — a `status` reply pointing at a parent via `in_reply_to` now auto-excludes it (matches `CLAUDE.md §1`), so a `status` reply often suffices without an explicit resolve. |
| `cron_should_fire(jobname)` | text | Wrap every new cron body with this gate |
| `cron_resume_with_gate(jobname)` | text | Re-enable paused crons through the gate |
| `sg_classify_events()` | — | Refresh tier classifications in `sg_event_priority_state` |
| `sg_priority_poll_tick(max_polls)` | int | HOT/WARM polling driver |
| `espn_scoreboard_queue(lookahead_days)` | int (default **270**) | ESPN scoreboard ingest. Bumped 2026-05-16 to capture full NFL season. |
| `espn_scoreboard_process()` | — | Process ESPN responses → date_lookup |
| `refresh_sg_broker_sales_event_metrics(max_events)` | int (default 200) | Populate `seatgeek_event_metrics.sold_*` from deduped (DISTINCT ON sg_sale_id) sales snapshots. Hourly cron @ :17. |
| `sg_canonical_refresh_v2_pull(window_minutes)` | int (default 15; NULL = full) | Reconciles `sg_events_canonical.last_v2_pull_at` + `last_v2_listings_count` + `last_v2_status` + `has_v2_listings_pulled` from `seatgeek_listings_snapshots`. Cron @ :12,:42. Backfill ran 2026-05-16: 574 rows brought to 100% coverage. |
| `sg_broker_listings_process(p_limit)` / `sg_broker_sales_process(p_limit)` | int (default **50**) | **Bounded drain** (2026-05-17). Reads `sg_broker_pending` rows that have an `_http_response`, joins `aq_event_map` + `seatgeek_event_xref` once, inserts rows + marks resolved. Cron is the 1-min priority variant only (30-min duplicates unscheduled). If pendings outpace 50/min, raise the param. |
| `sweep_all_expired_pg_net_pending(ttl_hours)` | int (default 12) | Cron-driven housekeeping. Includes `sg_broker_pending` as of 2026-05-17. Marks `resolved_at = now()` for pendings where the `_http_response` row has been pruned. |
| `sg_attempt_event_xref_v3(...)` | bigint, text, date, timestamptz, text, [text], [text], [text] | **Matcher v3**: ±24h date tolerance + parking skip + `cross_source_venue_resolve` lookup. Replaces v2 in `cross_source_match_tick`. **Accept-guards (do NOT bypass):** (1) name/league consistency via `aq_name_consistent`/`aq_league_consistent` (mig 20260608194500); (2) **exact-date guard (PR #613, mig 20260619200000):** same-date candidates outrank off-date ones, and an off-date pick is **rejected** when a same-venue, name-consistent **series sibling** exists within ±3d — else the ±24h window binds the *adjacent game of a series* (same teams next day) and the existing-xref early-return never self-corrects. Lone events (no sibling) keep the ±24h timezone fallback. |
| `auto_match_sg_canonical_v3()` | — | Sweeps all unlinked SG canonical rows through matcher v3. Returns `(attempted, newly_matched, parking_skipped, still_unmatched, needs_tevo_search)`. |
| `cross_source_venue_resolve(name, city, state)` | text, [text], [text] | Returns `tevo_venue_id` from any-source venue name via 3-tier match (canonical / aliases array / prefix). Driven by `cross_source_venue_map` (391 TEvo rows + 129 SG / 94 TickPick / 85 Vivid aliases as of 2026-05-16). |
| `refresh_cross_source_venue_map()` | — | Rebuilds `cross_source_venue_map` from events/sg_events_canonical/tickpick_orders.raw/vivid_orders.raw. Idempotent. |
| `release_health_check()` | — | All-checks rollup |
| `get_event_amalgam(p_event_id)` | int | **Cross-source blended value** (mig 20260531214306). LIVE blend across all 7 sources for an event tile between the 3×/day rollups. Stored companions on `event_listing_snapshot_daily`: `amalgam_getin` (cross-source FLOOR = `LEAST` of per-source get-ins), `amalgam_median` (**count-WEIGHTED mean** of per-source medians — for premium wide markets this is legitimately ≫ the get-in floor, e.g. Knicks Finals get-in $2,853 vs amalgam_median ~$8,243; do **not** read it as a floor), `amalgam_source_count` (how many of 7 sources backed it). Also on `v_event_listing_trends` w/ DoD/WoW deltas. |
| `get_event_sg_seller_listings_full(p_event_id, p_limit)` / `get_event_sg_seller_orders_full(...)` | int, int (default 250) | **D0 "OUR SG INVENTORY" tile** (mig 20260606195432 + orders companion). Our SeatGeek SellerDirect listings/orders for an event, keyed on `tevo_event_id` (populated by `sg_seller_sync_and_map`), latest snapshot per `seller_listing_id`. Email-gated `@s4kent.com`. |
| `sg_seller_sync_and_map()` | — | **SG SellerDirect full-book pull + AQ map** (mig 20260606195118). Registers our seller events into `sg_events_canonical` (`has_seller_listings`) + backfills `seatgeek_seller_listings.tevo_event_id` from canonical. Cron `*/15`; the full ~290k-listing book is pulled cursor-paginated by `sg_seller_listings_queue` (`*/2`, rolling keyset cursor, 1 page/tick). The `/orders` side (`seatgeek_orders`) is OBSOLETE per operator directive 2026-06-06. |
| `td_sg_discover(n)` / `td_sg_discover_drain()` | int | **TD→SeatGeek event discovery** (mig 20260606170000). Uses TD `/events?platform=seatgeek` (which searches SG by performer — our SG broker token has no search endpoint) to find `sg_event_id`s for unmapped high-value TEvo performers → `sg_events_canonical` → `auto_match_sg_canonical_v3`. **MANUAL, `td_budget_ok()`-gated, no cron.** |
| `aq_tevo_search_candidates(p_limit, p_backoff_hours)` | int, int | **Non-SG AQ→TEvo cold-search selector** (mig 20260605133500). The non-SG analogue of `sg_to_tevo_search_bridge` — selects TM/Vivid/SH hub rows that carry no canonical `tevo_event_id` and were never (or stalest) searched against TEvo `/v9/events`, never-tried-first. Drained by an edge fn; writes `aq_tevo_search_attempts`. |
| `exos_queue_mail(p_template, p_ref_id)` | text, uuid (default NULL) | **D4 transactional mail** (mig 20260520160000). Server-derives `to_email` + body from the related record — no open relay. Templates: `transfer-initiated`/`transfer-claimed` (refId=transfer.id), `org-invite` (refId=invite.token), `event-cancelled`/`event-updated` (refId=ticket.id, staff only), `event-announce` (refId=event.id, followers, via `exos_announce_to_followers`), `ticket-issued` (refId=ticket.id, via `exos_queue_ticket_issued`). SECDEF + auth check. Rows land in `exos_mail` as `status='pending'`; drained by `exos-mail-drain` edge fn (deployed 2026-05-24). |
| `exos_follow_org(p_org_id)` / `exos_unfollow_org(p_org_id)` | uuid | **D4 org follows** (mig 20260520140000). Idempotent (`ON CONFLICT DO NOTHING`); `followers_count` counter updated atomically only on actual insert/delete — cannot drift. SECDEF. |
| `exos_create_org(p_name, p_slug)` | text, text | **D4 org bootstrap** (mig 20260520120000). Only path to create an org; seeds owner membership. Validates slug uniqueness. SECDEF. |

For the full RPC list + arg detail + composition relationships → the migration headers (canonical source). Note: `RESOURCES_BIBLE.md` indexes tables / views / crons / edge-fns; it has no standalone RPC inventory section.

---

## 5. Cross-source bridge — full architecture (canonical; absorbed D0_BIBLE §3, 2026-06-19)

§0 = the why + mapper-job table. The detail:

**ID namespaces** (never align — never join raw cross-source): TEvo `event_id`/`tevo_event_id` (bigint 3.0–3.4M) · SG `sg_event_id` (17M+) · TD `ticketsdata_event_xref.event_id` (platform-native 4.5M–160M) · ESPN `espn_event_id` (text) · Vivid/TickPick (own bigint). Canonical = `tevo_event_id`/`tevo_performer_id`/`tevo_venue_id`.

**`aq_short_event_id` is TWO systems:** `listings_snapshots.aq_short_event_id` = TEvo `SYS-{hex}`, **0%-pop** (query by `event_id`); `ticketsdata_event_xref.aq_short_event_id` = 7-char (e.g. `K9KX32Z`), **100%-join** to `aq_event_map`. Never join the two.

**Hub `aq_event_map`** carries `tevo/sg/sh/vivid/tm_event_id` + `venue_short_id` + `performer_short_id` + name/venue/date/city/performer. `aq_source ∈ {aq_curated, system_seed, evo_only}`; **`evo_only`** = TEvo events intentionally on no cross-source feed (residencies; tevo set, others NULL) → add `AND aq_source IS DISTINCT FROM 'evo_only'` to separate intentional-EVO-only from real gaps.

**TD→TEvo (stop at first hit):** (1) `aq_event_map.tevo_event_id`; (2) its `sg_event_id`→`sg_events_canonical.tevo_event_id`; (3) `sg_to_tevo_search_bridge` fills over days; (4) `refresh_td_event_links()` nightly; (5) text `performer+date`. Expected-NULL (don't "fix"): parking, CANCELLED, international. `tevo_match_method ∈ {aq_event_map, sg_canonical_direct, text_performer_date, pending_bridge, null_parking}`.

**Other bridges:** TEvo↔ESPN = `event_xref` (`match_events_to_espn_10min`); TEvo↔AXS = `axs_aq_match()` (±48h); venue text→`tevo_venue_id` = `cross_source_venue_resolve(name,city,state)`.

**Performer (canonical `tevo_performer_id`):** start `entity_performer_map` (espn ids, `home_venue_ids[]`, genre); `performer_metadata.espn_team_id` (fastest tevo→ESPN); `aq_performer_map` via `aq_event_map.performer_short_id`; TD performers have **no** tevo id → link via event. ⚠ scope ESPN by `espn_league` (RULE 1).

**Venue (canonical `tevo_venue_id`):** start `venue_assets` (PK; ESPN venue + NWS weather + capacity/geo in one row); `aq_venue_map` via `venue_short_id` (`sg_venue_id` ~5%); text → `cross_source_venue_resolve`.

**Orders/sales → tevo (3 idempotent cron stages):** `match_unmatched_orders_sweep()` :22 (stamp `aq_short_event_id`) → `resolve_aq_tevo_from_sources()` :35 (fill hub `tevo_event_id` from a linked source's reliable raw venue+datetime, **unique-match only**) → `backfill_order_tevo_from_aq()` :40 (derive each order's `tevo_event_id`). Plus `link_aq_tevo_from_events()` (aq rows whose TEvo event is already in `events` — exact name+venue+date±1d, unique). Cold events not in `events`: evo-search from SQL (creds in `public.settings`, HMAC-sign → `net.http_get /v9/events`). EVO is special (native `event_id` IS tevo). **Pitfall:** `match_to_aq_event_id` mis-matches on venue+date collisions — confirm performer/opponent.

**Don't rebuild (args §4):** `cross_source_venue_resolve` · `sg_attempt_event_xref_v3`/`auto_match_sg_canonical_v3` (SG→TEvo ±24h) · `refresh_td_event_links()` · `sg_to_tevo_search_bridge_30min` · `aq_tevo_search_candidates()` · `sg_seller_sync_and_map()`.

**D0 entry:** `SELECT * FROM _v_d0_event_index WHERE sg_event_id=$1;` — non-SG → `get_broker_event_page_v2($tevo_event_id,168)`. **New snapshot?** check firehoses first (`RESOURCES_BIBLE §2.2`) — likely already captured; just need a SECDEF RPC wrapper.

---

## 6. MCP tool scope — by principal, not by lane

MCP scope follows the **§2.1 principals**, not a per-lane grid (the grid *was* the permission fiction §2 now collapses — retired 2026-07-02).

| MCP family | Scope |
|---|---|
| Supabase `execute_sql` (read), `list_*`/`get_*`; Render read (list/logs/metrics); Supabase `create_branch` (copy-on-write); Slack; scheduled-tasks; GitHub | **open to every session** — reads + branch forks need no principal |
| Supabase mutation / `apply_migration`; cron `schedule`/`unschedule`; Vault; Render **write**; data-mutating edge-fn deploy | **Applier** (§2.1) — today A1 sessions |
| DB-security migrations; CI/`bin/`/`scripts/` guard code; RULE-2 guards; `cron-auth.ts` | **Auditor** (§2.1) |
| Surface edits (html/js/css/routes), migration *files*, PRs, per-task `main` push after green CI | **Builder** (§2.1) |

Any standing deviation is a dated row in **§2.2** — not a per-lane cell.

### 6a. Read-only attach → layer general-data for color commentary
On a view-only attach (Terminal Analyst, `docs/d0_terminal_analyst_skill.md`), don't stop at market SQL — also pull context for the "why" (read-only, grounded in a query): ESPN (`v_event_full_sports`, `v_espn_injuries_current`, `v_team_recent_results`), weather (`v_event_weather`, `v_event_active_weather_alerts`), social/wiki (`v_event_reddit`, `v_performer_reddit_pulse`); one-call rollup `v_event_why_context`. Augments never replaces numbers; quote exact values; flag staleness (layer is thin); never present context as a pricing decision (human-in-loop). Inventory: `RESOURCES_BIBLE`.

### 6b. End broker answers with a verified terminal link
Broker/pricing/event/performer/venue/movers/orders answers end with a link to the live terminal page; **verify it resolves** (canonical page + id resolves in our data) before citing — else say so, don't invent. Pages (prefix deployed host): `/terminal/` · `event.html?event=<tevo_event_id>` · `performer.html?performer=<tevo_performer_id>` · `venue.html?venue=<tevo_venue_id>` · `movers.html` · `discovery.html` · `orders.html`. Ids = canonical `tevo_*` (resolve via `_v_d0_event_index`/AQ hub, not source-native).

---

## 7. SQL macros (operational patterns bots use repeatedly)

### `bot_chat_log` — durable cross-lane coordination
```sql
SELECT public.bot_chat_log(
  p_level := 'data-collection', p_lane := 'A1',
  p_event_type := 'change_log',     -- change_log | question | flag | resolve_request
  p_message := 'did X. details: ...',
  p_related_pr := 154, p_related_mig := '20260516070000',
  p_in_reply_to := NULL, p_meta := NULL);
```

### Cancel-pattern SKIP (used in `sg_classify_events`)
```sql
WHERE sg_event_name ~* '(cancelled|if necessary|\(date tbd\)|^TBD at )'
```

### SG sales dedupe (mandatory — 11× duplication factor)
```sql
SELECT DISTINCT ON (sg_sale_id) *
FROM seatgeek_sales_snapshots
WHERE sg_event_id = $1
ORDER BY sg_sale_id, pulled_at DESC;
```

### Sports event gate (no `events.is_classified`)
```sql
EXISTS (SELECT 1 FROM event_xref WHERE tevo_event_id = events.id AND espn_event_id IS NOT NULL)
```

### Outdoor venue gate (no `is_outdoor`)
```sql
venue_assets.is_indoor = false  -- explicit FALSE, never NULL
```

### Cron body wrapper (always use the policy gate)
```sql
DO $body$ BEGIN
  IF NOT public.cron_should_fire('your_cron_name') THEN RETURN; END IF;
  -- work here
END $body$;
```

### Function signature changes — drop old overloads explicitly
Adding (or removing) a parameter — **even one with a `DEFAULT`** — creates a NEW overload, not a replacement. The old function survives and callers that pass no args resolve ambiguously: `function X() is not unique`. Caught twice now: A1 bot_chat 258 (`match_to_aq_event_id` 7-arg), A1 mig 20260517160004 (`sg_broker_*_process` 0-arg). Pattern:
```sql
-- before adding a parameter to existing fn, drop the prior signature
DROP FUNCTION IF EXISTS public.your_fn(text, int);     -- prior signature
CREATE OR REPLACE FUNCTION public.your_fn(p_a text, p_b int, p_new int DEFAULT 50) ...
```
If you can't predict the prior signature, query `pg_proc` for `proname` to enumerate overloads before authoring the migration.

### `LANGUAGE sql` function bodies are validated at CREATE (declare after their tables)
A `LANGUAGE sql` function body is parsed **and its table/column references validated at CREATE time** — unlike `LANGUAGE plpgsql`, whose body is deferred to first call. So a SQL-language helper that reads a table must be declared **after** that table exists in the same migration, or apply fails with `ERROR: relation "..." does not exist`. Caught in D4 mig `20260520130000`: `exos_holds_ticket()` (LANGUAGE sql) was declared before `exos_tickets` and failed apply; fixed by moving it below the table. plpgsql RPCs are immune (deferred validation), which is why they can be defined before the tables they touch.

### `sg_broker_pending` — drains via 5-min priority cron
The bounded-drain functions (`sg_broker_listings_process(p_limit=50)` / `sg_broker_sales_process(p_limit=50)`) run from the 5-min priority crons (rebased 1min→5min per mig 20260519120000). The 30-min variants were unscheduled 2026-05-17 (redundant). If you need to drain faster ad-hoc, pass a larger `p_limit`. Pending rows whose `_http_response` has been pruned (>6h old) are housekept by `sweep_all_expired_pg_net_pending` at `:20` hourly.

The bounded-FIRE functions (`sg_broker_listings_queue` / `sg_broker_sales_queue` / `sg_priority_poll_tick`) were burst-size-capped to 8/8/6 events per call per mig 20260519140000 to fit under SG's 10-req/8s quota — see the pg_net pattern macro below.

### pg_net rate-limiting pattern (burst cap, NOT pg_sleep)
```sql
-- ❌ WRONG (no-op): pg_sleep inside a loop doesn't pace pg_net's async dispatch
FOR r IN <select> LOOP
  SELECT net.http_get(...) INTO v_req;
  PERFORM pg_sleep(0.9);  -- has no effect on HTTP dispatch timing
END LOOP;

-- ✅ RIGHT: cap LIMIT to ≤ upstream token quota; let cron frequency drive throughput
-- e.g. SG quota = 10 req / 8s, so:
FOR r IN <select> ... ORDER BY ... LIMIT p_max_events  -- cap at 8 in cron caller
LOOP
  SELECT net.http_get(...) INTO v_req;  -- async-dispatched; bucket sees 8 < 10
END LOOP;
-- Then schedule cron @ */5 * * * *  (5min >> 8s reset; bucket refills between firings)
```
**Throughput math**: (burst × firings/hr) ≥ inflow_rate. SG sustained: 96 listings + 96 sales + 72 priority = 0.73 req/sec << 1.25 req/sec quota.

### Email gate inside SECDEF RPC
```sql
v_email := coalesce(auth.jwt()->>'email', '');
IF v_email NOT LIKE '%@s4kent.com' THEN
  RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
END IF;
```

### SYS-md5 hash convention (used by `create_system_aq_event` + v2 RPC fallback)
```sql
v_aq := 'SYS-' || substring(md5(name || '|' || venue || '|' ||
            to_char(date::timestamptz, 'YYYY-MM-DD"T"HH24:MI')) from 1 for 10);
```

### TEvo `/v9/events` search procedure (autotrack cold bridge)
For events we have in SG/TickPick/Vivid but missing from local `events` table — use the active search bridge instead of waiting for broker-listed events.

**Endpoint**: `GET /v9/events` (signed HMAC-SHA256, see `tevo_sign_get()`)

**Filter params (verified 2026-05-16)**:
- `venue_id` (int) — TEvo venue id; resolve from `cross_source_venue_map` via `cross_source_venue_resolve(name, city, state)`
- `name` (text, partial match) — fallback when venue_id unknown
- `performer_id` (int)
- `category_id` (int)
- `"occurs_at.gte"` / `"occurs_at.lte"` (text dates, **dotted notation required** — `occurs_at_gte` returns 422)
- `per_page` (int, max 100), `page` (int)
- `only_with_available_tickets` (bool) — set FALSE for full event lookup, TRUE for crawl-ready listings

**Two-tier search strategy** (matches edge fn `sg-to-tevo-search-bridge`):
1. Tier 1: `venue_id` + date range — most precise
2. Tier 2: `name` (team name) + date range — fallback if no venue_id resolved or empty result

**Result scoring**: `+50` venue_id match, `+40` slug venue match, `+25` prefix venue match, `+10/token` team-name overlap, `+24-hoursAway` date proximity. Accept at `score >= 50` (= venue OK + at least 1 team hit).

**Attempt tracking**: every search writes to `sg_tevo_search_attempts` (PK `sg_event_id`) with result `matched | no_results | low_score`. Don't retry within 24h.

**Live invocation pattern**:
```sql
SELECT public._cron_invoke_edge_fn(
  'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/sg-to-tevo-search-bridge?limit=40&min_score=50',
  '{}'::jsonb);
```

**Observed hit rate (2026-05-16)**: 75% on first live batch (30/40), with venue-map-resolved candidates scoring 64–214.

---

## 8. Workflow recipes

> Recipes are becoming executable **workflow skills** (`.claude-plugins/terminal2-governance/skills/<name>/`, surfaced by the PreToolUse `skill_router.py`, `CLAUDE.md §5`). Shipped: **`ship-a-migration`**. Procedures → skills, facts → bibles; don't duplicate.

### "Understand the codebase fast (code knowledge graph)"
Interactive repo graph (Understand-Anything plugin; ~1,900 nodes / 3,500 edges / 17 layers, 0 orphans, incl. code→data `reads_from`/`writes_to`).
- **View (no toolchain):** open `.understand-anything/knowledge-graph-chart.html` in a browser (committed alongside `knowledge-graph.json`).
- **Freshness:** `node bin/graph-drift.mjs` (`--check` exits nonzero on drift) → lists files added/removed since snapshot; fold additions in + refresh `project.gitCommitHash`.
- **Regenerate:** `/understand` rebuilds (replaces hand-curated cross-layer edges — prefer incremental fold-in); `/understand-dashboard` explores. Graph JSON + chart + `meta.json` committed; scratch gitignored (scoped `.gitleaks.toml` allowlist).

### "I want to author a migration"
> **Executable form: the `ship-a-migration` skill** (`.claude-plugins/terminal2-governance/skills/ship-a-migration/`) runs these steps with checkpoints + a verification gate; editing a migration file or calling `apply_migration` auto-surfaces it. The `/new-migration` command scaffolds the file (step 3).
1. Read §3 landmines FIRST before writing column names
2. Test query shape on 5-10 sample rows via `execute_sql` (read-only)
3. Write `supabase/migrations/YYYYMMDDHHMMSS_descriptive_name.sql` per `MIGRATION_CONVENTIONS.md`
4. **Ask operator permission** via `AskUserQuestion` before `apply_migration`
5. Apply via MCP `apply_migration`
6. Verify post-apply on same 5-10 samples
7. Update header `## Already applied to prod  Applied via MCP YYYY-MM-DD`
8. Commit + push + open PR (A1 only pushes to main)

### "I want to wire a UI panel"
1. D0: call `supabase.rpc('get_broker_event_page_v2', {p_event_id, p_chart_hours})`
2. Branch on `data.bridge_ids.sg_event_id IS NULL` → render TEvo-only state
3. Branch on `data.weather.hidden=true` → hide weather strip
4. Branch on `data.espn.hidden=true` → hide ESPN panel
5. `data.sales_tape` is pre-deduped + capped at 20 rows
6. `data.freshness.*_latest` for per-source freshness chips

### "I want to flag a cross-lane issue"
```sql
SELECT public.bot_chat_log(
  p_level := 'data-collection', p_lane := 'D0', p_event_type := 'question',
  p_message := 'D1: add my Render origin to CORS_ALLOWED_ORIGINS', ...);
```

### "I want to spawn a cron"
1. Author the underlying SQL fn
2. Wrap body with `cron_should_fire('jobname')` gate
3. INSERT row in `cron_policy` with limits + work_check_sql
4. `cron.schedule('jobname', '*/X * * * *', $body$ ... $body$)`
5. Verify firings via `cron.job_run_details` + `cron_gate_decisions`

### "I am D4 — how do I call a write RPC?"
All D4 mutations go through SECURITY DEFINER RPCs — **never raw `.insert()`/`.update()` on base tables** (anon-EXECUTE revoked on all 10 write-path RPCs; mig 20260520230000). Authenticated callers invoke via `supabase.rpc()`.
```typescript
// ✅ Correct — SECDEF RPC (requires authenticated Supabase session)
const { data, error } = await supabase.rpc('exos_create_org', {
  p_name: 'My Org', p_slug: 'my-org', p_description: null,
});

// ❌ Wrong — authenticated base-table writes are REVOKED on write tables
await supabase.from('exos_orgs').insert({ name: 'My Org' });
```
**Available write RPCs** (migs 20260520120000 + 20260520130000):
| RPC | Purpose |
|---|---|
| `exos_create_org(p_name, p_slug, p_description)` | Bootstrap org + auto-profile + add caller as owner |
| `exos_claim_invite(p_invite_id uuid)` | Accept an org invite (joins org at invited role) |
| `exos_mint_tickets(p_tier_id, p_qty, p_buyer_profile_id)` | Staff/admin comp-ticket path — enforces tier cap + event cap + purchase limit (mig 20260523180000); admin bypasses all |
| `exos_check_in_ticket(p_ticket_id, p_event_id, p_barcode_payload, p_secret)` | Scan-in — 4-arg (mig 20260523160000): server HMAC verify + ±2-bucket tolerance via `extensions.hmac()`. Atomic double-scan guard → `exos_scan_rejects` |
| `exos_create_transfer(p_ticket_id, p_recipient_email)` | Initiate ticket transfer |
| `exos_cancel_transfer(p_transfer_id uuid)` | Cancel pending transfer |
| `exos_claim_transfer(p_transfer_id uuid)` | Recipient accepts transfer |
| `exos_void_ticket(p_ticket_id uuid, p_reason text)` | Void ticket (admin/staff) |
| `exos_assert_purchase_limit(p_event_id, p_buyer, p_qty)` | Pre-check purchase limit (raises on breach) — call before mint in paid path |
| `exos_queue_ticket_issued(p_ticket_id uuid)` | Queue `ticket-issued` confirmation mail to ticket owner (mig 20260523210000) |
| `exos_notify_event_holders(p_event_id uuid, p_template text)` | Bulk-queue `event-cancelled`/`event-updated` to all non-voided holders (staff/admin) |
| `exos_issue_ticket_to_email(p_event_id, p_tier_id, p_recipient_email, p_qty, p_order_ref)` | Look up/create user by email → mint tickets → queue confirmation. Idempotent on `order_ref` |
| `exos_redeem_discount_code(p_event_id uuid, p_code text)` | Validate promo/access code → `{valid, type, value, unlocks_tier_ids, remaining}` (read-only; consumption at mint) |
| `exos_announce_to_followers(p_event_id uuid)` | Bulk-queue `event-announce` to all org followers (staff/admin, published events only) |

**Read access**: `lib/events.ts`, `lib/orgs.ts`, `lib/tickets.ts` read the base tables directly (RLS enforces own-org scoping). Public/cross-org reads go through `exos_public_*` VIEWs (anon + authenticated).

**Auth pattern**: `supabase.auth.signInWithOtp()` / `supabase.auth.signInWithOAuth()` — NOT Firebase Auth. Session persists via `localStorage` (configured in `lib/supabase.ts`).

---

## 9. Recent landmark migrations → see `MIGRATION_CONVENTIONS.md §14`

> **Moved (2026-05-28).** The hand-curated landmark-migration log ("don't re-do shipped work") now lives in **`MIGRATION_CONVENTIONS.md §14`** — the natural home for migration provenance, and the single source of truth. Auto-generated release notes live in `CHANGELOG.md` (release-please-owned — do NOT hand-edit). This playbook no longer duplicates the log; **before authoring any migration, check `MIGRATION_CONVENTIONS.md §14` to avoid re-shipping work.**

---

## 10. Drift watchlist → see `KANBAN.md`

> **Moved (2026-05-28).** Open drift / gaps now live in **`KANBAN.md`** — the single source of truth for "what's open right now": actionable items in **§🟢 OPEN WORK** (severity-sorted), durable shape-of-the-data workarounds under **"Known data-architecture gaps (don't rediscover)"**. Resolved/shipped fixes are recorded in `MIGRATION_CONVENTIONS.md §14` + `CHANGELOG.md`. **Before treating a "discovery" as new, check KANBAN** — it's probably a known gap with a standing workaround.

---

## 11. Self-check before any task

1. ☐ Did I read this playbook (§0-§11)?
2. ☐ Is my action covered by §1 hard rules?
3. ☐ Am I editing files in my own lane (§2)?
4. ☐ Did I verify schema column names against §3 landmines?
5. ☐ For mutations: did I ask operator permission?
6. ☐ For new crons: did I wrap with `cron_should_fire`?
7. ☐ For cross-lane work: did I `bot_chat_log` a question?
8. ☐ Is my work already shipped per `MIGRATION_CONVENTIONS.md §14` (don't re-do)?
9. ☐ Is my "discovery" a known gap in `KANBAN.md` (don't waste cycles)?
10. ☐ **About to create a new doc?** STOP — the canonical doc set is CLOSED (see the README registry). Add the fact to its owning doc; never create a new root/governance `.md`; never state one fact in two places — link instead.
11. ☐ **Am I working in my own worktree, not the shared root?** A `git checkout`/branch-switch in the shared clone strands other sessions (§1 rule 9) — use `git -C <your-worktree>` on a per-session branch.
12. ☐ **Did I add a NEW catalogued resource** (service/secret/table/view/RPC/cron/edge-fn) or a new column landmine? If so, update the owning doc this PR (§1 rule 10). Routine changes need no doc edit — judgment, not a gate.

If YES to all → proceed. Else fall back to `RESOURCES_BIBLE.md` for inventory or `CLAUDE.md` for security rules.

---

**Refresh policy**: A1 updates this playbook when (a) new canonical RPC ships, (b) hard rule changes, (c) column-name landmine discovered, (d) landmark migration lands. Inventory deltas go in `RESOURCES_BIBLE.md`. Don't edit without A1 review (drift prevention).
