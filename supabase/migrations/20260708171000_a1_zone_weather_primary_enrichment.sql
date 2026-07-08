-- ============================================================================
-- Migration 20260708171000 — Weather + primary-market enrichment
--
-- Lane:     data plane (A1)
-- Touches:  zone_price_observations (add weather + primary columns),
--           enrich_zone_price_observations() (extend)
--
-- Two more "featurize data we already collect" signals, both already event-
-- mapped as views:
--   * Weather (v_event_weather_with_fallback): forecast with a climatology
--     fallback, plus active NWS alerts (v_event_active_weather_alerts). Drives
--     walk-up / last-minute demand for outdoor games.
--   * Primary market (v_event_primary_vs_secondary): AXS primary get-in/median
--     (Ticketmaster/AXS are primaries) vs secondary, with a flip signal — the
--     face-value anchor the store was blind to.
--
-- Enriched (not built-in) because both are per-event snapshots the monolithic
-- builder doesn't read; the value reflects the latest view state, best for
-- upcoming/recent capture_dates (historical as-of forecast/primary isn't stored).
-- ============================================================================

-- weather
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS wx_temp_f      numeric;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS wx_precip_pct  numeric;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS wx_wind_mph    numeric;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS wx_summary     text;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS wx_kind        text;   -- forecast | climo fallback
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS wx_has_alert   boolean DEFAULT false;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS wx_alert_tier  text;

-- primary market (AXS / Ticketmaster)
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS primary_getin           numeric;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS primary_median          numeric;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS primary_listings        integer;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS primary_flip_margin_pct numeric;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS primary_signal          text;

COMMENT ON COLUMN zone_price_observations.primary_getin IS
  'AXS/Ticketmaster primary-market get-in for the event (v_event_primary_vs_secondary). '
  'primary_flip_margin_pct = how far secondary sits above/below primary.';

CREATE OR REPLACE FUNCTION enrich_zone_price_observations(p_capture_date date DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows integer;
BEGIN
  -- (1) rivalry (static per event)
  UPDATE zone_price_observations z
     SET is_rivalry = true, rivalry_name = r.rivalry_name,
         rivalry_intensity = r.rivalry_intensity, rivalry_is_branded = r.is_branded
    FROM v_event_sporting_rivalries r
   WHERE r.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- (2) weather (forecast w/ climatology fallback)
  UPDATE zone_price_observations z
     SET wx_temp_f = w.temp_f, wx_precip_pct = w.precip_pct, wx_wind_mph = w.wind_mph,
         wx_summary = w.weather_summary, wx_kind = w.weather_kind
    FROM v_event_weather_with_fallback w
   WHERE w.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  -- (2b) active weather alert (highest impact tier per event)
  UPDATE zone_price_observations z
     SET wx_has_alert = true, wx_alert_tier = a.impact_tier
    FROM (SELECT DISTINCT ON (tevo_event_id) tevo_event_id, impact_tier
            FROM v_event_active_weather_alerts
           ORDER BY tevo_event_id, impact_tier) a
   WHERE a.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  -- (3) primary market (AXS/Ticketmaster face vs secondary)
  UPDATE zone_price_observations z
     SET primary_getin = p.axs_primary_getin, primary_median = p.axs_primary_median,
         primary_listings = p.axs_primary_listings,
         primary_flip_margin_pct = p.flip_margin_pct, primary_signal = p.signal
    FROM v_event_primary_vs_secondary p
   WHERE p.tevo_event_id = z.event_id
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  RETURN v_rows;
END $$;

REVOKE ALL ON FUNCTION enrich_zone_price_observations(date) FROM public;

-- backfill
SELECT enrich_zone_price_observations(NULL);
