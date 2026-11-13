\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) VALUES (40,'G',now()+interval '5 days',6,5);
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES (40,4001,'101','2',2,150,'{2}',false,false);
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES ('StubHub','M1',40,'101','2',2,100),('StubHub','M2',40,'101','2',2,100),('StubHub','M3',40,'101','2',2,100),('StubHub','M4',40,'101','2',2,50);
INSERT INTO n2s_items (n2s_id,order_number,n2s_order_key,marketplace,tevo_event_id,section,row,qty,price_per_ticket) VALUES (1,'N1','N1','Vivid Seats',40,'101','2',2,100);
INSERT INTO n2s_autobuy_exec (order_number) VALUES ('M2');
INSERT INTO v_sub_orders VALUES ('StubHub','M3','cancelled',false);
UPDATE v_s4kcs_orders SET order_status='Cancelled' WHERE s4k_order_id='M3';
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, buy_enabled=true, buy_key_ids='{7}';
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"M1"},{"order_number":"N1"},{"order_number":"M2"},{"order_number":"M3"},
 {"order_number":"M4","sold_ea":100},{"order_number":"X1","tevo_event_id":40,"section":"101","row":"2","qty":2,"sold_ea":100}]')->>'job_id')::uuid AS id;
SELECT sub_finder_job_json(7,(SELECT id FROM j))->>'status';
SELECT n, coalesce(r->>'state', r->>'detail') FROM (SELECT n, sub_finder_buy(7,'crm',(SELECT id FROM j),n,'4001','dana') r FROM unnest(ARRAY['M1','N1','M2','M3','M4','X1']) n) q;
SELECT sale_order_number, ticket_group_id, max_price_ea FROM manual_sub_buy ORDER BY 1;
