-- Operator 2026-11-28: "look into tax anomalies".
--
-- mig 20261123192030 promises, per ticket and for every source, price + fee + tax = all_in.
-- Primary keeps it. Resale does NOT, on about 1.9% of rows, and this scenario pins down exactly
-- which shapes hold and which do not, so the gap is visible instead of remembered.
--
-- Settled by the operator's own AXS cart (Pechanga, Sec LL24 Row 2): 2 x $52.80 + $26.92 resale
-- fee = $132.52, with NO tax line. So sales_tax_on_ticket is never charged on top -- it is
-- already inside `face` -- and our `tax` must be sales_tax_on_fee alone (mig 20261128110000).
--
-- Two wrong turns on the way, kept here so they are not repeated:
--   20261128090000 netted sales_tax_on_ticket off `face`. The arithmetic balances every body
--   below, but it moves `price` away from the face AXS displays to the buyer, so it was
--   superseded rather than kept.
--   20261128100000 reverted it on "breakage went 1.9% -> 9.8%", which was a CONFOUNDED
--   measurement comparing two time windows holding different venues. Compare the same
--   listing_ids across a change, or evaluate candidates against stored raw bodies.
--
-- Every pricing object below is a real one from axs_watch_raw_capture, not invented.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.row_of(p_pricing jsonb, p_kind text, p_seat_type text)
 RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.axs_watch_parse(jsonb_build_object(
    'event_id_requested','TAX',
    'event',  jsonb_build_object('starts_local','2027-02-06T19:30:00-06:00','title','T'),
    'onsale', jsonb_build_object('offer_id','o1'),
    'listings', jsonb_build_array(jsonb_build_object(
      'id','L1','kind',p_kind,'section','1','row','E',
      'seats',jsonb_build_array('1'),'quantity',1,
      'seat_type',p_seat_type,'status','AVAILABLE',
      'pricing', p_pricing)))) -> 'listings' -> 0;
$$;

\echo '--- A. primary (TSO, Toyota Center): face is NET of tax, and the contract holds'
SELECT (r->>'price')::numeric price, (r->>'fee')::numeric fee, (r->>'tax')::numeric tax,
       (r->>'all_in')::numeric all_in,
       abs((r->>'price')::numeric+(r->>'fee')::numeric+(r->>'tax')::numeric
           -(r->>'all_in')::numeric) <= 0.011 AS contract_holds
  FROM (SELECT pg_temp.row_of(jsonb_build_object(
          'face',66,'all_in',94.18,'tax',7.18,'fees_total',21,
          'before_tax',87,'tax_rate',8.25), 'primary','STANDARD') r) a;

\echo '--- B. resale with no tax anywhere (event 1644160): face + connection_fee = all_in, holds'
SELECT (r->>'price')::numeric price, (r->>'fee')::numeric fee, (r->>'tax')::numeric tax,
       (r->>'all_in')::numeric all_in,
       abs((r->>'price')::numeric+(r->>'fee')::numeric+(r->>'tax')::numeric
           -(r->>'all_in')::numeric) <= 0.011 AS contract_holds
  FROM (SELECT pg_temp.row_of(jsonb_build_object(
          'face',349.0,'all_in',438,'tax',0,'connection_fee',89,
          'sales_tax_on_fee',0,'sales_tax_on_ticket',0,
          'connection_fee_rate',0.255), 'resale','FLASHSEATS') r) b;

\echo '--- C. resale WITH tax (Randy Rogers, Ryman): tax must be the FEE tax 14.92, not 73.42'
\echo '    face 658.50 already contains sales_tax_on_ticket 58.50, which is never charged on top.'
SELECT (r->>'price')::numeric price, (r->>'fee')::numeric fee, (r->>'tax')::numeric tax,
       (r->>'all_in')::numeric all_in,
       (r->>'price')::numeric+(r->>'fee')::numeric+(r->>'tax')::numeric AS parts_sum,
       abs((r->>'price')::numeric+(r->>'fee')::numeric+(r->>'tax')::numeric
           -(r->>'all_in')::numeric) <= 0.011 AS contract_holds
  FROM (SELECT pg_temp.row_of(jsonb_build_object(
          'face',658.5,'all_in',826.42,'tax',73.42,'connection_fee',153,
          'sales_tax_on_fee',14.92,'sales_tax_on_ticket',58.5,
          'connection_fee_rate',0.255), 'resale','FLASHSEATS') r) c;

\echo '--- D. the fee is read as fees_total when present, connection_fee otherwise'
SELECT 'fees_total present' AS body, (r->>'fee')::numeric AS fee_taken
  FROM (SELECT pg_temp.row_of(jsonb_build_object(
          'face',100,'all_in',125.5,'tax',0,'fees_total',23.23,
          'connection_fee',25.5,'connection_fee_rate',0.255), 'resale','FLASHSEATS') r) d1
UNION ALL
SELECT 'fees_total absent', (r->>'fee')::numeric
  FROM (SELECT pg_temp.row_of(jsonb_build_object(
          'face',100,'all_in',125.5,'tax',0,
          'connection_fee',25.5,'connection_fee_rate',0.255), 'resale','FLASHSEATS') r) d2;

\echo '--- E. Opry House 1115342: the second venue that proved the rule (12 of 12 of its rows)'
SELECT (r->>'price')::numeric price, (r->>'fee')::numeric fee, (r->>'tax')::numeric tax,
       (r->>'all_in')::numeric all_in,
       abs((r->>'price')::numeric+(r->>'fee')::numeric+(r->>'tax')::numeric
           -(r->>'all_in')::numeric) <= 0.011 AS contract_holds
  FROM (SELECT pg_temp.row_of(jsonb_build_object(
          'face',109.75,'all_in',137.74,'tax',12.24,'connection_fee',25.5,
          'sales_tax_on_fee',2.49,'sales_tax_on_ticket',9.75,
          'connection_fee_rate',0.255), 'resale','FLASHSEATS') r) e;

\echo '--- F. the operator cart: Pechanga LL24 row 2, face 52.80 must survive as the price'
SELECT (r->>'price')::numeric price, (r->>'fee')::numeric fee, (r->>'tax')::numeric tax,
       (r->>'all_in')::numeric all_in,
       (r->>'price')::numeric = 52.8 AS price_is_the_displayed_face,
       abs((r->>'price')::numeric+(r->>'fee')::numeric+(r->>'tax')::numeric
           -(r->>'all_in')::numeric) <= 0.011 AS contract_holds
  FROM (SELECT pg_temp.row_of(jsonb_build_object(
          'face',52.8,'all_in',66.26,'tax',0,'connection_fee',13.46,
          'sales_tax_on_fee',0,'sales_tax_on_ticket',0,
          'connection_fee_rate',0.255), 'resale','FLASHSEATS') r) f;
