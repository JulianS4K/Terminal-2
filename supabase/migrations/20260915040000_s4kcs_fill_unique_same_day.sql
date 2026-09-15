-- Map the CRM rows where TEvo HAS the event and we were simply failing to match it.
--
-- Operator: "also go after those events, the evo ones". These are NOT the TEvo-absent bucket —
-- the mirror carries them. They decline today because rule 3 requires EXACT normalised name
-- equality while the CRM spells things differently: "Tennessee Vols Football" vs "Tennessee
-- Volunteers Football", "NBA Cup" vs "Emirates NBA Cup" (sponsor prefix), "Role Model" vs "Role
-- Model with Samia" (support act), "at" vs "vs", "Rec Hall" vs "Recreation Hall - Penn State
-- University". And 216 CRM rows arrive with no venue at all, so rule 1 cannot fire either.
--
-- SCOPE, deliberately narrow: a UNIQUE candidate on the SAME local day at name overlap >= 0.7.
--
-- THE +/-1 DAY CASES ARE EXCLUDED ON PURPOSE. There are 45 orders / 134 tickets sitting one day
-- off a unique candidate at average overlap 1.00, which looks like free money. It is not. The
-- offsets split almost evenly in BOTH directions (SeatGeek 12 before / 12 after, StubHub 5 / 12).
-- A timezone defect is ONE-directional — that asymmetry is exactly how the sg_event_date bug was
-- identified. A symmetric spread means the neighbouring candidate is usually a different night of
-- a run, so mapping them would walk straight back into the wrong-night class that mig
-- 20260915013000 had to clean up by hand.
--
-- TWO GUARDS, both found by reading the dry run rather than by reasoning about it:
--
--   1. NUMERIC TOKENS MUST AGREE. event_mapper_overlap scores "2027 BNP Paribas Open - Session
--      21" against "... Session 22" at 1.000. The normaliser keeps the digits ("session 21" vs
--      "session 22") but the overlap metric does not weigh the differing token. Session 21 and
--      Session 22 are different inventory on different days of the same tournament. So when both
--      names carry numeric tokens, the sets must be equal. When one side has none the rule cannot
--      apply and is skipped — which is what lets "2027 Concert In The Coliseum - Imagine Dragons
--      (21+)" still match a TEvo name carrying no digits at all.
--
--   2. IF THE CRM HAS A VENUE, IT MUST NOT CONTRADICT. "WORSHIP" at "Kia Forum - Inglewood, CA"
--      scored 1.000 against "Cece Winans with Charity Gayle, Red Worship and Terrian" at Gas
--      South Arena, Georgia — because "worship" is a token inside the TEvo name. Venue overlap
--      there is 0.000. The bar is deliberately LOW (>= 0.3) because CRM venue strings are rough:
--      "Rec Hall" vs "Recreation Hall - Penn State University" scores 0.5, "TPC of Scottsdale -
--      Scottsdale, AZ" vs "Coors Light Birds Nest At TPC Scottsdale" scores 1.0. The guard exists
--      to catch CONTRADICTION, not to demand agreement. A blank CRM venue cannot contradict, so
--      those rows pass on the name alone — which is the whole point, since blank venues are the
--      largest failure mode here.
--
-- First run: 35 rows mapped, 8 declined (2 by the number guard, 6 by the venue guard), and every
-- decline was one of the two patterns above. CRM future non-parking unmapped: 358 -> 322.
--
-- Fill-only, through the surface's own update_sql.
CREATE OR REPLACE FUNCTION public.s4kcs_fill_unique_same_day(p_apply boolean DEFAULT false)
RETURNS TABLE(out_row_key text, out_tevo bigint, out_crm_name text, out_tevo_name text,
              out_crm_venue text, out_tevo_venue text, out_day date, out_ovl numeric, out_action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_upd text; rr record; v_n int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '160000', true);

  SELECT s.update_sql INTO v_upd FROM public.event_mapper_surface_sql('s4kcs_orders') s;

  DROP TABLE IF EXISTS _sfd;
  CREATE TEMP TABLE _sfd ON COMMIT DROP AS
  WITH u AS (
    SELECT o.s4k_order_id, lower(o.source) AS src, o.event_name, o.event_date,
           nullif(trim(coalesce(o.venue_name, '')), '') AS venue
      FROM public.s4kcs_orders o
     WHERE o.tevo_event_id IS NULL AND o.event_date >= current_date
       AND coalesce(o.event_name, '') !~* 'parking|shuttle'
       AND o.event_name !~* '\(Date TBD\)|If Necessary|TBD vs TBD'),
  c AS (
    SELECT u.*, e.id AS tevo_id, e.name AS tevo_name, e.venue_name AS tevo_venue,
           public.event_mapper_overlap(public.event_mapper_norm_name(u.event_name),
                                       public.event_mapper_norm_name(e.name)) AS ovl
      FROM u JOIN public.events e
        ON left(e.occurs_at_local, 10) = u.event_date::text
       AND coalesce(e.name, '') !~* 'parking|shuttle'
       AND public.event_mapper_overlap(public.event_mapper_norm_name(u.event_name),
                                       public.event_mapper_norm_name(e.name)) >= 0.7),
  uniq AS (
    SELECT c.* FROM c
     WHERE (SELECT count(*) FROM c c2 WHERE c2.s4k_order_id = c.s4k_order_id) = 1)
  SELECT uniq.*,
         (SELECT coalesce(array_agg(m ORDER BY m), '{}') FROM regexp_matches(uniq.event_name, '\d+', 'g') AS t(m2), unnest(t.m2) AS m) AS crm_nums,
         (SELECT coalesce(array_agg(m ORDER BY m), '{}') FROM regexp_matches(uniq.tevo_name,  '\d+', 'g') AS t(m2), unnest(t.m2) AS m) AS tevo_nums,
         CASE WHEN uniq.venue IS NULL THEN NULL
              ELSE public.event_mapper_overlap(public.event_mapper_norm_name(uniq.venue),
                                               public.event_mapper_norm_name(uniq.tevo_venue)) END AS venue_ovl,
         NULL::text AS act
    FROM uniq;

  UPDATE _sfd SET act =
    CASE WHEN array_length(crm_nums,1) IS NOT NULL AND array_length(tevo_nums,1) IS NOT NULL
              AND crm_nums <> tevo_nums                        THEN 'decline_number_mismatch'
         WHEN venue_ovl IS NOT NULL AND venue_ovl < 0.3        THEN 'decline_venue_contradicts'
         ELSE 'map' END;

  IF p_apply THEN
    FOR rr IN SELECT * FROM _sfd WHERE act = 'map' LOOP
      EXECUTE v_upd USING rr.s4k_order_id, rr.tevo_id, 'crm_unique_same_day', round(rr.ovl, 2);
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN
        PERFORM public.event_mapper_apply(rr.src, NULL, rr.tevo_id, rr.event_name, rr.venue,
                                          rr.event_date, round(rr.ovl, 2), NULL, NULL);
      END IF;
    END LOOP;
    UPDATE _sfd SET act = 'mapped' WHERE act = 'map';
  END IF;

  RETURN QUERY SELECT f.s4k_order_id, f.tevo_id, f.event_name, f.tevo_name,
                      coalesce(f.venue, '(blank)'), f.tevo_venue, f.event_date, round(f.ovl, 2), f.act
                 FROM _sfd f ORDER BY f.act, f.ovl;
