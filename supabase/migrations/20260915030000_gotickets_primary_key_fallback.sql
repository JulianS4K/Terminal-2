-- GoTickets as the primary source and event key where TEvo has no event at all.
--
-- Operator: "for cases where there are no evo events, use gotickets as primary source and event
-- key". About a third of the residue this session is the TEvo-absent bucket — real events,
-- selling on three or four marketplaces, that the TEvo mirror does not carry. Broadway is the
-- clearest case (6 future Richard Rodgers dates against an eight-shows-a-week run) but college
-- football is worse: Delaware Stadium, Acrisure Bounce House and Memorial Stadium-KS have ZERO
-- TEvo events ever. Those rows can never earn a tevo_event_id, so today they sit unmapped
-- forever and are retried at every tick. GoTickets carries 263k events, so where TEvo is absent
-- it is the natural anchor.
--
-- WHAT THIS DELIBERATELY DOES NOT DO: it never writes a GoTickets id into tevo_event_id. That
-- column is the canonical TEvo key and every downstream consumer — the deal scanner, listings,
-- pricing, N2S cover — joins on it. A foreign id there would corrupt all of them silently, with
-- no error anywhere. tevo_event_id stays NULL on these rows, which is CORRECT: there is no TEvo
-- inventory to price or cover. The GoTickets key is additive; a consumer opts in by reading
-- primary_source / aq_short_event_id, never by accident. Verified after the run: 0 rows with
-- primary_source='gotickets' carry a tevo_event_id.
--
-- THE KEY. aq_event_map.aq_short_event_id is already the hub's source-agnostic key — unique, and
-- already carried on s4kcs_orders, vivid_orders, tickpick_orders and evo_orders — and
-- create_system_aq_event has long minted 'SYS-<md5>' rows for events TEvo lacks (5,145 of them).
-- Those are opaque and carry no source id. This uses 'GT-<gt_event_id>': stable, traceable back
-- to GoTickets, and self-deduplicating.
--
-- IDENTITY ONLY, NO NEW FUZZY MATCH. The GoTickets id comes from a tickets.dev cluster already
-- matched by marketplace id or by name + local day. gotickets_event carries only event_time_utc,
-- with no local time and no timezone, so matching it directly on a local day would mean
-- re-deriving a timezone — precisely the class of assumption that produced the SeatGeek
-- wrong-night defect earlier in this session (mig 20260915013000). The catalogue hands us an IANA
-- timezone per venue, so the cluster is the safe route and the only one used here.
--
-- THREE CONDITIONS, all required, and the third is the one that matters:
--   (a) the cluster's GoTickets id is not already bound to a TEvo event in gotickets_event;
--   (b) none of the cluster's marketplace ids resolves to a TEvo event through the hub;
--   (c) the TEvo mirror holds NO event at that venue on that local day.
-- (c) is deliberately name-agnostic. Without it the first draft would have keyed AC/DC at Lincoln
-- Financial Field 2026-09-29 to GoTickets even though the mirror carries an event there that
-- night — demoting a row the normal mapper still had a chance at. Adding (c) cut the candidate
-- set from ~130 to 72, and every one of the 58 it removed was a not-yet-mapped row rather than a
-- TEvo-absent one. "Not yet bound to TEvo" and "TEvo does not have it" are different things.
--
-- Runs in the maintenance cron only AFTER every TEvo route has had its turn.

COMMENT ON COLUMN public.aq_event_map.primary_source IS
  'Which id space is canonical for this row: tevo (tevo_event_id) or gotickets (gotickets_event_id, aq_short_event_id = GT-<id>). NULL on legacy rows means tevo (mig 20260915030000).';

UPDATE public.aq_event_map SET primary_source = 'tevo'
 WHERE primary_source IS NULL AND tevo_event_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.event_mapper_gt_fallback(p_surface text, p_apply boolean DEFAULT false)
