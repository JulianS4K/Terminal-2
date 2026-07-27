-- ============================================================================
-- Migration 20260509210000 — Canonical data map (registry + universal xref + unified views)
--
-- Cleans up the asymmetry between data sources by introducing:
--   data_sources               — registry of every read-only feed
--   data_source_field_map      — per-(source, entity, field) cross-walk
--   canonical_external_ids     — universal {entity_kind, tevo_id, source, source_id}
--   unified_listings           — UNION across all listings tables (mirror of unified_orders)
--   v_canonical_event          — entity_event_map enriched with all data sources
--   v_canonical_performer      — entity_performer_map + Wikipedia
--   v_canonical_coverage       — health-check counts
--
-- Adding a new source = INSERT one row to data_sources + a few rows to
-- data_source_field_map. Optional: extend unified_listings UNION branch.
-- See docs/canonical-data-map-2026-05-09.md for the field-by-field doc.
-- ============================================================================

-- (1) Source registry
CREATE TABLE IF NOT EXISTS data_sources (
  source_key       text PRIMARY KEY,
  display_name     text NOT NULL,
  kind             text NOT NULL,             -- 'pricing' | 'enrichment' | 'sentiment' | 'venue_data'
  host             text,
  auth_method      text,                      -- 'hmac_sha256' | 'token_qs' | 'api_key_header' | 'public'
  read_only        boolean DEFAULT true,      -- RULE 2: every source is read-only
  added_at         timestamptz DEFAULT now(),
  notes            text
);

INSERT INTO data_sources (source_key, display_name, kind, host, auth_method, notes) VALUES
  ('tevo',       'Ticket Evolution',          'pricing',     'api.ticketevolution.com',         'hmac_sha256',     'Hub source. events.id is the canonical event id.'),
  ('sg_broker',  'SeatGeek (broker data)',    'pricing',     'brokerdata.seatgeek.com',         'token_qs',        '/listings + /v2/listings + /sales. Marketplace tier carries broker-vs-fan flags.'),
  ('sg_seller',  'SeatGeek (seller direct)',  'pricing',     'sellerdirect-api.seatgeek.com',   'token_qs',        '/listings + /orders for our own SG catalog.'),
  ('seatdata',   'SeatData',                  'pricing',     'api.seatdata.io',                 'api_key_header',  'Sold listings (transacted) + multi-marketplace get-in.'),
  ('espn',       'ESPN',                      'enrichment',  'site.api.espn.com',               'public',          'Sports only. Standings, injuries, news, players.'),
  ('wikipedia',  'Wikipedia',                 'enrichment',  'en.wikipedia.org',                'public',          'Performer descriptions + extracts.')
ON CONFLICT (source_key) DO UPDATE SET
  display_name = EXCLUDED.display_name, kind = EXCLUDED.kind,
  host = EXCLUDED.host, auth_method = EXCLUDED.auth_method, notes = EXCLUDED.notes;

COMMENT ON TABLE data_sources IS
  'Registry of every external read-only feed. Adding a new source = INSERT '
  'one row + create xref tables OR use canonical_external_ids.';

-- (2) Field-by-field map
CREATE TABLE IF NOT EXISTS data_source_field_map (
  source_key      text NOT NULL REFERENCES data_sources(source_key) ON DELETE CASCADE,
  entity_kind     text NOT NULL,
  canonical_field text NOT NULL,
  source_field    text NOT NULL,
  source_table    text,
  example_value   text,
  notes           text,
  PRIMARY KEY (source_key, entity_kind, canonical_field)
);

COMMENT ON TABLE data_source_field_map IS
  'Per-source field cross-walk. Discoverable: query for a canonical_field '
  'and you get every source''s name + table for it. Adding a new mapping '
  'is a single INSERT.';

