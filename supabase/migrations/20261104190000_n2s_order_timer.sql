-- Migration 20261104190000 · level:secondary-sales · lane:D7 · writes:n2s_order_timer_state,n2s_order_timer_log,v_n2s_order_timer,cron · reads:n2s_items,vault.decrypted_secrets · pre:20261104170000
--
-- N2S order timer: how long a sale order stays in each state, to ~30 s.
--
-- Operator direction 2026-11-04: "go ahead with the order timer". The order
-- feeds we ingest refresh every 15–60 min, too coarse to time an accept or a
-- reject. While an N2S order is open (alert + 20 min) on a marketplace whose
-- token works, n2s_order_timer_tick() reads that one order's status straight
-- from the market and logs every state change with our timestamp:
--
--   EVO       GET api.ticketevolution.com/v9/orders/{id}   (signed)  → state
--   GoTickets GET sc.gotickets.com/rest/sales/{id}                    → sellerStatus
--   SeatGeek  GET sellerdirect-api.seatgeek.com/order?order_id=       → status
--   Vivid     GET brokers.vividseats.com/webservices/v1/getOrder      → <status>
--
-- GET only: nothing is written to any market. Each order is re-read every
-- 30 s (Vivid every 60 s, and a 429 pushes that order out 2 min); at most 6
-- reads per tick, 4 s timeout each, one tick at a time (advisory lock).
-- Measured 2026-11-04: GoTickets 93 ms, SeatGeek 150 ms, Vivid 218 ms,
-- EVO 509 ms. Roughly 30–40 open orders a day × ~30 reads.
--
-- rollback: SELECT cron.unschedule('n2s_order_timer_30s');
--           DROP VIEW v_n2s_order_timer; DROP FUNCTION n2s_order_timer_tick();
--           DROP TABLE n2s_order_timer_log, n2s_order_timer_state;

CREATE TABLE IF NOT EXISTS public.n2s_order_timer_state (
  market            text        NOT NULL,
  order_key         text        NOT NULL,
  n2s_id            bigint,
  alert_at          timestamptz,
  first_polled_at   timestamptz,
  last_polled_at    timestamptz,
  next_poll_at      timestamptz,
  last_state        text,
  last_http         integer,
  polls             integer     NOT NULL DEFAULT 0,
  errors            integer     NOT NULL DEFAULT 0,
  market_created_at timestamptz,
  market_updated_at timestamptz,
  PRIMARY KEY (market, order_key)
);

CREATE TABLE IF NOT EXISTS public.n2s_order_timer_log (
  id                bigserial   PRIMARY KEY,
  market            text        NOT NULL,
  order_key         text        NOT NULL,
  n2s_id            bigint,
  seen_at           timestamptz NOT NULL DEFAULT now(),
  prev_state        text,
  state             text,
  http_status       integer,
  ms                integer,
  market_updated_at timestamptz
);
CREATE INDEX IF NOT EXISTS n2s_order_timer_log_order ON public.n2s_order_timer_log (market, order_key, seen_at);

ALTER TABLE public.n2s_order_timer_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n2s_order_timer_log   ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_order_timer_state, public.n2s_order_timer_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.n2s_order_timer_state, public.n2s_order_timer_log TO service_role;

