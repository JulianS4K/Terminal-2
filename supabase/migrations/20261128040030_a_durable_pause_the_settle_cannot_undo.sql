-- A pause the settle cannot undo.
--
-- Operator 2026-11-28: "build the durable paused column".
--
-- WHY. The pause shipped in mig 20261127213000 is expressed as cadence_pinned AND a one-day
-- poll_interval -- and axs_watch_settle_one RECOMPUTES both on every successful read
-- (cadence_pinned = v_ga_slow, poll_interval = v_every). So any poll silently un-pauses the
-- event. The two Trans-Siberian shows came un-paused TWICE tonight on exactly this: the first
-- time after a forced re-poll, publishing the matinee's prices against the 19:30 show again
-- for about an hour before I noticed, and the second time on an ordinary scheduled read.
-- A pause that a routine read can undo is not a pause.
--
-- mig 20261128030030 already proved the shape of the fix for collisions: a column of its own,
-- with the cadence update skipping those rows. This generalises it to the operator pause,
-- and then does the three things a pause must do rather than the one it did:
--   1. the cadence update leaves the row alone, so the band and the pin survive every read
--   2. `fresh` is false, so listings_available cannot be true -- this is the arm that actually
--      governs publication, and the parked guard had to be put INSIDE it for the same reason
--   3. the reason arm sits ahead of not_polled and thin_inventory, because a paused event is
--      usually zeroed and a later arm would otherwise claim it and report the wrong reason
--      (exactly the defect s36 caught for the collision arm before it shipped)
--
-- collision_paused is added to `fresh` here too. It has been correct in practice only because
-- the settle happens to park the row at the same time, which is the same indirect reliance
-- that made the operator pause fragile in the first place.

BEGIN;

ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS paused boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.primary_poll_event.paused IS
  'Operator pause. Durable: the settle''s cadence update skips these rows, so a read cannot '
  'undo it, unlike cadence_pinned which the settle recomputes every time. Listings are '
  'withheld as ''paused'' and the event still polls on whatever band it was left on.';

-- 1. the settle leaves a paused row's cadence alone ----------------------------------------
DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
  old_guard CONSTANT text := '       AND NOT coalesce(e.collision_paused, false);';
  new_guard CONSTANT text := '       AND NOT coalesce(e.collision_paused, false)' || E'\n' ||
                             '       -- mig 20261128040030: nor the band of an operator-paused one' || E'\n' ||
                             '       AND NOT coalesce(e.paused, false);';
  n int;
BEGIN
  IF position('AND NOT coalesce(e.paused, false);' in src) > 0 THEN
    RAISE NOTICE 'the settle already respects the operator pause; nothing to do';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, old_guard, ''))) / length(old_guard);
  IF n <> 1 THEN RAISE EXCEPTION 'settle cadence guard matched % times, expected 1', n; END IF;
  EXECUTE replace(src, old_guard, new_guard);
END $surgery$;

-- 2. the feeds ------------------------------------------------------------------------------
DO $surgery$
DECLARE
  v_ev text; v_li text; v_ev_opts text[]; v_li_opts text[]; v_new text; n int;
  fresh_old CONSTANT text := ') AS fresh';
  fresh_new CONSTANT text := ' AND (NOT COALESCE(t.paused, false)) AND (NOT COALESCE(t.collision_paused, false))) AS fresh';
  arm_old CONSTANT text := E'            WHEN COALESCE(t.collision_paused, false) THEN \'wrong_performance\'::text\n';
  arm_new CONSTANT text := E'            WHEN COALESCE(t.collision_paused, false) THEN \'wrong_performance\'::text\n'
                        || E'            WHEN COALESCE(t.paused, false) THEN \'paused\'::text\n';
  where_old CONSTANT text := '(NOT COALESCE(t.collision_paused, false)) AND ((t.event_date IS NULL) OR (t.event_date >= (CURRENT_DATE - 1)))';
  where_new CONSTANT text := '(NOT COALESCE(t.collision_paused, false)) AND (NOT COALESCE(t.paused, false)) AND ((t.event_date IS NULL) OR (t.event_date >= (CURRENT_DATE - 1)))';
BEGIN
  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass)   INTO v_ev;
  SELECT pg_get_viewdef('v_primary_poll_listings_feed'::regclass) INTO v_li;
  SELECT reloptions INTO v_ev_opts FROM pg_class WHERE relname = 'v_primary_poll_events_feed';
  SELECT reloptions INTO v_li_opts FROM pg_class WHERE relname = 'v_primary_poll_listings_feed';
  IF v_ev ~ 'COALESCE\(t\.paused' THEN
    RAISE NOTICE 'the feeds already honour the operator pause; nothing to do';
    RETURN;
  END IF;

  n := (length(v_ev) - length(replace(v_ev, fresh_old, ''))) / length(fresh_old);
  IF n <> 1 THEN RAISE EXCEPTION 'events feed: the fresh anchor matched % times, expected 1', n; END IF;
  n := (length(v_ev) - length(replace(v_ev, arm_old, ''))) / length(arm_old);
  IF n <> 1 THEN RAISE EXCEPTION 'events feed: the collision arm matched % times, expected 1', n; END IF;
  v_new := replace(replace(v_ev, fresh_old, fresh_new), arm_old, arm_new);
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_events_feed AS ' || v_new;
  IF v_ev_opts @> ARRAY['security_invoker=true'] THEN
    EXECUTE 'ALTER VIEW public.v_primary_poll_events_feed SET (security_invoker = true)';
  END IF;

  n := (length(v_li) - length(replace(v_li, where_old, ''))) / length(where_old);
  IF n <> 1 THEN RAISE EXCEPTION 'listings feed: the where anchor matched % times, expected 1', n; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_listings_feed AS ' || replace(v_li, where_old, where_new);
  IF v_li_opts @> ARRAY['security_invoker=true'] THEN
    EXECUTE 'ALTER VIEW public.v_primary_poll_listings_feed SET (security_invoker = true)';
  END IF;

  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass)   INTO v_ev;
  SELECT pg_get_viewdef('v_primary_poll_listings_feed'::regclass) INTO v_li;
  IF v_ev !~ 'COALESCE\(t\.paused' OR v_li !~ 'COALESCE\(t\.paused' THEN
    RAISE EXCEPTION 'read-back: a feed does not honour the operator pause';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'v_primary_poll_events_feed'
                   AND reloptions @> ARRAY['security_invoker=true']) THEN
    RAISE EXCEPTION 'read-back: the events feed lost security_invoker=true';
  END IF;
  IF (SELECT reloptions FROM pg_class WHERE relname = 'v_primary_poll_listings_feed')
       IS DISTINCT FROM v_li_opts THEN
    RAISE EXCEPTION 'read-back: the listings feed reloptions changed';
  END IF;
END $surgery$;

-- 3. carry the two existing manual pauses onto the durable column ---------------------------
-- The Trans-Siberian pair (operator 2026-11-27: "Temp pause Trans-Siberian Orchestra /
-- Venue Toyota Center - TX / Both"). 1579101 is also collision_paused, which is the more
-- specific reason and wins in the ladder; 1579099 is the correct matinee and is paused
-- only because the operator asked for both.
UPDATE public.primary_poll_event
   SET paused = true
 WHERE source = 'axs' AND source_event_id IN ('1579099','1579101');

COMMIT;
