-- Migration 20261126214500 · level:data-collection · lane:a1 (AXS watch cadence) · writes:axs_watch_settle_one()(patched),axs_watch_event_dead()(replaced),primary_poll_event(backfill) · reads:primary_poll_event,axs_watch_poll,axs_watch_config
--
-- ============================================================================
-- Migration 20261126214500 — a read that finds no listings is treated as sold out
--
-- Lane:     a1 (AXS watch cadence)
-- pre:      20261126065000 (axs_watch_event_dead, the retire rules),
--           20261126070000 (no_tickets_every), 20261126150000 (cadence_pinned).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- ── WHAT THE OPERATOR ASKED FOR ───────────────────────────────────────────
-- Operator 2026-11-26: "if zero listings treat the same way we do for sold out".
--
-- ── THE TWO SHAPES AXS HAS FOR "NOTHING TO SELL" ──────────────────────────
-- AXS says it two ways, and until now we only recognised one:
--
--   1. exit_code 1 with "No tickets are currently available for this event."
--      -> axs_watch_settle_one's outcome 'unparsed', the slow branch, no_tickets_every
--         (1 day), cadence_pinned; and axs_watch_event_dead retires it when the event is
--         within no_tickets_retire_days (7).
--
--   2. exit_code 0 with a proper event object and an EMPTY listings array
--      -> outcome 'empty'. Nothing was done with it: the event kept whatever band its
--         proximity gave it and was read 24 times a day for nothing.
--
-- They mean the same thing, so they now get the same treatment. Shape 2 is the commoner
-- one: it is what a genuinely sold-out event looks like, and what a far-out event that has
-- not released inventory looks like.
--
-- ── WHAT IT SAVES, MEASURED BEFORE APPLYING ───────────────────────────────
-- Four of the 341 watched events were in shape 2 at 2026-11-26 20:30Z, every one of them on
-- the 1-hour band, every read of each of them empty:
--     1484015  2027 BNP Paribas Open - Session Q1   Indian Wells    94 days out   36 empty reads
--     1484019  2027 BNP Paribas Open - Session Q2   Indian Wells    95 days out   34 empty reads
--     1484020  2027 BNP Paribas Open - Session Q3   Indian Wells    96 days out   35 empty reads
--     1607398  Toy Factory Project                  Ryman           33 days out    2 empty reads
-- 4 x 24 reads a day -> 4 x 1. About 92 credits a day, and ~3.8 reads an hour off a demand
-- the one worker is already behind on.
--
-- None is within 7 days, so none is retired today — which is the same reasoning
-- 20261126065000 gave for the error-string rule: a far-out event with nothing on sale has
-- usually not released inventory yet, and the BNP Paribas qualifier sessions are the named
-- example. The retire arm is therefore INERT on today's data; it exists so that a near-term
-- event that has actually sold out leaves the list, exactly as shape 1 already does.
--
-- ── IT UNPINS ITSELF ──────────────────────────────────────────────────────
-- The band UPDATE above this branch sets cadence_pinned = v_ga_slow (false here), so the
-- first read that finds listings puts the event back on its proximity band within one day.
-- The cost of the rule is therefore bounded: up to one day's delay in noticing an on-sale,
-- the same trade 20261126070000 already took for shape 1.
--
-- ⚠ KNOWN, NOT FIXED HERE: axs_watch_cadence_demand() recomputes an event's cadence from
-- its band rather than reading poll_interval, so the gauge still counts these four at
-- 1 hour. It over-states demand by ~3.8 reads/hour. Same gap 20261126070000 recorded, same
-- reason for leaving it: fixing it means the gauge reading stored poll_interval, which would
-- stop a cadence_scale change showing until each event's next read.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- Re-apply 20261126070000 (settle) and 20261126065000 (axs_watch_event_dead), then
-- UPDATE public.primary_poll_event SET cadence_pinned = false
--  WHERE source='axs' AND poll_status='ok' AND coalesce(listing_count,0)=0;
-- ============================================================================

BEGIN;

