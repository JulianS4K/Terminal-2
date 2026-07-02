# Doc-version history archive — rolled up 2026-07-02

Historical, non-canonical. The canonical docs each carry a **single** current
`**Doc version:**` line under their title (per `README.md` *Doc-writing rules*);
the accreted multi-version run-on headers — which every session paid tokens to
skip — were rolled here on 2026-07-02 so the live headers stay one line. Newest
entries are at the end of each block. Full commit-level history is in git +
`CHANGELOG.md`.

---

## PROJECT_BIBLE.md — history prior to v2.12.0

> v2.11.0 (2026-07-01; §3 landmine CORRECTED: a `SET statement_timeout` prefix in a pg_cron command is a NO-OP (not just `SET LOCAL`); the only working cron cap is a role default — `ALTER ROLE postgres SET statement_timeout='900s'` (mig 20260701213000); durable FastAPI watchdog NOT confirmed running) · v2.10.0 (2026-07-01; §3 landmine: cron loops need a loop-level wall-clock budget — `SET LOCAL statement_timeout` inside a running function is a no-op; unbounded per-event loops wedge the whole scheduler under `use_background_workers=off`; scheduler-watchdog RPC + FastAPI loop are the backstop) · v2.9.0 (2026-06-28; §2 B1 line: `tests/frontend/` Playwright net + `frontend-smoke` CI job; the 5-surface VibePass hub is the Render landing at `/`, STOREFRONT_AS_LANDING=false) · v2.8.0 (2026-06-28; §2.5: BR-CODE-1 route decomposition COMPLETE (+routers `store`/`pages`/`store_test`/`admin`/`storefront_pages` — server.py now holds only `/healthz`+`/webhooks/render`) + core/ helper pass (+`discovery`·`trip_payloads`·`ingest`·`storefront_html`·`canonical_refresh`; `search` gained live/player/cache helpers); frontend Playwright smoke+behavioral net under `tests/frontend/`) · v2.7.0 (2026-06-26; §2.5 + §2.6: BR-CODE-2 shared client layer `core/readonly_guard`·`core/http_retry`·`core/vault`; RULE-2 guard body now single-sourced) · v2.6.0 (2026-06-26; §2.5 code map adds the production-readiness infra modules `core/db`·`core/resilience`·`core/ratelimit`) · v2.5.0 (2026-06-26; §2 decomposition row names the live routers/* + core/* modules, links the per-module route map to RESOURCES_BIBLE §9) · v2.4.0 (2026-06-26; app.py renamed → server.py post-decomp, all file/lane refs updated; entrypoint `uvicorn server:app`) · v2.3.0 (2026-06-19; history in git/CHANGELOG) — §4/§0: `sg_attempt_event_xref_v3` exact-date guard documented (same-date-first + off-date-series reject, PR #613 / mig 20260619200000) — was read as a naive "±24h, nearest wins" matcher

---

## CLAUDE.md — history prior to v2.3.0

> v2.2.0 (2026-06-26; RULE-2 guard body single-sourced in core/readonly_guard.py — per-file tokens still required, BR-CODE-2); v2.1.0 (2026-06-26; app.py→server.py rename refs §4/§4b; v2.0.0 2026-06-19; history in git/CHANGELOG)

---

## README.md — history prior to v2.6.0 (current line retains the v2.6.0 summary)

> v2.6.0 (2026-06-28; repo-layout: route decomposition 100% (+routers store/pages/store_test/admin/storefront_pages), core/ helper pass (+discovery/trip_payloads/ingest/storefront_html/canonical_refresh), tests/frontend Playwright net, and the 5-surface hub as the Render landing); v2.5.0 (2026-06-26; repo-layout core/ list += db/resilience/ratelimit/readonly_guard/http_retry/vault — the prod-readiness + BR-CODE-2 shared layers); v2.4.0 (2026-06-26; +routers/ & core/ module map in repo-layout; v2.3.0: renamed app.py→server.py post-decomp; v2.2.0 2026-06-25: coverage gate + Sentry/LOG_LEVEL observability env in local-run; history in git/CHANGELOG)

---

## RESOURCES_BIBLE.md — history prior to the 2026-07-02 header collapse (current line retains the v2.10.0 summary)

> v2.10.0 (2026-07-01; §5: per-source freshness SLA monitor — `record_source_freshness()` on the 5-min health cadence, `source_freshness` checks on the D0 health page, mig `20260701221500`); v2.9.0 (2026-07-01; §5: EVO tick band-priority ordering (mig `20260701191500`, fixes ≤3d near-term starvation) + D0 metrics pipeline note + `zone-backfill-isolated-10min` re-enabled bounded (mig `20260701192000`)); v2.8.0 (2026-07-01; §5: scheduler-wedge protection — self-bounding cron loops (loop wall-clock budgets, mig `20260701190000`) + durable FastAPI watchdog polling `scheduler_watchdog_kill_stale_backends` (mig `20260701182336`) + `/api/admin/scheduler-watchdog/status`; orphan/midnight-catchup stay disabled pending index build); v2.7.2 (2026-06-30; §5: D0 health page now lists ALL crons via `get_health_dashboard().crons[]`, mig `20260630270000`); v2.7.1 (2026-06-30; §5.1 AXS line: probe now 4 pulls/day peak-only (`axs_probe_step(p_refresh_hours=>6)`, off-peak fire removed, mig `20260630260000`) + TD-AXS maintenance-outage note); v2.7.0 (2026-06-30; §2.12/§4/§5: TD sourcing redesign — new §5.1 credit-budgeted cron model (250k-real/cycle phased caps, peak/off-peak `is_peak()`, breadth ladder `td_should_poll`, `td_tier_enqueue_*` RETIRED, TM→MSG, AXS-in-ledger, SG burn); cron count → 177/156); v2.6.0 (2026-06-28; §1: Render landing = the 5-surface VibePass hub at `/` (STOREFRONT_AS_LANDING=false) + the `tests/frontend/` Playwright net); v2.5.0 (2026-06-26; §1: BR-CODE-2 shared `*_client.py` layer note — `core/readonly_guard`·`core/http_retry`·`core/vault`); v2.4.0 (2026-06-26; §7: production-readiness resilience env — `SUPABASE_TIMEOUT_SECONDS`/`DB_CIRCUIT_*`/`REDIS_URL`/`SESSION_SIGNING_SECRET` + their `core/db`·`core/resilience`·`core/ratelimit` modules); v2.3.1 (2026-06-26; §9: keystone `resolve_event_with_filters` now in core/store_events.py); v2.3.0 (§9 code-map ties route groups → router modules; v2.2.0: app.py renamed server.py; v2.1.0 2026-06-25: added Sentry opt-in error tracking + observability env to §1/§7; history in git/CHANGELOG)

---

## MIGRATION_CONVENTIONS.md — history prior to the 2026-07-02 header collapse (current line retains the v2.2.0 summary)

> v2.2.0 (2026-06-30; §14: +9 landmark rows for the TD sourcing redesign `20260630160000`–`250000`); v2.1.0 (2026-06-26; +§11.3 rollback runbook for prod-readiness P1 #7; v2.0.0 2026-06-19; history in git/CHANGELOG)

---

## KANBAN.md — history prior to the 2026-07-02 header collapse

The KANBAN board is append-only; its per-update version log had grown to a
multi-hundred-word run-on header (v1.15.0 baseline … v1.67.0). Preserved
verbatim below; the live board now carries a single current line.

> v1.15.0 · baseline 2026-05-28 (A1); v1.1.0 2026-05-31 (A1) — added collector-cadence overhaul follow-ups A1-OPS-16..20 (retention Wave 2/3/4, Part D post-event report, evo_discover Phase-2); v1.2.0 2026-06-02 (D0) — Seat Map follow-ups D0-PROD-5..7 (realtime CSP, D1 port, CDN coverage probe); v1.3.0 2026-06-03 (D0) — D0-OPS-1: apply mig 20260603120000 (all-source listing metrics RPC); v1.4.0 2026-06-03 (D0) — D0-PROD-7 solved by seatmap_manifest cache (mig 20260603160000 + edge fn, applied); v1.5.0 2026-06-03 (A1) — added A1-OPS-21 (SG non-owned poller OFF pending re-enable + listings retention halve drain); removed obsolete A1-OPS-7 (floor-sweep ramp — floor sweep retired 05-31); v1.6.0 2026-06-03 (A1) — data-health audit: +2 known-gaps rows (dormant Reddit/SeatData/TickPick; release_health_check false-positives); v1.7.0 2026-06-08 — added A1-OPS-24 (POTENTIAL: last30days social-pulse → why_signals → alerts + scheduled-task bot; exploring, operator-gated); v1.8.0 2026-06-08 (D0) — added D0-PROD-8 (per-performer Trip Planner shipped via #463/#475/#477/#478/#483; refinement backlog); v1.9.0 2026-06-08 — cleanup: removed 6 fully-resolved OPEN-WORK rows per the closure protocol (A1-OPS-5/9/11/13/23, B1-NEXT-59); v1.10.0 2026-06-10 (A1) — added A1-OPS-25 (AXS primary box-office); v1.11.0 2026-06-17 (C1) — added C1-OPS-1 (workflow-skills rollout backlog); v1.12.0 2026-06-17 (operator) — added C1-OPS-2 (4-domain reorg follow-ups); v1.13.0 2026-06-17 (operator) — added the 🌿 BRANCHES / PRs IN FLIGHT git tracker; v1.14.0 2026-06-19 (A1) — added A1-OPS-26 (port the sg-to-tevo-search-bridge name-overlap accept-guard); v1.15.0 2026-06-19 (A1) — closed A1-OPS-26; v1.16.0 2026-06-22 (A1) — corrected A1-OPS-21(b) (sweep_old_listings retention drain fix, PR #568); v1.17.0 2026-06-25 (B1) — closed BR-CODE-3 (100% coverage + ratchet gate, PR #685); v1.18.0 2026-06-25 (B1) — bug-hunt sweep (6 correctness bugs + BUGHUNT-1/2 filed); v1.19.0–v1.62.0 2026-06-25..28 (D0/B1) — BR-CODE-1 route decomposition slices 13–43 (server.py 6,705 → ~2,152 LOC, route decomposition COMPLETE) + BR-CODE-2 client dedup slices 1–3 + production-readiness resilience passes (core/db·resilience·ratelimit, every storefront read site breaker-protected); v1.63.0 2026-06-28 (B1) — BR-CODE-4 JS-dedup investigated → deferred as low-value; v1.64.0 2026-06-28 (B1) — BR-CODE-4 slice 3 behavioral frontend net; v1.65.0 2026-06-28 (B1) — BR-CODE-1 core/ helper pass (server.py 2,152 → 1,599 LOC); v1.66.0 2026-06-28 (B1) — P0 ClientOptions import fix caught by pre-merge smoke; v1.67.0 2026-06-28 (B1) — hub (`/` landing) verify + rewire, 22 frontend tests green. (Full per-slice detail is preserved in the merged PRs #465–#685+ and in git.)
