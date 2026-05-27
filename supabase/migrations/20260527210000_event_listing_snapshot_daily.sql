-- 20260527210000_event_listing_snapshot_daily.sql
--
-- New table: event_listing_snapshot_daily
-- Captures point-in-time market metrics from EVO + SG 3× per day:
--   morning  (9:30am ET  / 13:30 UTC)
--   midday   (3:30pm ET  / 19:30 UTC)
--   evening  (11:30pm ET /  3:30 UTC)
--
-- WHY NOT reuse event_metrics:
--   With 15-min collect-listings, event_metrics grows to ~96 rows/event/day.
--   Mixing raw operational rows with "designated snapshots" makes trend queries messy.
--   This table: exactly 3 rows/event/day, kept 1 year — clean for BI + trend analysis.
--
-- Sources:
--   EVO columns ← event_metrics (populated by collect-listings edge function every 15 min)
--   SG  columns ← seatgeek_event_metrics (populated by sg_broker_listings_queue every 5 min)
--
-- event_metrics retention: reduced from "forever" → 7 days (raw operational data).
-- Snapshot table retains 1 year.

-- ── 1. Table ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.event_listing_snapshot_daily (
  id             bigserial PRIMARY KEY,
  event_id       bigint    NOT NULL,   -- TEvo event_id (= event_metrics.event_id)
  snapshot_slot  text      NOT NULL,   -- 'morning' | 'midday' | 'evening'
  snapshot_date  date      NOT NULL,   -- UTC date of snapshot

  -- ── EVO metrics (from event_metrics, latest row at snapshot time) ──────────
  evo_tickets_count   int,             -- total active listings count
  evo_owned_tickets   int,             -- our owned ticket count (is_owned=true)
  evo_owned_median    numeric(10,2),   -- our median retail price
  evo_retail_getin    numeric(10,2),   -- lowest listed retail price (get-in)
  evo_retail_median   numeric(10,2),   -- market median retail
  evo_retail_mean     numeric(10,2),   -- market mean retail
  evo_retail_min      numeric(10,2),   -- market floor
  evo_retail_max      numeric(10,2),   -- market ceiling

  -- ── SG broker metrics (from seatgeek_event_metrics, latest row at snapshot time) ──
  sg_all_listings     int,             -- total SG broker listings count
  sg_all_tickets      int,             -- total SG tickets
  sg_owned_tickets    int,             -- our listings on SG
  sg_owned_median     numeric(10,2),   -- our median price on SG
  sg_all_median       numeric(10,2),   -- market median on SG
  sg_all_getin        numeric(10,2),   -- SG get-in (listings_all_min)
  sg_all_mean         numeric(10,2),   -- SG market mean

  captured_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT event_listing_snapshot_daily_slot_check
    CHECK (snapshot_slot IN ('morning', 'midday', 'evening')),
  CONSTRAINT event_listing_snapshot_daily_unique
    UNIQUE (event_id, snapshot_date, snapshot_slot)
);

REVOKE ALL ON TABLE public.event_listing_snapshot_daily FROM anon, authenticated;
ALTER TABLE public.event_listing_snapshot_daily ENABLE ROW LEVEL SECURITY;
CREATE POLICY "service_role_all" ON public.event_listing_snapshot_daily
  TO service_role USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_els_daily_event_date
  ON public.event_listing_snapshot_daily (event_id, snapshot_date DESC);
CREATE INDEX IF NOT EXISTS idx_els_daily_date_slot
  ON public.event_listing_snapshot_daily (snapshot_date, snapshot_slot);

COMMENT ON TABLE public.event_listing_snapshot_daily IS
  '3 daily point-in-time metric snapshots per event (morning/midday/evening ET). '
  'EVO source: event_metrics. SG source: seatgeek_event_metrics. '
  'Kept 1 year. Complements event_metrics (7-day TTL raw data) for long-term trend analysis.';

