# Terminal-only redesign — informed by pricer + data mapping (2026-05-08)

> **Scope**: broker terminal ONLY. Retail shop and undelivered window are out of scope here.
> No coding — describes what the UI should look like and which data each panel reads.
>
> **Inputs that drove this doc**:
> 1. Julian's pricer CSV export (Knicks R2-G3 zone pricer state, 13 zones)
> 2. Code's audit at `docs/audit-2026-05-09.md` (1 blocker fixed: shop XSS; design submission approved)
> 3. Code's prior memos: `terminal-redesign-2026-05-09.md`, `historical-data-and-multi-view-strategy-2026-05-09.md`
> 4. Cross-source entity maps (mig 20260509120000)
> 5. Canonical order states (mig 20260509140000)
> 6. Matchup + sentiment + baselines (mig 20260509130000)
> 7. SeatData + SeatGeek + ESPN integrations
>
> **Worktree state**: HEAD synced to origin (1060a29). Code added `static/_proposals/preview-landing.html` switcher, fixed shop XSS, answered all 7 of my open questions (see audit §4).

---

## 0. TL;DR

The terminal has been treating "price" as a single number. The pricer CSV proves that's wrong: **price is a 4-dimensional surface** —

```
                                     ┌── retail (TEvo own + market)
                                     ├── wholesale (TEvo cost basis)
   PRICE = f(zone × quantity-tier × time × source) ─┼── SeatGeek cost (our SG inventory)
                                     └── SeatData sold (what cleared)
```

The redesign exposes that surface as the primary analytical object. Every panel below names the table/view it reads from so code can wire it without re-discovering the schema.

---

## 1. Data sources — single map of how everything joins

### 1.1 The hub-and-spoke model

TEvo's `events.id` is the hub. Every other source xrefs to TEvo independently. There is one canonical join view per entity:

