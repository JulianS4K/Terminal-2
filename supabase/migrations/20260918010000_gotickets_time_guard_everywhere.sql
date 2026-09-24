-- Migration 20260918010000 · level:data-collection · lane:A1 · writes:gotickets_time_ok() fn (new), event_mapper_resolve() fn (Rule 2 relaxed branch), gotickets_backfill_tevo_from_hub() fn (time guard), tickets_dev_resolve_clusters_to_tevo() fn (time guard), gotickets_dup_split() fn (keep rule + wider singles scope), gotickets_dup_split_restore() fn (new), event_mapper_switch.live_cap (1500 -> 1000 for gotickets_event) · reads:events, venue_timezone, gotickets_event, gotickets_map_audit · pre:20260917060000
--
-- ============================================================================================
-- ONE TIME GUARD FOR EVERY WRITER, A RELAXED BRANCH FOR STALE START TIMES, AND ROOM TO RUN.
-- ============================================================================================
-- Follow-up to mig 20260917060000 after its first night, measured 2026-09-18 09:05Z.
--
-- 1. The daily wide mapper (cron 548, event_mapper_run('gotickets_event')) did not finish: statement
--    timeout at 170 s, whole run rolled back, nothing written. It ran 167 s the day before. The switch
--    allows live_cap = 1,500 rows per run; the staged resolver costs ~100 ms per row (measured, 8 rows,
--    52 ms of which is event_mapper_resolve itself) -> ~150 s + overhead. The run was at capacity
--    before the time-aware rule and tipped over with it. live_cap -> 1,000 (data, event_mapper_switch);
--    the run then fits with a third in hand. Throughput per day drops from 1,500 to 1,000 evaluated
--    rows; yesterday's successful run wrote 117.
--
-- 2. Four rows the repair had unmapped were re-mapped overnight by writers that carry no time check:
--    gotickets_backfill_tevo_from_hub (3) and tickets_dev_resolve_clusters_to_tevo (1). Two of the
--    four are NBA games 90 and 120 min off -- one side's start time is stale (TV scheduling), the
--    same game, not a second show; two are 12 h and 17 h off (a bowl game with a placeholder time, a
--    multi-day golf championship). A flat 60-min rule is wrong for the first pair and the absence of
--    any rule is wrong for the second.
--
-- THE RULE, ONCE, IN public.gotickets_time_ok(gt_utc, gt_name, gt_venue_name, tevo_event_id):
--    zone unknown                         -> true  (cannot decide; the other guards apply)
--    |gt - tevo| <= 60 min                -> true
--    |gt - tevo| <= 120 min AND the normalised names are IDENTICAL AND the GoTickets name carries no
--      "cancel" token AND no other GoTickets row with the same name at the same venue sits closer
--      to that TEvo start                 -> true  (stale start time on one side)
--    otherwise                            -> false
--    The relaxed branch was sized on the 85 rows the repair unmapped as "no TEvo show at that time":
--    a 3-h / name-consistent version would have restored 8, three of them wrong (two "Come From Away -
--    Preface" pre-show talks, one "Cancelled: Rod Wave"); identical names + 2 h + no cancel token
--    restores the games and refuses those.
--
-- WIRED INTO: Rule 2 of event_mapper_resolve (GoTickets source, sole candidate in the window);
-- gotickets_backfill_tevo_from_hub (candidate filter); tickets_dev_resolve_clusters_to_tevo (name
-- filter); gotickets_dup_split (an off-time claimant that passes it is KEPT, reason
-- stale_time_single_event; the 'singles' scope now also covers hub_backfill and tdev_venue_day rows).
-- gotickets_dup_split_restore(p_run, p_apply) puts back rows a previous run unmapped that pass the
-- rule today, when their old TEvo event is still free (audited: action 'restore').
--
-- Every function body below is the tree copy (md5-verified against prod 2026-09-18 09:10Z:
-- event_mapper_resolve 9667ed3f…, gotickets_backfill_tevo_from_hub 2634db84…,
-- tickets_dev_resolve_clusters_to_tevo 80f468ed…, gotickets_dup_split 0a3082e8…) plus the marked lines.
--
-- ROLLBACK: functions from migs 20260917060000 / 20260916220000 / 20260917020000; live_cap back to
-- 1500; data via gotickets_map_audit by run_id.
-- ============================================================================================

-- ---------------------------------------------------------------------------
-- 1. The one time guard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gotickets_time_ok(p_gt_utc timestamptz, p_gt_name text, p_gt_venue_name text, p_tevo_event_id bigint)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
  WITH t AS (
    SELECT public.tevo_event_utc(e.occurs_at_local, e.venue_id) AS utc,
           regexp_replace(lower(public.unaccent(e.name)), '[^a-z0-9]+', ' ', 'g') AS tname
      FROM public.events e WHERE e.id = p_tevo_event_id
  )
  SELECT CASE
           WHEN t.utc IS NULL THEN true
           WHEN abs(extract(epoch FROM (p_gt_utc - t.utc))) <= 3600 THEN true
           WHEN abs(extract(epoch FROM (p_gt_utc - t.utc))) <= 7200
                AND regexp_replace(lower(public.unaccent(coalesce(p_gt_name, ''))), '[^a-z0-9]+', ' ', 'g') = t.tname
                AND coalesce(p_gt_name, '') !~* 'cancel'
                AND NOT EXISTS (
                  SELECT 1 FROM public.gotickets_event s
                   WHERE s.event_time_utc BETWEEN t.utc - interval '24 hours' AND t.utc + interval '24 hours'
                     AND s.event_time_utc <> p_gt_utc
                     AND lower(trim(coalesce(s.venue_name, ''))) = lower(trim(coalesce(p_gt_venue_name, '')))
                     AND regexp_replace(lower(public.unaccent(s.name)), '[^a-z0-9]+', ' ', 'g')
                         = regexp_replace(lower(public.unaccent(coalesce(p_gt_name, ''))), '[^a-z0-9]+', ' ', 'g')
                     AND abs(extract(epoch FROM (s.event_time_utc - t.utc))) < abs(extract(epoch FROM (p_gt_utc - t.utc))))
                THEN true
           ELSE false
         END
    FROM t;
$fn$;
REVOKE ALL ON FUNCTION public.gotickets_time_ok(timestamptz, text, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gotickets_time_ok(timestamptz, text, text, bigint) TO service_role;
COMMENT ON FUNCTION public.gotickets_time_ok(timestamptz, text, text, bigint) IS
  'May this GoTickets row (start, name, venue) map to this TEvo event? true within 60 min; true within 2 h when the names are identical, no cancel token, and no closer same-name GoTickets sibling (a stale start time, not a second show); true when the venue zone is unknown; else false (mig 20260918010000).';

-- ---------------------------------------------------------------------------
-- 2. event_mapper_resolve — Rule 2 gains the relaxed branch for GoTickets
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_mapper_resolve(p_source text, p_source_event_id bigint, p_name text, p_performer text, p_venue_name text, p_venue_city text, p_venue_state text, p_local_date date, p_event_time_utc timestamp with time zone, p_allow_identity boolean DEFAULT true, p_min_overlap numeric DEFAULT 0.5, p_source_venue_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(tevo_event_id bigint, method text, score numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_src     text    := lower(trim(coalesce(p_source, '')));
  v_name    text    := coalesce(p_name, '');
  v_venue   text    := nullif(trim(coalesce(p_venue_name, '')), '');
  v_nm      text    := public.event_mapper_norm_name(p_name);
  v_ntok    int;
  v_resched boolean := coalesce(p_name, '') ~* 'reschedul';
  v_num     text    := (regexp_match(coalesce(p_name, ''), '(?:session|game|match)\s*#?\s*(\d{1,3})', 'i'))[1];
  v_needle  text    := lower(trim(coalesce(nullif(trim(coalesce(p_performer, '')), ''), p_name, '')));
  v_vid     bigint;
  v_tevo    bigint;
  v_score   numeric;
  v_meth    text;
  v_n       int;
  v_day     date;
  v_hub_near boolean := false;
  v_dist    numeric;              -- mig 20260917060000: winner's true distance, seconds
  v_tzk     boolean;              -- mig 20260917060000: winner's zone known
  v_ncand   int;                  -- mig 20260917060000: candidates in the window
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_venue_name, '') ILIKE '%parking%' OR v_name ILIKE '%parking%'
     OR coalesce(p_performer, '') ILIKE '%parking%' THEN
    RETURN;
  END IF;
  IF p_allow_identity AND p_source_event_id IS NOT NULL THEN
    IF v_src IN ('tevo', 'evo') THEN
      tevo_event_id := p_source_event_id; method := 'identity_tevo'; score := 1.0;
      RETURN NEXT; RETURN;
    END IF;
    IF v_src IN ('gotickets', 'gt') THEN
      SELECT g.tevo_event_id INTO v_tevo FROM public.gotickets_event g
       WHERE g.gt_event_id = p_source_event_id AND g.tevo_event_id IS NOT NULL LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_gotickets_event'; END IF;
      IF v_tevo IS NULL THEN
        SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
         WHERE a.gotickets_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
         ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
        IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
      END IF;
    ELSIF v_src IN ('seatgeek', 'sg') THEN
      SELECT c.tevo_event_id INTO v_tevo FROM public.sg_events_canonical c
       WHERE c.sg_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_sg_canonical'; END IF;
      IF v_tevo IS NULL THEN
        SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
         WHERE a.sg_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
         ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
        IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
      END IF;
    ELSIF v_src IN ('tickpick', 'tp') THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.tp_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    ELSIF v_src IN ('vivid', 'vividseats', 'vivid seats', 'stubhub', 'sh', 'ticketmaster', 'tm', 'seatdata', 'sd') THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.tevo_event_id IS NOT NULL
         AND ((v_src IN ('vivid', 'vividseats', 'vivid seats') AND a.vivid_event_id = p_source_event_id)
           OR (v_src IN ('stubhub', 'sh')                      AND a.sh_event_id    = p_source_event_id)
           OR (v_src IN ('ticketmaster', 'tm')                 AND a.tm_event_id    = p_source_event_id)
           OR (v_src IN ('seatdata', 'sd')                     AND a.sd_event_id    = p_source_event_id))
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; method := v_meth; score := 1.0;
      RETURN NEXT; RETURN;
    END IF;
  END IF;
  IF v_name ~* '(\(date tbd\)|\btbd\b|if necessary)' THEN RETURN; END IF;
  IF p_local_date IS NULL AND p_event_time_utc IS NULL THEN RETURN; END IF;
  IF p_source_venue_id IS NOT NULL THEN
    SELECT m.tevo_venue_id INTO v_vid FROM public.cross_source_venue_map m
     WHERE (v_src IN ('gotickets', 'gt')      AND m.gotickets_venue_id = p_source_venue_id)
        OR (v_src IN ('seatgeek', 'sg')       AND m.sg_venue_id        = p_source_venue_id)
        OR (v_src IN ('tickpick', 'tp')       AND m.tickpick_venue_id  = p_source_venue_id)
     LIMIT 1;
  END IF;
  v_vid  := coalesce(v_vid, public.cross_source_venue_resolve(p_venue_name, p_venue_city, p_venue_state));
  SELECT count(*) INTO v_ntok FROM unnest(string_to_array(v_nm, ' ')) t WHERE length(t) > 2;
  IF p_local_date IS NOT NULL AND (v_venue IS NOT NULL OR v_vid IS NOT NULL) AND v_ntok >= 1 THEN
    WITH cand AS (
      SELECT e.id, e.last_seen,
             public.event_mapper_overlap(v_nm, e.name) AS ov,
             ((e.name ~* 'reschedul') = v_resched)::int
             + (v_num IS NOT NULL
                AND (regexp_match(e.name, '(?:session|game|match)\s*#?\s*(\d{1,3})', 'i'))[1] = v_num)::int AS keys
        FROM public.events e
       WHERE left(e.occurs_at_local, 10) = p_local_date::text
         AND (e.venue_name ILIKE v_venue OR (v_vid IS NOT NULL AND e.venue_id = v_vid))
         AND NOT (e.name ILIKE '%parking%' OR coalesce(e.venue_name, '') ILIKE '%parking%')
         AND public.aq_name_consistent(e.name, p_name)
    ), scored AS (
      SELECT c.*, count(*) OVER () AS n_cand FROM cand c
    ), good AS (
      SELECT s.*, count(*) OVER () AS n_good
        FROM scored s
       WHERE s.ov >= CASE WHEN s.n_cand = 1 THEN p_min_overlap ELSE greatest(p_min_overlap, 0.6) END
    ), ranked AS (
      SELECT g.*, row_number() OVER w AS rn, lead(g.keys) OVER w AS next_keys, lead(g.ov) OVER w AS next_ov,
             lead(g.last_seen) OVER w AS next_seen
        FROM good g
      WINDOW w AS (ORDER BY g.keys DESC, g.ov DESC, g.last_seen DESC NULLS LAST, g.id)
    )
    SELECT r.id, r.ov INTO v_tevo, v_score
      FROM ranked r
     WHERE r.rn = 1
       AND (r.n_good = 1 OR r.keys > coalesce(r.next_keys, -1) OR r.ov > coalesce(r.next_ov, -1)
            OR r.last_seen > coalesce(r.next_seen, '-infinity'::timestamptz) + interval '7 days');
    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; method := 'venue_day_name'; score := v_score;
      RETURN NEXT; RETURN;
    END IF;
  END IF;
  IF p_event_time_utc IS NOT NULL AND (v_venue IS NOT NULL OR v_vid IS NOT NULL) AND v_needle <> '' THEN
    -- Rule 2, TIME-AWARE (mig 20260917060000). Every candidate's start is put on the UTC axis by
    -- public.tevo_event_utc (offset in the string, else venue_timezone), so dist is a true distance.
    -- Before this, occurs_at_local (a naive local wall time for 94% of the mirror) was cast to
    -- timestamptz in a UTC session, i.e. treated as UTC: dist was off by the venue's offset and
    -- "nearest" picked the 9:30pm show for a 7pm ticket. 235 double-claims and 108 single
    -- off-time mappings were measured from exactly that.
    -- The winner must now be within 60 min of the source's start. A candidate whose zone is
    -- unknown keeps the naive comparison but wins only when it is the ONLY candidate.
    SELECT x.id, x.sc, x.n_same, x.dist, x.tz_known, x.n_cand
      INTO v_tevo, v_score, v_n, v_dist, v_tzk, v_ncand
      FROM (
        SELECT y.id, y.sc,
               count(*) FILTER (WHERE y.last_seen IS NULL OR y.last_seen >= y.max_seen - interval '7 days')
                 OVER (PARTITION BY y.occurs_at_local) AS n_same,
               count(*) OVER () AS n_cand,
               y.exact_venue, y.by_vid, y.dist, y.tz_known, y.active, y.last_seen
          FROM (
            SELECT e.id, e.occurs_at_local, e.last_seen,
                   0.80
                   + CASE WHEN v_vid IS NOT NULL AND e.venue_id = v_vid THEN 0.10 ELSE 0 END
                   + CASE WHEN lower(trim(coalesce(e.venue_name, ''))) = lower(v_venue) THEN 0.05 ELSE 0 END AS sc,
                   max(e.last_seen) OVER (PARTITION BY e.occurs_at_local) AS max_seen,
                   (lower(trim(coalesce(e.venue_name, ''))) = lower(v_venue)) AS exact_venue,
                   (v_vid IS NOT NULL AND e.venue_id = v_vid) AS by_vid,
                   (u.utc_ts IS NOT NULL) AS tz_known,
                   abs(extract(epoch FROM (coalesce(u.utc_ts, e.occurs_at_local::timestamptz) - p_event_time_utc))) AS dist,
                   coalesce(lc.is_active, true) AS active
              FROM public.events e
              LEFT JOIN public.event_lifecycle lc ON lc.event_id = e.id
              CROSS JOIN LATERAL (SELECT public.tevo_event_utc(e.occurs_at_local, e.venue_id) AS utc_ts) u
             WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
               AND left(e.occurs_at_local, 10) BETWEEN (p_event_time_utc - interval '2 days')::date::text
                                                  AND (p_event_time_utc + interval '2 days')::date::text
               AND NOT (e.name ILIKE '%parking%' OR coalesce(e.venue_name, '') ILIKE '%parking%')
               AND (v_name = '' OR public.aq_name_consistent(e.name, p_name))
               AND coalesce(u.utc_ts, e.occurs_at_local::timestamptz)
                     BETWEEN p_event_time_utc - interval '24 hours' AND p_event_time_utc + interval '24 hours'
               AND (p_local_date IS NULL OR left(e.occurs_at_local, 10) = p_local_date::text)
               AND (   (v_vid IS NOT NULL AND e.venue_id = v_vid)
                    OR lower(trim(coalesce(e.venue_name, ''))) = lower(v_venue)
                    OR lower(trim(coalesce(e.venue_name, ''))) LIKE lower(v_venue) || '%'
                    OR lower(v_venue) LIKE lower(trim(coalesce(e.venue_name, ''))) || '%')
               AND (   lower(coalesce(e.primary_performer_name, '')) LIKE '%' || v_needle || '%'
                    OR lower(coalesce(e.name, '')) LIKE '%' || v_needle || '%'
                    OR (char_length(coalesce(e.primary_performer_name, '')) >= 4
                        AND v_needle LIKE '%' || lower(e.primary_performer_name) || '%'))
          ) y
      ) x
     -- on-time candidates first, then the old venue preference, then true distance
     ORDER BY (x.tz_known AND x.dist <= 3600) DESC, x.exact_venue DESC, x.by_vid DESC, x.dist,
              x.active DESC, x.last_seen DESC NULLS LAST, x.id
     LIMIT 1;
    IF v_tevo IS NOT NULL AND v_n = 1
       AND ((v_tzk AND (v_dist <= 3600
                        -- mig 20260918010000: a GoTickets row may also match a single event on that
                        -- day whose start is a stale copy of its own (same name, <= 2 h, no closer
                        -- same-name GoTickets sibling) -- the NBA-TV-time case, not a second show
                        OR (v_src IN ('gotickets', 'gt') AND v_ncand = 1
                            AND public.gotickets_time_ok(p_event_time_utc, p_name, p_venue_name, v_tevo))))
            OR (NOT v_tzk AND v_ncand = 1)) THEN
      tevo_event_id := v_tevo; method := 'venue_24h_performer'; score := v_score;
      RETURN NEXT; RETURN;
    END IF;
    v_tevo := NULL;
  END IF;
  IF p_local_date IS NOT NULL AND v_ntok >= 2 THEN
    SELECT count(*), min(e.id) INTO v_n, v_tevo
      FROM public.events e
     WHERE left(e.occurs_at_local, 10) = p_local_date::text
       AND NOT (e.name ILIKE '%parking%' OR coalesce(e.venue_name, '') ILIKE '%parking%')
       AND public.event_mapper_norm_name(e.name) = v_nm
       AND public.aq_name_consistent(e.name, p_name);
    IF v_n = 1 THEN
      tevo_event_id := v_tevo; method := 'name_day_exact'; score := 0.70;
      RETURN NEXT; RETURN;
    END IF;
    v_tevo := NULL;
  END IF;
  v_day := coalesce(p_local_date, (p_event_time_utc AT TIME ZONE 'UTC')::date);
  v_hub_near := (v_venue IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.aq_event_map a
           WHERE lower(trim(a.venue_name)) = lower(v_venue)
             AND a.event_date >= (v_day - 1)::timestamp AND a.event_date < (v_day + 2)::timestamp))
    OR (v_venue IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.aq_event_map a
           WHERE a.event_date >= (v_day - 1)::timestamp AND a.event_date < (v_day + 2)::timestamp
             AND similarity(lower(coalesce(a.venue_name, '')), lower(v_venue)) >= 0.6));
  IF NOT v_hub_near THEN RETURN; END IF;
  FOR v_n IN 1..2 LOOP
    SELECT a.tevo_event_id, r.confidence, r.match_method INTO v_tevo, v_score, v_meth
      FROM public.match_to_aq_event_id(
             v_src,
             CASE WHEN p_allow_identity THEN p_source_event_id END,
             p_name, p_venue_name,
             coalesce(p_event_time_utc,
                      (p_local_date + CASE WHEN v_n = 1 THEN interval '12 hours' ELSE interval '19 hours' END)::timestamptz),
             NULL, NULL, NULL) r
      JOIN public.aq_event_map a
        ON a.aq_short_event_id = r.aq_short_event_id AND a.tevo_event_id IS NOT NULL
      LEFT JOIN public.events e ON e.id = a.tevo_event_id
     WHERE r.match_method IN ('tier0_tevo_id', 'tier1_direct_id')
        OR (v_ntok >= 1
            AND public.event_mapper_overlap(v_nm, coalesce(e.name, a.event_name)) >= p_min_overlap
            AND public.aq_name_consistent(coalesce(e.name, a.event_name), p_name))
     LIMIT 1;
    EXIT WHEN v_tevo IS NOT NULL OR p_event_time_utc IS NOT NULL;
  END LOOP;
  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; method := 'aq_' || coalesce(v_meth, 'match'); score := least(coalesce(v_score, 0.5), 0.95);
    RETURN NEXT;
  END IF;
  RETURN;
END $function$;

-- ---------------------------------------------------------------------------
-- 3. gotickets_backfill_tevo_from_hub — the hub is not authoritative about WHICH show
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gotickets_backfill_tevo_from_hub()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'gotickets_backfill_tevo_from_hub: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;

  WITH known AS (
    SELECT DISTINCT gotickets_event_id AS gt_id, tevo_event_id
      FROM public.aq_event_map
     WHERE gotickets_event_id IS NOT NULL AND tevo_event_id IS NOT NULL
  ), cand AS (
    SELECT g.gt_event_id, k.tevo_event_id, g.name AS gt_name, e.name AS tevo_name,
           g.event_time_utc AS gt_utc, g.venue_name AS gt_venue,   -- mig 20260918010000
           regexp_replace(lower(public.unaccent(g.name)),'[^a-z0-9]+','','g') AS gk,
           regexp_replace(lower(public.unaccent(e.name)),'[^a-z0-9]+','','g') AS tk
      FROM known k
      JOIN public.gotickets_event g ON g.gt_event_id = k.gt_id AND g.tevo_event_id IS NULL
      JOIN public.events e ON e.id = k.tevo_event_id
  ), ok AS (
    SELECT gt_event_id, min(tevo_event_id) AS tevo_event_id
      FROM cand
     -- The hub is NOT authoritative; re-apply the linkers' guards or this
     -- launders known-bad pairings into the catalogue. See 20260909210000 for
     -- the two classes this caught (US Open grounds-pass, season-ticket -> single game).
     WHERE gt_name   !~* 'camping|grandstand|grounds admission|grounds pass|pass only'
       AND tevo_name !~* 'camping|grandstand|grounds admission|grounds pass|pass only'
       AND gt_name !~* 'season tickets?' AND tevo_name !~* 'season tickets?'
       AND gt_name NOT ILIKE '%parking%' AND tevo_name NOT ILIKE '%parking%'
       AND ((tevo_name !~* 'session\s*\d+' OR gt_name !~* 'session\s*\d+')
            OR (regexp_match(lower(tevo_name),'session\s*(\d+)'))[1]
             = (regexp_match(lower(gt_name),'session\s*(\d+)'))[1])
       AND public.aq_name_consistent(public.unaccent(gt_name), public.unaccent(tevo_name))
       -- TIME GUARD (mig 20260918010000): the hub is not authoritative about WHICH show of a
       -- two-show night; refuse a pairing whose start is off the GoTickets start (see the fn).
       AND public.gotickets_time_ok(gt_utc, gt_name, gt_venue, tevo_event_id)
       AND (
         gk = tk
         OR (length(least(gk,tk)) >= 5 AND (gk LIKE tk || '%' OR tk LIKE gk || '%'))
         OR (SELECT count(*) FROM (
               SELECT unnest(string_to_array(trim(regexp_replace(lower(
                        regexp_replace(public.unaccent(tevo_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
               INTERSECT
               SELECT unnest(string_to_array(trim(regexp_replace(lower(
                        regexp_replace(public.unaccent(gt_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             ) q(tok) WHERE length(tok) >= 4) >= 2)
     GROUP BY 1
    HAVING count(DISTINCT tevo_event_id) = 1
  ), ok1 AS (
    -- BOTH-WAYS GUARD, HALF ONE (mig 20260916220000): a TEvo event wanted by TWO candidate
    -- GoTickets rows in this same statement is dropped for both. The NOT EXISTS below cannot
    -- catch this case -- it reads a statement-start snapshot in which neither row is written yet,
    -- so both pass and both land. First run on prod did exactly that: two nights of one show
    -- stamped to one TEvo event at the identical instant. This CTE is the fix.
    SELECT * FROM ok
     WHERE tevo_event_id IN (SELECT tevo_event_id FROM ok GROUP BY 1 HAVING count(*) = 1)
  )
  UPDATE public.gotickets_event g
     SET tevo_event_id = ok.tevo_event_id,
         mapped_via = 'hub_backfill',   -- provenance: derived, not GT-asserted
         mapped_at  = now()
    FROM ok1 ok
   WHERE g.gt_event_id = ok.gt_event_id
     AND g.tevo_event_id IS NULL        -- never overwrite
     -- BOTH-WAYS GUARD, HALF TWO: the TEvo event must not ALREADY be claimed by a different
     -- GoTickets row. Same line as the pipeline template in 20260915260000; without it a
     -- 15-minute cadence regrows the double-claims that guard exists to stop.
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2
                      WHERE g2.tevo_event_id = ok.tevo_event_id AND g2.gt_event_id <> ok.gt_event_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

-- ---------------------------------------------------------------------------
-- 4. tickets_dev_resolve_clusters_to_tevo — venue + local day + the time guard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tickets_dev_resolve_clusters_to_tevo(
  p_apply boolean DEFAULT false,
  p_limit int     DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_cap        int;
  v_candidates int := 0;
  v_venue_null int := 0;
  v_none       int := 0;
  v_one        int := 0;
  v_several    int := 0;
  v_name_fail  int := 0;
  v_claimed    int := 0;
  v_written    int := 0;
  v_started    timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);
  v_cap := greatest(1, least(2000, coalesce(p_limit, 200)));

  -- clusters whose GoTickets member is unmapped, nearest first (a mapping for next week is worth
  -- more than one for next spring, same ordering as the catalogue seed)
  DROP TABLE IF EXISTS _tdr;
  CREATE TEMP TABLE _tdr ON COMMIT DROP AS
  SELECT e.tdev_id, e.name, e.local_date, g.gt_event_id,
         g.event_time_utc AS gt_utc, g.venue_name AS gt_venue,   -- mig 20260918010000: for the time guard
         public.cross_source_venue_resolve(e.venue_name, e.venue_city, e.venue_state) AS vid
    FROM public.tickets_dev_event e
    JOIN public.tickets_dev_source_id s ON s.tdev_id = e.tdev_id AND s.marketplace = 'gotickets'
    JOIN public.gotickets_event g ON g.gt_event_id::text = s.source_event_id AND g.tevo_event_id IS NULL
   WHERE e.local_date >= current_date
     AND coalesce(e.name, '') !~* 'parking|shuttle|camping|grandstand|grounds admission|grounds pass|pass only|season tickets?'
   ORDER BY e.local_date
   LIMIT v_cap;
  SELECT count(*), count(*) FILTER (WHERE vid IS NULL) INTO v_candidates, v_venue_null FROM _tdr;

  -- the one TEvo event at that venue on that local day that the name rules accept -- or nothing
  DROP TABLE IF EXISTS _tdm;
  CREATE TEMP TABLE _tdm ON COMMIT DROP AS
  SELECT t.tdev_id, t.gt_event_id, t.name AS gt_name,
         count(ev.id) AS same_day,
         count(ev.id) FILTER (WHERE
               ev.name NOT ILIKE '%parking%'
           AND ev.name !~* 'camping|grandstand|grounds admission|grounds pass|pass only|season tickets?'
           AND ((ev.name !~* 'session\s*\d+' OR t.name !~* 'session\s*\d+')
                OR (regexp_match(lower(ev.name), 'session\s*(\d+)'))[1] = (regexp_match(lower(t.name), 'session\s*(\d+)'))[1])
           AND public.aq_name_consistent(public.unaccent(ev.name), public.unaccent(t.name))
           -- TIME GUARD (mig 20260918010000): venue + local day is not enough on a two-show night
           AND public.gotickets_time_ok(t.gt_utc, t.name, t.gt_venue, ev.id)) AS name_ok,
         min(ev.id) FILTER (WHERE
               ev.name NOT ILIKE '%parking%'
           AND ev.name !~* 'camping|grandstand|grounds admission|grounds pass|pass only|season tickets?'
           AND ((ev.name !~* 'session\s*\d+' OR t.name !~* 'session\s*\d+')
                OR (regexp_match(lower(ev.name), 'session\s*(\d+)'))[1] = (regexp_match(lower(t.name), 'session\s*(\d+)'))[1])
           AND public.aq_name_consistent(public.unaccent(ev.name), public.unaccent(t.name))
           -- TIME GUARD (mig 20260918010000): venue + local day is not enough on a two-show night
           AND public.gotickets_time_ok(t.gt_utc, t.name, t.gt_venue, ev.id)) AS tevo_event_id
    FROM _tdr t
    LEFT JOIN public.events ev
      ON ev.venue_id = t.vid AND ev.state = 'shown'
     AND left(ev.occurs_at_local, 10)::date = t.local_date
   WHERE t.vid IS NOT NULL
   GROUP BY t.tdev_id, t.gt_event_id, t.name, t.gt_utc, t.gt_venue;

  SELECT count(*) FILTER (WHERE same_day = 0),
         count(*) FILTER (WHERE name_ok = 1),
         count(*) FILTER (WHERE name_ok > 1),
         count(*) FILTER (WHERE same_day > 0 AND name_ok = 0),
         count(*) FILTER (WHERE name_ok = 1 AND EXISTS (SELECT 1 FROM public.gotickets_event g2
                             WHERE g2.tevo_event_id = _tdm.tevo_event_id AND g2.gt_event_id <> _tdm.gt_event_id))
    INTO v_none, v_one, v_several, v_name_fail, v_claimed
    FROM _tdm;

  IF NOT p_apply THEN
    RETURN jsonb_build_object(
      'applied', false, 'note', 'DRY RUN -- nothing written.',
      'candidates', v_candidates, 'venue_unresolved', v_venue_null, 'no_tevo_that_day', v_none,
      'would_write', v_one - v_claimed, 'refused', jsonb_build_object(
        'several_candidates', v_several, 'name_guard', v_name_fail, 'tevo_already_claimed', v_claimed),
      'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
  END IF;

  -- BOTH HALVES of the both-ways guard: half one drops any TEvo event wanted by two candidates
  -- in this statement (a NOT EXISTS cannot see them -- proven on prod 2026-09-16); half two
  -- refuses a TEvo event another GoTickets row already holds.
  WITH ok AS (
    SELECT gt_event_id, tevo_event_id FROM _tdm WHERE name_ok = 1
  ), ok1 AS (
    SELECT * FROM ok WHERE tevo_event_id IN (SELECT tevo_event_id FROM ok GROUP BY 1 HAVING count(*) = 1)
  )
  UPDATE public.gotickets_event g
     SET tevo_event_id = ok.tevo_event_id, mapped_via = 'tdev_venue_day', mapped_at = now()
    FROM ok1 ok
   WHERE g.gt_event_id = ok.gt_event_id
     AND g.tevo_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2
                      WHERE g2.tevo_event_id = ok.tevo_event_id AND g2.gt_event_id <> ok.gt_event_id);
  GET DIAGNOSTICS v_written = ROW_COUNT;

  RETURN jsonb_build_object(
    'applied', true,
    'candidates', v_candidates, 'venue_unresolved', v_venue_null, 'no_tevo_that_day', v_none,
    'written', v_written, 'refused', jsonb_build_object(
      'several_candidates', v_several, 'name_guard', v_name_fail, 'tevo_already_claimed', v_claimed),
    'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
END $fn$;

-- ---------------------------------------------------------------------------
-- 5. gotickets_dup_split — keep a stale-time single event; singles scope + hub writers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gotickets_dup_split(p_apply boolean DEFAULT false, p_scope text DEFAULT 'all', p_tol_min int DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_run   uuid := gen_random_uuid();
  v_out   jsonb;
  v_gt    jsonb; v_crm jsonb; v_aq jsonb;
  v_n_rep int := 0; v_n_unm int := 0; v_n_crm int := 0; v_n_aq int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_scope NOT IN ('dups', 'singles', 'all') THEN
    RAISE EXCEPTION 'p_scope must be dups | singles | all';
  END IF;

  DROP TABLE IF EXISTS pg_temp._c;
  CREATE TEMP TABLE _c ON COMMIT DROP AS
  WITH dupset AS (
    SELECT g.tevo_event_id FROM public.gotickets_event g
     WHERE g.tevo_event_id IS NOT NULL GROUP BY 1 HAVING count(*) > 1
  ), pop AS (
    SELECT g.gt_event_id, 'dup'::text AS scope
      FROM public.gotickets_event g JOIN dupset d USING (tevo_event_id)
     WHERE p_scope IN ('dups', 'all')
    UNION
    SELECT g.gt_event_id, 'single'
      FROM public.gotickets_event g
     WHERE p_scope IN ('singles', 'all')
       AND g.tevo_event_id IS NOT NULL AND g.event_time_utc > now()
       AND g.mapped_via IN ('venue_24h_performer', 'matcher_v3_got', 'hub_backfill', 'tdev_venue_day')   -- mig 20260918010000: + the two hub-derived writers
       AND NOT EXISTS (SELECT 1 FROM dupset d WHERE d.tevo_event_id = g.tevo_event_id)
  )
  SELECT p.scope, g.gt_event_id, g.tevo_event_id, g.name AS gt_name, g.event_time_utc AS gt_utc, g.venue_name AS gt_venue,
         g.mapped_via, g.map_score, e.name AS tevo_name, e.venue_id, e.occurs_at_local,
         public.tevo_event_utc(e.occurs_at_local, e.venue_id) AS tevo_utc,
         (e.name ~* '\mTBD\M|season|if necessary|home game|\(date' OR e.occurs_at_local ~ 'T00:00') AS tevo_placeholder,
         (g.name ~* 'season ticket|parking|shuttle|package|\mpass\M') AS product,
         public.aq_name_consistent(e.name, g.name) AS name_ok,
         EXISTS (SELECT 1 FROM public.gotickets_sales s WHERE s.gt_event_id = g.gt_event_id) AS has_sales,
         NULL::numeric AS delta_min, NULL::boolean AS on_time,
         NULL::bigint AS sib_id, NULL::int AS n_sib,
         NULL::text AS action, NULL::text AS reason
    FROM pop p JOIN public.gotickets_event g USING (gt_event_id)
    JOIN public.events e ON e.id = g.tevo_event_id;

  UPDATE _c SET delta_min = abs(extract(epoch FROM (gt_utc - tevo_utc))) / 60.0 WHERE tevo_utc IS NOT NULL;
  UPDATE _c SET on_time = (delta_min <= p_tol_min);

  UPDATE _c c SET n_sib = s.n, sib_id = s.one
    FROM (
      SELECT c2.gt_event_id, count(*) AS n, min(s.id) AS one
        FROM _c c2
        JOIN public.events s
          ON s.venue_id = c2.venue_id AND s.id <> c2.tevo_event_id AND coalesce(s.state, 'shown') = 'shown'
       WHERE c2.on_time IS FALSE
         AND abs(extract(epoch FROM (public.tevo_event_utc(s.occurs_at_local, s.venue_id) - c2.gt_utc))) / 60.0 <= p_tol_min
         AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2 WHERE g2.tevo_event_id = s.id)
         AND public.aq_name_consistent(s.name, c2.gt_name)
       GROUP BY c2.gt_event_id
    ) s
   WHERE s.gt_event_id = c.gt_event_id;

  UPDATE _c SET action = 'skip',   reason = 'no_tz'                WHERE action IS NULL AND tevo_utc IS NULL;
  UPDATE _c SET action = 'skip',   reason = 'placeholder'          WHERE action IS NULL AND tevo_placeholder;
  UPDATE _c SET action = 'unmap',  reason = 'product'              WHERE action IS NULL AND product;
  UPDATE _c SET action = 'unmap',  reason = 'name_guard'           WHERE action IS NULL AND on_time AND scope = 'dup' AND NOT name_ok AND NOT has_sales;
  UPDATE _c SET action = 'keep',   reason = 'on_time'              WHERE action IS NULL AND on_time;
  UPDATE _c SET action = 'repoint', reason = 'exact_time_sibling'  WHERE action IS NULL AND NOT on_time AND n_sib = 1;
  UPDATE _c SET action = 'skip',   reason = 'ambiguous_siblings'   WHERE action IS NULL AND NOT on_time AND n_sib >= 2;
  UPDATE _c SET action = 'skip',   reason = 'has_sales'            WHERE action IS NULL AND NOT on_time AND has_sales;
  -- mig 20260918010000: a single event whose start is a stale copy of the claimant's own (same name,
  -- <= 2 h, no closer same-name sibling) is the same show with one side's time out of date -- keep it
  UPDATE _c SET action = 'keep',   reason = 'stale_time_single_event' WHERE action IS NULL AND NOT on_time
     AND public.gotickets_time_ok(gt_utc, gt_name, gt_venue, tevo_event_id);
  UPDATE _c SET action = 'unmap',  reason = CASE WHEN name_ok THEN 'no_tevo_show_at_time' ELSE 'wrong_event' END
                                                                  WHERE action IS NULL AND NOT on_time;
  UPDATE _c SET action = 'skip', reason = 'sibling_contested'
   WHERE action = 'repoint'
     AND sib_id IN (SELECT sib_id FROM _c WHERE action = 'repoint' GROUP BY sib_id HAVING count(*) > 1);

  SELECT jsonb_object_agg(k, v) INTO v_gt
    FROM (SELECT scope || ':' || action || ':' || reason AS k, count(*) AS v FROM _c GROUP BY 1) t;

  IF p_apply THEN
    INSERT INTO public.gotickets_map_audit (run_id, surface, row_key, scope, action, reason, old_tevo, new_tevo, via_before, score_before, delta_min, note)
    SELECT v_run, 'gotickets_event', gt_event_id::text, scope, action, reason, tevo_event_id,
           CASE WHEN action = 'repoint' THEN sib_id END, mapped_via, map_score, delta_min, left(gt_name, 80)
      FROM _c WHERE action IN ('repoint', 'unmap');

    UPDATE public.gotickets_event g
       SET tevo_event_id = c.sib_id, mapped_via = 'dup_split_repoint', map_score = 0.90, mapped_at = now(), updated_at = now()
      FROM _c c
     WHERE c.action = 'repoint' AND g.gt_event_id = c.gt_event_id AND g.tevo_event_id = c.tevo_event_id
       AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2 WHERE g2.tevo_event_id = c.sib_id);
    GET DIAGNOSTICS v_n_rep = ROW_COUNT;

    UPDATE public.gotickets_event g
       SET tevo_event_id = NULL, mapped_via = 'dup_split_unmapped', map_score = NULL, mapped_at = now(), updated_at = now()
      FROM _c c
     WHERE c.action = 'unmap' AND g.gt_event_id = c.gt_event_id AND g.tevo_event_id = c.tevo_event_id;
    GET DIAGNOSTICS v_n_unm = ROW_COUNT;

    DROP TABLE IF EXISTS pg_temp._crm;
    CREATE TEMP TABLE _crm ON COMMIT DROP AS
    SELECT o.source, o.s4k_order_id, o.tevo_event_id, o.gt_event_id AS old_gt, o.gt_mapped_via,
           (SELECT CASE WHEN count(*) = 1 THEN min(g.gt_event_id) END
              FROM public.gotickets_event g WHERE g.tevo_event_id = o.tevo_event_id) AS new_gt
      FROM public.s4kcs_orders o
     WHERE o.gt_event_id IN (SELECT gt_event_id FROM _c WHERE action IN ('repoint', 'unmap'));

    INSERT INTO public.gotickets_map_audit (run_id, surface, row_key, action, reason, old_tevo, old_gt, new_gt, via_before)
    SELECT v_run, 's4kcs_orders', source || ':' || s4k_order_id,
           CASE WHEN gt_mapped_via = 'sale_identity' THEN 'skip' WHEN new_gt IS NULL THEN 'clear' ELSE 'recompute' END,
           CASE WHEN gt_mapped_via = 'sale_identity' THEN 'sale_identity_conflict' ELSE 'claimant_changed' END,
           tevo_event_id, old_gt, CASE WHEN gt_mapped_via = 'sale_identity' THEN old_gt ELSE new_gt END, gt_mapped_via
      FROM _crm;

    UPDATE public.s4kcs_orders o
       SET gt_event_id = c.new_gt,
           gt_mapped_via = CASE WHEN c.new_gt IS NULL THEN 'dup_split_cleared' ELSE 'dup_split_recompute' END,
           gt_mapped_at = now()
      FROM _crm c
     WHERE o.source = c.source AND o.s4k_order_id = c.s4k_order_id
       AND o.gt_mapped_via IS DISTINCT FROM 'sale_identity'
       AND o.gt_event_id IS DISTINCT FROM c.new_gt;
    GET DIAGNOSTICS v_n_crm = ROW_COUNT;

    DROP TABLE IF EXISTS pg_temp._aq;
    CREATE TEMP TABLE _aq ON COMMIT DROP AS
    SELECT a.id, a.tevo_event_id, a.gotickets_event_id AS old_gt,
           (SELECT CASE WHEN count(*) = 1 THEN min(g.gt_event_id) END
              FROM public.gotickets_event g WHERE g.tevo_event_id = a.tevo_event_id) AS new_gt
      FROM public.aq_event_map a
     WHERE a.gotickets_event_id IN (SELECT gt_event_id FROM _c WHERE action IN ('repoint', 'unmap'));

    INSERT INTO public.gotickets_map_audit (run_id, surface, row_key, action, reason, old_tevo, old_gt, new_gt)
    SELECT v_run, 'aq_event_map', id::text, CASE WHEN new_gt IS NULL THEN 'clear' ELSE 'recompute' END, 'claimant_changed',
           tevo_event_id, old_gt, new_gt FROM _aq;

    UPDATE public.aq_event_map a
       SET gotickets_event_id = q.new_gt, gotickets_map_score = CASE WHEN q.new_gt IS NULL THEN NULL ELSE a.gotickets_map_score END
      FROM _aq q
     WHERE a.id = q.id AND a.gotickets_event_id IS DISTINCT FROM q.new_gt;
    GET DIAGNOSTICS v_n_aq = ROW_COUNT;
  END IF;

  v_out := jsonb_build_object(
    'run_id', v_run, 'applied', p_apply, 'scope', p_scope, 'tol_min', p_tol_min,
    'decisions', coalesce(v_gt, '{}'::jsonb),
    'written', jsonb_build_object('repointed', v_n_rep, 'unmapped', v_n_unm, 'crm_rows', v_n_crm, 'aq_rows', v_n_aq),
    'double_claims_after', (SELECT count(*) FROM (SELECT tevo_event_id FROM public.gotickets_event WHERE tevo_event_id IS NOT NULL GROUP BY 1 HAVING count(*) > 1) x)
  );
  RETURN v_out;
END
$fn$;
-- ---------------------------------------------------------------------------
-- 6. Put back what a previous run unmapped that the rule now accepts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gotickets_dup_split_restore(p_run uuid, p_apply boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_new uuid := gen_random_uuid(); v_n int := 0; v_cand int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  DROP TABLE IF EXISTS pg_temp._r;
  CREATE TEMP TABLE _r ON COMMIT DROP AS
  SELECT au.row_key::bigint AS gt_event_id, au.old_tevo, au.reason
    FROM public.gotickets_map_audit au
    JOIN public.gotickets_event g ON g.gt_event_id = au.row_key::bigint AND g.tevo_event_id IS NULL
   WHERE au.run_id = p_run AND au.surface = 'gotickets_event' AND au.action = 'unmap'
     AND au.reason IN ('no_tevo_show_at_time')
     AND public.gotickets_time_ok(g.event_time_utc, g.name, g.venue_name, au.old_tevo)
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2 WHERE g2.tevo_event_id = au.old_tevo);
  SELECT count(*) INTO v_cand FROM _r;
  IF p_apply THEN
    INSERT INTO public.gotickets_map_audit (run_id, surface, row_key, action, reason, old_tevo, new_tevo, note)
    SELECT v_new, 'gotickets_event', gt_event_id::text, 'restore', 'time_rule_now_accepts', NULL, old_tevo, 'from run ' || p_run FROM _r;
    UPDATE public.gotickets_event g
       SET tevo_event_id = r.old_tevo, mapped_via = 'dup_split_restored', map_score = 0.85, mapped_at = now(), updated_at = now()
      FROM _r r
     WHERE g.gt_event_id = r.gt_event_id AND g.tevo_event_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2 WHERE g2.tevo_event_id = r.old_tevo);
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  RETURN jsonb_build_object('run_id', v_new, 'from_run', p_run, 'applied', p_apply, 'candidates', v_cand, 'restored', v_n);
END
$fn$;
REVOKE ALL ON FUNCTION public.gotickets_dup_split_restore(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gotickets_dup_split_restore(uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Room to run: the daily wide mapper at 1,000 rows fits its 170 s budget
-- ---------------------------------------------------------------------------
UPDATE public.event_mapper_switch
   SET live_cap = 1000,
       note = coalesce(note, '') || ' | 2026-09-18 live_cap 1500 -> 1000 (mig 20260918010000): the 08:50Z run hit the 170 s statement timeout at ~100 ms/row; 1,000 rows fits with a third in hand.'
 WHERE surface = 'gotickets_event' AND live_cap > 1000;
