\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- Accessible (ADA / wheelchair) seats and ordinary seats never replace each other (mig
-- 20261117100000, operator 2026-11-17 on StubHub order 659535353, section "204LWC"). The marker
-- may be in the row or in the section. Sales are 100 x2; every listing is 80 x2 on EVO, so each
-- would otherwise be a profitable buy.
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'G'||g,now()+interval '5 days',6,5 FROM generate_series(301,308) g;
INSERT INTO zone_stub VALUES (5,6,'101','Lower'),(5,6,'102','Lower'),(5,6,'102WC','Lower');
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (301,30101,'204LWC','1',2,80,'{2}',false,false),   -- sold 204LWC: the accessible seats themselves
 (302,30201,'103','WC',2,80,'{2}',false,false),     -- sold 103 row C, listing row WC
 (303,30301,'103WC','20',2,80,'{2}',false,false),   -- sold 103WC, listing 103WC
 (304,30401,'102WC','3',2,80,'{2}',false,false),    -- sold 101 row 3 (ordinary), the only zone listing is accessible
 (305,30501,'102','3',2,80,'{2}',false,false),      -- sold 101 row 3 (ordinary), an ordinary zone listing
 (306,30601,'101','2',2,80,'{2}',false,false),      -- sold 101 row 2, listing 101 row 2: nothing accessible about it
 (307,30701,'101','4',2,70,'{2}',false,false),      -- a GoTickets sale in 101 row 2, listing two rows back
 (308,30801,'101','2',2,80,'{2}',false,false);      -- sold 101 row 2, looked up later (E)
INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', g, now() FROM generate_series(301,308) g;
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','A301',301,'204LWC','1',2,100), ('StubHub','A302',302,'103','C',2,100), ('StubHub','A303',303,'103WC','20',2,100),
 ('StubHub','A304',304,'101','3',2,100),    ('StubHub','A305',305,'101','3',2,100), ('StubHub','A306',306,'101','2',2,100),
 ('GoTickets','7307',307,'101','2',2,100), ('StubHub','A308',308,'101','2',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true, buy_enabled=true, buy_key_ids='{7}', gt_offer_enabled=true, gt_offer_key_ids='{7}' WHERE id;
UPDATE manual_sub_buy_config SET enabled=true WHERE id;

\echo A what counts as accessible seating: section, row -> is it
SELECT s || ' / ' || r || ' -> ' || sub_finder_seat_is_ada(s, r)
  FROM (VALUES ('204LWC','1'),('103WC','20'),('103 WC','20'),('200 LWC','1'),('WC','5'),('ADA 12','3'),('Wheelchair Platform','1'),
               ('Accessible 5','1'),('104','WC'),('104','ADA'),('204','1'),('Section 204','1'),('TWC Club','5'),('3 WCLUB','1'),
               ('ADAMS 4','B'),('SWC','1'),('LAWN','GA')) v(s, r);
SELECT sub_finder_seat_is_ada(NULL, NULL), sub_finder_seat_is_ada('101', NULL), sub_finder_seat_is_ada(NULL, 'WC');

\echo B the lookups: sold seat, the cover, its label and flags, and what we did by ourselves
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"A301"},{"order_number":"A302"},{"order_number":"A303"},{"order_number":"A304"},{"order_number":"A305"},{"order_number":"A306"},{"order_number":"7307"}]')->>'job_id')::uuid AS id;
SELECT sub_finder_job_json(7,(SELECT id FROM j))->>'status';
SELECT order_number, section || '/' || seat_row, coalesce(best->>'section','-') || '/' || coalesce(best->>'row','-'), coalesce(best->>'label','no cover'),
       coalesce(best->>'flags','-'), state, action, coalesce(auto_buy_note,'-')
  FROM sub_finder_order WHERE job_id=(SELECT id FROM j) ORDER BY 1;
\echo no cover anywhere carries the old review flag
SELECT count(*) FROM sub_finder_order o, jsonb_array_elements(o.covers) c WHERE o.job_id=(SELECT id FROM j) AND (c->'flags' ? 'wheelchair_row' OR c->>'label' LIKE '%wheelchair%');
\echo bought by ourselves: like for like and ordinary for ordinary, never across
SELECT string_agg(sale_order_number, ', ' ORDER BY sale_order_number) FROM manual_sub_buy;