-- Field-map seed (62 mappings across 5 entity kinds × 6 sources where applicable)
INSERT INTO data_source_field_map(source_key, entity_kind, canonical_field, source_field, source_table, example_value, notes) VALUES
  ('tevo',      'event', 'id',          'id',                 'events.id',                              '3092720', 'bigint, hub for everything'),
  ('tevo',      'event', 'name',        'name',               'events.name',                            'Colorado Rockies at Arizona Diamondbacks', NULL),
  ('tevo',      'event', 'date',        'occurs_at_local',    'events.occurs_at_local',                 '2026-05-22T19:40:00-07:00', 'local TZ'),
  ('tevo',      'event', 'venue_id',    'venue_id',           'events.venue_id',                        '1234', NULL),
  ('tevo',      'event', 'venue_name',  'venue_name',         'events.venue_name',                      'Chase Field', NULL),
  ('tevo',      'event', 'event_type',  'event_type',         'events.event_type',                      'game | concert | comedy | show', NULL),
  ('sg_broker', 'event', 'id',          'sg_event_id',        'sg_events_canonical.sg_event_id',        '17692460', 'independent ID space'),
  ('sg_broker', 'event', 'name',        'sg_event_name',      'sg_events_canonical.sg_event_name',      'Colorado Rockies at Arizona Diamondbacks', NULL),
  ('sg_broker', 'event', 'date',        'sg_event_date',      'sg_events_canonical.sg_event_date',      '2026-05-22', NULL),
  ('sg_broker', 'event', 'datetime_utc','sg_datetime_utc',    'sg_events_canonical.sg_datetime_utc',    '2026-05-23T01:40:00+00:00', NULL),
  ('sg_broker', 'event', 'category',    'sg_category',        'sg_events_canonical.sg_category',        'mlb | nba | concert', 'lowercase enum'),
  ('sg_broker', 'event', 'venue_name',  'sg_venue_name',      'sg_events_canonical.sg_venue_name',      'Chase Field', NULL),
  ('seatdata',  'event', 'id',          'sd_event_id',        'seatdata_event_xref.sd_event_id',        '1247184', NULL),
  ('seatdata',  'event', 'tm_event_id', 'sd_tm_event_id',     'seatdata_event_xref.sd_tm_event_id',     'TM-style id', 'Ticketmaster passthrough'),
  ('espn',      'event', 'id',          'espn_event_id',      'event_xref.espn_event_id',               '401871162', 'Sports-only'),
  ('tevo',      'performer', 'id',         'performer_id',       'performer_metadata.performer_id',     '1234', NULL),
  ('tevo',      'performer', 'name',       'name',               'performer_metadata.name',             'New York Knicks', NULL),
  ('tevo',      'performer', 'event_type', 'what_event_type',    'performer_metadata.what_event_type',  'sports | concert | comedy | theater', NULL),
  ('tevo',      'performer', 'genre',      'genre',              'performer_metadata.genre',            'rock | hip hop | classical', 'concerts only'),
  ('sg_broker', 'performer', 'name',       'sg_performer_name',  'seatgeek_performer_xref.sg_performer_name', 'Detroit Tigers', 'name only'),
  ('seatdata',  'performer', 'id',         'sd_performer_id',    'seatdata_performer_xref.sd_performer_id', NULL, NULL),
  ('espn',      'performer', 'team_id',    'espn_team_id',       'performer_metadata.espn_team_id',     '18', 'sports only'),
  ('espn',      'performer', 'league',     'espn_league',        'performer_metadata.espn_league',      'NBA | NFL | MLB | NHL | MLS | WNBA', NULL),
  ('wikipedia', 'performer', 'pageid',     'wiki_pageid',        'performer_wikipedia.wiki_pageid',     '72855', NULL),
  ('wikipedia', 'performer', 'title',      'wiki_title',         'performer_wikipedia.wiki_title',      'New York Knicks', NULL),
  ('wikipedia', 'performer', 'extract',    'extract',            'performer_wikipedia.extract',         'The New York Knickerbockers...', NULL),
  ('tevo',      'venue', 'id',           'venue_id',           'events.venue_id',                        '1234', NULL),
  ('tevo',      'venue', 'name',         'venue_name',         'events.venue_name',                      'Madison Square Garden', NULL),
  ('sg_broker', 'venue', 'id',           'sg_venue_id',        'sg_events_canonical.sg_venue_id',        '30', NULL),
  ('sg_broker', 'venue', 'city',         'sg_venue_city',      'sg_events_canonical.sg_venue_city',      'Phoenix', NULL),
  ('sg_broker', 'venue', 'state',        'sg_venue_state',     'sg_events_canonical.sg_venue_state',     'AZ', NULL),
  ('sg_broker', 'venue', 'address',      'sg_venue_address',   'sg_events_canonical.sg_venue_address',   '401 E Jefferson St', NULL),
  ('seatdata',  'venue', 'std_venue_id', 'sd_std_venue_id',    'seatdata_venue_xref.sd_std_venue_id',    NULL, NULL),
  ('tevo',      'listing', 'id',          'tevo_ticket_group_id', 'listings_snapshots.tevo_ticket_group_id', NULL, NULL),
  ('tevo',      'listing', 'section',     'section',            'listings_snapshots.section',          NULL, NULL),
  ('tevo',      'listing', 'row',         'row',                'listings_snapshots.row',              NULL, NULL),
  ('tevo',      'listing', 'quantity',    'quantity',           'listings_snapshots.quantity',         NULL, NULL),
  ('tevo',      'listing', 'retail_price','retail_price',       'listings_snapshots.retail_price',     NULL, 'all-in retail'),
  ('tevo',      'listing', 'wholesale',   'wholesale_price',    'listings_snapshots.wholesale_price',  NULL, 'broker-payout'),
  ('tevo',      'listing', 'splits',      'splits',             'listings_snapshots.splits',           NULL, 'int[] same encoding as SG sp'),
  ('tevo',      'listing', 'is_owned',    'is_owned',           'listings_snapshots.is_owned',         NULL, 'S4K-owned'),
  ('tevo',      'listing', 'broker_name', 'brokerage_name',     'listings_snapshots.brokerage_name',   NULL, 'EVO exposes broker identity'),
  ('sg_broker', 'listing', 'id',          'display_id',         'seatgeek_listings_snapshots.display_id', '0nq14wj', 'opaque short string'),
  ('sg_broker', 'listing', 'sglid',       'sglid',              'seatgeek_listings_snapshots.sglid',   '25020550052', 'broker-network id'),
  ('sg_broker', 'listing', 'section',     'section',            'seatgeek_listings_snapshots.section', NULL, NULL),
  ('sg_broker', 'listing', 'row',         'row',                'seatgeek_listings_snapshots.row',     NULL, NULL),
  ('sg_broker', 'listing', 'quantity',    'quantity',           'seatgeek_listings_snapshots.quantity', NULL, NULL),
  ('sg_broker', 'listing', 'retail_price','retail_price_all_in','seatgeek_listings_snapshots.retail_price_all_in', NULL, 'pf in raw'),
  ('sg_broker', 'listing', 'wholesale',   'broadcast_price',    'seatgeek_listings_snapshots.broadcast_price', NULL, 'bp in raw'),
  ('sg_broker', 'listing', 'splits',      'splits',             'seatgeek_listings_snapshots.splits',  NULL, 'jsonb int array'),
  ('sg_broker', 'listing', 'tier_b2b',    'is_b2b',             'seatgeek_listings_snapshots.is_b2b',  NULL, 'broker-to-broker only'),
  ('sg_broker', 'listing', 'tier_market', 'market_source',      'seatgeek_listings_snapshots.market_source', 'exchange|marketplace', 'fan vs broker network'),
  ('seatdata',  'listing', 'price',       'price',              'seatdata_listings_snapshots.price',   NULL, 'list price (active row)'),
  ('seatdata',  'listing', 'sold_price',  'sold_price',         'seatdata_sales_snapshots.sold_price', NULL, 'transacted retail'),
  ('tevo',      'sale', 'id',         'order_id',          'evo_orders.order_id',                NULL, NULL),
  ('tevo',      'sale', 'price',      'price',             'evo_orders.price',                   NULL, NULL),
  ('tevo',      'sale', 'qty',        'quantity',          'evo_orders.quantity',                NULL, NULL),
  ('sg_broker', 'sale', 'id',         'sg_order_id',       'seatgeek_orders.sg_order_id',        NULL, NULL),
  ('sg_broker', 'sale', 'price',      'sale_price',        'seatgeek_orders.sale_price',         NULL, NULL),
  ('sg_broker', 'sale', 'section',    'sale_section',      'seatgeek_orders.sale_section',       NULL, NULL),
  ('sg_broker', 'sale', 'qty',        'sale_quantity',     'seatgeek_orders.sale_quantity',      NULL, NULL),
  ('seatdata',  'sale', 'price',      'sold_price',        'seatdata_sales_snapshots.sold_price', NULL, 'every SD sale row IS a transacted sale')
