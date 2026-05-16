# PROJECT_BIBLE.md — single-source reference for all bots

**Last updated**: 2026-05-16 by A1
**Token discipline**: READ THIS FILE FIRST. If your task is covered here, you don't need to read 5 other governance files. Only dig deeper when this doc references a specific source-of-truth and you need detail.

This bible consolidates the 80% bots actually need from CLAUDE.md + LANE_DISCIPLINE.md + BOT_HIERARCHY.md + MIGRATION_CONVENTIONS.md + data-source docs. The original files remain canonical for the 20% edge cases.

---

## 1. Hard rules (you can't override these)

1. **SQL data is read-only by default.** Any `INSERT`/`UPDATE`/`DELETE`/DDL on prod requires explicit operator permission per call. Standing exceptions: `bot_chat` writes via `bot_chat_log()`, Supabase branch creation (copy-on-write fork, no prod mutation), authoring migration files (apply gated separately).
2. **Upstream third-party APIs are READ-ONLY.** TEvo, SeatGeek, SeatData, TickPick, Vivid — GET endpoints only. No order POSTs, holds, webhook config changes without explicit operator authorization.
3. **HTML / JS in your assigned lane is free reign** — no per-step approval.
4. **Render workspace is per-service scoped.** See §3 below. Cross-service writes = lane violation.
5. **A1 is sole pusher to `main`** (see `MIGRATION_CONVENTIONS.md §9`).
6. **Cross-lane file edits require coordination** via `bot_chat` `question` or PR comment to the lane owner.

When in doubt → ask via `AskUserQuestion` or post a `bot_chat` question.

---

## 2. Bot hierarchy

```
A1 (admin · sole prod pusher · Render workspace owner)
├── B1 (security · monitors all; CRIT push allowed)
└── C1 (canonical · drift monitor only since PR #109)
    ├── D0 (Terminal FE · static site)
    ├── D1 (Consumer Retail · storefront/search)
    ├── D2 (Order Clients · ops dashboard)
    ├── D3 (Broadway Scraper · sub of D2)
    ├── D4 (Ticketing infra · UNASSIGNED)
    └── E1 (Kalshi/markets · future stub)
```

**Render service ownership** (per CLAUDE.md §4):

| Bot | Service | Service ID | Scope |
|---|---|---|---|
| A1 | workspace-wide | — | exclusive provisioning + deletes |
| D0 | `vibepass-terminal-test` | `srv-d839339kh4rs73ac3s20` | write OK |
| D1 | `vibepass-storefront-test` | `srv-d8140bnaqgkc73al4asg` | write OK |
| D2 | `d2-orders-dashboard` | `srv-d82b4kl7vvec73b4r3r0` | write OK |
| B1, C1, D3, D4, E1 | (read-only on all services) | — | read only |

**Lane ownership of code dirs** (per LANE_DISCIPLINE.md):
- D0 → `static/terminal/*` + Terminal FE
- D1 → `static/store/*` + storefront API in `app.py`
- D2 → ops dashboard
- A1 → `supabase/migrations/*`, governance docs, cross-cutting changes
- B1 → security workflows + `release_health_check`

---

## 3. SQL surface bots call (canonical RPCs + key tables)

### Canonical SECDEF RPCs (32 total; these are the key ones)

