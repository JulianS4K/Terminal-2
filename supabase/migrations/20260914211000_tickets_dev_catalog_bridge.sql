-- Tickets.dev cross-source catalogue bridge — identity between the NON-EVO marketplaces.
--
-- WHY. Sampling every unmapped surface (2026-09-14) showed the residual backlog is not one
-- problem but three, and only the last is a mapper weakness:
--   * unmappable by construction — parking, past events, "TBD vs TBD" placeholders;
--   * TEvo-absent — the event is real and sells on three or four marketplaces, but the TEvo
--     mirror does not carry it. Broadway is the clearest case: against an eight-shows-a-week
--     run the mirror holds 6 future Richard Rodgers dates, 3 Walter Kerr, 9 Lyric. Hadestown
--     2026-09-17, Hamilton 2026-10-09 and 2026-11-07, Harry Potter 2026-10-10 all have ZERO
--     TEvo candidates at that venue on that day;
--   * genuinely winnable — a TEvo event exists at that venue on that day and we decline anyway.
-- Nothing in our own data separates the second from the third, so a declined row is retried at
-- every cron tick forever. tickets.dev's /v1/events answers precisely that question: it is a
-- cross-marketplace catalogue keyed by each marketplace's OWN event id. It is free, never
-- billed and not rate limited (unlike /v1/capture, which this migration never calls).
--
-- WHAT IT BUYS US — measured against prod, not assumed:
--   * agreement. 3 of 3 control rows we had already mapped independently came back carrying a
--     GoTickets id that resolves through gotickets_event to the EXACT TEvo event we had picked
--     (vivid 5967243->3091874, 6493301->3286205, 7205172->3425322). It agrees with us where we
--     are confident, which is what makes it safe to lean on where we are not.
--   * reach. 10 of 11 Vivid rows the resolver had declined came back positively identified,
--     9 of them carrying a GoTickets sibling id.
--   * closure, later not now. None of those 9 siblings is mapped either, so the bridge does
--     NOT close those particular rows today. What it does is make the cluster explicit: the
--     moment ANY member of it earns a TEvo id, tickets_dev_hub_backfill() hands that id to
--     every other marketplace in the cluster and rule 0 identity picks them all up for free.
--   * clean geography. The catalogue returns venue/city/state already split, plus an IANA
--     timezone — the missing piece for Vivid's local-wall-time-labelled-+00 column (§3
--     landmine) and the reason rule 2 is still switched off for that surface.
--
-- WHAT IT DOES NOT BUY US, so nobody re-derives it:
--   * seatgeek and tickpick are NOT in the catalogue yet. Both answer 501 source_not_indexed,
--     explicitly non-retryable. The bridge cannot touch the SG or TickPick backlog today; the
--     probe table remembers that verdict so we do not ask again until the rollout lands.
--   * ?query= is a paginated SEARCH, not a matcher: dateFrom/dateTo are accepted and silently
--     ignored (query=Hadestown returns 872 rows with or without them). We therefore only ever
--     look up by a source id we already hold — never by name.
--   * the catalogue carries NO TEvo id. It complements aq_event_map; it never replaces it.
--
-- RULE 2 (upstream read-only). Every call here is net.http_get against the /v1/events read
-- endpoint. There is no POST path in this file and none may be added — /v1/capture costs
-- credits, mutates nothing of ours, and is not needed for mapping. The key lives in the vault
-- as secret 'tickets.dev' and is read inline at call time so it is never stored in a table,
-- a migration, or a log line.

