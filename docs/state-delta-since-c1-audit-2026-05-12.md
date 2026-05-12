# DELTA since C1 audit (2026-05-11 → 2026-05-12)

The 6 audit docs in this PR snapshot prod state **as of 2026-05-11 evening**. A merge wave on 2026-05-12 morning invalidates several numbers. This doc maps every superseded finding to its current state. The original audit docs are kept as historical record; read them with this delta in hand.

## Headline delta

| metric | 2026-05-11 audit | 2026-05-12 verified | doc impacted |
|---|---|---|---|
| public tables | 120 | **131** (+11) | `table-inventory-and-gaps` |
| RLS-on / RLS-off | 20 / 100 | **131 / 0** (100% coverage) | `view-deps-and-rls`, `data-sources-audit` |
| cron jobs total | 83 | 68 (consolidated via `_cron_invoke_edge_fn`) | `cron-and-queue-health` |
| public functions | 244 | 263 (+19) | `function-inventory` |
| `nws_alert_pending` stuck | 94 | **120** (worse) | `cron-and-queue-health` |
| share_links / macro_indicators / macro_series_config / fred_pending | not in inventory | live | `table-inventory-and-gaps`, `data-sources-audit` |

## What landed today that changed the picture

1. **#57 (security wave)** — `coworker_readonly` NOLOGIN, search_path on DEFINER funcs, anon JWT → vault, RLS on operational tables (`20260511000300`), RLS on domain tables — the `000400` draft has since been applied per A1's repair, closing the gap from 100→0 RLS-off
2. **#51 (canonical S1 batch)** — 14 phase migrations + Phase 15 views + the 2 anon REVOKEs C1 added
3. **#61 (C1 proposed-tables)** — 7 of the 7 proposals in `proposed-tables-2026-05-11.md` shipped (proposal #7 `tevo_event_archive` correctly deferred)
4. **#63 (storefront demo)** — `share_links` + storefront support tables added
5. **#52 (D1 broadway)** — `broadway_client.py` (no schema)
6. **#56 (D2 order clients)** — `tickpick_client.py` + `vivid_client.py` (no schema)
7. **#64 (bot_chat)** — cross-lane communication layer; `bot_chat` table + `bot_chat_log()` + `bot_chat_resolve()` + `v_bot_chat_unresolved`; security-locked to `service_role` only
8. **macro/FRED rollout** — `macro_indicators`, `macro_series_config`, `fred_pending` + 2 macro RPCs (`macro_value_at`, `macro_value_as_of_observed`) + FRED cron pipeline
9. **Cron consolidation** — `_cron_invoke_edge_fn` helper replaces literal-secret patterns across ~9 jobs; cron job count dropped from 83 → 68 via consolidation, not loss

## Per-doc supersession map

### `data-sources-audit-2026-05-11.md`
- 11 data sources count is still accurate
- **Add FRED ingestion** as a now-live data source (was wired previously, now confirmed via macro_indicators + fred_pending crons)
- RLS-off gap (100/120) is **CLOSED** (now 0/131) — withdraw that finding

### `view-deps-and-rls-2026-05-11.md`
- View-dependency map (top 20) still accurate (events 39 dependent views, etc.)
- **RLS coverage section is fully superseded** — 100% coverage now; the HIGH-risk broker-order gap closed

### `table-inventory-and-gaps-2026-05-11.md`
- 120 tables → **131 tables**. Add: `share_links`, `macro_indicators`, `macro_series_config`, `fred_pending` (+ ~7 more from the macro/FRED rollout I haven't enumerated)
- 11 logical categories still hold
- Storage growth on `listings_snapshots` (+23.6% in 3 days) finding still stands; needs separate follow-up
- Proposed tables (7) → all 6 buildable proposals shipped via #61, deferred #7 unchanged

### `function-inventory-2026-05-11.md`
- 244 functions → **263 functions**. New entrants include: `_cron_invoke_edge_fn`, `macro_value_at`, `macro_value_as_of_observed`, `fred_queue_all`, `fred_process_pending`, `bot_chat_log`, `bot_chat_resolve`, plus the 6 functions from #61 (`resolve_seatgeek_order`, `backfill_seatgeek_orders_resolved`, `rollup_event_section_row`, `sweep_inactive_event_states`, plus `trg_set_updated_at`)
- pg_trgm + unaccent extensions present (unaccent was installed by #61)
- F1 finding (`trg_set_updated_at()` doesn't exist) — **RESOLVED**, function created by #61

### `cron-and-queue-health-2026-05-11.md`
- 83 cron jobs → **68** (consolidated, not deleted)
- ~15 pg_net pipelines unchanged; `_cron_invoke_edge_fn` standardizes the invocation pattern
- **NWS retention bug WORSE**: 94 stuck → 120 stuck. Sweep migration sketched in §4 still not built. Real and urgent.
- `sg_seller_pending` may also have changed; need fresh queue-health snapshot

### `cross-source-entity-resolution-2026-05-11.md`
- Methodology sound; Layer 3 Path A `auto_match_sg_canonical_relaxed` benchmarks still TODO
- Strict matcher landed at 618 events matched (was unspecified in audit); SG xref coverage improved post-#51

### `proposed-tables-2026-05-11.md`
- Proposals #1-#6 SHIPPED via #61 (verified live, RLS+policies confirmed)
- Proposal #7 (`tevo_event_archive`) appropriately deferred — unchanged

### `audit-handoff-2026-05-11.md`
- Bug list: 1 of 3 resolved (anon REVOKEs landed via #51). Bug 1 (nws_alert_pending) worse. Bug 3 (AGENTS.md ARCHITECTURE stale) still standing.
- Storage trend (`listings_snapshots` growth): unchanged, still needs work
- 9 false-positive retractions: still accurate

## Now-superseded escalations

- **P0 anon-writable systemic finding** (bot_chat row 15, logged 04:00 UTC): WITHDRAWN. RLS covers 100% of tables now. The privilege grants still exist via default-privs leakage but RLS prevents actual data access. Cosmetic cleanup left to future hardening pass.

## Still real after the merge wave

1. **NWS pg_net retention bug** — 120 stuck rows and counting. `sweep_expired_pg_net_pending()` sketch still unbuilt.
2. **`listings_snapshots` storage growth** — +23.6% in 3 days at last audit; need fresh check.
3. **AGENTS.md ARCHITECTURE diagram stale** — says "TWO data sources," reality is 11+.

## Reading instructions

When reading any 2026-05-11 audit doc, mentally apply this delta. The numbers are accurate for that point-in-time; the categories and methodology hold.
