# Preliminary event views — design handoff (2026-05-08)

> **Audience**: claude design (next session) + Julian (code).
>
> **Builds on**:
> - `docs/terminal-redesign-2026-05-09.md` — 7-page architecture, build sequence, owned_premium_pct as headline KPI
> - `docs/historical-data-and-multi-view-strategy-2026-05-09.md` — 10-level zoom taxonomy, sentiment composite formula, similar-event matching
>
> **Mandate (Julian, 2026-05-08)**:
> 1. Read code's notes, build a preliminary design + wireframes for design handoff.
> 2. Run simulations against ticket-evolution patterns + per-persona needs.
> 3. Decide: sports-vs-non-sports performer split, venue mode (home team vs concert), performer-past-data integration, power-user "next event" pricing flow, metro-competing-events panel.
> 4. Audit metrics generated vs needed.
> 5. Produce 5 view templates with wireframes; let user pick which.
> 6. Reserve room for an LLM analysis layer (Grok / Claude / similar) for future hookup.

---

## 0. TL;DR

Six templates anchored to six different zoom levels from code's taxonomy. They're **not six versions of one page** — they're six first-class views the terminal needs. Design styles them; user picks default-landing via settings.

| # | Template | Anchor zoom | Primary persona |
|---|---|---|---|
| 1 | **Event Workbench** | Event | Pricing power-user (80% of broker time per code's memo) |
| 2 | **Performer Console** | Performer | Portfolio analyst + queue entry point |
| 3 | **Venue Pulse** | Venue | Market-color watcher; mode-tabs by event type |
| 4 | **Pricing Queue** | Cross-event flow | Power user re-pricing 47 home games in one sitting |
| 5 | **Metro Watchlist** | City + date | "Tonight in NYC" demand-overlap view |
| 6 | **Series / Season / Tour Aggregator** | Time-bound campaign | "How is the whole 5-game series / 41-game season / 47-stop tour pricing?" |

Gap to call out: **brokerage roll-up / position concentration** (Julian's "what's our risk?") sits above these as a Template 0 / Home page; it's covered in code's redesign memo but isn't a "view the user picks". Recommend keeping Home as the root and the 5 templates as user-pickable defaults for event-class navigation.

---

## 1. Structural decisions (Julian's questions, answered)

### 1.1 Sports vs non-sports performer view

**Decision**: gate the ESPN block on `event_type='game' AND entity_performer_map.has_espn=true`. Don't show empty ESPN panels for concerts / comedy / theater / F1 / tennis / golf — that's clutter pretending to be data.

For non-sports performers, swap the ESPN band for a **Tour band**:
- Tour name + stop number ("Stop 12 of 47 — Eras-Echo Tour").
- Tour map mini (cities visited so far + remaining).
- Tour-stop comparable strip (last 5 stops with retail-then-decay snapshots).
- Wikipedia / MusicBrainz blurb when available (provenance chip dark for now; lights up when source is added).

**Provenance lights stay 4-light**: TEvo · SeatData · SeatGeek · ESPN. Non-sports = ESPN dark, that's a feature, not a bug. (Per code's "graceful degradation" mandate in the redesign memo §1.)

### 1.2 Venue split — home team vs concert

**Decision**: ONE venue page (Template 3) with a mode-tab strip near the hero: `All · Home team · Concert · Comedy · Other`. Default = the dominant `event_type` for that venue.

Why one page, not separate templates:
- Section-premium baseline differs by mode (Section 100 at MSG prices very differently for Knicks vs Madonna). The page recomputes per-mode, but the layout is identical.
- Mover panel auto-filters to active mode.
- Capacity-utilization curve (when capacity is ingested) is per-mode.

Single-purpose venues (sports-only or concert-only) just hide the irrelevant tabs.

For multi-tenant venues (MSG = Knicks home + Rangers home + concerts + WWE + comedy), each home team is its own tab — they do not collapse into "sports." User cares about Knicks-at-MSG vs Rangers-at-MSG separately because the demand profile, sections that move first, and section-premium curve are all different.

### 1.3 Performer ideal view — how past data informs decisions

**Decision**: Template 2 (Performer Console) anchors on three blocks:

1. **Position rollup** (top): notional book size, owned share, avg owned premium, lifecycle status of upcoming events, concentration risk flag. This is "what do we have on this name?"
2. **Schedule strip** (next 10 events with mini-decay arcs + jumping CTAs).
3. **History — last 5 comparables** (matchup-similarity rank ≥ 0.6): this is THE block where past data becomes a pricing decision input. Each card shows retail-first → retail-day-of, qty drop, played-or-not. Median first→day-of summarizes the typical decay. User asks "what should I price the next game at?" — they look at the 5 cards and the median strip and answer it.

Past data doesn't sit in a separate analytics tab. It sits next to the "next event" entry point so the user sees both at once. (This addresses Julian's "incorporate past data to help user make decisions on next event.")

### 1.4 Power-user pricing — keyboard "next event by performer at home"

**Decision**: ship as Template 4 (Pricing Queue). YES, this is high-leverage. Triggered from any Performer Console (Template 2) or from the home dashboard ("47 Knicks home events to price · resume").

