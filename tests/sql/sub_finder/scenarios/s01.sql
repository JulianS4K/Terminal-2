\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events VALUES (3241050,'Kansas State Wildcats at TCU Horned Frogs Football','2026-11-14 00:00'),
 (1,'Twin Bill','2026-11-14 13:00'),(2,'Twin Bill','2026-11-14 19:00');
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (3241050,6833175743,'217','D',2,65.98,'{2}',false,false),
 (3241050,6833175913,'134','G',4,74.10,'{4}',false,false),
 (3241050,111,'217','A',2,10.00,'{2}',true,false),
 (3241050,112,'217','B',2,11.00,'{2}',false,true),
 (3241050,113,'134','M',3,50.00,'{1,3}',false,false),
 (3241050,114,'134','R',3,5.00,'{3}',false,false),
 (3241050,115,'217','E',6,1.00,'{2,4,6}',false,false);
UPDATE n2s_evo_current SET retail_price = 0 WHERE tevo_ticket_group_id = 115;
INSERT INTO n2s_gt_current (tevo_event_id,gt_event_id,gt_listing_id,section,row,quantity,all_in_price,splits) VALUES (3241050,1353401,900,'217','G',4,60,'{2,4}');
INSERT INTO sg_events_canonical VALUES (18024494,'https://seatgeek.com/tcu/18024494');
INSERT INTO n2s_sg_current (tevo_event_id,sg_event_id,display_id,sglid,section,row,quantity,retail_price_all_in,splits,is_broker_owned) VALUES
 (3241050,18024494,'A6rs2KO4wGY',500,'217','C',2,70,'[2]',false),
 (3241050,18024494,NULL,501,'217','F',2,71,'[2]',false),
 (3241050,18024494,'x',502,'217','A',2,1,'[2]',true);
\echo 1 disabled:
SELECT sub_finder_submit(7,'crm','[{"order_number":"a","tevo_event_id":3241050,"section":"1","row":"1","qty":1}]')->>'error';
UPDATE sub_finder_config SET enabled=true, key_ids='{7}';
\echo 2 other key / bad payloads:
SELECT sub_finder_submit(8,'x','[]')->>'error', sub_finder_submit(7,'crm','[]')->>'error', sub_finder_submit(7,'crm','{}')->>'error';
UPDATE sub_finder_config SET max_orders_per_job=1;
SELECT sub_finder_submit(7,'crm','[{},{}]')->>'detail';
UPDATE sub_finder_config SET max_orders_per_job=200;
\echo 3 submit:
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[
 {"order_number":"659213629","site":"Viagogo","tevo_event_id":3241050,"section":"217","row":"G","qty":2,"sold_ea":125.72},
 {"order_number":"659240801","site":"Viagogo","event_name":"kansas state wildcats at tcu horned frogs football","event_date":"2026-11-14","section":"134","row":"K","qty":3,"sold_ea":118.81},
 {"order_number":"X1","tevo_event_id":3241050,"section":"999","row":"1","qty":2,"sold_ea":50},
 {"order_number":"U1","event_name":"No Such Game","event_date":"2026-11-14","section":"1","row":"1","qty":1},
 {"order_number":"U2","event_name":"Twin Bill","event_date":"2026-11-14","section":"1","row":"1","qty":1},
 {"order_number":"U3","tevo_event_id":424242,"section":"1","row":"1","qty":1},
 {"order_number":"N1","tevo_event_id":3241050,"section":"217","row":"G","qty":2}]'::jsonb,'idem-1') AS r;
