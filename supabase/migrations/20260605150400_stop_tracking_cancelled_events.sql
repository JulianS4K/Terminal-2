-- 20260601120000_stop_tracking_cancelled_events.sql
--
-- Operator directive 2026-06-01 (A1): "create a cron to sweep for cancelled
-- events every 24 hours and stop tracking those events across all platforms."
--
-- Findings that shaped this migration (read-only investigation, 2026-06-01):
--   * A 24h sweep ALREADY exists: sweep_inactive_event_states() (cron jobid 192,
--     `sweep_inactive_event_states_daily`, 50 3 * * *). It flips events.state ->
--     'ignored' for any event whose lifecycle is cancelled/ghost_eliminated
--     (confidence >= 0.9). No new cron is needed — the cadence is covered.
--   * The GAP was enforcement: NONE of the collectors gated on events.state, so
--     flipping an event to 'ignored' did NOT stop polling. EVO/SG/TD each re-arm
--     within minutes. This migration makes events.state='ignored' the universal
--     "stop tracking" signal honored by all three collectors.
--   * Detection gap: derive_event_lifecycle only ghosted on staleness (>48/72h)
--     or 'TBD'+stale. Eliminated-team conditional games with a concrete opponent
--     name (e.g. the NYK @ Oklahoma City Thunder NBA Finals placeholders that
--     became ghosts when SAS won the WCF) stayed 'active' for days. We add an
--     elimination-aware rule grounded in ESPN: if the home performer maps to an
--     ESPN team that has NO scheduled ESPN game anywhere near this event's slot
--     (while its league still has near-term games), the team is out -> ghost.
--     Validated against the 2026 Finals: flags the 4 OKC ghosts, leaves all real
--     SAS/NYK games active (including SAS games not yet ESPN-xref-matched).
--
-- All four functions are CREATE OR REPLACE (idempotent). No schema changes.

