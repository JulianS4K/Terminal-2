-- The no-tickets / not-on-sale bands survive primary_poll_due's ladder clause too.
-- Operator 2026-11-26: "Fix the no ticket daily".
--
-- mig 20261126141500 guarded the deep-GA band with NOT coalesce(t.ga_slow, false), because
-- ga_slow is a stored record of WHY that band was chosen. The error-driven slow bands had no
-- such record, so the ladder clause still overrode them: event 1568048 (Matt Rife) carries a
-- stored band of 1 day from no_tickets_every and the shared ladder says 1 hour, and
-- primary_poll_due returned it as due. It escaped being read 24x its band only because
-- axs_watch_next orders by next_poll_at NULLS FIRST and its next_poll_at is the
-- furthest-future of any watched event, so the batch limit never reached it. Starved, not
-- protected — and on a quiet hour, or with a second reader draining the queue faster, it would
-- have been read hourly.
--
-- primary_poll_event.cadence_pinned is the general form of that record: "this interval was
-- chosen deliberately; the shared ladder must not undercut it". The settle sets it in both
-- places a band is written:
--   * the normal band UPDATE sets it to v_ga_slow, so an event that stops being deep-GA is
--     unpinned on its next read rather than staying slow forever;
--   * the slow branch sets it true, for every error the branch matches (no tickets, not on
--     sale, coming soon, cancelled).
-- primary_poll_due keeps BOTH predicates. cadence_pinned alone would be tidier, but a new
-- column starts false everywhere, so for one read per GA event the guard that shipped an hour
-- ago would have lapsed. Two predicates have no such window; the backfill below closes it for
-- the error bands in the same statement.
--
-- Inert for sitickets, timberwolves and ims: nothing outside the AXS settle writes
-- cadence_pinned, and it defaults false, so the clause reads exactly as before for them.
-- primary_poll_due is a shared seam (PROJECT_BIBLE 2.6), hence the deliberately inert shape.

BEGIN;

ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS cadence_pinned boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.primary_poll_event.cadence_pinned IS
  'The stored poll_interval was chosen by a deliberate rule (deep GA, no tickets, not on sale), '
  'not by the days-out ladder, so primary_poll_due''s ladder clause must not undercut it. '
  'Written only by axs_watch_settle_one. mig 20261126150000.';

-- Close the window for the events that already carry an error band, so the fix is live now
-- rather than at each event's next read.
UPDATE public.primary_poll_event e
   SET cadence_pinned = true
 WHERE e.source = 'axs'
   AND e.poll_interval IN ((SELECT c.no_tickets_every FROM public.axs_watch_config c),
                           (SELECT c.not_on_sale_every FROM public.axs_watch_config c))
   AND coalesce(e.poll_error, '') ~* 'not (currently |yet )?on sale|not on sale yet|no tickets are currently available|coming soon|\mcancel(l?)ed\M';

UPDATE public.primary_poll_event e SET cadence_pinned = true
 WHERE e.source = 'axs' AND e.ga_slow AND NOT e.cadence_pinned;

DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_settle_one not found'; END IF;
  v_new := v_src;

  -- (a) the normal band UPDATE records whether the band came from the GA rule
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'       SET poll_interval = v_every,\\n           ga_slow       = v_ga_slow,\\n           next_poll_at  = to_timestamp\\(v_next\\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle band UPDATE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'       SET poll_interval = v_every,\n           ga_slow       = v_ga_slow,\n           next_poll_at  = to_timestamp(v_next)',
    E'       SET poll_interval = v_every,\n           ga_slow       = v_ga_slow,\n'
    || E'           -- the ladder may not undercut a band the GA rule chose (mig 20261126150000);\n'
    || E'           -- false here is what UNPINS an event that is no longer deep GA\n'
    || E'           cadence_pinned = v_ga_slow,\n'
    || E'           next_poll_at  = to_timestamp(v_next)');

  -- (b) the slow branch pins whatever band it sets
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'         SET poll_interval = v_slow, next_poll_at = now\\(\\) \\+ v_slow \\* \\(0\\.75 \\+ random\\(\\) \\* 0\\.5\\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle slow UPDATE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'         SET poll_interval = v_slow, next_poll_at = now() + v_slow * (0.75 + random() * 0.5)',
    E'         SET poll_interval = v_slow, cadence_pinned = true,\n'
    || E'             next_poll_at = now() + v_slow * (0.75 + random() * 0.5)');

  IF v_new = v_src THEN RAISE EXCEPTION 'axs_watch_settle_one unchanged — surgery did nothing'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
  IF (SELECT count(*) FROM regexp_matches(v_src, 'cadence_pinned', 'g')) <> 2 THEN
    RAISE EXCEPTION 'axs_watch_settle_one did not come back with both cadence_pinned writes';
  END IF;
END $surgery$;

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
               -- band a deliberate rule chose (migs 20261126141500, 20261126150000)
               OR (live.every < t.poll_interval
                   AND NOT coalesce(t.ga_slow, false)
                   AND NOT coalesce(t.cadence_pinned, false)
                   AND t.poll_attempt_at + live.every <= now() + cfg.due_slack)))
$function$;

DO $check$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='primary_poll_due';
  IF v_src !~ 'NOT coalesce\(t\.ga_slow, false\)'
     OR v_src !~ 'NOT coalesce\(t\.cadence_pinned, false\)' THEN
    RAISE EXCEPTION 'primary_poll_due did not come back with both guards';
  END IF;
END $check$;

COMMIT;