CREATE OR REPLACE FUNCTION public.n2s_order_timer_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  o RECORD;
  r extensions.http_response;
  t0 timestamptz;
  v_state text; v_created timestamptz; v_updated timestamptz; v_ms int; v_http int;
  v_prev text; v_n int := 0;
  gt_id text; gt_sec text; sg_tok text; tv_tok text; tv_sec text; vv_tok text; sig text;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('n2s_order_timer_tick')) THEN RETURN 0; END IF;
  PERFORM set_config('http.timeout_msec', '4000', true);

  SELECT max(decrypted_secret) FILTER (WHERE name = 'GOTICKETS_ACCESS_ID'),
         max(decrypted_secret) FILTER (WHERE name = 'GOTICKETS_API_SECRET'),
         max(decrypted_secret) FILTER (WHERE name = 'SEATGEEK_API_TOKEN'),
         max(decrypted_secret) FILTER (WHERE name = 'TEVO_API_TOKEN'),
         max(decrypted_secret) FILTER (WHERE name = 'TEVO_SECRET'),
         max(decrypted_secret) FILTER (WHERE name = 'VIVID_API_TOKEN')
    INTO gt_id, gt_sec, sg_tok, tv_tok, tv_sec, vv_tok
    FROM vault.decrypted_secrets;

  FOR o IN
    SELECT CASE WHEN lower(i.s4k_source) LIKE 'evo%' THEN 'evo'
                WHEN lower(i.s4k_source) LIKE 'gotickets%' THEN 'gotickets'
                WHEN lower(i.s4k_source) LIKE 'seatgeek%' THEN 'seatgeek'
                ELSE 'vivid' END AS market,
           i.n2s_order_key AS order_key, i.n2s_id, i.alert_at
      FROM public.n2s_items i
      LEFT JOIN public.n2s_order_timer_state s
        ON s.order_key = i.n2s_order_key
       AND s.market = CASE WHEN lower(i.s4k_source) LIKE 'evo%' THEN 'evo'
                           WHEN lower(i.s4k_source) LIKE 'gotickets%' THEN 'gotickets'
                           WHEN lower(i.s4k_source) LIKE 'seatgeek%' THEN 'seatgeek'
                           ELSE 'vivid' END
     WHERE i.n2s_id > 0
       AND i.alert_at > now() - interval '20 minutes'
       AND i.n2s_order_key IS NOT NULL
       AND lower(COALESCE(i.s4k_source, '')) LIKE ANY (ARRAY['evo%', 'gotickets%', 'seatgeek%', 'vivid%'])
       AND (s.next_poll_at IS NULL OR s.next_poll_at <= now())
     ORDER BY s.last_polled_at NULLS FIRST, i.alert_at
     LIMIT 6
  LOOP
    v_state := NULL; v_created := NULL; v_updated := NULL; v_http := NULL;
    t0 := clock_timestamp();
    BEGIN
      IF o.market = 'evo' THEN
        sig := encode(extensions.hmac('GET api.ticketevolution.com/v9/orders/' || o.order_key || '?', tv_sec, 'sha256'), 'base64');
        r := extensions.http(('GET', 'https://api.ticketevolution.com/v9/orders/' || o.order_key,
               ARRAY[extensions.http_header('X-Token', tv_tok), extensions.http_header('X-Signature', sig),
                     extensions.http_header('Accept', 'application/json')], NULL, NULL)::extensions.http_request);
        v_http := r.status;
        IF r.status = 200 THEN
          v_state := r.content::jsonb ->> 'state';
          v_created := (r.content::jsonb ->> 'created_at')::timestamptz;
          v_updated := (r.content::jsonb ->> 'updated_at')::timestamptz;
        END IF;
      ELSIF o.market = 'gotickets' THEN
        r := extensions.http(('GET', 'https://sc.gotickets.com/rest/sales/' || o.order_key,
               ARRAY[extensions.http_header('X-Api-Access-Id', gt_id), extensions.http_header('X-Api-Access-Secret', gt_sec)],
               NULL, NULL)::extensions.http_request);
        v_http := r.status;
        IF r.status = 200 THEN
          v_state := r.content::jsonb ->> 'sellerStatus';
          v_created := ((r.content::jsonb ->> 'createTime')::timestamp) AT TIME ZONE 'UTC';
        END IF;
      ELSIF o.market = 'seatgeek' THEN
        r := extensions.http(('GET', 'https://sellerdirect-api.seatgeek.com/order?order_id=' || o.order_key || '&token=' || sg_tok,
               NULL, NULL, NULL)::extensions.http_request);
        v_http := r.status;
        IF r.status = 200 THEN
          v_state := r.content::jsonb ->> 'status';
          v_created := ((r.content::jsonb ->> 'created')::timestamp) AT TIME ZONE 'UTC';
          v_updated := ((r.content::jsonb ->> 'updated')::timestamp) AT TIME ZONE 'UTC';
        END IF;
      ELSE
        r := extensions.http(('GET', 'https://brokers.vividseats.com/webservices/v1/getOrder?apiToken=' || vv_tok
                                  || '&orderId=' || o.order_key, NULL, NULL, NULL)::extensions.http_request);
        v_http := r.status;
        IF r.status = 200 THEN
          v_state := (regexp_match(r.content, '<status>([^<]*)</status>'))[1];
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_http := -1;  -- timeout / network / parse error
    END;
    v_ms := extract(milliseconds FROM clock_timestamp() - t0)::int;

    SELECT last_state INTO v_prev FROM public.n2s_order_timer_state
     WHERE market = o.market AND order_key = o.order_key;

    INSERT INTO public.n2s_order_timer_state AS s
           (market, order_key, n2s_id, alert_at, first_polled_at, last_polled_at, next_poll_at,
            last_state, last_http, polls, errors, market_created_at, market_updated_at)
    VALUES (o.market, o.order_key, o.n2s_id, o.alert_at, now(), now(),
            now() + CASE WHEN v_http = 429 THEN interval '2 minutes'
                         WHEN o.market = 'vivid' THEN interval '60 seconds'
                         ELSE interval '30 seconds' END,
            COALESCE(v_state, v_prev), v_http, 1, CASE WHEN v_http IS DISTINCT FROM 200 THEN 1 ELSE 0 END,
            v_created, v_updated)
    ON CONFLICT (market, order_key) DO UPDATE
       SET last_polled_at    = now(),
           next_poll_at      = excluded.next_poll_at,
           last_state        = COALESCE(v_state, s.last_state),
           last_http         = v_http,
           polls             = s.polls + 1,
           errors            = s.errors + CASE WHEN v_http IS DISTINCT FROM 200 THEN 1 ELSE 0 END,
           market_created_at = COALESCE(s.market_created_at, excluded.market_created_at),
           market_updated_at = COALESCE(excluded.market_updated_at, s.market_updated_at);

    IF v_state IS NOT NULL AND v_state IS DISTINCT FROM v_prev THEN
      INSERT INTO public.n2s_order_timer_log (market, order_key, n2s_id, prev_state, state, http_status, ms, market_updated_at)
      VALUES (o.market, o.order_key, o.n2s_id, v_prev, v_state, v_http, v_ms, v_updated);
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_order_timer_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_order_timer_tick() TO service_role;

-- One row per state an order passed through: when we first saw it, seconds
-- after the CRM alert and after the market says the order was created.
CREATE OR REPLACE VIEW public.v_n2s_order_timer
WITH (security_invoker = true) AS
SELECT l.market, l.order_key, l.n2s_id, l.prev_state, l.state, l.seen_at,
       s.alert_at, s.market_created_at, l.market_updated_at,
       extract(epoch FROM (l.seen_at - s.alert_at))::int                         AS s_after_alert,
       extract(epoch FROM (l.seen_at - s.market_created_at))::int                AS s_after_created,
       extract(epoch FROM (l.market_updated_at - s.market_created_at))::int      AS market_s_to_update,
       s.polls, s.errors, s.last_http
  FROM public.n2s_order_timer_log l
  JOIN public.n2s_order_timer_state s USING (market, order_key);

REVOKE ALL ON public.v_n2s_order_timer FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_n2s_order_timer TO service_role;

SELECT cron.schedule('n2s_order_timer_30s', '30 seconds', $$SELECT public.n2s_order_timer_tick();$$);
