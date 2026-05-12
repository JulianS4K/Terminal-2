# Event View — Wireframe v4

**Status:** spec, ready for build (supersedes v3)
**Branch:** `claude/audit-datasets-schemas-auoc3` → PR #51
**Spec date:** 2026-05-10

---

## Changes from v3

| Direction | Action |
|---|---|
| **SG market split** | 3-way: `ours_sg` / `sg_broker` (3rd-party owned) / `sg_fan`. Each is its own line on the chart and its own row in the Owned-vs-Market table. New view: **`v_seatgeek_listings_classified`**. |
| **Competing events** | New panel below ESPN / Performer panel. Powered by **`v_event_competing_events`** (uses `v_venue_neighbors`, ±25 mi / ±6 h). Mirrors Tevo `/events?lat&lon&within` purely server-side. |
| **Data freshness** | Per-source freshness chips in the header context strip. New view: **`v_event_data_freshness`**. |
| **Weather context** | Expanded in header context: precip%, wind, gust, humidity (was just temp). |
| **NWS context** | Expanded in header context: threat icons (wind/hail/tornado), max gust mph, max hail in, instruction text excerpt, venue-zone match flag. |
| **Holiday impact** | Holiday name now joined with `attendance_impact` (▲ / ▼ / =). |
| **ESPN panel extras** | Add `home_score` / `away_score` / `attendance` for past meetings; `home_win_prob` history sparkline next to the win-prob KPI. |
| **Engineered signals panel** | New panel below the ESPN / Performer panel. Surfaces `event_movers_v3_owned_share`, `pricing_intel_unified`, `why_signals`, `section_metrics`, `zone_metrics`. |
| **SG flag chips** | NOT chart-series. Listed only in the SG raw-data tab as columns/icons. |
| **Skipped (for now)** | Cost & margin (no cost data yet); WTY indicator; specific seats; delivery readiness / fulfillment risk; sales-row meta extras; Reddit detail render; Wikipedia full bio render; tour-comp benchmark detail. |

---

## Decisions (current)

| Decision | Value |
|---|---|
| Personas | All three (Broker / Scout / Analyst) — single tabbed page |
| Tabs | `Pricing` (default) · `Discovery` · `Analytics` |
| Templates | **Sports** (when `performer_espn_team_xref` row exists) and **Generic** — hardwired |
| Tier badge | `multi_source` · `single_source` · `pending_match` (T4) |
| Lead chart | One merged multi-axis chart: standings strip + price pane (lines, scatter, inventory bars, alert/injury/weather markers) |
| Time-window toggle | `[24h] [3d] [7d ▣] [30d] [all]`. Falls back to widest with data if event younger than the default. |
| Owned aggregation | Split rows per source (`ours-tevo`, `ours-sg`) |
| **SG split** | **3-way: `ours-sg`, `sg-broker`, `sg-fan`** (was 1-way `sg-mkt`) |
| Tevo market | Single line `tevo-mkt` |
| SeatData market | Single line `sd-mkt` (when present; not yet) |
| Sales scatter | `v_event_sales_combined` plotted on price pane: ◆ ours, ○ market |
| Header content | Identity + tier badge + days-to-event + alert count + **context strip (weather + NWS + holidays w/ impact + freshness chips)** + injuries (sports) |
| ESPN section | Below pricing (sports template only). Game state, standings line chart **inside the price chart**, news, rivalry, **plus** historical scores / attendance / win-prob sparkline |
| Engineered signals panel | Below ESPN / Performer panel (movers, why_signals, section/zone metrics) |
| Competing events panel | Below engineered signals, both templates |
| Movement markers | `event_alerts` rows pinned at `captured_at` on the chart |
| Raw data | Three tabs: **EVO** · **SeatGeek** · **Sales (combined)**. Owned rows highlighted (★ + tint) |
| Tour benchmark (T2) | Reuse `v_performer_tours` / `v_performer_residencies` (full broker render specced later) |
| T4 match action | **Queue for review** — `queue_sg_event_match()` RPC |
| StubHub | Dropped for v1 |

