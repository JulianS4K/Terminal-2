-- Teach the hub to LISTEN. Every backfill in this repo runs hub -> source; nothing runs source -> hub.
--
-- WHAT WAS FOUND. Of 11,558 future non-parking TEvo events, 4,394 carry no marketplace id anywhere in
-- aq_event_map. 1,711 of those (39%) are ALREADY MATCHED and we simply never wrote it down:
--
--     sg_events_canonical.tevo_event_id points at one     1,397 events
--     gotickets_event.tevo_event_id points at one           400 events
--     seatdata_event_xref.tevo_event_id points at one         5 events   (left for later, see below)
--
-- SeatGeek's own matcher and GoTickets' own matcher both resolve TEvo ids perfectly well. Those ids
-- terminate on the source table. The hub can only learn a marketplace id by resolving it ITSELF
-- through the cascade, off an order row or a keyed cluster -- so a catalogue-side match is invisible
-- to it forever.
--
-- The asymmetry is literal and one-directional:
--     gotickets_backfill_tevo_from_hub()  (mig 20260909210000)  UPDATE gotickets_event SET tevo_event_id
--     tickets_dev_hub_backfill()          (mig 20260914211000)  hands the hub's TEvo id to td clusters
-- Both push OUT. Neither has an inbound counterpart. This migration is that counterpart.
--
-- WHY NOT JUST COPY THE 1,711. Because 105 of them are wrong, and they are wrong in the way that does
-- the most damage. aq_event_map.sg_event_id is a rule-0 / stage-2 IDENTITY source scored 1.00: it
-- outranks every piece of evidence the cascade can gather and re-asserts itself on every run (the
-- point mig 20260915120000 was written to make). Importing a wrong-night binding into that column is
-- worse than leaving the event unmapped.
--
-- sg_event_date is the known UTC landmine so it cannot adjudicate this. Every one of the 1,506 SG rows
-- carries raw_event_jsonb.datetime_local, which is local wall time, so the true local day IS available:
--
--     local day agrees   1,417        disagrees   89
--
-- Cross-checked a second way -- sg_datetime_utc through the TEvo venue's venue_timezone -- giving
-- 1,402 of the 1,490 with a known zone. Two independent methods, same answer.
--
-- The 89 are NOT the UTC-label artefact. They are all exactly +/-1 day and they are real errors:
--
--     "Arizona Diamondbacks at Colorado Rockies"   ->  SG's "Chicago Cubs at Colorado Rockies"
--     "Arizona Diamondbacks at San Diego Padres"   ->  SG's "Colorado Rockies at San Diego Padres"
--
-- Same venue, adjacent night, DIFFERENT OPPONENT. That is the wrong-night class sitting upstream in
-- sg_events_canonical.tevo_event_id, where nothing has ever looked. GoTickets has 16 of the same.
-- Concentrated in match_method='tevo_search_autotrack' @0.95 (1,011 rows); 'auto_canonical_loop' @0.90
-- is 287 rows and 287/287 day-exact.
--
-- So this ships TWO functions and the order matters: correct the source first, propagate second.
--
-- ============================================================================================
-- 1. source_matcher_fix_wrong_night(p_apply) -- correct the upstream bindings
-- ============================================================================================
-- Guards, all four required, mirroring mig 20260915120000 with one deliberate change:
--   * the replacement is at the SAME tevo venue_id as the event being replaced
--   * on the day the SOURCE says (SG: datetime_local; GT: event_time_utc through venue_timezone)
--   * name overlap >= 0.8 AND aq_name_consistent() against the SOURCE ROW'S name -- not the
--     incumbent's. mig 20260915120000 compared against the incumbent, which worked there because
--     both Zara Larsson nights carry the same name. Here the names differ BY CONSTRUCTION (the whole
--     error is a different opponent), so comparing to the incumbent would decline every real case.
--     Identity wants the candidate to look like what the SOURCE is describing.
--   * exactly one candidate survives
-- Anything that fails is left alone, not nulled. There is nothing to move it to, and inventing a
-- target is how wrong-night bindings get created in the first place.
--
-- ============================================================================================
-- 2. aq_hub_backfill_from_source_matchers(p_apply, p_limit) -- the propagation
-- ============================================================================================
-- Writes aq_event_map.sg_event_id / .gotickets_event_id for a TEvo event only when ALL hold:
--   * the event today carries NO marketplace id at all (this widens 0 -> 1; it never overwrites)
--   * EXACTLY ONE source row claims that TEvo event. 52 of the 400 GT events have more than one row
--     claiming them, and picking among them is matching, which this function refuses to do.
--   * that row's LOCAL day equals the TEvo event's local day. Unknown timezone counts as DISAGREE,
--     never as a default -- 49 GT candidates sit at venues absent from venue_timezone (990 rows) and
--     all 49 decline.
--   * the source id is not already bound anywhere else in the hub (3 SG / 4 GT are, and are skipped)
--   * GT status = 'AS_SCHEDULED' (1,762 CANCELLED, 698 MERGED, 1,170 RESCHEDULED are excluded)
--   * events.state <> 'ignored'
--
-- 1,468 of the survivors have no hub row at all, so this is not a column UPDATE -- it mints rows. The
-- key convention already exists ('EVO-'||e.id, mig 20260606120000) and is self-consistent: 747 such
-- keys, zero with a NULL or mismatched tevo_event_id. That inserter is gated behind the
-- evo_only_patterns allowlist, which is why only 747 exist; this one is gated on evidence instead and
-- is tagged aq_source='source_matcher' so the two never get confused. aq_source is read in exactly two
-- places repo-wide, both tie-break ORDER BYs preferring 'aq_curated', so a new value is inert.
--
-- seatdata's 5 are not done here: seatdata_event_xref has no event-time column of its own, so there is
-- nothing to adjudicate the day against, and 5 rows is not worth a bespoke rule.
--
-- WHAT THE FIRST DRY RUN CAUGHT, and why both functions carry a near-midnight rule.
-- v1 of the corrector proposed 109 GoTickets fixes out of 174 off-by-day rows -- a suspiciously high
-- rate, so it got looked at instead of applied. 139 of the 174 sat at a derived local time of 23:59,
-- and 105 of the 109 "fixes" came from that bucket. GoTickets stamps a time-unknown event at 23:59
-- LOCAL, which is sixty seconds from the date boundary: any imprecision in the venue's zone, or a DST
-- edge, rolls the day. The disagreement was the clock, not the booking. The repair it wanted to make
-- was worse than the defect -- "AL Wild Card ... Home Game 2 (If Necessary)" would have been
-- re-pointed onto "Home Game 1", 105 times.
--
-- So: a timestamp within 30 minutes of midnight cannot DECIDE a local day. The same sentence means it
-- cannot CONFIRM one either, which is why the rule is in the propagation too, not just the corrector,
-- and costs 44 otherwise-eligible GT candidates. A guard that is true in one direction and waived in
-- the other is not a guard.
--
-- Also added, from the same run: both functions refuse the TBD / "if necessary" class outright (the
-- token set the cascade already uses), and the corrector requires any "game N" / "session N" ordinal
-- to match EXACTLY -- IS NOT DISTINCT FROM, so absent-on-both passes and present-on-one fails.
-- aq_name_consistent() does not catch "Home Game 1" vs "Home Game 2"; gotickets_backfill_tevo_from_hub
-- carries a looser session-number guard for the same reason, and looser is not enough here.
--
-- BOTH functions default to p_apply=false and return a jsonb summary, and both log every write with
-- the old value, so both reverse with one UPDATE ... FROM the log.