ON CONFLICT (source_key, entity_kind, canonical_field) DO UPDATE SET
  source_field = EXCLUDED.source_field, source_table = EXCLUDED.source_table,
  example_value = EXCLUDED.example_value, notes = EXCLUDED.notes;

-- (3) Universal external-ids (slot-in shortcut for new sources)
CREATE TABLE IF NOT EXISTS canonical_external_ids (
  entity_kind   text NOT NULL,           -- 'event' | 'performer' | 'venue'
  tevo_id       bigint NOT NULL,
  source_key    text NOT NULL REFERENCES data_sources(source_key) ON DELETE CASCADE,
  external_id   text NOT NULL,
  external_name text,
  match_method  text,
  match_confidence numeric(3,2),
  matched_at    timestamptz DEFAULT now(),
  meta          jsonb,
  PRIMARY KEY (entity_kind, tevo_id, source_key)
);

CREATE INDEX IF NOT EXISTS canonical_external_ids_lookup_idx
  ON canonical_external_ids(entity_kind, source_key, external_id);

COMMENT ON TABLE canonical_external_ids IS
  'Universal {entity_kind, tevo_id, source} -> external_id mapping. New '
  'data sources can use this directly without creating a dedicated '
  '{src}_event_xref / {src}_performer_xref table.';

