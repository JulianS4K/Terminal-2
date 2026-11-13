\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(30,34) g;
INSERT INTO zone_stub VALUES (5,6,'101','Lower'),(5,6,'102','Lower');
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (30,3001,'102','1',2,90,'{2}',false,false),    -- A gate 3
 (31,3101,'102','2',2,120,'{2}',false,false),   -- B gate 4
 (32,3201,'102','4',2,70,'{2}',false,false),    -- C gate 5: sale 200, sub 140 -> rebate 60
 (33,3301,'102','5',2,150,'{2}',false,false),   -- D gate 6
 (34,3401,'101','2',2,80,'{2}',false,false);    -- E gate 1
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('GoTickets','1001',30,'101','2',2,100),('GoTickets','1002',31,'101','2',2,100),('GoTickets','1003',32,'101','2',2,100),
 ('GoTickets','1004',33,'101','2',2,100),('GoTickets','1005',34,'101','2',2,100),('StubHub','1006',30,'101','2',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0;
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[{"order_number":"1001"},{"order_number":"1002"},{"order_number":"1003"},{"order_number":"1004"},{"order_number":"1005"},{"order_number":"1006"},
 {"order_number":"1007","site":"GoTickets","tevo_event_id":30,"section":"101","row":"2","qty":2,"sold_ea":100}]') AS r;
\echo 1 sub_offer per order:
SELECT i->>'order_number', i->>'site', i->>'action', coalesce(i->'sub_offer'->>'ask_crm','-'), coalesce(i->'sub_offer'->>'results_only','-'), coalesce(i->'sub_offer'->>'gate','-'), coalesce(i->'sub_offer'->>'listing_id','-'), coalesce(i->'sub_offer'->>'rebate_needed','-') || '/' || coalesce(i->'sub_offer'->>'rebate_suggested','-')
 FROM (SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j)) r) o, jsonb_array_elements(r->'items') i;
