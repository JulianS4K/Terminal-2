-- A read that serves another performance is not this event's inventory.
--
-- Evidence (raw captures, 2026-11-27 21:58Z, mig 20261127220000):
--   Trans-Siberian Orchestra at Toyota Center, 2026-12-11. We hold two events:
--     1579099  starts_local 15:00  (matinee)
--     1579101  starts_local 19:30
--   We send two distinct, correct URLs (.../events/1579099/... and .../events/1579101/...)
--   and TicketsData echoes the right event_id_requested and the right `event` metadata for
--   each -- including the right start time. But BOTH responses resolve to the same
--   tix.axs.com onsale token and carry the SAME inventory: 296 listings, identical content
--   hash c9b3927e1129da41a0ebeabbe6387ae0, every listing stamped event_id 5263, and
--     onsale.sub_events = [{"date":"2026-12-11 15:00:00","title":"... - 3:00 PM","event_id":"5263"}]
--   AXS event 5263 is the 3:00 PM matinee. So the 19:30 event publishes the matinee's seats
--   and the matinee's prices. The 19:30 show's inventory is not in the response at all --
--   no parse change can recover it.
--
-- Measured against two real receipts for seats we were publishing at $66 face:
--     FLOOR D row 25  -> sold at $82 face      (we published $66)
--     section 119 / 17 -> sold at $77 face     (we published $66)
--   The matinee is the cheaper performance, which is why every seat read one band low.
--
-- The check is self-contained: `event.starts_local` and `onsale.sub_events[0].date` are both
-- in the same body, so no cross-event lookup is needed. When they disagree, the inventory
-- belongs to a different performance than the event we asked about.
--
-- This migration SHIPS IN OBSERVE MODE. It always records a mismatch in axs_watch_audit
-- (at most one row per event per 6h, so a 10-minute cadence does not flood it), but it only
-- withholds the listings when axs_watch_config.withhold_wrong_performance is turned on,
-- which it is NOT by default. Withholding changes what the CRM feed publishes, so that is an
-- operator decision taken on the evidence the observe mode collects -- not a side effect of
-- applying this file. Turning it on makes such a read fail, which surfaces as
-- listings_withheld = 'poll_failed' with the reason in poll_error; a distinct
-- 'wrong_performance' reason in the two feed views is a follow-up, kept out of here because
-- 20261127213000 is already queued against those same view bodies.

BEGIN;

