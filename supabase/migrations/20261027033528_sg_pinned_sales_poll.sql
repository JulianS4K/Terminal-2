-- Migration 20261027033528 · level:ops · lane:A1 (data plane — SeatGeek sales ingest) · writes:pinned_sales_poll_tick()(new),sg_broker_sales_process()(replace),sg_broker_pending_sales_event_fired_idx(new),cron pinned_sales_poll_2min(new) · reads:v_listings_poll_pinned_events,sg_events_canonical,sg_broker_pending,seatgeek_event_xref,aq_event_map,net._http_response · pre:20261024010220 (pinned poll priority)
--
-- ============================================================================
-- SeatGeek sales for EVERY pinned game (training data for the price predictor)
--
-- WHY: sales are only pulled for events in sg_event_priority_state (cron 248), which holds
-- 83 of the 2,858 pinned games that have a SeatGeek id. Every other pinned game — the whole
-- league-pin set, and 37 of 41 Knicks games — has listings history but no sales history.
--
-- WHAT THIS ADDS
--   pinned_sales_poll_tick(p_max)  GETs brokerdata.seatgeek.com/sales for pinned games with
--     'sg' in their sources (same SG id choice as the pinned listings leg). The endpoint
--     returns the event's full sale history, so cadence is about freshness, not coverage:
--       more than 14 days out  every 72 h
--       within 14 days         every 24 h
--       within 48 h            every 6 h
--       game over (> 2 h after start, still in the pinned view until +3 h)  once, first in line
--     "Last pulled" is the newest sales request for that SG id from EITHER poller, so games
--     the priority poller already covers are not pulled twice. Same rate-limit guard as the
--     pinned SG listings leg (skips the tick while ratelimit-remaining < 3). Responses land in
--     sg_broker_pending (scope 'sales') and are stored by the existing sg_broker_sales_process
--     (cron 237). Expected volume ≈ 1,400 GETs/day (~1/min) on top of ~3,600 SG GETs/day today.
--   sg_broker_sales_process(p_limit)  same signature and result. Two changes:
--     1. stores only sales not stored before for that (sg_event_id, sg_sale_id). It used to
--        store EVERY sale on EVERY pull (dup key includes pulled_at): the last 24 h wrote 147 k
--        rows from 695 pulls, nearly all repeats. Every reader already collapses repeats with
--        DISTINCT ON (sg_sale_id) ORDER BY pulled_at DESC, so they see the same sales. Only
--        change in meaning: v_event_data_freshness 'sg_sales' last_seen is now "last new sale
--        stored", not "last pull" (no code reads that view). rows_persisted = new sales.
--     2. tevo_event_id falls back to sg_events_canonical when seatgeek_event_xref has no row
--        (152 pinned games), so those sales are keyed to their TEvo event.
--   sg_broker_pending_sales_event_fired_idx  "last sales pull per SG id" lookup (mirrors the
--     listings index). Built CONCURRENTLY on prod beforehand; no-op there.
--   cron pinned_sales_poll_2min  odd minutes (the pinned listings tick runs on even ones), 6 per tick (first pass of ~2,800 games clears in ~16 h).
--
-- READ-ONLY UPSTREAM: GET only (CLAUDE.md rule 2) — same endpoint and token as cron 248.
--
-- ROLLBACK: SELECT cron.unschedule('pinned_sales_poll_2min'); DROP FUNCTION
--           pinned_sales_poll_tick(integer); re-apply sg_broker_sales_process from its
--           previous migration (insert every sale, xref-only tevo id).
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE INDEX IF NOT EXISTS sg_broker_pending_sales_event_fired_idx
  ON public.sg_broker_pending (sg_event_id, fired_at DESC) WHERE scope = 'sales';

-- ---------------------------------------------------------------------------
-- Poller
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pinned_sales_poll_tick(p_max integer DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r           RECORD;
  v_caller    text;
  v_token     text;
  v_remaining integer;
  v_req       bigint;
  v_n         integer := 0;
  v_post      integer := 0;
BEGIN
  -- inside SECURITY DEFINER current_user is the owner; check the caller's role
  v_caller := CASE WHEN coalesce(current_setting('role', true), 'none') IN ('', 'none')
                   THEN session_user::text ELSE current_setting('role', true) END;
  IF v_caller NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: pinned_sales_poll_tick is service-only (caller %)', v_caller USING ERRCODE = '42501';
  END IF;

  v_token := public.get_app_secret('SEATGEEK_API_TOKEN');
  IF coalesce(v_token, '') = '' OR p_max <= 0 THEN
    RETURN jsonb_build_object('sales', 0, 'skipped', 'no_token_or_zero_max');
  END IF;

  -- same guard as the pinned SG listings leg: back off while the shared token is nearly spent
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
    FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
   WHERE h.headers ? 'ratelimit-remaining' AND h.created > now() - interval '10 seconds'
   ORDER BY h.id DESC LIMIT 1;
  IF coalesce(v_remaining, 99) < 3 THEN
    RETURN jsonb_build_object('sales', 0, 'sg_ratelimit_remaining', v_remaining);
  END IF;

  FOR r IN
    WITH c AS (
      SELECT m.sg_event_id, v.occurs_at, v.hours_to_event AS h, bp.last_fired,
             (v.hours_to_event < -2) AS post_game,
             CASE WHEN v.hours_to_event <= 48      THEN 360
                  WHEN v.hours_to_event <= 24 * 14 THEN 1440
                  ELSE 4320 END AS required_min
        FROM public.v_listings_poll_pinned_events v
        JOIN LATERAL (SELECT min(sc.sg_event_id) AS sg_event_id FROM public.sg_events_canonical sc
                       WHERE sc.tevo_event_id = v.tevo_event_id) m ON m.sg_event_id IS NOT NULL
        LEFT JOIN LATERAL (SELECT max(p.fired_at) AS last_fired FROM public.sg_broker_pending p
                            WHERE p.sg_event_id = m.sg_event_id AND p.scope = 'sales') bp ON true
       WHERE 'sg' = ANY (v.sources))
    SELECT c.sg_event_id, c.post_game
      FROM c
     WHERE CASE WHEN c.post_game
                THEN c.last_fired IS NULL OR c.last_fired < c.occurs_at + interval '2 hours'
                ELSE c.last_fired IS NULL OR c.last_fired < now() - make_interval(mins => c.required_min) END
     ORDER BY c.post_game DESC,
              public._pinned_poll_priority(c.last_fired, c.required_min, greatest(c.h, 0)) DESC NULLS LAST,
              c.h
     LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000) INTO v_req;
    INSERT INTO public.sg_broker_pending (sg_event_id, scope, request_id, fired_at)
    VALUES (r.sg_event_id, 'sales', v_req, now());
    v_n := v_n + 1;
    IF r.post_game THEN v_post := v_post + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object('sales', v_n, 'post_game', v_post, 'sg_ratelimit_remaining', v_remaining);
