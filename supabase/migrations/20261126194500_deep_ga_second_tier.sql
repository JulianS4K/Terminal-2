-- A second GA step: over ga_slow2_min_tickets GA tickets, read every ga_slow2_every.
-- Operator 2026-11-26: "change it to every 4 hours if it's over 400 tickets", then chose the
-- tier shape over a flat replacement once the arithmetic was laid out.
--
-- WHAT THIS IS AND IS NOT WORTH, measured before building. The six GA-only events sit on
-- days-out bands of 60-90 minutes, which the 2-hour rule (mig 20261126065000) already
-- overrides:
--     their own days-out bands   5.00 reads/hour
--     now, at 2 hours            2.90
--     at 4 hours                 1.50
-- So the 2-hour rule already banked 2.1 reads/hour and this banks the remaining 1.4, about 34
-- credits a day. The operator's "4 events per 1-hour slot, 3 more event slots" is right
-- measured from a 1-HOUR baseline, which is not where these events were; against the current
-- 2-hour state the gain is ~1.4 reads/hour, about 1.4 average event slots (demand is 313
-- reads/hour over 310 watched events). Recorded here because the figure in the ask was 3.
--
-- All six current events are already over 400 — the lowest, CupcakKe, is 440 — so the new tier
-- captures all of them today and the 100-400 tier sits empty until a smaller GA show appears.
-- That is the point of a tier rather than a flat threshold: a 150-ticket GA club show keeps
-- the 2-hour band instead of falling back to its 60-minute days-out band.
--
-- HOW. ga_slow is a boolean, so a two-step ladder cannot be driven from it. The GA ticket count
-- is now stored on the event (primary_poll_event.ga_tickets), the settle writes it from the
-- same aggregate that already decides ga_slow, and a 4-argument axs_watch_cadence_every picks
-- the step. The 3-argument overload stays, unchanged, so nothing else has to move and the
-- ladder guards in primary_poll_due keep reading ga_slow exactly as they do now. A third tier
-- is then two config rows and one CASE arm.
--
-- The rule still only ever SLOWS: every step is greatest(days_out_band, step), so an event
-- inside its last day is never held back by a GA band.

BEGIN;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS ga_slow2_every interval NOT NULL DEFAULT interval '4 hours',
  ADD COLUMN IF NOT EXISTS ga_slow2_min_tickets integer NOT NULL DEFAULT 400;

ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS ga_tickets integer;

COMMENT ON COLUMN public.primary_poll_event.ga_tickets IS
  'General-admission tickets at the last good read, summed over GA listings. Drives the deep-GA '
  'cadence ladder (ga_slow_min_tickets -> ga_slow_every, ga_slow2_min_tickets -> ga_slow2_every). '
  'Written only by axs_watch_settle_one. mig 20261126194500.';

-- the second step must be slower than the first, and its threshold higher, or the ladder is
-- not a ladder
ALTER TABLE public.axs_watch_config
  DROP CONSTRAINT IF EXISTS axs_watch_config_ga_ladder_ck;
ALTER TABLE public.axs_watch_config
  ADD CONSTRAINT axs_watch_config_ga_ladder_ck
  CHECK (ga_slow2_every >= ga_slow_every AND ga_slow2_min_tickets >= ga_slow_min_tickets);

-- 4-arg overload: the step is chosen by ticket count, and still only slows
CREATE OR REPLACE FUNCTION public.axs_watch_cadence_every(
    p_start timestamp with time zone, p_event_date date, p_ga_slow boolean, p_ga_tickets integer)
 RETURNS interval
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
           WHEN NOT coalesce(p_ga_slow, false)
             THEN public.axs_watch_cadence_every(p_start, p_event_date)
           -- greatest(): a GA step may only ever slow an event down
           WHEN coalesce(p_ga_tickets, 0) > (SELECT c.ga_slow2_min_tickets FROM public.axs_watch_config c)
             THEN greatest(public.axs_watch_cadence_every(p_start, p_event_date),
                           (SELECT c.ga_slow2_every FROM public.axs_watch_config c))
           ELSE greatest(public.axs_watch_cadence_every(p_start, p_event_date),
                         (SELECT c.ga_slow_every FROM public.axs_watch_config c))
         END
$function$;

DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
  v_decl   text := '  v_ga_slow boolean := false; v_slow interval;';
  v_decl_r text := '  v_ga_slow boolean := false; v_slow interval; v_ga_tickets integer;';
  v_agg    text := '      INTO v_ga_slow
      FROM public.primary_poll_listing l
     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;
    v_ga_slow := coalesce(v_ga_slow, false);
    v_every := coalesce(public.axs_watch_cadence_every(t.start_utc, t.event_date, v_ga_slow), interval ''1 hour'');';
  v_agg_r  text := '      INTO v_ga_slow
      FROM public.primary_poll_listing l
     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;
    v_ga_slow := coalesce(v_ga_slow, false);
    -- the same aggregate, kept for the cadence ladder (mig 20261126194500)
    SELECT coalesce(sum(l.quantity) FILTER (WHERE coalesce(l.general_admission, false)), 0)
      INTO v_ga_tickets
      FROM public.primary_poll_listing l
     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;
    v_every := coalesce(public.axs_watch_cadence_every(t.start_utc, t.event_date, v_ga_slow, v_ga_tickets), interval ''1 hour'');';
  v_upd    text := '       SET poll_interval = v_every,
           ga_slow       = v_ga_slow,';
  v_upd_r  text := '       SET poll_interval = v_every,
           ga_slow       = v_ga_slow,
           ga_tickets    = v_ga_tickets,';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_settle_one not found'; END IF;
  v_new := v_src;


  v_hits := (length(v_new) - length(replace(v_new, v_decl, ''))) / length(v_decl);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle DECLARE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, v_decl, v_decl_r);

  v_hits := (length(v_new) - length(replace(v_new, v_agg, ''))) / length(v_agg);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle GA aggregate: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, v_agg, v_agg_r);

  v_hits := (length(v_new) - length(replace(v_new, v_upd, ''))) / length(v_upd);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle band UPDATE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, v_upd, v_upd_r);

  IF v_new = v_src THEN RAISE EXCEPTION 'axs_watch_settle_one unchanged — surgery did nothing'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
  IF v_src !~ 'v_ga_tickets integer'
     OR v_src !~ 'cadence_every\(t\.start_utc, t\.event_date, v_ga_slow, v_ga_tickets\)'
     OR v_src !~ 'ga_tickets    = v_ga_tickets' THEN
    RAISE EXCEPTION 'axs_watch_settle_one did not come back driving the GA ladder';
  END IF;
END $surgery$;

-- Backfill ga_tickets for the events already flagged, so the new step applies at the next read
-- rather than only after each event has been read twice.
UPDATE public.primary_poll_event t
   SET ga_tickets = coalesce((SELECT sum(l.quantity) FROM public.primary_poll_listing l
                               WHERE l.source = 'axs' AND l.source_event_id = t.source_event_id
                                 AND coalesce(l.general_admission, false)), 0)
 WHERE t.source = 'axs' AND t.ga_slow AND t.ga_tickets IS NULL;

COMMIT;
