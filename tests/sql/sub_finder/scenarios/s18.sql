\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO mcp_api_keys VALUES (7,'crm') ON CONFLICT DO NOTHING;
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(80,84) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) SELECT g, 8000+g, '101','2',2,90,'{2}',false,false FROM generate_series(80,84) g;
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) SELECT 'StubHub', (6000+g)::text, g, '101','2',2,100 FROM generate_series(80,84) g;
INSERT INTO n2s_items (n2s_id,order_number,marketplace,tevo_event_id,section,row,qty,price_per_ticket,status,status_label,item_source,raw) VALUES
 (1,'6080','StubHub',80,'101','2',2,100,'need2buy','Need2Buy','manual','{"seller_notes":"rush"}'),   -- labelled by status
 (2,'6081','StubHub',81,'101','2',2,100,'n2s','N2S','manual','{"label_status":"Need-2-Buy"}'),       -- labelled by label_status
 (3,'6082','StubHub',82,'101','2',2,100,'n2s','N2S','automatiq','{}'),                               -- plain N2S: not ours
 (-4,'6083','StubHub',83,'101','2',2,100,'n2b','N2B','gmail','{}'),                                  -- our Gmail N2B book: not picked up
 (5,'6084','StubHub',84,'101','2',2,100,'need2buy','Need2Buy','manual','{}');
UPDATE n2s_items SET is_terminal = true WHERE n2s_id = 5;                                            -- closed: not picked up
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, refresh_enabled=true, auto_buy_enabled=true WHERE id;
\echo off by default: nothing taken in
SELECT sub_finder_n2b_intake(), (SELECT count(*) FROM sub_finder_order);
UPDATE sub_finder_config SET n2b_intake_enabled=true, n2b_key_id=7 WHERE id;
\echo the refresh job takes in the two labelled items, once
SELECT sub_finder_refresh() ? 'closed'; SELECT sub_finder_refresh() ? 'closed';
SELECT n2s_id, order_number, result FROM sub_finder_n2b_seen ORDER BY 1;
SELECT sub_finder_job_json(7, job_id)->>'status' FROM sub_finder_n2b_seen ORDER BY n2s_id;
\echo order | source | notes | watching | action | note | bought  (labelled orders are auto-bought; still watched)
SELECT sub_finder_refresh() ? 'closed';
SELECT order_number, order_source, coalesce(crm_notes,'-'), watching, action, coalesce(auto_buy_note,'-'), buy_id IS NOT NULL FROM sub_finder_order ORDER BY 1;
\echo a plain N2S order alerted by hand is still left to N2S
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[{"order_number":"6082"}]') r;
SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM j))->>'status';
SELECT order_number, coalesce(auto_buy_note,'-'), buy_id IS NOT NULL FROM sub_finder_order WHERE order_number='6082';
\echo label removed -> watch closes and the item is forgotten; labelled again -> taken in again
UPDATE n2s_items SET status='resolved', is_terminal=true WHERE n2s_id=1;
SELECT sub_finder_refresh() ? 'closed';
SELECT watching, closed_reason FROM sub_finder_order WHERE order_number='6080'; SELECT count(*) FROM sub_finder_n2b_seen;
UPDATE n2s_items SET status='need2buy', is_terminal=false WHERE n2s_id=1;
SELECT sub_finder_refresh() ? 'closed'; SELECT count(*) FROM sub_finder_n2b_seen, (SELECT 1) x; SELECT count(*) FROM sub_finder_order WHERE order_number='6080';
\echo label test
SELECT sub_finder_need2buy('Need 2 Buy',NULL,NULL), sub_finder_need2buy('n2s','N2B',NULL), sub_finder_need2buy('n2s','N2S','{"label_status":"need_to_buy"}'), sub_finder_need2buy('n2s','N2S','{}'), sub_finder_need2buy(NULL,NULL,NULL);
