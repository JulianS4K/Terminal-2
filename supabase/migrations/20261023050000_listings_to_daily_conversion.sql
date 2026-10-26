-- Migration 20261023050000 · level:ops · lane:A1 (data plane — retention/rollups) · writes:listing_obs_section_daily(new),listing_conversion_state(new),rollup_listing_obs_daily()(new),listing_rollup_frontier()(new),listings_conversion_tick()(new),cron:listings_conversion_tick_5min · reads:gotickets_listings_snapshots,seatgeek_listings_snapshots,section_metrics,venue_section_rollup_state · pre:20261023044500
--
-- ============================================================================
-- Migration 20261023050000 — convert raw listings into daily snapshots BEFORE
--   the 7-day purge (KANBAN A1-DATA-2 follow-up)
--
-- Operator 2026-10-23: "convert listings into snapshots before you purge".
--
-- What already exists vs what was missing (verified 2026-10-23):
--   EVO   listings_snapshots → event_metrics / section_metrics are computed AT INGEST
--         (full-book aggregates); section_metrics → venue_section_price_daily
--         (per section per day, indefinite). GAP: venue_section_rollup_state has no
--         row for 08-14..09-10, 09-15..09-21, 09-24..09-27 → those days exist only
--         in section_metrics (21 d under ladder v3).
--   GT    gotickets_listings_snapshots (130 GB) — NO aggregate at all.
--   SG    seatgeek_listings_snapshots (19 GB) — event-level seatgeek_event_metrics
--         only, no per-section history.
--   GT and SG raw tables are DELTA-stored (a row is written only when a listing is
--   new or changes price/qty), so the end-of-day book cannot be rebuilt from one
--   capture. The rollup therefore records the listings OBSERVED that day (each
--   listing's last observation of the day): count, tickets, min/p25/median/p75/max.
--
-- Adds:
--   listing_obs_section_daily  (source, event_id, day, section) — section '*' = whole
--                               event. Indefinite (never in retention_policy).
--   listing_conversion_state   (source, day) ledger; source in evo | gt | sg.
--   rollup_listing_obs_daily(source, day)  — gt | sg, one day.
--   listings_conversion_tick() — converts the OLDEST unconverted (source, day) per
--                                call (evo → rollup_venue_section_price_daily); days
--                                with no raw rows are marked done cheaply.
--   listing_rollup_frontier(source) — start of the oldest unconverted day. Ladder v3's
--                                keep_where keeps every raw row at/after it, so the
--                                purge can never delete an unconverted day.
--   cron listings_conversion_tick_5min — backfills, then keeps yesterday current.
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.listing_obs_section_daily (
  source            text        NOT NULL CHECK (source IN ('gt','sg')),
  event_id          bigint      NOT NULL,
  day               date        NOT NULL,
  section           text        NOT NULL,
  listings          integer     NOT NULL,
  tickets           integer,
  price_min         numeric,
  price_p25         numeric,
  price_median      numeric,
  price_p75         numeric,
  price_max         numeric,
  last_captured_at  timestamptz,
  computed_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, event_id, day, section)
);
CREATE INDEX IF NOT EXISTS listing_obs_section_daily_event_day
  ON public.listing_obs_section_daily (event_id, day);
COMMENT ON TABLE public.listing_obs_section_daily IS
  'Daily conversion of DELTA-stored raw listings (gt = gotickets_listings_snapshots, sg = seatgeek_listings_snapshots): listings observed that day, last observation per listing. section ''*'' = whole event; event_id < 0 = SG event not yet mapped to TEvo (-sg_event_id). Prices: gt all_in_price, sg retail_price_all_in. Indefinite (mig 20261023050000).';
ALTER TABLE public.listing_obs_section_daily ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.listing_obs_section_daily FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.listing_conversion_state (
  source         text        NOT NULL CHECK (source IN ('evo','gt','sg')),
  day            date        NOT NULL,
  raw_present    boolean     NOT NULL,
  rows_upserted  integer     NOT NULL DEFAULT 0,
  duration_ms    integer,
  processed_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, day)
);
COMMENT ON TABLE public.listing_conversion_state IS
  'Which raw-listing days have been converted to the daily layer (evo → venue_section_price_daily, gt/sg → listing_obs_section_daily). listing_rollup_frontier() reads it (mig 20261023050000).';