-- --------------------------------------------------------------------------------------------
-- log tables
-- --------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.source_matcher_night_correction_log (
  source           text   NOT NULL,          -- 'seatgeek' | 'gotickets'
  source_event_id  bigint NOT NULL,
  old_tevo_id      bigint,
  new_tevo_id      bigint NOT NULL,
  source_local_day date,
  old_local_day    date,
  new_local_day    date,
  source_name      text,
  corrected_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, source_event_id)
);

COMMENT ON TABLE public.source_matcher_night_correction_log IS
  'Every sg_events_canonical / gotickets_event tevo_event_id re-pointed off a wrong night. Reversible from old_tevo_id (mig 20260915140000).';

CREATE TABLE IF NOT EXISTS public.aq_hub_source_backfill_log (
  aq_short_event_id text   NOT NULL,
  source            text   NOT NULL,         -- 'seatgeek' | 'gotickets'
  source_event_id   bigint NOT NULL,
  tevo_event_id     bigint NOT NULL,
  action            text   NOT NULL,         -- 'insert' | 'update'
  local_day         date,
  backfilled_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (aq_short_event_id, source)
);

COMMENT ON TABLE public.aq_hub_source_backfill_log IS
  'Every marketplace id written into aq_event_map by the inbound source-matcher backfill. action=update reverses by nulling the column; action=insert reverses by deleting the row (mig 20260915140000).';

