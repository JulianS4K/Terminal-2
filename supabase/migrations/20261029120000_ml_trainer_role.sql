-- Migration 20261029120000 · level:security · lane:A1 (DB security + ML) · writes:ml_trainer(role,new),ml_io(schema,new),ml_io.sales_train()(new),ml_io.predict_input()(new),ml_io.form_train()(new),ml_io.form_predict()(new),ml_io.save_run()(new) · reads:v_ml_knicks_sales_train,v_ml_knicks_predict_input,v_ml_knicks_form_train,v_ml_knicks_form_predict · pre:20261028210000
--
-- ============================================================================
-- A least-privilege login for the Render training job (`ml-knicks-price-train`), so it no
-- longer needs the service-role key.
--
-- WHY: the job reads four views and writes ml_model_runs + ml_price_predictions. With the
-- service-role key, a leak of the job's settings is a leak of the whole database. With this
-- role, the worst a leaked password can do is read Knicks training data and add model runs.
--
-- SHAPE
--   * Role `ml_trainer`: LOGIN, no table or view grants. Its only way in is the five
--     functions in schema `ml_io` (not exposed by PostgREST: its exposed schemas are the
--     default public + graphql_public).
--   * The functions are SECURITY DEFINER because the four views are security_invoker: they
--     read events, SeatGeek sales and ESPN snapshots as the caller, which a narrow role must
--     not be granted. A definer function runs the view as its owner instead.
--   * No current_user body guard: inside a SECURITY DEFINER function current_user is the
--     owner, so that guard never fires (mig 20261021163000). The REVOKE / GRANT below is the
--     gate; the schema is also closed to PUBLIC.
--   * Like every role it keeps what PUBLIC is granted (USAGE on schema public, EXECUTE on
--     functions granted to PUBLIC) — the same reach as the public anon key, nothing more.
--
-- AFTER APPLYING (operator, SQL editor — the password never goes in git):
--   ALTER ROLE ml_trainer PASSWORD '<a new random password>';
--   Render → ml-knicks-price-train → Environment:
--     ML_TRAINER_DATABASE_URL =
--       postgresql://ml_trainer.hzrizjeaxlqcxfrtczpq:<password>@aws-0-us-east-2.pooler.supabase.com:5432/postgres
--   then remove SUPABASE_SERVICE_ROLE_KEY from the job if it was ever added.
-- Rollback: DROP SCHEMA ml_io CASCADE; DROP ROLE ml_trainer;
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ml_trainer') THEN
    CREATE ROLE ml_trainer LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
      CONNECTION LIMIT 3;
  END IF;
END $$;
COMMENT ON ROLE ml_trainer IS
  'Render job ml-knicks-price-train. No table grants: EXECUTE on the ml_io functions only (mig 20261029120000).';
ALTER ROLE ml_trainer SET statement_timeout = '5min';
ALTER ROLE ml_trainer SET idle_in_transaction_session_timeout = '2min';

CREATE SCHEMA IF NOT EXISTS ml_io;
REVOKE ALL ON SCHEMA ml_io FROM PUBLIC;
GRANT USAGE ON SCHEMA ml_io TO ml_trainer, service_role;
COMMENT ON SCHEMA ml_io IS 'The ml_trainer role''s whole interface (mig 20261029120000).';

-- reads: one jsonb object per view row, the same shape PostgREST returns ---------
CREATE OR REPLACE FUNCTION ml_io.sales_train()
RETURNS SETOF jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(v) FROM public.v_ml_knicks_sales_train v ORDER BY v.sale_key, v.source
$$;

CREATE OR REPLACE FUNCTION ml_io.predict_input()
RETURNS SETOF jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(v) FROM public.v_ml_knicks_predict_input v
$$;

CREATE OR REPLACE FUNCTION ml_io.form_train()
RETURNS SETOF jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(v) FROM public.v_ml_knicks_form_train v
$$;

CREATE OR REPLACE FUNCTION ml_io.form_predict()
RETURNS SETOF jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(v) FROM public.v_ml_knicks_form_predict v
$$;

-- write: one run and its predictions, in one transaction ---------------------------
-- Only the columns the script sends are taken; run_id, trained_at and created_at stay
-- with their defaults, so a caller cannot overwrite or backdate an earlier run.
CREATE OR REPLACE FUNCTION ml_io.save_run(p_run jsonb, p_predictions jsonb DEFAULT '[]'::jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_run_id bigint;
BEGIN
  IF jsonb_typeof(p_run) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'save_run: p_run must be a json object' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(coalesce(p_predictions, '[]'::jsonb)) <> 'array'
     OR jsonb_array_length(coalesce(p_predictions, '[]'::jsonb)) > 5000 THEN
    RAISE EXCEPTION 'save_run: p_predictions must be an array of at most 5000 rows' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.ml_model_runs (model, status, n_train, n_test, games_train, games_test,
                                    metrics, feature_spec, coef, note)
  SELECT r.model, coalesce(r.status, 'ok'), r.n_train, r.n_test, r.games_train, r.games_test,
         r.metrics, r.feature_spec, r.coef, r.note
    FROM jsonb_populate_record(NULL::public.ml_model_runs, p_run) r
  RETURNING run_id INTO v_run_id;

  INSERT INTO public.ml_price_predictions (run_id, sg_event_id, tevo_event_id, zone, occurs_at,
                                           hours_to_event, predicted_price, p10, p90,
                                           ctx_zone_getin, ctx_zone_median)
  SELECT v_run_id, p.sg_event_id, p.tevo_event_id, p.zone, p.occurs_at,
         p.hours_to_event, p.predicted_price, p.p10, p.p90,
         p.ctx_zone_getin, p.ctx_zone_median
    FROM jsonb_populate_recordset(NULL::public.ml_price_predictions, coalesce(p_predictions, '[]'::jsonb)) p;

  RETURN v_run_id;
END $$;

REVOKE ALL ON FUNCTION ml_io.sales_train(), ml_io.predict_input(), ml_io.form_train(),
                       ml_io.form_predict(), ml_io.save_run(jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ml_io.sales_train(), ml_io.predict_input(), ml_io.form_train(),
                          ml_io.form_predict(), ml_io.save_run(jsonb, jsonb)
  TO ml_trainer, service_role;
