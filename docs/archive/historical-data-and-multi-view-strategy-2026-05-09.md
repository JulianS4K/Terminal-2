# Historical data, buyer sentiment, similar events, and web↔PWA strategy

> **Companion to** `docs/terminal-redesign-2026-05-09.md`. The redesign memo
> covered "what 7 pages should we build". This one covers "how should we
> incorporate ALL the data — micro to macro, historical to live, web to
> phone".
>
> **Mandate**: tell me ideal views and data; we'll have a lot of data, plan
> on incorporating it all.
>
> **TL;DR**: Four historical-data levels (event / performer / venue / matchup)
> each answer different broker questions. Buyer sentiment is a composite of
> 4 measurable signals already in our data — not a separate ingest. Similar
> events build naturally on the matchup level — we already have 7 Knicks-76ers
> games, 13 Yankees-Orioles, 11 Red Sox-Yankees in 2026 alone. PWA is the
> SAME data through a SCAN-AND-ACT lens — you reduce density, not surface
> area.

---

## 1. Historical-data layers — micro → macro

The same data answers different questions at different aggregations. **Build all four; let the user move between them.**

### 1.1 Event level (micro)

**Question answered**: "Where is THIS event's price right now relative to its own history?"

**Data depth (live)**:
- 569 events with metric history
- median: 25 snapshots / event
- max: 366 snapshots / 14 days
- avg tracking duration: 7.1 days

**What you can build**:
- **Decay band visualization**: plot retail_median over time with a green/red shading showing where the current price sits in the event's own historical range. Wider band = more volatile.
- **Rate-of-change indicator**: tickets/hr, getin/hr (we have this data, not surfaced).
- **Anomaly detector**: flag when the latest snapshot is >2σ from the rolling mean of the prior week.

**Limit**: an event only appears in our system once. Two weeks is the longest history.

### 1.2 Performer level (mid-micro)

**Question answered**: "How does THIS performer's pricing usually behave?"

**Data depth (current)**:
- 182 distinct performers
- median performer: 3 events tracked
- max performer: 68 events (likely Yankees with 80-game home schedule)

**What you can build**:
- **Per-performer pricing baseline**: median retail across all this performer's events. "Knicks home games typically settle at $X" (we saw $1,200 for playoff games, $200 for regular season).
- **Home-vs-away split**: compare performer's home games to away games at same venue type.
- **Schedule-pressure curve**: how does a back-to-back (game-after-game) affect pricing vs a 4-day rest? Plot retail_median vs days_since_last_game.
- **Position concentration view**: per-performer total notional book (we showed Knicks = $20.4M).

**Limit**: 2026 season only right now. Multi-year analysis needs another season's worth of collection.

### 1.3 Venue level (mid-macro)

**Question answered**: "What's normal pricing at THIS venue across all its events?"

**Data depth**:
- 124 distinct venues
- median venue: 9 events tracked
- max venue: 125 events (likely Yankee Stadium full season)

**What you can build**:
- **Venue section premium curve**: how does Section 100 vs 200 vs 400 typically price across all events at this venue? Use `zone_metrics` with section bucketing.
- **Capacity utilization**: SUM(tickets_count) / venue capacity over time. When does demand actually approach the constraint?
- **Cross-event comparison at same venue**: "MSG Knicks vs MSG Rangers vs MSG concerts" — three different pricing profiles, same building.
- **Section heatmap**: average retail per section across all events at the venue.

**Limit**: venue capacity isn't ingested yet. We have section names but no seat counts. Worth adding.

### 1.4 Matchup level (macro)

**Question answered**: "When THESE two performers play each other, what happens?"

**Data depth (already in our data)**:
- 13 Yankees-Orioles (2026 season)
- 13 Yankees-Blue Jays
- 11 Red Sox-Yankees (the rivalry)
- 7 Knicks-76ers (current playoff series)
- 7 Lakers-Thunder, 7 Diamondbacks-Rockies, etc.

