\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO mcp_api_keys VALUES (7,'crm') ON CONFLICT DO NOTHING;
INSERT INTO order_status_xref VALUES ('s4kcs','cancelled','cancelled',true);
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(100,104) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) SELECT g, 10000+g, '101','2',2,150,'{2}',false,false FROM generate_series(100,104) g;
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) SELECT 'StubHub', (8000+g)::text, g, '101','2',2,100 FROM generate_series(100,104) g;
INSERT INTO n2s_items (n2s_id,order_number,marketplace,tevo_event_id,section,row,qty,price_per_ticket,status,status_label,item_source,raw)
SELECT g, (8000+g)::text, 'StubHub', g, '101','2',2,100,'need2buy','Need2Buy','manual','{}' FROM generate_series(100,104) g;
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, refresh_enabled=true, refresh_pull=true, feed_check_every='0 seconds', n2b_intake_enabled=true, n2b_key_id=7 WHERE id;
SELECT sub_finder_refresh() ? 'closed';
SELECT sub_finder_job_json(7, job_id)->>'status' FROM sub_finder_n2b_seen ORDER BY n2s_id LIMIT 1;
SELECT count(*) FILTER (WHERE via_need2buy), count(*) FROM sub_finder_order;
\echo 8100 label kept | 8101 label back to n2s | 8102 subbed | 8103 resolved | 8104 marketplace cancels
UPDATE n2s_items SET status='n2s', status_label='N2S' WHERE n2s_id=101;
UPDATE n2s_items SET status='subbed', status_label='Subbed' WHERE n2s_id=102;
UPDATE n2s_items SET status='resolved', status_label='Resolved', is_terminal=true WHERE n2s_id=103;
UPDATE v_s4kcs_orders SET order_status='cancelled' WHERE s4k_order_id='8104';
TRUNCATE band_log;
SELECT sub_finder_refresh() ? 'closed';
SELECT order_number, watching, coalesce(closed_reason,'-') FROM sub_finder_order ORDER BY 1;
\echo only the one still labelled is polled:
SELECT (SELECT array_agg(e ORDER BY e) FROM unnest(evs) e) FROM band_log;
\echo a hand-alerted plain N2S order still closes when it leaves the book
CREATE TEMP TABLE j AS SELECT sub_finder_submit(7,'crm','[{"order_number":"8100x"}]') r;
INSERT INTO n2s_items (n2s_id,order_number,marketplace,tevo_event_id,section,row,qty,price_per_ticket,status,item_source,raw) VALUES (200,'8200','StubHub',100,'101','2',2,100,'n2s','automatiq','{}');
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES ('StubHub','8200',100,'101','2',2,100);
SELECT sub_finder_submit(7,'crm','[{"order_number":"8200"}]')->>'order_count';
UPDATE n2s_items SET status='no_subs' WHERE n2s_id=200;
SELECT sub_finder_refresh() ? 'closed';
SELECT order_number, via_need2buy, watching, coalesce(closed_reason,'-') FROM sub_finder_order WHERE order_number='8200';
