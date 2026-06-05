# Broadway scale plan (2026-05-18)

> ⚠ **2026-05-24 REDESIGN** — Broadway.com moved inventory out of the
> bootstrap GET. The `SectionListing` / `sections[]` schema below is
> **legacy** (applies to old responses / the SIX offline fixture only).
> Live shows now return `event_polling_enabled=true` with no `sections[]`;
> real inventory comes from an async reCAPTCHA-gated availability POST
> with a `data.tickets[]` array (PascalCase, per-seat-block). Parser:
> `BroadwayClient.parse_availability()` → `AvailabilitySnapshot` /
> `TicketBlock`. Field mapping updated below (§ Transport 2026-05-24).
> The `broadway_collect` edge-function plan is non-viable; browser-driven
> collection is required (see `docs/broadway-live-testing.md`).

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

### Field mapping — TicketBlock → broadway_listings_snapshots (2026-05-24 schema)

> Replaces the SectionListing mapping above for live shows. `TicketBlock`
> fields are PascalCase from the availability POST `data.tickets[]`.

| `broadway_listings_snapshots` field | `TicketBlock` field | Notes |
|---|---|---|
| `broadway_event_id` (bigint) | `event_id` (on `AvailabilitySnapshot`) | from wrapper |
| `captured_at_utc` (timestamptz) | `captured_at_utc` | client clock |
| `price_index` (bigint) | `TicketBlock.price_id` | `PriceId` — unique per block |
| `section_name` (text) | `TicketBlock.section_name` | `SectionName` |
| `area_name` (text) | `TicketBlock.area_name` | `AreaName` |
| `row_name` (text) | `TicketBlock.row_name` | `RowName` |
| `ticket_type` (text) | `TicketBlock.ticket_type` | `TicketTypeName` (Standard/Premium) |
| `face_price` (numeric) | `TicketBlock.price` | `TicketPrice` |
| `fee` (numeric) | `TicketBlock.fee` | `ServiceFee` |
| `original_price` (numeric, nullable) | `TicketBlock.original_price` | `OriginalTicketPrice` (discount) |
| `quantity` (int) | `TicketBlock.quantity` | `Quantity` (block size) |
| `quality` (int, nullable) | `TicketBlock.quality` | `Quality` (Broadway internal score) |
| `is_ga` (bool) | `TicketBlock.is_ga` | `IsGA` |
| `can_split` (bool) | `TicketBlock.can_split` | `CanSplitBlock` |
| `price_name` (text, nullable) | `TicketBlock.price_name` | `PriceName` |
| `ticket_block_id` (text, nullable) | `TicketBlock.ticket_block_id` | `TicketBlockId` |
| `section_id` (int, nullable) | `TicketBlock.section_id` | `SectionId` |
| `area_id` (int, nullable) | `TicketBlock.area_id` | `AreaId` |
| `broadway_show_id` (bigint) | from `AvailabilitySnapshot.event_id` upstream join | |

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

## Transport (2026-05-24)

Broadway.com's 2026-05-24 redesign rendered the `requests`-based GET
collection path non-viable:

| Layer | Old | New (2026-05-24) |
|---|---|---|
| **Bootstrap response** | `data.sections[]` inline inventory | `event_polling_enabled=true`, no sections |
| **Inventory source** | Inline in bootstrap HTML | Async POST `.../sections/` |
| **Gate** | None — plain GET | Fastly JS "Client Challenge" + reCAPTCHA Enterprise + session CSRF |
| **Response schema** | `SectionListing` (camelCase) | `TicketBlock` (PascalCase, per-seat-block) |
| **Parser** | `_snapshot_from_payload` → `SectionsSnapshot` | `parse_availability` → `AvailabilitySnapshot` |
| **Collection host** | Deno edge function (planned) | Chrome extension MV3 (interim) / Playwright worker |
| **RULE 2 strategy** | GET-only requests client | OBSERVE page's own XHR — never issue POST |

The Chrome extension at `broadway_extension/` is the current interim
host. It runs in residential Chrome, lets the page solve Fastly +
reCAPTCHA, tees the availability XHR in the MAIN world, parses via
`parse_availability.js` (JS port of the Python parser, fixture-verified),
and ships to a configurable ingest endpoint.

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

## Proposed fixes for remaining issues (P0/P1/P2)

The original scaling review surfaced 11 issues. P1 #4, P2 #7, P2 #9
are resolved above. Below are concrete proposals for the rest.

### P0 #2 — No `list_all_shows()` (slug discovery)

**Problem**: `broadway_client.py` requires callers to pass `slug`. No
mechanism to enumerate "all current Broadway shows."

**Proposal**: Add `discover_shows()` method that parses
`https://www.broadway.com/shows/` for show-card anchors matching
`/shows/<slug>/`. One HTTP call per discovery sweep (daily). Returns
`list[BroadwayShowStub]` — minimal `(slug, title, url)` triples. Cron
calls it once daily; results upsert into `broadway_shows`. Backstop:
`broadway_shows.is_pinned` boolean — operator can pin shows the
harvester misses (out-of-NYC tryouts, special previews).