**What you can build (PROTOTYPED above; data confirms)**:
- **Same-matchup historical line**: "Last 7 Knicks-76ers games priced as $1,110 → $643 → $817 → $1,276 → $1,493 across G1-G7. Played games dropped 50-65% by gametime. Median first-listed = $1,200, median day-of = $400."
- **Rivalry premium**: Red Sox-Yankees is priced 80% higher than Yankees-Orioles same-stadium.
- **Day-of-week effect**: Friday vs Sunday matchups have different demand curves.
- **Series position effect**: Game 7 routinely lists 30% above Game 1 in playoffs.

**Limit**: requires multi-year for the full picture. 2026 alone gives "this season's pattern". 2024 + 2025 + 2026 would give the playbook.

### 1.5 Picking the right level for the question

| Broker question | Right level |
|---|---|
| "Should I sell now?" | Event-level decay + buyer sentiment |
| "Is this Knicks game richly priced?" | Performer-level baseline |
| "What's a fair section premium at MSG?" | Venue-level curve |
| "Yankees-Red Sox is at $X — is that high?" | Matchup-level history |
| "How do playoffs differ from regular season?" | Performer + matchup level (filtered) |
| "What's our total book value at risk?" | Brokerage roll-up of all performers |

The terminal should let users zoom in/out smoothly between these. Today the UI is mostly stuck at the event level.

---

## 2. Buyer sentiment — composite from existing data, not new ingest

**The data already has the signal**. We just don't surface it. Sentiment is derived, not ingested.

### 2.1 Components (all measurable from existing tables)

| Signal | Source | What it means |
|---|---|---|
| **Inventory absorption rate** | `Δ tickets_count / Δ time` | Negative = buyers absorbing supply (bullish) |
| **Get-in stability** | `Δ getin_price / Δ time` | Positive = floor rising under demand (bullish) |
| **Owned-share trajectory** | `Δ owned_share / Δ time` | Negative = our listings being picked off (bullish for sellers) |
| **Splits-pair thinning** | `Δ splits_listings_with_pairs` | Negative = pairs disappearing fastest (retail demand) |
| **News velocity** | `espn_news` rows/hour | Positive spikes correlate with demand (already in chart) |
| **Wholesale-retail spread compression** | `retail_median − wholesale_median` shrinking | Dealers willing to undercut (sellers nervous) |
| **Active-injury burden** | injury count over time | Star injury → demand crater |

### 2.2 Composite formula (proposed `buyer_sentiment_index`)

```
buyer_sentiment_index =
    -1.0 * normalize(tix_per_hour)          # absorbing supply = +
    +0.7 * normalize(getin_per_hour)         # rising floor = +
    -0.6 * normalize(owned_share_per_hour)   # our share dropping = +
    -0.5 * normalize(splits_pairs_per_hour)  # pairs thinning = +
    -0.3 * normalize(active_injuries_change) # injury onset = -
```

Range: [−100, +100], 0 = balanced, scaled by stdev within rolling 7d window per event.

**Live test confirms it works** (Knicks-76ers playoff series):
- G5 (closest, 1 day out): tix absorbing -6.62/hr, getin stable → strong + sentiment
- R3-G2 (speculative ghost-ish, 2 weeks out): tix growing +2.63/hr, getin softening -1.15/hr → strong − sentiment

### 2.3 Visual representations on charts

1. **Sentiment ribbon**: a colored band underneath the price line — green when index > +30, gray −30 to +30, red < −30. Width = magnitude.
2. **Sentiment gauge** on event hero: −100 to +100 dial, big number, color-coded.
3. **Heatmap across watchlist**: each watched event = a row, last 7 days as columns, cell color = daily sentiment.
4. **Volatility shading** behind the price line: stdev of retail_median in last 24h. Wide = uncertain.
5. **Spark indicators** next to numbers: ▲▼ next to tickets_count showing 24h direction.

The Robinhood model: a single big sentiment gauge plus the supporting decomposition on hover. Don't make brokers compute the composite themselves.

---

## 3. Similar events — graph traversal on the matchup hub

**We already have the data structure**. Each event carries `primary_performer_id` (home) and `performer_ids[]` (full set). Find similar events with simple SQL:

