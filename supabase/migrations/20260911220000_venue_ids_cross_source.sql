-- ============================================================================
-- Migration 20260911220000 — venue ids mapped between every source: gotickets_venue_id + aq venue_short_id on the xref, hub fill-back, resolver takes the source's venue id
-- Migration 20260911220000 · level:data-collection · lane:A1 · writes:cross_source_venue_map,aq_venue_map · reads:gotickets_purchases,gotickets_sales,gotickets_event,events,sg_events_canonical,tickpick_orders
--
-- Lane:     A1 (data plane)
-- Touches:  cross_source_venue_map (NEW columns gotickets_venue_id, venue_short_id + partial indexes),
--           venue_xref_derive_from_events() (REPLACE — + GoTickets ids by event majority, + hub short ids, + aq_venue_map fill-back),
--           v_marketplace_venue_xref (REPLACE), event_mapper_surface_sql() / event_mapper_map_surface() (REPLACE — source_venue_id),
--           event_mapper_resolve() (DROP + CREATE: 12th arg p_source_venue_id; every existing 11-arg call keeps working)
--           event_mapper_apply() (DROP + CREATE: 9th arg p_source_venue_id — a strong hit teaches the xref the source's venue id)
-- Pre-reqs: 20260911219000, 20260908202400
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction ("for venues check for a venue mapping
-- table, if none create, and map the venue ids between each source").
--
-- THE TABLE EXISTS: cross_source_venue_map (1,342 rows, PK tevo_venue_id) is the venue xref — it already
-- carries sg_venue_id (881) and tickpick_venue_id (186), per-source name aliases, and id_provenance, and the
-- 0908 migration derives those ids by event agreement daily (cron venue_xref_derive_daily 06:23 UTC). What
-- it lacked: GoTickets ids (the 0908 note "GoTickets publishes no venue id" is true of the catalogue only —
-- the purchase + sales books carry venue_id on 76 / 377 distinct venues, 161 of them on mapped events) and
-- the AQ hub's venue_short_id, and nothing wrote the marketplace ids back onto aq_venue_map. Vivid publishes
-- no venue id at all; seatdata_venue_xref is empty. So: same table, two more columns filled by the same
-- daily derivation, and the resolver now takes the source's venue id and looks the TEvo venue up by ID
-- before falling back to the name (rules 1/2 accept a known id without a venue string).
--
-- ROLLBACK: re-apply event_mapper_resolve (11-arg) from 20260911218000 after DROP of the 12-arg one;
--           surface_sql + map_surface from 20260911219000; venue_xref_derive_from_events + view from 20260908202400;
--           ALTER TABLE public.cross_source_venue_map DROP COLUMN gotickets_venue_id, DROP COLUMN venue_short_id;
-- ============================================================================

ALTER TABLE public.cross_source_venue_map
  ADD COLUMN IF NOT EXISTS gotickets_venue_id bigint,
  ADD COLUMN IF NOT EXISTS venue_short_id     text;
COMMENT ON COLUMN public.cross_source_venue_map.gotickets_venue_id IS
  'GoTickets venue id, derived by event majority from gotickets_purchases / gotickets_sales rows on events mapped to this TEvo venue (venue_xref_derive_from_events, mig 20260911220000). Fill-only.';
COMMENT ON COLUMN public.cross_source_venue_map.venue_short_id IS
  'AQ hub venue id (aq_venue_map.venue_short_id) for this TEvo venue. Fill-only (mig 20260911220000).';
CREATE INDEX IF NOT EXISTS idx_csvm_gotickets_venue_id ON public.cross_source_venue_map (gotickets_venue_id) WHERE gotickets_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_csvm_tickpick_venue_id  ON public.cross_source_venue_map (tickpick_venue_id)  WHERE tickpick_venue_id  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_csvm_venue_short_id     ON public.cross_source_venue_map (venue_short_id)     WHERE venue_short_id     IS NOT NULL;

CREATE OR REPLACE FUNCTION public.venue_xref_derive_from_events(p_apply boolean DEFAULT true)
RETURNS TABLE(source text, action text, n integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer; v_conflicts integer := 0; v_txt text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'venue_xref_derive_from_events: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  DROP TABLE IF EXISTS _sg, _tp, _gt;
  -- Marketplace venue ids observed on events already mapped to a TEvo venue.
  -- Accepted only where every observation for that venue agrees.
  CREATE TEMP TABLE _sg ON COMMIT DROP AS
    SELECT e.venue_id AS tevo_venue_id,
           min((sgc.raw_event_jsonb->'venue'->>'id')::bigint) AS mp_id,
           count(*)::int AS ev
      FROM public.sg_events_canonical sgc
      JOIN public.events e ON e.id = sgc.tevo_event_id
     WHERE sgc.tevo_event_id IS NOT NULL
       AND e.venue_id IS NOT NULL
       AND sgc.raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$'
     GROUP BY e.venue_id
    HAVING count(DISTINCT (sgc.raw_event_jsonb->'venue'->>'id')::bigint) = 1;

  CREATE TEMP TABLE _tp ON COMMIT DROP AS
    SELECT e.venue_id AS tevo_venue_id,
           min((o.raw->'venue'->>'id')::bigint) AS mp_id,
           count(*)::int AS ev
      FROM public.tickpick_orders o
      JOIN public.events e ON e.id = o.tevo_event_id
     WHERE o.tevo_event_id IS NOT NULL
       AND e.venue_id IS NOT NULL
       AND o.raw->'venue'->>'id' ~ '^[0-9]+$'
     GROUP BY e.venue_id
    HAVING count(DISTINCT (o.raw->'venue'->>'id')::bigint) = 1;

  -- GoTickets DOES publish a venue id on its purchase + sales books (gotickets_purchases.venue_id,
  -- gotickets_sales.venue_id; the catalogue gotickets_event carries names only). mig 20260911220000:
  -- event majority — one GoTickets id explains >= 90% of the mapped events at this TEvo venue
  -- (unanimous, or >= 3 events). Tennis complexes are the known split (one GT id for Arthur Ashe +
  -- Louis Armstrong): those stay unmapped rather than guessed.
  CREATE TEMP TABLE _gt ON COMMIT DROP AS
    SELECT x.tevo_venue_id, x.top_id AS mp_id, x.votes::int AS ev, round(x.top::numeric / x.votes, 3) AS share
      FROM (SELECT o.tevo_venue_id, sum(o.n) AS votes, max(o.n) AS top, count(*) AS n_ids,
                   (array_agg(o.gt_venue_id ORDER BY o.n DESC))[1] AS top_id
              FROM (SELECT e.venue_id AS tevo_venue_id, p.venue_id AS gt_venue_id, count(*) AS n
                      FROM (SELECT venue_id, tevo_event_id FROM public.gotickets_purchases
                             WHERE tevo_event_id IS NOT NULL AND venue_id IS NOT NULL
                            UNION ALL
                            SELECT s.venue_id, g.tevo_event_id FROM public.gotickets_sales s
                              JOIN public.gotickets_event g ON g.gt_event_id = s.gt_event_id
                             WHERE g.tevo_event_id IS NOT NULL AND s.venue_id IS NOT NULL) p
                      JOIN public.events e ON e.id = p.tevo_event_id AND e.venue_id IS NOT NULL
                     GROUP BY 1, 2) o
             GROUP BY o.tevo_venue_id) x
     WHERE x.n_ids = 1 OR (x.top::numeric / x.votes >= 0.9 AND x.votes >= 3);
  -- one GoTickets id may explain only ONE TEvo venue
  DELETE FROM _gt g WHERE EXISTS (SELECT 1 FROM _gt o WHERE o.mp_id = g.mp_id AND o.tevo_venue_id <> g.tevo_venue_id);

  -- A pre-existing id that disagrees is NEVER overwritten — report it instead.
  SELECT count(*) INTO v_conflicts
    FROM (
      SELECT 1 FROM _sg s JOIN public.cross_source_venue_map m USING (tevo_venue_id)
        WHERE m.sg_venue_id IS NOT NULL AND m.sg_venue_id <> s.mp_id
      UNION ALL
      SELECT 1 FROM _tp t JOIN public.cross_source_venue_map m USING (tevo_venue_id)
        WHERE m.tickpick_venue_id IS NOT NULL AND m.tickpick_venue_id <> t.mp_id
      UNION ALL
      SELECT 1 FROM _gt g JOIN public.cross_source_venue_map m USING (tevo_venue_id)
        WHERE m.gotickets_venue_id IS NOT NULL AND m.gotickets_venue_id <> g.mp_id
    ) c;

  IF NOT p_apply THEN
    RETURN QUERY SELECT 'seatgeek'::text, 'derivable'::text, (SELECT count(*)::int FROM _sg);
    RETURN QUERY SELECT 'tickpick'::text, 'derivable'::text, (SELECT count(*)::int FROM _tp);
    RETURN QUERY SELECT 'gotickets'::text, 'derivable'::text, (SELECT count(*)::int FROM _gt);
    RETURN QUERY SELECT 'all'::text,      'conflicts'::text, v_conflicts;
    RETURN;
  END IF;

  -- New venues. canonical_name / sources_count are GENERATED — never listed.
  WITH need AS (
    SELECT tevo_venue_id FROM _sg
    UNION
    SELECT tevo_venue_id FROM _tp
    UNION
    SELECT tevo_venue_id FROM _gt
  ), src AS (
    SELECT DISTINCT ON (e.venue_id)
           e.venue_id AS tevo_venue_id, e.venue_name, e.venue_location, e.state
      FROM public.events e JOIN need n ON n.tevo_venue_id = e.venue_id
     WHERE e.venue_name IS NOT NULL
     ORDER BY e.venue_id, e.id DESC
  )
  INSERT INTO public.cross_source_venue_map
        (tevo_venue_id, tevo_venue_name, tevo_venue_location, state)
  SELECT s.tevo_venue_id, s.venue_name, s.venue_location, s.state
    FROM src s
   WHERE NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                      WHERE m.tevo_venue_id = s.tevo_venue_id)
  ON CONFLICT (tevo_venue_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'all'::text, 'venues_inserted'::text, v_n;

  UPDATE public.cross_source_venue_map m
     SET sg_venue_id = s.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('sg',
           jsonb_build_object('method','event_agreement','events',s.ev,'derived_at',now())),
         updated_at = now()
    FROM _sg s
   WHERE m.tevo_venue_id = s.tevo_venue_id
     AND m.sg_venue_id IS NULL;          -- fill-only
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'seatgeek'::text, 'ids_filled'::text, v_n;

  UPDATE public.cross_source_venue_map m
     SET tickpick_venue_id = t.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('tickpick',
           jsonb_build_object('method','event_agreement','events',t.ev,'derived_at',now())),
         updated_at = now()
    FROM _tp t
   WHERE m.tevo_venue_id = t.tevo_venue_id
     AND m.tickpick_venue_id IS NULL;    -- fill-only
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'tickpick'::text, 'ids_filled'::text, v_n;

  UPDATE public.cross_source_venue_map m
     SET gotickets_venue_id = g.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('gotickets',
           jsonb_build_object('method','event_majority','events',g.ev,'share',g.share,'derived_at',now())),
         updated_at = now()
    FROM _gt g
   WHERE m.tevo_venue_id = g.tevo_venue_id
     AND m.gotickets_venue_id IS NULL;   -- fill-only
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'gotickets'::text, 'ids_filled'::text, v_n;

  -- The AQ hub's venue short id onto the xref row, and the xref's marketplace ids back onto the
  -- hub's aq_venue_map — every id for one venue readable from either side (mig 20260911220000).
  UPDATE public.cross_source_venue_map m
     SET venue_short_id = a.venue_short_id, updated_at = now()
    FROM (SELECT DISTINCT ON (tevo_venue_id) tevo_venue_id, venue_short_id FROM public.aq_venue_map
           WHERE tevo_venue_id IS NOT NULL AND venue_short_id IS NOT NULL ORDER BY tevo_venue_id, venue_short_id) a
   WHERE m.tevo_venue_id = a.tevo_venue_id AND m.venue_short_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'aq'::text, 'short_ids_filled'::text, v_n;

  UPDATE public.aq_venue_map a
     SET sg_venue_id       = coalesce(a.sg_venue_id, m.sg_venue_id),
         tickpick_venue_id = coalesce(a.tickpick_venue_id, m.tickpick_venue_id)
    FROM public.cross_source_venue_map m
   WHERE m.tevo_venue_id = a.tevo_venue_id
     AND ((a.sg_venue_id IS NULL AND m.sg_venue_id IS NOT NULL) OR (a.tickpick_venue_id IS NULL AND m.tickpick_venue_id IS NOT NULL));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'aq'::text, 'aq_venue_map_ids_filled'::text, v_n;

  -- GoTickets NAME aliases from the catalogue (which carries names only), same event-agreement route.
  WITH gt AS (
    SELECT e.venue_id AS tevo_venue_id,
           jsonb_agg(DISTINCT g.venue_name) AS aliases
      FROM public.gotickets_event g
      JOIN public.events e ON e.id = g.tevo_event_id
     WHERE g.tevo_event_id IS NOT NULL AND e.venue_id IS NOT NULL
       AND g.venue_name IS NOT NULL AND g.venue_name <> ''
     GROUP BY e.venue_id
  )
  UPDATE public.cross_source_venue_map m
     SET gotickets_aliases = gt.aliases, updated_at = now()
    FROM gt
   WHERE m.tevo_venue_id = gt.tevo_venue_id
     AND m.gotickets_aliases IS DISTINCT FROM gt.aliases;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'gotickets'::text, 'aliases_set'::text, v_n;

  RETURN QUERY SELECT 'all'::text, 'conflicts_not_overwritten'::text, v_conflicts;

  IF v_conflicts > 0 THEN
    PERFORM public.bot_chat_log(
      p_level      => 'data-collection',
      p_lane       => 'A1',
      p_event_type => 'flag',
      p_message    => format('venue_xref_derive_from_events: %s marketplace venue id(s) '
                          || 'disagree with a value already in cross_source_venue_map. The existing '
                          || 'value was KEPT. Adjudicate before trusting either.', v_conflicts));
  END IF;
END $function$;

REVOKE ALL ON FUNCTION public.venue_xref_derive_from_events(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_xref_derive_from_events(boolean) TO service_role;

CREATE OR REPLACE VIEW public.v_marketplace_venue_xref AS
SELECT m.tevo_venue_id,
       m.tevo_venue_name,
       m.canonical_name,
       m.city, m.state, m.country,
       m.venue_short_id,       -- AQ hub venue id (aq_venue_map)
       m.sg_venue_id,
       m.tickpick_venue_id,
       m.gotickets_venue_id,   -- from the GoTickets purchase + sales books (mig 20260911220000)
       m.sg_aliases,
       m.tickpick_aliases,
       m.vivid_aliases,        -- Vivid publishes no venue id (no <venueId> in the XML)
       m.gotickets_aliases,
       (m.sg_venue_id IS NOT NULL)::int + (m.tickpick_venue_id IS NOT NULL)::int + (m.gotickets_venue_id IS NOT NULL)::int
         AS marketplace_ids_known,
       m.id_provenance,
       m.updated_at
  FROM public.cross_source_venue_map m;

COMMENT ON VIEW public.v_marketplace_venue_xref IS
  'Cross-marketplace venue xref keyed on tevo_venue_id: AQ hub venue_short_id, SeatGeek / TickPick / GoTickets venue ids derived from events already mapped (agreement or >= 90% majority — never by comparing venue name strings), plus per-source name aliases. Vivid publishes no venue id (aliases only). Refreshed daily by venue_xref_derive_from_events (cron venue_xref_derive_daily). mig 20260908202400; GoTickets ids + hub short id mig 20260911220000.';

DROP FUNCTION IF EXISTS public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric);
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
  p_min_overlap     numeric DEFAULT 0.5,
  p_source_venue_id bigint  DEFAULT NULL   -- mig 20260911220000: the source's own venue id → cross_source_venue_map
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

  -- Venue by ID first (mig 20260911220000): the source's venue id through cross_source_venue_map
  -- (gotickets_venue_id / sg_venue_id / tickpick_venue_id, derived by event agreement), then the name.
  IF p_source_venue_id IS NOT NULL THEN
    SELECT m.tevo_venue_id INTO v_vid FROM public.cross_source_venue_map m
     WHERE (v_src IN ('gotickets', 'gt')      AND m.gotickets_venue_id = p_source_venue_id)
        OR (v_src IN ('seatgeek', 'sg')       AND m.sg_venue_id        = p_source_venue_id)
        OR (v_src IN ('tickpick', 'tp')       AND m.tickpick_venue_id  = p_source_venue_id)
     LIMIT 1;
  END IF;
  v_vid  := coalesce(v_vid, public.cross_source_venue_resolve(p_venue_name, p_venue_city, p_venue_state));
  SELECT count(*) INTO v_ntok FROM unnest(string_to_array(v_nm, ' ')) t WHERE length(t) > 2;

  -- ── Rule 1: venue + same LOCAL day + token overlap, twin tie-breaks ───────
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
  IF p_event_time_utc IS NOT NULL AND (v_venue IS NOT NULL OR v_vid IS NOT NULL) AND v_needle <> '' THEN
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
  -- mig 20260911218000: no identity bypass — rule 0 already asked the hub's every source-id column,
  -- and the hub matcher's tier0/tier1 read the same columns, so a source id alone can never let
  -- rule 4 find what rule 0 missed. The bypass made EVERY catalogue row (gotickets_event,
  -- sg_events_canonical: all carry a source id) pay the 163 ms scan — 500 ms/row measured.
  v_hub_near := (v_venue IS NOT NULL AND EXISTS (
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
REVOKE ALL ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric, bigint) TO service_role;
COMMENT ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric, bigint) IS
  'THE event mapper (any marketplace event → tevo_event_id): identity (hub/canonical) → venue+local-day+overlap with twin tie-breaks → venue±24h performer (matcher v3) → exact name+day → AQ 4-tier. Pure/STABLE; unique-or-decline; parking + TBD guarded. A1 mig 20260911200000; rule-4 name guard mig 20260911213000; indexed day rules mig 20260911215000; hub-gated rule 4 mig 20260911216000; gate without the identity bypass mig 20260911218000; venue by source id mig 20260911220000.';




DROP FUNCTION IF EXISTS public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text);
CREATE OR REPLACE FUNCTION public.event_mapper_apply(
  p_source text, p_source_event_id bigint, p_tevo bigint,
  p_name text, p_venue_name text, p_local_date date, p_score numeric DEFAULT NULL, p_performer text DEFAULT NULL,
  p_source_venue_id bigint DEFAULT NULL   -- mig 20260911220000: the source's own venue id, learned onto the xref on a strong hit
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_src text := lower(trim(coalesce(p_source, '')));
  v_col text;
  v_aq  text;
  v_n   int := 0;
  v_out text := '';
  v_venue_id bigint; v_perf_id bigint; v_resolved_vid bigint; v_alias_col text; v_id_col text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_tevo IS NULL THEN RETURN 'no_tevo'; END IF;

  v_col := CASE
    WHEN v_src IN ('gotickets', 'gt')                     THEN 'gotickets_event_id'
    WHEN v_src IN ('seatgeek', 'sg')                      THEN 'sg_event_id'
    WHEN v_src IN ('vivid', 'vividseats', 'vivid seats')  THEN 'vivid_event_id'
    WHEN v_src IN ('stubhub', 'sh')                       THEN 'sh_event_id'
    WHEN v_src IN ('ticketmaster', 'tm')                  THEN 'tm_event_id'
    WHEN v_src IN ('seatdata', 'sd')                      THEN 'sd_event_id'
    ELSE NULL END;

  -- Hub row for this tevo id: curated first, else the oldest; create only when none exists.
  SELECT a.aq_short_event_id INTO v_aq FROM public.aq_event_map a
   WHERE a.tevo_event_id = p_tevo
   ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST LIMIT 1;
  IF v_aq IS NULL AND p_name IS NOT NULL AND p_local_date IS NOT NULL THEN
    v_aq := public.create_system_aq_event(v_src, p_name, p_venue_name, p_local_date::timestamptz, p_source_event_id);
    UPDATE public.aq_event_map SET tevo_event_id = p_tevo WHERE aq_short_event_id = v_aq AND tevo_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'hub_row_created;'; END IF;
  END IF;

  -- Source id onto that hub row: fill-only, and never when another hub row already binds this
  -- source id to a DIFFERENT tevo id (that is a hub duplicate to consolidate, not to widen).
  IF v_aq IS NOT NULL AND v_col IS NOT NULL AND p_source_event_id IS NOT NULL THEN
    EXECUTE format(
      'UPDATE public.aq_event_map SET %1$I = $1 WHERE aq_short_event_id = $2 AND %1$I IS NULL
          AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.%1$I = $1 AND o.tevo_event_id IS DISTINCT FROM $3)',
      v_col) USING p_source_event_id, v_aq, p_tevo;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'hub_' || v_col || ';'; END IF;
  END IF;

  -- Venue + performer cross-map (fill-only): the resolved TEvo event names its venue and primary
  -- performer, so the SOURCE's venue string / performer name become aliases of those canonical ids.
  -- Venue xref = cross_source_venue_map (THE one — never a rival; PROJECT_BIBLE §4); performer = the
  -- hub's aq_performer_map.aliases + seatgeek_performer_xref. The hub row also gets venue_short_id /
  -- performer_short_id when the aq maps know the id. Every later lookup then hits the alias tier
  -- instead of the prefix tier or a TEvo search.
  SELECT e.venue_id, e.primary_performer_id INTO v_venue_id, v_perf_id FROM public.events e WHERE e.id = p_tevo;
  IF v_venue_id IS NOT NULL AND nullif(trim(coalesce(p_venue_name, '')), '') IS NOT NULL THEN
    v_alias_col := CASE
      WHEN v_src IN ('seatgeek', 'sg')                     THEN 'sg_aliases'
      WHEN v_src IN ('tickpick', 'tp')                     THEN 'tickpick_aliases'
      WHEN v_src IN ('vivid', 'vividseats', 'vivid seats') THEN 'vivid_aliases'
      WHEN v_src IN ('gotickets', 'gt')                    THEN 'gotickets_aliases'
      ELSE 'crm_aliases' END;
    -- only when the string does not already resolve — and never when it resolves to ANOTHER venue
    -- (that is an ambiguity for the venue sweep, not something an event match may decide)
    v_resolved_vid := public.cross_source_venue_resolve(p_venue_name, NULL, NULL);
    IF v_resolved_vid IS NULL THEN
      EXECUTE format(
        'UPDATE public.cross_source_venue_map SET %1$I = coalesce(%1$I, ''[]''::jsonb) || to_jsonb($1::text), updated_at = now()
          WHERE tevo_venue_id = $2 AND NOT (coalesce(%1$I, ''[]''::jsonb) ? $1)', v_alias_col)
        USING trim(p_venue_name), v_venue_id;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN v_out := v_out || 'venue_alias;'; END IF;
    END IF;
    UPDATE public.aq_event_map a SET venue_short_id = m.venue_short_id
      FROM public.aq_venue_map m
     WHERE a.aq_short_event_id = v_aq AND a.venue_short_id IS NULL AND m.tevo_venue_id = v_venue_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'hub_venue_short_id;'; END IF;
    -- The source's venue ID onto the xref row (mig 20260911220000): every strong hit (identity, or a
    -- venue-anchored rule at >= 0.8) teaches cross_source_venue_map what this source calls the venue —
    -- fill-only, never when that id already names ANOTHER TEvo venue (the daily derive adjudicates those).
    v_id_col := CASE WHEN v_src IN ('gotickets', 'gt') THEN 'gotickets_venue_id'
                     WHEN v_src IN ('seatgeek', 'sg')  THEN 'sg_venue_id'
                     WHEN v_src IN ('tickpick', 'tp')  THEN 'tickpick_venue_id' END;
    IF p_source_venue_id IS NOT NULL AND v_id_col IS NOT NULL AND coalesce(p_score, 0) >= 0.8 THEN
      EXECUTE format(
        'UPDATE public.cross_source_venue_map m SET %1$I = $1,
                id_provenance = m.id_provenance || jsonb_build_object($3::text, jsonb_build_object(''method'', ''mapper_hit'', ''score'', $4::numeric, ''derived_at'', now())),
                updated_at = now()
          WHERE m.tevo_venue_id = $2 AND m.%1$I IS NULL
            AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map o WHERE o.%1$I = $1 AND o.tevo_venue_id <> $2)', v_id_col)
        USING p_source_venue_id, v_venue_id, replace(v_id_col, '_venue_id', ''), p_score;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN v_out := v_out || 'venue_id;'; END IF;
    END IF;
  END IF;
  IF v_perf_id IS NOT NULL THEN
    IF nullif(trim(coalesce(p_performer, '')), '') IS NOT NULL THEN
      UPDATE public.aq_performer_map m
         SET aliases = array_append(coalesce(m.aliases, '{}'::text[]), trim(p_performer))
       WHERE m.tevo_performer_id = v_perf_id
         AND NOT (lower(trim(p_performer)) = ANY (SELECT lower(x) FROM unnest(coalesce(m.aliases, '{}'::text[])) x))
         AND lower(trim(p_performer)) <> lower(coalesce(m.performer_name, ''));
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN v_out := v_out || 'performer_alias;'; END IF;
      IF v_src IN ('seatgeek', 'sg') AND NOT EXISTS (SELECT 1 FROM public.seatgeek_performer_xref x WHERE lower(x.sg_performer_name) = lower(trim(p_performer))) THEN
        INSERT INTO public.seatgeek_performer_xref (tevo_performer_id, sg_performer_name, match_method, match_confidence, matched_at)
        VALUES (v_perf_id, trim(p_performer), 'event_mapper', p_score, now());
        v_out := v_out || 'sg_performer_xref;';
      END IF;
    END IF;
    UPDATE public.aq_event_map a SET performer_short_id = m.performer_short_id
      FROM public.aq_performer_map m
     WHERE a.aq_short_event_id = v_aq AND a.performer_short_id IS NULL AND m.tevo_performer_id = v_perf_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'hub_performer_short_id;'; END IF;
  END IF;

  -- Catalogue writebacks (fill-only): the next surface that meets this event resolves by identity.
  IF v_src IN ('gotickets', 'gt') AND p_source_event_id IS NOT NULL THEN
    UPDATE public.gotickets_event
       SET tevo_event_id = p_tevo, mapped_via = 'event_mapper', map_score = p_score, mapped_at = now(), updated_at = now()
     WHERE gt_event_id = p_source_event_id AND tevo_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'gotickets_event;'; END IF;
  ELSIF v_src IN ('seatgeek', 'sg') AND p_source_event_id IS NOT NULL THEN
    UPDATE public.sg_events_canonical
       SET tevo_event_id = p_tevo, match_method = 'event_mapper', match_confidence = p_score, matched_at = now(), updated_at = now()
     WHERE sg_event_id = p_source_event_id AND tevo_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN v_out := v_out || 'sg_events_canonical;'; END IF;
  END IF;

  RETURN nullif(v_out, '');
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text, bigint) TO service_role;
COMMENT ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text, bigint) IS
  'Cross-map a resolved (source, source_event_id, venue string, performer name) → tevo_event_id: source id onto the hub row of that tevo id, venue string → cross_source_venue_map alias of the event''s venue, performer name → aq_performer_map alias (+ seatgeek_performer_xref), hub venue/performer short ids, tevo writeback onto gotickets_event / sg_events_canonical. All fill-only. A1 mig 20260911210000.';