SELECT r - 'job_id' - 'created_at' FROM j;
SELECT 'replay same job: ' || ((sub_finder_submit(7,'crm','[{"order_number":"zz","tevo_event_id":1,"section":"1","row":"1","qty":1}]','idem-1')->>'job_id') = (SELECT r->>'job_id' FROM j))::text;
SELECT 'pull rows: ' || count(*) FROM n2s_mkt_pull;
\echo 4 too early / pulls out / done:
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j))->>'status';
UPDATE sub_finder_config SET settle_min_s=0;
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j))->>'status';
UPDATE n2s_mkt_pull SET resolved_at=now();
SELECT sub_finder_job_json(8,(SELECT (r->>'job_id')::uuid FROM j)) IS NULL AS other_key_forbidden_or_null, sub_finder_job_json(8,(SELECT (r->>'job_id')::uuid FROM j));
CREATE TEMP TABLE o AS SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j)) AS r;
SELECT r->>'status', r->'summary' FROM o;
SELECT i->>'order_number', i->>'state', i->'best'->>'market', i->'best'->>'listing_id', i->'best'->>'row', i->'best'->>'row_relation', i->'best'->>'buy_qty', i->'best'->>'spare', i->'best'->>'total', i->'best'->>'profit', jsonb_array_length(i->'covers') FROM o, jsonb_array_elements(r->'items') i;
\echo 5 covers for 659213629 (market,listing,row,rel,price,link):
SELECT c->>'market', c->>'listing_id', c->>'row', c->>'row_relation', c->>'price_ea', c->>'buyable', coalesce(c->>'link','NULL') FROM o, jsonb_array_elements(r->'items') i, jsonb_array_elements(i->'covers') c WHERE i->>'order_number'='659213629';
\echo 5b covers for 659240801:
SELECT c->>'market', c->>'listing_id', c->>'row', c->>'row_relation', c->>'buy_qty', c->>'profit' FROM o, jsonb_array_elements(r->'items') i, jsonb_array_elements(i->'covers') c WHERE i->>'order_number'='659240801';
\echo 6 results feed:
SELECT x->>'count', x->>'total', x->>'limit', x->>'offset', (x->>'generated_at') ~ 'Z$' FROM (SELECT sub_finder_results(7,NULL,2,0) x) q;
SELECT x->>'count', x->>'total' FROM (SELECT sub_finder_results(7, now() + interval '1 hour') x) q;
SELECT sub_finder_results(8)->>'error';
\echo 7 buy:
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'659240801','6833175913','dana')->>'error';
UPDATE sub_finder_config SET buy_enabled=true;
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'659240801','6833175913','dana')->>'error';
UPDATE sub_finder_config SET buy_key_ids='{7}';
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'nope','1')->>'error';
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'659213629','900')->>'detail';
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'659213629','114')->>'detail';
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'659240801','6833175913','dana') - 'buy_id';
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'659240801','6833175913')->>'detail';
SELECT sale_site, sale_order_number, tevo_event_id, ticket_group_id, qty, max_price_ea, sold_ea, state, requested_by, note FROM manual_sub_buy;
\echo 7b a sale already bought outside this API:
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, tevo_event_id, ticket_group_id, qty, max_price_ea) VALUES ('operator','viagogo','659213629',3241050,6833175743,2,65.98);
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'659213629','6833175743')->>'detail';
\echo 8 buy shows on the order + moved the sync cursor:
SELECT i->'buy'->>'request_state', i->'buy'->>'outcome', i->'markets_searched' FROM (SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j)) r) q, jsonb_array_elements(r->'items') i WHERE i->>'order_number'='659240801';
\echo 9 timeout settles with what we have:
UPDATE sub_finder_config SET settle_timeout_s=0;
CREATE TEMP TABLE j2 AS SELECT sub_finder_submit(7,'crm','[{"order_number":"T1","tevo_event_id":3241050,"section":"217","row":"G","qty":2,"sold_ea":100}]') r;
SELECT sub_finder_results(7,NULL,1000,0)->>'total';
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j2))->>'status';
\echo 10 dup order numbers in one job cannot be bought:
CREATE TEMP TABLE j3 AS SELECT sub_finder_submit(7,'crm','[{"order_number":"D","tevo_event_id":3241050,"section":"217","row":"G","qty":2},{"order_number":"D","tevo_event_id":3241050,"section":"217","row":"G","qty":2}]') r;
SELECT sub_finder_buy(7,'crm',(SELECT (r->>'job_id')::uuid FROM j3),'D','6833175743')->>'error';
