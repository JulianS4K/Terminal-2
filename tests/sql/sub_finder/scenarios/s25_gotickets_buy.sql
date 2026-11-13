\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- GoTickets covers bought the way EVO covers are (mig 20261113300000). Sales are 100 x2 = 200.
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'G'||g,now()+interval '5 days',999,5 FROM generate_series(110,115) g;
INSERT INTO n2s_gt_current (tevo_event_id,gt_event_id,gt_listing_id,section,row,quantity,all_in_price,splits) VALUES
 (110,9110,51001,'101','2',2,90,'{2}'),      -- only GoTickets has the seats
 (111,9111,51101,'101','2',2,95,'{2}'),      -- EVO is cheaper here
 (112,9112,51201,'101','2',2,85,'{2}'),      -- GoTickets is cheaper here
 (113,NULL,51301,'101','2',2,90,'{2}'),      -- our feed has no GoTickets event id for this row
 (114,9114,51401,'101','2',2,90,'{2}'),      -- the CRM buys this one
 (115,9115,51501,'101','2',2,90,'{2}');      -- over the GoTickets order ceiling later
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (111,11101,'101','2',2,80,'{2}',false,false), (112,11201,'101','2',2,99,'{2}',false,false);
INSERT INTO gotickets_event (gt_event_id, tevo_event_id) VALUES (9113, 113);
INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', g, now() FROM generate_series(110,115) g;
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) SELECT 'StubHub','G'||g,g,'101','2',2,100 FROM generate_series(110,115) g;
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true, buy_enabled=true, buy_key_ids='{7}' WHERE id;
SELECT 'switches start off: ' || (SELECT gt_buy_enabled FROM sub_finder_config) || ' / ' || (SELECT gt_enabled FROM manual_sub_buy_config);

\echo GoTickets buying off: the cover is not buyable, nothing is bought, the CRM buy is refused
CREATE TEMP TABLE j1 AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"G110"}]')->>'job_id')::uuid id;
SELECT sub_finder_job_json(7,(SELECT id FROM j1))->>'status';
SELECT order_number, best->>'market', best->>'gate', best->>'buyable', action, coalesce(auto_buy_note,'-') FROM sub_finder_order WHERE job_id=(SELECT id FROM j1);
SELECT sub_finder_buy(7,'crm',(SELECT id FROM j1),'G110','51001')->>'detail';
SELECT count(*) FROM manual_sub_buy;

\echo one switch alone changes nothing
UPDATE sub_finder_config SET gt_buy_enabled=true WHERE id;
SELECT sub_finder_market_buyable('gotickets'), sub_finder_market_buyable('evo'), sub_finder_market_buyable('stubhub');
\echo both switches on: the same order is bought on GoTickets at the next match
UPDATE manual_sub_buy_config SET gt_enabled=true WHERE id;
SELECT sub_finder_market_buyable('gotickets');
UPDATE sub_finder_order SET rematch=true WHERE job_id=(SELECT id FROM j1);
SELECT sub_finder_scratch() IS NOT NULL, sub_finder_load_native((SELECT id FROM j1)) IS NOT NULL, sub_finder_match((SELECT id FROM j1));
SELECT order_number, best->>'market', best->>'buyable', action, coalesce(auto_buy_note,'-') FROM sub_finder_order WHERE job_id=(SELECT id FROM j1);

\echo the cheapest one-to-one wins, whichever market; a missing GoTickets event id comes from our event map
CREATE TEMP TABLE j2 AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"G111"},{"order_number":"G112"},{"order_number":"G113"}]')->>'job_id')::uuid id;
SELECT sub_finder_job_json(7,(SELECT id FROM j2))->>'status';
SELECT sale_order_number, market, coalesce(gt_event_id::text,'-'), ticket_group_id, qty, max_price_ea, requested_by FROM manual_sub_buy ORDER BY 1;
SELECT sale_order_number, market, manual_sub_buy_total_ceiling(b) FROM manual_sub_buy b WHERE sale_order_number IN ('G110','G111') ORDER BY 1;

\echo the CRM buys a GoTickets cover it was quoted (automatic buying off for this one)
UPDATE sub_finder_config SET auto_buy_enabled=false WHERE id;
CREATE TEMP TABLE j3 AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"G114"},{"order_number":"G115"}]')->>'job_id')::uuid id;
SELECT sub_finder_job_json(7,(SELECT id FROM j3))->>'status';
SELECT sub_finder_buy(7,'crm',(SELECT id FROM j3),'G114','51401','dana') - 'buy_id';
SELECT sub_finder_buy(7,'crm',(SELECT id FROM j3),'G115','51501','dana') - 'buy_id';
SELECT sub_finder_buy(7,'crm',(SELECT id FROM j3),'G115','999')->>'detail';