-- (4) unified_listings — mirror of unified_orders
CREATE OR REPLACE VIEW unified_listings AS
SELECT
  'tevo'::text                                AS source_key,
  ls.event_id                                 AS tevo_event_id,
  NULL::bigint                                AS sg_event_id,
  NULL::bigint                                AS sd_event_id,
  ls.tevo_ticket_group_id::text               AS source_listing_id,
  ls.section, ls.row, ls.quantity,
  ls.retail_price, ls.wholesale_price,
  to_jsonb(ls.splits)                         AS splits_jsonb,
  ls.eticket                                  AS is_eticket,
  ls.wheelchair                               AS is_wheelchair,
  ls.instant_delivery                         AS is_instant,
  ls.is_ancillary,
  ls.type                                     AS listing_type,
  ls.brokerage_name,
  ls.is_owned,
  NULL::text                                  AS sg_market_tier,
  NULL::boolean                               AS sg_is_b2b,
  ls.captured_at
FROM listings_snapshots ls
UNION ALL
SELECT 'sg_broker'::text,
  sls.tevo_event_id, sls.sg_event_id, NULL::bigint,
  sls.display_id,
  sls.section, sls.row, sls.quantity,
  sls.retail_price_all_in, sls.broadcast_price,
  sls.splits,
  NULL::boolean, sls.is_wheelchair_acc, sls.is_instant_download,
  NULL::boolean, NULL::text,
  NULL::text, sls.is_broker_owned,
  sls.market_source, sls.is_b2b,
  sls.captured_at
FROM seatgeek_listings_snapshots sls
UNION ALL
SELECT 'sg_seller'::text,
  ssl.tevo_event_id, ssl.sg_event_id, NULL::bigint,
  ssl.seller_listing_id,
  ssl.section, ssl.row, ssl.quantity,
  ssl.cost, NULL::numeric,
  to_jsonb(ARRAY[ssl.quantity]),
  NULL::boolean, NULL::boolean, ssl.is_instant,
  NULL::boolean, NULL::text,
  NULL::text, true,
  'exchange'::text, false,
  ssl.pulled_at