| RPC | What it does | When to call |
|---|---|---|
| `get_broker_event_page(p_event_id, p_chart_hours)` | v1 Event Detail payload: overview + chart + zones + orders + cadences | D0 Phase 1 (still works); rolled up into v2 |
| `get_broker_event_page_v2(p_event_id, p_chart_hours)` | v2 adds sales_tape + weather + espn + event_alerts + sg_side_by_side + splits + freshness | **D0 Phase 2a** primary entry point. Email-gated `@s4kent.com`. |
| `get_broker_event_detail(p_event_id)` | Raw event header (per-source xref-rich) | Composed by v1; bots usually don't call directly |
| `get_event_zones_rollup(event_id, is_owned)` | Zone-level rollup | Composed by v1 |
| `derive_event_lifecycle(p_event_id)` | Ghost/postponed/completed classifier | Composed by v1 |
| `match_to_aq_event_id(source, src_id, name, venue, date, lat, lon, [src_venue_id])` | 4-tier matcher → aq_short_event_id | Cross-source bridge work |
| `create_system_aq_event(source, name, venue, date, src_id)` | SYS-{md5} fallback row in aq_event_map | When matcher returns NULL |
| `match_unmatched_orders_sweep(max_per_table, create_synthetic)` | Sweep 5 order tables → tag aq_short_event_id | Cron `match_unmatched_orders_sweep_hourly` |
| `match_unmatched_listings_chunked(max_events, create_synthetic)` | Same for listings firehose | Cron `listings_aq_backfill_overnight` |
| `bot_chat_log(level, lane, event_type, message, related_pr, related_mig, in_reply_to, meta)` | Post to cross-lane chat | Standing permission |
| `bot_chat_resolve(id, resolver_level, resolver_lane, note)` | Mark a question/flag resolved | Standing permission |
| `cron_should_fire(jobname)` | 4-stage gate (budget/interval/work-check/window) | Wrap any cron body |
| `cron_resume_with_gate(jobname)` | Re-enable a paused cron through the gate | When graduating crons |
| `sg_classify_events()` | Refresh `sg_event_priority_state` tiers | Called by `sg_classify_events_5min` cron |
| `sg_priority_poll_tick(max_polls)` | HOT/WARM polling driver | Called by `sg_priority_poll_tick_1min` cron |
| `espn_scoreboard_queue(lookahead_days)` | Queue ESPN scoreboard fetches | Cron + manual NFL season refresh |
| `espn_scoreboard_process()` | Process queued ESPN responses → date_lookup | Cron `espn_scoreboard_process_5min` |
| `release_health_check()` | All-checks rollup | Cron + manual smoke |
| `_health_check_pg_net_errors()` | pg_net error rate sub-check | Composed by release_health_check |

### Canonical D0 entry view

```sql
SELECT * FROM public._v_d0_event_index WHERE sg_event_id = $1;
-- OR for non-SG events (NFL etc.):
SELECT public.get_broker_event_page_v2($tevo_event_id, 168);  -- falls back to base tables
```

### Key reference tables (144 tables total in public; these are the hot 25)

**Event canonical**:
- `events` — TEvo events PK=`id` (3,000+ future). Free-text venue + `primary_performer_id`.
- `event_xref` — TEvo ↔ ESPN bridge (PK `tevo_event_id`). 1,000+ rows after this session.
- `seatgeek_event_xref` — TEvo ↔ SG bridge. 967+ rows.
- `sg_events_canonical` — SG events PK=`sg_event_id`. 4,600 rows. Has `tevo_event_id` populated for ~26%.
- `aq_event_map` — Canonical AQ row PK=`aq_short_event_id`. 6,500+ rows; carries `sg_event_id`, `sh_event_id`, `tm_event_id`, `vivid_event_id`, `venue_short_id`, `performer_short_id`.
- `entity_event_map` — VIEW (NOT base table) joining events + 3 xref tables + lifecycle.
- `sg_event_priority_state` — Tier-classified events for HOT/WARM polling. Includes `tevo_event_id` (NEW 2026-05-16).
- `espn_event_date_lookup` — ESPN scoreboard ingest (2,400+ rows, 322 NFL).
- `espn_event_snapshots` — ESPN gameday firehose (state/scores/odds; 2,700+ rows, GAMEDAY-SCOPE only).