RETURNS TABLE(out_row_key text, out_gt_event_id bigint, out_aq_key text, out_event_name text,
              out_venue text, out_local_day date, out_action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE rr record; v_key text; v_n int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '160000', true);

  IF p_surface NOT IN ('s4kcs_orders', 'vivid_orders', 'tickpick_orders', 'sg_events_canonical') THEN
    RAISE EXCEPTION 'event_mapper_gt_fallback: unsupported surface %', p_surface;
  END IF;

  DROP TABLE IF EXISTS _gtc;
  CREATE TEMP TABLE _gtc ON COMMIT DROP AS
  SELECT t.tdev_id, t.name, t.local_date, t.venue_name, t.venue_city, t.venue_state, t.venue_tz,
         (SELECT s.source_event_id::bigint FROM public.tickets_dev_source_id s
           WHERE s.tdev_id = t.tdev_id AND s.marketplace = 'gotickets'
             AND s.source_event_id ~ '^[0-9]+$' LIMIT 1) AS gt_id
    FROM public.tickets_dev_event t
   WHERE t.local_date IS NOT NULL;
  DELETE FROM _gtc WHERE gt_id IS NULL;

  DELETE FROM _gtc c
   WHERE EXISTS (SELECT 1 FROM public.gotickets_event g
                  WHERE g.gt_event_id = c.gt_id AND g.tevo_event_id IS NOT NULL)
      OR EXISTS (SELECT 1 FROM public.tickets_dev_source_id s
                   JOIN public.aq_event_map a
                     ON (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
                     OR (s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
                     OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
                     OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)
                  WHERE s.tdev_id = c.tdev_id AND a.tevo_event_id IS NOT NULL)
      OR EXISTS (SELECT 1 FROM public.events e
                  WHERE lower(trim(e.venue_name)) = lower(trim(c.venue_name))
                    AND left(e.occurs_at_local, 10) = c.local_date::text)
      OR EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                   JOIN public.events e ON e.venue_id = m.tevo_venue_id
                  WHERE lower(trim(m.canonical_name)) = lower(trim(c.venue_name))
                    AND left(e.occurs_at_local, 10) = c.local_date::text);

  DROP TABLE IF EXISTS _gtr;
  CREATE TEMP TABLE _gtr (row_key text, tdev_id text);

  IF p_surface = 'vivid_orders' THEN
    INSERT INTO _gtr SELECT v.vivid_order_id, s.tdev_id
      FROM public.vivid_orders v
      JOIN public.tickets_dev_source_id s ON s.marketplace = 'vividseats'
                                         AND s.source_event_id = v.raw->>'productionId'
     WHERE v.tevo_event_id IS NULL AND v.aq_short_event_id IS NULL;
  ELSIF p_surface = 'tickpick_orders' THEN
    INSERT INTO _gtr SELECT o.tp_order_id, p.tdev_id
      FROM public.tickpick_orders o
      JOIN public.tickets_dev_row_probe p ON p.surface = 'tickpick_orders' AND p.row_key = o.tp_order_id
     WHERE o.tevo_event_id IS NULL AND p.outcome = 'matched' AND o.aq_short_event_id IS NULL;
  ELSE
    INSERT INTO _gtr SELECT p.row_key, p.tdev_id
      FROM public.tickets_dev_row_probe p
     WHERE p.surface = p_surface AND p.outcome = 'matched';
  END IF;

  FOR rr IN
    SELECT r.row_key, c.* FROM _gtr r JOIN _gtc c ON c.tdev_id = r.tdev_id
  LOOP
    v_key := 'GT-' || rr.gt_id::text;

    IF p_apply THEN
      -- the hub row for a GoTickets-primary event. tevo_event_id stays NULL, on purpose.
      INSERT INTO public.aq_event_map (aq_short_event_id, event_name, venue_name, city, state,
                                       event_date, gotickets_event_id, primary_source, aq_source, imported_at)
      VALUES (v_key, rr.name, rr.venue_name, rr.venue_city, rr.venue_state,
              rr.local_date::timestamp, rr.gt_id, 'gotickets', 'gotickets_primary', now())
      ON CONFLICT (aq_short_event_id) DO UPDATE
        SET gotickets_event_id = coalesce(public.aq_event_map.gotickets_event_id, excluded.gotickets_event_id),
            primary_source = coalesce(public.aq_event_map.primary_source, 'gotickets'),
            event_name = coalesce(public.aq_event_map.event_name, excluded.event_name),
            venue_name = coalesce(public.aq_event_map.venue_name, excluded.venue_name);

      IF p_surface = 's4kcs_orders' THEN
        UPDATE public.s4kcs_orders SET aq_short_event_id = v_key
         WHERE s4k_order_id = rr.row_key AND tevo_event_id IS NULL AND aq_short_event_id IS DISTINCT FROM v_key;
      ELSIF p_surface = 'vivid_orders' THEN
        UPDATE public.vivid_orders SET aq_short_event_id = v_key
         WHERE vivid_order_id = rr.row_key AND tevo_event_id IS NULL AND aq_short_event_id IS DISTINCT FROM v_key;
      ELSIF p_surface = 'tickpick_orders' THEN
        UPDATE public.tickpick_orders SET aq_short_event_id = v_key
         WHERE tp_order_id = rr.row_key AND tevo_event_id IS NULL AND aq_short_event_id IS DISTINCT FROM v_key;
      END IF;
      GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;

    out_row_key := rr.row_key; out_gt_event_id := rr.gt_id; out_aq_key := v_key;
    out_event_name := rr.name; out_venue := rr.venue_name; out_local_day := rr.local_date;
    out_action := CASE WHEN p_apply THEN 'keyed' ELSE 'would_key' END;
    RETURN NEXT;
  END LOOP;
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapper_gt_fallback(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_gt_fallback(text, boolean) TO service_role;

COMMENT ON FUNCTION public.event_mapper_gt_fallback(text, boolean) IS
  'Keys TEvo-absent events to GoTickets: hub row aq_short_event_id = GT-<gt_event_id>, primary_source = gotickets, tevo_event_id left NULL. Identity only, from a matched tickets.dev cluster, and only where the mirror has nothing at that venue that day. Dry run by default (mig 20260915030000).';

-- one canonical key per event, whichever id space it lives in. Read THIS rather than assuming
-- tevo_event_id is always the answer.
CREATE OR REPLACE VIEW public.v_event_key AS
SELECT a.aq_short_event_id,
       coalesce(a.primary_source, CASE WHEN a.tevo_event_id IS NOT NULL THEN 'tevo' END) AS primary_source,
       CASE WHEN a.tevo_event_id IS NOT NULL THEN 'tevo:' || a.tevo_event_id::text
            WHEN a.gotickets_event_id IS NOT NULL AND coalesce(a.primary_source,'') = 'gotickets'
                 THEN 'gt:' || a.gotickets_event_id::text
            ELSE 'aq:' || a.aq_short_event_id END AS event_key,
       a.tevo_event_id, a.gotickets_event_id, a.event_name, a.venue_name, a.event_date,
       a.sg_event_id, a.vivid_event_id, a.sh_event_id, a.tm_event_id, a.tp_event_id
  FROM public.aq_event_map a;

REVOKE ALL ON public.v_event_key FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_event_key TO service_role;

COMMENT ON VIEW public.v_event_key IS
  'One canonical key per hub event: tevo:<id> where TEvo has it, gt:<id> where GoTickets is primary, aq:<short id> otherwise (mig 20260915030000).';

-- the fallback joins the single maintenance job, AFTER every TEvo route has had its turn
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
      -- only after the TEvo routes have had their turn: key what TEvo genuinely lacks
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