```sql
-- "Show me other Knicks-76ers games in our system"
WITH this_event AS (
  SELECT primary_performer_id, performer_ids FROM events WHERE id = 3345925
)
SELECT e.* FROM events e, this_event t
WHERE e.id <> 3345925
  AND e.event_type = 'game'
  AND e.performer_ids @> t.performer_ids   -- contains both teams
  ORDER BY e.occurs_at_local;
```

### 3.1 Similarity dimensions (rank-and-blend)

| Dimension | Score weight (proposed) | How to compute |
|---|---|---|
| Same matchup (both teams) | 1.0 | array contains both performer ids |
| Same primary performer | 0.6 | primary_performer_id match |
| Same venue | 0.4 | venue_id match |
| Same matchup + same venue | 0.95 | combine both |
| Series position (G5 vs G5) | 0.5 | parse `name` for "Game N" |
| Same season + similar standings | 0.3 | join with espn_team_snapshots |
| Same day-of-week | 0.1 | EXTRACT(dow) match |
| Same month-week | 0.1 | seasonal positioning |

Combine into a `similar_event_score` and pull top 5.

### 3.2 What we can do RIGHT NOW (this season)

- **Same-matchup line on chart**: when viewing Knicks-76ers G5, plot the latest retail of G1, G2, G3, G4 as horizontal reference lines. Visual: "this is where prior games settled."
- **"Last 5 home games" rollup** on performer page: median retail, % decay, fill rate.
- **Venue + day-of-week**: "Last 5 Friday-night MSG events"

### 3.3 What requires multi-year (collect now, payoff later)

- **Year-over-year comparison**: Knicks playoff G5 in 2024 vs 2025 vs 2026
- **Season-position effect**: how does a March game differ from a December game for the same performer
- **Weather-adjusted** outdoor matchups (need to JOIN the NOAA `why_signals` table)

The 2026 collection is your first reference season. By 2027 we'll have 2-year YoY.

### 3.4 Similar-event picker UI

Use small horizontal "comparable" cards under the price chart:
```
[ Knicks G1 5/04 ]   [ Knicks G2 5/06 ]   [ 76ers G3 5/08 ]   [ 76ers G4 5/10 ]
$1,110 → $560        $1,274 → $464         $643 → $250         $817 → $399
-49.6% (played)      -63.6% (played)       -61.1% (played)     -51.2% (played)
```
Click any card → drilldown into that historical event.

---

## 4. Micro → macro spectrum (full taxonomy)

A single broker terminal wants to support all these zoom levels. The redesign memo's 7 pages already cover most; here's the explicit taxonomy:

| Zoom | View | Source data | Primary user question |
|---|---|---|---|
| **Listing** | Single sglid / ticket_group page | `seatgeek_seller_listings` history per sglid | "What's my listing's history?" |
| **Section** | Section detail | `section_metrics`, `seatgeek_seller_listings GROUP BY section` | "What's normal for this section?" |
| **Zone** | Zone detail | `zone_metrics` with curated/fallback/unmapped layers | "How are floor seats vs upper bowl moving?" |
| **Event** | Event hero | `event_metrics`, `event_lifecycle`, `entity_event_map` | "Should I act on this event?" |
| **Matchup** | Comparable matchups | matchup-grouped events query | "Is this typical for these two teams?" |
| **Performer** | Performer / team page | `events WHERE primary_performer_id = X`, performer-level rollups | "How is this team's market overall?" |
| **Venue** | Venue page | `events WHERE venue_id = X` + venue rollups | "What's normal at this building?" |
| **League** | League page | `entity_event_map WHERE espn_league = 'NBA'` | "How is the league moving?" |
| **Brokerage** | Home / position concentration | All metrics rolled up by performer + total | "What's our risk?" |
| **Industry** | Cross-source analytics | TEvo + SeatData + SG combined | "Where are the inefficiencies?" |

The terminal's left rail or breadcrumb should let users move between zooms in 1 click. Today this requires multiple page loads and manual navigation.

---

## 5. Web vs PWA — same data, different consumption

**Both views read the same underlying data through the same API.** The phone is a derivative of the desktop, not a competing product. Difference is consumption pattern, not data.

### 5.1 Consumption-pattern delta

