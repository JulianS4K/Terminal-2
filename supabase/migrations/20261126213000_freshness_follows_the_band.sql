-- Migration 20261126213000 · level:data-collection · lane:a1 (the feed's freshness gate) · writes:v_primary_poll_events_feed(patched),v_primary_poll_listings_feed(patched) · reads:primary_poll_event,primary_poll_config
--
-- ============================================================================
-- Migration 20261126213000 — the feed's freshness window follows the event's own band
--
-- Lane:     a1 (data plane; the two feed views)
-- pre:      20261123190030 (listing_max_age), 20261123194030 (per-event bands).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes which rows we are
-- willing to publish from reads we have already paid for.
--
-- ── WHAT THE OPERATOR ASKED FOR ───────────────────────────────────────────
-- Operator 2026-11-26: "Fix the stale issue."
--
-- ── WHAT WAS WRONG ────────────────────────────────────────────────────────
-- Both feeds publish an event's listings only while
--
--     now() < GREATEST(poll_ok_at + listing_max_age, next_poll_at + listing_grace)
--
-- listing_max_age (35 min) was chosen in 20261123190030, when EVERY source polled on one
-- 30-minute cycle: "one 30-minute cycle plus the run's own time". 20261123194030 then gave
-- each event its own band, and the AXS watch now runs bands of 30 min, 1 h, 1 h 30,
-- 2 h and 4 h (and 1 day for the sold-out rule). The flat 35 minutes was never revisited,
-- so for every band above 35 minutes the first arm is dead and the window rests entirely on
-- the second: next_poll_at + 20 minutes.
--
-- And next_poll_at is a poor proxy for "how long this data is good for", because the settle
-- phase-ALIGNS it (mig 20261126023000): next_poll_at is the next slot on the event's grid,
-- which can be a minute after the read or a full band after it. An hour-band event read just
-- before its grid slot therefore gets a 21-minute window on data we consider good for an
-- hour — and goes dark until its next read lands.
--
-- Measured on the live watch at 2026-11-26 20:30Z, 341 watched events:
--     258 events / 79,232 listing rows publishable
--      72 events outside the window, median 7 minutes past it, none more than 15
-- Those 72 had all been read successfully and charged for. They were withheld because the
-- window had closed, not because the data was old relative to their own band.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────
-- Anchor the first arm to the event's own cadence instead of a constant:
--
--     now() < GREATEST(poll_ok_at + GREATEST(listing_max_age, poll_interval + listing_grace),
--                      next_poll_at + listing_grace)
--
-- Read in words: a listing stays publishable for one of its event's own polling bands plus
-- the lateness allowance, and never for less than listing_max_age. The second arm is kept —
-- it still carries an event whose next read is deliberately far off.
--
-- GREATEST(listing_max_age, ...) is what keeps this from LOOSENING anything: a band shorter
-- than 15 minutes still gets the 35-minute floor it has today, so the Timberwolves source's
-- 10-minute band is untouched.
--
-- Both config lookups stay UNCORRELATED scalar subqueries, so they remain one InitPlan for
-- the whole scan rather than a lookup per row — the listings feed is ~98k rows. That is why
-- the GREATEST is written over the two intervals rather than inside a single subquery.
--
-- ── WHAT IT CHANGES, MEASURED BEFORE APPLYING ─────────────────────────────
--     axs           events publishable 258 -> 318, listing rows 79,232 -> 98,706
--                   (+19,474 rows, +24.6%), all of them already read and charged for
--     sitickets     no change (10 events, 1,574 rows; never late)
--     timberwolves  no change (29 events, 15,115 rows; never late)
--     oldest data published  99 min -> 116 min
-- The two other sources are unchanged because they are not behind; the new arm only ever
-- matters for an event whose read ran late.
--
-- ⚠ WHAT THIS DOES NOT FIX. Reads ARE running late: at 20:30Z, 156 of 301 read-ok watched
-- events were past their next_poll_at, median 17.7 min, p90 30.2, max 37.9; the queue had
-- 55 pending, its 6 lanes all busy, oldest pending 27 min, and it resolved 274 reads in the
-- hour against bands demanding ~344. The worker reads and acks SERIALLY (~13 s a cycle:
-- 6.3 s at TicketsData, the rest the ack's own ingest), so one worker cannot clear 344/h
-- however many lanes it claims. This migration stops that deficit COSTING COVERAGE; it does
-- not remove the deficit. That is a second reader (or concurrent reads inside this one) and
-- is an operator call — it changes how many reads reach TicketsData at once.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- Re-apply 20261125200000_primary_poll_ada_null_ticket_type.sql, which last stated both
-- views in full.
-- ============================================================================

BEGIN;

DO $surgery$
DECLARE
  v_view   text;
  v_src    text;
  v_new    text;
  v_opts   text[];
  v_cols   text;
  v_after  text;
  v_cols2  text;
  v_opts2  text;
  v_hits   integer;
  -- the first arm as pg_get_viewdef prints it, whitespace-tolerant, with the config alias
  -- captured so the same pattern fits both views (the events feed's lateral names it c_1)
  c_old    text := 't\.poll_ok_at \+ \({1,2}\s*SELECT (c(?:_\d+)?)\.listing_max_age\s+FROM primary_poll_config \1\){1,2}';
  c_new    text := 't.poll_ok_at + GREATEST((SELECT \1.listing_max_age FROM primary_poll_config \1), '
                || 'COALESCE(t.poll_interval, interval ''0'') + (SELECT \1.listing_grace FROM primary_poll_config \1))';
BEGIN
  FOREACH v_view IN ARRAY ARRAY['v_primary_poll_events_feed', 'v_primary_poll_listings_feed'] LOOP
    SELECT pg_get_viewdef(c.oid, true), c.reloptions,
           (SELECT string_agg(a.attname || ':' || a.atttypid::regtype::text, ',' ORDER BY a.attnum)
              FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped)
      INTO v_src, v_opts, v_cols
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = v_view AND c.relkind = 'v';
    IF v_src IS NULL THEN RAISE EXCEPTION 'view public.% not found', v_view; END IF;

    -- exactly one freshness arm, or we are patching something we do not understand
    SELECT count(*) INTO v_hits FROM regexp_matches(v_src, c_old, 'g');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION '%: expected 1 poll_ok_at + listing_max_age arm, found %', v_view, v_hits;
    END IF;
    IF v_src ~ 'COALESCE\(t\.poll_interval' THEN
      RAISE EXCEPTION '%: already band-relative', v_view;   -- a re-apply must not nest the GREATEST
    END IF;

    v_new := regexp_replace(v_src, c_old, c_new, 'g');
    IF v_new = v_src THEN RAISE EXCEPTION '%: unchanged', v_view; END IF;

    -- reloptions are NOT the same on the two views (the events feed is security_invoker, the
    -- listings feed is not), so each is re-emitted as it was rather than assumed
    EXECUTE format('CREATE OR REPLACE VIEW public.%I %s AS %s', v_view,
                   CASE WHEN v_opts IS NULL THEN ''
                        ELSE 'WITH (' || array_to_string(v_opts, ', ') || ')' END,
                   v_new);

    -- read back: same columns in the same order and types (CREATE OR REPLACE VIEW would have
    -- refused a rename or a retype, but not an addition), same options, the new arm in place
    SELECT pg_get_viewdef(c.oid, true),
           (SELECT string_agg(a.attname || ':' || a.atttypid::regtype::text, ',' ORDER BY a.attnum)
              FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
           coalesce(array_to_string(c.reloptions, ','), '')
      INTO v_after, v_cols2, v_opts2
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = v_view;
    IF v_cols2 IS DISTINCT FROM v_cols THEN
      RAISE EXCEPTION '%: columns changed', v_view;
    END IF;
    IF v_opts2 IS DISTINCT FROM coalesce(array_to_string(v_opts, ','), '') THEN
      RAISE EXCEPTION '%: reloptions changed (% -> %)', v_view, v_opts, v_opts2;
    END IF;
    IF v_after !~ 'COALESCE\(t\.poll_interval' OR v_after !~ 'listing_grace' THEN
      RAISE EXCEPTION '%: did not take the band-relative window', v_view;
    END IF;
  END LOOP;
END $surgery$;

COMMENT ON VIEW public.v_primary_poll_listings_feed IS
  'GET /primary/listings. A listing is published while its event''s last good read is no older than the event''s own poll_interval plus primary_poll_config.listing_grace, floored at listing_max_age (mig 20261126213000) — not for a flat 35 minutes, which predates per-event bands.';

COMMIT;
