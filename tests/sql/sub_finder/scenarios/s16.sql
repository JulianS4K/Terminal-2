\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(60,65) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (60,6001,'101','2',1,90,'{1}',false,false),    -- single, exact row
 (61,6101,'101','2',2,90,'{2}',false,false),    -- clean pair
 (62,6201,'101','4',2,70,'{2}',false,false),    -- rows back, no zones: gate 5 zone unverified
 (63,6301,'101','2',3,60,'{3}',false,false),    -- forces a spare
 (64,6401,'101','1',1,90,'{1}',false,false),    -- single, better row
 (65,6501,'101','1',1,90,'{1}',false,false);    -- single, better row, GoTickets order
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','4001',60,'101','2',1,100),('StubHub','4002',61,'101','2',2,100),('GoTickets','4003',62,'101','2',2,100),
 ('StubHub','4004',63,'101','2',2,100),('StubHub','4005',64,'101','2',1,100),('GoTickets','4006',65,'101','2',1,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true, buy_enabled=true, buy_key_ids='{7}', gt_offer_enabled=true, gt_offer_key_ids='{7}' WHERE id;
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[{"order_number":"4001"},{"order_number":"4002"},{"order_number":"4003"},{"order_number":"4004"},{"order_number":"4005"},{"order_number":"4006"}]') AS r;
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j))->>'status';
\echo order | label | flags | bypass | action | auto_buy_note | bought
SELECT order_number, best->>'label', best->'flags', best->>'offer_bypass', action, coalesce(auto_buy_note,'-'), buy_id IS NOT NULL FROM sub_finder_order ORDER BY 1;
\echo CRM bypass on the single in another row: refused without confirm, bought with it
SELECT sub_finder_buy_confirmed(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'4005','6401',NULL,false) - 'detail';
SELECT sub_finder_buy_confirmed(7,'crm',(SELECT (r->>'job_id')::uuid FROM j),'4005','6401','dana',true)->>'state';
\echo GoTickets single in another row: sub_offer asks the CRM, bypass allowed; offer goes through with confirm
SELECT j->>'ask_crm', j->>'bypass_allowed', j->>'gate' FROM sub_finder_order o, sub_finder_offer_json(o) j WHERE order_number='4006';
SELECT sub_finder_gt_offer_confirmed(7,'crm','4006','6501',NULL,NULL,NULL,false)->>'error';
SELECT sub_finder_gt_offer_confirmed(7,'crm','4006','6501',NULL,NULL,NULL,true) - 'offer_id';
\echo a clean gate 1 pair on GoTickets still needs no offer
SELECT sub_finder_gt_offer_confirmed(7,'crm','4003','6201',NULL,NULL,0,false)->>'error';
\echo old covers without the flags key
SELECT sub_finder_cover_flags('{"label":"Index single ticket","row_relation":"better"}'), sub_finder_cover_flags('{"label":"Index single ticket","row_relation":"same"}');
