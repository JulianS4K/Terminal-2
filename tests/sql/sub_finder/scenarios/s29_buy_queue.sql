\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- One buyer: the N2S auto-buyer files its buys into the queue (mig 20261113440000).
-- Stand-ins for the two functions lane D7 ships: they record what they were told.
CREATE TABLE n2s_told (n serial, exec_id bigint, state text, patch jsonb);
CREATE FUNCTION public.n2s_autobuy_queue_result(p_exec_id bigint, p_state text, p_patch jsonb) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO n2s_told (exec_id, state, patch) VALUES (p_exec_id, p_state, p_patch);
  IF p_state = 'unknown' THEN UPDATE n2s_autobuy_config SET kill_switch = true; END IF;
  RETURN p_state;
END $$;
CREATE FUNCTION public.n2s_autobuy_queue_job(p_exec_id bigint) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('action', 'buy', 'row', jsonb_build_object('exec_id', p_exec_id), 'cfg', jsonb_build_object('daily_cap_usd', 500)) $$;
CREATE FUNCTION pg_temp.take(p_can text[]) RETURNS text LANGUAGE plpgsql AS $$
DECLARE j jsonb := CASE WHEN p_can IS NULL THEN manual_sub_buy_claim() ELSE manual_sub_buy_claim_for(p_can) END;
BEGIN
  RETURN coalesce((j#>>'{row,sale_order_number}') || ' (' || (j#>>'{row,origin}') || ', ' || (j#>>'{row,market}') || ')'
                  || coalesce(', N2S job for exec ' || (j#>>'{n2s,row,exec_id}'), ''), 'nothing handed out');
END $$;
CREATE FUNCTION pg_temp.rec(p_order text, p_patch jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT manual_sub_buy_record(buy_id, lease_token, p_patch) FROM manual_sub_buy WHERE sale_order_number = p_order AND state = 'buying' $$;
CREATE FUNCTION pg_temp.told() RETURNS SETOF text LANGUAGE sql AS $$
  SELECT 'N2S was told: exec ' || exec_id || ' ' || state || ' ' || patch::text FROM n2s_told ORDER BY n $$;
UPDATE manual_sub_buy_config SET enabled = true, gt_enabled = true, per_order_cap_usd = 750, daily_cap_usd = 4000 WHERE id;
UPDATE n2s_autobuy_config SET mode = 'live', kill_switch = false, min_confirm_window_s = 60 WHERE id;
INSERT INTO n2s_gt_order_dryrun (dryrun_id, gt_event_id) VALUES (7, 9001);
INSERT INTO n2s_autobuy_exec (exec_id, order_number, mode, state, sub_source, sub_listing_id, sell_market, qty, sub_total_usd, est_tax_usd, sold_total_usd, sub_confirm_by, seller_window_in_hand_s, dryrun_id, tevo_event_id, event_name) VALUES
 (1,'N1','live','live_buy','tevo','5001','vivid',2,200,10,260,now()+interval '2 hours',600,NULL,1,'Game'),
 (2,'N2','live','live_buy','gotickets','5002','vivid',2,100,0,150,now()+interval '2 hours',NULL,7,1,'Game'),
 (3,'M1','live','live_buy','tevo','5003','vivid',2,100,5,150,now()+interval '2 hours',NULL,NULL,1,'Game'),
 (4,'N4','live','live_buy','tevo','5004','vivid',2,100,5,150,now()+interval '30 seconds',NULL,NULL,1,'Game'),
 (5,'N5','live','live_buy','tevo','abc','vivid',2,100,5,150,now()+interval '2 hours',NULL,NULL,1,'Game'),
 (6,'N6','live','live_buy','tevo','5006','vivid',2,100,5,150,now()+interval '2 hours',NULL,NULL,1,'Game'),
 (7,'N7','live','live_buy','tevo','5007','vivid',2,100,5,150,now()+interval '2 hours',NULL,NULL,1,'Game'),
 (8,'N8','live','live_buy','tevo','5008','vivid',2,100,5,150,now()+interval '2 hours',NULL,NULL,1,'Game'),
 (9,'N9','shadow','shadow_buy','tevo','5009','vivid',2,100,5,150,now()+interval '2 hours',NULL,NULL,1,'Game');
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, tevo_event_id, ticket_group_id, qty, max_price_ea, sold_ea, market, created_at) VALUES
 ('test','Vivid','M1',1,101,2,50,60,'evo',now()-interval '10 min'), ('test','Vivid','M2',1,102,2,50,60,'evo',now()-interval '9 min'),
 ('test','Vivid','M3',1,103,2,50,60,'evo',now()-interval '8 min');

\echo N2S files a buy: one row per exec row, with its ceiling and the last instant it may be sent
SELECT manual_sub_buy_file_n2s(1) IS NOT NULL;
SELECT sale_site, sale_order_number, market, origin, n2s_exec_id, ticket_group_id, qty, max_price_ea, max_total_usd, requested_by,
       round(extract(epoch FROM (buy_by - now())) / 60) || ' min left' FROM manual_sub_buy WHERE origin = 'n2s';
\echo not filed: the same exec row again, a sale that already has a live buy, a listing id that is not a number, a row out of time, a row that is not live, no such row
SELECT coalesce(manual_sub_buy_file_n2s(1)::text, 'no') || ' ' || coalesce(manual_sub_buy_file_n2s(3)::text, 'no') || ' ' || coalesce(manual_sub_buy_file_n2s(5)::text, 'no')
       || ' ' || coalesce(manual_sub_buy_file_n2s(4)::text, 'no') || ' ' || coalesce(manual_sub_buy_file_n2s(9)::text, 'no') || ' ' || coalesce(manual_sub_buy_file_n2s(99)::text, 'no');
\echo the caller may pass its own deadline and ceiling
SELECT manual_sub_buy_file_n2s(2, now() + interval '20 minutes', 123.45) IS NOT NULL;
SELECT sale_order_number, market, gt_event_id, max_total_usd, round(extract(epoch FROM (buy_by - now())) / 60) FROM manual_sub_buy WHERE n2s_exec_id = 2;

\echo a worker that does not know N2S rows gets only the buys of this path
SELECT pg_temp.take(NULL); SELECT pg_temp.rec('M1', '{"state":"bought","buy_order_id":"9001","bought_total_usd":100}');
\echo a worker that does gets the N2S buy first, though M2 was asked for earlier; the N2S job comes from N2S
SELECT pg_temp.take('{n2s}');
\echo one buy at a time, whoever it is for
SELECT pg_temp.take('{n2s}');
\echo its result goes to N2S in the same step; the kill switch of this path is untouched
SELECT pg_temp.rec('N1', '{"state":"buying","quote_total_usd":210}');
SELECT pg_temp.rec('N1', '{"state":"bought","buy_order_id":"7001","bought_total_usd":212,"n2s":{"buy_order_id":"7001","buy_total_usd":"212.00"}}');
SELECT pg_temp.told();
SELECT 'our kill switch: ' || kill_switch FROM manual_sub_buy_config;

\echo this path switched off: an N2S buy still goes (its own switches decide)
UPDATE manual_sub_buy_config SET enabled = false WHERE id;
SELECT pg_temp.take('{n2s}'); SELECT pg_temp.rec('N2', '{"state":"stopped","reasons":["listing_gone"]}');
SELECT pg_temp.take('{n2s}');
UPDATE manual_sub_buy_config SET enabled = true WHERE id;
\echo the N2S kill switch set after filing: its buy waits, ours goes
SELECT manual_sub_buy_file_n2s(6) IS NOT NULL;
UPDATE n2s_autobuy_config SET kill_switch = true WHERE id;
SELECT pg_temp.take('{n2s}'); SELECT pg_temp.rec('M2', '{"state":"bought","buy_order_id":"9002","bought_total_usd":100}');
\echo the N2S stop for EVO, N2S not live, the shared stop: each holds the N2S buy (this path is off here, so nothing else can go)
UPDATE manual_sub_buy_config SET enabled = false WHERE id;
UPDATE n2s_autobuy_config SET kill_switch = false, project_stopped = true WHERE id; SELECT pg_temp.take('{n2s}');
UPDATE n2s_autobuy_config SET project_stopped = false, mode = 'shadow' WHERE id; SELECT pg_temp.take('{n2s}');
UPDATE n2s_autobuy_config SET mode = 'live' WHERE id;
UPDATE sub_buy_control SET enforce = true, stop = true WHERE id; SELECT pg_temp.take('{n2s}');
UPDATE sub_buy_control SET enforce = false, stop = false WHERE id;
\echo past its deadline it is stopped unsent, and N2S is told so the run goes back
DELETE FROM n2s_told;
UPDATE manual_sub_buy SET buy_by = now() - interval '1 second' WHERE sale_order_number = 'N6';
SELECT pg_temp.take('{n2s}');
SELECT sale_order_number, state, array_to_string(reasons, ',') FROM manual_sub_buy WHERE sale_order_number = 'N6';
SELECT pg_temp.told();
UPDATE manual_sub_buy_config SET enabled = true WHERE id;
SELECT pg_temp.take('{n2s}'); SELECT pg_temp.rec('M3', '{"state":"stopped","reasons":["listing_gone"]}');

\echo an N2S buy with no clear answer: N2S is told (its kill switch), ours is not flipped
DELETE FROM n2s_told;
SELECT manual_sub_buy_file_n2s(7) IS NOT NULL, manual_sub_buy_file_n2s(8) IS NOT NULL;
SELECT pg_temp.take('{n2s}'); SELECT pg_temp.rec('N7', '{"state":"unknown","error":"timeout"}');
SELECT pg_temp.told();
SELECT 'our kill switch: ' || (SELECT kill_switch FROM manual_sub_buy_config) || ', N2S kill switch: ' || (SELECT kill_switch FROM n2s_autobuy_config);
\echo it holds back other N2S buys even with the N2S switch cleared, but not ours
UPDATE n2s_autobuy_config SET kill_switch = false WHERE id;
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, tevo_event_id, ticket_group_id, qty, max_price_ea, sold_ea, market) VALUES ('test','Vivid','M4',1,104,2,50,60,'evo');
SELECT pg_temp.take('{n2s}');
\echo and one of ours with no clear answer flips our switch and holds ours back, not N2S
SELECT pg_temp.rec('M4', '{"state":"unknown","error":"timeout"}');
UPDATE manual_sub_buy SET state = 'stopped' WHERE sale_order_number = 'N7';
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, tevo_event_id, ticket_group_id, qty, max_price_ea, sold_ea, market) VALUES ('test','Vivid','M5',1,105,2,50,60,'evo');
SELECT 'our kill switch: ' || kill_switch FROM manual_sub_buy_config;
SELECT pg_temp.take('{n2s}');
\echo a worker lost in the middle of an N2S buy: unknown, N2S is told, nothing is handed out
DELETE FROM n2s_told;
UPDATE manual_sub_buy SET lease_until = now() - interval '1 second' WHERE sale_order_number = 'N8';
SELECT pg_temp.take('{n2s}');
SELECT sale_order_number, state, array_to_string(reasons, ',') FROM manual_sub_buy WHERE sale_order_number = 'N8';
SELECT pg_temp.told();

\echo following, alerts, the feed and the shared counts leave an N2S buy to its own row
CREATE FUNCTION pg_temp.followed() RETURNS text LANGUAGE plpgsql AS $$
DECLARE j jsonb := manual_sub_buy_follow_claim();
BEGIN RETURN 'followed: ' || coalesce((SELECT sale_order_number FROM manual_sub_buy WHERE buy_id = (j->>'buy_id')::bigint), 'nothing'); END $$;
SELECT pg_temp.followed(); SELECT pg_temp.followed(); SELECT pg_temp.followed();
UPDATE sub_finder_config SET enabled = true, key_ids = '{7}', autobuys_key_ids = '{7}' WHERE id;
SELECT 'in the feed from this path: ' || string_agg(i->>'buy_ref', ', ' ORDER BY i->>'buy_ref') FROM jsonb_array_elements(sub_finder_buys(7)->'items') i;
SELECT 'bought rows by origin: ' || string_agg(origin || ' ' || n, ', ' ORDER BY origin) FROM (SELECT origin, count(*) n FROM manual_sub_buy WHERE state = 'bought' GROUP BY 1) q;
SELECT 'spent today, counted once: ' || sub_buy_spent_today();
UPDATE manual_sub_buy_config SET alerts_enabled = true WHERE id;
SELECT 'alerts sent: ' || (manual_sub_buy_alert_tick() + manual_sub_buy_alert_tick());
SELECT 'alerted, by origin: ' || string_agg(origin || ' ' || n, ', ' ORDER BY origin)
  FROM (SELECT origin, count(*) FILTER (WHERE coalesce(alerted_bought_at, alerted_unknown_at) IS NOT NULL) n FROM manual_sub_buy GROUP BY 1) q;
