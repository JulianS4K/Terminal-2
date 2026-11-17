\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', buy_enabled=true, buy_key_ids='{7}', gt_offer_enabled=true, gt_offer_key_ids='{7}', auto_buy_enabled=false, gt_offer_auto_buy=true WHERE id;
UPDATE manual_sub_buy_config SET enabled=true, kill_switch=false WHERE id;
-- one line per check: name, status and the facts that do not move with the clock
CREATE FUNCTION h(p_key bigint DEFAULT 7) RETURNS SETOF text LANGUAGE sql AS $$
  SELECT 'overall ' || (r->>'status') FROM sub_finder_health(p_key) r
  UNION ALL
  SELECT * FROM (SELECT (e->>'name') || ' ' || (e->>'status') || ' '
                        || (e - 'what' - 'last_at' - 'age_seconds' - 'oldest_waiting_seconds' - 'oldest_unanswered_seconds'
                              - 'name' - 'status' - 'ok_within_seconds' - 'down_after_seconds')::text
                   FROM sub_finder_health(p_key) r, jsonb_array_elements(r->'checks') WITH ORDINALITY x(e, o) ORDER BY o) y $$;

\echo A nothing has ever run: every reader is down, the switched-on parts with nothing waiting are ok
SELECT h();

\echo B everything fresh: ok, and the answer names no table of ours
INSERT INTO n2s_crm_direct_log (fetched_at, status, ms, items, upserted) VALUES (now() - interval '40 seconds', 200, 61000, 250, 250);
INSERT INTO s4kcs_orders (last_seen_at) VALUES (now() - interval '8 minutes');
INSERT INTO account_balance_run (taken_at, evo_http, evo_rows, gt_http, gt_rows) VALUES (now() - interval '50 minutes', 200, 3, 200, 2);
SELECT h();
SELECT r::text ~ '(sub_finder_|n2s_crm|s4kcs|manual_sub|account_balance|mlb_ticket)' AS names_a_table, r ? 'checked_at', jsonb_object_keys(r->'statuses') FROM sub_finder_health(7) r;

\echo C the CRM feed: a failed try after a good read keeps the good read and shows the failure; late is degraded, very late is down
INSERT INTO n2s_crm_direct_log (fetched_at, status, error) VALUES (now() - interval '5 seconds', 401, 'unauthorized');
SELECT e->>'status', e->>'last_attempt_http', e->>'last_read_items', (e->>'age_seconds')::int BETWEEN 39 AND 45 FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'crm_feed';
UPDATE n2s_crm_direct_log SET fetched_at = now() - interval '10 minutes' WHERE status = 200;
SELECT r->>'status', e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'crm_feed';
UPDATE n2s_crm_direct_log SET fetched_at = now() - interval '30 minutes' WHERE status = 200;
SELECT r->>'status', e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'crm_feed';
DELETE FROM n2s_crm_direct_log; INSERT INTO n2s_crm_direct_log (fetched_at, status, ms, items, upserted) VALUES (now(), 200, 500, 3, 3);

\echo D the order book and the balances late
UPDATE s4kcs_orders SET last_seen_at = now() - interval '45 minutes';
UPDATE account_balance_run SET taken_at = now() - interval '7 hours';
SELECT h();
UPDATE s4kcs_orders SET last_seen_at = now(); UPDATE account_balance_run SET taken_at = now();
INSERT INTO account_balance_run (taken_at, error) VALUES (now(), 'timeout');     -- a failed run is not a good run
SELECT e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'balances';

\echo E lookups: a watched order re-checked lately is ok; an unanswered lookup 20 minutes old is degraded, 2 hours old is down; another key sees its own
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) VALUES (95,'Game 95', now() + interval '5 days', 6, 5);
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES (95,9501,'101','2',2,90,'{2}',false,false);
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES ('StubHub','7501',95,'101','2',2,100);
UPDATE sub_finder_config SET settle_min_s=0 WHERE id;
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"7501"}]')->>'job_id')::uuid AS job;
SELECT sub_finder_job_json(7,(SELECT job FROM j))->>'status';
UPDATE sub_finder_order SET watching = true, refreshed_at = now() - interval '2 minutes';
SELECT h();
UPDATE sub_finder_order SET refreshed_at = now() - interval '25 minutes';
SELECT e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'lookups';
UPDATE sub_finder_order SET refreshed_at = now();
UPDATE sub_finder_job SET status = 'pulling', created_at = now() - interval '20 minutes';
SELECT e->>'status', e->>'lookups_unanswered' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'lookups';
UPDATE sub_finder_job SET created_at = now() - interval '2 hours';
SELECT r->>'status', e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'lookups';
UPDATE sub_finder_config SET key_ids='{7,8}' WHERE id;
SELECT e->>'status', e->>'lookups_unanswered', e->>'orders_watched' FROM sub_finder_health(8) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'lookups';
UPDATE sub_finder_job SET status = 'done';