FROM seatgeek_seller_listings ssl
UNION ALL
SELECT 'seatdata'::text,
  sdl.tevo_event_id, NULL::bigint, sdl.sd_event_id,
  sdl.content_hash,
  sdl.section, sdl.row, sdl.quantity,
  sdl.price, NULL::numeric,
  to_jsonb(ARRAY[sdl.quantity]),
  NULL::boolean, NULL::boolean, NULL::boolean,
  NULL::boolean, NULL::text,
  NULL::text, NULL::boolean,
  NULL::text, NULL::boolean,
  sdl.pulled_at
FROM seatdata_listings_snapshots sdl;

COMMENT ON VIEW unified_listings IS
  'UNION across all listings sources with normalized columns. source_key '
  'tag distinguishes TEvo / SG broker / SG seller / SeatData. Mirrors the '
  'unified_orders shape so cross-source pivots work.';

-- (5) Canonical entity views
CREATE OR REPLACE VIEW v_canonical_event AS
SELECT
  eem.tevo_event_id,
  eem.tevo_name,
  eem.event_date,
  eem.tevo_venue_id,
  eem.tevo_venue_name,
  eem.tevo_event_type,
  eem.tevo_primary_performer_id,
  eem.tevo_primary_performer_name,
  eem.espn_event_id,
  eem.espn_league,
  eem.espn_slug,
  eem.sd_event_id,
  eem.sg_event_id,
  eem.sg_event_name,
  eem.lifecycle_status,
  eem.lifecycle_is_active,
  eem.sources_count,
  eem.external_ids AS legacy_external_ids,
  sgc.sg_category,
  sgc.sg_datetime_utc,
  sgc.sg_url,
  sgc.has_seller_listings AS sg_has_seller_listings,
  sgc.has_orders          AS sg_has_orders,
  sgc.has_v2_listings_pulled AS sg_has_v2_pulled,
  tx.canonical_label
FROM entity_event_map eem
LEFT JOIN sg_events_canonical sgc ON sgc.tevo_event_id = eem.tevo_event_id
LEFT JOIN taxonomy_xref tx ON lower(tx.tevo_event_type) = lower(eem.tevo_event_type);

CREATE OR REPLACE VIEW v_canonical_performer AS
SELECT
  epm.tevo_performer_id,
  epm.tevo_performer_name,
  epm.what_event_type,
  epm.top_category_name,
  epm.parent_category_name,
  epm.category_name,
  epm.genre,
  epm.espn_team_id,
  epm.espn_league,
  epm.home_venue_ids,
  epm.sd_performer_id,
  epm.sg_performer_name,
  epm.sources_count,
  epm.external_ids AS legacy_external_ids,
  pw.wiki_pageid,
  pw.wiki_title,
  pw.wiki_url,
  pw.description AS wiki_description,
  pw.extract     AS wiki_extract,
  pw.image_url   AS wiki_image_url,
  pw.match_method AS wiki_match_method
FROM entity_performer_map epm
LEFT JOIN performer_wikipedia pw ON pw.tevo_performer_id = epm.tevo_performer_id;

CREATE OR REPLACE VIEW v_canonical_coverage AS
SELECT
  'event' AS entity_kind,
  count(*) AS total_canonical_rows,
  count(*) FILTER (WHERE espn_event_id IS NOT NULL) AS with_espn,
  count(*) FILTER (WHERE sd_event_id IS NOT NULL)   AS with_seatdata,
  count(*) FILTER (WHERE sg_event_id IS NOT NULL)   AS with_seatgeek,
  count(*) FILTER (WHERE sources_count >= 2)        AS with_2plus_sources
FROM entity_event_map
UNION ALL
SELECT
  'performer', count(*),
  count(*) FILTER (WHERE espn_team_id IS NOT NULL),
  count(*) FILTER (WHERE sd_performer_id IS NOT NULL),
  count(*) FILTER (WHERE sg_performer_name IS NOT NULL),
  count(*) FILTER (WHERE
    (CASE WHEN espn_team_id IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN sd_performer_id IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN sg_performer_name IS NOT NULL THEN 1 ELSE 0 END) >= 1)
FROM entity_performer_map;
