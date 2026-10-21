# KANBAN.md — Terminal-2 shared work board

> **Doc version:** v2.0.0 (2026-10-21) — **Board reset.** v1 (1,339 lines, last v1.138.0) frozen verbatim at [`docs/archive/2026-10-21-kanban-v1-archive.md`](docs/archive/2026-10-21-kanban-v1-archive.md); search it by row ID for history. Every still-open v1 row is carried forward below in one line; rows the 2026-10-21 full audit (tests, UX sweep, live Supabase read-only audit) proved done, obsolete or moot are listed in §Closed-on-reset. New audit findings filed as `A1-DB-*` (Supabase), `D0-UX-*`/`D1-UX-*` (UX), `B1-CODE-*` (code).

> **One source of truth for what's open, who's on it, and what's next.** Priority lives in the banner below and nowhere else (`CLAUDE.md`).

---

## 🎯 CURRENT PRIORITIES

- **★ #1 — Supabase hardening (operator 2026-10-21: "focus on the supabase as most urgent").** Work the 🔴 P0 table top-down: authenticated-readable order views → RLS-off tables → the always-failing rollup cron → cron startup-timeout congestion → stale listing data → storage bloat → edge-function hygiene → repo↔prod migration drift.
- **★ Product focus:** D0 terminal. D1–D7 lower priority (a focus call, not a lockout — permission is per-action, `PROJECT_BIBLE §2.1`).

---

## 🟢 OPEN WORK — live operating ledger (all lanes)

### Closure protocol

1. **Fixing session DELETES its row** in the same PR as the fix and appends one line to §Closed below (`ID — what — PR #`). Row absence is the closure signal.
2. **Mid-work:** prefix the row's lane cell with `[IN PROGRESS <lane>, PR #n]`.
3. **Anyone can add rows.** Sort within a table by severity.
4. **Prod mutations stay operator-gated** (`CLAUDE.md §1`): a row may be *authored* by any session; *applied* only with an explicit operator yes. Mark authored-not-applied rows `[AUTHORED, apply pending]`.
5. **Duplicate IDs are forbidden.** v1 reused two IDs; renamed on reset: `A1-OPS-24` (last30days) → **A1-OPS-34**, `A1-OPS-29` (retention redesign) → **A1-OPS-35**.

Lane codes (surface regions, not ranks — `PROJECT_BIBLE §2`): `A1` data plane · `B1` build/guards/docs · `D0` terminal + orders · `D1` storefront · `D3` broadway · `D4` Exos (source in `JulianS4K/EXP`) · `D5` fantasy · `D7` N2S (subset of D0) · `Op` operator-only.

### 🔴 P0 — Supabase (filed 2026-10-21 from the live read-only audit)

Live baseline at audit time: project `hzrizjeaxlqcxfrtczpq`, 351 GB, 755 public tables, 211 active / 60 inactive crons, `cron.max_running_jobs=32`, ~1,420 cron runs/h, 68 deployed edge functions, 11 auth users.

