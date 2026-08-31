# KANBAN.md — Terminal-2 shared work board

> **Doc version:** v1.73.0 (2026-08-31) — refreshed the CURRENT PRIORITIES banner to the live focus (D0 **DEALS / GoTickets**, shipped 2026-08-10/11); filed **A1-OPS-32** (prod GT cron topology + `gt_deals_retire_tick()` exist in no committed migration) and **D0-DEALS-1** (the quantity-band fast-follow the realized-median-v2 migration declares). · v1.72.0 (2026-07-09) — added A1-OPS-30 (our SG SellerDirect sales ingest-dark: webhook undeployed + its idempotency-table mig unapplied + orders cron off) + A1-OPS-31 (SeatGeek primary inventory is unobservable via the resale-only broker feed — a new SG consumer/v2 pull would be needed to surface SG face-value availability on the discovery chart, which today uses AXS+TM only). · v1.71.0 (2026-07-08) — added A1-OPS-29 (movers-agg windows outgrew per-statement budgets; 2700s cron stopgap applied mig 20260708164500, fast-by-construction rewrite queued). · v1.70.0 (2026-07-03) — added the UNMERGED BRANCH INVENTORY section: a full 2026-07-03 sweep of all 60 remote branches (ahead-of-main + last commit) for triage/reconcile. · v1.69.0 (2026-07-02) — latest: added A1-OPS-28 (engines-without-ignition + doc-drift audit sweep parked for later analysis); v1.68.0 — added A1-OPS-27 (Bands in Town tour-tracking client shipped PR #693; unwired backlog + `core/instagram_share.py` removal candidate). Board is append-only; full prior doc-version history → [`docs/archive/2026-07-02-doc-version-history.md`](docs/archive/2026-07-02-doc-version-history.md). Convention → [`README.md`](README.md) *Doc-writing rules*.

> **One source of truth for what's next, who's on it, and what just shipped.**
>
> - **code** owns: backend (Python, SQL, edge functions), audits, git push.
> - **design** owns: frontend (`static/*.html`, `design/*`), ships via code's proxy.
>
> **Update protocol**: append rows; don't edit other rows in place. Newest activity at the top of each column. Use the date format `YYYY-MM-DD HH:MM` (UTC).
>
> Status flow: `NEXT → DOING → BLOCKED (if stuck) → DONE`. When a NEXT row gets started, MOVE it (don't duplicate). When a DOING row ships, MOVE it to DONE with the commit SHA.

---

## 🎯 CURRENT PRIORITIES

**This banner is the single home for priority/focus** (moved out of `PROJECT_BIBLE §2` on 2026-07-02 — the bible holds invariants, KANBAN holds focus; status in a versioned doc is guaranteed to go stale). Keep it short and current; detail lives in 🟢 OPEN WORK below.

- **★ Focus:** D0 terminal, and within it the **DEALS / GoTickets buy-side engine** — the whole 2026-08-10/11 push (GT Pro-API listings ingest → section-outlier detection → realized-median-v2 calibration → the live `get_deals_feed` on `static/terminal/deals.html`). Architecture + gates: `RESOURCES_BIBLE §2.17`; the traps it cost us: `PROJECT_BIBLE §3`. **Before touching the GT crons, read `A1-OPS-32`** — prod's job topology is ahead of the migrations. D1–D6 are lower-priority right now, *not* "paused" as a permission state — any session may still build on them (permission is per-action, `PROJECT_BIBLE §2.1`); this is a focus call, not a lockout.
- Severity-sorted actionable work for every lane is in 🟢 OPEN WORK. Update this banner when the focus shifts.

---

## 🌿 UNMERGED BRANCH INVENTORY (2026-07-03 sweep)

All 60 remote branches, `ahead`-of-`main` + last commit. **Triage:** low-ahead + recent → merge-or-close soon; **500+ ahead (long-diverged, mostly June)** → reconcile-or-archive (either main moved past them or they never landed); ⭐ = overlaps active pricing / TicketsData / injury / cast-pool work. Infra branches (`release-please*`, `gh-pages`) are automation — leave.

| Branch | Ahead | Last | Subject / note |
|---|---|---|---|
| `claude/inventory-pricing-analysis-8gtzfc` | 2 | 07-03 | cast_price_ref migration + this A1-doc sweep — **this session, PR #784** |
| ⭐ `claude/espn-injury-updates-news-wire-vk7ear` | 2 | 07-03 | ESPN injury + news-wire build **and** the A1-gatekeeper doc retirement (dup of PR #784's doc fix) |
| ⭐ `claude/us-open-events-td-poll-0nwtgp` | 4 | 07-03 | td/sg: capture `sg_url` in `td_sg_discover_drain` — active TicketsData work |
| `claude/code-breakdown-e9blb4` | 4 | 07-03 | docs: de-drift `d0_terminal_build.md` (app.py→server.py) |
| `claude/d4-html-improvements-i9m4ye` | 2 | 07-03 | d4: per-artist social + streaming links |
| `claude/standard-git-licenses-20f2es` | 1 | 07-03 | license files (proprietary root + MIT carve-out) |
| `claude/html-visual-charts-fp404m` | 1 | 07-03 | D0 terminal: unified per-source chart color ramp |
| `release-please--branches--main` | 1 | 07-03 | chore(main): release 1.0.0 — **infra** |
| `release-please--branches--main--release-notes` | 1 | 07-03 | release notes — **infra** |
| `claude/c1-checkpoint-2026-07-01` | 59 | 07-01 | c1 daily checkpoint |
| `claude/project-code-review-crycl5` | 48 | 06-25 | consolidate read-only client HTTP transport + dead-code sweep |
| `claude/funny-cannon-jvx3j7` | 53 | 06-22 | fix(d0): drop duplicate 🔔 Alerts tab |
| `claude/sleepy-hypatia-vl9vmj` | 26 | 06-20 | feat(store): lowest-price anchor |
| `claude/practical-turing-1p7i9u` | 26 | 06-20 | feat(d0): alerts feed panel on home hub |
| `claude/c1-checkpoint-2026-06-20` | 24 | 06-20 | c1 daily checkpoint |
| `claude/affectionate-curie-khk4lm` | 22 | 06-20 | D0: unmapped-section tracker + manual venue-map |
| `claude/exciting-rubin-0pzd1k` | 18 | 06-20 | feat(d4): category + date browse filters |
| `claude/store-tour-guard` | 2 | 06-20 | fix(store): tour-package graceful degrade |
| `gh-pages` | 1 | 06-15 | static hub preview — **infra** |
| `claude/pwa-friendly-pages-ojccwm` | 828 | 06-19 | feat(d0): surface `cur_tix` in v2 movers table |
| `claude/code-update-maintenance-plan-t6xzgt` | 817 | 06-19 | feat(governance): lane agents as scoped subagents |
| `claude/retail-chat-cost-guards` | 816 | 06-19 | retail-chat cost guard (kill switch + caps) |
| `claude/c1-daily-checkpoint-terminal-2-4defa7` | 816 | 06-19 | c1 checkpoint |
| `claude/vibrant-ptolemy-7kmg2j` | 815 | 06-17 | fix(skills): ship-a-migration link |
| `claude/hourly-auto-checks-y0wsdb` | 815 | 06-17 | hourly §5 aging-sweep auto-checks (A1-OPS-26) |
| `claude/d0-home-page-updates-xk8car` | 815 | 06-17 | D0 home: watchlist + Top-50 exclusions |
| ⭐ `claude/sports-player-search-9nnrcz` | 811 | 06-17 | unify performers + players — overlaps cast-pool/Trends |
| `claude/practical-albattani-5am7e7` | 810 | 06-17 | health monitor cron + uptime dashboard |
| `claude/sweet-archimedes-7k9o57` | 809 | 06-16 | fix(security): gitleaksignore self-reference |
| `claude/eager-volta-vkvm5r` | 809 | 06-16 | terminal: exclude EVO-owned from SG chart |
| `claude/c1-checkpoint-2026-06-16` | 809 | 06-17 | c1 checkpoint |
| `claude/vigilant-hamilton-53kqtm` | 808 | 06-16 | ci: exos migrations on real Postgres |
| `claude/fix-d4-vite8-manualchunks` | 808 | 06-16 | fix(d4): Vite 8 manualChunks |
| `claude/elegant-curie-qx2s5k` | 808 | 06-17 | D4 exos parity build backlog |
| ⭐ `claude/exciting-noether-2zq7st` | 796 | 06-16 | fix(td): `td_match_apply` ambiguous id; re-enable cron |
| `claude/lucid-mccarthy-6pglsf` | 781 | 06-11 | fix(d4): secure standalone-server |
| `claude/c1-checkpoint-2026-06-08` | 771 | 06-10 | c1 checkpoint (merge main) |
| `claude/c1-checkpoint-2026-06-10` | 770 | 06-10 | c1 checkpoint |
| `claude/epic-turing-w89nn4` | 730 | 06-09 | Render blueprint for open-notebook |
| ⭐ `claude/store-follow-tour` | 724 | 06-09 | store: away vs home games split — overlaps cast_price_ref away-median |
| `feat/render-deploy-webhook-bridge` | 721 | 06-08 | feat(d0/ops): Render deploy-webhook → Actions bridge |
| `claude/store-tour-agent` | 709 | 06-08 | tour-agent: auto-select tickets by budget/qty |
| `claude/funny-ride-wx3m1b` | 699 | 06-08 | kanban: D0-FANTASY-1 caveats |
| `claude/kind-gates-zgLmb` | 646 | 06-06 | d0/home: self-correcting reveal-pull |
| `claude/beautiful-albattani-P0JXz` | 634 | 06-04 | d0/event: alert mail own queue |
| `claude/nyc-budget-chatbot-test-aDGum` | 631 | 06-04 | fix(d0): dedupe `v_canonical_performer` |
| `claude/bold-ride-XLP9H` | 629 | 06-05 | notifications: daily watchlist email |
| `claude/d0-aq-tevo-bridge` | 603 | 06-02 | resources-bible edge-fn reconcile |
| `claude/compassionate-hopper-aFNWL` | 603 | 06-01 | sec: pin search_path on `aq_league_consistent` |
| ⭐ `claude/great-albattani-pezXQ` | 602 | 06-01 | SG listings poller — soonest-event-first |
| ⭐ `claude/hopeful-gauss-SQ8iF` | 600 | 06-01 | fix SG bridge candidate-selection starvation |
| ⭐ `claude/resume-d0-chat-itUGb` | 547 | 05-27 | **TicketsData ingestion foundation** — snapshots + xref + credits |
| `claude/d4-comprehensive-testing-wPECJ` | 547 | 05-26 | d4: Stripe checkout (dormant) + capacity |
| `claude/d0-deploy-2026-05-27` | 546 | 05-27 | audit: CRON_SECRET / seatdata guard fixes |
| ⭐ `claude/optimistic-brahmagupta-DKiSl` | 542 | 05-27 | drop dead `td_enqueue_peak` overload |
| `claude/nice-fermi-UOpKo` | 542 | 05-27 | SeatDataClient vault creds |
| `claude/featured-section-events-pV5kM` | 542 | 05-26 | featured rail: playoff + soonest fallback |
| ⭐ `a1/ticketsdata-integration` | 542 | 05-27 | **activate GT + peak crons + retention** — the TD tracking work |
| ⭐ `a1/optimize-zone-section-metrics` | 540 | 05-26 | dedupe zone lookups in section_metrics — pricing tables |

**Recommended triage:** (1) the four **07-03 branches** (`espn-injury…`, `us-open…td-poll`, `code-breakdown`, `d4-html`) are current — review/merge or close. (2) `espn-injury…` duplicates PR #784's doc fix — reconcile so they don't both land. (3) The **500+ ahead cluster** is the real debt: dozens of June branches that never merged — a dedicated reconcile-or-archive pass is needed (several, e.g. `resume-d0-chat` + `a1/ticketsdata-integration`, are TicketsData foundations that predate any fresh build).

---

## 🟢 OPEN WORK — live operating ledger (all lanes)

**This is the single-source-of-truth for "what's open right now" across all bots.** Each row is one piece of currently-actionable work with the smallest action that closes it.

### Closure protocol

1. **Fixing bot DELETES its row** from this section in the same PR as the fix. Row's absence IS the closure signal. The historical detail (with `✅ CLOSED by PR #N` markers) flows to the §Archive sections below — that record is preserved.
2. **Mid-work**: replace your row with `[IN PROGRESS by <lane>, PR #<n>]` so other bots' sweeps don't double-file.
3. **Populate as you go**: anyone can add rows. B1 populates security findings; each lane populates its own ops/product work; A1 populates governance/cross-cutting.
4. **For deep context** on any row's history, search the §Archive sections below by ID — the original entry has full rationale + originating PR.
5. **Severity ordering**: rows sorted by `SEC-CRIT → SEC-HIGH → SEC-MED → SEC-LOW → OPS-*` (operational priority within sev). Operator-only items in their own table at the bottom.

### Lane shorthand

Lane codes are **identifiers for regions of the ownership map** (which surface), not ranks or a chain of command — no lane sits "under" another (hierarchy dissolved 2026-07-02, `PROJECT_BIBLE §2`). Permission is per-action (`§2.1`).

| Code | Lane (surface region) | Primary write surface |
|---|---|---|
| `A1` | Data plane (substrate) | `supabase/migrations/*`, ingest pipeline, cross-source xref, cross-cutting |
| `B1` | Build + guards + governance (substrate) | CI/guards, `*_security_*.sql`, tests, **and the docs surface** — bibles + registry + `bot_chat` + this ledger (absorbed C1 2026-07-02; the Auditor surface) |
| `D0` | Terminal + orders dashboard (product) | `static/terminal/*`, `/api/broker/*`, `d2_dashboard/*` |
| `D1` | Storefront (product) | `static/store/*`, `/api/store/*` |
| `D3` | Broadway (product) | `broadway_*` |
| `D4` | Exos/Bridge (product) | `d4_bridge/*`, `exos_*` schema |
| `C1` | *(retired 2026-07-02 → B1)* | docs governance = Auditor work; folded into B1 |
| `D2` | *(retired 2026-07-02 → D0)* | orders dashboard, broker-facing; folded into D0 |
| `E1` | *(folded 2026-06-17 → A1)* | — |
| `Op` | Operator-only | settings, lockdown-gated applies |

### 🔴 URGENT — Bottleneck remediation (filed 2026-06-19, operator-directed research sweep)

Prioritized program from the 2026-06-19 cross-axis bottleneck audit (code · data · infra). **Conclusion: the binding constraints are data-plane physics + architecture debt, NOT feature bloat** (1 TODO in the whole tree, near-zero dead code). Work top-down. Rows that already exist elsewhere are **linked, not restated** (one fact, one home). Full evidence narrative archived at `docs/archive/2026-06-19-bottleneck-research.md`.

| Prio | ID | Lane | Bottleneck | Smallest next action |
|---|---|---|---|---|
| **P0** | → `A1-OPS-3` | A1 / Op | **SG broker token is the #1 product ceiling** — one token shared with an invisible external prod program; 63–77% 429, 1,235 starved events, 10/30 MLB games 2–3d stale. Physics limit, not code. **⏸ SG token-consumer crons PAUSED 2026-06-19 (operator-directed): 6 jobs `active=false` (355/248/64/63/381/407) — see `docs/archive/2026-06-19-snapshot-bloat-play.md` for the list + resume SQL.** | See `A1-OPS-3` (OPS table). **Operator action:** coordinate SG token isolation from the external app; then resume the 6 paused crons. |
| **P0** | → `A1-OPS-16..21` | A1 / Op | **Firehose analysis SPEED** (operator reframe 2026-06-19: speed, not disk — disk is cheap). `listings_snapshots` 48GB/123M with **22GB bloated indexes** (415M deletes churn them); `min(captured_at)` **times out at 25s**. Pre-agg layer is ~200× smaller (`latest_event_metrics` 20MB). | **Speed play: `docs/archive/2026-06-19-snapshot-bloat-play.md` §Speed solution** — 4 pillars: (1) route analysis to pre-agg layer (SOP) + **guardrails AUTHORED `20260619210000_analysis_speed_guardrails.sql`** (`listings_snapshots_recent` 30d view that prunes via `idx_listings_captured` + a bounded `analyst_ro` role @30s timeout — service_role is left untouched because its ingest crons legitimately run up to 565s, so no single role-timeout separates them) → (2) **drop dead indexes — migration AUTHORED `20260619200000_drop_dead_firehose_indexes.sql`, operator-apply** → (3) `REINDEX CONCURRENTLY` hot indexes → (4) partition by `captured_at` (pruning + DROP-PARTITION retention = no re-bloat) — **runbook AUTHORED `20260619220000_partition_listings_snapshots_BLUEPRINT.sql`** (attach-existing-as-historical-partition = no 123M-row copy; stage-gated, needs maint window + a partition-maker cron). Plus espn `pg_repack`+autovac tune. **APPLIED 2026-06-19 (operator "do it"):** pillar-1 guardrails migration applied (2 `*_recent` views + `analyst_ro` role live; role still needs an out-of-band `LOGIN PASSWORD` + conn repoint); pillar-2 index drops **4 of 6 applied** (~227 MB: the SG-table + sg/sales price-change indexes), **2 blocked** on listings_snapshots by A1-OPS-24's stuck txn. Pillars 3–4 (REINDEX, partition) still pending. |
| **P0** | `A1-OPS-24` | A1 / Op [⏳ TERMINATED, cron-fix pending] | **🚩 Runaway 3-day transaction = a live root cause of the bloat/speed problem. TERMINATED 2026-06-19 (operator "terminate now") — `pg_terminate_backend` on the 2d23h backend; 0 txns >1h remain, vacuum horizon released.** But the cron immediately re-fired; new runs now self-cap at 5min (`SET LOCAL statement_timeout='5min'`) yet still hold AccessShareLock on listings_snapshots during each run, cycling-delaying the final removal of the last 2 (already-invalid) index drops. **Operator owns the cron fix** (chunk-and-commit so it never holds one long txn). Original detail:** A `midnight-catchup-sweep` cron txn (pid varies; `backfill_stale_zone_metrics` loop) has been ACTIVE ~3 days (`pg_stat_statements` max 269,549,901 ms ≈74h), holding `AccessShareLock` on `listings_snapshots` + writing `zone_metrics`/`section_metrics`. Its 3-day-old xmin **pins the vacuum horizon** → autovacuum runs but can't reclaim (listings 6.3M dead, espn **613k dead : 36k live = 17:1**) → the exact index bloat the speed program is fighting **regenerates faster than it's removed**. Also blocks any `ACCESS EXCLUSIVE` on listings_snapshots (the 2 remaining index drops, REINDEX, partition cutover). | **Operator decision (hard-to-reverse, NOT auto-done):** terminate it — `SELECT pg_terminate_backend(<pid>)` (find via `pg_stat_activity WHERE query ILIKE '%midnight-catchup-sweep%'`) — which rolls back ~3 days of zone-metrics backfill, then **fix the cron** so it can't run unbounded (add a `SET LOCAL statement_timeout`/`cron_should_fire` self-cap + chunk-and-commit instead of one giant txn). After it clears: finish the 2 listings_snapshots index drops + run the REINDEX/partition work that needs the table lock. |
| **P1** | **BR-CODE-1** | D0 / A1 / Op [IN PROGRESS] | **`server.py` (ex-app.py) monolith — 8,753 LOC, 112 routes, 236 fns, 302 inline SQL calls, ALL surfaces in one file** (5 fns >220 lines). #1 velocity drag; every route re-writes the same filter chains, no DB-access layer. | Carve out a `routers/` package by domain (broker · store · seatgeek · seatdata · axs · admin) + a thin shared `db`/query helper; move routes incrementally behind unchanged paths. Land in small PRs, tests green each step. **Slice 1 (done):** `routers/` package + `routers/site_essentials.py` (robots/sitemap/favicon, factory takes deploy base URL). **Slice 2 (done):** `routers/catalog.py` — TEvo performer/venue/configuration detail passthroughs (live `client` getter + `require_auth`). **Slice 3 (done):** `routers/lists.py` — `/api/watchlist` GET + `/api/runs` + `/api/snapshots/latest|velocity` (live `require_sb` getter + `require_auth`; watchlist POST/DELETE stay in app.py; covered by `test_watchlist_runs_snapshots.py`). **Slice 4 (done):** `core/config.py` — env-derived config out of app.py bootstrap. **Slice 5 (done):** `core/auth.py` — the security-critical **`require_auth` gate + `AUTH_DISABLED` kill-switch + `_is_production`** moved out of app.py (verbatim); app.py re-exports them (`app.require_auth is core.auth.require_auth`); only the security test's `AUTH_DISABLED` monkeypatch repointed to `core.auth` (the `requests` stub hits the shared module, unchanged). Security suite 6/6 + 122 route net = 128 green. **Slice 6 (done):** `/api/events` → `routers/catalog.py`. **Slice 7 (done):** `routers/seatdata.py` (5 SeatData reads). **Slice 8 (done):** `routers/axs.py` (4 AXS reads). **Slice 9 (done):** `routers/seatgeek.py` (6 SG reads). **Slice 10 (done):** `routers/misc.py` (config + cross-source). **Slice 11 (done):** `routers/broker.py` (3 simple broker routes). **Slice 12 (done — helper pass begins):** `core/helpers.py` (pure `delta`/`listings_cadence_seconds`, app.py imports aliased) + moved `/event/{id}/cadences` to `routers/broker.py` (+test). app.py 8753→8143 (8 routers + core/{config,auth,helpers}). **Slice 13 (done 2026-06-25):** `routers/shares.py` — the 4 `/api/store/share*` JSON routes (create/resolve/revoke/list) lifted verbatim behind unchanged paths; getters resolve live `require_sb`/`_resolve_event_with_filters` so the ownership-audit tests still bind; covered by `test_store_shares.py` + `test_app_store_c_full.py`, 100% line+branch held. app.py now ~6489 LOC (the `/s/{id}` + `/shares` HTML page routes intentionally stay in app.py). **Slice 14 (done 2026-06-25):** `routers/seatmap.py` — the 3 `/api/store/seatmap/*` routes (manifest/svg/section-map) + the private `_fetch_tevo_seatmap_file` helper; `get_sb` getter binds the live `app.sb`, moved helper uses the shared `requests` module (tests stub `app.requests.get`); covered by `test_store_seatmap.py` + `test_app_store_b_full.py`, 100% held. app.py → ~6373 LOC. **Slice 15 (done 2026-06-26):** `routers/retail_chat.py` — the 2 `/api/(store/)retail-chat` routes + their retail-chat-only helpers (`_client_ip`/`_sanitize_chat_history`/`_proxy_retail_chat`) + the transcript constants/offline-reply; server.py re-exports the constants+helpers (core/auth-style compat shim) so `app_module._RETAIL_CHAT_MAX_*`/`_CONCIERGE_OFFLINE_REPLY`/`_client_ip`/`_sanitize_chat_history` still resolve; concierge flag read via getter; covered by `test_retail_chat.py` + `test_app_store_c_full.py`, 100% held. server.py → ~6284 LOC (also renamed from app.py this session). **Slice 16 (done 2026-06-26 — core/ helper pass begins for the store block):** `core/store_events.py` — the two leaf SQL-only DB-read helpers (`fetch_event_from_db`, `fetch_owned_ticket_groups_from_db`) moved out; server.py keeps thin `(event_id)` wrappers that pass the live `require_sb` so call sites + the direct branch-test call still bind; 100% held. First of the shared-helper-to-core moves that must precede lifting the `/api/store/*` routes (`_resolve_event_with_filters` is the remaining keystone — still in server.py, HIGH-blast-radius). **Slice 17 (done 2026-06-26):** two more leaf helpers to `core/store_events.py` — `build_zone_resolver` (sb-injected) + `fetch_owned_ticket_groups` (sb+client-injected); server.py keeps signature-preserving wrappers passing the live globals; direct branch/store-b test calls + 100% held. Only `_resolve_event_with_filters` itself now remains before the store routes can lift. **Slice 18 (done 2026-06-26 — KEYSTONE):** `_resolve_event_with_filters` (the ~340-line store event-detail composer) moved to `core/store_events.py` as `resolve_event_with_filters`. Its patchable collaborators (the 4 fetch_*/build_zone_resolver + bulk_performer_assets/bulk_event_context) are INJECTED as params so the server-side monkeypatches still intercept; pure helpers (clean_opt_url/normalize_filters/section_sort_key/ticket_group_to_listing/tevo_runtime_to_http) imported directly; sb/client/STOREFRONT_SQL_ONLY/_fire_canonical_refresh injected via the signature-preserving server wrapper. First attempt (calling core helpers directly) broke 4 tests that patch the server aliases — caught by the 100% suite, re-done with injection. server.py → ~5779 LOC. The `/api/store/*` event-detail routes are now unblocked to lift into a router. **Slice 19 (done 2026-06-26 — first post-keystone lift):** `routers/store.py` — `/api/store/events/{id}` (+`/zones`) lifted behind unchanged paths; getters bind `require_sb`/`_resolve_event_with_filters`/`STOREFRONT_PREFER_INTERNAL_ZONES`; `_GRANULAR_LAYER_ZONE_COUNT_THRESHOLD` + `is_bowl_pattern_name` moved/imported. Proves the keystone unblock. server.py → ~5640 LOC. **Slice 20 (done 2026-06-26):** `/api/store/concierge` lifted into `routers/store.py` (clean — `get_require_sb` + `or_ilike_clause` from core.helpers; the `app._or_ilike_clause` tests hit the unmoved server alias). **Slice 21 (done 2026-06-26):** the 4 store trip-planner delegate routes (`/performers/{id}/trip-plan|tour-package`, `/tours/multi|near`) lifted into `routers/store.py` (thin delegates; payload builders stay in server.py shared with the D0 broker routes, passed via getters). **Slice 22 (done 2026-06-26):** the 4 storefront discovery routes (`/api/store/search` · `/movers` · `/home` · `/events/near`) lifted into `routers/store.py` — 15 discovery getters bind the live in-process caches (`_search_cache`/`_movers_cache`/`_MOVERS_CACHE_REFRESHING`) + the heavy helpers (`_search_cache_get/put`/`_search_players`/`_search_live`/`_attach_owned_metadata`/`_refresh_movers`/`_compute_movers`/`_bulk_performer_assets`) which stay in server.py so the route tests' monkeypatch keeps binding; **route-order gotcha fixed** — `/api/store/events/near` must be declared before the `/api/store/events/{event_id}` catch-all (Starlette matches in definition order, else "near" 422s coercing to an int path-param). server.py → ~5083 LOC, 100% line+branch held. The full `/api/store/*` API surface now lives in `routers/store.py`. **Slice 23 (done 2026-06-26):** the 4 broker trip-planner delegate routes (`/api/broker/performers/{id}/trip-plan|tour-package`, `/tours/multi|near`) lifted into `routers/broker.py` — the D0 authed twins of the slice-21 store routes; thin auth-gated wrappers over the shared payload builders (which stay in server.py, passed to both routers via getters). server.py → ~5015 LOC. **Slice 24 (done 2026-06-26):** 3 standalone DB-read broker routes (`/api/broker/news`, `/performers/by-league/{league}`, `/event/{id}/raw-tevo`) lifted into `routers/broker.py` — zero in-server helper coupling (require_sb + require_auth; raw-tevo adds a `get_client` getter for its live TEvo read-through). server.py → ~4871 LOC (under 5k). The remaining `/api/broker/*` routes (overview/section-zones/zones/section-metrics/watchlist-movers/espn/chart-data/movers/orders) are the helper-heavy ones — they need their large in-server helpers (`_bulk_event_context`, the `_event_*`/`_performer_espn` builders) extracted to `core/` first. **Slice 25 (done 2026-06-26):** 3 more standalone DB-read broker routes (`/event/{id}/section-metrics`, `/watchlist-movers`, `/event/{id}/orders`) lifted into `routers/broker.py` — require_sb only (+ the pure core `delta`/`listings_cadence_seconds` helpers; local nested pct/val helpers kept inline). server.py → ~4710 LOC. Broker routes still in server.py: `overview`, `section-zones`, `zones`, `performer/{id}/espn`, `chart-data`, `movers`. **Slice 26 (done 2026-06-26):** `/api/broker/event/{id}/overview` lifted into `routers/broker.py` — turned out clean (its `_bulk_event_context` was already in core; needs only require_sb + pure core `delta`/`listings_cadence_seconds` + `_bulk_performer_assets` via getter). server.py → ~4637 LOC. **Slice 27 (done 2026-06-26):** `/api/broker/event/{id}/section-zones` + `/zones` lifted into `routers/broker.py` (require_sb + the `_PARKING_ZONE_RE`/`_PARKING_SECTION_RE` regexes, both moved into the router). server.py → ~4466 LOC. **Slice 28 (done 2026-06-26):** `/api/broker/performer/{id}/espn` lifted into `routers/broker.py` (clean — require_sb + stdlib datetime only; the nearby `/api/admin/seed-home-venues` is a separate admin route, not part of the broker block). server.py → ~4384 LOC. **Slice 29 (done 2026-06-26):** `/api/broker/event/{id}/chart-data` (the ~485-line self-contained route, all `_series`/`_stand_series`/`_team_index_series`/etc. as nested helpers) lifted into `routers/broker.py` via a scripted +4 reindent — require_sb the only external dep. server.py → ~3902 LOC. **Slice 30 (done 2026-06-26 — FINAL broker route):** `/api/broker/movers` + its `_broker_movers_v2` helper lifted into `routers/broker.py` (require_sb + the core `delta` helper; nested `pct_delta`/`abs_delta` kept inline). **The entire `/api/broker/*` surface (16 routes) now lives in `routers/broker.py`** — matching `/api/store/*` in `routers/store.py`. server.py → ~3655 LOC (6,705 → 3,655 this session, −45%). **What's left in server.py:** the bootstrap (config/creds/clients/middleware), `/api/{events,performers,venues,portfolio,watchlist,collect,admin/*}`, the SeatGeek/SeatData link/sync POSTs, the static page routes (`/store/*`, `/terminal`, `/bridge`, `/home`), `/healthz`, and the shared payload builders + the few cross-router helpers (`_attach_owned_metadata`/`_search_*`/`_refresh_movers`/caches) the store router resolves via getters. **Remaining:** the big helper-heavy broker/store routes (overview/movers/chart-data/zones/store-*) still need the LARGE helpers (`_bulk_event_context`/`_compute_movers`/`_resolve_event`) moved to core/ — incremental from here. **Remaining:** the big `/api/broker/*` (D0) + `/api/store/*` (D1) blocks (~40 routes) are deeply helper-coupled (`_bulk_event_context`/`_compute_movers`/`_delta`/…) → need a shared-helper extraction into `core/` first (larger, multi-PR). Plus BR-CODE-2 (client base) is independent. **Next (larger, planned):** the `sb`/`client`/`require_sb` → `core/` move is HIGH-blast-radius (creds bootstrap has `sys.exit`; monkeypatched across many test files) — plan it deliberately, not a quick slice. Then `routers/public_meta.py`, then the big broker/store blocks (need shared helpers in `core/` first). |
| **P1** | **BR-CODE-2** | A1 / D0 | **9 `*_client.py` copy-paste ~100 LOC each** (read-only guard, retry/backoff, vault-secret, session/headers) with *inconsistent* retry → uneven rate-limit handling (ties into the SG 429 story). | Extract a `BaseReadOnlyClient` (GET-only guard + unified exponential backoff honoring `ratelimit-remaining` + vault resolver); migrate clients one at a time. ~900 LOC reclaimed; `tests/test_readonly_guards.py` stays green. **Slice 1 (done 2026-06-26 — guard dedup):** `core/readonly_guard.py::build_readonly_guard(error_cls, allowed, detail)` single-sources the RULE-2 `_assert_readonly_method` body; the 8 GET-only clients (evo/seatgeek/tickpick/gotickets/vivid/ticketsdata/axs/broadway) now wire it up instead of 8 hand-rolled copies (seatdata keeps its bespoke sanctioned-POST guard). Each client still declares its own `ALLOWED_HTTP_METHODS`+`frozenset({"GET"})`+`_assert_readonly_method`+error-class (the `check_readonly.py` static audit + `test_readonly_guards.py` per-client imports require those tokens in-file). 50 guard tests + RULE-2 static audit green; 100% held. **Slice 2 (done 2026-06-26 — retry dedup):** `core/http_retry.py::fetch_with_retry(do_request, *, max_retries, retry_statuses, base_backoff, max_backoff, sleep, jitter)` centralizes the 429/5xx retry loop (Retry-After → capped exponential backoff). Migrated the 4 attempt-indexed `requests.get` clients — **evo, tickpick, vivid, gotickets** — each passing its own `time.sleep` (so existing monkeypatch tests bind) + a thunk wrapping its transport/auth; each keeps its bespoke parse/raise (json/content/tuple, gotickets' network-error wrapper). 100% held + RULE-2 clean. **+ seatgeek + seatdata migrated** (jitter via the helper's `jitter=random.random`, `self.session` transport in the thunk, `(status, body[, headers])` tuple returns + seatdata's gzip handling preserved after the call; test `_FakeResp`s gained `.ok` to mirror requests.Response). **6 of 8 clients now share the retry loop.** **Intentionally NOT migrated (documented outliers):** `axs_client` uses a *fixed* `delays=[2.0, 5.0]` list (a deliberate non-exponential strategy that doesn't fit the helper); `broadway_client` is a low-criticality scraper with 7 test files of inline response fakes (high test-surface cost, low value) — both keep their hand-rolled loops. **Slice 3 (done 2026-06-26 — vault resolver):** `core/vault.py::vault_secret(db, name, *, on_error)` single-sources the Supabase-Vault `get_app_secret` lookup + result-unwrap (handles the bare-string, `{"get_app_secret": …}`, and `{"value": …}` shapes) + failure swallowing. Migrated the 4 vault-using clients — seatgeek, seatdata, ticketsdata, axs (the latter two keep their `_vault_secret` wrapper name + per-module log prefix via the `on_error` callback, so their tests' message + capsys assertions still pass). 100% held + RULE-2 clean. **BR-CODE-2 effectively complete:** guard (8/8) + retry (6/8, axs/broadway = documented outliers) + vault (4/4 vault clients) all single-sourced. |
| ~~P2~~ ✅ | **BR-CODE-3** | B1 / D0 [✅ RESOLVED 2026-06-25, PR #685] | ~~**Test coverage ~12%**~~ → **product code now at 100% line + branch coverage** (51.9%→100% measured; the old "~12%" was a LOC-ratio estimate). **Was 60+ broker/admin routes untested → now 0** (`/api/broker/*/chart-data`, `/movers`, all `/api/admin/*`, `/api/seatdata/*`, `/api/axs/*` all covered). | ~~Add route-level tests; target 30% ratio.~~ **Far exceeded.** Coverage tooling stood up from scratch (`.coveragerc` scoping the product surface; `conftest.py` global-state reset), ~1,600 mock-backed tests added, CI ratchet `--cov-fail-under=100` (line+branch) wired into `tests.yml`. Genuinely-unreachable lines carry justified `# pragma: no cover`. **2 latent bugs found+fixed** (store-events non-int performer-id 500; chart-data `_team_index_series` KeyError). **Increment 1 (done):** `tests/test_public_infra_routes.py` — 10 tests over the public non-DB infra routes. **Increment 2 (done):** `tests/test_broker_routes.py` — 5 tests over `/api/broker/leagues`, `/performer/{id}/assets`, `/event/{id}/overview` + a reusable `FakeSupabase`. **Increment 3 (done):** `tests/test_broker_movers.py` — 4 tests over `/api/broker/movers` v2 + `/watchlist-movers`. **Increment 4 (done):** `tests/test_watchlist_runs_snapshots.py` — 6 tests over `/api/watchlist`, `/api/runs`, `/api/snapshots/latest` (event-join enrichment + sort), `/api/snapshots/velocity`. **Increment 5 (done):** `tests/test_catalog_routes.py` — 6 tests over the TEvo-catalog passthrough GETs (`/api/performers/{id}`, `/api/venues/{id}`, `/api/configurations` + `/{id}`) asserting arg-passthrough + response relay. **Total at handoff: 31 route tests.** **✅ Completed (PR #685):** every remaining slice covered — incl. `/event/{id}/chart-data` (469-line fn), all `/api/admin/*` POST orchestrators, the store surface, and every `*_client.py`/`core/`/`routers/`/`d2_dashboard` module to 100% line+branch. |
| **P2** | → `A1-OPS-22` | A1 / Op | **AQ map duplicates/false-matches** — 235 `tevo_event_id`s with ≥2 rows → cross-source visibility gaps; safe-class consolidation fn built, pending apply. | See `A1-OPS-22`. Operator apply + dry-run review → execute. |
| **P2** | **BR-SPLIT-1** | D0 / Op | **D-tier git-split question (operator-asked 2026-06-19): verdict = DON'T split the monorepo now.** Cross-contamination of wiring is code/runtime coupling (one `server.py`, one `uvicorn server:app` process serving D0+D1, D2 `include_router`'d in), NOT a git problem — and the ownership boundaries a split would buy already exist (CODEOWNERS + `forbidden-paths-check.yml` + a separate `Terminal-2-ui` repo + lane governance). D4 is already cleanly isolated. Full analysis: `docs/archive/2026-06-19-d-tier-split-analysis.md`. | **Right sequence:** do `BR-CODE-1` (decompose `app.py` → per-surface routers — creates the seam) + per-surface Render services (roadmapped "migrate-back-at-beta"); a git split becomes trivial *after*, readiness order D4→D2→D0/D1. **Near-term PoC (needs operator go-ahead, not started):** extract D4 (Bridge) as a standalone repo — already isolated, near-zero risk, validates the seam model. |
| **P2** | **BR-SPLIT-2** | B1 / Op [NON-BLOCKING CHECK SHIPPED] | **Mechanical lane-boundary CI check (the missing enforcement).** Asset→lane assignment is complete + orphan-free (`PROJECT_BIBLE §2.5/§2.6`, ex-`BOT_HIERARCHY §5.5/§5.5b`) and labeled, but enforcement was **doc-only between D-lanes** (`CODEOWNERS`/`forbidden-paths-check.yml` only separate *owner vs coworker*). **Shipped (non-blocking):** `.github/workflows/surface-boundary-check.yml` emits `::warning::` annotations when a PR (a) spans >1 exclusive D-surface (`static/terminal` vs `static/store`/`home` vs `d2_dashboard` vs `d4_bridge`/`static/bridge` vs broadway) or (b) touches a §5.5b shared seam (`_shared`/`shared`/`trip_planner`/retail-chat) — seam paths are excluded from the surface tally so a legit cross-surface widget isn't mis-flagged. Logic smoke-tested across 6 scenarios. | **Remaining (operator decision):** flip `HARD_FAIL=1` to make multi-surface PRs blocking once the branch-prefix→lane convention is confirmed. Until then it's visibility-only (can't break the workflow). |
| **P3** | **BR-CODE-4** | D0 / D1 | **Frontend bloat** — `event.js` 5,595 LOC (130+ loose globals manually localStorage-synced, 5+ near-dup render fns); ~300–400 LOC duplicated CSS vars across two stylesheets. | Extract a shared `renderMarketplaceTable(data, cols)` + a single state object w/ localStorage util; hoist shared CSS vars to one `theme.css`. **Slice 1 (done 2026-06-26 — CSS token dedup):** terminal/style.css's `:root` block (16 color/font vars) was **byte-identical** to the already-existing `_shared/design-tokens.css` (the migration was started — the file's comment claims "Loaded by terminal" — but never finished). Linked `/static/_shared/design-tokens.css` in terminal/index.html (matching home/undelivered's proven absolute-path pattern under the `/static` StaticFiles mount + FileResponse serving) before style.css, and removed the duplicate block. Verified via TestClient: `/terminal/` serves the link, `/static/_shared/design-tokens.css` resolves 200 with the vars, style.css's `:root` block is gone — values unchanged. store/style.css (1 extra var, public-facing, deliberately deferred per the token file's comment) left untouched. **Remaining:** the bigger `event.js` (5,672 LOC) JS dedup (renderMarketplaceTable + state object) needs a browser smoke-test harness first — no pytest net covers JS. |
| **P2** | A1-OPS-SRC1 | A1 / Op | **Sourcing-cron redesign — TD credit control.** Phase 1 SHIPPED (AXS credit instrumentation, mig 20260630160000): AXS now logs to `ticketsdata_credit_usage` at ingest, true cost confirmed **≈1/fetch** (the prior "~46/fetch / ~10k-day AXS" was a quota-counter contention artifact; 3 counter groups `{SH}`/`{VD,GT,TM}`/`{AXS}`). New views `v_td_credit_usage_by_platform`/`_mtd`/`v_td_credit_cost_per_call`. **Peak/off-peak window DATA-DERIVED 2026-06-30** (mig `20260630170000`, AUTHORED, operator-apply): 135,658 deduped realized SG sales (`seatgeek_sales_snapshots.sale_at_utc`, ET) → **peak ET 09:00–01:59 (~93.4%)**, off-peak ET 02:00–08:59 (~6.6%), dead core ET 03:00–06:59 (~2%). Robust across two seeds + weekday/weekend + ≤7d-vs-far bands; a listing-reprice cross-check is flat (no morning spike) → sales = the right value-of-freshness signal. 5-agent adversarial workflow verified (stats critic reproduced the split on the DB). | **Phase 2 (window piece authored — `20260630170000`):** canonical `is_peak()` (DST-safe; extends current ET09–00:59 peak by +1h to ET09–01:59) + both `collector_band` overloads re-point at it + **AXS probe (jobid 402) off-peak throttle** (every-min peak → ~every-10-min off-peak; ~26–35% AXS-tick saving, safe vs the 12h refresh target). **ENROLLMENT SEEDED 2026-06-30** (mig `20260630180000`, APPLIED): `td_seed_mapped_xref()` generalizes `td_seed_owned_xref` to ALL AQ-mapped upcoming events (owned-first, SH/VD via templated URLs). Active enrollment **602 → ~2,100 distinct events** (SH 248→1,999 · VD 257→2,030; +3,524 rows). GT/TM/TP stay on the discovery track. **BUDGET CAPS — measured + cycle-aligned + phased** (migs `20260630190000`/`200000`/`210000`, APPLIED): live gate had drifted to 50k/day·600k/mo (≈800k real ≫ pool). Re-sized against the REAL pool via the **measured 1.276× real:recorded ratio** (billing 26,349 real vs 20,642 recorded since Jun 9; `td_credits_this_cycle()×1.276` reproduces billing to 0.04%). Gate now **cycle-aligned to the 9th** (billing cycle Jun 9→Jul 9, not calendar) and **phased by date**: NOW→7/9 runs the **300k plan** (loose: 40k/day·300k cycle, real) to burn the otherwise-expiring surplus; **from 7/9 an 8k REAL/day cap** auto-engages (8k×31≈248k, just under 250k). AXS probe now also gates on `td_budget_ok()` so "total" includes it. Projected non-SG steady-state ≈ **104k/mo recorded (~138k real)** — under either phase. **Phase 2 remainder (next):** per-platform breadth ladder (GT ≤30d · TP ≤14d · SG listings ≤7d) + retire dead `td_poll_policy` tier crons + TM→MSG-only (venue 896) + SG broker = discovery-first (all sales, listings ≤7d, off TD budget) + hold SG ≤7d at peak 24/7 + map the ~3,100 unmapped EVO-upcoming events into the AQ hub to grow the pollable universe. **CONSTRAINT (operator 2026-06-30): MAINTAIN + EVENLY-SPACE per-source leapfrog** — keep each TD source's enqueue cron on its own offset minute (SH `:00` / VD `:02` / GT `:04` / TM `:06`, `*/10`) so TD draw/credits stay spread across the clock; do NOT collapse sources into one simultaneous schedule. Mig `20260630170000` evens the spacing by dropping the AXS off-peak probe into the idle `:06→:10` gap at `:08`, giving a uniform 2-min leapfrog (SH:0→VD:2→GT:4→TM:6→AXS:8→repeat). Phase 2 consolidation must preserve this even leapfrog. **SG SURPLUS-BURN — temporary until 7/9** (mig `20260630220000`, APPLIED): overrode the TD-SeatGeek kill-switch to burn the ~184k of expiring real surplus + relieve the 429-throttled broker token. Enrolled **1,948 mapped events** on platform `SG` (URL templated from sg_event_id); verified TD `/fetch` serves live SG listings (HTTP 200, e.g. 742 offers/event). Date-gated enqueue `td_enqueue_peak_sg` (`5-59/10`, <7/9) + self-destruct `td_sg_burn_teardown` cron that on/after 7/9 re-arms the kill-switch, deactivates the SG xref rows, and unschedules both. **Phase 3 (data-gated ~3–7d):** per-platform budget split (`td_credits_by_platform`/`td_budget_split_ok`). Full plan: `.claude/plans/solutions-buzzing-riddle.md`. |

### SEC-HIGH (exploitable or sequencing-risk)

| ID | Lane | Finding/Task | Action |
|---|---|---|---|
| B1-NEXT-11 | Op ⚠️ AUDITED 2026-06-08 — "rotated" NOT confirmed | Leaked `CRON_SECRET` in git history (commit `5297739`). Value rotated but repo is public → internet-readable.<br><br>⚠️ **AUDIT 2026-06-08 — the "value rotated" premise is UNVERIFIED, and the leaked literal is still LIVE-wired.** Findings: (1) **5 active crons still hard-code the leaked placeholder** `pick-any-random-string-and-save-it` as their `X-Cron-Secret` — `collect-listings-{0-24h,1-7d,7-30d,30-60d,60d+}` (the *only* 5 crons sending a cron secret); all fired & succeeded today (pg_net queues async, so "succeeded" ≠ edge-fn accepted). (2) `CRON_SECRET` is **not** in the `get_app_secret` whitelist → it lives in **edge-function env**, so whether the live validated value still equals the placeholder is **operator-only** (can't compare from SQL; request queue purged so 200-vs-403 unobservable). (3) commit `5297739` is **not reachable in the CI clone** (shallow or already-rewritten — operator to confirm). **Implication:** if the edge-env `CRON_SECRET` is still the placeholder, the leaked value is **LIVE** (rotation never changed the checked value) and history-rewrite alone wouldn't contain it; if it was rotated, those 5 crons are silently **403-failing**. Either way the remediation is the same and was already specced but never done (see the NEXT-code "[SEC-MED] Cron command bodies hardcode the placeholder" row): **de-hardcode the 5 cron bodies + confirm/rotate the edge-env secret to a non-placeholder value.** | **Operator (decision now has 2 parts):** (a) confirm the edge-fn env `CRON_SECRET` ≠ `pick-any-random-string-and-save-it` (rotate it if it still is — leaked = live); (b) reschedule the 5 `collect-listings-*` crons so the header secret is not the hard-coded placeholder; THEN the `git filter-repo`-vs-accept (G-1) history decision. "Accept (rotated, contained)" is premature until (a)+(b). |

### SEC-MED (defense-in-depth)

| ID | Lane | Finding/Task | Action |
|---|---|---|---|
| B1-NEXT-63 | B1 🔍 AUDITED (latent, no live break) | **SECDEF RPC `occurs_at_local` parsing audit.** `public.events.occurs_at_local` is a TEXT column (PROJECT_BIBLE §3 landmine) — any SECDEF RPC that casts/parses it as a timestamp (`::timestamptz`, `to_timestamp`, date math) can throw or silently mis-sort on non-ISO rows. Defense-in-depth; no known live break. | 🔍 **AUDIT DONE 2026-06-08** (read-only sweep): **39 functions cast it** — 17 SECDEF (`get_broker_event_page_v2`, `terminal_search`, `get_broker_venue_page`, `get_broker_performer/venue_index`, `get_returning_entity_events`, `performer/venue_metric_value`, `sg_attempt_event_xref_v3`, `match_unmatched_listings_chunked`, `get_blind_spots_tevo_selling`, `get_event_sd_sales_full`, `td_target_events`, `td_gt_discover_drain`, `sg_canonical_link_from_tevo_chunked`, `evo_listings_poll_tick`, `collect_listings_featured_refresh`) + 22 non-SECDEF. **DATA CHECK: 0 live break** — across **9,207** rows `occurs_at_local` is **0 NULL / 0 invalid-timestamptz / 0 invalid-date** (`pg_input_is_valid`, PG17). Column is 100% well-formed ISO today, so every cast succeeds. **Risk is LATENT only** (a future malformed/NULL ingest). Hardening options for B1/A1 (gated DDL, not done): regex `CHECK` on `events.occurs_at_local` to enforce ISO-offset at ingest, or a `safe_occurs_tz(text)` `IMMUTABLE` wrapper the RPCs adopt. No fix rows filed — nothing is broken. |
| B1-NEXT-55 | A1 (B1) ✅ RLS-off regression FIXED 2026-06-08 (batch-REVOKE still open) | **Systemic**: 140 public tables carry the Supabase default anon/authenticated grant. Phase-2 verified (B1 2026-05-25): **0 are RLS-off** (B1-NEXT-7 thereby resolved), ~130 carry an `admin_only USING(false)` policy (anon denied — latent), but **7 carry a `USING(true)` anon-read policy = live-readable** (see B1-NEXT-58). Defense-in-depth: blanket `REVOKE ... FROM anon, authenticated` on internal tables + rely on views/RPCs for the intended anon surface. | ⚠️ **RE-AUDIT 2026-06-08: the "0 RLS-off" baseline is STALE — 2 granted+RLS-off tables now exist** (192 tables total, 169 anon/auth-granted, grown from 140). Offenders (0 policies, RLS off = no gate): **`seatdata_search_attempts`** (anon **+** auth SELECT — unauthenticated-readable; internal search log, low-sensitivity but real) and **`sg_league_priority_config`** (auth SELECT; config). A 3rd, `sg_market_chart` (1.2 MB), is RLS-off but **not granted** to anon/auth → safe. **Fix (owner-intentionality, NOT auto-applied — a blind `ENABLE RLS` with 0 policies would deny any current authenticated reader):** for the 2, either `ENABLE ROW LEVEL SECURITY` + a deny-all/`admin_only` policy, or `REVOKE … FROM anon, authenticated`. Confirm no terminal/app code reads them first. Still pursue the broader batch-REVOKE on internal tables. ✅ **FIXED 2026-06-08 (mig `20260608203000`, applied via MCP):** verified no app/view reads them → `ENABLE ROW LEVEL SECURITY` + `admin_only` deny policy on both (mirrors the `bot_chat` pattern); SECDEF/service_role readers unaffected. Post-apply **granted-AND-RLS-off count = 0**. The systemic batch-REVOKE on the ~130 latent internal tables remains open (separate, low marginal risk since RLS holds). |
| B1-NEXT-57 | A1 (B1) 🔍 AUDITED 2026-06-08 | **Harness blindspot** — `release_health_check.security_definer_views` only sees `relkind='v'` (misses anon-readable matviews) and flags ALL definer views (noise on intentional `exos_public_*`). Detector `_health_check_anon_exposed_relations()` shipped (mig `20260525180000`); prod `release_health_check` is BEHIND the on-disk chain (lacks cron_heartbeat #176 / aging / pg_net), so integration deferred to next coordinated revision. Also fix pgcrypto-check false-positive (`exos_check_in_ticket` uses qualified `extensions.hmac` — strip qualified calls before testing). | 🔍 **AUDIT 2026-06-08:** detector exists + runs clean — **`_health_check_anon_exposed_relations()` returns metric=0 (`status=ok`, no anon-exposed definer relations)**. Confirmed `release_health_check` does **NOT** yet call it (`prosrc` check = false), so the one-line `RETURN QUERY` append is **still open** (correctly deferred — prod RHC is behind the on-disk chain; don't clobber). Action unchanged: append the detector call + pgcrypto regex fix in the next coordinated `release_health_check` migration (A1 apply-sequencing). |
| B1-NEXT-58 | D0/D1/D3 (B1) 🔍 RE-AUDITED 2026-06-08 — improved | **7 base tables with `USING(true)` anon-read policies** (B1 Phase-2 2026-05-25): `espn_athletes`, `espn_teams_canonical`, `espn_event_snapshots`, `events`, `event_xref`, `venue_assets` (likely-intentional public/reference) + **`listings_snapshots` (ticket pricing — priority review)**. Deliberate policies (not the gotcha), so owner intentionality call, not unilateral revoke. | 🔍 **RE-AUDIT 2026-06-08 (`pg_policies`): the anon priority is largely RESOLVED.** Only **3** tables still carry an `anon` true-qual SELECT policy — `espn_athletes`, `espn_event_snapshots`, `espn_teams_canonical` (low-sensitivity public ESPN reference). **`listings_snapshots` (the priority), `events`, `event_xref`, `venue_assets` are NO LONGER anon-readable via a true-qual policy** (revoked/changed since the 05-25 baseline). Remaining action on the 3 ESPN tables: document-or-revoke (low risk). **NEW (→ B1-NEXT-60, authenticated-read not anon):** 9 tables are readable by ANY authenticated user via true-qual SELECT — flag two: **`leads`** (⚠️ likely contact/sales PII — review for a tighter policy) and **`event_xref_cleanup_archive_20260606`** (stray dated archive table carrying the default grant; drop the policy/table). Others (`exos_orgs`/`exos_profiles` likely intentional; `evo_only_patterns`, `td_sg_performers`, `performer/venue_metrics_daily`, `wc_price_daily` = reference/metrics). |
| B1-NEXT-60 | D2/D0 (B1) 🔍 PARTLY FIXED 2026-06-08 | **Tier-3** — post-#350, any *authenticated* user (not only `@s4kent`) still reads the order/intel views (definer, no row filter). Proper fix: `security_invoker=true` + RLS, or `auth.jwt()->>'email'` gate. | 🔍 **AUDIT 2026-06-08 enumerated the authenticated-read base tables** (true-qual policies): ✅ **FIXED `event_xref_cleanup_archive_20260606`** (mig `20260608204500`, applied) — stray dated cleanup archive, no readers/deps; dropped its `..._authenticated_select` policy → `admin_only` deny. ⚠️ **`leads` — OWNER REVIEW (likely PII):** carries a deliberate `leads_authenticated_read USING(true)` policy → ANY authenticated user reads all leads. No app/view reads it (grep+dep clean), but the named policy implies an intended reader — **tighten `USING(true)` → an admin/email claim (`auth.jwt()->>'email' LIKE '%@s4kent.com'`) rather than blanket authenticated.** Not auto-changed (could back an admin tool). Others from the sweep (`exos_orgs`/`exos_profiles` likely intentional; `evo_only_patterns`/`td_sg_performers`/`*_metrics_daily`/`wc_price_daily` = non-sensitive reference). Original Tier-3 order/intel **views** (definer, no row filter) still want the `security_invoker`+email-gate treatment per the owning lanes. |
| B1-NEXT-3 | B1 | Edge function auth-posture inventory (16 fns). Per-function record of `x-cron-secret` vs open vs JWT-gated. | Author `docs/edge_function_auth_inventory.md` |
| B1-NEXT-5 | B1 | Vault orphans check — `release_health_check()` row for `get_app_secret` allowlist entries unused by any prod fn/cron/edge-fn. | 1 SQL migration adding a new row to `release_health_check()` |
| B1-NEXT-18 | Op | Verify Actions secrets populated for `sync-check.yml` (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`). | Operator confirms next session via Settings → Secrets |
| B1-NEXT-31 | A1 | §6 body guard absent on 7 JWT-gated SECDEF RPCs: `get_broker_event_page` (v1/v2/v3), `get_event_sg_listings_full`, `get_event_evo_listings_full`, `get_event_sg_sales_full`, `get_event_cross_source_metrics`. JWT body check IS primary mitigation; guard is 2nd belt. **BLOCKED on spec clarification** — literal §6 `current_user NOT IN (service_role, postgres, supabase_admin)` would brick these (anon/authenticated callers via PostgREST). bot_chat question pending B1 response. | Wait for B1 spec; verified `public_exec=false` already in place on all 7 |

### SEC-LOW (hygiene)

| ID | Lane | Finding/Task | Action |
|---|---|---|---|
| D1-BOT-1 | Op | **Storefront bot gate (reCAPTCHA v3) wired but DORMANT** (merged #566). Sitewide first-interaction gate + honeypot + tightened reserve/share rate limits are live; reCAPTCHA stays off until keys exist (honeypot + rate limits protect the demo meanwhile). Deferred per operator "kanban as captchas for now" 2026-06-17. | Operator sets `RECAPTCHA_SITE_KEY` + `RECAPTCHA_SECRET_KEY` (optional `RECAPTCHA_MIN_SCORE`, default 0.5) on `vibepass-storefront-test`. No code change — `/api/public/config` flips `recaptcha_enabled` automatically. |
| D1-UX-1 | D1 | **Mobile: 413px horizontal overflow on the event page** (live iPhone test 2026-06-17, `/store/event/3091462`). `.head-row` is a flex row whose title/meta child has default `min-width:auto` → refuses to shrink → header ~2× viewport → sideways page scroll. **Live bug; fix authored in closed PR #574 (not merged).** | `.head-row { flex-wrap: wrap }` + title block `{ min-width:0; overflow-wrap:anywhere }` + `body { overflow-x: clip }` safety net. Then re-run the overflow snippet → expect 0. |
| D1-UX-2 | D1 | **Mobile: tap targets < 44px** (Apple HIG) — `.filter-chip` 24px, `.listing-tab` 40px, `.btn` 35px. 192 controls flagged (most are inline text links, exempt). Fix authored in closed PR #574 (not merged). | `.btn / .listing-tab / .chip-group .filter-chip { min-height:44px; display:inline-flex; align-items:center }` inside the ≤760px media block. |
| D1-UX-3 | D1 | **Mobile: notch/home-indicator safe-area regression.** The "concierge redesign" `.topbar` rule (added after the base rule) overrides the safe-area insets → header content slips under the Dynamic Island in standalone PWA. Fix authored in closed PR #574 (not merged). | Re-apply `env(safe-area-inset-*)` padding in the concierge `.topbar` override. Verify E3/E4 in standalone. |
| D1-UX-4 | D1 | **Verify (needs live browser): seat-map section tap → listings filter on mobile** (Stage C2). Map itself confirmed rendering (host 334×480, SVG present). Interaction path untested on touch. | In-browser: tap a section on the event-page map, confirm the listings list filters to it + selection is visible. File a fix only if it fails. |
| D1-UX-5 | D1 | **Search suggestion keyboard arrow-nav likely missing** (Stage B2). Combobox has `role=listbox`/`aria-controls` but no up/down/enter handling → keyboard + screen-reader users can't traverse results. | Add arrow-key/enter handling to the search-suggest dropdown in `static/store/store.js`; verify with keyboard + VoiceOver. |
| B1-NEXT-64 | B1 | **Governance audit-trail: log the historical D0 prod-apply pattern.** `BOT_HIERARCHY.md §6` now states D-tier has zero DB-apply authority (operator clarification 2026-05-28); record the prior D0 direct-apply instances (`bot_chat` #740/742/745 + their associated migrations) as a closed audit-trail entry for traceability. No code fix. | B1 confirms the exact threads/migs, then appends a dated governance row to `docs/archive/` (or a `bot_chat` `change_log`) cross-linking them and marking the pattern superseded by the §6 policy. No prod change. |
| B1-NEXT-61 | A1 | ~~`listings_aq_backfill_overnight` cron (mig `20260526000000` FIX-3) omits the `cron_should_fire()` policy gate PROJECT_BIBLE §7 mandates.~~ **OBSOLETE 2026-06-01** — cron disabled (`active=false`, mig `20260601120000`): both broken (120s timeout, never drains) and pointless (no reader of `listings_snapshots.aq_short_event_id`; market-tracking intent served via the `event_id→ticketsdata_event_xref→aq_event_map` path). No gate needed on a cron that won't run. | None — closed-obsolete. |
| B1-NEXT-62 | D4 | `exos_event_checkins.scanned_by` now nullable (mig `20260526020000`) — correct fix, but scanner attribution is lost if the scanner's `auth.users` row is later deleted. | Optional: denormalize a `scanned_by_email` text snapshot at scan time for a durable door-audit. B1 review F4. |
| A1-OPS-22 | A1 ⏳ FN BUILT (dry-run), pending apply | **`aq_event_map` duplicate-row consolidation** — ~211 `tevo_event_id`s carry ≥2 map rows (PK is `aq_short_event_id`); TBD/`aq_curated` placeholder + later `system_seed` `SYS-*` rows resolve to the same game and never merge, scattering platform IDs so the TD daily snapshot reads only one cluster (e.g. Knicks G3 `3346011`). **16 of these carry _conflicting_ `sg_event_id`s** (same tevo, ≥2 distinct SG ids — often main + parking pseudo-event or split-doubleheaders). `td_reconcile_knicks_finals_aq` already consolidates the Knicks subset; generalize it. | 🔍 **AUDITED 2026-06-08 — NOT superseded; still open + grown.** Live: **235** `tevo_event_id`s with ≥2 map rows (was ~211), **19** with conflicting `sg_event_id`s (was 16); 8,080 total map rows. Only `td_reconcile_knicks_finals_aq` exists (Knicks-only) — no general sweep yet. (A1-OPS-23's matcher fix touched `sg_events_canonical`, a different table, so it didn't reduce these.) **Build plan + RISK:** the safe class (TBD/`system_seed` placeholder dups where sg ids agree or one is NULL) is a mechanical COALESCE-onto-richest-survivor; but the **19 conflicting-sg cases are NOT safe to blind-merge** — they're often main-vs-parking pseudo-events or split doubleheaders (genuinely distinct events). Recommend: general sweep for the safe class + a parking-pseudo filter, and handle the 19 per-case (do NOT COALESCE distinct doubleheader games). Model on `td_reconcile_knicks_finals_aq`. ⏳ **SAFE-CLASS SWEEP BUILT** (`supabase/migrations/20260608201500_aq_consolidate_safe_dups_fn.sql`) — installs `aq_consolidate_safe_dups(p_apply default false)`: survivor = richest-platform (tie-break TD-xref-referenced, then smallest aq id), COALESCE loser ids onto survivor, re-point `ticketsdata_event_xref`, NULL loser ids — **never deletes** (8 FK-deps). Restricted to the 212 safe clusters; the 23 conflicting EXCLUDED. **Install-only migration (mutates nothing on apply); DEFAULTS TO DRY-RUN.** Dry-run preview: 212 clusters / 220 losers (15 carry ids). **Awaiting operator apply** → then `SELECT … aq_consolidate_safe_dups(false)` (review) → `(true)` (execute). |
| B1-NEXT-4 | B1 | Evaluate CodeQL / SAST for FastAPI + edge functions. | Research + decision doc |
| B1-NEXT-6 | B1 | Egress payload review on `*_public` / `/api/store/*` RPCs. (Partial pass via war-games W-3 2026-05-17; rotational.) | Quarterly sweep against war_games_playbook W-3 + W-4 |
| B1-NEXT-10 | A1 | Migration slot collisions: `20260515300000` (3 files), `20260515320000` (2 files), `20260515340000` (2 files — caught 2026-05-18, kanban missed it). None applied via `apply_migration` (`schema_migrations` empty for all). | Rename to next free slots in a future cleanup PR. **Risk-check first**: some may have been applied via direct `execute_sql` — verify via function/object presence before rename. |
| B1-NEXT-15 | Op | Branch-protection `enforce_admins=false` on `main`. | Operator decision. G-6. |
| B1-NEXT-16 | Op | `required_signatures=false` on `main`. | Operator decision. G-7. |
| B1-NEXT-17 | Op | Actions `sha_pinning_required=false`. | Operator decision. G-8. |
| B1-NEXT-19 | D1 | Render `ipAllowList: 0.0.0.0/0` on `d2-orders-dashboard` + `vibepass-terminal-test`. Both auth-gated at app layer. | PR comment to D1 — optional tightening. R-1. |
| B1-NEXT-20 | D1 | Render services `autoDeploy: yes`. Consider manual approval gate for `vibepass-storefront-test`. | PR comment to D1. R-2. |
| B1-NEXT-21 | Op | No active Slack MCP in repo. | Operator decides Slack MCP install |
| B1-NEXT-24 | B1 🔍 AUDITED 2026-06-08 (0 drift) | Periodic full-pass drift audit of `PROJECT_BIBLE.md` §4 RPC table. | 🔍 **AUDIT DONE 2026-06-08** (read-only `pg_proc` check of all 36 documented §4 RPCs): **36/36 present, exactly 1 overload each — 0 missing, 0 ambiguous duplicates** (the §7 drop-old-overload discipline is holding; `match_to_aq_event_id` is the single 8-arg form, the old 7-arg overload is gone). Signatures match the documented args (minor doc-shorthand only: `bot_chat_resolve` params are `p_resolver_level`/`p_resolver_lane` vs the table's `level`/`lane`). **§4 table is accurate — no edits needed.** Next quarterly pass due ~2026-09. |
| B1-NEXT-25 | B1 → A1 ⚠️ DRIFT FOUND 2026-06-08 | Periodic full-pass drift audit of `RESOURCES_BIBLE.md` §1. | ⚠️ **AUDIT DONE 2026-06-08 — headline inventory counts are STALE (understated).** Live prod vs the documented figures (PROJECT_BIBLE intro + RESOURCES_BIBLE §1): **tables 132→`192` (+60); views 152→`167` + 4 matviews = `171`; crons "75+"→`148` total / `144` active (~2×); `481` public functions.** Counts only — per-object accuracy not line-checked. **Action for A1** (bible bodies are A1-review-gated, not edited here): refresh the PROJECT_BIBLE intro line + RESOURCES_BIBLE §1 inventory to current counts. Next quarterly pass ~2026-09. |
| B1-NEXT-26 | B1 | bot_chat thread-closure rate dashboard — add to `release_health_check()` as `coordination.thread_closure_rate_7d`. | 1 SQL migration |
| B1-NEXT-27 | B1 | Cross-bible consistency check (lane ownership now single-homed in `PROJECT_BIBLE.md §2` — `BOT_HIERARCHY.md` merged in 2026-06-19, `LANE_DISCIPLINE.md` before it; diff is no longer cross-file). | Periodic self-consistency pass |
| B1-NEXT-28 | B1 (post-MCP) | Slack channel signal-quality metric. | Blocked on B1-NEXT-21 |
| B1-NEXT-35 | Op | Create scheduled task `b1-war-games-rotation`. Every 4h. | Operator approves Slack MCP tool + cron creation |
| B1-NEXT-40 | Op | **G-9**: `allow_forking: true` on public repo. Forks clone full history including the leaked `CRON_SECRET` commit `5297739`. Compounds G-1. | Operator decision (usually allow_forking stays true; real fix is G-1 history rewrite) |
| B1-NEXT-44 | Op | **G-14**: Branch protection on `main` — no required approving review count, no CODEOWNERS review required, no dismiss-stale-reviews. Single-operator can push without formal review. | Operator decision — Settings → Branches → Edit rule for `main` |
| B1-NEXT-45 | Op | **G-15**: `required_conversation_resolution: false`. PRs can merge with unresolved review comments. | Settings → Branches → toggle |
| B1-NEXT-51 | A1 (B1 assists) | 5 deferred major-version bumps (held in `.github/dependabot.yml` ignore rules 2026-05-18): `anthropic>=1.0`, `actions/upload-artifact>=5`, `actions/github-script>=8`, `actions/labeler>=6`, `github/codeql-action>=4`. Each needs smoke-test before operator unblocks. Original Dependabot PRs were #220/#221/#222/#225/#240 (all closed). | One smoke-test PR per bump (or batch). Remove the corresponding `ignore:` block after each lands. |

### Operator-only (settings / lockdown-gated applies)

> 🚀 **Production-readiness launch blockers** (the P0/P1 items that gate a real-money / multi-instance launch — legal, Supabase pooling, the `BUGHUNT-1` DB migration, Redis, external monitoring, Sentry DSN) are consolidated as an actionable punch-list in **[`docs/production_readiness.md`](docs/production_readiness.md)**. Read that before a go-live decision.

| Item | Action |
|---|---|
| **Recharge TwitterAPI.io credits** — starter balance exhausted 2026-07-07 18:14Z after 660 tweets (≈$0.10 @ ~$0.15/1k); X wire is in 402-backoff (one probe/~30 min, mig `20260707200000`) | Recharge at the twitterapi.io dashboard → wire auto-resumes ≤30 min, no other action. Post-recharge steady-state is cheap: incremental `since:` polling bills only NEW tweets (rough order: low single-digit $/mo at current roster volume vs ~$130/mo without it). Watch `SELECT * FROM v_x_news_usage;` (hourly est_usd + 402/429 counts). |
| Apply migration `20260516230000_security_release_health_cron_heartbeat.sql` | `apply_migration` via MCP — adds 3 RHC rows (heartbeat, aging_7d, pg_net) |
| Apply migration `20260515300000_security_secdef_post_pr101_compliance.sql` | `apply_migration` — Phase 1 §6 retrofit on 11 fns + RLS enable on `aq_*_map` |
| Mass-triage 47 aging bot_chat entries (>2 days old) | Per-lane sweep before PR #176 applies; otherwise `coordination.bot_chat_aging_7d` row will FAIL |

### OPS / product work (per-lane self-populates here)

| ID | Lane | Task | Action |
|---|---|---|---|
| A1-OPS-32 | A1 / B1 | **Prod's GoTickets cron topology is not reproducible from the repo (found 2026-08-31, doc sweep).** Live `cron.job` runs `gt_ingest_drain_1min` + `gt_deals_scan_odd_min` (`1-59/2`) + daily `gt_catalog_*_daily`, and calls **`gt_deals_retire_tick(p_stale_hours int)` — a function in NO committed migration**. The committed migrations instead define a single `gt_ingest_cascade_1min` + `gotickets_deals_scan_5min` + hourly `gt_catalog_*_hourly`. The live split is the *correct* shape (it is the structural fix for the 2026-08-11 incident — `PROJECT_BIBLE §3`), but it was applied straight to prod, so a rebuild-from-migrations would silently restore the cascade that caused the outage. | Capture prod's live definitions into a migration: `SELECT pg_get_functiondef(...)` for `gt_deals_retire_tick` + the three `cron.job` command bodies → one `*_capture_prod_gt_topology.sql` marked already-applied, per `MIGRATION_CONVENTIONS`. Read-only to write; no prod change. |
| D0-DEALS-1 | D0 | **Quantity-band matching is an unshipped fast-follow of realized-median v2** — mig `20260811273000` ships three validated fixes and explicitly defers the fourth ("ask #4"): comparables are matched by curated zone but NOT by quantity band, so a 2-seat ask is valued against 4-seat clears. Postgres can't `FILTER` an ordered-set median cleanly, so it needs its own pass. | Add a quantity-band dimension to the realized-median comparables in `scan_gotickets_deals` (per-band median via a lateral/percentile-over-partition rather than `FILTER`); validate against `get_deal_backtest` before shipping. |
| A1-OPS-31 | A1 / Op | **SeatGeek PRIMARY inventory is unobservable — the discovery chart's face-value availability is AXS+TM only (found 2026-07-09, PR #858).** Our SG broker feed (`brokerdata.seatgeek.com` → `seatgeek_listings_snapshots`) is **resale-only**: even for a SG-primary event/team (Austin FC `sg_event_id=17921663`, tevo `3221967`), we captured only 3 `market_source=exchange` (resale) listings, no primary allocation. So `sg_market_chart.primary_sources` reflects AXS (`is_axs_primary`) + TM (`td_tm_listings`) only; SG face-value availability can't be shown. | **Operator decision:** if SG primary availability is wanted on the chart, it needs a NEW SeatGeek **consumer/v2** pull (a separate GET client/endpoint that returns primary/GA allocations — RULE-2 read-only OK) → a `sg_primary_*` signal joined into `rebuild_sg_market_chart`. Non-trivial (new upstream integration + token). Until then, AXS+TM cover the primary signal we can see. |
| A1-OPS-30 | A1 / Op | **Our SG SellerDirect SALES are ingest-dark (found 2026-07-09).** Three stacked gaps: (1) `sg-seller-webhook` edge fn exists in-repo but is **NOT deployed** (absent from the 42 live fns); (2) its idempotency table `sg_seller_webhook_notifications_seen` (mig `20260516210000`) was **never applied to prod** — deploying the fn without it would error every notification; (3) `sg_seller_orders_queue_30min` cron is inactive (deliberately not resumed in mig `20260620120000`) and `seatgeek_orders` has nothing newer than 2025-06. Net: we cannot see sales made through our own SeatGeek seller account — any future feature keying on own-SG-sales is blind. (Not a blocker for the discovery chart, which is scoped to events we own NOTHING in.) Related: the SG LISTINGS path stays deliberately dark since 06-26 (`RESOURCES_BIBLE §5`). | **Operator decision (Applier actions):** relight our-SG-sales ingest when wanted — apply mig `20260516210000`, deploy `sg-seller-webhook` (+ cron-secret check), and/or `cron_resume_with_gate('sg_seller_orders_queue_30min')`. Any consumer union that includes `seatgeek_orders` heals automatically once it flows. |
| BUGHUNT-1 | A1 / Op | **`seatgeek_seller_listings` dedup is defeated for NULL `sg_listing_id`** (found 2026-06-25). `store_seller_listings` upserts `on_conflict="sg_listing_id,content_hash"`, but `NULL ≠ NULL` in a unique key, so any seller listing without an `sg_listing_id` re-inserts on every pull → unbounded duplicate growth. **FIX AUTHORED + TESTED (2026-06-26, B1):** mig `20260626120000_sg_seller_listings_nonnull_dedup_key.sql` swaps the dedup to the NON-NULL key `UNIQUE (sg_event_id, content_hash)` (content_hash already encodes sg_listing_id + every attribute; sg_event_id is NOT NULL) + the upsert is repointed to `sg_event_id,content_hash` (`seatgeek_client.py`) with a regression test. Dry-run on prod: **0 dups, new key already unique across all 2,859 rows** → applies cleanly. | ~~PROD APPLY HELD~~ **✅ APPLIED TO PROD 2026-06-26** (operator-authorized; via MCP `apply_migration`). Post-apply verified: constraint now `UNIQUE (sg_event_id, content_hash)`, all 2,859 rows intact, 0 dups. **BUGHUNT-1 CLOSED.** |
| BUGHUNT-2 | D0 / Op | **Holiday-window asymmetry — product decision, not a bug.** `core/movers.py` `_compute_movers` builds holiday-proximity options for `dd in range(-2, 2)` = −2…+1 days around a holiday's observed date (matches its own inline comment), so an event exactly **+2 days after** a holiday gets no "… Weekend" tag even when that day is a weekend (e.g. a Sunday two days after a Friday Juneteenth). The SQL fetch window is ±2, so the data is present — only the option-build loop is asymmetric. | **Operator/D0 decide intent:** if late-side ±2 is wanted, change to `range(-2, 3)` + a regression test; if the −2…+1 asymmetry is intentional, update the comment to say why. No action taken pending that call. |
| C1-OPS-1 | C1 / all | **Workflow-skills rollout (PoC landed 2026-06-17, PR #570).** Converting the `PROJECT_BIBLE §8` recipes into executable `SKILL.md` workflows under `.claude-plugins/terminal2-governance/skills/`, surfaced by the PreToolUse `skill_router.py` hook (`CLAUDE.md §5`). **Shipped:** `ship-a-migration` + the router (wired to migration edits / `apply_migration` / DDL `execute_sql`). **Backlog, ranked by git-audit churn + recurring-fix categories** (102-commit slice, 2026-06-08→17): (1) **`wire-a-ui-panel`** / build-a-terminal-surface — `static/terminal|store|bridge/*` are the #2 churn after migrations, and `fix` commits cluster on render/mount-timing, stale-bundle cache-bust, and missing error/404 states (D0). (2) **`spawn-a-cron`** — drain/poller-resilience fixes recur (poller aborting on dup `tevo_event_id`, processor stalls); §8 recipe exists (A1). (3) **`author-an-edge-function`** — `supabase/functions/*` = 70 touches, drain-repair fixes (A1). (4) **`run-a-security-audit-pass`** — recurring `audit HIGH/M2/H1` + RULE-2 remediations; maps to the existing `/rule2-audit` command (B1). (5) **`cross-source-sql` (use-the-AQ-hub)** — AQ-matcher fixes + the §0 "#1 fact sessions miss"; best enforced via a router nudge on cross-source SQL. | **Per skill:** author `SKILL.md` (Process/Red-flags/Verification + Rationalizations table wired to §3); add one `ROUTES` row in `skill_router.py` for discoverability; keep facts in the bibles (link, don't copy). **Guardrail before scaling:** a skills-namespace naming gate + a `using-agent-skills` meta-router so the skills surface can't regrow the doc-sprawl the closed registry exists to prevent. Convert one at a time (each its own PR) — don't mass-produce. **Next candidate:** `wire-a-ui-panel` (highest churn, different shape from migrations → tests whether the pattern generalizes). |
| C1-OPS-2 | C1 / B1 / Op | **4-domain reorg follow-ups (governance docs reframed 2026-06-17, PR #570).** `BOT_HIERARCHY.md` reframed from a top-down hierarchy to **peer-domain lane guidance** (A1 data plane · B1 git/code · C1 docs/coord · D0–D4 FE surfaces); push to `main` is **per-task** (A1 + B1 maintain, supersedes "A1 sole pusher"); DB security → A1, git security → B1; own-bible promotion model added. Authoritative docs updated (BOT_HIERARCHY §1–§6, CLAUDE.md §3/§5/§6/Push, PROJECT_BIBLE §1.5/§2, MIGRATION_CONVENTIONS, README). **Status (2026-07-02):** (1) own-bible CI wiring + (3) create per-bot bibles are **RETIRED as obsolete** — the "no lane-specific bibles" rule (2026-06-19) + the §2 convergence mean there are no per-bot bibles to wire or create. ✅ (2) **peripheral drift sweep DONE** (this PR): reconciled `docs/d4_bridge_charter.md` ("reports to C1 / under D0" → flat product lane), `docs/DATA_ARCHITECTURE.md` ("subordinates" → "any session"), and deprecation-bannered `docs/templates/LANE_DISCIPLINE.template.md` (its supervisor/subordinate/sole-pusher hierarchy is dissolved → points to §2). `MIGRATION_CONVENTIONS.md`'s roster note was already reconciled; `.github/CONTRIBUTING.md`'s "human operator = sole approver" correctly stays (a *different* statement). **Still open:** (4) **prune orphan branches** — ~19 `claude/*` + 2 `a1/*` remote branches with no open PR (see the 🌿 BRANCHES / PRs tracker); confirm-merged-then-delete. | **Op:** confirm the per-task push model is reflected in any GitHub branch-protection settings (branch protection is operator-only). Branch pruning is housekeeping — do when convenient. |
| A1-OPS-25 | A1 / D0 / Op | **AXS primary box-office (veritix) — data collection LIVE; purchase automation PARKED (operator paused 2026-06-10).** Shipped (#511 + #533 merged to main): `axs_venues` (8,811; 341 pegged to `tevo_venue_id`), `axs_events` registry (351 total; **319 active** after deactivating LA Kings + past-dated), serial classify+ingest `axs_probe_step()` (cron **jobid 402, `*/1`**, in-flight guard self-throttles to the ~40s single upstream TicketsData worker), per-seat retention `axs_seat_snapshots` (section/row/seat#/type/price + full `raw_item`), AQ mapping `axs_aq_match()`→`tevo_event_id` (±48h venue+date+name; AXS-vs-TEvo date drift), FE **AXS Box Office** tab + chart lines (`/api/axs/*`). Bibles updated (RESOURCES §2.18, D0 §4b-axs, PROJECT §3 landmine). **Now collecting:** 2/23 confirmed events snapshotted; drain backfilling the rest (~6–8h sweep). | **Now:** just collect — let the drain accumulate (no action; operator paused further build). **PARKED — do NOT build without explicit operator authorization (§2 security-CRIT):** automate AXS **checkout / order-substitution for double sales**. The pull exposes `isSaleThroughWebAllowed` + on-sale window + delivery methods + an ephemeral session/socket token, but **no callable buy endpoint** — automating purchase = an upstream order-creation **write path**, forbidden by the read-only lockdown; requires explicit operator auth + B1/A1 sign-off + real AXS/TicketsData purchase credentials + ToS/legal review. **Compliant interim (read-only, buildable when wanted):** surface `is_buyable` + live get-in + exact available seats as a double-sale **substitution signal** (alert/queue only, never a transaction). |
| A1-OPS-27 | A1 / Op | **Bands in Town artist tour tracking — client SHIPPED (PR #693), NOT yet wired (engine without ignition).** `bandsintown_client.py` = read-only GET client for `rest.bandsintown.com` (`get_artist`/`get_artist_events`/`get_tour_dates`); in the RULE-2 lockdown + 100% covered. No route/cron/UI calls it yet — pure capability. Needs vault secret `BANDSINTOWN_APP_ID`. **(Docs note: RESOURCES_BIBLE §1 lists a route `/api/broker/bandsintown/tour` — that route does NOT exist in code yet; the bible entry is aspirational until wired.)** **(Related: `core/instagram_share.py`, shipped same PR, is redundant — D4 already shares the event poster+link via `d4_bridge/src/lib/poster.ts::shareEventToStory`; flag for removal.)** | **Pick a use before building (operator/A1), ranked by fit:** (1) **⭐ discovery-gap detection** — diff an artist watchlist's BiT dates against `aq_event_map`/`events`; feed untracked shows into the existing `aq_tevo_search_candidates`/`discovery_gap_alerts` pipeline (highest broker value, reuses A1 machinery; needs a cron + 1 table). (2) **new-date alerts** — poll watchlist → `event_alerts` + Slack (early acquisition signal). (3) **demand signal** — `tracker_count`/`upcoming_event_count` → `s4k_popularity_boost`/`why_signals` pricing input. (4) **Trip Planner enrichment** (D0-PROD-8) — canonical tour routing for dates not yet in our data. (5) **D4 Exos cross-link** — "artist's other tour dates" on the event page. Then decide removal of `core/instagram_share.py`. |
| A1-OPS-28 | A1 / B1 / Op | **Engines-without-ignition + doc-drift sweep (audit 2026-07-02) — parked for later analysis.** Repo-wide import-graph check (prod, non-test callers per module across root `*.py` + `core/*` + `routers/*` + `trip_planner/*`). Findings to analyze later: **(a) 2 genuine orphans** (tested/shipped, 0 prod caller) = `bandsintown_client.py` + `core/instagram_share.py` → tracked in **A1-OPS-27** (keep/wire/remove decision pending). **(b) Doc-drift** — `RESOURCES_BIBLE §1` lists route `/api/broker/bandsintown/tour` that does NOT exist in code (bible ran ahead of wiring); also §7/§1 count "10 read-only clients" incl. bandsintown though it's unwired — reconcile when A1-OPS-27 resolves. **(c) Ruled-out false positives** (do NOT re-flag): `server.py` = app entrypoint (`uvicorn server:app`), `trip_planner/*` = reachable via `core/trip_payloads.py` (`from trip_planner import …` package re-exports). Everything else has ≥1 prod importer — matches the 2026-06-19 "near-zero dead code" finding. | **Later (A1/B1):** (1) resolve A1-OPS-27 (wire vs remove the 2 orphans). (2) Fix RESOURCES_BIBLE drift once (b)'s decision lands — remove the aspirational route line or ship the route. (3) Consider making the orphan check a recurring guard (a `scripts/` importer-count audit or CI step) so new engines-without-ignition surface automatically rather than by manual sweep. Audit method archived in this session; re-runnable from the description above. |
| A1-OPS-29 | A1 | **`refresh_event_movers_agg` outgrew per-statement budgets — needs the fast-by-construction rewrite.** 2026-07-08 manual backfill measured per-window cold costs: w7 ~24min · w15+w30 ~26min (pair) · w180 ~27min · w365 ~37min (vs 361s for ALL five on 07-03; growth drivers: TD-SG burn enrollment ~1,948 events + re-lit SG sales inflating the horizon/agg CTE scans). Stopgap APPLIED: cron prefix 840s→2700s (mig `20260708164500`) — the job may hold a scheduler slot ~2h/fire at 07:20/19:20 UTC (`use_background_workers=off`), acceptable short-term only. Root chain: the gate-clamp fix (mig `20260708042000`, PR #831) exposed the true window costs, which had been masked as exact-120s timeouts. Evidence: `bot_chat` #3290; per-window timings in this session. | **A1:** rewrite `refresh_event_movers_agg` fast-by-construction per `PROJECT_BIBLE §3` doctrine — pre-aggregate the `event_metrics`/SG/TD half-window CTE scans (e.g. daily per-event rollup + incremental tail, like the zone/section rewrites migs `20260701215000`/`220000`) — then drop the 2700s prefix back to a sane budget. |
| D0-PROD-8 | D0 | **Per-performer Trip Planner — SHIPPED, needs refinement.** Optimal multi-city itinerary around a performer's tour, on the D0 performer page (Upcoming Events tab) + D0/D1 `…/performers/{id}/trip-plan` endpoints. Shared `trip_planner` module: vendored gigtrip optimizer (MIT) + a 2-budget Pareto DP (our own `budget_optimizer.py`, engine untouched). Live: dual **travel-km + ticket-$ budget** (per-show cost = getin × max(0, qty − owned), owned tickets free; global tickets/show), **city-centroid coord fallback** (un-geocoded venues no longer silent-drop), self-contained **SVG US basemap**. PRs #463 / #475 / #477 / #478 / #483. | **Refine:** (1) **unpriced events** — EVO-only concerts often lack `evo_retail_getin`; today treated as cost 0 (non-blocking), so the $ budget understates spend → add a price fallback (amalgam / TD median) or flag-exclude. (2) **map** — coarse ~50-pt US outline (no Great-Lakes cutout, intl/Canada stops clip at the frame, NE labels overlap); consider a real tile map (Leaflet, vendored) once a tile host is allowlisted (network locked here), or a finer outline + label de-clutter. (3) **D1 store parity** — `/store/test/trip` lacks the owned/$-budget controls, the basemap, and the coverage/`≈`-city display the D0 page now has. (4) **multi-performer "plan my summer"** — engine already supports a `prefs` weight map; no UI yet. (5) **value weighting** — every show valued 1.0; option to weight by demand / median / owned notional. (6) confirm single-row-per-`tevo_event_id` trust vs the aq dup / false-match landmine (PROJECT_BIBLE §3). |
| A1-OPS-24 | A1 / D0 / Op | **POTENTIAL (exploring 2026-06-08) — `last30days` social-pulse → `why_signals` → alerts + analyst bot.** Incorporate the `mvanhorn/last30days-skill` multi-platform engagement engine (Reddit/X/YouTube/TikTok/HN/Polymarket) as a NEW producer for the **dormant** `why_signals` store. Verified live: `why_signals` = 3 rows / **0 active** (only expired `weather_alert`/noaa, scope=event); `v_event_why_context` carries **0 performer signals**; the existing Reddit-RSS pulse returns **0 posts/7d** for every mapped pilot performer. Engine `--emit=compact` → per-item `{source,url,engagement,author,timestamp,score(0–100),cluster,uncertainty_tag}` maps cleanly to `why_signals` (scope=`performer`, `signal_value=score/100`, `signal_label`=cluster+top item, `weight`×uncertainty discount, `source='last30days'`, `expires_at=now()+30d`). **Pilot = 6 performers**: Knicks `16303`, Yankees `15533`, Mets `15547`, Dodgers `15558`, Inter Miami CF `72393`, LAFC `55771` (LAFC has no subreddit map — MLS gap; last30days self-resolves entities, so no seed needed). **Two target surfaces:** (1) **alerts** — a "social-buzz spike" rule in `compute_alerts_tick`/`event_alerts` keyed off the new signal; (2) **bot** — runs as a §5 hourly scheduled-task over the pilot ids. **Read-wire gap (verified):** `get_broker_event_page_v2` does NOT read the why layer (`mentions why/reddit = false` live) → needs a `why`/`social` payload key (join `v_event_why_context` on `primary_performer_id`) + an `event.js` render block. Stays **COLOR COMMENTARY only** (§6a) — never a pricing input. | **Operator greenlight required** — adds NEW external scraper APIs (ScrapeCreators/Apify/Brave/X cookies + OpenAI/XAI keys); all GET/read so lockdown rule #2-compatible, but new API spend + ToS exposure + key provisioning. Can't run in this env (keys unset, egress 403, py3.11<3.12). Then **3 small pieces** (A1 mig + D0 FE): `why_signal_upsert()` write RPC + cron/scheduled-task producer; `v2` why-key + `event.js` render; one `compute_alerts_tick` rule. Fully reversible (delete the 6 ids' rows + revert the RPC key). Don't rebuild — `why_signals`/`v_event_why_context`/`performer_subreddits` already exist. |
| A1-OPS-3 | A1 / Op | **SG broker 429 rate too high.** Listings: 63-77% pct_429 during 60d+ windows (04-09 / 17-19 UTC) + unexplained spikes at off-window hours 10/16/20-22 UTC. Sales: pre-existing 57-70% 429 even at midnight-2am UTC (before any 60d+ crons). 1235 starved events. Mitigation A: reduce 60d+ p_max 8→4 (cron body UPDATE, §1 operator gate). Root cause of sales pre-existing issue + off-window listings spikes unknown. **Concrete repro (D0 seat-map audit 2026-06-03): 10 of 30 sampled MLB home games had SG listings 2-3 days stale** (last_seen 05-31/06-01, still 1.7k-8.7k rows each) — sg_event_ids 17694869(PIT)/17692668(ATL)/17691276(COL)/17695359(CWS)/17693153(DET)/17692998(CLE)/17693805(NYM)/17694712(BAL)/17692150(SD)/17695839(TEX); fresh (<40h) events mapped 86-100%, so it's a freshness/starvation issue, not bridge/mapping. | Operator approves cron body UPDATE; A1 reduces sg_60d_listings/sales_morning/afternoon batch size 8→4. Separately investigate sales 429 root cause. (bot_chat #414) |
| D0-OPS-1 | D0 ✅ authored · A1 apply | **Apply mig `20260603120000` — `get_event_all_source_listing_metrics` RPC** (PR #413). Powers the uniform per-source distribution (listings/tickets/min/median/p90/owned_median for TEvo·SG·SH·GT·VD·TP·TM) in the Overview CROSS-SOURCE panel; replaces the TEvo/SG-only precomputed-table read. SECDEF read-only (SELECT-only, `@s4kent.com`-gated; no DDL on existing tables, no data mutation) — validated live on event 3091423. FE is deploy-safe (falls back to the legacy panel until applied). | **A1:** `apply_migration` 20260603120000 (single CREATE FUNCTION + REVOKE/GRANT). Panel upgrades automatically on next load once applied. |
| A1-OPS-2 | A1 | **`compute_event_zone/section_metrics` heavy-event timeout.** Events with 1300+ listings (e.g. Yankees, 7180 expanded qty / 185 sections) exceed even the backfill's 90s cap — root cause is the per-row `match_performer_zone()` LATERAL + `generate_series(1,quantity)` percentile expansion. Non-fatal fix (PR #289) stops the 502s but those events' breakdowns stay stale. | Optimize: dedupe `match_performer_zone` (cache per distinct section/row instead of per listing) and/or quantity-weight percentiles without physical row expansion. |
| D4-OPS-1 | D4 | **✅ FIXED IN SOURCE (PR #321) — deploy-pending.** Was: `/bridge` SW scope broken — `registerSW.ts` registered `/sw.js` (verified `GET /sw.js`→404 vs `GET /bridge/sw.js`→200 under the prefix) and `sw.js`/`manifest.json` used root-scoped paths = the hub doc, not the Bridge SPA. Fix: register `${BASE_URL}sw.js` with `scope: BASE_URL`; SW derives `BASE` from `self.location` for `SHELL` precache + offline nav fallback; manifest `id/start_url/scope/icons/shortcuts` → `/bridge/`; cache `VERSION` v4→v5. No `Service-Worker-Allowed` header needed (scope = script dir). tsc + `vite build` green. | **Deploy step (owner: key-holder):** rebuild `npm --prefix d4_bridge run build` with `.env.local` Supabase keys (PR #316 landmine) → copy `dist/ → static/bridge/`. Source-only change does NOT reach prod /bridge/ until this rebuild. |
| D4-OPS-3 | D4 | **✅ FIXED IN SOURCE (PR #321) — deploy-pending.** Was: SW `NEVER_CACHE_HOSTS` listed removed-Firebase hosts + omitted Supabase. Fix: dropped Firebase entries; never-cache any `*.supabase.co` host (dynamic suffix match, covers auth/REST/storage) + kept Stripe; refreshed comments. | Same rebuild → `static/bridge/` deploy step as D4-OPS-1. |
| D4-OPS-4 | D4 | **✅ FIXED IN SOURCE (PR #321) — deploy-pending.** Was: offline CSV export labeled voided tickets `active` (`OrganizerCheckIn.tsx` ignored the `voided` flag). Fix: `e.voided ? 'voided' : e.used ? 'used' : 'active'`. tsc green. | Same rebuild → `static/bridge/` deploy step as D4-OPS-1. |
| D4-OPS-5 | D4 ✅ built · A1 apply | **✅ FIXED IN SOURCE (PR #323) — apply pending.** Mig `20260523150000` CREATE OR REPLACEs `exos_mint_tickets` to enforce `exos_events.total_tickets` atomically in the same UPDATE that bumps `tickets_sold` (`total_tickets = 0` = uncapped, mirrors tier `capacity = 0`); a NULL-tier mint is now also bounded. RAISE rolls back the tier increment (single txn). Same signature → no overload. B1 cleared (2026-05-24). | **A1:** apply mig `20260523150000` (free-first batch per handoff doc). |
| D4-OPS-6 | D4 ✅ built · A1 apply · B1 ✅ cleared | **✅ FIXED IN SOURCE (PR #323) — apply pending.** Server-side barcode verification added. Mig `20260523160000` DROPs the 3-arg `exos_check_in_ticket` + CREATEs a 4-arg with `p_barcode_payload`: for a signed payload the server re-checks ticket id + owner + ±2-bucket window + HMAC (`extensions.hmac`, base64url — same scheme as `lib/barcode.ts`) and rejects forgeries (`barcode-rejected` / `barcode-expired`). NULL payload = manual/attested (allowed, recorded as such); legacy 3-seg skipped (rollout); a non-3/4-segment `T-` payload is now rejected as malformed. B1 cleared (2026-05-24, PR comment). SEC-LOW follow-up: sunset 3-seg bypass once all clients emit 4-seg. | **A1:** apply mig `20260523160000` (it DROP+CREATEs — no other callers on the 3-arg, B1-verified). |
| D4-OPS-7 | D4 ⏸️ DEFERRED | **⏸️ DEFERRED — free-first go-live excludes payments (operator 2026-05-23).** Scaffold built (mig `20260523170000` + `exos-checkout`/`stripe-webhook`/`exos-connect-onboard` + `lib/checkout.ts`) and stays DORMANT/unapplied — not deployed, no UI wired, no keys. D4 runs free-first (comp/issue + transfer + scan). | When resumed — **Operator:** Connect type, fee % (`EXOS_PLATFORM_FEE_BPS`), URLs, `STRIPE_SECRET_KEY`+`STRIPE_WEBHOOK_SECRET`. **A1:** apply mig `170000` + deploy 3 fns (webhook `--no-verify-jwt`). **B1:** review. **Gate:** D1-OPS-5 legal. **Open:** refund-on-sold-out-race. |
| D4-OPS-8 | D4 ✅ built · A1 apply+deploy · Op secrets | **✅ DRAINER BUILT IN SOURCE (PR #323) — apply + deploy + secrets pending.** `supabase/functions/exos-mail-drain/index.ts` (cron-gated via `requireCronSecret`, service_role) claims pending rows, sends via Resend, records the outcome. Mig `20260523130000` adds the concurrency-safe claim primitives: interim `'sending'` status + `attempts`/`claimed_at`/`last_attempt_at` + `exos_mail_claim_batch()` (FOR UPDATE SKIP LOCKED, re-claims stuck rows) + `exos_mail_mark()` (sent / failed-at-cap / pending-retry). B1 cleared (2026-05-24). | **A1:** apply mig `20260523130000` + deploy `exos-mail-drain`. **Op:** set edge-fn secrets `RESEND_API_KEY` + `EXOS_MAIL_FROM` (verified sender) + schedule the 2-min cron (snippet in the fn header; `cron.*` operator-gated). |
| D4-OPS-9 | Op + D4 | **🟠 Supabase Auth SMTP not scaled for 1000 sign-ins.** 1000 attendees each need an Auth sign-in (OTP/OAuth) to view their in-app ticket. Supabase's default SMTP rate-limits hard (a few/hr) → mass OTP at the door throttles. | Op: configure a custom SMTP provider in Supabase Auth settings + raise rate limits; D4 prefers magic-link/OAuth over email-OTP at the door and pre-event "claim your ticket" nudge to spread sign-ins off the door. |
| D4-OPS-10 | D4 | **✅ FIXED IN SOURCE (PR #321) — deploy-pending (operator chose shared-lock realtime).** Each lane subscribes to `exos_event_checkins` INSERTs for the event over Supabase Realtime (`lib/checkinChannel.ts` + wired in `OrganizerCheckIn.tsx`); any lane's check-in (online, or a reconnect-replayed offline admit) marks the ticket used on every connected lane within ~seconds, so a near-simultaneous scan elsewhere is refused. Uses postgres_changes — authoritative + RLS-gated to org staff, NOT a spoofable broadcast. On reconnect the lane re-pulls the registry to cover the offline gap. True simultaneous FULL-offline scans on two disconnected lanes stay physically unpreventable (server atomic flip + scan-reject audit are the backstop). tsc + `vite build` green; migration premise verified read-only. | **A1:** apply `20260523120000_exos_realtime_checkins.sql` (adds the table to `supabase_realtime`). **Deploy:** same rebuild → `static/bridge/` as D4-OPS-1. **Test:** 2-lane live convergence at the door rehearsal (D4-OPS-11). |
| D4-OPS-12 | D4 ✅ built · A1 apply | **✅ FIXED IN SOURCE (PR #323) — per-person buy limits enforced server-side.** Sim finding (2026-05-23): `exos_events.purchase_limits` ({maxPerOrder,maxPerAccount}) was enforced client-side only. Mig `20260523180000` adds `exos_assert_purchase_limit()` + wires it into `exos_mint_tickets` (platform-admin bypass for comp blocks); the `exos-checkout` edge fn pre-checks it too. `maxPerAccount` is **cumulative** over the buyer's non-voided holdings → a SECOND buy that would exceed the limit is refused. Branch-verified: order-limit, 2nd-buy account-limit (hold 3 +2>4 reject; +1=4 ok; +1 reject), admin bypass, no-limit regression — all pass. | **A1:** apply mig `20260523180000`. **Residual:** two simultaneous checkout tabs can still race past `maxPerAccount` (no inventory hold — tied to D4-OPS-7); tier+event caps are the hard backstop. |
| D4-OPS-13 | D4 ⏸️ DEFERRED | **⏸️ DEFERRED — extra-reach later; not in free-first go-live.** Distribution scaffold built (mig `20260523190000` + `exos-distribute`), GATED + INERT, unapplied/undeployed. The EVO/Automatiq outbound channel is a later add once the free-first D4 core is live. | When resumed — **A1:** apply mig `190000` + deploy. **Op:** Automatiq/Lysted creds + Hard-Rule-2 sign-off. **D1 follow-up:** dedupe/route EVO listings via `bridge_event_xref`. |
| D4-OPS-14 | D4 ✅ built · A1 apply | **✅ GROWTH PRIMITIVES BUILT (PR #323) — venue/promoter marketing, LIVE non-gated parts.** Mig `20260523200000`: (a) `exos_redeem_discount_code` — promo/access-code validation (presale/unlock via `unlocks_tier_ids`); (b) `exos_announce_to_followers` — owned-audience email blast reusing `exos_org_follows` + the mail queue (`event-announce` template; recipients server-derived → no open relay); (c) `exos_orgs.marketing` jsonb (socials + pixel-ID config); (d) Bandsintown/Google added to the distribution channel model. Branch-verified 7/7. | **A1:** apply mig `20260523200000`. **Deferred/gated (Growth workstream):** publishing to Bandsintown/Google/social = upstream WRITE → Hard-Rule-2 + creds (scaffold via `exos-distribute`); rendering 3rd-party **pixels + JSON-LD** on public pages = CSP + consent → **B1**; per-event OG/SEO on the React SPA needs meta-injection/SSR. |
| D4-OPS-15 | D4 ✅ built · A1 apply | **✅ TICKET-ISSUANCE / PURCHASE MAIL ADDED (PR #323).** Mail audit found transfers (`transfer-initiated`/`-claimed`) + org-invite wired, but **no issuance/purchase confirmation**. Mig `20260523210000` adds the `ticket-issued` template + `exos_queue_ticket_issued(ticket_id)` (server-derives recipient from the ticket owner — no open relay; caller = owner or org staff). Wired into the claim flow (`ClaimTicket.tsx` → new owner gets a "ticket ready" email) + `lib/mail.ts queueTicketIssued`. Same shape as the branch-verified announce RPC. | **A1:** apply mig `20260523210000`. **Wiring TODO:** the deferred Stripe `exos_fulfill_checkout` should queue `ticket-issued` to the buyer when payments go live. |
| D4-OPS-16 | D4 ✅ built · A1 apply | **✅ HOLDER NOTIFICATIONS WIRED (PR #323).** `event-cancelled`/`event-updated` templates existed but nothing triggered them (cancelEvent only flipped status; the EditEvent "emails holders" comment was aspirational). Mig `20260523220000`: `exos_notify_event_holders(event_id, template)` — one mail per DISTINCT non-voided holder, server-derived (no open relay). `cancelEvent` now **auto-notifies on cancel**; `notifyEventHolders()` helper available for the update case. Pattern-identical to the branch-verified announce RPC. | **A1:** apply mig `20260523220000`. **Follow-up:** ✅ "notify attendees" button wired in EditEvent for `event-updated` (published-only, explicit; `notifyEventHolders` returns the recipient count for the toast). Pending A1 apply of the RPC. |
| D4-OPS-11 | D4 / Op | **🟡 DB-side load VALIDATED on a branch (PR #321, 2026-05-23); physical rehearsal still pending.** Harness `d4_bridge/scripts/loadtest_checkin.sql` models the mint hot-counter + check-in atomic-CAS on a throwaway branch. Results: minted 1000 tickets (~14ms, counters consistent); **8 concurrent lanes checked in all 1000 exactly once with 0 double-audits**; a 6-lane stampede on the same 50 tickets produced **exactly 50 admits, 0 doubles** — the atomic guard holds. In-DB throughput is not the bottleneck (µs/op). NOT covered: end-to-end PostgREST/RLS + network latency per scan (the real cost), camera/device throughput per lane, live 2-lane Realtime convergence (D4-OPS-10), and the Auth OTP sign-in spike (D4-OPS-9). | Physical door rehearsal on the DEPLOYED app, 2-3 devices: real RPC latency under concurrent scans, 1000-row registry pull, cross-lane Realtime convergence, mass sign-in. Re-run the harness for a regression baseline. Gate go-live on it. |
| D1-OPS-1 | D1 (B1 for CSP) | **JSON-LD structured data deferred from Sprint 4a (PR #166).** Event pages have OG/Twitter tags but no `Event` schema.org JSON-LD → no rich result eligibility in Google. `<script type="application/ld+json">` is blocked by CSP `script-src 'self'` (verified live: CSP unchanged on `/store/event/*`). | Pick a path: (a) B1 reviews adding a `sha256-` hash for the JSON-LD block to `script-src`, or (b) serve JSON-LD from a crawlable static endpoint. `Organization` schema on `/store` is the easy first win (static, no per-event data). |
| D1-OPS-3 | D1 | **`store.js` ships unminified — 2105 lines** to every visitor on every uncached load. Sprint 5 polish item; no build step exists in the repo today. | Add a minify step (esbuild/terser) emitting `store.min.js`; reference the minified file from the HTML shells via the existing `?v=<sha>` pattern. Keep source `store.js` as the edit target. |
| D1-OPS-5 | D1 / Op | **Legal page copy is placeholder.** about/privacy/terms ship with "placeholder; consult counsel before launch" text. Hard blocker before any real-purchase path (Sprint 2 / Stripe onboarding). | Operator provides counsel-reviewed Privacy + Terms copy; D1 wires it into the existing shells. No code change beyond content swap. |
| D1-OPS-6 | D1 / Op ⏸️ DORMANT | **TEvo Hosted Checkout wired but NOT enabled (PR #—).** Reserve→hosted-checkout redirect (`https://<domain>/checkout/payment/<event_id>/<ticket_group_id>?quantity=N`, TEvo = MOR) is gated behind env `STOREFRONT_CHECKOUT_DOMAIN`. **Unset (prod default) = MVP mock stays, no real purchases.** Pure browser redirect — no backend write, RULE 2 not involved; `/api/public/config` exposes `checkout_domain`/`purchase_enabled`. | **To ENABLE (operator-gated):** (1) operator + TEvo rep provision the hosted-checkout subdomain (e.g. `checkout.vibepass.com`); (2) point DNS — CNAME `checkout`→`cname.vercel-dns.com.`; (3) land real legal copy (**D1-OPS-5** gate); (4) set Render env `STOREFRONT_CHECKOUT_DOMAIN=<subdomain>`; (5) confirm seller-side fulfillment routing with TEvo rep (does our owned-inventory sale auto-fulfill, or do we need the accept/deliver-etickets write-client?). Drop the "MVP · browse only" badge on enable. |
| D1-OPS-7 | D1 done · A1 deploy | **Storefront concierge OFF (cost) + Grok/xAI adapter authored, pending A1 activate.** Kill-switch `STOREFRONT_CONCIERGE_ENABLED` defaults false → `/api/store/retail-chat` short-circuits with a friendly canned reply (HTTP 200, widget renders it as a normal message), **zero Anthropic spend** (PR #623). Grok adapter added to `supabase/functions/chat/index.ts` **INERT** (default `LLM_PROVIDER=anthropic`); translates the Anthropic-shaped loop ↔ xAI OpenAI schema, scope=owned clamp untouched. grok-4.1-fast = $0.20/$0.50 per 1M vs Haiku 4.5 $1/$5. Filed `bot_chat` #2401. | **A1:** `deno check` + deploy the chat edge fn; set env `LLM_PROVIDER=grok` / `LLM_MODEL=grok-4.1-fast` + vault secret `xai_api_key`; then flip `STOREFRONT_CONCIERGE_ENABLED=true` on `vibepass-storefront-test`. Recommend a tool-trigger prompt test pass (SYSTEM_PROMPT is Claude-tuned). |
| D2-OPS-1 | A1 apply | **Metrics tab reads dormant SG source.** 6 `d2_metrics_*` RPCs still filter `source IN ('evo','seatgeek',...)` → Metrics tab aggregates the dormant seller-side `seatgeek` (~$0) instead of the broker firehose `seatgeek_sales` (~$4M/hr). The Orders tab swapped to the firehose on 2026-05-16 (PR #147) but this companion RPC swap never applied. Verified live 2026-05-22 (`bool_and(... ILIKE '%seatgeek_sales%') = false`). | A1: `apply_migration` the **existing in-repo file** `20260516200000_d2_metrics_swap_sg_to_sg_sales.sql` (PR #147). Verified non-stale 2026-05-22 — live `d2_metrics_window` body is byte-identical except the source-IN list, so it's a clean swap with no drift-revert risk. |
| D2-OPS-2 | D2 → D0 deploy | **Broker-sales views not wired into dashboard FE.** `v_sg_broker_sales_by_section` + `v_sg_broker_sales_by_event` are live in prod (PR #158) but referenced nowhere in `d2_dashboard/*` (grep-verified 2026-05-22). Operator intent 2026-05-16: "for use later in front end view." | D2 adds a dashboard panel/tab reading the views (section-grain rows + per-event "heat" rollup); deploy via D0. |
| D2-OPS-3 | A1 apply + Op + SG | **WS2 SG SellerDirect webhook receiver not live.** Code merged (PR #149) but verified absent in prod 2026-05-22 (audit table + ingest RPCs + edge fn all missing). | A1: `apply_migration` 3 migs (`20260516210000/210100/210200`) + deploy `sg-seller-webhook` edge fn. Op: set vault `SG_SELLER_WEBHOOK_SECRET` + file SG support ticket (URL + token + 8 notification types). See `tests/test_sg_seller_webhook_contract.py` `SG_LIVE_TEST_PLAN`. |
| A1-OPS-4 | A1 | ~~**`listings_aq_backfill_overnight` still 120s-bounded despite `SET LOCAL`.** pg_cron's system-level 120s hard limit overrides `SET LOCAL statement_timeout='3min'`.~~ **OBSOLETE 2026-06-01** — cron disabled (`active=false`, mig `20260601120000`). The fix described here ("escape the 120s limit") is moot: `listings_snapshots.aq_short_event_id` has no reader and the cross-source market-tracking intent is already served by the working `event_id→ticketsdata_event_xref→aq_event_map` path (`get_event_cross_source_metrics`). Re-enabling would require BOTH a real reader AND the timeout fix. | None — closed-obsolete. |
| A1-OPS-6 | A1 / Op | **D4 Railway service decommission.** `static/bridge/` is current as of the 2026-05-25 rebuild and served from Render; the Railway host is now redundant. | Delete the Railway service once confirmed healthy on Render. (migrated from PROJECT_BIBLE §10) |
| D4-OPS-29 | A1 / B1 | **`exos-media` owner-scoped read policy missing (62h+).** Storage DDL not yet applied: `CREATE POLICY … ON storage.objects WHERE bucket_id='exos-media' AND owner=auth.uid()`. Flagged by D4 in bot_chat #562. | A1 apply the storage policy; B1 review. (migrated from PROJECT_BIBLE §10) |
| A1-OPS-10 | A1 / Op | **2026-05-29 `main` pushes bypassed branch protection.** The 4 TD/SG migration commits (TD-focus, floor-sweep, TickPick ×2) were pushed to `main` with A1 bypass rights — remote reported "Bypassed rule violations: 3 of 3 required status checks expected." Migrations were prod-validated first, but CI wasn't a merge gate. | Confirm A1 direct-push-with-bypass is the intended `main` promotion mechanism (vs PR + CI). If not, route future A1 promotions via PR. |
| A1-OPS-12 | A1 | **`20260528380000` applied to prod but uncommitted on `main`** (repo↔prod drift). The TD↔TEvo linkage mig (`refresh_td_event_links` + xref tevo columns) is live + logged in MIGRATION_CONVENTIONS §14, but the file is untracked in the working tree — a fresh `supabase db reset` from `main` would not reproduce prod. | A1: verify the untracked file matches applied prod state, then commit it to `main`. |
| A1-OPS-14 | A1 / Op | **Shared-working-tree contention.** Multiple sessions operate in the shared root `C:\VibeCode\terminal-2`; a branch-switch there rewrites files under other sessions → stranded work (hit live 2026-05-29 — D0 switched the root to `claude/d0-discovery-fixes` mid-A1-task). Discipline rule shipped: PROJECT_BIBLE §1 rule 9 + §11 self-check (each session uses its own `.claude/worktrees/<session>/`, never the shared root). | **Optional hard enforcement (operator-gated, settings.json):** a `SessionStart` hook that detects CWD == shared root and auto-creates/cd's to a per-session worktree (or warns loudly), and/or a `PreToolUse` guard blocking `git checkout`/`switch`/`reset` targeting the shared root. Decide whether the policy rule suffices or wire the hook. |
| A1-OPS-15 | A1 / Op | **`espn_injuries_snapshots` bloat.** Table is **175 MB for ~16.5k live rows** (~10 KB/row; `n_dead_tup` low at ~2.8k, so it's accumulated free-space / wide-row bloat, not active churn). The event-page chain's reads of it are now index-bounded (mig `20260530120000`), so it's off the hot path — but any future unbounded scan (or a NULL-team filter that matches nothing) still re-reads the full 175 MB. Discovered during the 2026-05-30 terminal SQL audit (it was the dominant event-page timeout cause via a no-WHERE `max()`). | `VACUUM FULL public.espn_injuries_snapshots` (ACCESS EXCLUSIVE, ~seconds for 175 MB → est. ~5–10 MB; **operator-gated** for the brief table lock) and/or fix the espn-injuries collector's write pattern (dedup / TTL) so it stops re-bloating. Low urgency — off the hot path post-audit. |
| A1-OPS-16 | A1 | **Retention Wave 2 — SG-sales dedup.** Follow-up to the 2026-05-31 collector-cadence + retention overhaul (Wave 1 = mig `20260531180000`; MIGRATION_CONVENTIONS §14). `seatgeek_sales_snapshots` re-inserts each logical sale every poll (11–23× overcount; PROJECT_BIBLE §3) → the 30d raw window carries ~20× the real rows. | Author the SG-sales dedup migration (dedup key `(sg_event_id, sg_sale_id)` keep-latest, or a deduped rollup + raw TTL). Coordinate D2 (owns `seatgeek_sales_snapshots`). |
| A1-OPS-17 | A1 | **Retention Wave 3 — change-detection [IN PROGRESS by A1, 2026-05-31].** Only persist a new snapshot row when the listing/metric actually changed vs the prior capture (skip no-op re-inserts), cutting firehose growth at the source rather than sweeping after. | Being authored now (A1). Land the change-detection write-gate on the high-churn snapshot writers; verify no signal loss vs the daily medians. |
| A1-OPS-18 | A1 / Op | **Retention Wave 4 — partitioning + VACUUM FULL.** After Waves 1–3 shrink the churn, range-partition the big snapshot tables (by `captured_at`) so the 30d sweep becomes a partition DROP (no dead-tuple churn), plus a one-time `VACUUM FULL` to reclaim accumulated bloat. | Wave 4 partitioning migration (staged); `VACUUM FULL` pass is **operator-gated** (ACCESS EXCLUSIVE). Folds in A1-OPS-15 (espn_injuries) + the listings/sales firehoses. **`listings_snapshots` runbook AUTHORED `20260619220000_partition_listings_snapshots_BLUEPRINT.sql`** (stage-gated; attaches the existing 123M-row table as the historical partition so there's no copy/`VACUUM FULL` — supersedes the VACUUM-FULL framing for this table; requires a maint window + a follow-up partition-maker/retention cron before cutover). |
| A1-OPS-19 | A1 | **Part D — post-event report.** Collector-cadence overhaul follow-up: once an event passes, emit a durable post-event summary (final medians / sell-through / cadence coverage) so the indefinitely-retained `event_listing_snapshot_daily` has a closing rollup per event. | Author the post-event report job (reads the daily snapshot ladder + sales). Scoped, not yet started. |
| A1-OPS-20 | A1 | **evo_discover Phase-2 — new-event ingestion.** The 2026-05-31 cutover re-added a low-freq `collect-listings` discovery sweep (mig `…200000`) as the interim new-event path. Phase-2 builds proper `evo_discover` new-event ingestion (catalog-walk → enqueue new TEvo events into the per-event poller) so discovery isn't piggy-backed on the broad sweep. | Author `evo_discover` Phase-2 (new-event detection → `evo_listings_poll_state` seed). Follow-up to the discovery-sweep re-add. |
| A1-OPS-21 | A1 / Op | **SG non-owned listings poller is OFF + raw-listings retention drain in flight** (migs `20260603180000` + `…190000`, PR #423, applied 2026-06-03). (a) `sg_listings_poll_nonowned_5min` is wired but `cron_policy.enabled=false` per operator ("only poll owned for now"); owned (`sg_listings_poll_owned_1min`) is ON. Non-owned has a ~1,700-event poll backlog parked. (b) ⚠️ **CORRECTED 2026-06-17 (PR #568): the drain was NEVER running.** `sweep_old_listings()` was throwing `column "id" does not exist` on EVERY daily run since at least 2026-06-15 — the function did `SELECT id … DELETE WHERE id IN (…)` but `listings_snapshots` has no `id` column (key is `event_id`+`captured_at`). So 15d retention was never enforced and the table grew to **45 GB / ~121 M rows** (≫ the documented 18 GB / 8–9.6 M — RESOURCES_BIBLE §2.2 is stale, see B1-NEXT-25). **FIXED**: function rewritten to delete by `captured_at` via `ctid` (matches `sweep-old-section-metrics`), branch-tested + `apply_migration` to prod 2026-06-17; first manual run committed (oldest row 04-23→04-27). | (a) Decide when to re-enable non-owned: `UPDATE cron_policy SET enabled=true WHERE jobname='sg_listings_poll_nonowned_5min'` — first day draws harder on the shared SG token to clear the backlog (consider a temporary `p_max` bump). (b) **Now actually draining** via the fixed daily cron (~4d of backlog/80s-run → ~2 wks to reach 15d). **Disk is NOT reclaimed by deletes** — the 45 GB file needs the operator-gated `VACUUM FULL` (folds into A1-OPS-18, Wave 4); a one-time faster bulk purge (temp longer `statement_timeout` or batched) would shorten the drain if wanted. |
| A1-OPS-29 | A1 / Op | **Retention redesign AUTHORED, prod apply pending (migs `20260705153000`/`153500`).** All 4 listing-data TTL sweeps were toggled off out-of-band on 2026-07-01 (scheduler-wedge day; no migration trail — audit AUD-16) and `listings_snapshots` reached **75 GB / ~227M rows, oldest row 36d vs 15d policy**. Redesign: `retention_policy`+`retention_tick_hourly` (single engine, in-data kill switch, run log, deadman) retires the `sweep-old-*` family; NEW `venue_section_price_daily` (venue-anchored per-section daily medians w/ performer + away-team dims, INDEFINITE) seals section history before the 60d `section_metrics` TTL; read layer `venue_section_{performer,opponent}_agg` (teams vs concert performers kept separate) + RPC `get_venue_section_medians` + D0 venue-page SECTIONS tab. | (1) Operator-gated **apply** of both migrations (Applier action); (2) on apply, watch `retention_run_log` — the ~130M-row `listings_snapshots` backlog drains over the first day of hourly ticks; (3) operator decision: flip `retention_policy.enabled` for `seatgeek_listings_snapshots` with/after the SG-listings resume; (4) verify `venue_section_rollup_state` seals the trailing ~64d of `section_metrics` (catchup runs oldest-first, ~3 days/hr). Disk reclaim still needs A1-OPS-18 (partition/VACUUM). |

### Operator-supplied repos to evaluate (filed 2026-06-08)

External repos the operator dropped in for triage. **EVAL only** — not adopted; no work started. Each needs a keep/drop decision before any integration.

| ID | Repo | What it is + relevance | Action / verdict |
|---|---|---|---|
| EVAL-1 | [`Lum1104/Understand-Anything`](https://github.com/Lum1104/Understand-Anything) ✅ WIRED · ⏸️ TRIAL DEFERRED (revisit: fresh session) | Claude Code plugin: turns a codebase into an interactive knowledge graph (tree-sitter static analysis + LLM agents). MIT. Tagline "Graphs that teach > graphs that impress." (Note: operator's link was the `Egonex-AI` mirror; canonical upstream is `Lum1104/Understand-Anything`.) | **Plausibly useful** as a dev/onboarding aid for *this* repo (625 migrations, 212 tables, 5k-line `event.js`/`app.py`) — could shorten per-session codebase comprehension. Low risk (read-only analysis tool). ✅ **WIRED 2026-06-08 (user-scope, live this session)** — `claude plugin marketplace add Lum1104/Understand-Anything` + `install understand-anything`; verified `enabled`. Exposes 8 skills (`understand`, `-onboard`, `-explain`, `-dashboard`, `-diff`, `-domain`, `-knowledge`, `-chat`) + 9 agents; **~613 tok always-on** per session. ⚠️ **Durability blocked:** `.claude/` is gitignored (`.gitignore:33`) + the container is ephemeral, so it does NOT persist cross-session. To make it durable = **operator decision to un-ignore `.claude/settings.json`** (would commit `extraKnownMarketplaces`+`enabledPlugins` for all sessions). **TRIAL (2026-06-08): blocked in THIS web sandbox — defer to fresh session.** Skill registers next session (mid-session install isn't invocable in-session). Its analysis is LOCAL (tree-sitter + LLM agents, no external HTTP), so egress is NOT a blocker → it IS trialable in a fresh Claude Code session on this repo. Pending that run for the keep/drop verdict. |
| EVAL-1b (last30days) | ✅ WIRED · ⏸️ TRIAL DEFERRED (revisit: networked/local session) | The `mvanhorn/last30days-skill` social-research plugin (see A1-OPS-24 for the deeper `why_signals` data integration) — wired as a TOOL alongside EVAL-1 per operator "try both". | ✅ **WIRED (user-scope, live this session)** — marketplace + `last30days` skill installed + `enabled`. Zero-config sources (Reddit/HN/Polymarket/GitHub) run without keys; X/TikTok/YT/Brave need keys (unset). **~62 tok always-on; ~36k on-invoke.** Same durability caveat as EVAL-1 (`.claude/` gitignored → no cross-session persistence without un-ignoring). This wires the *tool*; the **A1-OPS-24** build (feed `why_signals` → event color-commentary) remains the separate, operator-gated data-layer integration. ❌ **TRIAL (2026-06-08): cannot run in this web sandbox — ALL data sources egress-blocked (403): reddit.com, hacker-news.firebaseio.com, gamma-api.polymarket.com, api.github.com.** The sandbox allowlists only a few hosts (github git-clone + npm). A run would fetch nothing. To trial: a Claude Code session whose egress permits those hosts (local/desktop) + keys for X/TikTok/YT. Not a wiring fault — environment network policy. |
| EVAL-2 | [`rohitg00/ai-engineering-from-scratch`](https://github.com/rohitg00/ai-engineering-from-scratch) | 503-lesson AI-engineering curriculum (foundations → agents/multi-agent/safety), Python/TS/Rust/Julia. MIT. | **Reference/learning resource**, not an integration. Mild relevance to the §6 LLM analyst-layer build (`docs/d0_llm_analysis_layer_spec.md`). No code action — link it from analyst-layer docs if useful. |
| EVAL-3 | [`CloakHQ/CloakBrowser`](https://github.com/CloakHQ/CloakBrowser) | ⚠️ Stealth Chromium that **defeats bot-detection** (Cloudflare Turnstile / reCAPTCHA v3 bypass via 58 C++ source patches); drop-in Playwright/Puppeteer. MIT wrapper + custom binary license. | ⚠️ **GOVERNANCE CONFLICT — recommend DROP.** Antithetical to the hard lockdown (`CLAUDE.md §2`: every upstream source is read-only via **official GET endpoints**; `*_client.py` is GET-only by construction; no detection evasion). The data layer ingests via official broker/TD/SG APIs, not by scraping detection-protected sites. Adopting a detection-evasion browser would breach §2 + the listing-source lockdown and the project's ToS posture. **Do not integrate without explicit operator authorization + B1 security review of the ToS/legal implications.** Cataloged for awareness only. |

### Known data-architecture gaps (workarounds, not bugs — don't rediscover)

> Migrated from PROJECT_BIBLE §10 (2026-05-28). These are durable shape-of-the-data facts with a standing workaround — not actionable bugs. Don't waste cycles rediscovering them. (Resolved/shipped items from the old §10 drift watchlist live in `MIGRATION_CONVENTIONS.md §14` and `CHANGELOG.md`.)

| Gap | Status | Workaround |
|---|---|---|
| `tevo_event_id` on SG snapshot tables | Partial: PR #178 backfilled to 87.35%; mig `20260517160000` makes NEW rows born populated where an xref exists | Query by `sg_event_id` when `tevo_event_id IS NULL` (no xref) |
| `seatgeek_event_xref.last_listings_at` / `last_sales_at` | Dead globally (0/967) | Use `MAX(captured_at)` on the snapshot tables |
| `sg_events_canonical.has_v2_listings_pulled` | Dead (25/4609 = 0.5%) | Same — use `MAX(captured_at)` |
| `aq_short_event_id` on `listings_snapshots` | 0% populated (backfill cron **disabled** 2026-06-01, mig `20260601120000` — no reader; superseded by `event_id→tdx→aq_event_map`) | Use `event_id` for TEvo reads |
| ESPN snapshot pipeline = gameday-scope only | Specced, not built | Forward-look ESPN panels empty by design; use `espn_event_date_lookup` for forward-look team IDs / `game_at_utc` |
| ~29% active TEvo events have no SG bridge | NWSL/USL/AHL/niche — real coverage gap | First-class TEvo-only UI state |
| SG doesn't carry most NFL regular-season | SG coverage decision | NFL Event Detail renders TEvo+ESPN+AQ; SG hidden |
| SG broker `/v2/listings` (all-marketplace) OFF since ~2026-05-14 | Superseded by broker `/listings` (now `sg_listings_floor_sweep`); empirically `/v2` ≈ identical data to `/listings` | Use `/listings` (floor-sweep) for marketplace depth. The legacy `sg_listings_*` (jobids 53–58) `/v2` crons stay disabled; re-enable only if full-competitor visibility beyond `/listings` is ever needed. |
| SG listings = 3 feeds, one shared token (w/ external prod program) | Architecture fact (PROJECT_BIBLE §3) | broker `/listings` (market) + `/v2/listings` (off) + seller `/listings` (owned). Burst ≈10 req/8s shared; watch `v_sg_token_budget`. |
| `TRACK_BLINDSPOT` tier ≠ unmapped | 99%+ ARE aq+tevo mapped (PROJECT_BIBLE §3) | It's `owned_cnt=0` ownership tier; don't treat as a mapping gap. |
| Reddit *sentiment* / SeatData / TickPick-orders ingest **dormant** | Intentional (operator 2026-06-03 data-health audit): no active crons — `reddit_posts` sentiment RSS paused, `seatdata_listings` empty + `seatdata_sales` ~25d, `tickpick_orders_queue/_process_30min` `active=false` (~3d) | **Don't re-flag in freshness audits.** Re-enable only on operator request. NOTE: the Reddit *news ticker* (`reddit_news`, crons `reddit_news_*`) WAS re-enabled by operator 2026-06-26 — that path is expected-active, distinct from the paused sentiment pipeline. |
| `release_health_check.subhourly_jobs_silent_90min` false positives | Its expected-job list is stale — flags RETIRED crons (`collect-listings-7-30d/30-60d`) + off-window TD drains (`td_pull_drain`/`td_normalize_drain` only run 16–23,0–4 UTC) as "silent" | Ignore those entries; optionally refresh the check's expected-job list. |

---

## 🌿 BRANCHES / PRs IN FLIGHT — git tracker *(snapshot 2026-06-17)*

**Tracks the live git surface alongside the work ledger above.** One row per **open PR** (the actionable in-flight branches), lane inferred from the title scope. Re-snapshot via `mcp__github__list_pull_requests state=open` + `list_branches`. Closing protocol mirrors OPEN WORK: when a PR merges/closes, drop its row (history is in the PR + `MIGRATION_CONVENTIONS §14`).

| PR | State | Lane | Branch | Updated | Title |
|---|---|---|---|---|---|
| [#570](https://github.com/JulianS4K/Terminal-2/pull/570) | DRAFT | C1 | `claude/gallant-heisenberg-2k2ome` | 06-17 | workflow-skills layer + 4-domain reorg *(this PR)* |
| #568 | DRAFT | A1 | `claude/practical-albattani-5am7e7` | 06-17 | `sweep_old_listings` deletes by `captured_at` |
| #564 | DRAFT | D4/B1 | `claude/vigilant-hamilton-53kqtm` | 06-16 | run exos migrations + SQL tests on real Postgres |
| #563 | DRAFT | D4 | `claude/fix-d4-vite8-manualchunks` | 06-16 | `manualChunks` fn form for Vite 8 compat |
| #562 | DRAFT | B1 | `claude/sweet-archimedes-7k9o57` | 06-16 | allowlist false-positive secret-scan hits (#242) |
| #561 | DRAFT | D1 | `claude/affectionate-bardeen-x4j0eh` | 06-16 | make interactive venue seat map render |
| #560 | open | D0 | `claude/eager-volta-vkvm5r` | 06-17 | home movers 30d default + exclude EVO-owned |
| #559 | DRAFT | A1/D0 | `claude/exciting-noether-2zq7st` | 06-16 | pause non-AXS TicketsData crons + AXS budget split |
| #547 | open | B1-deps | `dependabot/pip/cryptography-…` | 06-15 | bump cryptography |
| #546 | open | B1-deps | `dependabot/pip/fastapi-…` | 06-15 | bump fastapi |
| #545 | open | B1-deps | `dependabot/pip/anthropic-…` | 06-15 | bump anthropic |
| #544 | open | B1-deps | `dependabot/npm/d4_bridge/…` | 06-13 | bump esbuild, vite, tsx in /d4_bridge |
| #543 | DRAFT | D4 | `claude/lucid-mccarthy-6pglsf` | 06-11 | secure standalone-server checkout + prune Firebase |
| #536 | open | C1 | `claude/c1-checkpoint-2026-06-10` | 06-10 | daily checkpoint 2026-06-10 |
| #514 | DRAFT | (explore) | `claude/epic-turing-w89nn4` | 06-09 | open-notebook publisher POC |
| #506 | open | D0/ops | `feat/render-deploy-webhook-bridge` | 06-09 | Render deploy-webhook → GitHub Actions bridge |
| #505 | DRAFT | A1/D0 | `claude/loving-darwin-nhzj1d` | 06-09 | fix `seating_chart 'null'` poison at TEvo ingest |
| #502 | open | C1 | `claude/c1-checkpoint-2026-06-08` | 06-10 | daily checkpoint 2026-06-08 |
| #495 | DRAFT | (explore) | `claude/funny-ride-wx3m1b` | 06-08 | Fantasy League — player-stats ingest + H2H |

> **Orphan branches (no open PR) — C1 prune (tracked in C1-OPS-2).** ~19 `claude/*` + 2 `a1/*` remote branches have no open PR (merged or abandoned) — e.g. `a1/optimize-zone-section-metrics`, `a1/ticketsdata-integration`, `claude/d0-aq-tevo-bridge`, `claude/store-tour-agent`, `claude/sports-player-search-9nnrcz`, `claude/resume-d0-chat-itUGb`, … (full list: `git branch -r`). Automated branches (`release-please--*`, `dependabot/*` with open PRs above, `gh-pages`) are exempt. C1 to confirm-merged-then-delete as part of the drift sweep.

---

## DOING

### DOING (design) — Design handoff: 6 broker templates + 2 parallel-product designs (DONE — ready for review)

- **What**: Three deliverables in this session, all in `design/`:
  1. **`design/preliminary-event-views-2026-05-08.md`** — 6 broker-terminal view templates with ASCII wireframes:
     - T1 Event Workbench (single-event, the workhorse)
     - T2 Performer Console (sports + non-sports variants)
     - T3 Venue Pulse (mode-tabs: home-team / concert / comedy / other)
     - T4 Pricing Queue (`J/K` keyboard flow for re-pricing 47 events in a sitting)
     - T5 Metro Watchlist (competing-events demand-overlap)
     - T6 Series / Season / Tour Aggregator (MLB 5-game, NBA full season, 47-stop tour)
     - Plus: structural decisions on Julian's 5 questions, 11-row × 6-template simulation grid, metrics have/need audit, LLM analysis-layer slot reserved for Grok hookup, build sequence integrated with code's prior memos.
  2. **`design/retail-site-2026-05-08.md`** — public buying site at `/shop` + `/shop/event/{id}`:
     - Two-API architecture (`/api/retail/*` mirrors `/api/broker/*` with code-enforced wall via `retail_inventory_v` view)
     - Three surfaces: catalog, event detail + seat picker, chatbot side-panel integration
     - Telemetry-as-product: `retail_events` table feeds the chatbot training corpus
     - 8 retail-persona scenarios scored across site flows
  3. **`design/undelivered-window-2026-05-08.md`** — fulfillment ops view (internal only):
     - One normalizing view (`undelivered_orders_v`) across EVO + SG + Vivid + StubHub + retail + wholesale
     - Single dense ops board with default sort by time-to-event (red T-0/T-24h first)
     - Hold-expiry alert lane (separate from delivery queue)
     - Bulk action: "deliver all 76 for Knicks G5" — the highest-leverage feature
     - 9 fulfillment-scenario simulations
- **Plus 3 frontend skeleton files** (added on Julian's "build templates, frontend only" follow-up):
  1. **`static/_proposals/templates.html`** — broker terminal · 6 templates · hash-router (`#workbench` / `#performer` / `#venue` / `#queue` / `#metro` / `#series`). Each template fully laid out with placeholder data and `<span class="todo">` markers on every backend hook. Uses CSS variables matching `static/index.html`.
  2. **`static/_proposals/shop.html`** — retail buying site · 4 hash-routed views (`#catalog` / `#event/{id}` / `#cart` / `#account`). Light theme (deliberately opposite density of the broker terminal). Chatbot side-panel with bidirectional handoff. Strict wall: file references only `/api/retail/*`, never `/api/broker/*`.
  3. **`static/_proposals/undelivered.html`** — fulfillment ops board. Pinned hold-expiry banner, KPI strip, filter chips, dense board with time-to-event color coding, drawer for row click, bulk-deliver-for-event modal. Reads from `unified_orders` (the canonical view from mig 20260509140000 — supersedes the `undelivered_orders_v` placeholder I sketched in the original doc).
- **Plus 1 notes-for-code file**:
  - **`design/CODE_NOTES_2026-05-08.md`** — every backend hook the 3 skeletons assume, organized as: existing endpoints to wire / NEW endpoints to build / new tables/views proposed / wiring sequence / open questions. Designed so code reads top-to-bottom and knows exactly what to build without touching frontend.
- **Plus, after Julian's TEvo-templates ask + media-asset ask**:
  - **Rewrote `static/_proposals/shop.html`** to follow the canonical TEvo template set per the API-01..API-10 docs Julian uploaded:
    - 7 hash routes: `#home` · `#performer/{slug}` · `#venue/{slug}` · `#event/{id}` · `#search` · `#cart` · `#account`
    - Comprehensive search with typeahead dropdown (groups: Events / Performers / Venues per `/searches/suggestions`)
    - Performer LP — slug URL + showPerformer + listEvents(performer_id) per API-06
    - Venue LP — slug URL + showVenue + listEvents(venue_id) per API-07
    - Event LP — showEvent + listings(event_id), with seatmaps-client placeholder + static fallback (real Citizens Bank Park static map URL) per API-08
    - Cart/checkout flow — Client creation (nested company/email/address/phone per API-09) + Braintree drop-in mount (API-10)
    - Wall held: 0 broker-namespace references; only retail namespace.
  - **Added `design/MEDIA_ASSETS_2026-05-08.md`** mapping every available media asset (ESPN team logos, ESPN player headshots, TEvo static + dynamic seat maps, TEvo `meta.image`, S4K `venue_assets`) to each project surface. Catalogues 5 sources, then maps each surface in all 3 projects to its preferred resolve-order (S4K venue_assets → ESPN logo → TEvo meta.image → static map → gradient fallback). Includes channel-logo plan for the undelivered window (self-host wordmarks for EVO/SG/Vivid/SH).
- **Files touched (this session, all design-owned)**: `design/preliminary-event-views-2026-05-08.md` (now 6 templates), `design/retail-site-2026-05-08.md`, `design/undelivered-window-2026-05-08.md`, `design/CODE_NOTES_2026-05-08.md`, `design/MEDIA_ASSETS_2026-05-08.md`, `static/_proposals/templates.html`, `static/_proposals/shop.html` (rewritten to TEvo pattern), `static/_proposals/undelivered.html`.
- **NOT touched**: `app.py`, `evo_client.py`, `seatgeek_client.py`, `seatdata_client.py`, `supabase/migrations/*`, `supabase/functions/*`, `SCHEMA.md`, `AGENTS.md`, `static/index.html` (still has BLOCKED chart-range-switcher edits from earlier in this session — separate row).
- **Reads from**: `docs/terminal-redesign-2026-05-09.md`, `docs/historical-data-and-multi-view-strategy-2026-05-09.md`, `docs/broker-audit-2026-05-08.md`, `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md`, `design/main.fig.md`. Skeletons reference the canonical state model in mig 20260509140000.
- **Git state at hand-off**: worktree HEAD = `3d55a38` (origin/main tip). Local main is 40 behind, but worktree itself is current.
- **Status**: 3 design docs + 3 frontend skeletons + 1 code-notes file ready for review. Skeletons are previewable by opening `static/_proposals/*.html` in a browser (no backend running needed for layout review).
- **Started**: 2026-05-08 (this session)

### DOING (code) — _none yet_
_(if I'm in the middle of something, it goes here so design knows what files I'm touching)_

### DONE (2026-05) — archived

Completed 2026-05 epochs (D1 storefront-movers rebuild + dep sweep; the
overnight audit + XSS fix + 3-surface preview switcher) moved to
[`docs/archive/2026-07-02-kanban-done-2026-05.md`](docs/archive/2026-07-02-kanban-done-2026-05.md)
to keep this board scannable. Nothing open remains in them.

---

## NEXT

### NEXT (D4) — state + backlog (free-first; updated 2026-05-23)

**Decision (operator 2026-05-23):** D4 runs **free-first** — a primary ticketing system that owns the ticket (issue → wallet/QR → transfer → scan). **Stripe payments + EVO distribution are DEFERRED** (scaffolded, dormant). Architecture + full plan: `docs/d_tier_unification_map.md` + `docs/d_tier_unification_plan.md`.

**✅ Built (PR #323) — B1 ✅ cleared — PR #323 merged to main (2026-05-24) — free-first batch applied to prod (2026-05-24) — `exos-mail-drain` v1 deployed (2026-05-24).** All 10 migs applied: `130000`(mail drainer) / `150000`(event cap) / `160000`(scan-verify) / `180000`(buy limits) / `200000`(growth primitives) / `210000`(ticket-issued mail) / `220000`(holder notify) / `230000`(issue-to-email) / `20260524150000`(public marketing) / `20260524160000`(security hardening). Skipped `170000`(Stripe) + `190000`(distribution) — dormant. Smoke checks: 8/8 new RPCs ✅; 4-arg check_in ✅; marketing col + public view ✅; anon EXECUTE revoked ✅. **2-min drainer cron scheduled** (`exos-mail-drain-2min`, jobid 253, work-check-gated → silent until mail is queued). **ONLY remaining mail blocker:** operator sets `RESEND_API_KEY` + `EXOS_MAIL_FROM` edge-fn secrets (verified live: drainer currently 500s `secrets unset` before claiming → no stuck rows; auto-delivers the instant secrets land). Apply runbook: [`docs/d4_prod_apply_handoff.md`](docs/d4_prod_apply_handoff.md). Effort key: **S** <1d · **M** 1-3d · **L** week+.

**🧪 Backend branch-verified end-to-end (2026-05-24): 41/41 scenarios green** on a throwaway Supabase branch. Covered: buy-limits incl. cumulative second-buy + admin bypass + tier/event caps (12/12); HMAC check-in valid/forged/expired/malformed/wrong-owner/replay + full transfer lifecycle incl. secret rotation killing a pre-transfer screenshot (15/15); issue-to-email + discount redeem + announce-to-followers + public marketing view + hardening (14/14). FE: `tsc`+`vite build` green; anon read-path validated at DB level.

**🟢 Free-first go-live punch list:** ① ✅ PR #323 merged + free-first batch applied (2026-05-24); ② ✅ Bridge rebuilt+deployed (PR #322) + `exos-mail-drain` deployed (v1) + 2-min cron scheduled (jobid 253) — all done (2026-05-24); ③ 🟠 Operator: set `RESEND_API_KEY`/`EXOS_MAIL_FROM` edge secrets (sole mail blocker) + Auth SMTP (D4-OPS-9); ④ **door rehearsal (D4-OPS-11)** = go/no-go → free-event go-live.

**Phase 1 — Door-ready (free / RSVP event)** — organizer mints, attendees access in-app, staffed manual fallback:
1. **D4-OPS-1** SW scope fix (**M**) — ✅ **DEPLOYED** (PR #321 + PR #322: built → `static/bridge/` synced 2026-05-24). Restores offline cold-boot + PWA install.
2. **D4-OPS-10** offline multi-lane double-admit (**M**) — ✅ **DEPLOYED** (PR #321 source + PR #322 deploy; mig `20260523120000` applied to prod). Realtime `postgres_changes` on `exos_event_checkins` live.
3. **D4-OPS-9** Auth SMTP at scale (**S**, operator config) — 🟠 operator action required; do early so day-of sign-ins don't throttle.
4. **D4-OPS-4** CSV voided-label fix (**S**) — ✅ **DEPLOYED** (PR #321 + PR #322: `static/bridge/` synced 2026-05-24).
5. **D4-OPS-11** load + door rehearsal (**M**) — 🟡 DB-side validated (8-lane concurrent check-in, 0 double-admits). **GATE:** physical device rehearsal on deployed app = go/no-go for free-event launch.
→ **Exit gate:** green door rehearsal → free 1000-person go-live.

**Phase 2 — Full-featured + hardened (still free; adds delivery + receipts)**:
6. **D4-OPS-8** `exos_mail` drainer (**M**) — ✅ **APPLIED + DEPLOYED + SCHEDULED** (mig `20260523130000` + `exos-mail-drain` v1 + cron `exos-mail-drain-2min` jobid 253, all 2026-05-24). Cron is work-check-gated (no fires until mail queued). 🟠 **Operator (sole remaining):** set `RESEND_API_KEY` + `EXOS_MAIL_FROM` edge-fn secrets → mail then auto-delivers within 2 min.
7. **D4-OPS-5** event-level oversell enforcement (**S**) — ✅ **APPLIED** to prod (mig `20260523150000`, 2026-05-24).
8. **D4-OPS-6** server-side check-in HMAC verification (**M**) — ✅ **APPLIED** to prod (mig `20260523160000`, 2026-05-24). 4-arg `exos_check_in_ticket` with server HMAC live.
→ **Exit gate:** fully-featured free events at scale; product proven end-to-end.

**Phase 3 — Payments (⏸️ DEFERRED — free-first excludes this)**:
9. **D4-OPS-7** Stripe Connect checkout + webhook-driven mint (**L**) — 🟡 SCAFFOLD built (PR #323), DORMANT. Resume only when paid sales are wanted: operator Stripe keys/decisions, A1 deploy, B1 review, refund-on-race flow, UI buttons, ticket-issued mail on fulfill, legal gate (D1-OPS-5).
→ **Exit gate:** paid 1000-person go-live.

### ⏸️ D4 LATER / BACKLOG (deferred — scoped, not lost)

- **D4-OPS-17 — door / box-office sales (eventually).** FREE walk-up issuance works today (org staff comp-mint on-site via `exos_mint_tickets`). PAID door sales need: the payments rail (depends on deferred D4-OPS-7) — likely Stripe **Terminal / tap-to-pay** — + a box-office POS mode in the seller app (fast repeat-sale UI, cash option, on-the-spot QR/print). Eventually; gated on payments.
- **Consumer D1↔D4 flow** (held) — surface D4 events on D1 (`exos_public_events`, no EVO needed) + buy + use D1 as the wallet for the D4 scanner. **Open decision:** FE stack (reuse the D4 React wallet vs port to D1 vanilla). The two asks imply D4 owns the ticket; EVO-as-checkout was dropped (it conflicts with the D1-wallet/D4-scanner).
- **Growth/Marketing — D4-OPS-14:** ✅ **Public rendering SHIPPED (PR #323, 2026-05-24):** per-org Meta/GA4/TikTok pixels load on public pages behind a **consent gate** (`lib/pixels.ts` + `lib/consent.ts` + `ConsentBanner` — resolves the deferred CSP/consent review; events queue pre-consent and replay on opt-in, no double PageView); org socials render on storefront + organizer profile (`SocialLinks`); per-event OG/Twitter/Schema.org JSON-LD via `applyMeta` (crawler-JS, no SSR); `marketing` exposed to anon via `exos_public_orgs` (mig `20260524120000`). Config UI shipped earlier (OrgSettings "Marketing & socials"). **Still gated/deferred:** publish to **Bandsintown** / Google Events / social = upstream WRITE → Hard-Rule-2 + creds (`exos-distribute` channels modeled); true SSR for non-JS social unfurlers (index.html defaults cover them today).
- **D4-OPS-13 distribution** — Automatiq → EVO outbound (extra reach). Scaffold dormant.
- **Cleanups:** **inventory hold/reservation** at checkout (closes the two-tab `maxPerAccount` race + the Stripe charged-but-sold-out race); `src/types.ts` Firebase `Timestamp` shim → `Date|string` — **deferred: it's a ~20-file app-wide date-handling refactor, browser-unverifiable here; do as a focused tsc-guided pass with UI verification, not blindly.**

Order-of-magnitude: free-first go-live ≈ apply + deploy + a door rehearsal (code's built); the backlog is post-go-live, mostly gated on operator creds (Stripe/Automatiq/Bandsintown) + B1 (CSP/pixels) + the held FE-stack decision.

### 🧭 D4 — standard-customer expectations backlog (gap analysis 2026-05-25)

What a standard organizer/attendee expects vs. what we ship today. Grouped **free-first (no payments) vs paid-gated (needs Stripe)**. Effort: **S** <1d · **M** 1-3d · **L** week+.

**🔜 Confirmed for next run**
- **D4-OPS-18 — event-scoped check-in RPC (S).** `exos_check_in_ticket` is org-scoped server-side; the event match is FE-only (`OrganizerCheckIn` wrong-event check). Add `p_event_id` + verify `ticket.event_id = p_event_id` in the RPC (defense-in-depth for multi-event orgs at velocity). Wire the FE to pass `eventId`. Barcode/hash scheme itself is collision-safe (UUID PK namespaces globally; HMAC is per-ticket, not a global key) — no prefix needed.

**🟢 Free-first wins (do without payments) — priority order**
- **D4-OPS-19 — turn on transactional email delivery (S, operator).** Drainer + cron deployed; idle until `RESEND_API_KEY` + `EXOS_MAIL_FROM` are set. Until then confirmation/transfer/issue/announce emails queue but never send — a baseline trust gap. Operator action only.
- **D4-OPS-20 — Apple/Google Wallet passes (M-L).** We render a web rotating-QR pass; native "Add to Apple/Google Wallet" is table stakes. Needs PassKit/Google Wallet signing (operator certs) + a pass-generation surface; the rotating-HMAC model maps to a barcode pass.
- **D4-OPS-21 — event reminders (S-M).** Add-to-calendar `.ics` already exists (`lib/calendarUtils.downloadIcsFile` in TicketDetail) — verify coverage; the gap is scheduled reminder emails ("your event is tomorrow") via the mail queue + a cron.
- **D4-OPS-22 — waitlist + self-serve RSVP release (M).** When a free tier hits capacity, let attendees join a waitlist (auto-offer on release); let a holder cancel/release a free RSVP to free capacity. New table + RPCs + UI.
- **D4-OPS-23 — attendee info capture at registration (M).** Per-ticket name/email + organizer-defined custom questions, surfaced on the guest list / check-in + CSV. Schema (per-ticket attendee fields / answers jsonb) + CreateEvent question builder + claim/checkout capture.
- **D4-OPS-24 — organizer analytics/reporting (M-L).** RSVP/sales over time, scan-in & no-show rate, promoter/channel attribution, exportable. Extends the existing event report + `exos_event_checkins`/`exos_scan_rejects`.
- **D4-OPS-25 — reserved/assigned seating + seat map (L).** Only if any venues are seated (theaters); today we're GA-tiers only. Large: seat inventory model, map builder, seat-level hold/sell, seat on the pass.
- **D4-OPS-26 — inventory hold/reservation at checkout (M).** Already noted under Cleanups — closes the two-tab `maxPerAccount` race; also a prereq for the Stripe sold-out race. Time-boxed hold table + claim/expire.
- **D4-OPS-27 — add-ons + multi-day/recurring/series (L).** Non-ticket add-ons (parking/VIP/merch) beyond tiers; recurring/series events sharing a template.
- **D4-OPS-28 — custom storefront domain (M).** White-label `/o/:slug` on the org's own domain (deferred from Sprint 2.5).

**🔴 Paid-gated (needs Stripe — extends the deferred D4-OPS-7)**
- The day you sell a paid ticket: card checkout + **organizer payouts** (Connect), receipts/invoices, **card refunds** + chargeback handling, service/platform fees & tax, paid box-office (Terminal/tap-to-pay, D4-OPS-17). Scaffolded + dormant by the free-first decision; this is the single biggest customer expectation once events aren't free.

### NEXT (D0) — Consolidated frontend lane post row 157 reorg

Plan: [docs/d0_frontend_consolidation_plan.md](docs/archive/d0_frontend_consolidation_plan.md). Self-contract: [docs/archive/d0_operating_constraints.md](docs/archive/d0_operating_constraints.md) (archived — D0 scope now in `PROJECT_BIBLE §2`). Coordination: [docs/edit_coordination_protocol.md](docs/archive/edit_coordination_protocol.md). 5 D0-tracked rows:

- **D0 → operator** — Supabase Auth Redirect URLs whitelist (2 URLs, dashboard action). Per `bot_chat` row 145. Unblocks PR #113 deployed login flow.
- **D0 → operator** — Render plan flip `vibepass-storefront-test` free → starter ($14/mo). Per D1 row 169 outstanding item 1. MCP `update_web_service` doesn't support plan changes — dashboard or Render REST API only.
- **D0** — Phase 2 design tokens: author `static/_shared/design-tokens.css`, refactor terminal CSS to reference it. Weeks 1-4.
- **D0** — `docs/d0_roadmap.md` (rolling Now/Next/Later/Backlog). First version covers D1+D2 outstanding items routed through D0.
- **D0 sign-off requirement on D1/D2 PRs PAUSED 7 days** (active 2026-05-22). Per operator directive `bot_chat` 170. Claim protocol + token discipline + CI gate still active.

### NEXT (D0) — product backlog (filed 2026-05-19, event-page + chart + landing session sweep)

Pending / incomplete D0 work captured for future cycles. Verified live state before filing — `cost_*`-reader blocker + parking-bridge pollution already cleared by A1, so those are NOT listed.

| ID | Lane | Task | Smallest action to close |
|---|---|---|---|
| D0-PROD-1 | D0 | **Landing selector — verify deploy propagated.** PR #278 (static-site root → unified Terminal/Undelivered/Store selector) MERGED to main (`0ab8a53`). As of 2026-05-21 21:49 UTC the live root still returns `301 → /terminal/` (Render static deploy + Cloudflare cache lag). | Re-check `curl -I https://vibepass-terminal-test.onrender.com/` returns `200 text/html`; if still `301` after deploy completes, check Render deploy log + CF `cf-cache-status` purge. |
| D0-PROD-2 | D0 | **Chart parity on performer + venue pages.** The 2-chart redesign + `get_event_chart_extended` (5 SG series + ESPN annotations, PR #237) live only on `event.html`. Performer + venue detail pages have no price/inventory chart. | New `get_performer_chart` / `get_venue_chart` aggregate RPCs (roll up member events) + reuse the event-page chart renderer. Medium effort. |
| D0-PROD-3 | D0 ✅ FIXED | **Chart legend toggle state is session-only.** Hiding a series resets on reload / range-flip. | ✅ **FIXED** — `_chartVisible` (shared across both panes, globally-unique keys) now persists to one `localStorage` key (`d0_chart_visible`) on every legend/source-toggle and rehydrates after the default seeds on load. Mirrors the existing `_showAlerts`/`_showEspn` pattern. (Range-flip already preserved the in-memory map; the reset was the reload path.) |
| D0-PROD-4 | D2/B1 (affects D0) | **Vivid bridge gap.** `vivid_orders.tevo_event_id` is 0/1169 populated (verified 2026-05-19) → the "Our Orders" tab TP+Vivid section shows zero Vivid rows on every event. D0 RPC bridges via `aq_short_event_id → aq_event_map → seatgeek_event_xref` but no Vivid rows carry it through. Filed `bot_chat` #292. | D2/B1: populate `vivid_orders.tevo_event_id` in the Vivid ingest/match cron (TickPick already at 14% via matcher v3 — same path). |
| D0-PROD-5 | D0 ✅ FIXED | **Realtime websocket blocked by CSP** (found during Seat Map testing 2026-06-02). `event.html` CSP `connect-src` lists `https://*.supabase.co` but not `wss://*.supabase.co`, so the live-refresh socket (`supabase.js` realtime) is blocked in console. Pre-existing; unrelated to the seat map. Likely affects other terminal pages too. | ✅ **FIXED** — `wss://*.supabase.co` added to `connect-src` in **all 8** terminal HTML `<meta>` CSPs (audit confirmed none had it). Cross-lane follow-up (NOT done — D1/other lanes): `static/store/*`, `static/home/index.html`, `static/undelivered/index.html` also lack `wss://` — coordinate with owners before patching. |
| D0-PROD-6 | D0 | **Seat Map → D1 storefront port.** The multi-source seat map (`docs/d0_terminal_build.md §B11`, PRs #406-410) lives only on the D0 terminal `event.html`. The consumer storefront (`static/store/event.html`) has no seat map. | Cross-lane (D1, currently paused): vendor the same `tevomaps.bundle.js`, reuse the tail-remap, feed storefront listing data. Coordinate with D1 owner. Medium effort. |
| D0-PROD-7 | D0 ✅ infra shipped | **Seat Map real CDN coverage — SOLVED by `seatmap_manifest` cache** (mig `20260603160000` + edge fn `seatmap-manifest-sync` + `*/30` cron, applied 2026-06-03). `public.seatmap_manifest(venue_id,configuration_id,has_map,section_count,section_keys[])` now holds the actual manifests (Supabase egress reaches the CDN; the agent/SQL sandbox can't). `has_map` replaces the `fanvenues_key` proxy. Early sweep: ~89% has_map. | (a) ✅ **Sweep complete (2026-06-08): 1,340 venue/config pairs · 1,184 has_map=true (88.4%) · 156 false · 0 null.** (b) ✅ **DONE** — `loadSeatmapTabVisibility()` (`event.js:3595`, called :161) reads `seatmap_manifest.has_map` and hides the Seat Map tab when `has_map=false`. (c) optional `section_alias` precompute — still open, low priority. |

### NEXT (D0 — checkpoint) — Phase 4 service-merge decision · review 2026-08-15

Recommend at decision time: collapse `vibepass-terminal-test` + `d2-orders-dashboard` into one operator-facing service; keep `vibepass-storefront-test` separate. Decision gates: ops MAU >50, deploy frequency stable. Cost-saver ~$14/mo at 3-service starter baseline.

### NEXT (P1 → A1) — Audit + sync storefront branch; gate live-TEvo flip behind your green light

**What**: Storefront branch `claude/store-sql-only-demo-mode` (HEAD `0901efd` as of 2026-05-12) is feature-complete for the MVP and ready for an audit pass. Asking A1 to review + sync to prod, after which we'd flip Render env `STOREFRONT_SQL_ONLY=false` to exercise the live-TEvo paths in production.

**What landed since the last sync** (all on P1's lane only — `app.py` web routes, `static/store/*`, `share_links`, and `evo_client.py` for one new read-method):

- `f7bf344` Lifecycle gate on event detail + share resolver — 404 ghost/cancelled events
- `24c252c` Context badges — rivalry, MLB series position, tournament parent
- `a820aac` Weather row + holiday pills (now-deprecated MLB series tab/page included in earlier commit, removed in `70b49ee`)
- `70b49ee` NYC movers strip + new event-list sort hierarchy (date asc · time asc · qty desc · listings desc · getin desc) + series tab teardown
- `25a9300` Playoff badge + parking tab + tagline/footer cleanup
- `0901efd` Live search dropdown — `/api/store/search` + `EvoClient.search_suggestions()` wrapper

**Why now**: All write surfaces still inside P1's lane (`share_links` table + `app.py` web routes + `static/store/*`). No new migrations. We've been read-only on `events / event_lifecycle / performer_metadata / venue_assets / v_rivalry_events / v_mlb_game_series / v_event_tournament_context / v_event_weather_with_fallback / v_event_calendar_context / v_event_velocity_windows / latest_event_metrics` per the lane map.

**How**:
1. A1 reviews the branch (audit-lane review checklist §9 of MIGRATION_CONVENTIONS.md). Particular attention requested on:
   - The new `_bulk_event_context` helper (`app.py`) — bulk reads against six views, all read-only. Verify no missed writes.
   - PostgREST `or_()` value sanitization in `_search_sql_only` (strips `, . ( ) "` before pattern build) — confirm the sanitizer is sufficient.
   - The 60s in-process search cache (`_search_cache`, 200-entry LRU). Single-instance Render dyno so process-local is fine; flag if you want Redis later.
   - `_search_live` falls through to `_search_sql_only` on TEvo failure — confirm that's the right fallback (vs. failing closed).
2. B1 syncs to prod once A1 is satisfied.
3. After B1 sync, P1 flips `STOREFRONT_SQL_ONLY=false` on Render and reports back observed live-mode latency + any TEvo 429s.

**Blocking question for A1**: any objection to enabling live mode against production TEvo on the Render test env? It's our seller account (X-Token in Supabase settings), but it does mean live writes to cron-cached `ticket_groups` payloads + fire-and-forget `collect-listings` calls (existing pattern, just exercised more often).

**Filed by**: P1 (storefront) · 2026-05-12

---

### NEXT (P1 → C1 / S1) — Notify: storefront ready for live-TEvo prod testing; flag if cross-lane interactions need coordination

**Routing note**: there is no supervisor — the actor hierarchy was dissolved 2026-07-02 (lane codes are ownership labels, not ranks; `PROJECT_BIBLE §2`). Docs/coordination (ex-C1) folded into **B1**; canonical-schema stability is an **Auditor** review by whichever session owns that surface. Coordinate laterally via `bot_chat`, not up a chain.

**What**: Heads-up that storefront is requesting permission from A1 to flip `STOREFRONT_SQL_ONLY=false` on the Render test env (see the row above). When that lands, P1's `/api/store/events/{id}` will call `/v9/events/:id` + `/v9/ticket_groups?owned=true` directly, and `/api/store/search` will hit `/v9/searches/suggestions`. Each detail hit also fires-and-forgets the audit-lane `collect-listings` edge function to refresh canonical SQL.

**Why flag C1/S1**: All of P1's reads bottom out in audit-lane / context-lane views — `event_xref`, `canonical_external_ids`, performer / venue / tournament context. If S1 is mid-flight on schema changes to any of those, live-mode reads from P1 would surface inconsistency to end users. Three reads I'd especially like S1 to confirm are stable:

- `v_event_tournament_context` — used for tournament-parent badges
- `event_xref` (indirectly via `v_event_tournament_context`)
- `v_rivalry_events` / `sporting_rivalries` — used for rivalry badges + the MLB series detection (`v_mlb_game_series` performer-name join)

**How**: S1 replies on this row with one of: (a) "all stable, go ahead"; (b) "wait until <date>, I'm refactoring <X>"; (c) "fine, but rename your reads from <old> to <new>". P1 will hold the live-mode flip until S1 signs off OR a week passes with no reply (whichever comes first).

**Filed by**: P1 (storefront) · 2026-05-12

---

### NEXT (code) — [SEC-MED] Cron command bodies hardcode the placeholder `CRON_SECRET`

**What**: Five `cron.job` rows currently ship the literal value `pick-any-random-string-and-save-it` in their `X-Cron-Secret` header inside the SQL command body (verified 2026-05-12 via `SELECT * FROM cron.job WHERE jobname LIKE '%collect-listings%'` etc.). Affected jobnames: `collect-listings-0-24h`, `collect-listings-1-7d`, `collect-listings-7-30d`, `collect-listings-30-60d`, `collect-listings-60d+`.

**Why it matters**: This is the same value already flagged in the SEC-CRIT row above as the in-code fallback. Rotating `CRON_SECRET` in Render / Supabase secrets won't help these specific cron jobs — the body of each `cron.schedule(...)` call has the literal baked in. When B1 rotates, the cron jobs would start failing auth unless these bodies are also rewritten. And before rotation, anyone who can `SELECT * FROM cron.job` (the `postgres` role + anyone with the right grants) reads the secret in plaintext.

**How**:
1. After CRON_SECRET rotation (the existing SEC-CRIT row), additionally:
2. `SELECT cron.unschedule('collect-listings-0-24h')` for each of the 5 jobs.
3. Reschedule with the new value: the body should reference the value via `vault.create_secret` / `get_app_secret('CRON_SECRET')` rather than a literal, so future rotations don't require re-touching `cron.job`.
4. Audit `cron.job` for any other secrets baked into command bodies (`SELECT command FROM cron.job WHERE command ILIKE '%pick-any-random%'` is the first sweep).

**Filed by**: P1 (storefront) · 2026-05-12

---

### NEXT (design) — orient and pick a starter task

**What**: Read `COWORKER_ONBOARDING.md` end-to-end, then pick a row below.
**Filed by**: code · 2026-05-09

---

## SECURITY BACKLOG (added by code · 2026-05-10 audit)

> Findings from the 2026-05-10 deep security audit (chat: "security chat"). Severity tags: **[SEC-CRIT]** = exploitable today, **[SEC-HIGH]** = exploitable under common conditions, **[SEC-MED]** = defense-in-depth gap, **[SEC-LOW]** = hardening. Each row keeps the standard NEXT format. Filed by code · 2026-05-10.
>
> **2026-05-11 first-pass — code fixes pushed by A1 for B1 review/sync.** 14 of the 16 entries now have landed in-code on PR #57. Operator steps required before B1 syncs to prod are listed at the top of the section below. The 2 remaining items (Supabase network restrictions, history rewrite of the leaked literal) are infra/git-ops actions that need a human and are tagged **[OPS-ONLY]** below.
>
> **2026-05-11 second-wave audit — new findings + fixes.** A1 ran a second pass across Python upstream clients, CI workflows, dependency pinning, app.py auth+logging, and a second-wave migration grep. **3 of 5 new findings landed in code in commit `<pending>`**; 2 are filed below for B1. Total 19 entries; 17 closed in-code, 4 are ops/human-judgment (the 2 from first pass + 2 new from second wave). Detail under "Second-wave findings (2026-05-11)" below.

### Second-wave findings (2026-05-11)

| ID | Severity | Status | One-liner |
|---|---|---|---|
| SW-1 | SEC-MED | LANDED | `seatgeek_client.py:495` was echoing user-controlled `order_id` + response body in `SeatGeekError`. Now: generic "HTTP {status}" message. |
| SW-2 | SEC-LOW | LANDED | `seatdata_client.py:215` gzip-decode error echoed the inner exception (which can carry partial bytes). Now: only the exception type name. |
| SW-3 | SEC-MED | LANDED | `requirements.txt` was fully unpinned — every redeploy could pull a different transitively-vulnerable version. Now: compatible-release ranges, dependabot-friendly. |
| SW-4 | SEC-LOW | LANDED | `AUTH_DISABLED` kill-switch was Railway-specific (`RAILWAY_ENVIRONMENT != production`). On Fly.io/Render/etc. the guard would silently re-arm. Now: checks 6 prod indicators. |
| SW-5 | SEC-MED | FILED | `require_auth` makes an outbound `GET /auth/v1/user` to Supabase on **every** authenticated request — a DoS amplifier against your Supabase auth quota. Fix below. |
| SW-6 | SEC-LOW | FILED | `seatdata_client.py:134` caches the bearer token in `self.session.headers` at init. Vault rotation doesn't propagate until the client reinits. Fix below. |
| SW-7 | OBS | NOTED | `v_dashboard_writes_24h` materialized view bypasses RLS by design (it's only count(*) aggregates over already-public catalog). Documented; no fix needed. |

### NEXT (code) — [SEC-MED · SW-5] Local JWT verification to remove the Supabase-auth DoS amplifier

**What**: `app.py:118-128` calls `requests.get(f"{SUPABASE_URL}/auth/v1/user", ...)` on every request that hits a `require_auth`-gated route. That's an outbound HTTPS round-trip to Supabase per request, which:
- Burns Supabase auth quota (free tier is 50k/month MAU; if you're sloppy in dev you can hit it fast)
- Couples API latency to Supabase availability
- Lets a flood of valid-JWT requests force a `502 auth check failed` outage by exhausting Supabase auth concurrency

The middleware-level rate limiter (`_RateLimitMiddleware`) caps per-IP bursts but doesn't help against distributed traffic.

**How**: Verify the JWT locally with `PyJWT` (the JWT secret is a server-side env var, separate from anon/service-role keys). Pattern:

```python
import jwt  # PyJWT
SUPABASE_JWT_SECRET = os.environ.get("SUPABASE_JWT_SECRET")  # from Supabase dashboard

def require_auth(authorization: str | None = Header(None)):
    if AUTH_DISABLED: return None
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    try:
        claims = jwt.decode(token, SUPABASE_JWT_SECRET, algorithms=["HS256"], audience="authenticated")
    except jwt.InvalidTokenError:
        raise HTTPException(401, "invalid session")
    email = (claims.get("email") or "").lower()
    if not email.endswith("@" + ALLOWED_EMAIL_DOMAIN.lower()):
        raise HTTPException(403, f"access restricted to @{ALLOWED_EMAIL_DOMAIN}")
    return {"email": email, "id": claims.get("sub")}
```

Add `PyJWT>=2.8,<3.0` to `requirements.txt`. Operator must set `SUPABASE_JWT_SECRET` env var (Dashboard → Settings → API → JWT Secret). Drops latency by ~50-100ms/req and removes the amplifier entirely.

**Trade-off**: locally-verified JWTs don't reflect revocation until they expire (default 1h). Acceptable for this app — the alternative is fetching once per JWT into a short-TTL cache (Redis or in-process), which adds complexity. If revocation-on-demand becomes critical (e.g., employee offboarding), layer a deny-list cache on top.

**Filed by**: A1 · 2026-05-11 second wave

---

### NEXT (code) — [SEC-LOW · SW-6] Refresh seatdata bearer per request so vault rotation propagates

**What**: `seatdata_client.py:134-138` bakes `Authorization: Bearer <api_key>` into `self.session.headers` at `__init__`. If `SEATDATA_API_KEY` is rotated via `vault.update_secret`, the running `SeatDataClient` instance never picks up the new value — it keeps signing with the old one until the process bounces.

**How**: Replace the eager header with a per-request auth callable, or simply read the key fresh into `headers` on each `request()` call. Pattern:

```python
def _request(self, method, path, **kw):
    headers = {**self._base_headers, "Authorization": f"Bearer {self._read_api_key()}"}
    return self.session.request(method, url, headers=headers, ...)

def _read_api_key(self):
    # Cached for 60s; falls back to vault on miss.
    if not self._cached or self._cached_at < time.monotonic() - 60:
        self._cached = self._fetch_from_vault()
        self._cached_at = time.monotonic()
    return self._cached
```

Same pattern applies to `seatgeek_client.py` (uses `?token=` query param, cached on init) and `evo_client.py` (signs per-request but reads `self.token` / `self._secret` at init). Lower priority on the latter two because their auth model differs.

**Filed by**: A1 · 2026-05-11 second wave

### B1 sync-to-prod checklist (apply IN THIS ORDER)

1. **Rotate `CRON_SECRET`** to a fresh random value. Set on Railway env, Supabase Edge Function secrets, AND seed into Supabase vault as `CRON_SECRET` (the new cron migration reads it from vault).
2. **Seed `EDGE_FN_ANON_JWT` in vault** with the current Supabase anon JWT value. The 3 cron migrations in `20260511000200` assert this exists.
3. **Set `CORS_ALLOWED_ORIGINS`** Railway env to your real frontend origins (comma-separated). Default permits localhost only.
4. **Set `CHAT_ALLOWED_ORIGINS`** Supabase edge fn secret for the same.
5. **Generate a fresh password for `coworker_readonly`** out-of-band before re-issuing. Migration `20260511000000` revokes LOGIN until you do this.
6. **Apply migrations in order**: `20260511000000`, `20260511000100`, `20260511000200`, `20260511000300`.
7. **Verify**: confirm cron jobs still tick (no Auth header failures); confirm `/api/store/share*` returns 401 to unauth callers; confirm edge functions return 401/500 to callers without `x-cron-secret`.

### Code changes landed by A1 (2026-05-11)

- `app.py`: import `hmac`, auth on store/share*, fail-closed `CRON_SECRET`, constant-time compare, AUTH_DISABLED non-prod guard, `CORSMiddleware` + `_SecurityHeadersMiddleware`.
- `supabase/functions/_shared/cron-auth.ts`: new shared `requireCronSecret` helper (fail-closed, constant-time).
- `supabase/functions/{collect,collect-listings,espn-collect,espn-rosters,wiki-collect,crawl-espn-team-assets,crawl-venues-and-performers,tevo-perf-find,seed-home-venues,bulk-add-watchlist,backfill-event-configurations}/index.ts`: wired to the shared helper. 6 were fail-open → fail-closed; 5 were unauth'd → now gated.
- `supabase/functions/chat/index.ts`: CORS allowlist via `CHAT_ALLOWED_ORIGINS`, rate-limit RPC errors fail-closed (was fail-open), per-min cap tightened 10 → 6.
- `supabase/migrations/20260511000000_security_coworker_readonly_nologin.sql`: ALTER ROLE … NOLOGIN.
- `supabase/migrations/20260511000100_security_search_path_definer_funcs.sql`: SET search_path on the 3 ESPN/asset DEFINER fns + a sweep over any others missing it.
- `supabase/migrations/20260511000200_security_anon_jwt_to_vault.sql`: vault-presence assertion + `_cron_invoke_edge_fn` helper + reschedule of 3 cron jobs without the literal JWT.
- `supabase/migrations/20260511000300_security_rls_internal_tables.sql`: dynamic `ENABLE RLS` on operational tables (queues, pull logs, crawl state, internal xref). Domain tables untouched.
- `static/store/store.js`: all `innerHTML` sinks with server/URL data converted to `textContent`/`createElement`; auto-mount via `body[data-page]`; URL params clamped (eventId, prices, qty).
- `static/store/{index,event,shares}.html`: CSP meta (no `'unsafe-inline'` scripts), X-Content-Type-Options, referrer policy, inline `<script>Store.mountX()` removed.
- `KANBAN.md` + `AGENTS.md`: leaked `CRON_SECRET` literal redacted.

### Still pending (after this PR)

- **[OPS-ONLY] Verify Supabase network restrictions / IP allowlist** — Supabase Dashboard → Database → Network restrictions. No code change possible.
- **[OPS-ONLY] History rewrite of the leaked literal** in git — needs `git filter-repo` + a force-push window. Decide whether private-repo posture makes it optional.
- **[SEC-MED] Add slowapi rate-limiter on `/api/store/*`** — left for the next pass; adds a Python dependency.
- **[SEC-LOW] Document `get_app_secret` whitelist + rotation runbook** — see `MIGRATION_CONVENTIONS.md` follow-up.
- **[SEC-HIGH] Full RLS coverage audit on domain tables** — internal/operational covered by `20260511000300`; events/performers/listings/etc. need explicit per-table policy decisions.

### B1-NEXT queue (filed 2026-05-15 by B1 monitoring charter)

Defense-in-depth follow-ups identified during the Phase-2 monitoring sweep. Each tagged `B1-NEXT-<N>` for tracking. Owner: B1 unless cross-lane noted.

> **🛡️ For the LIVE operating subset** (only OPEN items, severity-sorted, with closure protocol) → [`docs/b1_open_findings.md`](docs/b1_open_findings.md). Fixing bots: **delete your row from that doc in the same PR as your fix.** KANBAN here keeps the historical audit trail.

- **[B1-NEXT-1] [SEC-MED] ✅ CLOSED by D2 (mig `20260519110000_d2_cron_freshness_body_guard_and_sg_broker_mapping`).** CREATE OR REPLACE converted `d2_cron_freshness()` from LANGUAGE sql → plpgsql with the `current_user NOT IN ('service_role','postgres','supabase_admin')` body guard. Same mig folds in PR #147's pending mapping swap (SG source → `sg_broker_sales_queue_30min` + `sg_priority_sales_process_1min`) since the dashboard SG source moved from seller-side to broker firehose on 2026-05-16.
- **[B1-NEXT-2] [SEC-LOW]** Drop the dead v1 overload of `match_to_aq_event_id` (the 7-arg form, superseded by 8-arg form in [supabase/migrations/20260515230000_matcher_v2_tier_1_5.sql](supabase/migrations/20260515230000_matcher_v2_tier_1_5.sql)). Cleanup, not security.
- **[B1-NEXT-3] [SEC-MED]** Edge function auth posture inventory (`docs/edge_function_auth_inventory.md`). 16 functions deployed; need per-function record of `x-cron-secret` enforcement vs. open vs. JWT-gated. Heavyweight per-function audit.
- **[B1-NEXT-4] [SEC-LOW]** Evaluate CodeQL / SAST for FastAPI + edge functions. Decide whether to add as a CI workflow.
- **[B1-NEXT-5] [SEC-MED]** Vault orphans check — `release_health_check()` row for `get_app_secret` allowlist entries not actually referenced in any prod fn / cron / edge-fn. Punch-list item from [docs/release-discipline.md](docs/release-discipline.md) §7.
- **[B1-NEXT-6] [SEC-LOW]** Egress payload review — sample anon-callable RPC responses for accidental wholesale/broker field exposure ([PROJECT_BIBLE.md §2](PROJECT_BIBLE.md) `*_public` wall rules). Periodically review `*_public` RPCs.
- **[B1-NEXT-7] [SEC-HIGH] ✅ CLOSED** (B1 verified 2026-05-26 via Phase-2 anon-permissive-policy sweep — **0** anon-readable tables have `rowsecurity=false`; these 3 have since had RLS enabled, no fix migration needed). Original: RLS gap on `cron_pause_state_20260514`, `sg_event_priority_state`, `sg_priority_policy`.
- **[B1-NEXT-8] [SEC-MED]** §6 retrofit on `_health_check_pg_net_errors()` (A1's, added by PR #115). File PR comment to A1 per cross-lane patch protocol. Read-only diagnostic but defense-in-depth retrofit warranted.
- **[B1-NEXT-9] [SEC-MED]** §6 retrofit on `get_broker_event_page(integer, integer)` (A1's, added by PR #115). Body is already gated by `auth.jwt()->>'email'`; §6 guard is belt-and-suspenders. File PR comment to A1.
- **[B1-NEXT-10] [SEC-LOW]** Migration slot collision audit — `20260515300000` (3 files), `20260515320000` (2 files) collide. MIGRATION_CONVENTIONS.md §3 bump-by-30-or-50 rule not followed. Not security-class but flags discipline drift; recommend filenames be renamed to next free slots in a future cleanup PR. **Partial (2026-07-02):** `.github/workflows/migration-collision-check.yml` now blocks *new* colliding prefixes (diff-scoped; the 36 existing dupes are baselined, not renamed). Renaming the historical dupes is still open here.
- **[B1-NEXT-22] [chore]** Group the 9 root-level `*_client.py` into a `clients/` package to finish the `core/`/`routers/` extraction shape. **NOT afternoon-cleanup — do it as its own tested PR:** (1) ~324 references across `server.py`, `d2_dashboard/main.py`, and `scripts/*` use bare top-level imports (`from evo_client import …`) — all must move to `clients.evo_client` (or a package shim); (2) **security-CRIT dependency:** `scripts/check_readonly.py:304` does `ROOT.glob("*_client.py")` as an opt-OUT discovery that forces every client to be GET-guarded — moving the files makes that glob match nothing at root, silently disabling the readonly-guard audit's discovery (RULE-2). The glob must be updated to recurse into `clients/` **in the same PR**, with `tests/test_readonly_guards.py` proving coverage didn't drop. Until both land, leave the clients at root.

### B1-NEXT — git + render monitoring expansion (filed 2026-05-15 by B1 charter §git+render)

Operator-extended mandate covers git settings + Render workspace. Initial sweep landed [`docs/git_repo_security_posture.md`](docs/git_repo_security_posture.md) + [`docs/render_security_posture.md`](docs/render_security_posture.md). Findings filed below.

- **[B1-NEXT-11] [SEC-HIGH]** Reassess history-rewrite priority on leaked `CRON_SECRET` in commit `5297739`. Original SECURITY BACKLOG item scoped assuming private repo; current `visibility: public` means rotated value is internet-readable. Operator decides: `git filter-repo` + force-push window, OR accept (value rotated, blast radius is whoever scraped between leak + rotation). Documented as G-1 in git posture inventory.
- **[B1-NEXT-12] [SEC-MED]** Enable `dependabot_security_updates` on the repo (currently `disabled`). After 2026-05-11 `requirements.txt` unpinning incident (SW-3 above), Dependabot is the right tool. Operator-only — Settings → Code security. Documented as G-2.
- **[B1-NEXT-13] [SEC-MED]** Enable `secret_scanning_non_provider_patterns` (currently `disabled`). Catches project-shape secrets like `CRON_SECRET`, `APPSCRIPT_INGEST_SECRET`. Operator-only. Documented as G-3.
- **[B1-NEXT-14] [SEC-MED]** Enable `secret_scanning_validity_checks` (currently `disabled`). Confirms whether leaked tokens are still active. Operator-only. Documented as G-4.
- **[B1-NEXT-15] [SEC-LOW]** Consider enabling branch-protection `enforce_admins` for `main` (currently `false`). Admin (`JulianS4K`) can bypass protections. Acceptable single-operator risk profile but documented for transparency. Operator-only. G-6.
- **[B1-NEXT-16] [SEC-LOW]** Consider enabling `required_signatures` for `main`. Currently `false`. GitHub-server-side commits (PR merges) make impersonation low-risk, but signing would harden against compromised local dev environment. G-7.
- **[B1-NEXT-17] [SEC-LOW]** Consider enabling Actions `sha_pinning_required`. Currently `false`. Workflows reference Actions by mutable tags (`@v4`, `@v7`). Tighten to immutable SHA pins for supply-chain hardening. G-8.
- **[B1-NEXT-18] [SEC-MED]** Verify Actions secrets are populated for `sync-check.yml` (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, optional `SUPABASE_PAT`). `gh api .../actions/secrets` returned empty at sweep — could be permission-filtered, could be unset. If unset, sync-check fails silently. Operator confirms next session.
- **[B1-NEXT-19] [SEC-LOW]** Render `ipAllowList: 0.0.0.0/0` on `d2-orders-dashboard` and `vibepass-terminal-test` — both supposed to be `@s4kent.com` authenticated at app layer. Optional secondary defense: tighten allowlist to known operator IPs. PR comment to D1 (Render-write authority). Documented as R-1.
- **[B1-NEXT-20] [SEC-LOW]** Render services `autoDeploy: yes` from `main` on every commit. Standard CD; consider manual approval gate for `vibepass-storefront-test` (public retail). PR comment to D1. R-2.
- **[B1-NEXT-21] [SEC-LOW]** Slack surface monitoring — operator decision on installing a Slack MCP. Currently no active Slack integration in the repo (gitleaks catches `xoxb-*`/`xoxp-*` tokens via push-protection; no Slack-posting workflows; no webhooks). Future state: with Slack MCP, B1 monitors workspace admins, 2FA enforcement, recent-message search for incident leaks. Without MCP, B1's Slack coverage is grep + gitleaks only. See `docs/b1_operating_constraints.md` "Slack posture monitoring" section.

### B1-NEXT — Librarian / archivist role (filed 2026-05-16 per operator directive)

Operator extended B1's mandate 2026-05-16: "communication channel, Librarians and archivists and maintaining bible(s) so communication between bots is seamless and up to date." Operationalized in `docs/b1_operating_constraints.md` "Librarian / archivist role" + per-session sweep steps 15-16.

- **[B1-NEXT-24] [SEC-LOW]** Periodic full-pass drift audit of `PROJECT_BIBLE.md` §3 (canonical RPC table) — verify all 32 listed RPCs exist in `pg_proc` with the signatures stated. Rotating quarterly cadence; first pass at session start. Tracked here separately from per-session sweep step 15 (which is per-session rotating spot-check).
- **[B1-NEXT-25] [SEC-LOW]** Periodic full-pass drift audit of `RESOURCES_BIBLE.md` §1 (external services) — verify Render service IDs match `mcp__render__list_services`, vault secret names match `get_app_secret` allowlist, lane ownership rows match `PROJECT_BIBLE.md §2`, and the live counts in §0 match `pg_class`/`pg_proc`/`cron.job`. Rotating quarterly.
- **[B1-NEXT-26] [SEC-LOW]** `bot_chat` thread-closure rate dashboard — query for `(count(resolved) + count(status-closed)) / count(total flag+question)` by lane over rolling 7d. File flag if any lane closure rate < 50%. Could be added as a row in `release_health_check()` (`coordination.thread_closure_rate_7d`).
- **[B1-NEXT-27] [SEC-LOW]** Cross-bible consistency check. Lane ownership / push restrictions / write-surface declarations are now single-homed in `PROJECT_BIBLE.md §2` (`BOT_HIERARCHY.md` merged in 2026-06-19; `LANE_DISCIPLINE.md` before it), so this is a self-consistency pass within §2 + a check that `docs/<bot>_operating_constraints.md` self-contracts still agree. Periodic.
- **[B1-NEXT-28] [SEC-LOW]** Slack channel signal-quality metric — once interactive Slack MCP loads in B1 sessions, per-channel message rate + dormancy + scheduled-task vs human post ratio. Threshold-based alerts on signal degradation.
- **[B1-NEXT-29] [SEC-MED]** §6 retrofit on `public.refresh_sg_broker_sales_event_metrics(integer)` — SECDEF, anon EXECUTE, no body guard, no shared-secret gate. Drives hourly `:17` cron populating `seatgeek_event_metrics.sold_*`. Defense-in-depth (cron callers are service_role; primary mitigation is grant model). Filed by B1 in 2026-05-16 drift sweep after testing-unified architecture landed. Cross-lane to A1 — PR comment on the originating migration.
- **[B1-NEXT-30] [SEC-MED]** §6 retrofit on `public.sg_seller_orders_queue(p_pages integer, p_statuses text)` — SECDEF, anon EXECUTE, no body guard. SG seller-side ingest queue. Defense-in-depth. Cross-lane to A1/D2 — PR comment on originating migration.
- **[B1-NEXT-31] [SEC-MED]** §6 retrofit on `public.get_broker_event_page_v2(p_event_id integer, p_chart_hours integer)` — SECDEF, anon EXECUTE, body-gated by `auth.jwt()->>'email'` (D0 Phase 2a primary RPC per PROJECT_BIBLE.md §4). §6 guard is the second belt; body is the primary mitigation. Cross-lane to A1 — PR comment on PR #150 (a1/d0-phase2a-event-page-v2).
- **[B1-NEXT-32] [SEC-CRIT] ✅ CLOSED** by A1 PR #174 (2026-05-16 21:48 UTC). `requireCronSecret(req)` added to `match-sg-performers-to-tevo` Deno.serve top. Original finding: anon JWT + caller-controlled `limit` (1-200) drove paid TEvo `/v9/performers/search` calls.
- **[B1-NEXT-33] [SEC-HIGH] ✅ CLOSED** by A1 PR #174 (2026-05-16 21:48 UTC). `requireCronSecret(req)` added to `why-noaa-weather-alerts` POST handler. Original finding: unbounded `why_signals` INSERTs via service-role.
- **[B1-NEXT-34] [SEC-MED] ✅ CLOSED** by A1 PR #174 (2026-05-16 21:48 UTC). `espn` edge function wildcard CORS replaced with explicit allow-list (terminal-test, storefront-test, d2-orders-dashboard, localhost dev) + `vary: Origin` header. Original finding: `access-control-allow-origin: *`.
- **[B1-NEXT-35] [SEC-LOW]** Create scheduled task `b1-war-games-rotation` per `docs/war_games_playbook.md`. Cadence proposal: every 4h (avoids :00 and :30 collisions; full 10-scenario rotation completes in ~40h). Posts to `#terminal-2-admin` on findings, silent on clean runs. Operator decision required (Slack MCP tool approval + cron creation). Until task is created, war-games rotation runs via per-session sweep step 19 (manual rotation).
- **[B1-NEXT-36] [SEC-MED] MERGED** Cron heartbeat detector added to `release_health_check()` via migration `20260516230000_security_release_health_cron_heartbeat.sql` ([PR #176](https://github.com/JulianS4K/Terminal-2/pull/176), merged 2026-05-16 23:25 UTC). Closes D0 audit proposal B1.2 (bot_chat 251). New helper `_health_check_cron_heartbeat()` flags any ACTIVE cron whose `last_success > 3× median inter-run interval (last 7d)`. Self-tuning — no schedule parsing required. Catches daily-cadence crons that silently fail to fire (existing `subhourly_jobs_silent_90min` row only watches sub-hourly schedules). Prod-apply gated on operator per lockdown (file in main but `apply_migration` not yet called).
- **[B1-NEXT-37] [SEC-LOW]** Backfill `cron_policy` rows for the 4 daily collect-listings windowed crons (`1-7d`, `7-30d`, `30-60d`, `60d+`). Current `cron_gate_decisions` shows decision=`fire_no_policy` because no policy row exists for them. Default-fire behavior works but defense-in-depth would add daily-max-fires + work-check-sql + interval-min limits. Cross-lane to A1 (cron_policy owner).
- **[B1-NEXT-38] [SEC-MED] ✅ CLOSED** by mig `20260517170000_sg_broker_sales_views_security_invoker.sql` (applied as version `20260517210624`). Both views now have `reloptions=["security_invoker=true"]`; `release_health_check.views.security_definer_views` row cleared. Original finding filed 2026-05-17 ~02:30 UTC via PR #188 + bot_chat 275.
- **[B1-NEXT-39] [SEC-MED]** War-games W-3 (storefront egress probe, 2026-05-17 21:50 UTC): `/api/store/search?q=yankees` exposes `we_own` (bool) + `owned_tix` (count) — semantically equivalent to forbidden `is_owned` per `PROJECT_BIBLE §2.6` (ex-`LANE_DISCIPLINE.md §D1`) wall rules. `/api/store/events` schema includes the fields but values are null (TEvo-direct route). `/api/store/movers`, `/api/store/near` clean. May be intentional storefront-product behavior (broker storefront sells own inventory; "we have tickets!" UX badge). Filed bot_chat 308 to D0/D1 for product-intent clarification — if intentional, add carveout to `PROJECT_BIBLE §2.6`; if not, filter columns from response. Cross-lane to D0/D1.

### NEXT (code) — [SEC-CRIT] Rotate the leaked `CRON_SECRET` value, then redact from KANBAN/AGENTS

**What**: The `CRON_SECRET` value was committed in plaintext to `KANBAN.md` (lines 87, 90, 91 below this block) and discussed in `AGENTS.md`. It is in git history (commit `5297739` and prior). Anyone who clones this repo today reads the production cron secret.

**Why it matters**: With the cron secret an unauthenticated attacker can call `/api/admin/collect-orders` and similar cron-gated routes (also several edge functions that share the same secret), triggering paid TEvo / SeatGeek pulls and writes against `evo_orders` etc.

**How**:
1. Generate a new random value (32+ bytes): `python -c "import secrets; print(secrets.token_urlsafe(32))"`.
2. Set it in Railway env (`CRON_SECRET`) AND in Supabase Edge Function secrets (`supabase secrets set CRON_SECRET=...`) AND update the SQL of the relevant `cron.schedule` jobs (the body is in pg_cron — needs an update via `cron.unschedule` + reschedule).
3. Redact the value from `KANBAN.md` and `AGENTS.md` (replace with `<rotated; in vault>`).
4. Decide on history rewrite. If the repo is private to the trusted set forever, leaving history alone may be acceptable; otherwise plan a `git filter-repo` purge + force-push window.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-CRIT] Rotate `coworker_readonly` Postgres password (placeholder shipped in migration)

**What**: Migration `20260509460000_coworker_readonly_role.sql:24` creates the `coworker_readonly` role with `PASSWORD 'CHANGE_ME_BEFORE_HANDOFF'`. If the migration ran against prod and the post-handoff rotation didn't happen, that's the live password. Anyone with the public repo + a reachable Supabase Postgres host can `psql -U coworker_readonly` and read the entirety of `public.*`.

**How**:
1. Connect as superuser, run `ALTER ROLE coworker_readonly WITH PASSWORD '<new strong value>'`.
2. Re-deliver the new password to the UI coworker out-of-band.
3. Add a follow-up migration that drops the placeholder pattern: never embed credentials in DDL again. Use `vault.create_secret` or a `\set` script applied separately.
4. Verify by attempting login with `'CHANGE_ME_BEFORE_HANDOFF'` and confirming it's rejected.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-CRIT] Add auth to `/api/store/share*` endpoints (write + revoke + list are open)

**What**: In `app.py`:
- `POST /api/store/share` (line 3764) — no auth. Anyone can spam-create share links.
- `DELETE /api/store/share/{share_id}` (line 3881) — no auth. **Anyone with a share_id can revoke it**, including by enumerating from the list endpoint below.
- `GET /api/store/shares` (line 3897) — no auth. Lists every share row (event_id, filters, notes, view counts).

The handler comment at line 3774 explicitly acknowledges this is open as MVP. Risk before any sign-in flow lands: a single curl loop deletes every share link in the DB.

**How**: Wrap the three endpoints with `_=Depends(require_auth)` (mirrors the pattern at `app.py:94`). For the public read path `GET /api/store/share/{share_id}` (line 3840) — keep open since the share id is the unguessable cap (72 bits of entropy).

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-CRIT] Fix fail-open `CRON_SECRET` in app.py + 5 edge functions

**What**: Multiple components default to a weak/empty value when `CRON_SECRET` env var is unset:
- `app.py:2708` — `CRON_SECRET = os.environ.get("CRON_SECRET", "pick-any-random-string-and-save-it")`. If env unset and an attacker guesses the placeholder string, they pass auth.
- `supabase/functions/{collect,collect-listings,espn-collect,espn-rosters,wiki-collect}/index.ts` — pattern `if (expected && req.headers.get("x-cron-secret") !== expected) { reject }`. If `CRON_SECRET` env is unset, `expected` is undefined, the guard is skipped entirely → endpoint is fully open.
- `supabase/functions/crawl-espn-team-assets/index.ts:24` — hardcoded fallback string (same shape).

**How**: Replace each with fail-closed: `if (!expected) return 500; if (header !== expected) return 401`. Use a constant-time compare (Python: `hmac.compare_digest`; Deno: `crypto.subtle.timingSafeEqual`).

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-CRIT] DOM-XSS in `static/store/store.js` (multiple `innerHTML` sinks with server data)

**What**: ~20 `innerHTML` writes in `static/store/store.js` build HTML strings from server-returned and URL-derived values. Hot spots: lines 88, 90, 227, 231, 272-293, 331-343, 395, 399, 475-482, 633-634, 761, 795-807. Some use `escapeHtml()` correctly; the pattern is fragile and at least one path mixes URL params (`zones`, `section`) into the chip rendering. The retail HTML project ships these to public buyers — once a single attribute breaks the escape, it's reflected XSS.

**How**: Repeat the fix already done for `shop.html` chatbot (commit overnight): replace innerHTML with `textContent` + `appendChild`. Build chips/modals via `createElement` rather than template strings. Keep `escapeHtml()` only for genuinely opaque data, and audit each remaining call.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Add `SET search_path` to 3 SECURITY DEFINER functions

**What**: `supabase/migrations/20260508140000_espn_team_and_venue_assets.sql` declares `get_event_assets_public()`, `get_performer_assets_public()`, and `get_venue_assets_public()` as SECURITY DEFINER without `SET search_path`. This is the canonical Postgres privilege-escalation vector: a caller can prepend a malicious schema and intercept any unqualified function/table reference.

**How**: Add `SET search_path = public, pg_temp` to each function definition (new migration, or `ALTER FUNCTION ... SET search_path = ...`). Audit `pg_proc` for any other DEFINER functions added since: `SELECT n.nspname, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.prosecdef AND NOT 'search_path' = ANY(p.proconfig)`.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Audit RLS coverage on `public.*` tables (~120 tables without `ENABLE ROW LEVEL SECURITY`)

**What**: 141 `CREATE TABLE` statements across 159 migrations; only 20 have `ENABLE ROW LEVEL SECURITY`. The Supabase default GRANT model means anon role can already SELECT/INSERT/UPDATE/DELETE on any public table without RLS — the JWT for that role is published in 3 cron migrations and is also ambient on the FastAPI `/api/public/config` endpoint. Net: any reader of the repo gets anon-level direct PostgREST access to anything not RLS-gated.

**How**: 
1. Enumerate prod state — `SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname='public' AND NOT rowsecurity;`.
2. Categorize: (a) operational/internal that should never be reachable by anon → REVOKE from anon and authenticated; (b) public catalog data → ENABLE RLS + add explicit `FOR SELECT TO anon USING (true)` policy; (c) user-scoped → ENABLE RLS + per-user policy.
3. Run `mcp__supabase__get_advisors lint` for the security set; it'll flag this category.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Verify Supabase network restrictions (IP allowlist / Supavisor)

**What**: Repo doesn't tell us whether the Supabase Postgres host is reachable from the public internet on 5432. Combined with the (previously) leaked `coworker_readonly` placeholder password, this is the difference between "exploitable from any IP today" and "needs a foothold first".

**How**: Supabase dashboard → Project Settings → Database → "Network restrictions" / "Connection pooling" → add an allowlist for Railway egress IPs + your home IPs. Document the policy in `docs/`. If the project must remain open, mitigation moves entirely to "passwords + RLS must be hardened first".

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Lock down `chat` edge function (CORS `*` + LLM cost DoS)

**What**: `supabase/functions/chat/index.ts:38` returns `Access-Control-Allow-Origin: *` on a public POST that calls Anthropic via `resolveSecret(db, "anthropic_api_key", ...)`. An unauthenticated caller from any origin can drive arbitrary prompt costs against your account. The `chat_rate_limits` table exists (migration `20260507000001`) but isn't checked before the LLM call in this code path.

**How**: (a) require Bearer JWT (anon-key Supabase JWT is fine as a baseline; RLS on `chat_messages` does the actual gating); (b) call the rate-limit RPC before `llmCall`; (c) restrict `Access-Control-Allow-Origin` to the known frontend origin(s) — wildcard with credentials is invalid anyway.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Move the anon JWT out of cron migrations into vault

**What**: `supabase/migrations/{20260507000024,20260508016000,20260508240000}*.sql` hardcode the Supabase anon JWT in the `cron.schedule` body. This makes the JWT visible to anyone with `SELECT` on `cron.job` (e.g., `coworker_readonly` does NOT have it today, good — but any future read role might). It also locks rotation to a migration cycle.

**How**: Store the JWT in `vault.secrets` (use the existing `upsert_app_secret` whitelist, after expanding it to include `EDGE_FN_ANON_JWT`). In the cron body, read it via `(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='EDGE_FN_ANON_JWT')`. Drop the literal from the migration files (history rewrite optional — anon JWT is semi-public per Supabase model, so this is mostly hygiene).

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Replace `AUTH_DISABLED` env kill-switch with a non-prod guard

**What**: `app.py:42` reads `AUTH_DISABLED` env var; `app.py:101` short-circuits `require_auth` to return None when set. A Railway misconfiguration or copy-paste from local `.env` flips the entire FastAPI surface to anonymous.

**How**: Replace the env check with `if AUTH_DISABLED and os.environ.get("RAILWAY_ENVIRONMENT") != "production":`. Better: remove the flag entirely and use a local-only `.env.local` with mock credentials.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Auth-gate the rest of the unauth'd edge functions

**What**: `crawl-venues-and-performers`, `tevo-perf-find`, `seed-home-venues`, `bulk-add-watchlist`, `backfill-event-configurations` have no CRON_SECRET / Bearer check. Each is reachable on its public Functions URL. They mutate state (seeding, backfills) or hit paid upstreams (TEvo).

**How**: Add the standard `x-cron-secret` check (the fail-closed version per the related row above) to each. If a function should ONLY run from an authenticated UI, switch to JWT verification via `supabase-js` createClient with the user's JWT.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-MED] Add CSP headers + CORS allowlist to FastAPI

**What**: No `CORSMiddleware` is registered in `app.py` — relying on browser SOP for cross-origin defense. None of the served HTML (`static/store/index.html`, `event.html`, `shares.html`) carries a `Content-Security-Policy` meta. Inline `<script>Store.mountCatalog()</script>` exists in `index.html:45-46`.

**How**: 
- Register `CORSMiddleware` with an explicit allowlist (Railway prod URL + localhost during dev).
- Add a small middleware that emits `Content-Security-Policy: default-src 'self'; script-src 'self'; img-src 'self' data: https:; connect-src 'self' https://*.supabase.co https://api.anthropic.com; frame-ancestors 'none'` plus `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`. Move inline scripts to external files to keep `'unsafe-inline'` out of `script-src`.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-MED] Constant-time `CRON_SECRET` comparison

**What**: `app.py:2713` and the edge functions use `==` / `!==` on the cron secret. Practical timing-attack exploitability is low over public networks but is a free hardening.

**How**: `hmac.compare_digest(x_cron_secret, CRON_SECRET)` in Python; `crypto.subtle.timingSafeEqual` (after wrapping both in `TextEncoder` byte arrays of equal length) in Deno.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-MED] Add rate limiting on FastAPI public routes (store/* + login)

**What**: No app-level rate limit on `/api/store/*`, `/api/public/config`, or the auth-burning `/api/config` (which validates the Supabase JWT every request via an outbound `requests.get` — itself a DoS amplifier against Supabase auth).

**How**: Add `slowapi` (FastAPI-native) keyed by IP, default `60/minute` for `/api/store/*`, lower for the share-create + revoke routes.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-MED] Bound numeric URL/query params in store.js

**What**: `static/store/store.js` lines 145, 173-175 coerce `eventId`, prices, qty via `Number()` with no upper/lower bound. Edge cases (`Infinity`, very-large ints) propagate to API calls and DOM text.

**How**: Clamp to sane bounds (`eventId 1..1e9`, `min_price/max_price 0..1e6`, `min_qty 1..50`). Reject non-finite values with a user-facing error.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-LOW] Add SRI + clickjacking hardening on retail HTML

**What**: `static/store/{index,event,shares}.html` reference `/static/store/style.css` without `integrity`. Pages have no `X-Frame-Options` / `frame-ancestors` (covered if the CSP entry above lands).

**How**: Generate SHA-384 hashes for `style.css` + `store.js` and add `integrity="sha384-..." crossorigin="anonymous"`. The CSP `frame-ancestors 'none'` covers iframe embedding.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-LOW] Document the `get_app_secret` whitelist + rotation runbook

**What**: `get_app_secret`/`upsert_app_secret` are correctly whitelisted (good), but the whitelist is implicit in the function body and grows every time a new upstream lands. There's no place to look up "which secrets exist, who can read them, last rotated when".

**How**: Add a `vault.secret_metadata` view (name, last_rotated_at, owner) and a section in `MIGRATION_CONVENTIONS.md` that requires every new vault secret to add itself to the whitelist + this metadata table in the same migration.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — Set Railway CRON_SECRET to unblock EVO orders — VALUE REDACTED 2026-05-11

**Status**: superseded by the [SEC-CRIT] rotation row at the top of SECURITY BACKLOG. The original literal value was redacted from this row on 2026-05-11 (security chat) — see git log for the audit trail. Do NOT re-introduce the literal into source. Recipient: get the rotated value out-of-band from Julian.

**How** (operational, no secret in source):
- Railway dashboard → terminal-2-production service → Variables → add/update `CRON_SECRET=<rotated value, out-of-band>`
- OR `railway variables set CRON_SECRET=<rotated value, out-of-band>` if using the CLI
- After setting, redeploy is automatic; next cron tick (≤ 10 min) starts ingesting

**Verify**: `SELECT COUNT(*) FROM evo_orders` 30 min after redeploy — should be > 0.

**Why this is on the board**: design surfaced it during the 2026-05-08 Supabase data-reality pass. It's been the persistent action item from `docs/audit-2026-05-09.md` §5 item 1. Several design surfaces (Undelivered Window, Event Workbench order book strip, Pricing Queue) need EVO orders to feel populated.

**Filed by**: design · 2026-05-08

---

### NEXT (code) — Backfill SG event xref to TEvo

**What**: SeatGeek has 186 distinct SG events with orders in our DB but only 0-1 are TEvo-xref'd today. SG also has 25 distinct SG events with seller listings, only 1 xref'd. Most existing SG data is invisible at the event level.

**How**: name+venue+date matching from `seatgeek_orders` + `seatgeek_seller_listings` against `events`. Likely 80%+ matchable via fuzzy name + exact venue + date-equals.

**Companion task — same pattern for SeatData** (`seatdata_event_xref` is also 1 event today; SD has 254 sales for that event but more SD pulls are coming).

**Why**: unlocks `unified_orders_by_event` for the entire SG-covered book. Currently every event-level order panel shows zero SG orders even when they exist.

**Filed by**: design · 2026-05-08 (per data-reality-2026-05-08.md)

---

### NEXT (design) — Order status uses unified vocabulary now

**What**: New `unified_orders` + `unified_orders_by_event` views (mig 20260509140000) collapse EVO + SG seller-direct + SeatData into a single rowset with 6 canonical states (`pending` / `accepted` / `substitution` / `rejected` / `cancelled` / `fulfilled`). Two flags carry alongside: `is_terminal` (state won't change), `is_sale_succeeded` (only `fulfilled`).

UI surfaces that should use this:
1. **Event hero "order book strip"** — render counts in canonical buckets (pending / accepted / fulfilled / rejected+cancelled / substitution) regardless of which source they came from. Add a small badge per source within each bucket if the user wants to drill in.
2. **Movers panel** — the "Read" classifier should consider `unified_orders_by_event.fulfilled` count vs `in_flight` count. Strong fulfilled momentum + low in-flight = supply about to dry up.
3. **Sale pipeline page** (Page 6 in the redesign memo) — shows 5 canonical buckets with rows from all 3 sources blended into each.

**Why**: Brokers don't think in "EVO completed vs SG fulfilled vs SG delivered". They think "did the sale go through". The canonical states model that.

**Backend ready**: yes. `SELECT * FROM unified_orders_by_event WHERE tevo_event_id = X;` returns per-source per-canonical-state counts + gross.

**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Companion strategy at docs/historical-data-and-multi-view-strategy-2026-05-09.md

**What**: Second strategy memo extending the redesign. Covers:
- 4 historical-data layers (event / performer / venue / matchup), each answering different broker questions
- Buyer sentiment composite (formula + 5 visual options) — backed by new `event_sentiment` table
- Similar-event matching — new `find_similar_events(event_id, n)` SQL function returns ranked comparables
- Micro→macro view spectrum (10 zoom levels)
- Web vs PWA differences (same data, different consumption pattern)
- Schema additions made live: `matchup_xref` (445 matchups seeded), `event_sentiment`, `performer_baselines` (72), `venue_baselines` (67)

**Why**: Mandate was "tell me ideal views and how to incorporate ALL the data". This is the answer for historical depth + sentiment + similar-event intelligence + the phone form factor.

**Verified live**:
- Sentiment composite separates bullish (Knicks G5 +54, Pistons-Cavs G3 +100) from bearish (Wolves-Spurs G5 -34)
- Similar-events for Knicks G5 returns G7/G2/G1 (perfect 2.0 score), G6/G4/G3 (1.6), Finals games (1.0)
- Matchup table groups 13 Yankees-Orioles, 13 Yankees-Blue Jays, 11 Red Sox-Yankees, 7 Knicks-76ers

**Read both memos as a pair**:
1. `docs/terminal-redesign-2026-05-09.md` — what 7 pages to build
2. `docs/historical-data-and-multi-view-strategy-2026-05-09.md` — how to incorporate historical/sentiment/similar/PWA

**Filed by**: code · 2026-05-09

---

### NEXT (design) — TERMINAL REBUILD per docs/terminal-redesign-2026-05-09.md

**What**: User mandate — **rebuild `static/index.html` from scratch** based on what the data actually supports. The full design memo is at `docs/terminal-redesign-2026-05-09.md` and includes:
- 7 page templates (Home / Event detail / Performer / Movers / Cross-source explorer / Order book / Settings)
- 9 findings from data simulations on actual prod data
- Build sequence (Event detail first, then Home, then Movers, etc.)
- Visual conventions, deletion list, open questions

**Why**: Prior `static/index.html` accumulated 3,000+ lines over many iterations. The data shape is now clearer (sports-first, owned_premium_pct should be top-line KPI, mover classification is missing). Cleaner to start fresh than refactor.

**Headliner finding**: `owned_premium_pct` (S4K asks vs competitor asks for the same event) varies from −32% to +255% across our book. It's the single most actionable broker metric and isn't surfaced anywhere right now. Make it the biggest number on the event page.

**Top of the build queue**: Page 2 (Event detail) — that's where 80% of broker time goes. Ship that first with the new owned-premium KPI; the rest follows.

**Backend coverage** (what's already there to support this):
- 822 active sports events with rich tracking (avg 48 snapshots, 7 days price history)
- Cross-source entity maps for clean translation (`entity_event_map`, `entity_performer_map`, `entity_venue_map`)
- All metrics tables populated (TEvo `event_metrics`, `seatgeek_event_metrics`, `seatdata_event_stats`)
- Order books from both TEvo and SG seller-direct
- Lifecycle classifier filters ghost events automatically

**Files**: `static/index.html` (rebuild), referencing endpoints in `app.py`. New endpoints to add are listed in §4 of the redesign memo (5 new routes).

**Filed by**: code · 2026-05-09

---

### NEXT (design) — Cross-source data coverage badge on event hero

**What**: New view `cross_source_event_audit` returns one row per TEvo event with: ESPN id, SeatData event_id + sales_count, SG event_id + listings count + active tickets, EVO orders, lifecycle status. Render this as a 4-light coverage badge on the event hero ("TEvo · ESPN · SeatData · SG"), each light lit per source linked. Plus a popover showing actual counts.

Plus three new chart series powered by `seatgeek_event_metrics`:
- `SG_Cost_Median` (line, $-axis) — our wholesale cost percentile
- `SG_Active_Tickets` (bar, count axis) — our active SG inventory
- `SG_Sold_Quantity` (bar, count axis) — sold SG history

**Why**: At a glance brokers see "we have 3-source coverage on this event" vs "TEvo only — no comp data". Drives decisions about which events deserve deeper attention.
**Backend ready**: yes — view + metrics table both populated by master cascade every 2 min.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — SeatGeek Seller Direct: S4K inventory + sales overlay

> **Status 2026-06-06:** **LISTINGS side shipped** — full-book rolling-cursor pull + AQ map + D0 event-page panel (`get_event_sg_seller_listings_full`, mig `20260606194100`; RESOURCES_BIBLE §5). **ORDERS side (`/orders`, `seatgeek_orders`) is OBSOLETE** (operator directive) — feed is stale to 2025-06 with no payment data; not maintained, do not build the orders overlay below. Real-time upgrade for listings = webhook **D2-OPS-3** (still merged/undeployed).

**What**: SG Seller Direct integration is live. Listings are pulled full-book (rolling cursor) from `sellerdirect-api.seatgeek.com` and AQ-mapped to canonical TEvo events. Every row carries inline event metadata, so `seatgeek_event_xref` / `sg_events_canonical` auto-fill via fuzzy match. *(Orders ingest below is obsolete — see status banner.)*

UI surfaces to add:
1. **"S4K on SG" panel on event hero**. `GET /api/seatgeek/event/{tevo_id}/seller-listings` returns our active SG listings for the event with summary (count, tickets, median cost). Show as a small dense panel: "S4K SG: 12 listings · 47 tix · median cost $89".
2. **Realized SG sales chart series**. `GET /api/seatgeek/event/{tevo_id}/seller-orders` returns persisted orders with state breakdown. Add a new chart series `SG_Orders_Confirmed` (bar, hourly) — direct visibility into our SG sales velocity, parallel to TEvo's evo_orders.
3. **Cross-source sale comparison**. Combine: TEvo evo_orders (our TEvo sales), SG seller_orders (our SG sales), SeatData sales (whole-market sold comps), TEvo evo asks (current asks), SG seller_listings asks. That's 5 series for a single event — dense but each has a distinct color/dash convention.
4. **Auto-link status badge**. `GET /api/seatgeek/seller-status` reports auto-link rate. Surface on a settings page: "SG events seen: N, auto-linked to TEvo: M". When auto-linked stalls or fails, badge goes amber.

**Why**: This is the deepest data we have. SG Seller Direct gives us OUR actual transactions on SG, not market-wide aggregates. Combined with TEvo /v9/orders we now have the full S4K sales pipeline on both marketplaces.
**Backend ready**: yes — cron firing every 10 min, 200 listings + 400 orders already persisted from initial test pulls.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — SeatGeek BROKER DATA: marketplace listings + sold-comp overlay

**What**: SG integration is now the **broker** data API (not public). Three high-value UI surfaces:
1. **SG marketplace overlay** on the chart workbench. `GET /api/seatgeek/event/{id}/listings?latest_only=true` returns ALL secondary listings on the SG marketplace (when v2 was used). Plot as a scatter overlay alongside TEvo asks — gives brokers cross-marketplace visibility (TEvo asks vs SG marketplace asks).
2. **SG sold-comp panel** on the event hero. `GET /api/seatgeek/event/{id}/sales` returns transacted broadcast (wholesale) prices. Pair with SeatData's retail-side sold prices — together that's the full "what's actually clearing" view.
3. **Match button + manual link**. Broker API has no search endpoint. Show a "Link to SeatGeek" button when `seatgeek_event_xref` is empty; opens a small input that POSTs `/api/seatgeek/event/{tevo_id}/link?sg_event_id=N`. The user pastes the SG event_id from their SG broker portal (or any SG URL) once per event.
4. **"We are the marketplace" indicator**. `seatgeek_listings_snapshots.is_broker_owned=true` flags listings posted by THIS account. Surface as a badge: "S4K is N of M listings on SeatGeek".

**Why**: SeatGeek + TEvo + SeatData together give us 3-source coverage. SG is the only source that exposes BOTH our listings AND competitor listings on the same marketplace. The `sglid` (SeatGeek Listing ID) gives us cross-source listing linkage if we ever want to compare the SAME listing across exchanges.
**Backend ready**: yes — `POST /api/seatgeek/event/{tevo_id}/link?sg_event_id=N` then `POST /sync-listings` (with `?v2=true` for full marketplace) and `POST /sync-sales`.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — EVO orders: hero strip + chart series + e-ticket alerts

**What**: TEvo `/v9/orders` is now ingested every 10 min into `evo_orders` + `evo_order_items`. Three UI pieces unlock high-impact broker workflows:

1. **Order-book strip on event hero** — compact 5-segment bar showing pending / accepted / rejected / completed / pending_substitution counts pulled from `GET /api/broker/event/{id}/orders`. Click → side panel with the raw rows.
2. **Chart series `EVO_Orders_Completed`** — bar chart on `yC` axis, hourly buckets. The purest signal of demand for our specific inventory.
3. **E-ticket fulfillment alerts** — top-of-dashboard red banner if any item has `eticket_available=true AND eticket_downloaded_at IS NULL` for an event within 48h. The whole dashboard should pulse red until it's cleared.
4. **Hold-expiry alerts** — yellow badge on event tiles where `hold_expires_at < NOW() + 1h`.

**Why**: We've been flying blind on our own order book. Brokers waste time reconciling between the TEvo dashboard and our terminal; this brings the order state inline with the pricing data they're already looking at. The e-ticket alerts in particular catch deliverability misses BEFORE the buyer complains.

**Backend ready**: yes — cron jobid 40 firing every 10 min as of `<sha pending>`. `GET /api/broker/event/{id}/orders` returns `{ items, orders, summary: { total_items, by_state, tickets_sold, gross_sold, last_update_at } }`.
**Reference**: `docs/data-sources-terminal-uses.md` §5 has all 7 UI ideas worked out.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Render SeatData sales overlay on the chart workbench

**What**: SeatData integration is live (commit *pending*). For any TEvo event linked to SeatData, `/api/seatdata/event/{tevo_event_id}/sales` returns up to 5000 historical sale rows: `{sale_timestamp, quantity, price, zone, section, row}` plus an aggregated `summary: {avg, median, min, max, tickets_total, zones, first_sale, last_sale}`.

UI surfaces:
1. **Chart workbench** — add a new togglable series category "SeatData_Sales" (paint as scatter dots, not line). Each dot is a transacted sale; size = quantity, color = zone. Hover tooltip shows `$price · qty · section · row`. Y-axis = `y$` (same as TEvo prices).
2. **Event hero** — small badge "SeatData: 254 sales · median $668 · last sold 14m ago" pulled from the summary. Click opens a side panel with the sale list.
3. **Sync button** — manual "Refresh sales" button on the event page that POSTs `/api/seatdata/event/{id}/sync-sales` (charges 1 pull). Disable with tooltip if `/api/seatdata/budget` says budget is exhausted.
4. **Splash for unlinked events** — when `/api/seatdata/event/{id}` returns `linked:false`, show a "Match this event to SeatData" button that POSTs `/auto-search`.

**Why**: TEvo gives us asks; SeatData gives us actual transactions. Brokers price against transacted comps, not asks. This is the most actionable signal we've added since the chart workbench itself.
**Backend ready**: yes — Knicks G5 (TEvo 3345925) is pre-populated with 254 rows for visual testing.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Render event lifecycle status badge

**What**: Backend now classifies every event as `active | ghost_eliminated | completed | postponed | cancelled` via the new `lifecycle` block in `/api/broker/event/{id}/overview` and `lifecycle` field on each event in `/api/portfolio`. UI surfaces that need treatment:
1. **Event hero** (top of event detail page): show a colored badge if `lifecycle.status !== 'active'`. Suggested colors: `ghost_eliminated` = dim red, `completed` = neutral gray, `postponed` = amber, `cancelled` = solid red. Include `lifecycle.reasons[0]` as a small subline.
2. **Watchlist row + Movers list**: small dot or strikethrough on rows where the event is non-active. Tooltip shows the reason.
3. **Portfolio header**: when `inactive_excluded_count > 0`, show "N ghost events hidden" with a "Show all" link that re-fetches with `?include_inactive=true`.

**Why**: 18% of future events in our system are ghosts (eliminated playoff brackets). Without this badge a broker can scan the watchlist and waste time triaging events that won't happen. Knowing at-a-glance which events are actually playable is critical.
**Backend ready**: yes — the lifecycle data is live as of `<sha pending>`. Just consume it.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Splits inventory panel needs a glance-readable design

**What**: The chart already exposes `splits_min_q`, `splits_pct_pairs`, `splits_pct_singles`, `splits_with_singles..4plus`. The event page has a Splits Inventory panel but it's currently a bare table. Redesign to make "what splits are out there RIGHT NOW" answerable in <2 seconds.

**Why**: Splits are the difference between "this listing is buyable" and "this is a 6-pack only stadium tier" — brokers need to triage at a glance.
**Files**: `static/index.html` (search for "Splits Inventory")
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Event hero needs a "TIL EVENT" countdown

**What**: Top of event page shows home/away logos, venue, date. Add a prominent days-hours-minutes countdown to game time, color-shifted as it gets close (>14d gray, 7d-14d soft, 1d-7d accent, <24h hot). Updates live in-page.

**Why**: Time-to-event drives the entire collect-listings cron tier (20m / 1h / 4h / 12h / daily) — brokers think in event-proximity, the UI should too.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Watchlist 3-tab needs a sort persistence story

**What**: Watchlist tabs (mine / movers / gametime) lose sort state on tab switch. Persist `sortBy` + `sortDir` per tab in localStorage with versioned key.

**Why**: Brokers customize sort by tab (mine = my-positions-by-cost-basis; movers = absolute change; gametime = chronological). Forcing them to re-pick on every tab is annoying.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Update get_performers_by_league RPC to filter ghost events

**What**: `/api/broker/performers/by-league/{league}` now accepts `?include_inactive=` but the underlying SQL RPC (`get_performers_by_league`, mig 20260508050000) aggregates over ALL events including ghost playoff brackets. Rewrite the RPC to JOIN against `event_lifecycle` and exclude `is_active=false` rows when the new `p_include_inactive` arg is false.

**Why**: A team like Boston Celtics gets aggregate `home_events=8` from all the speculative Round 2/3/Finals home games even though they're eliminated. Should be `home_events=2` (the actual played games). Currently the API response includes `_inactive_filter_applied: false` so the frontend can flag the discrepancy.

**Files**: `supabase/migrations/<new>.sql` + matching update in `app.py` to pass through `p_include_inactive`.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Investigate listings_snapshots index for zone backfill timeout

**What**: `backfill_stale_zone_metrics` has been timing out at 120s pre-cascade. Check whether `(event_id, captured_at, is_ancillary)` index exists. Add if missing. Re-run a 50-batch test to confirm we can fold zone backfill back into the master cascade.

**Why**: Currently zones runs on a separate slower cron (jobid 39, batch=5) which is below historic throughput. An index could let us collapse it back into the 2-min cascade.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Replace league→slug CASE with a lookup table

**What**: `auto_link_event_xref` currently has a hardcoded CASE mapping NBA→`basketball/nba`, NFL→`football/nfl`, etc. Create a `league_slug` table; reference it from the function.

**Why**: SeatGeek migration will need multi-source slug mapping. Hardcoded CASE blocks that.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Fix `is_baseline` detection in espn-collect

**What**: NBA/NFL/MLS/WNBA/WC always return `is_baseline=true` from `espn-collect.roster`. Only MLB+NHL detect changes correctly. Means injury-change overlays only render markers for 2 of 7 leagues.

**Why**: User reported NBA injuries didn't show as overlays. Root cause is upstream content_hash logic skipping the change-detection branch for those 5 leagues.
**Files**: `supabase/functions/espn-collect/index.ts`
**Filed by**: code · 2026-05-09 (carried over from prior session)

---

### NEXT (code) — Extend `espn-collect.gameday` scope to MLS/NHL/NFL/WNBA/WC

**What**: Currently only iterates NBA + MLB events. Means MLS/NHL/NFL/WNBA/WC have full performer-level coverage but ZERO event-level snapshots/xref. ~80% of the cross-league data gap.
**Files**: `supabase/functions/espn-collect/index.ts`
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Capture 6 MCP-applied migrations into prod migration ledger

**What**: 6 migrations (20260508220000 through 20260509040000) have been applied via Supabase MCP `execute_sql` and captured as files in `supabase/migrations/`, but the prod migration ledger doesn't list them. Run `supabase db push` (or equivalent) to reconcile.

**Why**: Drift detection (sync-check.sh) flags this on every run.
**Filed by**: code · 2026-05-09

---

## BLOCKED

### BLOCKED (design) — Polish the chart range switcher

- **What**: Removed `color` from the `.rng` transition (was the source of the activate flash); added `[` / `]` keyboard stepping (one-shot global listener that respects input focus and clamps at the ends); added a Chart.js crosshair plugin + switched the tooltip to `mode:'index'` so all visible series values render at the snapped x; added a relative-time `title` callback ("3h ago", "yesterday 4 PM", "Apr 24") replacing the long ISO.
- **Files touched (already on disk, not yet reviewed/committed)**: `static/index.html`
  - CSS: ~lines 88-101 (`.rng` transition + new `:focus-visible` outline)
  - JS keyboard wiring: ~lines 1726-1755 (`_wireRangeKeyboard` + call from `_wireRangeButtons`)
  - JS chart helpers: ~lines 1830-1888 (`_formatRelativeTime`, `_evtChartCrosshair` plugin)
  - JS tooltip config: ~lines 2065-2080 (`mode:'index'` + `title` callback)
  - JS chart constructor: ~lines 2147-2151 (register `_evtChartCrosshair` locally, not globally)
- **Blocker**: paused by Julian — hold review/commit until he gives the go-ahead. File edits remain in the worktree; nothing has been pushed.
- **Started**: 2026-05-09 02:15 UTC
- **Flagged by**: design · 2026-05-09

---

## DONE (last 10)

### DONE — `7413ede` · feat(d0): multi-source data model — movers v2, market carpet, discovery gaps, TD freshness
- **Migrations (4)**:
  - `20260527200000` — TD owned-tickets fix + reschedule cron 4×/day
  - `20260527240000` — `sg_classify_events()` rewritten to use `event_listing_snapshot_daily` instead of 12.7M-row `listings_snapshots` scan; was timing out every 5 min since 08:40 UTC
  - `20260527250000` — `event_movers_index` + `event_movers_index_history` tables; TD columns on `event_listing_snapshot_daily`; `compute_event_movers_index_all()` (30 source×window combos); `discovery_gap_alerts` table + `evo_sg_discovery_gaps()` populate function; crons at 35 13,19,3 + 9am
  - `20260527260000` — `get_event_movers_v2` RPC (28 cols, cross-source medians + spreads); `get_event_movers_index_summary` RPC; `/api/broker/movers` v2 path in `app.py` (`?window_days=N&source=X[&category=Y]`)
- **Terminal UI (7 files)**:
  - `event.html/js` — TD Markets tab (SH/GT/VD snapshot history table); `#data-freshness` section (9-source per-row age/status/listings/median table); TD fr-chips (SH/GT/VD) in hero; `loadTdFreshness()` + `renderDataFreshness()` added
  - `performer.html/js` — Market Carpet tab (cross-source medians + movers index + discovery gap signals per upcoming event)
  - `venue.html/js` — Market Carpet tab (same as performer, + Performer column)
  - `movers.html/js` — Index v2 mode (default): SOURCE × HORIZON × CATEGORY selectors; legacy mode toggle; v2 calls `/api/broker/movers?window_days=`; `renderV2Summary()` / `renderV2Events()` / `buildV2Table()`
  - `discovery.html/js` — Discovery Gaps panel (first panel): queries `discovery_gap_alerts`, 10 gap types, type filter chips, priority sort
- **Docs**: `PROJECT_BIBLE.md` landmark migs + landmines; `RESOURCES_BIBLE.md` 5 new tables, D0 tab matrix, v2 API path
- by: D0 · landed: 2026-05-27

### DONE — D4-OPS-2 · D4 data cut-over — no migration (test data, fresh Supabase start)
- Operator confirmed all Firestore data is test-only. No Firestore→Supabase copy needed. `exos_*` tables start at 0 rows and populate via normal UI use (org create → events → tickets). `scripts/migrate-to-orgs.ts` was a Firestore-internal restructuring pass (stamps `orgId` on Firestore docs) — not applicable to the Supabase cut-over. All 5 D4 migration phases are live on prod (PRs #305 + #308).
- by: D4 · closed: 2026-05-23 · bot_chat #454

### DONE — `<sha pending>` · feat: cross-source order status mapping (unified vocabulary)
- Mig 20260509140000 adds order_status_xref (13 mappings, 6 canonical states), canonical_order_status() RPC, unified_orders view (254 SD fulfilled + 200 SG accepted + 200 SG fulfilled live), unified_orders_by_event rollup, order_status_coverage diagnostic. Caught and fixed seatgeek_sales_snapshots vs seatdata_sales_snapshots typo during build. SCHEMA v19. Future sources (TickPick, Vivid Seats) just add xref rows + UNION branch.
- by: code · landed: 2026-05-09 04:30 UTC

### DONE — `005e3c0` · feat: matchup index + buyer sentiment + baselines + similar-events finder
- See AGENTS LOG for details.
- by: code · landed: 2026-05-09 04:00 UTC

### DONE — `<sha pending>` · feat: cross-source entity maps (universal id translator)
- 3 views (entity_event_map / entity_performer_map / entity_venue_map) translate any source's id to all others, TEvo as hub. 6 translation functions (forward + inverse, both directions). taxonomy_xref table seeded with 12 league/type mappings (NBA, MLB, etc.). cross_source_coverage diagnostic view. Live coverage: 269/1233 events on ESPN, 37 multi-source performers, 21 SG-linked venues. All round-trips verified. Mig 20260509120000. SCHEMA v17.
- by: code · landed: 2026-05-09 03:30 UTC

### DONE — `e7e680f` · feat: SG metrics + xref + cascade + RULE 2 read-only
- Mig 20260509110000. New tables: seatgeek_performer_xref (102 auto-linked from listings/orders), seatgeek_venue_xref (21), seatgeek_event_metrics (28 cols parallel to event_metrics + seatdata_event_stats). New views: seatgeek_categorized_listings, cross_source_event_audit. Smart matcher fix prevents ghost-event mismatches (Lynx→Timberwolves bug fixed). master_cascade_2min extended with SG xref + metrics stages (1.7s total runtime). RULE 2 read-only enforcement at code level (HTTP method allowlist in evo/seatdata/seatgeek clients). Cross-source audit shows Knicks G5 with TEvo+ESPN+SeatData coverage (3 sources, 254 sales). SCHEMA v16.
- by: code · landed: 2026-05-09 03:15 UTC

### DONE — `c3762f5` · feat(seatgeek): seller-direct ingest with auto-xref via inline event metadata
- Added 2nd SG broker host (`sellerdirect-api.seatgeek.com`). Probe revealed /listings (157,846 active S4K), /orders?status= (496K fulfilled lifetime), /order single. Migration 20260509100000 adds seatgeek_seller_listings + seatgeek_orders + order_tickets + pull_log + sg_attempt_event_xref RPC + seatgeek_orders_by_event view. Each row carries inline event metadata → fuzzy match to TEvo on (date, venue) auto-fills xref. Live test: page-1 listings = 200 rows, 25 distinct SG events, 2 auto-linked to TEvo. Cron seatgeek-seller-collect-10min (jobid 41) every 10 min, pulls 5×200 listings + 4 status filters of orders. Page=N is deprecated; client uses page_cursor pagination. SCHEMA v15.
- by: code · landed: 2026-05-09 03:00 UTC

### DONE — `089c9a8` · refactor(seatgeek): scrap public-API, rebuild for BROKER DATA API
- v13 used wrong host (api.seatgeek.com/2 with ?client_id=). Token is actually for brokerdata.seatgeek.com with ?token=. Mig 20260509090000 drops 5 unused tables, rebuilds around event_xref/listings_snapshots/sales_snapshots/pull_log + event_latest view. Client + 6 routes rewritten for /listings, /v2/listings, /sales (purchases scope unavailable). Live diag: 400 "No event found" on bogus event_id (auth pass), 401 on /purchases (covered by TEvo /v9/orders). SCHEMA v14.
- by: code · landed: 2026-05-09 05:00 UTC

### DONE — `4c9641f` · feat(seatgeek): integration scaffolded — section_info + recommendations + xref
- 3rd data source. Metadata + discovery only (no pricing). Mig 20260509080000 adds `seatgeek_event/venue/performer_xref`, `seatgeek_taxonomies`, `seatgeek_event_sections`, `seatgeek_recommendations`, `seatgeek_pull_log`, `upsert_app_secret(name, value)` RPC. New `seatgeek_client.py` covers all 9 SG endpoints. 6 new `/api/seatgeek/*` routes. Awaiting SEATGEEK_API_TOKEN push to Vault before live test. SCHEMA bumped to v13.
- by: code · landed: 2026-05-09 04:30 UTC

### DONE — `914d846` · feat: vault for keys + SeatData↔TEvo mapping + EVO orders 10-min cron
- (a) Supabase Vault stores `SEATDATA_API_KEY`; `get_app_secret(name)` RPC reads it. seatdata_client uses vault by default. (b) New cross-source xref tables (venue/performer/zone/section) + `normalize_sd_listing()` function + `sd_sales_normalized` view fixing the SeatData quantity-null caveat. (c) TEvo `/v9/orders` ingested every 10 min: `evo_orders`, `evo_order_items`, `evo_orders_by_event` view; cron jobid 40. New routes: `POST /api/admin/collect-orders`, `GET /api/broker/event/{id}/orders`. EvoClient gained `list_orders`/`iter_orders`/`get_order`. (d) Bucket 18 added to taxonomy. Comprehensive memo at `docs/data-sources-terminal-uses.md`. Mig `20260509070000`. SCHEMA v12.
- by: code · landed: 2026-05-09 04:00 UTC

### DONE — `0582fac` · feat(seatdata): integration live + Knicks G5 sales pulled (254 rows)
- New second-source pricing API alongside TEvo. Hard-capped to BASIC plan budget (100/day, 2000/month) at the DB level. New `seatdata_client.py` + 7 `/api/seatdata/*` routes. Live-tested on TEvo 3345925: matched to sd_event_id=1247184, pulled 254 historical sales (median $668, avg $773, range $378-$3,756). Mig `20260509060000`. SCHEMA v11. **User action required**: set `SEATDATA_API_KEY` env var on Railway.
- by: code · landed: 2026-05-09 03:00 UTC

### DONE — `dc4c41d` · feat(events): lifecycle classifier sorts ghost playoff games out of live surfaces
- New SQL fn `derive_event_lifecycle(event_id)` + view `event_lifecycle`. Status enum `active | ghost_eliminated | completed | postponed | cancelled`. Strongest signal: TEvo `last_seen` staleness (live=avg 1.0h, ghost=avg 133h, zero overlap). Wired into `/api/broker/event/{id}/overview` (lifecycle block), `/api/broker/movers` (`?include_inactive` defaults false), `/api/portfolio` (per-event lifecycle + `inactive_excluded_count`). Distribution: 1045 active / 95 completed / 89 ghost / 2 postponed / 1 cancelled. Mig `20260509050000`. SCHEMA bumped to v10.
- by: code · landed: 2026-05-09 02:30 UTC

### DONE — `<sha pending>` · feat(cron): cascading 2-min freshness model
- 6 individual freshness crons collapsed into `master-cascade-2min` (jobid 38). ESPN injury/trade cadence 10m → 2m. Worst-case event coverage staleness 50m → 2m. Verified runtime ~150-200ms per tick. Side-fixed `auto_link_event_xref` NOT NULL bug. SCHEMA bumped to v8.
- by: code · landed: 2026-05-09 00:55 UTC

### DONE — `<sha pending>` · fix(chart): pin x-axis to range_meta + Robinhood-style transitions
- Backend now returns `range_meta: {hours, since, until}`. Frontend pins Chart.js x-axis explicitly to that window so 30d view doesn't collapse to 24h when newer series have sparse history. Auto-picks time unit (hour/day) by range. Smooth fade between ranges. Active range button uses `.rng.active` class.
- by: code · landed: pending push (this commit)

### DONE — `999ad3f` · feat(cron): cascading freshness migration committed
- See above for details.
- by: code · landed: 2026-05-09 00:55 UTC

### DONE — `27e20bd` · feat(chart): new default series + bar chart type for quantity
- by: code · landed: 2026-05-08 ~23:30 UTC

### DONE — `c58d6a4` · feat(schema): SCHEMA.md v6 + RULE 1 + midnight sweep cron
- by: code · landed: 2026-05-08

### DONE — `c8af9b8` · fix(chart): range buttons toggle active state via CSS class
- by: code · landed: 2026-05-08

---

## Reference — column conventions

- **NEXT** rows include: What, Why, Files (if known), Filed-by + date.
- **DOING** rows include: What, Files touched (with line range estimate), Status, Started timestamp.
- **DONE** rows include: commit SHA, subject line, by-whom, landed timestamp.
- **BLOCKED** rows: copy of the original DOING content + a `**Blocker**:` line + by-whom-flagged.

If a row sits in DOING for >2 days untouched, code's audit pass surfaces it as a stuck-work flag.
