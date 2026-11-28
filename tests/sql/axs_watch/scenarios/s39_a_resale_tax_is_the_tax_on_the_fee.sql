-- Operator 2026-11-28: "look into tax anomalies".
--
-- mig 20261123192030 promises, per ticket and for every source, price + fee + tax = all_in.
-- Primary keeps it. Resale does NOT, on about 1.9% of rows, and this scenario pins down exactly
-- which shapes hold and which do not, so the gap is visible instead of remembered.
--
-- This is a CHARACTERISATION test of where the contract ACTUALLY stands, not of where it
-- should. Section C prints f on purpose. Three attempts to fix it were made and all three are
-- reverted; the mapping today is the long-standing one, at ~1.9% of resale rows broken and 0%
-- of primary.
--
-- What the operator's own AXS cart established (Pechanga, Sec LL24 Row 2, resale):
--   2 x $52.80 + $26.92 resale fee = $132.52, NO tax line, fee exactly 25.5% of face.
--   Our rows for that listing already match to the cent. `face` is the price AXS DISPLAYS,
--   sales_tax_on_ticket is never charged on top, and all_in_price is correct throughout.
--   A CRM consumer reading all_in_price is never wrong; only summing the parts is unreliable.
--
-- Three wrong turns, kept so they are not repeated:
--   20261128090030 netted sales_tax_on_ticket off `face`. The arithmetic balances every body
--   below, but it moves `price` off the face AXS displays. Superseded.
--   20261128100030 reverted that on "breakage went 1.9% -> 9.8%" -- a CONFOUNDED measurement
--   comparing two time windows holding DIFFERENT VENUES, not the same listings.
--   20261128110030 set tax = coalesce(sales_tax_on_fee, tax). Measured once every row had
--   re-polled under it: 13.32% of resale broken, far worse than the 1.9% baseline. Reverted by
--   20261128130030. It failed because `fee` is coalesce(fees_total, connection_fee): where a
--   body carries BOTH, we take the net fee while all_in uses the gross one, so no mapping of
--   `tax` alone can balance it.
--
-- The untested hypothesis, needing bodies from a venue carrying both fee fields:
--   fee = coalesce(connection_fee, fees_total)  AND  tax = coalesce(sales_tax_on_fee, tax).
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

\echo '--- C. resale WITH tax (Randy Rogers, Ryman): KNOWN GAP, contract_holds is f on purpose'
\echo '    face 658.50 already contains sales_tax_on_ticket 58.50, counted again in tax 73.42.'
\echo '    all_in 826.42 is AXS own total and IS correct; only the sum of the parts is not.'
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

\echo '--- E. Opry House 1115342: same shape as Ryman, same gap (sales_tax_on_ticket 9.75)'
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
