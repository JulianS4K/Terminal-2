# Edge cases + UI elements + persona modes — third simulation doc (2026-05-08)

> **Audience**: claude design + Julian.
>
> **Trio context**:
> - `design/simulations-non-sports-2026-05-08.md` — 15 sims (Concerts/Comedy/Theater)
> - `design/simulations-sports-2026-05-08.md` — 30 sims (NBA/NFL/MLB/NHL/WNBA/MLS/F1+T+G)
> - **THIS DOC** — edge cases + UI element specifics + persona modes that cut across all 45 sims
>
> **Calibration baseline**: `design/data-reality-2026-05-08.md` (all sims here designed for current data state, with degrade-and-grow paths).
>
> **Mandate (Julian)**: cover ESPN-only views, raw-pricing-only views, multi-tab parallel investigations, custom-zone deep dive, real-time element placements, hide/show patterns per persona, day-trader feel.

---

## 0. TL;DR

The first two sim docs covered "what scenarios does the terminal solve?". This doc covers **how the broker uses the terminal across modes** — keyboard-first triage, multi-tab parallel work, the moments when only one data source matters, the moments when the data is too thin or too fresh to be useful. **24 edge cases + UI element specs**, each with a tight description and rendering decision.

---

## 1. Persona modes (the same broker, different mental states)

A single broker shifts between 5 modes during a workday. The terminal has to support each without forcing a context-switch tax.

### M1 · Triage mode — scan-a-watchlist in 30 seconds
- **What**: opens 9 AM, eyes the morning, identifies the day's 3-5 priority events.
- **Surface**: Home dashboard with risk-alerts strip + top-movers strip. Movers default-sorted by absolute notional Δ in last 24h.
- **UI elements**:
  - Sticky 4-line summary at top: $ at risk, # events at risk, holds expiring < 1h, pricer Filter Red rows.
  - Click any element → drilldown opens in a NEW tab (preserves the triage view).
  - Keyboard: `?` opens help; `g h` returns to home; `g w` opens watchlist; `1-9` jumps to the Nth row.
- **Time budget**: 30 sec.
- **Day-trader analog**: market open, scan SPX + watchlist for gappers.

### M2 · Pricing mode — deep work on one event
- **What**: lands on a single event for 5-15 minutes. Opens the Event Workbench.
- **Surface**: Event Workbench (T1) full chart workbench, all panels visible.
- **UI elements**:
  - Real-time sales tape on chart (every clearance dots in at sold-price + sold-time).
  - Owned-premium KPI front and center.
  - Sentiment ribbon below chart.
  - Zone breakdown deep view (drawer for any zone shows full pricer config).
  - Custom-zone overlay toggle.
  - Per-quantity ladder (SG2-SG6) on hover or in KPI grid.
- **Time budget**: 5-15 min.
- **Day-trader analog**: drilling into a single ticker for the day's trade idea.

### M3 · Ops mode — fulfillment + holds
- **What**: deliver outstanding orders, handle holds about to expire, manage the queue.
- **Surface**: Undelivered Window. Pinned hold-expiry banner.
- **UI elements**:
  - Hold-expiry lane at top with live countdowns.
  - Bulk action: "Deliver all N for this event" appears on ≥5 same-event undelivered orders.
  - Per-row drawer with timeline (sold → claimed → e-ticket downloaded → pushed).
  - 3-tier notes drawer (public / private / broker) — color-coded by audience.
- **Time budget**: continuous low-attention background; spikes during pre-game.
- **Day-trader analog**: clearing fills + reconciling positions.

### M4 · Analytical mode — investigation across many events
- **What**: "why did Knicks-home prices drop 15% this week?" — investigation that spans events, performers, zones.
- **Surface**: Performer Console + Comparable Matchups + Cross-Source Explorer (when ready). Multi-tab investigation.
- **UI elements**:
  - Multi-tab: 1 tab per investigative thread.
  - Cross-tab linking — "open in new tab" on every drillable element.
  - Saved analytical zones (cross-event cuts).
  - Side-by-side compare (split-screen for any 2 events / performers / zones).
