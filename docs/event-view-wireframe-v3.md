# Event View — Wireframe v3

**Status:** spec, ready for build
**Branch:** `claude/audit-datasets-schemas-auoc3` → PR #51
**Spec date:** 2026-05-10

---

## Decisions (locked from product convo)

| Decision | Value |
|---|---|
| Personas | All three (Broker / Scout / Analyst) — single tabbed page |
| Tabs | `Pricing` (default) · `Discovery` · `Analytics` |
| Templates | **Sports** (when `performer_espn_team_xref` row exists) and **Generic** — hardwired |
| Tier ranking inside template | `multi_source` · `single_source` · `pending_match` (T4) — affects header badge + match CTA, not template choice |
| Lead chart | **One merged chart**, multi-axis — prices + inventory + sales velocity. No row-stacked sub-charts. |
| Default time window | **Last 7 days**, with `[24h] [3d] [7d] [30d] [all]` toggle. If less than 7d of data exists, fall back to widest window with data. |
| Owned aggregation | **Split rows per source** (`ours-tevo`, `ours-sg`). No "ours total" collapse. |
| Market aggregation | **Split per source** (`tevo-mkt`, `sg-mkt`, `sd-mkt`). Each gets its own line on the chart. |
| Header content | Event identity + tier badge + days-to-event + alert count + **context strip + injuries (sports) merged in**. No separate context strip below. |
| ESPN section | Below pricing chart, **only when** event has an ESPN team mapping. Standings as line chart, injuries as **event annotations on the price chart** (not a separate panel). News + game state stay as a panel. |
| Movement markers | `event_alerts` rows pinned at `captured_at` on the chart. |
| Raw data | Two tabs at the bottom: **EVO** and **SeatGeek**. Owned rows visually highlighted (background tint + ★ marker). |
| Tour benchmark (T2) | Reuse existing `v_performer_tours` / `v_performer_residencies`. No new view. |
| T4 match action | **Queue for review** — call `queue_sg_event_match()` RPC; admin approves via `approve_sg_event_match()`. No direct write. |
| StubHub | **Dropped** for v1. Don't reserve UI slots. |

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

`tier` badge inside the chosen template:
- `multi_source` — ≥2 of {tevo, sg_broker, sg_seller, seatdata}
- `single_source` — exactly 1 of those
- `pending_match` — sg_events_canonical.tevo_event_id IS NULL (template = generic_t4)

---

## SPORTS TEMPLATE