-- ── 1. the settle: an empty read takes the sold-out band ──────────────────
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_settle_one';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_settle_one not found'; END IF;
  IF v_src ~ 'v_outcome = ''empty'' OR' THEN RAISE EXCEPTION 'settle already covers the empty read'; END IF;
  v_new := v_src;

  -- (a) the branch is entered for an empty read as well as for the five error strings
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new, 'IF v_outcome = ''unparsed'' AND v_error ~\* ''not \(currently ', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'slow branch head: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'IF v_outcome = ''unparsed'' AND v_error ~* ''not (currently ',
    'IF v_outcome = ''empty'' OR (v_outcome = ''unparsed'' AND v_error ~* ''not (currently ');

  -- ...and the condition is closed before THEN. This is the ONLY \mcancel(l?)ed\M'' THEN in
  -- the body (20261126070000 asserted the same site), so the paren lands on that condition.
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new, E'\\\\mcancel\\(l\\?\\)ed\\\\M'' THEN', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'slow branch close: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, E'\\mcancel(l?)ed\\M'' THEN', E'\\mcancel(l?)ed\\M'') THEN');

  -- (b) an empty read picks no_tickets_every. The test on v_outcome comes FIRST because
  -- v_error is NULL for an empty read, so the regex test alone would be NULL and fall
  -- through to not_on_sale_every (6 hours).
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'v_slow := CASE WHEN v_error ~\* ''no tickets are currently available''', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'slow CASE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'v_slow := CASE WHEN v_error ~* ''no tickets are currently available''',
    'v_slow := CASE WHEN v_outcome = ''empty'' OR v_error ~* ''no tickets are currently available''');

  IF v_new = v_src THEN RAISE EXCEPTION 'settle unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_settle_one';
  IF v_src !~ 'IF v_outcome = ''empty'' OR \(v_outcome = ''unparsed'''
     OR v_src !~ 'CASE WHEN v_outcome = ''empty'' OR v_error ~\*'
     OR v_src !~ 'poll_interval = v_slow, cadence_pinned = true' THEN
    RAISE EXCEPTION 'settle did not take the empty-read arm';
  END IF;
END $surgery$;

-- ── 2. the retire check: an empty read counts like the no-tickets error ───
-- Stated in full rather than patched: the change is to the shape of the union (it carries a
-- flag beside the error text now), not to a line inside it.
CREATE OR REPLACE FUNCTION public.axs_watch_event_dead(p_event_id text, p_event_date date)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cfg AS (SELECT c.no_tickets_retire_days AS days FROM public.axs_watch_config c),
  s AS (
    -- TWO sources, and both are needed.
    --
    -- The event's own last read. primary_poll_ingest writes it on EVERY read path — the
    -- worker's axs_watch_record AND the queue's axs_queue_ack -> axs_watch_settle_one — and
    -- a good read sets poll_error back to NULL and listing_count to what it found, so
    -- neither signal can go stale. An empty read is poll_status 'ok' with no listings: the
    -- ingest deletes the old capture before re-inserting, so a sold-out event really does
    -- fall to 0 rather than keeping yesterday's count.
    SELECT e.poll_error AS err,
           (e.poll_status = 'ok' AND e.poll_ok_at IS NOT NULL AND coalesce(e.listing_count, 0) = 0) AS empty
      FROM public.primary_poll_event e
     WHERE e.source = 'axs' AND e.source_event_id = p_event_id
       AND (e.poll_error IS NOT NULL OR e.poll_status = 'ok')
    UNION ALL
    -- And the read ledger, which outlives the event being taken OFF the list. Without it the
    -- retire arm and the candidate arm would disagree: the fill would remove a dead event
    -- and the same fill's backfill would hand it a place straight back, because
    -- primary_poll_event no longer has a row to carry the signal.
    SELECT w.error, w.outcome = 'empty'
      FROM public.axs_watch_poll w
     WHERE w.axs_event_id = p_event_id
       AND (w.error IS NOT NULL OR w.outcome = 'empty')
       AND w.checked_at = (SELECT max(w2.checked_at) FROM public.axs_watch_poll w2
                            WHERE w2.axs_event_id = p_event_id AND w2.checked_at IS NOT NULL))
  SELECT coalesce(bool_or(
           s.err ~* '\mcancel(l?)ed\M'
           -- AXS's two shapes for "nothing to sell" (mig 20261126214500), near-term only:
           -- a far-out event with nothing on sale has usually not released inventory yet.
           OR ((s.err ~* 'no tickets are currently available' OR coalesce(s.empty, false))
               AND p_event_date IS NOT NULL
               AND (SELECT c.days FROM cfg c) > 0
               AND p_event_date <= current_date + (SELECT c.days FROM cfg c))), false)
    FROM s
$function$;
COMMENT ON FUNCTION public.axs_watch_event_dead(text, date) IS
  'True when an AXS event is not worth reading again: the read says cancelled (any date), or the read found nothing on sale — either the "no tickets are currently available" error or a successful read with an empty listings array (mig 20261126214500) — and the event is within axs_watch_config.no_tickets_retire_days.';

-- ── 3. bring the events already in shape 2 onto the band now ─────────────
-- Without this the saving waits for each event's next read. Scoped to the watch and to rows
-- that are not already on the sold-out band, so a re-apply is a no-op.
UPDATE public.primary_poll_event t
   SET poll_interval  = (SELECT c.no_tickets_every FROM public.axs_watch_config c),
       cadence_pinned = true,
       next_poll_at   = now() + (SELECT c.no_tickets_every FROM public.axs_watch_config c)
                                * (0.75 + random() * 0.5)
 WHERE t.source = 'axs' AND t.watch
   AND t.poll_status = 'ok' AND t.poll_ok_at IS NOT NULL
   AND coalesce(t.listing_count, 0) = 0
   AND t.poll_interval IS DISTINCT FROM (SELECT c.no_tickets_every FROM public.axs_watch_config c);

COMMIT;
