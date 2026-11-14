-- Migration 20261027173000 · level:ops · lane:A1 (data plane — cross-source ID resolution) · writes:tickets_dev_requests_left()(new),tickets_dev_probe_enqueue()(replace),tickets_dev_search_enqueue()(replace) · reads:tickets_dev_probe,tickets_dev_row_probe,s4kcs_orders,sg_events_canonical,vault.decrypted_secrets · pre:20260917020000 (tickets.dev resolve clusters)
--
-- ============================================================================
-- tickets.dev: stay inside the free plan's daily quota
--
-- WHAT IS WRONG: api.tickets.dev (free plan) allows 1,000 requests / 2,500 returned events
-- per UTC day, then answers 429 "Daily catalog limit reached … resets at 00:00 UTC". The
-- id-spine cron (659, every 15 min: tickets_dev_run(150) + tickets_dev_fill_outward(150))
-- fires ~11 k GETs a day: last 24 h on 2026-10-27, 9,177 probes rate_limited + 995 searches
-- http_429 vs 928 + 44 answered. ~90 % of the calls are wasted, and the useful ones are
-- whichever happen to land before the quota runs out.
--
-- FIX: tickets_dev_requests_left() = 950 − GETs requested since 00:00 UTC (probe + search
-- ledgers), and 0 once any 429 has come back since 00:00 UTC (the quota is spent — the
-- counter can undercount because a re-probe overwrites requested_at). Both enqueue
-- functions stop when it reaches 0, so the day's ~950 calls go out in priority order and
-- nothing is fired into a closed quota. Bodies otherwise unchanged.
--
-- READ-ONLY UPSTREAM: GET only, as before (CLAUDE.md rule 2).
--
-- ROLLBACK: re-apply both functions from 20260914211000 / 20260917020000;
--           DROP FUNCTION tickets_dev_requests_left().
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.tickets_dev_requests_left()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH day AS (SELECT date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS t0)
  SELECT CASE
           WHEN EXISTS (SELECT 1 FROM public.tickets_dev_probe p, day
                         WHERE p.settled_at >= day.t0 AND p.outcome = 'rate_limited')
             OR EXISTS (SELECT 1 FROM public.tickets_dev_row_probe r, day
                         WHERE r.settled_at >= day.t0 AND r.outcome = 'http_429')
           THEN 0
           ELSE greatest(0, 950
                 - (SELECT count(*) FROM public.tickets_dev_probe p, day WHERE p.requested_at >= day.t0)::int
                 - (SELECT count(*) FROM public.tickets_dev_row_probe r, day WHERE r.requested_at >= day.t0)::int)
         END
$$;
REVOKE ALL ON FUNCTION public.tickets_dev_requests_left() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_requests_left() TO service_role;

CREATE OR REPLACE FUNCTION public.tickets_dev_probe_enqueue(p_marketplace text, p_ids text[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_key text; v_n int := 0; v_id text; v_req bigint; v_left int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_marketplace IS NULL OR p_ids IS NULL THEN RETURN 0; END IF;

  -- free-plan daily quota (mig 20261027173000)
  v_left := public.tickets_dev_requests_left();
  IF v_left <= 0 THEN RETURN 0; END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'tickets.dev';
  IF v_key IS NULL THEN
    RAISE NOTICE 'tickets_dev: vault secret "tickets.dev" missing — nothing enqueued';
    RETURN 0;
  END IF;

  FOR v_id IN
    SELECT DISTINCT x FROM unnest(p_ids) x WHERE public.tickets_dev_askable(p_marketplace, x)
  LOOP
    EXIT WHEN v_n >= v_left;
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
END $function$;

CREATE OR REPLACE FUNCTION public.tickets_dev_search_enqueue(p_surface text, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_key text; v_cap int; v_n int := 0; rr record; v_req bigint; v_left int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  -- free-plan daily quota (mig 20261027173000)
  v_left := public.tickets_dev_requests_left();
  IF v_left <= 0 THEN RETURN jsonb_build_object('surface', p_surface, 'enqueued', 0, 'skipped', 'daily_quota'); END IF;
  v_cap := least(v_left, greatest(1, least(300, coalesce(p_limit, 100))));

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
END $function$;

-- VERIFY: SELECT public.tickets_dev_requests_left();   -- 0 today (quota already spent), ~950 after 00:00 UTC
--         next day: SELECT outcome, count(*) FROM tickets_dev_probe WHERE requested_at >= current_date GROUP BY 1;
