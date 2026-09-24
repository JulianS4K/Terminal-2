-- Migration 20260924190000 · level:secondary-sales · lane:D7 · writes:n2s_items · reads:events · pre:20260910180000
--
-- Already applied to prod · via MCP 2026-09-24 under operator direction.
-- ============================================================================
-- Migration 20260924190000 — N2S mapper: the local START TIME breaks a tie
--                            between same-venue, same-day, name-consistent events
--
-- Lane:     D7 · Pre-reqs: 20260910180000 (rules 1-4, the _p candidate table),
--           20260911040000 (identity rules ahead of it — untouched here)
-- Touches:  n2s_map_events() — one column added to the _p candidate table and
--           one rule (3b) inserted between rule 3 (session number) and rule 4
--           (name guard). Nothing else moves. No new cron; cron 598 runs it.
--
-- READ-ONLY upstream: a join over tables we already hold. RULE 2 untouched.
--
-- Operator 2026-09-24: "see if you can fix the mapping for some of these"
-- (the 29 unmapped obligations).
--
-- ── WHAT WAS TRUE BEFORE ───────────────────────────────────────────────────
-- Four of the 29 were Broadway orders — Harry Potter and the Cursed Child x3
-- (Lyric Theatre, 2026-09-23) and Oh, Mary! (Lyceum, 2026-09-13). Both events
-- ARE in the catalogue (3217422 / 3387400) and the venue resolves (31499 /
-- 882). They failed because the house plays TWO sessions that day (13:00 and
-- 19:00): rule 1 sees two same-name events and declines, rule 2 needs exactly
-- one event at the venue, rule 3 needs a "Session N" token (tennis), and rule
-- 4 needs exactly one name-consistent candidate — both are. Every rule was
-- right to decline; none of them looked at the one field that separates a
-- matinee from an evening show: the start time, which the CRM feed carries on
-- every order (n2s_items.event_dt is a LOCAL timestamp) and the catalogue
-- carries on every event (events.occurs_at_local, text, "YYYY-MM-DDTHH:MI…").
--
-- Measured 2026-09-24 on the whole book before writing this:
--   * unmapped rows that a time tiebreak would map:      4 (the four above)
--   * mapped rows with >1 candidate where the time picks exactly one: 249 —
--     the pick AGREES with the existing mapping 239 times and disagrees 10.
--     All 10 disagreements are cases where the time-pick is the better answer:
--     a Yankees/Rays doubleheader mapped to the 19:05 game for 13:05 orders
--     (4), Belmont racing mapped to the 11:00 card for 12:00 orders (5), and
--     Arkansas at Texas A&M mapped to a 00:00 placeholder for an 18:00 order
--     (1). Those came from the CRM/AQ inference paths and rule 5, not from
--     rules 1-4, and the mapper is fill-only: this migration does NOT touch
--     them. They are listed in the PR for an operator decision.
--   * start-time agreement across ALL mapped rows with a candidate: 96%
--     (2,224 of 2,323); Vivid 91%, SeatGeek 88% — feeds that round or shift
--     the minute. So the time is a TIEBREAK among name-consistent candidates,
--     never a hard filter: where it matches nothing, rule 4 runs as before.
--
-- ── THE RULE ───────────────────────────────────────────────────────────────
-- Rule 3b  n2s_venue_date_time   among the venue+date candidates that pass the
--          name guard, exactly one starts at the order's local HH:MI.
-- Position: after rule 3 (a session number is a stronger discriminator when
-- present) and before rule 4 (which would decline on the 2-candidate case).
-- Fill-only, unique-or-decline, live rows only — like every other rule.
-- Anchored self-asserting edit; refuses a drifted body and a re-run.
-- ============================================================================

DO $do$
DECLARE d text; a1 text; a2 text;
BEGIN
  d := pg_get_functiondef('public.n2s_map_events(boolean)'::regprocedure);

  IF position('n2s_venue_date_time' in d) > 0 THEN
    RAISE EXCEPTION 'n2s_map_events already carries rule 3b — 20260924190000 is applied; do not re-run';
  END IF;

  -- a1: the last column of the _p candidate table (rule 3's session token).
  a1 := E''', ''i''))[1] AS ev_sess\n';
  -- a2: the head of rule 4's UPDATE (rule 3b goes right before it).
  a2 := E'  UPDATE public.n2s_items n\n     SET tevo_event_id = s.eid, mapped_via = ''n2s_venue_date_nameguard''';

  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN
    RAISE EXCEPTION 'anchor a1 (ev_sess column) not found exactly once — body drifted, re-derive 20260924190000';
  END IF;
  IF (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 THEN
    RAISE EXCEPTION 'anchor a2 (rule 4 UPDATE) not found exactly once — body drifted, re-derive 20260924190000';
  END IF;

  -- 1. _p gains time_ok: the candidate starts at the order's local HH:MI.
  d := replace(d, a1,
    E''', ''i''))[1] AS ev_sess,\n' ||
    E'           substr(e.occurs_at_local, 12, 5) = to_char(n.event_dt, ''HH24:MI'') AS time_ok\n');

  -- 2. Rule 3b, before rule 4.
  d := replace(d, a2,
    E'  -- Rule 3b: several name-consistent events (a matinee and an evening show),\n' ||
    E'  -- the local start time picks exactly one (20260924190000). Tiebreak only:\n' ||
    E'  -- when no candidate matches the time, rule 4 runs unchanged.\n' ||
    E'  UPDATE public.n2s_items n\n' ||
    E'     SET tevo_event_id = s.eid, mapped_via = ''n2s_venue_date_time''\n' ||
    E'    FROM (SELECT n2s_id, min(eid) FILTER (WHERE name_ok AND time_ok) AS eid\n' ||
    E'            FROM _p GROUP BY n2s_id\n' ||
    E'          HAVING count(*) FILTER (WHERE name_ok) > 1\n' ||
    E'             AND count(*) FILTER (WHERE name_ok AND time_ok) = 1) s\n' ||
    E'   WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;\n' ||
    E'  GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;\n' ||
    E'\n' || a2);

  EXECUTE d;

  -- Self-check: the rule is in the live body, after rule 3 and before rule 4.
  d := pg_get_functiondef('public.n2s_map_events(boolean)'::regprocedure);
  IF position('AS time_ok' in d) = 0
     OR position('n2s_venue_date_time' in d) = 0
     OR position('n2s_venue_date_time' in d) < position('n2s_venue_date_session' in d)
     OR position('n2s_venue_date_time' in d) > position('n2s_venue_date_nameguard' in d) THEN
    RAISE EXCEPTION 'post-apply check failed: rule 3b missing or out of order';
  END IF;
END $do$;

COMMENT ON FUNCTION public.n2s_map_events(boolean) IS
  'Map open N2S obligations to a tevo_event_id, fill-only and unique-or-decline. Order: rule 0 CRM order identity (s4kcs_orders) · 0b EVO order identity (evo_orders, via the n2s_order_key split, 20260911040000) · 0c GoTickets sale identity (gotickets_sales.gt_event_id -> gotickets_event) · 0d Vivid order identity (vivid_orders) · 0e SeatGeek order identity (seatgeek_orders, tevo id from the row / xref / hub) — all four 20260911040000 · 1 name+local date (+venue guard) · 2 venue+date unique · 3 venue+date, session number · 3b venue+date, local START TIME picks one of several name-consistent candidates (matinee vs evening, 20260924190000) · 4 venue+date, name guard · 5 GoTickets name alias. Identity rules run first because an order we already hold beats any inference. Run by cron 598 every minute; n2s_gt_map_by_name() and n2s_pull_all_sources() follow in the same command.';
