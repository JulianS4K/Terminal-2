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

### DOING (design) — _none yet_
_(append your work-in-progress here)_

### DOING (code) — _none yet_
_(if I'm in the middle of something, it goes here so design knows what files I'm touching)_

---

## NEXT

### NEXT (design) — orient and pick a starter task

**What**: Read `COWORKER_ONBOARDING.md` end-to-end, then pick a row below.
**Filed by**: code · 2026-05-09

---

### NEXT (design) — SeatGeek: section overlay + related events panel

**What**: SeatGeek integration is live. Two UI surfaces unlock high-value workflows:
1. **Section layout overlay** on the event detail page. `GET /api/seatgeek/event/{id}` returns `sections` (canonical seat layout from SG: `{section_name: [row, row, ...]}`). Overlay this onto the existing zone breakdown panel — color sections by current TEvo retail_median, click section to drill into its listings. SG's section_info gives us the canonical "what sections exist at this venue", which complements our derived zone system.
2. **Related events panel** on the event hero. `GET /api/seatgeek/recommendations/by-event/{event_id}` returns affinity-scored recommended events from SG. Show top 5 with title + date + venue + score. Click → adds to watchlist or opens that event in the terminal.
3. **Sync buttons** on the event page: "Pull section info" (`POST /sync-sections`), "Pull recommendations" (`POST /sync-recommendations`). Both are FREE (no SeatGeek charge) — just throttle to once per session per event.
4. **Performer hero images** — `seatgeek_performer_xref.sg_image_url` has SG's "huge"/"large" performer image. Use as fallback when our existing performer_metadata image is missing. Pull on-demand via auto-search.

**Why**: SG's section_info is the cleanest "ground truth" for venue layouts we have. Recommendations are how brokers find events to watchlist next without manual search. Both replace string-similarity workarounds.
**Backend ready**: yes — call `POST /api/seatgeek/event/{id}/auto-search` on any event to link, then read with `GET /api/seatgeek/event/{id}`.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — EVO orders: hero strip + chart series + e-ticket alerts

**What**: TEvo `/v9/orders` is now ingested every 10 min into `evo_orders` + `evo_order_items`. Three UI pieces unlock high-impact broker workflows:

1. **Order-book strip on event hero** — compact 5-segment bar showing pending / accepted / rejected / completed / pending_substitution counts pulled from `GET /api/broker/event/{id}/orders`. Click → side panel with the raw rows.
2. **Chart series `EVO_Orders_Completed`** — bar chart on `yC` axis, hourly buckets. The purest signal of demand for our specific inventory.
3. **E-ticket fulfillment alerts** — top-of-dashboard red banner if any item has `eticket_available=true AND eticket_downloaded_at IS NULL` for an event within 48h. The whole dashboard should pulse red until it's cleared.
4. **Hold-expiry alerts** — yellow badge on event tiles where `hold_expires_at < NOW() + 1h`.

**Why**: We've been flying blind on our own order book. Brokers waste time reconciling between the TEvo dashboard and our terminal; this brings the order state inline with the pricing data they're already looking at. The e-ticket alerts in particular catch deliverability misses BEFORE the buyer complains.

**Backend ready**: yes — cron jobid 40 firing every 10 min as of `<sha pending>`. `GET /api/broker/event/{id}/orders` returns `{ items, orders, summary: { total_items, by_state, tickets_sold, gross_sold, last_update_at } }`.
**Reference**: `docs/data-sources-terminal-uses.md` §5 has all 7 UI ideas worked out.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Render SeatData sales overlay on the chart workbench

**What**: SeatData integration is live (commit *pending*). For any TEvo event linked to SeatData, `/api/seatdata/event/{tevo_event_id}/sales` returns up to 5000 historical sale rows: `{sale_timestamp, quantity, price, zone, section, row}` plus an aggregated `summary: {avg, median, min, max, tickets_total, zones, first_sale, last_sale}`.

UI surfaces:
1. **Chart workbench** — add a new togglable series category "SeatData_Sales" (paint as scatter dots, not line). Each dot is a transacted sale; size = quantity, color = zone. Hover tooltip shows `$price · qty · section · row`. Y-axis = `y$` (same as TEvo prices).
2. **Event hero** — small badge "SeatData: 254 sales · median $668 · last sold 14m ago" pulled from the summary. Click opens a side panel with the sale list.
3. **Sync button** — manual "Refresh sales" button on the event page that POSTs `/api/seatdata/event/{id}/sync-sales` (charges 1 pull). Disable with tooltip if `/api/seatdata/budget` says budget is exhausted.
4. **Splash for unlinked events** — when `/api/seatdata/event/{id}` returns `linked:false`, show a "Match this event to SeatData" button that POSTs `/auto-search`.

