-- Migration 20261126230000 · level:data-collection · lane:a1 (AXS watch cadence + the feed) · writes:axs_watch_config(+thin_min_tickets),primary_poll_event(+sellable_tickets),axs_watch_settle_one()(patched),axs_watch_fill()(patched),v_primary_poll_events_feed(patched),v_primary_poll_listings_feed(patched),primary_poll_event(backfill) · reads:primary_poll_listing
--
-- ============================================================================
-- Migration 20261126230000 — an event with almost nothing to sell is read once a day,
--                            is not published, and gives its place to another event
--
-- Lane:     a1 (AXS watch cadence + the two feed views)
-- pre:      20261126070000 (no_tickets_every), 20261126150000 (cadence_pinned),
--           20261126213000 (the band-relative freshness window),
--           20261126214500 (the empty read taking the sold-out band).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- ── WHAT THE OPERATOR ASKED FOR ───────────────────────────────────────────
-- Operator 2026-11-26, in two messages and then reaffirmed:
--   "if event has under 20 reserved tickets for sale put into 24 hour watch list and
--    replace with new event"
--   "Treat under 20 reserved tickets as preemptive sold out but stop sharing with api"
--
-- ── "RESERVED TICKETS": WHAT IS MEASURED, AND WHY NOT THE LITERAL READING ──
-- thin_min_tickets (20) is compared against SELLABLE tickets with ADA excluded, not against
-- non-GA tickets. The literal reading cannot be used, and this is not a quibble: a GA-only
-- show has ZERO reserved tickets BY DEFINITION, so "under 20 reserved" is true of every one
-- of them. Measured on the live watch before applying, the literal rule matched 18 events and
-- six of them were our largest inventory —
--     Nora En Pure  5,611 GA    SIDEPIECE  3,208    A Boogie    1,945
--     The Escapement  630 GA    Cloonee      593    CupcakKe      441
-- 12,428 tickets that would have been parked at a day and dropped from the feed. Sellable-
-- excluding-ADA matches exactly the 12 events that have almost nothing to sell however it is
-- categorised, and leaves deep GA to its own ladder (ga_slow_every / ga_slow2_every).
--
-- For every event that HAS reserved inventory the two readings agree, which is why this is a
-- safe reading of the ask rather than a different rule. ADA is excluded because the feed
-- withholds it anyway (send_ada false), so an ADA-only event has nothing to sell.
--
-- TO GET THE LITERAL READING BACK, one UPDATE: there is no second code path. Set
-- thin_min_tickets to 0 to switch the rule off entirely.
--
-- ── THE THREE THINGS IT DOES ──────────────────────────────────────────────
-- 1. THE BAND. A good read that finds fewer than thin_min_tickets sellable tickets takes
--    no_tickets_every (1 day) and cadence_pinned, exactly as a sold-out read does
--    (20261126214500). It unpins itself: the band UPDATE above that branch sets
--    cadence_pinned from the GA rule, so the first read that finds real inventory restores
--    the proximity band within a day.
-- 2. NOT PUBLISHED. Both feeds withhold a thin event, and the events feed says why:
--    listings_withheld = 'thin_inventory'. This is the operator's "preemptive sold out but
--    stop sharing with api", and it has a cost worth naming: the UFC BJJ event's 8 tickets at
--    $77 all-in and Jonathan Lee's 16 stop reaching the API. Sellable inventory goes dark by
--    choice, not by accident.
-- 3. THE PLACE GOES BACK. axs_watch_fill stops counting a parked event against
--    target_events, so the backfill hands the freed place to another eligible event. A parked
--    event is one that is watched AND cadence_pinned AND on a band of no_tickets_every or
--    longer — so the 24-hour list (thin and sold out), NOT the 6-hour not-on-sale pin.
--
-- ⚠ THE WATCHED COUNT NOW READS ABOVE target_events. 341 active plus however many are
-- parked. That is the point of the ask — the parked ones cost about 1 read a day each
-- instead of 24 — but anything that flags "watched > target_events" is now wrong, including
-- the hourly monitor's item 5. axs_watch_fill returns a 'parked' key so the two can be told
-- apart. Not capped: each parked event costs ~1 credit/day, so even fifty would be ~50/day.
--
-- ── WHAT IT COSTS AND SAVES, MEASURED BEFORE APPLYING ─────────────────────
-- 12 of 333 read-ok watched events are thin. Four are already at a day (the sold-out rule
-- this morning), so EIGHT move: 8 x 23 reads/day = about 184 credits/day freed, and the same
-- again spent on the eight events the backfill puts in their place. Roughly neutral on
-- credits, and it buys eight events with inventory instead of eight without.
--     0 tickets   Toy Factory Project (Ryman) · BNP Paribas Open Q1/Q2/Q3 (Indian Wells)
--     1, 5        Amy Grant & Vince Gill x2 (Ryman)
--     8           UFC BJJ 14 (Meta APEX) · Kai Wachi (Red Rocks)
--     9, 9        NCAA DI W Bball Las Vegas Region x2 (T-Mobile Arena)
--     12          Ian Asher (Terminal 5)
--     16          Jonathan Lee (Yaamava')
--
-- ⚠ KNOWN, NOT FIXED HERE: axs_watch_cadence_demand() recomputes each event's cadence from
-- its band rather than reading poll_interval, so it will keep counting these twelve at their
-- proximity band and will NOT show the saving. Same gap 20261126070000 and 20261126214500
-- recorded, same reason for leaving it.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- UPDATE public.axs_watch_config SET thin_min_tickets = 0;   -- the rule off, nothing else to undo
-- ============================================================================

BEGIN;

-- ── 1. the knob and the stored measure ────────────────────────────────────
ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS thin_min_tickets integer NOT NULL DEFAULT 20
    CHECK (thin_min_tickets >= 0 AND thin_min_tickets <= 500);
COMMENT ON COLUMN public.axs_watch_config.thin_min_tickets IS
  'Fewer than this many SELLABLE tickets (ADA excluded) on a good read makes the event thin: it takes no_tickets_every, is withheld from both feeds, and gives its place back to the fill (mig 20261126230000). 0 switches the rule off. Compared against sellable rather than non-GA tickets because a GA-only show has zero reserved tickets by definition — the literal reading would park 12,428 GA tickets.';

ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS sellable_tickets integer;
COMMENT ON COLUMN public.primary_poll_event.sellable_tickets IS
  'Tickets the last good read found that we could sell: sum(quantity) over the stored listings with ADA excluded (mig 20261126230000). Written by axs_watch_settle_one beside ga_tickets. Stored rather than re-aggregated so the two feed views can read it per row without touching primary_poll_listing. NULL means not measured yet, and is treated as NOT thin so a missing measure never darkens inventory.';

-- ── 2. the settle: measure it, and park a thin event on the sold-out band ─
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_settle_one';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_settle_one not found'; END IF;
  IF v_src ~ 'v_thin' THEN RAISE EXCEPTION 'settle already carries the thin rule'; END IF;
  v_new := v_src;

  -- (a) two locals
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '  v_ga_slow boolean := false; v_slow interval; v_ga_tickets integer;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle DECLARE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    '  v_ga_slow boolean := false; v_slow interval; v_ga_tickets integer;',
    '  v_ga_slow boolean := false; v_slow interval; v_ga_tickets integer;'
    || E'\n  v_sellable integer; v_thin boolean := false;');

  -- (b) the measure, from the same capture the GA aggregate reads, and the verdict.
  --     ADA is excluded because the feed withholds it: an ADA-only event has nothing to sell.
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '      INTO v_ga_tickets\n      FROM public\.primary_poll_listing l\n     WHERE l\.source = ''axs'' AND l\.source_event_id = p_event_id;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ga_tickets SELECT: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'      INTO v_ga_tickets\n      FROM public.primary_poll_listing l\n     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;',
    E'      INTO v_ga_tickets\n      FROM public.primary_poll_listing l\n     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;\n'
    || E'    -- what we could actually sell, however it is categorised (mig 20261126230000). ADA is\n'
    || E'    -- left out because the feed withholds it anyway, so it is not inventory to us.\n'
    || E'    SELECT coalesce(sum(l.quantity) FILTER (WHERE NOT coalesce(l.ada, false)), 0)\n'
    || E'      INTO v_sellable\n'
    || E'      FROM public.primary_poll_listing l\n'
    || E'     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;\n'
    || E'    -- only a GOOD read may park an event: on a failed read v_sellable describes the capture\n'
    || E'    -- we are keeping, not what AXS just said, and parking on it would be acting on stale data.\n'
    || E'    v_thin := v_outcome IN (''ok'', ''empty'') AND v_cfg.thin_min_tickets > 0\n'
    || E'              AND coalesce(v_sellable, v_cfg.thin_min_tickets) < v_cfg.thin_min_tickets\n'
    || E'              AND NOT v_ga_slow;   -- deep GA has its own ladder and can never be thin anyway\n');

  -- (c) the band UPDATE stores the measure
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new, '           ga_tickets    = v_ga_tickets,', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'band UPDATE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, '           ga_tickets    = v_ga_tickets,',
                          E'           ga_tickets    = v_ga_tickets,\n           sellable_tickets = v_sellable,');

  -- (d) a thin read joins the sold-out branch, and picks the one-day band there
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new, 'IF v_outcome = ''empty'' OR \(v_outcome = ''unparsed''', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'slow branch head: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, 'IF v_outcome = ''empty'' OR (v_outcome = ''unparsed''',
                          'IF v_thin OR v_outcome = ''empty'' OR (v_outcome = ''unparsed''');
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'v_slow := CASE WHEN v_outcome = ''empty'' OR v_error ~\* ''no tickets are currently available''', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'slow CASE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'v_slow := CASE WHEN v_outcome = ''empty'' OR v_error ~* ''no tickets are currently available''',
    'v_slow := CASE WHEN v_thin OR v_outcome = ''empty'' OR v_error ~* ''no tickets are currently available''');

  IF v_new = v_src THEN RAISE EXCEPTION 'settle unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_settle_one';
  IF v_src !~ 'sellable_tickets = v_sellable'
     OR v_src !~ 'IF v_thin OR v_outcome = ''empty'''
     OR v_src !~ 'CASE WHEN v_thin OR v_outcome = ''empty''' THEN
    RAISE EXCEPTION 'settle did not take the thin rule';
  END IF;