CREATE OR REPLACE FUNCTION public.event_mapper_surface_sql(p_surface text, p_horizon_days int DEFAULT 180)
RETURNS TABLE(select_sql text, update_sql text, key_type text)
LANGUAGE plpgsql IMMUTABLE
AS $fn$
BEGIN
  -- select_sql yields: row_key, source, source_event_id, event_name, performer, venue_name, venue_city,
  --                    venue_state, local_date, event_time_utc, previous (current tevo), ord (recency),
  --                    source_venue_id (the source's own venue id when it publishes one — mig 20260911220000)
  -- update_sql takes $1 row_key (text, cast inside), $2 tevo, $3 method, $4 score; fill-only.
  CASE p_surface
    WHEN 'gotickets_purchases' THEN
      select_sql := $q$SELECT gt_purchase_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, event_name,
                              performers->0->>'name' AS performer, venue_name, venue_city, venue_state, event_time_local::date AS local_date,
                              event_time_utc, tevo_event_id AS previous, updated_at AS ord, venue_id AS source_venue_id FROM public.gotickets_purchases WHERE event_time_local IS NOT NULL$q$;
      update_sql := $q$UPDATE public.gotickets_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE gt_purchase_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'seatgeek_purchases' THEN
      select_sql := $q$SELECT order_id AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, event_name, NULL::text AS performer,
                              event_location AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_start::date AS local_date,
                              NULL::timestamptz AS event_time_utc, tevo_event_id AS previous, updated_at AS ord, NULL::bigint AS source_venue_id FROM public.seatgeek_purchases WHERE event_start IS NOT NULL$q$;
      update_sql := $q$UPDATE public.seatgeek_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 's4kcs_orders' THEN
      select_sql := $q$SELECT s4k_order_id AS row_key, lower(source) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue_name, venue_city, venue_state, event_date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, coalesce(mapped_at, pulled_at) AS ord, NULL::bigint AS source_venue_id FROM public.s4kcs_orders WHERE event_date >= current_date - 7$q$;
      update_sql := $q$UPDATE public.s4kcs_orders SET tevo_event_id = $2, map_method = $3, map_confidence = $4, mapped_at = now() WHERE s4k_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'n2s_items' THEN
      select_sql := $q$SELECT n2s_id::text AS row_key, lower(marketplace) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_dt::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, n2s_updated_at AS ord, NULL::bigint AS source_venue_id FROM public.n2s_items WHERE NOT coalesce(is_terminal, false) AND event_dt IS NOT NULL$q$;
      update_sql := $q$UPDATE public.n2s_items SET tevo_event_id = $2, mapped_via = $3 WHERE n2s_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'tickpick_orders' THEN
      select_sql := $q$SELECT tp_order_id AS row_key, 'tickpick'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, CASE WHEN raw->'venue'->>'id' ~ '^[0-9]+$' THEN (raw->'venue'->>'id')::bigint END AS source_venue_id FROM public.tickpick_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.tickpick_orders SET tevo_event_id = $2, matched_via = $3, match_confidence = $4, matched_at = now() WHERE tp_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'vivid_orders' THEN
      select_sql := $q$SELECT vivid_order_id AS row_key, 'vivid'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, NULL::bigint AS source_venue_id FROM public.vivid_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.vivid_orders SET tevo_event_id = $2 WHERE vivid_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'gotickets_event' THEN
      select_sql := format($q$SELECT gt_event_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, name AS event_name, performer,
                              venue_name, venue_city, venue_state, NULL::date AS local_date, event_time_utc, tevo_event_id AS previous,
                              coalesce(mapped_at, updated_at) AS ord, NULL::bigint AS source_venue_id FROM public.gotickets_event
                        WHERE status = 'AS_SCHEDULED' AND event_time_utc > now() AND event_time_utc < now() + make_interval(days => %s)
                          -- mig 20260911219000: only rows whose venue the TEvo mirror (future events) or the venue map
                          -- already knows — 138k future catalogue rows, most at venues TEvo never lists (hashed IN-lists)
                          AND lower(trim(venue_name)) IN (
                                SELECT lower(trim(e.venue_name)) FROM public.events e
                                 WHERE left(e.occurs_at_local, 10) >= current_date::text AND e.venue_name IS NOT NULL
                                UNION SELECT lower(trim(m.tevo_venue_name)) FROM public.cross_source_venue_map m WHERE m.tevo_venue_name IS NOT NULL
                                UNION SELECT lower(trim(x)) FROM public.cross_source_venue_map m, jsonb_array_elements_text(m.gotickets_aliases) x
                                 WHERE jsonb_typeof(m.gotickets_aliases) = 'array')$q$,
                        greatest(1, coalesce(p_horizon_days, 180)));
      update_sql := $q$UPDATE public.gotickets_event SET tevo_event_id = $2, mapped_via = $3, map_score = $4, mapped_at = now(), updated_at = now() WHERE gt_event_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'sg_events_canonical' THEN
      select_sql := $q$SELECT sg_event_id::text AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, sg_event_name AS event_name, NULL::text AS performer,
                              sg_venue_name AS venue_name, sg_venue_city AS venue_city, sg_venue_state AS venue_state, sg_event_date AS local_date, sg_datetime_utc AS event_time_utc,
                              tevo_event_id AS previous, coalesce(matched_at, updated_at) AS ord,
                              coalesce(sg_venue_id, CASE WHEN raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$' THEN (raw_event_jsonb->'venue'->>'id')::bigint END) AS source_venue_id FROM public.sg_events_canonical
                        WHERE sg_event_date >= current_date AND coalesce(sg_category, '') NOT IN ('Parking', 'parking')$q$;
      update_sql := $q$UPDATE public.sg_events_canonical SET tevo_event_id = $2, match_method = $3, match_confidence = $4, matched_at = now(), updated_at = now() WHERE sg_event_id = $1::bigint AND tevo_event_id IS NULL$q$;
    ELSE
      RAISE EXCEPTION 'event_mapper: unknown surface % (gotickets_purchases | seatgeek_purchases | s4kcs_orders | n2s_items | tickpick_orders | vivid_orders | gotickets_event | sg_events_canonical)', p_surface;
  END CASE;
  key_type := 'text';
  RETURN NEXT;
END $fn$;

CREATE OR REPLACE FUNCTION public.event_mapper_map_surface(
  p_surface text, p_apply boolean DEFAULT false, p_limit int DEFAULT 500, p_keys text[] DEFAULT NULL
)
RETURNS TABLE(row_key text, previous bigint, tevo_event_id bigint, method text, score numeric, crossmap text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_sel text; v_upd text; v_n int; rr record; v_x text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT s.select_sql, s.update_sql INTO v_sel, v_upd FROM public.event_mapper_surface_sql(p_surface) s;

  -- N2S identity rules 0–0e (verbatim from n2s_map_events): the SAME ORDER in one of our books.
  -- Identity beats inference, so they run before the resolver and only in apply mode.
  IF p_surface = 'n2s_items' AND p_apply AND p_keys IS NULL THEN
    UPDATE public.n2s_items n SET tevo_event_id = o.tevo_event_id, mapped_via = 'n2s_crm_order_identity'
      FROM public.s4kcs_orders o
     WHERE o.s4k_order_id = n.n2s_order_key AND o.tevo_event_id IS NOT NULL AND n.tevo_event_id IS NULL AND NOT coalesce(n.is_terminal, false);
    UPDATE public.n2s_items n SET tevo_event_id = o.tevo_event_id, mapped_via = 'n2s_evo_order_identity'
      FROM public.evo_orders o
     WHERE n.s4k_source = 'EVO' AND o.evo_order_id::text = n.n2s_order_key AND o.tevo_event_id IS NOT NULL
       AND n.tevo_event_id IS NULL AND NOT coalesce(n.is_terminal, false);
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_gt_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(g.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.gotickets_sales gs ON gs.gt_sale_id::text = n2.order_number
              LEFT JOIN public.gotickets_event g ON g.gt_event_id = gs.gt_event_id
              LEFT JOIN public.aq_event_map a ON a.gotickets_event_id = gs.gt_event_id AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'GoTickets' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(g.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_vivid_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(o.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.vivid_orders o ON o.vivid_order_id = n2.order_number
              LEFT JOIN public.aq_event_map a ON o.raw->>'productionId' ~ '^[0-9]+$'
                                             AND a.vivid_event_id = (o.raw->>'productionId')::bigint AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'Vivid Seats' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(o.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_sg_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(o.tevo_event_id, c.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.seatgeek_orders o ON o.sg_order_id = n2.order_number
              LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = o.sg_event_id AND c.tevo_event_id IS NOT NULL
              LEFT JOIN public.aq_event_map a ON a.sg_event_id = o.sg_event_id AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'SeatGeek' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(o.tevo_event_id, c.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
  END IF;

  -- Candidate rows: unmapped (normal) or an explicit key set (shadow replay), newest first.
  DROP TABLE IF EXISTS _em_rows;
  IF p_keys IS NULL THEN
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.previous IS NULL ORDER BY q.ord DESC NULLS LAST, q.event_time_utc ASC NULLS LAST, q.local_date ASC NULLS LAST LIMIT %s',
                   v_sel, greatest(1, least(5000, p_limit)));
  ELSE
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.row_key = ANY($1)', v_sel) USING p_keys;
  END IF;

  DROP TABLE IF EXISTS _em_out;
  CREATE TEMP TABLE _em_out ON COMMIT DROP AS
  SELECT q.row_key, q.previous, q.source, q.source_event_id, q.event_name, q.performer, q.venue_name, q.local_date, q.source_venue_id,
         res.tevo_event_id AS tevo, res.method, res.score, NULL::text AS crossmap
    FROM _em_rows q
    LEFT JOIN LATERAL public.event_mapper_resolve(q.source, q.source_event_id, q.event_name, q.performer, q.venue_name,
                        q.venue_city, q.venue_state, q.local_date, q.event_time_utc, (p_keys IS NULL), 0.5, q.source_venue_id) res ON true;

  IF p_apply THEN
    FOR rr IN SELECT o.* FROM _em_out o WHERE o.tevo IS NOT NULL AND o.previous IS NULL LOOP
      EXECUTE v_upd USING rr.row_key, rr.tevo, rr.method, rr.score;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN
        v_x := public.event_mapper_apply(rr.source, rr.source_event_id, rr.tevo, rr.event_name, rr.venue_name, rr.local_date, rr.score, rr.performer, rr.source_venue_id);
        UPDATE _em_out o SET crossmap = coalesce(v_x, 'written') WHERE o.row_key = rr.row_key;
      END IF;
    END LOOP;
  END IF;

  RETURN QUERY SELECT o.row_key, o.previous, o.tevo, o.method, o.score, o.crossmap FROM _em_out o;
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapper_surface_sql(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_surface_sql(text, int) TO service_role;
REVOKE ALL ON FUNCTION public.event_mapper_map_surface(text, boolean, int, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_map_surface(text, boolean, int, text[]) TO service_role;
