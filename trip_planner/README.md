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
optimal:{count,value,travel_km,events[]}, baseline_by_date:{...}, shows_gained, all_dates[] }`.

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
- The km budget can become a **$ budget** by making `prize`/cost price-aware — the cost model
  is isolated in `gigtrip/distance.py` by design.