- **Time budget**: 30 min - 2h.
- **Day-trader analog**: post-mortem on a position; long-form research.

### M5 · Power-user batch mode — Pricing Queue
- **What**: rip through 47 events updating suggested asks. Keyboard-only.
- **Surface**: Pricing Queue (T4) full-screen.
- **UI elements**:
  - One event card at a time, all relevant metrics + comparables + sentiment + per-quantity ladder.
  - Keyboard: `J/K` next/prev, `[/]` adjust price, `space` save+advance, `Esc` exit, `?` help.
  - ETA ticker at top: "12 of 47 · ~22 min remaining".
  - Auto-saves cursor + suggested asks.
- **Time budget**: 30-90 min sessions.
- **Day-trader analog**: end-of-day rebalancing across the book.

**Rule**: NO mode requires the user to navigate AWAY from the surface they're working on to find an answer. If they need data, it's either visible OR one keyboard shortcut away OR opens in a new tab without disturbing the current work.

---

## 2. Edge-case views (the special-purpose modes Julian called out)

### E1 · ESPN-only view — context layer, no prices
- **When**: pre-event analyst session. "I want to read about the Knicks tonight; I don't care about prices yet."
- **Surface**: T1 Event Workbench with **a single hide toggle** that collapses every pricing panel and expands ESPN data:
  - Standings + record + streak (full)
  - Player roster (when athletes ingested)
  - Injury report (active + recent)
  - News feed (last 7d)
  - Comparable matchups (without retail/owned/premium columns)
- **Toggle**: top-right "ESPN-only mode" pill. Persists in localStorage.
- **Use case**: pre-game brief, post-trade-deadline analysis, scouting an opponent.

### E2 · Raw-pricing-only view — no ESPN, no narrative
- **When**: pricer in the middle of a live update. "I just want the numbers; don't show me Brunson's Q tag right now."
- **Surface**: T1 with ESPN block, news, sentiment, comparables ALL hidden. Just:
  - Chart band (price + qty + sentiment ribbon stripped)
  - Zone breakdown deep view
  - Per-quantity ladder
  - Order book strip
- **Toggle**: top-right "Pricing-only mode" pill.
- **Use case**: M5 (batch pricing), M2 (final pricing tune-up).

### E3 · Custom-zone deep dive — analytical cut, not a section
- **When**: broker defines "Front 10 rows + GA standing" as a saved analytical zone. Wants to see it across N events.
- **Surface**: NEW Custom Zone Workbench. Side-by-side:
  - LEFT: zone definition (predicate over section + row + category + price-floor)
  - CENTER: across-event timeline showing this cut's median retail per event
  - RIGHT: per-event drilldown of inventory matching the cut
- **Operations**:
  - Save / rename / share custom zones (per-user, optional team-share).
  - Apply across any list of events (filter the inventory grid).
  - Compare two custom zones side-by-side.
- **Schema**: NEW `user_custom_zones` table (per `terminal-only-redesign §4`).

### E4 · Multi-tab parallel investigation
- **When**: M4 mode. 3 tabs open: "Pricer-Knicks-week" / "Pricer-MLS-leagues-cup" / "Performer-Madonna-tour".
- **UI**:
  - Saved-search tabs at top (per existing system screenshots).
  - Each tab is a fully-formed view; switching is instant.
  - Cross-tab alerts: a tab not currently visible can flash a red dot on its label if a price-filter-red event fires.
  - Keyboard: `Cmd-1..9` jumps to tab N; `Cmd-T` opens new tab; `Cmd-W` closes.
- **State**: per-tab cursor + filters persisted server-side.

### E5 · Compare two events side-by-side
- **When**: "Knicks G5 vs Knicks G6 — should they price differently?"
- **Surface**: split-screen Event Workbench, each half showing T1 in compact mode. Linked timelines (same x-axis).
- **Trigger**: from any Event Workbench, "Compare with..." action → opens a search picker.
- **Constraints**: only 2 events at a time (3+ becomes unreadable in horizontal split).

### E6 · Compare two zones across one event
- **When**: "How does 100 End vs 100 Garbage premium math compare?"
- **Surface**: in T1 zone-breakdown drawer, multi-select 2 zones → "Compare zones" button.
- **Result**: side-by-side mini-charts of each zone's price + qty + sales velocity.

