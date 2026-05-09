# Non-sports simulations — Concerts / Comedy / Theater (2026-05-08)

> **Audience**: claude design + Julian (code).
>
> **Scope**: this is the FIRST checkpoint of the simulation series Julian asked for. 15 scenarios across 3 non-sports categories (5 each). Sports + edge-case + UI-element sims live in companion docs.
>
> **Inputs that drove this doc**:
> - The pricer CSV (Knicks R2-G3 zone state, 13 zones)
> - The two existing-system screenshots (events grid + tabs / View-by-Zone / Auto Pricer)
> - All prior design + code docs through `terminal-only-redesign-2026-05-08.md`
>
> **Mandate (Julian, 2026-05-08)**:
> 1. 5 sims per non-sports category. ESPN excluded (except athlete-on-tour edge case).
> 2. Future data hooks: Twitter / Reddit / Google Trends / Wikipedia (sentiment + buzz layer that REPLACES ESPN here).
> 3. Cover the full pricer-scope spectrum (event / zone / series-run / venue / category / performer / custom-zone / holistic).
> 4. Surface every UI element relevant to each scenario: tabs, hide/shows, real-time chart overlays (sales tape, news markers, price-move dots), custom zones.
> 5. Day-trader feel, not catalog-shopper.

---

## 0a. Data reality 2026-05-08 (calibration after Supabase pass)

Three corrections to the assumptions baked into this doc:

1. **Wikipedia is PRESENT, not future** — `wiki_summary` has 126 performer rows + `wiki_rivalries` has 25 rows. Where this doc says "Wikipedia (FUTURE)", read "Wikipedia (PRESENT, 126 covered) but not yet linked to `events.primary_performer_id`". The xref-to-TEvo is the gap, not the data.
2. **Twitter / Reddit / Google Trends are still future** — no ingest yet. Those callouts remain accurate.
3. **Concert event coverage is sparse**: 130 active concert events vs 445 concert performers in metadata. Most concert performers in our catalog have no upcoming events tracked. Tour-wide sims (C1, C3, T5) work in shape but have a smaller universe of comparable tours than implied.

The 5-per-category sim shapes hold. Coverage is the calibration item, not the design.

---

## 0. TL;DR

The non-sports broker has fundamentally different mental tools than the sports broker:

- **No injury data, no standings, no game-result cliff.** The buzz signal that drives demand is social — Twitter/Reddit/GTrends. Until those land, brokers price off the price + sales velocity itself.
- **Performer is the campaign**, not the team. A tour is the product; individual stops are sub-units.
- **Venue is destiny.** A 200-seat off-Broadway theater prices VERY differently from MSG. Capacity is the overriding context for non-sports.
- **Time-decay is steeper, but more predictable.** Concerts/theater rarely have last-minute spikes — a 7d countdown drift is the norm.

The terminal must support all 15 scenarios below without UI rework — every panel hides/shows based on context, and the saved-search-tab system lets a broker keep 5 of these scenarios open as parallel investigations.

---

## 1. Existing-system context (per the screenshots)

The redesign builds on, doesn't replace, these workflow elements:

