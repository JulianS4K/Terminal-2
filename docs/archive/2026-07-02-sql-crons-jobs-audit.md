# SQL / Crons / Jobs Audit — 2026-07-02

> **Status:** historical archive artifact (non-canonical, per `CLAUDE.md` RULE 6 — audits live in `docs/archive/`).
> **Scope:** live pg_cron topology (177 jobs), the 671 `supabase/migrations/`, ~138 active cron job bodies, 30 edge functions, GitHub Actions + Render jobs, and DB security posture (SECDEF/RLS/advisors).
> **Method:** 10 parallel dimension auditors reading the repo + live prod (read-only `SELECT`/catalog only), merged/deduped, then **every CRIT/HIGH/MED finding independently re-derived by an adversarial verifier**. 80 raw → 60 unique → 37 verified → **28 confirmed, 9 refuted/downgraded**. Read against `PROJECT_BIBLE.md`, `RESOURCES_BIBLE.md`, `KANBAN.md`, `MIGRATION_CONVENTIONS.md`.
> **Prod project:** `hzrizjeaxlqcxfrtczpq` (single project — no staging; prod is the test environment).

---

## Executive summary

| Severity | Count | Headline |
|---|---:|---|
| **HIGH** | 5 | anon reads broker sale-lines + $170M league revenue via SECDEF views (RLS bypassed); 10 anon-executable mutating SECDEF fns; the 2026-07-01 ~12h scheduler wedge; `refresh_movers_agg` structurally can't finish; SG listings feed silently halted 5+ days |
| **MEDIUM** | 13 | see table |
| **LOW** | 10 | see table |

**The through-line: out-of-band `cron.alter_job` toggles with no migration trail.** At least four silent capability losses (SG listings halted, `td_match_fill_enqueue` re-enabled against an explicit ban, retention sweeps off, blindspot MV frozen) trace to jobs toggled directly in prod. The control planes now disagree — `cron.job.active`, `cron_policy.enabled`, `PROJECT_BIBLE`, `KANBAN`, and the new freshness monitor each report a different truth, and the documented `cron_policy` kill-switch is **silently broken** (jobs marked `enabled=false` still fire).

