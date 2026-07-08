-- ============================================================================
-- Migration 20260708172000 — Sell-through velocity / price-momentum enrichment
--
-- Lane:     data plane (A1)
-- Touches:  zone_price_observations (add velocity columns),
--           enrich_zone_price_observations() (extend)
--
-- The #1 gap from the pricing review: the store was a series of static snapshots
-- with no *derivative*. Velocity is the leading demand indicator — how fast
-- inventory drains and which way get-in/price trend between snapshots. Fully
-- self-contained: LAG over each (event_id, zone) ordered by capture_date.
--
-- Turns the store from "what is it worth" into "where is it heading":
--   vel_tickets_sold        = prior tickets_count - current (positive = selling)
--   vel_getin_delta_pct     = get-in momentum since the previous snapshot
--   vel_median_delta_pct    = retail-median momentum
-- Only rows with a prior snapshot for the same (event, zone) get values.
-- ============================================================================

ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS vel_prev_capture_date date;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS vel_days_since_prev   integer;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS vel_tickets_prev      integer;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS vel_tickets_sold      integer;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS vel_getin_prev        numeric;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS vel_getin_delta_pct   numeric;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS vel_median_delta_pct  numeric;

COMMENT ON COLUMN zone_price_observations.vel_tickets_sold IS
  'Prior snapshot tickets_count minus current, for the same (event, zone) — '
  'positive = inventory sold since the last capture. Leading demand indicator.';

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

  UPDATE zone_price_observations z
     SET wx_has_alert = true, wx_alert_tier = a.impact_tier
    FROM (SELECT DISTINCT ON (tevo_event_id) tevo_event_id, impact_tier
            FROM v_event_active_weather_alerts ORDER BY tevo_event_id, impact_tier) a
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

  -- (4) sell-through velocity / momentum (self-lag over each event×zone series)
  WITH lagged AS (
    SELECT event_id, zone, capture_date, getin_price, tickets_count, retail_median,
           lag(capture_date)  OVER w AS prev_date,
           lag(getin_price)   OVER w AS getin_prev,
           lag(tickets_count) OVER w AS tickets_prev,
           lag(retail_median) OVER w AS median_prev
      FROM zone_price_observations
     WINDOW w AS (PARTITION BY event_id, zone ORDER BY capture_date, captured_at)
  )
  UPDATE zone_price_observations z
     SET vel_prev_capture_date = l.prev_date,
         vel_days_since_prev   = (l.capture_date - l.prev_date),
         vel_tickets_prev      = l.tickets_prev,
         vel_tickets_sold      = l.tickets_prev - z.tickets_count,
         vel_getin_prev        = l.getin_prev,
         vel_getin_delta_pct   = CASE WHEN l.getin_prev > 0
                                   THEN round(100*(z.getin_price - l.getin_prev)/l.getin_prev, 2) END,
         vel_median_delta_pct  = CASE WHEN l.median_prev > 0
                                   THEN round(100*(z.retail_median - l.median_prev)/l.median_prev, 2) END
    FROM lagged l
   WHERE l.event_id = z.event_id AND l.zone = z.zone AND l.capture_date = z.capture_date
     AND l.prev_date IS NOT NULL
     AND (p_capture_date IS NULL OR z.capture_date = p_capture_date);

  RETURN v_rows;
END $$;

REVOKE ALL ON FUNCTION enrich_zone_price_observations(date) FROM public;

SELECT enrich_zone_price_observations(NULL);
