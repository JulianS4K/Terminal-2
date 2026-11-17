-- ============================================================================
-- Migration 20260912051500 — TickPick becomes a first-class surface, rule 2 may no longer cross a local day, Vivid + TickPick go live
-- Migration 20260912051500 · level:data-collection · lane:A1 · writes:aq_event_map(column),event_mapper_switch,cron_policy,cron.job · reads:tickpick_orders
--
-- Lane:     A1 (data plane)
-- Touches:  aq_event_map (NEW nullable column tp_event_id + partial index; fill-only),
--           event_mapper_resolve() (REPLACE - rule 0 TickPick branch, rule 2 same-local-day guard),
--           event_mapper_apply() (REPLACE - learns tp_event_id onto the hub),
--           event_mapper_surface_sql() (REPLACE - TickPick branch),
--           event_mapper_switch (vivid_orders + tickpick_orders -> live),
--           cron_policy + cron.job (NEW marketplace_orders_map_30min - ONE job for both surfaces)
-- Pre-reqs: 20260911230000
--
-- Already applied to prod · via MCP 2026-09-12 under operator direction ("start mapping and strengthen
-- mapper with every map").
--
-- THREE THINGS, each measured before applying.
--
-- 1. TICKPICK WAS THE LAST SURFACE STILL DISCARDING ITS INPUTS. Its raw payload is the richest we get
--    (event_id, a venue object with name/city/state/id/timezone, the local wall time AND the true
--    instant) and the select passed NULL for the event id and the entire venue. Worse, it derived
--    local_date from tickpick_orders.event_date, which is the UTC instant: wrong on 456 of 1,371 rows
--    (33%), because a 9pm ET game falls on the next day in UTC.
--    DRY RUN, 350 newest unmapped, old inputs vs new: agree 2 · DISAGREE 0 · LOST 0 · GAINED 109
--    (venue_day_name 107, venue_24h_performer 2). Venue mismatches in the gained set: 0.
--
-- 2. THE HUB NOW CARRIES A TICKPICK EVENT ID. aq_event_map had a column for every source except
--    TickPick (axs/gotickets/sd/sg/sh/tm/vivid). tp_event_id closes that gap, so rule 0 resolves
--    TickPick by identity and event_mapper_apply teaches the hub on every TickPick map - the same
--    compounding every other surface already had.
--
-- 3. RULE 2 MAY NO LONGER CROSS A LOCAL DAY when the caller supplied one. Its +/-24 h window was
--    binding multi-night runs to the wrong night: the TickPick dry run put Mac DeMarco 10/25 on the
--    10/26 show and Counting Crows 8/08 on 8/07, and the Vivid dry run (mig 20260911230000) did the
--    same to Hamilton and two Harry Potter dates. A candidate on a different local day is wrong by
--    construction when we know the date. Measured blast radius: 0 rows on ANY surface supplying a
--    local date were mapped by rule 2, and gotickets_event (the only real rule-2 user, 7 rows) passes
--    local_date NULL so the guard is inert there. Loses nothing already won; closes the whole class of
--    wrong-night picks for every surface at once.
--
-- Both remaining shadow surfaces go live here. They had no cron caller at all, so ONE new job serves
-- both every 30 min rather than two - the instance runs 197 cron jobs against max_worker_processes=6
-- and is already shedding startup slots.
--
-- ROLLBACK: re-apply event_mapper_resolve + event_mapper_apply from 20260911220000 and
--           event_mapper_surface_sql from 20260911230000; UPDATE event_mapper_switch SET mode='shadow'
--           WHERE surface IN ('vivid_orders','tickpick_orders'); SELECT cron.unschedule('marketplace_orders_map_30min');
--           ALTER TABLE public.aq_event_map DROP COLUMN tp_event_id;
-- ============================================================================

ALTER TABLE public.aq_event_map ADD COLUMN IF NOT EXISTS tp_event_id bigint;
COMMENT ON COLUMN public.aq_event_map.tp_event_id IS
  'TickPick event id (tickpick_orders.raw->>''event_id''), learned by event_mapper_apply on every TickPick map. Fill-only. mig 20260912051500';
CREATE INDEX IF NOT EXISTS idx_aq_event_map_tp ON public.aq_event_map (tp_event_id) WHERE tp_event_id IS NOT NULL;

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
    ELSIF v_src IN ('tickpick', 'tp') THEN
      -- mig 20260912051500: TickPick publishes an event id on every order; the hub now carries it.
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
               -- mig 20260912051500: when the CALLER knows the local date, a candidate on a different
               -- local day is wrong by construction. Rule 2's +/-24 h window was binding multi-night
               -- runs to the wrong night (Mac DeMarco 10/25 -> 10/26, Counting Crows 8/08 -> 8/07,
               -- Hamilton 9/12 -> 9/11). Inert when p_local_date IS NULL (gotickets_event), so the
               -- 7 catalogue rows using rule 2 today are untouched; 0 rows on any surface that DOES
               -- supply a local date were mapped by rule 2, so this loses nothing already won.
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
    WHEN v_src IN ('tickpick', 'tp')                      THEN 'tp_event_id'
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
      -- mig 20260912051500: TickPick's raw payload is the richest of any surface and the select threw
      -- most of it away. It carries event_id, a full venue object (name/city/state/id/timezone), the
      -- LOCAL wall time in 'event_date' and the true instant in 'event_date_utc'. Note the COLUMN
      -- tickpick_orders.event_date is the UTC instant (it equals raw.event_date_utc on all 1,371 rows),
      -- so deriving local_date from it was wrong on 456 of them (33%) -- a 9pm ET game is the NEXT day
      -- in UTC. local_date now comes from the raw LOCAL field; event_time_utc keeps the column, which
      -- IS a genuine instant here (unlike vivid_orders, mig 20260911230000), so rule 2 is safe.
      select_sql := $q$SELECT tp_order_id AS row_key, 'tickpick'::text AS source,
                              CASE WHEN raw->>'event_id' ~ '^[0-9]+$' THEN (raw->>'event_id')::bigint END AS source_event_id,
                              event_name, NULL::text AS performer,
                              raw->'venue'->>'name' AS venue_name, raw->'venue'->>'city' AS venue_city, raw->'venue'->>'state' AS venue_state,
                              CASE WHEN raw->>'event_date' ~ '^\d{4}-\d{2}-\d{2}T' THEN (left(raw->>'event_date', 10))::date ELSE event_date::date END AS local_date,
                              event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord,
                              CASE WHEN raw->'venue'->>'id' ~ '^[0-9]+$' THEN (raw->'venue'->>'id')::bigint END AS source_venue_id
                         FROM public.tickpick_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.tickpick_orders SET tevo_event_id = $2, matched_via = $3, match_confidence = $4, matched_at = now() WHERE tp_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'vivid_orders' THEN
      -- mig 20260911230000: Vivid's raw payload carries BOTH a venue string and its own event id
      -- (productionId) on 100% of the book; the surface threw both away, so rules 0 and 1 could never
      -- fire here and only the weakest rule (name+day) ever hit. Now:
      --   source_event_id = productionId  → rule 0 identity through aq_event_map.vivid_event_id
      --                                     (the same column n2s_vivid_order_identity already uses)
      --   venue_name/city/state = raw 'venue' split on its " - City, ST" suffix (378 of 379 distinct
      --                           strings split; the rest fall back whole) with &amp; decoded
      --                           ("AT&amp;T Stadium" never matched the mirror's "AT&T Stadium")
      --   event_time_utc = NULL, DELIBERATELY. vivid_orders.event_date stores the LOCAL wall time
      --     labelled +00 (the XML's <eventDate> verbatim), so handing it to rule 2 as a real instant
      --     put the ±24 h window 4–7 h off and picked the PREVIOUS evening's show: dry run 2026-09-11
      --     bound Hamilton 9/12 → the 9/11 performance and two Harry Potter dates the same way, plus
      --     a "Grounds Passes" row → "Session 8". Rule 2 stays off for Vivid until the venue timezone
      --     is applied to that column. Rule 4 anchors at local noon/19:00 as usual.
      select_sql := $q$SELECT vivid_order_id AS row_key, 'vivid'::text AS source,
                              CASE WHEN raw->>'productionId' ~ '^[0-9]+$' THEN (raw->>'productionId')::bigint END AS source_event_id,
                              event_name, NULL::text AS performer,
                              replace(coalesce((regexp_match(raw->>'venue', '^(.*?)\s+-\s+[^,]+,\s*[A-Za-z]{2}$'))[1],
                                               nullif(trim(coalesce(raw->>'venue', '')), '')), '&amp;', '&') AS venue_name,
                              (regexp_match(raw->>'venue', '^.*?\s+-\s+([^,]+),\s*[A-Za-z]{2}$'))[1] AS venue_city,
                              (regexp_match(raw->>'venue', '^.*?\s+-\s+[^,]+,\s*([A-Za-z]{2})$'))[1] AS venue_state,
                              event_date::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, NULL::bigint AS source_venue_id
                         FROM public.vivid_orders WHERE event_date >= now() - interval '90 days'$q$;
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

REVOKE ALL ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric, bigint) TO service_role;
COMMENT ON FUNCTION public.event_mapper_resolve(text, bigint, text, text, text, text, text, date, timestamptz, boolean, numeric, bigint) IS
  'THE event mapper (any marketplace event -> tevo_event_id): identity (hub/canonical/TickPick) -> venue+local-day+overlap with twin tie-breaks -> venue+/-24h performer, SAME LOCAL DAY when one is known -> exact name+day -> AQ 4-tier. Pure/STABLE; unique-or-decline; parking + TBD guarded. A1 migs 20260911200000 / 213000 / 215000 / 216000 / 218000 / 220000; TickPick identity + rule-2 day guard 20260912051500.';
REVOKE ALL ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text, bigint) TO service_role;
COMMENT ON FUNCTION public.event_mapper_apply(text, bigint, bigint, text, text, date, numeric, text, bigint) IS
  'Cross-map a resolved row: source id onto the hub row of that tevo id (gotickets/sg/vivid/sh/tm/sd/TICKPICK), venue string -> cross_source_venue_map alias, source venue id -> its id column on a strong hit, performer name -> aq_performer_map alias (+ seatgeek_performer_xref), hub venue/performer short ids, tevo writeback onto gotickets_event / sg_events_canonical. All fill-only. A1 mig 20260911210000; venue ids 20260911220000; TickPick hub id 20260912051500.';
REVOKE ALL ON FUNCTION public.event_mapper_surface_sql(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_surface_sql(text, int) TO service_role;

-- Both surfaces live. live_fallback stays OFF for each: neither has a legacy mapper of its own
-- (the AQ sweep :22 / backfill :40 own them today), so there is nothing to fall back to.
UPDATE public.event_mapper_switch
   SET mode = 'live',
       note = 'live 2026-09-12 (operator: start mapping). vivid: productionId + split venue, no instant (mig 230000). tickpick: event_id + venue + local date from raw, real instant (mig 20260912051500).'
 WHERE surface IN ('vivid_orders', 'tickpick_orders');

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, notes)
VALUES ('marketplace_orders_map_30min',
        ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 25, 25,
        'SELECT EXISTS (SELECT 1 FROM public.vivid_orders WHERE tevo_event_id IS NULL AND event_date >= now() - interval ''90 days'' UNION ALL SELECT 1 FROM public.tickpick_orders WHERE tevo_event_id IS NULL AND event_date >= now() - interval ''90 days'')',
        48, 'Maps the Vivid + TickPick order books through event_mapper_run. ONE job for both surfaces on purpose: 197 cron jobs share max_worker_processes=6. mig 20260912051500')
ON CONFLICT (jobname) DO UPDATE
  SET work_check_sql = excluded.work_check_sql, notes = excluded.notes, updated_at = now();

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('marketplace_orders_map_30min')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'marketplace_orders_map_30min');
    PERFORM cron.schedule('marketplace_orders_map_30min', '13,43 * * * *', $body$
      BEGIN;
      SET LOCAL statement_timeout='170s';
      DO $b$ BEGIN IF NOT public.cron_should_fire('marketplace_orders_map_30min') THEN RETURN; END IF;
        PERFORM public.event_mapper_run('vivid_orders');
        PERFORM public.event_mapper_run('tickpick_orders');
      END $b$;
      COMMIT;$body$);
  END IF;
