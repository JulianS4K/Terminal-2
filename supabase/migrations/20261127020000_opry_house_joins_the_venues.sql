-- Migration 20261127020000 · level:data-collection · lane:a1 (AXS watch venue set) · writes:axs_watch_venue(+Opry House) · reads:axs_export_event
--
-- ============================================================================
-- Migration 20261127020000 — Opry House joins the watched venue set
--
-- Lane:     a1 (AXS watch)
-- pre:      20261126044500 (keep_all venues), 20261127000000 (no date horizon).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- Operator 2026-11-27: "add Opry House to venues".
--
-- ── WHAT IT IS ────────────────────────────────────────────────────────────
-- Opry House, AXS venue 100951, Nashville. The export carries 333 live events for it, the
-- soonest tomorrow, and it says AXS tickets them (axs_ticketed true on at least some), so no
-- trust_axs_sold override is needed — unlike Nissan Stadium, which the operator also named and
-- which is NOT added here: its 15 events all say axs_ticketed false, so it needs that override
-- and a separate decision.
--
-- Shape: enabled, keep_all, quota 0 — the same as the other 28. keep_all publishes the whole
-- venue to the API as catalogue rows, which cost NOTHING: a catalogue row is never read
-- (mig 20261126060000). Places on the WATCH come only from the fill's soonest-first backfill.
--
-- ── THE CONSEQUENCE, WHICH IS NOT SMALL ───────────────────────────────────
-- The Grand Ole Opry plays most nights, so its events are perpetually among the soonest
-- anywhere, and the backfill takes candidates soonest first. The list is full at target_events
-- (341), so nothing is displaced today — Opry gains watched places only as other events pass
-- and free them. But it will keep winning those places, and the precedent says how far that
-- goes: Ryman Auditorium, the other nightly-show house in the set, holds 44 of the 341 with
-- 174 export events. Opry has 333, nearly twice as many.
--
-- So expect Opry to drift toward 60-90 of the 341 over the coming weeks, taking those places
-- from other venues rather than adding to the total. Two levers, both the operator's and
-- neither applied here:
--   · give it a quota (axs_watch_venue.quota) to bound or guarantee its share. Note a quota
--     CONSUMES places from the same 341, it does not add any;
--   · raise target_events, which costs credits — about 24 reads a day for each event added,
--     against a cap that tightens to ~8,167/day on 2026-12-18 while the bands already ask
--     ~8,278 (see mig 20261126200000).
-- Watch it in the monitor's per-venue line. If Opry's share is unwanted, a quota is the fix,
-- not removing the venue — the catalogue rows are free and worth having either way.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- DELETE FROM public.axs_watch_venue WHERE axs_venue_id = 100951;
-- (then the next axs_watch_fill retires its watched events and axs_catalogue_fill drops its
--  catalogue rows)
-- ============================================================================

BEGIN;

DO $guard$
DECLARE v_events integer; v_ticketed boolean; v_name text;
BEGIN
  SELECT count(*), bool_or(coalesce(e.axs_ticketed, false)), max(e.venue_name)
    INTO v_events, v_ticketed, v_name
    FROM public.axs_export_event e
   WHERE e.venue_id = 100951 AND e.gone_at IS NULL AND e.removed_utc IS NULL;
  IF coalesce(v_events, 0) = 0 THEN
    RAISE EXCEPTION 'venue 100951 has no live export events — check the id before adding it';
  END IF;
  IF v_name IS DISTINCT FROM 'Opry House' THEN
    RAISE EXCEPTION 'venue 100951 is "%", not Opry House', v_name;
  END IF;
  IF NOT v_ticketed THEN
    RAISE EXCEPTION 'the export says AXS does not ticket venue 100951 — it would need trust_axs_sold';
  END IF;
  RAISE NOTICE 'Opry House (100951): % live export events, axs_ticketed', v_events;
END $guard$;

INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by)
VALUES (100951, 'Opry House', 0, true, true,
        'operator 2026-11-27 "add Opry House to venues"; nightly-show house, 333 export events — expect it to drift toward 60-90 of target_events via the soonest-first backfill, bound it with a quota if that is unwanted (mig 20261127020000)',
        'claude-opus-5')
ON CONFLICT (axs_venue_id) DO UPDATE
   SET enabled = true, keep_all = true, venue_name = EXCLUDED.venue_name,
       note = EXCLUDED.note, set_by = EXCLUDED.set_by;

COMMIT;
