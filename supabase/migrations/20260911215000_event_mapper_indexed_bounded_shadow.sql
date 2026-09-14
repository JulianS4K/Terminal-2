-- ============================================================================
-- Migration 20260911215000 — event mapper: indexed day rules, bounded shadow tick in its own transaction, live cap
-- Migration 20260911215000 · level:data-collection · lane:A1 · writes:events(indexes),cron.job
--
-- Lane:     A1 (data plane)
-- Touches:  events (two NEW indexes: local-day expression + venue_id), event_mapper_resolve() (REPLACE —
--           rule 2 day-prefix prefilter), event_mapper_run() (REPLACE — shadow branch = legacy only,
--           live cap 400), event_mapper_shadow_tick() (NEW), cron.job (the six mapper jobs re-pointed
--           to two explicit transactions each)
-- Pre-reqs: 20260911213000, 20260911214000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction (same session).
--
-- WHAT WENT WRONG (first live hour): s4kcs_map_events_10min's 18:16 run FAILED — "canceling
-- statement due to statement timeout" 170 s into the shadow replay — and because the replay ran in
-- the SAME transaction as the legacy mapper, the legacy's writes rolled back too. Root causes:
--   1. event_mapper_resolve cost 548 ms per call: `events` (18.9k rows) had NO index on the local
--      day or on venue_id, so rules 1/3 (left(occurs_at_local,10) = day) and rule 2 (venue) were
--      sequential scans with a regex per row. 2,000 keys x 0.55 s can never fit a cron slot.
--   2. The shadow replay was unbounded (2,000 keys) and coupled to the legacy transaction.
-- Mitigation at 18:30: the four cron surfaces were set to mode='legacy' (old mappers only).
-- Fix: (a) events_local_day_idx ((left(occurs_at_local,10))) + events_venue_id_idx (venue_id) and a
-- day-prefix prefilter in rule 2 so every day rule is an index lookup; (b) the replay moves to
-- event_mapper_shadow_tick(surface, max=300): <= 300 rows not replayed in 24 h, >= 30 min apart,
-- rotating through the residue; (c) each mapper cron = `BEGIN; ... event_mapper_run(); COMMIT;
-- BEGIN; SET LOCAL statement_timeout; ... event_mapper_shadow_tick(); COMMIT;` — the tick can time
-- out without touching the legacy write; (d) live mode capped at 400 rows per run.
-- After apply: set the four surfaces back to 'shadow' (operator step in the same session).
--
-- ROLLBACK: DROP INDEX events_local_day_idx, events_venue_id_idx; re-apply event_mapper_resolve from
--   20260911213000 and event_mapper_run from 20260911214000; DROP FUNCTION event_mapper_shadow_tick;
--   restore the cron commands from 20260911210000 §8.
-- ============================================================================

CREATE INDEX IF NOT EXISTS events_local_day_idx ON public.events ((left(occurs_at_local, 10)));
CREATE INDEX IF NOT EXISTS events_venue_id_idx  ON public.events (venue_id);
COMMENT ON INDEX public.events_local_day_idx IS 'Local-day lookups for every event mapper day rule (and s4kcs rule 8). A1 mig 20260911215000.';

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
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
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
  'THE event mapper (any marketplace event → tevo_event_id): identity (hub/canonical) → venue+local-day+overlap with twin tie-breaks → venue±24h performer (matcher v3) → exact name+day → AQ 4-tier. Pure/STABLE; unique-or-decline; parking + TBD guarded. A1 mig 20260911200000; rule-4 name guard mig 20260911213000; indexed day rules mig 20260911215000.';


