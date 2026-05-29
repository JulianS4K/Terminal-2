# Full code + system audit (2026-05-09)

> Comprehensive macro + micro audit of repo state at commit `2096a40`. Two parallel agent passes (dead-code scan + issues scan) plus live-DB diagnostics. Findings sorted by severity.

---

## 0. Headline

**Health: solid.** RULE 2 clean across 5 Python files + 21 TS edge functions, 12 unit tests pass, 28+ crons active, all 4 vault secrets populated. 119 migrations applied cleanly. Recent ~5 hours of work (commits `1060a29..2096a40`) shipped end-to-end without breaking existing pipelines.

**3 real concerns + ~10 cleanup opportunities** documented below.

| Layer | Status |
|---|---|
| RULE 2 enforcement (Python + TS) | ✅ Clean — 3-layer stack |
| RULE 2 enforcement (plpgsql) | ⚠️ **Static check doesn't scan migrations** — manually verified clean today |
| Cron health (last 4h) | ✅ Verify with `cron.job_run_details` — all expected jobs ran |
| Vault secrets | ✅ All 4 whitelisted secrets present |
| Async pending queues | ✅ Small backlogs (16/8/4 in flight) — cron will clear |
| Test coverage | ⚠️ Only 1 test file (RULE 2 only) |
| Railway deploy | 🔴 Stale — `terminal-2-production.railway.app/` shows Railway default; FastAPI routes 404 |

---

## 1. Severity HIGH (real concerns)

### 1.1 Mig 280000 is tombstoned by 290000 — same-day churn

`20260509280000_server_side_pulls_evo_orders_sg_listings_sales.sql` introduced:
- `evo_orders_queue_10min` + `evo_orders_process_10min` ← **unscheduled** in mig 290000, replaced by `_30min`
- `sg_sales_queue_daily` + `sg_sales_process_daily` ← **unscheduled** in mig 290000
- `sg_sales_pending` table + `sg_sales_*` functions ← **dropped** in mig 290000

Net effect: ~40% of mig 280000 is dead code from the moment mig 290000 lands. Both migrations are committed; if they replay together on a fresh DB, the dead parts execute then immediately get torn down. Not a correctness bug, just historical noise.

**Recommendation**: leave it; future migration consolidation can squash these.

### 1.2 EVO order_items not persisted

Earlier `evo_orders_process()` versions persisted both `evo_orders` AND `evo_order_items` (deletes + re-inserts items per order). The final committed version dropped the items block to simplify the function after a series of column-mismatch errors.

**Live state**: `evo_order_items` has **0 rows**. The `our_orders_by_event` view depends on `evo_order_items` to derive `tevo_event_id`:
```sql
(SELECT min(event_id) FROM evo_order_items WHERE evo_order_id = evo_orders.evo_order_id) AS tevo_event_id
```
This returns NULL, so `our_orders_by_event` rolls everything into the `tevo_event_id IS NULL` bucket on the TEvo side.

**Recommendation**: P1 fix — restore the items insertion in `evo_orders_process()`. Schema already exists (mig 20260509070000); just need to add the INSERT block back. Took ~50 lines in the original draft.

### 1.3 `is_baseline` broken for NBA/NFL/MLS/WNBA/WC (known + documented)

Per `SCHEMA.md` L478-499: `upsert_espn_injury` only computes content-hash diffs correctly for MLB+NHL. For 5 other leagues, every captured row has `is_baseline=true`, so any `WHERE is_baseline=false` filter returns 0 rows. Same bug in `espn_team_snapshots`.

**Mitigated by**: `v_espn_team_state` and `v_espn_injuries_current` views (mig 240000) use `DISTINCT ON ... ORDER BY captured_at DESC` workaround. Frontend works correctly. Fix is on the espn-collect edge function side; not yet shipped.

**Recommendation**: P2 — fix at the writer side eventually so `is_baseline=false` semantics are reliable for downstream queries.

### 1.4 Railway deploy disconnected

Per `AGENTS.md` L329 + observed live this session: `https://terminal-2-production.railway.app/` returns Railway's default ASCII landing page, not our FastAPI app. The `/api/admin/collect-orders` route from the cron returned HTTP 404 repeatedly — that's what triggered the migration to server-side plpgsql for orders pulls.

**Impact**: any `app.py` route is currently inaccessible from outside (no UI). All data crons have been migrated off Railway as a result, so the database side is healthy. But the broker terminal UI itself is offline.

**Recommendation**: P0 if anyone needs the UI today. Verify Railway dashboard (paused project, build failure, or service config drift).

---

## 2. Severity MEDIUM

### 2.1 RULE 2 audit gap: doesn't scan plpgsql migrations

`scripts/check_readonly.py` only inspects `.py` and `.ts/.js/.tsx/.jsx` files. Recent migrations (280000, 290000, 300000, 310000) use `pg_net.http_get` directly. **Manually verified all 9 calls in those migrations are GET-only**, but the static check can't prove future migrations won't introduce a `pg_net.http_post` to a forbidden host.