| View (mig 20260509120000) | What it gives you |
|---|---|
| `entity_event_map` | One row per TEvo event, ESPN + SD + SG ids fanned out + `external_ids` JSON + `lifecycle_status` + `sources_count` |
| `entity_performer_map` | One row per TEvo performer + ESPN team_id + SD/SG ids + home venues array |
| `entity_venue_map` | One row per TEvo venue + SD/SG ids (no ESPN venue mapping — they don't expose) |

**These are the three views to start every query from.** Don't re-JOIN the underlying xref tables in app code; the views already do.

### 1.2 The 3 pricing data sets

| Source | Canonical table | What it answers |
|---|---|---|
| **TEvo (own + market)** | `event_metrics` (per-event time series) — `retail_median`, `owned_median_retail`, `nonowned_median_retail` (mig 030000), `getin_price`, `tickets_count`, `splits_*`, `owned_share` | "What's our ask vs the market right now?" |
| **SeatGeek (our SG-side)** | `seatgeek_event_metrics` (mig 110000) — `cost_median`, `active_tickets`, `sold_quantity` | "What's our SG inventory doing on the SG side?" |
| **SeatData (realized)** | `seatdata_event_stats` + `seatdata_sales_snapshots` (mig 060000) — sold prices, bought_at timestamps, zone-level rollups | "What actually cleared on the secondary market?" |

These three answer different questions. The terminal should present all three on the same chart for any event with `entity_event_map.sources_count >= 2`. When only TEvo is available (the long tail), gracefully degrade.

### 1.3 ESPN — performance + player data

Gated on `entity_event_map.espn_event_id IS NOT NULL` AND `entity_performer_map.espn_team_id IS NOT NULL`. Tables:

| Table | What it gives |
|---|---|
| `espn_team_snapshots` | Standings, record_summary, streak, win/loss, division position |
| `espn_player_snapshots` | Roster (athlete_id, position, depth_chart_position) |
| `espn_injuries` | athlete_id, status (Q/D/O/IR), comment, source_link |
| `espn_news` | Per-team news with optional injury/trade tag |

ESPN's `is_baseline` detection is currently broken for NBA/NFL/MLS/WNBA/WC (per audit §5 item 5) — only MLB+NHL detect injury changes correctly. So injury overlays only render markers for 2 of 7 leagues. **Surface a coverage warning**: when the active event's league is in the broken set, show a small "ESPN injury detection partial" badge so the broker knows.

### 1.4 Order/sale data — canonical via `unified_orders`

`unified_orders` (mig 140000) UNIONs three sources into one rowset with 6 canonical states:

```
canonical_status: pending | accepted | substitution | rejected | cancelled | fulfilled
+ is_terminal flag (won't transition again)
+ is_sale_succeeded flag (only fulfilled = true)
```

Sources unioned:
- `evo_orders` (TEvo /v9/orders — our buy/sell orders)
- `seatgeek_orders` (SG seller-direct — our SG outbound)
- `seatdata_sales_snapshots` (SeatData /salesdata — every row IS a sold)

`unified_orders_by_event` rolls these up per `tevo_event_id` with 6 bucket counts + gross_sold + tickets_sold. **This is the canonical source for the order book strip** on the event page.

### 1.5 Derived analytics

| Object | Purpose |
|---|---|
| `event_sentiment` (mig 130000) | Composite −100..+100 score per snapshot; built from inventory absorption + getin stability + owned-share trajectory + splits-pair thinning + injury delta |
| `event_lifecycle` (mig 050000) | active / ghost / completed / postponed / cancelled — drives ghost-event filtering |
| `find_similar_events(event_id, n)` (mig 130000) | Returns top-N comparables with similarity score (matchup-level: same teams, recency, venue, day-of-week) |
| `matchup_history` (mig 130000) | Per-matchup aggregate of all events of (team_a, team_b) in our system |
| `performer_baselines` / `venue_baselines` (mig 130000) | Daily-refreshed rolling 30d medians per performer / venue |

### 1.6 Data NOT yet wired but available

- **Weather** — NOAA `why_signals` table is collected (per code's redesign memo §6.4) but no API surface exposes it. Reserve a slot on the event hero for outdoor sports.
- **Pricer state** — the CSV Julian shared lives in S4K's main system (a separate DB or service). It is not in our terminal's Supabase yet. **Building a `zone_pricer` table** (mirror of the CSV columns) is on the roadmap; until then, the Pricing Queue surface (T4) reads from a stub.
- **`hold_expires_at` on `unified_orders`** — code answered YES to adding this in a follow-up migration (audit §4 Q2).

### 1.7 The diagram

```
                                  ┌─────────────────────────────────────┐
                                  │            TEvo events.id            │   ← THE HUB
                                  │   (events.primary_performer_id +     │
                                  │    events.venue_id are sub-hubs)     │
                                  └──────────┬──────────────────────────┘
                                             │
              ┌───────────────────┬──────────┼──────────┬─────────────────┐
              │                   │          │          │                 │
        event_xref        seatdata_event   seatgeek_event   matchup_xref  event_lifecycle
        (ESPN id)          _xref            _xref            (team_a,      (active/ghost/...)
              │                   │          │           team_b hash)         │
              │                   │          │              │                 │
        ESPN (team,         SeatData       SeatGeek      matchup_history     gates UI
        injury, news)       (sold $)       (cost,                            (drops
                                            sold qty)                         ghosts)

                                  ┌─────────────────────────────────────┐
                                  │  3 pricing tables joined per event:  │
                                  │   event_metrics       (TEvo)         │
                                  │   seatgeek_event_metrics (SG)        │
                                  │   seatdata_event_stats   (SD sold)   │
                                  └──────────────────────────────────────┘

                                  ┌──────────────────────────────────────┐
                                  │      unified_orders (mig 140000)     │
                                  │   UNION evo_orders + seatgeek_orders │
                                  │     + seatdata_sales_snapshots       │
                                  │   → canonical 6-state vocab          │
                                  └──────────────────────────────────────┘

                                  ┌──────────────────────────────────────┐
                                  │  Derived: event_sentiment,           │
                                  │  performer_baselines, venue_baselines│
                                  │  find_similar_events()               │
                                  └──────────────────────────────────────┘
```

### 1.8 One tactical note: the Knicks G5/G3 ESPN-id collision

Per audit §5 item 2: TEvo events 3345925 + 3346856 share ESPN id 401871162. So ESPN data on one of them is the wrong game. **In any terminal panel that surfaces ESPN-derived facts, surface a subtle "verify" indicator when an event shares an ESPN id with another non-historical event in our system.** Cheap to detect; high-value catch.

---

## 2. Pricer-informed structural decisions

These supersede equivalent decisions in `preliminary-event-views-2026-05-08.md` where there's a conflict.

### 2.1 Row-ranking is venue-dependent (per Julian)

The pricer assumes single-letter rows ranked "Worst to Best." Reality is messier:

| Venue archetype | Better seats | Worse seats |
|---|---|---|
| MSG / typical bowl | Single letters (A, B, ..., Z) | Double letters (AA, BB, ...) — risers |
| Some Broadway / theaters | Double letters (AA, BB, ...) — orchestra | Single letters |
| Stadium concerts (GA pit + reserved) | Pit standing → no row → single letters in seated sections | Lawn / GA back |

**Decision**: replace `row_ranking_method = 'Single-letter'` with `venue_row_rank_method` enum:
- `single_then_double` (single A-Z is best, then AA-ZZ — MSG default)
- `double_then_single` (double AA-ZZ is best, then A-Z — some theaters)
- `single_only` (no double letters in this venue)
- `numeric` (rows numbered 1, 2, 3...)
- `mixed` (custom — defer to per-zone override)

This becomes a column on a new `venue_seating_config` table (or on `venue_assets`). The Pricing Queue (T4) and any UI showing row-rank ladders read this.

### 2.2 Adopt the pricer's vocabulary

Don't invent a parallel vocabulary; reuse what `jaizer` already speaks:

| Concept | Use this term |
|---|---|
| Pricing mode | `Smart Pricing` / `Dumb Pricing (default)` — show as a per-zone badge |
| Price tier | `SG2 / SG3 / SG4 / SG5 / SG6` — pair / 3-pack / 4-pack / 5-pack / 6-pack |
| Movement alert | `Price Filter Red (>10%)` / `Price Filter Yellow (5-10%)` / `Price Filter Green (<5%)` |
| Run cadence | `>= 7 days (8h)` / `< 7 days (3h)` / `Same day after 9 (10m)` / `Last 2 hours (2m)` |
| Two timestamps | `Last Run Date` ≠ `Base Price Synced At` (compute time vs. push-to-wholesale time) |
| Safety rails | `Top Of Range %`, `Min Spacing`, `Max Spacing`, `Max Single Step Drop %`, `Price Floor`, `Price Ceiling` |

### 2.3 Code's answers to my open questions (from audit §4)

These are now decisions, not questions:

1. CI test for retail wall — **YES, P1 before retail launch.**
2. `hold_expires_at` on `unified_orders` — **YES, follow-up migration.**
3. `series_xref` table vs NLP parsing — **TABLE, small seed.**
4. Tour metadata source — **DEFER, separate planning round.**
5. Pricing Queue v1 write path — **READ-ONLY confirmed (RULE 2: never POST/PUT to TEvo).**
6. Retail Stripe account — **DEFER until shop wires.**
7. `/shop` mount — **same Railway service, `/shop` route.**

---

## 3. Terminal-only redesign — surface by surface

Six surfaces. Each names every table/view it reads. Frontend skeletons live in `static/_proposals/templates.html`; this doc supersedes that file's data bindings where they conflict.

### 3.1 Home — brokerage roll-up + alerts

**Above the fold**:
- **Position concentration card** — top 5 performers by notional. Reads `performer_baselines` (latest) + `events` filtered to upcoming + `event_metrics` (latest) for each.
- **Top movers strip** — 6 cards, last 24h notional Δ. Reads `event_movers()` RPC + `unified_orders_by_event` for fulfilled-velocity context.
- **Risk alerts** — events where (a) `event_metrics.owned_premium_pct > 30 AND days_to_event < 7`, OR (b) `unified_orders` has `hold_expires_at < NOW + 1h` (when the column lands).
- **Coverage band** — N active sports / within 30d / within 7d / today, derived from `events` + `event_lifecycle.is_active = true`.

**Below the fold**:
- League tabs (NBA / NFL / MLB / NHL / MLS / WNBA / Concert) — reads `taxonomy_xref` for canonical labels.
- Watchlist (3 tabs: mine / movers / gametime) — existing pattern.

### 3.2 Event Workbench (the 80% page)

This is where 80% of broker time goes. The redesign treats price as a 4-dimensional surface.

**Hero band**:
- Logos + countdown + venue + date — reads `events` + `entity_performer_map` (for ESPN team_id → logo URL).
- **Owned premium KPI** — biggest number on the page. `(owned_median_retail − nonowned_median_retail) / nonowned_median_retail`, color: green (−10..+15%), amber (otherwise), red (>+30 or <−20).
- **Coverage 4-light badge** — TEvo · ESPN · SeatData · SG. Reads `entity_event_map.sources_count` + `external_ids` JSON.
- **Lifecycle badge** — active/ghost/completed/postponed. Reads `event_lifecycle.status`. If ghost, dim the entire page and add a "GHOST" overlay.
- **ESPN id collision indicator** (per §1.8) — small "verify" pill if this event shares espn_event_id with another active event.
- Quick-actions: link to `/event/{id}/raw-tevo` (existing `/api/broker/event/{id}/raw-tevo`), sync buttons for SeatData / SG when not yet linked.

**Sentiment ribbon**:
Reads `event_sentiment` latest snapshot + 7d series. Renders a green/red ribbon below the chart's price line + a single big number on the hero. Decomposition (5 components: tix-per-hour, getin-per-hour, owned-share-per-hour, splits-pair-per-hour, injury-delta) shown on hover.

**Chart band** (~40% of page height):
Three pricing dimensions overlay on the same time axis:

| Series | Source table | Color/style |
|---|---|---|
| EVO_Market_Median | `event_metrics.retail_median` | blue solid |
| EVO_Owned_Median | `event_metrics.owned_median_retail` | green dashed |
| EVO_Nonowned_Median | `event_metrics.nonowned_median_retail` | purple solid |
| EVO_Get-in | `event_metrics.getin_price` | yellow line |
| EVO_Quantity_Avail | `event_metrics.tickets_count` | orange bars (right axis) |
| EVO_Splits_Min_Q | `event_metrics.splits_min_q` | gray line |
| SD_Sold_Median | `seatdata_event_stats.sold_median_retail` | red dashed (when SD-linked) |
| SG_Cost_Median | `seatgeek_event_metrics.cost_median` | teal dashed (when SG-linked) |
| SG_Active_Tickets | `seatgeek_event_metrics.active_tickets` | teal bars |
| Sentiment ribbon | `event_sentiment.composite` | green/red shaded band beneath |
| ESPN injury overlays | `espn_injuries` time-series | dot markers |
| ESPN news overlays | `espn_news` time-series | square markers |

Range selector with the pricer's cadences: 6h / 24h / 3d / 7d / 30d / ALL. Keyboard `[` / `]` to step.

**KPI grid** (8 cells):
retail / get-in / qty / S4K% / fill-rate / splits-min-q / sentiment-now / owned-premium. All from `event_metrics` latest snapshot + `event_sentiment`.

**Zone breakdown panel** — DEEPENED per pricer schema:

For each zone (rows from `zone_metrics` joined to a future `zone_pricer` table when wired):

| Column | Source |
|---|---|
| Zone name | `zone_metrics.zone_name` |
| Pricing mode badge | `zone_pricer.pricing_type` ("Smart" / "Dumb") |
| Current Base | `zone_pricer.current_base_price` |
| Δ vs Previous Run | `zone_pricer.base_change_percentage` color-coded with Filter Red/Yellow/Green |
| Status | `zone_pricer.status` (e.g. "Price Filter Red (>10%)") |
| Last Run | `zone_pricer.last_run_date` |
| Synced | `zone_pricer.base_price_synced_at` |
| Next Run | `zone_pricer.next_run_time` |
| Per-qty ladder | `zone_pricer.current_sg_2_base / sg_3_base / sg_4_base / sg_5_base / sg_6_base` — show as a small inline 5-cell strip |
| S4K listings count | from `listings_snapshots` filtered to `is_s4k_owned` |
| S4K share % | `zone_metrics.owned_share` |
| Active? | `zone_pricer.active` (Checked / Unchecked) |

Click a zone row → drawer showing the FULL pricer config for that zone (top-cap, min/max spacing, max-step-drop, floor, ceiling, all 5 SG enables + deltas + spacings + min/max %). This drawer is the "what is the pricer doing?" deep view.

**Splits inventory panel** — uses `event_metrics.splits_min_q`, `splits_pct_pairs`, `splits_pct_singles`, `splits_with_singles..4plus`. Render as a density bar.

**Comparable matchups strip** — reads `find_similar_events(event_id, 5)`. 5 horizontal cards with retail-then-decay snapshots.

**Order book strip** — reads `unified_orders_by_event WHERE tevo_event_id = $1`. 6-segment bar: pending / accepted / substitution / rejected / cancelled / fulfilled. Click → drilldown to per-row.

**SeatData sales tape** (when linked) — last 20 rows from `seatdata_sales_snapshots`.

**Recent big moves** detector — snap-over-snap ≥3% / ≥100 tix swings, computed from `event_metrics` deltas.

**Weather slot** (placeholder) — reserved for outdoor sports. Wires when NOAA `why_signals` is exposed.

**LLM analysis slot** — `💡 [pending]` placeholder. Wires to `/api/broker/analysis/event/{id}` when LLM endpoint ships.

### 3.3 Performer Console

**Hero**:
Logo + league/genre + home venue + ESPN provenance. Reads `entity_performer_map` (covers ESPN, SD, SG, home venues array).

**Position rollup**:
Notional book / owned tickets / active events / avg owned premium / risk flag. Aggregated from `events` + `event_metrics` filtered to `primary_performer_id`. Risk flag fires on concentration > 30% of total notional.

**ESPN context** (sports only — `entity_performer_map.espn_team_id IS NOT NULL`):
Standings + streak + injuries + news, all from `espn_*` tables.

**Tour band** (non-sports — `pm.what_event_type IN ('concert','comedy','theater')`):
Tour name + stop number + tour-map mini. Pulls from a future `tour_metadata` table (deferred per audit §4).

**Schedule strip**:
Next 10 events. Reads `events` + `event_metrics` (latest snapshot per event) + `event_lifecycle` (filters ghosts).

**History — last 5 comparables**:
Reads `find_similar_events()` filtered to home games. Each card: retail-first → retail-day-of, qty drop, played-or-not.

**Performer baseline**:
Reads `performer_baselines` for the rolling 30d median strip.

**Pricing Queue entry point**:
"Enter Pricing Queue (12 events) →" button. Hands off to T4 with filter `performer_id={id} AND lifecycle.is_active=true`.

### 3.4 Venue Pulse

**Hero**:
Venue name + address + capacity (from `venue_assets.capacity` when seeded). Reads `entity_venue_map`.

**Mode tabs**:
`All / Knicks home / Rangers home / Concert / Other` — auto-detected from event_type counts. Mode persistence in localStorage `venue_mode_v1:{venue_id}`.

**Section premium curve**:
Aggregated from `section_metrics` filtered by event_type (the active mode). Bars per section row showing median retail. **Row-rank-method aware** (per §2.1) — sort sections by venue's configured row-rank.

**Venue-wide metrics**:
Capacity utilization (`SUM(tickets_count) / capacity`), S4K share, avg owned premium, mover counts.

**Upcoming events list** (filtered to active mode).

**Cross-mode comparison table** — N events / median retail / fill rate per mode (last 30d).

### 3.5 Series / Season / Tour Aggregator

Auto-detected mode based on event metadata:

| Mode | Detection rule | Source |
|---|---|---|
| Series | Contiguous matchup block, name LIKE '%Game N%' | `matchup_xref` + future `series_xref` (per audit §4 Q3 — TABLE confirmed) |
| Season | All events for primary_performer_id + season_year + is_home=true | `events` + a future `season_year` column derivation |
| Tour | events with same `tour_name` (parsed) | future `tour_metadata` (deferred) |

**Series mode**:
Side-by-side timeline of N games (3-7) with status pills (played / today / scheduled / contingent). Each column shows: date, venue, current retail, decay arc, owned-premium status.

**Season mode**:
Heatmap by month + rolling 30d baseline + standout flags (rivalry, holiday, playoff transition). Auto-detected outliers via `event_metrics` vs `performer_baselines` deviation > 1.5σ.

**Tour mode**:
Tour map mini + chronological stop timeline + early-tour-vs-late-tour drift analysis (price stops 1-4 vs stops N-3..N).

**Cross-series comparables**:
For Series mode, show other 7-game series this season for context. Reads `matchup_history` filtered to recent.

### 3.6 Pricing Queue

The most important new surface. Drives `jaizer`'s actual workflow.

**Top breadcrumb**:
Filter description (e.g. "Knicks home games · 12 of 47") + ETA at current pace + resume-from-last-session indicator.

**Per-event card** (current cursor position):

| Block | Source |
|---|---|
| Event hero (logos + countdown + lifecycle badge) | `events` + `entity_event_map` + `event_lifecycle` |
| Market / Owned / Premium tiles | `event_metrics` |
| Last 5 comparable G5s strip | `find_similar_events()` filtered by series-position |
| **Per-zone pricer state** | `zone_pricer` (when wired) — list of all zones with Smart/Dumb badge, Status (Filter Red/Yellow/Green), Last Run, Synced timestamps |
| **Per-quantity ladder** for active zone | `zone_pricer.current_sg_2_base / sg_3_base / ... / sg_6_base` |
| **YOUR PRICE input** | Stepper — writes "suggested ask" to `pricing_queue_state` table (read-only v1 per audit §4 Q5) |
| Auto-analysis | `/api/broker/analysis/event/{id}` LLM slot |

**Keyboard**:
- `J` / `K` — next / prev event
- `[` / `]` — adjust suggested price
- `space` — save & advance
- `?` — help overlay
- `Esc` — exit queue

**Filter bar**:
performer / venue / matchup / league / lifecycle (default `is_active=true`). Filter is part of the persisted-state hash.

**Per-user state**:
`pricing_queue_state` table keyed by `(user_id, filter_hash)`. Stores cursor + per-zone suggested asks JSON. Server-side so a session can resume across days/devices.

**Output format**:
v1 = CSV export of (event_id, zone_name, suggested_base_price). Broker pushes to TEvo manually (per RULE 2: never POST/PUT to TEvo).

### 3.7 Movers + Cross-source Explorer (deferred)

Per code's redesign memo, ship after Templates 1-4. Reads `event_movers()` RPC for the classification (SUPPLY_FLOOD / RE_PRICING / GHOST_RESOLVE / DEMAND_SPIKE / DUMP) + `cross_source_coverage` for the explorer.

---

## 4. What's missing — schema additions needed before this can fully ship

| # | Object | Why | Priority |
|---|---|---|---|
| 1 | `zone_pricer` table | Mirror of the pricer CSV columns (per-event-per-zone). Drives Event Workbench zone breakdown deep view + Pricing Queue. | P1 — biggest gap |
| 2 | `venue_row_rank_method` enum on `venue_assets` (or new `venue_seating_config` table) | §2.1 — row-rank ambiguity is real | P2 |
| 3 | `hold_expires_at` on `unified_orders` view | Code already approved (audit §4 Q2) | P2 |
| 4 | `series_xref` table | Code approved table approach (audit §4 Q3) | P2 |
| 5 | `pricing_queue_state` table | Per-user cursor + suggested-ask persistence | P2 |
| 6 | `tour_metadata` table | Tour mode of T6; deferred per audit | P3 |
| 7 | NOAA `why_signals` API exposure | Weather panel on event hero (outdoor sports) | P3 |
| 8 | LLM analysis endpoint `/api/broker/analysis/{scope}/{id}` | Activates the placeholder slots across all surfaces | P3 |

---

## 5. Open questions for code

1. **`zone_pricer` schema** — should the table mirror the CSV exactly, or normalize into a few tables (one for the per-zone config, one for the per-run history, one for the per-qty-tier rules)? Recommend: 3-table normalization for query efficiency. Pricing Queue reads the latest run state; Event Workbench drawer reads the full config.
2. **Pricer ingest mechanism** — does the main system push CSV exports we ingest on a schedule, or do we pull via API? If pull, what's the auth + rate limit?
3. **Multi-venue row rank** — for venues with multiple configs (MSG bowls vs MSG concerts), is row-rank per-config or per-venue? Recommend per-config since the floor configurations differ.
4. **ESPN id collision detection** — should this be a server-side detection (a view that flags duplicate `espn_event_id` across active events) or computed client-side? Server-side recommended; one VIEW would do it.
5. **The Knicks G5/G3 fix** — when the dup ESPN id row gets cleaned (audit §5 item 2), do we want the audit log surfaced anywhere? Recommend a `xref_audit_log` table and a small "data fix history" page.

---

## 6. Build order

In priority order, smallest incremental wins first:

1. **`zone_pricer` ingest + schema** — biggest gap; unlocks Event Workbench zone-deep view + Pricing Queue.
2. **Wire 7 P1 endpoints from CODE_NOTES** — owned-premium, sentiment, similar, performer detail/baseline/history, canonical order buckets.
3. **Promote `templates.html` Templates 1+2** — Event Workbench + Performer Console with the new data bindings above. Replaces the current `static/index.html`.
4. **Pricing Queue v1 (read-only suggested-ask + CSV export)** — `pricing_queue_state` table + 3 endpoints. Highest workflow leverage per simulations.
5. **`venue_row_rank_method` + Venue Pulse** — promote Template 3.
6. **Series / Season / Tour Aggregator** — promote Template 6 with `series_xref` ingest.
7. **LLM analysis layer** — activates `💡 [pending]` slots across all surfaces.

---

## 7. References

- `docs/audit-2026-05-09.md` — code's review of this session's submission
- `docs/terminal-redesign-2026-05-09.md` — code's 7-page architecture (§3.1-§3.7 of this doc converge with that doc)
- `docs/historical-data-and-multi-view-strategy-2026-05-09.md` — zoom taxonomy + sentiment composite + similar-events
- `design/preliminary-event-views-2026-05-08.md` — 6-template baseline; this doc is the data-bound update
- `design/CODE_NOTES_2026-05-08.md` — backend hooks code needs to wire
- `design/MEDIA_ASSETS_2026-05-08.md` — visual asset resolution chain
- `static/_proposals/templates.html` — frontend skeleton
- `static/_proposals/preview-landing.html` — code-added 3-surface switcher
- Migrations referenced: 20260509030000 (nonowned median), 20260509050000 (lifecycle), 20260509060000 (SeatData), 20260509110000 (SG metrics), 20260509120000 (cross-source maps), 20260509130000 (matchup + sentiment + baselines), 20260509140000 (canonical order states)
- Pricer CSV: Julian's 2026-05-08 export of Knicks R2-G3 zone state (13 zones)

---

## 8. Status

Filed by: design · 2026-05-08
No code changes. No backend writes. Builds on code's prior work + the audit answers + the pricer CSV insight + Julian's row-rank correction. Ready for code review and selective implementation.
