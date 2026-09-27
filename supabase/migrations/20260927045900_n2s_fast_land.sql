-- Migration 20260927045900 · level:secondary-sales · lane:D7 · writes:n2s_fast_land,n2s_pipeline_tick,cron.job · reads:n2s_mkt_pull · pre:20260927043400
--
-- Already applied to prod · via MCP 2026-09-27 04:59 UTC under operator direction
-- ("build the faster drain job, test first"), after a rolled-back dry run: no
-- pending → cheap exit; one live EVO response → 437 groups landed and the cover
-- queue rebuilt from empty (6 orders), no errors.
--
-- ============================================================================
-- Responses were landed only by the once-a-minute tick. n2s_fast_land runs every
-- 15 s, lands them and rebuilds covers straight away (queue, history, feed,
-- webhook; the bot_chat ping stays in the tick because it writes n2s_items).
-- Mutual exclusion: the tick takes pg_advisory_xact_lock(n2s_cover_stage) first
-- thing; the fast job only TRIES it and skips while the tick runs — neither can
-- deadlock the other.
-- Finding after go-live: responses become visible only when their pg_net batch
-- completes, so landing is bounded by the batch (see 20260927160500).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_fast_land()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE d record; v_err jsonb := '[]'::jsonb;
BEGIN
  -- cheap exit: nothing of ours has come back yet
  IF NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull p
                   JOIN net._http_response h ON h.id = p.request_id
                  WHERE p.resolved_at IS NULL) THEN
    RETURN jsonb_build_object('skipped', 'nothing_landed');
  END IF;
  -- the tick holds this for its whole run; never wait on it
  IF NOT pg_try_advisory_xact_lock(hashtext('n2s_cover_stage')) THEN
    RETURN jsonb_build_object('skipped', 'tick_running');
  END IF;

  SELECT * INTO d FROM public.n2s_mkt_drain();
  IF COALESCE(d.rows_persisted, 0) = 0 THEN
    RETURN jsonb_build_object('landed', 0);
  END IF;

  -- same cover stages as the tick, minus n2s_sub_ping (it writes n2s_items;
  -- the tick sends the ping on its next run)
  BEGIN PERFORM * FROM public.n2s_cover_queue_refresh();
  EXCEPTION WHEN OTHERS THEN v_err := v_err || jsonb_build_object('stage','cover_queue_refresh','err',SQLERRM); END;
  BEGIN PERFORM * FROM public.n2s_cover_history_append();
  EXCEPTION WHEN OTHERS THEN v_err := v_err || jsonb_build_object('stage','cover_history_append','err',SQLERRM); END;
  BEGIN PERFORM * FROM public.n2s_profitable_cover_sync();
  EXCEPTION WHEN OTHERS THEN v_err := v_err || jsonb_build_object('stage','profitable_cover_sync','err',SQLERRM); END;
  BEGIN PERFORM * FROM public.n2s_cover_push_drain();
  EXCEPTION WHEN OTHERS THEN v_err := v_err || jsonb_build_object('stage','cover_push_drain','err',SQLERRM); END;
  BEGIN PERFORM * FROM public.n2s_cover_push_queue(25);
  EXCEPTION WHEN OTHERS THEN v_err := v_err || jsonb_build_object('stage','cover_push_queue','err',SQLERRM); END;

  RETURN jsonb_build_object('landed', d.rows_persisted, 'errors', v_err);
END $function$;
REVOKE ALL ON FUNCTION public.n2s_fast_land() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_fast_land() TO service_role;
COMMENT ON FUNCTION public.n2s_fast_land() IS
  'Every 15 s: lands N2S marketplace responses (n2s_mkt_drain) and rebuilds covers as soon as they arrive, instead of waiting for the next once-a-minute tick. Shares the n2s_cover_stage advisory lock with n2s_pipeline_tick; skips while the tick runs.';

DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_pipeline_tick'::regproc);
  v_old text := E'    RETURN jsonb_build_object(''skipped'', ''overlap'');\n  END IF;\n';
  v_new text := v_old || E'  -- shared with n2s_fast_land: only one of them rebuilds covers at a time\n  PERFORM pg_advisory_xact_lock(hashtext(''n2s_cover_stage''));\n';
BEGIN
  IF md5(v_def) <> '2f7a603ec99a750fdcdec1154dfe2e04' THEN RAISE EXCEPTION 'n2s_pipeline_tick drifted — refusing'; END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN RAISE EXCEPTION 'tick: overlap anchor not found exactly once'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- single statement on purpose (a SET-prefixed command stalls the scheduler — 20260926170000)
SELECT cron.schedule('n2s_fast_land_15s', '15 seconds', 'SELECT public.n2s_fast_land();');

-- rollback: SELECT cron.unschedule('n2s_fast_land_15s'); DROP FUNCTION
-- public.n2s_fast_land(); the tick's extra lock line is harmless on its own.
