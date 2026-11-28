-- Operator 2026-11-28: "differenciate from some seats being non-transferrable and an entire
-- event being untransferrable".
--
-- My detector (mig 20261127240000) was EXISTS(any delivery_methods label matches), and the
-- settle retires the whole event on it. That conflates two different things. delivery_methods
-- entries each carry their own offer_id -- the Trans-Siberian capture has five, one per offer
-- -- so a non-transferable label describes ONE OFFER, not the event. An event where one offer
-- is non-transferable and others are freely transferable is still sellable, and retiring it
-- throws away real inventory.
--
-- Amy Grant at the Ryman was a true positive: a single delivery method, non-transferable, plus
-- the warning in event.description. The loose rule then retired 27 more events in 40 minutes,
-- 26 of them Red Rocks -- and one of them was "Houston Rockets vs. Memphis Grizzlies" at
-- Toyota Center, a regular-season NBA game, which is the clearest possible demonstration that
-- the rule was wrong. All 28 non-Ryman events were restored to the watch to be re-judged.
--
-- The rule is now whole-event only:
--   event.description says so                                   -> the event, retire
--   OR every delivery method is non-transferable (none is not)   -> the event, retire
--   SOME but not all                                             -> NOT the event; those
--                                                                   offers' listings are
--                                                                   dropped by mig 20261128010000
-- Strictly more conservative than what it replaces: it can only retire fewer events, never more.

CREATE OR REPLACE FUNCTION public.axs_watch_nontransferable_offers(p_body jsonb)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT coalesce(array_agg(DISTINCT d->>'offer_id'), ARRAY[]::text[])
    FROM jsonb_array_elements(
           CASE WHEN jsonb_typeof(p_body->'delivery_methods') = 'array'
                THEN p_body->'delivery_methods' ELSE '[]'::jsonb END) d
   WHERE coalesce(d->>'label','') ~* 'non[- ]?transferable'
     AND nullif(d->>'offer_id','') IS NOT NULL
$fn$;

REVOKE ALL ON FUNCTION public.axs_watch_nontransferable_offers(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_nontransferable_offers(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.axs_watch_non_transferable(p_body jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $fn$
  -- coalesced to false on purpose: without it a body with no delivery_methods key returns
  -- NULL (jsonb_typeof(NULL) is NULL, and false OR NULL is NULL), which is a trap for any
  -- caller writing NOT v_nontrans.
  SELECT coalesce(
    coalesce(p_body->'event'->>'description','')
      ~* 'non[- ]?transferable|resale will not be permitted'
    OR (
      jsonb_typeof(p_body->'delivery_methods') = 'array'
      AND jsonb_array_length(p_body->'delivery_methods') > 0
      AND NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_body->'delivery_methods') d
             WHERE coalesce(d->>'label','') !~* 'non[- ]?transferable')
    ), false)
$fn$;

DO $verify$
DECLARE
  whole_label jsonb := jsonb_build_object('delivery_methods', jsonb_build_array(
    jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)','offer_id','1')));
  whole_descr jsonb := jsonb_build_object(
    'event', jsonb_build_object('description','TICKETS FOR THIS EVENT ARE NON-TRANSFERABLE.'),
    'delivery_methods', jsonb_build_array(jsonb_build_object('label','AXS Mobile ID','offer_id','1')));
  mixed jsonb := jsonb_build_object('delivery_methods', jsonb_build_array(
    jsonb_build_object('label','AXS Mobile ID','offer_id','1'),
    jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)','offer_id','2')));
  clean jsonb := jsonb_build_object('delivery_methods', jsonb_build_array(
    jsonb_build_object('label','AXS Mobile ID','offer_id','1'),
    jsonb_build_object('label','AXS Mobile ID','offer_id','2')));
BEGIN
  IF NOT public.axs_watch_non_transferable(whole_label) THEN
    RAISE EXCEPTION 'every delivery method non-transferable must count as the whole event';
  END IF;
  IF NOT public.axs_watch_non_transferable(whole_descr) THEN
    RAISE EXCEPTION 'the description must still count as the whole event';
  END IF;
  IF public.axs_watch_non_transferable(mixed) THEN
    RAISE EXCEPTION 'a mixed event must NOT be treated as wholly non-transferable';
  END IF;
  IF public.axs_watch_non_transferable(clean) THEN
    RAISE EXCEPTION 'a transferable event must not be flagged';
  END IF;
  IF public.axs_watch_non_transferable('{}'::jsonb) IS NOT FALSE THEN
    RAISE EXCEPTION 'an empty body must return false, not NULL';
  END IF;
  IF public.axs_watch_nontransferable_offers(mixed) <> ARRAY['2'] THEN
    RAISE EXCEPTION 'the mixed case must name offer 2 only, got %',
      public.axs_watch_nontransferable_offers(mixed)::text;
  END IF;
  IF public.axs_watch_nontransferable_offers(clean) <> ARRAY[]::text[] THEN
    RAISE EXCEPTION 'a transferable event must name no offers';
  END IF;
END $verify$;