-- ── 2. Snapshot computation function ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.compute_event_listing_snapshot(
  p_slot text DEFAULT 'manual'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_count int := 0;
  v_jobname text;
BEGIN
  v_jobname := 'event_snapshot_' || p_slot;
  IF p_slot NOT IN ('morning','midday','evening') THEN
    v_jobname := 'event_snapshot_morning';  -- default for cron_should_fire
  END IF;

  IF NOT public.cron_should_fire(v_jobname) THEN RETURN 0; END IF;

  INSERT INTO public.event_listing_snapshot_daily (
    event_id, snapshot_slot, snapshot_date,
    evo_tickets_count, evo_owned_tickets, evo_owned_median,
    evo_retail_getin, evo_retail_median, evo_retail_mean,
    evo_retail_min, evo_retail_max,
    sg_all_listings, sg_all_tickets, sg_owned_tickets,
    sg_owned_median, sg_all_median, sg_all_getin, sg_all_mean,
    captured_at
  )
  SELECT
    em.event_id,
    p_slot,
    CURRENT_DATE,
    -- EVO
    em.tickets_count,
    em.owned_tickets_count,
    em.owned_median_retail,
    em.getin_price,
    em.retail_median,
    em.retail_mean,
    em.retail_min,
    em.retail_max,
    -- SG
    sgm.listings_all_count,
    sgm.listings_all_tickets,
    sgm.listings_owned_tickets,
    sgm.listings_owned_median,
    sgm.listings_all_median,
    sgm.listings_all_min,
    sgm.listings_all_mean,
    now()
  FROM (
    -- Latest event_metrics row per event
    SELECT DISTINCT ON (event_id)
      event_id, tickets_count, owned_tickets_count, owned_median_retail,
      getin_price, retail_median, retail_mean, retail_min, retail_max
    FROM public.event_metrics
    ORDER BY event_id, captured_at DESC
  ) em
  LEFT JOIN (
    -- Latest seatgeek_event_metrics row per event (via tevo_event_id)
    SELECT DISTINCT ON (tevo_event_id)
      tevo_event_id, listings_all_count, listings_all_tickets,
      listings_owned_tickets, listings_owned_median,
      listings_all_median, listings_all_min, listings_all_mean
    FROM public.seatgeek_event_metrics
    ORDER BY tevo_event_id, captured_at DESC
  ) sgm ON sgm.tevo_event_id = em.event_id
  ON CONFLICT (event_id, snapshot_date, snapshot_slot) DO UPDATE SET
    evo_tickets_count  = EXCLUDED.evo_tickets_count,
    evo_owned_tickets  = EXCLUDED.evo_owned_tickets,
    evo_owned_median   = EXCLUDED.evo_owned_median,
    evo_retail_getin   = EXCLUDED.evo_retail_getin,
    evo_retail_median  = EXCLUDED.evo_retail_median,
    evo_retail_mean    = EXCLUDED.evo_retail_mean,
    evo_retail_min     = EXCLUDED.evo_retail_min,
    evo_retail_max     = EXCLUDED.evo_retail_max,
    sg_all_listings    = EXCLUDED.sg_all_listings,
    sg_all_tickets     = EXCLUDED.sg_all_tickets,
    sg_owned_tickets   = EXCLUDED.sg_owned_tickets,
    sg_owned_median    = EXCLUDED.sg_owned_median,
    sg_all_median      = EXCLUDED.sg_all_median,
    sg_all_getin       = EXCLUDED.sg_all_getin,
    sg_all_mean        = EXCLUDED.sg_all_mean,
    captured_at        = EXCLUDED.captured_at;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.compute_event_listing_snapshot(text) FROM anon, public;
COMMENT ON FUNCTION public.compute_event_listing_snapshot(text) IS
  'Compute point-in-time EVO + SG metric snapshot for all events. '
  'p_slot: morning | midday | evening. Called 3×/day by scheduled crons. '
  'Idempotent via ON CONFLICT DO UPDATE — safe to re-run. '
  'Sources: event_metrics (EVO) + seatgeek_event_metrics (SG).';

-- ── 3. Schedule 3 daily snapshot crons ───────────────────────────────────────

DO $sched$ BEGIN

  -- Morning: 9:30am ET = 13:30 UTC (30 min after TD fires SH at 13:00)
  PERFORM cron.schedule(
    'event_snapshot_morning',
    '30 13 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('event_snapshot_morning') THEN RETURN; END IF;
      PERFORM public.compute_event_listing_snapshot('morning');
    END $b$;$cron$
  );

  -- Midday: 3:30pm ET = 19:30 UTC
  PERFORM cron.schedule(
    'event_snapshot_midday',
    '30 19 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('event_snapshot_midday') THEN RETURN; END IF;
      PERFORM public.compute_event_listing_snapshot('midday');
    END $b$;$cron$
  );

  -- Evening: 11:30pm ET = 3:30 UTC
  PERFORM cron.schedule(
    'event_snapshot_evening',
    '30 3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('event_snapshot_evening') THEN RETURN; END IF;
      PERFORM public.compute_event_listing_snapshot('evening');
    END $b$;$cron$
  );

END $sched$;

-- ── 4. cron_policy rows ───────────────────────────────────────────────────────

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, work_check_sql, enabled, notes)
VALUES
  ('event_snapshot_morning',
   ARRAY[]::int[], 1440, 1440, 1, 'SELECT true', true,
   'Daily EVO+SG metric snapshot: morning slot (9:30am ET / 13:30 UTC). '
   'Captures event_metrics (EVO) + seatgeek_event_metrics (SG) state for trend analysis. '
   'Aligned with TD SH fire at 13:00. Retention: 1 year.'),
  ('event_snapshot_midday',
   ARRAY[]::int[], 1440, 1440, 1, 'SELECT true', true,
   'Daily EVO+SG metric snapshot: midday slot (3:30pm ET / 19:30 UTC). '
   'Aligned with TD SH fire at 19:00. Retention: 1 year.'),
  ('event_snapshot_evening',
   ARRAY[]::int[], 1440, 1440, 1, 'SELECT true', true,
   'Daily EVO+SG metric snapshot: evening slot (11:30pm ET / 3:30 UTC). '
   'Aligned with TD SH fire at 3:00. Retention: 1 year.')