\echo 2 refusals: off, wrong gate, not gotickets, unverified, unknown listing, unknown order:
SELECT sub_finder_gt_offer_request(7,'crm','1001','3001')->>'error';
UPDATE sub_finder_config SET gt_offer_enabled=true, gt_offer_key_ids='{7}';
SELECT sub_finder_access(7)->>'offer', sub_finder_access(8)->>'offer';
SELECT sub_finder_gt_offer_request(7,'crm','1004','3301')->>'detail';
SELECT sub_finder_gt_offer_request(7,'crm','1005','3401')->>'detail';
SELECT sub_finder_gt_offer_request(7,'crm','1006','3001')->>'detail';
SELECT sub_finder_gt_offer_request(7,'crm','1007','3001')->>'detail';
SELECT sub_finder_gt_offer_request(7,'crm','1001','999')->>'detail';
SELECT sub_finder_gt_offer_request(7,'crm','4242','1')->>'error';
\echo 3 yes for gates 3, 4, 5; a second yes conflicts:
SELECT sub_finder_gt_offer_request(7,'crm','1001','3001','evo','dana') - 'offer_id';
SELECT sub_finder_gt_offer_request(7,'crm','1002','3101',NULL,NULL,0) - 'offer_id';   -- gate 4, 0 = none
SELECT sub_finder_gt_offer_request(7,'crm','1003','3201') - 'offer_id';   -- gate 5 with no amount: refused, with a suggestion
SELECT sub_finder_gt_offer_request(7,'crm','1003','3201',NULL,NULL,500)->>'detail';   -- more than the sale
SELECT sub_finder_gt_offer_request(7,'crm','1003','3201',NULL,NULL,0) - 'offer_id';
SELECT sub_finder_gt_offer_request(7,'crm','1001','3001')->>'error';
SELECT order_number, gt_order_id, gate, section, seat_row, order_total, sub_total, coalesce(rebate_amount::text,'-'), requested_by, notes FROM sub_finder_gt_offer ORDER BY offer_id;
\echo 4 worker: claim, send, sent; stop; lease lost:
CREATE TEMP TABLE c1 AS SELECT sub_finder_gt_offer_claim() r;
SELECT r->>'order_number', r->>'state', (r->>'lease_token') IS NOT NULL FROM c1;
SELECT sub_finder_gt_offer_record((r->>'offer_id')::bigint, (r->>'lease_token')::uuid, '{"state":"sending"}') FROM c1;
SELECT sub_finder_gt_offer_record((r->>'offer_id')::bigint, gen_random_uuid(), '{"state":"sent"}') FROM c1;
SELECT sub_finder_gt_offer_record((r->>'offer_id')::bigint, (r->>'lease_token')::uuid, '{"state":"sent","gt_request_id":555,"gt_status":"PENDING"}') FROM c1;
CREATE TEMP TABLE c2 AS SELECT sub_finder_gt_offer_claim() r;
SELECT sub_finder_gt_offer_record((r->>'offer_id')::bigint, (r->>'lease_token')::uuid, '{"state":"stopped","reasons":["sale_cancelled"]}') FROM c2;
SELECT order_number, state, live, reasons, gt_request_id, gt_status FROM sub_finder_gt_offer ORDER BY offer_id;
\echo 5 follow: pending (no change), accepted; stopped order can be offered again; stale sending -> unknown:
SELECT sub_finder_gt_offer_follow_claim() - 'offer_id';
SELECT sub_finder_gt_offer_follow_claim() IS NULL;
SELECT sub_finder_gt_offer_follow_record(1,'{"gt_status":"PENDING"}'), sub_finder_gt_offer_follow_record(1,'{"gt_status":"ACCEPTED"}'), sub_finder_gt_offer_follow_record(1,'{}') IS NULL;
SELECT sub_finder_gt_offer_request(7,'crm','1002','3101')->>'state';
CREATE TEMP TABLE c3 AS SELECT sub_finder_gt_offer_claim() r;
SELECT sub_finder_gt_offer_record((r->>'offer_id')::bigint, (r->>'lease_token')::uuid, '{"state":"sending"}') FROM c3;
UPDATE sub_finder_gt_offer SET lease_until = now() - interval '1 min' WHERE state='sending';
UPDATE sub_finder_config SET gt_offer_enabled=false;
SELECT sub_finder_gt_offer_claim() IS NULL;
SELECT order_number, state, live, gt_status, final_at IS NOT NULL FROM sub_finder_gt_offer ORDER BY offer_id;
\echo 5b accepted with auto buy off -> note; on -> EVO buy filed once; spare / cap / gotickets seats are not bought:
SELECT order_number, coalesce(buy_id::text,'-'), coalesce(buy_note,'-') FROM sub_finder_gt_offer WHERE gt_status='ACCEPTED';
UPDATE sub_finder_config SET gt_offer_auto_buy=true, gt_offer_enabled=true;
UPDATE sub_finder_gt_offer SET buy_note=NULL WHERE offer_id=1;
SELECT sub_finder_gt_offer_buy(1), sub_finder_gt_offer_buy(1) IS NULL, sub_finder_gt_offer_buy(2) IS NULL;
SELECT sale_site, sale_order_number, ticket_group_id, qty, max_price_ea, requested_by, note FROM manual_sub_buy;
SELECT order_number, action, buy_id IS NOT NULL FROM sub_finder_order WHERE order_number='1001';
UPDATE sub_finder_gt_offer SET state='sent', gt_request_id=9, gt_status='ACCEPTED', buy_qty=3 WHERE offer_id=3;
SELECT sub_finder_gt_offer_buy(3);
UPDATE sub_finder_gt_offer SET buy_note=NULL, buy_qty=2, market='gotickets' WHERE offer_id=3;
SELECT sub_finder_gt_offer_buy(3);
UPDATE sub_finder_gt_offer SET buy_note=NULL, market='evo' WHERE offer_id=3; UPDATE sub_finder_config SET auto_buy_daily_cap_usd=200;
SELECT sub_finder_gt_offer_buy(3);
UPDATE sub_finder_gt_offer SET buy_note=NULL WHERE offer_id=3; UPDATE sub_finder_config SET auto_buy_daily_cap_usd=1000;
INSERT INTO n2s_autobuy_exec (order_number) VALUES ('1003');
SELECT sub_finder_gt_offer_buy(3);
DELETE FROM n2s_autobuy_exec; UPDATE sub_finder_gt_offer SET buy_note=NULL WHERE offer_id=3; UPDATE sub_finder_config SET enabled=false;
SELECT sub_finder_gt_offer_buy(3);
UPDATE sub_finder_gt_offer SET buy_note=NULL WHERE offer_id=3; UPDATE sub_finder_config SET enabled=true; INSERT INTO v_sub_orders VALUES ('GoTickets','1003','cancelled',false);
UPDATE v_s4kcs_orders SET order_status='Cancelled' WHERE s4k_order_id='1003';
SELECT sub_finder_gt_offer_buy(3);
UPDATE sub_finder_gt_offer SET state='unknown', gt_status=NULL, gt_request_id=NULL, buy_note=NULL WHERE offer_id=3;
\echo 6 order json after:
SELECT i->>'order_number', i->'sub_offer'->>'ask_crm', i->'sub_offer'->'request'->>'state', coalesce(i->'sub_offer'->'request'->>'status','-'), coalesce(i->'sub_offer'->>'rebate','-'), coalesce(i->'sub_offer'->'request'->>'buy','-'), coalesce(i->'buy'->>'request_state','-')
 FROM (SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j)) r) o, jsonb_array_elements(r->'items') i WHERE i->'sub_offer' IS NOT NULL AND i->>'sub_offer' <> 'null';
SELECT sub_finder_gt_offer_record(1, gen_random_uuid(), '{"state":"bogus"}');
