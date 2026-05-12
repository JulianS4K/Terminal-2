# Performer View — Wireframe v5

**Status:** spec, ready for build (Phase 15 migration to follow)
**Branch:** `claude/audit-datasets-schemas-auoc3` → PR #51
**Spec date:** 2026-05-10

Sister doc to `event-view-wireframe-v4.md`. Where the event view is the per-event live broker page, this is the parent view: per-performer (artist or team) rollup across all upcoming events.

---

## Decisions (locked from product convo)

| Decision | Value |
|---|---|
| Personas | All three (Broker / Scout / Analyst) — single tabbed page |
| Tabs | `Overview` (default) · `Events` · `Analytics` |
| Templates | **Sports team** (when `performer_espn_team_xref` row exists) and **Generic performer** — hardwired |
| Default chart window | **Sports: 30 days** · `[7d] [30d ▣] [season] [lifetime]`<br>**Non-sports: full active tour** · `[tour ▣] [7d] [30d] [lifetime]` |
| Default at-a-glance numbers | Sports: next 30 days · Non-sports: full active tour |
| Event-metric highlights | **Both templates surface min / max / average across all upcoming events for: get-in, ours-med, spread, sell-through, inventory, sales velocity.** Each high/low row links to the event. |
| Aggregate metric charts | **Both templates** — performer-wide rollups: per-event get-in (ranked bar), per-event sell-through (ranked bar), total inventory over time (line), total sales velocity over time (cumulative line), days-to-event vs sell-through (scatter). |
| ESPN expansion | Sports template surfaces all available ESPN data: season W-L progression, home attendance trend, historical win-probability, recent results with covers/attendance, full 26-man roster (sortable), trade/signing transactions, expanded news. |
| Aggregate chart style | **Both — per-event dots overlaid on rolled-up market lines.** One dot per upcoming event at its date (y = that event's median get-in). Rolled-up lines per source (ours-tevo / ours-sg / tevo-mkt / sg-broker / sg-fan) weight-averaged across all upcoming events. |
| Dot color | Sports: home ● vs away ▲ · Non-sports: region (US / EU / AU) chip color |
| Inventory bars | Stacked: **evo-owned / evo-mkt / sg-ours / sg-broker / sg-fan**. SD excluded (sales-only). |
| Sales scatter | ◆ ours · ○ market — both layered onto the chart from `v_event_sales_combined` rolled to performer scope |
| "Comparable" panel | **Competing Nearby Events** — geo-overlap based, rolled up from `v_event_competing_events` across the performer's upcoming venues. Dedup'd; each row carries a `conflict` column showing which of our events it conflicts with. |
| Below-table panel | Sports: **ESPN Team Panel** (standings, recent results, injuries, roster, news, rivalries)<br>Non-sports: **Performer Panel** (wiki, tour, residency, reddit, news) |
| Engineered Signals panel | Performer-level rollup (movers across all events, why-signals, top sections, pricing intel) |
| Header content | Identity + tier badge + days-to-next-event + alert count + context strip + **freshness chips** (per-source) |
| Events tab | **`[Table ▣] [Calendar]` switchable.** Table is sortable/filterable. Calendar is a month grid with chips. Click row/chip → event view. |
| Raw data | Not at performer scope. Drill into an event for raw rows. |
| Analytics tab | Same shape as event Analytics — performer-level lifetime chart + attribution timeline + revenue rollup. (Specced later.) |

---

## Routing

```
performer_id  →  fetch performer + performer_espn_team_xref
                 │
                 ├─ if performer_espn_team_xref row exists  → /performers/[id]?template=sports
                 └─ else                                    → /performers/[id]?template=generic
```

Tier badge inside the chosen template:
- `multi_source` — ≥2 of {tevo, sg_broker, sg_seller, seatdata} represented across upcoming events
- `single_source` — exactly 1
- `no_active_dates` — no upcoming events (header degrades, chart hidden)

---

## SPORTS TEAM TEMPLATE — Overview tab

```
╔══════════════════════════════════════════════════════════════════════════════════════════════════╗
║  ┌────────────────────────────────────────────────────────────────────────────────────────────┐  ║
║  │ [logo]  NEW YORK YANKEES                              tevo_perf 1234 · espn_team 10        │  ║
║  │ MLB · American League · AL East                                                             │  ║
║  │ Season 2026 — record 62-44 · 1st AL East · streak W4 · home Yankee Stadium                 │  ║
║  │ Next game: Astros @ home · 3 days   tier: ESPN sports · multi-source   ⚠ 5 alerts          │  ║
║  ├────────────────────────────────────────────────────────────────────────────────────────────┤  ║
║  │ CONTEXT (team-level)                                                                        │  ║
║  │  🏆 MLB All-Star Wk overlap (next 14d)        🆚 Yankees–Red Sox rivalry                    │  ║
║  │  🩹 Active injuries: Judge DTD · Cole 60-day · Verdugo Q · Stanton 10-day                   │  ║
║  │  📰 News last 14d: 14 articles    💬 r/NYYankees 47 posts/72h                                │  ║
║  │  📡 freshness   ESPN 18m · EVO 4m · SG-list 2m · SG-sales 9m                                 │  ║
║  ├────────────────────────────────────────────────────────────────────────────────────────────┤  ║
║  │ [▣ Overview]   Events   Analytics                          [push to chat] [pull fresh]     │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ AT A GLANCE  (next 30 days) ──────────────────────────────────────────────────────────────┐  ║
║  │  upcoming games:           12         ours gross last 7d:        $84,250                    │  ║
║  │  total mkt inventory:    14.2k        ours active inventory:     142                        │  ║
║  │  median get-in (mkt):       $32       median get-in (ours):      $215                       │  ║
║  │  sell-through 30d:         18.4%      net new listings 24h:      +312                       │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ EVENT METRICS HIGHLIGHTS  (across all upcoming events) ───────────────────────────────────┐  ║
║  │                                                                                              │  ║
║  │  GET-IN                       OURS MEDIAN                  SPREAD (ours − mkt)               │  ║
║  │   highest  $185  BOS 7/28      highest  $315  BOS 7/28      widest    +$172  BOS 7/28        │  ║
║  │   lowest   $102  KC  8/04      lowest   $145  KC  8/04      tightest   +$28  KC  8/04        │  ║
║  │   average  $164                average   $215                average    +$108                 │  ║
║  │                                                                                              │  ║
║  │  SELL-THROUGH                  INVENTORY                    SALES VELOCITY                   │  ║
║  │   highest  41%   BOS 7/28      highest  2.4k  HOU 7/26      highest  315/d  BOS 7/28         │  ║
║  │   lowest    8%   KC  8/04      lowest   1.4k  BOS 7/30      lowest   155/d  KC  8/04         │  ║
║  │   average  18.4%               total   14.2k                total     4.2k                   │  ║
║  │                                                                                              │  ║
║  │  ALERTS              DAYS-TO-EVENT (at first listing)        FIRST/LAST EVENT                 │  ║
║  │   total       5      avg     32d (median 28d)                first  7/26 vs HOU              │  ║
║  │   newest 2h   ENG    oldest  84d   newest  4d                last   8/24 @ TOR               │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ AGGREGATE CHART ──────────────── window: [7d] [30d ▣] [season] [lifetime] ────────────────┐  ║
║  │ ── STANDINGS strip ─────────────────────────────────────────── W-L %                         │  ║
║  │  .65 ┤  ──●NYY                            ╭──────                              .65          │  ║
║  │  .55 ┤   ───────────────╮  ╭──────────────╯                                                  │  ║
║  │  .45 ┤                   ╰──╯                                                                 │  ║
║  │      ├──────────────────────────────────────────────                                          │  ║
║  │ ── PER-EVENT DOTS over ROLLED-UP LINES ─────────────  med $  │  inv# (R)                     │  ║
║  │ $200 ┤      ●BOS    ●BOS                                                       16k           │  ║
║  │      │ ours-med ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                            │  ║
║  │ $150 ┤  ●HOU  ●HOU  ▲SEA  ▲KC  ●BAL  ●BAL ●TB                                                 │  ║
║  │      │ tevo-mkt ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                  12k       │  ║
║  │ $100 ┤ sg-broker ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─                                                │  ║
║  │      │ sg-fan ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                   8k        │  ║
║  │  $50 ┤   ◆        ◆◆     ○      ○○                                                            │  ║
║  │      │ ░░░░░░░░░░░░░░░░░░ evo-owned   ▒▒▒▒▒▒▒▒▒▒▒ evo-mkt   ▓▓▓▓▓▓▓▓▓ sg-* (stacked)  4k     │  ║
║  │      │ ⚾ home  ▲ away  schedule ticks                                                       │  ║
║  │      └────────────────────────── time (next 30d) ─────────                                    │  ║
║  │                                                                                              │  ║
║  │  ● = home game dot · ▲ = away game dot · y = that event's median get-in                      │  ║
║  │  ━━━ rolled-up weight-avg per source across upcoming games at each capture                   │  ║
║  │  Hover dot → quick-card; click → event view                                                  │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ AGGREGATE METRIC CHARTS  (performer-wide rollup) ─────────────────────────────────────────┐  ║
║  │                                                                                              │  ║
║  │  GET-IN ACROSS EVENTS  (ranked high → low)        SELL-THROUGH ACROSS EVENTS  (ranked high)  │  ║
║  │  $185 ┤█ BOS 7/28                                  41% ┤█ BOS 7/28                            │  ║
║  │  $182 ┤█ HOU 7/26                                  28% ┤█ HOU 7/26                            │  ║
║  │  $172 ┤██ HOU 7/27                                 22% ┤██ HOU 7/27                           │  ║
║  │  $165 ┤██ BAL 8/12                                 18% ┤███ BAL 8/12                          │  ║
║  │  $145 ┤███ TB 8/15                                 14% ┤███ TB 8/15                           │  ║
║  │  $130 ┤████ KC 8/06                                 9% ┤████ KC 8/06                          │  ║
║  │  $102 ┤██████ KC 8/04                               7% ┤█████ KC 8/04                         │  ║
║  │       └────────────────                                 └─────────────────                     │  ║
║  │                                                                                              │  ║
║  │  TOTAL INVENTORY OVER TIME  (sum across all upcoming events)                                 │  ║
║  │  20k ┤      ──────────────────                                                                │  ║
║  │  15k ┤   ────                                                                                 │  ║
║  │  10k ┤───                                                                                     │  ║
║  │   5k ┤                                                                                        │  ║
║  │      └──────────────────────                                                                  │  ║
║  │                                                                                              │  ║
║  │  TOTAL SALES VELOCITY  (sum across all upcoming events, last 30d cumulative)                 │  ║
║  │  4.2k ┤                              ╭──                                                      │  ║
║  │  3.0k ┤                       ╭─────╯                                                         │  ║
║  │  2.0k ┤                  ╭────╯                                                               │  ║
║  │  1.0k ┤        ╭─────────╯                                                                    │  ║
║  │       └──────────────────────                                                                 │  ║
║  │                                                                                              │  ║
║  │  DAYS-TO-EVENT vs SELL-THROUGH  (one dot per event)                                          │  ║
║  │  60% ┤                                                                                        │  ║
║  │      │                       ●BOS 7/28                                                        │  ║
║  │  40% ┤            ●HOU                                                                        │  ║
║  │      │       ●BAL                                                                             │  ║
║  │  20% ┤    ●KC               ●TB                                                               │  ║
║  │      └────────────────────────                                                                │  ║
║  │       80d   60d   40d   20d   0d  (days-to-event, descending → today)                        │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ SCHEDULE  (next 14 days) ──────────────────────────────────────────────────────────────────┐  ║
║  │  date         h/a  opponent          venue                tickets  med   Δ7d   sales/d  flags│  ║
║  │  ─────────────────────────────────────────────────────────────────────────────────────────  │  ║
║  │  2026-07-26    H   Houston Astros    Yankee Stadium        2.4k   $182  ▼ 5%   240    🌡     │  ║
║  │  2026-07-27    H   Houston Astros    Yankee Stadium        2.2k   $165  ▼ 3%   210    🌡     │  ║
║  │  2026-07-28    H   Boston Red Sox    Yankee Stadium        1.8k   $185  flat   285    ★🌡   │  ║
║  │  2026-07-29    H   Boston Red Sox    Yankee Stadium        1.6k   $172  ▲ 2%   240    ★     │  ║
║  │  2026-07-30    H   Boston Red Sox    Yankee Stadium        1.4k   $168  ▲ 1%   215    ★     │  ║
║  │  2026-08-01    A   Mariners          T-Mobile Park         1.6k   $142  ▼ 8%   180          │  ║
║  │  2026-08-02    A   Mariners          T-Mobile Park         1.5k   $136  ▼ 6%   165          │  ║
║  │  2026-08-04    A   Royals            Kauffman Stadium       —      —     —      —    🆕    │  ║
║  │  [+ 6 more · sortable · click row to open event view]                                        │  ║
║  │  flags: ★ rivalry · 🆕 just listed · 🌡 weather active · ⚠ alerts · ⛪ branded series         │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ ESPN TEAM PANEL  (expanded with all available ESPN data) ────────────────────────────────┐  ║
║  │                                                                                              │  ║
║  │  STANDINGS                                                                                   │  ║
║  │   AL East  1. NYY 62-44 ──── 2. BAL 58-46  3. TB 56-50  4. BOS 51-55  5. TOR 47-58           │  ║
║  │   playoff seed: AL 1   wildcard cushion: +6 g                                                │  ║
║  │   home/away: 35-19 H · 27-25 A     last 10: W7 L3     run diff: +84                          │  ║
║  │                                                                                              │  ║
║  │  SEASON PROGRESSION  (W-L % over the season — espn_team_snapshots)                           │  ║
║  │   .700 ┤                ╭──── current                                                         │  ║
║  │   .600 ┤             ╭──╯                                                                     │  ║
║  │   .500 ┤   ──╮  ╭────╯                                                                        │  ║
║  │   .400 ┤    ╰──╯                                                                              │  ║
║  │        └── opening day ── all-star ── trade deadline ── now                                  │  ║
║  │                                                                                              │  ║
║  │  HOME ATTENDANCE TREND  (last 30 home games — espn_event_snapshots.attendance)               │  ║
║  │   48k ┤  ●● ●  ●●●  ● ●  ●●  ●●  ●●●●●  ●● ●●●●●●                                            │  ║
║  │   42k ┤●                                                                                      │  ║
║  │   38k ┤            ●●         ● ●                                                             │  ║
║  │       └────────────────────────                                                                │  ║
║  │                                                                                              │  ║
║  │  WIN PROBABILITY TREND  (historical home_win_prob — espn_event_snapshots)                    │  ║
║  │   75% ┤   ●● ●●  ●●●  ●●●●● ●●●●●                                                            │  ║
║  │   55% ┤●●        ●                                                                            │  ║
║  │   35% ┤   ●●         ●  ●  ●                                                                  │  ║
║  │       └──────────────────────────                                                             │  ║
║  │                                                                                              │  ║
║  │  RECENT RESULTS  (last 10)                                                                   │  ║
║  │   7/22 NYY 8-2 vs ATL ★ home   att 47,201   spread NYY -1.5 (covered)                        │  ║
║  │   7/21 NYY 4-3 vs ATL  home    att 46,889   spread NYY -1.0 (covered)                        │  ║
║  │   7/20 NYY 5-2 vs ATL  home    att 47,012   spread NYY -1.5 (covered)                        │  ║
║  │   7/19 NYY 6-1 @ TOR           att 35,400   spread NYY -2.0 (covered)                        │  ║
║  │   7/18 TOR 4-2 vs NYY @ TOR    att 36,801   spread NYY -1.5 (lost)                            │  ║
║  │   [+ 5 more]                                                                                 │  ║
║  │                                                                                              │  ║
║  │  INJURIES (active list)                                                                      │  ║
║  │   Aaron Judge OF       day-to-day        ret 7/29  · WAR 4.8 · OPS .985                     │  ║
║  │   Gerrit Cole RHP      60-day IL         ret 8/15  · ERA 3.05 · WHIP 1.05                   │  ║
║  │   Alex Verdugo OF      questionable      —          · WAR 1.2                                │  ║
║  │   Giancarlo Stanton DH 10-day IL         ret 8/03  · 18 HR · OPS .795                       │  ║
║  │                                                                                              │  ║
║  │  ROSTER  (full 26-man, sortable — espn_athletes filtered to team)                            │  ║
║  │   pos  player              jersey  age  status   key stat                                    │  ║
║  │   ──── ─────────────────── ──────  ───  ───────  ──────────                                  │  ║
║  │   OF   Aaron Judge          99      33   DTD     OPS .985                                    │  ║
║  │   OF   Juan Soto            22      27   active  OPS .950                                    │  ║
║  │   RHP  Gerrit Cole           45      35   IL      ERA 3.05                                   │  ║
║  │   2B   Anthony Volpe         11      25   active  WAR 2.4                                    │  ║
║  │   1B   Anthony Rizzo         48      36   active  HR 14                                      │  ║
║  │   [+ 21 more]                                                                                │  ║
║  │                                                                                              │  ║
║  │  TRANSACTIONS  (last 30 days — espn_athlete_team_history)                                    │  ║
║  │   7/22  signed Devin Williams (RP) from MIL · 1y/$8m                                          │  ║
║  │   7/15  recalled Caleb Durbin from AAA                                                        │  ║
║  │   7/10  optioned Oswaldo Cabrera to AAA                                                       │  ║
║  │                                                                                              │  ║
║  │  TEAM NEWS — last 14 days  (espn_news, expanded)                                              │  ║
║  │   [thumb] "Judge progressing in rehab"             ESPN · 2d   [open]                         │  ║
║  │   [thumb] "Cole expected back mid-August"          ESPN · 4d   [open]                         │  ║
║  │   [thumb] "Yankees acquire bullpen arm at deadline" ESPN · 6d   [open]                        │  ║
║  │   [thumb] "Soto contract talks heating up"         ESPN · 7d   [open]                         │  ║
║  │   [thumb] "Boone discusses rotation plans"         ESPN · 8d   [open]                         │  ║
║  │   [+ 9 more]                                                                                 │  ║
║  │                                                                                              │  ║
║  │  RIVALRIES & BRANDED SERIES                                                                  │  ║
║  │   Yankees–Red Sox    ★ branded · high · MLB Sunday Night Bsbll                                │  ║
║  │   Subway Series (Mets)   ★ branded · medium                                                  │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ ENGINEERED SIGNALS  (team-level, last 30d) ───────────────────────────────────────────────┐  ║
║  │  TOP MOVERS                                                                                  │  ║
║  │   • 7/28 vs BOS  mkt med ▼6.2% on +18% inventory                                             │  ║
║  │   • 7/27 vs HOU  mkt med ▼3.8% on +12% inventory                                             │  ║
║  │  WHY-SIGNALS ROLLUP                                                                          │  ║
║  │   • Heat advisories trending up — outdoor venue                                              │  ║
║  │   • Cole IL announcement → rotation pressure on home games                                   │  ║
║  │   • Judge return imminent → upside risk on home games next week                              │  ║
║  │  HOTTEST SECTION ACROSS HOME GAMES  (section_metrics rolled up)                              │  ║
║  │   207     avg med $245   listings 1.1k    drift ▼14%                                         │  ║
║  │   209L    avg med $310   listings 740     drift ▼ 7%                                         │  ║
║  │   320     avg med $112   listings 380     drift ▼21%                                         │  ║
║  │  PRICING INTEL  (pricing_intel_unified rolled up)                                            │  ║
║  │   • signal: rivalry games getting tighter spreads — opportunity to widen                     │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ COMPETING NEARBY EVENTS  (next 30d, ≤25 mi from any of our home/away venues, ±6h) ────────┐  ║
║  │  competing event                  competing venue           date       Δh   mi   conflict    │  ║
║  │  ────────────────────────────────────────────────────────────────────────────────────────── │  ║
║  │  Mets vs Phillies                  Citi Field               7/28 1:10p −5.9 9.2  NYY 7/28   │  ║
║  │  Bruce Springsteen — The Tour       Citi Field               7/28 8:00p +0.9 9.2  NYY 7/28   │  ║
║  │  Hamilton                           Richard Rodgers Theatre  7/28 7:00p −0.1 6.8  NYY 7/28   │  ║
║  │  Stevie Wonder                      Madison Square Garden    7/29 8:00p +0.9 8.3  NYY 7/29   │  ║
║  │  Mariners vs Red Sox                T-Mobile Park            8/01 7:10p +0.0 0.0  NYY 8/01   │  ║
║  │  [+ N more · click row for that event]                                                       │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
╚══════════════════════════════════════════════════════════════════════════════════════════════════╝
```

### Sports Events tab

```
[▣ Overview]  [Events ▣]  Analytics
┌─ EVENTS  [Table ▣] [Calendar] ──── filter: [date ▾] [opponent ▾] [home/away ▾] [alerts ▾] ────┐
│ Table: full sortable schedule (all upcoming + last 30 played, toggle)                         │
│ Calendar: month grid with one chip per game; chip color = ours sell-through band              │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## NON-SPORTS PERFORMER TEMPLATE — Overview tab

```
╔══════════════════════════════════════════════════════════════════════════════════════════════════╗
║  ┌────────────────────────────────────────────────────────────────────────────────────────────┐  ║
║  │ [wiki image]  BILLIE EILISH                              tevo_perf 412067                   │  ║
║  │ Pop · alt · electronic                                                                       │  ║
║  │ Active tour: Hit Me Hard And Soft Tour · 32 venues · 58 shows · regions US, EU, AU          │  ║
║  │ Next show: Madison Square Garden · 6 days   tier: multi-source   ⚠ 4 alerts                │  ║
║  ├────────────────────────────────────────────────────────────────────────────────────────────┤  ║
║  │ CONTEXT (tour-level)                                                                        │  ║
║  │  🎵 New single "BIRDS OF A FEATHER" climbing Billboard · #14                                  │  ║
║  │  🏷 Tour partner Spotify · venue partner Live Nation                                          │  ║
║  │  💬 r/BillieEilish 47 posts/72h         📰 News last 14d: 22 articles                         │  ║
║  │  📡 freshness   EVO 3m · SG-list 2m · SG-sales 9m · reddit 18m                                │  ║
║  ├────────────────────────────────────────────────────────────────────────────────────────────┤  ║
║  │ [▣ Overview]   Events   Analytics                          [push to chat] [pull fresh]     │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ AT A GLANCE  (full active tour) ──────────────────────────────────────────────────────────┐  ║
║  │  upcoming shows (US):       18         ours gross last 7d:       $42,180                    │  ║
║  │  total mkt inventory:    24.6k         ours active inventory:    87                         │  ║
║  │  median get-in (mkt):      $172        median get-in (ours):     $475                       │  ║
║  │  sell-through 30d:         22.1%       net new listings 24h:     +540                       │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ EVENT METRICS HIGHLIGHTS  (across all upcoming shows) ────────────────────────────────────┐  ║
║  │                                                                                              │  ║
║  │  GET-IN                       OURS MEDIAN                  SPREAD (ours − mkt)               │  ║
║  │   highest  $610  NYC 8/16      highest  $720  NYC 8/16      widest    +$272  NYC 8/16        │  ║
║  │   lowest   $402  RAL 8/25      lowest   $498  RAL 8/25      tightest  +$96   RAL 8/25        │  ║
║  │   average  $478                average   $610                average    +$132                 │  ║
║  │                                                                                              │  ║
║  │  SELL-THROUGH                  INVENTORY                    SALES VELOCITY                   │  ║
║  │   highest  92%   NYC 8/16      highest  2.2k  NYC 8/16      highest  315/d  NYC 8/16         │  ║
║  │   lowest   12%   ATL 8/27      lowest   1.4k  RAL 8/25      lowest   155/d  RAL 8/25         │  ║
║  │   average  22.1%               total   24.6k                total     5.4k                   │  ║
║  │                                                                                              │  ║
║  │  ALERTS              DAYS-TO-EVENT (at first listing)        FIRST/LAST EVENT                 │  ║
║  │   total       4      avg     56d (median 48d)                first  8/16 MSG                  │  ║
║  │   newest 4h   PHI    oldest  120d  newest 8d                 last   12/15 LA                  │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ AGGREGATE CHART ────────────── window: [tour ▣] [7d] [30d] [lifetime] ─────────────────────┐  ║
║  │ ── PER-EVENT DOTS over ROLLED-UP LINES ─────────────  med $  │  inv# (R)                     │  ║
║  │ $700 ┤    ●NYC#1                                                                  25k        │  ║
║  │      │ ours-med ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                            │  ║
║  │ $500 ┤              ●LA  ●BOS                                                     20k        │  ║
║  │      │                          ●ATL                                                          │  ║
║  │ $400 ┤ tevo-mkt ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                              │  ║
║  │      │ sg-broker ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─                                       15k        │  ║
║  │ $300 ┤ sg-fan ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                                  │  ║
║  │      │  ⬆ alert#5022 NYC sold out                                                             │  ║
║  │      │   ◆     ◆◆     ○      ○○                                                  10k          │  ║
║  │ $200 ┤                                                                                        │  ║
║  │      │ ░░░░░░░░░░░ evo-owned   ▒▒▒▒▒▒▒ evo-mkt   ▓▓▓▓▓▓▓ sg-* (stacked)             5k        │  ║
║  │      └────────────────────── time (full active tour) ──────────                                │  ║
║  │                                                                                              │  ║
║  │  ● = show dot at its date · y = show's median get-in · color band = region (US / EU / AU)    │  ║
║  │  ━━━ rolled-up weight-avg per source across upcoming shows at each capture                   │  ║
║  │  Hover dot → quick-card; click → event view                                                  │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ AGGREGATE METRIC CHARTS  (tour-wide rollup) ──────────────────────────────────────────────┐  ║
║  │                                                                                              │  ║
║  │  GET-IN ACROSS SHOWS  (ranked high → low)         SELL-THROUGH ACROSS SHOWS  (ranked high)   │  ║
║  │  $610 ┤█ NYC 8/16                                  92% ┤█ NYC 8/16                            │  ║
║  │  $585 ┤█ NYC 8/17                                  88% ┤█ NYC 8/17                            │  ║
║  │  $510 ┤██ BOS 8/23                                 64% ┤██ BOS 8/23                           │  ║
║  │  $478 ┤██ PHI 8/19                                 38% ┤███ PHI 8/19                          │  ║
║  │  $452 ┤███ DC  8/20                                32% ┤████ DC  8/20                         │  ║
║  │  $445 ┤███ ATL 8/27                                12% ┤██████ ATL 8/27                       │  ║
║  │  $402 ┤████ RAL 8/25                               18% ┤█████ RAL 8/25                        │  ║
║  │       └────────────────                                 └─────────────────                     │  ║
║  │                                                                                              │  ║
║  │  TOTAL INVENTORY OVER TIME  (sum across all upcoming shows, full tour)                       │  ║
║  │  35k ┤      ──────────────────                                                                │  ║
║  │  25k ┤   ────                                                                                 │  ║
║  │  15k ┤───                                                                                     │  ║
║  │      └──────────────────────                                                                  │  ║
║  │                                                                                              │  ║
║  │  TOTAL SALES VELOCITY  (sum across all upcoming shows, last 30d cumulative)                  │  ║
║  │  5.4k ┤                              ╭──                                                      │  ║
║  │  3.5k ┤                       ╭─────╯                                                         │  ║
║  │  2.0k ┤                  ╭────╯                                                               │  ║
║  │  0.8k ┤        ╭─────────╯                                                                    │  ║
║  │       └──────────────────────                                                                 │  ║
║  │                                                                                              │  ║
║  │  DAYS-TO-EVENT vs SELL-THROUGH  (one dot per show; chip color = region)                      │  ║
║  │  90% ┤                       ●NYC 8/16                                                        │  ║
║  │  60% ┤                  ●BOS                                                                  │  ║
║  │  40% ┤            ●PHI                                                                        │  ║
║  │  20% ┤      ●ATL                ●RAL                                                          │  ║
║  │      └──────────────────────────                                                              │  ║
║  │       120d  90d   60d   30d   0d  (days-to-event)                                            │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ SHOWS  (next 14 dates) ────────────────────────────────────────────────────────────────────┐  ║
║  │  date         venue                          city         tickets  med    Δ7d  sales/d  flags│  ║
║  │  ─────────────────────────────────────────────────────────────────────────────────────────  │  ║
║  │  2026-08-16   Madison Square Garden          New York     2.2k    $610   ▲2%   315    ★      │  ║
║  │  2026-08-17   Madison Square Garden          New York     1.9k    $585   ▲1%   270    ★      │  ║
║  │  2026-08-19   Wells Fargo Center             Philadelphia 2.1k    $478   ▼3%   220           │  ║
║  │  2026-08-20   Capital One Arena              Washington   1.6k    $452   ▼2%   180           │  ║
║  │  2026-08-23   TD Garden                      Boston       1.7k    $510   ▼1%   210           │  ║
║  │  2026-08-25   PNC Arena                      Raleigh      1.4k    $402   flat  155           │  ║
║  │  2026-08-27   State Farm Arena               Atlanta      1.8k    $445   ▼4%   190     🆕   │  ║
║  │  [+ 11 more · click row to open event view]                                                  │  ║
║  │  flags: ★ MSG run · 🆕 just listed · 🎟 sold out · ⚠ alerts                                   │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ PERFORMER PANEL ───────────────────────────────────────────────────────────────────────────┐  ║
║  │  [wiki image]                                                                                │  ║
║  │  Billie Eilish O'Connell Pirate Baird   b. 2001 · Los Angeles                                │  ║
║  │  Pop / alt / electronic                                                                      │  ║
║  │  Wikipedia summary  ·  9× Grammy · 2 Academy Awards (songwriting)                           │  ║
║  │  ACTIVE TOUR   Hit Me Hard And Soft   32 venues · 58 shows · 4/22 → 12/15                    │  ║
║  │                regions: US (38), EU (14), AU (6)                                             │  ║
║  │  RESIDENCY     none active                                                                    │  ║
║  │  REDDIT  r/BillieEilish · 47/72h                                                             │  ║
║  │   • "MSG seating chart for the floor — anyone been?"   324 ↑                                │  ║
║  │   • "BIRDS OF A FEATHER live debut at LA show"          212 ↑                               │  ║
║  │   • "Tour merch lineup leaked"                          178 ↑                               │  ║
║  │  RECENT NEWS — last 14 days                                                                  │  ║
║  │   [thumb] "Eilish announces extra MSG date due to demand"   Pitchfork · 3d  [open]           │  ║
║  │   [thumb] "Hit Me Hard And Soft tops album charts again"    Billboard · 6d  [open]           │  ║
║  │   [+ 5 more]                                                                                 │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ ENGINEERED SIGNALS  (tour-level, full active tour) ───────────────────────────────────────┐  ║
║  │  TOP MOVERS                                                                                  │  ║
║  │   • 8/16 NYC #1   sold out, sg-fan med ▲22%                                                  │  ║
║  │   • 8/27 ATL      mkt med ▼9% on +14% inventory                                              │  ║
║  │  WHY-SIGNALS ROLLUP                                                                          │  ║
║  │   • New single drove +18% reddit chatter                                                     │  ║
║  │   • Extra MSG date added → spillover demand to PHI/DC                                        │  ║
║  │   • Tour merch announcement                                                                  │  ║
║  │  HOTTEST SECTION ACROSS TOUR                                                                 │  ║
║  │   GA       avg med $312   listings 4.2k   drift ▼12%                                         │  ║
║  │   Floor    avg med $710   listings 1.6k   drift ▼ 6%                                         │  ║
║  │   Lower    avg med $478   listings 2.8k   drift ▼ 8%                                         │  ║
║  │  PRICING INTEL                                                                               │  ║
║  │   • signal: ours-med 65% above sg-fan-med tour-wide → systematic over-price                  │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                                    ║
║  ┌─ COMPETING NEARBY EVENTS  (active tour, ≤25 mi from any tour stop, ±6h) ───────────────────┐  ║
║  │  competing event                       competing venue           date       Δh   mi  conflict│  ║
║  │  ─────────────────────────────────────────────────────────────────────────────────────────  │  ║
║  │  Yankees vs Astros                      Yankee Stadium            8/16 7:05p −0.9 9.6  BIL 8/16│  ║
║  │  The Book of Mormon                     Eugene O'Neill Theatre    8/16 8:00p +0.0 0.5  BIL 8/16│  ║
║  │  John Mayer                             Forest Hills Stadium      8/16 7:00p −1.0 12.4 BIL 8/16│  ║
║  │  76ers preseason                        Wells Fargo Center        8/19 7:30p −0.5 0.0  BIL 8/19│  ║
║  │  Capitals preseason                     Capital One Arena         8/20 7:00p −1.0 0.0  BIL 8/20│  ║
║  │  [+ N more]                                                                                  │  ║
║  └────────────────────────────────────────────────────────────────────────────────────────────┘  ║
╚══════════════════════════════════════════════════════════════════════════════════════════════════╝
```

### Non-sports Events tab

```
[▣ Overview]  [Events ▣]  Analytics
┌─ EVENTS  [Table ▣] [Calendar] ──── filter: [date ▾] [city ▾] [region ▾] [alerts ▾] ───────────┐
│ Table: full sortable tour schedule.                                                            │
│ Calendar: month grid with one chip per show; chip color = ours sell-through band              │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Component contracts

```ts
type PerformerTemplate = 'sports' | 'generic';
type PerformerTier = 'multi_source' | 'single_source' | 'no_active_dates';
type AggregateChartWindow =
  | 'tour'                          // non-sports default
  | 'season'                        // sports option
  | '7d' | '30d' | 'lifetime';

type ChartDot = {
  event_id: number;
  at: string;                       // event date
  median_price: number;
  source_color: 'home' | 'away'     // sports
              | 'us' | 'eu' | 'au'; // non-sports
};

type RolledUpSeries = {
  source: 'ours-tevo' | 'ours-sg' | 'tevo-mkt' | 'sg-broker' | 'sg-fan';
  metric: 'med' | 'getin';
  points: { at: string; weighted_avg: number }[];
};

type CompetingNearbyRow = {
  competing_event_id: number;
  competing_event_name: string;
  competing_venue_name: string;
  competing_occurs_at: string;
  hours_apart: number;
  distance_miles: number;
  conflict_event_id: number;        // which of our events this conflicts with
  conflict_event_label: string;     // e.g., "NYY 7/28" or "BIL 8/16"
};
```

New components:

| Component | Purpose |
|---|---|
| `<PerformerHeader />` | Identity + tier + days-to-next + alerts + context strip + freshness chips |
| `<AtAGlance />` | 4-cell summary block (sports rolled to 30d, non-sports rolled to active tour) |
| `<AggregateChart />` | Standings strip (sports only) + per-event dots overlaid on rolled-up market lines + inventory bars + sales scatter |
| `<ScheduleTable />` (sports) / `<ShowsTable />` (non-sports) | Compact 14-day cut, sortable; click row → event view |
| `<EspnTeamPanel />` (sports) | Standings + recent results + injuries + roster + news + rivalries |
| `<PerformerPanel />` (non-sports) | Wiki + tour + residency + reddit + recent news |
| `<EngineeredSignalsPanel />` (performer scope) | Movers + why-signals + hot sections + pricing intel rolled across all upcoming events |
| `<CompetingNearbyPanel />` | Rolled-up `v_event_competing_events` with `conflict` column |
| `<EventsTab />` | Switchable `<EventsTable />` ↔ `<EventsCalendar />` |

---

## Data hooks

| Section | Source(s) |
|---|---|
| Header identity | `events` (latest), `performer_wikipedia`, `performer_espn_team_xref`, `espn_teams` |
| Header context (sports) | `v_event_sporting_rivalries`, `v_event_espn_injuries` (rolled to performer), `v_event_espn_news` (rolled), `v_event_reddit` (rolled) |
| Header context (non-sports) | `v_performer_tours` for active-tour line, `v_event_reddit` (rolled), `news` table (when wired), Billboard/charts (future) |
| Header freshness | new view: **`v_performer_data_freshness`** (similar to `v_event_data_freshness` but rolled to performer) |
| At-a-glance | new view: **`v_performer_aggregate_metrics`** (sports rolled to 30d, non-sports rolled to active tour) |
| Aggregate chart — dots | new view: **`v_performer_upcoming_events`** (one row per event with med/get-in) |
| Aggregate chart — lines | rolled hourly weighted avg across `v_seatgeek_listings_classified` + `listings_snapshots` for the performer's upcoming events |
| Aggregate chart — bars | `v_seatgeek_listings_classified` + `listings_snapshots` rolled by ownership_class |
| Aggregate chart — sales scatter | `v_event_sales_combined` rolled to performer scope |
| Aggregate chart — standings (sports) | `espn_team_snapshots` filtered to the team |
| Schedule / Shows table | `v_performer_upcoming_events` |
| ESPN Team Panel | `espn_teams`, `espn_team_snapshots`, `espn_athletes`, `espn_injuries_snapshots`, `espn_news`, `v_event_sporting_rivalries` |
| Performer Panel | `performer_wikipedia`, `v_performer_tours`, `v_performer_residencies`, `v_event_reddit` (rolled), `news` (rolled) |
| Engineered Signals | `event_movers_v3_owned_share` + `why_signals` + `section_metrics` + `pricing_intel_unified` rolled to performer |
| Competing Nearby | `v_event_competing_events` UNION'd across upcoming events for this performer, dedup'd, with `conflict_event_id` |
| Events tab calendar | same as schedule, grouped by month/week |

---

## Phase 15 view plan

Sixteen views (10 core + 6 sports-only ESPN expansions).

### Core (both templates)

| # | View | Purpose | Inputs |
|---|---|---|---|
| 1 | `v_performer_summary` | identity + active-tour line + season record (sports) | `events`, `v_performer_tours`, `v_performer_residencies`, `performer_espn_team_xref`, `espn_teams`, `espn_team_snapshots`, `performer_wikipedia` |
| 2 | `v_performer_upcoming_events` | one row per upcoming event with median, get-in, qty, Δ24h, Δ7d, sell-through, alert count, source split, home/away (sports), region (non-sports), days_to_event | `events`, `v_seatgeek_listings_classified`, `listings_snapshots`, `event_metrics`, `event_alerts` |
| 3 | `v_performer_aggregate_inventory` | rolled-up totals by ownership_class | (2) |
| 4 | `v_performer_aggregate_sales` | rolled-up sales over a time window | `v_event_sales_combined` |
| 5 | `v_performer_event_highlights` | min/max/avg across performer's upcoming events for: get-in, ours-med, spread, sell-through, inventory, sales velocity, days-to-event. Each min/max row carries the event_id that achieved it. | (2), `v_event_sales_combined` |
| 6 | `v_performer_inventory_timeseries` | hourly sum(inventory_count) across all upcoming events, by ownership_class | (2), `seatgeek_listings_snapshots`, `listings_snapshots` |
| 7 | `v_performer_sales_timeseries` | hourly sum(qty) and sum(price*qty) across all upcoming events from `v_event_sales_combined`; cumulative variants | `v_event_sales_combined`, (2) |
| 8 | `v_performer_section_drift` | `section_metrics` rolled across upcoming events | `section_metrics`, (2) |
| 9 | `v_performer_competing_nearby` | dedup'd union of `v_event_competing_events` across performer's upcoming venues, with `conflict_event_id` and `conflict_event_label` | `v_event_competing_events`, (2) |
| 10 | `v_performer_data_freshness` | per-source most-recent timestamp across the performer's upcoming events | `v_event_data_freshness` rolled by performer |

### Sports-only ESPN expansions

| # | View | Purpose | Inputs |
|---|---|---|---|
| 11 | `v_team_season_progression` | espn_team_snapshots series across the season for a team — for the W-L % progression chart | `espn_team_snapshots`, `performer_espn_team_xref` |
| 12 | `v_team_recent_results` | last N games with score, attendance, spread, cover-flag | `espn_event_snapshots`, `performer_espn_team_xref` |
| 13 | `v_team_attendance_trend` | last N home games attendance for the trend chart | `espn_event_snapshots` filtered home-only |
| 14 | `v_team_win_prob_trend` | historical home_win_prob across past games for the trend chart | `espn_event_snapshots` |
| 15 | `v_team_roster_full` | espn_athletes filtered to team with key stats from `meta` jsonb | `espn_athletes`, `performer_espn_team_xref` |
| 16 | `v_team_transactions` | last N days of athlete movement for the team | `espn_athlete_team_history`, `performer_espn_team_xref` |
| 17 (opt) | `v_team_schedule_30d` | next-30d home/away schedule with rivalry/branded flag | `events` filtered via `performer_espn_team_xref`, `v_event_sporting_rivalries` |

---

## Build order (suggested)

1. Phase 15 migration (10 core views + 6 sports ESPN views = 16 total)
2. `<PerformerViewPage />` shell + routing
3. `<PerformerHeader />` with freshness + context
4. `<AtAGlance />` with the 4-cell summary
5. `<EventMetricsHighlights />` with min/max/avg cards (clickable to event)
6. `<AggregateMetricCharts />` — 5 small charts (get-in ranked, sell-through ranked, inventory over time, sales over time, days-to-event scatter)
5. `<AggregateChart />` — dots + lines + bars + scatter; standings strip on sports only
6. `<ScheduleTable />` / `<ShowsTable />` (compact 14-day cut)
7. `<EspnTeamPanel />` (sports only)
8. `<PerformerPanel />` (non-sports only)
9. `<EngineeredSignalsPanel />` performer-scope
10. `<CompetingNearbyPanel />`
11. `<EventsTab />` table-first
12. `<EventsTab />` calendar view
13. Analytics tab

---

## Open work / blocked

- **Cost / margin** — blocked on cost ingest (same as event view).
- **Tour benchmark detail** — past-tour `v_performer_tour_history` join to `event_metrics` (avg fill, avg get-in across stops). Specced in event view v4 as deferred; may live here at the performer scope instead.
- **Aggregate chart rolled-line pre-roll** — if client-side weight-avg is too slow on large tours, add `v_performer_aggregate_price_timeseries` materialized hourly. Defer until measured.
- **News rollup** for non-sports — currently uses ESPN news only; non-sports needs a different source (Pitchfork/Billboard/etc.) — TBD.
- **Calendar chip color band** — needs a `sell_through_band` enum derived from `v_performer_upcoming_events.sell_through` (e.g. hot/normal/cold). Add when building the calendar view.
- **Time zone** — performer rollups span time zones; chart x-axis should normalize to UTC and render labels per the active filter (or per the next-event venue tz).
