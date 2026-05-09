# Tournament Event Detection — Tennis / Golf / F1 (2026-05-09)

## Why this is its own pipeline

The existing windowed-listing crons (`collect-listings-0-24h..60d+`)
iterate over the `events` table — they pull pricing for events we
already know about. Tournament events (multi-day single-tournament:
Masters, US Open Tennis, F1 races) weren't getting added to `events`
because the regular order-flow only adds events we **sell tickets
for**, and we don't generally hold inventory on tournaments.

This pipeline pulls them in proactively from TEvo's catalog.

## Why this is different from MLB-series detection

| Shape | Example | View |
|---|---|---|
| **Team-vs-team series** | Yankees @ Mets, 3 games at Citi Field | `v_mlb_game_series` |
| **Multi-day single tournament** | US Open Tennis Day 5, Masters Round 2 | (no view yet — see "future work" below) |

Different partition keys, different detection logic. The MLB view
groups by `(home_team, away_team, venue_id)`; a tournament view would
group by `(name_prefix, venue_id)` because the matchup changes each
day but the tournament name stays consistent.

## Geographic scope: continental North America

Per directive 2026-05-09: **drop anything not in continental North
America**. The filter `is_north_america_venue(text)` matches any
venue_location string ending in:
- US state code (50 + DC + PR)
- Canadian province code (AB, BC, MB, NB, NL, NS, NT, NU, ON, PE, QC, SK, YT)
- Or contains `, Mexico` / `, Canada` / `, USA` / `, United States`

Tested live: Italian Open, Wimbledon, Spanish/Austrian/Monaco GPs,
Open Championship (Royal Birkdale) — all correctly filtered out.

## How it works

1. **`tournament_categories` table** — lists TEvo `category_id`s to
   pull. Currently:
   - `25` = Tennis (5 pages = up to 500 events)
   - `24` = Golf (3 pages = up to 300 events)
   - `29` = Formula 1 (2 pages = up to 200 events)

   Hand-edit to add new categories (e.g. `27` Auto Racing for NASCAR,
   `33` Horse Racing if relevant).

2. **`tournament_pull_queue(p_max_pages)`** — for each enabled
   category, fires signed `GET /v9/events?category_id=X&page=N&per_page=100&occurs_at.gte=<today>`
   per page. Skips queries already fired in the last 24h.

3. **`tournament_pull_process()`** — reads pg_net responses, applies
   `is_north_america_venue()` filter, UPSERTs into `events`.

4. **Cron**: `tournament_pull_queue_weekly` (Sun 04:00 UTC) +
   `tournament_pull_process_weekly` (Sun 04:05 UTC). Tournaments
   don't change inventory daily; weekly is sufficient.

## Why TEvo `name=` and `q=` don't work for this

