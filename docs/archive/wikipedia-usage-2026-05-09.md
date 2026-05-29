# Wikipedia data — what we keep, why, and how AI connectors should use it (2026-05-09)

## TL;DR

We keep Wikipedia summary text + image_url + canonical title per TEvo
performer. We do NOT do SQL analytics on it (no spike multipliers, no
trend views, no JOINs against pageviews). The consumer is **AI/RAG
connectors** that want plain-English context about a performer at
prompt time.

If you're writing a SQL query and reaching for `performer_wiki_*`,
stop — there's almost certainly a more direct signal in price/order
deltas, ESPN, or SeatGeek volume.

## What we pull (active)

`performer_wikipedia` table — one row per TEvo performer, populated by
the 3-stage cron pipeline in mig 20260509170000:

| Column | What |
|---|---|
| `wiki_pageid` | Wikipedia internal page id |
| `wiki_title` | Canonical article title |
| `wiki_url` | Full URL to the article |
| `description` | Short blurb (e.g. "American basketball team") |
| `extract` | First paragraph of the article |
| `image_url` | Thumbnail image URL |
| `match_method` | `search_top_summary` (good) / `rejected` (no good article) |

Cron cadence (still running):
- `performer_wiki_queue_searches_5min`     (every 5 min)
- `performer_wiki_process_searches_5min`   (every 5 min, +1m offset)
- `performer_wiki_process_summaries_5min`  (every 5 min, +2m offset)

These keep `extract` and `image_url` fresh as new TEvo performers land.

## What we DON'T do anymore (reverted in mig 20260509340000)

| Was | Reason for revert |
|---|---|
| `performer_wiki_pageviews` table | Unused — no day-trader query reaches for it |
| `wiki_pageviews_queue/process` functions | Same |
| `v_performer_pageview_trend` view (spike_multiplier) | Same — buzz lives in price/order deltas, not Wikipedia readership |
| `wiki_pageviews_queue_daily` + `_process_daily` crons | No consumer = no point spending the API budget |

The pageviews experiment was a YAGNI: building "rising buzz" detection
into SQL when the actual signal we trade on is `event_metrics` deltas
(listing prices moving, our orders accelerating). Wikipedia readership
is a noisy proxy for that, downstream of news cycles, not leading them.

## What it IS used for (active)

**1. Cross-source enrichment in `v_canonical_performer`** — already wired.
The performer canonical view exposes `wiki_extract` + `image_url`
alongside ESPN/SD/SG identifiers. Used for:
- Description on any performer-detail surface (when UI rebuilds)
- Image URL fallback for non-sports performers (ESPN doesn't cover them)

**2. AI-connector / RAG context** — intended primary consumer.
When a future AI assistant gets asked "should I price the Knicks game
higher" or "what's going on with Bad Bunny," the prompt-time
enrichment can pull `extract` so the model has plain-English context
without us having to teach it every team and artist explicitly. The
extract is a self-contained paragraph — no JOIN, no analytics, just
text → prompt.

Likely call shape from a future AI connector:

```sql
SELECT performer_name, extract, wiki_url, image_url
FROM performer_wikipedia
WHERE tevo_performer_id = $1 AND extract IS NOT NULL;
```

That's it. No aggregates, no windowing, no trend math.

## What we still don't do (deferred)

| Use case | Why |
|---|---|
| Wikipedia infobox extraction (genre, founded year, primary venue, roster) | Requires Wikidata API or HTML parsing; only a couple of UI surfaces would use it |
| Edit frequency as buzz signal | Same noise problem as pageviews — too downstream |
| Wikipedia categories / sister-projects | Useful for similarity but adds API calls; unclear consumer |
| Multi-language pageview rollup | Most of our market is en.wikipedia |
| Tour-mate detection ("touring with X") | Could parse from extract but error-prone |
| Player-level injury cross-check | ESPN handles this directly; Wiki adds noise |

## RULE 2 compliance

All Wikipedia + Wikimedia traffic is GET-only via pg_net. The endpoints
don't accept POST anyway (public read APIs). The audit script
(`scripts/check_readonly.py`) scans plpgsql migrations too, catching
any future drift toward write methods.

## Storage retention

`performer_wikipedia` is keyed on `tevo_performer_id` (PK). One row per
performer, refreshed in place when the search/summary cron re-runs.
~200–500 rows total — trivial.

The dropped `performer_wiki_pageviews` would have been ~73K rows/year
at full coverage, also trivial. The reason for dropping isn't storage
cost — it's that no SQL surface ever queried it, and signals we already
trade on are stronger.