| Sev | ID | Lane | Finding | Smallest next action |
|---|---|---|---|---|
| SEC-HIGH | A1-DB-1 | A1 | **Order/P&L views readable by ANY authenticated user.** `unified_orders` (buyer/seller/client names), `v_n2s_orders`, `v_n2s_orders_live`, `v_sub_orders`, `v_gt_credit_health` are SECURITY DEFINER (bypass RLS), have no per-user filter, and `authenticated` holds SELECT. The auth pool is shared with Exos, so once Exos opens public sign-up every buyer could read them over PostgREST. Supersedes v1 `B1-NEXT-60`. | Revoke SELECT from `anon, authenticated` (backend reads with service-role, unaffected) — or `security_invoker=on` where a browser reader exists. Migration authored this PR; apply is operator-gated. |
| SEC-HIGH | A1-DB-2 | A1 | **8 public tables with RLS OFF.** anon-readable: `zone_price_observations`, `espn_athlete_brand`, `athlete_pages`, `athlete_external_ids`, `athlete_wikipedia`; authenticated-readable: `deal_price_train`, `deal_price_train_state`, `deal_price_adjust`. | `ENABLE ROW LEVEL SECURITY` + an explicit read policy only where a browser reader exists. Migration authored this PR. |
| SEC-MED | A1-DB-3 | A1 | `anon` holds INSERT (and other DML grants) on view `v_reddit_news_ticker`. | Revoke all but SELECT. Folded into the A1-DB-1 migration. |
| OPS-P0 | A1-DB-4 | A1 | **`venue_section_rollup_hourly` (job 479) has never succeeded in retained history** — 168/168 fails in 7 days, `statement timeout` at 600 s in the `WITH reps AS (SELECT DISTINCT…)` step. Every run burns a worker slot for 10 min. | Bound the work (loop-level `clock_timestamp()` budget / batch by venue) or pause the job until fixed. |
| OPS-P0 | A1-DB-5 | A1 | **Cron congestion: ~2% of all runs fail with `job startup timeout`** (20–57/h). 32 worker slots vs 7 every-minute + 3 sub-minute jobs + many jobs piled on the same minutes. Worst: `aq_reschedule_sync_from_tevo_30min` 54% fail, `sg_blindspot_mv_refresh` 22%, `reddit_news_*` 5–6%, `n2s_pipeline_tick_1min` 40/day. | Re-stagger schedules off the peak minutes (concurrency map in the 2026-10-21 audit), lengthen sub-minute intervals that don't need them. |
| OPS-P0 | A1-DB-6 | A1 / Op | **Market data stale.** `listings_snapshots` + `section_metrics` last row 2026-10-14 09:08 (7 d); `event_metrics` 2026-10-20; `seatgeek_listings_snapshots` + `gotickets_listings_snapshots` frozen since the 2026-09-27 poller pause (mig `20260927043400`); `axs_seat_snapshots` since 09-01. `/prices` get-in prices are therefore stale. | Find the writer that stopped on 10-14 (not explained by the 09-27 pause); operator decides whether to resume the paused pollers. |
| OPS-P1 | A1-DB-7 | A1 / Op | **~150 GB of reclaimable bloat.** `gotickets_listings_snapshots` 130 GB for ~1.4 M rows (33 GB pkey); `ticketsdata_listings_snapshots` 34 GB with ~0 live rows (vendor lapsed); `listings_snapshots` 67 GB (30 GB indexes); `axs_event_snapshots` 4.3 GB TOAST for 5.7 k rows. | Operator-gated: `TRUNCATE`/drop the dead TD table; `pg_repack`/`VACUUM FULL` the GT table in a window. Ties to A1-OPS-16..21. |
| OPS-P1 | A1-DB-8 | A1 | Two **INVALID** leftover indexes from a failed concurrent reindex: `idx_gt_ls_captured_ccnew`, `idx_gt_ls_event_time_ccnew` (still maintained on every write). | `DROP INDEX` both. Folded into this PR's maintenance migration. |
| OPS-P1 | A1-DB-9 | A1 / B1 | **Edge functions deployed with no source in this repo:** `diag-ticket-groups`, `sms-bot`, `web-bot`, `espn-dbg`, `probe-espn-data`, `probe-tevo-category`, `hub-preview`, `ledger-*` (6). Most are `verify_jwt=false` = publicly invokable. `sg-seller-webhook` is in-repo but not deployed (= A1-OPS-30). | Pull source or delete the debug/probe fns (Supabase dashboard / CLI — no MCP delete); decide whether `ledger-*` belongs in this project. |
| OPS-P1 | A1-DB-10 | A1 / B1 | **Repo↔prod migration drift.** Prod records apply-time versions, so version diff is meaningless; by name (Sept→now) 49 repo files have no same-named prod row (many applied split `_part1/_part2`) and 155 prod rows have no file — some confirmed absent from git entirely: `require_mfa`, `cron_move_35_jobs`, `listings_poll_owned_scope_view`, `listings_poll_scope_view_revert_owned`, `a1_rollback_20260901_*`, `td_retire_crons`, `housekeeping_offpeak`. Confirmed **not** in prod: `listings_pollers_deadlock_guard`. Supersedes v1 A1-OPS-12. | Backfill the prod-only migrations into `supabase/migrations/` from `supabase_migrations.schema_migrations.statements`; add a name-based drift check to `bin/sync-check.sh`. |
| SEC-LOW | A1-DB-11 | A1 / Op | Advisor WARNs: 202 SECDEF fns EXECUTE-able by `anon`, 509 by `authenticated`, 70 fns with mutable `search_path`, 3 extensions in `public`, leaked-password protection OFF, 30 RLS policies re-evaluating `auth.*()` per row, 354 never-used indexes, 144 unindexed FKs (mostly `ledger`). | Triage anon-executable SECDEF list (revoke write-ish ones); Op toggles leaked-password protection in Auth settings. |

