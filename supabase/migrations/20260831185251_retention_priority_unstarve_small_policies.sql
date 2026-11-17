-- Migration 20260831185251 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "retention_priority_unstarve_small_policies" (version 20260831185251) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

-- Migration 20260831180000 — un-starve the cheap retention policies
-- retention_tick() burns its 240s budget on the priority 10-30 firehoses, so
-- everything at priority >= 40 never runs. Move the cheap policies ahead.
UPDATE public.retention_policy
   SET priority = 5, updated_at = now()
 WHERE table_name IN ('reddit_news','reddit_news_pending','x_news','x_news_pending','espn_news');

UPDATE public.retention_policy
   SET priority = 6, updated_at = now()
 WHERE table_name = 'retention_run_log';

UPDATE public.retention_policy
   SET priority = 7, updated_at = now()
 WHERE table_name = 'espn_injuries_snapshots';

DO $verify$
DECLARE v_bad int;
BEGIN
  SELECT count(*) INTO v_bad
    FROM public.retention_policy
   WHERE table_name IN ('reddit_news','reddit_news_pending','x_news','x_news_pending',
                        'espn_news','retention_run_log','espn_injuries_snapshots')
     AND priority >= (SELECT min(priority) FROM public.retention_policy
                       WHERE table_name IN ('listings_snapshots','ticketsdata_listings_snapshots',
                                            'gotickets_listings_snapshots','section_metrics'));
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'retention priority fix: % cheap policies still sort at/after the firehoses', v_bad;
  END IF;
END
$verify$;
;