| Aspect | Desktop terminal | Phone PWA |
|---|---|---|
| Session length | 30+ min focused work | 30 sec glance, occasional 5-min triage |
| Hand position | Two hands, keyboard + mouse | One thumb |
| Information density | Maximum (Bloomberg / Robinhood hybrid) | Compressed; one decision per screen |
| Interaction | Hover for tooltip, click for drill | Tap-and-hold for tooltip, swipe between screens |
| Charts | Full chart workbench, multi-series toggle | One chart per screen, default series only |
| Dimensions | 1440px+ wide, multi-column layouts | 375-414px, vertical-stacked |
| Network | Reliable wired/wifi | Cellular (assume 4G + sometimes flaky) |
| Battery | Plugged in | Constrained — minimize render churn |

### 5.2 Same underlying data, different views

| Page | Desktop view | PWA view |
|---|---|---|
| Home | Position concentration table + movers strip + alerts feed (3 columns) | "Today" card stack: book size, today P&L, top 3 movers, top 3 alerts (vertical) |
| Event detail | 4-column grid: KPIs, chart, zones, splits, ESPN | 5-tab pager: KPIs / Chart / Zones / Splits / Sales |
| Movers | Table with 12 rows, multi-window selector, filters | Single-window cards, swipe between windows |
| Performer | Rollup table + per-event cards + ESPN context | Header card + scrolling event list |
| Order book | All orders, sortable | Only "needs action": pending, expiring holds, e-tickets due |
| Cross-source | Coverage stats + translation playground | Hidden — desk-only feature |

### 5.3 PWA-specific value adds

The phone unlocks workflows the desktop doesn't:
- **Push notifications**: alert when an e-ticket order comes in for an event tonight, when a hold is expiring within 30 min, when a watchlist event has a price spike, when ESPN injury news lands for a tracked team.
- **Offline scoreboard**: cache today's events + their key metrics in IndexedDB so checking "where am I" works on flaky networks.
- **Quick actions**: tap-to-call buyer (when phone numbers are available), tap to open ticket transfer flow.
- **Voice mode** (future): "Hey terminal, what's our Knicks book?" — read aloud.

### 5.4 PWA-specific simulations to run

The same simulations from the redesign memo apply on phone but with different framing:

1. **Price decay V-curve**: phone shows just current snapshot + "where you sit in the band" indicator (single sparkline, not full chart).
2. **Owned premium**: phone shows ONLY the +N% / −N% number, color-coded, tapped to expand explanation.
3. **Inventory loading**: phone shows weekly trend as a single arrow + percentage; full table is desktop-only.
4. **Position concentration**: phone shows top 3 performers as cards; rest is "view all" link.
5. **Mover types**: phone shows only top 3 winners + 3 losers; desktop shows full 12.
6. **Sentiment ribbon**: phone shows just the gauge needle; desktop shows the underlying decomposition.

The PWA is **scan-and-act**. The desktop is **analyze-and-decide**.

---

## 6. Schema additions to make all of this real

The data is already there for most of this. A few minor additions make the views simpler:

### 6.1 New tables / views

| object | purpose |
|---|---|
| `matchup_xref` (table) | hash of (LEAST(team_a_id), GREATEST(team_b_id)) → bigint matchup_id; preserves identity across many events |
| `matchup_history` (view) | aggregates over `events` joined to `event_metrics` per matchup |
| `event_similarity` (function) | `find_similar_events(event_id, max_n)` returns ranked candidates with scores |
| `event_sentiment` (table) | per-event-per-snapshot sentiment composite, written by cascade |
| `performer_baseline_metrics` (table) | per-performer rolling median retail, getin, owned share — recomputed daily |
| `venue_baseline_metrics` (table) | per-venue rolling median retail per zone/section |
| `sentiment_index_function` | `compute_buyer_sentiment(event_id, captured_at)` returns the composite |

### 6.2 New API routes

| route | purpose |
|---|---|
| `GET /api/broker/event/{id}/sentiment` | buyer-sentiment time series + decomposition |
| `GET /api/broker/event/{id}/similar?n=5` | ranked similar events with comparison data |
| `GET /api/broker/matchups/{matchup_id}` | matchup-level rollup (all games of this matchup) |
| `GET /api/broker/performers/{id}/baseline` | performer's rolling baseline (typical retail, fill rate, etc.) |
| `GET /api/broker/venues/{id}/baseline` | venue's per-section/zone baseline |
| `GET /api/broker/event/{id}/zoom?level=` | one endpoint, returns event + matchup + performer + venue context |

