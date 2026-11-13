\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- Rows a person reviews before anything is bought (mig 20261113450000): a single-letter row
-- against a double-letter row, either way round, and a wheelchair row. Sales are 100 x2; every
-- listing is 80 x2 on EVO in the same section, so each would be a profitable gate 1 buy.
INSERT INTO events (id,name,occurs_at_local,venue_id,primary_performer_id) SELECT g,'G'||g,now()+interval '5 days',999,5 FROM generate_series(201,209) g;
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary) VALUES
 (201,20101,'101','H',2,80,'{2}',false,false),    -- sold AA, listing H
 (202,20201,'101','AA',2,80,'{2}',false,false),   -- sold H, listing AA (was not shown at all)
 (203,20301,'101','C',2,80,'{2}',false,false),    -- sold WC, listing C
 (204,20401,'101','WC',2,80,'{2}',false,false),   -- sold C, listing WC
 (205,20501,'101','WC',2,80,'{2}',false,false),   -- sold WC, listing WC: like for like
 (206,20601,'101','AA',2,80,'{2}',false,false),   -- sold BB, listing AA: both double letters
 (207,20701,'101','C',2,80,'{2}',false,false),    -- sold H, listing C: both single letters
 (208,20801,'101','H',1,80,'{1}',false,false),    -- one ticket sold in AA, listing H
 (209,20901,'101','8',2,80,'{2}',false,false);    -- sold 12, listing 8: numbers
INSERT INTO n2s_mkt_pull (source, tevo_event_id, resolved_at) SELECT 'evo', g, now() FROM generate_series(201,209) g;
INSERT INTO v_s4kcs_orders (source,s4k_order_id,tevo_event_id,section,row,quantity,price_per_ticket) VALUES
 ('StubHub','R201',201,'101','AA',2,100), ('StubHub','R202',202,'101','H',2,100), ('StubHub','R203',203,'101','WC',2,100),
 ('StubHub','R204',204,'101','C',2,100),  ('StubHub','R205',205,'101','WC',2,100), ('StubHub','R206',206,'101','BB',2,100),
 ('StubHub','R207',207,'101','H',2,100),  ('StubHub','R208',208,'101','AA',1,100), ('StubHub','R209',209,'101','12',2,100);
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', settle_min_s=0, auto_buy_enabled=true, buy_enabled=true, buy_key_ids='{7}' WHERE id;
UPDATE manual_sub_buy_config SET enabled=true WHERE id;

\echo what counts: single against double letters either way round; exactly one wheelchair row
SELECT a || ' / ' || b || ': letters differ ' || sub_finder_row_letters_differ(a, b) || ', wheelchair ' || (sub_finder_row_is_wheelchair(a) <> sub_finder_row_is_wheelchair(b))
  FROM (VALUES ('AA','H'),('H','AA'),('H','C'),('AA','BB'),('WC','C'),('C','WC'),('WC','WC'),('WC1','C'),('ADA','C'),('Wheelchair','C'),('W','C'),('12','8'),('12','B')) v(a, b);

\echo the lookups: sold row, the cover row, how it is labelled, and whether we bought it ourselves
CREATE TEMP TABLE j AS SELECT (sub_finder_submit(7,'crm','[{"order_number":"R201"},{"order_number":"R202"},{"order_number":"R203"},{"order_number":"R204"},{"order_number":"R205"},{"order_number":"R206"},{"order_number":"R207"},{"order_number":"R208"},{"order_number":"R209"}]')->>'job_id')::uuid id;
SELECT sub_finder_job_json(7,(SELECT id FROM j))->>'status';
SELECT order_number, seat_row, coalesce(best->>'row','-'), coalesce(best->>'label','no cover'), coalesce(best->>'row_relation','-'), coalesce(best->>'flags','-'),
       coalesce(best->>'confirm_needed','-'), action, coalesce(auto_buy_note,'-')
  FROM sub_finder_order WHERE job_id=(SELECT id FROM j) ORDER BY 1;
\echo bought by ourselves: only the unflagged ones
SELECT string_agg(sale_order_number, ', ' ORDER BY sale_order_number) FROM manual_sub_buy;

\echo the CRM buys a flagged cover only with a confirmation
SELECT sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j),'R201','20101',NULL,false) - 'detail';
SELECT sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j),'R201','20101','dana',true)->>'state';
SELECT sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j),'R203','20301',NULL,false) - 'detail';
SELECT sub_finder_buy_confirmed(7,'crm',(SELECT id FROM j),'R203','20301','dana',true)->>'state';
SELECT sale_order_number, ticket_group_id, requested_by FROM manual_sub_buy WHERE sale_order_number IN ('R201','R203') ORDER BY 1;

\echo a cover stored before the flags existed is read from its label
SELECT sub_finder_cover_flags('{"label":"Index wheelchair row"}'), sub_finder_cover_flags('{"label":"S4KTrading row letters differ"}'), sub_finder_cover_flags('{"label":"Index"}');

\echo the N2S auto-buyer skips the same pairs (mig 20261113460000): sold row / sub row -> skip reasons
INSERT INTO n2s_cover_queue (n2s_id, sub_source, sub_listing_id, order_row, sub_row) VALUES
 (1,'tevo','1','WC','AA'), (2,'tevo','2','WC','C'), (3,'tevo','3','C','WC'), (4,'tevo','4','WC','WC'), (5,'tevo','5','WC1','12'),
 (6,'tevo','6','AA','H'), (7,'tevo','7','H','C'), (8,'tevo','8','12','8'), (9,'tevo','9','ADA','B');
SELECT q.order_row || ' / ' || q.sub_row || ' -> ' || coalesce(nullif(array_to_string(n2s_dryrun_extra_reasons(q.n2s_id, 'tevo', q.sub_listing_id, '101', '101', NULL), ', '), ''), 'not skipped')
  FROM n2s_cover_queue q ORDER BY q.n2s_id;
SELECT 'no queue row -> ' || coalesce(nullif(array_to_string(n2s_dryrun_extra_reasons(99, 'tevo', '99', '101', '101', NULL), ', '), ''), 'not skipped');
