-- Migration 20261126044500 · level:data-collection · lane:a1 (AXS watch list) · writes:axs_watch_venue(+keep_all,quota,rows),axs_watch_rule_ok()(3-arg overload new; 2-arg delegates),axs_watch_fill()(replaced),axs_watch_config(target_events) · reads:axs_export_event,primary_poll_event
--
-- ============================================================================
-- Migration 20261126044500 — a venue can be watched WHOLE, not by title
--
-- Lane:     a1 (AXS watch list)
-- Touches:  axs_watch_venue (+keep_all, quotas raised, two new rows),
--           axs_watch_rule_ok() (NEW 3-arg overload; the 2-arg form delegates and keeps
--           its exact meaning), axs_watch_fill() (REPLACED in place — five gate predicates
--           thread the venue through), axs_watch_config (target_events 305 -> 230).
-- pre:      20261125232000 (keep_regex + the fill this replaces), 20261126011500 (bands).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes which events the
-- existing reader is told to read. No price, hold or order path is touched.
--
-- ── WHAT THE OPERATOR ASKED FOR ───────────────────────────────────────────
-- Operator 2026-11-26, in four messages: "check crypto, toyota center and t-mobile arena
-- for other events that have axs as primary, then give me new count" -> "add those event
-- and monitor for issues, also add axs events at Meta Apex" -> "add Red Rocks, Indian
-- Wells, Greek Theatre, MGM Grand Garden" -> "add both fc dallas and la galaxy venues on
-- events axs is primary".
--
-- That is a venue instruction, not a title instruction. 20261125232000 made the gate a
-- title regex on purpose — three teams, self-maintaining as the schedule extends — and
-- its own header says why a venue list was wrong THEN: the three arenas carried 51
-- concerts and ice shows a venue filter would have kept. The operator now wants exactly
-- those 51. So the gate gains a venue dimension rather than losing the title one:
-- keep_regex still governs every venue that is not flagged, and a flagged venue is
-- watched whole.
--
-- A title list would have been the wrong shape for a second reason: it goes stale the
-- moment AXS books the next concert. keep_all needs no edit when Red Rocks announces its
-- summer season — the events join at the 03:20Z fill.
--
-- ── WHAT keep_all LIFTS, AND WHAT IT NEVER LIFTS ──────────────────────────
-- Lifts  keep_regex        (the three-team restriction)
-- Lifts  sports_keep_regex (the sports allow-list)
-- KEEPS  exclude_regex     (parking, suites, packages, passes, season tickets, memberships,
--                           deposits, and the operator's own named exclusions)
--
-- The sports allow-list has to go with it, measured and not assumed: at Dignity Health
-- Sports Park all 8 AXS-ticketed events are MLS or USWNT, and sports_keep_regex carries
-- no MLS token, so keep_all alone would have admitted nothing and the operator's fourth
-- message would have been silently ignored. Lifting it also recovers 8 events already
-- being dropped at venues on the list: the 2027 NCAA Men's West Regional at Crypto (2),
-- the NCAA Division I women's Sweet 16 and Elite 8 at T-Mobile (4), the MGM Slam, and a
-- PWHL takeover. Those are arena-scale sales, not noise.
--
-- exclude_regex stays absolute because its tokens are not events: parking, a suite, a
-- season pass. The operator's named exclusions ride in it too — Lakers home games (31 at
-- Crypto), the Vegas Vanguards (14 at T-Mobile), Globetrotters, Hoopfest, Unrivaled and
-- Olivia Rodrigo all stay out, flag or no flag. ⚠ One of those tokens costs a game the
-- watch wants: 'timberwolves' excludes "Houston Rockets vs. Minnesota Timberwolves", a
-- Rockets HOME date at Toyota Center, because the token was written to keep the
-- Timberwolves' own venue feed out. Left as it is here — narrowing an operator exclusion
-- is their call, not this migration's.
--
-- ── FC DALLAS: THE EXPORT IS WRONG, NOT AXS ──────────────────────────────
-- Toyota Stadium (124913, Frisco TX) lists 7 FC Dallas home dates and every one carries
-- type = 'other_ticketer', axs_ticketed = false, ticketer = NULL. On that alone the
-- answer would be "AXS is not the primary, nothing to add". It is not the answer:
--   · every one of those rows' event_url is an axs.com event page (/events/1695057/...),
--   · the operator supplied AXS's own primary shop for the club (tix.axs.com/<token>/shop/search),
--   · all 7 are status 'Coming Soon' with onsale_utc NULL — the 2027 season has no on-sale
--     date yet, so AXS has published no ticketing metadata for the feed to read,
--   · and 478 live rows sit in exactly this other_ticketer-with-NULL-ticketer state, which
--     is the discovery feed defaulting "ticketer unknown" to "not ours".
-- For contrast, LA Galaxy at Dignity Health Sports Park is status 'Buy Tickets' and reads
-- axs_primary / axs_ticketed = true / ticketer 'axs' — the same club tier, on sale, so the
-- metadata is there. The difference is the on-sale date, not the ticketer.
--
-- Hence the second flag, trust_axs_sold, set for this one venue: the watch believes the
-- venue over the export's axs_ticketed. It is deliberately narrow — a per-venue opt-in with
-- its evidence in the row's note, not a change to how the export classifies 128k rows, which
-- is A1 ingest work and a separate task. It costs nothing today either way: all 7 dates are
-- held out by the on-sale rule until AXS publishes a date, and then they join on their own.
--
-- Greek Theatre is a third shape: 8 AXS-ticketed events, all beyond watch_until_days (180).
-- Its season arrives inside the horizon in spring, with no further change.
--
-- ── SIZE AND COST (measured on prod 2026-11-26 03:5xZ, not estimated) ─────
-- watched           88  ->  ~212     (of which 88 are the three teams)
-- reads/hour      89.7  ->  ~196     against 274 usable at the measured 8.0 s a read
-- credits/day    2,152  ->  ~6,000   against a 10,696 daily cap, 240k left in the cycle
--
-- target_events comes DOWN, 305 -> 230. It is the list's hard ceiling (the fill's
-- v_room), and 305 was set when the list was 305 title-matched events. The quotas below
-- sum past 230 on purpose: that is what the borrow-and-return machinery is for, and it
-- means Red Rocks' summer season cannot quietly walk the list to 300 events and 290
-- reads an hour. 230 holds ~216 reads/hour, 79% of throughput. Raising it is a separate
-- operator call and should wait for the queue to be live (20261126030000, still dark) or
-- for TicketsData to raise concurrency past the 3-second floor.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- UPDATE public.axs_watch_venue SET keep_all = false, trust_axs_sold = false;  -- the three teams
-- UPDATE public.axs_watch_config SET target_events = 305;
-- The next fill retires what the flag admitted, via the 'not_kept' arm.
-- ============================================================================

