-- Migration 20261117165000 · level:hotfix · lane:A1 · writes:event_key_lookup()(new, provisional) · pre:20261117160000
-- (numbered BEFORE 20261117170000 so that, in order, the key migration's full definition replaces this provisional one)
--
-- HOTFIX 2026-11-18 20:40Z: mig 20261117171000 (the resolver reads the internal key) landed on prod while
-- 20261117170000 (the key itself) had not — the 171000 resolver calls event_key_lookup(), which 170000 defines, so
-- event_mapper_identity() raised "function public.event_key_lookup(text, bigint) does not exist" on every lookup that
-- reached the spine fallback. This file defines event_key_lookup WITHOUT the ESPN column (which 170000 adds); 170000
-- then CREATE OR REPLACEs it with the full version. Safe to paste at any time: it only creates a function.

CREATE OR REPLACE FUNCTION public.event_key_lookup(p_source text, p_source_event_id bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT x.xmap_id FROM public.event_xmap x
   WHERE CASE lower(trim(coalesce(p_source, '')))
           WHEN 'tevo' THEN x.tevo_event_id WHEN 'evo' THEN x.tevo_event_id
           WHEN 'tickpick' THEN x.tp_event_id WHEN 'tp' THEN x.tp_event_id
           WHEN 'vivid' THEN x.vivid_event_id WHEN 'vividseats' THEN x.vivid_event_id
           WHEN 'gotickets' THEN x.gt_event_id WHEN 'gt' THEN x.gt_event_id
           WHEN 'axs' THEN x.axs_event_id
           WHEN 'seatgeek' THEN x.sg_event_id WHEN 'sg' THEN x.sg_event_id
           WHEN 'mlb' THEN x.mlb_schedule_id END = p_source_event_id
   LIMIT 1
$function$;
REVOKE ALL ON FUNCTION public.event_key_lookup(text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_key_lookup(text, bigint) TO service_role;

-- VERIFY: SELECT * FROM event_mapper_identity('seatgeek', 1);   -- returns no row, no error
