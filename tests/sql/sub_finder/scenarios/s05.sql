\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
UPDATE sub_finder_config SET enabled=true, key_ids='{7}', refresh_enabled=true, refresh_pull=true, settle_min_s=0, td_enabled=false;
INSERT INTO events VALUES (901,'Soon', now() + interval '1 day'), (902,'Soon too', now() + interval '2 days'), (903,'Next week', now() + interval '5 days'), (904,'Far', now() + interval '200 days');
INSERT INTO n2s_evo_current (event_id,tevo_ticket_group_id,section,row,quantity,retail_price,splits,is_owned,is_ancillary,pulled_at) SELECT e, e, '1','1',2,10,'{2}',false,false, now() FROM unnest(ARRAY[901,902,903,904]) e;
SELECT sub_finder_submit(7,'crm', (SELECT jsonb_agg(jsonb_build_object('order_number','B'||e,'tevo_event_id',e,'section','1','row','1','qty',2)) FROM unnest(ARRAY[901,902,903,904]) e))->>'status';
DELETE FROM band_log WHERE true;
SELECT sub_finder_refresh() - 'closed';
SELECT iv, (SELECT array_agg(x ORDER BY x) FROM unnest(evs) x) FROM band_log ORDER BY iv;
\echo off again: no pull
UPDATE sub_finder_config SET refresh_pull=false; DELETE FROM band_log WHERE true;
SELECT sub_finder_refresh() - 'closed'; SELECT count(*) FROM band_log;
