-- The daily drift sweep was still firing the burst that mig 20260915000000 exists to prevent.
--
-- That migration capped event_date_reconcile_queue's DEFAULT at 8 and pointed the 30-minute tick
-- at 8. It did not touch the OTHER caller: event_catalogue_drift_scan ends with
--
--     v_queued := public.event_date_reconcile_queue(200);
--
-- an explicit argument that overrides the default outright. Running the sweep by hand at 13:41
-- queued 84 events (the 45-second internal budget, not the 200, is what stopped it) and 79 of
-- those 84 came straight back as 429. Exactly the failure the cap was added for, on a path the
-- cap never covered.
--
-- The sweep's job is DETECTION. Queueing re-pulls is a courtesy on top, and a daily job has no
-- reason to want a bigger bite than the job that runs every 30 minutes. It now calls the queue
-- with no argument at all, so there is ONE place to change the rate and no way for a caller to
-- quietly opt out of it again.
DO $do$
DECLARE
  v_src  text;
  v_args text;
  v_cfg  text[];
  v_set  text := '';
  v_kv   text;
  v_a    text;
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid), p.proconfig INTO v_src, v_args, v_cfg
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'event_catalogue_drift_scan';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'event_catalogue_drift_scan not found';
  END IF;
  IF position('event_date_reconcile_queue(200)' in v_src) = 0 THEN
    RETURN;   -- already fixed, or the call moved: leave it alone rather than guess
  END IF;

  -- Carry the function's existing SET clauses across verbatim rather than retyping search_path.
  FOREACH v_kv IN ARRAY coalesce(v_cfg, ARRAY[]::text[]) LOOP
    v_set := v_set || format(' SET %I TO %s', split_part(v_kv, '=', 1),
                             substr(v_kv, strpos(v_kv, '=') + 1));
  END LOOP;

  v_a := '  v_queued := public.event_date_reconcile_queue(200);';
  IF (length(v_src) - length(replace(v_src, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'anchor did not match exactly once';
  END IF;
  v_src := replace(v_src, v_a,
    E'  -- No argument on purpose: the rate lives in the queue''s own default (mig 20260915000000).\n'
    '  -- Passing a number here is how this sweep kept firing 80+ SeatGeek calls at once and\n'
    '  -- taking the whole account to 429 while the 30-minute tick sat politely at 8.\n'
    '  v_queued := public.event_date_reconcile_queue();');

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.event_catalogue_drift_scan(%s) RETURNS jsonb '
    'LANGUAGE plpgsql SECURITY DEFINER%s AS %s',
    v_args, v_set, quote_literal(v_src));
END
$do$;