| Existing element | Where it lives today | Where it goes in the redesign |
|---|---|---|
| **Multiple saved Pricer tabs** | Top tab bar — "Pricer - [params]" with date+text filters | Top tab bar in the new terminal. Tabs persist per user. Each tab is a parameterized view of any of the 6 surfaces. |
| **Events grid + filters left rail** | Top half of pricer tab | Home / search results — but the inline-filter rail collapses to a top filter bar in the new terminal |
| **Tickets grid + filters left rail** | Bottom half | Inventory section of Event Workbench — same column set, dark-mode skin, and the linked-grid behavior is preserved |
| **Tickets / View-by-Zone / Auto-Pricer sub-tabs** | Inside the bottom half | Same trio of sub-tabs on the Event Workbench inventory section — these are real distinct tasks |
| **"New Zone" top tab** | First-class | First-class action — opens a Custom-Zone editor as a side drawer, not a separate page. Saved zones become rows in View-by-Zone. |
| **"Undelivered Orders" top tab** | First-class | The Undelivered Window we already designed. |
| **AQ Event Name / AQ Short Evt ID** | Columns + filter | Surface as a small "AQ" pill on event headers; filter still available. AQ id space xref'd into entity_event_map (NEW) — TEvo + AQ + ESPN + SD + SG = 5 id systems. |
| **Action shelf**: Open Event, Auto Merge, Sell Tickets, Broadcast/Unbroadcast, Update Sell Prices, Edit Tickets, Open PO, Delete Tickets, Import Barcodes, Export, Split Multi-PO | Bottom of pricer tab | Reproduce as a sticky bottom bar on the inventory section. Action vocabulary stays identical so brokers don't relearn. |
| **Filters above events grid**: Sales Flow / Show Blacklisted / Hide Sold-out / Hide Expired | Top of grid | Same chips on Home + every list view. |
| **3-tier notes** (Notes / Private Notes / Broker Notes) | Per-ticket fields | Same — but rendered in a tabbed accordion inside the per-ticket drawer; clearly labeled by audience. |
| **Per-ticket flags** (Status / Stock / Delivery Method / PDF Status / Barcode Status / Inhand Status) | Filter rail + columns | Same column set in the inventory grid; status pills color-coded. |
| **Pricer flags** (Auto Pricing / Grid Drop / Auto Dump / Auto Price + Variance) | View-by-Zone sub-tab | Reproduced as a 4-checkbox group per zone row + a Variance number. **These are 3 separate "auto" layers, not one switch** — terminology stays. |
| **"@" margin marker** = watched/sticky | Left edge of rows | Same — single-character margin marker. Click to toggle. |
| **Premium zones hand-managed** (Club Gold / Platinum / Courtside) | All auto-flags off | The redesign respects this — zones have a "manual" badge prominently shown when `Auto Pricing = false AND Grid Drop = false AND Auto Dump = false`. |
| **Blank Zone Pricing on some tickets** | Ops gap | Surface as a "needs zone mapping" alert chip in the inventory grid header, with row counts. |

---

## 2. Pricer scope spectrum

Every simulation below specifies which scope it operates at. The 10 levels + 2 cross-cutting dimensions:

| # | Scope | Example |
|---|---|---|
| 1 | **Single zone, single event** | "Repricing Risers 9+ for Knicks G5 only" |
| 2 | **Cross-zone within event** | "All MSG zones for the Madonna Brooklyn night" |
| 3 | **Single event, holistic** | "Everything I know about Madonna 5/13" |
| 4 | **Series / run / multi-night** | "Beyoncé 6-night SoFi residency" |
| 5 | **Tour-wide** | "Eras Tour 47 stops" |
| 6 | **Single venue, all events** | "All concerts at Beacon Theater next 30d" |
| 7 | **Single category, holistic** | "All Broadway runs in our book" |
| 8 | **Single performer, all events** | "Hamilton — every production worldwide" |
| 9 | **Brokerage roll-up** | "What's our total non-sports book risk?" |
| 10 | **Fixed-allocation across multiple events** | Same 4 physical seats × 81 Yankees home games (season tickets); same Center Orch pair × all 5 nights of a residency |
| **+** | **User custom zone** (cross-cutting) | "Front 10 rows + GA standing across all my Beyoncé stops" — analytical cut, not a section |
| **+** | **Inventory-mix mode** (cross-cutting) | "All Yankees season tickets" / "Random scattered Yankees" / **"Mix of both"** — the most common reality |

### 2.1 The inventory-vs-event relationship is many-to-many

This deserves its own framing because it changes the data model AND the UI:

- **Fixed allocation** (e.g. season tickets): one physical seat allocation = N event records. Cost basis is the season package price ÷ N games. Pricing is per-event, but inventory constraint is "do we still hold this allocation across all N games?"
- **Random inventory**: each ticket record is independent — bought from a scattered source, no relationship across events.
- **Mix** (the realistic case): a broker holds 4 Yankees seats × 81 games (season ticket) PLUS scattered Yankees buys from secondary purchases. Pricing decisions affect both, but inventory constraints differ.

