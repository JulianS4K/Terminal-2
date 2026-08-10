-- Migration 20260810184500 · lane:A1 (data plane — GoTickets↔tevo mapping scope)
--   writes (DDL): gotickets_attempt_event_xref(...) [fn], match_gotickets_us_events(...) [fn],
--                 cron.job 'gotickets_match_us_6h' (@ '23 */6 * * *'), cron_policy row (W)
--   writes on run: gotickets_event.tevo_event_id / mapped_via / map_score / mapped_at
--                  (ONLY for currently-unmapped rows; never overwrites an existing map)
--   reads: gotickets_event, events, event_lifecycle, cross_source_venue_resolve +
--          cross_source_venue_map (matcher v3)
--   pre: 20260516240000 (matcher v3 — cross_source_venue_map + cross_source_venue_resolve),
--        cron_should_fire + cron_policy, gotickets_event/gotickets_listings_snapshots
--        (external collector-owned tables)
--   auth: operator directive 2026-08-10 (julian@s4kent.com — "poll go tickets for all the
--         us based events" + "set cron cadence"); stay within current collector capacity
--
-- ## NOT YET APPLIED — apply is operator-gated (CLAUDE.md §1). The cron SELF-GATES
--    (cron_should_fire + a work_check_sql that only fires when unmapped tracked-venue US
--    work exists), so applying is safe: it no-ops when there's nothing to map. Suggested
--    first step after apply — a manual dry-run to eyeball volume before the cron takes over:
--      SELECT * FROM match_gotickets_us_events(p_horizon_days => 180, p_apply => false);
--    then let gotickets_match_us_6h run, and confirm the collector polls the new maps.
--
-- WHY ─────────────────────────────────────────────────────────────────────────
-- 1. The GoTickets listings feed (gotickets_event 60k rows + gotickets_listings_
--    snapshots 22M rows) is written by an EXTERNAL/operator-side collector, not this
--    repo. Empirically the collector polls listings for an event ONLY once that event
--    carries a gotickets_event.tevo_event_id (verified 2026-08-10: 807/807 events
--    polled in 24h were mapped; 0 unmapped). So the in-repo lever to "poll GoTickets
--    for more US events" is to MAP more US GoTickets events to tevo.
--
-- 2. Today only ~760 of ~38,958 US-upcoming GoTickets events are mapped. This matcher
--    maps the residual — REUSING matcher v3 (the SG↔EVO matcher): the same
--    cross_source_venue_resolve() venue anchor + ±24h datetime tolerance (deliberately
--    wide: GoTickets event_time_utc is a LOCAL time stamped '+00', so instants differ
--    from tevo occurs_at_local by the venue's UTC offset — ±24h absorbs it, exactly as
--    v3 documents) + venue-match AND performer/name overlap + parking skip. Validated
--    on 400 already-mapped rows: re-derived a match for 371 and agreed with the live
--    mapping on 355 (95.7%); the disagreements were all US-Open multi-court sessions
--    where this venue-anchored logic actually aligned the specific court better.
--
-- 3. CEILING (measured, honest): the unmapped US GoTickets long tail is dominated by
--    small-venue events (comedy/jazz clubs, local theatre) with NO tevo counterpart
--    (a v3-style sweep of 600 unmapped US ≤60d events matched only 2). So this matcher
--    is an INCREMENTAL lift over the tevo-overlapping subset — NOT a path to all ~38k.
--    Polling GoTickets' full US long tail would require the EXTERNAL collector to poll
--    by gt_event_id WITHOUT a tevo map — an operator-side change outside this repo.
--
-- 4. CRON + why the sweep is venue-gated. The sweep (§2) is restricted to events at a
--    venue we track (cross_source_venue_map): that collapses the ~18k unmapped US ≤180d
--    backlog to the ~1,008 tevo-overlapping candidates, so a bounded sweep PROGRESSES
--    through the mappable set instead of re-scanning the unmappable long tail every run.
--    gotickets_match_us_6h runs it 6-hourly (see §3 cron block for the full cadence
--    rationale). The external 'instant_performer' matcher still runs; this is additive.
--
-- ROLLBACK: SELECT cron.unschedule('gotickets_match_us_6h');
--           DELETE FROM public.cron_policy WHERE jobname='gotickets_match_us_6h';
--           DROP FUNCTION match_gotickets_us_events(int,int,numeric,boolean);
--           DROP FUNCTION gotickets_attempt_event_xref(bigint,text,text,timestamptz,text,text,text,boolean,numeric);
--   To unwind maps this wrote: UPDATE gotickets_event SET tevo_event_id=NULL, mapped_via=NULL,
--           map_score=NULL, mapped_at=NULL WHERE mapped_via='matcher_v3_got';
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Per-event attempt — mirrors sg_attempt_event_xref_v3, adapted to GoTickets fields.
CREATE OR REPLACE FUNCTION public.gotickets_attempt_event_xref(
  p_gt_event_id   bigint,
  p_performer     text,
  p_name          text,
  p_event_time_utc timestamptz,
  p_venue_name    text,
  p_venue_city    text DEFAULT NULL,
  p_venue_state   text DEFAULT NULL,
  p_apply         boolean DEFAULT true,
  p_min_score     numeric DEFAULT 0.80
)
RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_existing      bigint;
  v_tevo_venue_id bigint;
  v_tevo_event_id bigint;
  v_by_venue_id   boolean := false;
  v_exact_venue   boolean := false;
  v_score         numeric;
  v_needle        text := lower(trim(coalesce(p_performer, p_name, '')));
BEGIN
  -- Skip parking pseudo-events (TEvo merges parking into the main listing — §3 landmine).
  IF coalesce(p_venue_name,'') ILIKE '%parking%'
     OR coalesce(p_performer,'') ILIKE '%parking%'
     OR coalesce(p_name,'')     ILIKE '%parking%' THEN
    RETURN NULL;
  END IF;
  IF v_needle = '' OR p_event_time_utc IS NULL THEN RETURN NULL; END IF;

  -- Never overwrite an existing mapping (external collector or a prior run).
  SELECT tevo_event_id INTO v_existing FROM public.gotickets_event WHERE gt_event_id = p_gt_event_id;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;

  -- Reuse matcher v3's venue resolver: GoTickets venue name → tevo_venue_id.
  v_tevo_venue_id := public.cross_source_venue_resolve(p_venue_name, p_venue_city, p_venue_state);

  -- Best tevo event within ±24h, venue-anchored, with performer/name overlap.
  SELECT e.id,
         (v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id),
         (lower(trim(coalesce(e.venue_name,''))) = lower(trim(coalesce(p_venue_name,''))))
    INTO v_tevo_event_id, v_by_venue_id, v_exact_venue
  FROM public.events e
  LEFT JOIN public.event_lifecycle lc ON lc.event_id = e.id
  WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
    AND e.occurs_at_local::timestamptz BETWEEN p_event_time_utc - interval '24 hours'
                                           AND p_event_time_utc + interval '24 hours'
    AND (
      (v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id)
      OR lower(trim(coalesce(e.venue_name,''))) = lower(trim(coalesce(p_venue_name,'')))
      OR lower(trim(coalesce(e.venue_name,''))) LIKE lower(trim(coalesce(p_venue_name,''))) || '%'
      OR lower(trim(coalesce(p_venue_name,''))) LIKE lower(trim(coalesce(e.venue_name,''))) || '%'
    )
    AND (
      lower(coalesce(e.primary_performer_name,'')) LIKE '%' || v_needle || '%'
      OR lower(coalesce(e.name,'')) LIKE '%' || v_needle || '%'
      -- reverse-contains, guarded: a non-trivial tevo performer name inside the GT
      -- needle. char_length>=4 stops empty/short names matching everything ('%%').
      OR (char_length(coalesce(e.primary_performer_name,'')) >= 4
          AND v_needle LIKE '%' || lower(e.primary_performer_name) || '%')
    )
  ORDER BY
    -- exact venue name wins (disambiguates multi-court complexes like the US Open),
    CASE WHEN lower(trim(coalesce(e.venue_name,''))) = lower(trim(coalesce(p_venue_name,''))) THEN 0 ELSE 1 END,
    -- then a confirmed venue-id match,
    CASE WHEN v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id THEN 0 ELSE 1 END,
    -- then closest in time,
    abs(extract(epoch FROM (e.occurs_at_local::timestamptz - p_event_time_utc))),
    -- then active (non-ghost) first.
    CASE WHEN coalesce(lc.is_active, true) THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_tevo_event_id IS NULL THEN RETURN NULL; END IF;

  -- Confidence from venue-match strength (mirrors v3's 0.9 baseline, refined).
  v_score := 0.80
           + CASE WHEN v_by_venue_id THEN 0.10 ELSE 0 END
           + CASE WHEN v_exact_venue THEN 0.05 ELSE 0 END;

  -- Below the confidence floor → treat as no confident match.
  IF v_score < p_min_score THEN RETURN NULL; END IF;

  IF p_apply THEN
    UPDATE public.gotickets_event
    SET tevo_event_id = v_tevo_event_id,
        mapped_via    = 'matcher_v3_got',
        map_score     = v_score,
        mapped_at     = now(),
        updated_at    = now()
    WHERE gt_event_id = p_gt_event_id AND tevo_event_id IS NULL;  -- race-safe: only if still unmapped
  END IF;

  RETURN v_tevo_event_id;
END $func$;

REVOKE EXECUTE ON FUNCTION public.gotickets_attempt_event_xref(bigint,text,text,timestamptz,text,text,text,boolean,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gotickets_attempt_event_xref(bigint,text,text,timestamptz,text,text,text,boolean,numeric) TO service_role;

COMMENT ON FUNCTION public.gotickets_attempt_event_xref(bigint,text,text,timestamptz,text,text,text,boolean,numeric) IS
  'GoTickets event → tevo matcher (reuses matcher v3: cross_source_venue_resolve + ±24h + venue/performer overlap + parking skip). Writes gotickets_event.tevo_event_id/mapped_via=matcher_v3_got/map_score when p_apply. Never overwrites an existing map. Mig 20260810184500.';


-- 2. Bounded sweep — US upcoming unmapped events, wall-clock budgeted (§scheduler-wedge).
CREATE OR REPLACE FUNCTION public.match_gotickets_us_events(
  p_max          int     DEFAULT 500,
  p_horizon_days int     DEFAULT 60,
  p_min_score    numeric DEFAULT 0.80,
  p_apply        boolean DEFAULT true
)
RETURNS TABLE(attempted int, matched int, parking_skipped int, unmatched int, elapsed_ms int)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  r          RECORD;
  v_match    bigint;
  v_start    timestamptz := clock_timestamp();
  v_att int := 0; v_ok int := 0; v_park int := 0; v_no int := 0;
  us_states text[] := ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC'];
BEGIN
  FOR r IN
    SELECT gt_event_id, performer, name, event_time_utc, venue_name, venue_city, venue_state
    FROM public.gotickets_event
    WHERE tevo_event_id IS NULL
      AND event_time_utc > now()
      AND event_time_utc < now() + make_interval(days => greatest(p_horizon_days, 1))
      AND upper(trim(coalesce(venue_state,''))) = ANY(us_states)
      AND coalesce(performer,'')  !~* 'parking'
      AND coalesce(name,'')       !~* 'parking'
      AND coalesce(venue_name,'') !~* 'parking'
      -- Only attempt events at a venue we actually track (cross_source_venue_map).
      -- Collapses the ~18k unmapped US backlog to the ~1k tevo-overlapping set, so a
      -- bounded sweep PROGRESSES through mappable events each run instead of re-scanning
      -- the unmappable small-venue long tail (which has no tevo row) forever. Uses the
      -- resolver's tier-1 canonical-name key; alias/prefix-only venues are the rare miss.
      AND lower(regexp_replace(coalesce(venue_name,''), '[^a-z0-9]+', '', 'gi'))
          IN (SELECT canonical_name FROM public.cross_source_venue_map WHERE canonical_name <> '')
    ORDER BY event_time_utc
    LIMIT greatest(p_max, 1)
  LOOP
    -- Loop-level wall-clock budget: a per-iteration SET LOCAL is a no-op on the
    -- running statement, so bound the LOOP (§scheduler-wedge, PROJECT_BIBLE §3).
    EXIT WHEN clock_timestamp() - v_start > interval '45 seconds';
    v_att := v_att + 1;

    v_match := public.gotickets_attempt_event_xref(
      r.gt_event_id, r.performer, r.name, r.event_time_utc,
      r.venue_name, r.venue_city, r.venue_state, p_apply, p_min_score);

    IF v_match IS NULL THEN v_no := v_no + 1; ELSE v_ok := v_ok + 1; END IF;
  END LOOP;

  -- parking is pre-filtered out of the driving query, so parking_skipped is 0 here;
  -- kept in the signature for parity with auto_match_sg_canonical_v3.
  RETURN QUERY SELECT v_att, v_ok, v_park, v_no,
    (extract(epoch FROM (clock_timestamp() - v_start)) * 1000)::int;
END $func$;

REVOKE EXECUTE ON FUNCTION public.match_gotickets_us_events(int,int,numeric,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_gotickets_us_events(int,int,numeric,boolean) TO service_role;

COMMENT ON FUNCTION public.match_gotickets_us_events(int,int,numeric,boolean) IS
  'Bounded, wall-clock-budgeted (45s) sweep mapping unmapped US-upcoming GoTickets events to tevo via gotickets_attempt_event_xref (matcher v3 reuse). Restricted to events at tracked venues (cross_source_venue_map) so it progresses through the mappable set. Scheduled by gotickets_match_us_6h. Mig 20260810184500.';


-- 3. Cron — 6-hourly supplementary matcher.
--
-- CADENCE RATIONALE (investigated 2026-08-10, live):
--   * GoTickets inflow ≈ 8.6k new events/day, but the tevo-mappable subset is small.
--   * The EXTERNAL collector already maps ≈127/day (mapped_via='instant_performer',
--     last map minutes ago) — this cron is SUPPLEMENTARY, catching the venue-anchored
--     matches that performer-only external matcher misses.
--   * Standing candidate set = unmapped US-upcoming events AT TRACKED VENUES ≈ 1,008
--     (≤180d; 273 ≤60d) — clearable in ~1 pass, so a 6-hourly sweep keeps mappings
--     fresh with negligible load. Major events carry long runway, so ≤6h latency from
--     "GoTickets event appears" → "mapped → collector polls it" is ample. Tighten later
--     if late-announced events need faster pickup.
--   * Minute :23 avoids the saturated :00/:02/:05/:07 marks and the :17/:40 clusters.
--
-- Wrapped in cron_should_fire + a top-level statement_timeout (a per-iteration SET LOCAL
-- is a no-op; the fn's own 45s loop budget is the real bound). PROJECT_BIBLE §3 / §5.
SELECT cron.schedule(
  'gotickets_match_us_6h',
  '23 */6 * * *',
  $cron$BEGIN; SET LOCAL statement_timeout='90s'; DO $b$ BEGIN
    IF NOT public.cron_should_fire('gotickets_match_us_6h') THEN RETURN; END IF;
    PERFORM public.match_gotickets_us_events(
      p_max => 1500, p_horizon_days => 180, p_min_score => 0.80, p_apply => true);
  END $b$; COMMIT;$cron$
);

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, work_check_sql, daily_max_fires, enabled, notes)
VALUES ('gotickets_match_us_6h', ARRAY[]::int[], 360, 360,
  -- only fire when there is unmapped tracked-venue US work to do
  $q$SELECT EXISTS (
       SELECT 1 FROM public.gotickets_event g
       WHERE g.tevo_event_id IS NULL AND g.event_time_utc > now()
         AND g.event_time_utc < now() + interval '180 days'
         AND coalesce(g.venue_name,'') !~* 'parking'
         AND lower(regexp_replace(coalesce(g.venue_name,''),'[^a-z0-9]+','','gi'))
             IN (SELECT canonical_name FROM public.cross_source_venue_map WHERE canonical_name <> ''))$q$,
  4, true,
  'Supplementary GoTickets→tevo matcher (matcher_v3_got): maps unmapped US-upcoming events at tracked venues so the external collector polls them. 6-hourly @ :23. Mig 20260810184500.')
ON CONFLICT (jobname) DO UPDATE
  SET enabled = EXCLUDED.enabled, notes = EXCLUDED.notes, updated_at = now();
