-- Migration 20261121171530 · level:data-collection · lane:D0 (outbound feed; reads the A1 mapping program's tables) · writes:tm_discovery_change(new),tm_discovery_event_log_change(new),v_tm_discovery_changes(new),v_tm_discovery_feed · reads:tm_discovery_event,events · pre:20261118223540
--
-- TICKETMASTER EVENTS: WHAT CHANGED, AND A NAME SEARCH.
-- Asked 2026-11-21 by a reader of GET /tm/events, passed on by the operator:
--   "A way to get events whose status or time changed. since only returns newly listed or newly
--    matched ones, so we have to re-read everything to catch cancellations."
--   "A name search on /tm/events, so we don't have to keep a full copy."
--
-- 1. CHANGES. tm_discovery_event keeps only an event's latest state: the collector overwrites
--    the row each time it re-reads the event, so a cancellation left no trace. Now a trigger on
--    that table writes one row to tm_discovery_change for each of these that differs after an
--    update: status (status_changed), date (date_changed), start time (time_changed), venue
--    (venue_changed), with the old and the new value. It fires only when one of them differs,
--    and a failure inside it is a warning, never an error: it must not stop the collector.
--      v_tm_discovery_changes   GET /tm/changes   the log, oldest first, with the event's name,
--                               date and link as they are now. Page with after_id.
--      v_tm_discovery_feed      `changed_at` now also moves when such a change is detected, so
--                               GET /tm/events?since= returns changed events too.
--    A change is seen when the collector next re-reads the event, not when Ticketmaster makes it.
--    Nothing is logged for what happened before this migration.
--
-- 2. SEARCH. v_tm_discovery_feed gains `search_text` as its last column: the event's name, its
--    teams or performers, venue and city, lower case, accents removed. GET /tm/events?q= matches
--    every word of the query against it. The column is for filtering and is not returned.
--
-- Read-only towards Ticketmaster: nothing here calls it or any other site (RULE 2).
-- The table is created everywhere; the trigger and the views only where tm_discovery_event
-- exists (its migration, 20261117180000, is live on prod but not on main).
--
-- rollback: DROP TRIGGER tm_discovery_event_log_change ON public.tm_discovery_event;
--           DROP VIEW public.v_tm_discovery_changes; re-apply v_tm_discovery_feed from
--           20261118223540 after DROP VIEW (a view cannot lose a column in place);
--           tm_discovery_change may stay, nothing else reads it.

CREATE TABLE IF NOT EXISTS public.tm_discovery_change (
  change_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tm_event_id text NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('status_changed', 'date_changed', 'time_changed', 'venue_changed')),
  old_value   text,
  new_value   text,
  detected_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tm_discovery_change_event_idx ON public.tm_discovery_change (tm_event_id, detected_at);
CREATE INDEX IF NOT EXISTS tm_discovery_change_detected_idx ON public.tm_discovery_change (detected_at);
ALTER TABLE public.tm_discovery_change ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tm_discovery_change FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.tm_discovery_change TO service_role;

CREATE OR REPLACE FUNCTION public.tm_discovery_event_log_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  INSERT INTO public.tm_discovery_change (tm_event_id, kind, old_value, new_value)
  SELECT NEW.tm_event_id, k.kind, k.old_value, k.new_value
    FROM (VALUES
      ('status_changed', OLD.status_code, NEW.status_code,
         OLD.status_code IS DISTINCT FROM NEW.status_code),
      ('date_changed',
         CASE WHEN coalesce(OLD.date_tbd, false) THEN 'TBD' ELSE OLD.local_date::text END,
         CASE WHEN coalesce(NEW.date_tbd, false) THEN 'TBD' ELSE NEW.local_date::text END, NULL),
      ('time_changed',
         CASE WHEN coalesce(OLD.time_tba, false) THEN 'TBA' ELSE coalesce(to_char(OLD.local_time, 'HH24:MI'), 'TBA') END,
         CASE WHEN coalesce(NEW.time_tba, false) THEN 'TBA' ELSE coalesce(to_char(NEW.local_time, 'HH24:MI'), 'TBA') END, NULL),
      ('venue_changed',
         nullif(concat_ws(', ', OLD.venue_name, OLD.venue_city, OLD.venue_state), ''),
         nullif(concat_ws(', ', NEW.venue_name, NEW.venue_city, NEW.venue_state), ''),
         OLD.tm_venue_id IS DISTINCT FROM NEW.tm_venue_id)
    ) k(kind, old_value, new_value, differs)
   -- date and time: by the value a reader sees; status and venue: by the stored id
   WHERE coalesce(k.differs, k.old_value IS DISTINCT FROM k.new_value);
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- the log must never stop the collector's write
  RAISE WARNING 'tm_discovery_event_log_change: % (%)', SQLERRM, SQLSTATE;
  RETURN NULL;
END
$function$;

REVOKE ALL ON FUNCTION public.tm_discovery_event_log_change() FROM PUBLIC, anon, authenticated;

DO $do$
DECLARE
  -- unaccent, in whichever schema it is installed (`public` on prod); where it is not installed
  -- the search keeps accents
  v_unaccent text := coalesce((SELECT quote_ident(n.nspname) || '.unaccent'
                                 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                WHERE p.proname = 'unaccent' AND p.pronargs = 1
                                  AND p.proargtypes[0] = 'text'::regtype
                                ORDER BY n.nspname LIMIT 1), '');
BEGIN
  IF to_regclass('public.tm_discovery_event') IS NULL THEN
    RAISE NOTICE 'tm_discovery_event is not here yet: the change trigger and the Ticketmaster views are not created';
    RETURN;
  END IF;

  EXECUTE $t$
    CREATE OR REPLACE TRIGGER tm_discovery_event_log_change
    AFTER UPDATE ON public.tm_discovery_event
    FOR EACH ROW
    WHEN (OLD.status_code IS DISTINCT FROM NEW.status_code OR OLD.local_date IS DISTINCT FROM NEW.local_date
          OR OLD.local_time IS DISTINCT FROM NEW.local_time OR OLD.date_tbd IS DISTINCT FROM NEW.date_tbd
          OR OLD.time_tba IS DISTINCT FROM NEW.time_tba OR OLD.tm_venue_id IS DISTINCT FROM NEW.tm_venue_id)
    EXECUTE FUNCTION public.tm_discovery_event_log_change()
  $t$;

  -- the feed as 20261118223540 left it, with `changed_at` moved by a detected change and
  -- `search_text` appended
  EXECUTE replace($v$
    CREATE OR REPLACE VIEW public.v_tm_discovery_feed
    WITH (security_invoker = true) AS
    SELECT e.tm_event_id,
           e.name,
           e.url AS ticket_url,
           e.local_date AS event_date,
           to_char(e.local_time, 'HH24:MI') AS start_local_time,
           e.start_utc,
           e.date_tbd,
           e.time_tba,
           e.status_code AS status,
           e.segment,
           e.genre,
           e.sub_genre,
           e.tm_venue_id,
           e.venue_name,
           e.venue_city,
           e.venue_state,
           e.venue_country,
           e.venue_timezone,
           e.attraction_names,
           e.public_onsale,
           e.presales,
           e.ticket_limit,
           coalesce(e.is_product, false) AS is_product,
           e.tevo_event_id,
           e.tevo_match_method,
           ev.name AS tevo_event_name,
           ev.occurs_at_local AS tevo_start_local,
           CASE WHEN e.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || e.tevo_event_id END AS terminal_path,
           e.first_seen_at,
           e.last_seen_at,
           greatest(e.first_seen_at, e.tevo_matched_at, ch.at) AS changed_at,
           -- ── everything else Ticketmaster returns for the event (mig 20261118223540) ──
           CASE WHEN e.raw->'sales'->'public'->>'endDateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'sales'->'public'->>'endDateTime')::timestamptz END AS public_onsale_end,
           tl.nums AS ticket_limit_numbers,
           CASE WHEN (SELECT count(DISTINCT n) FROM unnest(tl.nums) n) = 1 THEN tl.nums[1] END AS ticket_limit_count,
           coalesce(e.raw->'ticketing'->'safeTix'->>'enabled' = 'true', false) AS safetix,
           coalesce(e.raw->'ticketing'->'allInclusivePricing'->>'enabled' = 'true', false) AS all_in_pricing,
           CASE WHEN e.raw->'dates'->'end'->>'localDate' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                THEN (e.raw->'dates'->'end'->>'localDate')::date END AS end_date,
           left(e.raw->'dates'->'end'->>'localTime', 5) AS end_local_time,
           CASE WHEN e.raw->'dates'->'end'->>'dateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'dates'->'end'->>'dateTime')::timestamptz END AS end_utc,
           coalesce(e.raw->'dates'->>'spanMultipleDays' = 'true', false) AS spans_multiple_days,
           CASE WHEN e.raw->'dates'->'access'->>'startDateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'dates'->'access'->>'startDateTime')::timestamptz END AS access_start_utc,
           CASE WHEN e.raw->'dates'->'access'->>'endDateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'dates'->'access'->>'endDateTime')::timestamptz END AS access_end_utc,
           left(e.raw->'doorsTimes'->>'localTime', 5) AS doors_local_time,
           CASE WHEN e.raw->'doorsTimes'->>'dateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'doorsTimes'->>'dateTime')::timestamptz END AS doors_utc,
           e.raw->>'pleaseNote' AS please_note,
           e.raw->>'info' AS info,
           e.raw->>'description' AS description,
           e.raw->'linkMoreInfo'->>'url' AS more_info_url,
           e.raw->'ticketTextLines'->'en-us' AS ticket_text,
           e.raw->'classifications'->0->'type'->>'name' AS classification_type,
           e.raw->'classifications'->0->'subType'->>'name' AS classification_sub_type,
           (e.raw->'classifications'->0->>'family' = 'true') AS family,
           (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                     'id', a->>'id', 'name', a->>'name', 'url', a->>'url',
                     'upcoming_events', CASE WHEN a->'upcomingEvents'->>'_total' ~ '^[0-9]+$' THEN (a->'upcomingEvents'->>'_total')::int END,
                     'links', a->'externalLinks')))
              FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.raw->'_embedded'->'attractions') = 'array'
                                             THEN e.raw->'_embedded'->'attractions' ELSE '[]'::jsonb END) a) AS attractions,
           (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                     'id', p->>'id', 'name', p->>'name', 'url', p->>'url', 'type', p->>'type')))
              FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.raw->'products') = 'array'
                                             THEN e.raw->'products' ELSE '[]'::jsonb END) p) AS products,
           v.v->'address'->>'line1' AS venue_address,
           v.v->>'postalCode' AS venue_postal_code,
           CASE WHEN v.v->'location'->>'latitude' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v.v->'location'->>'latitude')::numeric END AS venue_latitude,
           CASE WHEN v.v->'location'->>'longitude' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v.v->'location'->>'longitude')::numeric END AS venue_longitude,
           v.v->>'url' AS venue_url,
           (SELECT jsonb_agg(mk->>'name') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v.v->'markets') = 'array'
                                                                     THEN v.v->'markets' ELSE '[]'::jsonb END) mk) AS venue_markets,
           CASE WHEN v.v->'upcomingEvents'->>'_total' ~ '^[0-9]+$' THEN (v.v->'upcomingEvents'->>'_total')::int END AS venue_upcoming_events,
           v.v->'boxOfficeInfo' AS venue_box_office,
           v.v->>'parkingDetail' AS venue_parking,
           v.v->'generalInfo' AS venue_general_info,
           v.v->>'accessibleSeatingDetail' AS venue_accessible_seating,
           v.v->'ada' AS venue_ada,
           -- what `q` searches: name, teams or performers, venue and city, lower case, accents removed
           lower(@UNACCENT@(concat_ws(' ', e.name, array_to_string(e.attraction_names, ' '), e.venue_name, e.venue_city))) AS search_text
      FROM public.tm_discovery_event e
      LEFT JOIN public.events ev ON ev.id = e.tevo_event_id
      -- the last change we detected to its status, date, time or venue (tm_discovery_change)
      LEFT JOIN (SELECT c.tm_event_id, max(c.detected_at) AS at
                   FROM public.tm_discovery_change c GROUP BY c.tm_event_id) ch ON ch.tm_event_id = e.tm_event_id
      LEFT JOIN LATERAL (SELECT e.raw->'_embedded'->'venues'->0 AS v) v ON true
      -- the numbers in Ticketmaster's ticket-limit sentence, in the order it gives them
      LEFT JOIN LATERAL (SELECT array_agg(coalesce(mt[1], mt[2], mt[3])::int) AS nums
                           FROM regexp_matches(e.ticket_limit,
                                  '([0-9]{1,3})\)?\s*-?\s*ticket limit|ticket limits? of ([0-9]{1,3})|limit of ([0-9]{1,3})', 'gi') mt) tl ON true
     WHERE e.local_date >= CURRENT_DATE - 1
  $v$, '@UNACCENT@', v_unaccent);

  EXECUTE $v$
    CREATE OR REPLACE VIEW public.v_tm_discovery_changes
    WITH (security_invoker = true) AS
    SELECT c.change_id,
           c.detected_at,
           c.kind,
           c.old_value,
           c.new_value,
           c.tm_event_id,
           e.name,
           e.local_date AS event_date,
           to_char(e.local_time, 'HH24:MI') AS start_local_time,
           e.status_code AS status,
           e.segment,
           e.venue_name,
           e.venue_city,
           e.venue_state,
           e.url AS ticket_url,
           e.tevo_event_id
      FROM public.tm_discovery_change c
      LEFT JOIN public.tm_discovery_event e ON e.tm_event_id = c.tm_event_id
  $v$;

  EXECUTE 'REVOKE ALL ON public.v_tm_discovery_feed, public.v_tm_discovery_changes FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT SELECT ON public.v_tm_discovery_feed, public.v_tm_discovery_changes TO service_role';
END
$do$;

NOTIFY pgrst, 'reload schema';
