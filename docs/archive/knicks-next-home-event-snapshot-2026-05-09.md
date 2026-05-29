# Next Knicks home game — full data snapshot (2026-05-09)

Companion to `database-map-2026-05-09.md` — runs the audit on a real event
to demonstrate what data the system has on a high-coverage TEvo event.

## The event

| Field | Value |
|---|---|
| `tevo_event_id` | **3345925** |
| Name | Philadelphia 76ers at New York Knicks (Game 5, NY Home Game 3) (If Necessary) |
| Date | **2026-05-12** 00:00 ET (Mon → tip 7:00 PM ET, naming differs) |
| Venue | Madison Square Garden |
| Home performer | New York Knicks |
| Event type | game |
| State | shown |
| Watch-tracked | yes |

## Data we have on this event

### TEvo (the firehose)

```
Listings snapshots:    122,197
Distinct ticket groups: 2,930
Capture times:           173 (since pulls began)
Latest capture:        2026-05-09 20:05 UTC (5 min before audit)
Tickets in latest snap:  900 (across 877 distinct groups, 79 sections)
Get-in (latest):       $493.58
Highest listing:       $28,000
Median retail:         $977.96
P75 retail:            $1,628.03
P90 retail:            $2,924.51
Owned share:           33.04% (we have 249 groups / 934 tix listed)
Owned median retail:   $1,131.17
Top-5 concentration:    0.22
Tail premium:           2.99x
Price dispersion:       2.25
```

Per-source aggregates:
- 173 `event_metrics` rows
- 11,106 `section_metrics` rows
- 243 `zone_metrics` rows

### Velocity (multi-window)

```
TEvo get-in 1h delta:   $0       (0%)   — flat
TEvo get-in 6h delta:   $0       (0%)
TEvo get-in 24h delta:  $0       (0%)
TEvo tickets 1h delta:  -4
TEvo tickets 24h delta: -98
SG side:                NULL — no SG data on this event
```

Get-in price stable but inventory is bleeding — 98 tickets came off in
24h, 4 in the last hour. That's the kind of slow-burn pattern an alert
rule could catch ("inventory falling >5%/24h with stable price").

### EVO orders

**0 orders** on this event. We're not currently selling Knicks G5.

### SeatGeek

```
sg_listings_snapshots:   0
sg_orders:               0
sg_seller_listings:      0
sg_event_metrics:        0
sg_canonical present:    no
```

SG carries this game on the consumer side but our broker pull doesn't
have it. This is the "SG xref naturally sparse" pattern — not a matcher
bug, just a coverage choice. Worth surfacing on a future product surface.

### SeatData (the only event we have)

```
sd_event_id:           1247184 (xref'd to TEvo on 2026-05-09)
SD sales rows:         254
SD sales price range:  $378 – $3,756
SD sales median:       $668.50
```

This is the **only event with SD coverage** in the entire database.
The 254 sales were pulled manually before the SD pipeline broke.
Useful as a comp benchmark: SD median sold price ($668.50) vs TEvo
median listed price ($977.96) = market is paying ~32% below ask.

### ESPN

```
espn_event_id:    401871162
Snapshots:        1
Latest state:     pre  (pre-game)
Latest status:    "5/10 - 3:30 PM EDT"
```

ESPN is reporting a 3:30 PM EDT start on 5/10 — TEvo lists 5/12.
This is the "If Necessary" Game 5 — TEvo is showing the latest possible
date; ESPN has the actual scheduled date once it became necessary.
The mismatch is informative, not broken.

### Wikipedia (AI/RAG context)

```
Performer Wikipedia present: yes
Extract (first 120 chars):
  "The New York Knickerbockers, shortened and more commonly referred
   to as the New York Knicks, are an American professiona..."
```

### Weather (indoor — no live forecast needed)

```
Venue:         Madison Square Garden  (40.7505, -73.9935)
is_indoor:     true
weather_kind:  indoor_no_weather
```

System correctly identifies MSG as indoor and skips the forecast.
Geocoding present (lat/lon set), days_to_event = 3.

### Competing events (±24h × 20mi)

```
Count: 1
  - Detroit Tigers at New York Mets (Citi Field, 7.7 mi away, +19.2 hr offset)
```

One competing event tomorrow night across town. At 19.2 hours offset and
7.7 miles, modest demand overlap — Mets fans and Knicks fans aren't
typically the same crowd, but the alert is logged for completeness.

### Alerts

```
Open alerts on this event: 1
```

(`competing_event_added` rule fired when the Mets game appeared in the
neighbor list.)

### Sentiment

```
sentiment_index: 54.15  (neutral-positive — 50 is baseline)
```

## What's missing

- **SG data** — naturally sparse (this game isn't in SG broker catalog)
- **EVO orders** — we haven't sold any tickets on this event yet
- **Live ESPN game state** — game hasn't started; will populate once tip
- **Inbound demand sentiment** — we have one row; chat-driven sentiment
  needs more interactions to be meaningful

## Coverage scorecard

| Source | Status |
|---|---|
| TEvo listings | ✓ 122K snapshots, dense capture history |
| TEvo metrics (event/section/zone) | ✓ |
| TEvo orders / EVO | — (no sales yet) |
| SeatGeek listings | ✗ (catalog gap, not a bug) |
| SeatGeek orders | ✗ |
| SeatData sales | ✓ 254 historic sales (only event with SD) |
| ESPN xref | ✓ 401871162 |
| ESPN game state | ✓ 1 snapshot, pre-game |
| Wikipedia | ✓ Knicks article enriched |
| Weather | ✓ correctly classified indoor |
| Competitors | ✓ 1 competing event listed |
| Alerts | ✓ 1 open |
| Sentiment | ✓ 1 row |

This is a **representative high-coverage event**. The gaps (SG, EVO orders)
are coverage choices and timing, not infrastructure failures.

## How to get the same view yourself

```sql
-- Single-call AI/RAG bundle:
SELECT jsonb_pretty(get_event_context(3345925));

-- Per-section pricing (TEvo + SG + SG-seller + SD):
SELECT * FROM v_pricing_cross_source WHERE tevo_event_id = 3345925;

-- Velocity:
SELECT * FROM v_event_velocity_windows WHERE tevo_event_id = 3345925;

-- Open alerts:
SELECT * FROM v_open_alerts WHERE tevo_event_id = 3345925;

-- Competitors:
SELECT * FROM event_competitors_snapshot WHERE tevo_event_id = 3345925;
```
