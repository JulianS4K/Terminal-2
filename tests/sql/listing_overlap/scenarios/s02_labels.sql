\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- One game tomorrow, both books polled a minute ago. EVO rows: [id, section, row, qty, retail, owned, ancillary].
INSERT INTO events VALUES (10, 'Home at Away', 'The Arena', to_char(now() + interval '30 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
INSERT INTO gotickets_event VALUES (900, 'Home at Away', 'AS_SCHEDULED', 10), (901, 'Home at Away Parking', 'AS_SCHEDULED', 10),
                                   (902, 'Home at Away', 'CANCELLED', 10);
SELECT t_evo_poll(10, now() - interval '1 minute', '[
  [1,  "105",      "19", 2, 1917.40],
  [2,  "105",      "19", 2, 3455.70],
  [3,  "C129",     "4",  2, 500.00],
  [4,  "Club 129", "4",  2, 900.00],
  [5,  "223",      "12", 4, 688.49],
  [6,  "223",      "15", 2, 832.64],
  [7,  "223",      "30", 2, 400.00],
  [8,  "347",      "1",  2, 150.00],
  [9,  "FLOORE",   "Row 3", 2, 2500.00, true],
  [10, "LOT A",    "GA", 1, 60.00, false, true],
  [11, "106",      "7",  2, 3283.38],
  [12, "101",      "1",  2, 0],
  [13, "",         "1",  2, 75.00],
  [14, "C-B",      "2",  2, 1200.00]
]');
-- GoTickets rows: [id, section, row, qty, all-in]
SELECT t_gt_poll(10, 900, now() - interval '1 minute', '[
  [101, "Section 105", "19", 2, 1890.76],
  [102, "Section 105", "19", 2, 3394.12],
  [103, "Club 129",    "4",  2, 494.50],
  [105, "Section 223", "12", 4, 420.00],
  [106, "Section 223", "15", 4, 694.84],
  [107, "Section 223", "06", 4, 861.68],
  [108, "Lower 113",   "16", 2, 300.00],
  [109, "Floor E",     "3",  2, 2470.00],
  [111, "Section 106", "7",  2, 3221.88],
  [112, "Section 106", "7",  2, 3260.00],
  [114, "Club B",      "2",  2, 1190.00]
]');
SELECT t_gt_poll(10, 901, now() - interval '1 minute', '[[201, "Lot A", "GA", 1, 59.00]]');     -- parking event: never read
SELECT t_gt_poll(10, 902, now() - interval '1 minute', '[[301, "Section 105", "19", 2, 1890.00]]'); -- cancelled: never read

\echo 1 the labels, straight from the two books (nothing stored yet):
SELECT source, listing_id, label, reason, coalesce(counterpart_id::text, '-'), coalesce(price_ratio::text, '-')
  FROM listing_overlap_compute(10, (SELECT max(captured_at) FROM event_metrics WHERE event_id = 10), false, 0.989, 0.12)
 ORDER BY source, listing_id;
SELECT 'stored before any match: ' || count(*) FROM listing_overlap_label;

\echo 2 match the event:
SELECT listing_overlap_match_event(10) - 'evo_cap' - 'gt_cap';
SELECT status, evo_exact, evo_listings, gt_listings, both_pairs, evo_only, gt_only, evo_unclear, gt_unclear
  FROM listing_overlap_event WHERE tevo_event_id = 10;
SELECT name, gt_pct_on_evo, evo_pct_on_gt FROM v_listing_overlap_event;

\echo 3 the reading function: both books with their labels
SELECT source, listing_id, section, row_name, quantity, price, coalesce(is_owned::text, '-'), label, reason,
       coalesce(counterpart_id::text, '-')
  FROM listing_overlap_event_listings(10) ORDER BY source, listing_id;

\echo 4 a second match of the same books rewrites nothing:
CREATE TEMP TABLE before AS SELECT source, listing_id, label_since, updated_at FROM listing_overlap_label;
SELECT (listing_overlap_match_event(10))->>'labels_written';
SELECT 'rows whose timestamps moved: ' || count(*)
  FROM listing_overlap_label l JOIN before b USING (source, listing_id)
 WHERE l.label_since <> b.label_since OR l.updated_at <> b.updated_at;

\echo 5 a much tighter band: pairs outside it fall back to unclear, and a spot is re-walked to the copy that fits:
UPDATE listing_overlap_config SET price_band = 0.005;
SELECT (listing_overlap_match_event(10))->>'both_pairs';
SELECT source, listing_id, label, reason FROM listing_overlap_label WHERE listing_id IN (2, 102, 11, 111, 112) ORDER BY source, listing_id;