-- ============================================================================
-- 1) derive_event_lifecycle: add elimination-aware ghost rule (Rule 4.5)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.derive_event_lifecycle(p_event_id bigint)
 RETURNS TABLE(status text, confidence numeric, reasons text[], is_active boolean, hrs_since_seen numeric, hrs_to_event numeric, ghost_score integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e RECORD;
  espn RECORD;
  v_reasons text[] := ARRAY[]::text[];
  v_status text;
  v_conf numeric := 0.5;
  v_active boolean := true;
  v_score int := 0;
  v_now timestamptz := NOW();
BEGIN
  SELECT id, name, occurs_at_local, state, last_seen, event_type, primary_performer_name, primary_performer_id
  INTO e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN
    status := 'unknown'; confidence := 0; reasons := ARRAY['event_not_found'];
    is_active := false; ghost_score := 0;
    RETURN NEXT; RETURN;
  END IF;

  hrs_since_seen := EXTRACT(EPOCH FROM (v_now - e.last_seen)) / 3600.0;
  hrs_to_event   := EXTRACT(EPOCH FROM (e.occurs_at_local::timestamptz - v_now)) / 3600.0;

  -- ESPN status (if linked)
  SELECT ees.state, ees.status_short, ees.home_score, ees.away_score
  INTO espn
  FROM event_xref ex
  LEFT JOIN LATERAL (
    SELECT state, status_short, home_score, away_score
    FROM espn_event_snapshots WHERE espn_event_id = ex.espn_event_id
    ORDER BY captured_at DESC LIMIT 1
  ) ees ON true
  WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  -- Rule 1: TEvo state explicit
  IF e.state IN ('cancelled', 'ignored') THEN
    status := 'cancelled'; v_active := false; v_conf := 0.95;
    v_reasons := array_append(v_reasons, format('tevo_state=%s', e.state));
  ELSIF e.state = 'rescheduled' THEN
    status := 'postponed'; v_active := false; v_conf := 0.9;
    v_reasons := array_append(v_reasons, 'tevo_state=rescheduled');

  -- Rule 2: ESPN says final + scores → completed
  ELSIF espn.state = 'post' AND espn.home_score IS NOT NULL THEN
    status := 'completed'; v_active := false; v_conf := 0.95;
    v_reasons := array_append(v_reasons, format('espn_post_score=%s-%s', espn.home_score, espn.away_score));

  -- Rule 3: Past start time + 6h grace
  ELSIF hrs_to_event < -6 THEN
    status := 'completed'; v_active := false; v_conf := 0.85;
    v_reasons := array_append(v_reasons, format('past_event_%shr', round(hrs_to_event::numeric, 1)));

  -- Rule 4: ESPN postponed status_short
  ELSIF espn.status_short IS NOT NULL AND (
        espn.status_short ILIKE '%postpon%' OR espn.status_short ILIKE '%PPD%'
        OR espn.status_short ILIKE '%cancel%') THEN
    status := 'postponed'; v_active := false; v_conf := 0.9;
    v_reasons := array_append(v_reasons, format('espn_status=%s', espn.status_short));

  -- Rule 4.5 (NEW, A1 2026-06-01): Elimination-aware ghost.
  -- A future playoff-style game whose HOME performer (a) was recently active
  -- (played an ESPN game in the last 21d), (b) belongs to a league whose
  -- postseason is still live (ESPN has near-term games), yet (c) has NO upcoming
  -- ESPN game near this event's slot => the team was knocked out => ghost.
  -- The recent-activity + playoff-name guards exclude off-season / season-opener
  -- / sparse-schedule false positives (NFL "Season Tickets", preseason, etc.).
  -- Window-bounded so a partially-loaded next-season schedule can't suppress it.
  ELSIF e.event_type = 'game' AND hrs_to_event > 0 AND e.primary_performer_id IS NOT NULL
    AND e.name ~* '(finals|playoff|conference|round [0-9]|if necessary|game [0-9])'
    AND EXISTS (
      SELECT 1
      FROM performer_espn_team_xref x
      WHERE x.tevo_performer_id = e.primary_performer_id
        -- (a) team was recently active (played an ESPN game in the last 21 days)
        AND EXISTS (
          SELECT 1 FROM espn_event_date_lookup l
          WHERE l.espn_league = x.espn_league
            AND (l.home_team_id = x.espn_team_id OR l.away_team_id = x.espn_team_id)
            AND l.game_at_utc BETWEEN v_now - interval '21 days' AND v_now)
        -- (b) league postseason still live (ESPN has near-term games for this league)
        AND EXISTS (
          SELECT 1 FROM espn_event_date_lookup l
          WHERE l.espn_league = x.espn_league
            AND l.game_at_utc > v_now
            AND l.game_at_utc < e.occurs_at_local::timestamptz + interval '10 days')
        -- (c) ...but THIS team plays none of them => out
        AND NOT EXISTS (
          SELECT 1 FROM espn_event_date_lookup l
          WHERE l.espn_league = x.espn_league
            AND (l.home_team_id = x.espn_team_id OR l.away_team_id = x.espn_team_id)
            AND l.game_at_utc > v_now
            AND l.game_at_utc < e.occurs_at_local::timestamptz + interval '10 days')
    ) THEN
    status := 'ghost_eliminated'; v_active := false; v_conf := 0.9;
    v_score := v_score + 4;
    v_reasons := array_append(v_reasons, 'home_team_eliminated_no_espn_game');

  -- Rule 5: Ghost playoff (sports + TBD in name + stale TEvo)
  ELSIF e.event_type = 'game' AND e.name ILIKE '%TBD%' AND hrs_since_seen > 48 THEN
    status := 'ghost_eliminated'; v_active := false; v_conf := 0.95;
    v_score := v_score + 5;
    v_reasons := array_append(v_reasons, format('tbd_in_name+stale_%shr', round(hrs_since_seen::numeric, 0)));

  -- Rule 6: Sports + stale + future date but no TBD (e.g. Game 6/7 of an already-decided series)
  ELSIF e.event_type = 'game' AND hrs_since_seen > 72 AND hrs_to_event > 0 THEN
    status := 'ghost_eliminated'; v_active := false; v_conf := 0.75;
    v_score := v_score + 3;
    v_reasons := array_append(v_reasons, format('sports_stale_%shr', round(hrs_since_seen::numeric, 0)));

  -- Rule 7: Active event (recent crawl)
  ELSE
    status := 'active'; v_active := true; v_conf := 0.9;
    IF hrs_since_seen <= 24 THEN
      v_reasons := array_append(v_reasons, format('fresh_%shr', round(hrs_since_seen::numeric, 1)));
    ELSE
      v_reasons := array_append(v_reasons, format('warm_%shr', round(hrs_since_seen::numeric, 1)));
      v_conf := 0.7;
    END IF;
  END IF;

  reasons     := v_reasons;
  confidence  := v_conf;
  is_active   := v_active;
  ghost_score := v_score;
  RETURN NEXT;
END $function$;

-- ============================================================================
-- 2) EVO collector gate: skip events flipped to 'ignored' by the sweep
-- ============================================================================
CREATE OR REPLACE FUNCTION public.evo_listings_poll_tick(p_max integer DEFAULT 30)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_n int := 0;
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  FOR r IN
    WITH ev AS (
      SELECT e.id,
             EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
      FROM public.events e
      LEFT JOIN public.evo_listings_poll_state ps ON ps.event_id = e.id
      WHERE e.occurs_at_local IS NOT NULL
        AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
        AND coalesce(e.state, 'shown') <> 'ignored'   -- A1 2026-06-01: stop tracking cancelled/ghost events
        AND ( e.is_chat_tracked = true
              OR EXISTS (SELECT 1 FROM public.watch_sources w WHERE w.event_id = e.id)
              OR EXISTS (SELECT 1 FROM public.latest_event_metrics m
                         WHERE m.event_id = e.id AND m.owned_tickets_count > 0) )
    ),
    due AS (
      SELECT ev.id, ev.last_polled_listings_at
      FROM ev
      JOIN LATERAL public.collector_band('EVO','listings', ev.hte) c ON true
      WHERE ev.last_polled_listings_at IS NULL
         OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    )
    SELECT id FROM due ORDER BY last_polled_listings_at NULLS FIRST LIMIT p_max
  LOOP
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id=' || r.id::text,
      '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state(event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.id, now(), 1, current_date)
      ON CONFLICT (event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

-- ============================================================================
-- 3) TD collector gate: drop ignored events from the target set (td_apply_targets
--    auto-deactivates ticketsdata_event_xref rows no longer in td_target_events)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.td_target_events()
 RETURNS TABLE(aq_short_event_id text, sh_event_id bigint, vivid_event_id bigint, sg_event_id bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH yankees AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%at New York Yankees%'
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_date > now()
      AND NOT EXISTS (SELECT 1 FROM public.events ev          -- A1 2026-06-01: stop tracking cancelled/ghost
                      WHERE ev.id = aem.tevo_event_id AND ev.state = 'ignored')
    ORDER BY aem.event_date ASC
    LIMIT 20
  ),
  knicks AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%knicks%'
      AND aem.event_date > now()
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_name NOT ILIKE '%season ticket%'
      AND NOT EXISTS (SELECT 1 FROM public.events ev          -- A1 2026-06-01: stop tracking cancelled/ghost
                      WHERE ev.id = aem.tevo_event_id AND ev.state = 'ignored')
      AND ( aem.event_name ILIKE '%finals%'
         OR aem.event_name ILIKE '%playoff%'
         OR aem.event_name ILIKE '%round %'
         OR aem.event_name ILIKE '%conference%'
         OR aem.event_name ILIKE '%if necessary%'
         OR aem.event_name ~* 'game [0-9]' )
  )
  SELECT y.aq_short_event_id, y.sh_event_id, y.vivid_event_id, y.sg_event_id FROM yankees y
  UNION
  SELECT k.aq_short_event_id, k.sh_event_id, k.vivid_event_id, k.sg_event_id FROM knicks k;
