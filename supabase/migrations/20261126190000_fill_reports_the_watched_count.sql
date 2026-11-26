-- axs_watch_fill()'s 'watched' key counts WATCHED events, not every AXS row.
--
-- Found 2026-11-26 18:5xZ while verifying the tour exclusion: the fill returned
-- "watched": 587 against a target_events ceiling of 310. Both arms of its CASE count
--   SELECT count(*) FROM primary_poll_event t WHERE t.source = 'axs'
-- with no AND t.watch, so since the watch/catalogue split (mig 20261126060000) put catalogue
-- rows in the same table the key has reported watched + catalogue. 310 watched + 277 catalogue
-- = the 587 it printed.
--
-- Cosmetic — nothing reads it to make a decision; the ceiling itself is enforced elsewhere in
-- the fill and was respected (310 after the run). But it is wrong, it misled the author of this
-- migration for a minute, and the hourly monitor reads fill output, so it would eventually
-- have produced a false "watched >310" alarm. It is the same class of bug as the demand gauge
-- in mig 20261126062000: a count that silently stopped meaning what it said when the split
-- landed. One predicate per arm.
--
-- The p_apply = false arm keeps its arithmetic (it projects what a run WOULD leave, since no
-- rows have moved yet); only its base count is narrowed.

BEGIN;

DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
  v_old text := '''watched'', CASE WHEN p_apply THEN (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = ''axs'')
                           ELSE (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = ''axs'') - v_retired - v_returned + v_total_added + v_backfilled END,';
  v_rep text := '''watched'', CASE WHEN p_apply THEN (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = ''axs'' AND t.watch)
                           ELSE (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = ''axs'' AND t.watch) - v_retired - v_returned + v_total_added + v_backfilled END,';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_fill';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_fill not found'; END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'axs_watch_fill watched key: expected 1 site, found %', v_hits;
  END IF;

  v_new := replace(v_src, v_old, v_rep);
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_fill';
  IF (SELECT count(*) FROM regexp_matches(v_src, 't\.source = ''axs'' AND t\.watch\)', 'g')) <> 2 THEN
    RAISE EXCEPTION 'axs_watch_fill did not come back with both arms narrowed to watched rows';
  END IF;
END $surgery$;

COMMIT;
