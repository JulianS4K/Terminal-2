\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id)
 SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(10,22) g;
INSERT INTO zone_stub VALUES (5,6,'101','Lower'),(5,6,'102','Lower');
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,view_type) VALUES
 (10,1001,'101','8',2,80,'{2}',false,false,NULL),          -- G1 gate 1 -> auto buy
 (10,1002,'102','3',2,50,'{2}',false,false,NULL),          -- zone listing: hidden, G1 has a strict cover
 (11,1101,'102','1',2,90,'{2}',false,false,NULL),          -- W gate 3
 (11,1102,'102','5',2,150,'{2}',false,false,NULL),         -- W gate 6
 (11,1103,'102','2',2,500,'{2}',false,false,NULL),         -- W over 200, moved: not shown
 (11,1104,'301','1',2,10,'{2}',false,false,NULL),          -- W no zone: not shown
 (12,1201,'301','8',2,80,'{2}',false,false,NULL),          -- U gate 5 zone unverified
 (13,1301,'101','5',3,60,'{3}',false,false,NULL),          -- S spare ticket
 (14,1401,'101','5',2,80,'{2}',false,false,'Obstructed View'), -- O obstructed
 (15,1501,'101','5',2,95,'{2}',false,false,NULL),          -- T thin profit
 (16,1601,'101','5',2,80,'{2}',false,false,NULL),          -- N / N2 n2s orders
 (17,1701,'101','5',2,450,'{2}',false,false,NULL),         -- R over 200
 (18,1801,'101','5',1,80,'{1}',false,false,NULL),          -- Q single
 (18,1802,'101','4',2,80,'{2}',false,false,NULL),          -- P no sale price
 (19,1901,'101','5',2,400,'{2}',false,false,NULL),         -- C1 800
 (19,1902,'102','5',2,100,'{2}',false,false,NULL),         -- C2 over cap
 (21,2101,'101','5',2,80,'{2}',false,false,NULL),          -- B already bought
 (22,2201,'101','5',2,80,'{2}',false,false,NULL);          -- OFF job
INSERT INTO n2s_gt_current (tevo_event_id,gt_event_id,gt_listing_id,section,row,quantity,all_in_price,splits) VALUES
 (11,1,9101,'102','2',2,120,'{2}'),                        -- W gate 4
 (20,1,9201,'101','5',2,80,'{2}');                         -- K gotickets-only gate 1
INSERT INTO sg_events_canonical VALUES (77,'https://seatgeek.com/x/77');
INSERT INTO n2s_sg_current (tevo_event_id,sg_event_id,display_id,sglid,section,row,quantity,retail_price_all_in,splits,is_broker_owned) VALUES
 (11,77,'d',9301,'102','4',2,70,'[2]',false);              -- W gate 5
INSERT INTO n2s_items (n2s_id,order_number,n2s_order_key,marketplace,tevo_event_id,section,row,qty,price_per_ticket,timer_expires_at,timer_expired)
 VALUES (1,'N','N','StubHub',16,'101','5',2,100, now() + interval '10 min', false),
        (2,'NX','NX','StubHub',16,'101','5',2,100, now() - interval '10 min', true);   -- timer closed: not N2S's any more
INSERT INTO n2s_autobuy_exec (order_number) VALUES ('N2');
INSERT INTO manual_sub_buy (requested_by,sale_site,sale_order_number,ticket_group_id,qty,max_price_ea) VALUES ('op','CRM','B',1,2,10);
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','G1',10,'101','10',2,100),('StubHub','S',13,'101','5',2,100),('StubHub','O',14,'101','5',2,100),('StubHub','T',15,'101','5',2,100),
 ('StubHub','C1',19,'101','5',2,600),('StubHub','C2',19,'102','5',2,300),('StubHub','B',21,'101','5',2,100),
 ('StubHub','LIE',21,'101','5',2,50),('StubHub','DONE',21,'101','5',2,100),('StubHub','TWO',21,'101','5',2,100),('Vivid','TWO',21,'101','5',2,100),('StubHub','SITE',21,'101','5',2,100);
INSERT INTO v_sub_orders VALUES ('StubHub','DONE','cancelled',false),('StubHub','G1','open',true);
UPDATE v_s4kcs_orders SET order_status='Cancelled' WHERE s4k_order_id='DONE';   -- our book says 50; the caller will claim 100
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0;
\echo 1 auto buy off:
CREATE TEMP TABLE j0 AS SELECT sub_finder_submit(7,'crm','[{"order_number":"OFF","tevo_event_id":22,"section":"101","row":"5","qty":2,"sold_ea":100}]') AS r;
SELECT i->>'order_number', i->>'state', i->>'action', i->>'auto_buy_note', i->'best'->>'gate', i->'best'->>'label', i->'buy'
 FROM (SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j0)) r) o, jsonb_array_elements(r->'items') i;