END $surgery$;

-- ── 3. the fill: a parked event does not hold a place ─────────────────────
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_fill';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_fill not found'; END IF;
  IF v_src ~ 'v_parked' THEN RAISE EXCEPTION 'fill already discounts parked events'; END IF;
  v_new := v_src;

  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '  v_kept integer; v_borrowed integer; v_returned integer := 0; v_backfilled integer := 0;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'fill DECLARE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    '  v_kept integer; v_borrowed integer; v_returned integer := 0; v_backfilled integer := 0;',
    '  v_kept integer; v_borrowed integer; v_returned integer := 0; v_backfilled integer := 0;'
    || E'\n  v_parked integer := 0;');

  -- count the parked ones right after the kept ones are counted
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '  SELECT count\(\*\), count\(\*\) FILTER \(WHERE k\.borrowed\) INTO v_kept, v_borrowed FROM _aw_keep k;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'kept count: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    '  SELECT count(*), count(*) FILTER (WHERE k.borrowed) INTO v_kept, v_borrowed FROM _aw_keep k;',
    E'  SELECT count(*), count(*) FILTER (WHERE k.borrowed) INTO v_kept, v_borrowed FROM _aw_keep k;\n'
    || E'  -- A PARKED EVENT DOES NOT HOLD A PLACE (mig 20261126230000, operator "replace with new\n'
    || E'  -- event"). Parked means deliberately on the 24-hour list and pinned there: thin inventory\n'
    || E'  -- or sold out. The 6-hour not-on-sale pin is NOT parked — that event is waiting for an\n'
    || E'  -- on-sale moment that can arrive at any hour, so it is still being watched properly.\n'
    || E'  SELECT count(*) INTO v_parked\n'
    || E'    FROM _aw_keep k JOIN public.primary_poll_event t\n'
    || E'      ON t.source = ''axs'' AND t.source_event_id = k.source_event_id\n'
    || E'   WHERE coalesce(t.cadence_pinned, false) AND t.poll_interval >= v_cfg.no_tickets_every;\n');

  -- the three places the list's occupancy is measured
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'v_room := v_cfg\.target_events - \(v_kept - v_borrowed\) - v_total_added;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'room (quota pass): expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, 'v_room := v_cfg.target_events - (v_kept - v_borrowed) - v_total_added;',
                          'v_room := v_cfg.target_events - (v_kept - v_parked - v_borrowed) - v_total_added;');

  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'greatest\(v_kept \+ v_total_added - v_cfg\.target_events, 0\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'returned: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, 'greatest(v_kept + v_total_added - v_cfg.target_events, 0)',
                          'greatest(v_kept - v_parked + v_total_added - v_cfg.target_events, 0)');

  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'v_room := v_cfg\.target_events - \(v_kept - v_returned\) - v_total_added;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'room (backfill): expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, 'v_room := v_cfg.target_events - (v_kept - v_returned) - v_total_added;',
                          'v_room := v_cfg.target_events - (v_kept - v_parked - v_returned) - v_total_added;');

  -- and say how many are parked, so "watched above target_events" can be read correctly
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new, '''backfilled'', nullif\(v_backfilled, 0\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'return shape: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new, '''backfilled'', nullif(v_backfilled, 0)',
                          '''backfilled'', nullif(v_backfilled, 0), ''parked'', v_parked');

  IF v_new = v_src THEN RAISE EXCEPTION 'fill unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_fill';
  IF v_src !~ 'v_kept - v_parked - v_borrowed' OR v_src !~ 'v_kept - v_parked - v_returned'
     OR v_src !~ '''parked'', v_parked' THEN
    RAISE EXCEPTION 'fill did not take the parked discount';
  END IF;