**Why**: TEvo gives us asks; SeatData gives us actual transactions. Brokers price against transacted comps, not asks. This is the most actionable signal we've added since the chart workbench itself.
**Backend ready**: yes — Knicks G5 (TEvo 3345925) is pre-populated with 254 rows for visual testing.
**Files**: `static/index.html`
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

### BLOCKED (design) — Polish the chart range switcher

- **What**: Removed `color` from the `.rng` transition (was the source of the activate flash); added `[` / `]` keyboard stepping (one-shot global listener that respects input focus and clamps at the ends); added a Chart.js crosshair plugin + switched the tooltip to `mode:'index'` so all visible series values render at the snapped x; added a relative-time `title` callback ("3h ago", "yesterday 4 PM", "Apr 24") replacing the long ISO.
- **Files touched (already on disk, not yet reviewed/committed)**: `static/index.html`
  - CSS: ~lines 88-101 (`.rng` transition + new `:focus-visible` outline)
  - JS keyboard wiring: ~lines 1726-1755 (`_wireRangeKeyboard` + call from `_wireRangeButtons`)
  - JS chart helpers: ~lines 1830-1888 (`_formatRelativeTime`, `_evtChartCrosshair` plugin)
  - JS tooltip config: ~lines 2065-2080 (`mode:'index'` + `title` callback)
  - JS chart constructor: ~lines 2147-2151 (register `_evtChartCrosshair` locally, not globally)
- **Blocker**: paused by Julian — hold review/commit until he gives the go-ahead. File edits remain in the worktree; nothing has been pushed.
- **Started**: 2026-05-09 02:15 UTC
- **Flagged by**: design · 2026-05-09

---

## DONE (last 10)

### DONE — `<sha pending>` · feat(seatgeek): integration scaffolded — section_info + recommendations + xref
- 3rd data source. Metadata + discovery only (no pricing). Mig 20260509080000 adds `seatgeek_event/venue/performer_xref`, `seatgeek_taxonomies`, `seatgeek_event_sections`, `seatgeek_recommendations`, `seatgeek_pull_log`, `upsert_app_secret(name, value)` RPC. New `seatgeek_client.py` covers all 9 SG endpoints. 6 new `/api/seatgeek/*` routes. Awaiting SEATGEEK_API_TOKEN push to Vault before live test. SCHEMA bumped to v13.
- by: code · landed: 2026-05-09 04:30 UTC

### DONE — `914d846` · feat: vault for keys + SeatData↔TEvo mapping + EVO orders 10-min cron
- (a) Supabase Vault stores `SEATDATA_API_KEY`; `get_app_secret(name)` RPC reads it. seatdata_client uses vault by default. (b) New cross-source xref tables (venue/performer/zone/section) + `normalize_sd_listing()` function + `sd_sales_normalized` view fixing the SeatData quantity-null caveat. (c) TEvo `/v9/orders` ingested every 10 min: `evo_orders`, `evo_order_items`, `evo_orders_by_event` view; cron jobid 40. New routes: `POST /api/admin/collect-orders`, `GET /api/broker/event/{id}/orders`. EvoClient gained `list_orders`/`iter_orders`/`get_order`. (d) Bucket 18 added to taxonomy. Comprehensive memo at `docs/data-sources-terminal-uses.md`. Mig `20260509070000`. SCHEMA v12.
- by: code · landed: 2026-05-09 04:00 UTC

### DONE — `0582fac` · feat(seatdata): integration live + Knicks G5 sales pulled (254 rows)
- New second-source pricing API alongside TEvo. Hard-capped to BASIC plan budget (100/day, 2000/month) at the DB level. New `seatdata_client.py` + 7 `/api/seatdata/*` routes. Live-tested on TEvo 3345925: matched to sd_event_id=1247184, pulled 254 historical sales (median $668, avg $773, range $378-$3,756). Mig `20260509060000`. SCHEMA v11. **User action required**: set `SEATDATA_API_KEY` env var on Railway.
- by: code · landed: 2026-05-09 03:00 UTC

### DONE — `dc4c41d` · feat(events): lifecycle classifier sorts ghost playoff games out of live surfaces
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
