\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- The search of the other marketplaces, rebuilt on what the event mappers learned (mig 20261114000000).
-- Every order is 2 seats in section 101 row 2 sold at 100 each, with nothing on our own feeds.
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id)
  SELECT g, CASE g WHEN 65 THEN 'Parking: Game 65' ELSE 'Game ' || g END, now() + interval '5 days', 6, 5 FROM generate_series(60,69) g;
INSERT INTO aq_event_map (tevo_event_id, sh_event_id, sg_event_id, vivid_event_id) VALUES
 (60,9060,NULL,NULL),                       -- a StubHub id
 (61,NULL,7061,NULL),                       -- only a SeatGeek link
 (62,NULL,NULL,8062),                       -- only a Vivid id
                                            -- 63: nothing
 (64,9064,NULL,NULL), (64,NULL,NULL,8064),  -- two map rows, the ids split across them
 (65,9065,NULL,NULL),                       -- a parking event
 (66,9066,NULL,NULL), (66,9067,NULL,NULL),  -- two different StubHub ids for one event
 (67,9167,NULL,NULL), (68,9068,NULL,NULL), (69,9069,NULL,NULL);
INSERT INTO sg_events_canonical (sg_event_id, sg_url, tevo_event_id) VALUES
 (7061, 'https://seatgeek.com/game-61-tickets/concert/7061', NULL),
 (7069, 'https://seatgeek.com/game-69-tickets/concert/7069', 69);     -- linked from the catalogue side only
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', td_enabled=true, td_scope='no_cover', td_concurrency=10, settle_min_s=0, settle_timeout_s=180 WHERE id;
CREATE FUNCTION pg_temp.go(VARIADIC p_ev int[]) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  v := (sub_finder_submit(7, 'crm', (SELECT jsonb_agg(jsonb_build_object('order_number', 'O' || e || '-' || txid_current(), 'tevo_event_id', e,
          'section', '101', 'row', '2', 'qty', 2, 'sold_ea', 100)) FROM unnest(p_ev) e))->>'job_id')::uuid;
  INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', e, now() FROM unnest(p_ev) e;
  PERFORM sub_finder_job_json(7, v);                 -- our own feeds answer (nothing), the searches go out
  RETURN v;
END $$;
-- an answer as TicketsData gives it; p_day moves its date away from our event
CREATE FUNCTION pg_temp.answer(p_job uuid, p_ev int, p_conf numeric, p_day int, p_body text, p_code int DEFAULT 200) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO net._http_response (id, status_code, content)
  SELECT request_id, p_code,
         CASE WHEN p_code <> 200 THEN p_body ELSE
           (jsonb_build_object('status', 'success', 'match_type', 'probable', 'match_confidence', p_conf, 'quota_remaining', 5000, 'reports_remaining', 900,
              'event_details', jsonb_build_object('date', ((SELECT left(occurs_at_local::text, 10)::date FROM events WHERE id = p_ev) + p_day)::text))
            || p_body::jsonb)::text END
    FROM sub_finder_td_pull WHERE job_id = p_job AND tevo_event_id = p_ev;
  RETURN sub_finder_job_json(7, p_job)->>'status';
END $$;
CREATE FUNCTION pg_temp.pulls(p_job uuid) RETURNS SETOF text LANGUAGE sql AS $$
  SELECT concat_ws(' | ', 'event ' || p.tevo_event_id, 'asked ' || coalesce(p.seed, '-') || ' ' || regexp_replace(p.event_url, '^https?://(www\.)?', ''),
                   'tried ' || cardinality(p.tried), CASE WHEN p.resolved_at IS NULL THEN 'waiting' ELSE 'answered' END,
                   'note ' || coalesce(p.note, '-'), 'offers ' || coalesce(p.offers::text, '-'), 'learned ' || coalesce(p.learned, '-'),
                   'orders ' || (SELECT string_agg(DISTINCT o.state || '/' || coalesce(o.td_state, '-'), ',') FROM sub_finder_order o WHERE o.job_id = p.job_id AND o.tevo_event_id = p.tevo_event_id))
    FROM sub_finder_td_pull p WHERE p.job_id = p_job ORDER BY p.tevo_event_id $$;