END $fn$;

REVOKE ALL ON FUNCTION public.s4kcs_fill_unique_same_day(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.s4kcs_fill_unique_same_day(boolean) TO service_role;

COMMENT ON FUNCTION public.s4kcs_fill_unique_same_day(boolean) IS
  'CRM rows with a UNIQUE same-local-day TEvo candidate at name overlap >= 0.7, guarded on numeric-token equality and venue non-contradiction. Same-day only; +/-1 day is refused on purpose. Dry run by default (mig 20260915040000).';

-- joins the single maintenance job, before the GoTickets fallback: a row that TEvo can still
-- take must be offered to TEvo first.
DO $cron$
BEGIN
  PERFORM cron.unschedule('id_spine_tick_15min') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'id_spine_tick_15min');
  PERFORM cron.schedule('id_spine_tick_15min', '8,23,38,53 * * * *', $body$
    BEGIN; SET LOCAL statement_timeout = '170s';
    DO $b$ BEGIN
      IF NOT public.cron_should_fire('id_spine_tick_15min') THEN RETURN; END IF;
      PERFORM public.event_mapper_anchor_ids();
      PERFORM public.tickets_dev_run(150);
      PERFORM public.tickets_dev_fill_outward(150);
      PERFORM public.tickets_dev_search_harvest();
      PERFORM public.tickets_dev_apply_hints('s4kcs_orders', true);
      PERFORM public.tickets_dev_apply_hints('sg_events_canonical', true);
      PERFORM public.s4kcs_fill_unique_same_day(true);
      -- only after every TEvo route has had its turn: key what TEvo genuinely lacks
      PERFORM public.event_mapper_gt_fallback('s4kcs_orders', true);
      PERFORM public.event_mapper_gt_fallback('vivid_orders', true);
      PERFORM public.event_mapper_gt_fallback('tickpick_orders', true);
      PERFORM public.event_mapper_gt_fallback('sg_events_canonical', true);
      PERFORM public.tickets_dev_search_enqueue('s4kcs_orders', 60);
      PERFORM public.tickets_dev_search_enqueue('sg_events_canonical', 60);
      PERFORM public.venue_xref_derive_by_id(true);
      PERFORM public.performer_xref_derive_from_events(true);
    END $b$; COMMIT;$body$);
END $cron$;
