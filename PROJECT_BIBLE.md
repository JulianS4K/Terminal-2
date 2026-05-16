# PROJECT_BIBLE.md — operating playbook for all bots

**Last updated**: 2026-05-16 by A1
**Read this FIRST every session.** Saves ~5× the tokens vs reading every governance file at start.

This doc is the **operating playbook** — rules, macros, recipes, landmines. For the **inventory** (what exists: tables, views, crons, edge functions, vault, services), read `RESOURCES_BIBLE.md` (561 LOC, only when you need it).

| Need | Read |
|---|---|
| What can I do? Hard rules, hierarchy, macros, recipes | **This file** |
| What exists? Tables/views/crons/edge-fn inventory | `RESOURCES_BIBLE.md` |
| Who can push to where? | `BOT_HIERARCHY.md` |
| How do I apply a migration? | `MIGRATION_CONVENTIONS.md` |
| Security rules + lockdown invariants | `CLAUDE.md` |

---

## 1. Hard rules (you can't override these)

1. **SQL data is read-only by default.** Any `INSERT`/`UPDATE`/`DELETE`/DDL on prod requires explicit operator permission per call. Standing exceptions: `bot_chat` writes via `bot_chat_log()`, Supabase branch creation (copy-on-write fork, no prod mutation), authoring migration files (apply gated separately).
2. **Upstream third-party APIs are READ-ONLY.** TEvo, SeatGeek, SeatData, TickPick, Vivid — GET endpoints only. No order POSTs, holds, webhook config changes without explicit operator authorization.
3. **HTML / JS in your assigned lane is free reign** — no per-step approval.
4. **Render workspace is per-service scoped** (§2 ownership matrix). Cross-service writes = lane violation.
5. **A1 is sole pusher to `main`** (see `MIGRATION_CONVENTIONS.md §9`).
6. **Cross-lane file edits require coordination** via `bot_chat` `question` or PR comment to the lane owner.

When in doubt → ask via `AskUserQuestion` or post a `bot_chat` question.

---

## 2. Bot hierarchy + Render service ownership

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

| Bot | Render service | Service ID | Scope |
|---|---|---|---|
| A1 | workspace-wide | — | exclusive provisioning + deletes |
| D0 | `vibepass-terminal-test` | `srv-d839339kh4rs73ac3s20` | write OK |
| D1 | `vibepass-storefront-test` | `srv-d8140bnaqgkc73al4asg` | write OK |
| D2 | `d2-orders-dashboard` | `srv-d82b4kl7vvec73b4r3r0` | write OK |
| B1, C1, D3, D4, E1 | (all services) | — | read only |

Code-dir ownership (per `LANE_DISCIPLINE.md`):
- D0 → `static/terminal/*` + Terminal FE
- D1 → `static/store/*` + storefront API
- D2 → ops dashboard
- A1 → `supabase/migrations/*`, governance docs, cross-cutting

---

## 3. Column-name landmines (catch SQL bugs before you author)

Every entry here cost real session time when discovered. CHECK column names against this table FIRST.

| Table | Wrong name | Correct name |
|---|---|---|
| `seatgeek_sales_snapshots` | `sold_at`, `price`, `captured_at` | `sale_at_utc`, `broadcast_price`, `pulled_at` |
| `seatgeek_listings_snapshots` | `price` | `broadcast_price` (+ `retail_price_all_in` for all-in display) |
| `seatgeek_event_metrics` | `retail_min/median/p90` | `cost_min/median/p90` |
| `event_alerts` | `event_id`, `created_at` | `tevo_event_id`, `fired_at` |
| `nws_alerts` | `expires` | `expires_at` |
| `weather_observations` | `captured_at` | `observed_at` (reading) + `fetched_at` (ingest) |
| `venue_assets` | `is_outdoor`, 882 rows | `is_indoor`, **111 rows** (outdoor = `is_indoor = false`) |
| `sd_sales_normalized` | `observed_at`, `aq_short_event_id` | `sale_timestamp`, `tevo_event_id` |
| `events` | `is_classified`, `tbd` | (neither exists — use `EXISTS(event_xref...)` for sports; parse `(Date TBD)` from name) |
| `listings_snapshots` (TEvo firehose 8M rows) | filter by `aq_short_event_id` | **0% populated** — query by `event_id` only. Filter ours: `is_owned=true AND brokerage_id=1768` |
| `seatgeek_sales/listings_snapshots.tevo_event_id` | use as join key | **0% populated** — always query by `sg_event_id` (indexes added 2026-05-16) |

