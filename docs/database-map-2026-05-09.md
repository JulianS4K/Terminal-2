# Terminal-2 — Database Map (2026-05-09)

Comprehensive structural reference for the Supabase data plane. This file
is the answer to "what tables exist, what feeds what, what reads what."
Update when you add/remove a table, view, function, or cron.

The map is organized by **layer**, top-down:

```
  +-----------------------------------------------------------------+
  |  CONSUMER INTERFACE  (single-call functions, AI/RAG bundles)    |
  +-----------------------------------------------------------------+
                              ^
  +-----------------------------------------------------------------+
  |  INTELLIGENCE  (alerts, velocity windows, arbitrage, competitors)|
  +-----------------------------------------------------------------+
                              ^
  +-----------------------------------------------------------------+
  |  CANONICAL VIEWS  (cross-source unified surfaces)               |
  +-----------------------------------------------------------------+
                              ^
  +-----------------------------------------------------------------+
  |  PER-SOURCE METRICS  (rolled-up event/section/zone aggregates)  |
  +-----------------------------------------------------------------+
                              ^
  +-----------------------------------------------------------------+
  |  RAW SNAPSHOTS  (listings, sales, orders, ESPN, weather)        |
  +-----------------------------------------------------------------+
                              ^
  +-----------------------------------------------------------------+
  |  PULL PIPELINE  (queue tables -> pg_net -> process functions)   |
  +-----------------------------------------------------------------+
                              ^
  +-----------------------------------------------------------------+
  |  DATA SOURCES  (TEvo, SG, SD, ESPN, Wiki, Open-Meteo, Nominatim)|
  +-----------------------------------------------------------------+
```

## Layer 1 — Data sources

| Source | Auth | Endpoint(s) used | RULE 2 |
|---|---|---|---|
| **TEvo** (api.ticketevolution.com) | HMAC-SHA256 (X-Token + X-Signature) via `tevo_sign_get()` | `/v9/events`, `/v9/events/:id`, `/v9/orders` | GET only |
| **SeatGeek brokerdata** (brokerdata.seatgeek.com) | token query param | `/v2/listings`, `/v2/events` | GET only |
| **SeatGeek sellerdirect** (sellerdirect-api.seatgeek.com) | token query param | `/orders`, `/listings` | GET only |
| **SeatData** (vendor TBD) | API key | **MISSING** — no plpgsql pull function exists. See `seatdata-blocker-2026-05-09.md` | — |
| **ESPN** (site.api.espn.com) | none (public) | scoreboard, teams, news, athletes | Edge Function `espn-collect` |
| **Wikipedia** (en.wikipedia.org + wikimedia.org REST) | UA header only | `/api/rest_v1/page/summary/:title`, `/w/api.php?action=opensearch` | GET only |
| **Open-Meteo** (api.open-meteo.com + archive-api) | none | `/v1/forecast`, archive `/v1/era5` | GET only |
| **Nominatim** (nominatim.openstreetmap.org) | UA header only | `/search?q=...` | GET only |

Vault secrets whitelisted in `get_app_secret()`:
`SEATDATA_API_KEY`, `TEVO_API_TOKEN`, `TEVO_SECRET`, `SEATGEEK_API_TOKEN`.

## Layer 2 — Pull pipeline

The async pattern everywhere: `*_queue()` fires `net.http_get(...)` and
inserts a `*_pending` row; `*_process()` reads back from `net._http_response`
and persists into a snapshot/canonical table; pending row marked resolved.

