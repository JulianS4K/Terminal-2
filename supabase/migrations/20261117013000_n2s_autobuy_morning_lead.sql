-- Migration 20261117013000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,n2s_autobuy_event_lead,n2s_autobuy_enqueue_trg,n2s_autobuy_job_json,n2s_td_sub_report_capture · reads:n2s_autobuy_exec · pre:20261116180000,20261113470000
--
-- Morning events keep the 12-hour lead.
--
-- Operator 2026-11-17 ~01:34 UTC: "lower the event lead to 6 hours" (n2s_autobuy_config.
-- min_event_lead 12 h -> 6 h, a config value, set then) "but exclude events before noon est".
-- Asked which rule, the operator chose "Keep 12 h for them": an event that starts before 12:00
-- Eastern still needs 12 hours of lead, so a morning event is never bought overnight. The 6-hour
-- lead applies to events that start at noon Eastern or later.
--
--   1. n2s_autobuy_config.morning_before_et (time, default 12:00) and morning_event_lead
--      (interval, default 12 h).
--   2. n2s_autobuy_event_lead(config, start): the lead an event needs. A start before
--      morning_before_et in America/New_York needs GREATEST(min_event_lead, morning_event_lead);
--      any other start needs min_event_lead. An unknown start needs the greater of the two.
--   3. The three places that read min_event_lead read it instead (md5-guarded anchor patches on
--      the prod text, one anchor each):
--        - n2s_autobuy_enqueue_trg: the event_within_24h reason (20261116180000 text);
--        - n2s_autobuy_job_json: the min_event_lead_s handed to the live worker and to the one
--          queue, which the worker checks again against EVO's / GoTickets' own event time
--          (core/n2s_autobuy_live: ticket_group_checks, buy_guards) — no Python change;
--        - n2s_td_sub_report_capture: its event_within_lead reason, so the TicketsData report
--          keeps showing what the auto-buyer would do.
--
-- rollback: UPDATE n2s_autobuy_config SET morning_event_lead = min_event_lead (the rule then
--           changes nothing); full: re-create the three functions from their prod text
--           (md5s below) and drop n2s_autobuy_event_lead and the two columns.

-- ── 1. the setting ─────────────────────────────────────────────────────────
ALTER TABLE public.n2s_autobuy_config
  ADD COLUMN IF NOT EXISTS morning_before_et  time     NOT NULL DEFAULT '12:00',
  ADD COLUMN IF NOT EXISTS morning_event_lead interval NOT NULL DEFAULT '12 hours';
COMMENT ON COLUMN public.n2s_autobuy_config.morning_event_lead IS
  'Lead an event that starts before morning_before_et (America/New_York) needs, when greater than min_event_lead. Operator 2026-11-17: 6 h lead, but events before noon ET keep 12 h. 20261117013000.';

-- ── 2. the lead an event needs ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_autobuy_event_lead(c public.n2s_autobuy_config, p_start timestamptz)
 RETURNS interval
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
           WHEN p_start IS NULL
             OR (p_start AT TIME ZONE 'America/New_York')::time < c.morning_before_et
           THEN GREATEST(c.min_event_lead, c.morning_event_lead)
           ELSE c.min_event_lead
         END;
$function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_event_lead(public.n2s_autobuy_config, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_event_lead(public.n2s_autobuy_config, timestamptz) TO service_role;

-- ── 3. the three readers ───────────────────────────────────────────────────
DO $do$
DECLARE d text; n int;
  t_enq  CONSTANT text := $a$IF v_start < now() + c.min_event_lead THEN r := r || 'event_within_24h'::text; END IF;$a$;
  t_job  CONSTANT text := $a$'min_event_lead_s', extract(epoch FROM c.min_event_lead)::int,$a$;
  t_td   CONSTANT text := $a$IF v_start < now() + c.min_event_lead             THEN v_reasons := array_append(v_reasons, 'event_within_lead'); END IF;$a$;
BEGIN
  -- the enqueue trigger
  d := pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure);
  IF md5(d) <> '2b059ad98a9156dcba70534ae4b80438' THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg drifted from 20261116180000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, t_enq, ''))) / length(t_enq);
  IF n <> 1 THEN RAISE EXCEPTION 'n2s_autobuy_enqueue_trg: % of 1 anchor found', n; END IF;
  EXECUTE replace(d, t_enq,
    $a$IF v_start < now() + public.n2s_autobuy_event_lead(c, v_start) THEN r := r || 'event_within_24h'::text; END IF;$a$);

  -- the job the live worker and the one queue get
  d := pg_get_functiondef('public.n2s_autobuy_job_json(bigint, text)'::regprocedure);
  IF md5(d) <> '6a7d44c8c1ff3fef153d4cab19a4ca79' THEN
    RAISE EXCEPTION 'n2s_autobuy_job_json drifted from 20261113470000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, t_job, ''))) / length(t_job);
  IF n <> 1 THEN RAISE EXCEPTION 'n2s_autobuy_job_json: % of 1 anchor found', n; END IF;
  EXECUTE replace(d, t_job,
    $a$'min_event_lead_s', extract(epoch FROM public.n2s_autobuy_event_lead(c, e.event_start_utc))::int,$a$);

  -- the TicketsData report
  d := pg_get_functiondef('public.n2s_td_sub_report_capture(integer[], interval)'::regprocedure);
  IF md5(d) <> 'bed4be6a4473b9c4b0f5f26f20cc854e' THEN
    RAISE EXCEPTION 'n2s_td_sub_report_capture drifted from its 2026-11-17 prod text — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, t_td, ''))) / length(t_td);
  IF n <> 1 THEN RAISE EXCEPTION 'n2s_td_sub_report_capture: % of 1 anchor found', n; END IF;
  EXECUTE replace(d, t_td,
    $a$IF v_start < now() + public.n2s_autobuy_event_lead(c, v_start) THEN v_reasons := array_append(v_reasons, 'event_within_lead'); END IF;$a$);
END $do$;
