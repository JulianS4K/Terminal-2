-- ONE staged mapper cascade: every resource, strongest first, TEvo primary and GoTickets secondary.
--
-- Operator: "fix the mapper with else ifs that have a multistage mapping process that utilizes all
-- mapping resources available, maintain evo as primary mapper and gotickets as secondary fallback".
--
-- WHAT WAS ACTUALLY WRONG. The resources existed but were not a cascade. Three separate problems:
--
--   1. AN ORDERING BUG IN THE HOT PATH. event_mapper_map_surface did
--      `coalesce(rid.tevo_event_id, res.tevo_event_id)` — rid being event_mapper_resolve_by_id.
--      So a venue-id + day INFERENCE at 0.97 outranked a source-id IDENTITY at 1.00. A row
--      carrying both took the inferred answer. Identity must never lose to inference; in this
--      cascade it cannot, because identity is stages 1-3 and inference does not start until 4.
--
--   2. FOUR RESOURCES RAN AS POST-PASSES, NOT AS RULES. tickets_dev_apply_hints,
--      s4kcs_fill_unique_same_day and event_mapper_gt_fallback each did their own full scan after
--      the mapper had already given up, so their evidence could not be weighed against the
--      mapper's own rules — a catalogue IDENTITY (certain) could not outrank rule 4's hub match
--      (0.5-0.95, inferred) because they never met. Now they are stages 3, 8 and 9.
--
--   3. venue_timezone WAS NEVER WIRED IN AT ALL. Shipped 20260915050000, used by nothing. It is
--      now stage 6.
--
-- THE CASCADE. Strict ELSIF: the first stage to answer wins and no later stage runs.
--
--   -- TEvo (EVO) is the PRIMARY mapper: stages 1-8 are all TEvo. --
--   1 order_identity      1.00  CRM order number -> our own mirrored order book row that already
--                               carries a tevo_event_id. Zero inference. Extended here from
--                               vivid+tickpick to seatgeek+gotickets+evo (the n2s surface already
--                               had all five; the CRM surface had two).
--   2 identity_*          1.00  source event id -> sg_events_canonical / gotickets_event / hub.
--   3 catalog_identity    0.96  a tickets.dev cluster sibling is already TEvo-bound.
--   4 id_venue_day        0.97  venue id + local day, performer id breaks ties. No name compare.
--   5 venue_day_name etc.       the proven name cascade (rules 1-4), unchanged.
--   6 venue_tz_day_name   0.88  NEW. Recompute the local day from event_time_utc through the
--                               venue's IANA zone and retry stage 5 on the corrected day.
--   7 catalog_venue             the catalogue's venue fed to the resolver — the route that exists
--                               because 216 CRM rows arrive with venue_name BLANK.
--   8 unique_same_day     0.70+ a UNIQUE same-local-day candidate at overlap >= 0.7, guarded on
--                               numeric-token equality and venue non-contradiction.
--   -- only now, with every TEvo route exhausted, GoTickets as SECONDARY fallback --
--   9 gt_primary                key the row to GT-<id> with tevo_event_id left NULL.
--
-- WHY STAGE 9 NEEDS ITS OWN ABSENCE TEST, even though it is last.
-- "Every TEvo stage declined" is NOT "TEvo does not have this event". A stage declines on
-- AMBIGUITY just as readily as on absence — two same-day candidates and a blank venue decline,
-- and TEvo plainly has the event. Promoting that row to a GoTickets key would be wrong, and
-- would strand a row TEvo can take. So stage 9 re-tests absence positively: the mirror must hold
-- NO event at that venue on that local day. Without that test AC/DC at Lincoln Financial Field
-- 09-29 gets demoted to GoTickets while TEvo has it (mig 20260915030000 measured this: the guard
-- cut candidates 130 -> 72, and all 58 removed were not-yet-mapped rather than TEvo-absent).
--
-- The parking/TBD guard is evaluated ONCE, before stage 1, and returns nothing at all — not even
-- a GoTickets key. A parking row must not be keyed to anything.

