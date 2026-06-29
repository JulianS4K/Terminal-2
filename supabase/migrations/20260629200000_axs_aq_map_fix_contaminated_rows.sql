-- Migration 20260629200000 · lane:A1 (DB — AQ hub data fix) · writes:aq_event_map (4 contaminated rows), axs_events/axs_event_snapshots/axs_section_snapshots/axs_seat_snapshots (re-map 6 via canonical mapper) · reads:events · pre:20260629190000 · auth:operator-approved 2026-06-29 (julian@s4kent.com — "use tickets-data event matcher/mapper to assist")
--
-- WHY ------------------------------------------------------------------------
-- mig 190000 re-mapped the 6 off-date AXS events via match_to_aq_event_id, but the
-- mapper's tier-1 (direct axs_event_id lookup) was HIJACKED by pre-existing contaminated
-- aq_event_map rows and returned wrong tevo links (e.g. Andrea Gibson → Eric Church).
-- The hub rows themselves were bad:
--   K5ADZPP  (Vince Gill 8/7 curated)  wrongly back-ref'd axs_event_id='1289522' (the 8/6 AXS event)
--   AXS1240780 (Alison Krauss 9/18 own row) wrongly stamped tevo 3235906 (the 9/19 event)
--   AXS1413462 (Andrea Gibson 7/5 own row)  wrongly stamped tevo 3360484 (Eric Church 7/6)
--   G7OO4BO  (Nate Smith 6/18 curated)  wrongly stamped tevo 3252823 (the 6/17 event)
-- TEvo actually carries the correct per-night events (verified): Vince Gill 8/6=3269426
-- (aq 5XD7GZP), 8/8=3269438 (aq 2X69KJP); Alison Krauss 9/18=3236110; Nate Smith has
-- no 6/18 and Andrea Gibson/Rod-Stewart-2027 have no TEvo event → those stay SYS/unmapped.
--
-- FIX: (1) clean the 4 contaminated aq_event_map rows so the canonical mapper is no longer
-- hijacked; (2) re-clear + re-run match_to_aq_event_id (+ create_system_aq_event fallback)
-- for the 6 — now it resolves each correctly (tier-1 self-ref or tier-2 venue+date ±6h).
-- The axs_aq_match date-precision + name guards (migs 180000/190000) remain; the 6h backfill
-- cron uses axs_aq_match (guarded), so it will not re-introduce the off-date links.
--
-- SAFETY: scoped to 4 named aq rows + 6 named AXS events. match_to_aq_event_id is read-only;
-- create_system_aq_event is md5-idempotent. Reversible (restore prior tevo/axs_event_id values).

-- (1) Clean the contaminated hub rows.
UPDATE public.aq_event_map SET axs_event_id = NULL  WHERE aq_short_event_id = 'K5ADZPP';     -- drop wrong 8/6 back-ref
UPDATE public.aq_event_map SET tevo_event_id = 3236110 WHERE aq_short_event_id = 'AXS1240780'; -- Alison Krauss 9/18 → correct 9/18 tevo
UPDATE public.aq_event_map SET tevo_event_id = NULL  WHERE aq_short_event_id = 'AXS1413462';  -- Andrea Gibson: no TEvo
UPDATE public.aq_event_map SET tevo_event_id = NULL  WHERE aq_short_event_id = 'G7OO4BO';     -- Nate Smith 6/18: no 6/18 TEvo

-- (2) Re-clear the 6 AXS events, then re-map via the (now-unhijacked) canonical mapper.
UPDATE public.axs_section_snapshots SET tevo_event_id = NULL
  WHERE snapshot_id IN (SELECT id FROM public.axs_event_snapshots
        WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239'));
UPDATE public.axs_seat_snapshots SET tevo_event_id = NULL
  WHERE snapshot_id IN (SELECT id FROM public.axs_event_snapshots
        WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239'));
UPDATE public.axs_event_snapshots SET tevo_event_id = NULL, aq_short_event_id = NULL
  WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239');
UPDATE public.axs_events SET tevo_event_id = NULL, aq_short_event_id = NULL
  WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239');

DO $cleanup$
DECLARE r record; v_aq text; v_tevo bigint; v_snap bigint;
BEGIN
  FOR r IN
    SELECT ax.axs_event_id, l.event_name, l.venue_name, l.occurs_at_local, l.tevo_venue_id
    FROM (VALUES ('1413462'),('1216092'),('1240780'),('1289522'),('1253401'),('1289239')) ids(id)
    JOIN public.axs_events ax ON ax.axs_event_id = ids.id
    JOIN LATERAL (
      SELECT s.event_name, s.venue_name, s.occurs_at_local, s.tevo_venue_id
      FROM public.axs_event_snapshots s
      WHERE s.axs_event_id = ax.axs_event_id AND s.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
        AND s.event_name IS NOT NULL AND s.venue_name IS NOT NULL
      ORDER BY s.captured_at DESC LIMIT 1
    ) l ON true
  LOOP
    SELECT m.aq_short_event_id INTO v_aq
    FROM public.match_to_aq_event_id('axs', r.axs_event_id::bigint, r.event_name, r.venue_name,
                                     r.occurs_at_local::timestamptz, NULL, NULL, r.tevo_venue_id) m
    LIMIT 1;
    IF v_aq IS NULL THEN
      v_aq := public.create_system_aq_event('axs', r.event_name, r.venue_name,
                                            r.occurs_at_local::timestamptz, r.axs_event_id::bigint);
    END IF;
    SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq LIMIT 1;
    UPDATE public.axs_events SET aq_short_event_id = v_aq, tevo_event_id = v_tevo
      WHERE axs_event_id = r.axs_event_id;
    SELECT id INTO v_snap FROM public.axs_event_snapshots
      WHERE axs_event_id = r.axs_event_id ORDER BY captured_at DESC LIMIT 1;
    UPDATE public.axs_event_snapshots SET aq_short_event_id = v_aq, tevo_event_id = v_tevo WHERE id = v_snap;
    IF v_tevo IS NOT NULL THEN
      UPDATE public.axs_section_snapshots SET tevo_event_id = v_tevo WHERE snapshot_id = v_snap;
      UPDATE public.axs_seat_snapshots    SET tevo_event_id = v_tevo WHERE snapshot_id = v_snap;
    END IF;
  END LOOP;
END $cleanup$;
