\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(70,74) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (70,7001,'101','2',2,90,'{2}',false,false),     -- clean pair, 180
 (71,7101,'101','2',2,300,'{2}',false,false),    -- clean pair, 600
 (72,7201,'101','4',2,70,'{2}',false,false),     -- rows back: gate 5
 (73,7301,'101','2',2,90,'{2}',false,false),     -- for the order the caller describes
 (74,7401,'101','2',2,95,'{2}',false,false);     -- clean pair, 190
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','5001',70,'101','2',2,100),('StubHub','5002',71,'101','2',2,400),('GoTickets','5003',72,'101','2',2,100),
 ('StubHub','5004',74,'101','2',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true, buy_enabled=true, buy_key_ids='{7}', gt_offer_enabled=true, gt_offer_key_ids='{7}' WHERE id;

\echo A a key not listed acts for itself and may do what its account may
SELECT sub_finder_key_gate(7) - 'trusted_proxies';
\echo A listed keys: 8 reads for account 7; 9 buys and offers for it, from its registered addresses only
INSERT INTO sub_finder_key (key_id, account_id, can_buy, can_offer, allowed_ips, note) VALUES
 (8, 7, false, false, NULL, 'read'), (9, 7, true, true, '{203.0.113.7,198.51.100.0/24,2001:db8::/32}', 'buy');
UPDATE sub_finder_config SET write_requires_ip = true WHERE id;
SELECT sub_finder_key_gate(8) - 'trusted_proxies'; SELECT sub_finder_key_gate(9) - 'trusted_proxies';
\echo the proxies whose word the caller address rests on: our edge, IPv4 and IPv6
SELECT jsonb_array_length(g->'trusted_proxies'), g->'trusted_proxies'->>13, g->'trusted_proxies'->>15 FROM sub_finder_key_gate(9) g;

\echo B the label is status = need2buy and nothing else
SELECT sub_finder_need2buy('need2buy', NULL, NULL), sub_finder_need2buy('Need2Buy', NULL, NULL), sub_finder_need2buy('n2b', NULL, NULL),
       sub_finder_need2buy('n2s', 'need2buy', '{"label_status":"need2buy"}'), sub_finder_need2buy(NULL, NULL, NULL);

\echo C an order the caller describes is never bought automatically, even once our books show the same sale
CREATE TEMP TABLE r AS SELECT sub_finder_submit(7,'crm','[{"order_number":"R1","site":"StubHub","tevo_event_id":73,"section":"101","row":"2","qty":2,"sold_ea":100}]') AS r;
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM r))->>'status';
SELECT order_number, order_source, best->>'label', auto_buy_note, buy_id IS NOT NULL FROM sub_finder_order WHERE order_number='R1';
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES ('StubHub','R1',73,'101','2',2,100);
SELECT sub_finder_order_verified(o, ARRAY['api','marketplace'], true) FROM sub_finder_order o WHERE order_number='R1';
SELECT sub_finder_autobuy((SELECT (r->>'job_id')::uuid FROM r));
SELECT order_number, auto_buy_note, buy_id IS NOT NULL FROM sub_finder_order WHERE order_number='R1';

\echo D limits on the buys a CRM key asks for
UPDATE sub_finder_config SET auto_buy_enabled=false, crm_buy_per_order_cap_usd=500, crm_buy_daily_cap_usd=300, gt_offer_rebate_max_pct=50 WHERE id;
SELECT sub_finder_access(7)->'limits';
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[{"order_number":"5001"},{"order_number":"5002"},{"order_number":"5003"},{"order_number":"5004"}]') AS r;
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j))->>'status';
SELECT order_number, best->>'label', best->>'total', auto_buy_note FROM sub_finder_order WHERE job_id=(SELECT (r->>'job_id')::uuid FROM j) ORDER BY 1;
\echo over the per-order limit
SELECT sub_finder_buy_confirmed(7,'crm buy',(SELECT (r->>'job_id')::uuid FROM j),'5002','7101','dana',true);
\echo inside both limits
CREATE TEMP TABLE b1 AS SELECT sub_finder_buy_confirmed(7,'crm buy',(SELECT (r->>'job_id')::uuid FROM j),'5001','7001','dana',true) AS r;
SELECT r - 'buy_id' FROM b1;
\echo the next one would pass the daily limit
SELECT sub_finder_buy_confirmed(7,'crm buy',(SELECT (r->>'job_id')::uuid FROM j),'5004','7401','dana',true);
\echo a stopped buy does not count toward the day
UPDATE manual_sub_buy SET state='stopped' WHERE sale_order_number='5001';
SELECT sub_finder_buy_confirmed(7,'crm buy',(SELECT (r->>'job_id')::uuid FROM j),'5004','7401','dana',true)->>'state';