\echo F buying: a buy waiting 20 minutes is degraded; a buy of unknown outcome, or the safety switch, is down; switched off is off and does not lower the overall status
INSERT INTO manual_sub_buy (requested_by, sale_site, sale_order_number, tevo_event_id, ticket_group_id, qty, max_price_ea, state, created_at)
VALUES ('crm','StubHub','7501',95,9501,2,90,'requested', now() - interval '20 minutes');
SELECT r->>'status', e->>'status', e->>'buys_waiting', e->>'detail' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'buying';
UPDATE manual_sub_buy SET state = 'unknown';
SELECT r->>'status', e->>'status', e->>'buys_to_check', e->>'detail' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'buying';
UPDATE manual_sub_buy SET state = 'bought';
UPDATE manual_sub_buy_config SET kill_switch = true WHERE id;
SELECT e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'buying';
UPDATE manual_sub_buy_config SET kill_switch = false, enabled = false WHERE id;
SELECT r->>'status', e->>'status', e->>'detail' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'buying';
UPDATE manual_sub_buy_config SET enabled = true WHERE id;
UPDATE sub_finder_config SET buy_enabled = false, gt_offer_enabled = false, auto_buy_enabled = true, gt_offer_auto_buy = false WHERE id;
SELECT r->>'status', e->>'name', e->>'status', e->>'automatic_buying', e->>'buy_after_accept' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' IN ('buying','offers') ORDER BY 2;
UPDATE sub_finder_config SET buy_enabled = true, gt_offer_enabled = true WHERE id;

\echo G offers: one waiting 20 minutes is degraded, 2 hours is down; one sent with its outcome unknown is degraded
INSERT INTO sub_finder_gt_offer (job_id, idx, key_id, requested_by, order_number, gt_order_id, gate, market, listing_id, section, seat_row, qty, buy_qty, price_ea, order_total, sub_total, state, live, created_at)
SELECT job_id, idx, 7, 'crm', order_number, 1, 3, 'evo', '9501', '101', '2', 2, 2, 90, 200, 180, 'requested', true, now() - interval '20 minutes' FROM sub_finder_order LIMIT 1;
SELECT e->>'status', e->>'offers_waiting', e->>'detail' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'offers';
UPDATE sub_finder_gt_offer SET created_at = now() - interval '2 hours';
SELECT e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'offers';
UPDATE sub_finder_gt_offer SET state = 'unknown';
SELECT e->>'status', e->>'offers_to_check', e->>'detail' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'offers';
UPDATE sub_finder_gt_offer SET state = 'stopped', live = false;

\echo H the MLB schedule: no check until its tables exist; collected but not served is off; served and fresh is ok; stale is degraded then down
SELECT count(*) FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'mlb_schedule';
CREATE TABLE public.mlb_ticket_sync (team_id int, season int, last_ok_at timestamptz, last_error_at timestamptz, last_error text);
INSERT INTO mlb_ticket_sync VALUES (147, 2027, now() - interval '3 hours', NULL, NULL), (121, 2027, now() - interval '5 hours', now() - interval '1 hour', 'http 500'),
                                   (111, 2026, now() - interval '20 days', now() - interval '21 days', 'old');
SELECT r->>'status', e->>'status', e->>'clubs_failing', e->>'detail' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'mlb_schedule';
CREATE VIEW public.v_mlb_schedule_feed AS SELECT 1 AS mlb_schedule_id;
SELECT r->>'status', e->>'status', e->>'clubs_failing', e ? 'detail' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'mlb_schedule';
UPDATE mlb_ticket_sync SET last_ok_at = last_ok_at - interval '30 hours';
SELECT r->>'status', e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'mlb_schedule';
UPDATE mlb_ticket_sync SET last_ok_at = last_ok_at - interval '4 days';
SELECT r->>'status', e->>'status' FROM sub_finder_health(7) r, jsonb_array_elements(r->'checks') e WHERE e->>'name' = 'mlb_schedule';

\echo I a key that may not look up subs is refused; nobody but the service role may call it
SELECT sub_finder_health(99);
SELECT has_function_privilege('anon', 'public.sub_finder_health(bigint)', 'EXECUTE'), has_function_privilege('authenticated', 'public.sub_finder_health(bigint)', 'EXECUTE');
SELECT sub_finder_health_grade(NULL, 10, 20), sub_finder_health_grade(10, 10, 20), sub_finder_health_grade(20, 10, 20), sub_finder_health_grade(21, 10, 20);