---

## Routing

```
event_id  →  fetch event_xref + sg_events_canonical + performer_espn_team_xref
              │
              ├─ if performer_espn_team_xref row exists  → /events/[id]?template=sports
              ├─ if sg_events_canonical.tevo_event_id IS NULL but a SG row exists
              │      → /events/sg/[sg_event_id]?template=generic_t4
              └─ else                                    → /events/[id]?template=generic
```

---

## SPORTS TEMPLATE — Pricing tab

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│ HEADER                                                                                     │
│ ⚾ NEW YORK YANKEES vs BOSTON RED SOX                                  tevo_event_id 3346118│
│ Yankee Stadium · Bronx, NY                                                                  │
│ Mon Jul 28, 2026 · 7:05 PM ET   12 days   tier: ESPN sports · multi-source   ⚠ 3 alerts    │
│                                                                                             │
│ CONTEXT — weather · NWS · holidays · calendar · reddit · freshness                         │
│   ☀ 91°F · 0.0in · 12mph wind · 35% hum    🚨 NWS heat advisory (max gust 22 · zone 197)   │
│   ✈ summer break  🇺🇸 Memorial Day weekend ▲impact  🏆 MLB All-Star Wk  💬 r/NYY 18/72h    │
│   📡 freshness — EVO 4m · SG-listings 2m · SG-sales 11m · SG-orders 14m ·                   │
│                  ESPN 28m · weather 1h · NWS 22m · reddit 41m                              │
│                                                                                             │
│ INJURIES (sports only)                                                                      │
│   🩹 Aaron Judge DAY-TO-DAY (ret 7/29) · Gerrit Cole 60-day IL · Verdugo questionable      │
│                                                                                             │
│ [▣ Pricing]   Discovery   Analytics                       [reprice] [chat] [pull fresh]    │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│ MERGED CHART                          window: [24h] [3d] [7d ▣] [30d] [all]                 │
│                                                                                             │
│ ── STANDINGS strip ─────────────────────────────────────────── W-L %                       │
│  .65 ┤  ───●NYY (62-44 W4)               ╭────                                  .65         │
│  .55 ┤   ───────────────────────╮  ╭─────╯                                                  │
│  .45 ┤                           ╰──╯                                            .45         │
│  .35 ┤  ── ●BOS (51-55 L2)  ──────────────────╮                                              │
│      ├──────────────────────────────────────────────────────────                            │
│ ── PRICES + INVENTORY + SALES + ALERTS ───────────────  price$ │ inv# (R)                   │
│ $400 ┤      ◆     ◆                                                            3.0k         │
│      │ ours-tevo-med ●─────●──◆──●─────●●●●●─────●●●─●─●●           ⬆ alert#4419            │
│ $300 ┤      ○○                          ◆                              ◆      2.0k          │
│      │ ours-sg-med ○─◆─○────○○────○──○──○────○─○○─○                                          │
│      │     ○      ○○                                                                         │
│ $250 ┤ sg-broker-med ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─                                             │
│      │       ○○       ○      🩹 Cole→IL  ⬇alt#4413                                          │
│ $200 ┤ sg-fan-med ───────────────────────────●●●●─────────────●●●●●                          │
│      │ tevo-mkt-med ──────────────────────────                                  1.0k          │
│ $100 ┤                              🌡 NWS heat                                               │
│  $50 ┤ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ inventory bars         0          │
│      └─────────────────────────────────── time (last 7d) ───────────────                     │
│                                                                                              │
│ Legend (toggle):                                                                             │
│   STANDINGS:  ● NYY  ● BOS                                                                   │
│   PRICES:     ● ours-tevo-med  ● ours-sg-med  ─ tevo-mkt  ─ sg-broker  ─ sg-fan              │
│              ◌ get-in variants for each                                                      │
│   SALES:      ◆ ours   ○ market  (◆=ours-evo or ours-sg-seller; ○=sg-broker fan)             │
│   BARS:       ▓ inventory (stacked: ours / sg-broker / sg-fan / sd)                          │
│   ANNOTATIONS: 🩹 injuries  🌡 weather  ⚠ alerts                                              │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│ OWNED vs MARKET — current snapshot                                                           │
│  source        qty   median  get-in   Δ24h   Δ7d   cap%                                      │
│  ────────────  ────  ──────  ──────   ─────  ─────  ────                                     │
│ ★ ours-tevo      9   $315    $250     ▲$8    ▲$22   —                                        │
│ ★ ours-sg        5   $305    $240     ▲$5    ▲$15   —                                        │
│   tevo-mkt    1.2k   $190    $24      ▼$14   ▼$31   63%                                     │
│   sg-broker    410   $182    $22      ▼$12   ▼$30   24%                                     │
│   sg-fan       232   $168    $19      ▼$9    ▼$25   12%                                     │
│   sd-mkt        —     —       —        —      —     —                                        │
│  ────────────                                                                                │
│  total mkt   1.84k   $185    $19                          fill 95%                           │
│  spread (ours-med vs sg-fan-med):  +$130  (+78%)                                             │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│ ESPN SPORTS PANEL                                                                            │
│  GAME STATE                                                                                  │
│   Pre-game · 12 days   Win prob NYY 58% (sparkline →─╮ ╭─→ trending up)                     │
│   Spread NYY -1.5  ·  O/U 8.5  ·  Last meeting NYY 4-2 BOS  · attendance 47,309              │
│                                                                                              │
│  TEAM NEWS — both rosters, last 14 days                                                      │
│   [thumb] "Aaron Judge progressing well…"   ESPN · NYY tag · 2d ago   [open]                 │
│   [thumb] "Sale named Game 1 starter…"      ESPN · BOS tag · 3d ago   [open]                 │
│   [thumb] "Cole expected back mid-Aug…"     ESPN · NYY tag · 4d ago   [open]                 │
│   [+ 5 more]                                                                                 │
│                                                                                              │
│  HISTORICAL HEAD-TO-HEAD (this season)                                                       │
│   2026-04-12 NYY 7-3 BOS @ Yankee Stadium  attendance 46,801                                │
│   2026-05-08 BOS 5-4 NYY @ Fenway Park     attendance 36,400                                │
│   2026-06-15 NYY 4-2 BOS @ Yankee Stadium  attendance 47,309                                │
│                                                                                              │
│  RIVALRY  ★ branded (Yankees–Red Sox) · high intensity · MLB                                 │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│ ENGINEERED SIGNALS                                                                           │
│  Movers (event_movers_v3_owned_share, last 24h)                                              │
│   • mkt median ▼ 6.2% on +18% inventory   broker share 24%                                   │
│   • ours median ▲ 2.5%                                                                       │
│  Why-signals (last 7d)                                                                       │
│   • Standings dip → BOS lost 3 of 4 since last pull                                          │
│   • Heat advisory issued — outdoor venue                                                     │
│   • Cole IL announced 2026-07-12                                                             │
│  Section breakdown (section_metrics top 5 by drift)                                          │
│   207     med $245 ▼14%   listings 92  delta_24h ▼8                                          │
│   209L    med $310 ▼7%    listings 64  delta_24h ▼3                                          │
│   213L    med $325 ▼5%    listings 41  delta_24h ▼1                                          │
│   320     med $112 ▼21%   listings 28  delta_24h ▼5                                          │
│   408     med $74  ▼9%    listings 36  delta_24h ▼2                                          │
│  Pricing intel (pricing_intel_unified)                                                       │
│   • signal: get-in below market by 22%        confidence: high                               │
│   • recommendation: hold floor at $235                                                       │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│ COMPETING EVENTS  (within 25 miles · ±6 hours)                                               │
│  competing event                          venue                  date           Δh   mi      │
│  ──────────────────────────────────────────────────────────────────────────────────────      │
│  Bruce Springsteen — Tour                  Citi Field             7/28 8:00p   +0.9  9.2     │
│  Hamilton                                  Richard Rodgers Theatre 7/28 7:00p   −0.1  6.8     │
│  Mets vs Phillies                          Citi Field             7/28 1:10p   −5.9  9.2     │
│  [+ 7 more · scroll]                                                                         │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│ RAW PRICING DATA                                                                             │
│  [▣ EVO]  [ SeatGeek ]  [ Sales (combined) ]                                                 │
│  …                                                                                            │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

