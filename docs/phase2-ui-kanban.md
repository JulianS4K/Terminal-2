# Phase 2 UI rebuild — backlog (2026-05-09)

Phase 1 = data collection; UI on full reboot. This file collects items
deferred from Phase 1 that should land alongside or after the UI rebuild.

Each card is **stand-alone** — the spawned task / future Claude session
shouldn't need this conversation's context to act on it.

---

## CARD: Data quality dashboard

**Why:** silent failures (like the SD pull pipeline being completely
missing, or SG `payment_total` being NULL on every order) are the
class of bug that costs us money. We notice them on audit, never live.

**Build:** Daily cron `data_quality_tick` writes a `data_quality_runs`
row with these checks:
- % of upcoming events with listings <30min old
- % of upcoming sports events with ESPN xref
- % of upcoming events with weather observation (within 16d window)
- % of SG orders with non-NULL `payment_total`
- % of TEvo orders with at least one `evo_order_items` row
- Matcher orphan-rate trend (rows in v_unmatched_events vs yesterday)
- Cron run-counts per family (was each family invoked > X times in 24h?)

**Surface:** new view `v_data_quality_today` reading the latest run.
UI lands a single banner "data plane health: 94%" with drill-down.

**Effort:** 1 day to build cron + view + 6 checks. Add more checks
incrementally.

**Dependencies:** none (purely additive).

---

## CARD: Cost meter (pg_net + cron + API call counts)

**Why:** as the data plane scales, we want to know which cron is eating
egress / API-call budget. Cheap to add now, hard to retrofit later.

**Build:** scheduled task `cost_meter_tick` (daily) aggregates:
- `pg_net._http_response` row counts grouped by URL host (TEvo / SG /
  Wikipedia / Open-Meteo / Nominatim / SD)
- Total response bytes per host per day
- pg_cron.job_run_details job durations per cron
- Persist into `data_plane_cost_daily` table for trending

**Surface:** view `v_data_plane_cost_30d` — rolling 30d cost per source.

**Effort:** half-day. Mostly aggregation queries; the data is already
in pg_net + pg_cron internal tables.

**Dependencies:** none.

---

## CARD: Wikipedia rivalries — re-add for AI context only

**Why:** rivalries (Yankees vs Red Sox, Knicks vs Celtics, Cubs vs
Cardinals, etc.) shape demand for sports tickets. Currently dropped
(mig 20260509370000) but the user said "add later for context."

**Build:** new `performer_rivalries` table:
```
home_performer_id  bigint
away_performer_id  bigint
rivalry_name       text       -- e.g. "Subway Series"
strength           numeric    -- 0..1, optional
notes              text
source             text       -- 'manual' | 'wikipedia'
```
Surface as enrichment field in `get_event_context()` — when a TEvo
event's two performers have a rivalries-table row, include
`rivalry: { name, strength }` in the AI context bundle.

**Effort:** 2 hours for schema + manual seed (~30 well-known rivalries);
optional Wikipedia auto-discovery cron later.

**Dependencies:** Phase 2 UI for an admin "manage rivalries" surface.

---

## CARD: Alert delivery (Slack / email / push)

**Why:** `event_alerts` is now firing rules but there's no consumer.
A trader needs to *receive* alerts, not query for them.

**Build:** `alert_subscriptions` table — rules user wants delivered,
how (slack channel / email / push), and any per-rule overrides
(severity threshold, mute window).

`alert_delivery_tick` cron polls `event_alerts` for unsent + matching
subscriptions, fires webhooks, marks `delivered_at`.

**Effort:** 1 day. Slack first (single webhook URL); email/push later.

**Dependencies:** UI for subscription management; secret for Slack
webhook URL.

---

## CARD: SD pull pipeline (BLOCKED)

**Why:** historical sales comps are real money signal. See
`docs/seatdata-blocker-2026-05-09.md` for why this is blocked.

**Build:** when API spec arrives, write `seatdata_event_pull_queue` +
`seatdata_event_pull_process` following the EVO/SG pattern in mig
20260509280000 / 290000. Wire to `cross_source_match_tick`.

**Effort:** half-day once spec is provided.

**Dependencies:** SD vendor API spec OR resurrected Edge Function source.

---

## CARD: SeatGeek `payment_total` ~~data-quality fix~~ — RESOLVED differently

**Resolution (mig 20260509440000):** SG API simply does not return
payment_total for our token tier — verified across all 400 orders.
But sale_price + sale_quantity + sale_section + sale_row ARE
populated 100%. Migration 440000 derives gross_amount as
`sale_price * sale_quantity` and exposes per-section views
(v_sg_sales_by_section, v_sg_sales_by_event). SG side now shows real
numbers: ~$113K gross / $101K net across 186 events. Card closed.

---

## CARD: Inventory churn view (groups appearing/disappearing per capture)

**Why:** velocity views capture price + count Δ but not WHICH
ticket_groups are new vs disappearing. A group disappearing is either
sold or pulled — different signals. Knowing "8 new groups listed in
last hour" is different from "8 groups disappeared."

**Build:** view `v_event_inventory_churn` joining latest captures,
exposing `groups_added`, `groups_removed`, `groups_repriced`,
`net_change`. Likely needs a stable group identifier (tevo_ticket_group_id)
across captures.

**Effort:** half-day. The data is in `listings_snapshots`; just
diff-on-key arithmetic.