BEGIN;

-- ── 1. the flag ───────────────────────────────────────────────────────────
ALTER TABLE public.axs_watch_venue ADD COLUMN IF NOT EXISTS keep_all boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.axs_watch_venue.keep_all IS
  'true = every event AXS sells at this venue is watched: keep_regex and sports_keep_regex do not apply (mig 20261126044500). exclude_regex still does. false = the config regexes govern, as before.';

ALTER TABLE public.axs_watch_venue ADD COLUMN IF NOT EXISTS trust_axs_sold boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.axs_watch_venue.trust_axs_sold IS
  'true = watch this venue''s events even where the export says axs_ticketed = false (mig 20261126044500). For a venue we KNOW sells on AXS while TicketsData''s discovery feed has not said so yet. Set per venue, with the evidence in note. Everything else still gates: exclude_regex, the horizon, the 6h stop, and the on-sale rules.';

-- ── 2. the gate gains a venue ─────────────────────────────────────────────
-- The 3-arg form is a NEW overload, not a replacement, and takes no default: a 2-arg call
-- still resolves to the 2-arg function with no ambiguity, which is what the harness
-- scenarios s01/s11 and any caller outside this file rely on.
CREATE OR REPLACE FUNCTION public.axs_watch_rule_ok(p_category text, p_title text, p_venue_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(p_title, '') <> ''
     -- absolute, whatever the venue: these tokens are not events
     AND p_title !~* (SELECT c.exclude_regex FROM public.axs_watch_config c)
     AND (coalesce((SELECT wv.keep_all FROM public.axs_watch_venue wv
                     WHERE wv.axs_venue_id = p_venue_id AND wv.enabled), false)
          OR ((coalesce(p_category, '') <> 'Sports'
               OR p_title ~* (SELECT c.sports_keep_regex FROM public.axs_watch_config c))
              AND coalesce(p_title ~* (SELECT c.keep_regex FROM public.axs_watch_config c), true)))
$function$;

-- the 2-arg form keeps its exact meaning, in one place: no venue = no flag = the regexes govern
CREATE OR REPLACE FUNCTION public.axs_watch_rule_ok(p_category text, p_title text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.axs_watch_rule_ok(p_category, p_title, NULL::bigint)
$function$;

-- ── 3. the fill asks the gate about the venue ─────────────────────────────
-- The fill's BODY does not change: three keep-rule predicates and two axs_ticketed
-- predicates are threaded the venue, and the retire set gains the join that lets it see
-- the venue's row. Rather than restate 13.5k characters of unchanged plpgsql — where a
-- single transcription slip between this file and prod would be invisible — the five
-- sites are rewritten in place, each guarded by an exact site count that RAISEs if the
-- function is not the shape this migration was written against, and the result is read
-- back and checked before the transaction is allowed to commit. It cannot silently
-- no-op, and prod and this file cannot diverge.
--
--   retire CASE arm      rule_ok(cat, title)            -> rule_ok(cat, title, e.venue_id)
--   retire WHERE arm     rule_ok(cat, title)            -> rule_ok(cat, title, e.venue_id)
--   candidate predicate  rule_ok(cat, title)            -> rule_ok(cat, title, e.venue_id)
--   retire CASE + WHERE  coalesce(e.axs_ticketed,false) -> ... OR wvr.trust_axs_sold
--   candidate predicate  coalesce(e.axs_ticketed,false) -> ... OR wv.trust_axs_sold

DO $surgery$
DECLARE
  v_src text;
  v_new text;
  v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_fill'
     AND pg_get_function_identity_arguments(p.oid) = 'p_apply boolean';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'axs_watch_fill(boolean) not found — nothing to thread the venue through';
  END IF;
  v_new := v_src;

  -- (1) the retire set must be able to see the venue's row
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'LEFT JOIN public\.axs_export_event e ON e\.axs_event_id::text = t\.source_event_id', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'retire join: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'LEFT JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id',
    'LEFT JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id'
    || E'\n    LEFT JOIN public.axs_watch_venue wvr ON wvr.axs_venue_id = e.venue_id AND wvr.enabled');

  -- (2) the three keep-rule gates ask about the venue
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'public\.axs_watch_rule_ok\(e\.major_category, coalesce\(e\.event_title, t\.name\)\)', 'g');
  IF v_hits <> 2 THEN RAISE EXCEPTION 'rule_ok retire gates: expected 2 sites, found %', v_hits; END IF;
  v_new := replace(v_new,
    'public.axs_watch_rule_ok(e.major_category, coalesce(e.event_title, t.name))',
    'public.axs_watch_rule_ok(e.major_category, coalesce(e.event_title, t.name), e.venue_id)');

  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'public\.axs_watch_rule_ok\(e\.major_category, e\.event_title\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'rule_ok candidate gate: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'public.axs_watch_rule_ok(e.major_category, e.event_title)',
    'public.axs_watch_rule_ok(e.major_category, e.event_title, e.venue_id)');

  -- (3) the two axs_ticketed gates honour trust_axs_sold
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'WHEN NOT coalesce\(e\.axs_ticketed, false\) THEN ''not_axs_sold''', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'not_axs_sold arm: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'WHEN NOT coalesce(e.axs_ticketed, false) THEN ''not_axs_sold''',
    'WHEN NOT (coalesce(e.axs_ticketed, false) OR coalesce(wvr.trust_axs_sold, false)) THEN ''not_axs_sold''');

  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'OR NOT coalesce\(e\.axs_ticketed, false\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'retire axs_ticketed gate: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'OR NOT coalesce(e.axs_ticketed, false)',
    'OR NOT (coalesce(e.axs_ticketed, false) OR coalesce(wvr.trust_axs_sold, false))');

  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'AND coalesce\(e\.axs_ticketed, false\)\n', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'candidate axs_ticketed gate: expected 1 site, found %', v_hits; END IF;
  v_new := regexp_replace(v_new,
    'AND coalesce\(e\.axs_ticketed, false\)\n',
    E'AND (coalesce(e.axs_ticketed, false) OR wv.trust_axs_sold)\n');

  IF v_new = v_src THEN RAISE EXCEPTION 'axs_watch_fill unchanged — surgery did nothing'; END IF;
  EXECUTE v_new;

  -- and prove it took, rather than trusting that it did
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_fill'
     AND pg_get_function_identity_arguments(p.oid) = 'p_apply boolean';
  IF v_src !~ 'rule_ok\(e\.major_category, e\.event_title, e\.venue_id\)'
     OR v_src !~ 'wvr\.trust_axs_sold'
     OR v_src !~ 'OR wv\.trust_axs_sold' THEN
    RAISE EXCEPTION 'axs_watch_fill did not come back with the venue threaded through';
  END IF;