-- ---------------------------------------------------------------- catalogue cache
CREATE TABLE IF NOT EXISTS public.tickets_dev_event (
  tdev_id         text PRIMARY KEY,           -- the catalogue's own ULID
  name            text,
  event_utc       timestamptz,                -- eventDateUtc: a TRUE instant, unlike vivid_orders.event_date
  event_local     text,                       -- eventDateLocal verbatim, offset included
  local_date      date,                       -- left(eventDateLocal, 10) — what rules 1/2 compare on
  venue_name      text,
  venue_city      text,
  venue_state     text,
  venue_country   text,
  venue_tz        text,                       -- IANA, e.g. America/New_York
  performers      jsonb,
  sources         jsonb,
  tdev_updated_at timestamptz,
  fetched_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tickets_dev_event_venue_day_idx
  ON public.tickets_dev_event ((lower(trim(venue_name))), local_date);

-- one row per (marketplace, that marketplace's event id) — the actual bridge
CREATE TABLE IF NOT EXISTS public.tickets_dev_source_id (
  marketplace     text NOT NULL,              -- ticketmaster | vividseats | stubhub | gotickets | paciolan
  source_event_id text NOT NULL,              -- kept as text: ticketmaster ids are alphanumeric
  tdev_id         text NOT NULL REFERENCES public.tickets_dev_event(tdev_id) ON DELETE CASCADE,
  url             text,
  PRIMARY KEY (marketplace, source_event_id)
);
CREATE INDEX IF NOT EXISTS tickets_dev_source_id_tdev_idx ON public.tickets_dev_source_id (tdev_id);

-- what we have asked, and what came back. Doubles as the do-not-ask-twice memory: without it
-- a permanently unknown id would be re-probed at every tick forever.
CREATE TABLE IF NOT EXISTS public.tickets_dev_probe (
  marketplace     text NOT NULL,
  source_event_id text NOT NULL,
  req_id          bigint,                     -- net.http_get request id, NULL once settled
  requested_at    timestamptz NOT NULL DEFAULT now(),
  outcome         text,                       -- NULL = in flight; found | not_found | source_not_indexed | http_<code> | no_response
  settled_at      timestamptz,
  PRIMARY KEY (marketplace, source_event_id)
);
CREATE INDEX IF NOT EXISTS tickets_dev_probe_inflight_idx
  ON public.tickets_dev_probe (req_id) WHERE outcome IS NULL;

COMMENT ON TABLE public.tickets_dev_event IS
  'tickets.dev /v1/events catalogue cache. Cross-marketplace identity for the non-EVO sources; carries no TEvo id (mig 20260914211000).';
COMMENT ON TABLE public.tickets_dev_source_id IS
  'marketplace event id -> tickets.dev cluster. The bridge itself: two sources in the same cluster are the same event.';
COMMENT ON TABLE public.tickets_dev_probe IS
  'Probe ledger. outcome=source_not_indexed means the marketplace is not in the catalogue yet (seatgeek, tickpick as of 2026-09-14) — never retried.';

-- ---------------------------------------------------------------- probe (GET only)
-- Fires one /v1/events lookup per (marketplace, id) we do not already know or have already
-- asked about. Returns how many requests were queued. net.http_get is the ONLY verb used.
CREATE OR REPLACE FUNCTION public.tickets_dev_probe_enqueue(p_marketplace text, p_ids text[])
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_key text; v_n int := 0; v_id text; v_req bigint;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_marketplace IS NULL OR p_ids IS NULL THEN RETURN 0; END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'tickets.dev';
  IF v_key IS NULL THEN
    RAISE NOTICE 'tickets_dev: vault secret "tickets.dev" missing — nothing enqueued';
    RETURN 0;
  END IF;

  FOR v_id IN
    SELECT DISTINCT x FROM unnest(p_ids) x
     WHERE x IS NOT NULL AND x <> ''
       -- never ask about an id the catalogue already resolved …
       AND NOT EXISTS (SELECT 1 FROM public.tickets_dev_source_id s
                        WHERE s.marketplace = p_marketplace AND s.source_event_id = x)
       -- … nor one we have a standing verdict on. A settled 'not_found' is re-askable after a
       -- week (catalogues backfill); 'source_not_indexed' is declared non-retryable upstream,
       -- so it is never asked again until an operator clears the row.
       AND NOT EXISTS (SELECT 1 FROM public.tickets_dev_probe p
                        WHERE p.marketplace = p_marketplace AND p.source_event_id = x
                          AND (p.outcome IS NULL
                               OR p.outcome = 'source_not_indexed'
                               OR p.settled_at > now() - interval '7 days'))
  LOOP
    v_req := net.http_get(
               url := 'https://api.tickets.dev/v1/events?source=' || p_marketplace
                      || '&eventId=' || v_id,
               headers := jsonb_build_object('x-api-key', v_key),
               timeout_milliseconds := 8000);
    INSERT INTO public.tickets_dev_probe (marketplace, source_event_id, req_id, requested_at, outcome, settled_at)
    VALUES (p_marketplace, v_id, v_req, now(), NULL, NULL)
    ON CONFLICT (marketplace, source_event_id)
      DO UPDATE SET req_id = excluded.req_id, requested_at = now(), outcome = NULL, settled_at = NULL;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_probe_enqueue(text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_probe_enqueue(text, text[]) TO service_role;

-- ---------------------------------------------------------------- harvest
-- Drains settled pg_net responses into the catalogue cache. pg_net keeps a response for 6 h,
-- so this must run well inside that window — the cron below is every 10 minutes.
CREATE OR REPLACE FUNCTION public.tickets_dev_harvest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE rr record; v_ev jsonb; v_found int := 0; v_none int := 0; v_err int := 0; v_ids int := 0; v_code text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  FOR rr IN
    SELECT p.marketplace, p.source_event_id, p.req_id, r.status_code, r.content
      FROM public.tickets_dev_probe p
      JOIN net._http_response r ON r.id = p.req_id
     WHERE p.outcome IS NULL
  LOOP
    IF rr.status_code = 200 THEN
      v_ev := (rr.content::jsonb)->'events'->0;
      IF v_ev IS NULL OR v_ev = 'null'::jsonb THEN
        UPDATE public.tickets_dev_probe SET outcome = 'not_found', settled_at = now(), req_id = NULL
         WHERE marketplace = rr.marketplace AND source_event_id = rr.source_event_id;
        v_none := v_none + 1;
        CONTINUE;
      END IF;

      INSERT INTO public.tickets_dev_event (tdev_id, name, event_utc, event_local, local_date,
                                            venue_name, venue_city, venue_state, venue_country, venue_tz,
                                            performers, sources, tdev_updated_at, fetched_at)
      VALUES (v_ev->>'id', v_ev->>'name',
              nullif(v_ev->>'eventDateUtc','')::timestamptz,
              v_ev->>'eventDateLocal',
              nullif(left(v_ev->>'eventDateLocal', 10), '')::date,
              v_ev->'venue'->>'name', v_ev->'venue'->>'city', v_ev->'venue'->>'state',
              v_ev->'venue'->>'country', v_ev->'venue'->>'timezone',
              v_ev->'performers', v_ev->'sources',
              nullif(v_ev->>'updatedAt','')::timestamptz, now())
      ON CONFLICT (tdev_id) DO UPDATE SET
        name = excluded.name, event_utc = excluded.event_utc, event_local = excluded.event_local,
        local_date = excluded.local_date, venue_name = excluded.venue_name, venue_city = excluded.venue_city,
        venue_state = excluded.venue_state, venue_country = excluded.venue_country, venue_tz = excluded.venue_tz,
        performers = excluded.performers, sources = excluded.sources,
        tdev_updated_at = excluded.tdev_updated_at, fetched_at = now();

      INSERT INTO public.tickets_dev_source_id (marketplace, source_event_id, tdev_id, url)
      SELECT s->>'marketplace', s->>'eventId', v_ev->>'id', s->>'url'
        FROM jsonb_array_elements(coalesce(v_ev->'sources', '[]'::jsonb)) s
       WHERE nullif(s->>'marketplace','') IS NOT NULL AND nullif(s->>'eventId','') IS NOT NULL
      ON CONFLICT (marketplace, source_event_id) DO UPDATE SET tdev_id = excluded.tdev_id, url = excluded.url;
      GET DIAGNOSTICS v_ids = ROW_COUNT;

      UPDATE public.tickets_dev_probe SET outcome = 'found', settled_at = now(), req_id = NULL
       WHERE marketplace = rr.marketplace AND source_event_id = rr.source_event_id;
      v_found := v_found + 1;
    ELSE
      -- 501 source_not_indexed is the documented "this marketplace is not in the catalogue
      -- yet" answer and is flagged non-retryable, so it is recorded as a permanent verdict.
      BEGIN v_code := (rr.content::jsonb)->'error'->>'code'; EXCEPTION WHEN others THEN v_code := NULL; END;
      UPDATE public.tickets_dev_probe
         SET outcome = coalesce(nullif(v_code,''), 'http_' || coalesce(rr.status_code::text,'?')),
             settled_at = now(), req_id = NULL
       WHERE marketplace = rr.marketplace AND source_event_id = rr.source_event_id;
      v_err := v_err + 1;
    END IF;
  END LOOP;

  -- a request whose response pg_net has already expired is never coming back; release it so
  -- the id becomes re-askable rather than sitting "in flight" forever.
  UPDATE public.tickets_dev_probe SET outcome = 'no_response', settled_at = now(), req_id = NULL
   WHERE outcome IS NULL AND requested_at < now() - interval '6 hours';

  RETURN jsonb_build_object('found', v_found, 'not_found', v_none, 'errors', v_err);
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_harvest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_harvest() TO service_role;

-- ---------------------------------------------------------------- hub backfill
-- The point of the whole exercise. A tickets.dev cluster says "these marketplace ids are the
-- same event". If exactly ONE of them already resolves to a TEvo event in our own data, that
-- id is handed to every sibling by writing it onto the hub row — and rule 0 identity, which
-- already reads aq_event_map.{vivid,gotickets,sh,tm}_event_id, then maps all of them on the
-- next event_mapper_run with no resolver change at all. Unique-or-decline, as everywhere else:
-- a cluster whose members disagree about which TEvo event they are is left alone.
--
-- Landmine: aq_event_map.tm_event_id is BIGINT while roughly half of Ticketmaster's ids are
-- alphanumeric ('1000639186663DE4'). Only all-digit ids can be carried; the rest stay in
-- tickets_dev_source_id, which is text, and are simply not bridged through the hub.
CREATE OR REPLACE FUNCTION public.tickets_dev_hub_backfill()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_rows int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  CREATE TEMP TABLE _td_known ON COMMIT DROP AS
  WITH cl AS (
    SELECT s.tdev_id,
           max(CASE WHEN s.marketplace = 'vividseats'   AND s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END) AS vivid_id,
           max(CASE WHEN s.marketplace = 'gotickets'    AND s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END) AS gt_id,
           max(CASE WHEN s.marketplace = 'stubhub'      AND s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END) AS sh_id,
           max(CASE WHEN s.marketplace = 'ticketmaster' AND s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END) AS tm_id
      FROM public.tickets_dev_source_id s
     GROUP BY s.tdev_id)
  SELECT c.tdev_id, c.vivid_id, c.gt_id, c.sh_id, c.tm_id,
         (SELECT array_agg(DISTINCT z.t) FROM (
            SELECT a.tevo_event_id AS t FROM public.aq_event_map a WHERE a.vivid_event_id = c.vivid_id AND a.tevo_event_id IS NOT NULL
            UNION SELECT a.tevo_event_id FROM public.aq_event_map a WHERE a.gotickets_event_id = c.gt_id AND a.tevo_event_id IS NOT NULL
            UNION SELECT g.tevo_event_id FROM public.gotickets_event g WHERE g.gt_event_id = c.gt_id AND g.tevo_event_id IS NOT NULL
            UNION SELECT a.tevo_event_id FROM public.aq_event_map a WHERE a.sh_event_id = c.sh_id AND a.tevo_event_id IS NOT NULL
            UNION SELECT a.tevo_event_id FROM public.aq_event_map a WHERE a.tm_event_id = c.tm_id AND a.tevo_event_id IS NOT NULL) z) AS tevos
    FROM cl c;

  DELETE FROM _td_known WHERE tevos IS NULL OR array_length(tevos, 1) <> 1;

  -- Each id is written only if no OTHER hub row already claims it for a different TEvo event:
  -- the catalogue is a second opinion, never an override of something we already believe.
  UPDATE public.aq_event_map a SET
    vivid_event_id = coalesce(a.vivid_event_id, CASE WHEN k.vivid_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.aq_event_map o WHERE o.vivid_event_id = k.vivid_id AND o.tevo_event_id IS DISTINCT FROM k.tevos[1]) THEN k.vivid_id END),
    gotickets_event_id = coalesce(a.gotickets_event_id, CASE WHEN k.gt_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.aq_event_map o WHERE o.gotickets_event_id = k.gt_id AND o.tevo_event_id IS DISTINCT FROM k.tevos[1]) THEN k.gt_id END),
    sh_event_id = coalesce(a.sh_event_id, CASE WHEN k.sh_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.aq_event_map o WHERE o.sh_event_id = k.sh_id AND o.tevo_event_id IS DISTINCT FROM k.tevos[1]) THEN k.sh_id END),
    tm_event_id = coalesce(a.tm_event_id, CASE WHEN k.tm_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.aq_event_map o WHERE o.tm_event_id = k.tm_id AND o.tevo_event_id IS DISTINCT FROM k.tevos[1]) THEN k.tm_id END)
  FROM _td_known k
  WHERE a.tevo_event_id = k.tevos[1]
    AND ((a.vivid_event_id     IS NULL AND k.vivid_id IS NOT NULL)
      OR (a.gotickets_event_id IS NULL AND k.gt_id    IS NOT NULL)
      OR (a.sh_event_id        IS NULL AND k.sh_id    IS NOT NULL)
      OR (a.tm_event_id        IS NULL AND k.tm_id    IS NOT NULL));
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object('clusters_resolved', (SELECT count(*) FROM _td_known), 'hub_rows_enriched', v_rows);
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_hub_backfill() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_hub_backfill() TO service_role;

