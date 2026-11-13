\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
UPDATE sub_finder_config SET td_enabled=false, settle_min_s=0, buy_enabled=false;
SELECT 'cron: ' || schedule || ' ' || command FROM cron.scheduled;
DELETE FROM n2s_evo_current; DELETE FROM n2s_gt_current; DELETE FROM n2s_sg_current; DELETE FROM n2s_items; DELETE FROM v_s4kcs_orders;
INSERT INTO events VALUES (77,'Future Game', now() + interval '10 days'), (78,'Old Game', now() - interval '2 days') ON CONFLICT DO NOTHING;
INSERT INTO n2s_items (n2s_id, order_number, n2s_order_key, marketplace, tevo_event_id, event_name, event_dt, venue, section, row, qty, price_per_ticket) VALUES
 (1,'W1','W1','StubHub',77,'x', now() + interval '10 days','v','100','5',2,100),
 (2,'W2','W2','StubHub',77,'x', now() + interval '10 days','v','200','5',2,100),
 (3,'W3','W3','StubHub',77,'x', now() + interval '10 days','v','100','5',2,100),
 (4,'W5','W5','StubHub',78,'x', now() - interval '2 days','v','100','5',2,100);
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,pulled_at) VALUES (77,1,'100','4',2,80,'{2}',false,false, now());
INSERT INTO n2s_gt_current (tevo_event_id,gt_event_id,gt_listing_id,section,row,quantity,all_in_price,splits,pulled_at) VALUES (77,9,2,'100','5',2,90,'{2}', now());
CREATE TEMP TABLE w AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"W1"},{"order_number":"W2"},{"order_number":"W3"},{"order_number":"W4","tevo_event_id":77,"section":"100","row":"5","qty":2,"sold_ea":100},{"order_number":"W5"}]')->>'job_id')::uuid job;
UPDATE n2s_mkt_pull SET resolved_at=now();
SELECT i->>'order_number', i->>'state', i->'best'->>'market', i->'best'->>'price_ea', jsonb_array_length(i->'covers'), i->>'watching' FROM (SELECT sub_finder_job_json(7,(SELECT job FROM w)) r) q, jsonb_array_elements(r->'items') i;
\echo R1 off by default:
SELECT sub_finder_refresh();
UPDATE sub_finder_config SET refresh_enabled=true;
\echo R2 nothing newer landed: closes the past-event order only, no churn:
CREATE TEMP TABLE u0 AS SELECT idx, updated_at FROM sub_finder_order WHERE job_id=(SELECT job FROM w);
SELECT sub_finder_refresh();
SELECT order_number, watching, coalesce(closed_reason,'-'), refresh_count FROM sub_finder_order WHERE job_id=(SELECT job FROM w) ORDER BY idx;
SELECT 'refresh fired pulls: ' || count(*) FROM n2s_mkt_pull WHERE resolved_at IS NULL;
\echo R3 a cheaper EVO listing lands; GoTickets has nothing fresh (failed pull) -> its cover is kept; W2 (no cover) now gets one:
SELECT pg_sleep(0.05);
DELETE FROM n2s_evo_current;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,pulled_at) VALUES (77,3,'100','3',2,60,'{2}',false,false, now()), (77,4,'200','5',2,95,'{2}',false,false, now());
UPDATE n2s_gt_current SET pulled_at = now() - interval '30 minutes';
SELECT sub_finder_refresh();
SELECT o.order_number, o.state, o.best->>'market', o.best->>'listing_id', o.best->>'price_ea', (SELECT string_agg(c->>'market'||':'||(c->>'listing_id'), ',') FROM jsonb_array_elements(o.covers) c), o.refresh_count, o.updated_at > u0.updated_at AS feed_moved FROM sub_finder_order o JOIN u0 USING (idx) WHERE o.job_id=(SELECT job FROM w) AND o.watching ORDER BY o.idx;
\echo R4 same listings again (fresh pull, nothing changed): refreshed but the feed does not move:
CREATE TEMP TABLE u1 AS SELECT idx, updated_at, refresh_count FROM sub_finder_order WHERE job_id=(SELECT job FROM w);
SELECT pg_sleep(0.05);
UPDATE n2s_evo_current SET pulled_at = now();
SELECT sub_finder_refresh()->>'jobs_rematched';
SELECT o.order_number, o.refresh_count > u1.refresh_count AS rechecked, o.updated_at = u1.updated_at AS feed_quiet FROM sub_finder_order o JOIN u1 USING (idx) WHERE o.job_id=(SELECT job FROM w) AND o.watching ORDER BY o.idx;
\echo R5 the listing sells (fresh EVO pull without it): cover drops back, feed moves:
SELECT pg_sleep(0.05);
DELETE FROM n2s_evo_current WHERE tevo_ticket_group_id = 4;
UPDATE n2s_evo_current SET pulled_at = now();
SELECT sub_finder_refresh()->>'jobs_rematched';
SELECT order_number, state, jsonb_array_length(covers) FROM sub_finder_order WHERE job_id=(SELECT job FROM w) AND order_number='W2';
\echo R6 stop conditions: W1 leaves the CRM book, W3 goes terminal, W4 is fulfilled in our feed:
DELETE FROM n2s_items WHERE order_number='W1';
UPDATE n2s_items SET is_terminal=true, status='resolved' WHERE order_number='W3';
INSERT INTO v_sub_orders VALUES ('Vivid','W4','fulfilled',false), ('Vivid','W2','accepted',true);
SELECT 'feed check is paced: W4 was looked at ' || count(*) || ' time(s) recently' FROM sub_finder_order WHERE order_number='W4' AND feed_checked_at > now() - interval '15 minutes';
UPDATE sub_finder_order SET feed_checked_at = now() - interval '16 minutes' WHERE order_number IN ('W4','W2');
SELECT sub_finder_refresh()->>'closed';
SELECT order_number, watching, coalesce(closed_reason,'-') FROM sub_finder_order WHERE job_id=(SELECT job FROM w) ORDER BY idx;
SELECT i->>'order_number', i->>'watching', i->>'closed_reason' FROM (SELECT sub_finder_order_read(7,(SELECT job FROM w),'W4') r) q, jsonb_array_elements(r->'items') i;
\echo R6b routine data already there: an alert is answered in the same call, nothing pulled:
UPDATE n2s_evo_current SET pulled_at = now();
CREATE TEMP TABLE np AS SELECT count(*) n FROM n2s_mkt_pull;
SELECT sub_finder_submit(7,'crm','[{"order_number":"NOW1","tevo_event_id":77,"section":"100","row":"5","qty":2}]')->>'status';
SELECT (SELECT count(*) FROM n2s_mkt_pull) = (SELECT n FROM np) AS no_pull, state, best->>'market' FROM sub_finder_order WHERE order_number='NOW1';
\echo R6c refresh_pull on: it does fire:
UPDATE sub_finder_config SET refresh_pull = true;
SELECT sub_finder_refresh() ->> 'events' IS NOT NULL;
SELECT (SELECT count(*) FROM n2s_mkt_pull) > (SELECT n FROM np) AS pulled;
UPDATE sub_finder_config SET refresh_pull = false;
\echo R7 a new alert for W2 takes over from the old lookup:
SELECT (sub_finder_submit(7,'crm','[{"order_number":"W2"}]')->>'order_count');
SELECT order_number, watching, coalesce(closed_reason,'-') FROM sub_finder_order WHERE order_number='W2' ORDER BY updated_at;