```python
@dataclass
class BroadwayShowStub:
    slug: str
    title: str | None
    show_page_url: str

def discover_shows(self) -> list[BroadwayShowStub]:
    """Harvest all show slugs from /shows/. One HTTP call. Same
    drift-detection guards as discover_performances: empty result on
    200 with no Broadway.com markers → BroadwayParseError."""
```

**Cost**: ~80 lines new code + parser fixture + tests. Same Fastly
exposure as existing methods. In-lane D3.

### P0 #3 — Edge function execution limit

**Status**: Already resolved by the bucket design above. With
`pop_broadway_pulls(limit=50)` and 1.5s pacing per fetch, one cron
invocation runs ~75s — within Supabase edge function's 150s Team-tier
limit. Larger batches handled by the queue + repeated cron firings.

**To make this concrete**: document the per-invocation budget in the
edge function PR (#N+2). Reject batches whose projected wall-time
exceeds 120s (safety margin); requeue the overflow.

### P1 #5 — `discover_performances` failure drops whole show silently

**Problem**: `snapshot_show` (`broadway_client.py:634-645`) calls
`discover_performances` unwrapped. A 403 or `BroadwayParseError` there
kills the entire show's snapshot without a structured signal — the
caller just sees an exception (or worse, stops mid-show in a longer
sweep loop).

**Proposal**: Refactor `snapshot_show` to return a structured result
that distinguishes "discover failed" from "discover OK, N fetches
failed":

```python
@dataclass
class SnapshotShowResult:
    slug: str
    discover_error: BroadwayError | None = None
    snapshots: list[SectionsSnapshot] = field(default_factory=list)
    fetch_errors: list[dict] = field(default_factory=list)
    # each: {slug, show_id, event_id, error_class, error_message}

    @property
    def ok(self) -> bool:
        return self.discover_error is None

    @property
    def attempted(self) -> int:
        return len(self.snapshots) + len(self.fetch_errors)

def snapshot_show(self, slug: str) -> SnapshotShowResult:
    out = SnapshotShowResult(slug=slug)
    try:
        perfs = self.discover_performances(slug)
    except BroadwayError as e:
        out.discover_error = e
        return out
    for p in perfs:
        try:
            out.snapshots.append(self.fetch_sections(p.slug, p.show_id, p.event_id))
        except BroadwayError as e:
            out.fetch_errors.append({
                "slug": p.slug, "show_id": p.show_id, "event_id": p.event_id,
                "error_class": type(e).__name__, "error_message": str(e),
            })
    return out
```

**Cost**: in-lane D3 refactor. Breaking change to return type (was
`list[SectionsSnapshot]`, becomes `SnapshotShowResult`). Caller
update: `cli.snapshot_show(slug).snapshots` to get the previous list.
Only CLI `snapshot` command uses this today (`broadway_client.py:664-666`);
trivial to update. Tests need 1-2 new cases. ~40 lines net.

### P1 #6 — No run-level aggregation / alerting

**Status**: Downstream of #5. Once `snapshot_show` returns a structured
result, the edge function can aggregate:

```python
# in broadway_collect edge function (future PR)
run = BroadwayRunSummary(started_at=now_utc())
for slug in slugs:
    result = cli.snapshot_show(slug)
    run.add(result)

if run.failure_rate > 0.25:
    supabase.rpc('bot_chat_log', {
        'p_bot_lane': 'D3',
        'p_event_type': 'flag',
        'p_summary': f'Broadway collect run failure rate {run.failure_rate:.0%}',
        'p_payload': run.to_json(),
    })

supabase.table('broadway_run_log').insert(run.to_row()).execute()
```

**Proposal**: add `broadway_run_log` table (per-cron-invocation
summary) to the migration. Use `bot_chat_log` for >25% failure-rate
flags, matching A1's aging-sweep convention.

```sql
CREATE TABLE IF NOT EXISTS public.broadway_run_log (
  id              bigserial PRIMARY KEY,
  bucket          text NOT NULL,                  -- '0-72h' | '72h+'
  started_at      timestamptz NOT NULL,
  finished_at     timestamptz,
  events_attempted int  NOT NULL DEFAULT 0,
  events_ok       int  NOT NULL DEFAULT 0,
  events_failed   int  NOT NULL DEFAULT 0,
  shows_attempted int  NOT NULL DEFAULT 0,
  shows_failed    int  NOT NULL DEFAULT 0,
  flag_raised     boolean NOT NULL DEFAULT false,
  error_samples   jsonb NOT NULL DEFAULT '[]'::jsonb
);
CREATE INDEX idx_bwy_run_log_time ON public.broadway_run_log (started_at DESC);
```

**Cost**: small migration addition. In-lane D3 for the table; the
flag-emission code lives in the future edge function PR.

### P2 #8 — No idempotency on retry

**Problem**: Primary key on `broadway_listings_snapshots` is
`(broadway_event_id, captured_at_utc, price_index)`. Network retry or
duplicate cron firing within the same second → unique violation.

**Proposal**: Two-part fix.

(a) **Client-side**: when `BroadwayClient.db` is set and we write
through, use `ON CONFLICT DO NOTHING`:

```python
# in the (future) write-through method
self.db.table("broadway_listings_snapshots").upsert(
    rows, on_conflict="broadway_event_id,captured_at_utc,price_index",
    ignore_duplicates=True,
).execute()
```

(b) **Quantize captured_at_utc** at the bucket level so two firings
within the same dedup window can't both write. Hot bucket → round to
nearest minute; cold bucket → round to nearest hour. This makes the
PK collision a feature, not a bug: a duplicate fire is rejected
silently.

```python
def _quantize(captured_at: datetime, bucket: str) -> datetime:
    if bucket == "0-72h":
        return captured_at.replace(second=0, microsecond=0)
    return captured_at.replace(minute=0, second=0, microsecond=0)
```

**Cost**: client-side write-through doesn't exist yet (lives in the
edge function PR). Adding the quantize helper is ~15 lines + 1 test.
Migration unchanged (PK already enforces uniqueness).

