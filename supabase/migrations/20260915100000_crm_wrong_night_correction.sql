-- Correct the CRM orders that are mapped to the night BEFORE the one they were sold for.
--
-- Operator: "continue fix". This is the 325-row off-by-one population surfaced while building the
-- staged cascade (mig 20260915070000) and deliberately left alone there because it is an
-- OVERWRITE of existing mappings, not a fill.
--
-- THE POPULATION. 328 future non-parking CRM orders sit on a different local day from the TEvo
-- event they are mapped to, every one of them by exactly one day, and every one of them mapped by
-- a LEGACY method (name_date, name_date_venue, venue_date_nameguard). None of the methods the
-- cascade added is in it. The offsets are strongly one-directional -- StubHub 162/162, SeatGeek
-- 64/64, GoTickets 23/23, Vivid 18/18 all have TEvo on the day BEFORE -- which is the signature
-- of a date-labelling defect rather than of random mis-matching.
--
-- THE TRAP, AND WHY THIS IS NOT "ASK THE CASCADE AND WRITE WHAT IT SAYS".
-- Run the cascade over the population and it proposes a different event for 240 of them, landing
-- on the CRM order's own date every time and on another wrong day zero times. That looks like 240
-- free corrections. It is not. A one-day gap has TWO possible causes and they need opposite
-- treatment:
--
--   (a) the CRM date is a genuine LOCAL day and the mapping is on the wrong night  -> CORRECT it
--   (b) the CRM date is a UTC day for an evening show that crosses midnight UTC, so the mapping
--       is RIGHT and only the label differs                                        -> LEAVE IT
--
-- In case (b) "correcting" the row moves a CORRECT mapping onto the following night. Measured:
-- of the 240 proposals, 129 are case (b). Blindly applying the cascade here would have broken
-- more correct mappings than it fixed.
--
-- venue_timezone (mig 20260915050000) is what tells the two apart, and this is the job it was
-- built for. Take the INCUMBENT event's local time, put it through its venue's IANA zone, and ask
-- what UTC date that instant falls on. If that equals the CRM order's date, the CRM date is a UTC
-- label and the incumbent is right. Only when it does NOT is the gap a real wrong-night.
--
--   proposals  incumbent-right (b)  tz unknown  SAFE TO CORRECT (a)
--        240                  129            1                 110
--
--   stubhub 129/81/0/48 · seatgeek 56/20/0/36 · gametime 20/5/0/15
--   gotickets 18/14/0/4 · vivid 13/5/1/7 · tickpick 4/4/0/0
--
-- TickPick proposing 4 and correcting 0 is the expected answer, not a failure: tickpick_orders
-- dates are a known UTC landmine (PROJECT_BIBLE §3), so all four are case (b).
--
-- FOUR GUARDS, all required together:
--   1. the cascade returns a DIFFERENT event than the row currently holds;
--   2. that event's local day equals the CRM order's own date;
--   3. the incumbent's venue has a known IANA zone -- unknown means CANNOT DECIDE, and the row is
--      skipped rather than guessed at (substituting a default zone is how these defects started);
--   4. the CRM date is NOT the incumbent's UTC date, i.e. case (b) is positively ruled out.
--
-- Every write is logged to s4kcs_night_correction_log with old_tevo_id, so the batch reverses with
-- one UPDATE ... FROM the log. Nothing re-asserts the old answer afterwards: event_mapper_map_surface
-- only touches rows WHERE previous IS NULL, so a corrected row is never re-asked.

