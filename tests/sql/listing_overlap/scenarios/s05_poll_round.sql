\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- A game tomorrow. One poll round = an EVO poll and a GoTickets poll fired together; the
-- EVO response is stored first, the GoTickets one about a minute later.
INSERT INTO events VALUES (10, 'Home at Away', 'The Arena', to_char(now() + interval '30 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
INSERT INTO gotickets_event VALUES (900, 'Home at Away', 'AS_SCHEDULED', 10);
SELECT t_evo_poll(10, now() - interval '6 minutes', '[[1,"105","19",2,100],[2,"105","20",2,200]]');
SELECT t_gt_poll(10, 900, now() - interval '6 minutes', '[[101,"Section 105","19",2,99]]');
\echo 1 first round, both stored: matched once
SELECT listing_overlap_tick() - 'ms';
SELECT both_pairs, evo_only FROM listing_overlap_event WHERE tevo_event_id = 10;

\echo 2 next round fires. EVO is stored 20 s later; GoTickets fired 60 s ago and is not stored yet: wait
SELECT t_evo_poll(10, now() - interval '40 seconds', '[[1,"105","19",2,101]]');
UPDATE gt_listings_poll_state SET last_polled_listings_at = now() - interval '60 seconds' WHERE gt_event_id = 900;
SELECT listing_overlap_tick() - 'ms';

\echo 3 the GoTickets response is stored: the round is matched, once
INSERT INTO gotickets_listings_snapshots (tevo_event_id, gt_event_id, captured_at, gt_listing_id, section, section_id, row, quantity, all_in_price)
SELECT 10, 900, last_polled_listings_at, v.id, 'Section 105', 1, v.r, 2, v.p
  FROM gt_listings_poll_state, (VALUES (101, '19', 99.5), (102, '20', 198)) AS v(id, r, p) WHERE gt_event_id = 900;
SELECT listing_overlap_tick() - 'ms';
SELECT both_pairs, evo_only FROM listing_overlap_event WHERE tevo_event_id = 10;
SELECT listing_overlap_tick() - 'ms';

\echo 4 a GoTickets poll fires alone and EVO is not due: its own response is all that is waited for
UPDATE gt_listings_poll_state SET last_polled_listings_at = now() - interval '20 seconds' WHERE gt_event_id = 900;
SELECT listing_overlap_tick() - 'ms';
INSERT INTO gotickets_listings_snapshots (tevo_event_id, gt_event_id, captured_at, gt_listing_id, section, section_id, row, quantity, all_in_price)
SELECT 10, 900, last_polled_listings_at, 101, 'Section 105', 1, '19', 2, 99.5 FROM gt_listings_poll_state WHERE gt_event_id = 900;
SELECT listing_overlap_tick() - 'ms';
SELECT both_pairs, evo_only FROM listing_overlap_event WHERE tevo_event_id = 10;

\echo 5 an EVO poll that never comes back is not waited for for ever:
\echo   a new GoTickets capture is in; the EVO poll of the same round fired 30 s ago and stored nothing
SELECT t_gt_poll(10, 900, now() - interval '5 seconds', '[[101,"Section 105","19",2,99.5],[103,"Section 105","21",2,300]]');
UPDATE evo_listings_poll_state SET last_polled_listings_at = now() - interval '30 seconds' WHERE event_id = 10;
SELECT 'waiting up to 120 s: ' || (listing_overlap_tick() - 'ms')::text;
UPDATE listing_overlap_config SET settle_evo_seconds = 20;
SELECT 'waiting up to 20 s:  ' || (listing_overlap_tick() - 'ms')::text;
SELECT both_pairs, gt_only FROM listing_overlap_event WHERE tevo_event_id = 10;

\echo 6 the wait is a setting: 0 = match as soon as either response lands (the first behaviour)
UPDATE listing_overlap_config SET settle_evo_seconds = 0, settle_gt_seconds = 0;
SELECT t_evo_poll(10, now() - interval '10 seconds', '[[1,"105","19",2,102]]');
UPDATE gt_listings_poll_state SET last_polled_listings_at = now() - interval '15 seconds' WHERE gt_event_id = 900;
SELECT listing_overlap_tick() - 'ms';
