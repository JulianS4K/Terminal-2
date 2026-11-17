-- Re-point the SeatGeek rows mapped to the wrong night.
--
-- Operator-authorised overwrite ("fix the wrong night rows"). Everything else in this work is
-- fill-only; this is the one place existing mappings are CHANGED, so every write is logged
-- row-by-row and is reversible from sg_night_correction_log.old_tevo_id.
--
-- SCOPE — corrected from the earlier estimate, which was too high. The sg_event_date defect
-- touches 2,253 rows, but that is the COLUMN being a UTC date; the mapper never relied on it
-- alone (rule 2 used the real instant, rule 3 name+day), so most rows landed right regardless.
-- The mappings actually on the wrong night are 363 of 5,884, and only 187 of those have an
-- id-path answer at all. 175 clear the guards below and were corrected; 12 were declined.
--
-- THE GUARDS ARE STRICTER THAN FOR A FILL, because this destroys information:
--   1. the id path must return a UNIQUE answer at the SeatGeek venue on SeatGeek's own local day
--      (from raw datetime_local, not the broken column);
--   2. the proposed event's name must overlap the SeatGeek name >= 0.5 AND be at least as good a
--      match as the mapping being replaced. Guard 2 is not decoration — without it the id path
--      wanted to send "Johnny Blue Skies and The Dark Clouds" to "Seattle Kraken at Detroit Red
--      Wings", an ALCS game to "Circus Vazquez", a John Williams tribute to "Weekend
--      Spectaculars - SA4", and a WNBA semifinal to "Phoebe Bridgers with Alex G". Those are
--      exactly the 10 rows it refuses;
--   3. OR the multi-night escape hatch: when the current and proposed TEvo events have the SAME
--      name, the name cannot discriminate between them and the day must. That is the six Olivia
--      Rodrigo dates, each mapped one night late to an identically-named event. Without this
--      arm the absolute 0.5 threshold blocked them, because the SeatGeek name carries support
--      acts the TEvo name does not ("... with The Last Dinner Party and Devon Again" -> 0.20).
--
-- THE HUB HAD TO MOVE TOO, and this is the part that would have silently undone everything.
-- aq_event_map.sg_event_id is a rule-0 IDENTITY source. 31 hub rows still bound these SeatGeek
-- ids to the OLD TEvo event, so the next event_mapper_run would have re-asserted the wrong
-- answer by identity. The stale association is cleared (the hub row itself is fine — it is the
-- sg_event_id link that is wrong) and the id re-pointed onto the correct hub row, fill-only and
-- never over an id already claimed for a different event. Verified after the run: 0 stale.
--
-- WHAT REMAINS: 188 rows still on the wrong night — 176 with no id-path answer (usually the
-- venue id does not resolve, or the mirror has no event that night) and the 12 declined above.
-- Those need the cold path or a human, not a bulk rule.

