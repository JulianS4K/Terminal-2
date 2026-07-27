-- Migration 20260703144000 · lane:A1 (data plane — TicketsData StubHub fetch fix)
--   writes (DDL): td_apply_targets() [CREATE OR REPLACE — StubHub URL /x/event/ → /event/]
--   writes on run: ticketsdata_event_xref (rewrite SH event_url + reactivate via td_apply_targets)
--   pre: 20260703140100 (last td_apply_targets body)
--   auth: operator directive 2026-07-04 (julian@s4kent.com — "fix" [StubHub 100% poll failure])
--
-- ## Applied to prod 2026-07-04 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- StubHub polling was 100% failing (v_td_poll_health: SH 513/513 fail, 371× 404
-- "event_not_found", which auto-deactivates the xref row). td_apply_targets built
-- SH event_urls as https://www.stubhub.com/x/event/<id>/ — the /x/ short form,
-- which TicketsData's StubHub /fetch does NOT resolve (404). This was pre-existing
-- (SH sat at ~0 active because rows self-deactivated); the target expansion just
-- made it visible at volume. VividSeats (/production/<id>) was unaffected — 100% ok.
--
-- Verified live 2026-07-04 via three /fetch probes on a real StubHub event id
-- (159405626):
--   /x/event/<id>/                → 404 (broken, current)
--   /event/<id>/                  → 200 + live listings  ✅
--   /<slug>/event/<id>/           → 200 + live listings  ✅
-- The /x/ prefix is the whole bug; /event/<id>/ is constructible from the id alone.
--
-- FIX: build SH urls as https://www.stubhub.com/event/<id>/. Re-running
-- td_apply_targets rewrites every SH target row's event_url (ON CONFLICT DO UPDATE
-- SET event_url=EXCLUDED) and reactivates the ones 404 had deactivated. Body is
-- otherwise identical to mig 20260703140100 (DISTINCT ON per platform id).
-- Rollback: restore the mig 20260703140100 body (the /x/event/ url).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.td_apply_targets()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_count int := 0; v_now timestamptz := now();
BEGIN
  WITH t AS (SELECT DISTINCT ON (sh_event_id) * FROM public.td_target_events() WHERE sh_event_id IS NOT NULL ORDER BY sh_event_id)
  INSERT INTO public.ticketsdata_event_xref (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
  SELECT t.sh_event_id, 'SH', t.aq_short_event_id, 'https://www.stubhub.com/event/' || t.sh_event_id::text || '/', true, true, 'direct_id', v_now
  FROM t ON CONFLICT (event_id, platform) DO UPDATE SET active=true, always_on=true, event_url=EXCLUDED.event_url, updated_at=v_now;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  WITH t AS (SELECT DISTINCT ON (vivid_event_id) * FROM public.td_target_events() WHERE vivid_event_id IS NOT NULL ORDER BY vivid_event_id)
  INSERT INTO public.ticketsdata_event_xref (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
  SELECT t.vivid_event_id, 'VD', t.aq_short_event_id, 'https://www.vividseats.com/production/' || t.vivid_event_id::text, true, true, 'direct_id', v_now
  FROM t ON CONFLICT (event_id, platform) DO UPDATE SET active=true, always_on=true, event_url=EXCLUDED.event_url, updated_at=v_now;
  UPDATE public.ticketsdata_event_xref x SET active=false, updated_at=v_now
  WHERE x.active=true AND x.manual_opt_in IS NOT TRUE AND NOT EXISTS (SELECT 1 FROM public.td_target_events() t
    WHERE (x.platform='SH' AND x.event_id=t.sh_event_id) OR (x.platform='VD' AND x.event_id=t.vivid_event_id)
       OR (x.platform='GT' AND x.event_id=t.sg_event_id) OR (x.platform='TP' AND x.aq_short_event_id=t.aq_short_event_id)
       OR (x.platform='TM' AND x.aq_short_event_id=t.aq_short_event_id));
  UPDATE public.ticketsdata_event_xref x SET always_on=true, updated_at=v_now
  WHERE x.platform='GT' AND x.active=true AND EXISTS (SELECT 1 FROM public.td_target_events() t WHERE t.sg_event_id=x.event_id);
  UPDATE public.ticketsdata_event_xref x SET owned_tickets=COALESCE(em_data.owned_tickets_count,0), median_retail_price=em_data.retail_median, updated_at=v_now
  FROM public.aq_event_map aem JOIN public.sg_events_canonical sgc ON sgc.sg_event_id=aem.sg_event_id
  LEFT JOIN LATERAL (SELECT em.owned_tickets_count, em.retail_median FROM public.event_metrics em
    WHERE em.event_id=sgc.tevo_event_id ORDER BY em.captured_at DESC LIMIT 1) em_data ON true
  WHERE aem.aq_short_event_id=x.aq_short_event_id AND x.active=true AND sgc.tevo_event_id IS NOT NULL;
  RETURN v_count;
END $function$;

-- Immediately rewrite any lingering /x/event/ SH urls + reactivate (belt-and-suspenders;
-- the td_apply_targets re-run below also does this for current targets).
UPDATE public.ticketsdata_event_xref
SET event_url = replace(event_url, '/x/event/', '/event/'), active = true, updated_at = now()
WHERE platform = 'SH' AND event_url LIKE '%/x/event/%';

SELECT public.td_apply_targets();
