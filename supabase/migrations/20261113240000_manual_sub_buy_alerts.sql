-- Migration 20261113240000 · level:secondary-sales · lane:D0 · writes:manual_sub_buy_config,manual_sub_buy,manual_sub_buy_alert_text,manual_sub_buy_alert_tick,cron:manual_sub_buy_alert_1min · reads:n2s_autobuy_config,vault.decrypted_secrets · pre:20261113150000
--
-- MANUAL SUB BUY: an email whenever money moves.
--
-- Operator 2026-11-13: "Create alert when money moves". Every buy outside N2S goes through
-- manual_sub_buy: the operator's own buys, the sub finder's automatic one-to-one buys, the buys a
-- CRM key confirms, the ones carried out from the CRM's feed decisions, and the EVO seats a
-- GoTickets customer accepted. Until now a buy only showed in the data. N2S auto-buys already
-- email (n2s_autobuy_notify_tick, 20261109030000); this does the same for this path.
--
-- One email per event on a buy, each sent once:
--   bought    EVO took the order (state 'bought' with a buy_order_id): money is committed.
--   unknown   EVO did not answer clearly (state 'unknown'): a person must check, and every
--             further buy is blocked until then.
--   final     the seller confirmed, rejected or cancelled (outcome): covered, or money coming back.
--
--   who       manual_sub_buy_config.alert_email_to when set, else n2s_autobuy_config.email_to;
--             sender n2s_autobuy_config.email_from. Sent through Resend with the vault's
--             RESEND_API_KEY, one message per recipient (as n2s_autobuy_notify_tick does).
--   switch    manual_sub_buy_config.alerts_enabled (on). Inert without a key, sender or recipient.
--   no flood  buys that already exist are marked as alerted here, so only new events email.
--   failures  a send that fails is recorded (alert_http) and not retried: an alert must never
--             hold up or repeat around a buy.
-- Resend is our own mail provider, not a listing source: RULE 2 does not apply.
--
-- rollback: SELECT cron.unschedule('manual_sub_buy_alert_1min');
--           DROP FUNCTION public.manual_sub_buy_alert_tick(), public.manual_sub_buy_alert_text(public.manual_sub_buy, text);
--           ALTER TABLE public.manual_sub_buy DROP COLUMN alerted_bought_at, DROP COLUMN alerted_unknown_at,
--             DROP COLUMN alerted_final_at, DROP COLUMN alert_http;
--           ALTER TABLE public.manual_sub_buy_config DROP COLUMN alerts_enabled, DROP COLUMN alert_email_to;

ALTER TABLE public.manual_sub_buy_config
  ADD COLUMN IF NOT EXISTS alerts_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS alert_email_to text[];        -- NULL = n2s_autobuy_config.email_to

ALTER TABLE public.manual_sub_buy
  ADD COLUMN IF NOT EXISTS alerted_bought_at  timestamptz,
  ADD COLUMN IF NOT EXISTS alerted_unknown_at timestamptz,
  ADD COLUMN IF NOT EXISTS alerted_final_at   timestamptz,
  ADD COLUMN IF NOT EXISTS alert_http         integer;    -- last send: best HTTP status, -1 = could not send

-- buys that already happened are not news
UPDATE public.manual_sub_buy
   SET alerted_bought_at  = coalesce(alerted_bought_at,  CASE WHEN buy_order_id IS NOT NULL THEN now() END),
       alerted_unknown_at = coalesce(alerted_unknown_at, CASE WHEN state = 'unknown' THEN now() END),
       alerted_final_at   = coalesce(alerted_final_at,   CASE WHEN outcome IN ('confirmed', 'rejected', 'canceled') THEN now() END)
 WHERE (buy_order_id IS NOT NULL AND alerted_bought_at IS NULL)
    OR (state = 'unknown' AND alerted_unknown_at IS NULL)
    OR (outcome IN ('confirmed', 'rejected', 'canceled') AND alerted_final_at IS NULL);