Mechanics:
- Top breadcrumb: "12 of 47 · Knicks home games · resumed from last session · ~22 min remaining at current pace."
- Filter chips: performer · venue · matchup · league · lifecycle. User sets at queue start; filter is part of the persisted state hash.
- Keyboard: `J/K` next/prev, `[ ]` adjust price stepper, `space` save & advance, `?` help.
- Auto-persists progress per `(user, filter_hash)` so a session can resume cleanly across days/devices.
- Per-event card shows: market vs owned vs premium · last-5 comparables · 💡 LLM 1-liner · YOUR PRICE input.

**v1 scope is read-only**: queue writes a "suggested ask" to our DB, then user exports CSV to push to TEvo manually. Direct TEvo writes wait until the EVO order pipeline is solid. (See risks in §2 Template 4.)

This is the biggest workflow accelerator in the design and the one most likely to surprise-and-delight power users.

### 1.5 Metro-competing-events panel

**Decision**: yes — ship as both:
- A strip on Template 1 (Event Workbench) — passive context for the event you're already viewing.
- Template 5 (Metro Watchlist) — active "what's tonight in this metro" scanner.

A Knicks game competing with a Madonna show 2 blocks away DOES affect demand. Cross-event demand share is a missing signal today.

Mechanics:
- Bucket events by `geohash(venue.lat, venue.lng, precision)` + same-day ± 0.5 day.
- Geohash-precision-4 splits NYC into ~5 cells (Manhattan / Brooklyn / Bronx / Newark / LI separate). For metros that span multiple cells, use a manual `metro_id` lookup table for the top 20 markets. Geohash for the long tail.
- Strip color amber when competing notional > 50% of this event's market.
- Demand-share alert: "Knicks G5 competing with $30.3M of non-Knicks tonight — demand share 28%."

### 1.6 LLM analysis layer (Julian's Grok note)

**Decision**: reserve a 1-line slot on Templates 1, 2, 3, 5 labeled `💡 Auto-analysis: [pending]`. Empty placeholder until LLM endpoint ships. When it does:
- Endpoint: `/api/broker/analysis/{scope}/{id}?model=grok|claude|...`
- Server-side wraps the model with a prompt + the relevant metrics digest the page already has.
- Cache 5 min per (scope, id); recompute on `owned_share` or sentiment delta > 5 pts.

Prompt template (proposed):
```
You are a ticket-broker analyst. Given:
  - {scope_metrics_json}
  - {historical_comparables_json}
  - {sentiment_components_json}
Write ONE sentence (≤25 words) calling out the most actionable thing to know.
Tone: factual, specific, no hedging.
```

Per-template hooks:
- T1 Event: "Owned premium is +28% with 4 days to gate — consider trimming 10%."
- T2 Performer: "Knicks book up $1.2M this week; concentration risk increasing."
- T3 Venue: "MSG is 68% sold for next 7 days; Rangers softer than Knicks."
- T5 Metro: "Knicks G5 competes with $30M tonight; demand share 28% (low)."

This is a NULL-OP slot today. Important to leave the design space for it so retrofitting later is one component, not a layout rework.

---

## 2. The 5 templates

### Template 1 — Event Workbench

**When to use**: any single event detail. Default landing when user clicks an event.

**Persona**: pricing power-user, deciding to act / hold / dump.

**Wireframe**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  ◤ NYK   vs   PHI ◢       T-1d 17h 22m  [hot]      Coverage: ●●○●  TEvo·SD·SG·ESPN   │
│  Knicks Game 5 — playoff series · MSG · Wed May 13 19:30 ET                           │
│  ┌───────────────────────────────────┐  ┌──────────────────────────────────────────┐ │
│  │  OWNED PREMIUM                     │  │  📍 Competing tonight in NYC metro      │ │
│  │  −26%   ⬤ AMBER                   │  │  Madonna @ Barclays · $14.0M · 8% S4K   │ │
│  │  $987 ask vs $1,283 nonowned-mkt   │  │  Hawks–Brooklyn · $0.8M · 0% S4K         │ │
│  └───────────────────────────────────┘  └──────────────────────────────────────────┘ │
│  Sentiment: ▰▰▰▰▱▱▱▱▱▱  +42  📈 strong-bullish      💡 Auto-analysis: [pending]      │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  PRICE & VOLUME    [6h] [24h] [3d] [7d•] [30d] [ALL]                  [keys: [ / ] ] │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  ········ market median ($1,283) ··············· decay band (light shade)·── │   │
│  │      ·── owned median ($987) — — — — — — — — — — — — — — — — — — — — — — — │   │
│  │     get-in $645 ─── (yellow line)                                            │   │
│  │   ░░ qty available bars (right axis)         (sentiment ribbon below) ▓▓▓▓▓ │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  KPI grid (8) │ Zone breakdown (curated → fallback)  │ Splits + ESPN                 │
│  retail $987  │ Lower Bowl   $2,340  76 lst  S4K 28% │ Pairs avail: 89%              │
│  getin  $645  │ Mezzanine    $1,120  142 lst S4K 41% │ Singles:    34%               │
│  qty   1,402  │ Upper Deck   $385    229 lst S4K 51% │ Min split:   2.0              │
│  S4K %  49.9% │ Nosebleed    $145    156 lst S4K 33% │ Brunson Q · last-5 played     │
│  …            │  …                                    │ News: 3 in last 24h            │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  Comparable matchups: [G1 5/04 $1,110→$560] [G2 5/06 $1,274→$464] [G3 …] [G4 …]      │
│  Order book: ▮▮▮▮▮▮▮ pending 12 · accepted 84 · rejected 3 · completed 41            │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Data deps**: existing `/event/{id}/overview`, `/chart-data`, `/zones`, `/section-metrics`, `/orders`, `/espn`. NEW: `/event/{id}/sentiment`, `/event/{id}/similar?n=5`, `/event/{id}/competing-metro`, `/event/{id}/owned-premium`.

