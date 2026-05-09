# MLB Regular-Season Game Series — Detection (2026-05-09)

## Why this is its own doc

Among the leagues we cover (NBA, NFL, MLB, NHL, MLS, WNBA, F1), **MLB
is the only one that uses a "series" structure during the regular
season**. Every MLB regular-season home stand is built from 3- or
4-game series — same matchup, same venue, consecutive days. This
shapes how a broker thinks about pricing (game 1 vs game 3 of a
series prices very differently; weekend series dramatically different
from midweek; rivalry-branded series carry their own demand premium).

Detection has to be automated because:
- TEvo doesn't tag series in the event name
- The data is the only source of truth
- Manual labeling 162 games × 30 teams ÷ 2 sides ÷ ~3 games per series
  ≈ 800 series/year is not happening

This doc records the detection rule + the branded-series reference
table so the next person (or AI) extending this knows the contract.

## Cross-sport context (why we don't do this for NBA/NFL/etc.)

| League / phase | Series shape | Detection approach |
|---|---|---|
| **MLB regular season** | **3–4 games, same teams, same venue, consecutive days** | **`v_mlb_game_series` (this doc)** |
| MLB postseason | Best-of-5 / best-of-7, named "Game 1, Game 2, ..." | TEvo names them explicitly. Don't auto-detect; parse from name if needed. |
| NBA / NHL regular season | "Back-to-back" = same teams 2 nights, but at *different* venues. Not a series. | n/a — no concept |
| NBA / NHL playoffs | Best-of-7, named "Game N, Home Game M (If Necessary)" | TEvo names explicitly. Same as MLB postseason. |
| NFL | 1 game/week. No series concept. | n/a |
| MLS / soccer | Occasional 2-leg knockouts (CONCACAF, USOC). Rare. | Out of scope; flag as different shape if needed later. |
| WNBA | Single games regular season; best-of-N playoffs same as NBA. | TEvo handles via Game N naming for playoffs. |

So this whole doc applies to one specific shape: **MLB regular season,
April–September**.

## Schema

### `mlb_branded_series` — reference table

```
branded_name (PK)         text     "Subway Series"
team_a                    text     "New York Yankees"
team_b                    text     "New York Mets"
notes                     text     freeform
added_at                  timestamptz
```

