-- Migration 20261110040000 · level:secondary-sales · lane:D7 · writes:n2s_tickpick_seen,n2s_tickpick_byid_log,v_n2s_tickpick_watch,n2s_tickpick_watch_tick,cron · reads:n2s_items,vault.decrypted_secrets · pre:20261110030000
--
-- N2S × TickPick: are our N2S TickPick sales visible to the TickPick account we can log in as?
--
-- Operator 2026-11-10: "if it doesn't get confirmed it disappears from tickpick, track tickpick
-- unconfirmed orders against n2s and report … when we have a better sample size."
-- Context: the vault TickPick login (seller tu@s4kent.com, refreshed by tickpick_token_refresh)
-- sees 1,777 unfulfilled orders, but none of the last 30 days' 261 N2S TickPick sales — and
-- GET /1.0/orders/{n} answered 404 for two of today's. Those were looked up after their window,
-- and an unconfirmed TickPick order that lapses disappears, so that alone proves nothing.
--
-- n2s_tickpick_watch_tick() (cron n2s_tickpick_watch_1min), GET only:
--   1. GET /1.0/orders?status=unconfirmed → every order the account shows unconfirmed is upserted
--      into n2s_tickpick_seen (first/last seen, seller_status, confirmation_deadline, price, event).
--   2. For each N2S TickPick sale whose alert is under 20 min old: GET /1.0/orders/{order} and
--      log the HTTP status + seller_status in n2s_tickpick_byid_log (at most once a minute each).
-- v_n2s_tickpick_watch: one row per N2S TickPick sale since this migration — seen in the
-- unconfirmed list?, ever 200 by id?, statuses seen, first/last seen vs its alert.
-- No write to TickPick; nothing is confirmed. No token in any table.
--
-- rollback: SELECT cron.unschedule('n2s_tickpick_watch_1min');
--           DROP VIEW v_n2s_tickpick_watch; DROP FUNCTION n2s_tickpick_watch_tick();
--           DROP TABLE n2s_tickpick_byid_log, n2s_tickpick_seen;

CREATE TABLE IF NOT EXISTS public.n2s_tickpick_seen (
  order_number          text        PRIMARY KEY,
  first_seen_at         timestamptz NOT NULL DEFAULT now(),
  last_seen_at          timestamptz NOT NULL DEFAULT now(),
  seen_count            integer     NOT NULL DEFAULT 1,
  seller_status         text,
  order_status          text,
  confirmation_deadline text,
  purchase_date         text,
  event_name            text,
  event_date            text,
  section               text,
  row_name              text,
  quantity              integer,
  wholesale_price       numeric
);

CREATE TABLE IF NOT EXISTS public.n2s_tickpick_byid_log (
  id            bigserial   PRIMARY KEY,
  order_number  text        NOT NULL,
  n2s_id        bigint,
  polled_at     timestamptz NOT NULL DEFAULT now(),
  http          integer,
  seller_status text,
  order_status  text
);
CREATE INDEX IF NOT EXISTS n2s_tickpick_byid_log_order ON public.n2s_tickpick_byid_log (order_number, polled_at);

ALTER TABLE public.n2s_tickpick_seen     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n2s_tickpick_byid_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_tickpick_seen, public.n2s_tickpick_byid_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.n2s_tickpick_seen, public.n2s_tickpick_byid_log TO service_role;

CREATE OR REPLACE FUNCTION public.n2s_tickpick_watch_tick()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  tok   text;
  r     extensions.http_response;
  j     jsonb;
  o     RECORD;
  n_seen int := 0;
  n_id   int := 0;
