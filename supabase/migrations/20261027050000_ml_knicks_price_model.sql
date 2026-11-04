-- Migration 20261027050000 · level:feature · lane:A1 (data plane — ML price predictor) · writes:ml_model_runs(new),ml_price_predictions(new),v_ml_knicks_predict_input(new),v_ml_knicks_price_latest(new),retention_policy(zone_metrics row: exempt) · reads:ml_knicks_games,ml_knicks_sales,zone_metrics,event_listing_snapshot_daily,performer_metrics_daily · pre:20261027010830 (ml_knicks catalogue)
--
-- ============================================================================
-- Knicks price predictor — storage for the Render training job + zone_metrics exemption
--
-- Operator 2026-10-27: "render training job, exempt zone_metrics, backfill last season".
--
--   ml_model_runs          one row per training run (metrics, coefficients, feature spec).
--   ml_price_predictions   per run: predicted sale price per upcoming Knicks home game × zone,
--                          with a p10–p90 band from the held-out residuals.
--   v_ml_knicks_predict_input  what the job scores: every upcoming regular-season / Cup home
--                          game × zone the market currently lists, with the same context
--                          features the catalogue stores on each sale (zone_metrics ≤ 36 h,
--                          event_listing_snapshot_daily ≤ 2 days, Knicks home performer day).
--   v_ml_knicks_price_latest   the latest run's predictions joined to the current zone market.
--   The job (scripts/ml/train_knicks_price.py, Render cron `ml-knicks-price-train`) reads
--   v_ml_knicks_sales_train + v_ml_knicks_predict_input and writes the two tables with the
--   service-role key. Nothing upstream is called.
--
--   zone_metrics retention EXEMPT: the predictor needs each zone's market curve over the whole
--   season (the sale-time context the catalogue joins). The table has no policy today; this
--   adds a DISABLED row marked never_purge so the retention guard trigger refuses any later
--   attempt to enable it (ladder v3, 20261023044500, no longer adds its 60 d row).
--
-- ROLLBACK: DROP VIEW v_ml_knicks_price_latest, v_ml_knicks_predict_input;
--           DROP TABLE ml_price_predictions, ml_model_runs;
--           DELETE FROM retention_policy WHERE table_name = 'zone_metrics';
-- ============================================================================

SET LOCAL lock_timeout = '10s';

-- ---------------------------------------------------------------------------
-- zone_metrics: never purged (ML training context)
-- ---------------------------------------------------------------------------
INSERT INTO public.retention_policy (table_name, ts_column, keep_days, enabled, priority, notes, meta)
VALUES ('zone_metrics', 'captured_at', 36500, false, 100,
        'EXEMPT (operator 2026-10-27): per-zone market curve is the price predictor''s training context. Kept forever.',
        jsonb_build_object('never_purge', true,
                           'directive', 'operator 2026-10-27: exempt zone_metrics from retention (ML price predictor)'))
ON CONFLICT (table_name) DO UPDATE
   SET enabled = false, keep_days = 36500, notes = EXCLUDED.notes,
       meta = coalesce(public.retention_policy.meta, '{}'::jsonb) || EXCLUDED.meta, updated_at = now();

-- ---------------------------------------------------------------------------
-- Runs + predictions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ml_model_runs (
  run_id        bigserial   PRIMARY KEY,
  model         text        NOT NULL,                 -- e.g. 'knicks_price_ridge_v1'
  trained_at    timestamptz NOT NULL DEFAULT now(),
  n_train       integer,
  n_test        integer,
  games_train   integer,
  games_test    integer,
  metrics       jsonb,                                -- held-out errors vs baselines
  feature_spec  jsonb,                                -- categories, numeric means/sds, lambda
  coef          jsonb,                                -- name → coefficient
  status        text        NOT NULL DEFAULT 'ok',    -- ok | skipped | failed
  note          text
);
CREATE INDEX IF NOT EXISTS ml_model_runs_model_trained_idx ON public.ml_model_runs (model, trained_at DESC);

CREATE TABLE IF NOT EXISTS public.ml_price_predictions (
  run_id          bigint      NOT NULL REFERENCES public.ml_model_runs(run_id) ON DELETE CASCADE,
  sg_event_id     bigint      NOT NULL,
  tevo_event_id   bigint,
  zone            text        NOT NULL,
  occurs_at       timestamptz,
  hours_to_event  numeric,
  predicted_price numeric     NOT NULL,              -- per ticket, SeatGeek broadcast basis
  p10             numeric,
  p90             numeric,
  ctx_zone_getin  numeric,
  ctx_zone_median numeric,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, sg_event_id, zone)
);