END $$;

REVOKE ALL ON FUNCTION public.pinned_sales_poll_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pinned_sales_poll_tick(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Processor: store each sale once; TEvo id falls back to sg_events_canonical
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sg_broker_sales_process(p_limit integer DEFAULT 50)
RETURNS TABLE(processed integer, sales_persisted integer)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id,
           h.status_code, h.content::jsonb AS body,
           a.aq_short_event_id,
           coalesce(x.tevo_event_id,
                    (SELECT sc.tevo_event_id FROM public.sg_events_canonical sc
                      WHERE sc.sg_event_id = p.sg_event_id)) AS tevo_event_id
    FROM public.sg_broker_pending p
    JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = p.sg_event_id
    LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = p.sg_event_id
    WHERE p.scope = 'sales' AND p.resolved_at IS NULL
    ORDER BY p.fired_at
    LIMIT p_limit
  LOOP
    v_processed := v_processed + 1;
    v_inserted := NULL;
    IF r.status_code = 200 AND jsonb_typeof(r.body->'sales') = 'array' THEN
      WITH src AS (
        SELECT DISTINCT ON (s->>'id') s
          FROM jsonb_array_elements(r.body->'sales') AS s
         WHERE s->>'id' IS NOT NULL
         ORDER BY s->>'id'),
      ins AS (
        INSERT INTO public.seatgeek_sales_snapshots (
          tevo_event_id, sg_event_id, pulled_at, sg_sale_id,
          broadcast_price, quantity, section, row, stock_type,
          delivery_method, in_hand_date, is_instant, seller_notes,
          sale_at_utc, raw, aq_short_event_id
        )
        SELECT r.tevo_event_id, r.sg_event_id, now(), s->>'id',
          NULLIF(s->>'bp','')::numeric, NULLIF(s->>'q','')::int,
          s->>'s', s->>'r', s->>'st', s->>'dm',
          NULLIF(s->>'ihd','')::date, NULLIF(s->>'idl','')::boolean,
          s->>'pn', NULLIF(s->>'putc','')::timestamptz, s,
          r.aq_short_event_id
        FROM src
        -- already stored from an earlier pull → skip (was re-stored on every pull)
        WHERE NOT EXISTS (SELECT 1 FROM public.seatgeek_sales_snapshots o
                           WHERE o.sg_event_id = r.sg_event_id AND o.sg_sale_id = src.s->>'id')
        ON CONFLICT DO NOTHING
        RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);
    END IF;
    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = CASE
            WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0)
            WHEN r.status_code = 429 THEN -429
            ELSE -1
          END
      WHERE id = r.pending_id;
  END LOOP;

  -- D0 2026-06-06: self-heal orphaned pending rows whose pg_net response was purged.
  UPDATE public.sg_broker_pending p
    SET resolved_at = now(), rows_persisted = -2
  WHERE p.scope = 'sales' AND p.resolved_at IS NULL
    AND p.fired_at < now() - interval '1 hour'
    AND NOT EXISTS (SELECT 1 FROM net._http_response h WHERE h.id = p.request_id);

  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

-- ---------------------------------------------------------------------------
-- Cron: odd minutes (pinned listings runs on even minutes), 6 GETs per tick
-- ---------------------------------------------------------------------------
DO $c$
BEGIN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'pinned_sales_poll_2min';
  PERFORM cron.schedule('pinned_sales_poll_2min', '1-59/2 * * * *',
    $cmd$DO $b$ BEGIN IF NOT public.cron_try_lock('pinned_sales_poll') THEN RETURN; END IF; PERFORM public.pinned_sales_poll_tick(6); END $b$;$cmd$);
END $c$;

-- ============================================================================
-- VERIFY: SELECT count(*), count(*) FILTER (WHERE rows_persisted >= 0) FROM sg_broker_pending
--          WHERE scope = 'sales' AND fired_at > now() - interval '1 hour';
--         SELECT jobname, schedule FROM cron.job WHERE jobname = 'pinned_sales_poll_2min';
-- ============================================================================
