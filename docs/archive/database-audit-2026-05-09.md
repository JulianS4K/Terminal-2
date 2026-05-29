# Database audit — what's connected, what isn't, what's unused (2026-05-09)

Goal: for any random event, show what data we have on it, where the
gaps are, and which tables we collect into but never read from.

## TL;DR — the headline findings

1. **TEvo + ESPN + Wikipedia are wired correctly.** Any TEvo event we
   care about (popular sports + concert) gets full TEvo listings depth
   plus an ESPN xref plus performer Wikipedia text. End to end this
   side just works.

2. **SeatGeek cross-reference is sparse — but correct.** Initially
   reported as broken; on re-check the matcher correctly refuses to
   pair unrelated events sharing a date (e.g. BTS concert at Stanford
   vs WNBA game at Moda Center). The 208 unmatched `sg_events_canonical`
   rows are mostly events without a TEvo equivalent (concerts,
   non-major sports). See "SG xref state — corrected" below.

3. **SeatData is essentially silent.** 1 event xref'd, 254 sales rows
   on that one event. Either the SD pull pipeline isn't iterating
   events, or we're not feeding it the event list.

4. **Unmatched events bucket: 228 entries** — 208 SG + 20 EVO + 0 SD.
   The orphan bucket from mig 20260509330000 is doing its job; that
   number IS the work the day-trader has to clear.

5. **8 tables are collected into but never queried.** Not enormous,
   but worth pruning or wiring. List + verdict below.

## Per-event audit — Thunder @ Lakers G3 (tevo_event_id 3344959)

Tonight, 5/9 17:30 PT, Crypto.com Arena. Picked because it's a
high-traffic playoff game so any signal we have on a single event
should be present.

| Source | Rows / state | Verdict |
|---|---|---|
| `events` (TEvo)             | name, venue, performer, type=game, popularity 0 | ✓ basics fine |
| `listings_snapshots`        | **240,382** rows; 9,339 distinct ticket_groups; 354 capture times; latest 5/9 19:20 UTC; price $20–$13,133; 652 tickets in latest snap | ✓ deep |
| `event_metrics`             | 354 rows                | ✓ matches captures 1:1 |
| `section_metrics`           | 28,071 rows             | ✓ |
| `zone_metrics`              | 382 rows                | ✓ |
| `evo_orders` / `evo_order_items` | 1 line item        | ✓ (we sold 1 ticket) |
| `event_xref` → ESPN         | espn_event_id=401871328 | ✓ |
| `espn_event_snapshots`      | 3 rows                  | ✓ light but present |
| `performer_wikipedia`       | "The Los Angeles Lakers are an American professional basketball team based in Los…" | ✓ enriched |
| `performer_home_venues`     | row exists              | ✓ |
| `event_sentiment`           | 1 row                   | ✓ |
| `watch_sources`             | tracked                 | ✓ |
| **`seatgeek_listings_snapshots`** | **0**             | ✗ MISS |
| **`seatgeek_orders`**             | **0**             | ✗ MISS |
| **`seatgeek_seller_listings`**    | **0**             | ✗ MISS |
| **`seatgeek_event_metrics`**      | **0**             | ✗ MISS |
| **`sg_events_canonical`**         | not present       | ✗ MISS |
| **`seatdata_sales_snapshots`**    | **0**             | ✗ MISS |
| **`seatdata_listings_snapshots`** | **0**             | ✗ MISS |
| **`seatdata_event_xref`**         | not present       | ✗ MISS |
| `weather_observations`            | depends on lat/lon round | likely 0 (Crypto.com not in geocode set) |

**What "should" be on this event:** TEvo listings + metrics, ESPN
status, performer wiki, weather. We have all of those.

**What's missing despite being collectable:** SG marketplace pricing
+ SD historic comps. Both pipelines are running (crons active) and
both have data in their raw tables. The xref join is the failure.

## SG xref state — corrected

Initial finding ("69 obvious cross-source matches not xref'd") was a
**false positive** in the audit query. The fuzzy match used loose
substring overlap on event names, which produced spurious pairs like:

- SG "BTS" at Stanford Stadium ↔ TEvo "Connecticut Sun at Portland
  Fire" at Moda Center — different sport, different venue, same date.
- SG "Palomazo Norteno" at Kia Forum ↔ TEvo "Texas Rangers at Toronto
  Blue Jays" at Rogers Centre — different sport, different venue.

After re-querying with **same-venue + same-date**, only **1** legit
SG↔TEvo collision exists today, and the existing matcher correctly
rejects it (SG WNBA game vs TEvo Timberwolves at Target Center on the
same date — different performers, gated against ghost-matching).

The 208 unmatched `sg_events_canonical` rows are real cross-source
gaps in the TEvo catalog: SG carries lots of concerts and MLS/NCAAF
games that we don't pull into TEvo. Not a matcher bug — a coverage
choice.

```
sg_listings_snapshots:   7,298 total | 527 (7.2%) xref'd to tevo_event_id
sg_orders:                 400 total | 0 (0%)     xref'd
sg_seller_listings:        200 total | 1 (0.5%)   xref'd
sg_events_canonical:       211 total | 3 (1.4%)   xref'd
```

The low xref rates reflect that most SG events simply don't have a
TEvo equivalent in our event list. The matcher is doing its job —
correctly NOT pairing unrelated events that share a date.

**No fix needed.** The unified `cross_source_match_tick_30min` cron
(mig 20260509350000) keeps running the existing matcher and will pick
up new pairs whenever TEvo's event coverage and SG's overlap.

## SeatData near-empty