---

## 4. Canonical SECDEF RPCs (the hot 15 of 32)

| RPC | Args | When to call |
|---|---|---|
| `get_broker_event_page_v2(p_event_id, p_chart_hours)` | int, int (default 720) | **D0 Phase 2a primary**. 11 payload keys incl. sales_tape/weather/espn/sg_side_by_side/splits/freshness. Email-gated `@s4kent.com`. ~185ms. |
| `get_broker_event_page(p_event_id, p_chart_hours)` | — | v1; v2 composes it for base payload |
| `match_to_aq_event_id(source, src_id, name, venue, date, lat, lon, [src_venue_id])` | — | 4-tier matcher (direct id / venue+id / venue-exact / venue-fuzzy) |
| `create_system_aq_event(source, name, venue, date, src_id)` | — | SYS-md5 fallback when matcher returns NULL |
| `match_unmatched_orders_sweep(max, create_synth)` | int, bool | Cron-driven order sweep across 5 surfaces |
| `match_unmatched_listings_chunked(max_events, create_synth)` | int, bool | Listings firehose backfill (per-event chunked) |
| `bot_chat_log(level, lane, type, msg, pr, mig, in_reply_to, meta)` | — | **Standing permission**. Cross-lane coordination. |
| `bot_chat_resolve(id, level, lane, note)` | — | Standing permission. Close out a question/flag. |
| `cron_should_fire(jobname)` | text | Wrap every new cron body with this gate |
| `cron_resume_with_gate(jobname)` | text | Re-enable paused crons through the gate |
| `sg_classify_events()` | — | Refresh tier classifications in `sg_event_priority_state` |
| `sg_priority_poll_tick(max_polls)` | int | HOT/WARM polling driver |
| `espn_scoreboard_queue(lookahead_days)` | int (default **270**) | ESPN scoreboard ingest. Bumped 2026-05-16 to capture full NFL season. |
| `espn_scoreboard_process()` | — | Process ESPN responses → date_lookup |
| `refresh_sg_broker_sales_event_metrics(max_events)` | int (default 200) | Populate `seatgeek_event_metrics.sold_*` from deduped (DISTINCT ON sg_sale_id) sales snapshots. Hourly cron @ :17. |
| `release_health_check()` | — | All-checks rollup |

For the full RPC list + arg detail + composition relationships → `RESOURCES_BIBLE.md §3` and the migration headers.

---

## 5. Cross-source bridge topology

```
events (TEvo) ─── PK e.id ─────────────────────────────┐
   │                                                    │
   │ via entity_performer_map (perfid + ±6h date)       │
   ▼                                                    ▼
event_xref ──── espn_event_id ───────► espn_event_date_lookup
   │                                    espn_event_snapshots (gameday-scope)
   │                                    espn_team_snapshots
   │                                    espn_injuries_snapshots
   ▼
seatgeek_event_xref ── sg_event_id ──► sg_events_canonical
   │                                    seatgeek_listings_snapshots
   │                                    seatgeek_sales_snapshots (DISTINCT ON sg_sale_id !)
   │                                    seatgeek_event_metrics
   ▼
aq_event_map ── aq_short_event_id ────► universal canonical key
   │                                    (SYS-md5 hash convention for derived rows)
   ▼
venue_short_id ──► aq_venue_map / venue_assets / weather_observations
performer_short_id ──► aq_performer_map / espn_team_snapshots
```

**D0 canonical entry** (Phase 2a):

```sql
SELECT * FROM public._v_d0_event_index WHERE sg_event_id = $1;
-- OR for non-SG events (NFL etc.) — v2 RPC has fallback that resolves via event_xref:
SELECT public.get_broker_event_page_v2($tevo_event_id, 168);
```

---

## 6. MCP tools by lane

