-- Migration 20261127000000 · level:data-collection · lane:a1 (AXS watch budget + cadence + selection) · writes:axs_watch_config(+parked_daily_max,watch_until_days=NULL),axs_queue_claim()(patched),axs_watch_settle_one()(patched),primary_poll_listing(delete for thin events) · reads:axs_watch_poll,primary_poll_event
--
-- ============================================================================
-- Migration 20261127000000 — three operator answers in one change
--
-- Lane:     a1 (AXS watch)
-- pre:      20261126230000 (the thin rule, cadence_pinned, the parked discount).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes which of our own
-- reads are allowed, what we keep, and which events are eligible.
--
-- ── WHAT THE OPERATOR ASKED FOR, three of four answers ────────────────────
-- Operator 2026-11-26, answering the review:
--   A. "Reserved and ga"
--   B. "Park event uses credits outside the daily reserve, up to 50 polls daily."
--   C. "D3 stop sharing with API and delete last push."
--   D. "Remove beyond horrizon but by soonest event."
--
-- A NEEDED NO CHANGE and is recorded here so the decision is not re-litigated: thin is
-- measured on primary_poll_event.sellable_tickets, which is sum(quantity) over the stored
-- listings with ADA excluded — i.e. RESERVED + GA together, which is what A asks for. It was
-- already so in 20261126230000; the alternative reading, "under 20 reserved AND under 20 GA",
-- would make an event with 15 reserved plus 15 GA thin at 30 sellable tickets, and is not what
-- is built.
--
-- ── B. A PARKED EVENT'S READ IS OUTSIDE THE DAILY CAP ─────────────────────
-- A parked event (cadence_pinned, on a band of no_tickets_every or longer: thin or sold out)
-- is read once a day to notice inventory coming back. Those reads were competing for the daily
-- cap with events that have something to sell, which is backwards — the whole point of parking
-- is to stop spending the day's budget on them.
--
-- So in axs_queue_claim:
--   · today's parked reads are subtracted before the cap is tested, so a parked read does not
--     consume a place an active event could have used;
--   · a parked read is admitted past the cap entirely, while today's parked reads are under
--     parked_daily_max (50).
-- The credit is still CHARGED and still draws the monthly pool down — TicketsData bills it
-- either way, and td_charge_credit is untouched. What changes is only the gate.
--
-- 50 is ample: 20 events are parked today at one read each. It is a ceiling against a runaway,
-- not a target, and it binds at 50 parked events.
--
-- Counted from axs_watch_poll on the SAME Eastern-day boundary axs_watch_budget uses for
-- fired_today, so the subtraction is exact rather than two tables' estimates of one number.
-- ⚠ It reads each event's CURRENT parked state, so an event that parked or unparked part-way
-- through a day has that day's earlier reads counted on its present footing. Bounded by one
-- read a day per event and self-correcting at midnight; the alternative (the queue's stored
-- every_min) is per-read accurate but cannot be subtracted exactly from fired_today.
--
-- ⚠ NOT CHANGED: axs_watch_next, the due-list fallback, still counts parked reads against the
-- cap. It only runs while queue_enabled is false. Left alone deliberately rather than patched
-- twice and tested once.
--
-- ── C. THE LAST PUSH IS DELETED, NOT JUST HIDDEN ──────────────────────────
-- 20261126230000 stopped PUBLISHING a thin event by filtering the two views. The capture stayed
-- in primary_poll_listing, so a consumer that mirrors rows kept what it had. Parking an event
-- as thin now DELETES its listings and its split pieces and zeroes listing_count,
-- listed_quantity and median_price. sellable_tickets is deliberately kept: it is the measure
-- the rule and the views read, and it is what makes the withholding survive the delete.
--
-- Nothing is lost. A good read replaces the capture wholesale anyway (primary_poll_ingest), so
-- the first read finding real inventory republishes in full.
--
-- ⚠ A CONSEQUENCE WORTH SEEING BEFORE IT HAPPENS. With listing_count at 0, a thin event within
-- no_tickets_retire_days (7) now satisfies axs_watch_event_dead, so the next fill RETIRES it
-- instead of parking it, and a retired-as-dead event leaves the catalogue feed too
-- (20261126065000). One event qualifies today: "Jonathan Lee" at Yaamava' Theater, 2 days out
-- with 16 tickets. That reads as the right answer to "preemptive sold out" and "delete last
-- push" — nothing is published and nothing more is read — but it is a stronger action than
-- parking, so it is named here rather than discovered later.
--
-- ── D. THE HORIZON GOES; SOONEST FIRST DECIDES ────────────────────────────
-- watch_until_days (180) was both an add gate and a retire reason in axs_watch_fill. It is set
-- to NULL, which the function ALREADY treats as "no ceiling" in both places — the candidate
-- filter guards with `watch_until_days IS NULL OR`, and the retire arm with `IS NOT NULL AND`.
-- No code change, and reversible with one UPDATE.
--
-- Measured before applying:
--   110  export events beyond 180 days and inside catalogue_until_days become eligible
--     0  watched events are beyond 180 days, so nothing is retired by this
--   178  days out is the furthest watched event, so the list is pressed to the horizon
-- The list is full at its target, and the backfill takes candidates SOONEST FIRST, so those 110
-- do not displace anything today. What goes is the cliff: as December's events pass, the list
-- refills from the nearest events that exist rather than going short at a date boundary.
--
-- Checked rather than assumed: the eight venues carrying a quota are short 58 places, and it is
-- NOT the horizon doing it — they have zero eligible candidates at ANY date. So removing the
-- horizon cannot let a quota venue displace a backfilled event.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- UPDATE public.axs_watch_config SET watch_until_days = 180, parked_daily_max = 0;
-- (parked_daily_max 0 closes the exemption; the delete in C needs the settle re-applied from
--  20261126230000.)
-- ============================================================================

