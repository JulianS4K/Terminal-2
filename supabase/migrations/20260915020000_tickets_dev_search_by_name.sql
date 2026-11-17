-- Catalogue lookup for rows that carry NO marketplace event id.
--
-- Operator: "incorporate the tickets.dev API for any that we are unable to map".
--
-- The existing bridge (mig 20260914211000) is keyed by marketplace id, which covers Vivid and
-- GoTickets rows. It cannot touch the two biggest decliner pools — s4kcs CRM orders and
-- sg_events_canonical — because those rows have no id to look up with. This adds the only other
-- route the API offers: ?query=<event name>, then matching the result set ourselves.
--
-- MEASURED CONTRACT (tested against the live API; the PDF could not be parsed in this container,
-- and testing beats trusting a doc anyway):
--   * pageSize=100 works, page=N works — 100 results per call.
--   * date= and venue= are ACCEPTED AND IGNORED. query=Hadestown returns total 872 with or
--     without either. There is NO server-side filtering, so the date/venue match happens here.
--   * name selectivity varies enormously: "Rutgers Scarlet Knights at Northwestern Wildcats
--     Football" returns 4; "Hadestown" returns 872. One page of 100 covers the former easily and
--     would need nine pages for the latter, so long runs are bounded out (outcome 'too_broad')
--     rather than paged — paging a Broadway run to find one night is not worth the calls.
--
-- WHAT IT RECOVERS, and why it matters more than the ids. 216 of the unmapped CRM rows arrive
-- with venue_name BLANK in the feed — all of them SeatGeek — so rule 1 (venue + local day) had
-- literally nothing to match on and the row could only ever reach the weakest rules. The
-- catalogue supplies that venue. It also supplies the marketplace ids, which may resolve through
-- the hub directly. Either is enough; the venue is the one that unlocks the blank rows.
--
-- HONEST YIELD. First live run over 120 CRM rows: 71 matched a unique cluster, 16 ambiguous, 33
-- with nothing on that day. Of the 71, 35 produced a mapping — 20 by hub identity, 15 by the
-- recovered venue. Future non-parking CRM decliners went 387 -> 358. This is worth roughly a
-- fifth of the residue, not all of it, and saying otherwise would be overselling it.
--
-- UNIQUE-OR-DECLINE, and it genuinely bites here. "A Tribute to ABBA" on 2026-09-25 returns TWO
-- same-day events — Sebastiani Theatre and the Hollywood Bowl. A CRM row with no venue cannot
-- choose between them, so it declines rather than guess. That is the 16 'ambiguous' above.
--
-- The parking filter is not optional either: a name search returns the parking variant of the
-- same event on the same night ("... Football Parking" at "Ryan Field Parking"), which would
-- otherwise be a second candidate and turn a clean match into an ambiguity — or worse, be the
-- one picked.
--
-- RULE 2: net.http_get only, /v1/events (free, never billed, not rate limited), key read inline
-- from vault secret 'tickets.dev'. No write path exists here and none may be added.

CREATE TABLE IF NOT EXISTS public.tickets_dev_row_probe (
  surface      text NOT NULL,
  row_key      text NOT NULL,
  query_text   text,
  match_day    date,
  req_id       bigint,
  requested_at timestamptz NOT NULL DEFAULT now(),
  outcome      text,          -- NULL in flight | matched | no_same_day | ambiguous | too_broad | http_<code> | no_response
  tdev_id      text,          -- the single cluster it resolved to, when matched
  candidates   int,
  settled_at   timestamptz,
  PRIMARY KEY (surface, row_key)
);
CREATE INDEX IF NOT EXISTS tickets_dev_row_probe_inflight_idx
  ON public.tickets_dev_row_probe (req_id) WHERE outcome IS NULL;
CREATE INDEX IF NOT EXISTS tickets_dev_row_probe_matched_idx
  ON public.tickets_dev_row_probe (surface, outcome) WHERE outcome = 'matched';

COMMENT ON TABLE public.tickets_dev_row_probe IS
  'Name-search probes for rows with no marketplace id. One row per (surface, row_key); tdev_id is the single catalogue cluster it resolved to (mig 20260915020000).';

