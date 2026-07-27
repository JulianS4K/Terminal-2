-- ============================================================
-- MIG-A — collector_cadence: the tunable per-source / per-scope / per-horizon-band
-- poll-interval config that the new per-event pollers (evo_listings_poll_tick,
-- sg_listings_poll_tick, retuned sg_sales_poll_tick) read each tick.
-- A1 2026-05-31 (operator-approved cadence redesign; see plan zany-skipping-fox.md).
--
-- Two-layer split: cron_policy governs how often a tick SCANS; collector_cadence
-- governs the per-event INTERVAL, enforced in-tick via collector_band(). Peak = ET 12-23.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.collector_cadence (
  source     text    NOT NULL,            -- 'EVO' | 'SG'
  scope      text    NOT NULL,            -- 'listings' | 'sales'
  band       text    NOT NULL,
  min_hours  numeric NOT NULL,            -- inclusive lower bound (hours-to-event)
  max_hours  numeric,                     -- exclusive upper; NULL = +inf
  peak_interval_min    int NOT NULL,
  offpeak_interval_min int NOT NULL,
  enabled    boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  notes      text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, scope, band)
);
REVOKE ALL ON TABLE public.collector_cadence FROM anon;

INSERT INTO public.collector_cadence
  (source, scope, band, min_hours, max_hours, peak_interval_min, offpeak_interval_min, sort_order, notes) VALUES
  ('EVO','listings','le7d',     0,  168,  15,  15, 1, 'EVO unlimited rate; aggressive near-term'),
  ('EVO','listings','d8_14',  168,  336,  30,  60, 2, '30m peak / 60m off-peak'),
  ('EVO','listings','d15_30', 336,  720,  60,  60, 3, NULL),
  ('EVO','listings','d31_60', 720, 1440, 240, 240, 4, NULL),
  ('EVO','listings','d61p',  1440, NULL, 720, 720, 5, '12h far-out'),
  ('SG','listings','le7d',     0,  168,  60,  60, 1, 'SG rate-limited; conservative'),
  ('SG','listings','d8_14',  168,  336, 240, 240, 2, NULL),
  ('SG','listings','d15_30', 336,  720, 720, 720, 3, NULL),
  ('SG','listings','d31p',   720, NULL,1440,1440, 4, 'incl folded blindspot tail'),
  ('SG','sales','le7d',        0,  168,  60,  60, 1, NULL),
  ('SG','sales','d8_14',     168,  336, 240, 240, 2, NULL),
  ('SG','sales','d15_30',    336,  720, 720, 720, 3, NULL),
  ('SG','sales','d31p',      720, NULL,1440,1440, 4, NULL)
ON CONFLICT (source, scope, band) DO NOTHING;

-- Resolve an event's band + the interval to use right now (peak vs off-peak by ET hour).
CREATE OR REPLACE FUNCTION public.collector_band(p_source text, p_scope text, p_hours numeric)
RETURNS TABLE(band text, required_min int)
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp'
AS $function$
  SELECT c.band,
         CASE WHEN EXTRACT(hour FROM now() AT TIME ZONE 'America/New_York')::int
                   = ANY (ARRAY[12,13,14,15,16,17,18,19,20,21,22,23])
              THEN c.peak_interval_min ELSE c.offpeak_interval_min END
  FROM public.collector_cadence c
  WHERE c.source = p_source AND c.scope = p_scope AND c.enabled
    AND p_hours >= c.min_hours
    AND (c.max_hours IS NULL OR p_hours < c.max_hours)
  ORDER BY c.sort_order
  LIMIT 1;
$function$;
REVOKE ALL ON FUNCTION public.collector_band(text,text,numeric) FROM anon;