-- ---------------------------------------------------------------- driver
-- harvest what came back -> push new identities into the hub -> ask about the next batch.
-- Only sources the catalogue actually indexes are probed: seatgeek and tickpick would answer
-- 501 and are deliberately not enqueued at all.
CREATE OR REPLACE FUNCTION public.tickets_dev_run(p_limit int DEFAULT 120)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_h jsonb; v_b jsonb; v_v int := 0; v_g int := 0; v_cap int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  v_cap := greatest(1, least(500, coalesce(p_limit, 120)));

  v_h := public.tickets_dev_harvest();
  v_b := public.tickets_dev_hub_backfill();

  -- Vivid: still unmapped, still ahead of us, not a parking pass. Oldest-first, because the
  -- newest rows are the ones event_mapper_run already sees every tick — this is the tail.
  SELECT public.tickets_dev_probe_enqueue('vividseats', array_agg(id)) INTO v_v FROM (
    SELECT DISTINCT raw->>'productionId' AS id, min(event_date) AS d
      FROM public.vivid_orders
     WHERE tevo_event_id IS NULL AND raw->>'productionId' ~ '^[0-9]+$'
       AND event_date > now() AND event_name !~* 'parking|shuttle'
     GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;

  -- GoTickets purchases: the other direction. A GoTickets row we cannot map may have a
  -- StubHub/TM/Vivid sibling that we CAN, and the cluster carries the answer back.
  SELECT public.tickets_dev_probe_enqueue('gotickets', array_agg(id)) INTO v_g FROM (
    SELECT DISTINCT gt_event_id::text AS id, min(event_time_local) AS d
      FROM public.gotickets_purchases
     WHERE tevo_event_id IS NULL AND gt_event_id IS NOT NULL
       AND event_time_local > now() AND coalesce(event_name,'') !~* 'parking|shuttle'
     GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;

  RETURN jsonb_build_object('harvest', v_h, 'backfill', v_b,
                            'enqueued', jsonb_build_object('vividseats', coalesce(v_v,0), 'gotickets', coalesce(v_g,0)));
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_run(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_run(int) TO service_role;

COMMENT ON FUNCTION public.tickets_dev_run(int) IS
  'tickets.dev bridge tick: harvest settled probes, hand recovered identities to aq_event_map, enqueue the next batch. GET-only (RULE 2).';

-- ---------------------------------------------------------------- the decline explainer
-- Rows the catalogue positively identified but for which NO marketplace in the cluster resolves
-- to a TEvo event. These are the "TEvo-absent" bucket: real events, sold on three or four
-- marketplaces, that the mirror simply does not carry. They are not mapper failures and no
-- amount of resolver strengthening will close them — this view exists so they stop being
-- re-litigated at every tick and can be reported as a closed, explained set instead.
CREATE OR REPLACE VIEW public.v_tickets_dev_no_tevo AS
SELECT e.tdev_id, e.name, e.local_date, e.venue_name, e.venue_city, e.venue_state,
       (SELECT count(*) FROM public.tickets_dev_source_id s WHERE s.tdev_id = e.tdev_id) AS marketplaces,
       (SELECT string_agg(s.marketplace, ',' ORDER BY s.marketplace)
          FROM public.tickets_dev_source_id s WHERE s.tdev_id = e.tdev_id) AS sold_on
  FROM public.tickets_dev_event e
 WHERE e.local_date >= current_date
   AND NOT EXISTS (
     SELECT 1 FROM public.tickets_dev_source_id s
      WHERE s.tdev_id = e.tdev_id
        AND (EXISTS (SELECT 1 FROM public.aq_event_map a
                      WHERE a.tevo_event_id IS NOT NULL
                        AND ((s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
                          OR (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
                          OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
                          OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)))
          OR EXISTS (SELECT 1 FROM public.gotickets_event g
                      WHERE s.marketplace = 'gotickets' AND g.gt_event_id::text = s.source_event_id
                        AND g.tevo_event_id IS NOT NULL)));

REVOKE ALL ON public.v_tickets_dev_no_tevo FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_tickets_dev_no_tevo TO service_role;

COMMENT ON VIEW public.v_tickets_dev_no_tevo IS
  'Catalogue-confirmed events with no TEvo counterpart on ANY marketplace we hold. Declines that are data gaps, not mapper gaps (mig 20260914211000).';

-- ---------------------------------------------------------------- cron
-- Ten-minute tick. pg_net holds a response for 6 h, so harvest runs far inside the window even
-- if the shared outbound queue is backed up (it was ~270 deep and draining in ~3 min batches
-- when this was measured on 2026-09-14). Wrapped like every other job here: policy gate first,
-- bounded statement_timeout, one transaction.
DO $cron$
BEGIN
  PERFORM cron.unschedule('tickets_dev_bridge_10min')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tickets_dev_bridge_10min');
  PERFORM cron.schedule('tickets_dev_bridge_10min', '7,17,27,37,47,57 * * * *', $body$
    BEGIN; SET LOCAL statement_timeout = '170s';
    DO $b$ BEGIN
      IF NOT public.cron_should_fire('tickets_dev_bridge_10min') THEN RETURN; END IF;
      PERFORM public.tickets_dev_run(120);
    END $b$; COMMIT;$body$);
END $cron$;
