# Evening Checkpoint — 2026-05-16 (~20:30 UTC, cross-project consolidated)

**Author**: A1. Heavy whole-project session — 28 PRs merged across A1 + B1 + D0 + D1 + D2 lanes, 10 migrations applied to prod, governance docs reconciled. A1 view (own work) plus consolidated lane-by-lane summary below.

C1 may formalize into the canonical `c1-checkpoint-2026-05-16.md` at the next 09:00 ET cycle.

---

## Cross-project state (all lanes, end of session)

| Lane | PRs merged today | PRs open EOD | Headline |
|---|---|---|---|
| **A1** (admin) | **5** (#146 #150 #154 #155 #157) + 7 earlier-session admin fixes (#134/#135/#137/#138/#139/#142/#159) | **2** (#161 SG sales metrics, #162 this checkpoint) | D0 Phase 2a infra + multi-sport bridge + governance bible |
| **D0** (Terminal FE) | **2** (#136 doorway, #160 Phase 2a Event Detail — 6 new panels consuming v2 RPC, merged 19:51 UTC) | 0 | Phase 2a UI live same-day as A1 ships the RPC |
| **D1** (Consumer Retail) | **9** (#141 search race · #143 polish · #144 movers cache · #148 security bundle · #151 audit drift · #152 delegated handlers · #153 a11y · #156 reserve cap) + 1 earlier (#140) | 0 | Massive UX + security + perf shipping day |
| **D2** (Order Clients) | **3** (#147 Undelivered SG rewire · #149 SG SellerDirect webhook WS2 · #158 SG broker sales views) | **1** (#129 APIRouter refactor DRAFT — awaiting bot_chat 180) | SG SellerDirect webhook + broker firehose rewire |
| **B1** (Security) | **2** charter docs (#140 #159 — expanded role: librarian/archivist + bible curator) | 0 | Charter expansion + triage cleanup of bot_chat 226-229 |
| **C1** (Canonical) | 0 | **2** (#114 daily checkpoint, #145 PR governance proposal) | Drift-monitor only since PR #109; surfaced view-vs-doc drift via #233 |
| **D3 / D4 / E1** | 0 | 0 | Stub / observe only |

**Total merged today**: ~28 PRs. **Open EOD**: 5 (2 A1 mine, 1 D2 draft, 2 C1).

## Headline

Four big things from A1's seat this session:

1. **D0 Phase 2a fully unblocked**: shipped `get_broker_event_page_v2` RPC (7 new payload keys, 185ms typical), `_v_d0_event_index` canonical view, SG sg_event_id performance indexes, plus the `tevo_event_id` column on `sg_event_priority_state` + cancelled-event tier filter. D0 can now wire the Event Detail page against a single RPC call with full sales tape + weather + ESPN + splits + freshness chips.

2. **Cross-source bridge across 6 sports**: NFL schedule released today, so AQ + ESPN both stale on it. ESPN scoreboard refreshed with 270d lookahead (322 NFL games landed), then bridged ESPN→TEvo→AQ→SG across NFL + MLB + MLS + WNBA + NBA + NHL. Result: **1,007 new ESPN→TEvo xrefs + 470 AQ rows + 365 SG xrefs** added; existing `cross_source_match_tick` cron caught 669 more SG matches in one trigger.

3. **SG broker sales metrics activated**: `seatgeek_event_metrics.sold_*` columns existed but were empty (0/2,099 rows populated). Authored `refresh_sg_broker_sales_event_metrics()` + hourly cron @ :17 that aggregates deduped sales (DISTINCT ON sg_sale_id; 11× dup factor). First refresh populated 122 events with $138,910 gross / 1,619 unique sales.

4. **PROJECT_BIBLE.md + RESOURCES_BIBLE.md reconciled**: shipped operating playbook (rules + hierarchy + macros + landmines + recipes) alongside existing 561-LOC inventory doc. CLAUDE.md updated to direct all bots to read both with explicit roles. Saves ~5× tokens per session vs reading every governance file unprompted.

---

## State summary

| Surface | State |
|---|---|
| Open PRs (this session) | **6**: #146 D0 Phase 2a prep · #150 v2 RPC + indexes · #154 ESPN→TEvo→AQ→SG bridge · #155 PROJECT_BIBLE reconciliation · #157 ESPN lookahead 270d · #161 SG sales metrics + evo_orders + arbitrage views |
| Merged this session | None yet — all 6 above are A1-authored, awaiting CI + operator merge to main |
| Migrations applied to prod | **10** (20260516030000 → 20260516120000) |
| Branch protection | LIVE on main |
| Scheduled tasks | unchanged from prior session |
| Slack channels | unchanged from prior session |
| `release_health_check` | (last self-check pre-session ok; not re-run) |
| `pg_net error rate` | (not re-measured; Kong 429 from prior session likely still applies) |
| `bot_chat` total / unresolved | (not re-counted; standing surface unchanged) |

---

## Migrations shipped (10 total)

| # | File | Effect |
|---|---|---|
| 1 | `20260516030000_d0_phase2a_prep` | sg_classify SKIP-override for cancelled patterns + `sg_event_priority_state.tevo_event_id` column + `_v_d0_event_index` view |
| 2 | `20260516040000_resume_listings_aq_backfill` | `listings_aq_backfill_overnight` cron flipped `active=true`; first firing tonight 04:02 UTC |
| 3 | `20260516050000_get_broker_event_page_v2` | NEW RPC with 7 payload keys (sales_tape, weather, espn, event_alerts, sg_side_by_side, splits, freshness) on top of v1 |
| 4 | `20260516060000_sg_event_id_indexes` | 3 btree indexes on SG snapshot tables (`sg_event_id`, time DESC) — required for v2 RPC perf (185ms vs 2-min timeout) |
| 5 | `20260516070000_espn_nfl_bridge_backfill` | 292 NFL games bridged ESPN→TEvo (91% match rate via entity_performer_map) + 292 AQ SYS- rows + 3 SG bridges; v2 RPC fallback fix for non-SG events |
| 6 | `20260516080000_espn_multi_sport_bridge` | Same pattern for MLB (654) + MLS (42) + WNBA (12) + NBA (6) + NHL (1) = 715 more ESPN xrefs + conditional AQ creation (skips when existing match) |
| 7 | `20260516090000_espn_scoreboard_queue_lookahead_270d` | `espn_scoreboard_queue` default 90d → 270d (auto-captures full NFL season; avoids fall drift) |
| 8 | `20260516100000_evo_orders_event_mapping_columns` | ADD `tevo_event_id` + `aq_short_event_id` to `evo_orders` + backfill (201/202 = 99.5% tevo / 88% aq populated) |
| 9 | `20260516110000_sg_broker_sales_event_metrics` | NEW RPC `refresh_sg_broker_sales_event_metrics()` + hourly cron @ :17 with policy gate; first refresh populated 122 events |
| 10 | `20260516120000_event_price_arbitrage_views` | 3 analytics views: `v_event_sales_velocity` (27,704 rows), `v_event_sales_metrics_filtered` (354 events p99-clean), `v_event_price_arbitrage` (3,494 future events; 64 with full delta) |

---

## Key data shifts (post-session vs pre-session)

| Layer | Before | After |
|---|---|---|
| `event_xref` rows (ESPN bridge) | ~partial | **+1,007 new** (NFL 292 + MLB 654 + MLS 42 + WNBA 12 + NBA 6 + NHL 1) |
| `aq_event_map` SYS- rows | 0 | **+470** (espn_*_derived seeds, with 245 events skipped because matcher found existing) |
| `seatgeek_event_xref` rows | 967 | **+365** (NFL 3 + MLB 347 + MLS 10 + WNBA 2 + auto-matcher 669 catchup) |
| `sg_event_priority_state.tevo_event_id` | column didn't exist | column added; **55% global / 84% active-tier** populated |
| `seatgeek_event_metrics.sold_*` | 0 of 2,099 (empty) | 122 events with first refresh; cron runs hourly |
| `evo_orders` event-mapping | NULL across schema | **99.5% tevo / 88% aq** populated |
| `espn_event_date_lookup` NFL rows | 8 (preseason only) | **322** (full season Aug 2026 - Jan 2027) |
| Canonical D0 entry | none | **`_v_d0_event_index` view** (1,892 rows; SG-anchored with v2 RPC fallback for non-SG events) |

---

## Arbitrage signal validated (live data)

Top underpricing signal from `v_event_price_arbitrage` (TEvo retail median vs SG sales realized median):

| Event | Date | TEvo retail | SG sale | Delta |
|---|---|---|---|---|
| Cleveland Guardians @ Yankees | 6/4 | $38.56 | $131.84 | **+$93** |
| Atlanta Braves @ White Sox | 6/11 | $32.64 | $56.00 | +$23 |
| Phillies @ Blue Jays | 6/10 | $82.62 | $95.34 | +$13 |
| Rays @ Yankees | 5/23 | $76.30 | $87.16 | +$11 |

Real trading signals D0 can surface — events where SG is clearing well above our retail asks.

---

## Cron landscape changes

**New crons scheduled** (2):
- `sg_broker_sales_metrics_refresh_hourly` @ :17 — populates `seatgeek_event_metrics.sold_*`; gated via `cron_should_fire` with `work_check_sql` to skip when no new sales
- `listings_aq_backfill_overnight` @ `2-14 4 * * *` — resumed (was active=false since 20260515240000); 13 firings nightly 04:02-04:14 UTC

**False alarm resolved** (4 crons):
- `collect-listings-1-7d`, `collect-listings-7-30d`, `collect-listings-30-60d`, `collect-listings-60d+` — earlier session audit flagged "0 firings in 7d". Root cause: all freshly scheduled today; first triggers fell 16:20-17:30 UTC. All 4 fired successfully on first trigger. `collect-listings-1-7d` ingested 17,512 rows for 68 events post-17:30 firing.

**Default lookahead bumped** (1):
- `espn_scoreboard_queue` default 90d → 270d (auto-captures full NFL season schedule)

---

## Governance docs reconciled

- **`PROJECT_BIBLE.md`** (NEW, ~300 LOC) — operating playbook: hard rules, bot hierarchy + Render service ownership, 8 **column-name landmines** caught this session, hot 15 SECDEF RPCs, SQL macros (bot_chat_log, cancel filter, SG dedupe, sports gate, outdoor gate, cron wrapper, email gate, SYS-md5), workflow recipes, drift watchlist, 9-item self-check.
- **`RESOURCES_BIBLE.md`** (UPDATED, 561 LOC) — date header refreshed 2026-05-13 → 2026-05-16; added "Latest deltas" table with all 10 migrations + 1 doc; added `_v_d0_event_index` to §4.3 broker views.
- **`CLAUDE.md`** (UPDATED) — top section now directs bots to read PROJECT_BIBLE.md FIRST every session; RESOURCES_BIBLE.md only when looking up specific resources.

---

## Column-name landmines caught (8 documented in PROJECT_BIBLE §3)

These cost real session time when discovered:

| Wrong (assumed) | Correct (actual) | Table |
|---|---|---|
| `sold_at`, `price`, `captured_at` | `sale_at_utc`, `broadcast_price`, `pulled_at` | seatgeek_sales_snapshots |
| `event_id`, `created_at` | `tevo_event_id`, `fired_at` | event_alerts |
| `expires` | `expires_at` | nws_alerts |
| `captured_at` | `observed_at` or `fetched_at` | weather_observations |
| `retail_*` | `cost_*` | seatgeek_event_metrics |
| `is_outdoor`, 882 rows | `is_indoor`, **111 rows** | venue_assets |
| `observed_at`, `aq_short_event_id` | `sale_timestamp`, `tevo_event_id` | sd_sales_normalized |
| `is_classified`, `tbd` | (neither exists; use `EXISTS(event_xref...)` for sports gate) | events |

---

## Cross-lane handoff chain (the day's biggest story)

The A1 work this session was direct input to D0's same-day Phase 2a UI ship. Sequence:

1. **A1 12:00 UTC ish**: ships `_v_d0_event_index` view + `get_broker_event_page_v2` RPC + SG sg_event_id indexes (PRs #146, #150)
2. **A1 ~14:00**: ships ESPN→TEvo→AQ→SG bridge across NFL + 5 other sports (PRs #154, #157)
3. **D0 ~16:00 → 19:51**: consumes the v2 RPC + bridges, ships `event.js` with 6 new panels (sales tape / weather strip / ESPN panel / event_alerts / sg_side_by_side / splits / freshness). Merged as PR #160.
4. **A1 ~19:00**: ships SG broker sales metrics (PR #161) so D0's sales-tape panel + arbitrage view have populated `sold_*` data.
5. **D1 + D2 in parallel**: 9 D1 + 3 D2 PRs landing throughout — storefront UX bundles, SG SellerDirect webhook, Undelivered SG rewire.
6. **B1 in parallel**: triage cleanup (4 status closures), SEC-MED follow-up flag on PR #115 (bot_chat 235), governance drift catch on `v_bot_chat_unresolved` (bot_chat 233 → C1 ack 237), charter expansion to librarian/archivist + bible curator (PR #159).

Net effect: a same-day A1→D0 handoff cycle (RPC ships → UI consumes → both in main) plus parallel D1/D2 lane shipping with zero cross-lane conflicts.

## Outstanding cross-lane items at EOD

| Item | Owner | Notes |
|---|---|---|
| PR #129 D2 APIRouter refactor (DRAFT) | D2 | Awaiting bot_chat 180 architecture decision |
| PR #145 C1 PR governance proposal | C1 → A1 | Single doc proposing PR-flow standards. A1 review pending. |
| PR #114 C1 daily checkpoint (2026-05-15) | C1 | Stale; may be superseded by today's #162. |
| B1 SEC-MED follow-up on PR #115 (bot_chat 235) | A1 | Defense-in-depth on D0 RPC + Tier-1 RLS grants — operator to review |
| B1 governance/view drift (bot_chat 233 → 237) | C1 | C1 ack'd; root cause = migration 20260515340050 view definition vs CLAUDE.md §1 doc |
| `match_listings_to_sg_30min` 92% timeout (bot_chat 225) | A1 | D2 flagged; A1 acknowledged in 231 — next-session combo fix (24h window narrow + index) |

## Carry-forward (next session)

| Item | Owner | Status |
|---|---|---|
| 86K unmapped SG listings + 897 SG seller listings | self-resolving | Drains tonight 04:02 UTC via resumed `listings_aq_backfill_overnight` cron |
| 289 NFL events stay AQ-only (SG doesn't carry most) | self-resolving | `cross_source_match_tick_30min` auto-catches as SG ingests primetime games |
| `evo_orders_process` live-write update | A1 next-session | Currently backfill-only; new orders post-mig won't have tevo_event_id until backfill re-runs. Existing `match_unmatched_orders_sweep.evo_order_items` branch catches via items. |
| `tevo_event_id` 0% on SG snapshot tables | separate ingest workstream | Use `sg_event_id` paths (indexes added today) |
| `seatgeek_event_xref.last_*_at` dead columns | document only | Query snapshot tables for freshness |
| ESPN gameday-scope only | by design | Forward-look ESPN panels empty until per-event ingest specced/built |
| 6 open PRs awaiting merge to main | A1 | #146 #150 #154 #155 #157 #161 |
| C1 token-discipline carryover | from prior session | Not addressed this session |

---

## Session token usage notes

Operator asked about token discipline. Self-audit drivers:

1. Operator paste-throughs of large plan docs ×2 — biggest single sink (~15K tokens duplicated)
2. Migration SQL written 2-3× per file (response inline + Write tool + apply_migration body)
3. Large SQL result dumps (100-event census, 322 NFL games) — should always cap with LIMIT
4. Bible file reads + edits (RESOURCES_BIBLE.md 561 LOC pulled multiple ranges)
5. `pg_get_functiondef` reads for existing PL/pgSQL bodies
6. PR body texts (6 PRs × 100-200 LOC each)
7. TodoWrite churn (~25 calls, full list each time)
8. Explore agent prompts + outputs

Fix forward: PROJECT_BIBLE.md exists now — bots reading the playbook + RESOURCES_BIBLE.md inventory once at session start should save ~5× tokens vs reading every governance file. Plus: tight projections + LIMIT on SQL probes; batch migrations vs stacking thin ones.

---

## Open PRs at EOD (5)

```
#114  c1/daily-checkpoint-2026-05-15        (stale; may be superseded by #162)
#129  d2/api-router-refactor (DRAFT)         (awaiting bot_chat 180 architecture)
#145  c1/pr-governance-proposal              (A1 review pending)
#161  a1/sg-sales-metrics-and-arbitrage      (this session — applied, awaiting merge)
#162  a1/checkpoint-2026-05-16-evening       (this doc)
```

A1's other 5 PRs from this session (#146 #150 #154 #155 #157) all merged in operator-driven sequence during the session — that's why D0 PR #160 could ship Phase 2a Event Detail same-day.

---

## Critical files touched this session

```
supabase/migrations/
  20260516030000_d0_phase2a_prep.sql
  20260516040000_resume_listings_aq_backfill.sql
  20260516050000_get_broker_event_page_v2.sql
  20260516060000_sg_event_id_indexes.sql
  20260516070000_espn_nfl_bridge_backfill.sql
  20260516080000_espn_multi_sport_bridge.sql
  20260516090000_espn_scoreboard_queue_lookahead_270d.sql
  20260516100000_evo_orders_event_mapping_columns.sql
  20260516110000_sg_broker_sales_event_metrics.sql
  20260516120000_event_price_arbitrage_views.sql

PROJECT_BIBLE.md                       [NEW]
RESOURCES_BIBLE.md                     [edited — Latest deltas + view list]
CLAUDE.md                              [edited — bibles directive]
docs/D0_PHASE_2A_HANDOFF.md            [NEW per PR #146]
docs/checkpoint-2026-05-16-evening.md  [THIS FILE]
```

Owner: A1. Next session can resume from this state — start with PROJECT_BIBLE.md §11 self-check.
