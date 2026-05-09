# Wikipedia data — what we pull, what we use it for (2026-05-09)

## What we pull (already wired)

`performer_wikipedia` table — one row per TEvo performer, populated by the
3-stage cron pipeline in mig 20260509170000:

| Column | What |
|---|---|
| `wiki_pageid` | Wikipedia internal page id |
| `wiki_title` | Canonical article title |
| `wiki_url` | Full URL to the article |
| `description` | Short blurb (e.g. "American basketball team") |
| `extract` | First paragraph of the article |
| `image_url` | Thumbnail image URL |
| `match_method` | `search_top_summary` (good) / `rejected` (no good article) |

Cron cadence:
- `performer_wiki_queue_searches_5min` (every 5 min)
- `performer_wiki_process_searches_5min` (every 5 min, +1m offset)
- `performer_wiki_process_summaries_5min` (every 5 min, +2m offset)

## What we DO with it (active, as of mig 20260509330000)

**1. Pageviews trend extraction — buzz signal beyond storage.**

New pipeline pulls daily Wikipedia pageviews for every enriched performer:
- `performer_wiki_pageviews` table — (tevo_performer_id, date, views)
- `wiki_pageviews_queue_daily` cron at 06:30 UTC
- `wiki_pageviews_process_daily` cron at 06:35 UTC
- `v_performer_pageview_trend` view exposes spike multipliers

The pageviews API is free, no auth, UA-required (same pattern as the
existing summary fetch). Pulls a 30-day rolling window per performer per
day. Wikipedia's `wikimedia.org/api/rest_v1/metrics/pageviews/per-article/`
endpoint returns daily counts.

**Day-trader query:**

```sql
-- Performers with sudden buzz (recent 7d avg > 1.5× baseline 14-30d avg)
SELECT performer_name, recent_daily_views, baseline_daily_views,
       spike_multiplier, wiki_url
FROM v_performer_pageview_trend
WHERE spike_multiplier > 1.5
ORDER BY spike_multiplier DESC LIMIT 20;
```

**2. Cross-source enrichment in `v_canonical_performer`** — already wired.
The performer canonical view exposes wiki_extract + image_url alongside
ESPN/SD/SG identifiers. Used for:
- Description on any performer-detail surface (when UI rebuilds)
- Image URL fallback for non-sports performers (ESPN doesn't cover them)
- Sentiment-search corpus seed (concert performers without ESPN coverage)

## What we DON'T do (deferred — phase 2+)

| Use case | Why deferred |
|---|---|
| **Wikipedia infobox extraction** (genre, founded year, primary venue, roster) | Requires Wikidata API or HTML parsing; richer than summary endpoint |
| **Edit frequency as buzz signal** | Pageviews give a stronger signal at lower complexity |
| **Wikipedia categories / sister-projects** | Categories useful for cross-performer similarity but adds API calls |
| **Multi-language pageview rollup** | Most of our market is en.wikipedia; en-only is fine for v1 |
| **Tour-mate detection** ("touring with X") | Could parse from extract but error-prone |
| **Player-level injury cross-check** | ESPN handles this directly; Wiki adds noise |

## RULE 2 compliance

All Wikipedia + Wikimedia traffic is GET-only via pg_net. The endpoints don't
accept POST anyway (they're public read APIs). The audit script
(`scripts/check_readonly.py`) now scans plpgsql migrations too, catching any
future drift toward write methods.

## How spike_multiplier should be read

| Multiplier | Interpretation |
|---|---|
| < 0.7 | Performer is cooling off — interest dropped 30%+ |
| 0.7–1.3 | Stable — typical fluctuation |
| 1.3–2.0 | Moderate buzz spike — news cycle, signing, etc. |
| 2.0–5.0 | Strong buzz — likely a real event (trade/scandal/album drop) |
| > 5.0 | Likely viral — verify the cause manually |

For ticket-pricing, a spike >2.0 within 7 days of a performer's home game
is a meaningful demand signal independent of price action — use it as a
sanity check on `event_metrics` deltas.

## Storage retention

`performer_wiki_pageviews` is keyed on `(tevo_performer_id, date)` with no
retention policy. ~200 performers × 365 days = ~73K rows/year — trivial.
No sweep needed.
