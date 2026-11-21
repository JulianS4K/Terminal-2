-- Stand-ins for the N2S outcome email (lane D7) as it is in production, for the CRM push
-- (mig 20261120171030): the columns the email reads, pg_net's POST (recorded in net.posted), and
-- n2s_autobuy_outcome_tick() itself, copied whole as 20261113400000 left it. The migration's md5
-- guard (85fecc4eacd61c2aad1f9e72cf24df07) passes only if this copy equals production's.
ALTER TABLE public.n2s_autobuy_exec
  ADD COLUMN IF NOT EXISTS outcome_emailed_at timestamptz, ADD COLUMN IF NOT EXISTS margin_usd numeric;
CREATE TABLE IF NOT EXISTS net.posted (id bigserial PRIMARY KEY, url text, body jsonb, headers jsonb);
CREATE OR REPLACE FUNCTION net.http_post(url text, body jsonb DEFAULT '{}', params jsonb DEFAULT '{}',
                                         headers jsonb DEFAULT '{}', timeout_milliseconds integer DEFAULT 5000)
 RETURNS bigint LANGUAGE sql AS $$ INSERT INTO net.posted (url, body, headers) VALUES (url, body, headers) RETURNING id $$;
CREATE OR REPLACE FUNCTION public.n2s_autobuy_outcome_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c    public.n2s_autobuy_config%ROWTYPE;
  e    RECORD;
  rk   text; addr text; body text; subj text;
  resp extensions.http_response;
  n    int := 0;
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'RESEND_API_KEY') INTO rk FROM vault.decrypted_secrets;
  IF rk IS NULL OR cardinality(c.email_to) = 0 OR c.email_from IS NULL THEN RETURN 0; END IF;
  PERFORM set_config('http.timeout_msec', '5000', true);
  FOR e IN SELECT * FROM public.n2s_autobuy_exec
            WHERE mode = 'live' AND outcome_emailed_at IS NULL
              AND phase IN ('accepted', 'stopped', 'buy_unknown', 'accept_failed', 'accept_unknown')
            ORDER BY exec_id LIMIT 5 LOOP
    subj := format('N2S LIVE %s: sale %s%s', upper(replace(e.phase, '_', ' ')), e.order_number,
                   CASE WHEN e.buy_order_id IS NOT NULL THEN ', ' || CASE e.sub_source WHEN 'gotickets' THEN 'GoTickets' ELSE 'EVO' END || ' purchase ' || e.buy_order_id ELSE '' END);
    body := format(E'Outcome: %s\nReasons: %s\nError: %s\n\n'
                   || E'Sub purchase (buy) id: %s, state %s\nSale it covers: order %s on %s, state %s\n\n'
                   || E'Event: %s (%s)\nQty %s, buy $%s, sale $%s, margin $%s\n\n%s',
                   e.phase, array_to_string(e.reasons, ', '), COALESCE(e.live_error, '-'),
                   COALESCE(e.buy_order_id, 'none (nothing bought)'), COALESCE(e.buy_state, '-'),
                   e.order_number, e.sell_market, COALESCE(e.sale_state, '-'),
                   e.event_name, e.event_dt_local, e.qty, e.sub_total_usd, e.sold_total_usd, e.margin_usd,
                   CASE WHEN e.phase IN ('buy_unknown', 'accept_unknown')
                        THEN 'A write had an unknown outcome: CHECK ' || CASE e.sub_source WHEN 'gotickets' THEN 'GOTICKETS' ELSE 'EVO' END || ' NOW. The kill switch is on.'
                        WHEN e.phase = 'accepted' THEN 'Sub confirmed and the sale was accepted.'
                        WHEN e.buy_order_id IS NOT NULL THEN 'We hold the sub but the sale was NOT accepted: handle by hand.'
                        ELSE 'Nothing was bought.' END);
    FOREACH addr IN ARRAY c.email_to LOOP
      BEGIN
        resp := extensions.http(('POST', 'https://api.resend.com/emails',
                  ARRAY[extensions.http_header('Authorization', 'Bearer ' || rk)], 'application/json',
                  jsonb_build_object('from', c.email_from, 'to', jsonb_build_array(addr),
                                     'subject', subj, 'text', body)::text)::extensions.http_request);
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END LOOP;
    UPDATE public.n2s_autobuy_exec SET outcome_emailed_at = now() WHERE exec_id = e.exec_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;
