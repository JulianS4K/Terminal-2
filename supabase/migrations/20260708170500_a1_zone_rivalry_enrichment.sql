-- ============================================================================
-- Migration 20260708170000 — Rivalry feature + post-build enrichment pattern
--
-- Lane:     data plane (A1)
-- Touches:  zone_price_observations (add rivalry columns),
--           enrich_zone_price_observations() (new), zone daily cron (extend)
--
-- First of the "featurize data we already collect" gaps. Rivalry games command a
-- premium beyond what the opponent's win% implies, and sporting_rivalries is
-- already event-mapped (v_event_sporting_rivalries). Rather than rewrite the
-- monolithic builder for every cheap signal, this adds a lightweight POST-BUILD
-- enrichment function that UPDATEs additive columns by joining the source — the
-- pattern the next cheap features (sell-through velocity, news buzz) will extend.
--
-- Rivalry is static per event, so a full backfill + a per-day enrich after each
-- build keeps it current (the builder's delete-then-insert would otherwise reset
-- the columns to their DEFAULT on the daily today/yesterday rebuild).
-- ============================================================================

ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS is_rivalry          boolean DEFAULT false;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS rivalry_name        text;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS rivalry_intensity   text;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS rivalry_is_branded  boolean;

COMMENT ON COLUMN zone_price_observations.is_rivalry IS
  'Event is a named sporting rivalry (v_event_sporting_rivalries). Set by '
  'enrich_zone_price_observations() after the builder runs; DEFAULT false so '
  'non-rivalry rows are correct without an explicit write.';

-- ----------------------------------------------------------------------------
-- Post-build enrichment: additive signals joined from sources the monolithic
-- builder doesn't touch. p_capture_date NULL enriches the whole table (backfill).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enrich_zone_price_observations(p_capture_date date DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows integer;
BEGIN
  -- rivalry (static per event)
  UPDATE zone_price_observations z
     SET is_rivalry = true,
         rivalry_name = r.rivalry_name,
         rivalry_intensity = r.rivalry_intensity,
         rivalry_is_branded = r.is_branded
    FROM v_event_sporting_rivalries r
   WHERE r.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END $$;

REVOKE ALL ON FUNCTION enrich_zone_price_observations(date) FROM public;

-- Backfill the whole store now.
SELECT enrich_zone_price_observations(NULL);

-- ----------------------------------------------------------------------------
-- Extend the daily cron to enrich after building today + yesterday.
-- ----------------------------------------------------------------------------
SELECT cron.schedule('zone_price_observations_daily', '0 7 * * *', $CRON$
  SELECT public.build_zone_price_observations_day(current_date);
  SELECT public.build_zone_price_observations_day(current_date - 1);
  SELECT public.enrich_zone_price_observations(current_date);
  SELECT public.enrich_zone_price_observations(current_date - 1);
$CRON$);