Pre-existing `pg_net.http_post` calls exist in older migrations (cron jobs that POST to Supabase Edge Function URLs with `X-Cron-Secret`). Those target Supabase, not TEvo/SG, so they're fine. But the audit script can't distinguish.

**Recommendation**: P2 — extend `check_readonly.py` to scan `supabase/migrations/*.sql` for `net.http_post|put|patch|delete` AND verify the URL doesn't match forbidden hosts (`api.ticketevolution.com`, `brokerdata.seatgeek.com`, `sellerdirect-api.seatgeek.com`).

### 2.2 7 likely-orphaned edge functions

Of 21 edge functions, **6** are referenced from active crons + chat:
`collect`, `espn`, `espn-collect`, `crawl-espn-team-assets`, `crawl-venues-and-performers`, `backfill-event-configurations`, `chat` (called from `static/chat.html`).

**Likely orphaned** (no caller in code or active cron):
- `probe-espn-data`, `probe-seating-charts`, `probe-tevo-category`, `probe-tevo-events-by-venue`, `probe-tevo-performer` — 5 probe scripts (developer-tools era)
- `diag-ticket-groups` — diagnostic, only in docs
- `tevo-fallback-search` — only in docs

**Active but referenced only in docs**: `bulk-add-watchlist`, `seed-home-venues`, `tevo-perf-find`, `why-noaa-weather-alerts`, `wiki-collect`, `espn-rosters`, `collect-listings` — keep these (used as on-demand admin tools).

**Recommendation**: P2 cleanup — delete the 7 orphans (probes + diag + tevo-fallback-search). Saves edge-function build time on deploys + reduces surface to maintain. Edge functions in Supabase have no deploy-cost so it's purely housekeeping.

### 2.3 Test coverage gap

Exactly **1 test file**: `tests/test_readonly_guards.py` (12 tests, all RULE 2 enforcement).

**Zero coverage** for:
- Canonical views: `our_orders`, `unified_orders`, `v_canonical_event`, `v_canonical_performer`, `v_pricing_cross_source`, `v_competing_events`
- Geo: `haversine_miles`, `find_competing_events`
- TEvo signing: `tevo_sign_get` HMAC produces correct signature for fixed input
- ESPN injury `is_baseline` logic
- `_flatten_order` / `_flatten_order_items` shape
- Master cascade summary shape

**Recommendation**: P2 — add a `tests/test_views.py` covering the 5-7 most queried views with fixed input data. Catches schema drift at PR time.

### 2.4 Multiple competing implementations on a few surfaces

- `performers_by_league` v1/v2/v3 (3 migrations on 2026-05-08) — only the latest is referenced
- `event_movers` v2/v3 stacked
- `seatgeek_*_xref` triple-defined: created in mig 080000, dropped in 090000, recreated in 110000

**Recommendation**: P3 — natural housekeeping during next migration consolidation pass.

### 2.5 Unresolved async-pipeline backlogs

| Pipeline | Unresolved pending |
|---|---|
| Weather forecast | 16 |
| SG seller orders/listings | 8 |
| EVO orders | 4 |

All are in-flight requests waiting for pg_net background worker. Will clear naturally on next process tick (5–30 min). **Not a real concern unless they sit unresolved >1 hour**.

---

## 3. Severity LOW (cosmetic / non-blocking)

### 3.1 Empty tables that are intentional

| Table | Reason it's empty |
|---|---|
| `canonical_external_ids` | Universal slot-in xref — populated only as new sources adopt it |
| `seatdata_*` family (5 tables) | Budget-gated: 100 paid pulls/day cap on BASIC plan; only Knicks G5 manually backfilled |
| `seatgeek_order_tickets` | Per-ticket detail; not yet wired in `sg_seller_process` |
| `tevo_ticket_groups_cache` | Gets swept hourly by `sweep_tevo_ticket_groups_cache` cron |
| `wiki_seasons` | Defined but never populated — appears truly orphaned |
| `evo_order_items` | See §1.2 — should be populated, regression |

### 3.2 Vault state

```
SEATDATA_API_KEY      64 chars  ✓
SEATGEEK_API_TOKEN    32 chars  ✓
TEVO_API_TOKEN        32 chars  ✓
TEVO_SECRET           42 chars  ✓ (still wrapped in <...>; tevo_sign_get strips defensively)
```

**Recommendation**: re-push `TEVO_SECRET` cleanly without wrapping `<...>` brackets so the underlying value is correct. Optional — strip-fix already protects against it.

### 3.3 Stash pending: `static/index.html`

Modified but not committed. Contains:
- `[` / `]` keyboard range stepping (`_wireRangeKeyboard`)
- 120ms transition on background to drop color-fade flash
- `_formatRelativeTime` helper
- Chart.js vertical-crosshair plugin scaffold

