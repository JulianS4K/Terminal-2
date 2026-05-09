# Concerts / Broadway / Tours / Residencies — Detection (2026-05-09)

Three structural patterns detected automatically from the `events`
table, each with its own view. Companion to:
- `docs/mlb-game-series-detection.md` (team-vs-team series)
- `docs/tournament-event-detection.md` (multi-day single-tournament)

## Three patterns + their detection rules

| Pattern | Shape | View | Threshold |
|---|---|---|---|
| **Tour** | Same performer at ≥2 distinct venues, multi-city | `v_performer_tours` | `venue_count >= 2`, future 12 months |
| **Residency** | Same performer at ONE venue, ≥3 dates over ≥14 days | `v_performer_residencies` | `show_count >= 3`, span ≥14 days |
| **Broadway run** | Subset of residencies at known Broadway theaters | `v_broadway_runs` | residency + venue match |

Each is a query against the events table, no separate storage.

## Examples (verified live 2026-05-09)

### Tours

```
UB40                  | 27 venues | 28 shows | Oct 2 → Nov 15 2026 | 17 regions (US + Canada)
Bayonne               | 27 venues | 27 shows | Sep 27 → Nov 24 2026 | 24 states
Madison Beer          | 12 venues | 12 shows | Jun 23 → Jul 13 2026 | 11 regions
Suffs (Musical)       |  4 venues | 23 shows | May 9 → Jun 5 2026   | 4 regions (Broadway-on-tour)
```

### Residencies

```
Sphere (Las Vegas, NV — venue_id 44984):
  The Wizard of Oz at Sphere   | 256 shows | May 9 → Aug 27 2026 (110 days)
  Backstreet Boys              |  18 shows | Jul 16 → Aug 22 (37 days)
  No Doubt                     |  16 shows | May 9 → Jun 13  (35 days)
  Kenny Chesney                |   9 shows | Jun 19 → Jul 11 (22 days)
```

### Broadway runs

```
The Lion King — Minskoff Theatre   | 32 shows | May 9 → Jun 5 2026 (27 days)
Wicked — Gershwin Theatre          | 33 shows
Hadestown — Walter Kerr Theatre    | 33 shows
MJ The Musical — Neil Simon        | 33 shows
Maybe Happy Ending — Belasco       | 32 shows
Stranger Things — Marquis Theatre  | 32 shows
... (10+ more)
```

## Why we needed venue-specific pulls (`venue_pulls` table)

TEvo's `/v9/events?category_id=54` is **popularity-sorted**. With
`pages_to_pull=20` (= 2000 events), we cover the most-popular global
concerts. But:

- **Bruce Springsteen tour stops** outside MSG — not in top 2000
- **Sphere residencies** — niche venue, lower aggregate popularity than
  individual major-arena concerts
- **MSG residencies** (Phish, Billy Joel runs) — same problem

**Solution:** seed `venue_pulls` table with TEvo `venue_id`s for venues
we want full coverage on, regardless of popularity. The companion
function `venue_pull_queue()` fires `/v9/events?venue_id=X&page=N`
paginated.

Initial seeds (mig 510000):
| TEvo venue_id | Venue | Reason |
|---:|---|---|
| 44984 | Sphere (Las Vegas, NV) | Residency venue |
| 896 | Madison Square Garden | Major arena, Bruce/Phish/Billy Joel runs |
| 1262 | Hard Rock Stadium | Major arena (also tennis Miami Open) |

To add a venue: look up the `venue_id` via `/v9/venues?name=<query>`,
then `INSERT INTO venue_pulls(...)`. Weekly cron picks it up.

## Schema reuse

`venue_pulls` reuses the existing `tournament_category_pending` queue
table by storing rows with `category_id = -venue_id` as a sentinel.
The existing `tournament_pull_process()` function processes both
category-based and venue-based pulls identically — same UPSERT shape
into `events`. This avoided creating a parallel queue/process pair.

## Detection logic (in plain English)

### `v_performer_tours`

Group all future events (next 12 months) by `primary_performer_id`.
Keep rows where `count(DISTINCT venue_id) >= 2`. Output:
- `venue_count`, `show_count`, `tour_first_show`, `tour_last_show`,
  `tour_span_days`
- `venues[]` array (alphabetical)
- `regions[]` array (state codes / countries)
- `tevo_event_ids[]` (chronological)

Excludes `event_type = 'game'` so MLB road trips don't pollute.