| MCP family | A1 | B1 | C1 | D0 | D1 | D2 | D3/D4/E1 |
|---|---|---|---|---|---|---|---|
| Supabase `execute_sql` (read) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Supabase mutation/migration | ✓ | CRIT only | drift-monitor only | ✗ | ✗ | ✗ | ✗ |
| Supabase `create_branch` (copy-on-write) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Render: read (list/logs/metrics) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Render: write (own service only) | all | ✗ | ✗ | terminal | storefront | dashboard | ✗ |
| Slack | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| scheduled-tasks | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| GitHub (`gh` via Bash) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

---

## 7. SQL macros (operational patterns bots use repeatedly)

### `bot_chat_log` — durable cross-lane coordination
```sql
SELECT public.bot_chat_log(
  p_level := 'data-collection', p_lane := 'A1',
  p_event_type := 'change_log',     -- change_log | question | flag | resolve_request
  p_message := 'did X. details: ...',
  p_related_pr := 154, p_related_mig := '20260516070000',
  p_in_reply_to := NULL, p_meta := NULL);
```

### Cancel-pattern SKIP (used in `sg_classify_events`)
```sql
WHERE sg_event_name ~* '(cancelled|if necessary|\(date tbd\)|^TBD at )'
```

### SG sales dedupe (mandatory — 11× duplication factor)
```sql
SELECT DISTINCT ON (sg_sale_id) *
FROM seatgeek_sales_snapshots
WHERE sg_event_id = $1
ORDER BY sg_sale_id, pulled_at DESC;
```

### Sports event gate (no `events.is_classified`)
```sql
EXISTS (SELECT 1 FROM event_xref WHERE tevo_event_id = events.id AND espn_event_id IS NOT NULL)
```

### Outdoor venue gate (no `is_outdoor`)
```sql
venue_assets.is_indoor = false  -- explicit FALSE, never NULL
```

### Cron body wrapper (always use the policy gate)
```sql
DO $body$ BEGIN
  IF NOT public.cron_should_fire('your_cron_name') THEN RETURN; END IF;
  -- work here
END $body$;
```

### Email gate inside SECDEF RPC
```sql
v_email := coalesce(auth.jwt()->>'email', '');
IF v_email NOT LIKE '%@s4kent.com' THEN
  RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
END IF;
```

### SYS-md5 hash convention (used by `create_system_aq_event` + v2 RPC fallback)
```sql
v_aq := 'SYS-' || substring(md5(name || '|' || venue || '|' ||
            to_char(date::timestamptz, 'YYYY-MM-DD"T"HH24:MI')) from 1 for 10);
```

---

## 8. Workflow recipes

### "I want to author a migration"
1. Read §3 landmines FIRST before writing column names
2. Test query shape on 5-10 sample rows via `execute_sql` (read-only)
3. Write `supabase/migrations/YYYYMMDDHHMMSS_descriptive_name.sql` per `MIGRATION_CONVENTIONS.md`
4. **Ask operator permission** via `AskUserQuestion` before `apply_migration`
5. Apply via MCP `apply_migration`
6. Verify post-apply on same 5-10 samples
7. Update header `## Already applied to prod  Applied via MCP YYYY-MM-DD`
8. Commit + push + open PR (A1 only pushes to main)

### "I want to wire a UI panel"
1. D0: call `supabase.rpc('get_broker_event_page_v2', {p_event_id, p_chart_hours})`
2. Branch on `data.bridge_ids.sg_event_id IS NULL` → render TEvo-only state
3. Branch on `data.weather.hidden=true` → hide weather strip
4. Branch on `data.espn.hidden=true` → hide ESPN panel
5. `data.sales_tape` is pre-deduped + capped at 20 rows
6. `data.freshness.*_latest` for per-source freshness chips

### "I want to flag a cross-lane issue"
```sql
SELECT public.bot_chat_log(
  p_level := 'data-collection', p_lane := 'D0', p_event_type := 'question',
  p_message := 'D1: add my Render origin to CORS_ALLOWED_ORIGINS', ...);
```

### "I want to spawn a cron"
1. Author the underlying SQL fn
2. Wrap body with `cron_should_fire('jobname')` gate
3. INSERT row in `cron_policy` with limits + work_check_sql
4. `cron.schedule('jobname', '*/X * * * *', $body$ ... $body$)`
5. Verify firings via `cron.job_run_details` + `cron_gate_decisions`