\echo C a blocked listing is not a cover, so the CRM cannot buy it, confirmed or not
SELECT sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j),'A302','30201','dana',true)->>'error';
SELECT sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j),'A304','30401','dana',true)->>'error';

\echo D a cover quoted before this rule is refused at the buy and at the offer, and nothing is filed
UPDATE sub_finder_config SET auto_buy_enabled=false WHERE id;
UPDATE sub_finder_order SET section = '101WC', buy_id = NULL WHERE job_id=(SELECT id FROM j) AND order_number = 'A306';
SELECT r->>'error', r->>'limit', r->>'detail' FROM sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j),'A306','30601','dana',true) r;
UPDATE sub_finder_order SET section = '101', covers = jsonb_set(covers, '{0,row}', '"WC"') WHERE job_id=(SELECT id FROM j) AND order_number = 'A306';
SELECT r->>'error', r->>'limit' FROM sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j),'A306','30601','dana',true) r;
SELECT coalesce(best->>'label','no cover'), coalesce(best->>'gate','-') FROM sub_finder_order WHERE job_id=(SELECT id FROM j) AND order_number = '7307';
UPDATE sub_finder_order SET covers = jsonb_set(covers, '{0,section}', '"101 WC"') WHERE job_id=(SELECT id FROM j) AND order_number = '7307';
SELECT r->>'error', r->>'limit' FROM sub_finder_gt_offer_confirmed(7,'crm','7307','30701',NULL,'dana',20,true) r;
SELECT count(*) FROM sub_finder_gt_offer;
SELECT count(*) FROM manual_sub_buy WHERE sale_order_number IN ('A302','A304','7307');

\echo E the two buyers with no person in the loop refuse a cover or offer from before this rule
CREATE TEMP TABLE j2 AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"A308"}]')->>'job_id')::uuid AS id;
SELECT sub_finder_job_json(7,(SELECT id FROM j2))->>'status';
UPDATE sub_finder_order SET covers = jsonb_set(covers, '{0,section}', '"101WC"') WHERE job_id=(SELECT id FROM j2);
UPDATE sub_finder_config SET auto_buy_enabled=true WHERE id;
SELECT sub_finder_autobuy((SELECT id FROM j2));
SELECT order_number, action, coalesce(auto_buy_note,'-'), buy_id IS NOT NULL FROM sub_finder_order WHERE job_id=(SELECT id FROM j2);
\echo the same cover, ordinary again, is bought: the rule was the only thing in the way
UPDATE sub_finder_order SET covers = jsonb_set(covers, '{0,section}', '"101"') WHERE job_id=(SELECT id FROM j2);
SELECT sub_finder_autobuy((SELECT id FROM j2));
SELECT order_number, action, coalesce(auto_buy_note,'-'), buy_id IS NOT NULL FROM sub_finder_order WHERE job_id=(SELECT id FROM j2);
\echo an offer the customer accepted, made for accessible seats against an ordinary sale: not bought
UPDATE sub_finder_order SET covers = jsonb_set(covers, '{0,section}', '"101"') WHERE job_id=(SELECT id FROM j) AND order_number = '7307';
SELECT r->>'state', r->>'gate' FROM sub_finder_gt_offer_confirmed(7,'crm','7307','30701',NULL,'dana',20,true) r;
UPDATE sub_finder_config SET gt_offer_auto_buy=true WHERE id;
UPDATE sub_finder_gt_offer SET state='sent', gt_request_id=9, gt_status='ACCEPTED', section='101 WC';
SELECT sub_finder_gt_offer_buy(offer_id) FROM sub_finder_gt_offer;
SELECT order_number, section, coalesce(buy_note,'-'), buy_id IS NOT NULL FROM sub_finder_gt_offer;
\echo the same offer for ordinary seats is bought
UPDATE sub_finder_gt_offer SET section='101', buy_note=NULL;
SELECT sub_finder_gt_offer_buy(offer_id) IS NOT NULL FROM sub_finder_gt_offer;
SELECT order_number, section, coalesce(buy_note,'-'), buy_id IS NOT NULL FROM sub_finder_gt_offer;
SELECT string_agg(sale_order_number, ', ' ORDER BY sale_order_number) FROM manual_sub_buy;