**Good news first — what the verifier *refuted*** (don't act on these): the "timeout doctrine is wrong" scare is false (PG17 arms the statement timer once at `SET`; since the `postgres` role default is already `900s`, the `SET statement_timeout` prefixes are harmless no-ops — `PROJECT_BIBLE` §3 is **correct**); the scheduler-watchdog code **is** shipped on `main`/`server.py`; the marquee terminal RPCs (`get_blind_spots_tevo_selling`, returning-entity signals) **do** enforce the `@s4kent.com` email guard; the minute-grid "congestion" does not correlate with failures. Details in [§Refuted](#refuted--corrected-claims).

---

## HIGH findings

### AUD-01 — SECURITY DEFINER `d0_*` views leak broker sale-lines + revenue to `anon` (RLS bypassed) · security
**Object:** `d0_perf_sale_lines`, `d0_league_summary`, the `d0_perf_*`/`d0_league_*` family (~17 SECDEF views).
**Verified live:** `SET ROLE anon` then selecting the views returns **805,785 sale lines (775 `is_owned`) and ~$170M of league revenue aggregates**, while a direct `SELECT` on the base table `d0_sales_fact` returns **0 rows**. The views are owned by `postgres` with `security_invoker` **unset** (PG17 default = definer), and carry `SELECT` grants to `anon`+`authenticated`, so a read runs as `postgres` and bypasses base-table RLS. The publishable key that lets `anon` in is public by design (`static/terminal/auth.js:19`, served at `/api/public/config`). The repo's own migration `20260525170000` documents exactly this class of leak.
**Impact:** Anyone on the internet with the (public) publishable key reads the broker's owned + market sale lines and per-league revenue — the exact broker/owned data `PROJECT_BIBLE` §2.6 says must **never** be public. Confidentiality-only (no PII/credentials → HIGH, not CRIT).
**Fix:** `ALTER VIEW … SET (security_invoker = on)` on each internal `d0_*` view, and `REVOKE SELECT … FROM anon, authenticated` per mig `20260525170000`. Separately confirm the `exos_public_*` views are *intended* public and expose no cost/PII columns (they appear intentional).

### AUD-03 — 10 anon-executable, unguarded, **mutating** SECDEF functions (incl. `d0_refresh_sales_fact`) · security
**Object:** `d0_refresh_sales_fact`, `d0_refresh_sales_fact_active`, `refresh_concierge_events`, `refresh_entity_metrics_daily`, `refresh_event_last_seen_from_market`, `refresh_event_movers_agg`, `refresh_wc_price_daily`, `refresh_world_cup_2026`, `tag_evo_only_events`, `td_sg_discover_drain`.
**Verified live:** all 10 are `SECURITY DEFINER`, `postgres`-owned, with `anon`+`authenticated` `EXECUTE` and **no `current_user` role guard**; their bodies `DELETE`/`INSERT` on core tables (`d0_refresh_sales_fact` does `delete from d0_sales_fact` + a 6-join rebuild over `seatgeek_sales_snapshots`, ~13.2M rows). The two `d0_*` functions have `proconfig = null` (no `SET search_path` → advisor `function_search_path_mutable`) and, critically, **no creating migration exists in the repo** (`grep` empty) — they were created via out-of-band prod DDL, invisible to the review loop. Violates `PROJECT_BIBLE` §2.8 (the REVOKE+guard convention enforced elsewhere, e.g. mig `20260520230000`).
**Impact:** `anon` can trigger repeated expensive `DELETE`+rebuild cycles — a CPU/IO/lock **DoS lever** on the sales fact table. The statement timeout aborts each call (so no persistent corruption, and the priv-esc via mutable `search_path` is latent since `anon` lacks `CREATE`), but the unauthenticated pool-exhaustion surface + the repo-invisible DDL are the HIGH.
**Fix:** `REVOKE EXECUTE … FROM anon, authenticated, PUBLIC` on all 10; add the `current_user NOT IN ('service_role','postgres','supabase_admin')` guard; `ALTER FUNCTION … SET search_path` on the two `d0_*`; **commit them as real migrations**; add a PRIMARY KEY to `d0_sales_fact`.

### AUD-04 — 2026-07-01 pg_cron scheduler wedge: ~12h of zero runs · crons
**Object:** pg_cron scheduler (`cron.use_background_workers = off`), `cron.job_run_details` 2026-07-01.
**Verified live:** hourly run counts were steady (~650–780/hr) through 05:00 UTC, then **06:00 = 231, 07:00–13:00 = ZERO, 14:00 = 70, 15:00–16:00 = 0, 17:00 = 71**, recovering ~18:00 (a 4th brief zero at 20:00). Root cause: an unbounded per-event loop ran **exactly 8:11:58** with the timeout unarmed and, under `use_background_workers = off` (single-threaded execution), wedged the whole scheduler; three jobs were released together at 14:28:59. The same-day fixes are live: bounded loops (`20260701190000`), watchdog RPC (`20260701182336`), and the `postgres` role `statement_timeout = 900s` backstop (`20260701213000`, confirmed in `rolconfig`; no run has exceeded 900s since).
**Impact:** every pg_cron pipeline (ingest, matching, snapshots, alerts) stopped for ~12h; point-in-time snapshot data for that window is **unrecoverable** (confirmed holes: `event_snapshot_morning` 13:30, `refresh_movers_agg` 07:20). Recurrence is now bounded by the 900s backstop, but there is **no throughput deadman** to catch the next one.
**Fix:** keep the 900s backstop; add a cron-throughput deadman (runs/hr floor) wired into `health_monitor_5min`; evaluate `use_background_workers = on` and reduce grid density. (The watchdog code is shipped — see [Open question](#open-question--watchdog-runtime-liveness).)

### AUD-07 — `refresh_movers_agg` window-7 exceeds 900s and aborts all 5 windows (single txn) · crons
**Object:** cron `refresh_movers_agg` (jobid 344) → `refresh_event_movers_agg(int)`.
**Verified live:** the job is 6 statements (a gate + 5 window `SELECT`/`INSERT`s) sent as one simple query = **one implicit transaction** under the 900s cap. Runs on 06-30 07:20, 06-30 19:20, and 07-01 19:20 all failed at exactly 15:00 on the `INSERT INTO event_movers_agg`, so **nothing commits** — a slow 7-day window rolls back the other four. Each call rebuilds a `td_daily` CTE (`PERCENTILE_CONT` per day/platform) over `ticketsdata_listings_snapshots` (~19.3M rows / 20GB) **five times**. `event_movers_index` (the D0 movers UI) was frozen at 06-30 07:35 and **still frozen ~44h later** at audit time. 3 of the last 4 scheduled runs failed; TD volume growth (250k/day) will keep pushing window-7 past 900s.
**Impact:** all five movers windows freeze for a day+ whenever window-7 is slow; the D0 movers panel shows stale data as current.
**Fix:** materialize `td_daily` **once per run** (temp table / incremental rollup) and have all 5 windows read it, instead of re-scanning 20GB five times; **or** split each window into its own cron job so one slow window can't abort the rest.

### AUD-09 — SG listings ingestion halted since 2026-06-26 while every control plane says "ON" · crons
**Object:** `sg_listings_poll_owned_1min` (jobid 355) + `seatgeek_listings_snapshots`.
**Verified live:** jobid 355 is `active = false` (as is its processor, jobid 236) → the feed is **fully halted**; `max(captured_at)` on `seatgeek_listings_snapshots` is **06-26 18:52 (~5.4 days stale**, 18.1M rows / 15GB). Meanwhile: `cron_policy.enabled = true` (no pause note), `PROJECT_BIBLE` §3 says "ACTIVE `*/1`", `KANBAN` A1-OPS-21 says the owned poller is ON. Worst of all, the brand-new `record_source_freshness` (mig `20260701221500`) reports `status = 'off'` + "poller OFF (intentional)" **whenever the job is inactive** — so a 5-day accidental outage is **auto-labeled intentional** and can never trip a `fail`, and the dashboard's overall/timeline counters only count `fail`/`down`/`warn`.
**Impact:** a core market feed is down with an un-backfillable snapshot gap; four control planes disagree so operator-pause vs. failure is indistinguishable; and the freshness monitor **structurally masks** any future accidental poller deactivation.
**Fix:** operator decision — reactivate per mig `20260620120000`, **or** record the re-pause properly (migration + KANBAN + `cron_policy.enabled = false`). Fix `record_source_freshness` to report `'off'` only when a matching `cron_policy` row is *also* disabled, else `'fail'`.

---

## MEDIUM findings

| ID | Finding | Object | Smallest fix |
|---|---|---|---|
| **AUD-11** | `listings_deltas_backfill_overnight` hard-fails **30/30** — single-txn rollback, no in-loop budget, ranking scan times out for want of a partial index; `prev_retail_price` is ~99.9% NULL and it can never converge or self-unschedule. Wastes ~3.75h/night of parallel seq-scan on the 67GB `listings_snapshots`. | jobid 229 → `listings_deltas_backfill_chunked` | Partial indexes `CONCURRENTLY` on the NULL-prev predicates; `EXIT WHEN clock_timestamp()-v_start > 250s` per loop (or convert to a `PROCEDURE` that `COMMIT`s per chunk); delete the dead `SET LOCAL`; or deactivate until fixed. |
| **AUD-12** | Legacy `td_match_fill_enqueue` **re-enabled out-of-band** — fires SH/VD `/match` calls at **0/234 success** ("performer cluster" 500s + 429s) that mig `20260619180000` + `PROJECT_BIBLE` §3:282 explicitly say to keep DISABLED; contends with the correct SG-anchored `sg-match-map-tick`. (`td_match_drain`/`td_match_apply_cron` *are* intentional — scope the ban to `fill_enqueue`.) | jobids 404/405/406 | Re-apply `active=false` on `td_match_fill_enqueue` (or repoint 'fill' to SG-only seed URLs). |
| **AUD-14** | `alert-mail-drain` has **no cron** — terminal watchlist/alert emails have not sent since 06-06 (**17 queued, 0 attempts**). Enqueuer (`dispatch_watchlist_daily_8am`) fires daily; the drainer the fn header documents (`alert-mail-drain-2min`) was never scheduled. Recoverable (rows persist; no age filter). | edge fn `alert-mail-drain` / `alert_mail` | `cron.schedule('alert-mail-drain-2min','*/2 * * * *', …)` mirroring `exos-mail-drain-2min`; confirm `RESEND_API_KEY`/`ALERT_MAIL_FROM`. |
| **AUD-15** | `cron_policy` badly drifted from `cron.job`: **16 orphan policy rows** (no matching job), **3 disabled-but-active** (the `td_enqueue_peak_gt/sh/vd` that fire 67–68×/day despite `enabled=false` → the documented kill-switch is **silently broken**), and **41 active jobs with no `cron_should_fire` gate** (uncentrally-pausable, fail-open). | `cron_policy` vs `cron.job` | One reconciliation migration: delete/rename orphans, align `enabled`, wrap the 41 ungated jobs in `cron_should_fire`, add a weekly full-join drift check to `health_tick`. |
| **AUD-16** | Retention sweeps **off** on the two biggest snapshot tables while `cron_policy.enabled=true`: `seatgeek_listings_snapshots` (15GB) and **`ticketsdata_listings_snapshots` (20GB, actively growing** via TM/SG-burn/AXS). Repeat of the KANBAN A1-OPS-21 45GB incident. | jobids 282/283 (+190/193/325) | Reactivate `sweep-old-td-listings` now (writers active); decide `sweep-old-sg-listings` with the SG-listings resume; reconcile the other three. |
| **AUD-17** | Terminal RPCs `get_owned_events_upcoming` + `get_discovery_gaps` authored 2026-06-20 but **never applied to prod** (`pg_proc` empty; absent from `schema_migrations`). Deployed FE calls them on load (`home.js:673`, `discovery.js:85`) → panels render empty. ~501 owned-upcoming events and ~4,840 gaps hidden. | migs `20260620000000`/`20260620010000` | A1: apply both migrations. |
| **AUD-18** | **CI executes zero SQL.** No `postgres` service in any of 14 workflows; `tests.yml` is pytest (DB-less) + tsc/mypy + Playwright; the only SQL harness (`tests/exos/run.sh`) replays 8 of 671 migrations and no workflow invokes it. A bad column ref / broken plpgsql is caught only at prod-apply — exactly this audit's failure class. | `.github/workflows/tests.yml` | Add a `postgres:16` service job that replays `supabase/migrations/*.sql` against a throwaway DB; at minimum `plpgsql_check`/psql dry-parse on changed migrations. |
| **AUD-19** | `mv_tevo_blindspot_movers` **permanently stale** (~16d): both refresher crons `active=false` while `cron_policy.enabled=true` and `tevo_blindspot_discovery_daily` keeps enqueuing. `discovery.js:257` reads the frozen MV live → stale signals shown as current. | jobids 262/249 → `mv_tevo_blindspot_movers` | Fix the refresh timeout + reactivate 262 (`7-59/30` suffices), or drop the MV/panel and set the two policy rows `enabled=false`. |
| **AUD-22** | `cron_policy.min_interval` **equal** to schedule cadence causes systematic epsilon skips — `last_fire` lands ~100ms after the minute, so the next tick is interval-minus-epsilon and is dropped. **37–38% of ticks silently skipped** (`venue_section_map_refresh` ~16min not 10; `mv_event_price_vol` sometimes 30min not 15 — the input freshness for `compute_alerts` z-scores). | policy rows for `venue_section_map_refresh`, `mv_event_price_vol_refresh`, `event_section_row_rollup_hourly` | Set each `min_interval` to cadence minus 1–2 min (8/13/55). Data-only `cron_policy` UPDATE. |
| **AUD-29** | Mig `20260630250000` TM/MSG seeding is **non-functional (22/22 rows 404, self-deactivated)** and uses the wrong xref key: it builds the URL from the numeric `aq_event_map.tm_event_id` (real TM ids are alphanumeric) and keys `event_id` on `tevo_event_id` instead of `tm_event_id` (the convention `td_pending_sweep` matches on). | `20260630250000_a1_tm_msg_only.sql:31-33` | Build the URL from the alphanumeric TM id and key `event_id` on `tm_event_id`; re-seed MSG events. |
| **AUD-31** | `leads` (name/email/phone PII) readable by **any authenticated user** via `USING(true)` — contradicts the `@s4kent.com`-scoped policies on every other sensitive table. Mitigated *today* (0 rows, 7 staff users), but `d4_bridge`'s open consumer signup targets the same project → a producible exploit principal, bypassing the FastAPI `@s4kent.com` check. | policy `leads_authenticated_read` | Replace `qual` with `auth.email() LIKE '%@s4kent.com'` (match `d0_s4kent_read`), or restrict to `service_role`. |
| **AUD-33** | `check_chat_rate_limit` is a **check-then-insert TOCTOU race** on a PK-less table — under READ COMMITTED a synchronized burst from one IP all read a sub-cap count and all pass, bypassing the 6/min cap on the anon-reachable, paid-LLM (Anthropic/xAI) chat fn. | `check_chat_rate_limit` / `chat_rate_limits` | `pg_advisory_xact_lock(hashtext(p_ip))` at entry (or insert-then-count in one txn); add a PK. |
| **AUD-34** | `sg-seller-webhook` acks 200 **before** a fire-and-forget `dispatch(...).catch()` and stores only a payload *summary* (not the raw payload). SG dedup blocks retry, so a transient DB error **permanently drops** the notification; the "retry-via-replay" comment is unachievable (no raw payload persisted). Zero impact until SellerDirect goes live. | `sg-seller-webhook/index.ts:70-109` | `await dispatch` and insert the seen-row only after success, or persist the full raw payload + a replay drainer; don't 200 until durably recorded. |

---

## LOW findings

| ID | Finding | Fix |
|---|---|---|
| **AUD-08** | `event_snapshot_{morning,midday,evening}`: all 3 slots failed 06-30 (zero rows) + 07-01 morning lost to the wedge → permanent daily-chart holes; single all-or-nothing `INSERT`, `midnight-catchup-sweep` inactive. (Steady-state 20–60s; real cap is 900s, so LOW.) | Raise prefix to 12–15min; self-heal any missing earlier slot for `CURRENT_DATE`. |
| **AUD-21** | `sg_lifetime_sales_daily` re-sorts all 13.2M sales rows nightly (`DISTINCT ON` over the full table); missed 2 refreshes, grows unbounded (now passes at 86s under the raised 900s cap). | Make incremental: restrict to events with `pulled_at >` last success (idx exists), or maintain per-event aggregates on ingest. |
| **AUD-23** | Name-vs-schedule cadence drift on 12+ active jobs (`dashboard_writes_24h_refresh_60s` runs hourly, `sg_seller_process_30min` runs `*/4`, etc.) — stale labels over a correct by-design policy gate; misleading during triage. | `cron.alter_job` rename to real cadence, or drop cadence suffixes for the policy-note convention. |
| **AUD-24** | `cron_should_fire` work-check: the `set_config('statement_timeout','8000',true)` **8s bound is a no-op** mid-statement (a slow probe ate 77s on 07-01). (The paired restore-to-120000 claim was refuted — pg_cron arms once at 900s.) | Drop the ineffective 8s `set_config`; keep probes indexed. |
| **AUD-25** | 4 per-event loop fns lack the in-loop wall-clock budget the July-01 hardening added (`rollup_event_section_row_batch`, `match_unmatched_orders_sweep`, `sg_canonical_link_from_tevo_chunked`, `espn_scoreboard_process`) — single-txn, rollback-all on timeout. Defense-in-depth gap; 900s cap + watchdog still catch it. | Add `EXIT WHEN clock_timestamp()-v_start > 200-250s` per loop + a `LIMIT` on `espn_scoreboard_process`'s outer loop. |
| **AUD-27** | `sg_blindspot_mv_refresh` does a **non-`CONCURRENTLY`** `REFRESH MATERIALIZED VIEW` every 10 min (7-day: avg 10.4s, max 118s, 73 runs ≥60s) → `AccessExclusive` intermittently trips the panel's 8s PostgREST cap. Sole reader is the `@s4kent`-gated RPC (self-recovering). | Add a unique index + revert to `REFRESH … CONCURRENTLY`. |
| **AUD-30** | `td_credits_this_cycle` (SECDEF) still `anon`-executable: `REVOKE … FROM anon` **doesn't remove the `PUBLIC` default grant** (`proacl` keeps `=X`). Same buggy pattern copied into `is_peak` (harmless there — `SECURITY INVOKER`). Low-sensitivity data. | `REVOKE EXECUTE … FROM PUBLIC` (not `anon`). |
| **AUD-32** | `espn` edge fn: anon-reachable, no `requireCronSecret`, does service-role `event_xref` writes + an unbounded `/raw` ESPN proxy, no rate limit → violates Hard Rule 7. `docs/war_games_playbook.md:136` wrongly records it as remediated. Low data risk (ESPN free, CORS already fixed). | Move `event_xref` writes to a gated/cron path + make the browser endpoint read-only, or document as an accepted exception + correct war_games. |
| **AUD-36** | `RESOURCES_BIBLE` §5 / `PROJECT_BIBLE` §0 list inactive/superseded jobs as live (`auto_match_sg_canonical_v3_hourly`, `td_enqueue_peak_tp`, SG pollers, `collect-listings-*`); §0:60 calls `auto_match_sg_canonical_v3` "hourly" though it runs 2×/hr inside `cross_source_match_tick_30min`. | Annotate/remove inactive rows; adopt "cron toggles only via migration" as a §1-level rule. |
| **AUD-37** (KNOWN) | `RESOURCES_BIBLE` gives **three different cron counts** (§0 "164/151", §5 "177/156"; live **177/138**) and undercounts edge fns (29 vs disk 30 — omits `axs-to-tevo-search-bridge`). Tracked stale under B1-NEXT-25. | Set §0+§5 to 177/138; add the missing fn, bump 29→30. |

---

## Cross-cutting theme: out-of-band cron toggles

AUD-09, AUD-12, AUD-15, AUD-16, AUD-19, AUD-36 are all instances of the same root cause: **jobs toggled with `cron.alter_job` directly in prod, leaving no migration or KANBAN trail.** The consequences compound — the `cron_policy` kill-switch is broken (AUD-15), the freshness monitor masks outages (AUD-09), and the docs actively mislead auditors into treating disabled jobs as healthy (AUD-36). **Recommended §1-level rule: cron activation state changes only via migration**, mirroring the existing "prod-DB apply centralized on A1" gate. This single policy would have prevented four of this audit's findings.

## Open question — watchdog runtime liveness

The scheduler-watchdog **code is shipped** (`server.py` on `origin/main`; the kill RPC exists live via mig `20260701182336`), which resolves the `PROJECT_BIBLE` v2.11.0 "NOT confirmed running" note at the *code* level. What remains **unproven** is runtime liveness: the RPC writes no `health_check_history`/heartbeat row, so there is no DB-observable evidence it actually ticks each minute in the deployed service. Verifiers split on this. **Recommendation:** have the watchdog write a heartbeat row each run so liveness is provable — this also gives AUD-04's deadman a signal to alert on.

## Refuted / corrected claims

The adversarial pass killed or downgraded 9 findings. Recording them so they aren't re-raised:

| Claim | Verdict |
|---|---|
| "Timeout doctrine is wrong — `SET`-prefix caps are illusory/5-8min not 900s" (was HIGH) | **Refuted.** PG17 arms the statement timer **once** at the `SET`; the `postgres` role default is already `900s`, so the prefixes are harmless no-ops. `refresh_movers_agg` dies at exactly 900s cumulative, proving the armed-once model. `PROJECT_BIBLE` §3:261 is correct. Residual: stale superseded-mig comments (INFO). |
| "Scheduler watchdog is inert/unshipped" (was HIGH) | **Refuted.** Code is on `main`/`server.py`, deploys via `render.yaml`; RPC uses `SERVICE_ROLE_KEY` so its `service_role` assert passes. Residual = the liveness heartbeat gap above (LOW). |
| "Terminal analytics RPCs missing the `@s4kent.com` guard → anon broker intel" (was HIGH) | **Refuted.** `get_blind_spots_tevo_selling`, `get_returning_entities/_events` each `RAISE 42501` when the JWT email is null. Only `get_event_amalgam`/`td_target_events`/`td_credits_this_cycle`/`get_alert_metric_catalog` are truly unguarded — all low-sensitivity (amalgam mirrors public marketplace prices). |
| "SG **sales** ingest zero for 31h" (was HIGH) | **Refuted as new.** Real gap is ~5.25d (poller `sg_sales_poll_5min` inactive, not budget/wedge), but mig `20260701221500` already monitors it (live, 'ok') and blesses the operator pause. |
| "SH/VD/GT TD collection dead 23 days, enrollment wasted" (was HIGH) | **Refuted.** `td_tier_enqueue`+`td_normalize_drain` still enqueue tier-tagged rows; SH 924 / VD 514 resolved in 24h, `still_pending=0`. Only the `td_enqueue_peak_{sh,vd,gt}` legs are zombie no-ops (INFO). |
| "Zombie process/enqueue halves cause impact" (was MED) | **Refuted to INFO.** The process fns are pure internal drains (0 upstream calls, ~80s/day, backlog 0); re-pauses are documented/intentional. |
| "`compute_event_breakdowns` no-op `SET LOCAL` caps break degradation" (was MED) | **Refuted to INFO.** Each step has `WHEN query_canceled` (degrades, doesn't abort); the fn is orphaned — 0 crons, 0 callers (metrics moved to TS). Dead code. |
| "Minute-grid congestion causes the startup timeouts" (was MED) | **Refuted.** Failure rate is *inversely* correlated with density; the 25 startup-timeouts were the one 07-01 wedge burst at a *trough* minute. Non-actionable (mig `20260630300000`: "`max_connections=160` is NOT the constraint"). |
| "`cross_source_match_tick_30min` throttled to 2–3 fires/day" (was MED) | **Refuted to INFO.** By-design off-peak+budget gate (05-14 conservation directive); firing more won't help — `matched_24h=0`, backlog is tevo-search-bound (job 228), not tick-throttled. |

## Verified healthy (coverage)

188 explicit healthy-checks were recorded across the 10 auditors. Highlights of what was checked and found sound: the `postgres` role `900s` backstop is live and effective (no run >900s since 07-01); `net.http_request_queue` is empty and no stuck `running` rows; the RULE-2 upstream read-only guards hold (no `POST`/`PUT`/`DELETE` to broker hosts in `*_client.py` or edge fns beyond the blessed SeatData `/event-request-add`); `_shared/cron-auth.ts` gating is present on the mutating/paid edge fns spot-checked; `exos_public_*` views are intentionally public with safe columns; the `td_sg_burn` window (`td_enqueue_peak_sg` + `td_sg_burn_teardown`) teardown logic at 2026-07-09 is idempotent; the terminal's marquee RPCs enforce the email guard; retention of `cron.job_run_details` (7-day cleanup) is working.

---

## Recommended remediation order

1. **AUD-01 + AUD-03 (security, act first)** — one migration: `security_invoker=on` on the `d0_*` views + `REVOKE … FROM PUBLIC` and add role guards to the 10 mutating fns, and commit the two orphaned `d0_refresh_sales_fact*` as real migrations with `search_path` + a PK on `d0_sales_fact`. Closes the live anon exfiltration + the DoS lever together.
2. **AUD-09 + AUD-16 (feeds/disk)** — operator decision on the SG listings poller; reactivate the TD retention sweep now; fix `record_source_freshness` so "off" requires a disabled policy row.
3. **AUD-07 + AUD-11 + AUD-19 (broken pipelines)** — materialize `td_daily` once (or split the movers windows); partial-index + budget the deltas backfill; fix/retire the blindspot MV.
4. **AUD-15 + the out-of-band-toggle rule** — reconcile `cron_policy` ↔ `cron.job`, wrap the 41 ungated jobs, and adopt "cron toggles only via migration."
5. **AUD-17 (apply the two missing terminal RPCs)** and **AUD-14 (schedule `alert-mail-drain`)** — quick capability restorations.
6. **AUD-18 (CI SQL gate)** — the structural fix that would have caught most of the above pre-merge.
7. Remaining MED/LOW as capacity allows; the security LOWs (AUD-30, AUD-31, AUD-32, AUD-33) fold naturally into the step-1 security migration.
