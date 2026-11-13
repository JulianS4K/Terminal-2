\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) VALUES (70,'Taxed venue',now()+interval '5 days',214,5),(71,'Untaxed venue',now()+interval '5 days',999,5),(72,'Manual venue',now()+interval '5 days',300,5);
INSERT INTO evo_orders (evo_order_id,state,seller_brokerage_id,buyer_brokerage_id,tax,subtotal) VALUES
 (1,'completed',61,1768,18.80,341.88),(2,'completed',61,1768,0,100),(3,'completed',61,1768,2,100),   -- venue 214: 5.5%, none, 2% -> 5.5
 (4,'completed',61,1768,0,100),                                                                        -- venue 999: never taxed
 (5,'completed',1768,61,9,100),                                                                        -- our SALE: ignored
 (6,'completed',61,1768,50,100);                                                                       -- 50%: not believable, ignored
INSERT INTO evo_order_items (evo_order_id,venue_id,venue_name) VALUES (1,214,'Camp Randall'),(2,214,'Camp Randall'),(3,214,'Camp Randall'),(4,999,'Plain'),(5,500,'Sale venue'),(6,600,'Odd');
INSERT INTO evo_venue_tax (venue_id,venue_name,tax_pct,source,note) VALUES (300,'Manual',8,'manual','operator');
INSERT INTO evo_orders (evo_order_id,state,seller_brokerage_id,buyer_brokerage_id,tax,subtotal) VALUES (7,'completed',61,1768,3,100);
INSERT INTO evo_order_items (evo_order_id,venue_id,venue_name) VALUES (7,300,'Manual');
\echo 1 learned rows (manual row kept; rerun writes nothing):
SELECT evo_venue_tax_refresh(), evo_venue_tax_refresh();
SELECT venue_id, tax_pct, source, orders_seen, orders_taxed FROM evo_venue_tax ORDER BY 1;
SELECT sub_finder_evo_tax_pct('evo',214), sub_finder_evo_tax_pct('evo',999), sub_finder_evo_tax_pct('gotickets',214), sub_finder_evo_tax_pct('evo',300);
SELECT schedule FROM cron.scheduled WHERE name='evo_venue_tax_refresh_hourly';
-- sale 100 x2 = 200. EVO at 95: untaxed 190 (+10); at 5.5% 200.45 (-0.45 -> gate 2, not bought)
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (70,7001,'101','2',2,95,'{2}',false,false),(70,7002,'101','1',2,94,'{2}',false,false),(71,7101,'101','2',2,95,'{2}',false,false),(72,7201,'101','2',2,92,'{2}',false,false);
INSERT INTO n2s_gt_current (tevo_event_id,gt_event_id,gt_listing_id,section,row,quantity,all_in_price,splits) VALUES (70,1,7901,'101','2',2,95,'{2}');
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES ('StubHub','TAX',70,'101','2',2,100),('StubHub','NOTAX',71,'101','2',2,100),('StubHub','MAN',72,'101','2',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true;
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"TAX"},{"order_number":"NOTAX"},{"order_number":"MAN"}]')->>'job_id')::uuid id;
\echo 2 covers (order, market, listing, price, subtotal, tax%, tax, total, profit, gate):
SELECT i->>'order_number', c->>'market', c->>'listing_id', c->>'price_ea', c->>'subtotal', c->>'tax_pct', c->>'tax_est', c->>'total', c->>'profit', c->>'gate'
 FROM (SELECT sub_finder_job_json(7,(SELECT id FROM j)) r) o, jsonb_array_elements(r->'items') i, jsonb_array_elements(i->'covers') c;
\echo 3 actions and buys (ceiling stays the listed price):
SELECT order_number, action, coalesce(auto_buy_note,'-') FROM sub_finder_order WHERE job_id=(SELECT id FROM j) ORDER BY idx;
SELECT sale_order_number, ticket_group_id, max_price_ea, note FROM manual_sub_buy ORDER BY 1;
\echo 4 default for unknown venues:
UPDATE sub_finder_config SET evo_tax_default_pct=6; SELECT sub_finder_evo_tax_pct('evo',999), sub_finder_evo_tax_pct('evo',214);