CREATE TABLE IF NOT EXISTS public.sg_night_correction_log (
  sg_event_id    bigint PRIMARY KEY,
  sg_event_name  text,
  sg_local_day   date,
  old_tevo_id    bigint NOT NULL,
  old_event_name text,
  old_local_day  date,
  new_tevo_id    bigint NOT NULL,
  new_event_name text,
  accept_rule    text,           -- name_rule | identical_name_rule
  ovl_old        numeric,
  ovl_new        numeric,
  corrected_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.sg_night_correction_log IS
  'Row-by-row audit of the one operator-authorised overwrite of existing SeatGeek mappings (wrong-night defect). old_tevo_id makes every correction reversible (mig 20260915013000).';

-- OUT params are named out_*: ovl_new/ovl_old/sg_event_id collide with the temp table's own
-- columns and resolve to the plpgsql variables (42702). Same trap as venue_xref_derive_by_id.
DROP FUNCTION IF EXISTS public.sg_fix_wrong_night(boolean);

CREATE FUNCTION public.sg_fix_wrong_night(p_apply boolean DEFAULT false)
RETURNS TABLE(out_sg_event_id bigint, out_sg_event_name text, out_sg_local_day date,
              out_old_tevo bigint, out_old_name text, out_old_day date,
              out_new_tevo bigint, out_new_name text, out_ovl_old numeric, out_ovl_new numeric, out_action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_hub_cleared int; v_hub_set int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '150000', true);

  DROP TABLE IF EXISTS _sgfix;
  CREATE TEMP TABLE _sgfix ON COMMIT DROP AS
  WITH cur AS (
    SELECT c.sg_event_id, c.sg_event_name, c.sg_venue_id, c.tevo_event_id AS cur_tevo,
           left(c.raw_event_jsonb->>'datetime_local', 10)::date AS sg_day,
           (SELECT p->>'id' FROM jsonb_array_elements(coalesce(c.raw_event_jsonb->'performers', '[]'::jsonb)) p
             WHERE p->>'primary' = 'true' LIMIT 1) AS sg_perf,
           left(e.occurs_at_local, 10)::date AS cur_day, e.name AS cur_name
      FROM public.sg_events_canonical c
      JOIN public.events e ON e.id = c.tevo_event_id
     WHERE c.tevo_event_id IS NOT NULL AND c.sg_venue_id IS NOT NULL
       AND c.raw_event_jsonb ? 'datetime_local')
  SELECT cur.sg_event_id AS sgid, cur.sg_event_name AS sgname, cur.sg_day, cur.cur_tevo, cur.cur_name, cur.cur_day,
         r.tevo_event_id AS new_tevo, pe.name AS new_name,
         round(public.event_mapper_overlap(public.event_mapper_norm_name(cur.sg_event_name),
                                           public.event_mapper_norm_name(cur.cur_name)), 2) AS o_old,
         round(public.event_mapper_overlap(public.event_mapper_norm_name(cur.sg_event_name),
                                           public.event_mapper_norm_name(pe.name)), 2) AS o_new,
         NULL::text AS act
    FROM cur
    JOIN LATERAL public.event_mapper_resolve_by_id('seatgeek', cur.sg_venue_id, cur.sg_day,
                                                   cur.sg_perf, cur.sg_event_name) r ON true
    JOIN public.events pe ON pe.id = r.tevo_event_id
   WHERE cur.cur_day <> cur.sg_day AND r.tevo_event_id <> cur.cur_tevo;

  UPDATE _sgfix SET act =
    CASE WHEN o_new >= 0.5 AND o_new >= o_old                THEN 'name_rule'
         WHEN lower(trim(cur_name)) = lower(trim(new_name))  THEN 'identical_name_rule'
         WHEN o_new < 0.5                                     THEN 'decline_new_name_weak'
         ELSE 'decline_current_name_better' END;

  IF p_apply THEN
    INSERT INTO public.sg_night_correction_log (sg_event_id, sg_event_name, sg_local_day,
           old_tevo_id, old_event_name, old_local_day, new_tevo_id, new_event_name,
           accept_rule, ovl_old, ovl_new, corrected_at)
    SELECT f.sgid, f.sgname, f.sg_day, f.cur_tevo, f.cur_name, f.cur_day,
           f.new_tevo, f.new_name, f.act, f.o_old, f.o_new, now()
      FROM _sgfix f WHERE f.act IN ('name_rule', 'identical_name_rule')
    ON CONFLICT (sg_event_id) DO NOTHING;

    UPDATE public.sg_events_canonical c
       SET tevo_event_id = f.new_tevo, match_method = 'wrong_night_correction',
           match_confidence = 0.97, matched_at = now(), updated_at = now()
      FROM _sgfix f
     WHERE c.sg_event_id = f.sgid AND c.tevo_event_id = f.cur_tevo
       AND f.act IN ('name_rule', 'identical_name_rule');

    -- the hub, or rule 0 identity re-asserts the old answer on the next run
    UPDATE public.aq_event_map a SET sg_event_id = NULL
      FROM _sgfix f
     WHERE a.sg_event_id = f.sgid AND a.tevo_event_id = f.cur_tevo
       AND f.act IN ('name_rule', 'identical_name_rule');
    GET DIAGNOSTICS v_hub_cleared = ROW_COUNT;

    UPDATE public.aq_event_map a SET sg_event_id = f.sgid
      FROM _sgfix f
     WHERE a.tevo_event_id = f.new_tevo AND a.sg_event_id IS NULL
       AND f.act IN ('name_rule', 'identical_name_rule')
       AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o
                        WHERE o.sg_event_id = f.sgid AND o.tevo_event_id IS DISTINCT FROM f.new_tevo);
    GET DIAGNOSTICS v_hub_set = ROW_COUNT;

    RAISE NOTICE 'hub: % stale sg_event_id cleared, % re-pointed', v_hub_cleared, v_hub_set;
    UPDATE _sgfix SET act = 'corrected' WHERE act IN ('name_rule', 'identical_name_rule');
  END IF;

  RETURN QUERY SELECT f.sgid, f.sgname, f.sg_day, f.cur_tevo, f.cur_name, f.cur_day,
                      f.new_tevo, f.new_name, f.o_old, f.o_new, f.act
                 FROM _sgfix f ORDER BY f.act, f.sg_day;
END $fn$;

REVOKE ALL ON FUNCTION public.sg_fix_wrong_night(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sg_fix_wrong_night(boolean) TO service_role;

COMMENT ON FUNCTION public.sg_fix_wrong_night(boolean) IS
  'One-off operator-authorised correction of SeatGeek rows mapped to the wrong night. Dry run by default; every write logged to sg_night_correction_log and reversible from old_tevo_id (mig 20260915013000).';