CREATE FUNCTION pg_temp.covers(p_job uuid, p_ev int) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce((SELECT string_agg(c->>'market' || ':' || (c->>'listing_id'), ',' ORDER BY c->>'market', c->>'listing_id')
                     FROM sub_finder_order o, jsonb_array_elements(o.covers) c WHERE o.job_id = p_job AND o.tevo_event_id = p_ev), 'no cover') $$;
\set OFFER '{"listing_id":"L","section":"101","row":"2","quantity":2,"price_total":70,"available_lots":[2],"flags":{}}'

\echo where a search can start from, best first
SELECT e || ': ' || coalesce((SELECT string_agg(seed || CASE WHEN ambiguous THEN ' (one of several)' ELSE '' END, ', ' ORDER BY ord) FROM sub_finder_td_seeds(e)), 'nothing') FROM generate_series(60,69) e;

\echo a StubHub id, a SeatGeek link, a Vivid id, nothing, and a parking event
CREATE TEMP TABLE j1 AS SELECT pg_temp.go(60,61,62,63,65) AS job;
SELECT pg_temp.pulls(job) FROM j1;
SELECT 'orders with no search: ' || string_agg(tevo_event_id || ' ' || td_state, ', ' ORDER BY tevo_event_id) FROM sub_finder_order WHERE job_id = (SELECT job FROM j1) AND tevo_event_id IN (63,65);
\echo a good answer is used, charged, and teaches the map its StubHub and Vivid ids (the map refuses one: no harm)
SELECT pg_temp.answer(job, 60, 95, 0, '{"matches":{"stubhub":"https://www.stubhub.com/game-60/event/9060/","vividseats":"https://www.vividseats.com/e/production/6666","seatgeek":"https://seatgeek.com/g/concert/7060"},"fetch_results":{"normalized":{
  "stubhub":{"offers":[' || :'OFFER' || ']},"seatgeek":{"offers":[{"listing_id":"G60","section":"101","row":"2","quantity":2,"price_total":60,"available_lots":[2],"flags":{}}]}}}}') FROM j1;
\echo sure enough to use (85) but not to teach the map (90): the Vivid search
INSERT INTO n2s_sg_current (tevo_event_id, sg_event_id, section, row, quantity, retail_price_all_in) VALUES (62, 1, '999', '1', 2, 500);
SELECT pg_temp.answer(job, 62, 85, 0, '{"matches":{"stubhub":"https://www.stubhub.com/event/9962"},"fetch_results":{"normalized":{
  "vividseats":{"offers":[' || :'OFFER' || ']},"seatgeek":{"offers":[{"listing_id":"G62","section":"101","row":"2","quantity":2,"price_total":60,"available_lots":[2],"flags":{}}]}}}}') FROM j1;
\echo not sure enough (60): its listings are not used, and with no other link the search has failed
SELECT pg_temp.answer(job, 61, 60, 0, '{"matches":{},"fetch_results":{"normalized":{"stubhub":{"offers":[' || :'OFFER' || ']}}}}') FROM j1;
SELECT pg_temp.pulls(job) FROM j1;
SELECT 'event 60 covers (SeatGeek kept: our own feed has nothing for it): ' || pg_temp.covers(job, 60) FROM j1;
SELECT 'event 62 covers (SeatGeek dropped: our own feed covers it): ' || pg_temp.covers(job, 62) FROM j1;
SELECT 'event 61 covers: ' || pg_temp.covers(job, 61) FROM j1;
SELECT 'the map was told: ' || string_agg(source || ' ' || source_event_id || ' for event ' || tevo_event_id, ', ' ORDER BY n) FROM mapper_told;
SELECT 'charged: ' || count(*) || ' searches, ' || sum(credits) || ' credits, ' || sum(reports) || ' reports' FROM td_charged;
\echo the link that gave the unsure answer is not asked again for 14 days
SELECT event_url, note FROM sub_finder_td_seed_log ORDER BY id;
CREATE TEMP TABLE j2 AS SELECT pg_temp.go(61) AS job;
SELECT 'event 61 again: ' || td_state FROM sub_finder_order WHERE job_id = (SELECT job FROM j2);