### `v_performer_residencies`

Group all future events (next 24 months — longer because Broadway
runs span years) by `(primary_performer_id, venue_id)`. Keep where:
- `count(*) >= 3`
- `(max_date - min_date) >= 14`

Output: same shape as tours, plus `venue_id`, `venue_name`,
`venue_location`.

Includes both Vegas-style residencies and Broadway runs.

### `v_broadway_runs`

Subset of `v_performer_residencies` where venue_name matches a known
Broadway theater (hardcoded list in the view). Adds
`broadway_theater_name` column derived from `important_x_accounts`
where `account_type='broadway_theater'`.

The hardcoded venue list is in the WHERE clause (`venue_name ILIKE
ANY (ARRAY[...])`). Adding a new Broadway theater means editing the
view, not just inserting data — TODO: refactor to a reference table
when the list outgrows ~30 entries.

## Edge cases / caveats

- **A residency that's also touring**: rare but possible (artist
  has Vegas residency dates AND tour stops). Both views will show
  them; consumer needs to disambiguate. Acceptable today.

- **Broadway "tour" labeling**: a Broadway show on national tour
  (e.g. "Mean Girls — National Tour") will appear in both
  `v_performer_tours` (multiple cities) AND potentially
  `v_performer_residencies` if the touring production sits at a
  single regional venue for ≥14 days. That's the right behavior —
  it IS a residency at that regional venue while being a tour overall.

- **Concert pull popularity coverage**: the 2000-event ceiling means
  niche tours (regional folk artists, small venues) won't surface.
  The trade-off: more pages = more API cost + storage. 20 pages is
  fine for current needs.

- **N. America filter applies here too** (from mig 490000). Non-NA
  venues filtered at INSERT time. International tours (Coldplay's
  Paris dates, Taylor Swift's Tokyo) won't appear unless they hit a
  N.A. stop.

- **TEvo rate limits**: live-tested today, hit 429 after ~30 paged
  GETs in quick succession. The weekly cron stagger
  (04:00 / 04:05 / 04:15 / 04:25) should keep us under the budget.
  If we add many more venue pulls, may need to spread firing over
  multiple cron windows.

## Sample queries

### Bruce Springsteen tour visibility (after weekly cron lands his data)

```sql
SELECT * FROM v_performer_tours
WHERE primary_performer_name ILIKE '%bruce springsteen%';
```

### Find all Broadway shows currently running

```sql
SELECT primary_performer_name, venue_name, show_count, residency_span_days
FROM v_broadway_runs
ORDER BY residency_start;
```

### Compare Sphere residency demand

```sql
SELECT pr.primary_performer_name, pr.show_count,
       lem.getin_price, lem.retail_median
FROM v_performer_residencies pr
JOIN events e ON e.id = pr.tevo_event_ids[1]      -- first show
LEFT JOIN latest_event_metrics lem ON lem.event_id = e.id
WHERE pr.venue_id = 44984
ORDER BY lem.retail_median DESC NULLS LAST;
```

### "What kind of event is this?" — chatbot context

```sql
-- Given a tevo_event_id, classify as tour/residency/broadway/none
WITH classified AS (
  SELECT
    EXISTS(SELECT 1 FROM v_performer_tours        WHERE $1 = ANY(tevo_event_ids)) AS is_tour,
    EXISTS(SELECT 1 FROM v_performer_residencies  WHERE $1 = ANY(tevo_event_ids)) AS is_residency,
    EXISTS(SELECT 1 FROM v_broadway_runs          WHERE $1 = ANY(tevo_event_ids)) AS is_broadway,
    EXISTS(SELECT 1 FROM v_mlb_game_series        WHERE $1 = ANY(tevo_event_ids)) AS is_mlb_series
)
SELECT * FROM classified;
```

## Future work

- **`get_event_context()` extension**: surface tour/residency/Broadway
  classification + position-in-run ("Game 4 of 6 at Sphere",
  "Show 17 of Lion King's run"). Easy add when AI/RAG calls demand it.
- **Reference table for Broadway theaters**: move the hardcoded
  `venue_name ILIKE ANY (...)` list to a queryable table.
- **Rate-limit-aware queue**: detect 429 responses and exponentially
  back off. Currently we just retry next week.
- **More residency venues**: add Caesars Palace Colosseum, Dolby Live
  at Park MGM, Resorts World Theatre, BleauLive Theater at
  Fontainebleau when their TEvo venue_ids are confirmed.