ALTER TABLE public.listing_conversion_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.listing_conversion_state FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.rollup_listing_obs_daily(p_source text, p_day date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_from timestamptz := p_day::timestamptz;
  v_to   timestamptz := (p_day + 1)::timestamptz;
  v_n    integer := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: rollup_listing_obs_daily is service-only' USING ERRCODE='42501';
  END IF;

  IF p_source = 'gt' THEN
    INSERT INTO public.listing_obs_section_daily AS d
      (source, event_id, day, section, listings, tickets, price_min, price_p25, price_median,
       price_p75, price_max, last_captured_at, computed_at)
    WITH obs AS (
      SELECT DISTINCT ON (g.tevo_event_id, g.gt_listing_id)
             g.tevo_event_id AS event_id,
             coalesce(nullif(btrim(g.section), ''), '?') AS section,
             g.quantity, g.all_in_price AS price, g.captured_at
        FROM public.gotickets_listings_snapshots g
       WHERE g.captured_at >= v_from AND g.captured_at < v_to
         AND g.tevo_event_id IS NOT NULL AND g.all_in_price > 0
       ORDER BY g.tevo_event_id, g.gt_listing_id, g.captured_at DESC
    )
    SELECT 'gt', event_id, p_day, coalesce(section, '*'), count(*), sum(quantity)::int,
           min(price),
           round(percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric, 2),
           round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY price)::numeric, 2),
           round(percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric, 2),
           max(price), max(captured_at), now()
      FROM obs
     GROUP BY GROUPING SETS ((event_id, section), (event_id))
    ON CONFLICT (source, event_id, day, section) DO UPDATE SET
      listings = EXCLUDED.listings, tickets = EXCLUDED.tickets,
      price_min = EXCLUDED.price_min, price_p25 = EXCLUDED.price_p25,
      price_median = EXCLUDED.price_median, price_p75 = EXCLUDED.price_p75,
      price_max = EXCLUDED.price_max, last_captured_at = EXCLUDED.last_captured_at,
      computed_at = now();
  ELSIF p_source = 'sg' THEN
    INSERT INTO public.listing_obs_section_daily AS d
      (source, event_id, day, section, listings, tickets, price_min, price_p25, price_median,
       price_p75, price_max, last_captured_at, computed_at)
    WITH obs AS (
      -- Most SG raw rows carry only sg_event_id: resolve through sg_events_canonical;
      -- still-unmapped events are kept under -sg_event_id so no day is lost.
      SELECT DISTINCT ON (s.sg_event_id, s.sglid)
             coalesce(s.tevo_event_id,
                      (SELECT c.tevo_event_id FROM public.sg_events_canonical c
                        WHERE c.sg_event_id = s.sg_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1),
                      -s.sg_event_id) AS event_id,
             coalesce(nullif(btrim(s.section), ''), '?') AS section,
             s.quantity, coalesce(s.retail_price_all_in, s.broadcast_price) AS price, s.captured_at
        FROM public.seatgeek_listings_snapshots s
       WHERE s.captured_at >= v_from AND s.captured_at < v_to
         AND s.sg_event_id IS NOT NULL
         AND coalesce(s.retail_price_all_in, s.broadcast_price) > 0
       ORDER BY s.sg_event_id, s.sglid, s.captured_at DESC
    )
    SELECT 'sg', event_id, p_day, coalesce(section, '*'), count(*), sum(quantity)::int,
           min(price),
           round(percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric, 2),
           round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY price)::numeric, 2),
           round(percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric, 2),
           max(price), max(captured_at), now()
      FROM obs
     GROUP BY GROUPING SETS ((event_id, section), (event_id))
    ON CONFLICT (source, event_id, day, section) DO UPDATE SET
      listings = EXCLUDED.listings, tickets = EXCLUDED.tickets,
      price_min = EXCLUDED.price_min, price_p25 = EXCLUDED.price_p25,
      price_median = EXCLUDED.price_median, price_p75 = EXCLUDED.price_p75,
      price_max = EXCLUDED.price_max, last_captured_at = EXCLUDED.last_captured_at,
      computed_at = now();
  ELSE
    RAISE EXCEPTION 'rollup_listing_obs_daily: unknown source % (gt | sg)', p_source USING ERRCODE='22023';
  END IF;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.rollup_listing_obs_daily(text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rollup_listing_obs_daily(text, date) TO service_role;

-- Oldest raw day per source (index-backed min()).
CREATE OR REPLACE FUNCTION public._listing_raw_first_day(p_source text)
RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT (CASE p_source
            WHEN 'evo' THEN (SELECT min(captured_at) FROM public.section_metrics)
            WHEN 'gt'  THEN (SELECT min(captured_at) FROM public.gotickets_listings_snapshots)
            WHEN 'sg'  THEN (SELECT min(captured_at) FROM public.seatgeek_listings_snapshots)
          END AT TIME ZONE 'utc')::date;
$$;
REVOKE ALL ON FUNCTION public._listing_raw_first_day(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._listing_raw_first_day(text) TO service_role;

-- Start of the oldest day (UTC) not yet converted; today when fully caught up.
-- Ladder v3 keep_where: `t.captured_at >= public.listing_rollup_frontier('gt')`.
CREATE OR REPLACE FUNCTION public.listing_rollup_frontier(p_source text)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
           (SELECT min(gs::date)
              FROM generate_series(public._listing_raw_first_day(p_source),
                                   (now() AT TIME ZONE 'utc')::date - 1, interval '1 day') gs
             WHERE NOT EXISTS (SELECT 1 FROM public.listing_conversion_state c
                                WHERE c.source = p_source AND c.day = gs::date)),
           (now() AT TIME ZONE 'utc')::date
         )::timestamp AT TIME ZONE 'utc';
$$;
REVOKE ALL ON FUNCTION public.listing_rollup_frontier(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.listing_rollup_frontier(text) TO service_role;

-- One unit of work per call: the oldest unconverted (source, day), sources taken in turn.
CREATE OR REPLACE FUNCTION public.listings_conversion_tick()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src   text;
  v_day   date;
  v_from  timestamptz;
  v_raw   boolean;
  v_n     integer := 0;
  v_t0    timestamptz;
  v_skips integer := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: listings_conversion_tick is service-only' USING ERRCODE='42501';
  END IF;

  -- Empty days are cheap: mark up to 60 of them per call before doing one heavy day.
  LOOP
    SELECT s.src, f.d INTO v_src, v_day
      FROM unnest(ARRAY['evo','gt','sg']) AS s(src)
      CROSS JOIN LATERAL (
        SELECT (public.listing_rollup_frontier(s.src) AT TIME ZONE 'utc')::date AS d) f
     WHERE f.d < (now() AT TIME ZONE 'utc')::date
     ORDER BY f.d, s.src
     LIMIT 1;
    IF v_src IS NULL THEN
      RETURN 'caught up';
    END IF;

    v_from := v_day::timestamp AT TIME ZONE 'utc';
    v_raw := CASE v_src
      WHEN 'evo' THEN EXISTS (SELECT 1 FROM public.section_metrics
                               WHERE captured_at >= v_from AND captured_at < v_from + interval '1 day')
      WHEN 'gt'  THEN EXISTS (SELECT 1 FROM public.gotickets_listings_snapshots
                               WHERE captured_at >= v_from AND captured_at < v_from + interval '1 day')
      WHEN 'sg'  THEN EXISTS (SELECT 1 FROM public.seatgeek_listings_snapshots
                               WHERE captured_at >= v_from AND captured_at < v_from + interval '1 day')
    END;

    -- EVO days the existing rollup already completed need no re-run.
    IF v_src = 'evo' AND v_raw AND EXISTS (
         SELECT 1 FROM public.venue_section_rollup_state st
          WHERE st.snapshot_date = v_day AND st.rows_upserted > 0
            AND st.processed_at >= v_day + interval '1 day') THEN
      INSERT INTO public.listing_conversion_state (source, day, raw_present, rows_upserted)
      SELECT 'evo', v_day, true, st.rows_upserted FROM public.venue_section_rollup_state st
       WHERE st.snapshot_date = v_day
      ON CONFLICT (source, day) DO NOTHING;
      v_skips := v_skips + 1;
    ELSIF NOT v_raw THEN
      INSERT INTO public.listing_conversion_state (source, day, raw_present, rows_upserted)
      VALUES (v_src, v_day, false, 0)
      ON CONFLICT (source, day) DO NOTHING;
      v_skips := v_skips + 1;
    ELSE
      v_t0 := clock_timestamp();
      IF v_src = 'evo' THEN
        v_n := public.rollup_venue_section_price_daily(v_day);
      ELSE
        v_n := public.rollup_listing_obs_daily(v_src, v_day);
      END IF;
      INSERT INTO public.listing_conversion_state (source, day, raw_present, rows_upserted, duration_ms)
      VALUES (v_src, v_day, true, v_n, (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int)
      ON CONFLICT (source, day) DO UPDATE SET rows_upserted = EXCLUDED.rows_upserted,
        duration_ms = EXCLUDED.duration_ms, processed_at = now();
      RETURN format('%s %s: %s rows (%s empty/pre-done days marked)', v_src, v_day, v_n, v_skips);
    END IF;

    EXIT WHEN v_skips >= 60;
    v_src := NULL;
  END LOOP;
  RETURN format('%s empty/pre-done days marked', v_skips);
END $$;
REVOKE ALL ON FUNCTION public.listings_conversion_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.listings_conversion_tick() TO service_role;

SELECT cron.schedule('listings_conversion_tick_5min', '*/5 * * * *',
  $c$DO $b$ BEGIN IF NOT public.cron_try_lock('listings_conversion_tick') THEN RETURN; END IF; PERFORM public.listings_conversion_tick(); END $b$;$c$);

-- ============================================================================
-- VERIFY:
--   SELECT source, min(day), max(day), count(*), sum(rows_upserted) FROM public.listing_conversion_state GROUP BY 1;
--   SELECT s, public.listing_rollup_frontier(s) FROM unnest(ARRAY['evo','gt','sg']) s;   -- → today when caught up
-- Runs under the postgres role's 900 s statement_timeout (one heavy day per call).
-- ROLLBACK: SELECT cron.unschedule('listings_conversion_tick_5min'); the tables are additive.
-- ============================================================================
