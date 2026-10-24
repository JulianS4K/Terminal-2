-- ROLLBACK STEP 3c (operator-directed full rollback to the 2026-08-29 state).
--
-- Reverses the two retention_policy changes the branch made:
--   * 20260831160000 seeded a (disabled) espn_news policy      -> delete the row
--   * 20260831180000 re-prioritised six cheap policies to 5/6/7 -> restore
--
-- Provenance of the restored priorities:
--   espn_injuries_snapshots = 60  and  retention_run_log = 90 are the values
--   seeded by origin/main 20260705153000_a1_retention_policy_engine.sql, so
--   those two are exact.
--
--   reddit_news / reddit_news_pending / x_news / x_news_pending have NO
--   migration provenance at all — no migration on e43d549 creates them, so
--   they were written into prod live, and 20260831180000's UPDATE also set
--   updated_at = now(), erasing the last trace of their prior value. Their
--   exact pre-branch priority is UNRECOVERABLE. 100 is used here because it is
--   this project's convention for a news/low-cost policy: it is the priority of
--   seatgeek_sales_snapshots and the priority the branch's own espn_news seed
--   chose one migration earlier. This is an inference, not a restoration, and
--   is the single value in the rollback that is not provably the 08-29 state.

DELETE FROM public.retention_policy WHERE table_name = 'espn_news';

UPDATE public.retention_policy
   SET priority = 60, updated_at = now()
 WHERE table_name = 'espn_injuries_snapshots';

UPDATE public.retention_policy
   SET priority = 90, updated_at = now()
 WHERE table_name = 'retention_run_log';

UPDATE public.retention_policy
   SET priority = 100, updated_at = now()
 WHERE table_name IN ('reddit_news','reddit_news_pending','x_news','x_news_pending');

DO $verify$
DECLARE bad text;
BEGIN
  IF EXISTS (SELECT 1 FROM public.retention_policy WHERE table_name = 'espn_news') THEN
    RAISE EXCEPTION 'espn_news retention policy still present';
  END IF;
  SELECT string_agg(table_name || '=' || priority, ', ') INTO bad
    FROM public.retention_policy
   WHERE priority < 10;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'branch priorities survive the rollback: %', bad;
  END IF;
END $verify$;
