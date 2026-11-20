-- Migration 20261120165800 · level:secondary-sales · lane:D0 · writes:manual_sub_buy_config,manual_sub_buy_alert_tick · reads:n2s_autobuy_config,vault.decrypted_secrets · pre:20261113440000
--
-- MANUAL SUB BUY alerts get their own sender.
--
-- Operator 2026-11-20, seeing other jobs' mail arrive as "N2S Auto-buy": "look at everything
-- that reuses the template and make one for each that uses it". manual_sub_buy_alert_tick
-- (20261113240000, last redefined 20261113440000) sent from n2s_autobuy_config.email_from, so
-- a sub finder buy arrived as "N2S Auto-buy <onboarding@resend.dev>" although N2S did not buy it.
--
-- Now the sub buy alerts read only their own settings:
--   sender      manual_sub_buy_config.alert_email_from, 'Sub buy alerts <onboarding@resend.dev>'
--               (the same Resend address as before; only the name changes).
--   recipients  manual_sub_buy_config.alert_email_to. Where it was NULL (= use N2S's list) it is
--               filled once here with n2s_autobuy_config.email_to, so the same people keep getting
--               these, and a later change to N2S's list no longer changes this one.
-- Nothing else in the function changes. N2S's own mail (n2s_autobuy_notify_tick /
-- n2s_autobuy_outcome_tick) keeps n2s_autobuy_config.email_from / email_to.
-- Resend is our own mail provider, not a listing source: RULE 2 does not apply.
--
-- VERIFY: SELECT alert_email_from, alert_email_to FROM manual_sub_buy_config;
--         SELECT prosrc NOT LIKE '%n2s_autobuy_config%' FROM pg_proc WHERE proname = 'manual_sub_buy_alert_tick';
-- ROLLBACK: re-apply manual_sub_buy_alert_tick() from 20261113440000;
--           ALTER TABLE public.manual_sub_buy_config DROP COLUMN alert_email_from;
--           (alert_email_to keeps the copied list; set it back to NULL to follow N2S's list again.)

BEGIN;
SET LOCAL lock_timeout = '10s';

ALTER TABLE public.manual_sub_buy_config
  ADD COLUMN IF NOT EXISTS alert_email_from text NOT NULL DEFAULT 'Sub buy alerts <onboarding@resend.dev>';

UPDATE public.manual_sub_buy_config c
   SET alert_email_to = a.email_to
  FROM public.n2s_autobuy_config a
 WHERE c.alert_email_to IS NULL;

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
  v_to := c.alert_email_to;
  v_from := c.alert_email_from;
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
     WHERE k.due AND b.origin = 'manual'               -- the N2S desk sends its own (20261113440000)
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
$function$;

REVOKE ALL ON FUNCTION public.manual_sub_buy_alert_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_alert_tick() TO service_role;

COMMIT;