-- percent-encode for the query string; event names carry &, #, and accented characters
CREATE OR REPLACE FUNCTION public.url_encode(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT coalesce(string_agg(
           CASE WHEN c ~ '[A-Za-z0-9_.~-]' THEN c
                ELSE upper(regexp_replace(encode(convert_to(c, 'UTF8'), 'hex'), '(..)', '%\1', 'g')) END, ''), '')
    FROM regexp_split_to_table(coalesce(p, ''), '') AS c;
$fn$;

REVOKE ALL ON FUNCTION public.url_encode(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.url_encode(text) TO service_role;

CREATE OR REPLACE FUNCTION public.tickets_dev_search_enqueue(p_surface text, p_limit int DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_key text; v_cap int; v_n int := 0; rr record; v_req bigint;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  v_cap := greatest(1, least(300, coalesce(p_limit, 100)));

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'tickets.dev';
  IF v_key IS NULL THEN RETURN jsonb_build_object('error', 'vault secret tickets.dev missing'); END IF;

  DROP TABLE IF EXISTS _tdq;
  IF p_surface = 's4kcs_orders' THEN
    CREATE TEMP TABLE _tdq ON COMMIT DROP AS
    SELECT o.s4k_order_id AS row_key, o.event_name AS q, o.event_date AS day
      FROM public.s4kcs_orders o
     WHERE o.tevo_event_id IS NULL AND o.event_date >= current_date
       AND coalesce(o.event_name, '') !~* 'parking|shuttle'
       AND o.event_name !~* '\(Date TBD\)|If Necessary|TBD vs TBD'
       AND nullif(trim(o.event_name), '') IS NOT NULL
     ORDER BY o.event_date LIMIT v_cap * 3;
  ELSIF p_surface = 'sg_events_canonical' THEN
    CREATE TEMP TABLE _tdq ON COMMIT DROP AS
    SELECT c.sg_event_id::text AS row_key, c.sg_event_name AS q,
           coalesce(nullif(left(c.raw_event_jsonb->>'datetime_local', 10), '')::date, c.sg_event_date) AS day
      FROM public.sg_events_canonical c
     WHERE c.tevo_event_id IS NULL AND c.sg_event_date >= current_date
       AND coalesce(c.sg_category, '') NOT IN ('Parking', 'parking')
       AND coalesce(c.sg_event_name, '') !~* 'parking|shuttle'
       AND c.sg_event_name !~* '\(Date TBD\)|If Necessary|TBD vs TBD'
     ORDER BY c.sg_event_date LIMIT v_cap * 3;
  ELSE
    RAISE EXCEPTION 'tickets_dev_search: unsupported surface % (s4kcs_orders | sg_events_canonical)', p_surface;
  END IF;

  -- one probe per (surface, row_key); never re-asked while a verdict is under a week old.
  -- The askable test is applied BEFORE the LIMIT, per the starvation lesson of mig 20260915011000.
  FOR rr IN
    SELECT t.row_key, t.q, t.day FROM _tdq t
     WHERE NOT EXISTS (SELECT 1 FROM public.tickets_dev_row_probe p
                        WHERE p.surface = p_surface AND p.row_key = t.row_key
                          AND (p.outcome IS NULL OR p.settled_at > now() - interval '7 days'))
     LIMIT v_cap
  LOOP
    v_req := net.http_get(
               url := 'https://api.tickets.dev/v1/events?pageSize=100&query=' || public.url_encode(rr.q),
               headers := jsonb_build_object('x-api-key', v_key),
               timeout_milliseconds := 8000);
    INSERT INTO public.tickets_dev_row_probe (surface, row_key, query_text, match_day, req_id, requested_at, outcome, settled_at)
    VALUES (p_surface, rr.row_key, rr.q, rr.day, v_req, now(), NULL, NULL)
    ON CONFLICT (surface, row_key) DO UPDATE
      SET query_text = excluded.query_text, match_day = excluded.match_day,
          req_id = excluded.req_id, requested_at = now(), outcome = NULL, settled_at = NULL, tdev_id = NULL;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('surface', p_surface, 'enqueued', v_n);
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_search_enqueue(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_search_enqueue(text, int) TO service_role;

-- Drain settled name-searches. Note there is no min(jsonb), so candidates are collected into an
-- array rather than aggregated.
CREATE OR REPLACE FUNCTION public.tickets_dev_search_harvest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE rr record; v_tot int; v_cands int; v_arr jsonb[]; v_pick jsonb;
        v_m int := 0; v_none int := 0; v_amb int := 0; v_broad int := 0; v_err int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '150000', true);

  FOR rr IN
    SELECT p.surface, p.row_key, p.match_day, p.req_id, r.status_code, r.content
      FROM public.tickets_dev_row_probe p
      JOIN net._http_response r ON r.id = p.req_id
     WHERE p.outcome IS NULL
  LOOP
    IF rr.status_code <> 200 THEN
      UPDATE public.tickets_dev_row_probe SET outcome = 'http_' || coalesce(rr.status_code::text, '?'),
             settled_at = now(), req_id = NULL
       WHERE surface = rr.surface AND row_key = rr.row_key;
      v_err := v_err + 1; CONTINUE;
    END IF;

    v_tot := coalesce((rr.content::jsonb->>'total')::int, 0);

    -- the API does no filtering, so the whole match happens here: same local day, and not a
    -- parking/shuttle variant of the same night (those share the date and the name stem)
    SELECT array_agg(e) INTO v_arr
      FROM jsonb_array_elements(rr.content::jsonb->'events') e
     WHERE left(e->>'eventDateLocal', 10) = rr.match_day::text
       AND coalesce(e->>'name', '') !~* 'parking|shuttle|tailgate';
    v_cands := coalesce(array_length(v_arr, 1), 0);
    v_pick  := v_arr[1];

    IF v_cands = 1 THEN
      INSERT INTO public.tickets_dev_event (tdev_id, name, event_utc, event_local, local_date,
             venue_name, venue_city, venue_state, venue_country, venue_tz, performers, sources, tdev_updated_at, fetched_at)
      VALUES (v_pick->>'id', v_pick->>'name',
              nullif(v_pick->>'eventDateUtc','')::timestamptz, v_pick->>'eventDateLocal',
              nullif(left(v_pick->>'eventDateLocal', 10), '')::date,
              v_pick->'venue'->>'name', v_pick->'venue'->>'city', v_pick->'venue'->>'state',
              v_pick->'venue'->>'country', v_pick->'venue'->>'timezone',
              v_pick->'performers', v_pick->'sources',
              nullif(v_pick->>'updatedAt','')::timestamptz, now())
      ON CONFLICT (tdev_id) DO UPDATE SET
        name = excluded.name, event_utc = excluded.event_utc, event_local = excluded.event_local,
        local_date = excluded.local_date, venue_name = excluded.venue_name, venue_city = excluded.venue_city,
        venue_state = excluded.venue_state, venue_country = excluded.venue_country, venue_tz = excluded.venue_tz,
        performers = excluded.performers, sources = excluded.sources, fetched_at = now();

      INSERT INTO public.tickets_dev_source_id (marketplace, source_event_id, tdev_id, url)
      SELECT s->>'marketplace', s->>'eventId', v_pick->>'id', s->>'url'
        FROM jsonb_array_elements(coalesce(v_pick->'sources', '[]'::jsonb)) s
       WHERE nullif(s->>'marketplace','') IS NOT NULL AND nullif(s->>'eventId','') IS NOT NULL
      ON CONFLICT (marketplace, source_event_id) DO UPDATE SET tdev_id = excluded.tdev_id, url = excluded.url;

      UPDATE public.tickets_dev_row_probe SET outcome = 'matched', tdev_id = v_pick->>'id',
             candidates = 1, settled_at = now(), req_id = NULL
       WHERE surface = rr.surface AND row_key = rr.row_key;
      v_m := v_m + 1;
    ELSIF v_cands > 1 THEN
      UPDATE public.tickets_dev_row_probe SET outcome = 'ambiguous', candidates = v_cands, settled_at = now(), req_id = NULL
       WHERE surface = rr.surface AND row_key = rr.row_key;
      v_amb := v_amb + 1;
    ELSIF v_tot > 100 THEN
      -- nothing on the day in page 1, and the name is a long run we deliberately did not page
      UPDATE public.tickets_dev_row_probe SET outcome = 'too_broad', candidates = 0, settled_at = now(), req_id = NULL
       WHERE surface = rr.surface AND row_key = rr.row_key;
      v_broad := v_broad + 1;
    ELSE
      UPDATE public.tickets_dev_row_probe SET outcome = 'no_same_day', candidates = 0, settled_at = now(), req_id = NULL
       WHERE surface = rr.surface AND row_key = rr.row_key;
      v_none := v_none + 1;
    END IF;
  END LOOP;

  UPDATE public.tickets_dev_row_probe SET outcome = 'no_response', settled_at = now(), req_id = NULL
   WHERE outcome IS NULL AND requested_at < now() - interval '6 hours';

  RETURN jsonb_build_object('matched', v_m, 'ambiguous', v_amb, 'no_same_day', v_none,
                            'too_broad', v_broad, 'errors', v_err);
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_search_harvest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_search_harvest() TO service_role;

-- Turn a matched catalogue cluster into a mapping. Two routes, strongest first:
--   1. IDENTITY — any marketplace id in the cluster that our hub (or the GoTickets catalogue)
--      already resolves to a TEvo event. No inference at all.
--   2. RECOVERED VENUE — hand the catalogue's venue/city/state and the row's own local day to
--      event_mapper_resolve. This is the whole point for CRM rows.
--
-- Route 2 still goes through the normal resolver, so every guard it carries (parking, TBD,
-- same-local-day, unique-or-decline, liveness tie-break) applies unchanged. Nothing here
-- bypasses the mapper; it only supplies the input the source failed to provide.
--
-- Fill-only: writes through the surface's own update_sql, which is `WHERE tevo_event_id IS NULL`.
CREATE OR REPLACE FUNCTION public.tickets_dev_apply_hints(p_surface text, p_apply boolean DEFAULT false)
RETURNS TABLE(out_row_key text, out_tevo bigint, out_method text, out_score numeric, out_venue text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_upd text; rr record; v_n int; v_tevo bigint; v_meth text; v_score numeric;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '160000', true);

  SELECT s.update_sql INTO v_upd FROM public.event_mapper_surface_sql(p_surface) s;

  DROP TABLE IF EXISTS _tdh;
  CREATE TEMP TABLE _tdh (row_key text, tevo bigint, method text, score numeric, venue text);

  FOR rr IN
    SELECT p.row_key, p.match_day, t.venue_name, t.venue_city, t.venue_state, t.name AS td_name,
           CASE WHEN p.surface = 's4kcs_orders'
                THEN (SELECT lower(o.source) FROM public.s4kcs_orders o WHERE o.s4k_order_id = p.row_key)
                ELSE 'seatgeek' END AS src,
           CASE WHEN p.surface = 's4kcs_orders'
                THEN (SELECT o.event_name FROM public.s4kcs_orders o WHERE o.s4k_order_id = p.row_key)
                ELSE (SELECT c.sg_event_name FROM public.sg_events_canonical c WHERE c.sg_event_id = p.row_key::bigint) END AS ev_name,
           (SELECT coalesce(
              (SELECT g.tevo_event_id FROM public.tickets_dev_source_id s
                 JOIN public.gotickets_event g ON g.gt_event_id::text = s.source_event_id
                WHERE s.tdev_id = p.tdev_id AND s.marketplace = 'gotickets' AND g.tevo_event_id IS NOT NULL LIMIT 1),
              (SELECT a.tevo_event_id FROM public.tickets_dev_source_id s
                 JOIN public.aq_event_map a ON (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
                                            OR (s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
                                            OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
                                            OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)
                WHERE s.tdev_id = p.tdev_id AND a.tevo_event_id IS NOT NULL LIMIT 1))) AS hub_tevo
      FROM public.tickets_dev_row_probe p
      JOIN public.tickets_dev_event t ON t.tdev_id = p.tdev_id
     WHERE p.surface = p_surface AND p.outcome = 'matched'
  LOOP
    v_tevo := NULL; v_meth := NULL; v_score := NULL;

    IF rr.hub_tevo IS NOT NULL THEN
      v_tevo := rr.hub_tevo; v_meth := 'catalog_identity'; v_score := 0.96;
    ELSE
      SELECT res.tevo_event_id, 'catalog_venue', res.score INTO v_tevo, v_meth, v_score
        FROM public.event_mapper_resolve(rr.src, NULL, rr.ev_name, NULL, rr.venue_name,
               rr.venue_city, rr.venue_state, rr.match_day, NULL, true, 0.5, NULL) res;
    END IF;

    IF v_tevo IS NOT NULL THEN
      INSERT INTO _tdh VALUES (rr.row_key, v_tevo, v_meth, v_score, rr.venue_name);
      IF p_apply THEN
        EXECUTE v_upd USING rr.row_key, v_tevo, v_meth, v_score;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n > 0 THEN
          PERFORM public.event_mapper_apply(rr.src, NULL, v_tevo, rr.ev_name, rr.venue_name,
                                            rr.match_day, v_score, NULL, NULL);
        END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN QUERY SELECT h.row_key, h.tevo, h.method, h.score, h.venue FROM _tdh h;
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_apply_hints(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_apply_hints(text, boolean) TO service_role;

COMMENT ON FUNCTION public.tickets_dev_apply_hints(text, boolean) IS
  'Maps rows whose catalogue cluster was matched by name-search: hub identity on the cluster ids first, else the recovered venue through event_mapper_resolve. Fill-only, dry run by default (mig 20260915020000).';

-- the name-search loop joins the existing single maintenance job rather than adding another
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
      -- name-search route for rows that carry no marketplace id at all
      PERFORM public.tickets_dev_search_harvest();
      PERFORM public.tickets_dev_apply_hints('s4kcs_orders', true);
      PERFORM public.tickets_dev_apply_hints('sg_events_canonical', true);
      PERFORM public.tickets_dev_search_enqueue('s4kcs_orders', 60);
      PERFORM public.tickets_dev_search_enqueue('sg_events_canonical', 60);
      PERFORM public.venue_xref_derive_by_id(true);
      PERFORM public.performer_xref_derive_from_events(true);
    END $b$; COMMIT;$body$);
END $cron$;
