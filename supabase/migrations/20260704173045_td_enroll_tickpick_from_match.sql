-- Migration 20260704173045 · lane:A1 (data plane — TicketsData TP/GT coverage)
--   writes (DDL): td_gt_tm_enroll_from_match() [CREATE OR REPLACE — add TickPick]
--   writes on run: ticketsdata_event_xref (enroll GT/TM/TP rows from /match urls)
--   reads: td_match_results, aq_event_map
--   pre: 20260704160040 (td_gt_tm_enroll_from_match GT/TM version)
--   auth: operator directive 2026-07-04 (julian@s4kent.com — "map more gt and tickpick")
--
-- ## Applied to prod 2026-07-04 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- td_gt_tm_enroll_from_match() (mig 20260704160040) enrolls GT + TM xref rows from
-- td_match_results, but ignored the tickpick_url column — so TickPick sat at ~1
-- active despite /match returning tickpick_urls. Add ('TP', r.tickpick_url) to the
-- LATERAL platform set so TP enrolls the same way (authoritative /match url).
--
-- TP /fetch verified live 2026-07-04 (tickpick_url 7717873 → 200, 277 listings).
-- Note TP's fetch body is items{totalListings,offers}, not items[]; the drain
-- already handles per-platform shapes. TP still only *polls* within 5 days of the
-- event (td_poll_policy TP max_dte=5), so far-out TP rows are enrolled but dormant
-- until they enter the hot window — harmless. GT unchanged (this also re-captures
-- any un-enrolled GT urls on the same run). Hourly cron + run now (unchanged cron).
--
-- Rollback: restore the mig 20260704160040 body (GT/TM only, no TP row).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.td_gt_tm_enroll_from_match()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'td_gt_tm_enroll_from_match: forbidden for %', current_user USING ERRCODE = '42501';
  END IF;

  WITH m AS (
    SELECT DISTINCT ON (r.sg_event_id, plat.platform)
           r.sg_event_id, r.aq_short_event_id, plat.platform, plat.url
    FROM public.td_match_results r
    JOIN public.aq_event_map a ON a.aq_short_event_id = r.aq_short_event_id
    JOIN LATERAL (VALUES ('GT', r.gametime_url), ('TM', r.tm_url), ('TP', r.tickpick_url)) AS plat(platform, url)
      ON plat.url IS NOT NULL
    WHERE r.sg_event_id IS NOT NULL
      AND a.event_date > now()
      AND a.event_name NOT ILIKE '%parking%'
    ORDER BY r.sg_event_id, plat.platform, r.created_at DESC
  )
  INSERT INTO public.ticketsdata_event_xref
    (event_id, platform, aq_short_event_id, event_url, active, manual_opt_in, match_method, meta, updated_at)
  SELECT m.sg_event_id, m.platform, m.aq_short_event_id, m.url, true, true, 'gt_tm_tp_from_match',
         jsonb_build_object('seed','gt_tm_tp_from_match','seeded_at', now()), now()
  FROM m
  ON CONFLICT (event_id, platform) DO UPDATE
    SET active = true, manual_opt_in = true,
        event_url = COALESCE(public.ticketsdata_event_xref.event_url, EXCLUDED.event_url),
        updated_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$function$;
REVOKE ALL ON FUNCTION public.td_gt_tm_enroll_from_match() FROM anon, public;
