CREATE OR REPLACE FUNCTION public.manual_sub_buy_alert_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c     public.manual_sub_buy_config;
  v_to  text[];
  v_from text;
  rk    text;
  e     record;
  m     jsonb;
  addr  text;
  best  integer;
  resp  extensions.http_response;
  n     integer := 0;
BEGIN
  SELECT * INTO c FROM public.manual_sub_buy_config;
  IF NOT coalesce(c.alerts_enabled, false) THEN RETURN 0; END IF;
  SELECT coalesce(c.alert_email_to, a.email_to), a.email_from INTO v_to, v_from FROM public.n2s_autobuy_config a;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'RESEND_API_KEY') INTO rk FROM vault.decrypted_secrets;
  IF rk IS NULL OR v_from IS NULL OR coalesce(cardinality(v_to), 0) = 0 THEN RETURN 0; END IF;
  PERFORM set_config('http.timeout_msec', '5000', true);
  FOR e IN
    SELECT b AS buy, k.kind
      FROM public.manual_sub_buy b
      CROSS JOIN LATERAL (VALUES
        ('bought',  b.state = 'bought' AND b.buy_order_id IS NOT NULL AND b.alerted_bought_at IS NULL),
        ('unknown', b.state = 'unknown' AND b.alerted_unknown_at IS NULL),
        ('final',   b.outcome IN ('confirmed', 'rejected', 'canceled') AND b.alerted_final_at IS NULL)
      ) AS k(kind, due)
     WHERE k.due
     ORDER BY b.buy_id, k.kind LIMIT 5
  LOOP
    m := public.manual_sub_buy_alert_text(e.buy, e.kind);
    best := NULL;
    FOREACH addr IN ARRAY v_to LOOP
      BEGIN
        resp := extensions.http(('POST', 'https://api.resend.com/emails',
                  ARRAY[extensions.http_header('Authorization', 'Bearer ' || rk)], 'application/json',
                  jsonb_build_object('from', v_from, 'to', jsonb_build_array(addr),
                                     'subject', m->>'subject', 'text', m->>'text')::text)::extensions.http_request);
        best := CASE WHEN best = 200 THEN 200 ELSE resp.status END;
      EXCEPTION WHEN OTHERS THEN
        best := coalesce(best, -1);
      END;
    END LOOP;
    UPDATE public.manual_sub_buy
       SET alerted_bought_at  = CASE WHEN e.kind = 'bought'  THEN now() ELSE alerted_bought_at END,
           alerted_unknown_at = CASE WHEN e.kind = 'unknown' THEN now() ELSE alerted_unknown_at END,
           alerted_final_at   = CASE WHEN e.kind = 'final'   THEN now() ELSE alerted_final_at END,
           alert_http = best
     WHERE buy_id = (e.buy).buy_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END
$function$

