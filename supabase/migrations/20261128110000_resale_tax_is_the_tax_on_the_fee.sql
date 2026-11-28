-- Migration 20261128110000 · level:data-collection · lane:a1 (AXS watch parse) · writes:axs_watch_parse()(replaced) · reads:axs_watch_raw_capture
--
-- ============================================================================
-- Migration 20261128110000 — a resale tax is the tax on the FEE, nothing more
--
-- Lane:     a1 (AXS watch)
-- pre:      20261128100000 (which reverted 20261128090000)
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- Operator 2026-11-28: "look into tax anomalies", then a real AXS cart as the spot check.
--
-- ── THE SPOT CHECK THAT SETTLED IT ────────────────────────────────────────
-- Pechanga Arena San Diego, resale, Sec LL24 Row 2 Seats 5-6:
--     Tickets   Gulls Elite - Premium  ($52.80 x 2)   $105.60
--     Fees      Resale Fee                             $26.92
--     Order Total                                     $132.52
-- 105.60 + 26.92 = 132.52 exactly. THERE IS NO TAX LINE, and 26.92 / 105.60 = 0.2549, the
-- connection_fee_rate. Our rows for that listing (events 1583500 and 1583501) already read
-- price 52.80, fee 13.46, tax 0, all_in 66.26 — correct to the cent. The displayed ticket price
-- IS `face`.
--
-- ── WHAT WAS WRONG ────────────────────────────────────────────────────────
-- mig 20261123192030 promises price + fee + tax = all_in_price for every source. Resale broke
-- it wherever the venue charges a ticket sales tax. From raw bodies:
--
--   Opry House 1115342     face 109.75  connection_fee 25.50  sales_tax_on_fee 2.49
--                          sales_tax_on_ticket 9.75   tax 12.24   all_in 137.74
--   Ryman      1670958     face 658.50  connection_fee 153.0  sales_tax_on_fee 14.92
--                          sales_tax_on_ticket 58.50  tax 73.42   all_in 826.42
--
--   all_in = face + connection_fee + sales_tax_on_fee        holds 12 of 12 Opry resale rows
--   all_in = face + connection_fee + tax (what we stored)    holds  0 of 12
--
-- pricing.tax is sales_tax_on_ticket + sales_tax_on_fee, but sales_tax_on_ticket is ALREADY
-- inside `face` and is never charged on top — which is exactly why the operator's cart has no
-- tax line. Storing tax = pricing.tax therefore counted it twice.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────
-- tax = coalesce(sales_tax_on_fee, tax). One expression, no branch on market: primary bodies
-- carry no sales_tax_on_fee, so all 70,852 primary rows are untouched. `price` stays `face`, so
-- the CRM keeps seeing the price AXS displays.
--
-- ── TWO WRONG TURNS, RECORDED SO THEY ARE NOT REPEATED ────────────────────
-- 1. 20261128090000 instead netted sales_tax_on_ticket off `face`. That arithmetic is RIGHT —
--    it balances every body above — but it moves `price` away from the displayed face, which
--    the cart shows is what AXS puts in front of the buyer. Superseded, not merely reverted.
-- 2. I then reverted it (20261128100000) on the strength of "resale breakage went 1.9% -> 9.8%
--    after the change". That measurement was CONFOUNDED: it compared two time windows holding
--    different venues rather than the same listings before and after. Per-minute, breakage
--    spikes at 05:23 (83) and 05:28 (48) BEFORE the change and at 05:49 (90) and 05:50 (118)
--    AFTER the revert — it tracks which venues happen to be polling, not the deployment.
--    Lesson for the next person: compare the same listing_ids across a change, or evaluate
--    candidate expressions against stored raw bodies, which is what finally settled this.
--
-- WHAT THE CRM SEES: on resale rows at venues with a ticket sales tax, `tax` falls to just the
-- tax on the fee and price + fee + tax now equals all_in. `price`, `fee` and `all_in_price` do
-- not move. all_in_price was correct throughout — a consumer reading it was never wrong; one
-- summing the parts was high by sales_tax_on_ticket on ~4.7% of resale rows.
--
-- Covered by tests/sql/axs_watch s39.
-- rollback: re-apply axs_watch_parse() from 20261124200000.
-- ============================================================================

DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  old CONSTANT text := '           nullif(l->''pricing''->>''tax'', '''')::numeric AS tax,';
  new CONSTANT text :=
    '           -- mig 20261128110000: pricing.tax = sales_tax_on_ticket + sales_tax_on_fee, but' || E'\n' ||
    '           -- sales_tax_on_ticket is already inside `face` and is never charged on top, so' || E'\n' ||
    '           -- only the tax on the fee is payable. Primary has no such field and is unchanged.' || E'\n' ||
    '           coalesce(nullif(l->''pricing''->>''sales_tax_on_fee'', '''')::numeric,' || E'\n' ||
    '                    nullif(l->''pricing''->>''tax'', '''')::numeric) AS tax,';
  n int;
BEGIN
  IF position('sales_tax_on_fee' in src) > 0 THEN
    RAISE NOTICE 'the parse already reads the fee tax; nothing to do';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'the tax anchor matched % times, expected 1', n; END IF;
  EXECUTE replace(src, old, new);
END $surgery$;

DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  r jsonb; b jsonb; nm text; gap numeric;
BEGIN
  IF position('sales_tax_on_fee' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the parse does not read sales_tax_on_fee';
  END IF;
  FOR nm, b IN SELECT * FROM (VALUES
    ('Ryman resale',   '{"tax":73.42,"face":658.5,"all_in":826.42,"connection_fee":153,"sales_tax_on_fee":14.92,"sales_tax_on_ticket":58.5}'::jsonb),
    ('Opry resale',    '{"tax":12.24,"face":109.75,"all_in":137.74,"connection_fee":25.5,"sales_tax_on_fee":2.49,"sales_tax_on_ticket":9.75}'::jsonb),
    ('Opry resale b',  '{"tax":24.47,"face":219.5,"all_in":275.47,"connection_fee":51,"sales_tax_on_fee":4.97,"sales_tax_on_ticket":19.5}'::jsonb),
    ('resale no-tax',  '{"tax":0,"face":349.0,"all_in":438,"connection_fee":89,"sales_tax_on_fee":0,"sales_tax_on_ticket":0}'::jsonb),
    ('Pechanga resale','{"tax":0,"face":52.8,"all_in":66.26,"connection_fee":13.46,"sales_tax_on_fee":0,"sales_tax_on_ticket":0}'::jsonb),
    ('TSO primary',    '{"tax":7.18,"face":66,"all_in":94.18,"fees_total":21,"before_tax":87,"tax_rate":8.25}'::jsonb)
  ) v(a,c) LOOP
    SELECT public.axs_watch_parse(jsonb_build_object(
      'event_id_requested','__t__',
      'event',  jsonb_build_object('starts_local','2027-02-06T19:30:00-06:00','title','T'),
      'onsale', jsonb_build_object('offer_id','o1'),
      'listings', jsonb_build_array(jsonb_build_object(
        'id','L1','kind', CASE WHEN b ? 'connection_fee' THEN 'resale' ELSE 'primary' END,
        'section','1','row','E','seats',jsonb_build_array('1'),'quantity',1,
        'seat_type','STANDARD','status','AVAILABLE','pricing', b)))) -> 'listings' -> 0
      INTO r;
    gap := (r->>'price')::numeric + (r->>'fee')::numeric + (r->>'tax')::numeric
         - (r->>'all_in')::numeric;
    IF abs(gap) > 0.011 THEN
      RAISE EXCEPTION '% : price+fee+tax=all_in still fails, off by %', nm, round(gap,2);
    END IF;
  END LOOP;
  IF (SELECT (public.axs_watch_parse(jsonb_build_object(
        'event_id_requested','__t__',
        'event',  jsonb_build_object('starts_local','2027-02-06T19:30:00-06:00','title','T'),
        'onsale', jsonb_build_object('offer_id','o1'),
        'listings', jsonb_build_array(jsonb_build_object(
          'id','L1','kind','resale','section','1','row','E','seats',jsonb_build_array('1'),
          'quantity',1,'seat_type','FLASHSEATS','status','AVAILABLE',
          'pricing','{"tax":73.42,"face":658.5,"all_in":826.42,"connection_fee":153,"sales_tax_on_fee":14.92,"sales_tax_on_ticket":58.5}'::jsonb))))
        -> 'listings' -> 0 ->> 'price')::numeric) <> 658.5 THEN
    RAISE EXCEPTION 'price must stay the displayed face 658.5';
  END IF;
END $verify$;