Hand-maintained. The view applies the brand whenever a detected
series matches `(team_a, team_b)` in either direction (so home/away
order doesn't matter).

Initial seeds (mig 20260509470000):

| Brand | Teams | Notes |
|---|---|---|
| Subway Series | Yankees / Mets | Interleague NYC |
| Battle of Ohio | Guardians / Reds | I-71 |
| Freeway Series | Dodgers / Angels | I-5 |
| Bay Bridge Series | Giants / Athletics | SF Bay (A's now Sacramento) |
| Crosstown Classic | Cubs / White Sox | Also "Windy City Showdown" |
| Citrus Series | Marlins / Rays | Florida |
| Lone Star Series | Astros / Rangers | TX |
| Beltway Series | Orioles / Nationals | I-95 / Acela |
| I-70 Series | Cardinals / Royals | Also "Show-Me Series" |
| Battle of Pennsylvania | Phillies / Pirates | PA |

To add a new brand:
```sql
INSERT INTO mlb_branded_series(branded_name, team_a, team_b, notes)
VALUES ('My New Series', 'Team A', 'Team B', 'one-line context');
```
The view picks it up immediately on next read. No code change.

### `v_mlb_game_series` — detection view

Returns one row per detected series:

| Column | Type | What |
|---|---|---|
| `home_team`, `away_team` | text | the two teams |
| `venue_id` | bigint | TEvo venue id |
| `venue_name` | text | venue display name |
| `series_start`, `series_end` | date | first / last game of series |
| `series_span_days` | int | end − start + 1 |
| `game_count` | int | number of games |
| `tevo_event_ids` | bigint[] | array of all events in series, ordered by date |
| `branded_series_name` | text | NULL or the matched brand from `mlb_branded_series` |

## Detection algorithm (English)

1. **Filter to MLB regular-season games:**
   - `event_type = 'game'`
   - `name ILIKE '% at %'` (the standard "Away at Home" naming)
   - `name NOT ILIKE '%(Game %'` and `NOT ILIKE '%(If Necessary%'`
     (excludes postseason which TEvo names differently)
   - `primary_performer_name` and `venue_id` not null
   - **Both** teams (home from `primary_performer_name`, away from
     `split_part(name, ' at ', 1)`) must appear in the MLB performer
     subreddit set — this excludes preseason games, exhibition games,
     and any non-MLB content
2. **Gap analysis:** for each `(home_team, away_team, venue_id)`
   partition, walk events sorted by date and start a new series
   whenever the gap exceeds 2 days. (3-game series have 0 gap;
   4-game series have ≤1 day gap; 2-day buffer covers occasional
   travel days or rainout doubleheader splits.)
3. **Group + brand:** group by partition + series id, aggregate, and
   left-join `mlb_branded_series` on `(team_a, team_b)` in either
   order.

## Verification (2026-05-09)

Live coverage as of phase1-baseline:
- **243 series detected** across 1,558 events
- **726 total games** in series
- **15 series across 9 rivalry brands** auto-labeled
- Bay Bridge Series the only seeded brand absent (A's-Giants regular-
  season meetings disrupted by A's Sacramento relocation)

Yankees-specific verification:
```
24 series detected over the next 6 weeks. Subway Series correctly
labeled at row 8 (Mets @ Citi Field, May 15–17, 3 games).
```

## Sample queries

### Next branded rivalry series (next 30 days)

```sql
SELECT branded_series_name, home_team, away_team, venue_name,
       series_start, series_end, game_count
FROM v_mlb_game_series
WHERE branded_series_name IS NOT NULL
  AND series_start BETWEEN current_date AND current_date + 30
ORDER BY series_start;
```

### "What series is this event part of?"

```sql
SELECT *
FROM v_mlb_game_series
WHERE 3091557 = ANY(tevo_event_ids);  -- Subway Series Game 1, May 15
```

### All home series at Yankee Stadium this season

```sql
SELECT * FROM v_mlb_game_series
WHERE home_team = 'New York Yankees' AND venue_name = 'Yankee Stadium'
ORDER BY series_start;
```

### Pricing within a series — game 1 vs game 3

```sql
WITH series_games AS (
  SELECT unnest(tevo_event_ids) AS event_id,
         generate_subscripts(tevo_event_ids, 1) AS game_number,
         branded_series_name, home_team, away_team
  FROM v_mlb_game_series
  WHERE series_start = '2026-05-15' AND home_team = 'New York Mets'
)
SELECT sg.game_number, sg.event_id, lem.getin_price, lem.tickets_count
FROM series_games sg
JOIN latest_event_metrics lem ON lem.event_id = sg.event_id
ORDER BY sg.game_number;
```

## How to extend

### To add another branded rivalry

Just `INSERT INTO mlb_branded_series` — see schema section above. The
view picks it up on next read.

### To extend the detection rule (other sports)

Don't repurpose this view. Build sport-specific detection because
the *shape* differs:

- **MLS / soccer 2-leg knockouts:** same teams, *different* venues
  (1 home for each side), within 7–14 days. Detection partitions
  by `(team_a, team_b)` only, not venue.
- **Special-event "series":** Rivalry weeks (e.g. NFL Color Rush,
  NBA Crossover) — those are league-level branding, not date-based
  detection. Use `mlb_branded_series`-style reference tables but key
  on event ids directly.

### If TEvo changes naming convention

The `' at '` split is the linchpin. If TEvo ever names games
differently (e.g. "Yankees vs Mets") the parsed CTE in
`v_mlb_game_series` needs adjustment. Watch the audit script for
test failures on `test_canonical_views_exist`.

## Future work

- **Doubleheader handling:** when 2 games on the same date, the view
  groups both into the series correctly via array agg, but the
  `series_span_days` calc still works because it's `max - min + 1`.
  No special-casing needed; just noting it works.
- **Series fatigue signal:** game 4 of a 4-game series tends to draw
  worse than game 1. Could add a `series_position` (1-of-N) column
  derived from `array_position(tevo_event_ids, event_id)` for
  per-event pricing context. Add to `get_event_context()` if/when
  AI/RAG callers want it.
- **Auto-rotate brand on team rename:** if "Cleveland Guardians" is
  renamed (unlikely but possible), the brand row needs an UPDATE.
  No automation — hand maintenance.