### Pricing tab (default — broker)

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│ HEADER                                                                             │
│ Yankees vs Red Sox · Yankee Stadium · Mon Jul 28, 7:05p ET                         │
│ tier: ESPN sports · multi-source       12d to event   ⚠ 3 alerts                  │
│ ── context strip (compact)                                                         │
│   ☀ 91°F clr  •  🚨 NWS heat advisory  •  ✈ summer break  •  🏆 MLB All-Star Wk    │
│   💬 Reddit 18 posts/72h                                                           │
│ ── injuries (sports only, compact)                                                 │
│   🩹 Judge DTD ret 7/29  •  🩹 Cole 60-day IL  •  🩹 Verdugo questionable          │
│ [Pricing]  Discovery  Analytics                                                    │
│ [reprice ours] [push to chat] [pull fresh]                                         │
├────────────────────────────────────────────────────────────────────────────────────┤
│ MERGED CHART                       window: [24h] [7d ▣] [30d] [lifetime]           │
│                                                                                    │
│ left axis $        right axis #lst   third axis: cumulative sold                  │
│ $400 ┤── ours-tevo-med                                          alert#4419 ⬆      │
│ $300 ┤── ours-sg-med                                            🩹 Cole→IL         │
│ $200 ┤── tevo-mkt-med   ●●●●●           🩹 Judge→DTD            ⬇ alert#4413      │
│ $100 ┤── sg-mkt-med                     🌡 NWS heat advisory                       │
│       ┤── sd-mkt-med (collapsed if 0)                                              │
│       │ ▓▓ inventory bars (right axis, stacked: tevo+sg+sd, owned overlay)        │
│       │ ┄┄ sales velocity (3rd axis, cumulative — toggle off by default)          │
│       └────────────────── time (last 7d) ─────────────────                         │
│                                                                                    │
│ Legend (clickable to toggle):                                                      │
│   ● ours-tevo-med   ● ours-tevo-getin   ● ours-sg-med   ● ours-sg-getin           │
│   ● tevo-mkt-med    ● tevo-mkt-getin    ● sg-mkt-med    ● sg-mkt-getin            │
│   ● sd-mkt-med      ▓ inventory          ┄ sales velocity   🩹 injuries  ⚠ alerts  │
│                                                                                    │
│ Default visible: ours-tevo-med · ours-sg-med · tevo-mkt-med · sg-mkt-med ·        │
│                  inventory · alerts · injuries (sports only)                       │
├────────────────────────────────────────────────────────────────────────────────────┤
│ OWNED vs MARKET — current snapshot                                                 │
│ source       qty   med   get-in  Δ24h    Δ7d                                       │
│ ours-tevo      9   $315  $250    ▲$8     ▲$22                                     │
│ ours-sg        5   $305  $240    ▲$5     ▲$15                                     │
│ tevo-mkt    1.2k   $190  $24     ▼$14    ▼$31                                     │
│ sg-mkt       642   $175  $19     ▼$11    ▼$28                                     │
│ sd-mkt         —    —     —       —       —                                       │
├────────────────────────────────────────────────────────────────────────────────────┤
│ ESPN SECTION (only when espn_team_id is mapped)                                    │
│ ── game state                                                                      │
│   Pre-game · 12d   Win prob NYY 58%   Spread NYY -1.5   O/U 8.5                   │
│ ── standings (line chart, season-long)                                             │
│   .700 ┤   ╭──── NYY                                                               │
│   .500 ┤───╯ ── BOS                                                                │
│   .300 ┤                                                                           │
│        └────── season ──────                                                       │
│ ── news (last 14d)                                                                 │
│   • "Judge progressing well" 2d ago                                                │
│   • "Sale to start vs NYY" 3d ago                                                  │
│   • [+1 more]                                                                      │
│ ── rivalry  ★ branded · high intensity                                             │
├────────────────────────────────────────────────────────────────────────────────────┤
│ RAW DATA TABS                                                                      │
│ [ EVO ▣ ]  [ SeatGeek ]                                                            │
│ Last 100 listings_snapshots rows for this event:                                   │
│   captured_at        section  row  qty  price   ★owned  broker_id                 │
│   2026-05-10 14:32   209L    A     2   $312    ★ours    NYY-YANK-12              │
│   2026-05-10 14:32   209L    B     4   $295             ext-9018                  │
│   ...                                                                              │
│   ★★★ owned rows have a tinted background and ★ marker ★★★                       │
│                                                                                    │
│ Last 50 sales rows (toggle below the listings table):                              │
│   sold_at            section  row  qty  price   ★ours                              │
│   2026-05-10 13:08   207     C     2   $245    ★ours                              │
└────────────────────────────────────────────────────────────────────────────────────┘
```

### Discovery tab (scout)

```
HEADER + tabs identical.
┌────────────────────────────────────────────────────────────────────────────────────┐
│ Popularity      events.popularity_score · long_term_popularity_score · trend       │
│ Availability    fill rate by source · listings/cap · days-listed                   │
│ Game card       compact ESPN strip (game state · last 5 results · standings W-L)   │
│ Comparable      same matchup last seen · venue history (matchup_xref)              │
│ Context         weather + holidays + major calendar (collapsible)                  │
│ Signal flags    rivalry · branded series · injuries count · NWS active             │
└────────────────────────────────────────────────────────────────────────────────────┘
```

### Analytics tab (post-mortem)

```
HEADER + tabs identical.
┌────────────────────────────────────────────────────────────────────────────────────┐
│ Lifetime chart   same merged chart, x = lifetime, denser y                         │
│ Attribution     event timeline (one row per event_alerts + injury + weather):     │
│   2026-07-12 09:00 NWS heat advisory issued                                       │
│   2026-07-12 12:30 Judge → IL                                                      │
│   2026-07-12 14:05 Market median ▼ 12% (alert#4413)                               │
│   2026-07-12 16:20 Sales spike +35 in 2h (alert#4419)                             │
│ Why-signals     rows from why_signals (engineered explanations)                    │
│ Revenue         gross / net by source · refund rate                                │
│ Comp events     same matchup history · venue history                               │
└────────────────────────────────────────────────────────────────────────────────────┘
```

---

## GENERIC TEMPLATE

Same shape minus the ESPN section, plus a Performer panel.

### T2/T3 — Pricing tab

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│ HEADER                                                                             │
│ Billie Eilish — Hit Me Hard And Soft Tour · MSG · Sat Aug 16, 8:00p ET             │
│ tier: multi-source       38d to event   ⚠ 2 alerts                                │
│ ── context strip                                                                   │
│   ☀ 78°F clr  •  ✈ summer break  •  🏆 US Open overlap                            │
│   💬 Reddit 6 posts/24h                                                            │
│ [Pricing]  Discovery  Analytics                                                    │
│ [reprice] [push to chat] [pull fresh]                                              │
├────────────────────────────────────────────────────────────────────────────────────┤
│ MERGED CHART (same as sports, no injury markers)                                   │
│ window: [24h] [7d ▣] [30d] [lifetime]                                              │
├────────────────────────────────────────────────────────────────────────────────────┤
│ OWNED vs MARKET TABLE (same shape)                                                 │
├────────────────────────────────────────────────────────────────────────────────────┤
│ PERFORMER PANEL (replaces ESPN section)                                            │
│ [wiki image]                                                                       │
│ Billie Eilish (b. 2001, LA · pop · alt)                                            │
│ Wikipedia · SG name · Tevo perf id · ESPN n/a                                      │
│ ── tour                                                                            │
│   v_performer_tours: 32 venues · 58 shows · 2026-04-22 → 2026-12-15                │
│   regions: US, EU, AU                                                              │
│ ── residency                                                                       │
│   v_performer_residencies: none                                                    │
│ ── reddit  6 posts/24h r/BillieEilish                                              │
├────────────────────────────────────────────────────────────────────────────────────┤
│ RAW DATA TABS  [ EVO ▣ ] [ SeatGeek ]   (same shape, owned highlighted)            │
└────────────────────────────────────────────────────────────────────────────────────┘
```

### T3 single-source modifications

```
HEADER adds:  ◆ Single source (Tevo only)  [Find SG/SD match]
CHART:        market lines for absent sources show as "— awaiting match" overlay
              instead of being silently missing
TABLE:        market rows for absent sources show "— awaiting match"
RAW DATA:     only the available tab is enabled (other tab shows "no data")
```

### T4 generic_t4 — Pending Tevo match

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│ HEADER                                                                             │
│ ◆ Pending Tevo match — SG event 18047738                                           │
│ "Diljit Dosanjh"  ·  Crypto.com Arena  ·  Fri Jun 19 2026                          │
│ tier: pending_match                                                                │
├────────────────────────────────────────────────────────────────────────────────────┤
│ TEvo MATCH CANDIDATES (from v_sg_event_match_proposals)                            │
│ tevo_event_id   name                       venue              date         ovrlap  │
│  3346118        Diljit Dosanjh             Crypto.com Arena   2026-06-19   1.00   │
│                                                                          [queue]  │
│  3346205        Diljit Dosanjh — VIP       Crypto.com Arena   2026-06-19   0.70   │
│                                                                          [queue]  │
│ Already queued (sg_event_match_pending):                                           │
│   #84 → tevo 3346118 · queued by jose@s4k 2h ago · awaiting review                │
├────────────────────────────────────────────────────────────────────────────────────┤
│ SG-SIDE PRICING CHART (single-source only)                                         │
│ ── ours-sg-med · sg-mkt-med · inventory · alerts                                  │
├────────────────────────────────────────────────────────────────────────────────────┤
│ RAW DATA TABS:  EVO disabled (no Tevo event yet)  ·  [ SeatGeek ▣ ]                │
└────────────────────────────────────────────────────────────────────────────────────┘
```

The **[queue]** button calls `queue_sg_event_match(sg_event_id, tevo_event_id, broker_user)`. An admin or cron later calls `approve_sg_event_match(pending_id)` to promote — that write triggers the existing Phase 4 cascade and the page upgrades to T2/T3 on next render.

---

## Component contracts (React)

### `<EventViewPage />`
Top-level. Fetches once, picks template + tier, renders the right shell.

```ts
type EventViewProps = {
  routeKey: { kind: 'tevo'; tevo_event_id: number }
           | { kind: 'sg';   sg_event_id: number };
};
type EventTier = 'multi_source' | 'single_source' | 'pending_match';
type EventTemplate = 'sports' | 'generic';
```

### `<EventHeader />`
Identity + tier badge + days-to-event + alerts + **context strip** + **injuries (sports)** + action bar.

| Slot | Source |
|---|---|
| identity | `events` (or `sg_events_canonical` for T4) |
| tier badge | computed from canonical_external_ids count |
| days-to-event | `event_at_local - now()` |
| alerts count | `event_alerts` for the event_id |
| context strip | `v_event_holidays`, `v_event_school_breaks`, `v_event_weather`, `v_event_nws_alerts`, `v_event_major_calendar`, `v_event_reddit` (count) |
| injuries (sports only) | `v_event_espn_injuries` |
| actions | mutation hooks (`reprice`, `push_to_chat`, `pull_fresh`) |

### `<EventChart />`
The merged multi-axis chart. **Default time window 7d**; falls back to widest available if less data exists.

```ts
type ChartSeries = {
  key: string;                 // e.g. "ours-tevo-med", "sg-mkt-getin"
  axis: 'price' | 'inventory' | 'sales';
  defaultVisible: boolean;
  source: 'ours-tevo' | 'ours-sg' | 'tevo-mkt' | 'sg-mkt' | 'sd-mkt';
  metric: 'med' | 'getin' | 'count' | 'cumulative_sold';
};
type ChartAnnotation = {
  at: string;                  // ISO timestamp
  kind: 'alert' | 'injury' | 'weather' | 'news';
  label: string;
  payload: object;
};
```

Data sources:
- price lines: `listings_snapshots` (Tevo) + `seatgeek_listings_snapshots` rolled up by hour. `is_broker_owned` (SG) and `evo_order_items.event_id` (Tevo) flag the owned subset.
- inventory bars: same source, `count(*)` per hour stacked by source.
- sales velocity: `seatgeek_sales_snapshots` + `seatgeek_orders` + `evo_orders` cumulative.
- alert pins: `event_alerts.captured_at` for `event_id` (sports template also includes alerts on the linked SG event).
- injury markers (sports): `espn_injuries_snapshots` rows where `status` changes within window.
- weather markers: `nws_alerts` overlapping window.

### `<OwnedVsMarketTable />`
Current snapshot, split-rows. One row per `(source, ownership)` × union.

| Source | Sourced from | Ownership flag |
|---|---|---|
| `ours-tevo` | `listings_snapshots` | row.ticket_group_id ∈ owned_inventory |
| `ours-sg` | `seatgeek_seller_listings` | always ours |
| `tevo-mkt` | `listings_snapshots` | NOT ours |
| `sg-mkt` | `seatgeek_listings_snapshots` | `is_broker_owned = false` |
| `sd-mkt` | `seatdata_listings_snapshots` | always market |

Δ24h / Δ7d computed from rolled-up snapshots.

### `<EspnSection />` (sports only)
Renders only when `espn_team_id` is non-null. Game state, standings line, news, rivalry.

| Slot | Source |
|---|---|
| game state | `v_event_espn_state` |
| standings line chart | `espn_team_snapshots` filtered to event's team across season |
| news | `v_event_espn_news` |
| rivalry | `v_event_sporting_rivalries` |

### `<PerformerPanel />` (generic only)
Wikipedia + tour + residency + reddit.

| Slot | Source |
|---|---|
| wiki bio + image | `performer_wikipedia` |
| tour | `v_performer_tours` filtered to `primary_performer_id` |
| residency | `v_performer_residencies` filtered to `primary_performer_id` |
| reddit | `v_event_reddit` (last 30d posts) |

### `<RawDataTabs />`
Two tabs at the page bottom. Each tab is a virtualized table of the most recent N rows for the event, owned rows highlighted.

```
[ EVO ▣ ]  [ SeatGeek ]
listings (default) | sales (toggle)
```

EVO tab columns: `captured_at, section, row, qty, retail_price, our_cost (if owned), is_owned, ticket_group_id, broker_brokerage_name`
SG tab columns: `captured_at, section, row, qty, retail_price_all_in, broadcast_price, is_owned, is_broker_owned, market_source, sg_listing_id`

Owned highlighting: `bg-amber-500/10` row + leading `★` marker. T4 disables the EVO tab (no Tevo event yet).

### `<MatchCandidatesPanel />` (T4 only)
Renders `v_sg_event_match_proposals` for `sg_event_id`. Each row has a **[queue]** button calling `queue_sg_event_match()` RPC. Already-queued items shown as a sub-list with the queued-by user and queued-at timestamp.

---

## Data hooks summary (one place)

| Section | Source(s) |
|---|---|
| Hero KPIs | `events`, `event_metrics`, `seatgeek_event_metrics` |
| Header context strip | `v_event_holidays`, `v_event_school_breaks`, `v_event_weather`, `v_event_nws_alerts`, `v_event_major_calendar`, `v_event_reddit` |
| Header injuries (sports) | `v_event_espn_injuries` |
| Chart prices | `listings_snapshots` + `seatgeek_listings_snapshots` rolled up by hour |
| Chart inventory | same |
| Chart sales | `seatgeek_sales_snapshots`, `seatgeek_orders`, `evo_orders` |
| Chart alerts | `event_alerts` |
| Chart injury markers | `espn_injuries_snapshots` (status change events) |
| Owned vs market table | listings rolled up, current snapshot |
| ESPN game state | `v_event_espn_state` |
| ESPN standings | `espn_team_snapshots` |
| ESPN news | `v_event_espn_news` |
| ESPN rivalry | `v_event_sporting_rivalries` |
| Performer panel | `performer_wikipedia`, `v_performer_tours`, `v_performer_residencies`, `v_event_reddit` |
| EVO raw tab | `listings_snapshots`, `evo_orders`, `evo_order_items` |
| SG raw tab | `seatgeek_listings_snapshots`, `seatgeek_sales_snapshots`, `seatgeek_seller_listings` |
| Sales (combined) raw tab | **`v_event_sales_combined`** — UNION of EVO per-item + SG seller per-order + SG broker per distinct sale (Phase 13) |
| Chart sales scatter | same `v_event_sales_combined`, plotted as scatter on the price pane |
| T4 match candidates | `v_sg_event_match_proposals`, `sg_event_match_pending` |

---

## State machine for the chart time-window selector

```
buckets, in priority order:  [24h] [3d] [7d ▣] [30d] [all]

on mount:
  desired_window = 7d
  earliest_data = MIN(captured_at) across all chart series for the event
  if (now - earliest_data) < desired_window:
       fall back to nearest-smaller bucket that fits the data
       (e.g. 1d of data → 24h is the widest; 4d of data → 3d)
  else:
       use desired_window

user toggles:
  always allowed; show empty plot if window has no data
  selection persists per-event in localStorage
```

---

## Build order (suggested)

1. `<EventViewPage />` shell + routing
2. `<EventHeader />` with merged context+injuries
3. `<EventChart />` — start with price lines + alerts; add inventory + sales toggle in v1.1
4. `<OwnedVsMarketTable />`
5. `<EspnSection />` — only on sports template
6. `<PerformerPanel />` — only on generic template
7. `<RawDataTabs />` — EVO tab first; SG tab second
8. `<MatchCandidatesPanel />` — T4 only; small
9. Discovery + Analytics tabs — share data hooks; ship after Pricing

---

## What lands in PR #51 vs follow-up

**Already in PR #51 (data side):**
- All 12 phases of canonical mapping + drift triggers
- `v_sg_event_match_proposals`, `v_sg_events_by_status`, `v_orphan_seatgeek_data`, `audit_cross_source_health()`
- `queue_sg_event_match()` / `approve_sg_event_match()` / `reject_sg_event_match()` RPCs (used by T4)
- All ESPN / performer / context overlay views referenced by this wireframe

**Follow-up PR(s) (UI side):**
- Build out the React components above
- One follow-up for `<EventChart />` since the multi-axis + annotation logic is non-trivial
- Optional: a small admin page that lists `sg_event_match_pending` rows with `[approve][reject]` buttons (the reviewer side of T4)

---

## Open notes for whoever builds the UI

- The chart needs to handle "no data" gracefully — many T3 events have only one source.
- Annotation density: at >20 markers in a 7d window, cluster them into a single "+N events" pin that expands on click. Otherwise the chart gets unreadable.
- Owned highlighting in raw-data tables should use a tint that's accessible at WCAG-AA (don't rely on color alone — keep the leading ★).
- For T4, hide the chart's "rest of market" lines that would imply Tevo data (since we don't have a tevo_event_id yet); show only SG-side series.
- The 7d default should NOT call out to Tevo's `events` table in any header summary — for T4 events, the event identity comes from `sg_events_canonical`, not `events`.
- Time zone: `events.occurs_at_local` is text with offset (`2026-05-23T20:00:00-04:00`); cast to `timestamptz` for math. The chart's x-axis should display in the venue's local time, derived from the event's offset.
