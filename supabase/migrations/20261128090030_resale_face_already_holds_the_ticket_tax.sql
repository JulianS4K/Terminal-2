-- Migration 20261128090030 · level:data-collection · lane:a1 (AXS watch parse) · writes:axs_watch_parse()(replaced) · reads:axs_watch_raw_capture
--
-- ============================================================================
-- Migration 20261128090030 — a resale face already holds the ticket tax
--
-- Lane:     a1 (AXS watch)
-- pre:      20261124200000 (the parse that maps pricing -> price/fee/tax)
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- Operator 2026-11-28: "look into tax anomalies".
--
-- ── THE CONTRACT, AND HOW RESALE BREAKS IT ────────────────────────────────
-- mig 20261123192030 promises ONE meaning of price for every source, per ticket:
--     price + fee + tax = all_in_price
-- Primary keeps it. Resale does not, for 734 of 35,091 rows (2.1%); primary is clean at
-- 69,048 of 69,048.
--
-- TicketsData gives the two markets DIFFERENT shapes, and `face` does not mean the same thing
-- in each. From raw captures (axs_watch_raw_capture):
--
--   primary  (event 1579101)          resale  (event 1670958, Ryman, FLASHSEATS)
--     face        66                    face                658.50
--     fees_total  21                    connection_fee      153.00
--     before_tax  87   (= 66 + 21)      connection_fee_rate   0.255
--     tax_rate     8.25                 sales_tax_on_ticket  58.50
--     tax          7.18 (on 87)         sales_tax_on_fee     14.92
--     all_in      94.18                 tax                  73.42  (= 58.50 + 14.92)
--                                       all_in              826.42
--
--   primary: face is NET of tax. 66 + 21 + 7.18 = 94.18 = all_in. Correct today.
--   resale:  face is GROSS of the ticket tax. 658.50 - 58.50 = 600, and 600 x 0.255 = 153,
--            which is the connection fee — so the net ticket is 600 and `face` is 600 plus
--            its own sales tax. all_in = face + connection_fee + sales_tax_on_fee = 826.42.
--
-- So storing price = face and tax = tax counts sales_tax_on_ticket TWICE, and
-- price + fee + tax overstates all_in by exactly that amount. It reproduces to the cent on
-- the row that first looked wrong (Ryman, section 5 row W):
--     stored  price 192.06  fee 44.62  tax 21.41  all_in 241.03   sum 258.09, over by 17.06
--     net     192.06 / 1.0975 = 175.00          <- Nashville 9.75%
--     fee     175.00 x 0.255  =  44.62          <- matches the stored fee exactly
--     fee tax  44.62 x 0.0975 =   4.35
--     tax      17.06 + 4.35   =  21.41          <- matches the stored tax exactly
--     all_in  192.06 + 44.62  +  4.35 = 241.03  <- matches
-- and 17.06 is sales_tax_on_ticket. Measured across the broken rows: all_in = face x 1.255
-- for 646 of 648 FLASHSEATS rows, where 0.255 is AXS's own connection_fee_rate, while the
-- stored fee sits at 0.2323 of the stored price — the same fee expressed against a price that
-- has been inflated by its own tax.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────
-- One line: price = face - sales_tax_on_ticket. `fee` and `tax` are already right.
-- Primary bodies carry no sales_tax_on_ticket, so coalesce(...,0) leaves primary untouched —
-- which is why this is a universal expression rather than a branch on market. `tax` keeps
-- meaning the WHOLE tax the buyer pays, so the contract reads the same for both markets.
--
-- WHAT THE CRM SEES: on those 734 rows `price` drops by the ticket tax and price + fee + tax
-- now equals all_in. all_in_price itself does NOT move — it was always AXS's own correct total.
-- A consumer that reads all_in_price was never wrong; one that summed the parts was high by
-- up to ~9% on 0.7% of AXS rows.
--
-- NOT FIXED HERE, and worth raising with TicketsData alongside the collisions: `face` meaning
-- pre-tax for primary and tax-inclusive for resale, in the same field of the same payload,
-- is their inconsistency, not ours. We are compensating for it.
--
-- Guarded in-place surgery: asserts the anchor appears exactly once, replaces, executes, reads
-- the body back. Covered by tests/sql/axs_watch s39.
--
-- rollback: re-apply axs_watch_parse() from 20261124200000.
-- ============================================================================

DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  old CONSTANT text := '           nullif(l->''pricing''->>''face'', '''')::numeric AS price,';
  new CONSTANT text :=
    '           -- mig 20261128090030: a resale face is GROSS of the ticket tax, a primary face' || E'\n' ||
    '           -- is net. Subtracting it keeps price + fee + tax = all_in for both; primary' || E'\n' ||
    '           -- bodies carry no sales_tax_on_ticket, so primary is unchanged.' || E'\n' ||
    '           nullif(l->''pricing''->>''face'', '''')::numeric' || E'\n' ||
    '             - coalesce(nullif(l->''pricing''->>''sales_tax_on_ticket'', '''')::numeric, 0) AS price,';
  n int;
BEGIN
  IF position('sales_tax_on_ticket' in src) > 0 THEN
    RAISE NOTICE 'the parse already nets the ticket tax off the face; nothing to do';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'the face->price anchor matched % times, expected 1', n; END IF;
  EXECUTE replace(src, old, new);
END $surgery$;

DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  v_rows jsonb;
BEGIN
  IF position('sales_tax_on_ticket' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the parse does not net the ticket tax off the face';
  END IF;

  -- a resale body, exactly as TicketsData sends one: price must come back 600, not 658.50
  SELECT public.axs_watch_parse(jsonb_build_object(
    'event_id_requested','__t__',
    'event', jsonb_build_object('starts_local','2027-02-06T19:30:00-06:00','title','T'),
    'onsale', jsonb_build_object('offer_id','o1'),
    'listings', jsonb_build_array(jsonb_build_object(
       'id','L1','kind','resale','section','1','row','E','seats',jsonb_build_array('1'),
       'quantity',1,'seat_type','FLASHSEATS','status','AVAILABLE',
       'pricing', jsonb_build_object('face',658.5,'all_in',826.42,'tax',73.42,
                                     'connection_fee',153,'sales_tax_on_fee',14.92,
                                     'sales_tax_on_ticket',58.5,'connection_fee_rate',0.255)))))
    INTO v_rows;
  IF (v_rows->'listings'->0->>'price')::numeric <> 600 THEN
    RAISE EXCEPTION 'resale price came back % , expected 600', v_rows->'listings'->0->>'price';
  END IF;
  IF abs((v_rows->'listings'->0->>'price')::numeric
       + (v_rows->'listings'->0->>'fee')::numeric
       + (v_rows->'listings'->0->>'tax')::numeric
       - (v_rows->'listings'->0->>'all_in')::numeric) > 0.011 THEN
    RAISE EXCEPTION 'resale still does not satisfy price + fee + tax = all_in';
  END IF;

  -- a primary body must be untouched: face 66 stays 66
  SELECT public.axs_watch_parse(jsonb_build_object(
    'event_id_requested','__t__',
    'event', jsonb_build_object('starts_local','2026-12-11T19:30:00-06:00','title','T'),
    'onsale', jsonb_build_object('offer_id','o1'),
    'listings', jsonb_build_array(jsonb_build_object(
       'id','L1','kind','primary','section','105','row','19','seats',jsonb_build_array('1'),
       'quantity',1,'seat_type','STANDARD','status','AVAILABLE',
       'pricing', jsonb_build_object('face',66,'all_in',94.18,'tax',7.18,
                                     'fees_total',21,'before_tax',87,'tax_rate',8.25)))))
    INTO v_rows;
  IF (v_rows->'listings'->0->>'price')::numeric <> 66 THEN
    RAISE EXCEPTION 'primary price came back %, expected 66 — primary must be untouched',
      v_rows->'listings'->0->>'price';
  END IF;
END $verify$;
