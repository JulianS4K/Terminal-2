\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- TicketsData scope (mig 20261113290000): which orders ask TicketsData, and what happens to
-- an order that already has a cover while it is asked.
-- event 50: EVO has the same seats at a profit (gate 1). event 51: EVO only at a loss.
-- event 52: nothing anywhere.
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(50,52) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (50,5001,'101','2',2,80,'{2}',false,false), (51,5101,'101','2',2,130,'{2}',false,false);
INSERT INTO aq_event_map (tevo_event_id, sh_event_id) VALUES (50,9050),(51,9051),(52,9052);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', td_enabled=true, td_concurrency=10, settle_min_s=0, settle_timeout_s=180 WHERE id;
CREATE FUNCTION pg_temp.go(p_tag text) RETURNS uuid LANGUAGE sql AS $$
  SELECT (sub_finder_submit(7,'crm', format('[
   {"order_number":"%1$s-A","tevo_event_id":50,"section":"101","row":"2","qty":2,"sold_ea":100},
   {"order_number":"%1$s-B","tevo_event_id":51,"section":"101","row":"2","qty":2,"sold_ea":100},
   {"order_number":"%1$s-C","tevo_event_id":52,"section":"101","row":"2","qty":2,"sold_ea":100}]', p_tag)::jsonb)->>'job_id')::uuid $$;
CREATE FUNCTION pg_temp.show(p_job uuid) RETURNS TABLE(o text) LANGUAGE sql AS $$
  SELECT concat_ws('|', i->>'order_number', i->>'state', coalesce(i->'best'->>'gate','-'), coalesce(i->>'ticketsdata','-'),
                   (SELECT string_agg(c->>'market' || ':' || (c->>'listing_id'), ',' ORDER BY c->>'market', c->>'listing_id') FROM jsonb_array_elements(i->'covers') c))
  FROM (SELECT sub_finder_job_json(7, p_job) r) q, jsonb_array_elements(r->'items') i ORDER BY 1 $$;

\echo scope no_cover (default): only the order with no cover asks
CREATE TEMP TABLE j1 AS SELECT pg_temp.go('n') AS job;
INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', g, now() FROM generate_series(50,52) g;
SELECT pg_temp.show(job) FROM j1;
SELECT array_agg(tevo_event_id ORDER BY tevo_event_id) FROM sub_finder_td_pull WHERE job_id = (SELECT job FROM j1);

\echo scope not_one_to_one: the loss cover asks too, the gate 1 cover does not
UPDATE sub_finder_config SET td_scope = 'not_one_to_one' WHERE id;
CREATE TEMP TABLE j2 AS SELECT pg_temp.go('p') AS job;
INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', g, now() FROM generate_series(50,52) g;
SELECT pg_temp.show(job) FROM j2;
SELECT array_agg(tevo_event_id ORDER BY tevo_event_id) FROM sub_finder_td_pull WHERE job_id = (SELECT job FROM j2);

\echo scope all: every order asks; the ones with a cover keep showing it, the job is not done yet
UPDATE sub_finder_config SET td_scope = 'all' WHERE id;
CREATE TEMP TABLE j3 AS SELECT pg_temp.go('a') AS job;
INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', g, now() FROM generate_series(50,52) g;
SELECT pg_temp.show(job) FROM j3;
SELECT array_agg(tevo_event_id ORDER BY tevo_event_id) FROM sub_finder_td_pull WHERE job_id = (SELECT job FROM j3);
SELECT sub_finder_job_json(7, job)->>'status' FROM j3;

\echo event 51 answers with cheaper StubHub seats, event 50 is rate limited, event 52 has nothing
INSERT INTO net._http_response (id,status_code,content) SELECT request_id, 200, '{"matches":{"stubhub":"https://www.stubhub.com/event/9051"},"fetch_results":{"normalized":{
 "stubhub":{"offers":[{"listing_id":"S51","section":"101","row":"2","quantity":2,"price_total":70,"available_lots":[2],"flags":{}}]}}}}'
  FROM sub_finder_td_pull WHERE job_id = (SELECT job FROM j3) AND tevo_event_id = 51;
INSERT INTO net._http_response (id,status_code,content) SELECT request_id, 429, 'Too Many Requests'
  FROM sub_finder_td_pull WHERE job_id = (SELECT job FROM j3) AND tevo_event_id = 50;
INSERT INTO net._http_response (id,status_code,content) SELECT request_id, 200, '{"matches":{},"fetch_results":{"normalized":{}}}'
  FROM sub_finder_td_pull WHERE job_id = (SELECT job FROM j3) AND tevo_event_id = 52;
\echo A keeps its EVO cover (search failed), B has EVO and StubHub, C ends with no cover:
SELECT pg_temp.show(job) FROM j3;
SELECT sub_finder_job_json(7, job)->>'status' FROM j3;
SELECT tevo_event_id, status_code, offers, coalesce(note,'-') FROM sub_finder_td_pull WHERE job_id = (SELECT job FROM j3) ORDER BY 1;

\echo more events than the limit: the event with a no-cover order is asked first
UPDATE sub_finder_config SET td_max_events_per_job = 1 WHERE id;
CREATE TEMP TABLE j4 AS SELECT pg_temp.go('l') AS job;
INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', g, now() FROM generate_series(50,52) g;
SELECT pg_temp.show(job) FROM j4;
SELECT array_agg(tevo_event_id ORDER BY tevo_event_id) FROM sub_finder_td_pull WHERE job_id = (SELECT job FROM j4);