| Family | Queue fn | Process fn | Pending table | Cron(s) |
|---|---|---|---|---|
| TEvo listings (windowed) | (Edge Function `collect-listings`) | (Edge Function) | — | `collect-listings-0-24h..60d+` (5 crons) |
| TEvo orders | `evo_orders_queue` | `evo_orders_process` | `evo_orders_pending` | `evo_orders_queue_30min` + `_process_30min` |
| TEvo orphan-event backfill | `evo_event_backfill_queue` | `evo_event_backfill_process` | `evo_event_backfill_pending` | `orphan_event_backfill_queue_15min` + `_process_15min` |
| SG broker listings (windowed) | `sg_listings_queue_window` | `sg_listings_process` | `sg_listings_pending` | `sg_listings_0-24h..60d+` (5 crons) + `sg_listings_process_5min` |
| SG sellerdirect | `sg_seller_orders_queue`, `sg_seller_listings_queue` | `sg_seller_process` | `sg_seller_pending` | `sg_seller_orders_queue_30min`, `sg_seller_listings_queue_30min`, `sg_seller_process_30min` |
| SG orphan-event backfill | `sg_event_backfill_queue` | `sg_event_backfill_process` | `sg_event_backfill_pending` | (shared with EVO orphan crons) |
| Wikipedia enrichment | `queue_performer_wiki_searches` -> `process_performer_wiki_searches` -> `process_performer_wiki_summaries` | (3-stage) | `performer_wiki_pending` | 3 crons at 5-min cadence + `wiki_pending_sweep_daily` |
| Weather forecast | `weather_forecast_queue` | `weather_forecast_process` | `weather_forecast_pending` | `weather_forecast_queue_30min` + `_process_30min` |
| Weather climatology | `weather_historical_backfill_outdoor` | `weather_historical_process` | (uses pull_log) | `weather_climatology_weekly` |
| Venue geocoding | `venue_geocode_queue` | `venue_geocode_process` | `venue_geocode_pending` | `venue_geocode_queue_5min` + `_process_5min` |
| ESPN | (Edge Function `espn-collect`) | — | — | `crawl-espn-team-assets-3min`, `espn-team-daily`, `master-cascade-2min` |
| **SeatData** | **MISSING** | **MISSING** | — | — |

## Layer 3 — Raw snapshots (immutable history)

