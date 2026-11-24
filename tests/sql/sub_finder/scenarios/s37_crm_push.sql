\echo a confirmed N2S buy goes to the CRM webhook once, with the order number we bought (20261120171030)
INSERT INTO n2s_autobuy_exec (exec_id, order_number, mode, phase, sub_source, sell_market, buy_order_id, buy_state,
                              sale_state, qty, event_name, sub_total_usd, sold_total_usd, buy_total_usd, live_started_at, live_updated_at)
VALUES (901, '8500756', 'live', 'accepted', 'tevo', 'gotickets', '19464447', 'accepted', 'PENDING_FULFILLMENT', 1,
        'Arkansas Razorbacks at Texas Longhorns Football', 140.00, 159.79, 146.52, now(), now()),
       (902, '8500757', 'live', 'stopped',  'tevo', 'gotickets', NULL, NULL, NULL, 1, 'stopped, nothing bought', 10, 20, NULL, now(), now()),
       (903, '8500758', 'live', 'buy_sent', 'gotickets', 'vivid', '55', 'pending', NULL, 2, 'bought, not confirmed yet', 10, 20, 11, now(), now()),
       (904, '8500759', 'dryrun', 'accepted', 'tevo', 'vivid', '77', 'accepted', 'x', 1, 'not live', 10, 20, 11, now(), now());
SELECT 'outcome emails: ' || n2s_autobuy_outcome_tick();
SELECT url, body->>'event' AS event, body->>'exec_id' AS exec_id, body->>'buy_ref' AS buy_ref,
       body->>'bought_order_number' AS bought, body->'for_order'->>'order_number' AS for_order,
       body->'for_order'->>'sold_on' AS sold_on, body->>'status' AS status, body->>'attempt' AS attempt,
       headers->>'Authorization' AS auth
  FROM net.posted ORDER BY id;

\echo the next minute sends nothing new
SELECT 'outcome emails: ' || n2s_autobuy_outcome_tick();
SELECT 'posted: ' || count(*) FROM net.posted;

\echo no 2xx answer: sent again 5 minutes on, 3 sends at most
CREATE FUNCTION pg_temp.answer(p_status integer, p_body text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO net._http_response (id, status_code, content)
  SELECT request_id, p_status, p_body FROM n2s_autobuy_crm_push WHERE exec_id = 901;
  RETURN 'push: ' || (n2s_autobuy_crm_push() - 'configured')::text;
END $$;
SELECT pg_temp.answer(500, 'receiver down');
UPDATE n2s_autobuy_crm_push SET fired_at = now() - interval '6 minutes';
SELECT 'push: ' || n2s_autobuy_crm_push()::text;
SELECT pg_temp.answer(NULL, NULL);
UPDATE n2s_autobuy_crm_push SET fired_at = now() - interval '6 minutes';
SELECT 'push: ' || n2s_autobuy_crm_push()::text;
SELECT pg_temp.answer(502, 'bad gateway');
UPDATE n2s_autobuy_crm_push SET fired_at = now() - interval '6 minutes';
SELECT 'push: ' || n2s_autobuy_crm_push()::text;
SELECT exec_id, attempts, status_code, error_msg FROM n2s_autobuy_crm_push;
SELECT 'attempts posted: ' || string_agg(body->>'attempt', ',' ORDER BY id) FROM net.posted;

\echo a 2xx answer ends it
INSERT INTO n2s_autobuy_exec (exec_id, order_number, mode, phase, sub_source, sell_market, buy_order_id, buy_state,
                              sale_state, qty, event_name, sub_total_usd, sold_total_usd, buy_total_usd, live_started_at, live_updated_at)
VALUES (905, '8500760', 'live', 'accepted', 'gotickets', 'tickpick', '8348959', NULL, 'Confirmed', 2, 'GoTickets cover', 200, 260, 237.12, now(), now());
SELECT 'push: ' || n2s_autobuy_crm_push()::text;
INSERT INTO net._http_response (id, status_code, content)
SELECT request_id, 200, 'ok' FROM n2s_autobuy_crm_push WHERE exec_id = 905;
UPDATE n2s_autobuy_crm_push SET fired_at = now() - interval '6 minutes' WHERE exec_id = 905;
SELECT 'push: ' || n2s_autobuy_crm_push()::text;
SELECT exec_id, attempts, status_code, payload->>'buy_ref' AS buy_ref FROM n2s_autobuy_crm_push WHERE exec_id = 905;

\echo no webhook URL in the vault: nothing is sent
CREATE OR REPLACE FUNCTION get_app_secret(p text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN p = 'N2S_COVER_WEBHOOK_URL' THEN NULL ELSE 'secret-' || p END $$;
INSERT INTO n2s_autobuy_exec (exec_id, order_number, mode, phase, sub_source, sell_market, buy_order_id, buy_state,
                              sale_state, qty, event_name, sub_total_usd, sold_total_usd, buy_total_usd, live_started_at, live_updated_at)
VALUES (906, '8500761', 'live', 'accepted', 'tevo', 'seatgeek', '19500001', 'accepted', 'x', 1, 'later buy', 10, 20, 11, now(), now());
SELECT 'push: ' || n2s_autobuy_crm_push()::text;

\echo a listing-source URL is refused, and the outcome email still goes out
CREATE OR REPLACE FUNCTION get_app_secret(p text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN p = 'N2S_COVER_WEBHOOK_URL' THEN 'https://crm.s4kcs.com/hook' ELSE 'secret-' || p END $$;
SELECT 'outcome emails: ' || n2s_autobuy_outcome_tick();
SELECT 'posted: ' || count(*) FROM net.posted;
SELECT 'emailed 906: ' || (outcome_emailed_at IS NOT NULL) FROM n2s_autobuy_exec WHERE exec_id = 906;