We tried them first. Findings (live-probed 2026-05-09):
- `name=Masters Tournament` → returns 0 events (requires exact match
  on `events.name` field; tournament names like
  `"2026 Masters Tournament - Round 1"` don't match)
- `q=Masters` → returns 145 events but they're plays/concerts/
  masterclasses; the actual tournament not in the result set
- `q=Masters Tournament` (full phrase) → returns 0
- `q=` on `/v9/performers` is silently ignored (returns full 107K list)

`category_id=` is the only reliable filter for tournament discovery.
Documented here so the next person doesn't waste an afternoon.

## Live results (first run, 2026-05-09)

```
F1     | 2 pages | 90 returned  | 20 N.America kept | 70 Europe/Asia filtered
Golf   | 3 pages | 48 returned  | 31 N.America kept | 17 non-NA filtered
Tennis | 5 pages | 354 returned | 230 N.America     | 124 non-NA filtered
                              ───────                ────
Total persisted: 281 events                         211 dropped
```

Tournaments captured (sample):
- Tennis: US Open Tennis (52 events), Cincinnati Open (41), Indian
  Wells (42), Miami Open (24), Mubadala Citi DC Open, National Bank
  Open (Toronto/Montreal)
- Golf: LIV Golf US events (Andalucia, Louisiana, Virginia)
- F1: Canadian Grand Prix (5), Las Vegas Grand Prix (5)

Tournaments NOT captured (because already past, or not yet in TEvo):
- Masters Tournament (April 2026 — past)
- F1 Miami GP (May 2026 — past)
- US Open Golf (June 2026 — should appear soon)
- F1 US GP (October 2026 — may appear closer to date)
- F1 Mexico City GP (October — may appear closer to date)

Weekly cron will pick these up as TEvo adds them.

## How to add a new tournament category

```sql
INSERT INTO tournament_categories(category_id, tevo_label, genre, pages_to_pull, notes)
VALUES (27, 'Auto Racing', 'racing', 3, 'NASCAR + IndyCar');
```

Categories list (live-probed):
| ID | Label | Notes |
|---|---|---|
| 24 | Golf | enabled |
| 25 | Tennis | enabled |
| 27 | Auto Racing | NASCAR + IndyCar would land here |
| 29 | Formula 1 | enabled |
| 33 | Horse Racing | low priority |
| 135 | Amateur Golf | NCAA/USGA non-pro |
| 209 | Motorsports | superset of auto/F1; redundant |
| 990 | NCAA Tennis | college tennis |

## How to extend the geographic filter

Edit `is_north_america_venue()` to add e.g. Caribbean ticketing
venues, but be careful: TEvo's venue_location is "City, State" format
for US, "City, Borough, Province" for Canada, "City, Country" for
Mexico — non-NA venues use "City, Country" only (e.g. "Rome, Italy").
Adding more countries requires explicit ILIKE matches, not regex.

## Future work

### `v_tournament_grouping` view (deferred)

Would group events by `(name_prefix, venue_id)` where name_prefix is
everything before " - " or " (". Examples:
- `"2026 Formula 1 - Canadian Grand Prix - Friday"` → prefix
  `"2026 Formula 1 - Canadian Grand Prix"`
- `"US Open Tennis - Session 5"` → prefix `"US Open Tennis"`

Result: one row per tournament with `tournament_name`, `venue_name`,
`start_date`, `end_date`, `total_sessions`, `tevo_event_ids[]`.

Same idea as `v_mlb_game_series` but with different partition keys.
Skipped for now — the existing 281 events are useful as-is, and the
view can be added later when a UI surface needs it.

### `get_event_context()` extension

Once `v_tournament_grouping` exists, AI/RAG context for any session
can include `"this is session 5 of 14 in the US Open Tennis at the
USTA Billie Jean King NTC, Aug 30 – Sep 13."` That's the natural
follow-up. Keep it kanban'd until UI demands it.

### Pages_to_pull tuning

If a category's catalog grows beyond the configured pages, we'd miss
events. Monitor via:

```sql
-- Pages whose returned count == per_page (saturated; increase pages_to_pull)
SELECT category_id, page, events_returned
FROM tournament_category_pending
WHERE events_returned = 100 ORDER BY fired_at DESC LIMIT 10;
```

Tennis hit 354 events in 5 pages (max 500) so we have headroom.

## Sample queries

### Next 5 tournament events in N.America

```sql
SELECT name, occurs_at_local, venue_name, venue_location
FROM events
WHERE event_type = 'game'  -- TEvo categorizes most tournaments as 'game'
  AND occurs_at_local::timestamptz > now()
  AND name ~* '(open|tournament|championship|grand prix|masters|liv golf)'
ORDER BY occurs_at_local::timestamptz LIMIT 5;
```

### All US Open Tennis sessions

```sql
SELECT id, name, occurs_at_local, venue_name
FROM events
WHERE name ILIKE '%US Open%' AND venue_name ILIKE '%USTA%'
ORDER BY occurs_at_local::timestamptz;
```

### F1 N.America calendar

```sql
SELECT name, occurs_at_local::date, venue_name, venue_location
FROM events
WHERE name ILIKE '%grand prix%'
  AND occurs_at_local::timestamptz > now()
ORDER BY occurs_at_local::timestamptz;
```
