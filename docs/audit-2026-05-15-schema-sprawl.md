# Schema Sprawl Audit — 2026-05-15

Author: C1 (Cluster F of the [audit + consolidation plan](docs/audit-2026-05-15-consolidation-plan.md)). Read-only inventory; recommendations only.

## Public schema shape

| Object class | Count |
|---|---|
| Tables | 144 |
| Views | 149 |
| Materialized views | 2 |
| Functions (total) | 297 |
| Functions — SECDEF w/ search_path | 28 |
| Functions — SECINVOKER w/ search_path | 234 |
| Functions — SECINVOKER **without** search_path | 35 |

149 views against 144 tables — close 1:1 — suggests heavy view layering (each table has ~1 view fronting it). Worth confirming whether each `v_*` is in use or is dead code from prior iterations.

## View prefix distribution (149 total)

| Prefix | Count | Notes |
|---|---|---|
| `v_*` | 103 | The canonical convention. Likely contains the most dead code. |
| `chat_*` | 5 | Chat surface; live |
| `retail_*` | 5 | D1 retail surface |
| `broker_*` | 4 | Broker pipeline |
| `our_*` | 4 | Likely operator/account-specific |
| `entity_*` | 3 | Entity resolution |
| `espn_*` | 3 | ESPN-tagged |
| `event_*` | 3 | Event domain |
| `seatgeek_*` | 3 | SG-tagged |
| `unified_*` | 3 | Unified-orders shape |
| `cross_*` | 2 | Cross-source |
| `latest_*` | 2 | Latest-snapshot |
| `data_*`, `events_*`, `evo_*`, `matchup_*`, `order_*`, `sd_*`, `seatdata_*`, `sg_*`, `team_*` | 1 each | Single-purpose |

## Gap: function usage statistics

`pg_stat_user_functions` returns **zero rows** — Supabase's default `track_functions='none'` means per-function call counts aren't collected. Without enabling this, C1 cannot answer "which of the 297 public functions are dead code."

**Recommendation (Cluster A follow-up, A1 lane)**: enable `track_functions='pl'` on the prod project. Cheap to turn on; gives the next sprawl pass real data.

Alternative without changing the setting: build a static-analysis map by scanning:
- `cron.job.command` for function name references
- `pg_views.definition` (and `pg_matviews`) for function references
- `pg_proc.prosrc` for function-to-function references
- Edge-function source code for RPC calls
- Repo `static/` JS for `rpc('<fn_name>')` patterns

That's a one-time scan; output is a function dependency graph. Cluster F sub-task, ~1 C1 session of work.

## Top-level recommendations (not action items — for plan refinement)

1. **Enable `track_functions='pl'`** (A1, 1 line of config) — unlocks F-2 properly.
2. **Inventory `v_*` views by underlying-table access** — use `pg_stat_user_tables.last_seq_scan` / `last_idx_scan` as a proxy. Views with no recent underlying-table read = dead-code candidates.
3. **Convention check**: do all `v_*` views set `security_invoker = true` (post PR #94)? Spot-checks suggest yes but worth a confirming `pg_class.reloptions` scan.
4. **The 46 non-`v_*` views** — confirm each has a single owning lane and a documented purpose. Anything orphaned post-pipeline-rewrite (broker rewrite in PR #100, AQ rewrite in PR #103) is a candidate for removal.

## Function search_path retrofit

35 SECINVOKER functions in public lack `SET search_path`. Per [docs/audit-2026-05-14-data-stability.md](docs/audit-2026-05-14-data-stability.md), PR #95 swept 215 functions; the remaining 35 were either created after that PR or escaped the sweep. PR #110 (B1, in flight) addresses some.

C1 will report the residual count after PR #110 merges; B1 owns the follow-on.

## Materialized views in API surface

Two matviews are exposed to `anon`/`authenticated`: `latest_event_metrics` + `v_dashboard_writes_24h`. Documented as intentional in 5/14 audit. No change recommended.

## NOT VALID foreign keys (57)

Cross-source FKs declared in PR #99 are deliberately `NOT VALID` — they document relationships without locking the table for backfill validation. Should be `VALIDATE`d in a low-traffic window once data is clean. Backlog item for A1, low priority (warn-only).

## Out of scope for this doc

- Function call dependency graph (needs `track_functions` or static analysis)
- View-to-table access stats (needs `pg_stat_user_tables` snapshot over time)
- Storage-bloat audit (needs `pg_total_relation_size` ranking)

These are next-week opportunities, not blockers.
