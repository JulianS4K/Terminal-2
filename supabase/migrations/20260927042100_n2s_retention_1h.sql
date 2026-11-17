-- Migration 20260927042100 · level:secondary-sales · lane:D7 · writes:n2s_mkt_drain · reads:none · pre:20260927041700
--
-- Already applied to prod · via MCP 2026-09-27 04:21 UTC under operator direction
-- ("For n2s data retention should only be 1 hour"), after a rolled-back dry run.
-- N2S's own polling data (request log + the three current-list tables) is kept
-- one hour. n2s_cover_history (the per-obligation P&L record) is NOT affected.
-- ============================================================================

DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_mkt_drain'::regproc);
  v_old text := E'  DELETE FROM public.n2s_mkt_pull    WHERE fired_at  < now() - interval ''3 days'';\n'
             || E'  DELETE FROM public.n2s_evo_current WHERE pulled_at < now() - interval ''1 day'';\n'
             || E'  DELETE FROM public.n2s_gt_current  WHERE pulled_at < now() - interval ''1 day'';\n'
             || E'  DELETE FROM public.n2s_sg_current  WHERE pulled_at < now() - interval ''1 day'';\n';
  v_new text := E'  DELETE FROM public.n2s_mkt_pull    WHERE fired_at  < now() - interval ''1 hour'';\n'
             || E'  DELETE FROM public.n2s_evo_current WHERE pulled_at < now() - interval ''1 hour'';\n'
             || E'  DELETE FROM public.n2s_gt_current  WHERE pulled_at < now() - interval ''1 hour'';\n'
             || E'  DELETE FROM public.n2s_sg_current  WHERE pulled_at < now() - interval ''1 hour'';\n';
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'n2s_mkt_drain: retention block not found exactly once';
  END IF;
  EXECUTE replace(replace(v_def, v_old, v_new),
                  '-- retention: N2S keeps only the current list per event, for a day',
                  '-- retention: N2S keeps its own polling data for 1 hour (operator, 2026-09-27)');
END $$;

-- rollback: swap the four intervals back ('3 days' / '1 day' ×3).