### 🟠 App / UX (filed 2026-10-21 from tests + Playwright sweep of 53 pages × 2 viewports)

Baseline: backend pytest 2,219 passed / 17 skipped / 100.00% coverage; frontend smoke 52/52; RULE-2 audit clean.

| Sev | ID | Lane | Finding | Smallest next action |
|---|---|---|---|---|
| P1 | D0-UX-1 | D0 / B1 | **Rate limiter 429s the app's own JS/CSS.** Static assets share the 200 req/min/IP default bucket (`server.py` `_RateLimitMiddleware`); a terminal page costs 10–16 requests, so one fast user (or an office NAT) gets pages with `nav.js`/`app.js` missing. | Exempt `/static`, `*.js`, `*.css`, images — or give them their own large bucket. |
| P1 | D0-UX-2 | D0 | **PWA broken on the unified host:** `static/terminal/pwa.js` registers `/sw.js` → 404 (worker is served at `/terminal/sw.js`); console error on 18 terminal pages. | Register `/terminal/sw.js` (scope `/terminal/`) or route `/sw.js`. |
| P2 | D1-UX-6 | D1 | Store landing (`/store/index.html`) overflows at 390 px by 20–190 px (chip row + a button); 8–11 tap targets < 24 px. | `flex-wrap`/`min-width:0` on the chip row; 44 px targets. |
| P2 | D1-UX-7 | D1 | Store error/404 page 141 px wider than a phone (`.error-screen`, `.err-big`). | Constrain widths / `overflow-wrap`. |
| P2 | D0-UX-3 | D0 | `/undelivered/` fetches `d2-orders-dashboard.onrender.com/healthz`, blocked by its own CSP `connect-src`. | Add the origin to CSP or call a same-origin health route. |
| P3 | D1-UX-8 | D1 / B1 | Inline `<script>` blocked by CSP `script-src 'self'` on `static/index.html` (redirect never runs) and all `store/test/*`. `frame-ancestors` set via `<meta>` on every page is ignored by browsers. | Move inline JS to files; send `frame-ancestors` as a response header. |
| P3 | D1-UX-9 | D1 | `/prices/event.html` with no id calls `/api/prices/event/undefined` (422); `/favicon.svg` 404; `store/discover` 6 and `store/test/tour` 7 unlabeled inputs. | Guard the missing id; add favicon; `aria-label`s. |
| P3 | D1-UX-4 | D1 | (v1) Verify seat-map section tap → listings filter on mobile. | Live-browser check. |
| P3 | D1-UX-5 | D1 | (v1) Search-suggest dropdown lacks arrow-key/enter navigation. | Add keyboard handling in `static/store/store.js`. |

### 🟡 Code health (filed 2026-10-21)

| ID | Lane | Finding | Smallest next action |
|---|---|---|---|
| B1-CODE-1 | D1 | `STOREFRONT_RESERVE_REQUIRES_AUTH` defaults **true** (`core/config.py`) but `routers/store.py` docstring says the MVP leaves it off. | Fix whichever is stale. |
| B1-CODE-2 | D0 / Op | `render-d2-dashboard.yaml` marked DEFUNCT yet still starts `d2_dashboard.main:app`, which no longer exists. | Delete the file or the service. |
| B1-CODE-3 | A1 | `vivid_client.py`, `paciolan_client.py` have no production importer; `axs_client.py`/`ticketsdata_client.py` only scripts. | Keep (guarded, tested) or retire; decide in A1-OPS-28. |
| B1-CODE-4 | D0 | Size hotspots: `static/terminal/event.js` 7,223 LOC, `static/store/store.js` 3,280, `routers/broker.py` 3,040. Continues BR-CODE-4. | Next BR-CODE-4 slice. |
| B1-CODE-5 | D0 | Stale comment `server.py` ~L760 ("no HTML routes shipped") — `routers/pages.py` serves HTML. | Delete the comment. |
| B1-CODE-6 | B1 | 1,107 migration files but 1,060 unique timestamps — 47 version collisions (v1 B1-NEXT-10 named only 3). | Rename colliding unapplied files; leave applied ones. |

### 🔵 Carried forward from v1 (still open — one line each; history in the archive by ID)

