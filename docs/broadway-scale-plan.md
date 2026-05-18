# Broadway scale plan (2026-05-18)

How D3 scales `broadway_client.py` from per-show smoke tests to
all-Broadway daily coverage. Resolves three issues raised in
`docs/broadway-live-testing.md` planning notes:

- **P1 #4** — Fastly bot-velocity at scale: addressed by cadence ladder
- **P2 #7** — Storage volume at year-scale: addressed by reusing evo/sg
  schema shape + 30-day raw retention
- **P2 #9** — Missed-day backfill detection: addressed by a
  monitoring view; backfill itself remains impossible

Companion to:
- `docs/broadway-live-testing.md` — testing runbook + Fastly defenses
- `docs/concerts-broadway-tours-residencies.md` — detection views
- `supabase/migrations/<ts>_broadway_listings_pipeline.sql` — schema (drafted, not applied)

## Decision 1 — Mirror evo/sg schema shape, don't invent a new one

Existing canonical pattern (from `supabase/migrations/20260424000000_listings_v2.sql`):

| Table | Retention | Granularity |
|---|---|---|
| `listings_snapshots` | 60d sweep via `sweep_old_listings()` | one row per (event, captured_at, ticket_group) |
| `event_metrics` | indefinite | one row per (event, captured_at) — aggregated |
| `section_metrics` | indefinite | one row per (event, captured_at, section) — aggregated |

SeatGeek + SeatData each mirror this with parallel `*_listings_snapshots`
tables (`seatgeek_listings_snapshots`, `seatdata_listings_snapshots`).
We follow the same convention rather than reusing the canonical
`listings_snapshots` directly — broadway has fields evo doesn't
(`fee`, `price_index`, `ticket_type`) and the schema is tightly
coupled to TEvo's `tevo_ticket_group_id`.

### Broadway tables (parallel shape)

```
broadway_listings_snapshots  (30d retention)
broadway_event_metrics       (indefinite)
broadway_section_metrics     (indefinite)
broadway_pull_log            (already referenced at broadway_client.py:288)
broadway_event_xref          (broadway_event_id ↔ tevo_event_id when canonicalized)
broadway_pull_queue          (slug, event_id, performance_time, last_snapshot_at)
```

### Field mapping — SectionListing → broadway_listings_snapshots

| `listings_snapshots` field | `broadway_listings_snapshots` field | Source |
|---|---|---|
| `event_id` | `broadway_event_id` (bigint) | `payload.event_id` |
| `captured_at` | `captured_at_utc` (timestamptz) | client clock |
| `tevo_ticket_group_id` | `price_index` (bigint) | `SectionListing.price_index` (unique per tier) |
| `section` | `section_name` (text) | `SectionListing.name` |
| `row` | (omitted) | broadway never exposes row |
| `quantity` | (omitted, use `splits`) | `SectionListing.quantities[]` |
| `retail_price` | `face_price` (numeric) | `SectionListing.price` |
| `wholesale_price` | (omitted) | broadway is primary retail, no wholesale |
| `format` | `ticket_type` (text) | `SectionListing.ticket_type` (Standard/Premium) |
| `splits` | `splits` (int[]) | `SectionListing.quantities` |
| `wheelchair` | (omitted) | not exposed |
| `instant_delivery` | (constant TRUE) | broadway is always e-ticket |
| `eticket` | (constant TRUE) | broadway is always e-ticket |
| `is_ancillary` | (omitted) | no parking / hospitality in broadway flow |
| **new**: `fee` (numeric) | service fee on top of face | `SectionListing.fee` |
| **new**: `area_indexes` (int[]) | broadway's seating-area ids | `SectionListing.area_indexes` |
| **new**: `broadway_show_id` (bigint) | for joins to broadway_shows | `payload.show.aristotle_id` |

### Retention — 30 days for raw, indefinite for metrics

`sweep_old_broadway_listings()`:
```sql
DELETE FROM broadway_listings_snapshots
WHERE captured_at < now() - interval '30 days';
```

Tighter than evo's 60d because Broadway pricing is slower-moving (no
last-minute getin spikes the way sports has) — 30d covers the
analytical window for a typical show. `broadway_event_metrics` +
`broadway_section_metrics` retain indefinitely (small aggregated rows,
matches evo).

