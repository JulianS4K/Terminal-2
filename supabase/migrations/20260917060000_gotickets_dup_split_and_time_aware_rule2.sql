-- Migration 20260917060000 · level:data-collection · lane:A1 · writes:tevo_event_utc() fn (new), event_mapper_resolve() fn (Rule 2 time-aware), gotickets_map_audit (new table), gotickets_dup_split() fn (new; writes gotickets_event.tevo_event_id/mapped_via/map_score, s4kcs_orders.gt_event_id/gt_mapped_via, aq_event_map.gotickets_event_id) · reads:events, venue_timezone, gotickets_event, gotickets_sales, s4kcs_orders, aq_event_map · pre:20260917050000
--
-- ============================================================================================
-- THE MATCHER MEASURED "NEAREST BY TIME" WITH LOCAL WALL TIMES TREATED AS UTC.
-- ============================================================================================
-- Operator 2026-09-17: "Investigate, fix and then fix the matcher so it doesn't happen again and merge."
--
-- WHAT WAS FOUND (all read-only, all measured on prod 2026-09-17 16:20–17:10Z).
--   235 TEvo events carried two or more GoTickets claimants (495 claimant rows, every one written
--   BEFORE the both-ways guard of mig 20260915260000 went live — the guard stops the symptom;
--   it does not stop the wrong FIRST claim, which is invisible to the double-claim count).
--   224 of the 495 came from Rule 2 of event_mapper_resolve ("venue_24h_performer"), 166 from
--   gt_map_events ("instant_performer"), 79 from matcher_v3_got.
--
--   With timezone-correct times (GoTickets publishes UTC; the TEvo mirror stores a NAIVE local
--   wall time for 94% of future events; the session runs in UTC):
--     147 dups: exactly one claimant sits on the TEvo start, the rest are off — two-show nights
--              (comedy clubs, theatres, Disney on Ice) and next-day runs
--      68 dups: every claimant at the same instant — tennis stadium sessions, Olympics,
--              doubleheaders (52), season-ticket/parking products (8), name-guard failures (4),
--              true GoTickets duplicate listings (4)
--      17 dups: no claimant on time;  3 dups: two on time and some off
--   Of the 198 off-time claimants: 108 have exactly ONE free TEvo event at their own local start
--   at the same venue (105 pass the name guard) — the second show EXISTS in TEvo and the matcher
--   missed it; 90 have no TEvo event at that time (88 name-consistent = a second show TEvo does
--   not carry; 2 plain wrong events).
--   The same defect outside the dup set: 108 single mappings via the two loose matchers sit
--   >60 min off the TEvo start (34 re-pointable, 74 GT-only shows).
--
-- ROOT CAUSE. Rule 2 computed  abs(e.occurs_at_local::timestamptz - p_event_time_utc)  and the
-- ±24 h window the same way. "2026-09-18T19:00:00" cast to timestamptz in a UTC session is 19:00Z,
-- but the show is 19:00 Pacific = 02:00Z next day. A 7pm GoTickets ticket (02:00Z) is then 7 h from
-- TEvo's "19:00" and 4.5 h from TEvo's "21:30", so the 9:30pm show wins. When TEvo carries only
-- one show that night, BOTH GoTickets shows land on it. Across the whole future book 31% of
-- venue_24h_performer mappings are >30 min off the TEvo start; instant_performer (minute-exact
-- on the same broken axis) is 98% on time only because it can only match when the offset
-- happens to cancel.
--
-- THE FIX, TWO PARTS.
--   1. public.tevo_event_utc(occurs_at_local, venue_id): the mirror row's start on the UTC axis —
--      the string's own offset when it has one, else venue_timezone (mig 20260915050000; covers
--      108,872 of 108,999 future events, 233 of the 235 dup events). NULL when the zone is
--      unknown, never a default zone (the venue_timezone rule).
--      Rule 2 now measures dist and the ±24 h window on that axis, sorts on-time candidates
--      first, and accepts the winner only when it is within 60 min of the source's start. A
--      candidate whose zone is unknown keeps the old comparison but wins only when it is the ONLY
--      candidate in the window. Nothing else in event_mapper_resolve changes (the file body is the
--      live prod body, md5 18ae6e80…, plus this block — prod had drifted from the tree by comment
--      stripping only).
--   2. public.gotickets_dup_split(p_apply, p_scope, p_tol_min): the data repair, with the same
--      time axis and an audit row for every change (public.gotickets_map_audit — reversible).
--        keep      claimant on time (≤ tol)
--        repoint   off-time claimant with exactly ONE free, name-consistent TEvo event at its own
--                  start at the same venue; both-ways guard at execution, and two re-points that
--                  want the same sibling are both refused
--        unmap     off-time claimant with NO TEvo event at its start (GT-only show, or a wrong
--                  event); season-ticket/parking/package products; same-instant claimants that
--                  fail aq_name_consistent
--        skip      TEvo placeholders (TBD / season / if necessary / home game N / 00:00 start),
--                  unknown zone, ambiguous siblings, and any off-time claimant that carries OUR
--                  GoTickets sales (three today; in each the TEvo side is the placeholder)
--      Knock-ons handled in the same run: s4kcs_orders rows whose gt_event_id was a changed
--      claimant are recomputed from the spine (sale_identity rows are never touched — our own
--      sale is stronger evidence than a matcher); aq_event_map rows whose gotickets_event_id was a
--      changed claimant are recomputed the same way.
--      p_scope: 'dups' (the 235), 'singles' (the 108 loose-matcher off-time singles), 'all'.
--
-- NOT TOUCHED: evo_gt_pipeline_match (evo_gt_v2_venue1to1) — its own exact-time logic, but 1,278
-- of its 23,723 future mappings are 6–25 h off the TEvo start on the corrected axis; measured,
-- reported, left for its own change. gt_map_events (instant_performer) is not scheduled.
--
-- ROLLBACK: functions — restore event_mapper_resolve from mig 20260912051500 (prod body);
--           data — gotickets_map_audit holds old/new per row; UPDATE back from it by run_id.
-- ============================================================================================