**Listings + sales**:
- `listings_snapshots` — TEvo firehose **8.2M rows, 2.8 GB**. Filter `is_owned=true AND brokerage_id=1768` for our inventory. **`aq_short_event_id` is 0% populated** — query via `event_id`.
- `seatgeek_listings_snapshots` — SG firehose 2M+ rows, 1.5 GB. 95% `aq_short_event_id` populated. Use `broadcast_price` / `retail_price_all_in`.
- `seatgeek_sales_snapshots` — SG sales 900K+ rows, 449 MB. **Always `DISTINCT ON (sg_sale_id)` — 11× duplication factor**. Columns: `sale_at_utc` (NOT `sold_at`), `broadcast_price`, `pulled_at`.
- `seatgeek_seller_listings` — SG seller (our cost basis).
- `event_metrics` / `zone_metrics` / `section_metrics` — TEvo-derived aggregates.
- `seatgeek_event_metrics` — SG aggregates with `cost_*` columns (NOT `retail_*`).

**Orders**:
- `evo_orders` / `evo_order_items` — our TEvo orders (PII columns; never expose to anon).
- `vivid_orders`, `tickpick_orders`, `seatgeek_orders` — per-source orders.

**Context**:
- `venue_assets` — 111 rows (NOT 882). Columns: `is_indoor` boolean (outdoor = NOT is_indoor). `latitude`, `longitude`, `tevo_venue_id` PK, `capacity`, `espn_venue_id`, `nws_grid_*`.
- `weather_observations` — `tevo_venue_id` + `observed_at` (reading time) + `fetched_at` (ingest time). `is_forecast` boolean separates obs from forecast.
- `nws_alerts` — `expires_at` (NOT `expires`). Geo-keyed.
- `espn_team_snapshots` — Per-team standings (`record_summary`, `win_pct`, `streak`).
- `espn_injuries_snapshots` — Active injuries by team.
- `event_alerts` — Movement markers (`tevo_event_id` + `fired_at`; NOT `event_id` + `created_at`).

**Entity xref**:
- `aq_venue_map` — Canonical venue (`venue_short_id` + cross-source IDs).
- `aq_performer_map` — Canonical performer.
- `entity_performer_map` — TEvo↔ESPN team mapping (393 rows; all 32 NFL teams + all major leagues).
- `entity_venue_map` — TEvo↔SeatData venue mapping.
- `cron_policy` / `cron_gate_decisions` — Cron policy gate config + audit log.

### Column-name landmines (commonly miscalled)

| Table | Wrong | Correct |
|---|---|---|
| `seatgeek_sales_snapshots` | `sold_at`, `price`, `captured_at` | `sale_at_utc`, `broadcast_price`, `pulled_at` |
| `event_alerts` | `event_id`, `created_at` | `tevo_event_id`, `fired_at` |
| `nws_alerts` | `expires` | `expires_at` |
| `weather_observations` | `captured_at` | `observed_at` (or `fetched_at`) |
| `seatgeek_event_metrics` | `retail_min/median/p90` | `cost_min/median/p90` |
| `venue_assets` | `is_outdoor`, 882 rows | `is_indoor`, **111 rows** |
| `sd_sales_normalized` | `observed_at`, `aq_short_event_id` | `sale_timestamp`, `tevo_event_id` |
| `events` | `is_classified`, `tbd` | (neither exists; use `EXISTS(entity_event_map...)` for sports gate, parse `(Date TBD)` from name) |

---

## 4. Data source inventory (12 families)

