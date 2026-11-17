\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- When a buy stops, move on to the next cover (mig 20261113310000). Sales are 100 x2 = 200.
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'F'||g,now()+interval '5 days',999,5 FROM generate_series(130,133) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (130,13001,'101','2',2,80,'{2}',false,false), (130,13002,'101','2',2,85,'{2}',false,false),   -- two one-to-one covers
 (131,13101,'101','2',2,80,'{2}',false,false), (131,13102,'101','1',2,90,'{2}',false,false),   -- the CRM picks the second by hand
 (132,13201,'101','2',2,80,'{2}',false,false), (132,13202,'101','2',2,85,'{2}',false,false),   -- stopped by a spend ceiling
 (133,13301,'101','2',2,80,'{2}',false,false), (133,13302,'101','2',2,85,'{2}',false,false);   -- the seller rejects after the buy
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) SELECT 'StubHub','F'||g,g,'101','2',2,100 FROM generate_series(130,133) g;
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true, buy_enabled=true, buy_key_ids='{7}',
  refresh_enabled=true, refresh_pull=true, feed_check_every='0 seconds' WHERE id;
UPDATE manual_sub_buy_config SET enabled=true, per_order_cap_usd=750, daily_cap_usd=4000 WHERE id;
CREATE FUNCTION pg_temp.stop_next(p_reasons text) RETURNS text LANGUAGE sql AS $$
  SELECT (j->'row'->>'sale_order_number') || ' listing ' || (j->'row'->>'ticket_group_id') || ' -> ' ||
         manual_sub_buy_record((j->'row'->>'buy_id')::bigint, (j->'row'->>'lease_token')::uuid,
                               jsonb_build_object('state', 'stopped', 'reasons', string_to_array(p_reasons, ',')))
    FROM (SELECT manual_sub_buy_claim() j) q $$;
CREATE FUNCTION pg_temp.orders() RETURNS TABLE(o text) LANGUAGE sql AS $$
  SELECT concat_ws('|', o.order_number, o.action, coalesce(o.auto_buy_note,'-'),
           coalesce((SELECT b.ticket_group_id || ':' || b.state FROM manual_sub_buy b WHERE b.buy_id = o.buy_id), 'no buy'),
           (SELECT count(*) FROM manual_sub_buy b WHERE b.sale_order_number = o.order_number))
    FROM sub_finder_order o WHERE o.watching ORDER BY o.order_number $$;

\echo the cheapest one-to-one cover is requested for each order
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"F130"},{"order_number":"F131"},{"order_number":"F132"},{"order_number":"F133"}]')->>'job_id')::uuid id;
SELECT pg_temp.orders();

\echo the four buys end differently: listing gone / listing gone / over a spend ceiling / bought, then the seller rejects
SELECT pg_temp.stop_next('listing_gone');
SELECT pg_temp.stop_next('listing_gone');
SELECT pg_temp.stop_next('over_daily_cap');
CREATE TEMP TABLE c4 AS SELECT manual_sub_buy_claim() j;
SELECT manual_sub_buy_record((j->'row'->>'buy_id')::bigint, (j->'row'->>'lease_token')::uuid, '{"state":"bought","buy_order_id":"70133","bought_price_ea":80,"bought_total_usd":160}') FROM c4;
SELECT manual_sub_buy_follow_record((j->'row'->>'buy_id')::bigint, '{"seller_state":"rejected","order_state":"rejected","rejection_reason":"sold elsewhere"}') FROM c4;
SELECT sub_finder_stop_is_listing('{listing_gone}'), sub_finder_stop_is_listing('{seller_rejected}'), sub_finder_stop_is_listing('{over_daily_cap}'),
       sub_finder_stop_is_listing('{listing_gone,over_order_cap}'), sub_finder_stop_is_listing('{}');

\echo switch off: nothing is released, the stopped buys stay on their orders
SELECT sub_finder_refresh() ? 'closed', sub_finder_release_stopped();
SELECT pg_temp.orders();

\echo a person may still buy a different cover for an order whose buy stopped (F131), and the dead listing is named
SELECT r->>'state', r->>'listing_id', r->>'detail' FROM (SELECT sub_finder_buy(7,'crm',(SELECT id FROM j),'F131','13102','dana') r) q;
SELECT i->>'order_number', i->'last_stopped_buy'->>'listing_id', i->'last_stopped_buy'->'reasons', i->'buy'->>'request_state'
  FROM (SELECT sub_finder_job_json(7,(SELECT id FROM j)) r) q, jsonb_array_elements(r->'items') i ORDER BY 1;
SELECT pg_temp.stop_next('listing_gone');

\echo switch on: the listing stops are released (F130, F131, F133); the spend-ceiling stop is not (F132)
UPDATE sub_finder_config SET buy_fallback_enabled=true WHERE id;
SELECT sub_finder_release_stopped();
SELECT pg_temp.orders();

\echo the next match takes the next cover, never the listing that stopped
UPDATE n2s_evo_current SET pulled_at = now() + interval '1 second';
SELECT sub_finder_refresh() ? 'closed';
SELECT pg_temp.orders();
SELECT sale_order_number, ticket_group_id, state, reasons FROM manual_sub_buy ORDER BY sale_order_number, buy_id;

\echo the second cover stops too: with no untried cover left nothing more is requested
SELECT pg_temp.stop_next('price_above_ceiling');
SELECT pg_temp.stop_next('listing_gone');
SELECT sub_finder_release_stopped();
UPDATE n2s_evo_current SET pulled_at = now() + interval '2 second';
SELECT sub_finder_refresh() ? 'closed';
SELECT pg_temp.orders();

\echo attempts per order per day are limited (buy_fallback_max): with the limit lowered to 2, a third stop is not released
SELECT sale_order_number, count(*) FILTER (WHERE state='stopped') FROM manual_sub_buy GROUP BY 1 ORDER BY 1;
UPDATE sub_finder_config SET buy_fallback_max=2 WHERE id;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,pulled_at) VALUES (130,13003,'101','2',2,86,'{2}',false,false, now() + interval '3 second');
SELECT sub_finder_refresh() ? 'closed';
SELECT pg_temp.orders();
SELECT pg_temp.stop_next('listing_gone');
SELECT sub_finder_release_stopped();
SELECT pg_temp.orders();