ALTER TABLE public.ml_model_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ml_price_predictions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ml_model_runs, public.ml_price_predictions FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.ml_model_runs_run_id_seq FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ml_model_runs, public.ml_price_predictions TO service_role;
GRANT USAGE ON SEQUENCE public.ml_model_runs_run_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- What the job scores: upcoming home games × zones listed now
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_ml_knicks_predict_input
WITH (security_invoker = true) AS
SELECT g.sg_event_id, g.tevo_event_id, g.season, g.game_type, g.opponent, g.occurs_at,
       round((extract(epoch FROM g.occurs_at - now()) / 3600.0)::numeric, 2) AS hours_to_event,
       extract(isodow FROM g.occurs_at AT TIME ZONE 'America/New_York')::int AS game_dow,
       z.zone,
       z.getin_price   AS ctx_zone_getin,
       z.retail_p25    AS ctx_zone_p25,
       z.retail_median AS ctx_zone_median,
       z.tickets_count AS ctx_zone_tickets,
       z.owned_share   AS ctx_zone_owned_share,
       z.captured_at   AS ctx_zone_at,
       ctx.eg  AS ctx_evo_getin, ctx.em AS ctx_evo_median, ctx.sgg AS ctx_sg_getin, ctx.sgm AS ctx_sg_median,
       pf.getin_median AS ctx_perf_home_getin, pf.price_median AS ctx_perf_home_median
  FROM public.ml_knicks_games g
  JOIN LATERAL (
    SELECT DISTINCT ON (zm.zone) zm.zone, zm.getin_price, zm.retail_p25, zm.retail_median,
           zm.tickets_count, zm.owned_share, zm.captured_at
      FROM public.zone_metrics zm
     WHERE zm.event_id = g.tevo_event_id AND zm.captured_at > now() - interval '36 hours'
       AND zm.zone IS NOT NULL
     ORDER BY zm.zone, zm.captured_at DESC) z ON true
  LEFT JOIN LATERAL (
    SELECT avg(d.evo_retail_getin) eg, avg(d.evo_retail_median) em, avg(d.sg_all_getin) sgg, avg(d.sg_all_median) sgm
      FROM public.event_listing_snapshot_daily d
     WHERE d.event_id = g.tevo_event_id
       AND d.snapshot_date = (SELECT max(d2.snapshot_date) FROM public.event_listing_snapshot_daily d2
                               WHERE d2.event_id = g.tevo_event_id AND d2.snapshot_date >= current_date - 2)) ctx ON true
  LEFT JOIN LATERAL (
    SELECT p.getin_median, p.price_median
      FROM public.performer_metrics_daily p
     WHERE p.performer_id = 16303 AND p.split = 'home' AND p.snapshot_date >= current_date - 2
     ORDER BY p.snapshot_date DESC LIMIT 1) pf ON true
 WHERE g.game_type IN ('regular', 'cup')
   AND g.occurs_at > now()
   AND g.tevo_event_id IS NOT NULL;
REVOKE ALL ON public.v_ml_knicks_predict_input FROM anon, authenticated;
GRANT SELECT ON public.v_ml_knicks_predict_input TO service_role;

CREATE OR REPLACE VIEW public.v_ml_knicks_price_latest
WITH (security_invoker = true) AS
SELECT r.run_id, r.model, r.trained_at, p.sg_event_id, p.tevo_event_id, g.opponent, p.occurs_at, p.zone,
       p.predicted_price, p.p10, p.p90, p.ctx_zone_getin, p.ctx_zone_median,
       round(p.predicted_price / nullif(p.ctx_zone_getin, 0), 3) AS predicted_vs_zone_getin
  FROM public.ml_price_predictions p
  JOIN public.ml_model_runs r ON r.run_id = p.run_id
  LEFT JOIN public.ml_knicks_games g ON g.sg_event_id = p.sg_event_id
 WHERE r.run_id = (SELECT max(run_id) FROM public.ml_model_runs
                    WHERE model = 'knicks_price_ridge_v1' AND status = 'ok');
REVOKE ALL ON public.v_ml_knicks_price_latest FROM anon, authenticated;
GRANT SELECT ON public.v_ml_knicks_price_latest TO service_role;

GRANT SELECT ON public.v_ml_knicks_sales_train TO service_role;

-- ============================================================================
-- VERIFY: SELECT enabled, meta FROM retention_policy WHERE table_name = 'zone_metrics';
--         SELECT count(*), count(DISTINCT sg_event_id) FROM v_ml_knicks_predict_input;
--         (after the job) SELECT run_id, status, metrics FROM ml_model_runs ORDER BY run_id DESC LIMIT 3;
-- ============================================================================