CREATE OR REPLACE FUNCTION public.event_mapper_run(p_surface text, p_horizon_days int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_mode text; v_legacy jsonb := NULL; v_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT mode INTO v_mode FROM public.event_mapper_switch WHERE surface = p_surface;
  v_mode := coalesce(v_mode, 'shadow');
  IF v_mode = 'live' THEN
    -- bounded: 400 newest unmapped rows per run (a 10-min / hourly cadence drains any backlog)
    SELECT count(*) INTO v_n FROM public.event_mapper_map_surface(p_surface, true, 400) m WHERE m.tevo_event_id IS NOT NULL;
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n);
  END IF;
  -- shadow / legacy: ONLY the legacy mapper runs here. The shadow replay lives in
  -- event_mapper_shadow_tick(), which every cron calls in its OWN transaction, so a slow replay can
  -- never roll back a legacy write (2026-09-11 18:16: a 2000-key replay hit the 170 s cap and undid
  -- s4kcs_map_events' writes).
  CASE p_surface
    WHEN 's4kcs_orders'        THEN SELECT jsonb_agg(to_jsonb(t)) INTO v_legacy FROM public.s4kcs_map_events() t;
    WHEN 'n2s_items'           THEN SELECT jsonb_agg(to_jsonb(t)) INTO v_legacy FROM public.n2s_map_events(true) t;
    WHEN 'gotickets_event'     THEN
      v_legacy := jsonb_build_object('gt_map_events', public.gt_map_events(coalesce(p_horizon_days, 120)));
      IF p_horizon_days IS NOT NULL AND p_horizon_days > 180 THEN
        SELECT v_legacy || jsonb_build_object('match_gotickets_us_events', to_jsonb(t)) INTO v_legacy FROM public.match_gotickets_us_events(3000, p_horizon_days, 0.80, true) t;
      ELSE
        SELECT v_legacy || jsonb_build_object('match_gotickets_us_events', to_jsonb(t)) INTO v_legacy FROM public.match_gotickets_us_events(1500, 180, 0.80, true) t;
      END IF;
    WHEN 'sg_events_canonical' THEN SELECT to_jsonb(t) INTO v_legacy FROM public.auto_match_sg_canonical_v3() t;
    ELSE v_legacy := jsonb_build_object('legacy', 'none (AQ sweep :22 / backfill :40 own this surface)');
  END CASE;
  RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'legacy', v_legacy,
                            'shadow', 'see event_mapper_shadow_tick(surface) - separate transaction');
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_run(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_run(text, int) TO service_role;
COMMENT ON FUNCTION public.event_mapper_run(text, int) IS
  'The ONE mapper entry point every cron calls. Dispatches on event_mapper_switch.mode: legacy/shadow -> old mapper (the shadow replay is event_mapper_shadow_tick, own transaction); live -> resolver writes + cross-maps, 400 rows per run. A1 mig 20260911210000; 215000.';

CREATE OR REPLACE FUNCTION public.event_mapper_shadow_tick(p_surface text, p_max int DEFAULT 300)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_mode text; v_sel text; v_keys text[];
  v_agree int := 0; v_dis int := 0; v_ronly int := 0; v_lonly int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  SELECT mode INTO v_mode FROM public.event_mapper_switch WHERE surface = p_surface;
  IF coalesce(v_mode, 'shadow') <> 'shadow' THEN
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'replayed', 0, 'skipped', 'not in shadow');
  END IF;
  -- at most once per 30 min per surface, and only rows not replayed in the last 24 h (rotating
  -- coverage: 300 keys x 48 ticks/day covers the whole residue of every surface, without ever
  -- competing with the legacy mapper's slot)
  IF EXISTS (SELECT 1 FROM public.event_mapper_shadow_log l WHERE l.surface = p_surface AND l.at > now() - interval '30 minutes') THEN
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'replayed', 0, 'skipped', 'throttled 30 min');
  END IF;
  SELECT s.select_sql INTO v_sel FROM public.event_mapper_surface_sql(p_surface) s;
  -- Two kinds of rows, freshly-legacy-mapped FIRST (they grade the legacy: agree / disagree), then
  -- still-unmapped ones (resolver_only / declined) — each at most once per 24 h.
  EXECUTE format(
    'SELECT coalesce(array_agg(q.row_key), ''{}''::text[]) FROM (
       SELECT q.row_key FROM (%s) q
        WHERE (q.previous IS NULL OR q.ord > now() - interval ''24 hours'')
          AND NOT EXISTS (SELECT 1 FROM public.event_mapper_shadow_log l
                           WHERE l.surface = $1 AND l.row_key = q.row_key AND l.at > now() - interval ''24 hours'')
        ORDER BY (q.previous IS NOT NULL) DESC, q.ord DESC NULLS LAST LIMIT %s) q', v_sel, greatest(1, least(1000, p_max)))
    INTO v_keys USING p_surface;
  IF coalesce(array_length(v_keys, 1), 0) = 0 THEN
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'replayed', 0, 'skipped', 'nothing new');
  END IF;
  -- identity OFF: the hub / canonical tables must not answer for what the legacy mapper wrote
  INSERT INTO public.event_mapper_shadow_log (surface, row_key, legacy_tevo, resolver_tevo, method, score, verdict)
  SELECT p_surface, m.row_key, m.previous, m.tevo_event_id, m.method, m.score,
         CASE WHEN m.previous IS NOT NULL AND m.tevo_event_id = m.previous THEN 'agree'
              WHEN m.previous IS NOT NULL AND m.tevo_event_id IS NOT NULL  THEN 'disagree'
              WHEN m.previous IS NULL     AND m.tevo_event_id IS NOT NULL  THEN 'resolver_only'
              ELSE 'legacy_only' END
    FROM public.event_mapper_map_surface(p_surface, false, 1000, v_keys) m
   WHERE m.previous IS NOT NULL OR m.tevo_event_id IS NOT NULL;
  SELECT count(*) FILTER (WHERE verdict = 'agree'), count(*) FILTER (WHERE verdict = 'disagree'),
         count(*) FILTER (WHERE verdict = 'resolver_only'), count(*) FILTER (WHERE verdict = 'legacy_only')
    INTO v_agree, v_dis, v_ronly, v_lonly
    FROM public.event_mapper_shadow_log WHERE surface = p_surface AND at > now() - interval '1 minute';
  RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'replayed', array_length(v_keys, 1),
                            'agree', v_agree, 'disagree', v_dis, 'resolver_only', v_ronly, 'legacy_only', v_lonly);
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_shadow_tick(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_shadow_tick(text, int) TO service_role;
COMMENT ON FUNCTION public.event_mapper_shadow_tick(text, int) IS
  'The shadow DRY RUN, bounded: <= p_max (300) unmapped rows of a shadow-mode surface not replayed in 24 h, at most every 30 min, resolver with identity OFF, verdicts into event_mapper_shadow_log. Called by each mapper cron in its OWN transaction after event_mapper_run(). A1 mig 20260911215000.';

DO $cron$
DECLARE r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  FOR r IN
    SELECT jobid, jobname FROM cron.job
     WHERE jobname IN ('s4kcs_map_events_10min', 'n2s_map_events_5min', 'gt_map_events_hourly', 'gt_map_events_wide_daily',
                       'gotickets_match_us_6h', 'auto_match_sg_canonical_v3_hourly')
  LOOP
    -- two EXPLICIT transactions per job: legacy/live first and committed, then the bounded shadow tick
    PERFORM cron.alter_job(r.jobid, command := CASE r.jobname
      WHEN 's4kcs_map_events_10min'   THEN $c$BEGIN; SET LOCAL statement_timeout='170s'; SELECT public.event_mapper_run('s4kcs_orders'); COMMIT; BEGIN; SET LOCAL statement_timeout='120s'; SELECT public.event_mapper_shadow_tick('s4kcs_orders'); COMMIT;$c$
      WHEN 'n2s_map_events_5min'      THEN $c$BEGIN; SELECT public.n2s_order_identity_pull(); SELECT public.event_mapper_run('n2s_items'); SELECT public.n2s_gt_map_by_name(); SELECT public.n2s_pull_all_sources(); COMMIT; BEGIN; SET LOCAL statement_timeout='60s'; SELECT public.event_mapper_shadow_tick('n2s_items', 150); COMMIT;$c$
      WHEN 'gt_map_events_hourly'     THEN $c$BEGIN; SET LOCAL statement_timeout='170s'; SELECT public.event_mapper_run('gotickets_event'); COMMIT; BEGIN; SET LOCAL statement_timeout='120s'; SELECT public.event_mapper_shadow_tick('gotickets_event'); COMMIT;$c$
      WHEN 'gt_map_events_wide_daily' THEN $c$BEGIN; SET LOCAL statement_timeout='170s'; SELECT public.event_mapper_run('gotickets_event', 3650); COMMIT;$c$
      WHEN 'gotickets_match_us_6h'    THEN $c$BEGIN; SET LOCAL statement_timeout='170s'; DO $b$ BEGIN IF NOT public.cron_should_fire('gotickets_match_us_6h') THEN RETURN; END IF; PERFORM public.event_mapper_run('gotickets_event'); END $b$; COMMIT;$c$
      WHEN 'auto_match_sg_canonical_v3_hourly' THEN $c$BEGIN; DO $body$ BEGIN IF NOT public.cron_should_fire('auto_match_sg_canonical_v3_hourly') THEN RETURN; END IF; PERFORM public.event_mapper_run('sg_events_canonical'); END $body$; COMMIT; BEGIN; SET LOCAL statement_timeout='120s'; SELECT public.event_mapper_shadow_tick('sg_events_canonical'); COMMIT;$c$
      END);
  END LOOP;
END;
$cron$;