**Dependencies:** none.

---

## CARD: Time-decay curves per venue × performer

**Why:** "what's the typical price 7 days out for this team at this
venue" is the universal pricing baseline question. Currently no view
answers it.

**Build:** view `v_price_decay_baseline` — for each venue × performer
combo with ≥3 historical events, compute median price by `days_to_event`
buckets (0d, 1d, 3d, 7d, 14d, 30d+). Compare current event's track
to baseline.

**Effort:** 1 day. Real value once we have ≥6 months of history.

**Dependencies:** sufficient history accumulation (~3 months minimum).

---

## CARD: Seatgeek_event_metrics retention/sweep

**Why:** SG metrics table will grow unbounded. Need policy.

**Build:** sweep cron deleting `seatgeek_event_metrics` rows older
than X days for events past their date.

**Effort:** 1 hour.

**Dependencies:** none, but only urgent once table is >1M rows
(currently 494).

---

## CARD: Google News RSS pipeline

**Why:** mainstream-news complement to Reddit (which gives fan
reactions). Google News RSS is free, no auth, returns headlines
within minutes of publication. Search by performer/team name to
catch breaking news from outlets like The Athletic, USA Today, ESPN
that don't always show up on team subreddits.

**Build:** mirror the Reddit RSS pattern. URL shape:
`https://news.google.com/rss/search?q=<encoded query>&hl=en-US&gl=US&ceid=US:en`.
Returns RSS XML with <item><title><link><pubDate><description>.

  - `news_pending` queue table (one row per query)
  - `news_queue()` — iterates performer_metadata.name + handles in
    important_x_accounts.name (skip handles already covered by
    Reddit subs); fires GET via pg_net
  - `news_process()` — regex-extract <item> blocks (same Atom-style
    parser shape as the Reddit one in mig 410000)
  - `news_articles` storage table (article_id PK derived from <link>)
  - 30-min cron `news_queue_30min` + `news_process_30min`
  - `v_performer_news_recent` view + extend `get_event_context`
    with `news_articles` array

**Effort:** half-day. Same pattern as Reddit RSS, regex parsing
approach already proven.

**Dependencies:** none.

---

## CARD: Google Trends signal (pytrends)

**Why:** broad public-interest signal that Reddit can't deliver:
covers every searchable entity equally (concert artists + Broadway,
not just sports teams), gives comparable 0–100 scores across
performers, supports geographic filtering. Lagging vs Reddit (1–6h
to register) but captures the broader ticket-buying public, not
just fan-community.

**Build:** can't pull from plpgsql/pg_net cleanly because pytrends
scrapes the unofficial Trends interface and needs a Python runtime.
Two options:

1. **Edge Function** in Deno using a Trends scraper port (cleaner
   for our Supabase-only architecture). Fire on a daily cron via
   pg_cron → net.http_post to the function URL.
2. **Supabase Scheduled Function** (Python, if/when supported in
   Edge runtime — currently Deno-only).

Schema:
  - `performer_trends_daily` (tevo_performer_id, date, region,
    interest_score, related_topics jsonb, pulled_at)
  - `v_performer_trends_recent` rolling 30-day curve per performer

**Effort:** 1 day to wire Edge Function + persistence + view + cron.

**Dependencies:** Edge Function deployment infra (already used for
espn-collect and collect-listings — no new dep).

**Caveats:** rate limits + occasional captcha block. Pull <50
performers/day to stay safe; cycle through the full list over
multiple days.

---

## CARD: Wikipedia pageviews — comeback (AI-context only)

**Why:** dropped from SQL analytics in mig 20260509340000 because
the trend math was YAGNI for SQL. But as a **prompt-time AI signal**
for "did interest in this performer spike yesterday" it's genuinely
useful at zero cost. Different intent layer than Reddit (post
volume) or Google Trends (search interest) — pageviews capture
"reading-up-on" behavior.

**Build:** restore the schema (`performer_wiki_pageviews` table +
queue/process functions + cron) but DO NOT add the trend view this
time. Just the raw daily counts, queryable per performer + date.
Surface in `get_event_context` as `wikipedia_pageviews_7d`,
`wikipedia_pageviews_30d` so the AI prompt can include "Knicks
Wikipedia pageviews 7d/30d ratio = 1.4x" without anyone needing to
run analytics views.

**Effort:** 2 hours (schema is essentially what mig 330000 created
before we reverted; cleaner version without the v_performer_pageview_trend
analytics view).

**Dependencies:** none.

---

## Priority order if we did one card per week

1. ~~SeatGeek `payment_total` fix~~ — RESOLVED via mig 440000 (use
   sale_price × sale_quantity since payment_total isn't returned).
2. **Google News RSS pipeline** — half-day, mainstream-news layer.
3. **Alert delivery** (Slack/email/push) — turns alerts into product.
4. **Google Trends signal** — broad public-interest layer that
   Reddit can't capture; needs Edge Function + 1d work.
5. **Data quality dashboard** — protects against silent failures.
6. **Inventory churn view** — high-value pricing signal.
7. **Wikipedia pageviews comeback** — 2h, AI-context-only.
8. **Time-decay baselines** — needs ~3 months history first.
9. **Cost meter** — nice to have, no immediate pain.
10. **Rivalries** — easy when prioritized; not urgent.
11. **SD pull** — blocked on external input.
12. **SG metrics retention** — pre-emptive only.
