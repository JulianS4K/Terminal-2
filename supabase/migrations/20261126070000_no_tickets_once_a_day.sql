-- Migration 20261126070000 · level:data-collection · lane:a1 (AXS watch cadence) · writes:axs_watch_config(+no_tickets_every),axs_watch_settle_one()(patched) · reads:-
--
-- ============================================================================
-- Migration 20261126070000 — "no tickets available" is read once a day, not four times
--
-- Lane:     a1 (AXS watch cadence)
-- pre:      20261126065000 (the dead-event rules and the slow branch this splits).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- ── WHAT THE OPERATOR ASKED FOR ───────────────────────────────────────────
-- Operator 2026-11-26: "Ok if it shows no tickets currently available ping once a day
-- instead."
--
-- Context: 20261126065000 retires such an event when it is within no_tickets_retire_days
-- (7). Beyond that window it stays on the list, because a far-out event answering that way
-- has usually not released inventory yet. Until now it sat on not_on_sale_every (6 hours),
-- shared with "not on sale" and "coming soon". This gives it its own, slower knob.
--
-- The slow branch in axs_watch_settle_one matched five strings and applied one interval to
-- all of them. It now picks: no_tickets_every (1 day) for the no-tickets case,
-- not_on_sale_every (6 hours) for everything else it already covered. "Not on sale" and
-- "coming soon" are kept at 6 hours deliberately — those events are waiting for an on-sale
-- moment that can arrive at any hour, and missing it by up to a day would matter. An event
-- that is on sale and has no inventory is a different thing: nothing is about to happen.
--
-- ── WHAT IT SAVES ─────────────────────────────────────────────────────────
-- One event today: "Matt Rife - Saturday" at Yaamava' Theater, 9 days out, 6h -> 24h, so
-- 4 reads a day becomes 1. Three credits a day.
--
-- Small because the population is small, and worth saying why rather than implying more:
-- the two Sienna Spiro shows carrying the same error are 287 and 288 days out, beyond
-- watch_until_days (180), so they are catalogue-only and already cost nothing at all.
--
-- ⚠ KNOWN, NOT FIXED HERE: axs_watch_cadence_demand() computes an event's cadence from its
-- proximity band and the ga_slow flag, and knows nothing about this override or the
-- not_on_sale one. So the gauge OVER-states demand for an event on either slow rule — by
-- about 20 reads/day for this one event (it counts Matt Rife at its 60-minute band rather
-- than at 24 hours). Same class of mismatch as 20261126062000, two orders of magnitude
-- smaller. Fixing it properly means the gauge reading stored poll_interval instead of
-- recomputing, which would stop cadence_scale changes showing until each event's next read
-- — a real trade-off, and an operator call rather than a drive-by.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- UPDATE public.axs_watch_config SET no_tickets_every = not_on_sale_every;
-- ============================================================================

BEGIN;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS no_tickets_every interval NOT NULL DEFAULT interval '1 day'
    CHECK (no_tickets_every >= interval '5 minutes' AND no_tickets_every <= interval '7 days');
COMMENT ON COLUMN public.axs_watch_config.no_tickets_every IS
  'Cadence for an event whose read says "no tickets are currently available" and which is beyond no_tickets_retire_days (mig 20261126070000). Separate from not_on_sale_every because an on-sale event with no inventory has nothing about to happen, where one waiting for an on-sale moment does.';

DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_settle_one not found'; END IF;
  v_new := v_src;

  -- (a) a local for the chosen interval
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new, '  v_ga_slow boolean := false;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle DECLARE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, '  v_ga_slow boolean := false;',
                          E'  v_ga_slow boolean := false; v_slow interval;');

  -- (b) the slow branch picks its interval instead of applying one to all five strings
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'SET poll_interval = v_cfg\.not_on_sale_every, next_poll_at = now\(\) \+ v_cfg\.not_on_sale_every \* \(0\.75 \+ random\(\) \* 0\.5\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'slow UPDATE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'SET poll_interval = v_cfg.not_on_sale_every, next_poll_at = now() + v_cfg.not_on_sale_every * (0.75 + random() * 0.5)',
    'SET poll_interval = v_slow, next_poll_at = now() + v_slow * (0.75 + random() * 0.5)');

  -- and set it just before, from which string matched
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'coming soon\\|\\\\mcancel\\(l\\?\\)ed\\\\M'' THEN\\n', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'slow branch head: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'coming soon|\\mcancel(l?)ed\\M'' THEN\n',
    E'coming soon|\\mcancel(l?)ed\\M'' THEN\n'
    || E'      -- an event that is ON SALE with no inventory has nothing about to happen, so it is\n'
    || E'      -- read once a day; one waiting for an on-sale moment keeps the 6-hour rule, because\n'
    || E'      -- that moment can arrive at any hour (mig 20261126070000).\n'
    || E'      v_slow := CASE WHEN v_error ~* ''no tickets are currently available''\n'
    || E'                     THEN v_cfg.no_tickets_every ELSE v_cfg.not_on_sale_every END;\n');

  IF v_new = v_src THEN RAISE EXCEPTION 'settle unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
  IF v_src !~ 'v_cfg\.no_tickets_every' OR v_src !~ 'poll_interval = v_slow' THEN
    RAISE EXCEPTION 'settle did not take the no_tickets_every split';
  END IF;
END $surgery$;

-- bring the events already on the 6-hour rule into line, so the change is not waiting on
-- each one's next read
UPDATE public.primary_poll_event t
   SET poll_interval = (SELECT c.no_tickets_every FROM public.axs_watch_config c),
       next_poll_at  = now() + (SELECT c.no_tickets_every FROM public.axs_watch_config c)
                               * (0.75 + random() * 0.5)
 WHERE t.source = 'axs' AND t.watch
   AND t.poll_error ~* 'no tickets are currently available'
   AND t.poll_interval = (SELECT c.not_on_sale_every FROM public.axs_watch_config c);

COMMIT;