\echo E the rebate ceiling: half the sale (100 of 200)
SELECT j->>'gate', j->>'rebate_needed', j->>'rebate_suggested' FROM sub_finder_order o, sub_finder_offer_json(o) j WHERE order_number='5003';
SELECT sub_finder_gt_offer_confirmed(7,'crm buy','5003','7201',NULL,'dana',NULL,true);
SELECT sub_finder_gt_offer_confirmed(7,'crm buy','5003','7201',NULL,'dana',150,true);
SELECT sub_finder_gt_offer_confirmed(7,'crm buy','5003','7201',NULL,'dana',100,true) - 'offer_id';
\echo no ceiling set: the sale total, as before
UPDATE sub_finder_config SET gt_offer_rebate_max_pct=NULL WHERE id;
SELECT sub_finder_rebate_max(200), sub_finder_rebate_max(NULL);

\echo F the record: an accepted buy, a refusal, an offer, a settings change
SELECT sub_finder_audit_log(7, 9, 'crm buy', 'buy', '5001', '7001', '203.0.113.7', ' dana ', 'k-1', 202, (SELECT r FROM b1));
SELECT sub_finder_audit_log(7, 9, 'crm buy', 'buy', '5002', '7101', '203.0.113.7', 'dana', 'k-2', 403, '{"error":"forbidden","limit":"per_order"}');
SELECT sub_finder_audit_log(7, 9, 'crm buy', 'offer', '5003', '7201', '198.51.100.9', NULL, NULL, 202,
         jsonb_build_object('offer_id', (SELECT offer_id FROM sub_finder_gt_offer WHERE order_number='5003'), 'state', 'requested'));
SELECT sub_finder_audit_log(7, 9, 'crm buy', 'settings', NULL, NULL, '203.0.113.7', NULL, NULL, 200, '{"default":5}');
SELECT sub_finder_audit_log(7, 8, 'crm read', 'buy', '5001', '7001', '192.0.2.1', NULL, NULL, 403, NULL);
\echo the same Idempotency-Key again: the first row stands
SELECT sub_finder_audit_log(7, 9, 'crm buy', 'buy', '5001', '7001', '203.0.113.7', 'dana', 'k-1', 202, '{"buy_id":999,"state":"requested"}');
SELECT action, order_number, listing_id, market, amount_usd, rebate_usd, source_ip, key_id, requested_by, idem_key, http_status, outcome, buy_id IS NOT NULL, offer_id IS NOT NULL, response IS NOT NULL FROM sub_finder_audit ORDER BY audit_id;
\echo an accepted call is found by its key; a refused one is not
SELECT sub_finder_idem(7,'k-1') - 'response', (sub_finder_idem(7,'k-1')->'response') - 'buy_id', sub_finder_idem(7,'k-2'), sub_finder_idem(8,'k-1');
\echo the audit feed, newest first, for the account only
SELECT r->'count', r->'total', (SELECT jsonb_agg((i - 'at' - 'buy_id' - 'offer_id')) FROM jsonb_array_elements(r->'items') i) FROM (SELECT sub_finder_audit_read(7, NULL, 2, 0) r) q;
SELECT sub_finder_audit_read(7, now() + interval '1 hour', 200, 0) - 'generated_at';
SELECT sub_finder_audit_read(99, NULL, 200, 0);
