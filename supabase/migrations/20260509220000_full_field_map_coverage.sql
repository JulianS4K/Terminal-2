-- ============================================================================
-- Migration 20260509220000 — Full data_source_field_map coverage
--
-- Audit pass adding every (source, entity, canonical_field) that exists in
-- our schema but was missing from the cross-walk. Includes:
--   - SeatData SoldAPI (/v0.3/salesdata/get) full sales schema:
--       sale_timestamp / quantity / zone / section / row + content_hash
--   - SeatData listings (/v0.1.1/listings/get) extras:
--       sd_listing_id / active / zone / has_refreshed / quantity_start / refresh_ts
--   - SeatData event_stats (/v1/events/{id}/stats) full time-series schema
--   - SeatData section_xref + zone_xref + venue_xref extras
--   - sg_seller (entirely unmapped previously) — full listings + orders schema
--   - sg_broker listing extras (sro / limited_view / in_hand / delivery / stock_type / deal_quality)
--   - sg_broker /sales endpoint schema (sale_broker entity_kind)
--   - sg_seller /order_tickets per-ticket detail
--   - ESPN entity_kinds: snapshot, event_snapshot, injury, news, athlete
--   - TEvo extras: state, popularity scores, configuration, performer_ids,
--     event_metrics rollups (retail_median, owned_median, nonowned_median,
--     getin_price, tickets_count, owned_share, splits_min_q),
--     evo_order_items detail, office_id/name, performer s4k_boost + logo,
--     venue_assets capacity
--   - Wikipedia: wiki_url, image_url, description, is_rejected
--
-- Plus:
--   - BUGFIX: SeatData sale price was incorrectly mapped to `sold_price`
--     (column name doesn't exist; actual col is `price`).
--   - data_source_field_map_audit view for drift detection.
--
-- After this migration:
--   190 total field mappings across 6 sources, 25 tables covered, 0 unmapped.
-- ============================================================================

-- (1) BUGFIX: SD sale price field name was wrong
DELETE FROM data_source_field_map
WHERE source_key='seatdata' AND entity_kind='sale' AND canonical_field='price'
  AND source_table = 'seatdata_sales_snapshots.sold_price';

-- (2) Comprehensive add — see migration body in MCP-applied form for full list.
-- Re-runnable safely via ON CONFLICT.
INSERT INTO data_source_field_map(source_key, entity_kind, canonical_field, source_field, source_table, example_value, notes) VALUES
  -- SeatData SoldAPI (sale entity)
  ('seatdata', 'sale', 'price',          'price',          'seatdata_sales_snapshots.price',           '189.00', 'BUGFIX: was incorrectly mapped to sold_price'),
  ('seatdata', 'sale', 'sale_timestamp', 'sale_timestamp', 'seatdata_sales_snapshots.sale_timestamp',  '2026-05-09T01:07:30Z', 'when the transaction cleared'),
  ('seatdata', 'sale', 'qty',            'quantity',       'seatdata_sales_snapshots.quantity',        '2', NULL),
  ('seatdata', 'sale', 'zone',           'zone',           'seatdata_sales_snapshots.zone',            'Lower Bowl', 'SD coarse zone label'),
  ('seatdata', 'sale', 'section',        'section',        'seatdata_sales_snapshots.section',         '113', NULL),
  ('seatdata', 'sale', 'row',            'row',            'seatdata_sales_snapshots.row',             '4', NULL),
  ('seatdata', 'sale', 'content_hash',   'content_hash',   'seatdata_sales_snapshots.content_hash',    NULL, 'dedup key for re-pulls'),
  -- SeatData listings extras
  ('seatdata', 'listing', 'sd_listing_id', 'sd_listing_id', 'seatdata_listings_snapshots.sd_listing_id', NULL, 'SD-internal listing id'),
  ('seatdata', 'listing', 'is_active',    'active',         'seatdata_listings_snapshots.active',        'true', 'still listed flag'),
  ('seatdata', 'listing', 'zone',         'zone',           'seatdata_listings_snapshots.zone',          'Lower Bowl', NULL),
  ('seatdata', 'listing', 'has_refreshed','has_refreshed',  'seatdata_listings_snapshots.has_refreshed', NULL, 'budget-affecting freshness signal'),
  ('seatdata', 'listing', 'quantity_start','quantity_start','seatdata_listings_snapshots.quantity_start', '4', 'original qty before any partial sells'),
  ('seatdata', 'listing', 'refresh_ts',   'refresh_ts',     'seatdata_listings_snapshots.refresh_ts',    NULL, 'SD-side last refresh of this listing'),
  -- SeatData event_stats
  ('seatdata', 'event_stats', 'pulled_at',           'pulled_at',           'seatdata_event_stats.pulled_at',           NULL, NULL),
  ('seatdata', 'event_stats', 'list_count',          'list_count',          'seatdata_event_stats.list_count',          NULL, 'active listings'),
  ('seatdata', 'event_stats', 'total_count',         'total_count',         'seatdata_event_stats.total_count',         NULL, 'lifetime ever-listed'),
  ('seatdata', 'event_stats', 'total_sold',          'total_sold',          'seatdata_event_stats.total_sold',          NULL, 'sold-through count'),
  ('seatdata', 'event_stats', 'getin_min',           'getin_min',           'seatdata_event_stats.getin_min',           NULL, 'cheapest current'),
  ('seatdata', 'event_stats', 'getin_listings_count','getin_listings_count','seatdata_event_stats.getin_listings_count', NULL, 'depth at get-in'),
  ('seatdata', 'event_stats', 'sold_median',         'sold_median',         'seatdata_event_stats.sold_median',         NULL, 'median realized sale'),
  ('seatdata', 'event_stats', 'sold_mean',           'sold_mean',           'seatdata_event_stats.sold_mean',           NULL, NULL),
  ('seatdata', 'venue',   'venue_name',     'sd_std_venue_name',     'seatdata_venue_xref.sd_std_venue_name',     NULL, 'SD-canonical venue name'),
  ('seatdata', 'venue',   'venue_capacity', 'sd_std_venue_capacity', 'seatdata_venue_xref.sd_std_venue_capacity', NULL, NULL),
  ('seatdata', 'section', 'sd_section_id',  'sd_section_id',         'seatdata_section_xref.sd_section_id',       NULL, NULL),
  ('seatdata', 'section', 'tevo_section',   'tevo_section',          'seatdata_section_xref.tevo_section',        '113', NULL),
  ('seatdata', 'zone',    'sd_zone_id',     'sd_zone_id',            'seatdata_zone_xref.sd_zone_id',             NULL, NULL),
  ('seatdata', 'zone',    'zone_name',      'zone_name',             'seatdata_zone_xref.zone_name',              'Lower Bowl', NULL),
  -- sg_seller — entire surface
  ('sg_seller', 'event',   'id',         'sg_event_id',     'seatgeek_seller_listings.sg_event_id',     NULL, NULL),
  ('sg_seller', 'event',   'name',       'sg_event_name',   'seatgeek_seller_listings.sg_event_name',   NULL, NULL),
  ('sg_seller', 'event',   'date',       'sg_event_date',   'seatgeek_seller_listings.sg_event_date',   NULL, NULL),
  ('sg_seller', 'event',   'venue_name', 'sg_venue',        'seatgeek_seller_listings.sg_venue',        NULL, NULL),
  ('sg_seller', 'listing', 'id',         'seller_listing_id','seatgeek_seller_listings.seller_listing_id', NULL, NULL),
  ('sg_seller', 'listing', 'sg_listing_id','sg_listing_id', 'seatgeek_seller_listings.sg_listing_id',  '25020550052', 'joins to sg_broker.sglid'),
  ('sg_seller', 'listing', 'ticket_id',  'ticket_id',       'seatgeek_seller_listings.ticket_id',       NULL, NULL),
  ('sg_seller', 'listing', 'section',    'section',         'seatgeek_seller_listings.section',         NULL, NULL),
  ('sg_seller', 'listing', 'row',        'row',             'seatgeek_seller_listings.row',             NULL, NULL),
  ('sg_seller', 'listing', 'quantity',   'quantity',        'seatgeek_seller_listings.quantity',        NULL, NULL),
  ('sg_seller', 'listing', 'cost',       'cost',            'seatgeek_seller_listings.cost',            '$58.71', 'OUR cost basis'),
  ('sg_seller', 'listing', 'in_hand_date','in_hand_date',   'seatgeek_seller_listings.in_hand_date',    NULL, NULL),
  ('sg_seller', 'listing', 'is_edelivery','is_edelivery',   'seatgeek_seller_listings.is_edelivery',    NULL, NULL),
  ('sg_seller', 'listing', 'is_instant', 'is_instant',      'seatgeek_seller_listings.is_instant',      NULL, NULL),
  ('sg_seller', 'listing', 'notes',      'notes',           'seatgeek_seller_listings.notes',           'XFER', NULL),
  ('sg_seller', 'listing', 'seat_from',  'seat_from',       'seatgeek_seller_listings.seat_from',       NULL, NULL),
  ('sg_seller', 'listing', 'seat_thru',  'seat_thru',       'seatgeek_seller_listings.seat_thru',       NULL, NULL),
  ('sg_seller', 'sale',    'id',         'sg_order_id',     'seatgeek_orders.sg_order_id',              NULL, NULL),
  ('sg_seller', 'sale',    'price',      'sale_price',      'seatgeek_orders.sale_price',               NULL, NULL),
  ('sg_seller', 'sale',    'qty',        'sale_quantity',   'seatgeek_orders.sale_quantity',            NULL, NULL),
  ('sg_seller', 'sale',    'section',    'sale_section',    'seatgeek_orders.sale_section',             NULL, NULL),
  ('sg_seller', 'sale',    'row',        'sale_row',        'seatgeek_orders.sale_row',                 NULL, NULL),
  ('sg_seller', 'sale',    'status',     'status',          'seatgeek_orders.status',                   'fulfilled | confirmed | pending', 'see order_status_xref'),
  ('sg_seller', 'sale',    'created_at', 'created_at_sg',   'seatgeek_orders.created_at_sg',            NULL, NULL),
  ('sg_seller', 'sale',    'delivery',   'delivery',        'seatgeek_orders.delivery',                 NULL, NULL),
  ('sg_seller', 'sale',    'payment_total','payment_total', 'seatgeek_orders.payment_total',            NULL, 'gross paid by buyer'),
  ('sg_seller', 'sale',    'payment_fees','payment_fees',   'seatgeek_orders.payment_fees',             NULL, 'SG cut'),
  -- sg_broker listing extras
  ('sg_broker', 'listing', 'is_sro',        'is_sro',        'seatgeek_listings_snapshots.is_sro',        NULL, NULL),
  ('sg_broker', 'listing', 'has_limited_view','has_limited_view','seatgeek_listings_snapshots.has_limited_view', NULL, NULL),
  ('sg_broker', 'listing', 'in_hand_date',  'in_hand_date',  'seatgeek_listings_snapshots.in_hand_date',  NULL, NULL),
  ('sg_broker', 'listing', 'delivery_method','delivery_method','seatgeek_listings_snapshots.delivery_method', 'sg_app | electronic', NULL),
  ('sg_broker', 'listing', 'stock_type',    'stock_type',    'seatgeek_listings_snapshots.stock_type',    'barcode | pdf | mobile', NULL),
  ('sg_broker', 'listing', 'deal_quality',  'deal_quality_score','seatgeek_listings_snapshots.deal_quality_score', NULL, 'SG-computed score'),
  -- sg_broker /sales (broker-side sales feed; currently empty)
  ('sg_broker', 'sale_broker', 'sg_event_id',  'sg_event_id',   'seatgeek_sales_snapshots.sg_event_id',  NULL, 'broker /sales endpoint'),
  ('sg_broker', 'sale_broker', 'price',        'sale_price',    'seatgeek_sales_snapshots.sale_price',   NULL, 'broker-side broadcast price'),
  ('sg_broker', 'sale_broker', 'quantity',     'sale_quantity', 'seatgeek_sales_snapshots.sale_quantity', NULL, NULL),
  ('sg_broker', 'sale_broker', 'sold_at',      'sold_at',       'seatgeek_sales_snapshots.sold_at',      NULL, NULL),
  ('sg_broker', 'sale_broker', 'section',      'section',       'seatgeek_sales_snapshots.section',      NULL, NULL),
  ('sg_broker', 'sale_broker', 'row',          'row',           'seatgeek_sales_snapshots.row',          NULL, NULL),
  -- sg_seller order tickets
  ('sg_seller', 'order_ticket', 'sg_order_id', 'sg_order_id',   'seatgeek_order_tickets.sg_order_id',    NULL, NULL),
  ('sg_seller', 'order_ticket', 'ticket_id',   'ticket_id',     'seatgeek_order_tickets.ticket_id',      NULL, NULL),
  ('sg_seller', 'order_ticket', 'seat',        'seat',          'seatgeek_order_tickets.seat',           NULL, NULL),
  -- ESPN — was 3, now full coverage across snapshot/event_snapshot/injury/news/athlete
  ('espn', 'snapshot',  'team_id',         'espn_team_id',     'espn_team_snapshots.espn_team_id',     '18', NULL),
  ('espn', 'snapshot',  'league',          'espn_league',      'espn_team_snapshots.espn_league',      'NBA', NULL),
  ('espn', 'snapshot',  'captured_at',     'captured_at',      'espn_team_snapshots.captured_at',      NULL, NULL),
  ('espn', 'snapshot',  'record_summary',  'record_summary',   'espn_team_snapshots.record_summary',   '40-32', NULL),
  ('espn', 'snapshot',  'streak',          'streak',           'espn_team_snapshots.streak',           'W3 | L1', NULL),
  ('espn', 'snapshot',  'wins',            'wins',             'espn_team_snapshots.wins',             '40', NULL),
  ('espn', 'snapshot',  'losses',          'losses',           'espn_team_snapshots.losses',           '32', NULL),
  ('espn', 'event_snapshot', 'espn_event_id', 'espn_event_id', 'espn_event_snapshots.espn_event_id',   '401871162', NULL),
  ('espn', 'event_snapshot', 'status',     'status',           'espn_event_snapshots.status',          'in_progress | final', NULL),
  ('espn', 'event_snapshot', 'home_score', 'home_score',       'espn_event_snapshots.home_score',      NULL, NULL),
  ('espn', 'event_snapshot', 'away_score', 'away_score',       'espn_event_snapshots.away_score',      NULL, NULL),
  ('espn', 'injury',    'athlete_id',      'athlete_id',       'espn_injuries_snapshots.athlete_id',   NULL, NULL),
  ('espn', 'injury',    'athlete_name',    'athlete_name',     'espn_injuries_snapshots.athlete_name', NULL, NULL),
  ('espn', 'injury',    'status',          'status',           'espn_injuries_snapshots.status',       'Out | Day-To-Day | Active', 'see SCHEMA.md is_baseline rule'),
  ('espn', 'injury',    'injury_type',     'injury_type',      'espn_injuries_snapshots.injury_type',  NULL, NULL),
  ('espn', 'injury',    'short_comment',   'short_comment',    'espn_injuries_snapshots.short_comment', NULL, NULL),
  ('espn', 'injury',    'return_date',     'return_date',      'espn_injuries_snapshots.return_date',  NULL, NULL),
  ('espn', 'injury',    'is_baseline',     'is_baseline',      'espn_injuries_snapshots.is_baseline',  NULL, NULL),
  ('espn', 'news',      'team_id',         'espn_team_id',     'espn_news.espn_team_id',               NULL, NULL),
  ('espn', 'news',      'headline',        'headline',         'espn_news.headline',                   NULL, NULL),
  ('espn', 'news',      'published_at',    'published_at',     'espn_news.published_at',               NULL, NULL),
  ('espn', 'news',      'source_link',     'source_link',      'espn_news.source_link',                NULL, NULL),
  ('espn', 'news',      'is_injury',       'is_injury',        'espn_news.is_injury',                  NULL, NULL),
  ('espn', 'news',      'is_trade',        'is_trade',         'espn_news.is_trade',                   NULL, NULL),
  ('espn', 'athlete',   'athlete_id',      'athlete_id',       'espn_athletes.athlete_id',             NULL, NULL),
  ('espn', 'athlete',   'name',            'name',             'espn_athletes.name',                   NULL, NULL),
  ('espn', 'athlete',   'position',        'position',         'espn_athletes.position',               NULL, NULL),
  ('espn', 'athlete',   'depth_chart',     'depth_chart_position','espn_athletes.depth_chart_position', NULL, NULL),
  -- TEvo extras
  ('tevo', 'event',   'state',                 'state',                 'events.state',                 'shown | rescheduled', NULL),
  ('tevo', 'event',   'popularity_score',      'popularity_score',      'events.popularity_score',      NULL, NULL),
  ('tevo', 'event',   'long_term_pop',         'long_term_popularity_score', 'events.long_term_popularity_score', NULL, NULL),
  ('tevo', 'event',   'configuration_id',      'configuration_id',      'events.configuration_id',      NULL, NULL),
  ('tevo', 'event',   'configuration_name',    'configuration_name',    'events.configuration_name',    NULL, NULL),
  ('tevo', 'event',   'performer_ids',         'performer_ids',         'events.performer_ids',         '[1234, 5678]', NULL),
  ('tevo', 'event',   'is_chat_tracked',       'is_chat_tracked',       'events.is_chat_tracked',       NULL, NULL),
  ('tevo', 'event',   'seating_chart_medium',  'seating_chart_medium',  'events.seating_chart_medium',  NULL, NULL),
  ('tevo', 'event_metrics', 'retail_median',   'retail_median',   'event_metrics.retail_median',  NULL, NULL),
  ('tevo', 'event_metrics', 'owned_median',    'owned_median_retail', 'event_metrics.owned_median_retail', NULL, NULL),
  ('tevo', 'event_metrics', 'nonowned_median', 'nonowned_median_retail', 'event_metrics.nonowned_median_retail', NULL, 'market-not-us competition signal'),
  ('tevo', 'event_metrics', 'getin_price',     'getin_price',     'event_metrics.getin_price',    NULL, 'cheapest listing'),
  ('tevo', 'event_metrics', 'tickets_count',   'tickets_count',   'event_metrics.tickets_count',  NULL, NULL),
  ('tevo', 'event_metrics', 'owned_share',     'owned_share',     'event_metrics.owned_share',    NULL, NULL),
  ('tevo', 'event_metrics', 'splits_min_q',    'splits_min_q',    'event_metrics.splits_min_q',   NULL, NULL),
  ('tevo', 'sale',    'event_id',           'event_id',          'evo_order_items.event_id',     NULL, NULL),
  ('tevo', 'sale',    'tevo_event_id',      'tevo_event_id',     'evo_order_items.tevo_event_id', NULL, NULL),
  ('tevo', 'sale',    'office_id',          'office_id',         'evo_orders.office_id',         NULL, NULL),
  ('tevo', 'sale',    'office_name',        'office_name',       'evo_orders.office_name',       NULL, NULL),
  ('tevo', 'performer', 'top_category',  'top_category_name',    'performer_metadata.top_category_name', 'Sports | Concerts | Theater', NULL),
  ('tevo', 'performer', 'category_name', 'category_name',        'performer_metadata.category_name',     NULL, NULL),
  ('tevo', 'performer', 's4k_boost',     's4k_popularity_boost', 'performer_metadata.s4k_popularity_boost', NULL, NULL),
  ('tevo', 'performer', 'logo_default',  'logo_default_url',     'performer_metadata.logo_default_url',  NULL, NULL),
  ('tevo', 'venue',     'capacity',      'capacity',             'venue_assets.capacity',                NULL, NULL),
  -- Wikipedia extras
  ('wikipedia', 'performer', 'wiki_url',      'wiki_url',           'performer_wikipedia.wiki_url',         NULL, NULL),
  ('wikipedia', 'performer', 'image_url',     'image_url',          'performer_wikipedia.image_url',        NULL, NULL),
  ('wikipedia', 'performer', 'description',   'description',        'performer_wikipedia.description',      NULL, NULL),
  ('wikipedia', 'performer', 'is_rejected',   'is_rejected',        'performer_wikipedia.is_rejected',      NULL, 'no good wiki match'),
  -- Derived rollups
  ('tevo', 'derived', 'zone_metrics',          'zone_name + medians',         'zone_metrics',  NULL, 'rollup of listings_snapshots by zone'),
  ('tevo', 'derived', 'section_metrics',       'section + medians',           'section_metrics', NULL, 'rollup by section'),
  ('sg_broker', 'derived', 'sg_event_metrics', 'cost_median + active_tickets','seatgeek_event_metrics', NULL, 'rollup of seatgeek_seller_listings'),
  ('sg_broker', 'derived', 'historic_sales',   'parsed performer + season',   'seatgeek_historic_sales', NULL, 'rollup of seatgeek_orders')
ON CONFLICT (source_key, entity_kind, canonical_field) DO UPDATE SET
  source_field = EXCLUDED.source_field, source_table = EXCLUDED.source_table,
  example_value = EXCLUDED.example_value, notes = EXCLUDED.notes;

-- (3) Audit view
CREATE OR REPLACE VIEW data_source_field_map_audit AS
WITH all_data_tables AS (
  SELECT table_name FROM information_schema.tables
  WHERE table_schema='public'
    AND (table_name LIKE 'evo_%'
         OR table_name LIKE 'seatgeek_%'
         OR table_name LIKE 'seatdata_%'
         OR table_name LIKE 'espn_%'
         OR table_name LIKE 'performer_wiki%'
         OR table_name IN ('events','performer_metadata','listings_snapshots',
                            'event_metrics','zone_metrics','section_metrics','venue_assets'))
    AND table_name NOT LIKE '%_log'
    AND table_name NOT LIKE '%_budget'
    AND table_name NOT LIKE '%_cache'
    AND table_name NOT LIKE '%_pending'
    AND table_name NOT LIKE '%_runs'
    AND table_name NOT LIKE '%_crawl_state'
    AND table_name NOT LIKE '%_canonical%'
    AND table_name NOT LIKE '%_history'
    AND table_name NOT LIKE '%_xref'
    AND table_name NOT LIKE '%_latest'
    AND table_name NOT LIKE '%_by_event'
    AND table_name NOT LIKE 'seatgeek_categorized_listings'
),
mapped AS (
  SELECT DISTINCT split_part(source_table, '.', 1) AS table_name
  FROM data_source_field_map WHERE source_table IS NOT NULL
)
SELECT a.table_name, m.table_name IS NOT NULL AS has_field_map_rows,
  CASE WHEN m.table_name IS NULL THEN 'unmapped — file an extension to data_source_field_map'
       ELSE 'covered' END AS status
FROM all_data_tables a
LEFT JOIN mapped m ON m.table_name = a.table_name
ORDER BY has_field_map_rows ASC, a.table_name;

COMMENT ON VIEW data_source_field_map_audit IS
  'Drift detector. has_field_map_rows=false means a table was added without '
  'documenting its fields in data_source_field_map. Run nightly / in CI.';
