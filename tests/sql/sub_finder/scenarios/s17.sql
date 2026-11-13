\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(70,71) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES (70,7001,'101','2',2,150,'{2}',false,false),(71,7101,'101','2',2,150,'{2}',false,false);
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES ('StubHub','5001',70,'101','2',2,100),('StubHub','5002',71,'101','2',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0 WHERE id;
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[{"order_number":"5001","notes":"  buyer wants aisle  "},{"order_number":"5002"}]') AS r;
\echo with the alert: 5001 has a note, 5002 none
SELECT i->>'order_number', coalesce(i->>'notes','-'), (i->>'notes_at') IS NOT NULL FROM jsonb_array_elements(sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j))->'items') i ORDER BY 1;
\echo set, replace, clear, unknown order, wrong key
SELECT sub_finder_set_notes(7,'5002','called buyer 3pm')->>'notes';
SELECT sub_finder_set_notes(7,'5002', repeat('x',600))->>'notes' = repeat('x',500);
SELECT coalesce(sub_finder_set_notes(7,'5002','   ')->>'notes','(cleared)');
SELECT sub_finder_set_notes(7,'9999','x')->>'error', sub_finder_set_notes(8,'5001','x')->>'error';
\echo a re-alert keeps the last note unless it brings its own
SELECT sub_finder_submit(7,'crm','[{"order_number":"5001"}]')->>'order_count';
SELECT order_number, watching, crm_notes FROM sub_finder_order WHERE order_number='5001' ORDER BY watching;
SELECT sub_finder_submit(7,'crm','[{"order_number":"5001","notes":"new note"}]')->>'order_count';
SELECT crm_notes FROM sub_finder_order WHERE order_number='5001' AND watching;
