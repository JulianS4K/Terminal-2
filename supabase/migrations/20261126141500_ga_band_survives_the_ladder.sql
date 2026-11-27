-- The deep-GA band survives primary_poll_due's ladder clause.
-- Operator 2026-11-26: "Do 3, and fix the ga rule".
--
-- Operator 2026-11-26 earlier: "if event is GA only and over 100 GA listings we can reduce
-- polling cadence to every 2 hours" (then "not 100 listings, 100 tickets"). That shipped as
-- mig 20261126065000: axs_watch_cadence_every(start, date, ga_slow) takes
-- greatest(band, ga_slow_every) so the rule may only ever SLOW an event down, and the settle
-- stores the decision on primary_poll_event.ga_slow.
--
-- It was then being undone on the read path. primary_poll_due's last clause,
--
--   OR (live.every < t.poll_interval AND t.poll_attempt_at + live.every <= now() + due_slack)
--
-- declares an event due on the SHARED ladder (primary_poll_interval: event_date + median_price
-- + listed_quantity) whenever that ladder is faster than the event's stored band. The shared
-- ladder's price band gives -1 step at median >= 150 and its qty band -1 step at >= 2000, and
-- the max_slowdown_steps clamp only limits SLOWING, so a combined -2 passes through and the
-- interval floors at 30 minutes however far out the event is. All six ga_slow events were
-- bypassed: three to 30 minutes and three to 60, against the 2 hours the operator set. Over
-- the six hours before this migration they took 4,4,5,5,6,7 reads where the band asks for 3.
--
-- axs_watch_next and axs_watch_tick both gate on primary_poll_due, so both paths were
-- affected. axs_queue_fill already reads next_poll_at and poll_interval directly and carries a
-- comment saying why, so the queue path was never exposed; this keeps the band honoured on the
-- due-list path too, which is the fallback whenever queue_enabled is false.
--
-- ga_slow is written only by the AXS settle and defaults false, so this changes nothing for
-- sitickets, timberwolves or ims: for them the clause reads exactly as before. primary_poll_due
-- is a shared seam (PROJECT_BIBLE 2.6), hence the deliberately inert condition.
--
-- NOT fixed here, and deliberately: the no-tickets daily band (no_tickets_every, mig
-- 20261126070000) has the same exposure — one event, Matt Rife 1568048, whose stored band is
-- 1 day and whose shared ladder says 1 hour. primary_poll_due returns it as due right now. It
-- has escaped so far only because axs_watch_next orders by next_poll_at NULLS FIRST and its
-- next_poll_at is the furthest-future of any watched event, so the batch limit never reaches
-- it. There is no stored flag for "this band came from the no-tickets rule" the way ga_slow
-- records the GA decision, so pinning it needs a column and settle surgery. Operator decision.

BEGIN;

CREATE OR REPLACE FUNCTION public.primary_poll_due(p_source text, p_event_ids jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(jsonb_agg(x.id ORDER BY x.id), '[]'::jsonb)
    FROM jsonb_array_elements_text(p_event_ids) x(id)
    LEFT JOIN public.primary_poll_event t ON t.source = p_source AND t.source_event_id = x.id
    LEFT JOIN LATERAL (SELECT public.primary_poll_interval(t.event_date, t.median_price, t.listed_quantity) AS every) live ON true
   CROSS JOIN (SELECT c.due_slack FROM public.primary_poll_config c) cfg
   WHERE t.source_event_id IS NULL
      OR (coalesce(t.watch, true)
          AND NOT public.primary_poll_ended(t.start_utc, t.event_date)
          AND (t.poll_attempt_at IS NULL OR t.next_poll_at IS NULL OR t.poll_interval IS NULL
               OR t.next_poll_at <= now() + cfg.due_slack
               -- the ladder clause: the shared ladder may overtake a stale band, but never a
               -- band the deep-GA rule chose (mig 20261126141500)
               OR (live.every < t.poll_interval
                   AND NOT coalesce(t.ga_slow, false)
                   AND t.poll_attempt_at + live.every <= now() + cfg.due_slack)))
$function$;

DO $check$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='primary_poll_due';
  IF v_src !~ 'NOT coalesce\(t\.ga_slow, false\)' THEN
    RAISE EXCEPTION 'primary_poll_due did not come back with the ga_slow guard';
  END IF;
END $check$;

COMMIT;