END $surgery$;

-- ── 4. the two feeds withhold a thin event ────────────────────────────────
-- The thin test goes immediately before the freshness arm 20261126213000 installed, in BOTH
-- views, so the two feeds cannot disagree about one event. It names its own alias for the
-- config row rather than borrowing the view's, so there is no backreference to get wrong, and
-- the subquery stays UNCORRELATED — one InitPlan for the scan, not a lookup per row.
DO $surgery$
DECLARE
  v_view text; v_src text; v_new text; v_opts text[]; v_cols text;
  v_after text; v_cols2 text; v_opts2 text; v_hits integer;
  c_anchor text := 'now() < GREATEST(t.poll_ok_at';
  -- NULL means not measured yet and must NOT withhold: a missing measure never darkens inventory
  c_test text := 'COALESCE(t.sellable_tickets, (SELECT tc.thin_min_tickets FROM axs_watch_config tc))'
              || ' >= (SELECT tc.thin_min_tickets FROM axs_watch_config tc) AND ';
BEGIN
  FOREACH v_view IN ARRAY ARRAY['v_primary_poll_events_feed', 'v_primary_poll_listings_feed'] LOOP
    SELECT pg_get_viewdef(c.oid, true), c.reloptions,
           (SELECT string_agg(a.attname || ':' || a.atttypid::regtype::text, ',' ORDER BY a.attnum)
              FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped)
      INTO v_src, v_opts, v_cols
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = v_view AND c.relkind = 'v';
    IF v_src IS NULL THEN RAISE EXCEPTION 'view public.% not found', v_view; END IF;
    IF v_src ~ 'sellable_tickets' THEN RAISE EXCEPTION '%: already carries the thin test', v_view; END IF;
    -- the band-relative window must already be there: this change sits on top of it
    IF v_src !~ 'COALESCE\(t\.poll_interval' THEN
      RAISE EXCEPTION '%: no band-relative freshness arm — is 20261126213000 applied?', v_view;
    END IF;

    v_hits := (length(v_src) - length(replace(v_src, c_anchor, ''))) / length(c_anchor);
    IF v_hits <> 1 THEN RAISE EXCEPTION '%: expected 1 freshness arm, found %', v_view, v_hits; END IF;
    v_new := replace(v_src, c_anchor, c_test || c_anchor);

    EXECUTE format('CREATE OR REPLACE VIEW public.%I %s AS %s', v_view,
                   CASE WHEN v_opts IS NULL THEN ''
                        ELSE 'WITH (' || array_to_string(v_opts, ', ') || ')' END, v_new);

    SELECT pg_get_viewdef(c.oid, true),
           (SELECT string_agg(a.attname || ':' || a.atttypid::regtype::text, ',' ORDER BY a.attnum)
              FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
           coalesce(array_to_string(c.reloptions, ','), '')
      INTO v_after, v_cols2, v_opts2
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = v_view;
    IF v_cols2 IS DISTINCT FROM v_cols THEN RAISE EXCEPTION '%: columns changed', v_view; END IF;
    IF v_opts2 IS DISTINCT FROM coalesce(array_to_string(v_opts, ','), '') THEN
      RAISE EXCEPTION '%: reloptions changed', v_view;
    END IF;
    IF v_after !~ 'thin_min_tickets' OR v_after !~ 'COALESCE\(t\.poll_interval' THEN
      RAISE EXCEPTION '%: did not take the thin test, or lost the freshness arm', v_view;
    END IF;
  END LOOP;
END $surgery$;

-- the events feed says WHY, rather than calling a thin event stale
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer; v_opts text[];
  c_else text := 'ELSE ''poll_stale''::text';
BEGIN
  SELECT pg_get_viewdef(c.oid, true), c.reloptions INTO v_src, v_opts
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'v_primary_poll_events_feed';
  IF v_src ~ 'thin_inventory' THEN RAISE EXCEPTION 'events feed already names thin_inventory'; END IF;
  v_hits := (length(v_src) - length(replace(v_src, c_else, ''))) / length(c_else);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'withheld CASE: expected 1 site, found %', v_hits; END IF;
  -- after poll_failed and not_polled, so a thin event that is ALSO failed or unread says that first
  v_new := replace(v_src, c_else,
    'WHEN COALESCE(t.sellable_tickets, (SELECT tc.thin_min_tickets FROM axs_watch_config tc))'
    || ' < (SELECT tc.thin_min_tickets FROM axs_watch_config tc) THEN ''thin_inventory''::text '
    || c_else);
  EXECUTE format('CREATE OR REPLACE VIEW public.v_primary_poll_events_feed %s AS %s',
                 CASE WHEN v_opts IS NULL THEN '' ELSE 'WITH (' || array_to_string(v_opts, ', ') || ')' END, v_new);
  SELECT pg_get_viewdef(c.oid, true) INTO v_src FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'v_primary_poll_events_feed';
  IF v_src !~ 'thin_inventory' THEN RAISE EXCEPTION 'events feed did not take the thin_inventory reason'; END IF;
END $surgery$;
COMMENT ON VIEW public.v_primary_poll_events_feed IS
  'GET /primary/events. listings_withheld says why an event''s listings are not published: not_polled (catalogue-only, never read), poll_failed, poll_stale (the read is older than the event''s band plus grace, mig 20261126213000), or thin_inventory (fewer than axs_watch_config.thin_min_tickets sellable tickets — preemptive sold out, mig 20261126230000).';

-- ── 5. measure the events already read, so the rule bites now ─────────────
UPDATE public.primary_poll_event t
   SET sellable_tickets = agg.sellable
  FROM (SELECT l.source_event_id,
               coalesce(sum(l.quantity) FILTER (WHERE NOT coalesce(l.ada, false)), 0) AS sellable
          FROM public.primary_poll_listing l WHERE l.source = 'axs'
         GROUP BY l.source_event_id) agg
 WHERE t.source = 'axs' AND t.source_event_id = agg.source_event_id
   AND t.sellable_tickets IS DISTINCT FROM agg.sellable;
-- an ok event with no stored listings at all has nothing to sell, and the join above cannot see it
UPDATE public.primary_poll_event t
   SET sellable_tickets = 0
 WHERE t.source = 'axs' AND t.poll_status = 'ok' AND t.sellable_tickets IS NULL;

UPDATE public.primary_poll_event t
   SET poll_interval  = (SELECT c.no_tickets_every FROM public.axs_watch_config c),
       cadence_pinned = true,
       next_poll_at   = now() + (SELECT c.no_tickets_every FROM public.axs_watch_config c)
                                * (0.75 + random() * 0.5)
 WHERE t.source = 'axs' AND t.watch AND t.poll_status = 'ok'
   AND NOT coalesce(t.ga_slow, false)
   AND t.sellable_tickets < (SELECT c.thin_min_tickets FROM public.axs_watch_config c)
   AND t.poll_interval IS DISTINCT FROM (SELECT c.no_tickets_every FROM public.axs_watch_config c);

COMMIT;
