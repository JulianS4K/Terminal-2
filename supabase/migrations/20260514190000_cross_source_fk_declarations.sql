-- Migration 20260514190000 · level:admin · lane:Audit/Push · writes:56 FK constraints across 7 anchor tables · reads:- · pre:20260514185100
-- Schema visualizer fix: 56 cross-source FKs declared, NOT VALID.
--
-- Why: per bot_chat row 108, the Supabase Studio visualizer showed almost no
-- cross-source mapping because only 22 FKs were declared. Operator clarified
-- that event_id / performer_id / venue_id columns are SOURCE-SPECIFIC (each
-- source has its own ID space — TEvo, SeatGeek, ESPN, SeatData, etc. don't
-- share number spaces), so columns are ONLY safe to FK when prefixed
-- (tevo_*, sg_*, espn_*).
--
-- Strategy: NOT VALID on every constraint.
--   - Existing rows are NOT scanned on apply (instant ALTER, no lock storm)
--   - Dirty rows (orphans where parent doesn't exist) are accepted
--   - All future INSERT/UPDATE checked against the constraint
--   - Later `ALTER TABLE … VALIDATE CONSTRAINT` will surface orphans for cleanup
--
-- Orphan spot-check during this apply (2026-05-14 18:20 UTC): 0 orphans on
-- event_alerts, seatdata/seatgeek listings_snapshots, seatgeek_orders,
-- tickpick_orders, vivid_orders, seatgeek_listings_snapshots(sg_event_id).
-- Data is already clean; validation is purely cosmetic perf for the
-- visualizer, deferred to a follow-up batch.
--
-- Anchor PKs (verified):
--   events(id)                                      single
--   performer_metadata(performer_id)                single
--   venue_assets(tevo_venue_id)                     single
--   sg_events_canonical(sg_event_id)                single
--   espn_athletes(espn_athlete_id)                  single
--   macro_series_config(series_id)                  single
--   espn_teams_canonical(espn_team_id,espn_league)  COMPOSITE (handled below)
--
-- Result post-apply:
--   FKs to events:               8 → 27 (+19)
--   FKs to sg_events_canonical:  0 → 11 (+11)
--   FKs to venue_assets:         0 → 9  (+9)
--   FKs to espn_teams_canonical: 0 → 8  (+8 composite)
--   FKs to performer_metadata:   0 → 7  (+7)
--   FKs to macro_series_config:  0 → 1  (+1)
--   FKs to espn_athletes:        0 → 1  (+1)
--   Total prod FKs: 22 → 78.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 ~18:20 UTC during cron-paused window
-- (bot_chat row 106). Idempotent codification per SYNC_PROTOCOL §5.

-- ============================================================================
-- Single-column FKs (47 from the 19 events + 11 sg + 9 venue + 7 performer
-- + 1 macro + 1 athlete = 48 ... wait, the table count is 48 single-col)
-- ============================================================================

DO $$
DECLARE
  pair text[];
  cname text;
  pairs text[][] := ARRAY[
    -- events(id) refs (19)
    ARRAY['event_alerts','tevo_event_id','events','id'],
    ARRAY['event_competitors_snapshot','tevo_event_id','events','id'],
    ARRAY['evo_event_backfill_pending','tevo_event_id','events','id'],
    ARRAY['seatdata_event_stats','tevo_event_id','events','id'],
    ARRAY['seatdata_event_xref','tevo_event_id','events','id'],
    ARRAY['seatdata_listings_snapshots','tevo_event_id','events','id'],
    ARRAY['seatdata_pull_log','tevo_event_id','events','id'],
    ARRAY['seatdata_sales_snapshots','tevo_event_id','events','id'],
    ARRAY['seatdata_section_xref','tevo_event_id','events','id'],
    ARRAY['seatdata_zone_xref','tevo_event_id','events','id'],
    ARRAY['seatgeek_event_metrics','tevo_event_id','events','id'],
    ARRAY['seatgeek_event_xref','tevo_event_id','events','id'],
    ARRAY['seatgeek_listings_snapshots','tevo_event_id','events','id'],
    ARRAY['seatgeek_orders','tevo_event_id','events','id'],
    ARRAY['seatgeek_pull_log','tevo_event_id','events','id'],
    ARRAY['seatgeek_sales_snapshots','tevo_event_id','events','id'],
    ARRAY['seatgeek_seller_listings','tevo_event_id','events','id'],
    ARRAY['tickpick_orders','tevo_event_id','events','id'],
    ARRAY['vivid_orders','tevo_event_id','events','id'],
    -- performer_metadata(performer_id) refs (7)
    ARRAY['performer_espn_team_xref','tevo_performer_id','performer_metadata','performer_id'],
    ARRAY['performer_subreddits','tevo_performer_id','performer_metadata','performer_id'],
    ARRAY['performer_wiki_pending','tevo_performer_id','performer_metadata','performer_id'],
    ARRAY['performer_wikipedia','tevo_performer_id','performer_metadata','performer_id'],
    ARRAY['reddit_posts','tevo_performer_id','performer_metadata','performer_id'],
    ARRAY['seatdata_performer_xref','tevo_performer_id','performer_metadata','performer_id'],
    ARRAY['seatgeek_performer_xref','tevo_performer_id','performer_metadata','performer_id'],
    -- venue_assets(tevo_venue_id) refs (9)
    ARRAY['major_event_calendar','tevo_venue_id','venue_assets','tevo_venue_id'],
    ARRAY['seatdata_venue_xref','tevo_venue_id','venue_assets','tevo_venue_id'],
    ARRAY['seatgeek_orders_resolved','tevo_venue_id','venue_assets','tevo_venue_id'],
    ARRAY['seatgeek_venue_xref','tevo_venue_id','venue_assets','tevo_venue_id'],
    ARRAY['venue_geocode_pending','tevo_venue_id','venue_assets','tevo_venue_id'],
    ARRAY['venue_nws_points_pending','tevo_venue_id','venue_assets','tevo_venue_id'],
    ARRAY['venue_pulls','tevo_venue_id','venue_assets','tevo_venue_id'],
    ARRAY['weather_forecast_pending','tevo_venue_id','venue_assets','tevo_venue_id'],
    ARRAY['weather_observations','tevo_venue_id','venue_assets','tevo_venue_id'],
    -- sg_events_canonical(sg_event_id) refs (11)
    ARRAY['seatgeek_event_metrics','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['seatgeek_event_xref','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['seatgeek_historic_sales','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['seatgeek_listings_snapshots','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['seatgeek_orders','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['seatgeek_pull_log','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['seatgeek_sales_snapshots','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['seatgeek_seller_listings','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['sg_event_backfill_pending','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['sg_event_match_pending','sg_event_id','sg_events_canonical','sg_event_id'],
    ARRAY['sg_listings_pending','sg_event_id','sg_events_canonical','sg_event_id'],
    -- macro_series_config(series_id) refs (1)
    ARRAY['macro_indicators','series_id','macro_series_config','series_id'],
    -- espn_athletes(espn_athlete_id) refs (1)
    ARRAY['espn_athlete_team_history','espn_athlete_id','espn_athletes','espn_athlete_id']
  ];
BEGIN
  FOREACH pair SLICE 1 IN ARRAY pairs LOOP
    cname := pair[1] || '_' || pair[2] || '_fkey';
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = cname) THEN
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES public.%I(%I) NOT VALID',
        pair[1], cname, pair[2], pair[3], pair[4]
      );
    END IF;
  END LOOP;
END $$;

-- ============================================================================
-- Composite (espn_team_id, espn_league) → espn_teams_canonical (8 tables)
-- ============================================================================

DO $$
DECLARE
  tbls text[] := ARRAY[
    'espn_asset_crawl_state','espn_athlete_team_history','espn_athletes',
    'espn_injuries_snapshots','espn_news','espn_team_snapshots',
    'performer_espn_team_xref','performer_metadata'
  ];
  t text; cname text;
BEGIN
  FOREACH t IN ARRAY tbls LOOP
    cname := t || '_espn_team_fkey';
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = cname) THEN
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (espn_team_id, espn_league) REFERENCES public.espn_teams_canonical(espn_team_id, espn_league) NOT VALID',
        t, cname
      );
    END IF;
  END LOOP;
END $$;
