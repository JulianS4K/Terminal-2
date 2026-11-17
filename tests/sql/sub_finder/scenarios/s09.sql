\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'G',now()+interval '5 days',6,5 FROM generate_series(50,53) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (50,5001,'101','2',2,100,'{2}',false,false),(51,5101,'101','2',2,99,'{2}',false,false),(52,5201,'101','2',2,100.01,'{2}',false,false),(53,5301,'101','2',2,95,'{2}',false,false);
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','EVEN',50,'101','2',2,100),('StubHub','WIN1',51,'101','2',2,100),('StubHub','LOSS',52,'101','2',2,100),('StubHub','WIN5',53,'101','2',2,100);
SELECT 'default pct: ' || auto_buy_min_profit_pct FROM sub_finder_config;
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true;
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"EVEN"},{"order_number":"WIN1"},{"order_number":"LOSS"},{"order_number":"WIN5"}]')->>'job_id')::uuid id;
SELECT i->>'order_number', i->'best'->>'gate', i->'best'->>'profit', i->>'action', coalesce(i->>'auto_buy_note','-') FROM (SELECT sub_finder_job_json(7,(SELECT id FROM j)) r) o, jsonb_array_elements(r->'items') i;
SELECT sale_order_number, note FROM manual_sub_buy ORDER BY 1;
