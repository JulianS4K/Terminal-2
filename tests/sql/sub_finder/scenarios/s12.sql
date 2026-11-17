\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'G'||g,now()+interval '5 days', CASE WHEN g=85 THEN 214 ELSE 999 END,5 FROM generate_series(80,86) g;
INSERT INTO evo_venue_tax (venue_id,tax_pct,source) VALUES (214,5.5,'manual');
-- sale 100 x2 = 200 each. loss limit 5% = $10
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (80,8001,'101','2',2,105,'{2}',false,false),                -- 210: -10 = 5.0% -> bought
 (81,8101,'101','2',2,105.01,'{2}',false,false),             -- 210.02: -10.02 -> not bought
 (82,8201,'101','2',2,104,'{2}',false,false),(82,8202,'101','1',2,99,'{2}',false,false),   -- a profit exists: it is taken, not the loss
 (83,8301,'101','2',3,60,'{3}',false,false),                 -- gate 2-ish via spare: never
 (84,8401,'102','2',2,104,'{2}',false,false),                -- another section: gate 4 if zoned -> never
 (85,8501,'101','2',2,99,'{2}',false,false),                 -- 198 + 5.5% tax = 208.89: -8.89 = gate 2, 4.4% -> bought
 (86,8601,'101','2',2,104,'{2}',false,false);                -- no sale price
INSERT INTO zone_stub VALUES (5,999,'101','L'),(5,999,'102','L');
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) SELECT 'StubHub','L'||g,g,'101','2',2,CASE WHEN g=86 THEN NULL ELSE 100 END FROM generate_series(80,86) g;
SELECT 'limit: ' || auto_buy_max_loss_pct FROM sub_finder_config;
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true;
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm',(SELECT jsonb_agg(jsonb_build_object('order_number','L'||g)) FROM generate_series(80,86) g))->>'job_id')::uuid id;
SELECT order_number, best->>'gate', best->>'total', best->>'profit', action, coalesce(auto_buy_note,'-') FROM sub_finder_order WHERE job_id=(SELECT id FROM j) ORDER BY idx;
SELECT sale_order_number, ticket_group_id, max_price_ea, note FROM manual_sub_buy ORDER BY 1;
\echo after the buy: EVO charged more than quoted (tax) -> flagged gate 2; a profitable one -> gate 1; unknown yet -> null
UPDATE manual_sub_buy SET state='bought', order_total_usd=205 WHERE sale_order_number='L82';
UPDATE manual_sub_buy SET state='bought', order_total_usd=198 WHERE sale_order_number='L85';
SELECT i->>'order_number', i->'buy'->>'total', i->'buy'->>'profit_actual', i->'buy'->>'gate_actual', i->'buy'->>'label_actual'
 FROM (SELECT sub_finder_job_json(7,(SELECT id FROM j)) r) o, jsonb_array_elements(r->'items') i WHERE i->'buy' IS NOT NULL AND i->>'buy' <> 'null';
\echo limit 0 = breakeven only:
UPDATE sub_finder_config SET auto_buy_max_loss_pct=0;
SELECT sub_finder_autobuy_gate('{"gate":2,"profit":0,"total":200}'), sub_finder_autobuy_gate('{"gate":2,"profit":-0.01,"total":200.01}'), sub_finder_autobuy_gate('{"gate":1,"profit":5,"total":195}'), sub_finder_autobuy_gate('{"gate":2,"total":200}'), sub_finder_autobuy_gate('{"gate":4,"profit":-1,"total":201}');
