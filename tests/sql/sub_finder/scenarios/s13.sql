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
UPDATE sub_finder_config SET gt_offer_enabled=true, gt_offer_key_ids='{7}', refresh_enabled=true, refresh_pull=true WHERE id;
\echo submit pulled with the SeatGeek flag:
SELECT sg, cardinality(evs) FROM band_log;
TRUNCATE band_log;
SELECT sub_finder_gt_offer_request(7,'crm','1001','3001','evo','dana')->>'state';
\echo live helper (1001 yes, 1002 no):
SELECT sub_finder_offer_pending('1001',7), sub_finder_offer_pending('1002',7), sub_finder_offer_pending('1001',8);
-- cheaper seats land for events 30 and 31, and 1006 (StubHub, also event 30) is still watched
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,pulled_at) VALUES
 (30,3002,'102','1',2,50,'{2}',false,false, now() + interval '1 second'), (31,3102,'102','2',2,60,'{2}',false,false, now() + interval '1 second');
SELECT sub_finder_refresh() - 'closed';
\echo pull: SeatGeek flag true; event 30 still pulled (order 1006 watches it):
SELECT sg, (SELECT array_agg(e ORDER BY e) FROM unnest(evs) e) FROM band_log;
\echo 1001 (offer out) keeps listing 3001; 1002 and 1006 moved to the cheaper seats:
SELECT order_number, best->>'listing_id', refreshed_at IS NOT NULL FROM sub_finder_order WHERE order_number IN ('1001','1002','1006') ORDER BY 1;
\echo an event watched ONLY by an offered order is not pulled:
UPDATE sub_finder_order SET watching=false WHERE order_number IN ('1006','1007');
TRUNCATE band_log;
SELECT sub_finder_refresh() - 'closed';
SELECT (SELECT array_agg(e ORDER BY e) FROM unnest(evs) e) FROM band_log;
\echo offer denied -> 1001 is polled and re-matched again:
UPDATE sub_finder_gt_offer SET live=false, state='sent', gt_status='DENIED' WHERE order_number='1001';
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,pulled_at) VALUES
 (30,3003,'102','1',2,49,'{2}',false,false, now() + interval '2 second');
TRUNCATE band_log;
SELECT sub_finder_refresh() - 'closed';
SELECT (SELECT array_agg(e ORDER BY e) FROM unnest(evs) e) FROM band_log;
SELECT order_number, best->>'listing_id' FROM sub_finder_order WHERE order_number = '1001';