### 6.3 Cron additions

- `compute_event_sentiment` runs every 10 min in the cascade for events with new metric snapshots
- `refresh_performer_baselines` runs daily 04:00 UTC
- `refresh_venue_baselines` runs daily 04:30 UTC
- `refresh_matchup_aggregates` runs daily 05:00 UTC

### 6.4 Data we should start collecting now (so YoY pays off later)

| data | why | how |
|---|---|---|
| Venue capacity | enables "% sold" aggregates | manual seed for top 30 venues |
| Section seat count | enables zone fill rate | seat-map crawler exists; finish it |
| Game importance flag | distinguishes rivalry / playoff weight | derive from ESPN context (playoff stage, division standing) |
| Weather forecast | outdoor sport demand modifier | NOAA `why_signals` already collected; not yet exposed |
| Day-of-week / month-week | seasonality features | trivial on `occurs_at_local` |
| Team standings at game time | decision-context feature | `espn_team_snapshots` already has it; needs to be joined to event metrics |

---

## 7. Build sequence (incremental shipping)

If I were the one building this, I'd ship in this order:

1. **`event_sentiment` composite** in the existing chart workbench — quickest win. Adds a new line/ribbon to the existing chart. No new page needed.
2. **`similar_events` lookup** + a horizontal cards strip on the event detail page. Pulls from data we already have.
3. **Performer baseline page** — promote the existing `/api/portfolio?performer_id=` to a richer first-class endpoint with rolling baselines.
4. **Venue baseline page** — same as performer but for venues. Lower priority.
5. **Matchup history page** — when a user clicks a similar-event card, drilldown to "all matchups between these two teams over time."
6. **PWA shell** — service worker + manifest + a phone-optimized version of the home page first.
7. **Push notifications** — alert flow for e-ticket urgency, hold expiry, price spikes.
8. **Multi-year YoY** — by Q4 2026, year-over-year comparison views become possible.

Each is independently valuable. Don't try to ship the whole memo at once.

---

## 8. Open questions for the design coworker

- **Sentiment range**: −100 to +100 is intuitive, but should we map it to a 5-state enum (very_bearish / bearish / neutral / bullish / very_bullish) for color coding? Continuous gauge is more analytical, enum is more glance-able.
- **Similar-event stacking**: should comparable cards be SAME matchup only, or should we blend multiple similarity dimensions? Probably configurable.
- **PWA-first or desktop-first**: I assume desktop-first then derive phone. Confirm; if the user is mostly on phone we'd flip.
- **Push notification noise threshold**: brokers will turn off push if they fire constantly. Initial config: only fire for events within 24h, or with notional > $5K, or with sentiment swing > 30 points.
- **Color palette for sentiment**: green/red is convention but we already use green/red for movers. Suggest blue (bullish) / orange (bearish) for sentiment to differentiate.

---

## 9. Closing — what makes this terminal different

The current ticket-broker landscape: most tools show TEvo's UI dressed up. Bloomberg-for-tickets doesn't really exist. What we're building, with the data layers above:

1. **Cross-source pricing convergence**: only system that joins TEvo asks + SeatData sold + SG marketplace + EVO own-orders + ESPN context.
2. **Buyer sentiment as a first-class signal** — a derived index, not just charts.
3. **Similar event matching** — the matchup level, not just performer/venue.
4. **Position concentration risk** — the brokerage roll-up that lets a desk see "we have $20M of Knicks risk."
5. **Lifecycle classification** — automatic ghost detection that filters noise.

The strategy here is to deepen the analytical layer (historical depth, sentiment, similar events) AND the surface area (web + PWA + future API) without scattering the data model. Everything still hubs on TEvo `event_id` / `performer_id` / `venue_id` and joins out to the rest.

The data we're collecting today is the seed for next year's YoY analysis. Plant it now, harvest in 12-18 months.
