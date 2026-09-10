-- ============================================================================
-- Migration 20260910500000 — drop the 6h age-out; run the history appender
--
-- Lane: D7 · Pre-reqs: 20260910390000 (added the cap), 20260910490000
-- Operator 2026-09-10: "actually store all the data remove the 6 hour cap, i
-- want to track it."
--
-- ⚠ WHAT THIS GIVES UP. The predicate removed here was a DEADMAN: with the
-- poll chain stalled, covers stopped being re-captured and the feed emptied
-- itself within six hours rather than serving buy links priced against dead
-- inventory. An empty feed is a visible failure; a stale one is not. Without
-- it a stalled poller leaves stale covers visible and actionable indefinitely.
-- n2s_cover_history.captured_at makes that DETECTABLE after the fact; nothing
-- now PREVENTS it. To restore: re-add the one line to the src CTE.
--
-- Applied by rewriting the stored definition so the rest of the body cannot
-- drift, with assertions that the predicate was found and then gone.
-- ============================================================================

DO $do$
DECLARE d text; before_len int; after_len int;
BEGIN
  d := pg_get_functiondef('public.n2s_profitable_cover_sync()'::regprocedure);
  before_len := length(d);

  d := replace(d,
       E'\n       -- 6-hour age-out (operator, 2026-09-10). Source-side on purpose.\n       AND v.captured_at > now() - interval ''6 hours''', '');
  d := replace(d, E'\n       AND v.captured_at > now() - interval ''6 hours''', '');
  after_len := length(d);

  IF after_len = before_len THEN
    RAISE EXCEPTION 'age-out predicate not found in n2s_profitable_cover_sync — body changed?';
  END IF;
  IF d LIKE '%6 hours%' THEN
    RAISE EXCEPTION 'age-out predicate still present after removal';
  END IF;

  EXECUTE d;
END $do$;

COMMENT ON FUNCTION public.n2s_profitable_cover_sync() IS
  'Diff-syncs profitable covers into n2s_profitable_cover for Realtime. Writes only genuine differences, so a quiet minute emits nothing and an event is meaningful. The 6-hour listing age-out was REMOVED 2026-09-10 (operator: track everything) — with it went the deadman that emptied the feed when polling stalled, so a stalled poller now leaves stale covers visible. Retention lives in n2s_cover_history; this table stays current-state-only because a DELETE here means "un-flag it" to the consumer.';

-- History is appended BEFORE the feed sync so a cover that appears and
-- vanishes inside a single tick is still recorded.
SELECT cron.alter_job(
  602,
  command := 'SELECT public.n2s_cover_queue_refresh(); SELECT public.n2s_cover_history_append(); SELECT public.n2s_profitable_cover_sync();'
);
