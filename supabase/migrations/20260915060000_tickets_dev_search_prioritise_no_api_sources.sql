-- Order the name-search queue by whether the row has ANY other route to a venue.
--
-- Operator: "for any that don't have api points use the tickets dev matcher".
--
-- The name-search route (mig 20260915020000) already selects on SURFACE, not on source, so every
-- CRM source was eligible from the start. What it did NOT do was decide who goes first. With a
-- 60-row-per-tick cap and an ORDER BY date, the rows probed were simply the soonest — which is
-- exactly the wrong axis when the question is "who has no other way in".
--
-- WHY THESE TIERS. Measured local order-book coverage — what fraction of future CRM orders per
-- source we can already resolve from our own mirrored order data, which is the alternative route
-- an order-number API lookup would provide:
--
--     Vivid Seats  95.8%      GoTickets  66.7%
--     SeatGeek     15.1%      TickPick    6.4%
--     StubHub       0.0%      Gametime    0.0%
--
--   tier 1 — StubHub, Gametime. No *_client.py exists for either and the local book is EMPTY.
--            The catalogue is not the best route for these rows, it is the ONLY route. They are
--            also the two biggest CRM sources: 13,611 future orders between them.
--   tier 2 — SeatGeek, TickPick. A client exists, but the local book is thin (SeatGeek 15.1% is
--            an ingest gap, not an absence of data — see the open question in KANBAN). The
--            catalogue is doing real work here until that gap is closed.
--   tier 3 — Vivid Seats, GoTickets. Nearly everything is already locally resolvable; a catalogue
--            probe is mostly redundant. Still queued, just last.
--
-- ORDERING ONLY. Nothing is excluded, no source is skipped, and a tier-3 row still gets probed
-- once the tiers above it are drained. The 7-day re-ask cooldown is unchanged.
--
-- SECOND STARVATION FIX, same class as mig 20260915011000. The old bodies carried
-- `ORDER BY <date> LIMIT v_cap * 3` on the temp table, BEFORE the askable test. Once the soonest
-- 3*cap rows had all been asked and were inside their cooldown, the loop drained to nothing while
-- thousands of askable rows sat further out — the cron would report success having enqueued zero.
-- That pre-cap is removed: the temp table is now the full eligible set and the only LIMIT is the
-- one that follows the askable filter. Third time this pattern has bitten (Vivid backlog,
-- tickets_dev_fill_outward, and now here): a cap on an ordered list whose head is exhausted is
-- not a cap, it is a wall.
--
-- Body otherwise identical to 20260915020000 — same vault read, same GET-only net.http_get, same
-- upsert. RULE 2 unchanged: /v1/events is a read endpoint and there is no write path here.
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
    SELECT o.s4k_order_id AS row_key, o.event_name AS q, o.event_date AS day,
           CASE lower(o.source) WHEN 'stubhub' THEN 1 WHEN 'gametime' THEN 1
                                WHEN 'seatgeek' THEN 2 WHEN 'tickpick' THEN 2
                                ELSE 3 END AS tier
      FROM public.s4kcs_orders o
     WHERE o.tevo_event_id IS NULL AND o.event_date >= current_date
       AND coalesce(o.event_name, '') !~* 'parking|shuttle'
       AND o.event_name !~* '\(Date TBD\)|If Necessary|TBD vs TBD'
       AND nullif(trim(o.event_name), '') IS NOT NULL;
  ELSIF p_surface = 'sg_events_canonical' THEN
    CREATE TEMP TABLE _tdq ON COMMIT DROP AS
    SELECT c.sg_event_id::text AS row_key, c.sg_event_name AS q,
           coalesce(nullif(left(c.raw_event_jsonb->>'datetime_local', 10), '')::date, c.sg_event_date) AS day,
           2 AS tier
      FROM public.sg_events_canonical c
     WHERE c.tevo_event_id IS NULL AND c.sg_event_date >= current_date
       AND coalesce(c.sg_category, '') NOT IN ('Parking', 'parking')
       AND coalesce(c.sg_event_name, '') !~* 'parking|shuttle'
       AND c.sg_event_name !~* '\(Date TBD\)|If Necessary|TBD vs TBD';
  ELSE
    RAISE EXCEPTION 'tickets_dev_search: unsupported surface % (s4kcs_orders | sg_events_canonical)', p_surface;
  END IF;

  -- the askable test is applied BEFORE the LIMIT, per the starvation lesson of mig 20260915011000
  FOR rr IN
    SELECT t.row_key, t.q, t.day FROM _tdq t
     WHERE NOT EXISTS (SELECT 1 FROM public.tickets_dev_row_probe p
                        WHERE p.surface = p_surface AND p.row_key = t.row_key
                          AND (p.outcome IS NULL OR p.settled_at > now() - interval '7 days'))
     ORDER BY t.tier, t.day
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

COMMENT ON FUNCTION public.tickets_dev_search_enqueue(text, int) IS
  'Queues catalogue name-searches for rows carrying no marketplace id, ordered by whether the source has another route: tier 1 StubHub/Gametime (no client, empty local book), tier 2 SeatGeek/TickPick (thin book), tier 3 Vivid/GoTickets (already locally resolvable). Ordering only, nothing excluded (mig 20260915060000).';