---

## 3. Data-state edge cases

These are the "what does the UI show when data is thin?" scenarios. Calibrated to current Supabase reality.

### D1 · Event with NO ESPN linkage
- **Frequency**: ~70% of game events today (1228 games − 428 espn-linked).
- **Render**: ESPN block hidden entirely. Replace slot with "ESPN data not yet linked for this event" + a small "request match" button (queues a manual xref task for code).
- **Comparable matchups**: still works via TEvo-only similarity.

### D2 · Event with NO order data yet
- **Frequency**: vast majority today (until SG xref backfill + EVO secret).
- **Render**: order book strip shows "No orders yet — SG xref pending" with a `sources_count` badge explaining what's linked.
- **Pricing Queue**: still works; just no historical-orders comparison.

### D3 · Event with `event_sentiment` unpopulated
- **Frequency**: ~616 of 634 events (only 18 sentiment rows today).
- **Render**: sentiment ribbon greys out with "Not yet computed" tooltip. KPI cell shows "—". The ribbon spot stays reserved.
- **Manual trigger**: "Compute sentiment for this event" action queues `compute_buyer_sentiment(event_id)`.

### D4 · Event with NO comparable matchups
- **When**: a brand-new performer's first event in our system, a one-off venue, an unusual matchup (e.g., All-Star skills competition).
- **Render**: comparables strip shows "No comparable events found in our history" + a 'broaden criteria' link (drops similarity threshold from 0.6 → 0.3 → 0.0).

### D5 · Event with NO zones mapped yet (fresh listings)
- **Frequency**: per the existing-system screenshot, several rows had blank Zone Pricing.
- **Render**: zone-breakdown panel shows "X listings unmapped to zones" alert at the top with a "Map to existing zone" action. Listings still appear in the inventory grid; just unzoned.

### D6 · Extremely thin data — 1 metric snapshot only
- **When**: just-added event, listings_snapshots cron hasn't run twice yet.
- **Render**: chart shows a single point. Hide the time-axis range selector. Display "Backfilling — chart will populate within X minutes" notice.

### D7 · Massive data — 10K listings, multi-month history
- **When**: long-run Broadway events, full MLB season home schedule.
- **Render**:
  - Default chart range: 30d (not the 7d default).
  - Inventory grid uses virtualized scroll.
  - Zone breakdown caps at top-10 zones with a "show all N" expander.

### D8 · Mid-event (game in progress — listings frozen)
- **When**: T-0 to T+game-end. Most marketplaces freeze listings during play.
- **Render**: top banner "Event in progress · listings frozen". Chart shows the moment of freeze with a vertical marker. Order book stops updating. Sales tape continues for any post-purchase trickle.

### D9 · Postponed / canceled event
- **When**: weather, network outage (NHL game has been canceled mid-event), pandemic delay.
- **Render**: T1 in **postponement mode** — banner with original date + makeup date (if applicable) + ticket-validity policy badge ("Original tickets honored" / "Refund only" / "TBD").

### D10 · Ghost / contingent event
- **When**: "TBD at New York Knicks (Round 2 - Home Game 3) (Date TBD) (If Necessary)" — playoff games whose existence depends on prior outcomes.
- **Render**: T1 shows the contingent badge prominently. Pricing exists but inventory shows "If necessary" indicator. The lifecycle classifier already filters most of these from the active dashboards; the broker can opt in via a "Show contingent" toggle.

### D11 · Multi-event same-day-same-venue (doubleheader)
- **When**: rare but real — MLB makeup doubleheader, festival multi-stage.
- **Render**: top banner linking to the sister event. Inventory shows whether the same physical seat allocation covers BOTH events or just one.

### D12 · Allocation already-sold-the-good-games scenario
- **When**: broker has 81 Yankees season-ticket games × 4 seats = 324 ticket records. They sold the 5 most-valuable home games early. Remaining 76 games skew weak.
- **Render**: Allocation View shows red "remaining-games-skew" warning. Suggests rebundling the remaining games as a partial package + an exit math panel.

