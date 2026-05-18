-- Migration 20260519170000 · lane:A1 · writes:sg_classify_events · pre:20260519160000 · auth:operator-approved 2026-05-19
--
-- Refine sg_classify_events SKIP filter: don't SKIP "(Date TBD)" / "^TBD at "
-- events when we have a TEvo bridge confirming the matchup.
--
-- Discovered live 2026-05-18: Cavs/Knicks Round 3 games (sg 18068086 +
-- 18068088) were stuck at tier='SKIP' because SG's broker-side names still
-- said "TBD at New York Knicks (Round 3 - Home Game 1) (Date TBD)" — leftover
-- placeholders from before Cavs won round 2. TEvo had the real matchup
-- confirmed via xref (tevo 3346000 + 3346001), and both events had ~1,700
-- distinct SG listings each. Polling silently dropped for 2 days, with no
-- alert because tier='SKIP' is a normal classification, not an error state.
--
-- Old regex: `(cancelled|if necessary|\(date tbd\)|^TBD at )` — all matches
-- → unconditional SKIP. Too aggressive when bracket games get TEvo bridges
-- before SG refreshes their broker-side event names.
--
-- New logic, splits the regex by certainty:
--   - "(cancelled)" / "(if necessary)" — definitive, always SKIP regardless
--     of bridge state. Cancelled is cancelled; if-necessary games that DO
--     get played get their own canonical record from SG anyway.
--   - "(date tbd)" / "^TBD at " — provisional, SKIP only when no TEvo
--     bridge exists. The TEvo bridge is our authoritative confirmation
--     that the matchup is locked in. If we have one, the placeholder name
--     is just lagging metadata — the market is real.
--
-- Other rules unchanged. owned_cnt / listings_cnt thresholds via policy
-- table still apply for the non-SKIP cases.
--
-- Companion DML applied 2026-05-18: tier override on sg 18068086 (HOT) +
-- 18068088 (WARM) to un-stick polling immediately. Future bracket games
-- will be handled by the new classifier logic automatically.

CREATE OR REPLACE FUNCTION public.sg_classify_events()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
BEGIN
  WITH listings_by_tevo AS (
    SELECT event_id AS tevo_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
      AND event_id IS NOT NULL
    GROUP BY event_id
  ),
  listings_by_aq AS (
    SELECT aq_short_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
      AND aq_short_event_id IS NOT NULL
    GROUP BY aq_short_event_id
  ),
  event_metrics AS (
    SELECT c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_datetime_utc,
           coalesce(a.aq_short_event_id,
                    (SELECT aem.aq_short_event_id FROM public.aq_event_map aem
                     WHERE aem.sg_event_id = c.sg_event_id LIMIT 1)) AS aq_short_event_id,
           coalesce(c.tevo_event_id,
                    (SELECT x.tevo_event_id FROM public.seatgeek_event_xref x
                     WHERE x.sg_event_id = c.sg_event_id LIMIT 1)) AS tevo_event_id,
           EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event,
           coalesce(lt.owned_cnt,    la.owned_cnt,    0) AS owned_cnt,
           coalesce(lt.listings_cnt, la.listings_cnt, 0) AS listings_cnt
    FROM public.sg_events_canonical c
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = c.sg_event_id
    LEFT JOIN listings_by_tevo lt ON lt.tevo_event_id = c.tevo_event_id
    LEFT JOIN listings_by_aq   la ON la.aq_short_event_id = a.aq_short_event_id
    WHERE c.sg_datetime_utc IS NOT NULL
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '60 days'
  ),
  classified AS (
    SELECT em.*,
      CASE
        -- Definitive skip — cancelled / if-necessary regardless of bridge
        WHEN em.sg_event_name ~* '(cancelled|if necessary)' THEN 'SKIP'
        -- Provisional skip — TBD markers only when no TEvo bridge to
        -- confirm matchup. (A1 mig 20260519170000.)
        WHEN em.sg_event_name ~* '(\(date tbd\)|^TBD at )'
             AND em.tevo_event_id IS NULL THEN 'SKIP'
        ELSE
          (SELECT p.tier FROM public.sg_priority_policy p
           WHERE p.enabled = true
             AND em.hours_to_event >= coalesce(p.min_hours_to_event, -999999)
             AND em.hours_to_event <  coalesce(p.max_hours_to_event, 999999)
             AND (p.requires_owned = false OR em.owned_cnt > 0)
           ORDER BY p.sort_order LIMIT 1)
      END AS tier
    FROM event_metrics em
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     tevo_event_id, owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         tevo_event_id, owned_cnt, listings_cnt, coalesce(tier, 'SKIP'), hours_to_event, v_now
  FROM classified WHERE sg_event_id IS NOT NULL
  ON CONFLICT (sg_event_id) DO UPDATE SET
    sg_event_name           = EXCLUDED.sg_event_name,
    sg_venue_name           = EXCLUDED.sg_venue_name,
    sg_datetime_utc         = EXCLUDED.sg_datetime_utc,
    aq_short_event_id       = EXCLUDED.aq_short_event_id,
    tevo_event_id           = EXCLUDED.tevo_event_id,
    owned_count_last_7d     = EXCLUDED.owned_count_last_7d,
    active_listings_last_7d = EXCLUDED.active_listings_last_7d,
    tier                    = EXCLUDED.tier,
    hours_to_event          = EXCLUDED.hours_to_event,
    computed_at             = EXCLUDED.computed_at,
    sales_polls_today       = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day              = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END
$function$;

COMMENT ON FUNCTION public.sg_classify_events() IS
  'Refresh sg_event_priority_state tier per event. A1 2026-05-19 (mig 20260519170000): split SKIP regex — "cancelled"/"if necessary" stay unconditional; "(date tbd)"/"^TBD at " only skip when no TEvo bridge confirms the matchup. Caught the Cavs/Knicks bracket dropout where SG broker-side names lag the actual matchup determination.';