The SeatGeek raw tab now exposes the listing-quality columns we previously dropped:

```
captured_at        section row qty price ownership stock delivery in-hand splits  flags             notes
─────────────────────────────────────────────────────────────────────────────────────────────────────────────
2026-05-10 14:32   209L   A   2  $312  ours_sg   mob  edel    7/27   [1,2]  ★                  ours
2026-05-10 14:32   209L   B   4  $295  sg_broker mob  edel    7/27   [1..4] B2B                ext
2026-05-10 14:32   213L   C   2  $325  ours_sg   mob  edel    7/27   [1,2]  ★                  ours
2026-05-10 14:32   217L   G   4  $215  sg_fan    mob  edel    7/27   [2,4]  LV                 limited view
2026-05-10 14:32   224L   D   6  $268  sg_broker mob  edel    7/27   [1..6] —                  ext
2026-05-10 14:32   312    AA  2  $152  sg_fan    pdf  -       —      [1,2]  ADA wheel acc      —
```

`flags` icons key: ★ ours · B2B · LV (limited view) · SRO · ADA · INST (instant download) · DQ (deal-quality score chip).

---

## Generic template — Pricing tab

Same shape as Sports, with two differences:

1. **No ESPN section.** In its place, a **Performer panel** (wiki blurb + image + tour summary from `v_performer_tours` / `v_performer_residencies`).
2. **No standings strip on the chart.** The chart starts with the price pane.

