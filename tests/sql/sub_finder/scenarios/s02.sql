\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
UPDATE sub_finder_config SET td_enabled=true, settle_min_s=0, settle_timeout_s=180;
INSERT INTO aq_event_map (tevo_event_id, sh_event_id) VALUES (3241050,159917331),(2,555);
\echo T1 submit, native pulls answer:
CREATE TEMP TABLE t AS SELECT (sub_finder_submit(7,'crm','[
 {"order_number":"A","tevo_event_id":3241050,"section":"217","row":"G","qty":2,"sold_ea":125.72},
 {"order_number":"B","tevo_event_id":3241050,"section":"999","row":"5","qty":2,"sold_ea":100},
 {"order_number":"C","tevo_event_id":3241050,"section":"888","row":"3","qty":1,"sold_ea":50},
 {"order_number":"D","tevo_event_id":1,"section":"1","row":"1","qty":1},
 {"order_number":"E","tevo_event_id":2,"section":"10","row":"2","qty":2,"sold_ea":80}]')->>'job_id')::uuid AS job;
UPDATE n2s_mkt_pull SET resolved_at=now();
TRUNCATE net.sent;
SELECT r->>'status', r->'summary' FROM (SELECT sub_finder_job_json(7,(SELECT job FROM t)) r) q;
SELECT i->>'order_number', i->>'state', coalesce(i->>'ticketsdata','-') FROM (SELECT sub_finder_job_json(7,(SELECT job FROM t)) r) q, jsonb_array_elements(r->'items') i;
\echo T2 what was sent to TicketsData (only events with an uncovered order, creds from vault):
SELECT id, url, params->>'event_url', params->>'username' FROM net.sent ORDER BY id;
SELECT 'feed has only answered orders of this job: ' || string_agg(i->>'order_number', ',' ORDER BY i->>'order_number') FROM (SELECT sub_finder_results(7,NULL,1000,0) r) q, jsonb_array_elements(r->'items') i WHERE i->>'job_id' = (SELECT job::text FROM t);
\echo T3 event 3241050 answers:
INSERT INTO net._http_response (id,status_code,content) SELECT request_id, 200, '{"matches":{"stubhub":"https://www.stubhub.com/event/159917331","tickpick":"https://www.tickpick.com/x/1/"},"fetch_results":{"normalized":{
 "stubhub":{"offers":[
   {"listing_id":"S1","section":"999","row":"3","quantity":4,"price_total":40,"available_lots":[2,4],"flags":{"parking":false}},
   {"listing_id":"S2","section":"999","row":"1","quantity":2,"price_total":5,"available_lots":[2],"flags":{"parking":true}},
   {"listing_id":"S3","section":"999","row":"2","quantity":"two","price_total":1,"available_lots":[2]},
   {"listing_id":"S4","section":"999","row":"2","quantity":2,"price_total":null}]},
 "tickpick":{"offers":[{"listing_id":"T1","section":"999","row":"8","quantity":2,"price_total":30,"available_lots":[2],"flags":{}}]},
 "vividseats":{"offers":[{"listing_id":"V1","section":"999","row":"5","quantity":3,"price_total":45.5,"available_lots":"n/a"}]},
 "seatgeek":{"offers":[{"listing_id":"G1","section":"999","row":"1","quantity":2,"price_total":1,"available_lots":[2]}]},
 "gametime":{"status":"error"}}}}' FROM sub_finder_td_pull WHERE job_id=(SELECT job FROM t) AND tevo_event_id=3241050;