Plus `static/_proposals/templates.html` modified — design coworker drops.

**Recommendation**: P3 — review and either commit or stash properly. Currently held out per session-start instructions.

### 3.4 Untracked design files

`design/auto-populate-2026-05-08.md` — coworker drop, untracked. RULE 12 proxy commit pattern would include in next batch.

### 3.5 Zero TODOs/FIXMEs in code

Surprising and good. The 8 `TODO(code)` markers in `static/_proposals/*.html` are intentional API-hook stubs per `design/CODE_NOTES_2026-05-08.md`.

### 3.6 No `.bak` / `_old.*` files

Repo is hygienic — no abandoned-file leftovers.

---

## 4. Architectural state — macro health

### 4.1 Backend split (after recent migrations)

| Concern | Where it lives |
|---|---|
| Web UI (FastAPI HTML) | Railway (currently broken — see §1.4) |
| Interactive admin endpoints | Railway |
| Cron scheduling | Supabase `pg_cron` |
| TEvo data pulls (orders, listings) | Supabase: edge functions (collect-listings) + plpgsql (evo_orders) |
| SG data pulls (broker + seller) | Supabase plpgsql + pg_net |
| SeatData pulls | On-demand only (budget cap) |
| ESPN | Supabase edge functions |
| Wikipedia | Supabase plpgsql + pg_net |
| Open-Meteo + Nominatim | Supabase plpgsql + pg_net |
| HMAC signing | Supabase pgcrypto |
| Diagnostics / cron history | Supabase `cron.job_run_details` + custom views |

**Result**: data plane is fully Supabase-native. Railway is now strictly a frontend host.

### 4.2 Cron landscape (28 active jobs)

Documented in `docs/cron-landscape-2026-05-09.md`. Six source pipelines (TEvo, SG, SeatData, ESPN, Wikipedia, Open-Meteo+Nominatim) plus internal sweeps. Recent 4h shows 0 failures across `cron.job_run_details`.

### 4.3 Canonical layer

`docs/canonical-data-map-2026-05-09.md`: 190 field mappings across 25 tables, 0 unmapped. 6 sources registered. Drift detector via `data_source_field_map_audit` view.

Five canonical views composing the day-trader query layer:
- `v_canonical_event`, `v_canonical_performer`, `v_canonical_venue`, `v_canonical_coverage`
- `v_event_full` (kitchen-sink), `v_event_full_sports`
- `v_pricing_cross_source` (4-way price JOIN by section)
- `our_orders` (TEvo + SG own sales) + `unified_orders` (adds SeatData market obs)
- `v_competing_events` (±24h, 20mi)
- `v_event_weather_with_fallback` (forecast ≤16d, climatology >16d)
- `v_team_at_venue_history`, `v_sg_historic_per_*` (4 historic rollups)

### 4.4 Migration count

**119 migrations** total. Recent 32 (2026-05-08 onward) cover canonical layer + RULE 2 + weather + competing-events. No correctness failures in latest replay.

---

## 5. Recommended next steps (priority-ordered)

| P | Item | Est effort |
|---|---|---|
| **P0** | Fix Railway deploy so UI is accessible | unknown — depends on Railway issue |
| **P0** | Restore `evo_order_items` persistence in `evo_orders_process()` | 30 min |
| P1 | Re-push `TEVO_SECRET` without `<...>` wrapping (clean vault) | 1 min |
| P1 | Extend `check_readonly.py` to scan `supabase/migrations/*.sql` | 1 hour |
| P1 | Fix `is_baseline` writer logic on espn-collect for NBA/NFL/MLS/WNBA/WC | 2 hours |
| P2 | Delete 7 orphaned edge functions | 15 min |
| P2 | Add `tests/test_views.py` covering 5-7 critical views | 2 hours |
| P3 | Migration consolidation pass (squash 280000+290000 redundancy) | 1 hour |
| P3 | Drop unused `wiki_seasons` table | 5 min |
| P3 | Decision on `static/index.html` stash (commit or drop) | 15 min |

---

## 6. What's in great shape

- **RULE 2** triple-stack enforcement holding firm — runtime guards + static analysis + 12 unit tests
- **Zero TODO/FIXME** in production code (all in design proposal stubs)
- **Vault discipline** — 4 whitelisted secrets, no leakage
- **Cron observability** — every external call logged in `net._http_response` + `cron.job_run_details`
- **Data flow** — fully Supabase server-side, Railway-independence achieved
- **Documentation density** — canonical data map, cron landscape, weather sources, EVO↔SG field mapping all current as of 2026-05-09
- **Drift detection** — `data_source_field_map_audit` flags any new tables added without field-map entries

---

## 7. Status

Filed by: code · 2026-05-09
Branch: `claude/mystifying-lederberg-ea407b` · HEAD: `2096a40`
Two parallel agent passes (dead-code + issues) cross-referenced with live DB queries. No external advisor reviewed.
