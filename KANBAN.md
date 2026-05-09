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

### NEXT (design) — TERMINAL REBUILD per docs/terminal-redesign-2026-05-09.md

**What**: User mandate — **rebuild `static/index.html` from scratch** based on what the data actually supports. The full design memo is at `docs/terminal-redesign-2026-05-09.md` and includes:
- 7 page templates (Home / Event detail / Performer / Movers / Cross-source explorer / Order book / Settings)
- 9 findings from data simulations on actual prod data
- Build sequence (Event detail first, then Home, then Movers, etc.)
- Visual conventions, deletion list, open questions

**Why**: Prior `static/index.html` accumulated 3,000+ lines over many iterations. The data shape is now clearer (sports-first, owned_premium_pct should be top-line KPI, mover classification is missing). Cleaner to start fresh than refactor.

**Headliner finding**: `owned_premium_pct` (S4K asks vs competitor asks for the same event) varies from −32% to +255% across our book. It's the single most actionable broker metric and isn't surfaced anywhere right now. Make it the biggest number on the event page.

**Top of the build queue**: Page 2 (Event detail) — that's where 80% of broker time goes. Ship that first with the new owned-premium KPI; the rest follows.

**Backend coverage** (what's already there to support this):
- 822 active sports events with rich tracking (avg 48 snapshots, 7 days price history)
- Cross-source entity maps for clean translation (`entity_event_map`, `entity_performer_map`, `entity_venue_map`)
- All metrics tables populated (TEvo `event_metrics`, `seatgeek_event_metrics`, `seatdata_event_stats`)
- Order books from both TEvo and SG seller-direct
- Lifecycle classifier filters ghost events automatically

**Files**: `static/index.html` (rebuild), referencing endpoints in `app.py`. New endpoints to add are listed in §4 of the redesign memo (5 new routes).

**Filed by**: code · 2026-05-09

---

### NEXT (design) — Cross-source data coverage badge on event hero

**What**: New view `cross_source_event_audit` returns one row per TEvo event with: ESPN id, SeatData event_id + sales_count, SG event_id + listings count + active tickets, EVO orders, lifecycle status. Render this as a 4-light coverage badge on the event hero ("TEvo · ESPN · SeatData · SG"), each light lit per source linked. Plus a popover showing actual counts.

Plus three new chart series powered by `seatgeek_event_metrics`:
- `SG_Cost_Median` (line, $-axis) — our wholesale cost percentile
- `SG_Active_Tickets` (bar, count axis) — our active SG inventory
- `SG_Sold_Quantity` (bar, count axis) — sold SG history

**Why**: At a glance brokers see "we have 3-source coverage on this event" vs "TEvo only — no comp data". Drives decisions about which events deserve deeper attention.
**Backend ready**: yes — view + metrics table both populated by master cascade every 2 min.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — SeatGeek Seller Direct: S4K inventory + sales overlay

**What**: SG Seller Direct integration is live (commit *pending*). Cron `seatgeek-seller-collect-10min` (jobid 41) pulls 1000 listings + paginated orders every 10 min from `sellerdirect-api.seatgeek.com`. Every row carries inline event metadata, so `seatgeek_event_xref` auto-fills via fuzzy match.

UI surfaces to add:
1. **"S4K on SG" panel on event hero**. `GET /api/seatgeek/event/{tevo_id}/seller-listings` returns our active SG listings for the event with summary (count, tickets, median cost). Show as a small dense panel: "S4K SG: 12 listings · 47 tix · median cost $89".
2. **Realized SG sales chart series**. `GET /api/seatgeek/event/{tevo_id}/seller-orders` returns persisted orders with state breakdown. Add a new chart series `SG_Orders_Confirmed` (bar, hourly) — direct visibility into our SG sales velocity, parallel to TEvo's evo_orders.
3. **Cross-source sale comparison**. Combine: TEvo evo_orders (our TEvo sales), SG seller_orders (our SG sales), SeatData sales (whole-market sold comps), TEvo evo asks (current asks), SG seller_listings asks. That's 5 series for a single event — dense but each has a distinct color/dash convention.
4. **Auto-link status badge**. `GET /api/seatgeek/seller-status` reports auto-link rate. Surface on a settings page: "SG events seen: N, auto-linked to TEvo: M". When auto-linked stalls or fails, badge goes amber.

**Why**: This is the deepest data we have. SG Seller Direct gives us OUR actual transactions on SG, not market-wide aggregates. Combined with TEvo /v9/orders we now have the full S4K sales pipeline on both marketplaces.
**Backend ready**: yes — cron firing every 10 min, 200 listings + 400 orders already persisted from initial test pulls.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — SeatGeek BROKER DATA: marketplace listings + sold-comp overlay

**What**: SG integration is now the **broker** data API (not public). Three high-value UI surfaces:
1. **SG marketplace overlay** on the chart workbench. `GET /api/seatgeek/event/{id}/listings?latest_only=true` returns ALL secondary listings on the SG marketplace (when v2 was used). Plot as a scatter overlay alongside TEvo asks — gives brokers cross-marketplace visibility (TEvo asks vs SG marketplace asks).
2. **SG sold-comp panel** on the event hero. `GET /api/seatgeek/event/{id}/sales` returns transacted broadcast (wholesale) prices. Pair with SeatData's retail-side sold prices — together that's the full "what's actually clearing" view.
3. **Match button + manual link**. Broker API has no search endpoint. Show a "Link to SeatGeek" button when `seatgeek_event_xref` is empty; opens a small input that POSTs `/api/seatgeek/event/{tevo_id}/link?sg_event_id=N`. The user pastes the SG event_id from their SG broker portal (or any SG URL) once per event.
4. **"We are the marketplace" indicator**. `seatgeek_listings_snapshots.is_broker_owned=true` flags listings posted by THIS account. Surface as a badge: "S4K is N of M listings on SeatGeek".

**Why**: SeatGeek + TEvo + SeatData together give us 3-source coverage. SG is the only source that exposes BOTH our listings AND competitor listings on the same marketplace. The `sglid` (SeatGeek Listing ID) gives us cross-source listing linkage if we ever want to compare the SAME listing across exchanges.
**Backend ready**: yes — `POST /api/seatgeek/event/{tevo_id}/link?sg_event_id=N` then `POST /sync-listings` (with `?v2=true` for full marketplace) and `POST /sync-sales`.
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

### DONE — `<sha pending>` · feat: cross-source entity maps (universal id translator)
- 3 views (entity_event_map / entity_performer_map / entity_venue_map) translate any source's id to all others, TEvo as hub. 6 translation functions (forward + inverse, both directions). taxonomy_xref table seeded with 12 league/type mappings (NBA, MLB, etc.). cross_source_coverage diagnostic view. Live coverage: 269/1233 events on ESPN, 37 multi-source performers, 21 SG-linked venues. All round-trips verified. Mig 20260509120000. SCHEMA v17.
- by: code · landed: 2026-05-09 03:30 UTC

### DONE — `e7e680f` · feat: SG metrics + xref + cascade + RULE 2 read-only
- Mig 20260509110000. New tables: seatgeek_performer_xref (102 auto-linked from listings/orders), seatgeek_venue_xref (21), seatgeek_event_metrics (28 cols parallel to event_metrics + seatdata_event_stats). New views: seatgeek_categorized_listings, cross_source_event_audit. Smart matcher fix prevents ghost-event mismatches (Lynx→Timberwolves bug fixed). master_cascade_2min extended with SG xref + metrics stages (1.7s total runtime). RULE 2 read-only enforcement at code level (HTTP method allowlist in evo/seatdata/seatgeek clients). Cross-source audit shows Knicks G5 with TEvo+ESPN+SeatData coverage (3 sources, 254 sales). SCHEMA v16.
- by: code · landed: 2026-05-09 03:15 UTC

### DONE — `c3762f5` · feat(seatgeek): seller-direct ingest with auto-xref via inline event metadata
- Added 2nd SG broker host (`sellerdirect-api.seatgeek.com`). Probe revealed /listings (157,846 active S4K), /orders?status= (496K fulfilled lifetime), /order single. Migration 20260509100000 adds seatgeek_seller_listings + seatgeek_orders + order_tickets + pull_log + sg_attempt_event_xref RPC + seatgeek_orders_by_event view. Each row carries inline event metadata → fuzzy match to TEvo on (date, venue) auto-fills xref. Live test: page-1 listings = 200 rows, 25 distinct SG events, 2 auto-linked to TEvo. Cron seatgeek-seller-collect-10min (jobid 41) every 10 min, pulls 5×200 listings + 4 status filters of orders. Page=N is deprecated; client uses page_cursor pagination. SCHEMA v15.
- by: code · landed: 2026-05-09 03:00 UTC

### DONE — `089c9a8` · refactor(seatgeek): scrap public-API, rebuild for BROKER DATA API
- v13 used wrong host (api.seatgeek.com/2 with ?client_id=). Token is actually for brokerdata.seatgeek.com with ?token=. Mig 20260509090000 drops 5 unused tables, rebuilds around event_xref/listings_snapshots/sales_snapshots/pull_log + event_latest view. Client + 6 routes rewritten for /listings, /v2/listings, /sales (purchases scope unavailable). Live diag: 400 "No event found" on bogus event_id (auth pass), 401 on /purchases (covered by TEvo /v9/orders). SCHEMA v14.
- by: code · landed: 2026-05-09 05:00 UTC

### DONE — `4c9641f` · feat(seatgeek): integration scaffolded — section_info + recommendations + xref
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