**UI implications**:
- A new **Allocation View** sub-tab on the inventory section. Like View-by-Zone, but groups by "physical seat allocation" — shows the cross-event timeline of one fixed asset.
- **Per-allocation cost basis** column — the package price ÷ events still held. Drives "minimum acceptable price per game" floor logic.
- **Sold-from-allocation tracking** — if broker has sold 15 of 81 Yankees games for these seats, the remaining 66 events show "allocation 19% sold; 81% remaining at avg $X cost".
- **Bundle-vs-individual decision panel** — the broker can choose to relist the remaining 66 games as a partial season package OR continue per-game pricing. Each strategy has different break-even math.
- **Allocation-aware alerts**: "you've sold the 5 most-valuable home games from this allocation; remaining 76 games skew toward weak opponents — consider package re-bundle."

The data model needs:
- `inventory_allocation` table: id, source (season_ticket_purchase / single_purchase / etc.), original_cost, original_event_count, broker_notes
- Each ticket record gets an `allocation_id` FK
- `allocation_id IS NULL` = random / single inventory
- Aggregate views: per-allocation rollup of remaining events + sold events + cost basis recovered

Several of the simulations below now flag scope as "10 + mix" where the broker realistically holds both fixed-allocation and random inventory side-by-side. The Allocation View is what lets them see those two stacks separately.

---

## 3. Concerts — 5 simulations

### C1 · Eras Tour pricing — full tour, single broker

- **Persona / intent**: tour pricer optimizing nightly across stops. Looking for stops drifting low (sell now) and stops drifting high (hold).
- **Scope**: **5 — tour-wide**
- **Data sources used**: EVO (own + nonowned per-stop), SD (sold-vs-asks per-stop), SG (cost + active per-stop), Twitter (artist mentions volume per-stop, FUTURE), GTrends (search interest per-city, FUTURE), Wikipedia (artist context, FUTURE). NO ESPN.
- **Primary view**: T6 Tour mode. Stop timeline running horizontally. Each stop is a column showing:
  - City / venue / date
  - Current retail median + 7d delta
  - Owned premium %
  - S4K share %
  - Sentiment proxy from sales velocity
  - Sales tape sparkline (last 24h sold count)
- **Tabs / hide-shows**:
  - Tabs: Stops · Stops grouped by region · Cross-stop section comparison · Sales velocity heatmap
  - Hide-show: ESPN row (hidden by default — non-sports), tour-map mini (toggleable), per-stop Twitter sentiment column (toggleable, gray placeholder until wired)
- **Real-time chart overlays**: a bottom strip showing live sales for the current selected stop — each sale appears as a dot on the price line at its sold price + timestamp. New sales animate in.
- **Custom zones used?**: yes — tour-pricer typically defines "Front 10 rows + GA standing" as their analytical cut and applies it across all stops. The custom zone overlay shows the % of inventory in this user-cut as a separate series.
- **2-sec answer**: which 3 stops are the biggest movers + which direction.

### C2 · Madonna single-night Brooklyn opening — micro pricing during on-sale

- **Persona / intent**: pricer mid-onsale. Tickets are flying. Need to keep base price ahead of the curve without going so high that the next 100 listings sit.
- **Scope**: **3 — single event, holistic**
- **Data sources**: EVO (real-time ticks), SD (similar shows historical sold-vs-ask), SG (parallel SG seller-direct sales), Twitter (live mentions, FUTURE).
- **Primary view**: T1 Event Workbench in DENSE mode — 6h chart range default, faster refresh (10s instead of 30s), sales tape on chart prominent.
- **Tabs / hide-shows**:
  - Top sub-tabs (the existing Tickets/View-by-Zone/Auto-Pricer trio is the bottom-pane decision): Tickets default for the on-sale frenzy.
  - Hide ESPN block (concert).
  - Show: real-time sales count badge in nav (animated number, ticks up).
  - Show: sentiment ribbon condensed to a single +/- gauge at top-right.
- **Real-time elements**: sales tape on chart (every 10s); "BROADCAST PRICE CHANGED" toast when our broadcast price update fires; "@buyer typing" ghost indicator from active retail-shop sessions (when retail is wired).
- **Custom zones used?**: not typical for on-sale — too fast. But broker may have a saved "GA pit + first-tier" zone they monitor.
- **2-sec answer**: how fast is inventory being absorbed, and is our owned price keeping pace.

### C3 · Beyoncé 6-night SoFi residency — multi-night comparison