$function$;

-- ============================================================================
-- 4) SG collector gate: classify ignored events as 'SKIP' (poll tick polls only
--    tier <> 'SKIP'), as the first branch so it overrides any live tier
-- ============================================================================
CREATE OR REPLACE FUNCTION public.sg_classify_events()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
  v_us_states text[] := ARRAY[
    'AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME',
    'MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI',
    'SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY',
    'California','New York','Texas','Florida','Pennsylvania','Ohio','Illinois','Arizona','Washington',
    'Georgia','Massachusetts','North Carolina','Tennessee'
  ];
BEGIN
  WITH
  latest_snap AS (
    SELECT DISTINCT ON (s.event_id)
      s.event_id            AS tevo_event_id,
      s.evo_owned_tickets   AS owned_cnt,
      s.evo_tickets_count   AS listings_cnt
    FROM public.event_listing_snapshot_daily s
    WHERE s.event_id IS NOT NULL
    ORDER BY s.event_id,
             s.snapshot_date DESC,
             CASE s.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC
  ),

  latest_em AS (
    SELECT DISTINCT ON (em.event_id)
      em.event_id           AS tevo_event_id,
      em.owned_tickets_count AS owned_cnt,
      em.tickets_count      AS listings_cnt
    FROM public.event_metrics em
    ORDER BY em.event_id, em.captured_at DESC
  ),

  latest_owned_fallback AS (
    SELECT DISTINCT ON (em.event_id)
      em.event_id AS tevo_event_id,
      em.owned_tickets_count AS owned_cnt_fallback
    FROM public.event_metrics em
    WHERE em.owned_tickets_count > 0
      AND em.captured_at > now() - interval '30 days'
    ORDER BY em.event_id, em.captured_at DESC
  ),

  event_data AS (
    SELECT c.sg_event_id,
           c.sg_event_name,
           c.sg_venue_name,
           c.sg_venue_state,
           c.sg_datetime_utc,
           a.aq_short_event_id,
           coalesce(c.tevo_event_id,
                    (SELECT x.tevo_event_id FROM public.seatgeek_event_xref x
                     WHERE x.sg_event_id = c.sg_event_id LIMIT 1)) AS tevo_event_id,
           EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event
    FROM public.sg_events_canonical c
    LEFT JOIN LATERAL (
      SELECT aq_short_event_id FROM public.aq_event_map
      WHERE sg_event_id = c.sg_event_id
      ORDER BY (aq_short_event_id LIKE 'SYS-%') ASC, aq_short_event_id
      LIMIT 1
    ) a ON true
    WHERE c.sg_datetime_utc IS NOT NULL
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '365 days'
  ),

  event_metrics_cte AS (
    SELECT ed.*,
           coalesce(s.owned_cnt, m.owned_cnt, fb.owned_cnt_fallback, 0) AS owned_cnt,
           coalesce(s.listings_cnt, m.listings_cnt, 0) AS listings_cnt,
           (s.listings_cnt IS NOT NULL OR m.listings_cnt IS NOT NULL) AS has_listings_data
    FROM event_data ed
    LEFT JOIN latest_snap          s  ON s.tevo_event_id  = ed.tevo_event_id
    LEFT JOIN latest_em            m  ON m.tevo_event_id  = ed.tevo_event_id
    LEFT JOIN latest_owned_fallback fb ON fb.tevo_event_id = ed.tevo_event_id
  ),

  classified AS (
    SELECT em.*,
      CASE
        WHEN em.tevo_event_id IS NOT NULL AND EXISTS (       -- A1 2026-06-01: stop tracking cancelled/ghost
             SELECT 1 FROM public.events ev
             WHERE ev.id = em.tevo_event_id AND ev.state = 'ignored') THEN 'SKIP'
        WHEN em.sg_event_name ILIKE '%parking%'
             OR em.sg_venue_name ILIKE '%parking%' THEN 'SKIP'
        WHEN em.sg_event_name ~* '(cancelled|if necessary)' THEN 'SKIP'
        WHEN em.sg_event_name ~* '(\(date tbd\)|^TBD at )'
             AND em.tevo_event_id IS NULL THEN 'SKIP'
        WHEN em.hours_to_event >= 0 AND em.hours_to_event < 168
             AND em.owned_cnt = 0 AND em.listings_cnt > 150 THEN 'WATCH'
        WHEN em.hours_to_event >= 24
             AND em.hours_to_event < 8760
             AND em.owned_cnt = 0
             AND em.sg_venue_state = ANY(v_us_states) THEN 'TRACK_BLINDSPOT'
        ELSE
          (SELECT p.tier FROM public.sg_priority_policy p
           WHERE p.enabled = true
             AND em.hours_to_event >= coalesce(p.min_hours_to_event, -999999)
             AND em.hours_to_event <  coalesce(p.max_hours_to_event, 999999)
             AND (p.requires_owned = false OR em.owned_cnt > 0)
           ORDER BY p.sort_order LIMIT 1)
      END AS raw_tier
    FROM event_metrics_cte em
  ),

  tier_floored AS (
    SELECT c.*,
      CASE
        WHEN c.raw_tier = 'COLD'
         AND NOT c.has_listings_data
         AND c.hours_to_event BETWEEN 0 AND 720
        THEN 'COOL'
        ELSE coalesce(c.raw_tier, 'SKIP')
      END AS tier
    FROM classified c
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     tevo_event_id, owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         tevo_event_id, owned_cnt, listings_cnt, tier, hours_to_event, v_now
  FROM tier_floored WHERE sg_event_id IS NOT NULL
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
    sales_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day           = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$function$;
