\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- The results feed shows only what is still in play (mig 20261118172530, operator 2026-11-18):
-- an N2S alert while its 15-minute timer runs (operator: "15 mins timer"), need2buy (PED
-- included) while its item is open and the event day has not passed, one row per order, and an
-- order with a purchase whatever its timer says. Scope 'all' is the old feed.
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'G'||g,now()+interval '5 days',6,5 FROM generate_series(401,407) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary)
 SELECT g, g*100+1, '101','2',2,80,'{2}',false,false FROM generate_series(401,407) g;
INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', g, now() FROM generate_series(401,407) g;
INSERT INTO n2s_items (n2s_id,order_number,marketplace,tevo_event_id,section,row,qty,price_per_ticket,status,status_label,item_source,raw,is_terminal,alert_at,timer_expires_at,event_dt) VALUES
 (401,'N401','StubHub',401,'101','2',2,100,'n2s','Need2Sub','automatiq','{}',false, now()-interval '2 minutes', now()+interval '13 minutes', now()+interval '5 days'),  -- alert, timer running
 (402,'N402','StubHub',402,'101','2',2,100,'n2s','Need2Sub','automatiq','{}',false, now()-interval '2 hours',   now()-interval '105 minutes', now()+interval '5 days'), -- alert, timer ran out
 (403,'N403','StubHub',403,'101','2',2,100,'need2buy','Need2Buy','manual','{}',false, NULL, NULL, NULL),                                      -- labelled need2buy, no event time
 (404,'N404','StubHub',404,'101','2',2,100,'n2b','Need2Buy','gmail','{}',false, NULL, NULL, now()+interval '5 days'),                         -- PED: need2buy too
 (405,'N405','StubHub',405,'101','2',2,100,'n2b_closed','Closed','gmail','{}',true, NULL, NULL, now()+interval '5 days');                     -- PED, closed
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','M406',406,'101','2',2,100), ('StubHub','M407',407,'101','2',2,100);        -- not in the N2S book
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=false, buy_enabled=true, buy_key_ids='{7}' WHERE id;
UPDATE manual_sub_buy_config SET enabled=true WHERE id;

\echo A where an order stands in the N2S book: kind, alert, timer, inside its time
SELECT o, w->>'kind', (w->>'alert_at') IS NOT NULL, (w->>'timer_expires_at') IS NOT NULL, w->>'in_window'
  FROM (SELECT o, sub_finder_n2s_window(o) w FROM unnest(ARRAY['N401','N402','N403','N404','N405']) o) x;
SELECT sub_finder_n2s_window('M406') IS NULL;

\echo B every order looked up once; N401 and N404 a second time
CREATE TEMP TABLE j1 AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"N401"},{"order_number":"N402"},{"order_number":"N403"},{"order_number":"N404"},{"order_number":"N405"},{"order_number":"M406"},{"order_number":"M407"}]')->>'job_id')::uuid AS id;
SELECT sub_finder_job_json(7,(SELECT id FROM j1))->>'status';
CREATE TEMP TABLE j2 AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"N401"},{"order_number":"N404"}]')->>'job_id')::uuid AS id;
SELECT sub_finder_job_json(7,(SELECT id FROM j2))->>'status';
SELECT order_number, count(*), count(*) FILTER (WHERE watching), string_agg(DISTINCT state, ',') FROM sub_finder_order GROUP BY 1 ORDER BY 1;

\echo C the feed: one row per order, inside its time (order, kind, watched, has a timer)
SELECT r->>'scope', r->>'count', r->>'total' FROM sub_finder_feed(7) r;
SELECT i->>'order_number', i->'n2s'->>'kind', i->>'watching', (i->'n2s'->>'timer_expires_at') IS NOT NULL, i->'n2s' ? 'in_window'
  FROM jsonb_array_elements(sub_finder_feed(7)->'items') i ORDER BY 1;
\echo the old name answers the same feed
SELECT sub_finder_results(7)->>'total', sub_finder_results(7)->>'scope';
\echo scope all: every answered lookup, nothing merged
SELECT r->>'scope', r->>'total' FROM sub_finder_feed(7, NULL, 200, 0, 'all') r;
SELECT i->>'order_number', count(*), coalesce(min(i->'n2s'->>'kind'), '-') FROM jsonb_array_elements(sub_finder_feed(7, NULL, 200, 0, 'all')->'items') i GROUP BY 1 ORDER BY 1;
SELECT sub_finder_feed(7, NULL, 200, 0, 'everything')->>'error', sub_finder_feed(8)->>'error';

\echo D the timer runs out: the alert leaves. The item closes or the event day passes: need2buy leaves
UPDATE n2s_items SET timer_expires_at = now() - interval '1 second' WHERE n2s_id = 401;
SELECT string_agg(i->>'order_number', ', ' ORDER BY i->>'order_number') FROM jsonb_array_elements(sub_finder_feed(7)->'items') i;
UPDATE n2s_items SET is_terminal = true WHERE n2s_id = 403;
SELECT string_agg(i->>'order_number', ', ' ORDER BY i->>'order_number') FROM jsonb_array_elements(sub_finder_feed(7)->'items') i;
UPDATE n2s_items SET event_dt = now() - interval '2 days' WHERE n2s_id = 404;
SELECT coalesce(string_agg(i->>'order_number', ', ' ORDER BY i->>'order_number'), 'nothing') FROM jsonb_array_elements(sub_finder_feed(7)->'items') i;
UPDATE n2s_items SET event_dt = now() + interval '5 days' WHERE n2s_id = 404;
SELECT string_agg(i->>'order_number', ', ' ORDER BY i->>'order_number') FROM jsonb_array_elements(sub_finder_feed(7)->'items') i;

\echo E an order with a purchase stays, in or out of the N2S book, until a week after it is final
SELECT r->>'state' FROM sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j1),'M407','40701','dana',true) r;
SELECT string_agg(i->>'order_number', ', ' ORDER BY i->>'order_number') FROM jsonb_array_elements(sub_finder_feed(7)->'items') i;
UPDATE manual_sub_buy SET final_at = now() - interval '6 days' WHERE sale_order_number = 'M407';
SELECT string_agg(i->>'order_number', ', ' ORDER BY i->>'order_number') FROM jsonb_array_elements(sub_finder_feed(7)->'items') i;
UPDATE manual_sub_buy SET final_at = now() - interval '8 days' WHERE sale_order_number = 'M407';
SELECT string_agg(i->>'order_number', ', ' ORDER BY i->>'order_number') FROM jsonb_array_elements(sub_finder_feed(7)->'items') i;

\echo F updated_since and paging work on the merged set
SELECT r->>'count', r->>'total' FROM sub_finder_feed(7, now() + interval '1 hour') r;
SELECT r->>'count', r->>'total', r->>'limit', r->>'offset' FROM sub_finder_feed(7, NULL, 1, 0) r;
