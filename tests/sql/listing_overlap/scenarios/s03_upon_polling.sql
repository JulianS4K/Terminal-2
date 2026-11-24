\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- A game ten days out: polled hourly, so a book stays current for 3 x 60 + 15 minutes.
INSERT INTO events VALUES (10, 'Home at Away', 'The Arena', to_char(now() + interval '10 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
                          (11, 'No GoTickets Event', 'The Arena', to_char(now() + interval '30 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
INSERT INTO gotickets_event VALUES (900, 'Home at Away', 'AS_SCHEDULED', 10);

\echo 1 nothing polled: the tick does nothing
SELECT listing_overlap_tick() - 'ms';

\echo 2 EVO has landed, GoTickets has not: still nothing to match
SELECT t_evo_poll(10, now() - interval '50 minutes', '[[1,"105","19",2,100],[2,"105","20",2,200],[3,"106","1",4,300]]');
SELECT t_evo_poll(11, now() - interval '50 minutes', '[[50,"105","19",2,100]]');
SELECT listing_overlap_tick() - 'ms';
SELECT 'events tracked: ' || count(*) FROM listing_overlap_event;

\echo 3 the GoTickets poll lands: matched on the next tick
SELECT t_gt_poll(10, 900, now() - interval '49 minutes', '[[101,"Section 105","19",2,99],[103,"Section 106","1",4,297]]');
SELECT listing_overlap_tick() - 'ms';
SELECT source, listing_id, label, reason FROM listing_overlap_label ORDER BY 1, 2;
SELECT 'event 11 (no GoTickets event) tracked: ' || count(*) FROM listing_overlap_event WHERE tevo_event_id = 11;

\echo 4 no new poll: the tick matches nothing
SELECT listing_overlap_tick() - 'ms';

\echo 5 a GoTickets poll fired but its response has not been stored: nothing to match yet
UPDATE gt_listings_poll_state SET last_polled_listings_at = now() - interval '44 minutes' WHERE gt_event_id = 900;
SELECT listing_overlap_tick() - 'ms';

\echo 6 a new GoTickets capture: 105/20 appears there, 106/1 has gone
CREATE TEMP TABLE since AS SELECT source, listing_id, label_since FROM listing_overlap_label;
SELECT t_gt_poll(10, 900, now() - interval '44 minutes', '[[101,"Section 105","19",2,99],[102,"Section 105","20",2,198]]');
SELECT listing_overlap_tick() - 'ms';
SELECT l.source, l.listing_id, l.label, l.reason,
       CASE WHEN s.listing_id IS NULL THEN 'new row' WHEN s.label_since = l.label_since THEN 'label_since kept' ELSE 'label_since moved' END
  FROM listing_overlap_label l LEFT JOIN since s USING (source, listing_id) ORDER BY 1, 2;

\echo 7 EVO polls again 40 minutes on. The firehose only stores what changed: group 3 left, group 1 repriced, group 2 untouched.
\echo   Without the id set (collector not yet updated) group 3 is still inside its hour and still counted:
SELECT t_evo_poll(10, now() - interval '10 minutes', '[[1,"105","19",2,101]]');
SELECT listing_overlap_tick() - 'ms';
SELECT 'evo_exact=' || evo_exact || ' evo_listings=' || evo_listings || ' both=' || both_pairs FROM listing_overlap_event WHERE tevo_event_id = 10;
SELECT source, listing_id, label, reason FROM listing_overlap_label WHERE source = 'evo' ORDER BY 2;

\echo 8 the same kind of poll with the id set from the collector: the book is exact, group 3 is gone
SELECT t_evo_poll(10, now() - interval '5 minutes', '[]', ARRAY[1, 2]::bigint[]);
SELECT listing_overlap_tick() - 'ms';
SELECT 'evo_exact=' || evo_exact || ' evo_listings=' || evo_listings || ' both=' || both_pairs FROM listing_overlap_event WHERE tevo_event_id = 10;
SELECT source, listing_id, label, reason FROM listing_overlap_label ORDER BY 1, 2;
SELECT 'live ids: ' || string_agg(tevo_ticket_group_id::text, ',' ORDER BY tevo_ticket_group_id) FROM listing_overlap_evo_live WHERE event_id = 10;

\echo 9 an older response arriving late does not overwrite the live set
SELECT listing_overlap_evo_seen(10, now() - interval '30 minutes', ARRAY[1, 2, 3, 4]::bigint[]);
SELECT 'live ids: ' || string_agg(tevo_ticket_group_id::text, ',' ORDER BY tevo_ticket_group_id) FROM listing_overlap_evo_live WHERE event_id = 10;

\echo 10 the id set belongs to an earlier capture than the one being matched: not trusted
SELECT t_evo_poll(10, now() - interval '1 minute', '[[5,"300","1",2,50]]');
SELECT listing_overlap_tick() - 'ms';
SELECT 'evo_exact=' || evo_exact || ' evo_listings=' || evo_listings FROM listing_overlap_event WHERE tevo_event_id = 10;

\echo 11 switched off: the tick returns at once
SELECT t_gt_poll(10, 900, now() - interval '30 seconds', '[[101,"Section 105","19",2,99]]');
UPDATE listing_overlap_config SET enabled = false;
SELECT listing_overlap_tick();
UPDATE listing_overlap_config SET enabled = true;
SELECT listing_overlap_tick(p_max => 0) - 'ms';
SELECT listing_overlap_tick() - 'ms';