\echo the worker switch for GoTickets goes off after requests were filed: the GoTickets row stops, nothing is handed out
UPDATE manual_sub_buy_config SET enabled=true, gt_enabled=false, per_order_cap_usd=750, daily_cap_usd=4000, gt_buyer_email='b@x.test', gt_buyer_phone='5550100',
  gt_billing_address='{"firstName":"A"}', gt_recipient='{"firstName":"A"}', gt_gift_card_ids='{28085}' WHERE id;
SELECT manual_sub_buy_claim() IS NULL;
SELECT sale_order_number, state, reasons FROM manual_sub_buy WHERE sale_order_number='G110';

\echo the worker: the EVO row is handed out with the GoTickets buyer details beside the EVO ones
CREATE TEMP TABLE c1 AS SELECT manual_sub_buy_claim() j;
SELECT j->'row'->>'sale_order_number', j->'row'->>'market', j->'cfg' ? 'evo_buyer_office_id', j->'cfg'->>'gt_buyer_email', j->'cfg'->'gt_gift_card_ids' FROM c1;
SELECT manual_sub_buy_record((j->'row'->>'buy_id')::bigint, (j->'row'->>'lease_token')::uuid, '{"state":"bought","buy_order_id":"70001","bought_price_ea":80,"bought_total_usd":160}') FROM c1;

\echo GoTickets on: its own ceilings. EVO spent 160 today; a 170 GoTickets day ceiling still lets a 170 GoTickets buy through
UPDATE manual_sub_buy_config SET gt_enabled=true, gt_daily_cap_usd=170, gt_per_order_cap_usd=175 WHERE id;
CREATE TEMP TABLE c2 AS SELECT manual_sub_buy_claim() j;
SELECT j->'row'->>'sale_order_number', j->'row'->>'market', j->'row'->>'gt_event_id', j->'row'->>'ticket_group_id', j->'row'->>'max_total_usd' FROM c2;
SELECT manual_sub_buy_record((j->'row'->>'buy_id')::bigint, (j->'row'->>'lease_token')::uuid, '{"state":"bought","buy_order_id":"880001","buy_state":"PENDING_CONFIRMATION","bought_price_ea":85,"bought_total_usd":170}') FROM c2;
\echo the next GoTickets rows are over the GoTickets ceilings (day, then order) and stop
SELECT manual_sub_buy_claim() IS NULL;
UPDATE manual_sub_buy_config SET gt_daily_cap_usd=4000 WHERE id;
SELECT manual_sub_buy_claim() IS NULL;
SELECT sale_order_number, market, state, reasons FROM manual_sub_buy ORDER BY 1;

\echo following a bought order: the claim says which market to ask
SELECT j ? 'buy_id', j->>'buy_order_id', j->>'market' FROM (SELECT manual_sub_buy_follow_claim() j) q;
SELECT j ? 'buy_id', j->>'buy_order_id', j->>'market' FROM (SELECT manual_sub_buy_follow_claim() j) q;
SELECT manual_sub_buy_follow_record((SELECT buy_id FROM manual_sub_buy WHERE sale_order_number='G112'), '{"order_state":"MOBILE_QR_DELIVERED","seller_state":"accepted","order_total_usd":170}');

\echo what the CRM reads on each buy
SELECT i->>'order_number', i->'buy'->>'market', i->'buy'->>'order_id', coalesce(i->'buy'->>'evo_order_id','-'), i->'buy'->>'request_state', i->'buy'->>'outcome', i->'buy'->>'total', i->'buy'->>'profit_actual'
 FROM (SELECT sub_finder_job_json(7,(SELECT id FROM j2)) r) o, jsonb_array_elements(r->'items') i ORDER BY 1;

\echo the money alert names the market
SELECT manual_sub_buy_alert_text(b,'bought')->>'subject' FROM manual_sub_buy b WHERE sale_order_number IN ('G111','G112') ORDER BY sale_order_number;

\echo an unknown outcome on a GoTickets buy stops everything and says where to look
UPDATE manual_sub_buy_config SET gt_per_order_cap_usd=666 WHERE id;
UPDATE manual_sub_buy SET state='requested', reasons='{}' WHERE sale_order_number='G114';
CREATE TEMP TABLE c3 AS SELECT manual_sub_buy_claim() j;
SELECT manual_sub_buy_record((j->'row'->>'buy_id')::bigint, (j->'row'->>'lease_token')::uuid, '{"state":"unknown","reasons":["buy_unknown"]}') FROM c3;
SELECT kill_switch, regexp_replace(kill_reason, 'buy \d+', 'buy N') FROM manual_sub_buy_config;
