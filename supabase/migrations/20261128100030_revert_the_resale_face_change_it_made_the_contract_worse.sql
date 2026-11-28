-- Migration 20261128100030 · level:data-collection · lane:a1 (AXS watch parse) · writes:axs_watch_parse()(restored) · reads:-
--
-- ============================================================================
-- Migration 20261128100030 — revert 20261128090030; it made the contract worse
--
-- Lane:     a1 (AXS watch)
-- pre:      20261128090030 (the change this undoes)
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- ── WHAT I GOT WRONG ──────────────────────────────────────────────────────
-- 20261128090030 netted sales_tax_on_ticket off `face` for every listing, on the strength of
-- ONE venue's raw body (Ryman Auditorium, event 1670958). That body is real and the arithmetic
-- on it is right. Generalising from it was not: resale pricing does not have one shape.
--
-- Measured on prod, rows breaking price + fee + tax = all_in_price:
--     before the change   494 of 26,455 resale rows   1.9%
--     after  the change   862 of  8,785 resale rows   9.8%
-- Primary stayed clean throughout (0 of 70,857). So the change made the field it was meant to
-- fix worse, by a factor of five, and it is reverted rather than left in over a weekend.
--
-- ── THE SHAPE I HAD NOT SEEN ──────────────────────────────────────────────
-- Opry House resale rows (event 1115342), AFTER the change:
--     price 78.30   fee 18.19   tax 8.73   all_in 98.26     gap +6.96
--     all_in / price = 1.2549
-- all_in is price x 1.255 with price ALREADY net, so `face` there carries no ticket tax and the
-- change was subtracting nothing. The mismatch at that venue is in `fee`: stored at 0.2323 of
-- price (which is `fees_total`) while all_in implies 0.255 (which is `connection_fee`). Ryman's
-- mismatch was in `face`. Two venues, two different culprits.
--
-- ── WHAT IS ACTUALLY ESTABLISHED, AND WHAT IS NOT ─────────────────────────
-- Established, from raw bodies:
--   · primary: face is net, before_tax = face + fees_total, all_in = before_tax x (1+tax_rate).
--     price + fee + tax = all_in holds for every primary row. Nothing to do.
--   · resale at Ryman: face = net + sales_tax_on_ticket, all_in = face + connection_fee +
--     sales_tax_on_fee, and both fees_total and connection_fee are present.
--   · resale with no tax at all (event 1644160): face + connection_fee = all_in, clean.
-- NOT established: the rule that covers every venue. `fees_total` vs `connection_fee` and
-- whether `face` includes the ticket tax appear to vary, and I have one body per shape.
--
-- Raw capture is now on for a second resale venue (Opry House 1115342) alongside Ryman
-- (1670958), so the next fix is derived from several bodies rather than one. Until then the
-- mapping stays as it was: all_in_price is AXS's own total and is CORRECT in every case
-- measured; only summing price + fee + tax is unreliable, on ~1.9% of resale rows and 0% of
-- primary. Characterised by tests/sql/axs_watch s39.
--
-- rollback: re-apply 20261128090030 (not advised — see above).
-- ============================================================================

DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  new CONSTANT text := '           nullif(l->''pricing''->>''face'', '''')::numeric AS price,';
  old CONSTANT text :=
    '           -- mig 20261128090030: a resale face is GROSS of the ticket tax, a primary face' || E'\n' ||
    '           -- is net. Subtracting it keeps price + fee + tax = all_in for both; primary' || E'\n' ||
    '           -- bodies carry no sales_tax_on_ticket, so primary is unchanged.' || E'\n' ||
    '           nullif(l->''pricing''->>''face'', '''')::numeric' || E'\n' ||
    '             - coalesce(nullif(l->''pricing''->>''sales_tax_on_ticket'', '''')::numeric, 0) AS price,';
  n int;
BEGIN
  IF position('sales_tax_on_ticket' in src) = 0 THEN
    RAISE NOTICE 'the parse already reads face straight; nothing to revert';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'the revert anchor matched % times, expected 1', n; END IF;
  EXECUTE replace(src, old, new);
END $surgery$;

DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  v jsonb;
BEGIN
  IF position('sales_tax_on_ticket' in src) > 0 THEN
    RAISE EXCEPTION 'read-back: the parse still nets the ticket tax off the face';
  END IF;
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
    INTO v;
  IF (v->'listings'->0->>'price')::numeric <> 658.5 THEN
    RAISE EXCEPTION 'revert failed: resale price came back %, expected the raw face 658.5',
      v->'listings'->0->>'price';
  END IF;
END $verify$;