-- The subject and text of one alert. Pure: no sending, so it can be read and tested on its own.
CREATE OR REPLACE FUNCTION public.manual_sub_buy_alert_text(b public.manual_sub_buy, p_kind text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'subject', CASE p_kind
        WHEN 'bought'  THEN format('Sub buy PLACED: EVO order %s for %s sale %s ($%s)',
                                   b.buy_order_id, b.sale_site, b.sale_order_number, t.total)
        WHEN 'unknown' THEN format('Sub buy NEEDS A CHECK: %s sale %s, EVO did not answer clearly',
                                   b.sale_site, b.sale_order_number)
        ELSE format('Sub buy %s: EVO order %s for %s sale %s',
                    upper(CASE b.outcome WHEN 'canceled' THEN 'cancelled' ELSE b.outcome END),
                    coalesce(b.buy_order_id, 'n/a'), b.sale_site, b.sale_order_number) END,
    'text', format(E'%s\n\n'
                || E'Buy id %s, requested by %s\n'
                || E'EVO order: %s (listing %s)\n'
                || E'Sale it covers: order %s on %s\n\n'
                || E'Event: %s\nSeats: %s\nQty %s at $%s each, total $%s\n'
                || E'Sold at $%s each, total $%s: %s\n%s',
           CASE p_kind
             WHEN 'bought'  THEN 'EVO took the order. Money is committed; waiting for the seller to confirm.'
             WHEN 'unknown' THEN 'EVO did not answer clearly, so we do not know whether this was bought. '
                              || 'Check it in EVO. No other buy goes out until this is cleared.'
             ELSE CASE b.outcome
                    WHEN 'confirmed' THEN 'The seller confirmed. The sale is covered.'
                    WHEN 'rejected'  THEN 'The seller REJECTED the order. The sale is NOT covered; pick another sub.'
                    ELSE 'The order was CANCELLED. The sale is NOT covered; pick another sub.' END END,
           b.buy_id, b.requested_by,
           coalesce(b.buy_order_id, 'none recorded'), b.ticket_group_id,
           b.sale_order_number, b.sale_site,
           coalesce(b.event_name, 'event ' || coalesce(b.tevo_event_id::text, '?')),
           coalesce(nullif(concat_ws(' row ', b.bought_section, b.bought_row), ''), 'not known yet'),
           b.qty, coalesce(b.bought_price_ea, b.max_price_ea), t.total,
           coalesce(b.sold_ea::text, '?'), coalesce((b.sold_ea * b.qty)::text, '?'),
           CASE WHEN b.sold_ea IS NULL THEN 'profit not known'
                WHEN b.sold_ea * b.qty - t.total >= 0 THEN 'profit $' || round(b.sold_ea * b.qty - t.total, 2)
                ELSE 'LOSS $' || round(t.total - b.sold_ea * b.qty, 2) END,
           CASE WHEN b.rejection_reason IS NOT NULL THEN 'Reason given: ' || b.rejection_reason
                WHEN b.error IS NOT NULL AND p_kind = 'unknown' THEN 'Error: ' || left(b.error, 300)
                ELSE '' END))
  FROM (SELECT round(coalesce(b.order_total_usd, b.bought_total_usd,
                              b.qty * coalesce(b.bought_price_ea, b.max_price_ea)), 2) AS total) t
$$;

CREATE OR REPLACE FUNCTION public.manual_sub_buy_alert_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.manual_sub_buy_alert_tick(), public.manual_sub_buy_alert_text(public.manual_sub_buy, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_alert_tick() TO service_role;

DO $cron$
BEGIN
  IF to_regclass('cron.job') IS NULL THEN RETURN; END IF;                     -- no pg_cron here (local / CI)
  EXECUTE $q$
    SELECT cron.schedule('manual_sub_buy_alert_1min', '* * * * *', 'SELECT public.manual_sub_buy_alert_tick();')
     WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'manual_sub_buy_alert_1min')
  $q$;
END
$cron$;
