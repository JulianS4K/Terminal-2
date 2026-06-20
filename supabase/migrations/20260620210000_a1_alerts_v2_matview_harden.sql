-- Migration 20260620210000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — alerts v2 performance hardening + enable the cron)
-- Touches W: CREATE MATERIALIZED VIEW mv_event_price_vol (+unique idx);
--            REPLACE VIEW v_event_price_vol -> reads the matview;
--            cron mv_event_price_vol_refresh; ENABLE cron compute_alerts_tick_15min
-- Touches R: public.event_metrics, public.v_event_velocity_windows
-- Pre-reqs: v_event_price_vol (mig 20260620200000), compute_alerts_tick v2
-- Already applied to prod · via MCP 2026-06-20. Verified: refresh cron 16.3s, tick reads
-- ~11.5s (was failing at 120s on the parked arb view); compute_alerts_tick_15min ENABLED.
--
-- The v2 tick scanned 14d of event_metrics live (v_event_price_vol ~9-30s cold) every run,
-- pushing the tick toward its 120s slot. Real systems precompute indicators off the hot
-- path: materialize the per-event vol stats into mv_event_price_vol, refreshed on its own
-- ~15-min cron, and repoint the v_event_price_vol view at it so the tick reads it instantly.
-- Then enable compute_alerts_tick_15min.
-- ============================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS public.mv_event_price_vol AS
WITH up AS (
  SELECT id FROM public.events
  WHERE NULLIF(occurs_at_local,'')::timestamptz BETWEEN now() AND now() + interval '60 days'
),
daily AS (
  SELECT DISTINCT ON (m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date)
    m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date AS d, m.getin_price
  FROM public.event_metrics m JOIN up ON up.id = m.event_id
  WHERE m.captured_at > now() - interval '14 days' AND m.getin_price > 0
  ORDER BY m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date, m.captured_at DESC
),
chg AS (
  SELECT event_id, d, getin_price,
    (getin_price - lag(getin_price) OVER w) / NULLIF(lag(getin_price) OVER w, 0) AS dchg
  FROM daily WINDOW w AS (PARTITION BY event_id ORDER BY d)
),
stats AS (
  SELECT event_id,
    count(*) FILTER (WHERE dchg IS NOT NULL) AS days_n,
    stddev_samp(dchg) AS sigma_daily,
    max(getin_price) AS peak_14d, min(getin_price) AS low_14d,
    max(getin_price) FILTER (WHERE d < (now() AT TIME ZONE 'UTC')::date) AS peak_prior,
    min(getin_price) FILTER (WHERE d < (now() AT TIME ZONE 'UTC')::date) AS low_prior
  FROM chg GROUP BY event_id
)
SELECT
  vw.tevo_event_id, vw.name, vw.venue_name, vw.occurs_at_local,
  vw.tevo_getin_now AS getin_now, vw.tevo_median_now AS median_now, vw.tevo_tix_now AS tix_now,
  vw.tevo_getin_d1h_pct AS getin_d1h_pct, vw.tevo_getin_d24h_pct AS getin_d24h_pct,
  s.days_n, round((s.sigma_daily*100)::numeric,2) AS sigma_daily_pct,
  s.peak_14d, s.low_14d, s.peak_prior, s.low_prior,
  round((vw.tevo_getin_d24h_pct/100.0 / NULLIF(s.sigma_daily,0))::numeric, 2) AS move_z_24h,
  greatest(round(((s.peak_14d - vw.tevo_getin_now)/NULLIF(s.peak_14d,0)*100)::numeric,1), 0) AS drawdown_from_peak_pct,
  (s.days_n >= 7 AND vw.tevo_getin_now > s.peak_prior) AS breakout_up,
  (s.days_n >= 7 AND vw.tevo_getin_now < s.low_prior)  AS breakout_down
FROM stats s
JOIN public.v_event_velocity_windows vw ON vw.tevo_event_id = s.event_id
WHERE vw.tevo_getin_now > 0;

-- unique index required for REFRESH ... CONCURRENTLY (one row per event)
CREATE UNIQUE INDEX IF NOT EXISTS mv_event_price_vol_pk ON public.mv_event_price_vol (tevo_event_id);
GRANT SELECT ON public.mv_event_price_vol TO authenticated, service_role;
COMMENT ON MATERIALIZED VIEW public.mv_event_price_vol IS
  'Precomputed per-event volatility stats (refreshed ~15m by mv_event_price_vol_refresh) so '
  'compute_alerts_tick reads instantly instead of scanning event_metrics live. A1 · mig 20260620210000.';

-- Repoint the view at the matview (same columns) so the tick + interactive callers get the fast path.
CREATE OR REPLACE VIEW public.v_event_price_vol AS SELECT * FROM public.mv_event_price_vol;
GRANT SELECT ON public.v_event_price_vol TO authenticated, service_role;

-- Refresh cron: every 15 min at :08/:23/:38/:53 (a few min before the :11/:26/:41/:56 alert tick).
SELECT cron.schedule('mv_event_price_vol_refresh', '8-59/15 * * * *', $cron$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('mv_event_price_vol_refresh') THEN RETURN; END IF;
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_event_price_vol;
END $body$;
$cron$);
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES ('mv_event_price_vol_refresh', ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 15, 15, 96, true,
        'Refresh precomputed alert volatility stats. Every 15m, a few min before the alert tick. A1 mig 20260620210000.')
ON CONFLICT (jobname) DO NOTHING;

-- Enable the alerts tick now that it reads the precomputed matview.
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='compute_alerts_tick_15min'), active := true);
