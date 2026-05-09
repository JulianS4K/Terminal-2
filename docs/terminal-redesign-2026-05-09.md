# Terminal redesign 2026-05-09 — what the data says we should build

> **Audience**: design coworker, future code agent.
>
> **Mandate**: prior `static/index.html` is obsolete. Rebuild from scratch using what we now know about the data we're actually collecting.
>
> **TL;DR**: this is a sports-broker terminal. Sports = 822 active future events vs 115 concerts (and concerts have basically no metric depth). Build sports-first, with concert support as a secondary tier. The single most important number on every event page is **`owned_premium_pct`** — how our asks compare to competitor asks — which currently isn't surfaced anywhere.

---

## 1. What we have (data inventory, 2026-05-09)

### Event coverage

| event_type | active future | with metrics | within 7d | within 30d |
|---|---:|---:|---:|---:|
| **game** | 822 | 382 (47%) | 94 | 553 |
| concert | 115 | 1 (~0%) | 1 | 8 |
| null | 95 | 14 (15%) | 0 | 26 |

### Market exposure (active sports, latest snapshot)
- **564,002 active market tickets** across our tracked sports book
- **60,160 S4K-owned tickets** in active future events
- Median tracked event has **48 metric snapshots over ~7 days** of price history (max 366 over 14 days)

### Cross-source matching (RULE 1 + entity_event_map)
- ESPN: 269 of 1,233 events linked (22%)
- SeatData: 1 event manually linked (Knicks G5)
- SeatGeek seller: 1 event auto-linked, 39 performers, 21 venues
- Multi-source: 37 performers, 1 event

**Implication**: ESPN context is reliable for sports. SeatData + SG cross-comparisons only land for events brokers explicitly trigger or where our SG inventory happens to overlap. Build the UI to gracefully degrade — show what's available, flag what's missing.

---

## 2. Findings that should drive design

### 🟢 Finding 1 — Price decay isn't monotonic
Median sports retail goes **$370 (3-7d out) → $195 (1-3d) → $356 (6-24h) → $251 (<6h)**. Brokers face a non-trivial decision: dump now or hold for the final-stretch bounce. Inventory drops 70%+ in the last 6 hours.

**Surface as**: a "decay curve" visualization on the event hero, showing where the current price sits in the historical decay band. Plus a "Time-to-event" countdown that flips color/weight as it crosses thresholds (>14d / 7-14d / 1-7d / <24h / <6h).

### 🟢 Finding 2 — `owned_premium_pct` varies wildly per event
Real numbers from current book (`owned_median_retail` vs `nonowned_median_retail`):

| Event | Owned share | Owned premium |
|---|---:|---:|
| Lakers G5 | 50.8% | **+59%** |
| Knicks G5 | 49.9% | **−26%** |
| Knicks R3-G1 | 41.4% | **−32%** |
| Yankees–Pirates | 23% | +7% |
| Tigers–Yankees | 22.5% | +12% |
| **Pistons (perf-level avg)** | 30% | **+255% (!)** |

Negative premium = we're leaving money on the table. Big positive = our asks may not clear. **This number isn't surfaced anywhere right now.**

**Surface as**: top-line KPI on every event page. Color-coded: green (−10% to +15% sweet spot), amber (+15-30% or −10 to −20%), red (>+30% or <−20%). Hover shows the full breakdown.

### 🟢 Finding 3 — Inventory loading is asymmetric
Over 7 days (175 events with both T-7d and T-now snapshots):
- Market tickets: **+45% avg** — supply growing
- S4K-owned tickets: **+767% avg** — we're loading aggressively
- Retail median: −0.1% (flat)
- 69 events dropped 5%+ vs 37 rose 5%+ (downward bias)

S4K is buying inventory faster than the market is digesting. This is a risk-management view — we need a "position growth rate" panel.

**Surface as**: Movers panel (already exists) + new "Inventory growth heatmap" showing per-performer 7d position change. Red cells where we're loading into a softening market.

