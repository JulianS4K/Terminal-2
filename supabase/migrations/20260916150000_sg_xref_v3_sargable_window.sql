-- ============================================================================
-- Migration 20260916150000 — make the v3 matcher's date window sargable too
-- Migration 20260916150000 · level:data-collection · lane:A1 · writes:none · reads:events · pre:20260916140000
--
-- Lane:     A1 (cross-source xref)
-- Touches:  sg_attempt_event_xref_v3 (R) — function body only. No table,
--           column, index or cron schedule is changed.
-- Pre-reqs: 20260916140000 (fixed the v1 matcher and bounded both loops)
--
-- ── CORRECTING 20260916140000 ─────────────────────────────────────────────
-- That migration deferred this fix on the grounds that v3 "has never been
-- observed running, because v1 has been timing out before it is reached."
-- That was wrong, and the evidence was already in cron.job_run_details: the
-- 2026-09-16 11:09 failure of cross_source_match_tick_30min carries v3's
-- query in its CONTEXT, not v1's —
--
--     SQL statement "SELECT e.id, e.name FROM public.events e
--                    LEFT JOIN public.event_lifecycle lc ON lc.e..."
--
-- against v1's "SELECT e.id FROM events e ...". Both legs run and both time
-- out; which one the tick dies in varies. So v3 needed the same treatment,
-- and it gets it here, against measurements rather than blind.
--
-- ── THE SAME BUG, SLIGHTLY DIFFERENT SHAPE ────────────────────────────────
-- v3 windows on an instant rather than a day:
--
--     e.occurs_at_local::timestamptz BETWEEN <t> - 24h AND <t> + 24h
--
-- `occurs_at_local` is TEXT and the only index on it is
-- events_local_day_idx ON events (left(occurs_at_local, 10)), so a cast to
-- timestamptz is just as unindexable as v1's cast to date. Measured on prod,
-- same row, same shape:
--
--   ::timestamptz BETWEEN +/-24h          Seq Scan, 118,122 rows removed
--                                         11,885 buffers   229.1 ms
--   + left(...) day pre-filter            Index Scan on events_local_day_idx
--                                          7,934 rows removed
--                                          3,698 buffers    24.9 ms
--
-- 9.2x faster. At ~2,000 unmatched rows per pass that is ~458s of work
-- becoming ~50s — the difference between a pass that cannot finish inside
-- the tick's 5-minute timeout and one that does.
--
-- ── WHY A WIDENED PRE-FILTER RATHER THAN A REWRITE ────────────────────────
-- v1's predicate could be rewritten outright because `occurs_at_local::date`
-- and `left(occurs_at_local,10)` were shown equal for every row in the table.
-- v3's cannot: it is a +/-24h window on an INSTANT, and the text carries a
-- per-row UTC offset, so no day-granular expression reproduces it exactly.
--
-- So the exact condition is KEPT as the filter, and a day-granular range is
-- ADDED purely to give the planner something indexable. It is deliberately
-- wider than the real window, which makes it a provable superset — it can
-- only pre-select rows, never exclude a row the exact condition would have
-- accepted:
--
--   * a row's local date sits within 38h either side of its own instant
--     (24h of local day span, plus a UTC offset bounded by 14h);
--   * the instants of interest sit within 24h of <t>;
--   * so any qualifying row's local date is within 62h of <t>, and a bound
--     of 96h clears that by a day and a half at each end.
--
-- The bounds are pinned with AT TIME ZONE 'UTC' rather than a bare ::date so
-- the guarantee does not depend on the session's TimeZone (UTC here today,
-- but the margin should not rest on a GUC). Widening from 48h to 96h cost
-- 1.7ms in measurement — the margin is close to free, so it is taken.
--
-- The A1-OPS-24 exact-date guard is a different case and IS rewritten
-- outright: it compares against a `date` parameter, where the v1 equivalence
-- (verified across all 118,122 rows) applies exactly. Same rows, sargable.
--
-- The ORDER BY still contains `occurs_at_local::date`, untouched: it sorts
-- the handful of rows that survived the WHERE, so it costs nothing and
-- changing it would risk the tie-break order that decides which event wins.
--
-- SECURITY DEFINER is preserved (pg_proc.prosecdef = true in prod).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sg_attempt_event_xref_v3(
  p_sg_event_id bigint, p_sg_event_name text, p_sg_event_date date,
  p_sg_datetime_utc timestamp with time zone, p_sg_venue text,
  p_sg_venue_city text DEFAULT NULL::text, p_sg_venue_state text DEFAULT NULL::text,
  p_sg_category text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tevo_event_id bigint;
  v_tevo_name     text;
  v_existing      bigint;
  v_sg_team_a     text;
  v_sg_team_b     text;
  v_tevo_venue_id bigint;
  v_cand_date     date;
  v_anchor        timestamptz;
BEGIN
  IF p_sg_category IN ('Parking','parking')
     OR coalesce(p_sg_venue,'') ILIKE '%parking%'
     OR coalesce(p_sg_event_name,'') ILIKE '%parking%' THEN
    RETURN NULL;
  END IF;

  SELECT tevo_event_id INTO v_existing FROM public.seatgeek_event_xref WHERE sg_event_id = p_sg_event_id LIMIT 1;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;

  v_sg_team_a := trim(split_part(coalesce(p_sg_event_name,''), ' at ', 1));
  v_sg_team_b := trim(split_part(coalesce(p_sg_event_name,''), ' at ', 2));
  IF v_sg_team_b = '' THEN v_sg_team_b := v_sg_team_a; END IF;

  v_tevo_venue_id := public.cross_source_venue_resolve(p_sg_venue, p_sg_venue_city, p_sg_venue_state);

  v_anchor := coalesce(p_sg_datetime_utc, p_sg_event_date::timestamptz);

  SELECT e.id, e.name INTO v_tevo_event_id, v_tevo_name
  FROM public.events e
  LEFT JOIN public.event_lifecycle lc ON lc.event_id = e.id
  WHERE
    -- Indexable superset of the +/-24h window (see header): day-granular,
    -- padded to +/-96h, pinned to UTC so it does not depend on the session
    -- TimeZone. Narrows events_local_day_idx; excludes nothing the exact
    -- condition below would have kept.
    left(e.occurs_at_local, 10) BETWEEN
        to_char((v_anchor - interval '96 hours') AT TIME ZONE 'UTC', 'YYYY-MM-DD')
    AND to_char((v_anchor + interval '96 hours') AT TIME ZONE 'UTC', 'YYYY-MM-DD')
    AND e.occurs_at_local::timestamptz BETWEEN
      v_anchor - interval '24 hours' AND v_anchor + interval '24 hours'
    AND (
      (v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id)
      OR lower(trim(coalesce(e.venue_name,''))) = lower(trim(coalesce(p_sg_venue,'')))
      OR lower(trim(coalesce(e.venue_name,''))) LIKE lower(trim(coalesce(p_sg_venue,''))) || '%'
      OR lower(trim(coalesce(p_sg_venue,''))) LIKE lower(trim(coalesce(e.venue_name,''))) || '%'
    )
    AND (
      (v_sg_team_b <> '' AND (
        lower(coalesce(e.primary_performer_name,'')) LIKE '%' || lower(v_sg_team_b) || '%'
        OR lower(coalesce(e.name,'')) LIKE '%' || lower(v_sg_team_b) || '%'))
      OR
      (v_sg_team_a <> '' AND (
        lower(coalesce(e.primary_performer_name,'')) LIKE '%' || lower(v_sg_team_a) || '%'
        OR lower(coalesce(e.name,'')) LIKE '%' || lower(v_sg_team_a) || '%'))
    )
  ORDER BY
    CASE WHEN e.occurs_at_local::date = coalesce(p_sg_event_date, p_sg_datetime_utc::date) THEN 0 ELSE 1 END,
    abs(extract(epoch FROM (e.occurs_at_local::timestamptz - v_anchor))),
    CASE WHEN coalesce(lc.is_active, true) THEN 0 ELSE 1 END,
    CASE WHEN v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_tevo_event_id IS NOT NULL
     AND ( NOT public.aq_name_consistent(v_tevo_name, p_sg_event_name)
           OR NOT public.aq_league_consistent(v_tevo_event_id, p_sg_category) ) THEN
    v_tevo_event_id := NULL;
  END IF;

  -- A1-OPS-24 EXACT-DATE GUARD
  IF v_tevo_event_id IS NOT NULL THEN
    SELECT e.occurs_at_local::date INTO v_cand_date FROM public.events e WHERE e.id = v_tevo_event_id;
    IF v_cand_date IS DISTINCT FROM p_sg_event_date
       AND EXISTS (
         SELECT 1 FROM public.events e2
         WHERE e2.id <> v_tevo_event_id
           AND ( (v_tevo_venue_id IS NOT NULL AND e2.venue_id = v_tevo_venue_id)
                 OR lower(trim(coalesce(e2.venue_name,''))) = lower(trim(coalesce(p_sg_venue,''))) )
           -- was: e2.occurs_at_local::date BETWEEN p_sg_event_date - 3 AND p_sg_event_date + 3
           -- exact same rows (equivalence verified table-wide), now sargable
           AND left(e2.occurs_at_local, 10) BETWEEN to_char(p_sg_event_date - 3, 'YYYY-MM-DD')
                                                AND to_char(p_sg_event_date + 3, 'YYYY-MM-DD')
           AND public.aq_name_consistent(e2.name, p_sg_event_name)
       ) THEN
      v_tevo_event_id := NULL;
    END IF;
  END IF;

  IF v_tevo_event_id IS NOT NULL THEN
    INSERT INTO public.seatgeek_event_xref (
      tevo_event_id, sg_event_id, sg_event_name, sg_event_type,
      sg_event_location, sg_start_data, match_method, match_confidence
    ) VALUES (
      v_tevo_event_id, p_sg_event_id, p_sg_event_name, p_sg_category,
      p_sg_venue,
      coalesce(p_sg_datetime_utc, make_timestamptz(
        EXTRACT(YEAR FROM p_sg_event_date)::int,
        EXTRACT(MONTH FROM p_sg_event_date)::int,
        EXTRACT(DAY FROM p_sg_event_date)::int, 0, 0, 0, 'UTC')),
      'matcher_v3_pm24h', 0.9
    )
    ON CONFLICT (tevo_event_id) DO UPDATE SET
      sg_event_id = EXCLUDED.sg_event_id,
      sg_event_name = EXCLUDED.sg_event_name,
      sg_event_location = EXCLUDED.sg_event_location,
      match_method = 'matcher_v3_pm24h',
      matched_at = NOW();
  END IF;
  RETURN v_tevo_event_id;
END $function$;
