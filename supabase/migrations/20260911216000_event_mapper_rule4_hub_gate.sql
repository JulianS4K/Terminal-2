-- ============================================================================
-- Migration 20260911216000 — event_mapper_resolve(): rule 4 asks the hub through indexes before calling match_to_aq_event_id
-- Migration 20260911216000 · level:data-collection · lane:A1 · writes:aq_event_map(index)
--
-- Lane:     A1 (data plane)
-- Touches:  aq_event_map (NEW expression index lower(trim(venue_name)), event_date),
--           event_mapper_resolve() (REPLACE — identical to mig 20260911215000 except the rule-4 gate + search_path gains `extensions` for similarity())
-- Pre-reqs: 20260911215000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction (same session).
--
-- Measured on prod 2026-09-11: a declined resolve cost 321 ms of which match_to_aq_event_id was
-- 163 ms x 2 anchors — it scans the whole hub (18,453 rows; the bible's "~7,271" is stale) with
-- lower(trim(venue_name)) equality and a similarity() pass, neither indexable as written, and it is
-- shared by five other callers so it is not rewritten here. The resolver now asks the hub through
-- idx_aq_event_map_date + the new expression index whether ANY row for this venue (exact, or
-- trigram-similar) sits within +/-1 day — a superset of everything tier2/tier3 could hit — and
-- calls the matcher only then. Identity tiers (source id) always run. Recall unchanged; the
-- common no-hub-row case drops from ~320 ms to a few ms.
--
-- ROLLBACK: DROP INDEX aq_event_map_venue_lower_date_idx; re-apply event_mapper_resolve from 20260911215000.
-- ============================================================================

CREATE INDEX IF NOT EXISTS aq_event_map_venue_lower_date_idx ON public.aq_event_map ((lower(trim(venue_name))), event_date);

CREATE OR REPLACE FUNCTION public.event_mapper_resolve(
  p_source          text,
  p_source_event_id bigint,
  p_name            text,
  p_performer       text,
  p_venue_name      text,
  p_venue_city      text,
  p_venue_state     text,
  p_local_date      date,
  p_event_time_utc  timestamptz,
  p_allow_identity  boolean DEFAULT true,
  p_min_overlap     numeric DEFAULT 0.5
)
RETURNS TABLE(tevo_event_id bigint, method text, score numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
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
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  -- Parking pseudo-events: TEvo merges parking into the main listing (§3 landmine).
  IF coalesce(p_venue_name, '') ILIKE '%parking%' OR v_name ILIKE '%parking%'
     OR coalesce(p_performer, '') ILIKE '%parking%' THEN
    RETURN;
  END IF;

  -- ── Rule 0: identity through the hub / canonical tables ───────────────────
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

  -- Date-unreliable names never match by date (identity above is the only path for them).
  IF v_name ~* '(\(date tbd\)|\btbd\b|if necessary)' THEN RETURN; END IF;
  IF p_local_date IS NULL AND p_event_time_utc IS NULL THEN RETURN; END IF;

  v_vid  := public.cross_source_venue_resolve(p_venue_name, p_venue_city, p_venue_state);
  SELECT count(*) INTO v_ntok FROM unnest(string_to_array(v_nm, ' ')) t WHERE length(t) > 2;

  -- ── Rule 1: venue + same LOCAL day + token overlap, twin tie-breaks ───────
  IF p_local_date IS NOT NULL AND v_venue IS NOT NULL AND v_ntok >= 1 THEN
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
         -- matchup guard shared with s4kcs rule 8 / SG matcher v3: "A at B" vs "C at B" on the
         -- same day at the same venue (doubleheaders, tournaments) must agree on the away side
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
    -- Liveness tie-break: TEvo re-lists an event under a new id and the mirror keeps both;
    -- the live one keeps getting seen. Two twins seen within 7 days of each other stay a tie.
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

  -- ── Rule 2: venue-anchored ±24h + performer/name containment (matcher v3) ──
  IF p_event_time_utc IS NOT NULL AND v_venue IS NOT NULL AND v_needle <> '' THEN
    SELECT x.id, x.sc, x.n_same INTO v_tevo, v_score, v_n
      FROM (
        SELECT y.id, y.sc,
               -- twins at one instant: a twin the mirror has not seen for 7+ days longer than
               -- the freshest one is a stale re-list, not a competitor (liveness tie-break)
               count(*) FILTER (WHERE y.last_seen IS NULL OR y.last_seen >= y.max_seen - interval '7 days')
                 OVER (PARTITION BY y.occurs_at_local) AS n_same,
               y.exact_venue, y.by_vid, y.dist, y.active, y.last_seen
          FROM (
            SELECT e.id, e.occurs_at_local, e.last_seen,
                   0.80
                   + CASE WHEN v_vid IS NOT NULL AND e.venue_id = v_vid THEN 0.10 ELSE 0 END
                   + CASE WHEN lower(trim(coalesce(e.venue_name, ''))) = lower(v_venue) THEN 0.05 ELSE 0 END AS sc,
                   max(e.last_seen) OVER (PARTITION BY e.occurs_at_local) AS max_seen,
                   (lower(trim(coalesce(e.venue_name, ''))) = lower(v_venue)) AS exact_venue,
                   (v_vid IS NOT NULL AND e.venue_id = v_vid) AS by_vid,
                   abs(extract(epoch FROM (e.occurs_at_local::timestamptz - p_event_time_utc))) AS dist,
                   coalesce(lc.is_active, true) AS active
              FROM public.events e
              LEFT JOIN public.event_lifecycle lc ON lc.event_id = e.id
             WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
               -- day-prefix prefilter first so events_local_day_idx serves the +/-24 h window
               AND left(e.occurs_at_local, 10) BETWEEN (p_event_time_utc - interval '2 days')::date::text
                                                  AND (p_event_time_utc + interval '2 days')::date::text
               AND NOT (e.name ILIKE '%parking%' OR coalesce(e.venue_name, '') ILIKE '%parking%')
               AND (v_name = '' OR public.aq_name_consistent(e.name, p_name))
               AND e.occurs_at_local::timestamptz BETWEEN p_event_time_utc - interval '24 hours'
                                                      AND p_event_time_utc + interval '24 hours'
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
     ORDER BY x.exact_venue DESC, x.by_vid DESC, x.dist, x.active DESC, x.last_seen DESC NULLS LAST, x.id
     LIMIT 1;
    IF v_tevo IS NOT NULL AND v_n = 1 THEN
      tevo_event_id := v_tevo; method := 'venue_24h_performer'; score := v_score;
      RETURN NEXT; RETURN;
    END IF;
    v_tevo := NULL;
  END IF;

  -- ── Rule 3: exact normalised name on the same local day, unique across venues ──
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

  -- ── Rule 4: AQ 4-tier → hub row that already carries a tevo id ────────────
  -- match_to_aq_event_id windows ±6 h around an instant. With only a local DATE known,
  -- anchor at local noon (covers 06:00–18:00) and then local 19:00 (13:00–01:00) — the
  -- two anchors together span every plausible start time without a third call.
  -- The hub's venue+time tiers carry NO name check, so a same-venue same-window neighbour (an
  -- 11:00 doubles session vs the 19:00 exhibition at Arthur Ashe — the first live wrong pick,
  -- 2026-09-11) can come back. The hub row's TEvo event (or the hub row itself) must overlap
  -- the source name at the same floor every other rule uses, and pass the matchup guard.
  -- Rule 4 gate (mig 20260911216000): match_to_aq_event_id scans the whole hub (18.5k rows, ~163 ms)
  -- and runs twice per declined row — 90% of a resolve. Its tier2/tier3 can only hit a hub row for
  -- this venue (exact or trigram-similar) within +/-6 h, so ask the hub through its indexes first
  -- (+/-1 day, a superset) and call it only when such a row exists. Identity tiers always run.
  v_day := coalesce(p_local_date, (p_event_time_utc AT TIME ZONE 'UTC')::date);
  v_hub_near := (p_allow_identity AND p_source_event_id IS NOT NULL)
    OR (v_venue IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.aq_event_map a
           WHERE lower(trim(a.venue_name)) = lower(v_venue)
             AND a.event_date >= (v_day - 1)::timestamp AND a.event_date < (v_day + 2)::timestamp))
    OR (v_venue IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.aq_event_map a
           WHERE a.event_date >= (v_day - 1)::timestamp AND a.event_date < (v_day + 2)::timestamp
             AND similarity(lower(coalesce(a.venue_name, '')), lower(v_venue)) >= 0.6));  -- 0.6: similarity() is real; 0.7::real < 0.7 double, so gate looser than the hub's 0.7
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
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric) TO service_role;
COMMENT ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric) IS
  'THE event mapper (any marketplace event → tevo_event_id): identity (hub/canonical) → venue+local-day+overlap with twin tie-breaks → venue±24h performer (matcher v3) → exact name+day → AQ 4-tier. Pure/STABLE; unique-or-decline; parking + TBD guarded. A1 mig 20260911200000; rule-4 name guard mig 20260911213000; indexed day rules mig 20260911215000; hub-gated rule 4 mig 20260911216000.';