-- ---------------------------------------------------------------------------
-- 1. The TEvo mirror row's start on the UTC axis
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tevo_event_utc(p_occurs_at_local text, p_venue_id bigint)
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT CASE
           WHEN p_occurs_at_local IS NULL OR p_occurs_at_local !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' THEN NULL
           WHEN p_occurs_at_local ~ '(Z|[+-]\d\d:?\d\d)$' THEN p_occurs_at_local::timestamptz
           ELSE (SELECT (p_occurs_at_local::timestamp AT TIME ZONE v.iana_tz)
                   FROM public.venue_timezone v WHERE v.tevo_venue_id = p_venue_id)
         END;
$fn$;
REVOKE ALL ON FUNCTION public.tevo_event_utc(text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tevo_event_utc(text, bigint) TO service_role;
COMMENT ON FUNCTION public.tevo_event_utc(text, bigint) IS
  'events.occurs_at_local -> UTC instant: the string''s own offset when present, else venue_timezone. NULL when the zone is unknown; callers must treat NULL as "cannot decide" (mig 20260917060000).';

-- ---------------------------------------------------------------------------
-- 2. event_mapper_resolve — live prod body + time-aware Rule 2
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
       AND ((v_tzk AND v_dist <= 3600) OR (NOT v_tzk AND v_ncand = 1)) THEN
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
-- 3. Audit table — one row per changed row, reversible by run_id
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gotickets_map_audit (
  id           bigserial PRIMARY KEY,
  at           timestamptz NOT NULL DEFAULT now(),
  run_id       uuid        NOT NULL,
  surface      text        NOT NULL,   -- gotickets_event | s4kcs_orders | aq_event_map
  row_key      text        NOT NULL,
  scope        text,                   -- dup | single
  action       text        NOT NULL,   -- repoint | unmap | recompute | clear | skip
  reason       text,
  old_tevo     bigint, new_tevo bigint,
  old_gt       bigint, new_gt   bigint,
  via_before   text, score_before numeric,
  delta_min    numeric,
  note         text
);
REVOKE ALL ON public.gotickets_map_audit FROM anon, authenticated;
ALTER TABLE public.gotickets_map_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS gotickets_map_audit_service_only ON public.gotickets_map_audit;
CREATE POLICY gotickets_map_audit_service_only ON public.gotickets_map_audit FOR ALL TO service_role USING (true);
CREATE INDEX IF NOT EXISTS gotickets_map_audit_run_idx ON public.gotickets_map_audit (run_id);

-- ---------------------------------------------------------------------------
-- 4. The repair
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
       AND g.mapped_via IN ('venue_24h_performer', 'matcher_v3_got')
       AND NOT EXISTS (SELECT 1 FROM dupset d WHERE d.tevo_event_id = g.tevo_event_id)
  )
  SELECT p.scope, g.gt_event_id, g.tevo_event_id, g.name AS gt_name, g.event_time_utc AS gt_utc,
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
REVOKE ALL ON FUNCTION public.gotickets_dup_split(boolean, text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gotickets_dup_split(boolean, text, int) TO service_role;
COMMENT ON FUNCTION public.gotickets_dup_split(boolean, text, int) IS
  'Splits GoTickets double-claims and off-time loose-matcher mappings on the corrected time axis: keep / repoint / unmap / skip, audited in gotickets_map_audit. p_apply=false is a dry run (mig 20260917060000).';
