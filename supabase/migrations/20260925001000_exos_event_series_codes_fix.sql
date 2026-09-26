-- ============================================================================
-- Migration 20260925001000 — Exos (Bridge / D4): creating an event series
--                            works when discount codes exist
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_create_event_series (patched in place)
--           R: exos_discount_codes
-- Pre-reqs: 20260911133000 (exos_create_event_series; applied to prod 2026-09-24)
--
-- Bug (found 2026-09-25 by replaying prod's real schema locally). The
-- discount-code copy in exos_create_event_series builds
--   SELECT * FROM jsonb_populate_record(... to_jsonb(d) ...) FROM exos_discount_codes d
-- (two FROM clauses), so every call raised "syntax error at or near FROM"
-- whenever public.exos_discount_codes exists, which it does in prod. Creating
-- any series from the organizer dashboard fails today. The offline harness
-- never ran that branch because its stub schema has no exos_discount_codes.
-- Fix: select from the table and populate each row with a LATERAL call.
--
-- Patched in place (one exact match asserted); skipped once applied.
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

DO $$
DECLARE
  v_def text := pg_get_functiondef(
    'public.exos_create_event_series(uuid, timestamptz[], text, text, jsonb, boolean)'::regprocedure);
  v_old text :=
    '        SELECT * FROM jsonb_populate_record(NULL::public.exos_discount_codes,' || chr(10) ||
    '          (to_jsonb(d) - ''id'' - ''created_at'' - ''updated_at'') || jsonb_build_object(' || chr(10) ||
    '            ''id'', gen_random_uuid(), ''event_id'', %L::uuid, ''used_count'', 0,' || chr(10) ||
    '            ''unlocks_tier_ids'', NULL, ''created_at'', now(), ''updated_at'', now()))' || chr(10) ||
    '          FROM public.exos_discount_codes d WHERE d.event_id = %L::uuid';
  v_new text :=
    '        SELECT r.* FROM public.exos_discount_codes d,' || chr(10) ||
    '          LATERAL jsonb_populate_record(NULL::public.exos_discount_codes,' || chr(10) ||
    '          (to_jsonb(d) - ''id'' - ''created_at'' - ''updated_at'') || jsonb_build_object(' || chr(10) ||
    '            ''id'', gen_random_uuid(), ''event_id'', %L::uuid, ''used_count'', 0,' || chr(10) ||
    '            ''unlocks_tier_ids'', NULL, ''created_at'', now(), ''updated_at'', now())) r' || chr(10) ||
    '          WHERE d.event_id = %L::uuid';
  v_hits int;
BEGIN
  IF position('LATERAL jsonb_populate_record(NULL::public.exos_discount_codes' in v_def) > 0 THEN
    RETURN;   -- already patched
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'exos_create_event_series: expected one discount-code copy, found %', v_hits;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;
