-- Store AXS's own internal event id, and act on a collision.
--
-- Operator 2026-11-28: "add that column, if an event sends wrong info and is caught add it to
-- the once a day poller and stop sending listings to crm but monitor, then replace with a new
-- one."
--
-- WHY THE COLUMN. Two collisions are now proven: Trans-Siberian Orchestra 1579099/1579101
-- (same show, two performances) and Disney Descendants 1374728 served for KING + COUNTRY's
-- inventory 1519444 (two DIFFERENT shows, adjacent nights) -- the latter confirmed against the
-- live page by the operator: section 112 row 14 holds nine seats at $86 on for KING + COUNTRY
-- and does not exist at all on Disney, and our published all-in floor of $52 matches for KING
-- + COUNTRY's advertised $52, not Disney's $60.
--
-- Both were found the hard way. The fingerprint method (two events with identical listing
-- hashes) only works while BOTH still hold listings and were read closely enough that
-- inventory has not moved. The in-body time check (axs_watch_wrong_performance) needs exactly
-- one sub_event and produces false positives on doors and session metadata -- PBR 1583731
-- fired and its 12/19 sibling has a different 389 listings against its 388.
--
-- Every listing carries AXS's own internal event id (5263 for the Trans-Siberian pair), and
-- onsale.flags.events names it too. Stored per event, a collision becomes one query: two of
-- our source_event_ids pointing at the same AXS internal id. No timing, no tolerance, no
-- dependence on sub_events being present, and it settles the four cases the time check could
-- not judge (NCAA at T-Mobile Arena, BNP Paribas at Indian Wells).
--
-- WHAT HAPPENS ON A CATCH, per the operator: the event is PARKED on the one-a-day band so it
-- is still monitored, its listings stop reaching the CRM, and -- because a parked event does
-- not hold a place against target_events (mig 20261126230000) -- axs_watch_fill gives the slot
-- to a replacement. collision_paused is a column of its own rather than a reuse of
-- cadence_pinned, because cadence_pinned is RECOMPUTED by the settle on every read: that is
-- how the Trans-Siberian pause silently came undone earlier tonight and published matinee
-- prices again for an hour. The cadence update now skips a collision-paused event entirely.

BEGIN;

-- 1. the columns --------------------------------------------------------------------------
ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS axs_event_internal text,
  ADD COLUMN IF NOT EXISTS collision_paused   boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.primary_poll_event.axs_event_internal IS
  'AXS''s own internal event id from the read (onsale.flags.events[0], else listings[].event_id). '
  'Two of our source_event_ids sharing one value is a served-inventory collision (mig 20261128020030).';
COMMENT ON COLUMN public.primary_poll_event.collision_paused IS
  'Caught serving another event''s inventory: parked on the daily band, listings withheld from '
  'the CRM, slot returned to the fill. Durable - the settle''s cadence update skips these rows, '
  'unlike cadence_pinned which it recomputes every read.';

-- 2. read the id out of a body --------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.axs_watch_internal_event_id(p_body jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT coalesce(
    -- the onsale names it even when the event has no listings at all
    nullif(p_body->'onsale'->'flags'->'events'->>0, ''),
    -- otherwise every listing carries it
    (SELECT nullif(l->>'event_id','')
       FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(p_body->'listings') = 'array'
                   THEN p_body->'listings' ELSE '[]'::jsonb END) l
      WHERE nullif(l->>'event_id','') IS NOT NULL LIMIT 1))
$fn$;

REVOKE ALL ON FUNCTION public.axs_watch_internal_event_id(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_internal_event_id(jsonb) TO service_role;

-- 2b. the onsale block names a different SHOW ----------------------------------------------
-- Operator 2026-11-28: "isnt the title and time and date a give away?" -- yes, and the title
-- is the sharper of the two. event.title and event.starts_local are the trustworthy half of
-- the response: AXS returns OUR event's identity correctly every time, and it is the onsale /
-- listings half that gets substituted. So the event block is the anchor and the onsale block
-- is the suspect, for the title exactly as for the time.
--
-- Measured against all seven detections to date:
--   Disney Descendants ... <- "for KING + COUNTRY"          no overlap  -> different show
--   PBR ... TOUR - 12/20   <- "PBR ... TOUR - 12/19"        same words -> same show;
--                                                            caught by the TIME check instead
--   Trans-Siberian Orchestra <- "... - 3:00 PM"             contains    -> same show
--   NCAA ... Sweet 16 / Elite 8 <- identical strings        contains    -> same show
--   2027 BNP Paribas Open - Session 20 ... <- "Session 20 - Friday Eve Session - 03/12/2027"
--                                                            subset      -> same show
-- so a subset either way means the same show, and that is the whole rule. Punctuation and
-- case are normalised first so "for KING + COUNTRY" and "FOR KING AND COUNTRY" do not differ
-- on styling alone.
CREATE OR REPLACE FUNCTION public.axs_watch_wrong_show(p_body jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $fn$
  -- Compared as sets of WORDS, not as substrings. Plain containment fails on the Indian
  -- Wells pair, where each title appends its own date and so neither string contains the
  -- other; splitting on non-letters drops the dates and the question becomes the right one:
  -- is one title's vocabulary a subset of the other's?
  WITH t AS (
    SELECT (SELECT array_agg(w) FROM regexp_split_to_table(
              lower(coalesce(p_body->'event'->>'title','')), '[^a-z]+') w WHERE length(w) > 1) ev,
           (SELECT array_agg(w) FROM regexp_split_to_table(
              lower(coalesce(p_body->'onsale'->'sub_events'->0->>'title','')), '[^a-z]+') w
             WHERE length(w) > 1) sub)
  SELECT CASE
           WHEN ev IS NULL OR sub IS NULL THEN false   -- nothing to compare
           WHEN ev <@ sub OR sub <@ ev     THEN false  -- one vocabulary inside the other
           ELSE true
         END
    FROM t
$fn$;

REVOKE ALL ON FUNCTION public.axs_watch_wrong_show(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_wrong_show(jsonb) TO service_role;

-- 3. the collision view, for the operator and the monitor -----------------------------------
CREATE OR REPLACE VIEW public.v_axs_event_collisions AS
  SELECT t.axs_event_internal,
         count(*)                                   AS events,
         array_agg(t.source_event_id ORDER BY t.start_utc) AS source_event_ids,
         array_agg(t.name            ORDER BY t.start_utc) AS names,
         array_agg(t.start_utc       ORDER BY t.start_utc) AS starts,
         count(*) FILTER (WHERE t.collision_paused) AS already_paused
    FROM public.primary_poll_event t
   WHERE t.source = 'axs' AND t.axs_event_internal IS NOT NULL
   GROUP BY t.axs_event_internal
  HAVING count(*) > 1;

-- service_role only. An earlier cut granted SELECT to `authenticated` as well, which would
-- have let any signed-in user read primary_poll_event through a view that is not
-- security_invoker -- i.e. around RLS. This is an internal diagnostic; nothing outside the
-- service needs it, and if an operator UI ever does, it wants security_invoker plus its own
-- policy rather than a blanket grant.
REVOKE ALL ON public.v_axs_event_collisions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_event_collisions TO service_role;

COMMIT;
