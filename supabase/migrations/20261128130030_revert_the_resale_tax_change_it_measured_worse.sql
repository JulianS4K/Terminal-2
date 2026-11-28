-- Migration 20261128130030 · level:data-collection · lane:a1 (AXS watch parse) · writes:axs_watch_parse()(restored) · reads:-
--
-- ============================================================================
-- Migration 20261128130030 — revert the resale tax change; it measured worse
--
-- Lane:     a1 (AXS watch)
-- pre:      20261128110030 (the change this undoes)
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- ── THE MEASUREMENT ───────────────────────────────────────────────────────
-- Once EVERY axs listing had re-polled under 20261128110030, resale rows breaking
-- price + fee + tax = all_in_price reached 4,696 of 35,266 (13.32%), against the ~1.9%
-- baseline standing before any of today's changes. Primary stayed clean, 0 of 70,797.
--
-- Unlike the measurement that misled me earlier today, this one is not confounded: every row
-- is post-change, so there is no population mismatch between the two sides of the comparison.
--
-- ── WHY IT WAS WRONG ──────────────────────────────────────────────────────
-- The tax half was right but incomplete. The real resale identity is
--     all_in = face + connection_fee + sales_tax_on_fee
-- Our fee is coalesce(fees_total, connection_fee). Wherever a resale body carries BOTH fee
-- fields we take fees_total (the net fee) while all_in is built from connection_fee (the gross
-- one), so the row cannot balance however `tax` is mapped.
--
-- Ryman 1670958 and Opry House 1115342 — the two bodies I derived the rule from — happen to
-- carry connection_fee ONLY. That is exactly why they balanced, and exactly why generalising
-- from them failed a second time in one day.
--
-- ── THE LIKELY COMPLETE FIX, NOT APPLIED ──────────────────────────────────
--     fee = coalesce(connection_fee, fees_total)    <- note the order, reversed from today's
--     tax = coalesce(sales_tax_on_fee, tax)
-- Both halves together, or neither. This is a HYPOTHESIS. It needs raw bodies from venues that
-- carry both fee fields, which axs_watch_raw_capture does not yet cover — the capture list is
-- 1374728, 1519444, 1579099, 1579101, 1583731, 1670958, 1115342. Add a venue that carries both
-- before trying again, and verify against stored bodies rather than against aggregate counts.
--
-- ── WHAT IS ACTUALLY TRUE, AND STILL WORTH KNOWING ────────────────────────
-- The operator's AXS cart (Pechanga, Sec LL24 Row 2, resale): 2 x $52.80 + $26.92 = $132.52,
-- with NO tax line, the fee exactly 25.5% of face. Our rows for that listing (events 1583500,
-- 1583501) read price 52.80, fee 13.46, tax 0, all_in 66.26 — correct to the cent. So:
--   · `face` is the ticket price AXS displays to the buyer. Do not move `price` off it.
--   · sales_tax_on_ticket is never charged on top; it sits inside `face`.
--   · all_in_price is AXS's own total and has been correct throughout. A CRM consumer reading
--     all_in_price was never wrong. Only summing the three parts is unreliable, on ~1.9% of
--     resale rows and 0% of primary.
--
-- ── ANCHORING, WHICH COST TWO FAILED ATTEMPTS ─────────────────────────────
-- Prod carries "mig 20261128110000" because that was the filename when it was applied; the
-- repo file was renamed to ...110030 afterwards for a prefix collision. Two hand-written
-- literal anchors then matched 0 times, because the deployed comment is THREE lines, not one.
-- The guard refused both rather than mangling the function, which is the point of it. This
-- migration instead matches a pattern against the body read back from pg_get_functiondef and
-- asserts the result — changed, no sales_tax_on_fee left, original line restored, and under
-- 500 bytes removed — before executing. Copy this approach, not the literal-anchor one, when
-- the deployed text may not match what the repo thinks it says.
--
-- rollback: re-apply 20261128110030 (not advised — see the measurement above).
-- ============================================================================

DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  out text;
BEGIN
  IF position('sales_tax_on_fee' in src) = 0 THEN
    RAISE NOTICE 'the parse already reads pricing.tax straight; nothing to revert';
    RETURN;
  END IF;
  out := regexp_replace(src,
           '[ ]*-- mig 2026112811[0-9]{4}.*?AS tax,',
           '           nullif(l->''pricing''->>''tax'', '''')::numeric AS tax,',
           '');
  IF out = src THEN
    RAISE EXCEPTION 'the revert pattern changed nothing';
  END IF;
  IF position('sales_tax_on_fee' in out) <> 0 THEN
    RAISE EXCEPTION 'the revert left sales_tax_on_fee behind';
  END IF;
  IF position('nullif(l->''pricing''->>''tax'', '''')::numeric AS tax,' in out) = 0 THEN
    RAISE EXCEPTION 'the revert did not restore the original tax line';
  END IF;
  IF length(src) - length(out) > 500 THEN
    RAISE EXCEPTION 'the revert removed % bytes, far more than the ~363 expected',
      length(src) - length(out);
  END IF;
  EXECUTE out;
END $surgery$;

DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_parse(jsonb)'::regprocedure);
  r jsonb;
BEGIN
  IF position('sales_tax_on_fee' in src) > 0 THEN
    RAISE EXCEPTION 'read-back: the parse still reads sales_tax_on_fee';
  END IF;
  SELECT public.axs_watch_parse(jsonb_build_object(
    'event_id_requested','__t__',
    'event',  jsonb_build_object('starts_local','2027-02-06T19:30:00-06:00','title','T'),
    'onsale', jsonb_build_object('offer_id','o1'),
    'listings', jsonb_build_array(jsonb_build_object(
      'id','L1','kind','resale','section','1','row','E','seats',jsonb_build_array('1'),
      'quantity',1,'seat_type','FLASHSEATS','status','AVAILABLE',
      'pricing','{"tax":73.42,"face":658.5,"all_in":826.42,"connection_fee":153,"sales_tax_on_fee":14.92,"sales_tax_on_ticket":58.5}'::jsonb))))
    -> 'listings' -> 0 INTO r;
  IF (r->>'tax')::numeric <> 73.42 THEN
    RAISE EXCEPTION 'revert failed: tax came back %, expected the raw 73.42', r->>'tax';
  END IF;
  IF (r->>'price')::numeric <> 658.5 THEN
    RAISE EXCEPTION 'revert failed: price came back %, expected the raw face 658.5', r->>'price';
  END IF;
  SELECT public.axs_watch_parse(jsonb_build_object(
    'event_id_requested','__t__',
    'event',  jsonb_build_object('starts_local','2026-12-11T19:30:00-06:00','title','T'),
    'onsale', jsonb_build_object('offer_id','o1'),
    'listings', jsonb_build_array(jsonb_build_object(
      'id','L1','kind','primary','section','105','row','19','seats',jsonb_build_array('1'),
      'quantity',1,'seat_type','STANDARD','status','AVAILABLE',
      'pricing','{"tax":7.18,"face":66,"all_in":94.18,"fees_total":21,"before_tax":87,"tax_rate":8.25}'::jsonb))))
    -> 'listings' -> 0 INTO r;
  IF abs((r->>'price')::numeric + (r->>'fee')::numeric + (r->>'tax')::numeric
         - (r->>'all_in')::numeric) > 0.011 THEN
    RAISE EXCEPTION 'primary no longer satisfies price+fee+tax=all_in';
  END IF;
END $verify$;