---

## 4. Time-state edge cases (game-clock-aware UI)

The terminal's behavior shifts as time-to-event closes. Per the pricer CSV cadences:

| Phase | Window | UI behavior |
|---|---|---|
| **Cold** | T > 30d | Daily-cadence updates. Chart default = 90d range. Sales-tape compressed (every 6h dot). News-overlay default OFF. |
| **Warming** | 7d < T ≤ 30d | 4h-cadence pricer ticks. Chart default = 30d. Sales-tape per-day. News-overlay ON for tracked teams. |
| **Hot** | 1d < T ≤ 7d | 3h-cadence (matches pricer). Chart default = 7d. Sales-tape per-hour. Alerts louder. Sentiment ribbon refreshes every snapshot. |
| **Live** | 0 < T ≤ 24h | 10-min-cadence. Chart range = 24h. Sales-tape ticks every clearance. Pre-game inactives drop alert (90-min before for NFL, 1h for NBA, lineup at MLB time). |
| **Final hour** | 0 < T ≤ 2h | 2-min-cadence. Chart auto-zooms to last 2h. Owned-premium KPI animates on every change. Critical alerts loud (audible if user opted in). |
| **In-progress** | T ≤ 0 (game playing) | Listings freeze marker on chart. Order book stops updating. ESPN live-game widget visible if available. |
| **Cooldown** | T+1 to T+24h | Post-event refunds + audit window. Allocation View updates with sold-from-allocation final tally. |

**The same Event Workbench renders all 7 phases** — what changes is default chart range, refresh cadence, alert volume, which panels collapse vs expand. No mode switch required by the user.

---

## 5. UI element placements & behaviors

### 5.1 Real-time sales tape on chart
- **What**: every clearance shows as a dot on the chart at (sold-time, sold-price). Animates in.
- **Color**: green for buyer-side clears (going to a customer), gray for our outbound sales (we sold).
- **Hover**: shows section, row, qty, price, channel.
- **Frequency**: real-time when in "Live" or "Final hour" phase; every 10s elsewhere.
- **Hide-show**: toggleable per chart instance (some pricers want it off for pure trend reading).

### 5.2 Real-time injury markers on chart
- **What**: when ESPN injury status CHANGES for an athlete on a tracked team, drop a marker at that timestamp on the chart.
- **Visual**: small triangle marker, color-coded by severity (Q = amber, D = red, OUT = bright red, IR = dim red).
- **Hover**: shows athlete name, status change, source link.
- **Click**: opens ESPN news for that team filtered to that day.
- **Constraint**: only renders for events whose `entity_event_map.espn_event_id IS NOT NULL`.