ON CONFLICT (jobname) DO UPDATE
  SET notes = EXCLUDED.notes, enabled = true, updated_at = now();

-- ── 5. Reduce event_metrics retention: add to sweep_old_listings function ────
-- event_metrics is now raw operational data (96 rows/event/day with 15-min collection).
-- Keep 7 days for intraday analysis; snapshot table covers long-term.

CREATE OR REPLACE FUNCTION public.sweep_old_listings(
  p_days int DEFAULT 1
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_ls_count  integer;
  v_em_count  integer;
BEGIN
  -- EVO raw listings: 24h rolling window (listings_snapshots)
  DELETE FROM public.listings_snapshots
  WHERE captured_at < now() - make_interval(hours => 24);
  GET DIAGNOSTICS v_ls_count = ROW_COUNT;

  -- event_metrics: 7-day rolling window (raw operational, high-volume with 15-min collection)
  DELETE FROM public.event_metrics
  WHERE captured_at < now() - interval '7 days';
  GET DIAGNOSTICS v_em_count = ROW_COUNT;

  RETURN v_ls_count + v_em_count;
END $$;
REVOKE ALL ON FUNCTION public.sweep_old_listings(int) FROM anon, public;
COMMENT ON FUNCTION public.sweep_old_listings(int) IS
  'UPDATED 2026-05-27: '
  'listings_snapshots (EVO raw): 24h rolling window. '
  'event_metrics (EVO computed): 7-day rolling window (high-volume at 15-min cadence). '
  'Snapshot table (event_listing_snapshot_daily) retains 1 year for trend analysis.';

-- ── 6. Long-term cleanup: sweep event_listing_snapshot_daily > 1 year ────────
-- Add to existing sweep cron chain or handle via separate annual job.
-- For now: handled by sweep_old_listings override above (listings + metrics).
-- Snapshot table annual sweep deferred to future migration when rows accumulate.

-- ── 7. Trend analysis view ────────────────────────────────────────────────────

CREATE OR REPLACE VIEW public.v_event_listing_trends AS
SELECT
  s.id,
  s.event_id,
  s.snapshot_slot,
  s.snapshot_date,
  s.captured_at,

  -- EVO raw metrics
  s.evo_tickets_count,
  s.evo_owned_tickets,
  s.evo_owned_median,
  s.evo_retail_getin,
  s.evo_retail_median,
  s.evo_retail_mean,
  s.evo_retail_min,
  s.evo_retail_max,

  -- SG raw metrics
  s.sg_all_listings,
  s.sg_all_tickets,
  s.sg_owned_tickets,
  s.sg_owned_median,
  s.sg_all_median,
  s.sg_all_getin,
  s.sg_all_mean,

  -- ── Week-over-week delta: same slot 1 week prior (3 slots back) ──────────
  s.evo_retail_median - LAG(s.evo_retail_median, 3) OVER w_event_slot  AS evo_median_wow_delta,
  s.evo_owned_tickets - LAG(s.evo_owned_tickets,  3) OVER w_event_slot AS evo_owned_wow_delta,
  s.sg_all_median     - LAG(s.sg_all_median,      3) OVER w_event_slot AS sg_median_wow_delta,

  -- ── Day-over-day delta: prior same slot (1 slot back) ────────────────────
  s.evo_retail_median - LAG(s.evo_retail_median, 1) OVER w_event_slot  AS evo_median_dod_delta,
  s.evo_owned_tickets - LAG(s.evo_owned_tickets,  1) OVER w_event_slot AS evo_owned_dod_delta,

  -- ── 7-day rolling average (21 slots = 3 slots × 7 days) ─────────────────
  AVG(s.evo_retail_median) OVER (
    PARTITION BY s.event_id
    ORDER BY s.snapshot_date,
             CASE s.snapshot_slot WHEN 'morning' THEN 1 WHEN 'midday' THEN 2 ELSE 3 END
    ROWS BETWEEN 20 PRECEDING AND CURRENT ROW
  ) AS evo_median_21slot_avg,

  AVG(s.sg_all_median) OVER (
    PARTITION BY s.event_id
    ORDER BY s.snapshot_date,
             CASE s.snapshot_slot WHEN 'morning' THEN 1 WHEN 'midday' THEN 2 ELSE 3 END
    ROWS BETWEEN 20 PRECEDING AND CURRENT ROW
  ) AS sg_median_21slot_avg,

  -- ── Pricing position metrics ──────────────────────────────────────────────
  CASE WHEN s.evo_retail_median > 0
    THEN ROUND((s.evo_owned_median / s.evo_retail_median) * 100, 1)
    ELSE NULL
  END AS evo_owned_vs_market_pct,   -- 100 = at market, <100 = below, >100 = above

  ROUND(s.sg_all_median - s.evo_retail_median, 2) AS sg_vs_evo_spread,  -- SG premium (+) or discount (-)

  -- ── Inventory velocity ────────────────────────────────────────────────────
  -- Positive = accumulating tickets; Negative = selling down
  s.evo_owned_tickets - LAG(s.evo_owned_tickets, 3) OVER w_event_slot AS evo_owned_7d_velocity,

  -- ── Event context (from sg_events_canonical) ─────────────────────────────
  sgc.sg_event_name,
  sgc.sg_datetime_utc,
  sgc.sg_venue_name,
  sgc.sg_venue_city,
  sgc.sg_venue_state,
  (sgc.sg_datetime_utc::date - s.snapshot_date)::int AS days_to_event

FROM public.event_listing_snapshot_daily s
LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = s.event_id

WINDOW w_event_slot AS (
  PARTITION BY s.event_id, s.snapshot_slot
  ORDER BY s.snapshot_date
);

REVOKE ALL ON public.v_event_listing_trends FROM anon, authenticated;
COMMENT ON VIEW public.v_event_listing_trends IS
  'Trend analysis over event_listing_snapshot_daily (3 slots/day, 1-year retention). '
  'WoW delta = LAG(3) = same slot 1 week earlier. DoD delta = LAG(1) = prior snapshot. '
  '21-slot rolling avg = 7 calendar days smoothed. '
  'evo_owned_vs_market_pct: 100=at market, <100=below, >100=above. '
  'sg_vs_evo_spread: positive means SG market is more expensive than EVO. '
  'evo_owned_7d_velocity: +ve=accumulating tickets, -ve=selling down. '
  'Deferred: price velocity score, demand index, hold/sell signal (future migration after 14d data).';

GRANT SELECT ON public.v_event_listing_trends TO service_role;
