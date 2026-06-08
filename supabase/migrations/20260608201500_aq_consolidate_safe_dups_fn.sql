-- ============================================================================
-- MIG 20260608201500 — aq_event_map safe-class dedupe function (A1-OPS-22)
--
-- aq_event_map is the cross-source hub (PK aq_short_event_id). ~235 tevo_event_ids
-- carry >=2 rows — TBD/aq_curated placeholder + later system_seed SYS-* rows that
-- resolve to the same game and never merge, scattering platform ids so the TD
-- daily snapshot reads only one cluster. This installs a GENERAL consolidation
-- sweep for the SAFE class only, modeled on td_reconcile_knicks_finals_aq.
--
-- SAFE class (212 of 235 clusters, audited 2026-06-08): a dup cluster with NO
-- platform-id conflict — <=1 distinct value per platform (sg/sh/vivid/tm/sd)
-- across the cluster. The 23 CONFLICTING clusters (main-vs-parking pseudo-events
-- / split doubleheaders) are deliberately EXCLUDED — they may be genuinely
-- distinct events and must be handled per-case, never blind-merged.
--
-- NEVER DELETES (aq_event_map has 8 FK-dependents: listings_snapshots,
-- seatgeek_*_snapshots, seatgeek_orders, evo_order_items, tickpick_orders,
-- vivid_orders, aq_tevo_search_attempts). Instead, per cluster:
--   • survivor = richest platform coverage; tie-break: referenced by
--     ticketsdata_event_xref, then smallest aq_short_event_id.
--   • COALESCE each loser's platform ids onto the survivor (safe — no conflicts).
--   • re-point ticketsdata_event_xref.aq_short_event_id loser -> survivor.
--   • NULL the loser's platform ids (row KEPT — FK-safe).
--
-- SAFETY: the function DEFAULTS TO DRY-RUN (p_apply => false) — it only reports
-- what it WOULD do. This migration INSTALLS THE FUNCTION ONLY and does NOT invoke
-- it, so applying the migration mutates NO data. Operator runs, in order:
--     SELECT action, count(*) FROM public.aq_consolidate_safe_dups(false) GROUP BY 1;  -- dry-run preview
--     SELECT * FROM public.aq_consolidate_safe_dups(true);                              -- execute
-- Re-runnable + idempotent (once consolidated a cluster is no longer a dup).
--
-- Dry-run preview (read-only, 2026-06-08): 212 safe clusters, 212 survivors,
-- 220 losers to neutralize (15 of them carry platform ids; the rest are empty
-- placeholders).
--
-- ⏳ NOT YET APPLIED — pending operator apply_migration (installs fn; mutates
--    nothing until invoked with p_apply=>true).
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
    -- survivor = richest platform coverage; tie-break TD-xref-referenced, then smallest aq id
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
        SELECT max(sg_event_id) sg_event_id, max(sh_event_id) sh_event_id,
               max(vivid_event_id) vivid_event_id, max(tm_event_id) tm_event_id,
               max(sd_event_id) sd_event_id
        FROM public.aq_event_map
        WHERE tevo_event_id = c.tid AND aq_short_event_id <> v_survivor
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

COMMENT ON FUNCTION public.aq_consolidate_safe_dups(boolean) IS
  'A1-OPS-22: consolidate SAFE-class aq_event_map dup clusters (no platform-id '
  'conflict). Survivor = richest platform coverage; COALESCE loser ids onto it, '
  're-point ticketsdata_event_xref, NULL loser ids (never deletes — 8 FK-deps). '
  'EXCLUDES the conflicting/doubleheader clusters. DEFAULTS TO DRY-RUN; pass '
  'true to execute. Modeled on td_reconcile_knicks_finals_aq.';