| Table | Rows | Size | Purpose |
|---|---:|---:|---|
| `listings_snapshots` | 8.67M | 2,157 MB | TEvo listings, every capture, every ticket_group |
| `section_metrics` | 2.07M | 418 MB | TEvo section-level rollups per capture |
| `zone_metrics` | 21.6K | 6.5 MB | TEvo zone-level rollups per capture |
| `event_metrics` | 29.2K | 9.6 MB | TEvo event-level rollup per capture |
| `seatgeek_listings_snapshots` | 11.8K | 9.3 MB | SG /v2/listings, every capture |
| `seatgeek_event_metrics` | 515 | 248 kB | SG event-level cost percentiles + orders by status |
| `seatgeek_sales_snapshots` | 1.8K | 1.0 MB | SG /v2/sales (legacy/orphan; we don't have access) |
| `seatgeek_orders` | 400 | 1.1 MB | OUR SG sellerdirect orders |
| `seatgeek_seller_listings` | 200 | 576 kB | OUR SG sellerdirect listings |
| `seatgeek_historic_sales` | 400 | 496 kB | SG historic sales for similar events |
| `seatdata_sales_snapshots` | 254 | 144 kB | SD historic sales (1 event only — pipeline broken) |
| `seatdata_listings_snapshots` | 0 | 32 kB | SD listings (empty — pipeline broken) |
| `seatdata_event_stats` | 0 | 32 kB | SD event-level stats (empty) |
| `evo_orders` | 41 | 400 kB | OUR TEvo orders |
| `evo_order_items` | 40 | 184 kB | Line items per order |
| `espn_event_snapshots` | 663 | 392 kB | ESPN game state + score + odds per capture |
| `espn_team_snapshots` | 365 | 264 kB | ESPN team record + form per capture |
| `espn_injuries_snapshots` | 4.2K | 4.6 MB | Per-player injury state per capture |
| `espn_news` | 594 | 512 kB | ESPN news articles |
| `espn_athletes` | 857 | 472 kB | Player roster (AI-context only) |
| `weather_observations` | 145K | 46 MB | Open-Meteo forecast + ERA5 historical |
| `event_alerts` | 445 | 328 kB | Append-only alert log |
| `snapshots` | 223 | 88 kB | (legacy event-level snapshots; mostly used by `event_velocity`) |

## Layer 4 — Cross-source xref (id mapping)

These are the connection tables that make multi-source views possible.

| Xref | Rows | What | Status |
|---|---:|---|---|
| `event_xref` | 432 | TEvo <-> ESPN event ids | **100% clean** — 430/432 with both sides |
| `sg_events_canonical` | 211 | SG event metadata + tevo_event_id when matched | matcher correct, only 3 xref'd (SG carries different catalog) |
| `seatgeek_event_xref` | 3 | (Older xref table — sparse) | superseded by sg_events_canonical |
| `seatdata_event_xref` | 1 | SD <-> TEvo + SD's own id schemes | only 1 row (pipeline broken) |
| `seatgeek_performer_xref` | 91 | SG performer ids -> TEvo performer | active |
| `seatgeek_venue_xref` | 22 | SG venue ids -> TEvo venue | active |
| `seatdata_performer_xref` | 0 | SD performers -> TEvo | empty |
| `seatdata_venue_xref` | 0 | SD venues -> TEvo | empty |
| `seatdata_section_xref` | 0 | SD sections -> TEvo (mapping for `normalize_sd_listing`) | empty |
| `seatdata_zone_xref` | 0 | SD zones -> TEvo | empty |
| `matchup_xref` | 445 | TEvo team-name pair -> league-canonical | active |
| `taxonomy_xref` | 12 | TEvo category -> SG category mapping | active |
| `order_status_xref` | 13 | per-source status -> canonical (`fulfilled`/`pending`/etc.) | active |
| `data_source_field_map` | 200 | source field name -> canonical column | drift-detection target |

## Layer 5 — Canonical views

Single sources of truth that paper over per-source quirks.

```
v_canonical_event       <-- entity_event_map + sg_events_canonical + taxonomy_xref
v_canonical_performer   <-- entity_performer_map + performer_wikipedia
v_canonical_venue       <-- entity_venue_map + sg_events_canonical + venue_assets
v_canonical_coverage    <-- sources-per-entity rollup

v_event_full            <-- v_canonical_event + raw snapshots (TEvo+SG+SD pricing)
v_event_full_sports     <-- v_event_full + ESPN team state + injuries + news + home/away
v_event_full_v2         <-- v_event_full + seatgeek_event_metrics + event_sentiment
v_pricing_cross_source  <-- section-level TEvo+SG+SG-seller+SD pricing with sg_vs_tevo_pct

v_event_home_away       <-- events + performer_home_venues + performer_metadata
v_unmatched_events      <-- UNION of orphans across SG, SD, EVO
```

## Layer 6 — Per-source metrics views

| View | Source | What |
|---|---|---|
| `latest_event_metrics` | TEvo | Latest event_metrics row per event (every column: getin, percentiles, owned_share, top5_concentration, dispersion) |
| `broker_event_metrics` | TEvo | Same shape; alias |
| `retail_event_metrics` | TEvo | Lighter cut: tickets/listings/price_from/price_to/getin |
| `event_velocity` | TEvo | Latest vs immediately-previous capture (`snapshots` table) |
| `seatgeek_event_latest` | SG | Latest sg_listings + sg_sales + xref per event |
| `seatdata_event_latest` | SD | Latest SD stats + sales |
| `latest_zone_metrics` | TEvo | Latest zone_metrics per (event, zone) |
| `retail_event_zones`, `retail_event_sections` | TEvo | Public-facing slices |
| `unified_listings` | All | UNION listings_snapshots + seatgeek + seatdata |
| `unified_orders`, `unified_orders_by_event` | All | UNION evo_order_items + seatgeek_orders + seatdata_sales |

## Layer 7 — Intelligence layer

Built from the canonical layer + raw snapshots.

| Object | Type | Source | Purpose |
|---|---|---|---|
| `v_event_velocity_windows` | view | event_metrics + seatgeek_event_metrics | 1h/6h/24h price + inventory deltas across TEvo+SG |
| `v_arbitrage_opportunities` | view | v_pricing_cross_source | Section-level TEvo<->SG gap with depth filter |
| `v_competing_events` | view | events + v_venue_neighbors | ±24h × 20mi neighbors live |
| `event_competitors_snapshot` | table | refresh_event_competitors() | Pre-computed neighbors, hourly refresh |
| `event_alerts` | table | compute_alerts_tick() | Append-only alert log |
| `v_open_alerts` | view | event_alerts + events | Unacknowledged, severity-sorted |
| `v_event_weather_with_fallback` | view | weather_observations + v_venue_climatology + venue_assets | Forecast within 16d, climatology fallback |
| `v_canonical_coverage` | view | entity_event_map + entity_performer_map | Sources-present-per-entity scoreboard |
| `v_unmatched_events` | view | events + sg_events_canonical + seatdata_event_xref + evo_order_items | Orphan bucket across all sources |

Alert rules currently firing (compute_alerts_tick_15min):
1. `tevo_getin_drop_1h` — get-in dropped >10% in last hour
2. `tevo_getin_surge_1h` — get-in jumped >10%
3. `tevo_inventory_low_48h` — <25 tickets within 48h of event
4. `arbitrage_opportunity` — TEvo<->SG section gap >=15%
5. `espn_status_change` — ESPN status_short flipped to postponed/delayed/canceled
6. `competing_event_added` — new event landed within 20mi×24h of a tracked event

## Layer 8 — Consumer interface

Single-call entry points that hide the schema from callers.

| Function | Returns | Use |
|---|---|---|
| `get_event_context(event_id)` | jsonb (event + pricing + ESPN + Wiki + weather + competitors + our_orders) | AI/RAG prompt-time enrichment, single-event dashboards |
| `get_broker_event_detail(event_id)` | jsonb | Broker UI event detail |
| `get_broker_events_upcoming(...)` | table | Broker UI list |
| `get_event_listings_public(event_id)` | table | Public listings surface |
| `get_event_movers(...)` | table | Movers / heatmap surface |
| `get_event_zones_public/_rollup(event_id)` | table | Zone heatmap |
| `get_team_context(team)`, `get_team_playoff_context(team)`, `get_team_roster(team)` | jsonb | Team-level AI/UI bundles |
| `get_player_info(...)` | jsonb | Player-level AI/UI |
| `get_wiki_context(performer_id)` | jsonb | Wikipedia summary (AI prompt) |
| `get_chat_suggestion_chips(...)` | table | Chat-driven UI chips |

## Order-side modeling (gross + net)

```
evo_orders + evo_order_items     \
seatgeek_orders                   ─-> our_orders (UNION, source-tagged)
                                       │
                                       ├─-> our_orders_by_event
                                       │
                                       └─-> our_orders_with_net (joins order_fee_schedule)
                                              │
                                              └─-> our_orders_by_event_with_net
                                                     (gross_fulfilled AND net_fulfilled)
```

`order_fee_schedule` (placeholder rates — verify against contracts):
- `tevo`: 6% seller commission
- `sg_seller`: 10% seller fee
- `seatdata`: 0% (observation-only)

## Active crons (47 total)

Categorized:

- **TEvo listings (windowed)**: `collect-listings-0-24h..60d+` (5)
- **TEvo orders**: `evo_orders_queue_30min`, `evo_orders_process_30min`
- **SG broker listings (windowed)**: `sg_listings_0-24h..60d+` (5) + `sg_listings_process_5min`
- **SG sellerdirect**: `sg_seller_*_30min` (3)
- **Orphan event backfill**: `orphan_event_backfill_queue/process_15min` + `orphan_backfill_sweep_daily`
- **Cross-source matcher**: `cross_source_match_tick_30min`
- **Competitor snapshot**: `event_competitors_refresh_hourly`
- **Alerts**: `compute_alerts_tick_15min`
- **ESPN**: `crawl-espn-team-assets-3min`, `espn-team-daily`, `master-cascade-2min`
- **Wikipedia**: 3 enrichment + `wiki_pending_sweep_daily`
- **Weather**: `weather_forecast_queue/process_30min`, `weather_climatology_weekly`
- **Venue geocoding**: `venue_geocode_queue/process_5min`
- **Chat**: `refresh-chat-corpus`, `refresh-chat-term-freq-split-hourly`, `run-daily-chat-audit`, `sweep-bot-messages`
- **Maintenance**: `master-cascade-2min`, `midnight-catchup-sweep`, `sweep-old-listings`, `sweep_tevo_ticket_groups_cache`, `ensure-watchlist-coverage-daily`, `backfill-event-configurations-5min`, `zone-backfill-isolated-10min`

## Function inventory by family

(184 functions total in public schema)

| Family | Count |
|---|---:|
| other (utility / trgm / cascade / sync) | 91 |
| helpers (get_* consumer-facing) | 21 |
| seatgeek (pull + match) | 15 |
| matchers (cross-source) | 10 |
| tevo | 9 |
| weather | 7 |
| wikipedia | 6 |
| chat | 9 |
| venue | 9 |
| seatdata | 3 (gate + audit only — no pull) |
| espn (upserters; pulls live in Edge Functions) | 3 |
| alerts | 2 |
| competitors | 1 |

## RULE 2 enforcement

3-layer:
- **Runtime**: `evo_client.py`, `seatgeek_client.py` deny non-GET methods
- **Static**: `scripts/check_readonly.py` scans .py + .ts + plpgsql migrations
- **Tests**: `tests/test_readonly_guards.py` synthesizes a violation, asserts the audit catches it

Last audit: 127 plpgsql migrations clean, no write paths to TEvo or SG hosts.

## Foreign keys actually declared

Most cross-source linkage is via **convention** (e.g. `tevo_event_id` columns
in many tables), not declared FKs. Declared FKs:

| From | To |
|---|---|
| `event_xref.tevo_event_id` -> `events.id` |
| `evo_order_items.evo_order_id` -> `evo_orders.evo_order_id` |
| `seatgeek_historic_sales.sg_order_row_id` -> `seatgeek_orders.id` |
| `seatgeek_order_tickets.sg_order_id` -> `seatgeek_orders.sg_order_id` |
| `sg_events_canonical.tevo_event_id` -> `events.id` |
| `snapshots.event_id` -> `events.id` |
| `watch_sources.event_id` -> `events.id` |
| `zone_metrics.event_id` -> `events.id` |
| `weather_observations.source_key` -> `data_sources.source_key` |
| `data_source_field_map.source_key` -> `data_sources.source_key` |
| `canonical_external_ids.source_key` -> `data_sources.source_key` |
| `chat_corpus.user_msg_id` / `bot_msg_id` -> `bot_messages.id` |
| `chat_audit_findings.bot_message_id` -> `bot_messages.id` |
| `leads.event_id` -> `events.id` |
| `performer_zone_rules.zone_id` -> `performer_zones.id` |

**Convention-only joins** (most multi-source connections):
- `*.tevo_event_id` -> `events.id` (in 25+ tables)
- `*.tevo_performer_id` -> performer ids
- `event_xref.espn_event_id` <-> `espn_event_snapshots.espn_event_id`
- `seatdata_event_xref.tevo_event_id` <-> `events.id`
- `sg_events_canonical.sg_event_id` <-> `seatgeek_*.sg_event_id`

## Storage footprint

Total ~2.65 GB:
- `listings_snapshots`: 2,157 MB (81%)
- `section_metrics`: 418 MB (16%)
- `weather_observations`: 46 MB (2%)
- All other tables combined: ~30 MB (1%)

The TEvo listings firehose dominates. Sweep cron `sweep-old-listings` runs
daily but retention policy needs review as we move past 90 days of history.

## Known gaps (referenced in other docs)

- **SeatData pull pipeline missing** — see `docs/seatdata-blocker-2026-05-09.md`
- **SG `payment_total` NULL on every order** — see kanban card in `docs/phase2-ui-kanban.md`
- **Phase 2 backlog** — full list in `docs/phase2-ui-kanban.md`