BEGIN;

-- ── B. the knob ───────────────────────────────────────────────────────────
ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS parked_daily_max integer NOT NULL DEFAULT 50
    CHECK (parked_daily_max >= 0 AND parked_daily_max <= 500);
COMMENT ON COLUMN public.axs_watch_config.parked_daily_max IS
  'How many reads of PARKED events (cadence_pinned and on a band of no_tickets_every or longer) axs_queue_claim admits in an Eastern day OUTSIDE the daily cap (mig 20261127000000, operator "Park event uses credits outside the daily reserve, up to 50 polls daily"). The credit is still charged and still draws the monthly pool; only the daily gate is bypassed. 0 closes the exemption.';

-- ── B. the claim: parked reads neither consume the cap nor are stopped by it
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_queue_claim';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_queue_claim not found'; END IF;
  IF v_src ~ 'v_parked_today' THEN RAISE EXCEPTION 'claim already exempts parked reads'; END IF;
  v_new := v_src;

  -- (a) the locals
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '  v_items jsonb := ''\[\]''::jsonb; q record; v_n integer := 0;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'claim DECLARE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    '  v_items jsonb := ''[]''::jsonb; q record; v_n integer := 0;',
    '  v_items jsonb := ''[]''::jsonb; q record; v_n integer := 0;'
    || E'\n  v_parked_min integer; v_parked_today integer := 0; v_parked_n integer := 0; v_fired_gate integer;');

  -- (b) count today's parked reads and take them out of the number the cap is tested against
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '  v_fired  := \(v_budget->>''fired_today''\)::integer;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'claim budget read: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    '  v_fired  := (v_budget->>''fired_today'')::integer;',
    E'  v_fired  := (v_budget->>''fired_today'')::integer;\n'
    || E'  -- A PARKED EVENT''S READ IS OUTSIDE THE DAILY CAP (mig 20261127000000). Counted from\n'
    || E'  -- axs_watch_poll on the same Eastern-day boundary axs_watch_budget uses for fired_today,\n'
    || E'  -- so the subtraction below is exact rather than two tables'' estimates of one number.\n'
    || E'  v_parked_min := greatest(extract(epoch FROM v_cfg.no_tickets_every)::integer / 60, 1);\n'
    || E'  SELECT count(*) INTO v_parked_today\n'
    || E'    FROM public.axs_watch_poll w\n'
    || E'    JOIN public.primary_poll_event e ON e.source = ''axs'' AND e.source_event_id = w.axs_event_id\n'
    || E'   WHERE w.fired_at >= date_trunc(''day'', now() AT TIME ZONE ''America/New_York'') AT TIME ZONE ''America/New_York''\n'
    || E'     AND coalesce(e.cadence_pinned, false) AND e.poll_interval >= v_cfg.no_tickets_every;\n'
    || E'  -- the cap is tested against the ACTIVE reads only; v_fired is left alone so the response\n'
    || E'  -- still reports the true figure rather than an adjusted one\n'
    || E'  v_fired_gate := greatest(v_fired - v_parked_today, 0);\n');

  -- (c) the gate itself
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '    IF v_fired \+ v_n >= v_cap THEN\n      CONTINUE WHEN q\.every_min IS NULL OR make_interval\(mins => q\.every_min\) > v_cfg\.hot_every;\n      CONTINUE WHEN v_fired \+ v_n >= v_cap \+ \(v_cap \* v_cfg\.hot_overrun_pct\) / 100;\n    END IF;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'claim cap gate: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'    IF v_fired + v_n >= v_cap THEN\n      CONTINUE WHEN q.every_min IS NULL OR make_interval(mins => q.every_min) > v_cfg.hot_every;\n      CONTINUE WHEN v_fired + v_n >= v_cap + (v_cap * v_cfg.hot_overrun_pct) / 100;\n    END IF;',
    E'    IF q.every_min IS NOT NULL AND q.every_min >= v_parked_min THEN\n'
    || E'      -- a parked event: outside the cap, bounded only by parked_daily_max for the day\n'
    || E'      CONTINUE WHEN v_parked_today + v_parked_n >= v_cfg.parked_daily_max;\n'
    || E'      v_parked_n := v_parked_n + 1;\n'
    || E'    ELSIF v_fired_gate + (v_n - v_parked_n) >= v_cap THEN\n'
    || E'      CONTINUE WHEN q.every_min IS NULL OR make_interval(mins => q.every_min) > v_cfg.hot_every;\n'
    || E'      CONTINUE WHEN v_fired_gate + (v_n - v_parked_n) >= v_cap + (v_cap * v_cfg.hot_overrun_pct) / 100;\n'
    || E'    END IF;');

  -- (d) say what the exemption did, so it can be watched
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '''daily_cap'', v_cap, ''fired_today'', v_fired,', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'claim return shape: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, '''daily_cap'', v_cap, ''fired_today'', v_fired,',
    E'''daily_cap'', v_cap, ''fired_today'', v_fired,\n'
    || E'                            ''parked_today'', v_parked_today + v_parked_n,\n'
    || E'                            ''parked_daily_max'', v_cfg.parked_daily_max,');

  IF v_new = v_src THEN RAISE EXCEPTION 'claim unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_queue_claim';
  IF v_src !~ 'v_parked_today \+ v_parked_n >= v_cfg\.parked_daily_max'
     OR v_src !~ 'v_fired_gate \+ \(v_n - v_parked_n\) >= v_cap'
     OR v_src !~ '''parked_today''' THEN
    RAISE EXCEPTION 'claim did not take the parked exemption';
  END IF;
END $surgery$;

-- ── C. parking as thin deletes the capture ────────────────────────────────
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_settle_one';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_settle_one not found'; END IF;
  IF v_src !~ 'v_thin' THEN RAISE EXCEPTION 'settle has no thin rule — is 20261126230000 applied?'; END IF;
  IF v_src ~ 'delete the last push' THEN RAISE EXCEPTION 'settle already deletes the capture'; END IF;

  -- the end of the slow branch's UPDATE is the anchor: the delete goes after it, inside the branch
  SELECT count(*) INTO v_hits FROM regexp_matches(v_src,
    '         SET poll_interval = v_slow, cadence_pinned = true,\n             next_poll_at = now\(\) \+ v_slow \* \(0\.75 \+ random\(\) \* 0\.5\)\n       WHERE e\.source = ''axs'' AND e\.source_event_id = p_event_id;\n    END IF;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'slow branch UPDATE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_src,
    E'         SET poll_interval = v_slow, cadence_pinned = true,\n             next_poll_at = now() + v_slow * (0.75 + random() * 0.5)\n       WHERE e.source = ''axs'' AND e.source_event_id = p_event_id;\n    END IF;',
    E'         SET poll_interval = v_slow, cadence_pinned = true,\n             next_poll_at = now() + v_slow * (0.75 + random() * 0.5)\n       WHERE e.source = ''axs'' AND e.source_event_id = p_event_id;\n'
    || E'      -- THIN: stop sharing with the API and delete the last push (mig 20261127000000,\n'
    || E'      -- operator "stop sharing with API and delete last push"). The views already withheld\n'
    || E'      -- it; the capture itself goes, so a consumer that mirrors rows does not keep what it\n'
    || E'      -- was last sent. sellable_tickets is KEPT on purpose: it is the measure the rule and\n'
    || E'      -- both views read, so the withholding survives its own delete. Nothing is lost — a\n'
    || E'      -- good read replaces the capture wholesale, so real inventory republishes in full.\n'
    || E'      IF v_thin THEN\n'
    || E'        DELETE FROM public.primary_poll_listing_piece pc\n'
    || E'         WHERE pc.source = ''axs'' AND pc.source_event_id = p_event_id;\n'
    || E'        DELETE FROM public.primary_poll_listing l\n'
    || E'         WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;\n'
    || E'        UPDATE public.primary_poll_event e\n'
    || E'           SET listing_count = 0, listed_quantity = 0, median_price = NULL\n'
    || E'         WHERE e.source = ''axs'' AND e.source_event_id = p_event_id;\n'
    || E'      END IF;\n'
    || E'    END IF;');

  IF v_new = v_src THEN RAISE EXCEPTION 'settle unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_settle_one';
  IF v_src !~ 'delete the last push' OR v_src !~ 'DELETE FROM public\.primary_poll_listing l'
     OR v_src !~ 'listing_count = 0, listed_quantity = 0, median_price = NULL' THEN
    RAISE EXCEPTION 'settle did not take the capture delete';
  END IF;
END $surgery$;

-- ── C. clear what the twelve already-parked events last pushed ────────────
DELETE FROM public.primary_poll_listing_piece pc
 USING public.primary_poll_event t, public.axs_watch_config c
 WHERE pc.source = 'axs' AND pc.source_event_id = t.source_event_id
   AND t.source = 'axs' AND t.watch AND t.poll_status = 'ok'
   AND NOT coalesce(t.ga_slow, false)
   AND c.thin_min_tickets > 0 AND t.sellable_tickets < c.thin_min_tickets;
DELETE FROM public.primary_poll_listing l
 USING public.primary_poll_event t, public.axs_watch_config c
 WHERE l.source = 'axs' AND l.source_event_id = t.source_event_id
   AND t.source = 'axs' AND t.watch AND t.poll_status = 'ok'
   AND NOT coalesce(t.ga_slow, false)
   AND c.thin_min_tickets > 0 AND t.sellable_tickets < c.thin_min_tickets;
UPDATE public.primary_poll_event t
   SET listing_count = 0, listed_quantity = 0, median_price = NULL
  FROM public.axs_watch_config c
 WHERE t.source = 'axs' AND t.watch AND t.poll_status = 'ok'
   AND NOT coalesce(t.ga_slow, false)
   AND c.thin_min_tickets > 0 AND t.sellable_tickets < c.thin_min_tickets
   AND (t.listing_count <> 0 OR t.listed_quantity <> 0 OR t.median_price IS NOT NULL);

-- ── D. the horizon goes; soonest first decides ────────────────────────────
UPDATE public.axs_watch_config SET watch_until_days = NULL WHERE watch_until_days IS NOT NULL;

COMMIT;
