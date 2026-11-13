\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- The automatic buy's loss limit (mig 20261113320000): need2buy orders only, by the marketplace
-- the order sold on, set by the CRM as a percent of the sale total (100 to 200). Sales are 100 x2 = 200.
INSERT INTO mcp_api_keys VALUES (7,'crm') ON CONFLICT DO NOTHING;
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'N'||g,now()+interval '5 days',999,5 FROM generate_series(140,144) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (140,14001,'101','2',2,104,'{2}',false,false),   -- need2buy, StubHub: 208 = 104% of the sale
 (141,14101,'101','2',2,106,'{2}',false,false),   -- need2buy, StubHub: 212 = 106%
 (142,14201,'101','2',2,104,'{2}',false,false),   -- need2buy, Vivid:   208 = 104%
 (143,14301,'101','2',2,101,'{2}',false,false),   -- NOT need2buy: 202 = 101%
 (144,14401,'101','2',2,95,'{2}',false,false);    -- NOT need2buy: 190, a profit
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket)
 SELECT CASE WHEN g = 142 THEN 'Vivid Seats' ELSE 'StubHub' END, 'N'||g, g, '101','2',2,100 FROM generate_series(140,144) g;
INSERT INTO n2s_items (n2s_id,order_number,marketplace,tevo_event_id,section,row,qty,price_per_ticket,status,status_label,item_source,raw)
 SELECT g, 'N'||g, CASE WHEN g = 142 THEN 'Vivid Seats' ELSE 'StubHub' END, g, '101','2',2,100,'need2buy','Need2Buy','manual','{}' FROM generate_series(140,142) g;
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true, refresh_enabled=true, refresh_pull=true,
  feed_check_every='0 seconds', n2b_intake_enabled=true, n2b_key_id=7 WHERE id;
CREATE FUNCTION pg_temp.orders() RETURNS TABLE(o text) LANGUAGE sql AS $$
  SELECT concat_ws('|', o.order_number, o.site, o.via_need2buy, o.best->>'gate', o.best->>'total', o.action, coalesce(o.auto_buy_note,'-'),
           (sub_finder_order_json(o)->>'auto_buy_max_cost_pct'),
           coalesce((SELECT manual_sub_buy_total_ceiling(b)::text FROM manual_sub_buy b WHERE b.buy_id = o.buy_id), 'no buy'))
    FROM sub_finder_order o WHERE o.watching ORDER BY o.order_number $$;

\echo what the CRM reads before anything is set: 105 everywhere, and this key may not set it yet
SELECT r->>'default_max_cost_pct', r->'by_marketplace', r->>'can_set', r->>'min', r->>'max' FROM (SELECT sub_finder_loss_limits(7) r) q;
SELECT sub_finder_loss_limits_set(7,'crm','{"default_max_cost_pct":110}')->>'error';
SELECT sub_finder_loss_limits(8)->>'error';

\echo default limit 105: the need2buy order at 104% is bought, the one at 106% is not; a plain order is bought at a profit only
SELECT sub_finder_refresh() ? 'closed';
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"N143"},{"order_number":"N144"}]')->>'job_id')::uuid id;
SELECT pg_temp.orders();

\echo the CRM sets limits by marketplace: StubHub 110, Vivid 100 (no loss); bad values change nothing
UPDATE sub_finder_config SET loss_limit_key_ids='{7}' WHERE id;
SELECT r->>'error', r->>'detail' FROM (SELECT sub_finder_loss_limits_set(7,'crm','{"by_marketplace":{"stubhub":110,"vivid":99}}') r) q;
SELECT r->>'error', r->>'detail' FROM (SELECT sub_finder_loss_limits_set(7,'crm','{"by_marketplace":{"stubhub":201}}') r) q;
SELECT r->>'error', r->>'detail' FROM (SELECT sub_finder_loss_limits_set(7,'crm','{"by_marketplace":{"stubhub":"110"}}') r) q;
SELECT r->>'error', r->>'detail' FROM (SELECT sub_finder_loss_limits_set(7,'crm','{"by_marketplace":{"!!":110}}') r) q;
SELECT r->>'error' FROM (SELECT sub_finder_loss_limits_set(7,'crm','{"limits":1}') r) q;
SELECT r->>'error' FROM (SELECT sub_finder_loss_limits_set(7,'crm','[110]') r) q;
SELECT count(*) FROM sub_finder_loss_limit;
SELECT r->>'default_max_cost_pct', r->'by_marketplace', r->>'can_set' FROM (SELECT sub_finder_loss_limits_set(7,'crm','{"by_marketplace":{"StubHub 2.0":110,"Vivid Seats":100}}','dana') r) q;
SELECT sub_finder_max_loss_pct('Stubhub', true), sub_finder_max_loss_pct('Vivid', true), sub_finder_max_loss_pct('GoTickets', true), coalesce(sub_finder_max_loss_pct('Stubhub', false)::text, 'profit only');

\echo at the next match the StubHub order at 106% is bought (the Vivid order was already requested under the default)
UPDATE n2s_evo_current SET pulled_at = now() + interval '1 second';
SELECT sub_finder_refresh() ? 'closed';
SELECT pg_temp.orders();

\echo the default for every other marketplace can be set too, up to 200; null takes a marketplace back to the default
SELECT r->>'default_max_cost_pct', r->'by_marketplace' FROM (SELECT sub_finder_loss_limits_set(7,'crm','{"default_max_cost_pct":200,"by_marketplace":{"vivid":null}}') r) q;
SELECT sub_finder_max_loss_pct('Vivid', true), sub_finder_max_loss_pct('Stubhub', true);
SELECT sub_finder_autobuy_gate('{"gate":2,"profit":-200,"total":400}', 100), sub_finder_autobuy_gate('{"gate":2,"profit":-200.01,"total":400.01}', 100),
       sub_finder_autobuy_gate('{"gate":2,"profit":-1,"total":201}', NULL), sub_finder_autobuy_gate('{"gate":1,"profit":5,"total":195}', NULL),
       sub_finder_autobuy_gate('{"gate":3,"profit":5,"total":195}', 100);
SELECT r->>'default_max_cost_pct' FROM (SELECT sub_finder_loss_limits_set(7,'crm','{"default_max_cost_pct":null}') r) q;

\echo every change is kept
SELECT site, coalesce(old_pct::text,'-'), coalesce(new_pct::text,'-'), set_by FROM sub_finder_loss_limit_log ORDER BY id;

\echo a buy that ends at a loss is put in the gate 2 category afterwards; one that made money stays gate 1
UPDATE manual_sub_buy SET state='bought', order_total_usd=209 WHERE sale_order_number='N140';
UPDATE manual_sub_buy SET state='bought', order_total_usd=191 WHERE sale_order_number='N144';
SELECT o.order_number, j->'buy'->>'total', j->'buy'->>'profit_actual', j->'buy'->>'gate_actual', j->'buy'->>'label_actual'
  FROM sub_finder_order o, LATERAL (SELECT sub_finder_order_json(o) j) q WHERE o.order_number IN ('N140','N144') AND o.watching ORDER BY 1;
