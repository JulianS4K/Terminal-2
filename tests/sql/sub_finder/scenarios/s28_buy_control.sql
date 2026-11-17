\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- One control over both buyers, and one feed of what they bought (mig 20261113430000).
CREATE FUNCTION pg_temp.buy_next(p_order text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE j jsonb;
BEGIN
  j := manual_sub_buy_claim();
  IF j IS NULL THEN RETURN 'nothing handed out'; END IF;
  PERFORM manual_sub_buy_record((j#>>'{row,buy_id}')::bigint, (j#>>'{row,lease_token}')::uuid,
            jsonb_build_object('state', 'bought', 'buy_order_id', p_order, 'bought_total_usd', 100));
  RETURN (j#>>'{row,sale_order_number}') || ' bought on ' || (j#>>'{row,market}');
END $$;
CREATE FUNCTION pg_temp.n2s_next() RETURNS text LANGUAGE plpgsql AS $$
DECLARE j jsonb := n2s_autobuy_live_claim();
BEGIN
  RETURN coalesce(j->>'action' || ' ' || (j#>>'{row,order_number}'), 'nothing handed out')
         || ', EVO runs used ' || (SELECT live_runs_used FROM n2s_autobuy_config);
END $$;
INSERT INTO events (id, name, occurs_at_local) VALUES (1, 'Game', '2026-12-01 19:00');
UPDATE manual_sub_buy_config SET enabled = true, gt_enabled = true, per_order_cap_usd = 750, daily_cap_usd = 4000 WHERE id;
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, event_name, tevo_event_id, ticket_group_id, qty, max_price_ea, sold_ea, market, gt_event_id, created_at)
VALUES ('test','Vivid','E0','Game',1,100,2,50,60,'evo',NULL,now()-interval '10 min'), ('test','Vivid','E1','Game',1,101,2,50,60,'evo',NULL,now()-interval '9 min'), ('test','Vivid','E2','Game',1,102,2,50,60,'evo',NULL,now()-interval '8 min'),
       ('test','Vivid','E3','Game',1,103,2,50,60,'evo',NULL,now()-interval '7 min'), ('test','Vivid','E4','Game',1,104,2,50,60,'evo',NULL,now()-interval '6 min'),
       ('test','Vivid','E5','Game',1,105,2,50,60,'evo',NULL,now()-interval '5 min'), ('test','Vivid','G1','Game',1,106,2,50,60,'gotickets',9001,now()-interval '4 min');
SELECT 'starts: enforce ' || enforce || ', stop ' || stop || ', ceiling ' || coalesce(daily_ceiling_usd::text, 'none')
       || ', EVO in-flight limit ' || coalesce(evo_inflight_max::text, 'none') FROM sub_buy_control;
\echo as shipped nothing is held: the worker hands out one buy per tick, as before
SELECT pg_temp.buy_next('9000');
SELECT manual_sub_buy_follow_record(1, '{"seller_state":"accepted"}');

\echo with an in-flight limit of 3 set
UPDATE sub_buy_control SET evo_inflight_max = 3 WHERE id;

\echo three EVO buys go out, one per tick
SELECT pg_temp.buy_next('9001'); SELECT pg_temp.buy_next('9002'); SELECT pg_temp.buy_next('9003');
SELECT 'EVO buys waiting for a seller: ' || sub_buy_evo_inflight();
\echo the fourth EVO buy waits; the GoTickets buy behind it goes; then nothing
SELECT pg_temp.buy_next('G-1'); SELECT pg_temp.buy_next('9004');
SELECT sale_order_number, market, state, coalesce(array_to_string(reasons, ','), '') FROM manual_sub_buy ORDER BY buy_id;
\echo a seller confirms one: the next EVO buy goes
SELECT manual_sub_buy_follow_record(2, '{"seller_state":"accepted"}'); SELECT pg_temp.buy_next('9004'); SELECT pg_temp.buy_next('9005');
\echo a seller rejects one: that also frees a place
SELECT manual_sub_buy_follow_record(3, '{"seller_state":"rejected"}'); SELECT pg_temp.buy_next('9005');
\echo a buy no seller answered stops counting after the window
UPDATE manual_sub_buy SET updated_at = now() - interval '61 minutes' WHERE sale_order_number = 'E3';
SELECT 'waiting: ' || sub_buy_evo_inflight();
UPDATE manual_sub_buy SET updated_at = now() WHERE sale_order_number = 'E3';
\echo EVO buys by the N2S buyer count in the same limit; its GoTickets buys do not
INSERT INTO n2s_autobuy_exec (order_number, mode, state, phase, sub_source, sell_market, qty, sub_total_usd, est_tax_usd, sold_total_usd, live_started_at, live_updated_at, lease_until, buy_order_id)
VALUES ('N1','live','live_buy','buy_sent','tevo','vivid',2,200,10,260,now(),now(),now()+interval '1 hour','7001'),
       ('N2','live','live_buy','buy_sent','gotickets','vivid',2,100,0,150,now(),now(),now()+interval '1 hour','8001');
SELECT 'waiting: ' || sub_buy_evo_inflight() || ', an EVO buy now: ' || coalesce(sub_buy_gate('tevo', 10), 'may go')
       || ', a GoTickets buy now: ' || coalesce(sub_buy_gate('gotickets', 10), 'may go');
\echo no limit when it is cleared
UPDATE sub_buy_control SET evo_inflight_max = NULL WHERE id;
SELECT coalesce(sub_buy_gate('evo', 10), 'may go');

\echo the shared stop and ceiling are ignored while enforce is off
UPDATE sub_buy_control SET stop = true, daily_ceiling_usd = 1 WHERE id;
SELECT coalesce(sub_buy_gate('evo', 500), 'may go');
\echo enforce on, stop on: neither buyer starts a new buy; the waiting rows are untouched
UPDATE sub_buy_control SET enforce = true WHERE id;
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, tevo_event_id, ticket_group_id, qty, max_price_ea, sold_ea, market) VALUES ('test','Vivid','E6',1,107,2,50,60,'evo');
INSERT INTO n2s_autobuy_exec (order_number, mode, state, sub_source, sell_market, qty, sub_total_usd, est_tax_usd, sold_total_usd, sub_confirm_by)
VALUES ('N3','live','live_buy','tevo','vivid',2,100,5,150,now()+interval '1 day');
SELECT pg_temp.buy_next('9006'); SELECT pg_temp.n2s_next();
SELECT sale_order_number, state FROM manual_sub_buy WHERE sale_order_number = 'E6';
SELECT order_number, coalesce(phase, 'not started') FROM n2s_autobuy_exec WHERE order_number = 'N3';
\echo a buy already placed is still followed while the stop is on
UPDATE n2s_autobuy_exec SET lease_until = NULL WHERE order_number = 'N1';
SELECT pg_temp.n2s_next();
UPDATE n2s_autobuy_exec SET lease_until = now() + interval '1 hour' WHERE order_number = 'N1';
\echo stop off, a ceiling 50 above what both have spent today: neither 100 buy fits
UPDATE sub_buy_control SET stop = false WHERE id;
SELECT 'spent today by both buyers: ' || sub_buy_spent_today();
UPDATE sub_buy_control SET daily_ceiling_usd = sub_buy_spent_today() + 50 WHERE id;
SELECT pg_temp.n2s_next(); SELECT pg_temp.buy_next('9006');
SELECT sale_order_number, state, array_to_string(reasons, ',') FROM manual_sub_buy WHERE sale_order_number = 'E6';
\echo a buy with no known total never passes a ceiling
SELECT sub_buy_gate('gotickets', NULL);
\echo ceiling raised: the N2S buy is handed out and spends its run
UPDATE sub_buy_control SET daily_ceiling_usd = 100000 WHERE id;
SELECT pg_temp.n2s_next();

\echo one feed of what both buyers bought
UPDATE sub_finder_config SET enabled = true, key_ids = '{7}', autobuys_key_ids = '{7}' WHERE id;
SELECT sub_finder_buys(8)->>'detail';
SELECT 'count ' || (j->>'count') || ', total ' || (j->>'total') FROM sub_finder_buys(7) j;
SELECT i->>'buyer', i->>'buy_ref', i->>'status', i#>>'{for_order,ref}', i#>>'{bought,qty}', i#>>'{totals,charged_usd}', i#>>'{totals,margin_usd}', coalesce(i->>'reasons','')
  FROM jsonb_array_elements(sub_finder_buys(7)->'items') i ORDER BY 1, 2;
SELECT i#>>'{event,name}', i#>>'{event,local_start}', i#>>'{bought,listing_id}', i->>'phase'
  FROM jsonb_array_elements(sub_finder_buys(7)->'items') i WHERE i->>'buy_ref' = 'evo-9001';
\echo a confirmation by the seller moves changed_at (the cursor of the feed), not updated_at (the spend day)
SELECT changed_at > updated_at FROM manual_sub_buy WHERE buy_id = 2;
SELECT 'changed since a minute from now: ' || (sub_finder_buys(7, now() + interval '1 minute')->>'total');
SELECT 'page of 2 from the third: ' || (j->>'count') || ' of ' || (j->>'total') FROM sub_finder_buys(7, NULL, 2, 2) j;