| ID | Lane | Open item | Next action |
|---|---|---|---|
| A1-OPS-3 | A1 / Op | SG broker token shared with an external program; 6 SG crons paused since 06-19. | Op isolates the token. |
| A1-OPS-16..21 | A1 / Op | Firehose snapshot speed/bloat program (dedup, change-detection, partitioning, VACUUM FULL, post-event report, evo_discover phase 2, SG non-owned poller off). | See A1-DB-7; resume in order. |
| A1-OPS-24 | A1 / Op | Runaway-transaction cron fix (txn terminated 06-19; no >10 min txns at 2026-10-21 audit). | Confirm the cron body fix and close. |
| A1-OPS-35 | A1 / Op | Retention redesign `20260705153000`/`153500` authored, not applied (was the 2nd "A1-OPS-29"). | Operator apply decision. |
| A1-OPS-29 | A1 | `refresh_event_movers_agg` outgrew per-statement budgets; needs fast-by-construction rewrite. | Author rewrite. |
| A1-OPS-22 | A1 / Op | `aq_event_map` duplicate-row consolidation fn built (dry-run), pending apply. | Operator apply. |
| A1-OPS-2 | A1 | `compute_event_zone/section_metrics` heavy-event timeouts. | Pre-aggregate before percentile expansion. |
| A1-OPS-30 | A1 / Op | Our SG SellerDirect sales ingest-dark (`sg-seller-webhook` undeployed; table never applied). Same as v1 D2-OPS-3. | Apply 3 migs + deploy + vault secret + SG ticket. |
| A1-OPS-31 | A1 / Op | SG primary inventory unobservable (broker feed is resale-only). | Product decision. |
| A1-OPS-25 | A1 / Op | AXS purchase automation parked (data collection paused 09-01). | Operator decision. |
| A1-OPS-27 | A1 / Op | Bandsintown: client + `/api/broker/bandsintown/tour` route exist; no cron/table/UI and no vault `BANDSINTOWN_APP_ID`. | Wire or drop. |
| A1-OPS-28 | A1 / B1 | Engines-without-ignition sweep (orphans: `core/instagram_share.py`, see B1-CODE-3). | Analyze. |
| A1-OPS-34 | A1 / D0 | last30days social-pulse → `why_signals` exploration (was the 2nd "A1-OPS-24"). | Parked. |
| A1-OPS-SOCIAL-DEAD | A1 / Op | ESPN + Reddit fixed; X wire off (TwitterAPI.io credits exhausted). | Op recharges credits. |
| A1-OPS-SRC1 | A1 | TD credit-control sourcing redesign — moot while the TD contract is lapsed. | Revisit only if TD returns. |
| A1-OPS-6 | Op | Decommission the redundant D4 Railway service. | Op deletes it. |
| A1-OPS-14 | Op | Shared-working-tree contention between local sessions. | Process rule exists; keep. |
| A1-OPS-15 | A1 | `espn_injuries_snapshots` bloat (175 MB / 16.5 k rows). | Fold into A1-DB-7 pass. |
| BUGHUNT-1 | A1 / Op | `seatgeek_seller_listings` NULL-key dedup defeat; fix mig `20260626120000` authored. | Operator apply. |
| BUGHUNT-2 | D0 / Op | Holiday-window asymmetry in `core/movers.py` (product decision). | Operator decides. |
| BR-CODE-1 | D0 / A1 | `server.py` decomposition — now 2,013 LOC / 4 `@app` routes + 26 `routers/` files (v1 headline "8,753 LOC" stale). | Continue slices. |
| BR-CODE-2 | A1 / D0 | Client dedup (`BaseReadOnlyClient`); guard body already single-sourced. | Migrate remaining clients. |
| BR-CODE-4 | D0 / D1 | Frontend bloat (see B1-CODE-4). | Next slice. |
| D0-DEALS-1 | D0 / A1 | Deals feed outcome labels + model fit; `our_purchases_map_evo` (`20260911161100`) never applied (superseded). | Report-only fit; delete the superseded file. |
| D0-OPS-1 | D0 / Op | Apply `20260603120000` `get_event_all_source_listing_metrics` (not in prod by name). | Operator apply. |
| D0-PROD-8 | D0 | Per-performer Trip Planner shipped; refinement backlog. | Iterate. |
| D7-PROD-1 | D7 | N2S pipeline operating (health: see A1-DB-5 for `n2s_pipeline_tick` startup timeouts). | Monitor. |
| D7-SEC-1 | Op | Rotate the N2S CRM key (pasted in plaintext 2026-09-09); SG token travels in query string. | Op rotates. |
| D7-DATA-1 | D7 / A1 | TEvo `public_notes` never stored → sightlines unknown for most covers. | Persist `public_notes` in `core/store_events.py`. |
| D7-OPS-3 | B1 | `seam-review` blind to security controls living in migrations. | Extend its path map. |
| D4-OPS-33 | D4 / Op | Exos extraction: own Render service (`exos-web` + `EXOS_ORIGIN` proxy exists) and DB split not done. | Continue in `JulianS4K/EXP`. |
| D4-OPS-32 | D4 | Stage 3 organizer side — PR #976 draft, 4 migs. | Lives in EXP now. |
| D4-OPS-7 / 13 | D4 / Op | Payments + distribution scaffolds deferred. (Note: `exos-checkout`/`stripe-webhook`/`exos-distribute` ARE deployed in prod.) | Reconcile row vs reality in EXP. |
| D4-OPS-8 / 19 / 9 | Op | Exos mail idle (no `RESEND_API_KEY`/`EXOS_MAIL_FROM`); Auth SMTP not scaled. | Op sets secrets + custom SMTP. |
| D4-OPS-11 | D4 / Op | Physical door-scan rehearsal pending (DB side validated). | Rehearse. |
| D1-OPS-1 | D1 / B1 | Event JSON-LD blocked by CSP. | Hash-allow or external file. |
| D1-OPS-3 | D1 | `store.js` unminified. | Add minify step. |
| D1-OPS-5 | D1 / Op | Legal copy is placeholder — blocks any real purchase path. | Op supplies counsel copy. |
| D1-OPS-6 | D1 / Op | TEvo hosted checkout wired, dormant (`STOREFRONT_CHECKOUT_DOMAIN` unset); `/api/store/reserve` is a mock. | Op decision. |
| D1-OPS-7 | D1 / A1 | Concierge off (cost); Grok adapter authored, not activated. | A1 deploy if wanted. |
| D1-BOT-1 | Op | reCAPTCHA wired, dormant (no keys). | Op sets keys. |
| D2-OPS-1 | A1 / Op | Six `d2_metrics_*` RPCs read the dormant seller-side SG source. | Apply the swap. |
| D2-OPS-2 | D0 | Broker-sales views not wired into the dashboard FE. | Add panel. |
| B1-NEXT-11 | Op | Leaked placeholder `CRON_SECRET` still hard-coded in 2 migrations; rotation unverified. | Rotate + history rewrite decision. |
| B1-NEXT-57 | A1 / B1 | `release_health_check` misses anon-readable matviews; prod RHC behind the repo chain. | Apply the RHC migs. |
| B1-NEXT-58 | D0 / D1 | 7 tables with `USING(true)` anon-read policies (incl. `listings_snapshots`). | Owner confirms intent. |
| B1-NEXT-31 | A1 | §6 body guard absent on 7 JWT-gated SECDEF RPCs — blocked on spec. | Spec clarification. |
| B1-NEXT-3 / 5 | B1 | Edge-fn auth inventory; vault-orphans RHC row. | Fold B1-NEXT-3 into A1-DB-9. |
| B1-NEXT-10 | A1 | Migration slot collisions (see B1-CODE-6). | Merged into B1-CODE-6. |
| B1-NEXT-4 / 6 / 24–28 / 35 / 51 / 63 / 64 | B1 | SAST eval, egress review, drift audits, Slack metrics, war-games task, dep bumps, `occurs_at_local` audit, governance trail. | Periodic. |
| B1-NEXT-15 / 16 / 17 / 18 / 19 / 20 / 21 / 40 / 44 / 45 | Op | GitHub/Render settings: enforce_admins, signatures, SHA pinning, Actions secrets, Render IP allowlist + autoDeploy, Slack MCP, forking, review rules, conversation resolution. | Operator decisions. |
| EVAL-1 / 1b / 2 / 3 | Op | External repo evaluations (CloakBrowser: recommend DROP — conflicts with `CLAUDE.md §2`). | Keep/drop. |

