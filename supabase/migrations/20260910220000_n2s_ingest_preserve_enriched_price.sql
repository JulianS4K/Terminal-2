-- ============================================================================
-- Migration 20260910220000 — the CRM feed must not erase an enriched price
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_items_drain() — ONE column in its ON CONFLICT list.
-- Pre-reqs: 20260910030000 (creates the function), 20260910200000
--
-- READ-ONLY upstream: no API call. RULE 2 untouched.
--
-- ── THE BUG THIS FIXES, WHICH 20260910200000 CREATED ──────────────────────
-- n2s_sg_drain() fills n2s_items.price_per_ticket from SeatGeek for the orders
-- whose CRM feed reports it NULL. But the CRM upsert ran
--     price_per_ticket = EXCLUDED.price_per_ticket
-- unconditionally, and EXCLUDED is NULL for exactly those orders. So the
-- 2-minute CRM poll wiped the enriched value, the 2-minute pull refilled it,
-- and the column FLAPPED between 658.00 and NULL forever — with both jobs
-- reporting success the whole time. It was caught only because
-- n2s_pull_all_sources kept returning sg_prices_filled = 3 on a book where
-- those 3 were already filled: a counter that should have decayed to zero and
-- did not. Watch for that shape; a "successful" job doing identical work every
-- tick is doing no work at all.
--
-- ⚠ A NULL FROM THE FEED MEANS "NOT STATED", NOT "KNOWN TO BE NOTHING".
-- COALESCE keeps what we already hold when the incoming row is silent, so an
-- upstream that never carried the number cannot delete one we sourced
-- elsewhere. A real value from the feed still wins; this only guards absence.
--
-- ⚠ DELIBERATELY ONE COLUMN. Every other field stays a straight overwrite,
-- because for those the feed IS authoritative and must be able to change them:
-- status, is_terminal, the timers and the resolution timestamps all have to be
-- able to move, and blanket-COALESCEing the row would freeze an order in its
-- first-seen state and quietly break eviction. Do not widen this pattern
-- without making the same argument per column.
--
-- ── WHY THIS IS A TEXT PATCH AND NOT A REWRITTEN FUNCTION BODY ────────────
-- n2s_items_drain() is ~5KB of INSERT column list. Retyping it to change one
-- line risks silently altering another, which is not hypothetical: earlier in
-- this same session a hand-rewrite of n2s_pull_all_sources() from memory got
-- the edge-function URL, the GoTickets auth header and both poll-state tables
-- wrong, and would have stopped EVO and GoTickets pulling altogether. So this
-- reads the deployed definition, replaces exactly one substring, and re-executes
-- it — byte-faithful everywhere else by construction.
-- The guard is the point: if that substring is ever absent (someone edited the
-- line, or this ran twice), it RAISES instead of quietly doing nothing.
-- ============================================================================

DO $patch$
DECLARE
  d text;
  anchor  constant text := 'price_per_ticket = EXCLUDED.price_per_ticket';
  -- ⚠ THE ALIAS IS "t", NOT THE TABLE NAME. The insert is
  --   INSERT INTO public.n2s_items AS t ...
  -- and Postgres requires the ALIAS inside ON CONFLICT DO UPDATE once one is
  -- given: writing n2s_items.price_per_ticket there raises "invalid reference
  -- to FROM-clause entry". That exact mistake was shipped to prod and broke
  -- the 2-minute CRM ingest for ~4 minutes (cron 596 failing, nothing else
  -- affected) before it was reverted. The guard below asserts the alias rather
  -- than trusting this comment.
  patched constant text :=
    'price_per_ticket = COALESCE(EXCLUDED.price_per_ticket, t.price_per_ticket)';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'n2s_items_drain';

  IF d IS NULL THEN
    RAISE EXCEPTION 'n2s_items_drain() not found — 20260910030000 must run first';
  END IF;

  -- Already patched (re-run / replay past this point): nothing to do.
  IF position(patched IN d) > 0 THEN
    RAISE NOTICE 'n2s_items_drain already preserves price_per_ticket; no change';
    RETURN;
  END IF;

  IF position('INSERT INTO public.n2s_items AS t ' IN d) = 0 THEN
    RAISE EXCEPTION
      'n2s_items_drain(): the insert target is no longer aliased "t". '
      'Re-derive the alias from pg_get_functiondef before patching — the '
      'ON CONFLICT reference must use whatever alias is actually in force.';
  END IF;

  IF position(anchor IN d) = 0 THEN
    RAISE EXCEPTION
      'n2s_items_drain(): expected "%" not found. The upsert was changed '
      'elsewhere — reconcile by hand rather than guessing.', anchor;
  END IF;

  EXECUTE replace(d, anchor, patched);
END
$patch$;
