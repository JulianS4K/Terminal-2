-- An EVO -> GoTickets mapper. Every existing GT matcher runs the other way, and the direction
-- turns out to be the entire problem.
--
-- ============================================================================================
-- THE MEASUREMENT THAT JUSTIFIES THIS FILE
-- ============================================================================================
-- Four GT<->TEvo matchers already run on cron and all of them succeed every tick:
--
--   gt_map_events_hourly           35 * * * *     gt_map_events()                  ~72s
--   gt_map_events_wide_daily       50 8 * * *     gt_map_events()
--   gotickets_match_us_6h          23 */6 * * *   match_gotickets_us_events()      ~100s
--   aq_link_gotickets_catalogue_hourly  40 * * * * aq_link_gotickets_from_catalogue()
--
-- And yet only 4,594 of 188,992 future GoTickets events carry a tevo_event_id -- 2.4%. The jobs
-- are not broken and they are not starved. They are pointed the wrong way.
--
-- Every one of them iterates the GOTICKETS catalogue and asks "which TEvo event is this?".
-- GoTickets carries 189k future events; TEvo carries 11,558. The overwhelming majority of GT's
-- catalogue is events TEvo simply does not list, so the work is ~16x larger than the answer and
-- almost all of it is spent proving a negative.
--
-- The venue crosswalk makes this measurable rather than a matter of opinion. cross_source_venue_map
-- has 1,351 rows. Asked from each side, about the events that still need mapping:
--
--   from GT:    143,717 unmapped future events   ->   10,495 at a crosswalked venue   =  7.3%
--               (133,261 sit at 12,971 distinct venues with no crosswalk row at all)
--   from TEvo:    5,664 future events with no GT id ->  5,661 at a crosswalked venue  = 99.95%
--
-- Same table, same join, opposite direction, and it goes from useless to essentially complete.
-- A matcher driven from TEvo gets a venue key for all but THREE of its candidates.
--
-- Yield, measured before writing any of this: of the 5,664, 1,009 have at least one unmapped
-- AS_SCHEDULED GoTickets event at the crosswalked venue within +/-1 day. 750 of those clear a
-- 0.45 name-or-performer bar, 728 clear 0.60 and 651 clear 0.80. Of a 200-row sample of the
-- ~4,655 with no candidate at all, 45 (22.5%) do have a GT event in the same city on the same
-- date at a fuzzily-matching venue name -- an ALIAS miss, not an absence -- which is what stage 3
-- is for. The remaining ~78% are events GoTickets genuinely does not carry, and no amount of
-- matcher is going to conjure them.
--
-- WHY IT PAYS FOR ITSELF. mig 20260810184500 established, and re-verified 2026-08-10, that the
-- external GoTickets collector polls listings for an event ONLY once that event carries a
-- tevo_event_id (807/807 events polled in 24h were mapped; 0 unmapped). Mapping is therefore not
-- bookkeeping -- it is the switch that turns listings collection on for an event.
--
-- ============================================================================================
-- WHAT THIS DOES NOT DO
-- ============================================================================================
-- It writes gotickets_event.tevo_event_id and nothing else. It does NOT write aq_event_map --
-- aq_link_gotickets_from_catalogue() already runs hourly (cron 587) and propagates exactly that
-- column into the hub, with its own independent verification of the catalogue's claim. Writing
-- the hub here would duplicate a live writer and put two authorities on one column.
--
-- It never overwrites: every write is gated on gotickets_event.tevo_event_id IS NULL. The four
-- existing matchers keep whatever they have already claimed.
--
-- ============================================================================================
-- THE STAGES
-- ============================================================================================
--   1  crosswalk venue + DECIDABLE local day + name/performer >= 0.60
--   2  crosswalk venue + same local MINUTE          + name/performer >= 0.45   (near-identity)
--   3  same city/state + venue name >= 0.60         + name/performer >= 0.70   (the alias miss)
--
-- Stage 2 sits below stage 1 deliberately: an exact minute is stronger evidence than a day, so it
-- can afford a lower name bar, but it is only reachable for rows where BOTH sides carry a real
-- time, which is a minority. Stage 3 is last and carries the highest name bar because its venue
-- evidence is the weakest thing in the file.
--
-- ============================================================================================
-- GUARDS, and which ones are paid for in blood
-- ============================================================================================
-- * NEAR-MIDNIGHT. GoTickets stamps a time-unknown event at 23:59 LOCAL -- 14,361 future rows.
--   Sixty seconds from the date boundary, so any imprecision in the venue's zone rolls the day.
--   mig 20260915140000 learned this by proposing 105 wrong "corrections" in a dry run. So a GT
--   timestamp within 30 minutes of midnight is NOT day-decidable, and neither is a TEvo event
--   whose occurs_at_local time is 00:00 (2,286 future rows, TEvo's own time-unknown convention).
--   Those fall through to the undecidable path below rather than being silently trusted.
--
-- * WHAT "DECIDABLE" DOES NOT MEAN. The first cut required BOTH sides to carry a real time, and
--   the dry run showed why that is wrong: of 1,730 venue+window candidate pairs 1,044 have a good
--   name match, but only 240 survived -- and 555 pairs were dropped purely for a TEvo time of
--   00:00. TEvo's 00:00 is an unknown TIME on a perfectly real DATE. Comparing days never needed
--   TEvo's clock, only GoTickets'. The near-midnight risk belongs to GoTickets alone, so the
--   requirement for a real TEvo time now lives only in stage 2, where an exact minute is the whole
--   point. Over-copying a guard is as much a defect as omitting one.
--
-- * THE UNDECIDABLE PATH. When the day cannot be decided, the candidate is taken from a +/-1 day
--   window and must clear THREE extra tests: name/performer >= 0.80, exactly one GT candidate in
--   the whole window, and -- the one that actually matters -- TEvo itself must have only ONE event
--   at that venue in the window. A two-night run is exactly where an off-by-one lands, so if we
--   hold both nights we decline rather than guess. This is the same reasoning that made
--   mig 20260915140000 refuse 89 SeatGeek bindings.
--
-- * BOTH-WAYS UNIQUENESS. One GT event may be claimed by at most one TEvo event AND one TEvo event
--   may claim at most one GT event, enforced on the candidate set before any write. Without the
--   second half a three-night residency maps all three nights to whichever GT row sorts first.
--
-- * ORDINALS. "game N" / "session N" must match exactly (IS NOT DISTINCT FROM, so absent-on-both
--   passes and present-on-one fails). aq_name_consistent() does not catch Home Game 1 vs Home
--   Game 2; gotickets_backfill_tevo_from_hub carries a looser version of this for the same reason.
--
-- * PARKING and TBD, on both sides, using the token sets the cascade already uses.
--
-- * THE CAP GOES LAST. p_limit is applied AFTER the predicate that removes finished work, and that
--   predicate -- "no gotickets_event row already points at this TEvo event" -- is the one the
--   WRITER uses. This is the rule mig 20260915130000 had to restate after the fourth time a
--   per-tick cap on an unfiltered list turned into a wall.
--
-- Dry-run by default. Every write is logged to evo_gt_map_log, so the batch reverses with
--   UPDATE gotickets_event g SET tevo_event_id = NULL, mapped_via = NULL
--     FROM evo_gt_map_log l WHERE g.gt_event_id = l.gt_event_id AND g.mapped_via = 'evo_to_gt_v1';

CREATE TABLE IF NOT EXISTS public.evo_gt_map_log (
  gt_event_id    bigint PRIMARY KEY,
  tevo_event_id  bigint NOT NULL,
  stage          text   NOT NULL,
  score          numeric,
  tevo_local_day date,
  gt_local_day   date,
  tevo_name      text,
  gt_name        text,
  venue_name     text,
  mapped_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.evo_gt_map_log IS
  'Every gotickets_event.tevo_event_id written by the TEvo-driven mapper. Reversible by nulling where mapped_via=''evo_to_gt_v1'' (mig 20260915150000).';

-- A dry run you cannot read is not a dry run. Verifying the first two dry runs of this function
-- meant re-deriving its whole candidate set by hand in a standalone query, which took ~60s and,
-- the second time, silently dropped the parking guard and produced eight "defects" that were
-- artefacts of the check rather than the mapper. So every run -- apply or not -- lands its
-- surviving proposals here, replacing the previous run. It is scratch, not a record: the durable
-- record of what was WRITTEN is evo_gt_map_log.
CREATE UNLOGGED TABLE IF NOT EXISTS public.evo_gt_map_candidates (
  tevo_event_id  bigint,
  gt_event_id    bigint,
  stage          text,
  score          numeric,
  tevo_local_day date,
  gt_local_day   date,
  tevo_name      text,
  gt_name        text,
  tevo_venue     text,
  gt_venue       text,
  tevo_local_ts  timestamp,
  gt_utc         timestamptz,
  computed_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.evo_gt_map_candidates IS
  'Scratch: what the last evo_gt_map() run proposed, apply or dry-run. Replaced each run. Durable write record is evo_gt_map_log (mig 20260915150000).';

-- Extracted so the ordinal vocabulary can grow without redeploying the mapper. Every ordinal that
-- distinguishes SIBLING events at the same venue on the same day belongs here. "game" and
-- "session" came from mig 20260915140000 (Home Game 1 vs Home Game 2); "bracket" and "round"
-- were added when a dry run matched TEvo's generic "Fort Worth Stock Show and Rodeo" to
-- GoTickets' "... ProRodeo Tournament (Bracket 5, Round 1)".
--
-- Deliberately strict: IS NOT DISTINCT FROM means absent-on-both passes, present-on-both must
-- agree, and present-on-ONE fails. That last case declines some correct pairs where one side
-- simply names the night more precisely. That is the intended trade -- a false decline costs a
-- mapping, a false match pollutes a listings feed with the wrong night's inventory.
CREATE OR REPLACE FUNCTION public.evo_gt_ordinals_agree(p_a text, p_b text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT (regexp_match(lower(p_a), '(?:home )?game\s*(\d+)'))[1]
         IS NOT DISTINCT FROM (regexp_match(lower(p_b), '(?:home )?game\s*(\d+)'))[1]
     AND (regexp_match(lower(p_a), 'session\s*(\d+)'))[1]
         IS NOT DISTINCT FROM (regexp_match(lower(p_b), 'session\s*(\d+)'))[1]
     AND (regexp_match(lower(p_a), 'bracket\s*(\d+)'))[1]
         IS NOT DISTINCT FROM (regexp_match(lower(p_b), 'bracket\s*(\d+)'))[1]
     AND (regexp_match(lower(p_a), 'round\s*(\d+)'))[1]
         IS NOT DISTINCT FROM (regexp_match(lower(p_b), 'round\s*(\d+)'))[1];
$fn$;

REVOKE ALL ON FUNCTION public.evo_gt_ordinals_agree(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_ordinals_agree(text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.evo_gt_map(
  p_apply boolean DEFAULT false, p_limit int DEFAULT 2000,
  p_horizon_days int DEFAULT 400, p_fuzzy_venue boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
DECLARE
  v_written int := 0; v_s1 int := 0; v_s2 int := 0; v_s3 int := 0; v_tot int := 0;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _egt (
    tevo_event_id bigint, gt_event_id bigint, stage text, score numeric,
    tevo_ld date, gt_ld date, tevo_name text, gt_name text, venue_name text,
    gt_venue text, tevo_local_ts timestamp, gt_utc timestamptz) ON COMMIT DROP;
  DELETE FROM _egt;
  CREATE TEMP TABLE IF NOT EXISTS _va (tevo_venue_id bigint, nm text, city text, st text) ON COMMIT DROP;
  DELETE FROM _va;
  INSERT INTO _va
  SELECT DISTINCT v.tevo_venue_id, lower(trim(x.nm)), lower(trim(v.city)), upper(trim(v.state))
  FROM public.cross_source_venue_map v
  CROSS JOIN LATERAL (SELECT v.canonical_name AS nm UNION ALL SELECT v.tevo_venue_name
    UNION ALL SELECT jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(v.gotickets_aliases)='array' THEN v.gotickets_aliases ELSE '[]'::jsonb END)) x
  WHERE x.nm IS NOT NULL AND btrim(x.nm) <> '' AND v.tevo_venue_id IS NOT NULL;

  CREATE TEMP TABLE IF NOT EXISTS _t (
    id bigint PRIMARY KEY, name text, venue_id bigint, venue_name text, performer text,
    ld date, local_ts timestamp, city text, st text, tz text, siblings int) ON COMMIT DROP;
  DELETE FROM _t;
  INSERT INTO _t
  SELECT e.id, e.name, e.venue_id, e.venue_name, e.primary_performer_name,
         left(e.occurs_at_local,10)::date, left(e.occurs_at_local,19)::timestamp,
         lower(nullif(trim(split_part(e.venue_location,',',1)),'')),
         upper(trim(split_part(e.venue_location,',',array_length(string_to_array(e.venue_location,','),1)))),
         vt.iana_tz,
         (SELECT count(*) FROM public.events e2 WHERE e2.venue_id=e.venue_id AND e2.state<>'ignored'
            AND e2.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
            AND left(e2.occurs_at_local,10)::date BETWEEN left(e.occurs_at_local,10)::date-1
                                                      AND left(e.occurs_at_local,10)::date+1)::int
  FROM public.events e
  LEFT JOIN public.venue_timezone vt ON vt.tevo_venue_id = e.venue_id
  WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
    AND left(e.occurs_at_local,10) >= current_date::text
    AND left(e.occurs_at_local,10) <  (current_date + p_horizon_days)::text
    AND e.state <> 'ignored'
    AND coalesce(e.name,'') !~* 'parking|shuttle' AND coalesce(e.venue_name,'') !~* 'parking'
    AND coalesce(e.name,'') !~* '\(date tbd\)|\btbd\b|if necessary'
    AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g WHERE g.tevo_event_id = e.id)
  ORDER BY left(e.occurs_at_local,10)::date LIMIT p_limit;

  CREATE TEMP TABLE IF NOT EXISTS _g (
    gt_event_id bigint PRIMARY KEY, name text, performer text, venue_name text,
    city text, st text, utc timestamptz) ON COMMIT DROP;
  DELETE FROM _g;
  INSERT INTO _g
  SELECT g.gt_event_id, g.name, g.performer, g.venue_name,
         lower(trim(g.venue_city)), upper(trim(g.venue_state)), g.event_time_utc
  FROM public.gotickets_event g
  WHERE g.tevo_event_id IS NULL AND g.status='AS_SCHEDULED' AND g.event_time_utc IS NOT NULL
    AND g.event_time_utc >= now() - interval '2 days'
    AND g.event_time_utc <  now() + (p_horizon_days || ' days')::interval
    AND coalesce(g.name,'') !~* 'parking|shuttle' AND coalesce(g.venue_name,'') !~* 'parking'
    AND coalesce(g.name,'') !~* '\(date tbd\)|\btbd\b|if necessary';

  CREATE INDEX IF NOT EXISTS _g_utc_idx ON _g (utc);
  CREATE INDEX IF NOT EXISTS _g_city_idx ON _g (city, st, utc);
  CREATE INDEX IF NOT EXISTS _va_key_idx ON _va (nm, city, st);
  ANALYZE _g; ANALYZE _t; ANALYZE _va;

  CREATE TEMP TABLE IF NOT EXISTS _gx (gt_event_id bigint, tevo_venue_id bigint) ON COMMIT DROP;
  DELETE FROM _gx;
  INSERT INTO _gx SELECT DISTINCT g.gt_event_id, va.tevo_venue_id
  FROM _g g JOIN _va va ON va.nm = lower(trim(g.venue_name)) AND va.city = g.city AND va.st = g.st;
  CREATE INDEX IF NOT EXISTS _gx_v_idx ON _gx (tevo_venue_id);
  ANALYZE _gx;

  CREATE TEMP TABLE IF NOT EXISTS _p (
    tevo_event_id bigint, gt_event_id bigint, stage text, score numeric,
    tevo_ld date, gt_ld date) ON COMMIT DROP;
  DELETE FROM _p;

  INSERT INTO _p
  SELECT t.id, g.gt_event_id, c.stage, ev.score, t.ld, ev.gt_ld
  FROM _t t
  JOIN _gx x ON x.tevo_venue_id = t.venue_id
  JOIN _g  g ON g.gt_event_id = x.gt_event_id
            AND g.utc >= (t.ld - 1)::timestamptz AND g.utc < (t.ld + 2)::timestamptz
  CROSS JOIN LATERAL (
    SELECT greatest(
        coalesce(similarity(lower(public.unaccent(g.name)),      lower(public.unaccent(t.name))), 0),
        coalesce(similarity(lower(public.unaccent(g.performer)), lower(public.unaccent(t.performer))), 0)) AS score,
      CASE WHEN t.tz IS NOT NULL THEN (g.utc AT TIME ZONE t.tz)::date END AS gt_ld,
      (t.tz IS NOT NULL AND (g.utc AT TIME ZONE t.tz)::time BETWEEN '00:30' AND '23:30') AS decidable) ev
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN ev.decidable AND ev.gt_ld = t.ld AND ev.score >= 0.60 THEN '1_xwalk_day'
      WHEN t.tz IS NOT NULL AND t.local_ts::time <> '00:00'::time
           AND (g.utc AT TIME ZONE t.tz) = t.local_ts AND ev.score >= 0.45 THEN '2_xwalk_minute'
      WHEN NOT ev.decidable AND ev.score >= 0.80 AND t.siblings = 1 THEN '4_xwalk_window'
    END AS stage) c
  WHERE c.stage IS NOT NULL
    AND public.aq_name_consistent(public.unaccent(t.name), public.unaccent(g.name))
    AND public.evo_gt_ordinals_agree(t.name, g.name);

  IF p_fuzzy_venue THEN
    INSERT INTO _p
    SELECT t.id, g.gt_event_id, '3_fuzzy_day', ev.score, t.ld, ev.gt_ld
    FROM _t t
    JOIN _g g ON g.city = t.city AND g.st = t.st
             AND g.utc >= (t.ld - 1)::timestamptz AND g.utc < (t.ld + 2)::timestamptz
    CROSS JOIN LATERAL (
      SELECT greatest(
          coalesce(similarity(lower(public.unaccent(g.name)),      lower(public.unaccent(t.name))), 0),
          coalesce(similarity(lower(public.unaccent(g.performer)), lower(public.unaccent(t.performer))), 0)) AS score,
        CASE WHEN t.tz IS NOT NULL THEN (g.utc AT TIME ZONE t.tz)::date END AS gt_ld,
        (t.tz IS NOT NULL AND (g.utc AT TIME ZONE t.tz)::time BETWEEN '00:30' AND '23:30') AS decidable) ev
    WHERE t.city IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM _p q WHERE q.tevo_event_id = t.id)
      AND similarity(lower(public.unaccent(g.venue_name)), lower(public.unaccent(t.venue_name))) >= 0.60
      AND ev.decidable AND ev.gt_ld = t.ld AND ev.score >= 0.70
      AND public.aq_name_consistent(public.unaccent(t.name), public.unaccent(g.name))
      AND public.evo_gt_ordinals_agree(t.name, g.name);
  END IF;

  CREATE INDEX IF NOT EXISTS _p_t_idx ON _p (tevo_event_id);
  CREATE INDEX IF NOT EXISTS _p_g_idx ON _p (gt_event_id);
  ANALYZE _p;

  INSERT INTO _egt
  SELECT p.tevo_event_id, p.gt_event_id, p.stage, p.score, p.tevo_ld, p.gt_ld,
         t.name, g.name, t.venue_name, g.venue_name, t.local_ts, g.utc
  FROM _p p JOIN _t t ON t.id = p.tevo_event_id JOIN _g g ON g.gt_event_id = p.gt_event_id
  WHERE NOT EXISTS (SELECT 1 FROM _p q WHERE q.tevo_event_id = p.tevo_event_id AND q.gt_event_id <> p.gt_event_id)
    AND NOT EXISTS (SELECT 1 FROM _p q WHERE q.gt_event_id = p.gt_event_id AND q.tevo_event_id <> p.tevo_event_id);

  SELECT count(*) FILTER (WHERE stage='1_xwalk_day'), count(*) FILTER (WHERE stage='2_xwalk_minute'),
         count(*) FILTER (WHERE stage='3_fuzzy_day'), count(*)
    INTO v_s1, v_s2, v_s3, v_tot FROM _egt;

  DELETE FROM public.evo_gt_map_candidates;
  INSERT INTO public.evo_gt_map_candidates
    (tevo_event_id, gt_event_id, stage, score, tevo_local_day, gt_local_day,
     tevo_name, gt_name, tevo_venue, gt_venue, tevo_local_ts, gt_utc)
  SELECT tevo_event_id, gt_event_id, stage, score, tevo_ld, gt_ld,
         tevo_name, gt_name, venue_name, gt_venue, tevo_local_ts, gt_utc FROM _egt;

  IF p_apply THEN
    WITH w AS (
      UPDATE public.gotickets_event g
         SET tevo_event_id = e.tevo_event_id, mapped_via = 'evo_to_gt_v1',
             map_score = e.score, mapped_at = now()
        FROM _egt e WHERE g.gt_event_id = e.gt_event_id AND g.tevo_event_id IS NULL
      RETURNING g.gt_event_id)
    INSERT INTO public.evo_gt_map_log
      (gt_event_id, tevo_event_id, stage, score, tevo_local_day, gt_local_day, tevo_name, gt_name, venue_name)
    SELECT e.gt_event_id, e.tevo_event_id, e.stage, e.score, e.tevo_ld, e.gt_ld,
           e.tevo_name, e.gt_name, e.venue_name
    FROM _egt e JOIN w ON w.gt_event_id = e.gt_event_id
    ON CONFLICT (gt_event_id) DO NOTHING;
    GET DIAGNOSTICS v_written = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object('applied', p_apply,
    'tevo_candidates_considered', (SELECT count(*) FROM _t), 'gt_pool', (SELECT count(*) FROM _g),
    'pairs', (SELECT count(*) FROM _p), 'proposed', v_tot,
    'by_stage', jsonb_build_object('1_xwalk_day', v_s1, '2_xwalk_minute', v_s2,
      '3_fuzzy_day', v_s3, '4_xwalk_window', v_tot - v_s1 - v_s2 - v_s3),
    'written', v_written);
END $fn$;

REVOKE ALL ON FUNCTION public.evo_gt_map(boolean, int, int, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_map(boolean, int, int, boolean) TO service_role;