**Risks**: density. 5 panels above the fold = eye-chart edge. Mitigations: collapse Order book to a strip with click-expand; keep Competing-metro as a strip (alert-y); ESPN block default-expanded only when has_espn=true.

---

### Template 2 — Performer Console

**When to use**: clicking a team / artist name; or "view performer" from event page.

**Persona**: portfolio analyst (per-team rollup) + power-user about to enter pricing queue.

**Wireframe (sports variant)**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  ◤ NYK ◢   New York Knicks · NBA · home: MSG               Coverage: ●●○○             │
│  ┌─POSITION ROLLUP──────────────┐  ┌─UPCOMING (next 10)─────────────────────────┐    │
│  │ Notional book   $20.4M  ⬤   │  │ 5/13  vs PHI G5  T-1d   $987   ▼-26% ●hot │    │
│  │ Owned tickets   5,088   40% │  │ 5/15  vs PHI G6  T-3d   $1,140 ▲+5%  ●    │    │
│  │ Active events   12          │  │ 5/17  vs PHI G7  T-5d   $1,460 ▲+12% ●    │    │
│  │ Avg owned premium  +18%  ⬤  │  │ 5/22  R3-G1 (TBD)                CONTINGENT│    │
│  │ Risk flag: concentration⚠   │  │ 5/24  R3-G2 (TBD)                CONTINGENT│    │
│  └─────────────────────────────┘  └────────────────────────────────────────────┘    │
│  💡 Auto-analysis: [pending]      [Enter Pricing Queue (12 events) → ]                │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  ESPN context (because event_type=game + has_espn=true)                               │
│  Standings 51-31 · streak W3 · Brunson questionable · Bridges out · 3 news 24h        │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  HISTORY — last 5 comparable home games (matchup-similarity rank ≥ 0.6)               │
│  ┌────────────┬────────────┬────────────┬────────────┬────────────┐                   │
│  │ G1 5/04    │ G2 5/06    │ G3 5/08    │ G4 5/10    │ Reg 4/15   │                   │
│  │ vs PHI     │ vs PHI     │ vs PHI(A)  │ vs PHI(A)  │ vs BOS     │                   │
│  │ $1,110→$560│ $1,274→$464│ $643→$250  │ $817→$399  │ $410→$315  │                   │
│  │ -49.6%     │ -63.6%     │ -61.1%     │ -51.2%     │ -23.2%     │                   │
│  │ qty -78%   │ qty -82%   │ qty -69%   │ qty -71%   │ qty -55%   │                   │
│  └────────────┴────────────┴────────────┴────────────┴────────────┘                   │
│  Median first-listed → day-of: $1,030 → $397 (−61.5%)                                 │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  Performer baseline (rolling 30d): retail med $1,030 · getin $645 · own-share 38%     │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Non-sports variant**: ESPN band swaps for "TOUR · Eras-Echo Tour 2026 · 47 stops · stop 12 of 47" plus a tour-map mini and last-5 comparable shows from prior stops. Risk-flag concept stays. Schedule strip stays.

**Data deps**: NEW `/performers/{id}/detail`, `/performers/{id}/baseline`, `/performers/{id}/history?n=5`, `/performers/{id}/tour` (non-sports). ESPN block reuses existing `/espn`.

**Risks**: matchup-history depth is shallow for early-season. Surface "available history" count next to the comparables strip ("5 of 7 comparable matchups in our system; 2 outside coverage window") so user trusts the median.

---

### Template 3 — Venue Pulse

**When to use**: venue research; "what's normal at MSG?"; cross-event comparison at the same building.

**Persona**: market-color watcher, ops planning concentration.

