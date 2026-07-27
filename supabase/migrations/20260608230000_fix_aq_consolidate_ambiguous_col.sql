-- ============================================================================
-- MIG 20260608230000 — fix aq_consolidate_safe_dups ambiguous column (A1-OPS-22)
--
-- The function installed by mig 20260608201500 errored on the p_apply=>true path
-- with: "column reference 'tevo_event_id' is ambiguous". Inside the COALESCE
-- UPDATE, the inner subquery's `WHERE tevo_event_id = c.tid` was unqualified and
-- collided with the function's RETURNS TABLE OUT parameter `tevo_event_id`. The
-- dry-run path (p_apply=>false) never runs that UPDATE, so it slipped through.
--
-- FIX: alias the table in that subquery (am.) so the column is unambiguous. No
-- other behavioral change. Verified in prod: dry-run 220 rows / 212 clusters,
-- then executed — all 212 safe clusters now hold their platform ids on a single
-- survivor row (0 clusters with >1 id-bearing row), ticketsdata_event_xref
-- re-pointed (0 orphans), 23 conflicting clusters untouched.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.aq_consolidate_safe_dups(p_apply boolean DEFAULT false)
RETURNS TABLE(tevo_event_id bigint, survivor_aq text, loser_aq text, action text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c RECORD;
  l RECORD;
  v_survivor text;
BEGIN
  FOR c IN
    SELECT m.tevo_event_id AS tid
    FROM public.aq_event_map m
    WHERE m.tevo_event_id IS NOT NULL
    GROUP BY m.tevo_event_id
    HAVING count(*) > 1
      AND count(DISTINCT m.sg_event_id)    FILTER (WHERE m.sg_event_id IS NOT NULL)    <= 1
      AND count(DISTINCT m.sh_event_id)    FILTER (WHERE m.sh_event_id IS NOT NULL)    <= 1
      AND count(DISTINCT m.vivid_event_id) FILTER (WHERE m.vivid_event_id IS NOT NULL) <= 1
      AND count(DISTINCT m.tm_event_id)    FILTER (WHERE m.tm_event_id IS NOT NULL)    <= 1
      AND count(DISTINCT m.sd_event_id)    FILTER (WHERE m.sd_event_id IS NOT NULL)    <= 1
  LOOP
    SELECT a.aq_short_event_id INTO v_survivor
    FROM public.aq_event_map a
    WHERE a.tevo_event_id = c.tid
    ORDER BY
      ( (a.sg_event_id IS NOT NULL)::int + (a.sh_event_id IS NOT NULL)::int
      + (a.vivid_event_id IS NOT NULL)::int + (a.tm_event_id IS NOT NULL)::int
      + (a.sd_event_id IS NOT NULL)::int ) DESC,
      (EXISTS(SELECT 1 FROM public.ticketsdata_event_xref x WHERE x.aq_short_event_id = a.aq_short_event_id)) DESC,
      a.aq_short_event_id ASC
    LIMIT 1;

    IF p_apply THEN
      -- pull each loser's single non-null platform value onto the survivor (no conflicts in the safe class)
      UPDATE public.aq_event_map s SET
        sg_event_id    = COALESCE(s.sg_event_id,    o.sg_event_id),
        sh_event_id    = COALESCE(s.sh_event_id,    o.sh_event_id),
        vivid_event_id = COALESCE(s.vivid_event_id, o.vivid_event_id),
        tm_event_id    = COALESCE(s.tm_event_id,    o.tm_event_id),
        sd_event_id    = COALESCE(s.sd_event_id,    o.sd_event_id)
      FROM (
        SELECT max(am.sg_event_id) sg_event_id, max(am.sh_event_id) sh_event_id,
               max(am.vivid_event_id) vivid_event_id, max(am.tm_event_id) tm_event_id,
               max(am.sd_event_id) sd_event_id
        FROM public.aq_event_map am
        WHERE am.tevo_event_id = c.tid AND am.aq_short_event_id <> v_survivor
      ) o
      WHERE s.aq_short_event_id = v_survivor;
    END IF;

    FOR l IN
      SELECT a.aq_short_event_id AS aq
      FROM public.aq_event_map a
      WHERE a.tevo_event_id = c.tid AND a.aq_short_event_id <> v_survivor
    LOOP
      IF p_apply THEN
        UPDATE public.ticketsdata_event_xref x
          SET aq_short_event_id = v_survivor, updated_at = now()
          WHERE x.aq_short_event_id = l.aq;
        UPDATE public.aq_event_map a
          SET sg_event_id=NULL, sh_event_id=NULL, vivid_event_id=NULL, tm_event_id=NULL, sd_event_id=NULL
          WHERE a.aq_short_event_id = l.aq;
      END IF;
      tevo_event_id := c.tid; survivor_aq := v_survivor; loser_aq := l.aq;
      action := CASE WHEN p_apply THEN 'consolidated' ELSE 'would_consolidate' END;
      RETURN NEXT;
    END LOOP;
  END LOOP;
END $function$;

REVOKE ALL ON FUNCTION public.aq_consolidate_safe_dups(boolean) FROM anon, PUBLIC;