### Operator-only (settings / lockdown-gated applies)

> Launch blockers (legal, pooling, Redis, monitoring, Sentry) live in [`docs/production_readiness.md`](docs/production_readiness.md).

| Item | Action |
|---|---|
| Apply the 2026-10-21 Supabase security + maintenance migrations (A1-DB-1/2/3/8) | Explicit yes per migration (`CLAUDE.md §1`). |
| Decide A1-DB-6 (resume listing pollers?) and A1-DB-7 (reclaim ~150 GB) | Operator call. |
| Delete/lock the unsourced debug edge functions (A1-DB-9) | Dashboard or CLI. |
| Enable Auth leaked-password protection (A1-DB-11) | Supabase Auth settings. |
| Apply `20260516230000_security_release_health_cron_heartbeat.sql`, `20260515300000_security_secdef_post_pr101_compliance.sql` | `apply_migration`. |
| Recharge TwitterAPI.io credits | Dashboard. |
| Triage aging `bot_chat` entries | Per-lane sweep. |

### Known data-architecture gaps (workarounds, not bugs — don't rediscover)

| Gap | Status | Workaround |
|---|---|---|
| Listing pollers paused 2026-09-27 (mig `20260927043400`) | Intentional, operator | `/prices` get-in prices are frozen; see A1-DB-6. |
| `tevo_event_id` on SG snapshot tables | ~87% populated; new rows born populated where an xref exists | Query by `sg_event_id` when `tevo_event_id IS NULL`. |
| `seatgeek_event_xref.last_listings_at` / `last_sales_at`, `sg_events_canonical.has_v2_listings_pulled` | Dead columns | Use `MAX(captured_at)` on the snapshot tables. |
| `aq_short_event_id` on `listings_snapshots` | 0% populated (backfill cron disabled 2026-06-01) | Use `event_id` → `aq_event_map`. |
| ESPN snapshot pipeline = gameday scope only | Specced, not built | Forward-look panels empty by design; use `espn_event_date_lookup`. |
| ~29% active TEvo events have no SG bridge | NWSL/USL/AHL/niche coverage gap | First-class TEvo-only UI state. |
| SG doesn't carry most NFL regular season | SG coverage decision | NFL pages render TEvo+ESPN+AQ. |
| SG broker `/v2/listings` OFF since ~2026-05-14 | Superseded by broker `/listings` | Use `/listings` (floor sweep). |
| SG listings = 3 feeds on one shared token | Architecture fact (`PROJECT_BIBLE §3`) | Watch `v_sg_token_budget`. |
| `TRACK_BLINDSPOT` tier ≠ unmapped | Ownership tier | Not a mapping gap. |
| Reddit sentiment / SeatData / TickPick-orders ingest dormant | Intentional | Don't re-flag in freshness audits. |
| TicketsData contract lapsed (2026-09-10) | 0 TD crons active at 2026-10-21 | TD tables are dead weight (A1-DB-7). |
| `release_health_check.subhourly_jobs_silent_90min` false positives | Stale expected-job list | Ignore retired-cron entries. |

