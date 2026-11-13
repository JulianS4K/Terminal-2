\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(40,41) g;
INSERT INTO zone_stub VALUES (5,6,'101','Lower'),(5,6,'102','Lower');
-- event 40: only a GoTickets listing in the zone (gate 3). event 41: an EVO listing (gate 3)
INSERT INTO n2s_gt_current (tevo_event_id,gt_event_id,gt_listing_id,section,row,quantity,all_in_price,splits) VALUES (40,4,4001,'102','2',2,90,'{2}');
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES (41,4101,'102','2',2,90,'{2}',false,false),(40,4099,'999','9',2,500,'{2}',false,false);
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('GoTickets','2001',40,'101','2',2,100),('GoTickets','2002',41,'101','2',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, gt_offer_enabled=true, gt_offer_key_ids='{7}', gt_offer_auto_buy=true, refresh_enabled=true, refresh_pull=true WHERE id;
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[{"order_number":"2001"},{"order_number":"2002"}]') AS r;
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j))->>'status';
SELECT order_number, best->>'market', best->>'listing_id', best->>'gate' FROM sub_finder_order ORDER BY 1;
SELECT sub_finder_gt_offer_request(7,'crm','2001','4001')->>'state', sub_finder_gt_offer_request(7,'crm','2002','4101')->>'state';
UPDATE sub_finder_gt_offer SET state='sent', gt_request_id=500+offer_id;
\echo A pending: neither order is polled
TRUNCATE band_log; SELECT sub_finder_refresh() - 'closed'; SELECT count(*) FROM band_log;
\echo B accepted: EVO-offered 2002 is bought at once; GoTickets-offered 2001 has no EVO seats yet
SELECT sub_finder_gt_offer_follow_record(offer_id,'{"gt_status":"ACCEPTED"}') FROM sub_finder_gt_offer ORDER BY offer_id;
SELECT order_number, market, buy_id IS NOT NULL, buy_note, live FROM sub_finder_gt_offer ORDER BY 1;
\echo C accepted orders are polled again
TRUNCATE band_log; SELECT sub_finder_refresh() - 'closed'; SELECT (SELECT array_agg(e ORDER BY e) FROM unnest(evs) e) FROM band_log;
SELECT order_number, buy_note FROM sub_finder_gt_offer WHERE order_number='2001';
SELECT order_number, action, sub_finder_order_json(o)->>'action', jsonb_array_length(sub_finder_order_json(o)->'covers') > 0 FROM sub_finder_order o ORDER BY 1;
SELECT o.order_number, j->>'accepted', j->>'accepted_next', (o.updated_at > now() - interval '1 minute') FROM sub_finder_order o, sub_finder_offer_json(o) j ORDER BY 1;
\echo D offered GoTickets seats still listed -> buy_manually; nothing bought on EVO seats in the offered section
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,pulled_at) VALUES
 (40,4012,'102','1',2,85,'{2}',false,false, now()+interval '1 second');
INSERT INTO n2s_gt_current (tevo_event_id,gt_event_id,gt_listing_id,section,row,quantity,all_in_price,splits,pulled_at) VALUES (40,4,4002,'102','9',2,300,'{2}', now()+interval '1 second');
SELECT sub_finder_refresh() - 'closed';
SELECT o.order_number, sub_finder_order_json(o)->>'action', j->>'offered_gone', j->>'accepted_next', j->'new_best' FROM sub_finder_order o, sub_finder_offer_json(o) j WHERE order_number='2001';
SELECT count(*) FROM manual_sub_buy WHERE sale_order_number='2001';
\echo E offered seats gone, only other-section covers -> new_sub_needed with the new best and gate, no buy
DELETE FROM n2s_gt_current WHERE gt_listing_id=4001;
UPDATE n2s_gt_current SET pulled_at = now()+interval '2 second' WHERE tevo_event_id=40;
UPDATE n2s_evo_current SET pulled_at = now()+interval '2 second' WHERE event_id=40;
SELECT sub_finder_refresh() - 'closed';
SELECT o.order_number, sub_finder_order_json(o)->>'action', j->>'offered_gone', j->>'accepted_next', j->'new_best' FROM sub_finder_order o, sub_finder_offer_json(o) j WHERE order_number='2001';
SELECT count(*) FROM manual_sub_buy WHERE sale_order_number='2001';
\echo F a one-to-one EVO cover in the ORIGINAL section appears -> the standing rule buys it
UPDATE sub_finder_config SET auto_buy_enabled=true WHERE id;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,pulled_at) VALUES
 (40,4020,'101','2',2,95,'{2}',false,false, now()+interval '3 second');
SELECT sub_finder_refresh() - 'closed';
SELECT sale_order_number, ticket_group_id, qty, max_price_ea, requested_by FROM manual_sub_buy ORDER BY buy_id;
SELECT o.order_number, sub_finder_order_json(o)->>'action', j->>'accepted_next' FROM sub_finder_order o, sub_finder_offer_json(o) j ORDER BY 1;
\echo G the EVO-offered buy stops (listing gone) -> released, reported
UPDATE manual_sub_buy SET state='stopped', reasons='{listing_gone}' WHERE sale_order_number='2002';
SELECT sub_finder_refresh() - 'closed';
SELECT g.order_number, g.buy_id IS NULL, g.buy_note, o.buy_id IS NULL, j->>'offered_gone', j->>'accepted_next' FROM sub_finder_gt_offer g JOIN sub_finder_order o USING (job_id, idx), sub_finder_offer_json(o) j WHERE g.order_number='2002';