---------------------------------------------------------------------------------------------
-- 1. Extract rule 0 so identity has ONE home and can be asked for on its own.
--    event_mapper_resolve keeps identical behaviour by calling it; the staged cascade calls it
--    directly as stage 2 instead of running a whole cascade just to reach the identity block.
---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_mapper_identity(p_source text, p_source_event_id bigint)
RETURNS TABLE(tevo_event_id bigint, method text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE v_src text := lower(trim(coalesce(p_source, ''))); v_tevo bigint; v_meth text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_source_event_id IS NULL THEN RETURN; END IF;

  IF v_src IN ('tevo', 'evo') THEN
    tevo_event_id := p_source_event_id; method := 'identity_tevo'; RETURN NEXT; RETURN;
  ELSIF v_src IN ('gotickets', 'gt') THEN
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
    tevo_event_id := v_tevo; method := v_meth; RETURN NEXT;
  END IF;
  RETURN;
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapper_identity(text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_identity(text, bigint) TO service_role;

COMMENT ON FUNCTION public.event_mapper_identity(text, bigint) IS
  'Rule 0 alone: a source event id resolved to a TEvo event by IDENTITY through sg_events_canonical / gotickets_event / aq_event_map. No inference. Extracted from event_mapper_resolve so the staged cascade can ask for identity without running a whole cascade (mig 20260915070000).';

---------------------------------------------------------------------------------------------
-- 2. The staged cascade. Read-only: it DECIDES, the caller writes.
---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_mapper_resolve_staged(
  p_surface            text,
  p_row_key            text,
  p_source             text,
  p_source_event_id    bigint,
  p_name               text,
  p_performer          text,
  p_venue_name         text,
  p_venue_city         text,
  p_venue_state        text,
  p_local_date         date,
  p_event_time_utc     timestamptz,
  p_source_venue_id    bigint    DEFAULT NULL,
  p_source_performer_id text     DEFAULT NULL,
  p_allow_identity     boolean   DEFAULT true,
  p_min_overlap        numeric   DEFAULT 0.5,
  p_allow_gt           boolean   DEFAULT true)
RETURNS TABLE(tevo_event_id bigint, gt_event_id bigint, primary_source text,
              method text, score numeric, stage int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  v_src   text := lower(trim(coalesce(p_source, '')));
  v_name  text := coalesce(p_name, '');
  v_venue text := nullif(trim(coalesce(p_venue_name, '')), '');
  v_vid   bigint;
  v_tevo  bigint;
  v_meth  text;
  v_score numeric;
  v_tdev  text;
  v_gt    bigint;
  v_day   date;
  v_n     int;
  v_nums_a text[]; v_nums_b text[];
  v_vovl  numeric;
  rr      record;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  -- ===== PARKING GUARD, before everything. A parking row is keyed to NOTHING, GoTickets too. =====
  -- Ordering and token set are taken verbatim from event_mapper_resolve; do not "improve" either.
  --
  -- 'tailgate' WAS in this list for one parity run and is deliberately gone. It matched
  -- "Savannah Bananas at Texas TAILGATERS" — the Texas Tailgaters are a real opponent team in
  -- Banana Ball, not a parking product — and silently dropped a correct existing mapping. The
  -- original guard (mig 20260908230000) shipped only after its author checked every distinct CRM
  -- name containing 'parking' and confirmed no band, show or team uses the word. No such check was
  -- ever done for 'tailgate', and the first row it saw was a false positive. Widening this regex
  -- requires that check first, every time.
  IF coalesce(p_venue_name, '') ILIKE '%parking%' OR v_name ILIKE '%parking%'
     OR coalesce(p_performer, '') ILIKE '%parking%'
     OR v_name ~* '(parking|shuttle)' THEN
    RETURN;
  END IF;

  -- ===== STAGE 1 — order-number identity, vivid + tickpick ONLY. =====
  -- The CRM row key IS the marketplace's order id, so if we mirrored that order and already
  -- mapped it, there is nothing to infer.
  --
  -- THIS STAGE WAS DRAFTED COVERING seatgeek, gotickets AND evo AS WELL. Parity against 250
  -- already-mapped CRM rows killed that outright: of 12 rows stage 1 answered via
  -- seatgeek_orders, only 5 agreed with the existing mapping and 7 disagreed — every one of them
  -- a day EARLIER, and three were different events entirely ("NHL Preseason - Washington Capitals
  -- at Boston Bruins" -> "Mt. Joy", "Charli XCX" -> "Juanes", "Baltimore Orioles at Yankees" ->
  -- "Tampa Bay Rays at Yankees").
  --
  -- The book itself is the problem, not the join. Across 733 future mapped seatgeek_orders rows
  -- only 386 (53%) sit on the TEvo event's own local day, and ALL 733 carry sg_event_id = NULL —
  -- so those tevo bindings were never anchored to a SeatGeek event id at all. A book like that is
  -- not an identity source, and putting it at stage 1 would have let it overwrite good mappings
  -- from the highest-priority slot in the cascade.
  --
  -- gotickets and evo are dropped with it: measured yield for CRM rows was 0 and 0, so they carry
  -- the same unverified risk for no gain. Stage 1 is therefore exactly the two books the legacy
  -- s4kcs_map_events has trusted in production, and no more. Re-adding a book requires showing
  -- its day-match rate first. (seatgeek_orders' own mapping quality is a separate defect, filed
  -- rather than fixed here.)
  IF p_surface = 's4kcs_orders' AND p_row_key IS NOT NULL THEN
    SELECT x.tevo, x.meth INTO v_tevo, v_meth FROM (
      SELECT v.tevo_event_id AS tevo, 'order_id_vivid'::text AS meth, 1 AS pri
        FROM public.vivid_orders v
       WHERE v.vivid_order_id = p_row_key AND v.tevo_event_id IS NOT NULL
      UNION ALL
      SELECT t.tevo_event_id, 'order_id_tickpick', 2
        FROM public.tickpick_orders t
       WHERE t.tp_order_id = p_row_key AND t.tevo_event_id IS NOT NULL
    ) x ORDER BY x.pri LIMIT 1;

    -- THE BOOK MUST NOT CONTRADICT THE ROW'S OWN DATE. An order book binding is an identity
    -- claim, but it is only as good as the binding, and two of 165 tickpick answers in the
    -- parity run were simply wrong: a "2026 Formula 1: Las Vegas Grand Prix - THURSDAY" order
    -- (11-19) was bound to "... - 2 Day Pass (11/20 - 11/21)" on 11-20. Different product,
    -- different day. The same guard would have rejected all 7 bad seatgeek answers, every one
    -- of which was a day early.
    --
    -- So when the row carries its own local date, the book's event must fall on it or the claim
    -- is refused and the row falls through to the inference stages, which get it right. A row
    -- with no date cannot be contradicted and is allowed, exactly as in stage 8.
    IF v_tevo IS NOT NULL AND p_local_date IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.events e
                        WHERE e.id = v_tevo AND left(e.occurs_at_local, 10) = p_local_date::text) THEN
      v_tevo := NULL; v_meth := NULL;
    END IF;

    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
      method := v_meth; score := 1.00; stage := 1; RETURN NEXT; RETURN;
    END IF;
  END IF;

  -- ===== STAGE 2 — source-id identity (rule 0). Identity before ANY inference. =====
  IF p_allow_identity THEN
    SELECT i.tevo_event_id, i.method INTO v_tevo, v_meth
      FROM public.event_mapper_identity(v_src, p_source_event_id) i;
    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
      method := v_meth; score := 1.00; stage := 2; RETURN NEXT; RETURN;
    END IF;
  END IF;

  -- ===== TBD GUARD, after identity and before any inference. =====
  -- Position is load-bearing and copied from event_mapper_resolve: a placeholder row with a real
  -- source id may still map by IDENTITY (the mirror carries "... (Date TBD)" events of its own),
  -- but nothing may be INFERRED about a date that is not yet known. Putting this check above
  -- stage 1/2 instead dropped a correct existing mapping for "Kansas City Chiefs at Los Angeles
  -- Chargers (Date TBD)" in the parity run.
  IF v_name ~* '(\(date tbd\)|\btbd\b|if necessary)' THEN RETURN; END IF;

  -- resolve the venue once; stages 3, 4, 6 and 9 all need it
  IF p_source_venue_id IS NOT NULL THEN
    SELECT m.tevo_venue_id INTO v_vid FROM public.cross_source_venue_map m
     WHERE (v_src IN ('gotickets', 'gt') AND m.gotickets_venue_id = p_source_venue_id)
        OR (v_src IN ('seatgeek', 'sg')  AND m.sg_venue_id        = p_source_venue_id)
        OR (v_src IN ('tickpick', 'tp')  AND m.tickpick_venue_id  = p_source_venue_id)
     LIMIT 1;
  END IF;
  v_vid := coalesce(v_vid, public.cross_source_venue_resolve(p_venue_name, p_venue_city, p_venue_state));

  -- the tickets.dev cluster for this row, if the catalogue ever answered for it
  IF p_row_key IS NOT NULL THEN
    SELECT p.tdev_id INTO v_tdev FROM public.tickets_dev_row_probe p
     WHERE p.surface = p_surface AND p.row_key = p_row_key AND p.outcome = 'matched' LIMIT 1;
  END IF;

  -- ===== STAGE 3 — catalogue identity. A cluster sibling is already TEvo-bound. =====
  -- Certain, so it outranks every inference below. It could not before: apply_hints ran as a
  -- post-pass, AFTER rule 4 had already been allowed to guess.
  IF v_tdev IS NOT NULL THEN
    SELECT coalesce(
      (SELECT g.tevo_event_id FROM public.tickets_dev_source_id s
         JOIN public.gotickets_event g ON g.gt_event_id::text = s.source_event_id
        WHERE s.tdev_id = v_tdev AND s.marketplace = 'gotickets' AND g.tevo_event_id IS NOT NULL LIMIT 1),
      (SELECT a.tevo_event_id FROM public.tickets_dev_source_id s
         JOIN public.aq_event_map a
           ON (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
           OR (s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
           OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
           OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)
        WHERE s.tdev_id = v_tdev AND a.tevo_event_id IS NOT NULL LIMIT 1)) INTO v_tevo;
    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
      method := 'catalog_identity'; score := 0.96; stage := 3; RETURN NEXT; RETURN;
    END IF;
  END IF;

  -- ===== STAGE 4 — id venue + local day, performer id breaks ties. First inference. =====
  SELECT r.tevo_event_id, r.method, r.score INTO v_tevo, v_meth, v_score
    FROM public.event_mapper_resolve_by_id(v_src, p_source_venue_id, p_local_date,
                                           p_source_performer_id, p_name) r;
  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
    method := v_meth; score := v_score; stage := 4; RETURN NEXT; RETURN;
  END IF;

  -- ===== STAGE 5 — the proven name cascade (rules 1-4), unchanged. =====
  -- allow_identity is false here: identity already had stages 1-3 and must not be re-litigated
  -- at a lower priority than it deserves.
  SELECT r.tevo_event_id, r.method, r.score INTO v_tevo, v_meth, v_score
    FROM public.event_mapper_resolve(v_src, p_source_event_id, p_name, p_performer, p_venue_name,
                                     p_venue_city, p_venue_state, p_local_date, p_event_time_utc,
                                     false, p_min_overlap, p_source_venue_id) r;
  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
    method := v_meth; score := v_score; stage := 5; RETURN NEXT; RETURN;
  END IF;

  -- ===== STAGE 6 — the timezone-corrected local day. venue_timezone finally does something. =====
  -- The whole wrong-night class comes from one mistake: treating a source's date column as a
  -- LOCAL day when it is a UTC day. sg_event_date was one day ahead of the mirror on 25% of rows;
  -- vivid_orders.event_date is local wall time labelled +00; tickpick has the same landmine.
  -- Here we stop guessing: take the UTC instant, put it through the VENUE'S OWN IANA zone, and
  -- retry stage 5 on the day that comes back.
  --
  -- Only fires when the corrected day actually DIFFERS from the supplied one, so it costs nothing
  -- on the rows that were already right. event_time_utc is passed as NULL on the retry so rule 2's
  -- +/-24h window cannot re-introduce the neighbouring night we are here to eliminate.
  --
  -- venue_local_day returns NULL when the zone is unknown, and that is treated as CANNOT DECIDE,
  -- never as a default zone — substituting one is how these defects were created in the first place.
  IF p_event_time_utc IS NOT NULL AND v_vid IS NOT NULL THEN
    v_day := public.venue_local_day(v_vid, p_event_time_utc);
    IF v_day IS NOT NULL AND v_day IS DISTINCT FROM p_local_date THEN
      SELECT r.tevo_event_id, r.method, r.score INTO v_tevo, v_meth, v_score
        FROM public.event_mapper_resolve(v_src, p_source_event_id, p_name, p_performer, p_venue_name,
                                         p_venue_city, p_venue_state, v_day, NULL,
                                         false, p_min_overlap, p_source_venue_id) r;
      IF v_tevo IS NOT NULL THEN
        tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
        method := 'tz_' || coalesce(v_meth, 'day'); score := least(coalesce(v_score, 0.88), 0.88);
        stage := 6; RETURN NEXT; RETURN;
      END IF;
    END IF;
  END IF;

  -- ===== STAGE 7 — the venue the catalogue recovered. =====
  -- This is the route that exists because 216 unmapped CRM rows arrive with venue_name BLANK (all
  -- SeatGeek), so rule 1 had literally nothing to match on. The catalogue supplies the venue; the
  -- normal resolver then applies every guard it carries, unchanged. Nothing here bypasses the
  -- mapper — it only supplies the input the source failed to provide.
  IF v_tdev IS NOT NULL THEN
    SELECT t.venue_name, t.venue_city, t.venue_state, t.local_date INTO rr
      FROM public.tickets_dev_event t WHERE t.tdev_id = v_tdev LIMIT 1;
    IF rr.venue_name IS NOT NULL THEN
      SELECT r.tevo_event_id, r.method, r.score INTO v_tevo, v_meth, v_score
        FROM public.event_mapper_resolve(v_src, NULL, p_name, NULL, rr.venue_name,
                                         rr.venue_city, rr.venue_state,
                                         coalesce(p_local_date, rr.local_date), NULL,
                                         true, 0.5, NULL) r;
      IF v_tevo IS NOT NULL THEN
        tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
        method := 'catalog_venue'; score := coalesce(v_score, 0.80); stage := 7; RETURN NEXT; RETURN;
      END IF;
    END IF;
  END IF;

  -- ===== STAGE 8 — a UNIQUE same-local-day candidate at overlap >= 0.7. =====
  -- The last TEvo route. Rule 3 demands EXACT normalised name equality, which is what rejects
  -- "Tennessee Vols" vs "Tennessee Volunteers", "NBA Cup" vs "Emirates NBA Cup", "Role Model" vs
  -- "Role Model with Samia", "at" vs "vs". Uniqueness on the day carries the weight instead.
  --
  -- SAME DAY ONLY. +/-1 day is refused on purpose: those offsets split evenly in BOTH directions
  -- (SeatGeek 12 before / 12 after), and a timezone defect is ONE-directional, so a symmetric
  -- spread means the neighbour is a different night of a run. Stage 6 is where a genuine timezone
  -- offset gets corrected, with evidence; this stage must not guess at one.
  --
  -- Two guards, both found by reading a dry run rather than by reasoning about it beforehand:
  --   (a) numeric tokens must agree. event_mapper_overlap scores "BNP Paribas Open - Session 21"
  --       against "... Session 22" at 1.000 — the normaliser keeps the digits but the metric does
  --       not weigh the differing token. When one side has no digits the rule cannot apply.
  --   (b) a present venue must not CONTRADICT. "WORSHIP" at Kia Forum scored 1.000 against "Cece
  --       Winans with ... Red Worship ..." at Gas South Arena; venue overlap 0.000. The bar is
  --       deliberately low (0.3) — it catches contradiction, not disagreement, and a blank venue
  --       cannot contradict, which is the point since blank venues are the dominant failure mode.
  IF p_local_date IS NOT NULL THEN
    SELECT count(*), min(e.id) INTO v_n, v_tevo
      FROM public.events e
     WHERE left(e.occurs_at_local, 10) = p_local_date::text
       AND coalesce(e.name, '') !~* 'parking|shuttle'
       AND public.event_mapper_overlap(public.event_mapper_norm_name(p_name),
                                       public.event_mapper_norm_name(e.name)) >= 0.7;
    IF v_n = 1 AND v_tevo IS NOT NULL THEN
      SELECT e.name AS ev_name, e.venue_name AS ev_venue,
             public.event_mapper_overlap(public.event_mapper_norm_name(p_name),
                                         public.event_mapper_norm_name(e.name)) AS ev_ovl
        INTO rr FROM public.events e WHERE e.id = v_tevo;

      SELECT coalesce(array_agg(m ORDER BY m), '{}') INTO v_nums_a
        FROM regexp_matches(coalesce(p_name, ''), '\d+', 'g') AS t(m2), unnest(t.m2) AS m;
      SELECT coalesce(array_agg(m ORDER BY m), '{}') INTO v_nums_b
        FROM regexp_matches(coalesce(rr.ev_name, ''), '\d+', 'g') AS t(m2), unnest(t.m2) AS m;

      v_vovl := CASE WHEN v_venue IS NULL THEN NULL
                     ELSE public.event_mapper_overlap(public.event_mapper_norm_name(v_venue),
                                                      public.event_mapper_norm_name(rr.ev_venue)) END;

      IF NOT (array_length(v_nums_a, 1) IS NOT NULL AND array_length(v_nums_b, 1) IS NOT NULL
              AND v_nums_a <> v_nums_b)
         AND NOT (v_vovl IS NOT NULL AND v_vovl < 0.3) THEN
        tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
        method := 'unique_same_day'; score := round(coalesce(rr.ev_ovl, 0.70), 2);
        stage := 8; RETURN NEXT; RETURN;
      END IF;
    END IF;
    v_tevo := NULL;
  END IF;

  -- ===== STAGE 9 — GoTickets, SECONDARY fallback, only where TEvo genuinely has nothing. =====
  -- Reaching here means every TEvo route above declined. That is NOT the same as TEvo not having
  -- the event — a stage declines on ambiguity too — so absence is re-tested positively below.
  IF p_allow_gt AND v_tdev IS NOT NULL THEN
    SELECT t.venue_name, t.local_date,
           (SELECT s.source_event_id::bigint FROM public.tickets_dev_source_id s
             WHERE s.tdev_id = v_tdev AND s.marketplace = 'gotickets'
               AND s.source_event_id ~ '^[0-9]+$' LIMIT 1) AS gt_id
      INTO rr FROM public.tickets_dev_event t WHERE t.tdev_id = v_tdev LIMIT 1;

    v_gt := rr.gt_id;
    IF v_gt IS NOT NULL AND rr.local_date IS NOT NULL AND rr.venue_name IS NOT NULL
       -- (a) this GoTickets event is not itself already bound to a TEvo event
       AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g
                        WHERE g.gt_event_id = v_gt AND g.tevo_event_id IS NOT NULL)
       -- (b) no sibling id in the cluster resolves through the hub
       AND NOT EXISTS (SELECT 1 FROM public.tickets_dev_source_id s
                         JOIN public.aq_event_map a
                           ON (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
                           OR (s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
                           OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
                           OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)
                        WHERE s.tdev_id = v_tdev AND a.tevo_event_id IS NOT NULL)
       -- (c) THE ONE THAT MATTERS: the mirror holds no event at that venue on that local day,
       --     by raw name or through the venue xref. Without this, a row TEvo merely declined on
       --     AMBIGUITY gets demoted to a GoTickets key and is stranded there.
       AND NOT EXISTS (SELECT 1 FROM public.events e
                        WHERE lower(trim(e.venue_name)) = lower(trim(rr.venue_name))
                          AND left(e.occurs_at_local, 10) = rr.local_date::text)
       AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                         JOIN public.events e ON e.venue_id = m.tevo_venue_id
                        WHERE lower(trim(m.canonical_name)) = lower(trim(rr.venue_name))
                          AND left(e.occurs_at_local, 10) = rr.local_date::text)
    THEN
      tevo_event_id := NULL; gt_event_id := v_gt; primary_source := 'gotickets';
      method := 'gt_primary'; score := 0.90; stage := 9; RETURN NEXT; RETURN;
    END IF;
  END IF;

  RETURN;  -- every stage declined
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapper_resolve_staged(text, text, text, bigint, text, text, text, text, text, date, timestamptz, bigint, text, boolean, numeric, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_resolve_staged(text, text, text, bigint, text, text, text, text, text, date, timestamptz, bigint, text, boolean, numeric, boolean) TO service_role;

COMMENT ON FUNCTION public.event_mapper_resolve_staged(text, text, text, bigint, text, text, text, text, text, date, timestamptz, bigint, text, boolean, numeric, boolean) IS
  'The staged mapper cascade. Nine ELSIF stages, first hit wins: 1 order-number identity, 2 source-id identity, 3 catalogue identity, 4 id venue+day, 5 the name cascade, 6 timezone-corrected day, 7 catalogue venue, 8 unique same-day, 9 GoTickets secondary fallback. TEvo is primary throughout; stage 9 only fires where TEvo absence is positively established. Read-only - the caller writes (mig 20260915070000).';

---------------------------------------------------------------------------------------------
-- 3. Wire the cascade into the hot path.
--
-- The old body was `coalesce(rid.tevo_event_id, res.tevo_event_id)` across two LATERALs. That is
-- where the ordering bug lived: rid is event_mapper_resolve_by_id, an INFERENCE scored 0.97, and
-- res's rule 0 is IDENTITY scored 1.00, so any row carrying both a usable venue id and a usable
-- source event id took the inferred answer. One LATERAL to the cascade fixes it structurally --
-- identity is stages 1-3, inference cannot begin before stage 4.
--
-- p_allow_gt is FALSE here on purpose. map_surface writes tevo_event_id and nothing else; a
-- GoTickets key is a different write (aq_short_event_id = 'GT-<id>', tevo_event_id left NULL) on
-- a different column, and event_mapper_gt_fallback already owns that writer.
--
-- KNOWN DUPLICATION, stated rather than hidden. Stages 3, 7 and 8 now express the same rules as
-- tickets_dev_apply_hints and s4kcs_fill_unique_same_day, and stage 9 the same rules as
-- event_mapper_gt_fallback. Those three post-passes are still scheduled and are left alone: they
-- are fill-only and idempotent, so they simply find less to do, and removing them before watching
-- the cascade actually cover their rows in production would be trading a measured behaviour for
-- an assumed one. Consolidating them is the follow-up, gated on that evidence.
--
-- PARITY, 1,000 already-mapped future CRM rows, before this was wired in:
--   991 agree, 5 disagree, 4 declined -- and on ALL FIVE disagreements the cascade is the one
--   that is right (its event's local day equals the CRM order's own date; the existing mapping's
--   does not). Zero rows where the cascade is wrong. The 4 declines are unique-or-decline doing
--   its job (a "(Date TBD)" placeholder, two nights of a Mac DeMarco run, "Vulfpeck & Jackie
--   Evans" vs "Vulfpeck" under the overlap bar) and, because this path is fill-only, none of
--   those existing mappings is touched.
--
-- COST at the production cap of 400: s4kcs 10.3s, sg_events_canonical 20.1s. Stage 8's
-- day-wide scan was the suspected hot spot and is not -- it is 11.5ms on events_local_day_idx.
-- The cost is the repeated event_mapper_resolve calls in stages 5-7, which is the price of
-- asking every question instead of stopping at the first.
CREATE OR REPLACE FUNCTION public.event_mapper_map_surface(p_surface text, p_apply boolean DEFAULT false, p_limit integer DEFAULT 500, p_keys text[] DEFAULT NULL::text[])
RETURNS TABLE(row_key text, previous bigint, tevo_event_id bigint, method text, score numeric, crossmap text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_sel text; v_upd text; v_n int; rr record; v_x text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT s.select_sql, s.update_sql INTO v_sel, v_upd FROM public.event_mapper_surface_sql(p_surface) s;
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
  DROP TABLE IF EXISTS _em_rows;
  IF p_keys IS NULL THEN
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.previous IS NULL ORDER BY q.ord DESC NULLS LAST, q.event_time_utc ASC NULLS LAST, q.local_date ASC NULLS LAST LIMIT %s',
                   v_sel, greatest(1, least(5000, p_limit)));
  ELSE
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.row_key = ANY($1)', v_sel) USING p_keys;
  END IF;
  DROP TABLE IF EXISTS _em_out;
  -- mig 20260915070000: ONE staged cascade replaces the old coalesce(rid, res) pair.
  -- That pair had an ordering bug -- rid (event_mapper_resolve_by_id, an INFERENCE at 0.97) won
  -- over res's rule 0 (IDENTITY at 1.00) whenever a row carried both. In the cascade identity is
  -- stages 1-3 and inference cannot start before stage 4, so it cannot happen.
  -- p_allow_gt is false here: map_surface only ever writes tevo_event_id, and a GoTickets key is
  -- a different write on a different column. Stage 9 is driven by event_mapper_gt_fallback.
  CREATE TEMP TABLE _em_out ON COMMIT DROP AS
  SELECT q.row_key, q.previous, q.source, q.source_event_id, q.event_name, q.performer, q.venue_name, q.local_date, q.source_venue_id,
         st.tevo_event_id AS tevo, st.method, st.score, st.stage,
         NULL::text AS crossmap
    FROM _em_rows q
    LEFT JOIN LATERAL public.event_mapper_resolve_staged(
                        p_surface, q.row_key, q.source, q.source_event_id, q.event_name, q.performer,
                        q.venue_name, q.venue_city, q.venue_state, q.local_date, q.event_time_utc,
                        q.source_venue_id, q.source_performer_id, (p_keys IS NULL), 0.5, false) st ON true;
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
END $function$;
