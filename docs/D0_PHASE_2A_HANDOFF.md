# D0 Phase 2a handoff — working build contract

**Date**: 2026-05-16
**Author**: A1 (Audit/Push)
**Status**: Schema fixes deployed; D0 unblocked to start wiring

This doc captures what A1 verified, what got fixed, and the constraints D0 needs to code around. Sit alongside D0's Phase 2a plan (Addendums 4+5) and supersedes any prior schema assumptions.

---

## What D0 should use as the entry point

```sql
SELECT * FROM public._v_d0_event_index WHERE sg_event_id = $1;
```

One row per active/upcoming event with all bridge IDs and venue context pre-resolved. RLS-gated (authenticated @s4kent.com via `d0_s4kent_read` policy from 20260515320000; the view itself has `security_invoker=true` so it inherits the caller's RLS).

### View columns

| Column | Type | Notes |
|---|---|---|
| `sg_event_id` | bigint | Primary cross-source key. 95-100% of SG listings/sales rows have this. |
| `tevo_event_id` | bigint | **NEW** — populated for ~55% of rows (84% of active-tier events). NULL for SG-only events. |
| `aq_short_event_id` | text | Canonical AQ ID. Populated for ~95% of SG-bridged events. |
| `event_name`, `venue_name`, `event_at_utc` | text/text/timestamptz | Display strings (from SG side). |
| `tier` | text | `HOT`/`WARM`/`COOL`/`COLD`/`OBSERVE`/`SKIP`. **NEW**: cancelled/if-necessary/date-tbd events now correctly SKIP'd. |
| `owned_count_last_7d`, `active_listings_last_7d`, `hours_to_event` | int/int/numeric | Pre-aggregated. |
| `espn_event_id`, `espn_league` | text/text | Gameday-scope (see Constraint 2 below). |
| `venue_tevo_id`, `is_indoor`, `latitude`, `longitude`, `capacity` | … | Venue context. Outdoor = `NOT is_indoor`. Coverage is sparse: 111 venues in `venue_assets`. |
| `performer_short_id` | text | Single primary performer. |

### Freshness signals — fetch on demand

The view **does NOT** include `last_listings_at` / `last_sales_at` because correlated MAX() subqueries against `listings_snapshots` (8M rows) and `seatgeek_listings_snapshots` (2.3M) consistently time out. When you need them for a specific event:

```sql
-- Per-event listings freshness
SELECT max(captured_at) FROM public.seatgeek_listings_snapshots WHERE sg_event_id = $1;
SELECT max(captured_at) FROM public.listings_snapshots WHERE event_id = $1;  -- TEvo
SELECT max(sale_at_utc)  FROM public.seatgeek_sales_snapshots  WHERE sg_event_id = $1;
```

**DO NOT** read `seatgeek_event_xref.last_listings_at` or `sg_events_canonical.last_v2_pull_at` — those columns are dead globally (0 of 967 + 25 of 4609 rows populated).

---

## Migrations shipped today (2026-05-16)

| File | What it does | Status |
|---|---|---|
| `20260516030000_d0_phase2a_prep.sql` | sg_classify cancelled-filter + ADD `tevo_event_id` + `_v_d0_event_index` view | Applied ✅ |
| `20260516040000_resume_listings_aq_backfill.sql` | Resume `listings_aq_backfill_overnight` cron (was active=false) | Applied ✅, first firing 2026-05-17 04:02 UTC |

After tonight's 4:02-4:14 UTC backfill window, `listings_snapshots.aq_short_event_id` coverage rises from 0% to ~95%.

---

## D0 plan constraints (no migration — these are facts to code around)

### Constraint 1 — SG xref freshness columns are dead

`seatgeek_event_xref.last_listings_at`, `seatgeek_event_xref.last_sales_at`,
`sg_events_canonical.has_v2_listings_pulled`, `sg_events_canonical.last_v2_pull_at`,
`sg_events_canonical.last_v2_status`, `sg_events_canonical.has_seller_listings`
are all unmaintained.

**Population census (verified 2026-05-16):**
- `seatgeek_event_xref.last_listings_at`: 0 of 967 (0%)
- `seatgeek_event_xref.last_sales_at`: 0 of 967 (0%)
- `sg_events_canonical.has_v2_listings_pulled=true`: 25 of 4609 (0.5%)
- `sg_events_canonical.has_seller_listings=true`: 47 of 4609 (1%)
- `sg_events_canonical.has_orders=true`: 186 of 4609 (4%)
- `sg_events_canonical.has_broker_sales=true`: 371 of 4609 (8%) — only this one works

**Action for D0**: Don't gate UI on these flags. Always query the snapshot tables for "is data fresh?" decisions.

### Constraint 2 — ESPN is gameday-scope only

`espn_event_snapshots` is fed by `espn-gameday-10min` cron which only ingests today's slate. The pipeline writes 478 snapshots in last 24h, but those flow ONLY to events currently in pre/in/post-game state.

**Population census (verified 2026-05-16, events upcoming next 7d):**
- MLB upcoming: 96 events, 7 have any snapshot, latest 2026-05-07 (9d stale)
- NBA upcoming: 8 events, 8 have snapshot, all 2026-05-07 (9d stale)
- WNBA/F1/MLS/NHL upcoming: 0 snapshots

**Action for D0**: ESPN "live score" panel works on game day. For pre-event "matchup preview 3-7 days out", ESPN snapshot data is empty by design. Use `entity_event_map.espn_event_id` to confirm an event IS ESPN-tracked, but expect snapshot data only when `hours_to_event ≤ 12` and the event is in `state` of `pre`/`in`/`post`.

### Constraint 3 — 29% of active TEvo events have no SG bridge

162 active TEvo events (24h listings activity), 47 have no `seatgeek_event_xref` row. Sample shows the gap is mostly:
- NWSL (Bay FC, Gotham FC, Orlando Pride, Boston Legacy, Denver Summit)
- USL/lower-tier soccer (Sacramento Republic, Oakland Roots)
- AHL hockey (Cleveland Monsters)
- Niche shows (World Elite Sumo, Stars On Ice, Wizard of Oz @ Sphere)

**Action for D0**: First-class "TEvo-only" UI state when `sg_event_id IS NULL` in the view. Show TEvo listings panel; hide SG comparison + AQ pricing context.

### Constraint 4 — Cancelled / If-Necessary / Date-TBD pattern matters

D0 should treat `_v_d0_event_index.tier = 'SKIP'` as "do not display in active polling lists". After today's migration, 85 cancelled-pattern events are correctly SKIP'd. Pattern is `~* '(cancelled|if necessary|\(date tbd\)|^TBD at )'`.

---

## Verified spot-check (5 broad-spectrum events)

| Event | tier | tevo_event_id | espn_league | aq_short_event_id |
|---|---|---|---|---|
| MLB Yankees vs Blue Jays 5/18 | COOL | 3091413 | MLB | 6Z999NA |
| NBA Thunder @ Lakers G6 CANCELLED | **SKIP** ✓ | 3344961 | NBA | Z4ZKPO4 |
| Bruno Mars @ Soldier Field | HOT | 3262932 | (null) | XVGQZDY |
| MMA Rousey vs Carano @ Intuit Dome | HOT | 3309894 | (null) | 59B46Y33 |
| MLS Toronto FC @ Charlotte FC | HOT | 3221955 | MLS | EEJ54Y3 |

---

## Outstanding operator/B1 items (don't block D0)

1. **`collect-listings-1-7d` + `collect-listings-60d+` cron coverage**: 0 firings in 7 days despite `active=true`. Other comma-hour schedules work fine, so it's specific to these two. B1 investigation. Symptom: events 1-7 days out have stale TEvo data (last capture 2026-05-14 ~16:05 for most events). Doesn't block D0 — once these resume, TEvo listings panels become live.

2. **TEvo aq tagging backfill** completing tonight 04:14 UTC. D0 can start wiring against the view today; TEvo-specific aq joins will succeed by tomorrow morning.

---

## D0 next steps

1. Wire the event-index dropdown / search against `_v_d0_event_index` filtered by `tier IN ('HOT','WARM','COOL')`.
2. On event-detail page open, fan out to per-table freshness queries (see "Freshness signals" section).
3. Branch UI on `sg_event_id IS NULL` (TEvo-only) vs both-present (cross-source panel).
4. ESPN panel: only fetch + render when `espn_event_id IS NOT NULL` AND `hours_to_event ≤ 12`.
5. Outdoor weather strip: `is_indoor = false AND latitude IS NOT NULL`.

Owner: A1 → D0.