END $surgery$;
-- ── 4. the venues the operator named ──────────────────────────────────────
-- the two that had no row yet
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by, set_at)
VALUES (100988, 'Dignity Health Sports Park', 14, true, true,
        'operator 2026-11-26: LA Galaxy, whole venue. 8 AXS-ticketed (7 Galaxy home + USWNT v Panama), all of them blocked by sports_keep_regex before keep_all.', 'operator', now()),
       (124913, 'Toyota Stadium', 10, true, true,
        'operator 2026-11-26: FC Dallas, whole venue, trust_axs_sold. The export marks all 7 home dates other_ticketer/axs_ticketed=false with ticketer NULL, but their event_url is an axs.com event page and the operator supplied the AXS primary shop for FC Dallas (tix.axs.com/.../shop/search). The feed defaults an unknown ticketer to other_ticketer; 478 live rows are in that state. All 7 are still held by the on-sale rule until AXS publishes a date.', 'operator', now())
ON CONFLICT (axs_venue_id) DO UPDATE
   SET venue_name = excluded.venue_name, quota = excluded.quota, enabled = true,
       keep_all = true, note = excluded.note, set_by = 'operator', set_at = now();

UPDATE public.axs_watch_venue SET trust_axs_sold = true WHERE axs_venue_id = 124913;

