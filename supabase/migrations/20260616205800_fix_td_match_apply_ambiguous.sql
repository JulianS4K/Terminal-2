-- Migration 20260616205800 · lane:D0 · APPLIED LIVE 2026-06-16 by operator directive · writes(DDL): td_match_apply() · writes(cron): re-enable td_match_apply_cron · reads: td_match_results, aq_event_map · pre:20260616205000_td_resume_scoped · auth:operator-requested 2026-06-16 ("just use the td matcher")
--
-- Fix: td_match_apply() failed 100% (71/71 cron runs) with
--   "column reference aq_short_event_id is ambiguous" — the function's RETURNS
--   TABLE OUT param aq_short_event_id collided with the td_match_results column
--   in its driving query's WHERE clause. Aliased the table (r) and qualified the
--   predicate columns. Logic otherwise unchanged. Cron re-enabled.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_match_apply(p_min_confidence numeric DEFAULT 90, p_apply boolean DEFAULT false)
 RETURNS TABLE(aq_short_event_id text, tevo_event_id bigint, col text, old_value bigint, new_value bigint, confidence numeric, action text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE res RECORD; a RECORD; pair RECORD;
BEGIN
  FOR res IN
    SELECT * FROM public.td_match_results r
    WHERE r.applied_at IS NULL AND r.aq_short_event_id IS NOT NULL
    ORDER BY r.created_at ASC
  LOOP
    SELECT m.aq_short_event_id, m.tevo_event_id, m.sg_event_id, m.sh_event_id, m.vivid_event_id
    INTO a FROM public.aq_event_map m WHERE m.aq_short_event_id = res.aq_short_event_id;
    IF NOT FOUND THEN CONTINUE; END IF;
    IF res.match_confidence IS NULL OR res.match_confidence < p_min_confidence THEN
      aq_short_event_id := res.aq_short_event_id; tevo_event_id := a.tevo_event_id;
      col := '*'; old_value := NULL; new_value := NULL;
      confidence := res.match_confidence; action := 'SKIP_LOWCONF';
      RETURN NEXT; CONTINUE;
    END IF;
    FOR pair IN
      SELECT * FROM (VALUES
        ('sg_event_id',    a.sg_event_id,    res.sg_event_id),
        ('sh_event_id',    a.sh_event_id,    res.sh_event_id),
        ('vivid_event_id', a.vivid_event_id, res.vivid_event_id)
      ) AS v(col, cur, proposed)
    LOOP
      IF pair.proposed IS NULL THEN CONTINUE;
      ELSIF pair.cur IS NULL THEN action := 'FILL';
      ELSIF pair.cur = pair.proposed THEN action := 'AGREE';
      ELSE action := 'CONFLICT'; END IF;
      IF p_apply AND action = 'FILL' THEN
        EXECUTE format('UPDATE public.aq_event_map SET %I = $1 WHERE aq_short_event_id = $2', pair.col)
        USING pair.proposed, res.aq_short_event_id;
      END IF;
      aq_short_event_id := res.aq_short_event_id; tevo_event_id := a.tevo_event_id;
      col := pair.col; old_value := pair.cur; new_value := pair.proposed;
      confidence := res.match_confidence; RETURN NEXT;
    END LOOP;
    IF p_apply THEN UPDATE public.td_match_results SET applied_at = now() WHERE id = res.id; END IF;
  END LOOP;
  RETURN;
END $function$;