---

## ✅ Closed-on-reset (2026-10-21 audit — verified done, obsolete or moot)

- **D1-UX-1/2/3** — mobile overflow / tap targets / safe-area fixes are in `static/store/style.css`.
- **A1-OPS-33** — no TicketsData cron is active (0 active, 0 inactive by command match).
- **A1-OPS-32** — Paciolan crons 532/533 deactivated (0 active Paciolan jobs).
- **v1 SEC-CRIT/HIGH/MED legacy rows citing `app.py`** — `app.py` is gone; share endpoints auth-gated (`routers/shares.py`), `CRON_SECRET` fail-closed + `compare_digest` (`core/auth.py`), `AUTH_DISABLED` refused in prod, rate limiting + CSP shipped.
- **BLOCKED chart range switcher** — the worktree edits it referenced no longer exist.
- **BR-CODE-3** — 100% line + branch coverage gate (verified 2026-10-21: 100.00%).
- **D7-PROD-2** fixed; **D7-OPS-1/2** moot (TD lapsed); **B1-NEXT-61 / A1-OPS-4** obsolete.
- **D4-OPS-1/3/4/5/6/10/12/14/15/16/29/30/31** — applied/deployed per v1; D4 now tracked in `JulianS4K/EXP`.
- **v1 "DOING (design) handoff" and stale "PRs in flight" / "unmerged branch inventory" snapshots** — superseded; this clone has no unmerged branches.

<!-- Append new closures below this line: `- ID — what — PR #n (YYYY-MM-DD)` -->
