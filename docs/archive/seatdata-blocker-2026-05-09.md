# SeatData pull pipeline — blocker (2026-05-09)

## State

The SD ingestion pipeline is **missing**, not "silent." On audit:

```
seatdata_event_xref          1 row (manually populated)
seatdata_event_stats         0 rows
seatdata_listings_snapshots  0 rows
seatdata_sales_snapshots     254 rows (one event, manually populated)
seatdata_pull_log            0 rows
seatdata_pull_budget         0 rows  (never even initialized)
```

What exists in plpgsql:

- `seatdata_check_budget(endpoint)` — gate function (works)
- `seatdata_increment_budget(endpoint)` — counter (works)
- `normalize_sd_listing(...)` — section/zone normalization helper
- `sd_xref_resolve()` — orphan audit (added 2026-05-09)

What does **not** exist:

- Any `seatdata_*_queue()` function
- Any `seatdata_*_process()` function
- Any cron firing SD pulls
- Documentation of the SD vendor's API endpoint, auth shape, or
  rate-limit contract

## What happened

`SEATDATA_API_KEY` is whitelisted in `get_app_secret()` and the
schema is fully provisioned, so SD was clearly **planned**. The 254
sales rows on Knicks/76ers G5 (tevo 3345925) suggest at least one
ad-hoc pull worked once. But nothing automated runs today and the
pull function source-of-truth was never committed to plpgsql.

Two possibilities:
1. The SD pull was an Edge Function that lived on Railway and got
   deprecated when we moved the data plane to Supabase.
2. It was always a manual one-off and never automated.

Either way, **rebuilding it correctly requires the SD vendor's
current API spec** — endpoint URL, auth header shape, request/response
JSON, rate-limit contract (since it's metered/paid).

## Why this isn't fixable inline

SD is a **paid** API (the `last_paid_pull_at` and `daily_cap` /
`monthly_cap` columns in `seatdata_pull_budget` make that clear).
Writing a pull function with guessed endpoints would either 404 or
silently burn paid credits. Worth blocking on a real spec.

## What unblocks it

Provide one of:
- The Edge Function source if SD pull existed on Railway (we can
  port it to plpgsql/pg_net 1:1)
- The SD vendor's API documentation (URL + auth pattern + rate limit)
- An old commit hash where SD pull was working (we can resurrect)

Once we have any of those, the pull function is a half-day's work —
the schema is already there, the budget gate already works, and the
unified `cross_source_match_tick` is already wired to call into SD
once data lands.

## What we lose without it

SD provides historical sales comps the other sources can't. Without
SD the price-arbitrage views (`v_arbitrage_opportunities`) work on
TEvo↔SG only, and the `sd_sold_vs_tevo_listed_pct` column in
`v_pricing_cross_source` will stay NULL for all but one event.

For pricing decisions on events without recent comparable history,
we have no fallback today.