### P2 #10 — robots.txt unchecked

**Problem**: At one-show-a-day this is noise; at 30-shows × hourly
this becomes a ToS exposure. Broadway.com publishes a `/robots.txt`;
we ignore it.

**Proposal**: Honor robots in `BroadwayClient`:

```python
from urllib.robotparser import RobotFileParser

class BroadwayClient:
    def __init__(self, ..., respect_robots: bool = True):
        ...
        self.respect_robots = respect_robots
        self._robots: RobotFileParser | None = None

    def _check_robots(self, url: str) -> None:
        if not self.respect_robots:
            return
        if self._robots is None:
            self._robots = RobotFileParser()
            self._robots.set_url(f"{WWW_BASE}/robots.txt")
            try:
                self._robots.read()
            except Exception:
                # Fail open — if we can't fetch robots, don't block work.
                self._robots = None
                return
        if self._robots and not self._robots.can_fetch(
            self.session.headers.get("User-Agent", "*"), url
        ):
            raise BroadwayError(
                f"robots.txt disallows fetching {url} for our UA. "
                "Set respect_robots=False to override (RULE 2 still applies)."
            )

    def _get(self, url: str, ...):
        self._check_robots(url)
        # ... existing logic
```

**Cost**: ~30 lines + 2 tests (mock robots that allows + mock that
denies). In-lane D3. Default-on; override via `respect_robots=False`
for testing.

Note: this is policy compliance, not a security boundary. Our
existing RULE 2 (`_assert_readonly_method`) is the security boundary
and is unchanged.

### P2 #11 — Slug churn (new + closed shows)

**Problem**: New shows open ~monthly during seasonal opens; closed
shows return 404 or redirect. Neither is auto-detected.

**Proposal**: Two-pronged.

(a) **New shows**: addressed by `discover_shows()` in #2. Daily
discovery sweep upserts into `broadway_shows` with
`first_seen_at = now()` for new slugs.

(b) **Closed shows**: track consecutive failures per slug. After 3
consecutive failed `discover_performances` calls (404 or
ParseError + no Broadway markers), mark `broadway_shows.closed_at =
now()` and remove from `broadway_pull_queue`. Operator can manually
reopen via setting `closed_at = NULL` if it was a false positive.

```sql
ALTER TABLE public.broadway_shows
  ADD COLUMN IF NOT EXISTS closed_at timestamptz,
  ADD COLUMN IF NOT EXISTS consecutive_discover_failures int NOT NULL DEFAULT 0;
```

```python
# in the future edge function
result = cli.snapshot_show(slug)
if result.discover_error and isinstance(result.discover_error, BroadwayParseError):
    db.rpc('broadway_increment_failure', {'p_slug': slug})
elif result.ok:
    db.rpc('broadway_reset_failure', {'p_slug': slug})
```

**Cost**: column additions + 2 helper RPCs. Edge function uses them.
In-lane D3.

## Implementation order — updated

| PR | Scope | Lane | Gating |
|---|---|---|---|
| #261 (this) | Tests + Fastly fix + scale plan + base schema | D3 | none |
| #N+1 | `discover_shows()` + `snapshot_show` refactor (#2, #5) | D3 | ✅ landed in PR #261 (commit c36561b) |
| #N+2 | robots.txt honoring (#10) + idempotency helpers (#8) | D3 | ✅ landed in PR #261 (commit e9c6122) |
| #N+3 | `broadway_run_log` + close-tracking columns (#6, #11) | D3 | ✅ migration drafted in PR #261; apply gated |
| #N+4 | Edge function `broadway_collect` — wires through to all the above | D3 | follow-up PR |
| #N+5 | Cron schedules | D3 → A1 | operator approval (cron.*) |
| #N+6 | Dashboard wiring for missed-snapshots + run-log views | D2 sub-PR | follow-up |