**Pull-log retention**: 30 days as well. `broadway_pull_log` accumulates
~one row per fetch attempt; at scale that's ~400 rows/day, ~12K/month.
Worth keeping for diagnostics but not forever.

### Volume budget (post-mirror, post-retention)

- `broadway_listings_snapshots`: ~30 shows × ~8 perfs avg × ~6 sections × 30 daily snapshots = **~43K rows in steady-state** (rolling 30-day window). Each row ~200 bytes → 8 MB. Trivial.
- `broadway_event_metrics`: 30 × 8 × 365 = **~88K rows/year**, ~500 bytes each = ~45 MB/year. Indefinite-retention fine for 20+ years.
- `broadway_section_metrics`: ~6× event_metrics = ~530K rows/year, ~250 MB/year. Still fine.
- `broadway_pull_log`: ~12K rows in 30-day window after retention sweep. Trivial.

That's two orders of magnitude under the original "7 GB/yr if `keep_raw=True`" estimate, because we don't store raw payloads — only the parsed `SectionListing` dataclass shape.

## Decision 2 — Cadence ladder keyed on `hours_to_event`

### Mirror evo's bucket pattern

Existing evo cadence (from `supabase/migrations/20260513185058_cron_io_diet.sql` + `20260515250003_listings_cadence_halve.sql`):

| Bucket (evo) | Schedule | Notes |
|---|---|---|
| `collect-listings-0-24h` | `*/10 * * * *` (every 10m) | High-frequency tier |
| `collect-listings-1-7d` | `5 */2 * * *` (every 2h) | Halved from hourly |
| `collect-listings-7-30d` | `10 */8 * * *` (every 8h) | Halved from 4h |
| `collect-listings-30-60d` | `15 */12 * * *` (every 12h) | |
| `collect-listings-60d+` | `20 2 * * *` (1/day) | |

### Broadway buckets — coarser, Fastly-aware

Broadway pricing moves slowly compared to sports. And Fastly's bot
management on `*.broadway.com` punishes velocity. Two buckets only:

| Bucket (broadway) | Schedule | Window | Notes |
|---|---|---|---|
| `broadway-collect-0-72h` | `0 * * * *` (every hour, on the hour) | 0 ≤ hours_to_event < 72 | Hot window — capture intraday price moves |
| `broadway-collect-72h+` | `30 5 * * *` (1/day at 05:30 UTC) | hours_to_event ≥ 72 | Default daily |
| (skip) | — | hours_to_event < 0 | Event passed; never re-fetch |

At steady-state, with ~30 shows × ~8 perfs/show:
- Within 72h: roughly 30 × 8 × (72/24) × (perfs in window) = ~24 perfs in window at any moment, hourly → **~24 fetches/hour = 0.4/min**
- Outside 72h: ~30 × 8 × 7 (weekly-ish coverage) = **~240 fetches once daily**

Total wall-time per day ≈ (24 perfs × 24 hours) hourly + 240 daily = **~820 fetches/day**, vs. the naive "all shows hourly" of **~5,760/day**. 7× reduction, well under Fastly's velocity tier.

### Cron dedup pattern — reuse evo's

Pattern from `event_pulls` (`supabase/migrations/20260506000001_event_pulls.sql`):
> "The function is the sole writer of `event_pulls` so rate-limit windows are accurate..."

For broadway, the dedup check lives in the queue selector. Each cron
fires `pop_broadway_pulls(p_bucket text)` which:

1. Picks events in the target `hours_to_event` window
2. Filters out events with a `broadway_pull_log` row in the bucket's
   minimum interval (`> now() - interval '50 minutes'` for the hot
   bucket; `> now() - interval '20 hours'` for daily)
3. Returns up to N events per invocation (rate-limit budget)

This is exactly the evo `tournament_pull_queue` / `tournament_pull_process`
pattern at `supabase/migrations/20260509500000_*.sql`.

