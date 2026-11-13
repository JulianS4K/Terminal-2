ALTER TABLE band_log ADD COLUMN sg boolean;
CREATE OR REPLACE FUNCTION public.n2s_pull_events(p_events bigint[], p_refresh_after interval, p_sg_repeat boolean)
 RETURNS TABLE(evo_fired integer, gt_fired integer, sg_queued integer, td_queued integer, evo_skipped_fresh integer, gt_skipped_fresh integer, evo_skipped_unknown integer) LANGUAGE plpgsql AS $$
BEGIN INSERT INTO band_log(evs, iv, sg) VALUES (p_events, p_refresh_after, p_sg_repeat); RETURN QUERY SELECT 1,0,0,0,0,0,0; END $$;