---

## 9. Recent landmark migrations (don't re-do these)

| Date | Migration | Effect |
|---|---|---|
| 2026-05-13 | cron policy gate | 4-stage conservation (budget/interval/work-check/window) |
| 2026-05-14 | universal AQ matcher | 4-tier `match_to_aq_event_id` + `create_system_aq_event` |
| 2026-05-14 | tiered polling | `sg_event_priority_state` + HOT/WARM/COOL/COLD tiers |
| 2026-05-15 | `get_broker_event_page` v1 RPC | D0 Phase 1 Path C foundation |
| **2026-05-16** | 20260516030000 | D0 Phase 2a prep: cancelled-filter + `tevo_event_id` col + `_v_d0_event_index` view |
| 2026-05-16 | 20260516040000 | Resume `listings_aq_backfill_overnight` cron |
| 2026-05-16 | 20260516050000 | `get_broker_event_page_v2` RPC (7 new keys, 185ms) |
| 2026-05-16 | 20260516060000 | SG `sg_event_id` indexes (perf for v2) |
| 2026-05-16 | 20260516070000 | NFL ESPN→TEvo→AQ→SG bridge + v2 RPC fallback fix |
| 2026-05-16 | 20260516080000 | Multi-sport bridge (MLB/MLS/WNBA/NBA/NHL) |
| 2026-05-16 | 20260516090000 | `espn_scoreboard_queue` default 90d → 270d |
| 2026-05-16 | 20260516100000 | `evo_orders` event-mapping columns (tevo_event_id + aq_short_event_id) + backfill |
| 2026-05-16 | 20260516110000 | NEW RPC `refresh_sg_broker_sales_event_metrics` + hourly cron; populates `seatgeek_event_metrics.sold_*` from `seatgeek_sales_snapshots` |
| 2026-05-16 | 20260516120000 | 3 analytics views: `v_event_sales_velocity`, `v_event_sales_metrics_filtered`, `v_event_price_arbitrage` |

---

## 10. Drift watchlist (known gaps — don't waste cycles rediscovering)

| Gap | Status | Symptom / workaround |
|---|---|---|
| `tevo_event_id` 0% populated on SG snapshot tables | Open (separate ingest workstream) | Query SG snapshots by `sg_event_id` (indexes added 2026-05-16) |
| `seatgeek_event_xref.last_listings_at`/`last_sales_at` | Dead globally (0/967) | Use `MAX(captured_at)` on snapshot tables |
| `sg_events_canonical.has_v2_listings_pulled` | Dead (25/4609 = 0.5%) | Same |
| ESPN snapshot pipeline = gameday-scope only | (specced, not built) | Forward-look ESPN panels empty by design |
| 29% active TEvo events have no SG bridge | NWSL/USL/AHL/niche real gap | First-class TEvo-only UI state |
| SG doesn't carry most NFL regular-season | SG coverage decision | NFL Event Detail renders TEvo+ESPN+AQ; SG hidden |
| `aq_short_event_id` 0% on `listings_snapshots` | Cron resumed 2026-05-16; firing 04:02 UTC | Use `event_id` for TEvo reads |

---

## 11. Self-check before any task

1. ☐ Did I read this playbook (§1-§8)?
2. ☐ Is my action covered by §1 hard rules?
3. ☐ Am I editing files in my own lane (§2)?
4. ☐ Did I verify schema column names against §3 landmines?
5. ☐ For mutations: did I ask operator permission?
6. ☐ For new crons: did I wrap with `cron_should_fire`?
7. ☐ For cross-lane work: did I `bot_chat_log` a question?
8. ☐ Is my work already shipped per §9 (don't re-do)?
9. ☐ Is my "discovery" a §10 known gap (don't waste cycles)?

If YES to all → proceed. Else fall back to `RESOURCES_BIBLE.md` for inventory or `CLAUDE.md` for security rules.

---

**Refresh policy**: A1 updates this playbook when (a) new canonical RPC ships, (b) hard rule changes, (c) column-name landmine discovered, (d) landmark migration lands. Inventory deltas go in `RESOURCES_BIBLE.md`. Don't edit without A1 review (drift prevention).