BEGIN
  SELECT decrypted_secret INTO tok FROM vault.decrypted_secrets WHERE name = 'TICKPICK_API_TOKEN';
  IF tok IS NULL THEN RETURN 'no_token'; END IF;
  PERFORM set_config('http.timeout_msec', '20000', true);

  -- 1. Everything the account shows unconfirmed right now.
  BEGIN
    r := extensions.http(('GET', 'https://api.tickpick.com/1.0/orders?status=unconfirmed',
           ARRAY[extensions.http_header('Authorization', 'Bearer ' || tok)], NULL, NULL)::extensions.http_request);
    IF r.status = 200 AND r.content ~ '^\s*\[' THEN
      j := r.content::jsonb;
      INSERT INTO public.n2s_tickpick_seen AS s
             (order_number, seller_status, order_status, confirmation_deadline, purchase_date, event_name, event_date,
              section, row_name, quantity, wholesale_price)
      SELECT e->>'order_number', e->>'seller_status', e->>'order_status', e->>'confirmation_deadline', e->>'purchase_date',
             e->>'event_name', e->>'event_date', e->>'section', e->>'row', NULLIF(e->>'quantity','')::int,
             NULLIF(e->>'wholesale_price','')::numeric
        FROM jsonb_array_elements(j) e
       WHERE e->>'order_number' IS NOT NULL
      ON CONFLICT (order_number) DO UPDATE
         SET last_seen_at = now(), seen_count = s.seen_count + 1,
             seller_status = excluded.seller_status, order_status = excluded.order_status,
             confirmation_deadline = COALESCE(excluded.confirmation_deadline, s.confirmation_deadline);
      GET DIAGNOSTICS n_seen = ROW_COUNT;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    n_seen := -1;   -- timeout / parse error: try again next minute
  END;

  -- 2. Each open N2S TickPick sale, by its order number (at most once a minute per order).
  FOR o IN
    SELECT i.n2s_id, i.n2s_order_key AS order_number
      FROM public.n2s_items i
     WHERE i.n2s_id > 0 AND lower(COALESCE(i.s4k_source, '')) LIKE 'tickpick%'
       AND i.n2s_order_key IS NOT NULL AND i.alert_at > now() - interval '20 minutes'
       AND NOT EXISTS (SELECT 1 FROM public.n2s_tickpick_byid_log l
                        WHERE l.order_number = i.n2s_order_key AND l.polled_at > now() - interval '50 seconds')
     ORDER BY i.alert_at DESC
     LIMIT 5
  LOOP
    BEGIN
      r := extensions.http(('GET', 'https://api.tickpick.com/1.0/orders/' || o.order_number,
             ARRAY[extensions.http_header('Authorization', 'Bearer ' || tok)], NULL, NULL)::extensions.http_request);
      j := CASE WHEN r.content ~ '^\s*\{' THEN r.content::jsonb END;
      INSERT INTO public.n2s_tickpick_byid_log (order_number, n2s_id, http, seller_status, order_status)
      VALUES (o.order_number, o.n2s_id, r.status, j->>'seller_status', j->>'order_status');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.n2s_tickpick_byid_log (order_number, n2s_id, http) VALUES (o.order_number, o.n2s_id, -1);
    END;
    n_id := n_id + 1;
  END LOOP;
  RETURN format('unconfirmed_rows=%s byid_polls=%s', n_seen, n_id);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_tickpick_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_tickpick_watch_tick() TO service_role;

-- One row per N2S TickPick sale alerted since the watch started.
CREATE OR REPLACE VIEW public.v_n2s_tickpick_watch
WITH (security_invoker = true) AS
SELECT i.n2s_id, i.n2s_order_key AS order_number, i.alert_at, i.event_name, i.status AS n2s_status,
       s.order_number IS NOT NULL                                     AS seen_unconfirmed,
       s.first_seen_at, s.last_seen_at, s.seller_status AS list_status, s.confirmation_deadline,
       b.polls, b.ok_polls, b.statuses AS byid_statuses, b.http_codes,
       (s.order_number IS NOT NULL OR COALESCE(b.ok_polls, 0) > 0)    AS visible_to_account
  FROM public.n2s_items i
  LEFT JOIN public.n2s_tickpick_seen s ON s.order_number = i.n2s_order_key
  LEFT JOIN LATERAL (
        SELECT count(*) AS polls, count(*) FILTER (WHERE l.http = 200) AS ok_polls,
               array_agg(DISTINCT l.seller_status) FILTER (WHERE l.seller_status IS NOT NULL) AS statuses,
               array_agg(DISTINCT l.http) AS http_codes
          FROM public.n2s_tickpick_byid_log l WHERE l.order_number = i.n2s_order_key) b ON true
 WHERE i.n2s_id > 0 AND lower(COALESCE(i.s4k_source, '')) LIKE 'tickpick%'
   AND i.alert_at >= '2026-11-09 23:00:00+00';
REVOKE ALL ON public.v_n2s_tickpick_watch FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_n2s_tickpick_watch TO service_role;

SELECT cron.schedule('n2s_tickpick_watch_1min', '* * * * *', $$SELECT public.n2s_tickpick_watch_tick();$$);
