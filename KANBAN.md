# KANBAN.md — Terminal-2 shared work board

> **One source of truth for what's next, who's on it, and what just shipped.**
>
> - **code** owns: backend (Python, SQL, edge functions), audits, git push.
> - **design** owns: frontend (`static/*.html`, `design/*`), ships via code's proxy.
>
> **Update protocol**: append rows; don't edit other rows in place. Newest activity at the top of each column. Use the date format `YYYY-MM-DD HH:MM` (UTC).
>
> Status flow: `NEXT → DOING → BLOCKED (if stuck) → DONE`. When a NEXT row gets started, MOVE it (don't duplicate). When a DOING row ships, MOVE it to DONE with the commit SHA.

---

## DOING

### DOING (design) — Polish the chart range switcher

- **What**: Removed `color` from the `.rng` transition (was the source of the activate flash); added `[` / `]` keyboard stepping (one-shot global listener that respects input focus and wraps at the ends without spilling); added a Chart.js crosshair plugin + switched the tooltip to `mode:'index'` so all visible series values render at the snapped x; added a relative-time `title` callback ("3h ago", "yesterday 4 PM", "Apr 24") replacing the long ISO.
- **Files touched**: `static/index.html`
  - CSS: ~lines 88-101 (`.rng` transition + new `:focus-visible` outline)
  - JS keyboard wiring: ~lines 1726-1755 (`_wireRangeKeyboard` + call from `_wireRangeButtons`)
  - JS chart helpers: ~lines 1830-1888 (`_formatRelativeTime`, `_evtChartCrosshair` plugin)
  - JS tooltip config: ~lines 2065-2080 (`mode:'index'` + `title` callback)
  - JS chart constructor: ~lines 2147-2151 (register `_evtChartCrosshair` locally, not globally)
- **Status**: ready for review
- **Started**: 2026-05-09 02:15 UTC

### DOING (code) — _none yet_
_(if I'm in the middle of something, it goes here so design knows what files I'm touching)_

---

## NEXT

### NEXT (design) — orient and pick a starter task

**What**: Read `COWORKER_ONBOARDING.md` end-to-end, then pick a row below.
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Render event lifecycle status badge

**What**: Backend now classifies every event as `active | ghost_eliminated | completed | postponed | cancelled` via the new `lifecycle` block in `/api/broker/event/{id}/overview` and `lifecycle` field on each event in `/api/portfolio`. UI surfaces that need treatment:
1. **Event hero** (top of event detail page): show a colored badge if `lifecycle.status !== 'active'`. Suggested colors: `ghost_eliminated` = dim red, `completed` = neutral gray, `postponed` = amber, `cancelled` = solid red. Include `lifecycle.reasons[0]` as a small subline.
2. **Watchlist row + Movers list**: small dot or strikethrough on rows where the event is non-active. Tooltip shows the reason.
3. **Portfolio header**: when `inactive_excluded_count > 0`, show "N ghost events hidden" with a "Show all" link that re-fetches with `?include_inactive=true`.

**Why**: 18% of future events in our system are ghosts (eliminated playoff brackets). Without this badge a broker can scan the watchlist and waste time triaging events that won't happen. Knowing at-a-glance which events are actually playable is critical.
**Backend ready**: yes — the lifecycle data is live as of `<sha pending>`. Just consume it.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Splits inventory panel needs a glance-readable design

**What**: The chart already exposes `splits_min_q`, `splits_pct_pairs`, `splits_pct_singles`, `splits_with_singles..4plus`. The event page has a Splits Inventory panel but it's currently a bare table. Redesign to make "what splits are out there RIGHT NOW" answerable in <2 seconds.

**Why**: Splits are the difference between "this listing is buyable" and "this is a 6-pack only stadium tier" — brokers need to triage at a glance.
**Files**: `static/index.html` (search for "Splits Inventory")
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Event hero needs a "TIL EVENT" countdown

**What**: Top of event page shows home/away logos, venue, date. Add a prominent days-hours-minutes countdown to game time, color-shifted as it gets close (>14d gray, 7d-14d soft, 1d-7d accent, <24h hot). Updates live in-page.

**Why**: Time-to-event drives the entire collect-listings cron tier (20m / 1h / 4h / 12h / daily) — brokers think in event-proximity, the UI should too.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Watchlist 3-tab needs a sort persistence story

**What**: Watchlist tabs (mine / movers / gametime) lose sort state on tab switch. Persist `sortBy` + `sortDir` per tab in localStorage with versioned key.

**Why**: Brokers customize sort by tab (mine = my-positions-by-cost-basis; movers = absolute change; gametime = chronological). Forcing them to re-pick on every tab is annoying.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Update get_performers_by_league RPC to filter ghost events

**What**: `/api/broker/performers/by-league/{league}` now accepts `?include_inactive=` but the underlying SQL RPC (`get_performers_by_league`, mig 20260508050000) aggregates over ALL events including ghost playoff brackets. Rewrite the RPC to JOIN against `event_lifecycle` and exclude `is_active=false` rows when the new `p_include_inactive` arg is false.

**Why**: A team like Boston Celtics gets aggregate `home_events=8` from all the speculative Round 2/3/Finals home games even though they're eliminated. Should be `home_events=2` (the actual played games). Currently the API response includes `_inactive_filter_applied: false` so the frontend can flag the discrepancy.

**Files**: `supabase/migrations/<new>.sql` + matching update in `app.py` to pass through `p_include_inactive`.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Investigate listings_snapshots index for zone backfill timeout

**What**: `backfill_stale_zone_metrics` has been timing out at 120s pre-cascade. Check whether `(event_id, captured_at, is_ancillary)` index exists. Add if missing. Re-run a 50-batch test to confirm we can fold zone backfill back into the master cascade.

**Why**: Currently zones runs on a separate slower cron (jobid 39, batch=5) which is below historic throughput. An index could let us collapse it back into the 2-min cascade.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Replace league→slug CASE with a lookup table

**What**: `auto_link_event_xref` currently has a hardcoded CASE mapping NBA→`basketball/nba`, NFL→`football/nfl`, etc. Create a `league_slug` table; reference it from the function.

**Why**: SeatGeek migration will need multi-source slug mapping. Hardcoded CASE blocks that.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Fix `is_baseline` detection in espn-collect

**What**: NBA/NFL/MLS/WNBA/WC always return `is_baseline=true` from `espn-collect.roster`. Only MLB+NHL detect changes correctly. Means injury-change overlays only render markers for 2 of 7 leagues.

**Why**: User reported NBA injuries didn't show as overlays. Root cause is upstream content_hash logic skipping the change-detection branch for those 5 leagues.
**Files**: `supabase/functions/espn-collect/index.ts`
**Filed by**: code · 2026-05-09 (carried over from prior session)

---

### NEXT (code) — Extend `espn-collect.gameday` scope to MLS/NHL/NFL/WNBA/WC

**What**: Currently only iterates NBA + MLB events. Means MLS/NHL/NFL/WNBA/WC have full performer-level coverage but ZERO event-level snapshots/xref. ~80% of the cross-league data gap.
**Files**: `supabase/functions/espn-collect/index.ts`
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Capture 6 MCP-applied migrations into prod migration ledger

**What**: 6 migrations (20260508220000 through 20260509040000) have been applied via Supabase MCP `execute_sql` and captured as files in `supabase/migrations/`, but the prod migration ledger doesn't list them. Run `supabase db push` (or equivalent) to reconcile.

**Why**: Drift detection (sync-check.sh) flags this on every run.
**Filed by**: code · 2026-05-09

---

## BLOCKED

_(none currently)_

---

## DONE (last 10)

### DONE — `<sha pending>` · feat(events): lifecycle classifier sorts ghost playoff games out of live surfaces
- New SQL fn `derive_event_lifecycle(event_id)` + view `event_lifecycle`. Status enum `active | ghost_eliminated | completed | postponed | cancelled`. Strongest signal: TEvo `last_seen` staleness (live=avg 1.0h, ghost=avg 133h, zero overlap). Wired into `/api/broker/event/{id}/overview` (lifecycle block), `/api/broker/movers` (`?include_inactive` defaults false), `/api/portfolio` (per-event lifecycle + `inactive_excluded_count`). Distribution: 1045 active / 95 completed / 89 ghost / 2 postponed / 1 cancelled. Mig `20260509050000`. SCHEMA bumped to v10.
- by: code · landed: 2026-05-09 02:30 UTC

### DONE — `<sha pending>` · feat(cron): cascading 2-min freshness model
- 6 individual freshness crons collapsed into `master-cascade-2min` (jobid 38). ESPN injury/trade cadence 10m → 2m. Worst-case event coverage staleness 50m → 2m. Verified runtime ~150-200ms per tick. Side-fixed `auto_link_event_xref` NOT NULL bug. SCHEMA bumped to v8.
- by: code · landed: 2026-05-09 00:55 UTC

### DONE — `<sha pending>` · fix(chart): pin x-axis to range_meta + Robinhood-style transitions
- Backend now returns `range_meta: {hours, since, until}`. Frontend pins Chart.js x-axis explicitly to that window so 30d view doesn't collapse to 24h when newer series have sparse history. Auto-picks time unit (hour/day) by range. Smooth fade between ranges. Active range button uses `.rng.active` class.
- by: code · landed: pending push (this commit)

### DONE — `999ad3f` · feat(cron): cascading freshness migration committed
- See above for details.
- by: code · landed: 2026-05-09 00:55 UTC

### DONE — `27e20bd` · feat(chart): new default series + bar chart type for quantity
- by: code · landed: 2026-05-08 ~23:30 UTC

### DONE — `c58d6a4` · feat(schema): SCHEMA.md v6 + RULE 1 + midnight sweep cron
- by: code · landed: 2026-05-08

### DONE — `c8af9b8` · fix(chart): range buttons toggle active state via CSS class
- by: code · landed: 2026-05-08

---

## Reference — column conventions

- **NEXT** rows include: What, Why, Files (if known), Filed-by + date.
- **DOING** rows include: What, Files touched (with line range estimate), Status, Started timestamp.
- **DONE** rows include: commit SHA, subject line, by-whom, landed timestamp.
- **BLOCKED** rows: copy of the original DOING content + a `**Blocker**:` line + by-whom-flagged.

If a row sits in DOING for >2 days untouched, code's audit pass surfaces it as a stuck-work flag.
