\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- Event 10 plays tomorrow (polled every 5 minutes: a book is current for 3 x 5 + 15 = 30 minutes).
-- Event 20 is ten days out (hourly: 195 minutes). Event 30 has two GoTickets events.
INSERT INTO events VALUES (10, 'Tomorrow', 'The Arena', to_char(now() + interval '30 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
                          (20, 'Next Week', 'The Arena', to_char(now() + interval '10 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
                          (30, 'Twice Listed', 'The Arena', to_char(now() + interval '10 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
                          (40, 'No Start Time', 'The Arena', 'TBD');
INSERT INTO gotickets_event VALUES (900, 'Tomorrow', 'AS_SCHEDULED', 10), (920, 'Next Week', 'AS_SCHEDULED', 20),
                                   (930, 'Twice Listed', 'AS_SCHEDULED', 30), (931, 'Twice Listed', 'AS_SCHEDULED', 30),
                                   (940, 'No Start Time', 'AS_SCHEDULED', 40);

\echo 1 both books fresh: labelled
SELECT t_evo_poll(10, now() - interval '2 minutes', '[[1,"105","19",2,100],[2,"105","20",2,200]]');
SELECT t_gt_poll(10, 900, now() - interval '3 minutes', '[[101,"Section 105","19",2,99]]');
SELECT listing_overlap_tick() - 'ms';
SELECT status, evo_listings, gt_listings, both_pairs FROM listing_overlap_event WHERE tevo_event_id = 10;

\echo 2 GoTickets stops answering while EVO keeps polling: once its book is 30 minutes old the labels are withdrawn
UPDATE gotickets_listings_snapshots SET captured_at = now() - interval '40 minutes' WHERE gt_event_id = 900;
SELECT t_evo_poll(10, now() - interval '1 minute', '[[2,"105","20",2,210]]');
SELECT listing_overlap_tick() - 'ms';
SELECT status, coalesce(evo_listings::text, '-'), coalesce(both_pairs::text, '-') FROM listing_overlap_event WHERE tevo_event_id = 10;
SELECT 'labels: ' || count(*) FROM listing_overlap_label WHERE tevo_event_id = 10;
SELECT 'rows from the reading function: ' || count(*) FROM listing_overlap_event_listings(10);

\echo 3 GoTickets answers again: labelled again
SELECT t_gt_poll(10, 900, now() - interval '30 seconds', '[[101,"Section 105","19",2,99],[102,"Section 105","20",2,208]]');
SELECT listing_overlap_tick() - 'ms';
SELECT status, evo_listings, gt_listings, both_pairs FROM listing_overlap_event WHERE tevo_event_id = 10;

\echo 4 the same 40-minute-old GoTickets book is fine for a game ten days out
SELECT t_evo_poll(20, now() - interval '2 minutes', '[[21,"105","19",2,100]]');
SELECT t_gt_poll(20, 920, now() - interval '40 minutes', '[[121,"Section 105","19",2,99]]');
SELECT listing_overlap_tick() - 'ms';
SELECT status, evo_listings, gt_listings, both_pairs FROM listing_overlap_event WHERE tevo_event_id = 20;

\echo 5 a GoTickets poll comes back with no listings: the GoTickets book is empty, every EVO listing is EVO-only
SELECT t_gt_poll(20, 920, now() - interval '1 minute', '[]');
SELECT listing_overlap_tick() - 'ms';
SELECT status, evo_listings, gt_listings, both_pairs, evo_only FROM listing_overlap_event WHERE tevo_event_id = 20;
SELECT source, listing_id, label, reason FROM listing_overlap_label WHERE tevo_event_id = 20;

\echo 6 two GoTickets events on one game: one book, listings from both
SELECT t_evo_poll(30, now() - interval '2 minutes', '[[31,"105","19",2,100],[32,"106","1",2,300]]');
SELECT t_gt_poll(30, 930, now() - interval '3 minutes', '[[131,"Section 105","19",2,99]]');
SELECT t_gt_poll(30, 931, now() - interval '4 minutes', '[[132,"Section 106","1",2,297]]');
SELECT listing_overlap_tick() - 'ms';
SELECT source, listing_id, label, coalesce(counterpart_id::text, '-') FROM listing_overlap_label WHERE tevo_event_id = 30 ORDER BY 1, 2;

\echo 7 a game with no readable start time is held to the tightest interval (30 minutes), not skipped
SELECT t_evo_poll(40, now() - interval '2 minutes', '[[41,"105","19",2,100]]');
SELECT t_gt_poll(40, 940, now() - interval '3 minutes', '[[141,"Section 105","19",2,99]]');
SELECT listing_overlap_tick() - 'ms';
SELECT status, both_pairs FROM listing_overlap_event WHERE tevo_event_id = 40;

\echo 8 both polls stop (game over): after 50 hours the labels are removed
UPDATE listing_overlap_event SET matched_at = now() - interval '51 hours' WHERE tevo_event_id = 30;
SELECT listing_overlap_tick() - 'ms';
SELECT status FROM listing_overlap_event WHERE tevo_event_id = 30;
SELECT 'labels: ' || count(*) FROM listing_overlap_label WHERE tevo_event_id = 30;
SELECT 'other events untouched: ' || count(DISTINCT tevo_event_id) FROM listing_overlap_label;

\echo 9 and after 30 days the event row goes too
UPDATE listing_overlap_event SET matched_at = now() - interval '31 days' WHERE tevo_event_id = 30;
SELECT listing_overlap_tick() - 'ms';
SELECT 'event 30 rows: ' || count(*) FROM listing_overlap_event WHERE tevo_event_id = 30;

\echo 10 one event failing does not stop the others
SELECT t_evo_poll(10, now() - interval '20 seconds', '[[1,"105","19",2,100]]');
SELECT t_evo_poll(20, now() - interval '20 seconds', '[[21,"105","19",2,100]]');
ALTER TABLE listing_overlap_label ADD CONSTRAINT t_boom CHECK (tevo_event_id <> 20 OR label <> 'evo_only') NOT VALID;
SET client_min_messages = error;
SELECT listing_overlap_tick() - 'ms';