-- --------------------------------------------------------------------------------------------
-- 1. correct the upstream wrong-night bindings
-- --------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.source_matcher_fix_wrong_night(p_apply boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_sg_off int := 0; v_sg_fix int := 0;
  v_gt_off int := 0; v_gt_fix int := 0;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _smn (
    source text, source_event_id bigint, source_name text, source_ld date,
    old_tevo bigint, old_ld date, new_tevo bigint, new_ld date
  ) ON COMMIT DROP;
  DELETE FROM _smn;

  -- SeatGeek: datetime_local is local wall time, so it is the authority. sg_event_date is UTC.
  INSERT INTO _smn
  SELECT 'seatgeek', b.sg_event_id, b.sg_event_name, b.src_ld, b.old_tevo, b.old_ld, c.new_tevo, b.src_ld
  FROM (
    SELECT s.sg_event_id, s.sg_event_name,
           left(s.raw_event_jsonb->>'datetime_local',10)::date AS src_ld,
           e.id AS old_tevo, e.venue_id, left(e.occurs_at_local,10)::date AS old_ld
    FROM public.sg_events_canonical s
    JOIN public.events e ON e.id = s.tevo_event_id
    WHERE s.tevo_event_id IS NOT NULL
      AND s.raw_event_jsonb->>'datetime_local' ~ '^\d{4}-\d{2}-\d{2}'
      AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND left(e.occurs_at_local,10) >= current_date::text
      AND left(e.occurs_at_local,10)::date <> left(s.raw_event_jsonb->>'datetime_local',10)::date
      AND e.name          !~* '\(date tbd\)|\btbd\b|if necessary'
      AND s.sg_event_name !~* '\(date tbd\)|\btbd\b|if necessary'
  ) b
  LEFT JOIN LATERAL (
    SELECT max(e2.id) AS new_tevo, count(*) AS n
    FROM public.events e2
    WHERE e2.venue_id = b.venue_id
      AND e2.id <> b.old_tevo
      AND e2.state <> 'ignored'
      AND e2.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND left(e2.occurs_at_local,10)::date = b.src_ld
      AND similarity(lower(public.unaccent(e2.name)), lower(public.unaccent(b.sg_event_name))) >= 0.8
      AND public.aq_name_consistent(public.unaccent(e2.name), public.unaccent(b.sg_event_name))
      AND (regexp_match(lower(e2.name), '(?:home )?game\s*(\d+)'))[1]
          IS NOT DISTINCT FROM (regexp_match(lower(b.sg_event_name), '(?:home )?game\s*(\d+)'))[1]
      AND (regexp_match(lower(e2.name), 'session\s*(\d+)'))[1]
          IS NOT DISTINCT FROM (regexp_match(lower(b.sg_event_name), 'session\s*(\d+)'))[1]
  ) c ON c.n = 1;

  SELECT count(*), count(*) FILTER (WHERE new_tevo IS NOT NULL)
    INTO v_sg_off, v_sg_fix FROM _smn WHERE source = 'seatgeek';

  -- GoTickets: only event_time_utc exists, so the venue's IANA zone is the only way to a local day.
  -- No zone -> no row here at all; an undecidable case must never be "corrected".
  INSERT INTO _smn
  SELECT 'gotickets', b.gt_event_id, b.gt_name, b.src_ld, b.old_tevo, b.old_ld, c.new_tevo, b.src_ld
  FROM (
    SELECT g.gt_event_id, g.name AS gt_name,
           (g.event_time_utc AT TIME ZONE vt.iana_tz)::date AS src_ld,
           e.id AS old_tevo, e.venue_id, left(e.occurs_at_local,10)::date AS old_ld
    FROM public.gotickets_event g
    JOIN public.events e ON e.id = g.tevo_event_id
    JOIN public.venue_timezone vt ON vt.tevo_venue_id = e.venue_id AND vt.iana_tz IS NOT NULL
    WHERE g.tevo_event_id IS NOT NULL
      AND g.status = 'AS_SCHEDULED'
      AND g.event_time_utc IS NOT NULL
      AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND left(e.occurs_at_local,10) >= current_date::text
      AND left(e.occurs_at_local,10)::date <> (g.event_time_utc AT TIME ZONE vt.iana_tz)::date
      AND e.name !~* '\(date tbd\)|\btbd\b|if necessary'
      AND g.name !~* '\(date tbd\)|\btbd\b|if necessary'
      AND (g.event_time_utc AT TIME ZONE vt.iana_tz)::time BETWEEN '00:30' AND '23:30'
  ) b
  LEFT JOIN LATERAL (
    SELECT max(e2.id) AS new_tevo, count(*) AS n
    FROM public.events e2
    WHERE e2.venue_id = b.venue_id
      AND e2.id <> b.old_tevo
      AND e2.state <> 'ignored'
      AND e2.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND left(e2.occurs_at_local,10)::date = b.src_ld
      AND similarity(lower(public.unaccent(e2.name)), lower(public.unaccent(b.gt_name))) >= 0.8
      AND public.aq_name_consistent(public.unaccent(e2.name), public.unaccent(b.gt_name))
      AND (regexp_match(lower(e2.name), '(?:home )?game\s*(\d+)'))[1]
          IS NOT DISTINCT FROM (regexp_match(lower(b.gt_name), '(?:home )?game\s*(\d+)'))[1]
      AND (regexp_match(lower(e2.name), 'session\s*(\d+)'))[1]
          IS NOT DISTINCT FROM (regexp_match(lower(b.gt_name), 'session\s*(\d+)'))[1]
  ) c ON c.n = 1;

  SELECT count(*), count(*) FILTER (WHERE new_tevo IS NOT NULL)
    INTO v_gt_off, v_gt_fix FROM _smn WHERE source = 'gotickets';

  IF p_apply THEN
    INSERT INTO public.source_matcher_night_correction_log
      (source, source_event_id, old_tevo_id, new_tevo_id, source_local_day, old_local_day, new_local_day, source_name)
    SELECT source, source_event_id, old_tevo, new_tevo, source_ld, old_ld, new_ld, source_name
    FROM _smn WHERE new_tevo IS NOT NULL
    ON CONFLICT (source, source_event_id) DO NOTHING;

    UPDATE public.sg_events_canonical s
       SET tevo_event_id = m.new_tevo,
           match_method   = 'wrong_night_correction_src',
           matched_at     = now()
      FROM _smn m
     WHERE m.source = 'seatgeek' AND m.new_tevo IS NOT NULL
       AND s.sg_event_id = m.source_event_id
       AND s.tevo_event_id = m.old_tevo;

    UPDATE public.gotickets_event g
       SET tevo_event_id = m.new_tevo,
           mapped_via     = 'wrong_night_correction_src',
           mapped_at      = now()
      FROM _smn m
     WHERE m.source = 'gotickets' AND m.new_tevo IS NOT NULL
       AND g.gt_event_id = m.source_event_id
       AND g.tevo_event_id = m.old_tevo;
  END IF;

  RETURN jsonb_build_object(
    'applied', p_apply,
    'seatgeek', jsonb_build_object('off_by_day', v_sg_off, 'correctable', v_sg_fix, 'declined', v_sg_off - v_sg_fix),
    'gotickets', jsonb_build_object('off_by_day', v_gt_off, 'correctable', v_gt_fix, 'declined', v_gt_off - v_gt_fix)
  );
END $fn$;

REVOKE ALL ON FUNCTION public.source_matcher_fix_wrong_night(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.source_matcher_fix_wrong_night(boolean) TO service_role;

-- --------------------------------------------------------------------------------------------
-- 2. the inbound propagation
-- --------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.aq_hub_backfill_from_source_matchers(
  p_apply boolean DEFAULT false,
  p_limit int     DEFAULT 5000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_ins int := 0; v_upd int := 0;
  v_cand int := 0; v_sg int := 0; v_gt int := 0;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _hbf (
    tevo_event_id bigint PRIMARY KEY,
    ld date, ts timestamp,
    ev_name text, venue_name text, city text, st text,
    performer text, category text, venue_id bigint, performer_id bigint,
    sg_event_id bigint, gt_event_id bigint,
    hub_key text
  ) ON COMMIT DROP;
  DELETE FROM _hbf;

  INSERT INTO _hbf
  WITH tgt AS (
    SELECT e.id, e.name, e.venue_id, e.venue_name, e.venue_location,
           e.primary_performer_name, e.primary_performer_id, e.event_type,
           left(e.occurs_at_local,10)::date AS ld,
           left(e.occurs_at_local,19)::timestamp AS ts
    FROM public.events e
    WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND left(e.occurs_at_local,10) >= current_date::text
      AND e.state <> 'ignored'
      AND coalesce(e.name,'') !~* 'parking|shuttle'
      -- 0 -> 1 only. An event that already carries any marketplace id is out of scope.
      AND NOT EXISTS (
        SELECT 1 FROM public.aq_event_map a
        WHERE a.tevo_event_id = e.id
          AND (a.vivid_event_id IS NOT NULL OR a.sh_event_id IS NOT NULL OR a.sg_event_id IS NOT NULL
            OR a.tm_event_id IS NOT NULL OR a.sd_event_id IS NOT NULL OR a.axs_event_id IS NOT NULL
            OR a.gotickets_event_id IS NOT NULL OR a.tp_event_id IS NOT NULL
            OR a.tnow_production_id IS NOT NULL))
  ),
  sg AS (
    SELECT t.id AS tevo_event_id, min(s.sg_event_id) AS sg_event_id
    FROM tgt t
    JOIN public.sg_events_canonical s ON s.tevo_event_id = t.id
    GROUP BY 1
    -- exactly one claimant, and it must agree on the LOCAL day. bool_and over the whole claim set
    -- means a single bad sibling disqualifies the event rather than being silently outvoted.
    HAVING count(*) = 1
       AND bool_and(s.raw_event_jsonb->>'datetime_local' ~ '^\d{4}-\d{2}-\d{2}'
                    AND left(s.raw_event_jsonb->>'datetime_local',10)::date = t.ld)
  ),
  gt AS (
    SELECT t.id AS tevo_event_id, min(g.gt_event_id) AS gt_event_id
    FROM tgt t
    JOIN public.gotickets_event g ON g.tevo_event_id = t.id
    LEFT JOIN public.venue_timezone vt ON vt.tevo_venue_id = t.venue_id
    WHERE g.status = 'AS_SCHEDULED'
    GROUP BY 1
    -- iana_tz NULL makes the bool_and term false, so an unknown zone DECLINES. Never default a zone.
    HAVING count(*) = 1
       AND bool_and(vt.iana_tz IS NOT NULL AND g.event_time_utc IS NOT NULL
                    AND (g.event_time_utc AT TIME ZONE vt.iana_tz)::time BETWEEN '00:30' AND '23:30'
                    AND (g.event_time_utc AT TIME ZONE vt.iana_tz)::date = t.ld)
  )
  SELECT t.id, t.ld, t.ts, t.name, t.venue_name,
         nullif(trim(split_part(t.venue_location, ',', 1)),''),
         upper(trim(split_part(t.venue_location, ',',
               array_length(string_to_array(t.venue_location,','),1)))),
         t.primary_performer_name, t.event_type, t.venue_id, t.primary_performer_id,
         CASE WHEN EXISTS (SELECT 1 FROM public.aq_event_map z WHERE z.sg_event_id = sg.sg_event_id)
              THEN NULL ELSE sg.sg_event_id END,
         CASE WHEN EXISTS (SELECT 1 FROM public.aq_event_map z WHERE z.gotickets_event_id = gt.gt_event_id)
              THEN NULL ELSE gt.gt_event_id END,
         (SELECT a.aq_short_event_id FROM public.aq_event_map a
           WHERE a.tevo_event_id = t.id
           ORDER BY (a.aq_source = 'aq_curated') DESC, a.id ASC LIMIT 1)
  FROM tgt t
  LEFT JOIN sg ON sg.tevo_event_id = t.id
  LEFT JOIN gt ON gt.tevo_event_id = t.id
  WHERE (sg.sg_event_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM public.aq_event_map z WHERE z.sg_event_id = sg.sg_event_id))
     OR (gt.gt_event_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM public.aq_event_map z WHERE z.gotickets_event_id = gt.gt_event_id))
  ORDER BY t.ld
  LIMIT p_limit;

  SELECT count(*), count(sg_event_id), count(gt_event_id) INTO v_cand, v_sg, v_gt FROM _hbf;

  IF p_apply THEN
    WITH upd AS (
      UPDATE public.aq_event_map a
         SET sg_event_id        = coalesce(a.sg_event_id, h.sg_event_id),
             gotickets_event_id = coalesce(a.gotickets_event_id, h.gt_event_id),
             tevo_venue_id      = coalesce(a.tevo_venue_id, h.venue_id),
             tevo_performer_id  = coalesce(a.tevo_performer_id, h.performer_id)
        FROM _hbf h
       WHERE h.hub_key IS NOT NULL AND a.aq_short_event_id = h.hub_key
      RETURNING a.aq_short_event_id, h.tevo_event_id, h.sg_event_id, h.gt_event_id, h.ld
    ), ins AS (
      INSERT INTO public.aq_event_map
        (aq_short_event_id, event_name, venue_name, event_date, city, state, performer, category,
         tevo_event_id, tevo_venue_id, tevo_performer_id, sg_event_id, gotickets_event_id,
         primary_source, aq_source)
      SELECT 'EVO-'||h.tevo_event_id, h.ev_name, h.venue_name, h.ts, h.city, h.st,
             h.performer, h.category, h.tevo_event_id, h.venue_id, h.performer_id,
             h.sg_event_id, h.gt_event_id, 'tevo', 'source_matcher'
      FROM _hbf h WHERE h.hub_key IS NULL
      ON CONFLICT (aq_short_event_id) DO NOTHING
      RETURNING aq_short_event_id, tevo_event_id, sg_event_id, gotickets_event_id, event_date
    ), logged AS (
      INSERT INTO public.aq_hub_source_backfill_log
        (aq_short_event_id, source, source_event_id, tevo_event_id, action, local_day)
      SELECT aq_short_event_id, 'seatgeek', sg_event_id, tevo_event_id, 'update', ld FROM upd WHERE sg_event_id IS NOT NULL
      UNION ALL
      SELECT aq_short_event_id, 'gotickets', gt_event_id, tevo_event_id, 'update', ld FROM upd WHERE gt_event_id IS NOT NULL
      UNION ALL
      SELECT aq_short_event_id, 'seatgeek', sg_event_id, tevo_event_id, 'insert', event_date::date FROM ins WHERE sg_event_id IS NOT NULL
      UNION ALL
      SELECT aq_short_event_id, 'gotickets', gotickets_event_id, tevo_event_id, 'insert', event_date::date FROM ins WHERE gotickets_event_id IS NOT NULL
      ON CONFLICT (aq_short_event_id, source) DO NOTHING
      RETURNING 1
    )
    SELECT (SELECT count(*) FROM upd), (SELECT count(*) FROM ins) INTO v_upd, v_ins;
  ELSE
    SELECT count(*) FILTER (WHERE hub_key IS NOT NULL), count(*) FILTER (WHERE hub_key IS NULL)
      INTO v_upd, v_ins FROM _hbf;
  END IF;

  RETURN jsonb_build_object(
    'applied', p_apply,
    'candidates', v_cand,
    'sg_ids', v_sg,
    'gt_ids', v_gt,
    'updated_existing_hub_row', v_upd,
    'inserted_new_hub_row', v_ins
  );
END $fn$;

REVOKE ALL ON FUNCTION public.aq_hub_backfill_from_source_matchers(boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.aq_hub_backfill_from_source_matchers(boolean, int) TO service_role;