| Family | Tables | Rows | Status | Notes |
|---|---|---|---|---|
| **TEvo (EVO)** | 11 | 12.7M (4.9 GB) | Live; collector gaps for 1-7d + 60d+ windows | listings_snapshots is the firehose |
| **SeatGeek** | 20 | 935K (461 MB) | Live; sales firehose 487K rows/24h | Use `tevo_event_id`-indexed paths when possible |
| **AQ canonical** | 5 (event/venue/performer maps) | 6.5K | Updated via xlsx ingest + SYS-md5 seeds | Bridge for cross-source linkage |
| **ESPN** | 13 | 19K (14 MB) | Gameday-scope by default; this session backfilled 1,007 future xrefs | Bumped lookahead 90d → 270d manually |
| **Weather / NWS** | 6 | 193K (84 MB) | Live; forecast 7d ahead | Outdoor gate = `NOT is_indoor` |
| **Canonical entities** | 9 | 16K (12 MB) | entity_event_map / entity_performer_map / entity_venue_map | NFL teams 32/32 mapped |
| **SeatData** | 3 | 254 rows | Sparse (mostly defunct) | `sd_sales_normalized` |
| **Reddit** | 2 | 3.8K | Social sentiment | Not yet UI-wired |
| **TickPick** | 2 | 921 | Orders ingest only | No listings firehose |
| **Vivid** | 1 | (varies) | Orders ingest only | No listings firehose |
| **Crons + queues** | 4 | per-state | 79 active of 89 total | Policy gate via `cron_should_fire` |
| **Bot infra** | 3 | bot_chat, bot_chat_threads, scheduled_tasks_lock | Cross-lane coordination | Standing permission |

### Cross-source bridge topology (post-2026-05-16)

```
events (TEvo) ─── PK e.id ─────────────────────────────┐
   │                                                    │
   │ via entity_performer_map (perfid + ±6h date)       │
   ▼                                                    ▼
event_xref ──── espn_event_id ───────► espn_event_date_lookup
   │                                    espn_event_snapshots
   │                                    espn_team_snapshots
   │                                    espn_injuries_snapshots
   ▼
seatgeek_event_xref ── sg_event_id ──► sg_events_canonical
   │                                    seatgeek_listings_snapshots
   │                                    seatgeek_sales_snapshots
   │                                    seatgeek_event_metrics
   ▼
aq_event_map ── aq_short_event_id ────► (universal canonical key)
   │
   ▼
venue_short_id ──► aq_venue_map / venue_assets / weather_observations
performer_short_id ──► aq_performer_map / espn_team_snapshots
```

---

## 5. MCP tools by lane

| MCP tool family | A1 | B1 | C1 | D0 | D1 | D2 | D3/D4/E1 |
|---|---|---|---|---|---|---|---|
| Supabase: `execute_sql` (read) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Supabase: `execute_sql` (write) / `apply_migration` | ✓ | CRIT only | drift-monitor read only | ✗ | ✗ | ✗ | ✗ |
| Supabase: `create_branch` (no prod mutation) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Render: read (list/get/logs/metrics) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Render: write (own service only) | all | ✗ | ✗ | terminal | storefront | dashboard | ✗ |
| Slack | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| scheduled-tasks | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| GitHub (`gh` via Bash) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

---

## 6. Macros / SQL helper patterns bots use

### `bot_chat_log` — durable cross-lane coordination

```sql
SELECT public.bot_chat_log(
  p_level       := 'data-collection',  -- or 'admin' / 'security' / 'supervisor'
  p_lane        := 'A1',                -- your lane code
  p_event_type  := 'change_log',        -- change_log | question | flag | resolve_request
  p_message     := 'Did X. Details: ...',
  p_related_pr  := 154,                 -- optional
  p_related_mig := '20260516070000',    -- optional
  p_in_reply_to := NULL,                -- bigint of another bot_chat row
  p_meta        := NULL                  -- optional jsonb
);
```

### Cancel-pattern detection (sg_classify SKIP override)

```sql
WHERE sg_event_name ~* '(cancelled|if necessary|\(date tbd\)|^TBD at )'
```

### SG sales dedupe (mandatory)

```sql
-- ALWAYS DISTINCT ON sg_sale_id — 11× duplication factor in prod
SELECT DISTINCT ON (sg_sale_id) *
FROM seatgeek_sales_snapshots
WHERE sg_event_id = $1
ORDER BY sg_sale_id, pulled_at DESC;
```

### Sports gate (no `events.is_classified` column)

```sql
EXISTS (SELECT 1 FROM event_xref WHERE tevo_event_id = events.id AND espn_event_id IS NOT NULL)
```