\echo another night of the run: the StubHub answer is for the next day, so the Vivid id on the other map row is asked
CREATE TEMP TABLE j3 AS SELECT pg_temp.go(64) AS job;
SELECT pg_temp.pulls(job) FROM j3;
SELECT pg_temp.answer(job, 64, 100, 1, '{"matches":{"stubhub":"https://www.stubhub.com/event/9064"},"fetch_results":{"normalized":{"stubhub":{"offers":[' || :'OFFER' || ']}}}}') FROM j3;
SELECT pg_temp.pulls(job) FROM j3;
SELECT pg_temp.answer(job, 64, 100, 0, '{"matches":{"vividseats":"https://www.vividseats.com/production/8064"},"fetch_results":{"normalized":{"vividseats":{"offers":[' || :'OFFER' || ']}}}}') FROM j3;
SELECT pg_temp.pulls(job) FROM j3;
SELECT 'event 64 covers: ' || pg_temp.covers(job, 64) FROM j3;

\echo two StubHub ids for one event: the first matches but shows nothing (a parking twin), so the second is asked
CREATE TEMP TABLE j4 AS SELECT pg_temp.go(66) AS job;
SELECT pg_temp.answer(job, 66, 95, 0, '{"matches":{},"fetch_results":{"normalized":{"stubhub":{"offers":[{"listing_id":"P","section":"Lot A","row":"1","quantity":2,"price_total":20,"available_lots":[2],"flags":{"parking":true}}]}}}}') FROM j4;
SELECT pg_temp.pulls(job) FROM j4;
SELECT pg_temp.answer(job, 66, 95, 0, '{"matches":{},"fetch_results":{"normalized":{"stubhub":{"offers":[' || :'OFFER' || ']}}}}') FROM j4;
SELECT pg_temp.pulls(job) FROM j4;
\echo a single link that matches and shows nothing is an answer, not a failure
CREATE TEMP TABLE j5 AS SELECT pg_temp.go(67) AS job;
SELECT pg_temp.answer(job, 67, 95, 0, '{"matches":{},"fetch_results":{"normalized":{}}}') FROM j5;
SELECT pg_temp.pulls(job) FROM j5;

\echo no credit left on the plan (402): the rest of the job is not asked
UPDATE sub_finder_config SET td_concurrency = 1 WHERE id;
TRUNCATE net.sent;
CREATE TEMP TABLE j6 AS SELECT pg_temp.go(68,69) AS job;
SELECT 'sent: ' || count(*) FROM net.sent;
SELECT pg_temp.answer(job, 68, 0, 0, 'Payment Required', 402) FROM j6;
SELECT pg_temp.pulls(job) FROM j6;
SELECT 'sent: ' || count(*) FROM net.sent;
\echo our own credit guard says stop: nothing is sent
UPDATE td_stub SET budget_ok = false;
TRUNCATE net.sent;
CREATE TEMP TABLE j7 AS SELECT pg_temp.go(69) AS job;
SELECT pg_temp.pulls(job) FROM j7;
SELECT 'sent: ' || count(*) FROM net.sent;
\echo the switch for teaching the map
UPDATE td_stub SET budget_ok = true; UPDATE sub_finder_config SET td_writeback = false WHERE id; TRUNCATE mapper_told;
CREATE TEMP TABLE j8 AS SELECT pg_temp.go(69) AS job;
SELECT pg_temp.answer(job, 69, 100, 0, '{"matches":{"stubhub":"https://www.stubhub.com/event/9069"},"fetch_results":{"normalized":{"stubhub":{"offers":[' || :'OFFER' || ']}}}}') FROM j8;
SELECT pg_temp.pulls(job) FROM j8;
SELECT 'the map was told: ' || count(*) FROM mapper_told;