### 🟢 Finding 4 — S4K position concentration
**Knicks book = $20.4M notional** (5,088 owned tickets × ~$3,950 avg retail). Yankees book is 28K tickets but only $3.3M (cheap regular-season MLB). Lakers $2M. The whole rest of the book is a long tail.

Knicks are 40% of total notional risk. A single team's playoff outcome moves the entire book.

**Surface as**: home-page "Position concentration" card — per-performer notional, share of total book, lifecycle status of their next 5 events. Click drills into per-event view.

### 🟢 Finding 5 — Three distinct "mover" types
Not all 5%+ price moves mean the same thing:
1. **Supply flood**: +4,000 tix, prices −32% (someone listed a season's worth — Chiefs/Raiders example)
2. **Re-pricing event**: +15 tix, prices halved (someone matched the market without inventory change — Chiefs/Broncos)
3. **Ghost re-pricing**: bracket clarifies, ghost-event prices crash 45% (Pistons playoff brackets after their elimination)

Current Movers panel doesn't distinguish these. They demand different actions: flood = wait for the floor; re-pricing = check the market disagrees with you; ghost = filter out (lifecycle classifier already does this if `is_active=true`).

**Surface as**: Movers panel with a "Read" column that classifies each row using these three buckets + the existing patterns (supply dump, demand spike).

### 🟢 Finding 6 — Sports inventory is pair-friendly, but with structure
Avg sports event: 88.5% pairs available, 39.7% singles available, min split = 1.86. Per-event distribution: ~145 listings with singles, ~298 with pairs, ~145 with 3+. The "pair median" is the buyable one — singles often clean themselves up late.

**Surface as**: Splits panel on event page (already exists per KANBAN NEXT row, but rebuild) showing the 3-bucket distribution as a density bar, with "buyable now" floor highlighted.

### 🟡 Finding 7 — Cross-source data is sparse but valuable when present
Knicks G5 has TEvo + ESPN + SeatData + lifecycle (3 sources, 254 historical sales pulled from SeatData at $668 median sold price vs $987 TEvo retail median = **34% spread between asks and sold**).

Most events don't have this depth. But where we have it, the spread vs asks tells us whether our pricing is in the actual transaction band.

**Surface as**: small cross-source coverage badge on event hero (4 lights: TEvo / ESPN / SeatData / SG, lit per source matched) plus, when SeatData is linked, a "vs sold" line on the chart.

---

## 3. Recommended terminal architecture

### Page 1: Home (replaces current /)

**Above the fold**:
1. **Position concentration card** — top 5 performers by notional, total book size, today's mark-to-market change
2. **Top movers strip** — 6 horizontal cards (winners 3 / losers 3) by notional Δ in last 24h, with the "Read" classification
3. **Coverage band** — 822 active sports / 553 within 30d / 94 within 7d / N today, with a "Today's events" jump-to button if N > 0
4. **Risk alerts** — events where (a) owned_premium_pct > +30% AND days_to_event < 7, or (b) hold_expires_at < 1h on an EVO order

**Below the fold**:
- League tabs (NBA / NFL / MLB / NHL / MLS / WNBA / Concert) with per-league rollup
- Watchlist (3 tabs: mine / movers / gametime — keep current pattern, just redesign)
- Search box with typeahead

### Page 2: Event detail (replaces current /event/{id})

**Hero band** (top of page):
- Home/away logos + venue + countdown to gametime (color-shifted by proximity)
- **`owned_premium_pct` KPI** — biggest, boldest number on the page
- Lifecycle status badge (active / ghost / completed / postponed)
- Cross-source coverage 4-light badge
- Quick-action row: link to /event/{id}/raw-tevo for full ticket browse, sync buttons for SeatData + SG when applicable

**Chart band** (~40% of page height):
Default series:
- `EVO_Get-in ($)` — yellow line
- `EVO_Market median (all)` — blue line
- `EVO_Owned median (S4K)` — green dashed line
- `EVO_Market not S4K median` — purple line
- `EVO_Quantity available (mkt)` — orange bars on right axis
- `EVO_Most common split qty` — gray line
- (when linked) `SD_Sold median` — red dashed line
- (when linked) `SG_Cost median` — teal dashed line
- Range selector: 6h / 24h / 3d / 7d / 30d / ALL

**Data band** (below chart):
- **3-column layout**:
  - Col 1: **KPI grid** (24 metrics: tickets/groups/sections/percentiles/wholesale/structure/owned/splits)
  - Col 2: **Zone breakdown** (curated > fallback > unmapped, single source)
  - Col 3: **Splits inventory** + ESPN context (when linked: standings, injuries, last-5)

**Order/sales band** (below data):
- **EVO order book strip** — 5-segment bar showing pending/accepted/rejected/completed/pending_sub for THIS event
- **SeatData sales tape** (when linked) — last 20 sold rows from `seatgeek_sales_snapshots` and `seatdata_sales_snapshots`
- **Recent big moves** detector — snap-over-snap ≥3% / ≥100 tix swings

### Page 3: Performer detail (NEW)

Currently a button on event page. Promote it to first-class.

- Hero: team logo, league, home venue, ESPN badge
- Per-performer rollup: total active events, owned tickets, owned book notional, avg owned premium
- Per-event mini-cards: each upcoming event with cur-retail / cur-owned / 24h Δ
- Recent injuries (ESPN) + roster moves (ESPN)
- News feed (ESPN)
- Cross-source xref (entity_performer_map)

### Page 4: Movers report (replaces current /movers)

- 4 windows: 1h / 6h / 24h / 7d
- Filter by: event_type, league, performer, lifecycle.is_active
- Row classification: SUPPLY_FLOOD / RE_PRICING / GHOST_RESOLVE / DEMAND_SPIKE / DUMP
- Sort by: % retail change, absolute notional change, owned share, days_to_event
- Row click → event detail

### Page 5: Cross-source explorer (NEW)

For data ops + research, not regular trading.

- Coverage stats (`cross_source_coverage` view): per-entity-type linkage rates
- Bulk auto-search button to trigger SG + SeatData matching for unlinked events
- Translation playground: enter any source's id, see all others
- Pull-log diagnostics: recent SG / SeatData / ESPN call counts + errors

### Page 6: Order book / Sales pipeline (NEW)

S4K's own actual sales activity. Currently buried in the API.

- Pending TEvo orders queue (from `evo_orders`)
- Recent sold (last 30d): TEvo + SG seller-orders combined
- E-ticket fulfillment alerts (any item with `eticket_available=true AND eticket_downloaded_at IS NULL` for an event within 48h)
- Hold-expiry urgency (any `hold_expires_at < NOW() + 1h`)
- Realized vs ask analysis (sold price vs `listings_snapshots.retail_price` at sale time)

### Page 7: Settings / Watchlist management

Lightweight. Add/remove watchlist entries, see chat-tracked-only filter, manual SG event_id linker for events not auto-matched.

---

## 4. New API endpoints needed

Most of what these pages need already exists. Net-new endpoints:

| route | purpose |
|---|---|
| `GET /api/broker/home` | NEW — combined home-page payload (top movers, position concentration, alerts, coverage band) |
| `GET /api/broker/movers/classified` | NEW — Movers with the 5-bucket classification |
| `GET /api/broker/performers/{id}/detail` | NEW — promotes the existing `/api/portfolio?performer_id=` to a richer first-class endpoint |
| `GET /api/broker/orders/sales-pipeline` | NEW — combined TEvo + SG order book + alerts |
| `GET /api/broker/cross-source/explorer` | NEW — coverage + translation playground |

Existing endpoints stay:
- `/api/broker/event/{id}/overview`, `/chart-data`, `/zones`, `/section-zones`, `/section-metrics`, `/orders`, `/espn`
- `/api/cross-source/event/{id}` (now the canonical source via `entity_event_map`)
- `/api/seatdata/event/{id}/*`, `/api/seatgeek/event/{id}/*`

---

## 5. Visual conventions

- **Dark theme only**. Terminal users don't want light mode.
- **Wide-screen optimized** (1440px+). No mobile responsiveness goal for the broker terminal.
- **Densely-packed grids**. Bloomberg/Robinhood hybrid — facts dense, action big.
- **CSS variables for theming**: `--surface`, `--surface-2`, `--border`, `--text`, `--dim`, `--accent` (yellow for primary), `--pos` (green), `--neg` (red), `--warn` (amber).
- **Number formatting**: `$1,234.56` for money, `1,234` (no decimals) for counts, `+12.3%` for changes.
- **Color coding**: positive = green, negative = red, warning = amber, neutral/dim = gray.
- **Time formatting**: relative when recent ("3h ago", "yesterday 4 PM"), absolute when farther ("Apr 24"). The chart range polish KANBAN row already specs this.

---

## 6. What to delete from the prior `static/index.html`

The current file is ~3,000 lines accumulated over many iterations. Per the user's mandate, **start fresh**. Specifically don't carry over:

- The legacy chart workbench (good ideas, messy implementation)
- The 17-bucket pill grid (replace with the 6-page structure above)
- Hard-coded color hex values scattered throughout (use CSS variables)
- Inline event handlers (use `addEventListener` consistently)
- The `_autoDiscoverSeries` magic (keep — it's the feature)
- The localStorage versioning pattern (keep — bump key suffixes when defaults change)

---

## 7. Build sequence (suggested)

If I were building this, I'd ship in this order to maximize early value:

1. **Page 2 (Event detail)** — that's where 80% of broker time goes. Ship with the new `owned_premium_pct` KPI as the headliner.
2. **Page 1 (Home)** — once event detail is solid, the home page can deep-link cleanly.
3. **Page 4 (Movers)** with the 5-bucket classifier — relatively isolated, easy to ship.
4. **Page 6 (Order book)** — high-value but depends on EVO orders cron filling.
5. **Page 3 (Performer detail)** — important but lower urgency.
6. **Page 5 (Cross-source explorer)** — internal/ops, ship last.
7. **Page 7 (Settings)** — roll into earlier pages as inline controls; standalone page is optional.

Each page is testable in isolation. Don't try to ship a "v1 of everything" — ship Page 2 first, iterate.

---

## 8. Open questions for the design coworker

- **Information density vs scannability**: how many metrics on the event page before it becomes an eye chart? Suggest hiding behind progressive-disclosure (collapsed by default, click to expand).
- **Default chart range**: I'd suggest 7d. Long enough to show meaningful trends, short enough that the bars aren't too smushed.
- **Mobile?**: I assumed broker terminal = desk-only. If we need mobile, scope it as a separate read-only "view" mode.
- **Color-blind safe palette?**: green/red is the convention but consider amber/blue alternatives for accessibility.
- **Animation budget**: Robinhood-style smoothness is valuable but expensive. Suggest 320ms ease-out as the cap; no spinning loaders.

---

## 9. References — the data behind every recommendation

- **Inventory totals**: `events`, `event_metrics` (cron-collected, 5-tier cadence)
- **Owned premium**: `event_metrics.owned_median_retail` − `nonowned_median_retail` (mig 20260509030000)
- **Lifecycle**: `event_lifecycle` view + `derive_event_lifecycle()` (mig 20260509050000)
- **Movers**: `event_movers` RPC (mig 20260508040000) + the 5-bucket classifier added in Page 4 spec above
- **Splits**: `event_metrics.splits_*` columns (mig 20260508230000)
- **Cross-source**: `entity_event_map` / `entity_performer_map` / `entity_venue_map` views (mig 20260509120000)
- **Order book**: `evo_orders` + `evo_order_items` + `seatgeek_orders` + `seatgeek_orders_by_event` view
- **SeatData sales**: `seatdata_sales_snapshots` + `sd_sales_normalized` view (canonical zones)
- **SG seller**: `seatgeek_seller_listings` + `seatgeek_categorized_listings` view + `seatgeek_event_metrics`