**Wireframe**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  Madison Square Garden · NYC · capacity 19,812 · 125 events tracked                   │
│  Mode:  [All]  [Knicks home •]  [Rangers home]  [Concert]  [Other]                    │
│  ┌─SECTION PREMIUM CURVE (Knicks mode)─────────────────────────────────────────────┐  │
│  │ Section 100s    ▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆ $2,340                                        │  │
│  │ Section 200s    ▆▆▆▆▆▆▆▆ $1,120                                                  │  │
│  │ Section 400s    ▆▆▆ $385                                                         │  │
│  │ Section 200/end ▆▆ $230                                                          │  │
│  └────────────────────────────────────────────────────────────────────────────────┘  │
│  💡 Auto-analysis: [pending]                                                          │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  VENUE-WIDE METRICS (last 7d, Knicks mode)                                            │
│  Capacity util: 64%  ·  S4K share: 41%  ·  Avg owned premium: +18%  ·  Movers: 4↑ 2↓ │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  UPCOMING AT THIS VENUE (next 14d, Knicks mode)                                       │
│  5/13  Knicks vs PHI G5      T-1d   $987   28% S4K  ⬤AMBER                            │
│  5/15  Knicks vs PHI G6      T-3d   $1,140 41%      ⬤GREEN                            │
│  5/17  Knicks vs PHI G7      T-5d   $1,460 48%      ⬤GREEN                            │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  CROSS-MODE COMPARISON (this venue, last 30d)                                         │
│  Knicks home   12 events  med $1,030  fill 64%                                        │
│  Rangers home  6 events   med $385    fill 71%                                        │
│  Concerts      4 events   med $245    fill 92%                                        │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Data deps**: NEW `/venues/{id}/baseline`, `/venues/{id}/events?mode=`, `/venues/{id}/section-curve?mode=`. Venue capacity manual seed needed (in code's data-collection list per redesign memo §6.4).

**Risks**: section names aren't consistent across modes (MSG concert seating reshapes the floor). Mode-aware section bucketing required — this is real backend work, not just a UI filter.

---

### Template 4 — Pricing Queue

**When to use**: power-user mode for re-pricing a performer's full schedule (or a venue's, or a matchup's). Triggered from Templates 2 / 3 / dashboard.

**Persona**: power user pricing 47 events in one sitting.

**Wireframe**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  PRICING QUEUE                                                              [Esc]     │
│  Knicks home games · 12 of 47 · ~22 min remaining · resumed from last session         │
│  Filter: performer=Knicks · venue=any · matchup=any · lifecycle=active                │
│  ◀ K       J ▶       [ ] adjust price       space save & advance       ? help         │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────┐    │
│  │  Knicks vs PHI · Game 5 · MSG · Wed May 13 19:30 ET           T-1d 17h 22m   │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────────────────┐  │    │
│  │  │ MARKET   │  │ OWNED    │  │ PREMIUM  │  │ HISTORICAL — last 5 G5s     │  │    │
│  │  │ $1,283   │  │ $987     │  │ −26% ⬤  │  │ $1,110·$1,274·$643·$817·… │  │    │
│  │  │ 1,402 lst│  │ 56 lst   │  │ AMBER    │  │ med-first→day-of: 1030→397 │  │    │
│  │  └──────────┘  └──────────┘  └──────────┘  └─────────────────────────────┘  │    │
│  │                                                                              │    │
│  │  YOUR PRICE   ◀ $1,090 ▶          (last suggested $987, prior set $1,150)    │    │
│  │                                                                              │    │
│  │  💡 Auto-analysis: "Owned premium pulls toward 0 at this price; sentiment   │    │
│  │     +42 bullish; comparable G5s settled $1,030→$397; consider 5% above"     │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                        │
│  ▼ NEXT: 5/15 Knicks vs PHI G6 (T-3d)                                                 │
│  ▼ NEXT: 5/17 Knicks vs PHI G7 (T-5d)                                                 │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Data deps**: NEW `/pricing-queue/{filter_hash}/start`, `/pricing-queue/{filter_hash}/save`, `/pricing-queue/{filter_hash}/advance`. Per-user state in `pricing_queue_state` table OR client-side localStorage with versioned key. Server-side preferred for multi-device continuity.

**Risks**:
1. Direct TEvo write API is a code-side blocker. v1 = read-only review (writes a "suggested ask" to our DB; user exports CSV to push to TEvo manually). Re-evaluate when EVO order pipeline is solid.
2. Keyboard conflicts with chart `[ ]` range stepper if both surfaces are visible. Queue mode takes over input focus and disables global shortcuts; release on `Esc`.

---

### Template 5 — Metro Watchlist

**When to use**: pre-event scanning ("what's tonight in NYC?"); demand-overlap research.

**Persona**: market-color, demand-share watcher.

**Wireframe**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  METRO WATCHLIST · NYC metro                                                          │
│  Date: [Today •]  [Tomorrow]  [This weekend]  Type: [All •] [Sports] [Concert]        │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  TOTAL DEMAND POOL TONIGHT    $42.1M                                                  │
│  Of which S4K-owned             $8.7M  (21%)                                          │
│  Largest event                  Madonna @ Barclays  $14.0M  (33% of pool)             │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  COMPETING SLATE — Wed May 13 (T-0)                                                   │
│  ┌──────────────────────────────────────────────────────────────────────────────┐    │
│  │ Event                         Venue        Start  Notional  S4K%   Premium   │    │
│  │ ⚡ Knicks vs PHI G5          MSG           19:30  $11.8M    49%    -26% ⬤  │    │
│  │   Madonna · Eras-Echo Tour   Barclays      20:00  $14.0M     8%    +12% ⬤  │    │
│  │   Hawks vs Nets              Barclays(d)   13:00  $0.8M      0%      —      │    │
│  │   Yankees vs Pirates         YS3           19:05  $3.3M     23%     +7% ⬤  │    │
│  │   Hadestown (Bway)           Walter Kerr   20:00  $0.6M      0%      —      │    │
│  │   "Gucci"  comedy            Beacon        21:00  $0.2M      0%      —      │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
│  💡 Auto-analysis: [pending]                                                          │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  DEMAND-SHARE ALERT                                                                   │
│  Knicks G5 competing with $30.3M of NON-Knicks tonight — demand share 28%.            │
│  4 of 12 competing events have S4K inventory; total cross-exposure $9.0M.             │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Data deps**: NEW `/metro/{metro_id}/slate?date=` joins events on `(metro_id, occurs_at_local::date)`. Reuses event_metrics. Manual `metro_id` lookup table for top 20 markets; geohash-precision-4 fallback for everything else.

**Risks**: metro scoping. Geohash-4 splits NYC into ~5 cells (Manhattan / Brooklyn / Bronx / Newark / LI separate) which is wrong for demand-overlap analysis — MSG and Barclays are competing venues for the same buyer pool. Fix: manual `metro_id` map for top markets; let geohash handle the long tail.

---

### Template 6 — Series / Season / Tour Aggregator

**When to use**: an event isn't pricing in isolation — it's part of a campaign (5-game MLB series, 7-game NBA playoff series, 41-game home season, 47-stop concert tour). Brokers need to see the whole campaign at once to make consistent pricing across the run.

**Persona**: portfolio analyst + pricing user looking at the contour of a multi-event campaign.

**Difference from existing zoom levels**:
- **Event** (T1) = single event, deepest detail.
- **Matchup** (handled within T2's last-5-comparables) = same two teams across multiple meetings, can span seasons.
- **Performer** (T2) = all this performer's events, no time bound.
- **Series / Season / Tour** (T6) = time-bound contiguous campaign — a definite start, definite end, with intra-campaign dynamics (G1 demand carries into G2; tour-stop-1 sets price discovery for stop-2).

Mode-tabs (auto-detected from event metadata, user can override):

| Mode | Cardinality | Trigger |
|---|---|---|
| **Series** | 3–7 contiguous games | NBA playoff series, MLB home stand (3-game vs Yankees, 4-game vs Red Sox), NHL playoff series. Detected via `name LIKE '%Game N%'` + same matchup contiguous block. |
| **Season** | 8–162 events | NBA / MLB / NHL / MLS / NFL / WNBA full home schedule. Detected via primary_performer + `season_year`. |
| **Tour** | 3–60+ stops | Concert tour (Eras, Echo, etc.), comedy run, theater touring production. Detected via `tour_name` (needs `tour_metadata` table — see §4 metrics-need list). |

**Wireframe (Series mode — Knicks vs 76ers, R2 7-game series)**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  KNICKS vs 76ERS · Round 2 series · 4-3 series projection · MSG home (G1/G2/G5/G7)    │
│  Status: 🟢 G1 played · 🟢 G2 played · 🟢 G3(A) played · 🟢 G4(A) played ·            │
│           ⚡ G5 today · ⚪ G6 scheduled · ⚪ G7 if necessary (CONTINGENT)             │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  SERIES TIMELINE (each game = one column)                                             │
│  ┌──────┬──────┬──────┬──────┬──────┬──────┬──────┐                                  │
│  │  G1  │  G2  │  G3  │  G4  │  G5  │  G6  │  G7  │  ← TBD: contingent badge          │
│  │ 5/04 │ 5/06 │ 5/08 │ 5/10 │ 5/13 │ 5/15 │ 5/17 │                                  │
│  │ MSG  │ MSG  │ Phil │ Phil │ MSG  │ Phil │ MSG  │                                  │
│  │$1110 │$1274 │ $643 │ $817 │ $987 │$1140 │$1460 │  ← current retail med             │
│  │ →    │ →    │ →    │ →    │ NOW  │ +5%  │ +12% │  ← decay (played) or projection   │
│  │$560  │$464  │$250  │$399  │ T-1d │ T-3d │ T-5d │                                  │
│  │-49.6%│-63.6%│-61.1%│-51.2%│      │      │      │                                  │
│  │  ⬤  │  ⬤  │  ⬤  │  ⬤  │AMBER │GREEN │GREEN │  ← owned-premium status            │
│  └──────┴──────┴──────┴──────┴──────┴──────┴──────┘                                  │
│  Click any column → drill into Template 1 (Event Workbench) for that game             │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  ROLLUP — series-wide                                                                 │
│  Total notional (live games)  $7.2M                                                   │
│  S4K-owned (live games)       $3.5M (49%)                                             │
│  Avg owned premium (live)     +4% (range −26% to +18%)                                │
│  Avg drop on played games     -56% (range -49% to -64%)                               │
│  💡 Auto-analysis: [pending]                                                          │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  PRICING ACROSS THE SERIES (chart)                                                    │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  Grouped lines per game · color = day-of decay arc                            │   │
│  │  X-axis = days-to-event (so all games align at T-0); Y-axis = retail median  │   │
│  │  Shows whether G5 is tracking the same decay shape as G1-G4                   │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  CROSS-SERIES COMPARABLES (other 7-game series this season)                           │
│  Lakers-Thunder (R2, ongoing)   med-game $890   avg drop -52%                         │
│  Celtics-Heat (R1, completed)   med-game $720   avg drop -58%                         │
│  Pistons-Cavs (R1, swept)       med-game $410   avg drop -41% (sweep effect)          │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Wireframe (Season mode — Knicks 2026 home schedule)**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  KNICKS · 2026 SEASON · 41 home games · 38 played, 3 remaining (R3)                   │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  SCHEDULE STRIP — heatmap by retail median (color = $)                                │
│  Oct: ▆▆▆▆     · Nov: ▆▆▆▅▄▄▆ · Dec: ▆▅▄▄▅▆▆▇  · Jan: ▆▆▆▆▆▆▆                      │
│  Feb: ▅▅▅▆▆▇   · Mar: ▆▆▇▇▇█  · Apr: █████ playoffs · May: ███ R2 active            │
│  Click any cell → Template 1                                                          │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  ROLLING BASELINE (last 30 days · per-day median home retail)                         │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  Line chart: retail_median rolling avg with shaded ±1σ band                   │   │
│  │  Overlay: rivalry-game spikes (BOS, MIA), playoff transition jump             │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  STANDOUTS                                                                            │
│  ↑ vs CHI 12/25 (Christmas Day)              med $1,420  vs season avg +37%           │
│  ↑ vs BOS 3/14 (rivalry)                     med $1,210  vs season avg +17%           │
│  ↓ vs DET 1/22 (mid-week, weak opp)          med $310    vs season avg -70%           │
│  💡 Auto-analysis: [pending]                                                          │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Wireframe (Tour mode — Eras-Echo Tour 47 stops)**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  ERAS-ECHO TOUR · Madonna · 47 stops (12 played, 35 upcoming)                         │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  TOUR MAP (mini)                                                                      │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  US/EU outline · played stops gray dots · upcoming stops accent dots         │   │
│  │  Stop selected highlights with hover card (city, date, retail, S4K share)     │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  STOP TIMELINE (chronological)                                                        │
│  Stop 1  Toronto   3/12 ✓    $480 → $290    -39.6%    qty 4,200 → 920                 │
│  Stop 2  Detroit   3/14 ✓    $410 → $245    -40.2%                                    │
│  Stop 3  Cleveland 3/16 ✓    $375 → $215    -42.7%                                    │
│  ⋯ (12 played) ⋯                                                                      │
│  Stop 13 Brooklyn  5/13 ⚡   $620 (T-1d, current)   ●AMBER  S4K 8%                    │
│  Stop 14 Boston    5/16 ⚪   $480 (T-4d)             ●GREEN S4K 12%                   │
│  Stop 15 Chicago   5/19 ⚪   $510 (T-7d)                                              │
│  ⋯ (35 upcoming) ⋯                                                                    │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  ROLLUP — tour-wide                                                                   │
│  Total notional (upcoming)  $94M                                                      │
│  S4K-owned                  $11M (12%)                                                │
│  Median first-listed → played-day-of: $475 → $280 (-41%)                              │
│  Played stops drift: stops 1-4 priced 8% higher than stops 5-12 (early-tour premium) │
│  💡 Auto-analysis: [pending]                                                          │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Data deps**:
- Series mode: detect contiguous matchup blocks via `events WHERE primary_performer_id=X AND opponent_performer_id=Y AND occurs_at_local in N-day window`. Use `name LIKE '%Game N%'` to order. NEW: `/series/{series_id}/timeline` returns all games + their decay arcs.
- Season mode: `events WHERE primary_performer_id=X AND season_year=Y AND is_home=true`. NEW: `/performers/{id}/season/{year}/heatmap` + `/season/{id}/standouts`.
- Tour mode: requires `tour_metadata` table (per §4 metrics-need list). NEW: `/tours/{tour_id}/stops`.

**Risks**:
- Detection logic. "Game N" parsing is brittle — TEvo names aren't always normalized. Need a `series_xref` table that maps each event to (series_id, game_number) at ingest, derived from ESPN bracket data when available.
- Tour metadata is a data hole. Code's redesign memo flagged `tour_name` parsing from `events.name` as partial; need a real `tour_metadata` table seeded from MusicBrainz / Bandsintown.
- Season-mode standouts (Christmas, rivalry, playoff transition) require manual or rule-based tagging today — could be auto-detected from price-vs-baseline outliers without ground-truth labels.

---

## 3. Simulation grid — scenario × template

Scoring: 🟢 = answers persona's first question in <2s; 🟡 = needs <10s + interaction; 🔴 = wrong template for this scenario.

| Scenario | T1 Event | T2 Performer | T3 Venue | T4 Queue | T5 Metro | T6 Series |
|---|---|---|---|---|---|---|
| Knicks G5 — single pricing decision | 🟢 | 🟢 | 🟡 | 🟢 | 🔴 | 🟢 (series ctx) |
| Touring concert (Madonna stop 12) | 🟢 | 🟢 (tour mode) | 🟡 | 🟡 | 🟢 | 🟢 (tour mode) |
| Comedy/theater (Beacon resident) | 🟡 (sparse) | 🟡 (sparse) | 🟢 | 🔴 | 🟡 | 🟡 (run mode) |
| F1 Miami GP (single-week event) | 🟢 | 🔴 | 🔴 | 🔴 | 🟢 | 🔴 (single) |
| Power user re-pricing 47 Knicks | 🔴 | 🟡 (entry pt) | 🔴 | 🟢 | 🔴 | 🟡 (overview) |
| Pre-game metro overlap scan | 🟡 | 🔴 | 🔴 | 🔴 | 🟢 | 🔴 |
| "Is Yankees-Red Sox priced right?" | 🟡 | 🟢 (matchup hist) | 🟡 | 🔴 | 🔴 | 🟢 (3-game stand) |
| Position concentration overview | 🔴 | 🟢 (per-team) | 🔴 | 🔴 | 🔴 | 🔴 |
| **MLB 5-game series at MSG** | 🟡 (per game) | 🟡 (broader) | 🟡 | 🔴 | 🔴 | 🟢 |
| **NBA full home season** | 🔴 | 🟡 (rollup) | 🟡 (filtered) | 🟡 | 🔴 | 🟢 (season mode) |
| **47-stop concert tour** | 🔴 | 🟡 (tour band) | 🔴 | 🔴 | 🔴 | 🟢 (tour mode) |

**Read**: each template wins ≥ 1 scenario cleanly. No template is dead weight.
- T1 is the workhorse — single-event detail, 3🟢 across diverse event types.
- T2 is the analytical anchor (4🟢) and the queue entry point.
- T3 is venue-specific but covers comedy/theater where T1+T2 are sparse.
- T4 is the workflow accelerator — power-user pricing flow.
- T5 is the demand-context lens (3🟢) for time-bound decisions.
- T6 is the campaign view — series / season / tour roll-ups (3🟢) where intra-campaign dynamics matter and a single event's price shouldn't be set in isolation.

**Gap surfaced by simulations**: position concentration / brokerage roll-up doesn't have a clean template home. Code's redesign memo handles this via the Home page (Page 1). Recommend keeping the Home dashboard as the always-visible root; the 5 templates are user-pickable defaults for event-class navigation.

**Special-case findings**:
- F1 / one-off events: T3 (Venue Pulse) is wrong because the venue doesn't have history at this scale. T1 + T5 carry these. Consider an EVENT-INTENSITY mode for T1 that auto-loads more historical comparables when venue history is shallow.
- Comedy/theater: data is genuinely thin (per code's coverage table — 1 of 115 concerts has metric history). Templates can render but the analytical value is low until coverage grows. Surface a "coverage low" chip; don't pretend to know more than we do.
- Multi-venue arena swaps (Hawks at Barclays in 2026 = "Barclays(d)" displaced): venue mode-tabs need a "displaced home" sub-flag so user knows it's not a normal Barclays event.

---

## 4. Metrics audit — have / need

### Already generated (verified in SCHEMA.md + code's docs)

- `event_metrics`: retail_median, getin_price, owned_share, owned_median_retail, nonowned_median_retail, splits_pairs/singles, tickets_count, listing_fill_rate, getin_qty2plus
- `zone_metrics`: per-zone breakdown (curated/fallback/unmapped layers)
- `section_metrics`: per-section
- `event_lifecycle` view: active/ghost/completed/postponed
- `entity_event_map / entity_performer_map / entity_venue_map`: cross-source linkage
- ESPN: standings, injuries, news (gameday cron — currently only iterates NBA + MLB; per KANBAN NEXT row, MLS/NHL/NFL/WNBA/WC scope expansion is queued)
- `evo_orders`: own-pipeline state
- `seatdata_sales_snapshots / seatgeek_sales_snapshots`: realized prices
- 822 active sports + 115 concerts with metric history
- Master cascade every 2 min (per SCHEMA active crons)

### Need to build (proposed; ~80% from code's memos)

| Metric / object | Why | Source |
|---|---|---|
| `buyer_sentiment_index` | Composite signal — single number for glance + decomposition for analysis | Formula already specced in code's multi-view memo §2 |
| `matchup_xref` table + `matchup_history` view | Powers Template 2's last-5-comparables block | Specced in code's multi-view memo §6.1 |
| `event_similarity` function | Powers comparable-matchups strip on T1 | Specced in code's multi-view memo §6.1 |
| `performer_baseline_metrics` | Powers T2 rollup baseline lines | Specced; daily cron |
| `venue_baseline_metrics` | Powers T3 section-premium curve per-mode | Specced; daily cron |
| `competing_events_metro` | Powers T1 strip + T5 entire view | New — geohash + same-day query function |
| `pricing_queue_state` | Per-user-per-filter cursor + suggested-ask persistence | New table, MVP |
| `owned_premium_pct` | Headline KPI on T1 | DERIVE from existing fields; no new ingest |
| `tour_metadata` | Non-sports performer view (tour name, stop number, total stops) | Partially in `events.name` parsing; deserves its own table |
| `metro_id` lookup | Manual map for top 20 markets, geohash fallback | New seed table |

### Need to start collecting (long-tail, plant-now-harvest-later)

| Data | Why | How |
|---|---|---|
| Venue capacity | Enables % sold / fill-rate aggregates | Manual seed top 30 venues |
| Section seat count | Enables zone fill rate | Seat-map crawler exists per code's data-inventory; finish it |
| Game-importance flag | Distinguishes rivalry / playoff / division weight | Derive from ESPN context |
| Weather forecast | Outdoor-sport demand modifier | NOAA `why_signals` already collected; not yet exposed |
| Day-of-week / month-week | Seasonality features | Trivial on `occurs_at_local` |
| Standings AT GAME TIME | Decision-context | `espn_team_snapshots` has it; needs JOIN to event metrics |

### Ghost-metrics watch (data we generate but should question)

- `event_metrics` for 14 of 95 null-event_type events (15% with metrics). Why are these getting metrics if classification is uncertain? Could be misclassified or could be ghosts. Worth a `lifecycle.is_active=true` cross-check before surfacing.
- `tickets_count` includes wholesale + retail combined; T1 KPI grid should clarify which.

---

## 5. Open questions for design execution

1. **Density floor for T1** — collapse Order book + Competing-metro + ESPN by default? Suggest: Order book = collapsed strip; Competing-metro = expanded strip (alert-y); ESPN = default-shown only when has_espn=true.
2. **Pricing Queue write-path** — read-only suggestion + CSV export (v1) vs full TEvo push (later)? Suggest read-only first.
3. **Metro geohash precision** — precision 4 splits NYC. Use precision 3 (~70km, too wide?) or manual `metro_id` lookup. Suggest manual for top 20 + geohash fallback.
4. **Sentiment scale** — continuous −100..+100 vs 5-state enum. Suggest both: number for analytical mode, color-coded enum for glance mode (per code's open question).
5. **Mode-switcher persistence** on Venue Pulse — remember per-venue selection? Suggest yes, localStorage `venue_mode_v1:{venue_id}`.
6. **Default landing template** when user clicks an event — Template 1 always, or learn from past usage? Suggest always T1 for v1.
7. **"Let user pick which"** — what does user actually pick? Options:
   - (a) Default landing template after sign-in (Home vs T2 vs T5).
   - (b) Default density mode within a single template (compact / standard / spacious).
   - (c) Default chart range, sort order, etc.
   Suggest (a) + (b) for v1; (c) is per-component and lives in component-local localStorage already.
8. **Provenance lights** — 4-light strip is tight on small screens. Single-letter labels (T·S·G·E) or icons? Suggest icons with hover-text legend.

---

## 6. Build sequence (designer + code coordination)

Per code's redesign memo §7, ship Page 2 (Event Workbench) first. My adaptation, integrated with the 5-template scope:

| # | Ship | Blockers | LLM slot |
|---|---|---|---|
| 1 | T1 + sentiment ribbon | `event_sentiment` cron (~1d code work) | 💡 placeholder |
| 2 | T2 + matchup history | `matchup_xref`, `event_similarity`, `performer_baseline` (~2d) | 💡 placeholder |
| 3 | T4 read-only (Pricing Queue) | `pricing_queue_state` table + UI focus mgmt (~2d) | 💡 active (high value) |
| 4 | T5 (Metro Watchlist) | `metro_id` seed + `competing_events_metro` fn (~1d) | 💡 placeholder |
| 5 | T3 (Venue Pulse) | `venue_baseline`, `venue_capacity` seed (~2d, multi-step) | 💡 placeholder |
| 6 | LLM endpoint + analysis layer | `/api/broker/analysis/*` + Grok/Claude wrapper (~3d) | activates 1-5 |

Each step is independently shippable. Don't ship "v1 of everything" — ship T1 first, iterate.

---

## 7. References

- `docs/terminal-redesign-2026-05-09.md` — 7-page architecture, owned-premium-pct as headline, build sequence
- `docs/historical-data-and-multi-view-strategy-2026-05-09.md` — zoom taxonomy, sentiment composite, similar-events query
- `docs/terminal-data-inventory.md` — TIER 1 / TIER 2 metrics map
- `docs/broker-audit-2026-05-08.md` — risk briefing (freshness chips, contingent badge, ownership flags)
- `design/main.fig.md` — design system tokens (colors, typography, chips)
- `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md` — design-coworker onboarding
- `SCHEMA.md` — 47 tables, 73 functions, 17 active crons (cascading 2-min freshness)

---

## 8. Status

Filed by: design · 2026-05-08
Builds on code's prior memos; no original analysis claimed where code's docs already specced it.
Next step: review by Julian (code) + claude design session pickup.
