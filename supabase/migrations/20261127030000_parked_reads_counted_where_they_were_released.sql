-- The parked-read credit is counted from the queue, not from the event's present band.
--
-- mig 20261127000000 put a parked event's read outside the daily cap, and counted the
-- day's parked reads so the active side could be charged for the rest:
--
--   SELECT count(*) INTO v_parked_today
--     FROM axs_watch_poll w JOIN primary_poll_event e ON ...
--    WHERE w.fired_at >= <Eastern day start>
--      AND coalesce(e.cadence_pinned,false) AND e.poll_interval >= v_cfg.no_tickets_every;
--
-- That asks "is this event parked NOW?" and then credits back EVERY read it had today.
-- An event parked at 18:00 that was read every 30 minutes since 05:00 Eastern contributes
-- its whole day of fast-band reads to the credit, though each of those was charged to the
-- cap at the time and none of them was a parked read. The gate a few lines below asks a
-- different question -- "was this queue row filled at a parked band?" (q.every_min >=
-- v_parked_min) -- so the counter and the gate disagreed about what a parked read is.
--
-- Measured on prod before this migration: counted_now = 163, true parked reads today = 0.
-- My header on 20261127000000 called the error "bounded by one read a day per event"; that
-- was wrong by an order of magnitude -- it is bounded by a full day at the event's FORMER
-- band (~480 reads for the 20 events now parked). Flagged in bot_chat 7650. The effect is
-- that the active side gets a credit it did not earn and overruns the daily cap by that much.
--
-- The fix counts where the release actually happened: axs_read_queue.every_min is the band
-- the row was FILLED at, so a row with every_min >= v_parked_min is a read this very gate
-- let through outside the cap. The counter and the gate now read the same column against
-- the same threshold, so they cannot drift apart again.
--
-- claimed_at is the anchor, not resolved_at, because the claim is the release:
--   * claimed + acked      -> counted; axs_queue_ack wrote a poll row at release_at, so it
--                             is in fired_today too. Matched.
--   * claimed, in flight   -> counted; not yet in fired_today. Over-credits by at most
--                             queue_lanes (6) for seconds, self-correcting on ack.
--   * claimed, then reaped -> axs_queue_reap sets claimed_at = NULL and no poll row was
--                             ever written, so neither side counts it. Matched.
--   * reaped and re-claimed-> claimed_at is the live claim; one poll row. Counted once.
-- resolved_at would instead UNDER-count parked by the in-flight set, which both under-credits
-- the active side and lets more than parked_daily_max parked reads through in a day.
--
-- In-place surgery on the deployed body so this file and prod cannot drift. The guard
-- asserts the old count exists exactly once and refuses the migration otherwise.

DO $surgery$
DECLARE
  v_def text; v_new text; v_old text; v_rep text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_queue_claim';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'axs_queue_claim is not present -- refusing to guess at its body';
  END IF;

  v_old := '  -- A PARKED EVENT''S READ IS OUTSIDE THE DAILY CAP (mig 20261127000000). Counted from' || E'\n' ||
           '  -- axs_watch_poll on the same Eastern-day boundary axs_watch_budget uses for fired_today,' || E'\n' ||
           '  -- so the subtraction below is exact rather than two tables'' estimates of one number.' || E'\n' ||
           '  v_parked_min := greatest(extract(epoch FROM v_cfg.no_tickets_every)::integer / 60, 1);' || E'\n' ||
           '  SELECT count(*) INTO v_parked_today' || E'\n' ||
           '    FROM public.axs_watch_poll w' || E'\n' ||
           '    JOIN public.primary_poll_event e ON e.source = ''axs'' AND e.source_event_id = w.axs_event_id' || E'\n' ||
           '   WHERE w.fired_at >= date_trunc(''day'', now() AT TIME ZONE ''America/New_York'') AT TIME ZONE ''America/New_York''' || E'\n' ||
           '     AND coalesce(e.cadence_pinned, false) AND e.poll_interval >= v_cfg.no_tickets_every;';

  v_rep := '  -- A PARKED EVENT''S READ IS OUTSIDE THE DAILY CAP (mig 20261127000000). Counted from' || E'\n' ||
           '  -- the QUEUE (mig 20261127030000): every_min is the band the row was filled at, so this' || E'\n' ||
           '  -- counts the reads this gate itself released outside the cap -- the same column against' || E'\n' ||
           '  -- the same threshold the loop below tests, on the Eastern-day boundary axs_watch_budget' || E'\n' ||
           '  -- uses for fired_today. Counting from the event''s PRESENT band instead credited back' || E'\n' ||
           '  -- every read it had today, including the fast-band ones already charged to the cap.' || E'\n' ||
           '  v_parked_min := greatest(extract(epoch FROM v_cfg.no_tickets_every)::integer / 60, 1);' || E'\n' ||
           '  SELECT count(*) INTO v_parked_today' || E'\n' ||
           '    FROM public.axs_read_queue pq' || E'\n' ||
           '   WHERE pq.claimed_at >= date_trunc(''day'', now() AT TIME ZONE ''America/New_York'') AT TIME ZONE ''America/New_York''' || E'\n' ||
           '     AND pq.every_min IS NOT NULL AND pq.every_min >= v_parked_min;';

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'expected the axs_watch_poll parked count exactly once in axs_queue_claim, found %', v_hits;
  END IF;

  v_new := replace(v_def, v_old, v_rep);
  EXECUTE v_new;

  -- read back: the new count is in, the old join is gone, the gate is untouched
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_queue_claim';
  IF position('FROM public.axs_read_queue pq' IN v_def) = 0 THEN
    RAISE EXCEPTION 'read-back: the queue-based parked count is not in the deployed body';
  END IF;
  IF position('JOIN public.primary_poll_event e ON e.source = ''axs''' IN v_def) <> 0 THEN
    RAISE EXCEPTION 'read-back: the old primary_poll_event parked count is still in the deployed body';
  END IF;
  IF position('q.every_min IS NOT NULL AND q.every_min >= v_parked_min' IN v_def) = 0 THEN
    RAISE EXCEPTION 'read-back: the loop''s parked gate is no longer where this migration expects it';
  END IF;
END $surgery$;
