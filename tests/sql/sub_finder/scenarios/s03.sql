\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
UPDATE sub_finder_config SET td_enabled=false, settle_min_s=0;
INSERT INTO n2s_items (n2s_id, order_number, n2s_order_key, marketplace, tevo_event_id, event_name, event_dt, venue, section, row, qty, price_per_ticket, pulled_at) VALUES
 (1,'JY8','JY8','Gametime',3241050,'K-State at TCU (Big Noon)','2026-11-14 13:00','Amon G. Carter Stadium','217','G',2,125.72, now() - interval '1 day'),
 (2,'JY8','JY8','Gametime',3241050,'K-State at TCU (Big Noon)','2026-11-14 13:00','Amon G. Carter Stadium','217','G',2,130.00, now()),
 (3,'8171891-19412715','19412715','Ticket Evolution',3241050,'x','2026-11-14 13:00','v','134','K',3,118.81, now()),
 (4,'NOEV','NOEV','StubHub',NULL,'Unknown Game','2026-11-14 13:00','v','1','1',1,10, now());
INSERT INTO v_s4kcs_orders VALUES ('StubHub','MK1',3241050,'crm name','2026-11-14','Carter','134','K',3,118.81, now()), ('StubHub','JY8',1,'wrong book','2026-11-14','x','9','9',9,9, now());
\echo M1 numbers only, CRM split key, unknown number, spelled-out order:
CREATE TEMP TABLE m AS SELECT sub_finder_submit(7,'crm','[{"order_number":"JY8"},{"order_number":"MK1"},{"order_number":"ZZ"},{"order_number":"19412715"},{"order_number":"NOEV"},
 {"order_number":"OV","section":"217","row":"G","qty":2,"tevo_event_id":3241050},{"order_number":"JY8","qty":1,"sold_ea":99}]') r;
SELECT r - 'job_id' - 'created_at' FROM m;
UPDATE n2s_mkt_pull SET resolved_at=now();
SELECT i->>'order_number', i->>'order_source', i->>'site', i->>'state', i->>'section', i->>'row', i->>'qty', i->>'sold_ea', i->>'tevo_event_id', i->>'event_name', i->'best'->>'listing_id' FROM (SELECT sub_finder_job_json(7,(SELECT (r->>'job_id')::uuid FROM m)) x) q, jsonb_array_elements(x->'items') i;
\echo M2 nothing known at all:
SELECT sub_finder_submit(7,'crm','[{"order_number":"ZZ"},{"order_number":"YY"}]') - 'detail';
\echo M3 address by order number:
SELECT sub_finder_latest_job(7,'MK1') = (SELECT (r->>'job_id')::uuid FROM m), sub_finder_latest_job(8,'MK1') IS NULL, sub_finder_latest_job(7,'nope') IS NULL;
