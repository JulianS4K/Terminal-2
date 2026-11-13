\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO mcp_api_keys VALUES (7,'crm') ON CONFLICT DO NOTHING;
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(90,95) g;
INSERT INTO zone_stub VALUES (5,6,'101','Lower'),(5,6,'102','Lower');
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (90,9001,'101','2',2,110,'{2}',false,false),   -- A: gate 2, 10% loss: not auto-bought
 (91,9101,'101','1',1,90,'{1}',false,false),    -- B: single, better row: flagged
 (92,9201,'102','4',2,70,'{2}',false,false),    -- C: GoTickets order, rows back in the zone: gate 5
 (93,9301,'101','2',2,110,'{2}',false,false),   -- D: decision older than our answer
 (94,9401,'101','2',2,110,'{2}',false,false),   -- E: a listing we never quoted
 (95,9501,'101','2',2,110,'{2}',false,false);   -- F: decision none
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','7090',90,'101','2',2,100),('StubHub','7091',91,'101','2',1,100),('GoTickets','7092',92,'101','2',2,100),
 ('StubHub','7093',93,'101','2',2,100),('StubHub','7094',94,'101','2',2,100),('StubHub','7095',95,'101','2',2,100);
INSERT INTO n2s_items (n2s_id,order_number,marketplace,tevo_event_id,section,row,qty,price_per_ticket,status,status_label,item_source,raw)
SELECT g, (7000+g)::text, CASE WHEN g=92 THEN 'GoTickets' ELSE 'StubHub' END, g, '101','2', CASE WHEN g=91 THEN 1 ELSE 2 END, 100, 'need2buy','Need2Buy','manual','{}' FROM generate_series(90,95) g;
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, refresh_enabled=true, auto_buy_enabled=true,
       buy_enabled=true, buy_key_ids='{7}', gt_offer_enabled=true, gt_offer_key_ids='{7}', n2b_intake_enabled=true, n2b_key_id=7 WHERE id;
SELECT sub_finder_refresh() ? 'closed';
SELECT sub_finder_job_json(7, job_id)->>'status' FROM sub_finder_n2b_seen ORDER BY n2s_id LIMIT 1;
\echo taken in, none bought automatically:
SELECT order_number, action, best->>'gate', coalesce(best->'flags','[]')::text, buy_id IS NOT NULL FROM sub_finder_order ORDER BY 1;
-- the CRM writes its decisions into the feed
UPDATE n2s_items SET raw = jsonb_build_object('sub_decision','buy','sub_listing_id','9001','sub_decided_by','dana','sub_decided_at', to_char(now() AT TIME ZONE 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"')) WHERE n2s_id=90;
UPDATE n2s_items SET raw = jsonb_build_object('sub_decision','BUY','sub_listing_id','9101','sub_decided_at', to_char(now() AT TIME ZONE 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"')) WHERE n2s_id=91;
UPDATE n2s_items SET raw = jsonb_build_object('sub_decision','offer','sub_listing_id','9201','sub_market','evo','sub_decided_at', to_char(now() AT TIME ZONE 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"')) WHERE n2s_id=92;
UPDATE n2s_items SET raw = jsonb_build_object('sub_decision','buy','sub_listing_id','9301','sub_decided_at','2020-01-01T00:00:00Z') WHERE n2s_id=93;
UPDATE n2s_items SET raw = jsonb_build_object('sub_decision','buy','sub_listing_id','424242','sub_decided_at', to_char(now() AT TIME ZONE 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"')) WHERE n2s_id=94;
UPDATE n2s_items SET raw = jsonb_build_object('sub_decision','none','sub_listing_id','9501','sub_decided_at', to_char(now() AT TIME ZONE 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"')) WHERE n2s_id=95;
\echo switch off: nothing is carried out
SELECT sub_finder_feed_decisions(), (SELECT count(*) FROM manual_sub_buy);
UPDATE sub_finder_config SET n2b_decisions_enabled=true WHERE id;
\echo switch on: the refresh carries them out, once (two rounds)
SELECT sub_finder_refresh() ? 'closed'; SELECT sub_finder_refresh() ? 'closed';
SELECT n2s_id, decision, outcome, coalesce(result->>'detail', result->>'flags', '-') FROM sub_finder_feed_decision ORDER BY 1;
SELECT sale_order_number, ticket_group_id, qty, requested_by FROM manual_sub_buy ORDER BY buy_id;
\echo the CRM decides again: B with confirm, C with a rebate, D with a fresh instant
UPDATE n2s_items SET raw = raw || jsonb_build_object('sub_confirm', true, 'sub_decided_at', to_char((now() + interval '1 second') AT TIME ZONE 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"')) WHERE n2s_id=91;
UPDATE n2s_items SET raw = raw || jsonb_build_object('sub_rebate_amount', 10, 'sub_decided_at', to_char((now() + interval '1 second') AT TIME ZONE 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"')) WHERE n2s_id=92;
UPDATE n2s_items SET raw = raw || jsonb_build_object('sub_confirm', 'true', 'sub_decided_at', to_char((now() + interval '1 second') AT TIME ZONE 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"')) WHERE n2s_id=93;
SELECT sub_finder_refresh() ? 'closed';
SELECT n2s_id, decision, confirm, rebate, outcome FROM sub_finder_feed_decision ORDER BY acted_at, n2s_id OFFSET 5;
SELECT count(*) AS buys FROM manual_sub_buy; SELECT order_number, gate, rebate_amount, state FROM sub_finder_gt_offer;
\echo what the CRM reads on the order
SELECT order_number, sub_finder_order_json(o)->'feed_decision'->>'outcome', sub_finder_order_json(o)->'feed_decision'->>'detail', sub_finder_order_json(o)->'feed_decision'->'flags' FROM sub_finder_order o WHERE order_number IN ('7091','7094','7095') ORDER BY 1;