```sql
CREATE OR REPLACE FUNCTION public.pop_broadway_pulls(
  p_bucket text,
  p_limit  int DEFAULT 50
) RETURNS TABLE (
  broadway_event_id bigint,
  broadway_slug     text,
  broadway_show_id  bigint,
  performance_time  timestamptz
) LANGUAGE sql STABLE AS $$
  WITH bucket AS (
    SELECT
      CASE p_bucket
        WHEN '0-72h'  THEN 0
        WHEN '72h+'   THEN 72
      END AS min_hours,
      CASE p_bucket
        WHEN '0-72h'  THEN 72
        WHEN '72h+'   THEN 999999
      END AS max_hours,
      CASE p_bucket
        WHEN '0-72h'  THEN interval '50 minutes'   -- dedup window
        WHEN '72h+'   THEN interval '20 hours'
      END AS dedup_window
  )
  SELECT q.broadway_event_id, q.broadway_slug, q.broadway_show_id, q.performance_time
  FROM broadway_pull_queue q, bucket b
  WHERE EXTRACT(epoch FROM (q.performance_time - now())) / 3600
        BETWEEN b.min_hours AND b.max_hours
    AND q.performance_time > now()  -- skip past events
    AND NOT EXISTS (
      SELECT 1 FROM broadway_pull_log l
      WHERE l.event_id = q.broadway_event_id
        AND l.endpoint = 'sections'
        AND l.http_status = 200
        AND l.created_at > now() - b.dedup_window
    )
  ORDER BY q.performance_time
  LIMIT p_limit;
$$;
```

## Decision 3 — Missed-day tracking (P2 #9, not backfill)

Backfill is impossible — Broadway.com doesn't expose historical pricing
for closed performances. But we can detect when our own coverage drops
and alert.

### View: `v_broadway_missed_snapshots`

```sql
CREATE OR REPLACE VIEW public.v_broadway_missed_snapshots AS
WITH expected AS (
  SELECT
    q.broadway_event_id,
    q.broadway_slug,
    q.performance_time,
    CASE
      WHEN EXTRACT(epoch FROM (q.performance_time - now())) / 3600 < 72 THEN 'hourly'
      ELSE 'daily'
    END AS expected_cadence,
    CASE
      WHEN EXTRACT(epoch FROM (q.performance_time - now())) / 3600 < 72 THEN interval '90 minutes'
      ELSE interval '30 hours'
    END AS max_gap
  FROM broadway_pull_queue q
  WHERE q.performance_time > now()
)
SELECT
  e.broadway_event_id,
  e.broadway_slug,
  e.performance_time,
  e.expected_cadence,
  (SELECT max(captured_at_utc) FROM broadway_listings_snapshots s
    WHERE s.broadway_event_id = e.broadway_event_id) AS last_snapshot_at,
  now() - (SELECT max(captured_at_utc) FROM broadway_listings_snapshots s
    WHERE s.broadway_event_id = e.broadway_event_id) AS gap,
  e.max_gap AS gap_threshold
FROM expected e
WHERE (
  SELECT max(captured_at_utc) FROM broadway_listings_snapshots s
  WHERE s.broadway_event_id = e.broadway_event_id
) IS NULL
   OR now() - (
     SELECT max(captured_at_utc) FROM broadway_listings_snapshots s
     WHERE s.broadway_event_id = e.broadway_event_id
   ) > e.max_gap;
```

Rows in this view = events that have missed their cadence. Surfaces via:
- Dashboard panel (D2-owned)
- Daily `bot_chat_log` flag if `count(*) > 0`
- A1's existing aging-sweep cron picks up the flag

## Implementation order

1. **PR #261** (this PR) — testing scaffold + Fastly fix + this design doc
2. **PR #N+1** — `supabase/migrations/<ts>_broadway_listings_pipeline.sql`
   (schema only; **does not** schedule crons)
3. **PR #N+2** — edge function `broadway_collect` invoked by
   `pop_broadway_pulls(...)`, writes through the parsed `SectionsSnapshot`
   into `broadway_listings_snapshots` + computes `broadway_event_metrics`
   + `broadway_section_metrics`
4. **PR #N+3** — cron schedules (`broadway-collect-0-72h`, `broadway-collect-72h+`,
   `broadway-retention-sweep-daily`). Requires operator approval per
   2026-05-13 lockdown (`cron.*` schema mutations).
5. **PR #N+4** — `v_broadway_missed_snapshots` view + dashboard wiring (D2 sub-PR)

Migration files for steps 2-3 can be authored without approval (global
rule 1 standing-permits authoring); applying them needs operator
sign-off.