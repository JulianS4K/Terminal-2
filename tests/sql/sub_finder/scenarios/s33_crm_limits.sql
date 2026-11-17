\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'Game '||g, now() + interval '5 days', 6, 5 FROM generate_series(90,92) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (90,9001,'101','2',2,120,'{2}',false,false),    -- clean pair at a loss: 240 against a 200 sale (120%)
 (91,9101,'101','4',2,70,'{2}',false,false),     -- rows back on a GoTickets sale: gate 5
 (92,9201,'101','2',2,120,'{2}',false,false);    -- the same loss on another marketplace
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','7001',90,'101','2',2,100),('GoTickets','7002',91,'101','2',2,100),('SeatGeek','7003',92,'101','2',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=false, buy_enabled=true, buy_key_ids='{7}', gt_offer_enabled=true, gt_offer_key_ids='{7}' WHERE id;
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"7001"},{"order_number":"7002"},{"order_number":"7003"}]')->>'job_id')::uuid AS job;
SELECT sub_finder_job_json(7,(SELECT job FROM j))->>'status';
SELECT order_number, site, best->>'label', best->>'total' FROM sub_finder_order ORDER BY 1;

\echo A nothing set: no percentage limit on a buy, a rebate may be up to the sale total
SELECT r->'rebate_max_pct'->'default', r->'buy_max_cost_pct'->'default', r->'can_set', r->'s4k_ceilings' FROM sub_finder_limits(7) r;
SELECT sub_finder_access(7)->'limits';
SELECT sub_finder_rebate_limit(200, 'GoTickets'), sub_finder_crm_limit_pct('buy_max_cost', 'StubHub') IS NULL;

\echo B the CRM sets its limits: a default and one marketplace of its own
SELECT r->'rebate_max_pct', r->'buy_max_cost_pct' FROM sub_finder_limits_set(7, 'crm buy',
  '{"rebate_max_pct": {"default": 40, "by_marketplace": {"GoTickets": 25}},
    "buy_max_cost_pct": {"default": 110, "by_marketplace": {"seat geek": 125}}}', 'dana') r;
SELECT sub_finder_access(7)->'limits';
SELECT kind, site, old_pct, new_pct, set_by FROM sub_finder_crm_limit_log ORDER BY id;

\echo C a buy over the CRM limit for its marketplace is refused; inside it goes through
SELECT sub_finder_buy_confirmed(7,'crm buy',(SELECT job FROM j),'7001','9001','dana',true);
SELECT sub_finder_buy_confirmed(7,'crm buy',(SELECT job FROM j),'7003','9201','dana',true)->>'state';

\echo D the rebate limit is the one the CRM set: 25% of a 200 GoTickets sale is 50
SELECT j->>'rebate_suggested' FROM sub_finder_order o, sub_finder_offer_json(o) j WHERE order_number='7002';
SELECT sub_finder_gt_offer_confirmed(7,'crm buy','7002','9101',NULL,'dana',60,true);
SELECT sub_finder_gt_offer_confirmed(7,'crm buy','7002','9101',NULL,'dana',50,true) - 'offer_id';

\echo E one value changed, one cleared; the rest stands
SELECT r->'rebate_max_pct', r->'buy_max_cost_pct' FROM sub_finder_limits_set(7, 'crm buy',
  '{"rebate_max_pct": {"by_marketplace": {"gotickets": null}}, "buy_max_cost_pct": {"default": 150}}', NULL) r;
SELECT sub_finder_rebate_limit(200, 'GoTickets'), sub_finder_crm_limit_pct('buy_max_cost', 'StubHub'), sub_finder_crm_limit_pct('buy_max_cost', 'SeatGeek');
\echo the outer bound S4K keeps still wins when it is lower
UPDATE sub_finder_config SET gt_offer_rebate_max_pct = 10 WHERE id;
SELECT sub_finder_rebate_limit(200, 'GoTickets'), sub_finder_access(7)->'limits'->'rebate_max_pct';
UPDATE sub_finder_config SET gt_offer_rebate_max_pct = NULL WHERE id;

\echo F with a limit set, an order with no sale price cannot be measured
UPDATE sub_finder_order SET sold_ea = NULL, buy_id = NULL WHERE order_number = '7001';
SELECT r->>'error', r->>'detail', r->>'limit' FROM sub_finder_buy_confirmed(7,'crm buy',(SELECT job FROM j),'7001','9001','dana',true) r;

\echo G bad input changes nothing
CREATE TEMP TABLE before AS SELECT * FROM sub_finder_crm_limit;
SELECT r->>'error', left(r->>'detail', 60) FROM (VALUES
  ('{}'::jsonb), ('[1]'), ('{"rebate_max_pct": 40}'), ('{"rebate_max_pct": {}}'), ('{"rebate_max_pct": {"default": 101}}'),
  ('{"rebate_max_pct": {"default": "40"}}'), ('{"buy_max_cost_pct": {"default": 0}}'), ('{"buy_max_cost_pct": {"default": 1001}}'),
  ('{"buy_max_cost_pct": {"by_marketplace": {"123": 120}}}'), ('{"buy_max_cost_pct": {"by_marketplace": [1]}}'),
  ('{"rebate_max_pct": {"default": 30}, "buy_max_cost_pct": {"default": 5000}}')) v(b), sub_finder_limits_set(7, 'crm buy', v.b, NULL) r;
SELECT (SELECT count(*) FROM (SELECT kind, site, pct FROM sub_finder_crm_limit EXCEPT SELECT kind, site, pct FROM before) x) = 0
   AND (SELECT count(*) FROM sub_finder_crm_limit) = (SELECT count(*) FROM before);
\echo a key that may neither buy nor offer cannot set them, and an unknown key cannot read them
UPDATE sub_finder_config SET buy_key_ids='{}', gt_offer_key_ids='{}' WHERE id;
SELECT sub_finder_limits_set(7, 'crm read', '{"rebate_max_pct": {"default": 5}}', NULL), sub_finder_limits(7)->'can_set';
SELECT sub_finder_limits(99);
