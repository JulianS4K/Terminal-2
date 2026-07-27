-- Migration 20260629170000 · lane:A1 (DB + ingest/cron — AXS↔GT/TM cross-source) · writes (DDL):axs_enroll_gt_tm_from_match() [new SECDEF fn]; new cron 'axs-enroll-gt-tm'; on run:ticketsdata_event_xref (GT/TM rows for AXS events) · reads:td_match_results, axs_events · pre:20260629160000 · auth:operator-approved 2026-06-29 (julian@s4kent.com — "yes do it" → option (a): build the GT/TM consumer now)
--
-- WHY ------------------------------------------------------------------------
-- The SeatGeek-anchored matcher (sg_match_map_tick → td_match_results) ALREADY returns
-- gametime_url / tm_url alongside sh/vivid in the same /match response, but td_match_apply
-- only persists sg/sh/vivid into aq_event_map and discards the GT/TM URLs. There is no
-- gt/tp/tm-URL column in aq_event_map, so GT/TM coverage for AXS events was never wired.
-- This is the missing consumer: it reads the GT/TM URLs that /match already produced and
-- enrolls them as ticketsdata_event_xref pull rows — no new API calls, no performer
-- seeding (which is unsourceable for these concerts), no SG pull (SG is anchor-only).
--
-- WHAT -----------------------------------------------------------------------
-- For active AXS events (matched by tevo_event_id OR aq_short_event_id — robust to the
-- §0 duplicate-aq-id hazard) that have a td_match_results row with a gametime_url/tm_url
-- and an sg_event_id, UPSERT a GT/TM ticketsdata_event_xref row:
--   event_id = sg_event_id (the established GT/TM xref key; matches td_*_discover_drain),
--   event_url = the /match GT/TM URL, manual_opt_in=true (sticky vs td_apply_targets),
--   active=true. Existing rows keep their event_url (COALESCE) and are made sticky+active.
-- A daily-ish cron re-runs it so GT/TM enroll automatically as the matcher works through
-- the AXS backlog over the coming weeks. Immediate yield: 2 GT rows (verified dry-run);
-- grows as AXS events acquire SG anchors (mig 20260629150000/160000) and get matched.
--
-- SCOPE / SAFETY -------------------------------------------------------------
-- AXS-scoped (does NOT enroll GT/TM for non-AXS matched events). Zero API/credit cost
-- (consumes already-fetched URLs; the pulls themselves are the normal td enqueue, budget
-- gated <6000/day,<180000/mo with huge headroom). SG never pulled (RULE-2 safe). TickPick
-- intentionally excluded (its enqueue crons are off; operator asked GT+TM). Idempotent
-- (ON CONFLICT) and reversible (drop fn + cron; delete match_method='axs_match_url' rows).
-- SECDEF with the standard lockdown (REVOKE + service_role grant + current_user guard).
--
-- ROLLBACK -------------------------------------------------------------------
--   SELECT cron.unschedule('axs-enroll-gt-tm');
--   DROP FUNCTION IF EXISTS public.axs_enroll_gt_tm_from_match();
--   UPDATE public.ticketsdata_event_xref SET active=false, manual_opt_in=false
--     WHERE match_method='axs_match_url';

CREATE OR REPLACE FUNCTION public.axs_enroll_gt_tm_from_match()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $func$
DECLARE v_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'axs_enroll_gt_tm_from_match: forbidden for %', current_user USING ERRCODE = '42501';
  END IF;

  WITH axs_match AS (
    SELECT DISTINCT ON (r.sg_event_id, plat.platform)
           r.sg_event_id, r.aq_short_event_id, plat.platform, plat.url
    FROM public.td_match_results r
    JOIN LATERAL (VALUES ('GT', r.gametime_url), ('TM', r.tm_url)) AS plat(platform, url)
      ON plat.url IS NOT NULL
    WHERE r.sg_event_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public.axs_events ax
        WHERE ax.active AND (ax.tevo_event_id = r.tevo_event_id
                             OR ax.aq_short_event_id = r.aq_short_event_id)
      )
    ORDER BY r.sg_event_id, plat.platform, r.created_at DESC
  )
  INSERT INTO public.ticketsdata_event_xref
    (event_id, platform, aq_short_event_id, event_url, active, manual_opt_in, match_method, meta, updated_at)
  SELECT m.sg_event_id, m.platform, m.aq_short_event_id, m.url, true, true, 'axs_match_url',
         jsonb_build_object('seed','axs_gt_tm_from_match','seeded_at', now()), now()
  FROM axs_match m
  ON CONFLICT (event_id, platform) DO UPDATE
    SET active = true,
        manual_opt_in = true,
        event_url = COALESCE(public.ticketsdata_event_xref.event_url, EXCLUDED.event_url),
        updated_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$func$;

REVOKE ALL ON FUNCTION public.axs_enroll_gt_tm_from_match() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_enroll_gt_tm_from_match() TO service_role;

-- one-time run (enrolls the GT rows available now)
SELECT public.axs_enroll_gt_tm_from_match();

-- keep enrolling as the AXS-prioritized matcher produces more GT/TM URLs over time
SELECT cron.schedule('axs-enroll-gt-tm', '23 * * * *',
  $$ SELECT public.axs_enroll_gt_tm_from_match(); $$);