SELECT r->>'status', r->'summary' FROM (SELECT sub_finder_job_json(7,(SELECT job FROM t)) r) q;
SELECT i->>'order_number', i->>'state', i->>'ticketsdata', i->'markets_searched' FROM (SELECT sub_finder_job_json(7,(SELECT job FROM t)) r) q, jsonb_array_elements(r->'items') i WHERE i->>'order_number' IN ('B','C');
SELECT c->>'market', c->>'source', c->>'listing_id', c->>'row', c->>'row_relation', c->>'buy_qty', c->>'spare', c->>'price_ea', c->>'profit', c->>'buyable', coalesce(c->>'price_note','-'), c->>'link' FROM (SELECT sub_finder_job_json(7,(SELECT job FROM t)) r) q, jsonb_array_elements(r->'items') i, jsonb_array_elements(i->'covers') c WHERE i->>'order_number'='B';
SELECT tevo_event_id, status_code, offers, coalesce(note,'-'), resolved_at IS NOT NULL FROM sub_finder_td_pull WHERE job_id=(SELECT job FROM t) ORDER BY 1;
\echo T4 a TicketsData-only cover cannot be bought:
UPDATE sub_finder_config SET buy_enabled=true, buy_key_ids='{7}';
SELECT sub_finder_buy(7,'crm',(SELECT job FROM t),'B','S1')->>'detail';
\echo T5 event 2 answers 429 -> failed, job done:
INSERT INTO net._http_response (id,status_code,content) SELECT request_id, 429, 'Too Many Requests' FROM sub_finder_td_pull WHERE job_id=(SELECT job FROM t) AND tevo_event_id=2;
SELECT r->>'status', r->'summary' FROM (SELECT sub_finder_job_json(7,(SELECT job FROM t)) r) q;
SELECT i->>'order_number', i->>'state', i->>'ticketsdata', i->'markets_searched' FROM (SELECT sub_finder_order_read(7,(SELECT job FROM t),'E') r) q, jsonb_array_elements(r->'items') i;
SELECT tevo_event_id, status_code, coalesce(note,'-') FROM sub_finder_td_pull WHERE job_id=(SELECT job FROM t) AND tevo_event_id=2;
SELECT sub_finder_order_read(7,(SELECT job FROM t),'ZZZ') IS NULL, sub_finder_order_read(8,(SELECT job FROM t),'E')->>'error';
\echo T6 concurrency 1 and per-job cap 1; overdue pull times out:
UPDATE sub_finder_config SET td_concurrency=1;
TRUNCATE net.sent;
CREATE TEMP TABLE t2 AS SELECT (sub_finder_submit(7,'crm','[
 {"order_number":"F","tevo_event_id":3241050,"section":"777","row":"1","qty":1},
 {"order_number":"G","tevo_event_id":2,"section":"777","row":"1","qty":1}]')->>'job_id')::uuid AS job;
UPDATE n2s_mkt_pull SET resolved_at=now();
SELECT sub_finder_job_json(7,(SELECT job FROM t2))->>'status'; SELECT 'sent so far: ' || count(*) FROM net.sent;
SELECT sub_finder_job_json(7,(SELECT job FROM t2))->>'status'; SELECT 'sent so far: ' || count(*) FROM net.sent;
UPDATE sub_finder_td_pull SET fired_at = now() - interval '10 minutes' WHERE job_id=(SELECT job FROM t2) AND request_id IS NOT NULL;
SELECT sub_finder_job_json(7,(SELECT job FROM t2))->>'status'; SELECT 'sent so far: ' || count(*) FROM net.sent;
SELECT tevo_event_id, coalesce(note,'-'), request_id IS NOT NULL fired, resolved_at IS NOT NULL resolved FROM sub_finder_td_pull WHERE job_id=(SELECT job FROM t2) ORDER BY 1;
UPDATE sub_finder_config SET td_max_events_per_job=1, td_concurrency=3;
CREATE TEMP TABLE t3 AS SELECT (sub_finder_submit(7,'crm','[
 {"order_number":"H","tevo_event_id":3241050,"section":"777","row":"1","qty":1},
 {"order_number":"H2","tevo_event_id":3241050,"section":"776","row":"1","qty":1},
 {"order_number":"I","tevo_event_id":2,"section":"777","row":"1","qty":1}]')->>'job_id')::uuid AS job;
UPDATE n2s_mkt_pull SET resolved_at=now();
SELECT i->>'order_number', i->>'state', i->>'ticketsdata' FROM (SELECT sub_finder_job_json(7,(SELECT job FROM t3)) r) q, jsonb_array_elements(r->'items') i;
\echo T7 no credentials -> failed, nothing sent:
CREATE OR REPLACE FUNCTION get_app_secret(p text) RETURNS text LANGUAGE sql AS $$ SELECT ''::text $$;
UPDATE sub_finder_config SET td_max_events_per_job=6;
TRUNCATE net.sent;
CREATE TEMP TABLE t4 AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"J","tevo_event_id":2,"section":"777","row":"1","qty":1}]')->>'job_id')::uuid AS job;
UPDATE n2s_mkt_pull SET resolved_at=now();
SELECT r->>'status', r->'items'->0->>'state', r->'items'->0->>'ticketsdata', (SELECT count(*) FROM net.sent) FROM (SELECT sub_finder_job_json(7,(SELECT job FROM t4)) r) q;
\echo F1 follow a bought order:
UPDATE sub_finder_config SET td_enabled=false;
CREATE TEMP TABLE b AS SELECT buy_id, updated_at FROM manual_sub_buy WHERE sale_order_number='659240801';
UPDATE manual_sub_buy SET state='bought', buy_order_id='19429529', buy_state='pending', bought_price_ea=74.10, bought_total_usd=296.40 WHERE buy_id=(SELECT buy_id FROM b);
CREATE TEMP TABLE b2 AS SELECT updated_at FROM manual_sub_buy WHERE buy_id=(SELECT buy_id FROM b);
SELECT manual_sub_buy_follow_claim() = jsonb_build_object('buy_id',(SELECT buy_id FROM b),'buy_order_id','19429529');
SELECT manual_sub_buy_follow_claim() IS NULL AS not_due_again_for_30s;
SELECT manual_sub_buy_follow_record((SELECT buy_id FROM b), '{"order_state":"pending","seller_state":"pending","order_total_usd":"296.4","bought_section":"134","bought_row":"G","seats":[]}');
SELECT outcome, seller_state, seats IS NULL, final_at IS NULL, state, updated_at = (SELECT updated_at FROM b2) AS spend_day_untouched FROM manual_sub_buy WHERE buy_id=(SELECT buy_id FROM b);
SELECT pg_sleep(0.05);
CREATE TEMP TABLE cur AS SELECT now() AS at;
UPDATE manual_sub_buy SET status_checked_at = now() - interval '1 minute' WHERE buy_id=(SELECT buy_id FROM b);
SELECT manual_sub_buy_follow_claim()->>'buy_order_id';
SELECT manual_sub_buy_follow_record((SELECT buy_id FROM b), '{"order_state":"completed","seller_state":"Completed","order_total_usd":"296.4","bought_section":"134","bought_row":"G","seats":["14","15","16","17"]}');
SELECT outcome, state, seats, order_total_usd, final_at IS NOT NULL, status_checks, updated_at = (SELECT updated_at FROM b2) FROM manual_sub_buy WHERE buy_id=(SELECT buy_id FROM b);
SELECT manual_sub_buy_follow_claim() IS NULL AS final_is_never_claimed, manual_sub_buy_follow_record((SELECT buy_id FROM b), '{"seller_state":"rejected"}');
\echo F2 the CRM sees it, and the sync feed re-emits the order:
SELECT (i->'buy') - 'buy_id'::text - 'status_checked_at'::text - 'final_at'::text FROM (SELECT sub_finder_results(7,(SELECT at FROM cur),1000,0) r) q, jsonb_array_elements(r->'items') i;
\echo F3 a rejected order frees the sale and the spend:
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, ticket_group_id, qty, max_price_ea, state, buy_order_id, bought_total_usd) VALUES ('op','Vivid','R1',1,2,50,'bought','777',100) RETURNING outcome;
SELECT manual_sub_buy_follow_claim()->>'buy_order_id';
SELECT manual_sub_buy_follow_record((SELECT buy_id FROM manual_sub_buy WHERE sale_order_number='R1'), '{"order_state":"rejected","seller_state":"rejected","rejection_reason":"Tickets sold"}');
SELECT state, outcome, reasons, rejection_reason, buy_order_id FROM manual_sub_buy WHERE sale_order_number='R1';
SELECT manual_sub_buy_request('Vivid','R1',NULL,2,2,50,NULL,NULL,'op') IS NOT NULL AS sale_can_be_covered_again;
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, ticket_group_id, qty, max_price_ea, state, buy_order_id) VALUES ('op','Vivid','C1',1,2,50,'bought','778');
SELECT manual_sub_buy_follow_record((SELECT buy_id FROM manual_sub_buy WHERE sale_order_number='C1'), '{"order_state":"canceled","seller_state":"pending"}'), (SELECT reasons FROM manual_sub_buy WHERE sale_order_number='C1');
SELECT 'pre-migration bought rows start pending after backfill rule: ' || (SELECT count(*) FROM manual_sub_buy WHERE state='bought' AND outcome='none' AND buy_order_id IS NOT NULL);
