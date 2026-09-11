-- ============================================================================
-- Migration 20260911161100 — map the last unmapped purchases through the EXISTING
--                            mapping tools (venue search → venue events → matcher v3)
--
-- Lane:     A1 (data plane) serving D0's deals surface
-- Touches:  our_purchases_map() (REPLACE — twin tie-breaks + matcher-v3 pass) ·
--           our_purchases_map_deep_enqueue(), our_purchases_map_deep_harvest() (CREATE FUNCTION) ·
--           tevo_venue_search (W — seeds venue rows, the SAME queue the CRM venue sweep uses) ·
--           cron_policy (+1) · cron.job (our_purchases_map_deep_daily)
--           Reads: gotickets_purchases, seatgeek_purchases, events, aq_event_map
--           Reuses: tevo_venue_search_enqueue/harvest, tevo_venue_alias_adopt,
--                   tevo_venue_events_enqueue(limit, since)/harvest, gotickets_attempt_event_xref,
--                   cross_source_venue_resolve, match_to_aq_event_id
-- Pre-reqs: 20260911161000, 20260909030000 (TEvo venue+event resolver), 20260810184500 (matcher v3)
--
-- NOT APPLIED. Authored 2026-09-11 (operator: "Map the final ones, look for venue in evo to
-- see if event exists under different naming" · "Look at existing mapping tool(s)"), then
-- the operator moved the mapping-tools work to a SEPARATE session ("lets split the mapping
-- tools into a separate chat"). Left here as the reviewed starting point for that session;
-- apply only from there. Parsed clean (libpg_query); never run against prod.
--
-- ⚠ READ-ONLY UPSTREAM (RULE 2): the only API calls are the ones the reused resolver
-- already makes — signed GET /v9/searches (venue) and GET /v9/events (venue events).
-- No new request shape, no new host, no new table of our own.
--
-- WHAT THE 54 LEFTOVERS WERE (diagnosed 2026-09-11 after mig 161000) and WHICH
-- EXISTING TOOL OWNS EACH:
--   (a) venue resolved, the event EXISTS in the mirror under another name or as a
--       rescheduled twin ("Boston Red Sox at Seattle Mariners (Friday Night F…)" vs
--       "… (Rescheduled…)"; "BNP Paribas Open - Session 10" vs "2027 BNP Paribas Open -
--       Session 9/10"; "WWE Friday Night Smackdown" vs "WWE RAW and SmackDown").
--       → our own event-match step, now with TWIN TIE-BREAKS (rescheduled flag must
--         agree, then Session/Game/Match number, then strictly-best overlap) and a
--         0.5 overlap floor when the venue+day has exactly one candidate; plus a pass
--         through `gotickets_attempt_event_xref` (matcher v3: venue-anchored ±24h,
--         performer/name overlap) for anything that still resists.
--   (b) venue resolved, the mirror has NOTHING that day — 17 World Cup matches
--       (MetLife/Hard Rock/Levi's/Gillette/Arrowhead), college football, Broadway.
--       → `tevo_venue_search` gets a row per such venue (status='resolved', the id
--         cross_source_venue_resolve already knows, ev_status=NULL) and
--         `tevo_venue_events_enqueue(60, p_since := earliest such purchase date)`
--         pulls that venue's events from that date; `tevo_venue_events_harvest()`
--         upserts them into `events` exactly as it does for the CRM sweep.
--   (c) the venue STRING did not resolve — "Manhattan Center Hammerstein Ballroom",
--       "Winter Garden Theatre - NY", "Pacha New York".
--       → the same `tevo_venue_search` queue, status='pending':
--         `tevo_venue_search_enqueue` asks /v9/searches, `tevo_venue_search_harvest`
--         resolves, `tevo_venue_alias_adopt` promotes into cross_source_venue_map
--         (PROJECT_BIBLE §4: the ONE venue xref — never create a rival). The mirror
--         already holds Hammerstein Ballroom (625) and Winter Garden Theatre - New York
--         (2012), so once the alias lands the event match resolves them.
-- What still cannot map after this is an event TEvo itself does not list (a club
-- night at Pacha, a "Date TBD" game) — left unmapped by design, never guessed.
--
-- Two entry points because pg_net is asynchronous: *_enqueue seeds + fires, *_harvest
-- (next run, or by hand a minute later) harvests + adopts + re-maps. Daily cron at
-- 09:15 UTC runs harvest-then-enqueue, slotted between the CRM venue sweep's own
-- enqueue (09:05) and harvest (09:35) so both share one request budget and one queue.
--
-- ROLLBACK: cron.unschedule('our_purchases_map_deep_daily'); DELETE the cron_policy row;
--   DROP FUNCTION our_purchases_map_deep_harvest(), our_purchases_map_deep_enqueue();
--   re-apply our_purchases_map() from mig 161000. Seeded tevo_venue_search rows are
--   ordinary queue rows (crm_orders=0) and may stay.
-- ============================================================================

-- ── 1. Mapper: twin tie-breaks + matcher-v3 pass ─────────────────────────────
CREATE OR REPLACE FUNCTION public.our_purchases_map()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_sg int := 0; v_gt int := 0; v_gt_ev int := 0; v_gt_aq int := 0; v_gt_v3 int := 0; v_sg_ev int := 0; v_sg_aq int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '150000', true);

  -- ── hub ids ────────────────────────────────────────────────────────────────
  WITH m AS (
    SELECT p.order_id, coalesce(c.tevo_event_id, a.tevo_event_id) AS tevo,
           CASE WHEN c.tevo_event_id IS NOT NULL THEN 'sg_events_canonical'
                WHEN a.tevo_event_id IS NOT NULL THEN 'aq_event_map' END AS via
    FROM public.seatgeek_purchases p
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.sg_events_canonical x WHERE x.sg_event_id = p.sg_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) c ON true
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.aq_event_map x WHERE x.sg_event_id = p.sg_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) a ON true
    WHERE p.tevo_event_id IS NULL AND p.sg_event_id IS NOT NULL
  ), u AS (
    UPDATE public.seatgeek_purchases p SET tevo_event_id = m.tevo, mapped_via = m.via, map_score = 1, updated_at = now()
    FROM m WHERE m.order_id = p.order_id AND m.tevo IS NOT NULL RETURNING 1
  ) SELECT count(*) INTO v_sg FROM u;

  WITH m AS (
    SELECT p.gt_purchase_id, coalesce(g.tevo_event_id, a.tevo_event_id) AS tevo,
           CASE WHEN g.tevo_event_id IS NOT NULL THEN 'gotickets_event'
                WHEN a.tevo_event_id IS NOT NULL THEN 'aq_event_map' END AS via
    FROM public.gotickets_purchases p
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.gotickets_event x WHERE x.gt_event_id = p.gt_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) g ON true
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.aq_event_map x WHERE x.gotickets_event_id = p.gt_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) a ON true
    WHERE p.tevo_event_id IS NULL AND p.gt_event_id IS NOT NULL
  ), u AS (
    UPDATE public.gotickets_purchases p SET tevo_event_id = m.tevo, mapped_via = m.via, map_score = 1, updated_at = now()
    FROM m WHERE m.gt_purchase_id = p.gt_purchase_id AND m.tevo IS NOT NULL RETURNING 1
  ) SELECT count(*) INTO v_gt FROM u;

  -- ── event match: venue (cross_source_venue_resolve) + local date + name overlap, twin tie-breaks ──
  WITH u AS (
    SELECT p.gt_purchase_id, p.event_name, p.venue_name, p.event_time_local::date AS ed,
           lower(regexp_replace(regexp_replace(p.event_name, '\s*\(.*?\)\s*', ' ', 'g'), '[^a-z0-9 ]', ' ', 'gi')) AS nm,
           (p.event_name ~* 'reschedul') AS is_resched,
           (regexp_match(p.event_name, '(?:session|game|match)\s*#?\s*(\d{1,3})', 'i'))[1] AS num,
           public.cross_source_venue_resolve(p.venue_name, p.venue_city, p.venue_state) AS vid
    FROM public.gotickets_purchases p WHERE p.tevo_event_id IS NULL AND p.event_time_local IS NOT NULL AND p.venue_name IS NOT NULL
  ),
  cand AS (
    SELECT u.gt_purchase_id, e.id AS tevo, lower(regexp_replace(e.name, '[^a-z0-9 ]', ' ', 'gi')) AS enm, u.nm,
           (e.name ~* 'reschedul') AS c_resched,
           (regexp_match(e.name, '(?:session|game|match)\s*#?\s*(\d{1,3})', 'i'))[1] AS c_num,
           u.is_resched, u.num
    FROM u JOIN public.events e
      ON left(e.occurs_at_local, 10) = u.ed::text
     AND (e.venue_name ILIKE u.venue_name OR (u.vid IS NOT NULL AND e.venue_id = u.vid))
  ),
  scored AS (
    SELECT c.*,
      (SELECT count(*) FROM unnest(string_to_array(c.nm, ' ')) t WHERE length(t) > 2 AND c.enm ~ ('\m' || t || '\M'))::numeric
        / NULLIF((SELECT count(*) FROM unnest(string_to_array(c.nm, ' ')) t WHERE length(t) > 2), 0) AS overlap,
      count(*) OVER (PARTITION BY c.gt_purchase_id) AS n_cand
    FROM cand c
  ),
  good AS (
    SELECT *, count(*) OVER (PARTITION BY gt_purchase_id) AS n_good
    FROM scored WHERE overlap >= CASE WHEN n_cand = 1 THEN 0.5 ELSE 0.6 END
  ),
  ranked AS (
    SELECT *,
      ((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int) AS keys,
      row_number() OVER (PARTITION BY gt_purchase_id ORDER BY ((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int) DESC, overlap DESC) AS rn,
      lead(((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int)) OVER (PARTITION BY gt_purchase_id ORDER BY ((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int) DESC, overlap DESC) AS next_keys,
      lead(overlap) OVER (PARTITION BY gt_purchase_id ORDER BY ((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int) DESC, overlap DESC) AS next_overlap
    FROM good
  ),
  pick AS (
    SELECT gt_purchase_id, tevo, overlap FROM ranked
    WHERE rn = 1 AND (n_good = 1 OR keys > coalesce(next_keys, -1) OR overlap > coalesce(next_overlap, -1))
  ),
  up AS (
    UPDATE public.gotickets_purchases p SET tevo_event_id = k.tevo, mapped_via = 'event_match', map_score = round(k.overlap, 3), updated_at = now()
    FROM pick k WHERE k.gt_purchase_id = p.gt_purchase_id RETURNING 1
  ) SELECT count(*) INTO v_gt_ev FROM up;

  WITH u AS (
    SELECT p.order_id, p.event_name, p.event_location AS venue_name, p.event_start::date AS ed,
           lower(regexp_replace(regexp_replace(p.event_name, '\s*\(.*?\)\s*', ' ', 'g'), '[^a-z0-9 ]', ' ', 'gi')) AS nm,
           (p.event_name ~* 'reschedul') AS is_resched,
           (regexp_match(p.event_name, '(?:session|game|match)\s*#?\s*(\d{1,3})', 'i'))[1] AS num,
           public.cross_source_venue_resolve(p.event_location, NULL, NULL) AS vid
    FROM public.seatgeek_purchases p WHERE p.tevo_event_id IS NULL AND p.event_start IS NOT NULL AND p.event_location IS NOT NULL
  ),
  cand AS (
    SELECT u.order_id, e.id AS tevo, lower(regexp_replace(e.name, '[^a-z0-9 ]', ' ', 'gi')) AS enm, u.nm,
           (e.name ~* 'reschedul') AS c_resched,
           (regexp_match(e.name, '(?:session|game|match)\s*#?\s*(\d{1,3})', 'i'))[1] AS c_num,
           u.is_resched, u.num
    FROM u JOIN public.events e
      ON left(e.occurs_at_local, 10) = u.ed::text
     AND (e.venue_name ILIKE u.venue_name OR (u.vid IS NOT NULL AND e.venue_id = u.vid))
  ),
  scored AS (
    SELECT c.*,
      (SELECT count(*) FROM unnest(string_to_array(c.nm, ' ')) t WHERE length(t) > 2 AND c.enm ~ ('\m' || t || '\M'))::numeric
        / NULLIF((SELECT count(*) FROM unnest(string_to_array(c.nm, ' ')) t WHERE length(t) > 2), 0) AS overlap,
      count(*) OVER (PARTITION BY c.order_id) AS n_cand
    FROM cand c
  ),
  good AS (
    SELECT *, count(*) OVER (PARTITION BY order_id) AS n_good
    FROM scored WHERE overlap >= CASE WHEN n_cand = 1 THEN 0.5 ELSE 0.6 END
  ),
  ranked AS (
    SELECT *,
      ((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int) AS keys,
      row_number() OVER (PARTITION BY order_id ORDER BY ((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int) DESC, overlap DESC) AS rn,
      lead(((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int)) OVER (PARTITION BY order_id ORDER BY ((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int) DESC, overlap DESC) AS next_keys,
      lead(overlap) OVER (PARTITION BY order_id ORDER BY ((c_resched = is_resched)::int + (num IS NOT NULL AND c_num = num)::int) DESC, overlap DESC) AS next_overlap
    FROM good
  ),
  pick AS (
    SELECT order_id, tevo, overlap FROM ranked
    WHERE rn = 1 AND (n_good = 1 OR keys > coalesce(next_keys, -1) OR overlap > coalesce(next_overlap, -1))
  ),
  up AS (
    UPDATE public.seatgeek_purchases p SET tevo_event_id = k.tevo, mapped_via = 'event_match', map_score = round(k.overlap, 3), updated_at = now()
    FROM pick k WHERE k.order_id = p.order_id RETURNING 1
  ) SELECT count(*) INTO v_sg_ev FROM up;

  -- ── matcher v3 (the sanctioned GoTickets → TEvo matcher; read-only call, p_apply=false) ──
  WITH u AS (
    SELECT p.gt_purchase_id,
           public.gotickets_attempt_event_xref(p.gt_event_id, p.performers->0->>'name', p.event_name, p.event_time_utc,
                                               p.venue_name, p.venue_city, p.venue_state, false, 0.5) AS tevo
    FROM public.gotickets_purchases p WHERE p.tevo_event_id IS NULL AND p.event_time_utc IS NOT NULL
  ),
  up AS (
    UPDATE public.gotickets_purchases p SET tevo_event_id = u.tevo, mapped_via = 'matcher_v3', map_score = 0.8, updated_at = now()
    FROM u WHERE u.gt_purchase_id = p.gt_purchase_id AND u.tevo IS NOT NULL RETURNING 1
  ) SELECT count(*) INTO v_gt_v3 FROM up;

  -- ── AQ 4-tier matcher for what is left ─────────────────────────────────────
  WITH u AS (
    SELECT gt_purchase_id, gt_event_id, event_name, venue_name, event_time_local::date AS ed
    FROM public.gotickets_purchases WHERE tevo_event_id IS NULL AND event_time_local IS NOT NULL
  ),
  m AS (
    SELECT u.gt_purchase_id, a.tevo_event_id AS tevo, r.confidence
    FROM u
    JOIN LATERAL public.match_to_aq_event_id('gotickets', u.gt_event_id, u.event_name, u.venue_name, u.ed::timestamptz, NULL, NULL, NULL) r ON true
    JOIN public.aq_event_map a ON a.aq_short_event_id = r.aq_short_event_id AND a.tevo_event_id IS NOT NULL
  ),
  up AS (
    UPDATE public.gotickets_purchases p SET tevo_event_id = m.tevo, mapped_via = 'aq_matcher', map_score = round(m.confidence, 3), updated_at = now()
    FROM m WHERE m.gt_purchase_id = p.gt_purchase_id RETURNING 1
  ) SELECT count(*) INTO v_gt_aq FROM up;

  WITH u AS (
    SELECT order_id, sg_event_id, event_name, event_location, event_start::date AS ed
    FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL AND event_start IS NOT NULL
  ),
  m AS (
    SELECT u.order_id, a.tevo_event_id AS tevo, r.confidence
    FROM u
    JOIN LATERAL public.match_to_aq_event_id('seatgeek', u.sg_event_id, u.event_name, u.event_location, u.ed::timestamptz, NULL, NULL, NULL) r ON true
    JOIN public.aq_event_map a ON a.aq_short_event_id = r.aq_short_event_id AND a.tevo_event_id IS NOT NULL
  ),
  up AS (
    UPDATE public.seatgeek_purchases p SET tevo_event_id = m.tevo, mapped_via = 'aq_matcher', map_score = round(m.confidence, 3), updated_at = now()
    FROM m WHERE m.order_id = p.order_id RETURNING 1
  ) SELECT count(*) INTO v_sg_aq FROM up;

  RETURN jsonb_build_object(
    'sg_mapped_now', v_sg + v_sg_ev + v_sg_aq, 'gt_mapped_now', v_gt + v_gt_ev + v_gt_v3 + v_gt_aq,
    'gt_by', jsonb_build_object('hub', v_gt, 'event_match', v_gt_ev, 'matcher_v3', v_gt_v3, 'aq_matcher', v_gt_aq),
    'sg_by', jsonb_build_object('hub', v_sg, 'event_match', v_sg_ev, 'aq_matcher', v_sg_aq),
    'sg_unmapped', (SELECT count(*) FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL),
    'gt_unmapped', (SELECT count(*) FROM public.gotickets_purchases WHERE tevo_event_id IS NULL));
END $fn$;
COMMENT ON FUNCTION public.our_purchases_map() IS
  'Fill tevo_event_id on unmapped purchases: hub ids → event match (venue via cross_source_venue_resolve, same local date, name-token overlap >= 0.5 single-candidate / 0.6 multi, twin tie-breaks on rescheduled flag + Session/Game/Match number) → gotickets_attempt_event_xref (matcher v3, read-only) → match_to_aq_event_id 4-tier. Ambiguous stays unmapped. A1 mig 20260911161100.';

-- ── 2. Deep pass, step 1: seed the EXISTING venue queue and fire its requests ──
CREATE OR REPLACE FUNCTION public.our_purchases_map_deep_enqueue()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_pending int := 0; v_resolved int := 0; v_since date; v_vs int := 0; v_ve int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  CREATE TEMP TABLE _need ON COMMIT DROP AS
  SELECT venue_name, max(venue_state) AS venue_state, min(ed) AS first_date, count(*) AS n,
         public.cross_source_venue_resolve(venue_name, max(venue_city), max(venue_state)) AS vid
  FROM (
    SELECT venue_name, venue_city, venue_state, event_time_local::date AS ed
    FROM public.gotickets_purchases WHERE tevo_event_id IS NULL AND venue_name IS NOT NULL AND event_time_local IS NOT NULL
    UNION ALL
    SELECT event_location, NULL, NULL, event_start::date
    FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL AND event_location IS NOT NULL AND event_start IS NOT NULL
  ) x GROUP BY venue_name;

  -- (c) unresolved venue STRINGS → the venue-search queue (status pending).
  INSERT INTO public.tevo_venue_search (venue_name_raw, state_hint, crm_orders, status)
  SELECT venue_name, venue_state, 0, 'pending' FROM _need WHERE vid IS NULL
  ON CONFLICT (venue_name_raw) DO NOTHING;
  GET DIAGNOSTICS v_pending = ROW_COUNT;

  -- (b) resolved venues whose purchase day has no mirror event → resolved row, events not yet pulled.
  INSERT INTO public.tevo_venue_search (venue_name_raw, state_hint, crm_orders, status, tevo_venue_id, ev_status)
  SELECT n.venue_name, n.venue_state, 0, 'resolved', n.vid, NULL
  FROM _need n
  WHERE n.vid IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.events e WHERE e.venue_id = n.vid AND left(e.occurs_at_local, 10) = n.first_date::text)
  ON CONFLICT (venue_name_raw) DO UPDATE
    SET ev_status = CASE WHEN tevo_venue_search.status = 'resolved' AND coalesce(tevo_venue_search.ev_status,'') <> 'requested' THEN NULL ELSE tevo_venue_search.ev_status END,
        updated_at = now();
  GET DIAGNOSTICS v_resolved = ROW_COUNT;

  SELECT min(first_date) INTO v_since FROM _need WHERE vid IS NOT NULL;

  -- Fire the existing resolvers. Both are bounded by their own limits.
  v_vs := public.tevo_venue_search_enqueue(20);
  IF v_since IS NOT NULL THEN
    v_ve := public.tevo_venue_events_enqueue(60, v_since);
  END IF;

  RETURN jsonb_build_object('venues_needing_help', (SELECT count(*) FROM _need),
                            'seeded_pending', v_pending, 'seeded_resolved', v_resolved,
                            'venue_searches_fired', v_vs, 'venue_event_pulls_fired', v_ve, 'events_since', v_since);
END $fn$;
REVOKE ALL ON FUNCTION public.our_purchases_map_deep_enqueue() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.our_purchases_map_deep_enqueue() TO service_role;
COMMENT ON FUNCTION public.our_purchases_map_deep_enqueue() IS
  'Seed tevo_venue_search from unmapped purchases (unresolved venue strings → pending; resolved venues with no mirror event on the purchase day → resolved/ev_status NULL) and fire the existing tevo_venue_search_enqueue + tevo_venue_events_enqueue(60, since). Async: harvest with our_purchases_map_deep_harvest(). A1 mig 20260911161100.';

-- ── 3. Deep pass, step 2: harvest through the existing tools, then re-map ────
CREATE OR REPLACE FUNCTION public.our_purchases_map_deep_harvest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_search jsonb; v_adopt int; v_ev record; v_map jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT jsonb_object_agg(outcome, n) INTO v_search FROM public.tevo_venue_search_harvest();
  v_adopt := public.tevo_venue_alias_adopt();
  SELECT * INTO v_ev FROM public.tevo_venue_events_harvest();
  v_map := public.our_purchases_map();
  RETURN jsonb_build_object('venue_search', coalesce(v_search, '{}'::jsonb), 'aliases_adopted', v_adopt,
                            'venues_harvested', v_ev.venues, 'events_upserted', v_ev.events_upserted) || v_map;
END $fn$;
REVOKE ALL ON FUNCTION public.our_purchases_map_deep_harvest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.our_purchases_map_deep_harvest() TO service_role;
COMMENT ON FUNCTION public.our_purchases_map_deep_harvest() IS
  'Run the existing harvesters (tevo_venue_search_harvest → tevo_venue_alias_adopt → tevo_venue_events_harvest) then our_purchases_map(). Pair with our_purchases_map_deep_enqueue(). A1 mig 20260911161100.';

-- ── 4. Daily self-heal, slotted inside the CRM venue sweep's window ──────────
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, notes)
VALUES ('our_purchases_map_deep_daily',
        ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 720, 720,
        'SELECT EXISTS (SELECT 1 FROM public.gotickets_purchases WHERE tevo_event_id IS NULL UNION ALL SELECT 1 FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL)',
        2, 'Harvest yesterday''s venue/event pulls, re-map purchases, then seed + fire today''s through the existing TEvo venue resolver. mig 20260911161100')
ON CONFLICT (jobname) DO UPDATE SET work_check_sql = excluded.work_check_sql, notes = excluded.notes, updated_at = now();

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('our_purchases_map_deep_daily')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'our_purchases_map_deep_daily');
    PERFORM cron.schedule('our_purchases_map_deep_daily', '15 9 * * *', $body$
      DO $b$ BEGIN IF NOT public.cron_should_fire('our_purchases_map_deep_daily') THEN RETURN; END IF;
        PERFORM public.our_purchases_map_deep_harvest();
        PERFORM public.our_purchases_map_deep_enqueue();
      END $b$;$body$);
  END IF;
END;
$cron$;
