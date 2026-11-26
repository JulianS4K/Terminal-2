-- Venue building tours are neither polled nor published.
-- Operator 2026-11-26: "never poll or push out Crypto.com Arena VIP Tours presented by Delta
-- Air Lines", then "also exclude Ryman's tours, auto fill the poll list".
--
-- They are not ticketed events. Reading one back (1676569): each "listing" is a guided tour
-- departure slot, and the section field holds the DEPARTURE TIME — '11:00AM', '1:00PM',
-- '3:00PM' — not a seating section. quantity 18 is the tour group cap, seats is [], price is a
-- flat 60.00 with zero fee and zero tax. Nothing to trade, no price movement, and a clock time
-- in a section field misleads any consumer that expects a section. Ryman's are the same shape
-- at 10 to 68 dollars.
--
-- They were on the list because both venues are keep_all, and keep_all watches a venue WHOLE
-- by design (mig 20261126044500). Being near-dated they sat on the fast 30-101 minute bands:
-- 57 of 310 watched events — 18% of the list — taking 70.2 reads an hour, about 1,684 credits
-- a day, for 3,651 listings against the real events' 84,121. A fixed-price building tour was
-- being re-read every half hour.
--
-- TWO TOKENS, both verified against the live export before authoring:
--   crypto\.com arena vip tours   35 rows, all one title, 0 Ryman rows
--   ^ryman .*\mtour               366 rows across 5 titles, and NOTHING else starting 'Ryman'
--
-- The Ryman token is anchored and that anchor is the whole point. An earlier draft used
-- 'ryman (self-guided|vip|guided backstage)[ a-z]*tour' and MISSED 'Ryman Guided Tour' — 290
-- export rows, the largest tour family of all. Anchoring on ^ryman catches all five titles
-- ('Ryman Guided Tour', 'Ryman Self-Guided Tour', 'Ryman VIP Tour', 'Ryman Guided Backstage
-- Tour', 'Ryman Self-Guided Tour | Santa at the Ryman') while sparing the real concerts whose
-- titles merely END in Tour — 'Jimmy O. Yang Has No Friends Tour', 'Todd Rundgren: DAMNED IF I
-- DO TOUR' — and sparing 'Amy Grant & Vince Gill Christmas at the Ryman' and 'Grand Ole Opry:
-- Opry at the Ryman', which do not start with the word.
--
-- The tokens go in exclude_regex because that is the one gate keep_all does NOT lift, so they
-- remove the events from the watch AND from the API feed, the same way the operator's own
-- Lakers / Vanguards / Olivia Rodrigo exclusions do. Both arms of axs_catalogue_fill() call
-- axs_watch_rule_ok, so the out-arm DELETES the catalogue rows rather than stranding them in
-- the feed, and the in-arm never re-adds them; axs_watch_fill() retires the watched ones.
-- Freeing 57 slots under the 310 ceiling, the fill's backfill arm then draws real events in
-- soonest-first — the "auto fill" the operator asked for, needing no new code.

BEGIN;

DO $guard$
DECLARE v_old text; v_new text; v_titles integer; v_match integer;
  v_toks text[] := ARRAY['crypto\.com arena vip tours', '^ryman .*\mtour'];
  v_tok text;
BEGIN
  SELECT exclude_regex INTO v_old FROM public.axs_watch_config;
  IF v_old IS NULL OR btrim(v_old) = '' THEN
    RAISE EXCEPTION 'exclude_regex is empty — refusing to guess the operator''s regex';
  END IF;


  v_new := v_old;
  FOREACH v_tok IN ARRAY v_toks LOOP
    CONTINUE WHEN position(v_tok in v_new) > 0;   -- idempotent: already carried

    -- the token must name a small, closed set of titles, and must spare the real events whose
    -- titles merely contain the word 'tour'
    SELECT count(*), count(DISTINCT e.event_title) INTO v_match, v_titles
      FROM public.axs_export_event e
     WHERE e.event_date_utc > now() AND e.event_title ~* v_tok;
    IF v_titles > 5 THEN
      RAISE EXCEPTION 'token % matches % distinct titles, expected at most 5', v_tok, v_titles;
    END IF;
    -- A token matching nothing is inert, not wrong: a fresh or rebuilt database has no export
    -- rows yet, and the harness's stand-in export has none of these titles. Over-BREADTH is the
    -- dangerous direction and stays a hard failure above; this is a notice.
    IF v_match = 0 THEN
      RAISE NOTICE 'token % matches nothing in this database''s export (inert here)', v_tok;
    END IF;

    -- Append without rebuilding the operator's regex. Their value is one alternation group, so
    -- the token goes inside it, before the closing paren; anything else is wrapped into a
    -- group. Deliberately shape-general: asserting prod's exact tail made this unrunnable
    -- anywhere the regex differs, including the test harness and any rebuilt database.
    IF v_new ~ '\)$' THEN
      v_new := left(v_new, length(v_new) - 1) || '|' || v_tok || ')';
    ELSE
      v_new := '(' || v_new || '|' || v_tok || ')';
    END IF;
    RAISE NOTICE 'token % added (% export rows, % titles)', v_tok, v_match, v_titles;
  END LOOP;

  IF v_new = v_old THEN
    RAISE NOTICE 'exclude_regex already carries both tokens; nothing to change';
    RETURN;
  END IF;

  UPDATE public.axs_watch_config SET exclude_regex = v_new, updated_at = now() WHERE id;

  -- Read back two ways. First the gate: exclude_regex is ANDed ahead of every other clause, so
  -- an excluded title is refused at any venue and a keep_all venue cannot lift it
  -- (mig 20261126044500). Venue 0 has no axs_watch_venue row, so nothing else is in play.
  IF public.axs_watch_rule_ok('Music', 'Crypto.com Arena VIP Tours presented by Delta Air Lines', 0) THEN
    RAISE EXCEPTION 'the gate still admits the Crypto.com VIP tour title';
  END IF;
  IF public.axs_watch_rule_ok('Music', 'Ryman Guided Tour', 0) THEN
    RAISE EXCEPTION 'the gate still admits Ryman Guided Tour';
  END IF;
  IF public.axs_watch_rule_ok('Music', 'Ryman Self-Guided Tour | Santa at the Ryman', 0) THEN
    RAISE EXCEPTION 'the gate still admits the Santa-at-the-Ryman tour';
  END IF;
  -- the anchor must spare a real concert whose title merely ends in Tour
  IF v_new ~* 'ryman' AND 'Todd Rundgren: DAMNED IF I DO TOUR' ~* v_new THEN
    RAISE EXCEPTION 'the Ryman token also catches a real concert ending in Tour';
  END IF;
  IF 'Amy Grant & Vince Gill Christmas at the Ryman' ~* v_new THEN
    RAISE EXCEPTION 'the Ryman token also catches a concert with Ryman later in the title';
  END IF;

  -- Then width, isolated from keep_regex and the sports gate: the only export rows the NEW
  -- regex newly excludes must be exactly the rows the token itself matches. An earlier draft
  -- asserted that an ordinary title still passes axs_watch_rule_ok, which conflated this with
  -- keep_regex and failed wherever keep_regex is restrictive.
  SELECT count(*), count(DISTINCT e.event_title) INTO v_match, v_titles
    FROM public.axs_export_event e
   WHERE e.event_date_utc > now()
     AND e.event_title ~* v_new AND e.event_title !~* v_old;
  IF v_titles > 6 THEN
    RAISE EXCEPTION 'the two tokens newly exclude % distinct titles, expected at most 6', v_titles;
  END IF;
  RAISE NOTICE 'exclude_regex updated; it newly excludes % export rows across % titles', v_match, v_titles;
END $guard$;

COMMIT;