-- 1. the detector -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.axs_watch_wrong_performance(p_body jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_starts text; v_sub text; v_title text; v_ev timestamp; v_on timestamp;
BEGIN
  -- Only a single sub_event is comparable. A body with none cannot be checked; one with
  -- several is a package or festival, where the event's own time need not match any of them.
  IF jsonb_typeof(p_body->'onsale'->'sub_events') <> 'array'
     OR jsonb_array_length(p_body->'onsale'->'sub_events') <> 1 THEN
    RETURN NULL;
  END IF;
  v_starts := nullif(p_body->'event'->>'starts_local', '');
  v_sub    := nullif(p_body->'onsale'->'sub_events'->0->>'date', '');
  v_title  := nullif(p_body->'onsale'->'sub_events'->0->>'title', '');
  IF v_starts IS NULL OR v_sub IS NULL THEN
    RETURN NULL;
  END IF;
  -- starts_local carries an offset ("2026-12-11T19:30:00-06:00"); the sub_event date does
  -- not. Both are local wall time for the same venue, so compare the wall clocks.
  v_ev := left(v_starts, 19)::timestamp;
  v_on := left(v_sub, 19)::timestamp;
  IF abs(extract(epoch FROM (v_ev - v_on))) <= 1800 THEN
    RETURN NULL;
  END IF;
  RETURN format('wrong_performance: event starts %s but the onsale block serves %s (%s)',
                to_char(v_ev, 'YYYY-MM-DD HH24:MI'), to_char(v_on, 'YYYY-MM-DD HH24:MI'),
                coalesce(v_title, 'untitled'));
EXCEPTION WHEN others THEN
  -- An unexpected shape must never fail a read. Silence here only loses the check.
  RETURN NULL;
END $fn$;

REVOKE ALL ON FUNCTION public.axs_watch_wrong_performance(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_wrong_performance(jsonb) TO service_role;

-- 2. the switch, off ----------------------------------------------------------------------
ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS withhold_wrong_performance boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.axs_watch_config.withhold_wrong_performance IS
  'When true, a read whose onsale block serves a different performance is failed instead of '
  'published. Off by default: observe first in axs_watch_audit (action = wrong_performance).';

-- 3. wire it into the settle, in place ----------------------------------------------------
DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
  decl_old CONSTANT text := '  v_sellable integer; v_thin boolean := false;';
  decl_new CONSTANT text := '  v_sellable integer; v_thin boolean := false;' || E'\n' ||
                            '  v_perf text;';
  body_old CONSTANT text :=
    '    parsed := public.axs_watch_parse(body);' || E'\n' ||
    '    v_ok := true; v_outcome := CASE WHEN jsonb_array_length(parsed->''listings'') = 0 THEN ''empty'' ELSE ''ok'' END;';
  body_new CONSTANT text :=
    '    parsed := public.axs_watch_parse(body);' || E'\n' ||
    '    -- mig 20261127230000: the body may carry another performance''s inventory.' || E'\n' ||
    '    v_perf := public.axs_watch_wrong_performance(body);' || E'\n' ||
    '    IF v_perf IS NOT NULL AND NOT EXISTS (' || E'\n' ||
    '         SELECT 1 FROM public.axs_watch_audit a' || E'\n' ||
    '          WHERE a.action = ''wrong_performance'' AND a.axs_event_id = p_event_id' || E'\n' ||
    '            AND a.at > now() - interval ''6 hours'') THEN' || E'\n' ||
    '      INSERT INTO public.axs_watch_audit (action, axs_event_id, venue, note)' || E'\n' ||
    '      VALUES (''wrong_performance'', p_event_id,' || E'\n' ||
    '              nullif(body->''event''->''venue''->>''name'', ''''), left(v_perf, 400));' || E'\n' ||
    '    END IF;' || E'\n' ||
    '    IF v_perf IS NOT NULL AND coalesce(v_cfg.withhold_wrong_performance, false) THEN' || E'\n' ||
    '      parsed := NULL; v_ok := false; v_outcome := ''wrong_performance'';' || E'\n' ||
    '      v_error := left(v_perf, 200);' || E'\n' ||
    '    ELSE' || E'\n' ||
    '      v_ok := true; v_outcome := CASE WHEN jsonb_array_length(parsed->''listings'') = 0 THEN ''empty'' ELSE ''ok'' END;' || E'\n' ||
    '    END IF;';
  n_decl int; n_body int;
BEGIN
  n_decl := (length(src) - length(replace(src, decl_old, ''))) / length(decl_old);
  n_body := (length(src) - length(replace(src, body_old, ''))) / length(body_old);
  IF n_decl <> 1 THEN
    RAISE EXCEPTION 'settle DECLARE anchor matched % times, expected 1', n_decl;
  END IF;
  IF n_body <> 1 THEN
    RAISE EXCEPTION 'settle parse anchor matched % times, expected 1', n_body;
  END IF;
  IF position('axs_watch_wrong_performance' in src) > 0 THEN
    RAISE EXCEPTION 'settle already calls axs_watch_wrong_performance';
  END IF;
  src := replace(src, decl_old, decl_new);
  src := replace(src, body_old, body_new);
  EXECUTE src;
END $surgery$;

-- 4. read back ----------------------------------------------------------------------------
DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
  good jsonb := jsonb_build_object(
    'event', jsonb_build_object('starts_local', '2026-12-11T15:00:00-06:00'),
    'onsale', jsonb_build_object('sub_events', jsonb_build_array(
      jsonb_build_object('date', '2026-12-11 15:00:00', 'title', 'TSO - 3:00 PM', 'event_id', '5263'))));
  bad jsonb := jsonb_build_object(
    'event', jsonb_build_object('starts_local', '2026-12-11T19:30:00-06:00'),
    'onsale', jsonb_build_object('sub_events', jsonb_build_array(
      jsonb_build_object('date', '2026-12-11 15:00:00', 'title', 'TSO - 3:00 PM', 'event_id', '5263'))));
  none jsonb := jsonb_build_object('event', jsonb_build_object('starts_local', '2026-12-11T19:30:00-06:00'));
BEGIN
  IF position('axs_watch_wrong_performance' in src) = 0 THEN
    RAISE EXCEPTION 'settle does not call the detector after surgery';
  END IF;
  IF position('withhold_wrong_performance' in src) = 0 THEN
    RAISE EXCEPTION 'settle does not read the config flag after surgery';
  END IF;
  -- the matinee, asked for and served: no complaint
  IF public.axs_watch_wrong_performance(good) IS NOT NULL THEN
    RAISE EXCEPTION 'detector flagged a matching performance: %', public.axs_watch_wrong_performance(good);
  END IF;
  -- the 19:30 show served the matinee: caught
  IF public.axs_watch_wrong_performance(bad) IS NULL THEN
    RAISE EXCEPTION 'detector missed the 19:30 event served the 15:00 inventory';
  END IF;
  -- a body with no sub_events is not judged
  IF public.axs_watch_wrong_performance(none) IS NOT NULL THEN
    RAISE EXCEPTION 'detector judged a body with no sub_events';
  END IF;
  -- and it stays off until an operator says otherwise
  IF (SELECT bool_or(withhold_wrong_performance) FROM public.axs_watch_config) THEN
    RAISE EXCEPTION 'withhold_wrong_performance must ship off';
  END IF;
END $verify$;

COMMIT;
