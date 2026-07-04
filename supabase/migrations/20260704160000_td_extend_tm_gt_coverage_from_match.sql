-- Migration 20260704160000 · lane:A1 (data plane — TicketsData TM/GT coverage)
--   writes (DDL): td_gt_tm_enroll_from_match() [new], td_match_cron_budget_ok() [300→600];
--                 cron 'td_gt_tm_enroll_from_match_hourly'
--   writes on run: ticketsdata_event_xref (enroll GT/TM rows from /match urls)
--   reads: td_match_results, aq_event_map
--   pre: 20260619163000 (td_match_cron_budget_ok), 20260629170000 (axs_enroll_gt_tm_from_match)
--   auth: operator directive 2026-07-04 (julian@s4kent.com — "extend tm coverage")
--
-- ## Applied to prod 2026-07-04 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- Ticketmaster coverage was stuck at ~20 events. TM event ids come essentially
-- only from /match (which returns an authoritative tm_url per SG-anchored event) —
-- the by-performer path (td_tm_discover/_drain) is hardcoded to Yankees@Yankee-Stadium
-- and Knicks@MSG and needs non-derivable TM artist ids. And the only enroller,
-- axs_enroll_gt_tm_from_match(), restricts to events tied to axs_events (EXISTS
-- axs_events) — so TM/GT urls for the other ~thousands of matched events were
-- discarded.
--
-- Two levers, both here:
--   1. td_gt_tm_enroll_from_match() — the same enrollment as axs_enroll_gt_tm_from_match
--      but WITHOUT the axs-only filter: enroll GT + TM xref rows from EVERY upcoming
--      td_match_results row that carries a gametime_url / tm_url. Urls come straight
--      from /match (authoritative — the working TM rows use this exact format, 100%
--      ok in v_td_poll_health), so no false-match / artist-id lookup needed. Runs
--      hourly + once now.
--   2. Raise the /match report cap (td_match_cron_budget_ok) 300 → 600 (still ≤ the
--      600 automated cap, ~30% of the 2,000/mo plan). /match is the sole scalable
--      source of TM/GT/TP ids AND the sh/vivid filler; doubling its monthly budget
--      grows TM coverage (and finishes the sh/vivid mapping backlog) proportionally.
--
-- Cost: enrollment is free (reads our tables). The extra /match spend is bounded by
-- the 600-report cap (~600×12 = 7,200 credits/mo, trivial vs the ~200k plan pool).
-- Rollback: drop td_gt_tm_enroll_from_match + its cron; reset the cap to < 300.
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
    JOIN LATERAL (VALUES ('GT', r.gametime_url), ('TM', r.tm_url)) AS plat(platform, url)
      ON plat.url IS NOT NULL
    WHERE r.sg_event_id IS NOT NULL
      AND a.event_date > now()
      AND a.event_name NOT ILIKE '%parking%'
    ORDER BY r.sg_event_id, plat.platform, r.created_at DESC
  )
  INSERT INTO public.ticketsdata_event_xref
    (event_id, platform, aq_short_event_id, event_url, active, manual_opt_in, match_method, meta, updated_at)
  SELECT m.sg_event_id, m.platform, m.aq_short_event_id, m.url, true, true, 'gt_tm_from_match',
         jsonb_build_object('seed','gt_tm_from_match','seeded_at', now()), now()
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

-- Raise the /match report cap so more events get TM/GT-resolved (also feeds sh/vivid).
CREATE OR REPLACE FUNCTION public.td_match_cron_budget_ok()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
  SELECT public.td_budget_ok() AND public.td_reports_this_month() < 600;
$$;

-- Hourly enroll (off saturated :02/:05/:07 minute marks).
SELECT cron.schedule('td_gt_tm_enroll_from_match_hourly', '41 * * * *',
                     $$SELECT public.td_gt_tm_enroll_from_match()$$);

-- Enroll what's already available now.
SELECT public.td_gt_tm_enroll_from_match();
