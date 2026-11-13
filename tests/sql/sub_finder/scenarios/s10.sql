\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g,now()+interval '5 days',6,5 FROM generate_series(60,66) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary)
 SELECT g, 6000+g, '101','2',2,80,'{2}',false,false FROM generate_series(60,66) g;
-- GT1: in the GoTickets feed AND the CRM book (CRM has a stale price and no event) -> api wins, event from the feed's map
INSERT INTO gotickets_event VALUES (900,60),(901,NULL);
INSERT INTO gotickets_sales (gt_sale_id,gt_event_id,event_name,event_time_local,venue_name,section,row,quantity,unit_cost,total_payout,seller_status,fulfilled)
 VALUES (7001,900,'GT Game','2026-11-18 19:00','GT Venue','101','2',2,100,200,'PENDING_FULFILLMENT',false),
        (7002,901,'GT Unmapped','2026-11-18 19:00','V','101','2',2,100,200,'PENDING_FULFILLMENT',false),   -- event only in the CRM row
        (7003,900,'GT Game','2026-11-18 19:00','V','101','2',2,100,200,'COMPLETED',true),                   -- already delivered
        (7004,900,'Other sale','2026-11-18 19:00','V','555','9',4,10,40,'PENDING_FULFILLMENT',false);        -- collides with a Vivid CRM order number
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('GoTickets','7001',NULL,'101','2',2,90),('GoTickets','7002',61,'101','2',2,100),('Vivid Seats','7004',62,'101','2',2,100),
 ('StubHub','SH1',63,'101','2',2,100);
-- TP1: per-ticket price lives in tickpick_orders.total; VV1 cancelled on Vivid; SG1 has no price in its feed (CRM supplies it)
INSERT INTO tickpick_orders VALUES ('TP1','TP Game',now()+interval '5 days','101','2',2,100,'CONFIRMED','Scheduled',64);
INSERT INTO vivid_orders VALUES ('VV1','VV Game',now()+interval '5 days','101','2',2,100,'CANCELLED',65);
INSERT INTO seatgeek_orders VALUES ('SG1','confirmed','SG Game','SGV',current_date+5,NULL,'2','101',2,66);
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES ('SeatGeek','SG1',66,'101','2',2,100);
\echo 1 lookup_best (book, site, event, section, row, qty, price):
SELECT n, b.book, b.site, b.tevo_event_id, b.section, b.seat_row, b.qty, b.sold_ea FROM unnest(ARRAY['7001','7002','7003','7004','SH1','TP1','VV1','SG1','NOPE']) n LEFT JOIN LATERAL sub_finder_lookup_best(n) b ON true;
SELECT 'caller says GoTickets for 7004: ' || coalesce((SELECT book||'/'||site||'/'||section FROM sub_finder_lookup_best('7004','Go Tickets')),'-');
\echo 2 closed:
SELECT n, coalesce(sub_finder_order_closed(n, NULL),'-') FROM unnest(ARRAY['7001','7003','VV1','TP1','SH1']) n;
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true, refresh_enabled=true;
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"7001"},{"order_number":"7002"},{"order_number":"7003"},{"order_number":"7004"},{"order_number":"SH1"},{"order_number":"TP1"},{"order_number":"VV1"},{"order_number":"SG1"},
  {"order_number":"7001X","site":"GoTickets","tevo_event_id":60,"section":"101","row":"2","qty":2,"sold_ea":500}]')->>'job_id')::uuid id;
\echo 3 orders (source, site, event, sold, action, note):
SELECT order_number, order_source, site, tevo_event_id, sold_ea, state, action, coalesce(auto_buy_note,'-') FROM sub_finder_order WHERE job_id=(SELECT id FROM j) ORDER BY idx;
SELECT sale_site, sale_order_number, sold_ea FROM manual_sub_buy ORDER BY 1,2;
\echo 4 a caller cannot inflate the price of an api order:
CREATE TEMP TABLE j2 AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"TP1","sold_ea":900}]')->>'job_id')::uuid id;
SELECT order_number, order_source, sold_ea, action, coalesce(auto_buy_note,'-') FROM sub_finder_order WHERE job_id=(SELECT id FROM j2);
\echo 5 live status: the marketplace marks a watched sale fulfilled -> the refresh closes it:
UPDATE gotickets_sales SET seller_status='COMPLETED', fulfilled=true WHERE gt_sale_id=7002;
SELECT sub_finder_refresh() - 'events' - 'jobs_rematched';
SELECT order_number, watching, coalesce(closed_reason,'-') FROM sub_finder_order WHERE job_id=(SELECT id FROM j) ORDER BY idx;