The Engineered Signals panel and Competing Events panel render identically.

T3 single-source: market lines collapsed where source absent ("— awaiting match" overlay).
T4 (`generic_t4`, no Tevo match): Match Candidates panel at top calling `queue_sg_event_match()`; chart and tabs degrade to SG-side only.

---

## Component contracts (delta from v3)

```ts
// Chart ownership keys grow:
type SgOwnership = 'ours_sg' | 'sg_broker' | 'sg_fan';
type Source =
  | 'ours-tevo' | 'tevo-mkt'
  | 'ours-sg'   | 'sg-broker' | 'sg-fan'
  | 'sd-mkt'
  | 'home-team' | 'away-team';   // standings pane
```

New components added:

| Component | Purpose |
|---|---|
| `<FreshnessChips />` | renders `v_event_data_freshness` rows as compact "X{m,h,d} ago" badges |
| `<EngineeredSignalsPanel />` | bundles movers + why_signals + section_metrics + pricing_intel_unified |
| `<CompetingEventsPanel />` | renders `v_event_competing_events` filtered by `source_event_id`; sortable by `distance_miles` / `hours_apart` / `competing_popularity_score` |

Updated:

| Component | Update |
|---|---|
| `<EventChart />` | source enum gains `sg-broker`, `sg-fan`; `is_ours` derives from `ownership_class = 'ours_sg'`. Default visible: ours-tevo, ours-sg, sg-fan, tevo-mkt; sg-broker default-on per the user request. |
| `<OwnedVsMarketTable />` | three SG rows instead of one |
| `<EventHeader />` | freshness strip slot; expanded weather/NWS/holiday rendering with impact arrows + threat icons |
| `<EspnSection />` | adds historical-meeting list + win-prob sparkline + attendance figures |

---

## Data hooks (current truth)

