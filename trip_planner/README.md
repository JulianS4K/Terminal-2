# trip_planner — optimal trips around live events

Shared server-side module that plans the **maximum-value multi-city itinerary** around a
performer's upcoming tour dates, within a travel budget. Used by:

- **D1 store** — `GET /api/store/performers/{performer_id}/trip-plan` (consumer, open)
- **D0 terminal** — `GET /api/broker/performers/{performer_id}/trip-plan` (auth-gated)

Both routes are thin wrappers over `plan_performer_trip()`; the planning logic lives here so
the two surfaces never duplicate it.

## How it works
Every event has a fixed date, so the calendar forces visit order — planning is **selection
under a travel budget**, not a travelling-salesman ordering problem. The engine
(`gigtrip/`, vendored verbatim from [axiom-orion/gigtrip](https://github.com/axiom-orion/gigtrip),
MIT — see `NOTICE.md`) solves it exactly with a Pareto label-setting DP, verified against a
brute-force oracle. Bandsintown + Streamlit layers of the upstream project are **not**
vendored — we feed the optimizer our own `public.v_event_base` data instead.

It is pure compute: **no writes, no upstream API calls** (consistent with the read-only
lockdown in `CLAUDE.md`/`PROJECT_BIBLE.md §1`).

## API
```
GET /api/store/performers/{performer_id}/trip-plan
      ?home_lat=&home_lon=&budget_km=6000&home_name=&days=365&max_events=
```
Returns `{ performer, performer_id, home, budget_km, window, tour_date_count,
coord_coverage:{venue,city_fallback,dropped_no_coords},
optimal:{count,value,travel_km,events[]}, baseline_by_date:{...}, shows_gained, all_dates[] }`.
Each event carries `coord_source` = `"venue"` (precise geocode) or `"city"` (centroid fallback).

### Location data + the city-centroid fallback
EVO/TEvo gives an event only **text** location (`venue_name` + `venue_location` "City, ST" +
`venue_id`) — **no coordinates**. The lat/lon the planner needs is geocoded separately into
`venue_assets` (`geocode_source='nominatim_osm'`), which has gaps (un-geocoded venues, some
mis-citied rows). Without a fallback those shows get NULL coords and are silently dropped
(e.g. Ariana Grande: 17 of 25 dates routable, Kia Forum + Barclays shows lost).

`city_centroids.py` closes most of that gap: for any event missing a precise geocode, it
resolves EVO's reliable `events.venue_location` "City, ST" text to an approximate city
centroid (static gazetteer of North American touring markets — no external call). Such shows
are tagged `coord_source="city"` and still routed; a few km of imprecision is negligible
against inter-city legs. Cities not in the gazetteer fall through to `dropped_no_coords`
(reported, not silent).

`optimal.events` is the recommended itinerary (date order); `all_dates` is the full tour so
the UI can show selected vs skipped. `baseline_by_date` is the naive sort-by-date trip, kept
so the UI can show the value the optimizer adds.

## Test
```bash
python3 -m trip_planner.test_ariana
```
Offline end-to-end on a real tour snapshot (Ariana Grande, performer 27474). Asserts the
exact optimizer equals the brute-force oracle, and that it beats the baseline at a binding
budget.

## Notes / next
- Single performer = uniform preference weights (every show valued 1.0); the engine already
  supports a `prefs` map for the multi-performer "plan my whole summer" case.
- **Two-budget mode** (`budget_optimizer.py`): pass `budget_usd` + `qty` and the trip must fit
  BOTH the travel-km budget and a ticket-spend budget. Per-show cost = `evo_retail_getin ×
  max(0, qty − evo_owned_tickets)` (owned tickets free), pulled from
  `event_listing_snapshot_daily`. The 2-budget solver is an exact Pareto label-setting DP
  (cross-checked against a brute-force oracle in `test_ariana.py`). The vendored gigtrip
  engine is untouched — this is a sibling module reusing its geometry helpers.