### Outdoor venue gate (no `is_outdoor` column)

```sql
venue_assets.is_indoor = false  -- explicit FALSE, NOT NULL
```

### Cron body wrapper (policy gate)

```sql
DO $body$ BEGIN
  IF NOT public.cron_should_fire('your_cron_name') THEN RETURN; END IF;
  -- your work here
END $body$;
```

### Email gate (inside SECDEF RPC)

```sql
v_email := coalesce(auth.jwt()->>'email', '');
IF v_email NOT LIKE '%@s4kent.com' THEN
  RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
END IF;
```

### TEvo aq backfill SYS-md5 hash convention

```sql
-- create_system_aq_event() uses this hash; v2 RPC fallback looks for it
v_aq := 'SYS-' || substring(md5(name || '|' || venue || '|' || to_char(date::timestamptz, 'YYYY-MM-DD"T"HH24:MI')) from 1 for 10);
```

---

## 7. Workflow recipes

### "I want to author a migration"
1. Check schema first via `information_schema.columns` (don't assume — see §3 landmines)
2. Test the query SHAPE on 5-10 sample rows via `execute_sql` (read-only)
3. Write `supabase/migrations/YYYYMMDDHHMMSS_descriptive_name.sql` with header per `MIGRATION_CONVENTIONS.md`
4. **Ask operator permission** via `AskUserQuestion` before `apply_migration`
5. Apply via MCP `apply_migration`
6. Verify post-apply on the same 5-10 samples
7. Update migration file header `## Already applied to prod  Applied via MCP YYYY-MM-DD`
8. Commit + push + open PR (A1 only pushes to main; subordinates open PRs against A1's branch)

### "I want to query SQL"
1. **READ this bible's §3 landmines first** before writing column names
2. Use `tevo_event_id` paths over `sg_event_id` paths where indexes exist (see SG snapshots)
3. Add `LIMIT` to exploratory queries (MCP has 2-min statement timeout)
4. Tight projections — `SELECT id, name, ...` not `SELECT *`
5. For SG sales: `DISTINCT ON (sg_sale_id)` mandatory

### "I want to wire a UI panel for an event"
1. D0: call `supabase.rpc('get_broker_event_page_v2', {p_event_id, p_chart_hours})`
2. Branch on `data.bridge_ids.sg_event_id IS NULL` → render TEvo-only state
3. Branch on `data.weather.hidden=true` → hide weather strip
4. Branch on `data.espn.hidden=true` → hide ESPN panel
5. `data.sales_tape` is already deduped + capped at 20 rows
6. `data.freshness.*_latest` per-source MAX(captured_at); use for chips

### "I want to flag a cross-lane issue"
```sql
SELECT public.bot_chat_log(
  p_level := 'data-collection', p_lane := 'D0', p_event_type := 'question',
  p_message := 'D1: can you add my Render domain to CORS_ALLOWED_ORIGINS?',
  p_related_pr := NULL, p_related_mig := NULL, p_in_reply_to := NULL, p_meta := NULL);
```

### "I want to spawn a cron"
1. Author the underlying SQL function
2. Wrap with `cron_should_fire` gate
3. INSERT/UPDATE a row in `cron_policy` with limits + work_check_sql
4. `SELECT cron.schedule('jobname', '*/X * * * *', $body$ ... $body$);`
5. Verify firings via `cron.job_run_details` + `cron_gate_decisions`

---

## 8. Recent landmark changes (last 7 days)

| Date | Migration | Effect |
|---|---|---|
| 2026-05-13 | cron policy gate | 4-stage conservation (budget/interval/work-check/window) for all crons |
| 2026-05-14 | universal AQ matcher | 4-tier match_to_aq_event_id() + create_system_aq_event() fallback |
| 2026-05-14 | tiered polling | sg_event_priority_state + HOT/WARM/COOL/COLD/OBSERVE/SKIP tiers |
| 2026-05-15 | get_broker_event_page v1 RPC | D0 Phase 1 Path C foundation |
| 2026-05-16 | 20260516030000 | D0 Phase 2a prep: cancelled-filter + tevo_event_id col + `_v_d0_event_index` view |
| 2026-05-16 | 20260516050000 | get_broker_event_page_v2 RPC (7 new payload keys; 185ms typical) |
| 2026-05-16 | 20260516060000 | SG sg_event_id indexes (required for v2 perf) |
| 2026-05-16 | 20260516070000 | NFL ESPN→TEvo→AQ→SG bridge (292 events; v2 RPC fallback fix) |
| 2026-05-16 | 20260516080000 | Multi-sport bridge MLB/MLS/WNBA/NBA/NHL (715 more xrefs) |

---

## 9. Drift watchlist (known gaps — don't waste cycles rediscovering)

| Gap | Owner | Symptom |
|---|---|---|
| `collect-listings-1-7d` + `collect-listings-60d+` 0 firings/7d | B1/A1 | TEvo data stale for events 5-100d out |
| `tevo_event_id` is 0% populated on SG snapshot tables | (separate ingest workstream) | Queries must use `sg_event_id` paths |
| `seatgeek_event_xref.last_listings_at` / `last_sales_at` 0/967 populated | dead columns | Use `MAX(captured_at)` on snapshot tables instead |
| `sg_events_canonical.has_v2_listings_pulled` 25/4609 (0.5%) | dead metadata | Same |
| ESPN snapshot pipeline is gameday-scope only | (specced, not built) | Pre-event preview cards empty for sports |
| 29% of active TEvo events have no SG bridge | NWSL/USL/AHL/niche genuinely | First-class "TEvo-only" UI state |
| AQ NFL data was partial before this session | RESOLVED 2026-05-16 | Now 292 NFL games bridged via ESPN |
| `espn_scoreboard_queue` cron default 90d | A1 pending | NFL drift each fall when schedule releases |
| `aq_short_event_id` 0% on `listings_snapshots` | A1 cron resumed 2026-05-16 | First firing 2026-05-17 04:02 UTC |

---

## 10. Where to dig deeper

| Need | Read |
|---|---|
| Lane discipline detail | `LANE_DISCIPLINE.md` |
| Migration apply protocol | `MIGRATION_CONVENTIONS.md` |
| Push hierarchy + branch protection | `BOT_HIERARCHY.md` |
| Global security rules | `CLAUDE.md` |
| Active kanban / sprint state | `KANBAN.md` |
| Phase 2a Event Detail wireframe | `docs/event-view-wireframe-v4.md` |
| D0 contract + plan | `docs/D0_PHASE_2A_HANDOFF.md` |
| Cron landscape (all 79 active) | `docs/cron-landscape-2026-05-09.md` |
| Data sources detail | `docs/data-sources-terminal-uses.md` |
| Anon-callable RPCs | `docs/anon_callable_surface_inventory.md` |

---

## 11. Self-check before any task

1. ☐ Did I read this bible (§1-§7)?
2. ☐ Is my action covered by the §1 hard rules?
3. ☐ Am I editing a file in my lane (§2)?
4. ☐ Did I verify schema column names against §3 landmines?
5. ☐ For mutations: have I asked operator permission?
6. ☐ For new crons: did I wrap with `cron_should_fire`?
7. ☐ For cross-lane work: did I `bot_chat_log` a question?
8. ☐ Is my work already covered in §8 (don't re-do)?
9. ☐ Is my "discovery" actually a §9 known gap (don't waste cycles)?

If you answered YES to all → proceed.
If §11 doesn't cover your case → fall back to the file map in §10.

---

**Bible refresh policy**: A1 updates this file when (a) a new canonical RPC ships, (b) a hard rule changes, (c) a column-name landmine is discovered, or (d) a landmark migration lands. Don't edit without A1 review (avoid drift).