```
seatdata_event_xref:         1 row (with tevo_event_id)
seatdata_sales_snapshots:  254 rows on 1 event
seatdata_listings_snapshots: 0 rows
```

SD has the smallest footprint by far. The single covered event is
Knicks/76ers G5 (tevo 3345925, the "if necessary" Game 5). Either:
- SD pull pipeline isn't iterating its event list, OR
- We're not feeding it our event list (and it's only finding what we
  manually pulled)

**Fix path** (P2): identify why SD pulls aren't fanning out. The
`seatdata_pull_log` table has 0 rows, which is the smoking gun — no
pulls are even being logged.

## Cross-source xref scoreboard

| Pair | Status |
|---|---|
| TEvo ↔ ESPN | **100% clean** — 81 espn events, 430 xref rows, 0 espn orphans |
| TEvo ↔ Wikipedia (performer-level) | 183 enriched performers; works ✓ |
| TEvo ↔ SeatGeek | **broken** — see above |
| TEvo ↔ SeatData | **near-empty** — see above |
| SG ↔ SD | not directly attempted (everything goes via TEvo) |

## Datasets that exist but nothing reads

These tables hold data but no view or function references them.
Either they're abandoned, or they're waiting on a consumer to be
built. Verdict for each:

| Table | Rows | Verdict |
|---|---|---|
| `wiki_summary`            | 127 | **DROP** — superseded by `performer_wikipedia` |
| `wiki_rivalries`          | 25  | **DROP** — proposal artifact, no consumer planned |
| `event_sentiment`         | 18  | **WIRE** — sentiment_index column should feed `v_event_full`; trivial fix |
| `seatgeek_event_metrics`  | 494 | **WIRE** — being computed by SG cron, never JOINed; should appear in `v_pricing_cross_source` |
| `performer_baselines`     | 72  | **WIRE OR DROP** — used by `event_metrics` deltas? unclear |
| `venue_baselines`         | 67  | **WIRE OR DROP** — same question |
| `major_event_calendar`    | 14  | **WIRE** — could feed `v_competing_events` for major-event awareness (Super Bowl week, All-Star, etc.) |
| `espn_athletes`           | 857 | **WIRE FOR AI** — useful as RAG context (player rosters); not for SQL analytics |

The `*_pending` tables and `*_runs` log tables ARE supposed to have no
view consumer — they're operational scaffolding. Excluded from above.

## Active data plane (for reference)

39 active cron jobs in supabase. Categorized:

- **TEvo listings (windowed by event proximity)**: 5 crons (`collect-listings-0-24h` through `60d+`)
- **SeatGeek listings (matching cadence)**: 5 crons (`sg_listings_*`)
- **EVO orders**: 2 (`evo_orders_queue_30min`, `evo_orders_process_30min`)
- **SG seller orders + listings**: 3 (`sg_seller_*_30min`)
- **ESPN**: 3 (`crawl-espn-team-assets-3min`, `espn-team-daily`, `master-cascade-2min`)
- **Performer Wikipedia (enrichment only)**: 3 (search → process → summary)
- **Venue geocode + weather**: 4 (`venue_geocode_*`, `weather_*`)
- **SG canonical matcher**: 1 (`sg_canonical_auto_match_30min`) ← **the broken one**
- **Chat / corpus**: 4
- **Sweeps + maintenance**: 5

Zero crons hitting forbidden write paths (RULE 2 verified by static
audit + plpgsql scan).

## What a "complete" event SHOULD have

Using Thunder/Lakers G3 as the template, a fully-wired TEvo event has:

```
Tier 1 (must have, currently does):
  ✓ events row with venue + performer + type
  ✓ listings_snapshots: hundreds-to-thousands per capture
  ✓ event_metrics aggregates per capture
  ✓ section_metrics + zone_metrics
  ✓ event_xref → ESPN (for sports)
  ✓ espn_event_snapshots (game-day score / status)
  ✓ performer_wikipedia (text + image_url)
  ✓ performer_home_venues
  ✓ event_sentiment row(s)
  ✓ watch_sources (if tracked)

Tier 2 (should have, often missing):
  ✗ seatgeek_listings_snapshots with tevo_event_id set
  ✗ seatgeek_event_metrics
  ✗ sg_events_canonical with tevo_event_id set
  ✗ seatdata_event_xref + seatdata_sales_snapshots
  ✗ weather_observations (only populated within 16d of event)

Tier 3 (nice to have, deferred):
  – major_event_calendar tag (Super Bowl week etc.)
  – espn_athletes for player-level context (AI consumer)
  – evo_order_items aggregated by ticket_group
```

## Action items ranked by impact

| # | Action | Effort | Why it matters |
|---|---|---|---|
| 1 | ~~Fix SG matcher~~ — withdrawn, matcher is correct. Replaced by `cross_source_match_tick_30min` unified cron (mig 350000) | done | logs orphans across all sources for visibility |
| 2 | Diagnose why `seatdata_pull_log` is empty (cron not running? not iterating?) | small-medium | SD comps are real money signal; right now we have ~zero |
| 3 | Wire `seatgeek_event_metrics` into `v_pricing_cross_source` | small | data exists, just needs JOIN |
| 4 | Wire `event_sentiment` into `v_event_full` | small | data exists, currently invisible |
| 5 | Drop `wiki_summary` + `wiki_rivalries` | trivial | dead tables |
| 6 | Decide fate of `performer_baselines` + `venue_baselines` (wire or drop) | small | unclear ownership |
| 7 | Investigate weather coverage for non-NYC venues | medium | Crypto.com Arena likely missing geocode |

Items 1, 2, 5 are the most productive — high signal, low complexity.
Items 3, 4 are pure plumbing.
