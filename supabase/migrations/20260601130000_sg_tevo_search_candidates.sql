-- sg_tevo_search_candidates: server-side candidate selection for the SG cold bridge.
--
-- Fixes the starvation bug in sg-to-tevo-search-bridge: the edge fn fetched a
-- date-ordered LIMIT*6 window from sg_events_canonical and filtered tried rows
-- CLIENT-side, so it never paginated past the nearest-dated front of the queue.
-- no_results rows at the front got retried every 24h while ~1300 never-tried
-- upcoming candidates were never reached.
--
-- Mirrors the pattern shipped for the non-SG bridge (aq_tevo_search_candidates,
-- migration 20260601051410): anti-join sg_tevo_search_attempts, never-tried-first
-- ordering, backoff window. Adds owned_first / owned_only support to preserve the
-- seatgeek_seller_listings priority behavior the SG bridge already had.
--
-- SECURITY DEFINER + search_path pinned per SECDEF RPC convention. Read-only.

CREATE OR REPLACE FUNCTION public.sg_tevo_search_candidates(
  p_limit         integer DEFAULT 20,
  p_backoff_hours integer DEFAULT 24,
  p_owned_first   boolean DEFAULT true,
  p_owned_only    boolean DEFAULT false
)
RETURNS TABLE(
  sg_event_id     bigint,
  sg_event_name   text,
  sg_event_date   date,
  sg_datetime_utc timestamptz,
  sg_venue_name   text,
  sg_venue_city   text,
  sg_venue_state  text,
  sg_category     text,
  owned           boolean,
  last_result     text
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH owned_ev AS (
    SELECT DISTINCT sg_event_id
    FROM public.seatgeek_seller_listings
    WHERE sg_event_id IS NOT NULL
  )
  SELECT
    c.sg_event_id,
    c.sg_event_name,
    c.sg_event_date,
    c.sg_datetime_utc,
    c.sg_venue_name,
    c.sg_venue_city,
    c.sg_venue_state,
    c.sg_category,
    (o.sg_event_id IS NOT NULL) AS owned,
    a.result                    AS last_result
  FROM public.sg_events_canonical c
  LEFT JOIN owned_ev o                     ON o.sg_event_id = c.sg_event_id
  LEFT JOIN public.sg_tevo_search_attempts a ON a.sg_event_id = c.sg_event_id
  WHERE c.tevo_event_id IS NULL
    AND c.sg_datetime_utc > now()
    AND NOT (COALESCE(c.sg_category, '') IN ('Parking', 'parking')
             OR c.sg_venue_name ILIKE '%parking%'
             OR c.sg_event_name ILIKE '%parking%')
    AND NOT (c.sg_event_name ~* '(cancelled|if necessary|\(date tbd\))')
    -- never-tried OR outside the retry backoff window
    AND (a.sg_event_id IS NULL
         OR a.attempted_at < now() - make_interval(hours => p_backoff_hours))
    -- owned_only: restrict to events we hold inventory on
    AND (NOT p_owned_only OR o.sg_event_id IS NOT NULL)
  ORDER BY
    -- owned priority (owned_first default ON, and always when owned_only)
    CASE WHEN p_owned_first OR p_owned_only THEN (o.sg_event_id IS NOT NULL) ELSE false END DESC,
    -- never-tried first, then oldest attempt — drains the backlog instead of
    -- pinning to the date-front
    (a.sg_event_id IS NULL) DESC,
    a.attempted_at ASC NULLS FIRST,
    c.sg_datetime_utc ASC
  LIMIT GREATEST(1, LEAST(200, p_limit));
$function$;

REVOKE ALL ON FUNCTION public.sg_tevo_search_candidates(integer, integer, boolean, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.sg_tevo_search_candidates(integer, integer, boolean, boolean) TO service_role;

COMMENT ON FUNCTION public.sg_tevo_search_candidates(integer, integer, boolean, boolean) IS
  'SG cold-bridge candidate selection. Anti-joins sg_tevo_search_attempts, orders never-tried-first within owned-first/owned-only priority. Fixes date-front starvation in sg-to-tevo-search-bridge. See migration 20260601130000.';