END;
$cron$;

-- ── Counter fix, folded in from the first live run (mig 20260912052500 in prod) ──────────────
-- event_mapper_run reported `mapped` as count(*) over the GROUPED subquery — the number of distinct
-- METHODS, not rows. The first live vivid_orders run said "mapped: 3" when it had mapped 193
-- (identity_hub 81 + venue_day_name 110 + name_day_exact 2). Same shape as the bug fixed earlier in
-- our_purchases_map. Every live run on every surface was under-reporting.
CREATE OR REPLACE FUNCTION public.event_mapper_run(p_surface text, p_horizon_days int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_mode text; v_fallback boolean := false; v_cap int; v_legacy jsonb := NULL; v_n int := 0; v_by jsonb := '{}'::jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT s.mode, s.live_fallback, s.live_cap INTO v_mode, v_fallback, v_cap FROM public.event_mapper_switch s WHERE s.surface = p_surface;
  v_mode := coalesce(v_mode, 'shadow');

  IF v_mode = 'live' THEN
    SELECT coalesce(sum(x.n), 0)::int, coalesce(jsonb_object_agg(x.method, x.n), '{}'::jsonb) INTO v_n, v_by
      FROM (SELECT m.method, count(*) AS n FROM public.event_mapper_map_surface(p_surface, true, coalesce(v_cap, 400)) m
             WHERE m.tevo_event_id IS NOT NULL GROUP BY m.method) x;
    IF NOT v_fallback THEN
      RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n, 'by', v_by);
    END IF;
  END IF;

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

  IF v_mode = 'live' THEN
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n, 'by', v_by, 'legacy_fallback', v_legacy);
  END IF;
  RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'legacy', v_legacy,
                            'shadow', 'see event_mapper_shadow_tick(surface) - separate transaction');
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_run(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_run(text, int) TO service_role;
COMMENT ON FUNCTION public.event_mapper_run(text, int) IS
  'The ONE mapper entry point every cron calls. Dispatches on event_mapper_switch.mode: legacy / shadow -> old mapper only (the dry run is event_mapper_shadow_tick, own transaction); live -> resolver writes + cross-maps (live_cap rows), then the old mapper as a fill-only fallback when live_fallback is on. A1 mig 20260911210000; reshaped 215000; live fallback 217000; per-surface live_cap 219000; mapped counts ROWS not methods 20260912052500.';
