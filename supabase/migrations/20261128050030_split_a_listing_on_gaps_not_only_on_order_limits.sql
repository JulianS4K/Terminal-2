-- Split a listing because its seats are not adjacent, not only because it is too big to buy.
--
-- Found by the operator spot-checking for KING + COUNTRY at Target Center (axs 1527095),
-- section 113 row P. We publish it as one row, seat_low 10, seat_high 14, quantity 3,
-- max_per_order 3 -- which reads as three seats together. The seats are ["10","13","14"]:
-- seat 10 on its own, then 13 and 14, with 11 and 12 missing.
--
-- primary_poll_pieces() is correct and already splits on gaps; it returns exactly
-- (seat 10, qty 1) and (seats 13-14, qty 2) for that input. The fault is in which listings
-- primary_poll_split_event() hands to it:
--
--     AND l.order_limit > 0 AND l.quantity > l.order_limit AND x.parts > 1
--                             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
--
-- The splitter was built to break up a listing too large to buy in one order, and contiguity
-- splitting only ever happened as a side effect of that. A listing whose quantity fits inside
-- the order limit is never offered to the splitter at all, however many gaps it has. 113 row P
-- is quantity 3 against an order limit of 3, so 3 > 3 is false and it goes out whole.
--
-- On this one event 29 of 346 listings are non-contiguous and exactly 1 is split.
--
-- The condition is simply dropped. x.parts > 1 already distinguishes the two cases on its own:
-- it is false for genuinely adjacent seats inside the limit (["3","4","5"], qty 3, limit 3 ->
-- parts 1) and true when either a gap or an order limit forces a break. Nothing else changes:
-- the obstructed and order_limit > 0 guards stay, and the piece shape is whatever
-- primary_poll_pieces already produced.
--
-- The listing_id suffix is NOT a new contract. The feed has always emitted <id>-<part> for a
-- split listing and the CRM already receives them -- 655373020704273417-1 and -2 are in this
-- very event's current output. Only the number of rows changes, and in the direction of being
-- true.

BEGIN;

DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.primary_poll_split_event(text,text)'::regprocedure);
  old_cond CONSTANT text := 'AND NOT l.obstructed AND l.order_limit > 0 AND l.quantity > l.order_limit';
  new_cond CONSTANT text := 'AND NOT l.obstructed AND l.order_limit > 0';
  n int;
BEGIN
  IF position('l.quantity > l.order_limit' in src) = 0 THEN
    RAISE NOTICE 'the splitter already runs on gaps; nothing to do';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, old_cond, ''))) / length(old_cond);
  IF n <> 1 THEN
    RAISE EXCEPTION 'split_event condition matched % times, expected 1', n;
  END IF;
  EXECUTE replace(src, old_cond, new_cond);
END $surgery$;

DO $verify$
DECLARE
  src text := pg_get_functiondef('public.primary_poll_split_event(text,text)'::regprocedure);
BEGIN
  IF position('l.quantity > l.order_limit' in src) > 0 THEN
    RAISE EXCEPTION 'read-back: the order-limit-only condition is still there';
  END IF;
  IF position('AND NOT l.obstructed AND l.order_limit > 0' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the obstructed / order_limit guards were lost';
  END IF;
  IF position('x.parts > 1' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the parts guard was lost';
  END IF;
  -- the behaviour the fix depends on, asserted rather than assumed
  IF (SELECT count(*) FROM public.primary_poll_pieces('["10","13","14"]'::jsonb, 3, 3)) <> 2 THEN
    RAISE EXCEPTION 'a gapped listing inside its order limit must yield 2 pieces';
  END IF;
  IF (SELECT count(*) FROM public.primary_poll_pieces('["3","4","5"]'::jsonb, 3, 3)) <> 1 THEN
    RAISE EXCEPTION 'adjacent seats inside the order limit must stay whole';
  END IF;
END $verify$;

COMMIT;