| Section | Source(s) |
|---|---|
| Hero KPIs | `events`, `event_metrics`, `seatgeek_event_metrics` |
| Header weather | `v_event_weather` (now exposing temp_f, precip_in, precip_pct, wind_mph, gust_mph, humidity_pct, weather_summary) |
| Header NWS | `v_event_nws_alerts` joined to `nws_alerts` for max_wind_gust_mph, max_hail_size_in, threat flags, instruction; `nws_alert_zones` for venue-zone match |
| Header holidays | `v_event_holidays` exposing `attendance_impact` |
| Header freshness | **`v_event_data_freshness`** |
| Header injuries (sports) | `v_event_espn_injuries` |
| Chart standings | `espn_team_snapshots` for both home & away team |
| Chart prices (TEvo) | `listings_snapshots` |
| Chart prices (SG split) | **`v_seatgeek_listings_classified`** GROUP BY `ownership_class` |
| Chart inventory | same, COUNT(*) per hour, stacked by ownership_class + tevo + sd |
| Chart sales scatter | **`v_event_sales_combined`** |
| Chart alerts | `event_alerts` |
| Chart injury markers | `espn_injuries_snapshots` (status changes) |
| Chart weather markers | `v_event_nws_alerts` overlapping window |
| Owned vs market table | rolled up by `ownership_class` × source |
| ESPN game state | `v_event_espn_state` |
| ESPN historical scores | `espn_event_snapshots` filtered to past matchups |
| ESPN win-prob sparkline | `espn_event_snapshots.home_win_prob` time series |
| ESPN news | `v_event_espn_news` |
| ESPN rivalry | `v_event_sporting_rivalries` |
| Performer panel (T2) | `performer_wikipedia` + `v_performer_tours` + `v_performer_residencies` |
| Engineered signals — movers | `event_movers_v3_owned_share` |
| Engineered signals — why | `why_signals` |
| Engineered signals — sections | `section_metrics` (filter to event) |
| Engineered signals — zones | `zone_metrics` |
| Engineered signals — pricing intel | `pricing_intel_unified` |
| **Competing events** | **`v_event_competing_events`** WHERE `source_event_id = :id` |
| EVO raw tab | `listings_snapshots` joined to `evo_orders` / `evo_order_items` |
| SG raw tab | `v_seatgeek_listings_classified` |
| Sales raw tab | `v_event_sales_combined` |
| T4 match candidates | `v_sg_event_match_proposals` + `sg_event_match_pending` |

---

## State machine for the chart time-window selector

```
buckets, in priority order:  [24h] [3d] [7d ▣] [30d] [all]

on mount:
  desired = 7d
  earliest_data = MIN(captured_at) across chart series for the event
  if (now - earliest_data) < desired:
       fall back to nearest-smaller bucket that fits the data
       (e.g. 1d → 24h; 4d → 3d)
  else:
       use desired

user toggles:
  always allowed; show empty plot if window has no data
  selection persists per-event in localStorage
```

---

## Build order

1. `<EventViewPage />` shell + routing
2. `<EventHeader />` with freshness chips, expanded weather/NWS/holiday-impact strip, injuries
3. `<EventChart />` — standings strip + price lines (5 SG split + Tevo) + sales scatter + inventory bars + annotations
4. `<OwnedVsMarketTable />` with 3 SG rows
5. `<EspnSection />` with historical scores, win-prob sparkline, news (sports only)
6. `<PerformerPanel />` (generic only)
7. `<EngineeredSignalsPanel />`
8. `<CompetingEventsPanel />`
9. `<RawDataTabs />` — EVO + SG (with classified columns) + Sales
10. `<MatchCandidatesPanel />` (T4 only)
11. Discovery + Analytics tabs

---

## Open work

- **Cost / margin** — blocked on ingesting cost data into EVO + SG-seller paths. Re-spec when available.
- **WTY indicator** — blocked on engineering the metric.
- **Tour benchmark detail** — needs new view joining `v_performer_tours` rows to past `event_metrics` (avg fill, avg get-in across stops). Queued for a later phase.
- **Specific seats** — render plan deferred.
- **Delivery readiness / fulfillment risk** — surface plan deferred.