### 5.3 Price-move dots
- **What**: snap-over-snap moves ≥ 3% or ≥ 100 tickets get a special marker on the chart.
- **Visual**: small filled circle on the price line.
- **Hover**: shows direction + magnitude + classification (SUPPLY_FLOOD / RE_PRICING / GHOST_RESOLVE / DEMAND_SPIKE / DUMP per code's redesign memo).
- **Click**: opens "what changed?" mini-investigation showing the listings_snapshots delta.

### 5.4 News markers
- **What**: ESPN news rows + (future) Twitter/Reddit mentions + Wiki update events render as scatter points on the time axis below the chart.
- **Visual**: small squares, colored by source (ESPN blue, Twitter cyan, Reddit orange when wired).
- **Hover**: headline + source.
- **Click**: opens news drawer with full description + url.

### 5.5 Sentiment ribbon below chart
- **What**: a colored band underneath the price line. Width = sentiment magnitude. Green = bullish, gray = neutral, red = bearish.
- **Compute**: from `event_sentiment.composite` (-100 to +100).
- **Fallback**: when not yet computed, ribbon dimmed with "Compute" affordance.

### 5.6 Tabs and sub-tabs
- **Top-level tabs** (saved-search): "Pricer - [params]" format. Persisted per-user. Up to 12 concurrent. Drag-to-reorder. Right-click for rename / duplicate / close.
- **Sub-tabs within Event Workbench inventory section**: Tickets / View-by-Zone / Auto-Pricer / Allocation / Custom-Zone (the existing trio + 2 new). Per the screenshots.
- **Sub-tabs within View-by-Zone**: state-filtered sub-views (All zones / Active pricer / Manual / Filter Red / Filter Yellow).

### 5.7 Allocation View as primary surface
- **Where**: a top-level tab on inventory section (per Julian's M&M scope addition).
- **Default**: hidden when broker has no fixed allocations. Auto-shows when `inventory_allocation` table has rows for the active filter.
- **Layout**: 81-game grid (or N-game grid) with cells colored by per-game current-retail vs cost-basis-break-even.
- **Drilldown**: click a cell → T1 for that game.

### 5.8 Drawers
- **Right-side drawer** for: order detail, zone-pricer config, custom-zone editor, ticket detail (3-tier notes inside), ESPN context expand.
- **Width**: 400-440px. Slide-in 200ms.
- **Esc**: closes drawer.
- **State**: drawer state in URL hash so a deep link reopens to the same drawer.

### 5.9 Toasts and alert banners
- **Severity tiers**:
  - **Info** (gray bar at top): "Sentiment recomputed for 14 events".
  - **Warning** (amber): "Hold expiring in 30 min on order sg_77910".
  - **Critical** (red): "Price Filter Red on Knicks G5 Risers 9+ — base moved 11%".
- **Position**: stack at top-right, max 3 visible. Older auto-dismiss after 6s; critical require dismiss.
- **Sound**: opt-in audio cue for critical only.

### 5.10 3-tier notes rendering
- **In drawer**: tabbed accordion with audience labels.
- **Public** (top tab, blue): visible to buyers if/when surfaced retail-side. e.g. "Limited view of stage."
- **Private** (middle, gray): S4K-internal. e.g. "Came from Yankees season-ticket-package #4421."
- **Broker** (bottom, red): ops-only. e.g. "Replace if seller cancels — backup PO available."
- **Edit**: in-place per-tab; persisted to `tickets.notes_*` / `events.notes_*`.

### 5.11 Coverage 4-light badge
- **Where**: every event hero.
- **Visual**: 4 small circular dots in a row, labeled T (TEvo) · S (SeatData) · G (SeatGeek) · E (ESPN). Lit if `entity_event_map` shows that source linked.
- **Hover**: shows the source's external id.
- **Today, most events show**: T lit, E lit-or-dim, S+G dim. As xref backfill catches up, more cells light.

### 5.12 Coverage warning indicators
- **Inline data caveats** (per data-reality-2026-05-08):
  - On WNBA event hero: "ESPN player data not yet ingested for WNBA — team-level signals only."
  - On NFL event hero: same caveat.
  - On NHL event hero: same.
- **One-click "request ingest"** action queues a code-side task.

### 5.13 Pricing Queue keyboard reference card
- **Always-on at bottom of Queue mode**: `J/K` prev/next · `[/]` price step · `space` save+adv · `?` help · `Esc` exit.
- **Interactive `?` help**: full keyboard map overlay.

### 5.14 ESPN id collision warning
- **Per audit §5 item 2**: events 3345925 + 3346856 share espn_event_id 401871162.
- **Render**: subtle "verify" pill on event hero when the espn_event_id is duplicated across active events.
- **Click**: shows the conflicting event so ops can request the dedupe.

---

## 6. Multi-tab workflows

### W1 · Morning triage with parallel investigations
- 3 tabs: Home (M1) · Pricer-Knicks-week (M2) · Performer-Madonna (M4)
- Pattern: Home tab flashes red dot when alert fires → broker switches to that tab → handles → returns.

### W2 · Pricing batch with comparables
- 2 tabs: Pricing Queue (M5) · Comparable Matchups (M4 reference)
- Pattern: in Queue, broker sees "comparable G5s" mini-data → wants more depth → opens reference tab in M4 mode → returns to queue with `Cmd-1`.

### W3 · Ops + pricing simultaneous
- 2 tabs: Undelivered Window (M3) · Event Workbench (M2)
- Pattern: pre-game ops monitors holds while pricer fine-tunes the event. Cross-tab notification when a hold hits the M3 banner.

### W4 · Investigation-deep (3+ tabs)
- 4 tabs: Performer Console · Two specific events for comparison · Custom-Zone Workbench
- Pattern: long-form M4 session. Tabs persist across sessions.

### W5 · Cross-event compare via split-screen
- 1 tab in compare mode: Event A | Event B linked.
- Pattern: M2 deep work but on TWO events at once.

---

## 7. Day-trader vibe specifics

These are the touches that signal "this is a serious analytical tool, not a catalog browser":

1. **Dense numerics, tabular-num font.** All money + percentage uses `font-variant-numeric: tabular-nums`.
2. **Keyboard-first.** Every action a power-user does has a keyboard shortcut. Discoverable via `?` overlay.
3. **Multi-window, multi-monitor friendly.** Each saved tab can be opened in a new browser window (URL-routable). Brokers commonly use 2-3 monitors.
4. **No spinning loaders.** Skeleton states + smooth fades instead. Nothing animated for animation's sake.
5. **Status bar at bottom.** Refreshed-Xs-ago + active alerts count + which crons last fired. Ambient awareness.
6. **Right-click context menus on every drillable element.** "Open in new tab", "Pin to watchlist", "Compare with...", "Add to custom zone", "Mark as watched (@)".
7. **Sound is optional and rare.** Audible cue only for Critical-tier alerts AND only when user has explicitly opted in. Silent by default.
8. **No pop-ups, no modals for routine work.** Confirmations are inline. Modals only for destructive bulk actions.
9. **Tool-tips are SHORT.** 1-line max, factual. No marketing copy anywhere.
10. **The terminal NEVER asks "are you sure?"** unless you're about to delete inventory. Otherwise it does the action and offers a 5-second undo.

---

## 8. Accessibility / fallback patterns

- **Color-blind safe palette mode**: an opt-in setting (Settings → Display) replaces green/red price moves with up-arrow/down-arrow + amber/blue. Persists per-user.
- **Reduced-motion mode**: disables sales-tape animations, ribbon transitions, drawer slide-ins. Hard-cut state changes only.
- **High-density / standard / spacious row heights**: per-table setting. Power-users default to dense; new brokers default to standard.
- **No-data fallback**: every panel that depends on data we don't have today has a visible fallback message — never an empty white box.

---

## 9. Schema additions surfaced by this doc

Beyond what the prior 2 sim docs flagged:

| # | Addition | Why |
|---|---|---|
| 1 | `user_custom_zones` table + per-user RLS | E3 Custom-Zone Workbench |
| 2 | `user_tab_state` table | E4 multi-tab persistence (cursor + filters per tab per user) |
| 3 | `user_settings` table | M1-M5 mode preferences, color-blind mode, sound opt-in, default chart range, density |
| 4 | `event_audit_log` for time-state transitions | D8 Listings Frozen indicator, D9 Postponement banner |
| 5 | `unmapped_listings_count` view per event | D5 zone-mapping alert chip |
| 6 | `xref_request_queue` table | D1 / coverage-warning "request match" actions |

---

## 10. Status

Filed by: design · 2026-05-08
Third sim doc — covers the cross-cutting cases that make the terminal feel like a stockbroker tool, not a catalog. Calibrated to current data state (most events have only TEvo signals; ESPN partial; SD/SG xref pending). Each edge case has a today-render and an after-data-grows-render so nothing breaks as ingest catches up.

3 sim docs filed:
- `simulations-non-sports-2026-05-08.md` (15 sims)
- `simulations-sports-2026-05-08.md` (30 sims)
- `simulations-edge-and-ui-2026-05-08.md` (this — 24 cross-cutting cases + UI elements + persona modes)

Plus the pre-existing terminal architecture docs:
- `terminal-only-redesign-2026-05-08.md` — view-by-view design (with calibration edits A-F applied)
- `data-reality-2026-05-08.md` — what Supabase actually contains today
- `MEDIA_ASSETS_2026-05-08.md` — visual asset resolve-order
- `CODE_NOTES_2026-05-08.md` — backend hooks code needs to wire

Awaiting Julian's direction on next phase (selective implementation, additional sims, or shifting back to code wiring).
