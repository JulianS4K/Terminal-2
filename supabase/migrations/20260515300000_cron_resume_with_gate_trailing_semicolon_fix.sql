-- Migration 20260515300000 · level:admin · lane:Audit/Push · writes:cron_resume_with_gate() fn · pre:20260515290000
-- Bug surfaced by C1 in bot_chat 128 (2026-05-15 03:54 UTC): 4 crons failed with
-- "syntax error at or near ;" LINE 4: ; END $body$;
--
-- Root cause: cron_resume_with_gate() used `trim(both ' ;' from v_cmd)` to strip
-- trailing semicolons, but trim() stops at the first char NOT in the set. Multi-line
-- snapshot commands end with ");\n" — the \n blocks the trim from reaching the ;.
-- Then format() appends another ; before END, producing ");\n; END $body$;"
-- which Postgres parses as an empty statement between the inner ; and END.
--
-- Fix: switch to regex_replace which handles whitespace + semicolons regardless of
-- which order they appear in. Pattern `[\s;]+$` strips trailing whitespace AND
-- semicolons together, and the symmetric `^[\s;]+` strips leading.
--
-- Affected crons (re-resumed after this patch landed):
--   - backfill-event-configurations-5min
--   - collect-listings-0-24h
--   - crawl-espn-team-assets-3min
--   - crawl-venues-and-performers-3min
--
-- ## Already applied to prod  Applied via MCP 2026-05-15.

CREATE OR REPLACE FUNCTION public.cron_resume_with_gate(p_jobname text)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_schedule  text;
  v_cmd       text;
  v_wrapped   text;
  v_new_jobid bigint;
  v_inner     text;
BEGIN
  SELECT schedule, command INTO v_schedule, v_cmd
  FROM public.cron_pause_state_20260514 WHERE jobname = p_jobname;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'jobname % not in cron_pause_state_20260514 snapshot', p_jobname;
  END IF;

  IF v_cmd ~* '^\s*DO\s+\$' THEN
    RAISE EXCEPTION 'cron_resume_with_gate cannot auto-wrap a DO-block command for %. Manual wrap required. Original command: %', p_jobname, v_cmd;
  END IF;

  -- Strip leading/trailing whitespace + semicolons via regex.
  -- trim(both ' ;' from ...) used previously DOES NOT WORK because trim() stops
  -- at the first char not in the set, and snapshot commands end with ');\n'.
  v_inner := regexp_replace(v_cmd, '^[\s;]+',    '', '');
  v_inner := regexp_replace(v_inner, '[\s;]+$', '', '');
  v_inner := regexp_replace(v_inner, '^\s*SELECT\s+\*\s+FROM\s+', 'PERFORM ', 'i');
  v_inner := regexp_replace(v_inner, '^\s*SELECT\s+',             'PERFORM ', 'i');

  v_wrapped := format(
    $wrap$DO $body$ BEGIN IF NOT public.cron_should_fire(%L) THEN RETURN; END IF; %s; END $body$;$wrap$,
    p_jobname, v_inner);

  PERFORM cron.unschedule(p_jobname) FROM cron.job WHERE jobname = p_jobname;
  v_new_jobid := cron.schedule(p_jobname, v_schedule, v_wrapped);

  RETURN format('jobid=%s schedule=%I wrapped=true', v_new_jobid, v_schedule);
END $func$;
