# Audit handoff — 2026-05-11

Single-page index of every finding from C1's 2026-05-11 audit batch. **Start here.** Reference docs linked below; this doc is the bird's-eye view + work checklist.

**Branch:** `claude/audit-data-sources-b7EGu` (PR #58, draft)
**Produced by:** C1 (Data + Chat Bot, supervisor)
**Handoff target:** A1 (Primary/Audit/Push) for git + DDL work; B1 (Security Manager) receives drift signals downstream

---

## Reference docs (in reading order)

1. **`data-sources-audit-2026-05-11.md`** — 11 sources, 120 tables, 11 categories, **WITH CORRECTIONS** (initial orphan flags retracted)
2. **`cross-source-entity-resolution-2026-05-11.md`** — 4.5-layer xref methodology with live-data Findings 1–6
3. **`cron-and-queue-health-2026-05-11.md`** — 83 cron jobs, pg_net pipeline pattern, NWS retention bug
4. **`table-inventory-and-gaps-2026-05-11.md`** — full table inventory + storage growth finding
5. **`proposed-tables-2026-05-11.md`** — implementation-ready specs for 7 new tables/views

---

## TL;DR for the next bot

The data plane is **in much better shape than the first audit suggested**. False positives were corrected. Real findings reduce to:

- **3 confirmed bugs** worth fixing (xref slice, NWS pg_net retention, AGENTS.md staleness)
- **1 concrete data-acquisition opportunity** (SG historical orders → venue/performer resolution = 67.8% coverage already achievable)
- **1 storage trend to investigate** (`listings_snapshots` +23.6% in 3 days)
- **7 proposed new tables** to close gaps surfaced in the audit, ranked by priority

---

## All findings, by severity

### 🔴 Confirmed bugs needing fix

#### B1. `nws_alert_pending` permanently stuck rows
- **Symptom:** 94 unresolved rows, 92 over 24h stale, all `http_status`/`error` fields NULL
- **Root cause confirmed live:** zero matching rows in `net._http_response` — pg_net pruned responses before `nws_alerts_process_5min` could drain them. JOIN returns empty forever.
- **Affects entire pattern:** every `*_pending` table using queue/process/sweep architecture (15+ pipelines) is at risk of the same class
- **Same pattern likely on:** `sg_seller_pending` (11 rows, but recent — needs 24h re-check)
- **Fix sketched in** `cron-and-queue-health-2026-05-11.md` §4 — single `sweep_expired_pg_net_pending()` function applied to all `*_pending` tables
- **Implementation:** held back per pause directive

#### B2. `seatgeek_event_xref` matches the wrong slice of events
- **Symptom:** 11 xref rows, 0 of which overlap with the 186 `sg_event_id`s in `seatgeek_orders`
- **Root cause:** `auto_seller_inline_v2` matcher runs at listing-ingest time; historical orders' listings were never ingested in real time → matcher never fired
- **Impact:** every historical SG sale is cross-source-orphaned at the event level
- **Fix:** Layer 3 Path B (resolve venue + performers directly without requiring a TEvo event row)
- **Implementation:** see proposed table #1 `seatgeek_orders_resolved`

#### B3. `AGENTS.md` ARCHITECTURE diagram stale
- **Symptom:** Diagram declares "TWO data sources" (TEvo + ESPN); reality is **11**
- **Last accurate:** through 2026-05-08; subsequent SeatGeek / SeatData / Wikipedia / NOAA / Open-Meteo / FRED / Reddit / Nominatim integrations not reflected
- **Fix:** refresh the ASCII diagram, either to 11 sources or annotate the "two" as "running backbone only"
- **Trivial doc edit; care needed because `AGENTS.md` is a shared file per RULES**

---

### 🟡 Storage / capacity

#### S1. `listings_snapshots` grew 23.6% in 3 days
- 1,876 MB (2026-05-08) → 2,318 MB (2026-05-11)
- `n_live_tup` dropped 7.18M → 374k — either post-VACUUM stats catching up OR heap bloat
- **Storage audit 3 days ago** (`docs/storage-audit-2026-05-08.md`) recommended change-only ingest; not clear it's been applied or is preventing growth
- At current growth rate, Supabase tier limit risks within weeks
- **Investigation needed:** confirm whether change-only ingest is live in `collect-listings`; if not, that's the storage fix; if yes, need to investigate why it's not reducing growth
- **Next bot:** treat as P1 if implementing anything that adds to `listings_snapshots`

---

### 🟢 Corrections to original audit (now documented as not orphans)

These were initially flagged in `data-sources-audit-2026-05-11.md` and have been corrected in place:

| originally flagged | reality |
|---|---|
| `seatgeek_listings_snapshots` orphan | Live table, 50 MB / 63k rows, created in `20260509090000_seatgeek_broker_rebuild.sql:99`, has cron writers + dashboard readers |
| `seatgeek_sales_snapshots` orphan | Same migration, same usage pattern |
| `code_staging._readme` etc | Intentional sandbox markers per AGENTS.md TEST SCHEMAS Option C |
| `wiki-collect` edge function dormant | Intentional manual admin tool (targeted refresh, rivalries); unique vs SQL+pg_net pipeline |
| Open-Meteo under-pulled | Cron-scheduled at `20260509260000:357-358` |
| Reddit RSS under-pulled | Cron-scheduled at `20260509410000:477-491` |
| OSM Nominatim reactive-only | Cron-scheduled at `20260509260000:355-356` |
| 8 "dormant" edge functions | Mostly intentional (manual/frontend-triggered admin); only `wiki-collect` is purely admin and that's by design |
| `sg_event_backfill_pending` stalled | Has dedicated 3-cron processor at `20260509360000` |

**Net orphan count after corrections:** 0 tables, 0 functions, 0 data sources.

---

### 🔵 Architectural notes for context

#### A1. View layer (136) is larger than table layer (120)
Schema-change ripple effects are higher than table count suggests. Document view dependencies before any DROP TABLE.

#### A2. SQL + pg_net is the dominant ingest pattern
Edge functions are the minority. 22 migrations use `net.http_*`; ~15 distinct async pipelines (queue/process/sweep triple). Edge functions are reserved for: chat (Anthropic SDK loop), TEvo-specific complex flows (`collect`, `collect-listings`), ESPN ingest stack, and manual admin tools.

#### A3. 83 distinct cron jobs scheduled
Categorized in `cron-and-queue-health-2026-05-11.md` §1. Most are queue/process pairs; some are sweeps; some are top-level orchestration (`master-cascade-2min`, `midnight-catchup-sweep`).

#### A4. Top-2 tables hold 95% of DB
`listings_snapshots` (2.3 GB) + `section_metrics` (460 MB) ≈ 2.77 GB of total. Every other table is < 60 MB. Any storage optimization should target the top two first.

#### A5. Existing canonical views already unify cross-source
- `v_canonical_venue` — TEvo + SeatData + SeatGeek + ESPN
- `v_canonical_performer` — same scope plus ESPN league + Wikipedia pageid
These are used in the Path B sample fix and should be the reference layer for new cross-source work. No need to build parallel xref tables for venues/performers — extend these views.

---

### 🟢 Validated infrastructure (proven during audit)

- **Path B methodology** validated: 67.8% venue match / 19.8% full (venue + both performers) on all 400 historical SG orders using exact-name only, no normalization. Normalization + `pg_trgm` fuzzy should push to 90%+ / 60%+.
- **Cron+queue layer**: 14 of 16 `*_pending` queues running clean (0 unresolved).
- **Orphan auto-backfill** for SG events runs via dedicated 3-cron pipeline.
- **120 base tables / 136 views / 1 matview** in a sensible 11-category structure.

---

## Work checklist for the next bot

### Pre-implementation verification
- [ ] Read `proposed-tables-2026-05-11.md` cover-to-cover before any DDL
- [ ] Confirm Supabase MCP connectivity is stable
- [ ] Verify `v_canonical_venue` + `v_canonical_performer` view shapes haven't drifted since audit
- [ ] Verify `seatgeek_seller_listings` schema for the seat-array + seller-id fields (needed for proposals #5 and #6)
- [ ] Re-check `sg_seller_pending` in 24h — distinguish in-flight vs stuck rows

### Implementation order (each as a separate migration on a NEW feature branch — not on audit branch)
1. **Migration 1:** `seatgeek_orders_resolved` table + Path B backfill function + reactive trigger
2. **Migration 2:** `v_pg_net_queue_health` view (enumerate all 16 `*_pending` tables; exclude non-existent `fred_pending`/`sg_sales_pending`/`performer_wiki_pageviews_pending`)
3. **Migration 3:** `sweep_expired_pg_net_pending(p_table, p_ttl_hours)` function + per-pipeline hourly cron schedules (fixes B1)
4. **Migration 4:** `event_section_row_snapshots` + `section_norm()` function + trigger
5. **Migration 5:** `entity_xref_overrides` + `entity_xref_conflicts`
6. **Migration 6:** `broker_xref` (requires SG seller-id field confirmation)
7. **Migration 7:** `listing_xref` (requires SG seat-array field confirmation)
8. **Defer:** `tevo_event_archive` until justified by data demand

### Documentation tasks
- [ ] Update `AGENTS.md` ARCHITECTURE diagram from 2 → 11 sources (or annotate as "running backbone")
- [ ] Update `SCHEMA.md` version label after each new-table migration; append to change log
- [ ] Once migrations land: append AGENTS.md LOG entries (`DONE <SHA> <subject>`)

### Investigation tasks
- [ ] Confirm whether change-only ingest is live in `collect-listings` (storage-audit-2026-05-08.md proposed it; storage still grew 23.6%)
- [ ] If change-only ISN'T live: that's the priority storage fix
- [ ] If change-only IS live: investigate why heap is still bloating — likely needs VACUUM FULL or partitioning strategy

### Open questions (need user / A1 input)
- [ ] Should `tevo_event_archive` be built? Or accept Path B as the permanent historical-data solution?
- [ ] Confidence floor for downstream consumers — current methodology says 0.70; reviewer should confirm or override
- [ ] Manual override workflow — who can write to `entity_xref_overrides`? Service role only, or also UI access via specific RPC?

---

## Hand-off bus stops

| layer | doc | owner |
|---|---|---|
| Full data-source inventory + categories | `data-sources-audit-2026-05-11.md` | C1 |
| Methodology for cross-source xref | `cross-source-entity-resolution-2026-05-11.md` | C1 |
| Cron + queue operational health | `cron-and-queue-health-2026-05-11.md` | C1 |
| Table inventory + storage + proposals | `table-inventory-and-gaps-2026-05-11.md` | C1 |
| Implementation-ready DDL specs | `proposed-tables-2026-05-11.md` | C1 → A1 |
| **This index (start here)** | `audit-handoff-2026-05-11.md` | C1 → next bot |