-- the six already enabled: flag on, quota raised to the measured count plus headroom
UPDATE public.axs_watch_venue wv
   SET keep_all = true, quota = v.quota, set_by = 'operator', set_at = now(),
       note = v.note
  FROM (VALUES
        (101242::bigint, 60, 'operator 2026-11-26: whole venue. 54 eligible (31 Kings + 23 other, incl. the 2027 NCAA West Regional). Lakers stay out on exclude_regex.'),
        (101329,         54, 'operator 2026-11-26: whole venue. 49 eligible (29 Rockets + 20 other).'),
        (101949,         42, 'operator 2026-11-26: whole venue. 37 eligible (28 Golden Knights + 9 other, incl. NCAA women''s Sweet 16 + Elite 8). Vanguards stay out on exclude_regex.'),
        (128331,          8, 'operator 2026-11-26: whole venue. 2 UFC dates, 1 on sale now, 1 at its 12-04 on-sale.'),
        (101164,         36, 'operator 2026-11-26: whole venue. 30 eligible of 51 AXS-ticketed; the rest are beyond the 180-day horizon and join as the season nears.'),
        (100995,         28, 'operator 2026-11-26: whole venue. 25 BNP Paribas Open sessions.'),
        (101076,         12, 'operator 2026-11-26: whole venue. 7 eligible.'),
        (101546,         14, 'operator 2026-11-26: whole venue. 0 today — all 8 AXS-ticketed events are beyond the 180-day horizon; the season arrives in spring.')
       ) AS v(axs_venue_id, quota, note)
 WHERE wv.axs_venue_id = v.axs_venue_id;

-- ── 5. the list's ceiling ─────────────────────────────────────────────────
UPDATE public.axs_watch_config SET target_events = 230, updated_at = now();

-- ── 6. grants, matching 20261124190000 ────────────────────────────────────
REVOKE ALL ON FUNCTION public.axs_watch_rule_ok(text, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_rule_ok(text, text, bigint) TO service_role;

COMMIT;