- **Persona / intent**: residency pricer. 6 nights across 8 days. Night-1 always softer than Night-3 (the "best" Saturday). Wants to compare nights side-by-side.
- **Scope**: **4 — series / run / multi-night**
- **Data sources**: EVO per-night, SD per-night when sales accumulate, Twitter mentions per-night (FUTURE), GTrends (FUTURE).
- **Primary view**: T6 in **multi-night sub-mode** — 6 columns side-by-side (Night 1..6), each showing the same metric stack. A toggle switches the metric the columns visualize (retail / get-in / qty / sentiment / S4K share). The chart band overlays all 6 nights as separate-color lines.
- **Tabs / hide-shows**:
  - Tabs: Per-night view · Cross-night comparison chart · Section premium night-vs-night
  - Hide-show: night-of-week badge on each column (Sat = bold, Mon = dim)
- **Real-time elements**: a cross-night "movers" alert bar — if any night's price moves > 5% in 1h, banner alert for that night specifically.
- **Custom zones used?**: yes — "Front section + B-stage zone" is a user-created analytical cut that pulls performer's specific stage layout.
- **2-sec answer**: which night has the steepest discount opportunity; which night is over-asking.

### C4 · Coachella weekend pricing — multi-day festival

- **Persona / intent**: festival pricer with two SKUs: per-day passes AND full-festival passes. Want to keep multi-day passes priced as a discount-to-3x-day-pass to drive bundle conversion.
- **Scope**: **4 + a special "bundle" overlay**
- **Data sources**: EVO (3 per-day events + 1 multi-day SKU), SD (cleared bundles vs cleared per-day), SG (per-day SG inventory).
- **Primary view**: a hybrid — top half is T6 Series mode showing the 3 days. Bottom half is a "Bundle math" panel: 3 × Day Pass median = $X; current Multi-Day median = $Y; bundle discount = ($X − $Y) / $X. If the discount drops below 8% the panel turns red ("bundle losing edge").
- **Tabs / hide-shows**:
  - Tabs: Day-by-day · Bundle vs days · Per-stage pricing
  - Hide-show: per-stage chart (toggleable; festival venues have multiple stages)
  - Real-time: per-day sales tape on each column
- **Custom zones used?**: yes — "VIP enclosure" cross-day cut. The broker may have inventory in VIP on Day 1 and Day 3 only; the custom zone aggregates.
- **2-sec answer**: is the multi-day bundle still discounted enough to convert.

### C5 · Last-minute liquidation — 24h before show, brokerage holistic