CREATE TABLE IF NOT EXISTS public.s4kcs_night_correction_log (
  s4k_order_id  text PRIMARY KEY,
  old_tevo_id   bigint,
  new_tevo_id   bigint NOT NULL,
  crm_date      date,
  old_local_day text,
  new_local_day text,
  method        text,
  corrected_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.s4kcs_night_correction_log IS
  'Every s4kcs_orders.tevo_event_id re-pointed off a wrong night. old_tevo_id makes the batch reversible (mig 20260915100000).';

CREATE OR REPLACE FUNCTION public.s4kcs_fix_wrong_night(p_apply boolean DEFAULT false,
                                                        p_limit int DEFAULT 400)
RETURNS TABLE(out_order text, out_src text, out_name text, out_crm_day date,
              out_old_tevo bigint, out_old_day text, out_new_tevo bigint, out_new_day text,
              out_method text, out_action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE rr record; v_n int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '165000', true);

  FOR rr IN
    SELECT b.s4k_order_id, b.src, b.event_name, b.event_date, b.cur, b.cur_loc,
           st.tevo_event_id AS new_tevo, st.method AS new_method,
           en.occurs_at_local AS new_loc,
           (vt.iana_tz IS NULL) AS tz_unknown,
           (vt.iana_tz IS NOT NULL
             AND ((b.cur_loc::timestamp AT TIME ZONE vt.iana_tz) AT TIME ZONE 'UTC')::date = b.event_date
           ) AS incumbent_right
      FROM (
        SELECT o.s4k_order_id, lower(o.source) AS src, o.event_name, o.venue_name, o.event_date,
               o.tevo_event_id AS cur, e.occurs_at_local AS cur_loc, e.venue_id AS cur_venue_id
          FROM public.s4kcs_orders o
          JOIN public.events e ON e.id = o.tevo_event_id
         WHERE o.event_date >= current_date
           AND coalesce(o.event_name, '') !~* 'parking|shuttle'
           AND left(e.occurs_at_local, 10) <> o.event_date::text
         ORDER BY o.event_date
         LIMIT greatest(1, least(2000, p_limit))) b
      LEFT JOIN LATERAL public.event_mapper_resolve_staged(
             's4kcs_orders', b.s4k_order_id, b.src, NULL, b.event_name, NULL,
             b.venue_name, NULL, NULL, b.event_date, NULL, NULL, NULL, true, 0.5, false) st ON true
      LEFT JOIN public.events en ON en.id = st.tevo_event_id
      LEFT JOIN public.venue_timezone vt ON vt.tevo_venue_id = b.cur_venue_id
  LOOP
    out_order := rr.s4k_order_id; out_src := rr.src; out_name := rr.event_name;
    out_crm_day := rr.event_date; out_old_tevo := rr.cur; out_old_day := left(rr.cur_loc, 10);
    out_new_tevo := rr.new_tevo; out_new_day := left(rr.new_loc, 10); out_method := rr.new_method;

    IF rr.new_tevo IS NULL THEN
      out_action := 'decline_cascade_has_no_answer';
    ELSIF rr.new_tevo = rr.cur THEN
      out_action := 'decline_cascade_agrees_with_current';
    ELSIF left(rr.new_loc, 10) <> rr.event_date::text THEN
      out_action := 'decline_proposal_not_on_crm_day';
    ELSIF rr.tz_unknown THEN
      out_action := 'decline_venue_timezone_unknown';
    ELSIF rr.incumbent_right THEN
      out_action := 'decline_crm_date_is_utc_incumbent_right';
    ELSE
      out_action := 'correct';
      IF p_apply THEN
        INSERT INTO public.s4kcs_night_correction_log
               (s4k_order_id, old_tevo_id, new_tevo_id, crm_date, old_local_day, new_local_day, method)
        VALUES (rr.s4k_order_id, rr.cur, rr.new_tevo, rr.event_date,
                left(rr.cur_loc, 10), left(rr.new_loc, 10), rr.new_method)
        ON CONFLICT (s4k_order_id) DO UPDATE
          SET old_tevo_id = excluded.old_tevo_id, new_tevo_id = excluded.new_tevo_id,
              crm_date = excluded.crm_date, old_local_day = excluded.old_local_day,
              new_local_day = excluded.new_local_day, method = excluded.method,
              corrected_at = now();

        UPDATE public.s4kcs_orders
           SET tevo_event_id = rr.new_tevo,
               map_method = 'night_corrected_' || coalesce(rr.new_method, 'cascade'),
               map_confidence = 0.95, mapped_at = now()
         WHERE s4k_order_id = rr.s4k_order_id AND tevo_event_id = rr.cur;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n > 0 THEN out_action := 'corrected'; END IF;
      END IF;
    END IF;
    RETURN NEXT;
  END LOOP;
END $fn$;

REVOKE ALL ON FUNCTION public.s4kcs_fix_wrong_night(boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.s4kcs_fix_wrong_night(boolean, int) TO service_role;

COMMENT ON FUNCTION public.s4kcs_fix_wrong_night(boolean, int) IS
  'Re-points CRM orders mapped to the wrong night, using the staged cascade for the answer and venue_timezone to rule out the case where the CRM date is merely a UTC label and the incumbent is right. Logged to s4kcs_night_correction_log and reversible. Dry run by default (mig 20260915100000).';
