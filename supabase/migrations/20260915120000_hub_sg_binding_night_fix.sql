-- Correct the handful of aq_event_map.sg_event_id bindings that point at the wrong night.
--
-- Found by a self-check, not by looking for it. After seeding 201 catalogue rows from orders
-- (mig 20260915110000), 154 of them mapped and 153 landed on the seeded local day. The one that
-- did not was Zara Larsson at Greek Theatre - Los Angeles: the order payload puts SeatGeek event
-- 18211752 on 2026-09-30 19:30, the row mapped to the 09-29 show, and TEvo turns out to hold BOTH
-- nights (3368956 on 09-29, 3369288 on 09-30). The seeded data was right; the HUB was wrong, and
-- it won because it came through stage 2 as `identity_hub`.
--
-- WHY THIS MATTERS OUT OF PROPORTION TO ITS SIZE. aq_event_map.sg_event_id is a rule-0 / stage-2
-- IDENTITY source, scored 1.00. A wrong row there outranks every piece of evidence the cascade can
-- gather -- venue, day, performer, catalogue, timezone -- so it is the single worst place in the
-- system to hold a wrong answer, and it re-asserts itself on every run. mig 20260915013000 had to
-- clear 31 of these for exactly that reason.
--
-- SCOPE, measured before acting: of 3,482 future hub bindings carrying an sg_event_id, 38 (1.1%)
-- disagree with the catalogue's local day and only 6 have a confident alternative. So the class is
-- nearly closed -- the earlier sweep did the bulk -- and this is the tail, not a systemic defect.
-- The other 32 are left alone: no same-venue event on the catalogue's day at name overlap >= 0.8
-- means there is nothing to move them to, and inventing a target is how wrong-night bindings get
-- created in the first place.
--
-- GUARDS: the replacement must be at the SAME venue, on the day the CATALOGUE says (preferring the
-- explicit datetime_local over the UTC-ambiguous sg_event_date), and carry a name overlap >= 0.8
-- with the event being replaced. Logged to sg_hub_binding_correction_log with old_tevo_id, so it
-- reverses with one UPDATE ... FROM the log.

CREATE TABLE IF NOT EXISTS public.sg_hub_binding_correction_log (
  aq_short_event_id text PRIMARY KEY,
  sg_event_id   bigint NOT NULL,
  old_tevo_id   bigint,
  new_tevo_id   bigint NOT NULL,
  sg_local_day  text,
  old_local_day text,
  new_local_day text,
  corrected_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.sg_hub_binding_correction_log IS
  'Every aq_event_map.sg_event_id binding re-pointed off a wrong night. Reversible from old_tevo_id (mig 20260915120000).';

CREATE OR REPLACE FUNCTION public.aq_hub_fix_sg_night(p_apply boolean DEFAULT false)
RETURNS TABLE(out_key text, out_sg_event_id bigint, out_old_tevo bigint, out_new_tevo bigint,
              out_sg_day text, out_old_day text, out_new_day text, out_action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE rr record; v_n int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '160000', true);

  FOR rr IN
    SELECT a.aq_short_event_id AS key, a.sg_event_id, a.tevo_event_id AS old_tevo,
           coalesce(nullif(left(c.raw_event_jsonb->>'datetime_local', 10), ''), c.sg_event_date::text) AS sg_day,
           left(e.occurs_at_local, 10) AS old_day,
           (SELECT e2.id FROM public.events e2
             WHERE e2.venue_name = e.venue_name
               AND left(e2.occurs_at_local, 10)
                   = coalesce(nullif(left(c.raw_event_jsonb->>'datetime_local', 10), ''), c.sg_event_date::text)
               AND public.event_mapper_overlap(public.event_mapper_norm_name(e.name),
                                               public.event_mapper_norm_name(e2.name)) >= 0.8
             ORDER BY e2.id LIMIT 1) AS new_tevo
      FROM public.aq_event_map a
      JOIN public.sg_events_canonical c ON c.sg_event_id = a.sg_event_id
      JOIN public.events e ON e.id = a.tevo_event_id
     WHERE a.sg_event_id IS NOT NULL AND a.tevo_event_id IS NOT NULL
       AND c.sg_event_date >= current_date
       AND coalesce(nullif(left(c.raw_event_jsonb->>'datetime_local', 10), ''), c.sg_event_date::text)
           <> left(e.occurs_at_local, 10)
  LOOP
    out_key := rr.key; out_sg_event_id := rr.sg_event_id; out_old_tevo := rr.old_tevo;
    out_new_tevo := rr.new_tevo; out_sg_day := rr.sg_day; out_old_day := rr.old_day;
    out_new_day := rr.sg_day;

    IF rr.new_tevo IS NULL THEN
      out_action := 'decline_no_same_venue_event_on_catalog_day';
    ELSIF rr.new_tevo = rr.old_tevo THEN
      out_action := 'decline_same_event';
    ELSE
      out_action := 'correct';
      IF p_apply THEN
        INSERT INTO public.sg_hub_binding_correction_log
               (aq_short_event_id, sg_event_id, old_tevo_id, new_tevo_id, sg_local_day, old_local_day, new_local_day)
        VALUES (rr.key, rr.sg_event_id, rr.old_tevo, rr.new_tevo, rr.sg_day, rr.old_day, rr.sg_day)
        ON CONFLICT (aq_short_event_id) DO UPDATE
          SET old_tevo_id = excluded.old_tevo_id, new_tevo_id = excluded.new_tevo_id,
              corrected_at = now();

        UPDATE public.aq_event_map
           SET tevo_event_id = rr.new_tevo
         WHERE aq_short_event_id = rr.key AND tevo_event_id = rr.old_tevo;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n > 0 THEN out_action := 'corrected'; END IF;
      END IF;
    END IF;
    RETURN NEXT;
  END LOOP;
END $fn$;

REVOKE ALL ON FUNCTION public.aq_hub_fix_sg_night(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.aq_hub_fix_sg_night(boolean) TO service_role;

COMMENT ON FUNCTION public.aq_hub_fix_sg_night(boolean) IS
  'Re-points aq_event_map rows whose sg_event_id binding sits on a different local day from the SeatGeek catalogue, where a same-venue event exists on the catalogue day at name overlap >= 0.8. Identity sources must be right: this column is read at confidence 1.00. Logged and reversible. Dry run by default (mig 20260915120000).';