- **Persona / intent**: ops + pricer pair. T-24h. Decide which excess inventory to dump aggressively, which to hold for a last-minute spike, which to refund-and-eat (rarely).
- **Scope**: **9 — brokerage roll-up** (sliced to "all events within 24h")
- **Data sources**: EVO (own qty open + price floor), SD (last-minute clearance comparables), SG (active SG inventory + last-1h sold), historical sales velocity from past similar T-24h liquidations.
- **Primary view**: a triage table — every event in the next 24h, columns: notional at risk, current S4K share, qty open, sold last 6h velocity, recommended action (Dump / Hold / Refund). Sortable. Click → drilldown to T1.
- **Tabs / hide-shows**:
  - Tabs: T-24h list · T-12h list · T-6h list · T-2h list (the pricer's cadence tiers)
  - Hide-show: per-row sentiment gauge column (toggleable)
- **Real-time elements**: every minute, the velocity column re-sorts. Dump-eligible rows pulse a soft red.
- **Custom zones used?**: rarely — at T-24h you're dumping the whole inventory.
- **2-sec answer**: which 3 events have the most $ at risk in the next 6h.

---

## 4. Comedy — 5 simulations

### COM1 · Touring comedian residency — 5-night Dave Chappelle at Beacon

- **Persona / intent**: residency pricer + ops. Last-minute residencies tend to be sold out by night 1; later nights can soften if word-of-mouth is mixed.
- **Scope**: **4 — multi-night**
- **Data sources**: EVO, SD, SG. Wikipedia for Chappelle's tour history (FUTURE). Twitter for show reviews after each night (FUTURE — important: review-driven demand shift).
- **Primary view**: T6 multi-night in 5-column layout (similar to Beyoncé residency above). With a key difference: a **review-impact panel** that shows "post-night sentiment delta" — Twitter mentions of "good/bad/funny" per show, mapped to the next night's price reaction.
- **Tabs / hide-shows**:
  - Tabs: Per-night · Review impact · Section premium
  - Hide-show: Wiki context column (artist tour history + venue history)
- **Real-time elements**: live Twitter mentions ticker once a night ends (FUTURE). When wired, mentions feed alert thresholds on subsequent nights.
- **Custom zones used?**: rarely for comedy — small venue, less zone differentiation.
- **2-sec answer**: are post-night reviews softening tomorrow's demand.

### COM2 · Single comedy show — Trevor Noah at MSG, classic event

- **Persona / intent**: pricer with a one-off event. Treats it like a sports event but without ESPN.
- **Scope**: **3 — single event, holistic**
- **Data sources**: EVO, SD, SG. Wikipedia (artist popularity baseline). NO Twitter live (event is too small to drive ticker volume).
- **Primary view**: T1 Event Workbench in **non-sports variant** — ESPN block hidden, replaced by:
  - "Artist context" card with Wikipedia tour-summary blurb
  - "Last 5 comparable shows" using `find_similar_events` filtered to non-sports + same primary_performer
  - Comp shows similar to ESPN's "last 5 played" but driven by performer history not league play
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Auto-Pricer (the existing trio)
  - Hide-show: ESPN block (off — concert)
  - Show: artist-context card (replaces ESPN slot)
- **Real-time elements**: sales tape on chart; news markers from Twitter when wired.
- **Custom zones used?**: yes — at MSG the broker uses the standard "100 Corner / 100 End / U1 .1-9" zone vocabulary even for non-sports.
- **2-sec answer**: where the price is vs comparable Trevor Noah shows in this venue.

### COM3 · Sebastian Maniscalco tour — full tour-wide pricing

- **Persona / intent**: tour pricer for a comedy headliner. ~30 stops. Each stop a different venue, different capacity, different demand profile.
- **Scope**: **5 — tour-wide**
- **Data sources**: EVO (per-stop), SD (per-stop sold), SG. Wikipedia (artist tour history). GTrends (per-city search interest).
- **Primary view**: T6 Tour mode with a **capacity-normalized chart** — instead of raw retail, show retail-as-%-of-capacity-sold-baseline so a 1500-seat theater and a 5000-seat arena are comparable.
- **Tabs / hide-shows**:
  - Tabs: Stops chronological · Stops by capacity bucket (small / mid / arena) · GTrends by city
  - Hide-show: tour-map mini (always shown for tours); per-stop venue type indicator (theater/arena/casino)
- **Real-time elements**: GTrends search-interest delta per-city (FUTURE) overlays as a small bar per stop column.
- **Custom zones used?**: per-tour user defines "first 5 rows + premium box" — applies across all stops, regardless of venue's specific zone vocab.
- **2-sec answer**: which 3 stops have the worst search-interest decay (Twitter / GTrends signal).

### COM4 · Comedy festival mixed bill — 8 comedians one night

- **Persona / intent**: festival pricer. One ticket gets you 8 comedians. Mid-tier comedians' fans drive demand more than headliner alone.
- **Scope**: **3 — single event** (but with multi-performer attribution)
- **Data sources**: EVO, SD, SG. Per-comedian Twitter mention counts (FUTURE) — the festival is the bundle, but per-comedian buzz is the demand driver.
- **Primary view**: T1 Event Workbench with a **multi-performer attribution panel** — pie chart or bar chart showing which performer's fans are buying (when crossed with retail-tracking signals).
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Per-performer attribution
  - Hide-show: ESPN block (off); per-performer Wiki blurb (toggleable)
- **Real-time elements**: per-performer mention counter (FUTURE) tickers up next to performer name.
- **Custom zones used?**: less common — single venue, single show.
- **2-sec answer**: is demand correlating with the headliner or with the second/third-billed comedians.

### COM5 · Athlete-comedy crossover — Shaq tour with ESPN player overlay (the rare ESPN edge case Julian called out)

- **Persona / intent**: rare niche. Comedy tour by a former NBA player. Their NBA fanbase still drives some demand. ESPN PLAYER data (not team) is relevant: if Shaq's TV career has a notable hit/miss it spikes ticket interest.
- **Scope**: **5 — tour-wide** with an ESPN-player overlay
- **Data sources**: EVO, SD, SG (per-stop), PLUS ESPN `espn_player_snapshots` filtered to Shaquille O'Neal (athlete_id 9000). Player-level tracking is the ONLY ESPN data point used for non-sports per Julian's call.
- **Primary view**: T6 Tour mode with a thin "ESPN player overlay" strip showing news markers tied to the athlete (e.g., "Inside the NBA contract renewal" → spike in tour ticket interest the next day).
- **Tabs / hide-shows**:
  - Tabs: Tour · Stops · ESPN player news (rare for non-sports — explicitly enabled)
  - Hide-show: ESPN team-data column (off — irrelevant); ESPN player-news (on for this special case)
- **Real-time elements**: ESPN news ticker for the player only (filter `espn_news WHERE athlete_id = 9000`).
- **Custom zones used?**: maybe — if there's per-stop premium "meet & greet" zone.
- **2-sec answer**: did the player's last TV moment impact tonight's tour stop sales velocity.

---

## 5. Theater — 5 simulations

### T1 · Hamilton long-run weekly pricing

- **Persona / intent**: long-run pricer (Hamilton has been on Broadway since 2015). Weekly demand cycle: Tue/Wed soft, Sat/Sun premium. Pricer sets weekly tier rules, not per-show ticks.
- **Scope**: **8 — single performer, all events** (where performer = "Hamilton on Broadway", a long run)
- **Data sources**: EVO (8 shows/week × N weeks), SD (steady-state sold history). GTrends (search interest decay over time of show's tenure).
- **Primary view**: a **weekly heatmap calendar** — one row per week, 8 columns per week (Tue eve / Wed mat / Wed eve / Thu eve / Fri eve / Sat mat / Sat eve / Sun mat). Cell color = current retail vs the show's all-time median. Click → T1 single-event drilldown.
- **Tabs / hide-shows**:
  - Tabs: Weekly heatmap · Day-of-week trend · Tier setup (the Auto-Pricer rules per day-of-week)
  - Hide-show: long-term decay chart (10y Hamilton history shown as a backdrop)
- **Real-time elements**: rolling weekly velocity ticker.
- **Custom zones used?**: standard Broadway zones (Orchestra / Mezzanine / Balcony / Boxes) — venue-curated, not user-custom. But pricer may save "Standing Room" + "Last 5 rows mezzanine" as their own analytical cut for the discount-tier flag.
- **2-sec answer**: which day-of-week is currently softest vs its baseline.

### T2 · Limited-engagement Sondheim revival — 12-week run at Lincoln Center

- **Persona / intent**: limited-run pricer. Weeks 1-2 = previews (soft pricing), weeks 3-10 = peak (steady), weeks 11-12 = closing (premium for "last chance"). Each phase is a different pricing regime.
- **Scope**: **4 — series / run** (12-week limited engagement)
- **Data sources**: EVO + SD + SG + Wikipedia (revival reception history) + Twitter (review buzz, FUTURE).
- **Primary view**: T6 in a **phase-aware mode** — the 12 weeks split into 3 phases (Preview / Peak / Closing) with phase-specific KPIs and pricing rules. A timeline at top with phase boundaries clearly demarcated.
- **Tabs / hide-shows**:
  - Tabs: Per-week · Per-phase · Reviews timeline (Twitter mentions, FUTURE)
  - Hide-show: critic-review column (per-week New York Times / NYTW review headline + sentiment, FUTURE)
- **Real-time elements**: when in the closing phase, "T-N days remaining in run" countdown — drives premium pricing rules.
- **Custom zones used?**: yes — for limited engagements brokers often save "all dates remaining post-N-days" as a custom rolling zone.
- **2-sec answer**: where are we in the run lifecycle, and what pricing regime is the active rule set.

### T3 · Off-Broadway smaller venue — 200-seat capacity, intimate pricing

- **Persona / intent**: small-venue pricer. 200 seats, fewer zones (often just Orch / Mez), low absolute prices ($45-$120). Per-show liquidity is thin.
- **Scope**: **3 — single event, holistic**
- **Data sources**: EVO + SD + SG. Twitter (for buzz, FUTURE).
- **Primary view**: T1 Event Workbench in **small-venue variant**:
  - Hide the zone-breakdown panel (only 2-3 zones — not informative as a separate panel)
  - Promote the Splits panel (small venues sell in groups of 2-4 mostly)
  - Compress the chart (5-day default range, not 7d — events sell in 1-2 weeks)
  - Show capacity-as-%-sold prominently (because at 200 seats, % sold is the main metric)
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone (with small-venue note: "Zones limited at this venue") · Auto-Pricer
  - Hide-show: full chart workbench (default off — small venue doesn't need 30d history)
- **Real-time elements**: per-show capacity-utilization gauge (animated as % sold ticks up).
- **Custom zones used?**: rarely — too few zones to begin with.
- **2-sec answer**: how close to sold-out are we.

### T4 · Holiday Nutcracker — predictable seasonal demand, all of December

- **Persona / intent**: seasonal pricer. 31 shows in December. Christmas Eve / NYE = peak; mid-week early Dec = soft. Every year follows the same curve.
- **Scope**: **8 — single performer, all events** (the production), or **6 — single venue, season**
- **Data sources**: EVO + SD + SG + historical YoY (this venue's last 3 Decembers). GTrends ("Nutcracker NYC" search interest curve).
- **Primary view**: a **seasonal heatmap** — December calendar grid, each cell colored by current retail vs YoY-this-day. Above the grid: "vs last year" line chart showing how this season is tracking.
- **Tabs / hide-shows**:
  - Tabs: This season's calendar · YoY comparison (last 3 Decembers) · Per-show drilldown
  - Hide-show: holiday-event-flag column (Christmas Eve/Day/NYE highlighted in accent color)
- **Real-time elements**: season-to-date sold velocity vs same-day-last-year.
- **Custom zones used?**: maybe — "family 4-pack zones" custom cut for holiday family bookings.
- **2-sec answer**: are we tracking ahead of, on, or behind last year.

### T5 · Touring Broadway — Hamilton North American tour, 30 cities

- **Persona / intent**: tour pricer for a touring Broadway production. Different from tour C3 (comedy) because each tour stop is itself a 1-2 week run, not a single night.
- **Scope**: **5 — tour-wide** with a nested **4 — series/run** per stop
- **Data sources**: EVO (per-stop, per-show), SD per-stop. GTrends per-city. Wikipedia (tour overview).
- **Primary view**: T6 Tour mode with a **drill-into-stop-run** pattern — clicking a tour stop opens the per-stop run-mode (similar to T1 Hamilton long-run but compressed to the 1-2 week window).
- **Tabs / hide-shows**:
  - Tabs: Tour overview · Per-stop run · GTrends per-city
  - Hide-show: tour-map mini (always shown); per-city Wiki context (toggleable)
- **Real-time elements**: per-stop sales velocity ticker.
- **Custom zones used?**: yes — same as long-run Broadway. "Standing Room + last-5-mez rows" as discount-tier cut, applied across all stops.
- **2-sec answer**: which stop-run is undersold vs the tour median.

---

## 6. Cross-cutting UI patterns surfaced by the 15 sims

Patterns that appear repeatedly and should be first-class:

1. **Saved-search tabs at the top** — every scenario above could be a saved tab. Title format mirrors existing system: "Tour - [Madonna, 47 stops]" / "Run - [Sondheim, weeks 3-10]" / "Festival - [Coachella W2]". Right-click → rename / duplicate / close.
2. **Per-scenario "context" replaces ESPN slot** — the slot is reserved at the same coords on every event view; what fills it depends on `event_type`:
   - Sports: ESPN team + injuries + standings + news
   - Concert: artist Wiki + Twitter mentions + GTrends
   - Comedy: artist Wiki + Twitter reviews + (rarely) ESPN-player
   - Theater: production Wiki + critic reviews + previous-run history
3. **Sales tape on chart is universal** — every Event view has it. Different event types just have different sale velocities (concerts on-sale = burst; theater long-run = trickle). Visualization is the same: dots on the price line at sold-price + sold-time.
4. **Custom-zone overlay** — every analytical view (T1, T6) supports an overlay of user-saved analytical zones. Three states: hidden (default) / overlaid as a series / used to filter the inventory grid below.
5. **Capacity-normalized mode toggle** — for non-sports views especially, raw retail is misleading when comparing a 200-seat off-Broadway to a 5000-seat arena. A single toggle switches the chart's Y-axis between $-absolute and $-per-capacity-sold.
6. **"Phase" / "regime" awareness** — limited runs have phases (preview/peak/closing); residencies have nights; tours have stop-by-region. The terminal needs a top-of-page phase indicator that changes the active pricing-rule set + which alerts fire.
7. **YoY mode** — for seasonal events, "vs last year" is the primary metric. A toggle on the chart replaces "vs 7d ago" with "vs same-day last year" (where data exists).
8. **The 4-checkbox auto-flag group** (Auto Pricing / Grid Drop / Auto Dump / Auto Price) appears per-zone in View-by-Zone. Same UI control on every category. Premium zones default all-off; standard zones default all-on.
9. **"Needs zone mapping" alert chip** — when an event has tickets with blank Zone Pricing, a chip in the inventory grid header surfaces the count + a one-click "Map to existing zone" action.
10. **3-tier notes drawer** — every ticket / event / zone has Notes / Private Notes / Broker Notes tabs in its detail drawer. Color-coded by audience (public / S4K-internal / ops-only).

---

## 7. Open questions / what needs to land before this fully ships

1. **Wikipedia / Twitter / Reddit / GTrends ingest layer** — the biggest gap. None of these are in our schema. Suggest a `social_signals` table keyed by `(scope_type, scope_id, source, captured_at)` so a single ingest pipeline can land all four.
2. **AQ id system xref** — confirmed real from the screenshots. Add an `aq_event_id` column to `entity_event_map` + a row in `taxonomy_xref` for AQ. Coverage: small (only events the existing pricer touches), but high-value for cross-system clarity.
3. **YoY data depth** — for seasonal sims (T4 Nutcracker), we need 3+ Decembers of history. Today our event_metrics history is ~2 weeks. Long-term: snapshot December every year going forward; in the short term, run on whatever history we have and label it ("this season vs N comparable past seasons").
4. **Custom-zone schema** — `user_custom_zones` table. Per-user, per-saved-zone, with a definition (a JSON predicate over section/row/category) + a name. Not yet built.
5. **Capacity ingest** — we have `venue_assets` for top venues but not all. The capacity-normalized toggle requires it. Gap: backfill capacity for top 100 venues.
6. **Limited-run "phase" model** — needs a `event_run` table grouping consecutive same-show events into a run with phase boundaries (Preview / Peak / Closing). Out-of-scope for v1; T2 Sondheim runs without it (raw chart only).
7. **3-tier note audience enforcement** — currently a single notes column; the existing system has 3 columns. Needs schema split + per-tier audience checks at the API layer.
8. **Real-time sales tape feed** — websocket or polling? Events with ~10 sales/min during on-sale need responsive feel. Suggest WebSocket from `unified_orders` + 30s poll fallback.
9. **Twitter / Reddit / GTrends rate limits + cost** — these have API costs. Suggest a per-event "buzz pull" budget similar to SeatData's pull budget pattern (`seatdata_pull_budget`).

---

## 8. What's NEXT (in this simulation series)

Per the sequencing Julian set:

1. **THIS DOC** (15 non-sports sims) — checkpoint for review.
2. **Sports simulations** — `design/simulations-sports-2026-05-08.md`. ~30-35 sims across NBA / NFL / MLB / NHL / WNBA / MLS / F1 / Tennis / Golf with structural specifics:
   - Regular vs post for NFL/NHL/WNBA/MLB
   - In-Season Tournament for NBA
   - Concacaf / US Open Cup / Leagues Cup for MLS
   - Multi-day single-event for F1 / Tennis / Golf
   - Game-series (Subway Series / playoffs)
   - Full ESPN deck (team + standings + injuries + player + news)
3. **Edge-case + UI-element simulations** — `design/simulations-edge-and-ui-2026-05-08.md`:
   - ESPN-only views (just the context layer, no prices)
   - Raw-pricing-only views (no ESPN, no narrative)
   - Multi-tab parallel investigations
   - Custom-zone deep dive
   - Real-time elements (sales tape / news markers / price-move dots) — exact placements
   - Hide/show patterns per persona

---

## 9. Status

Filed by: design · 2026-05-08
First checkpoint of the simulation series. Builds on `terminal-only-redesign-2026-05-08.md` + the pricer CSV + the existing-system screenshots.
No code changes. No backend writes. Ready for code review and to drive prioritization on the social-signals ingest pipeline + custom-zone schema.

Awaiting Julian's go-ahead to write the sports + edge-case companion docs.
