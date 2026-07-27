-- Migration 20260703140100 · lane:A1 (data plane — TicketsData target apply robustness)
--   writes (DDL): td_apply_targets() [CREATE OR REPLACE — DISTINCT ON platform id]
--   reads/writes on run: same as before (ticketsdata_event_xref upsert + sweep)
--   pre: 20260703140000 (td_target_events expansion), 20260629120000 (last apply body)
--   auth: operator directive 2026-07-03 (required to apply the expanded target set)
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- The expanded td_target_events() (mig 20260703140000, ~1,500 events) surfaced a
-- latent fragility: two distinct aq events can share one StubHub/Vivid id (the §0
-- "map can be wrong" dup case — un-merged TBD/system-seed dupes, venue+date false
-- matches). td_apply_targets()'s `INSERT … SELECT … FROM td_target_events()
-- ON CONFLICT (event_id, platform) DO UPDATE` then proposes two rows with the same
-- (event_id, platform) in one command → Postgres 21000 "ON CONFLICT DO UPDATE
-- command cannot affect row a second time". With the old ~195-event set no dup
-- existed, so it never fired; the daily td_watchlist_refresh would now hit it.
--
-- FIX: dedupe the insert source per platform id — SELECT DISTINCT ON (sh_event_id)
-- / DISTINCT ON (vivid_event_id). Picks one aq_short_event_id per marketplace id
-- (the id is what's polled; the aq link is only for tier/display). Body otherwise
-- identical to mig 20260629120000 (manual_opt_in-preserving deactivation sweep, GT
-- always_on, owned_tickets/median refresh). Rollback: restore that body.
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
  SELECT t.sh_event_id, 'SH', t.aq_short_event_id, 'https://www.stubhub.com/x/event/' || t.sh_event_id::text || '/', true, true, 'direct_id', v_now
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
