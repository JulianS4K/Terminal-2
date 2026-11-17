\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(50,52) g;
INSERT INTO zone_stub VALUES (5,6,'101','Lower'),(5,6,'102','Lower');
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (50,5001,'102','2',2,90,'{2}',false,false),(51,5101,'102','2',2,90,'{2}',false,false),(52,5201,'102','2',2,90,'{2}',false,false);
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('GoTickets','3001',50,'101','2',2,100),('GoTickets','3002',51,'101','2',2,100),('GoTickets','3003',52,'101','2',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, gt_offer_enabled=true, gt_offer_key_ids='{7}', refresh_enabled=true, refresh_pull=true WHERE id;
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[{"order_number":"3001"},{"order_number":"3002"},{"order_number":"3003"}]') AS r;
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j))->>'status';
SELECT sub_finder_gt_offer_request(7,'crm','3001','5001')->>'state', sub_finder_gt_offer_request(7,'crm','3002','5101')->>'state', sub_finder_gt_offer_request(7,'crm','3003','5201')->>'state';
UPDATE sub_finder_gt_offer SET state='sent', gt_request_id=500+offer_id;
\echo 3001 denied, sale live -> watched; 3002 denied, worker saw the sale cancelled -> closed; 3003 denied, read failed but our copy says cancelled -> closed
INSERT INTO order_status_xref VALUES ('s4kcs','cancelled','cancelled',true);
UPDATE v_s4kcs_orders SET order_status='cancelled' WHERE s4k_order_id='3003';
SELECT sub_finder_gt_offer_follow_record((SELECT offer_id FROM sub_finder_gt_offer WHERE order_number='3001'),'{"gt_status":"DENIED","sale_checked":true}'),
       sub_finder_gt_offer_follow_record((SELECT offer_id FROM sub_finder_gt_offer WHERE order_number='3002'),'{"gt_status":"DENIED","sale_checked":true,"sale_closed":"cancelled"}'),
       sub_finder_gt_offer_follow_record((SELECT offer_id FROM sub_finder_gt_offer WHERE order_number='3003'),'{"gt_status":"CANCELLED"}');
SELECT order_number, watching, coalesce(closed_reason,'-') FROM sub_finder_order ORDER BY 1;
\echo only the live sale is polled again
TRUNCATE band_log; SELECT sub_finder_refresh() - 'closed'; SELECT evs FROM band_log;