UPDATE sub_finder_config SET auto_buy_enabled=true;
\echo 2 main job:
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[
 {"order_number":"G1","site":"StubHub","tevo_event_id":10,"section":"101","row":"10","qty":2,"sold_ea":100},
 {"order_number":"W","tevo_event_id":11,"section":"101","row":"2","qty":2,"sold_ea":100},
 {"order_number":"U","tevo_event_id":12,"section":"301","row":"5","qty":2,"sold_ea":100},
 {"order_number":"S","tevo_event_id":13,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"O","tevo_event_id":14,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"T","tevo_event_id":15,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"N","tevo_event_id":16,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"N2","tevo_event_id":16,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"R","tevo_event_id":17,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"Q","tevo_event_id":18,"section":"101","row":"5","qty":1,"sold_ea":70},
 {"order_number":"P","tevo_event_id":18,"section":"101","row":"5","qty":2},
 {"order_number":"C1","tevo_event_id":19,"section":"101","row":"5","qty":2,"sold_ea":600},
 {"order_number":"C2","tevo_event_id":19,"section":"102","row":"5","qty":2,"sold_ea":300},
 {"order_number":"K","tevo_event_id":20,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"B","tevo_event_id":21,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"LIE","tevo_event_id":21,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"DONE","tevo_event_id":21,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"TWO","tevo_event_id":21,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"SITE","site":"Vivid","tevo_event_id":21,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"GHOST","tevo_event_id":21,"section":"101","row":"5","qty":2,"sold_ea":100},
 {"order_number":"Z","tevo_event_id":21,"section":"999","row":"5","qty":2,"sold_ea":100}]') AS r;
UPDATE n2s_mkt_pull SET resolved_at=now();
CREATE TEMP TABLE o AS SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j)) AS r;
SELECT r->>'status' FROM o;
SELECT i->>'order_number', i->>'state', i->>'action', coalesce(i->>'auto_buy_note','-'), coalesce(i->'best'->>'gate','-'), coalesce(i->'best'->>'label','-'),
       coalesce(i->'best'->>'needs_buyer_ok','-'), coalesce(i->'buy'->>'request_state','-')
 FROM o, jsonb_array_elements(r->'items') i;
\echo 3 covers of W (gate order) and G1 (no zone cover shown):
SELECT i->>'order_number', c->>'market', c->>'listing_id', c->>'gate', c->>'label', c->>'row_relation', c->>'zone', c->>'needs_buyer_ok'
 FROM o, jsonb_array_elements(r->'items') i, jsonb_array_elements(i->'covers') c WHERE i->>'order_number' IN ('W','G1','U','O');
\echo 4 buys filed:
SELECT sale_site, sale_order_number, ticket_group_id, qty, max_price_ea, sold_ea, requested_by, state, note FROM manual_sub_buy ORDER BY buy_id;
\echo 5 rerun does not buy again, thin-profit bought at 0 pct, cap holds:
SELECT sub_finder_autobuy((SELECT (r->>'job_id')::uuid FROM j));
UPDATE sub_finder_config SET auto_buy_min_profit_pct=0;
SELECT sub_finder_autobuy((SELECT (r->>'job_id')::uuid FROM j));
SELECT order_number, action, coalesce(auto_buy_note,'-') FROM sub_finder_order WHERE order_number IN ('T','C2','G1') AND job_id=(SELECT (r->>'job_id')::uuid FROM j) ORDER BY 1;
SELECT 'auto spend today: ' || sum(max_price_ea*qty) FROM manual_sub_buy WHERE requested_by LIKE 'sub finder auto%';
\echo 6 closed N2S timer is still N2S; a stopped auto buy is not retried; not-watching is skipped:
UPDATE sub_finder_config SET auto_buy_daily_cap_usd=5000;
UPDATE manual_sub_buy SET state='stopped' WHERE sale_order_number='G1';
CREATE TEMP TABLE j2 AS SELECT sub_finder_submit(7,'crm','[{"order_number":"NX","tevo_event_id":16,"section":"101","row":"5","qty":2,"sold_ea":100}]') AS r;
SELECT order_number, action, coalesce(auto_buy_note,'-'), buy_id IS NOT NULL FROM sub_finder_order WHERE job_id=(SELECT (r->>'job_id')::uuid FROM j2);
SELECT sub_finder_autobuy((SELECT (r->>'job_id')::uuid FROM j));
SELECT count(*) FROM manual_sub_buy WHERE sale_order_number='G1';
SELECT order_number, watching, action, coalesce(auto_buy_note,'-') FROM sub_finder_order WHERE order_number='C2';
