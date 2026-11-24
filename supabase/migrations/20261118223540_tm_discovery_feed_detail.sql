-- Migration 20261118223540 · level:data-collection · lane:D0 (outbound feed; reads the A1 mapping program's tables) · writes:v_tm_discovery_feed · reads:tm_discovery_event,events · pre:20261118220530
--
-- EVERYTHING TICKETMASTER RETURNS FOR AN EVENT, IN THE FEED.
-- Operator 2026-11-18, shown what Discovery returns beyond the first feed (SafeTix, on-sale end,
-- doors, notes, add-ons, venue detail, ticket limits): "add and push all of them out including buy
-- limits".
--
-- v_tm_discovery_feed keeps its 31 columns as they were and gains, after them, read from the
-- stored response (tm_discovery_event.raw):
--   buying     ticket_limit_numbers (the numbers in `ticket_limit`, Ticketmaster's own sentence,
--              in order), ticket_limit_count (the limit when the sentence gives exactly one:
--              "a 4 ticket limit for presales and an 8 ticket limit for public onsale" has two, so
--              it is null there and the sentence is the answer); safetix; all_in_pricing;
--              public_onsale_end
--   timing     end_date / end_local_time / end_utc, spans_multiple_days, access_start_utc /
--              access_end_utc, doors_local_time / doors_utc
--   text       please_note, info, description, more_info_url, ticket_text
--   class      classification_type, classification_sub_type, family
--   people     attractions [{id, name, url, upcoming_events, links}]
--   add-ons    products [{id, name, url, type}] (parking and upsells tied to the event)
--   venue      venue_address, venue_postal_code, venue_latitude / venue_longitude, venue_url,
--              venue_markets, venue_upcoming_events, venue_box_office, venue_parking,
--              venue_general_info, venue_accessible_seating, venue_ada
-- Discovery returns no prices and no inventory for these events (0 of 400 carry a price range),
-- so there is none to serve. A value that is not in the expected shape reads as null: one odd
-- response cannot break the feed.
--
-- Read-only: nothing here calls Ticketmaster (RULE 2). Created only where tm_discovery_event
-- exists, as 20261118220530.
--
-- rollback: re-apply v_tm_discovery_feed from 20261118220530 after DROP VIEW (a view cannot lose
--           columns in place); nothing else reads the new columns.

DO $do$
BEGIN
  IF to_regclass('public.tm_discovery_event') IS NULL THEN
    RAISE NOTICE 'tm_discovery_event is not here yet: the Ticketmaster feed view is not changed';
    RETURN;
  END IF;

  EXECUTE $v$
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
           greatest(e.first_seen_at, e.tevo_matched_at) AS changed_at,
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
           v.v->'ada' AS venue_ada
      FROM public.tm_discovery_event e
      LEFT JOIN public.events ev ON ev.id = e.tevo_event_id
      LEFT JOIN LATERAL (SELECT e.raw->'_embedded'->'venues'->0 AS v) v ON true
      -- the numbers in Ticketmaster's ticket-limit sentence, in the order it gives them
      LEFT JOIN LATERAL (SELECT array_agg(coalesce(mt[1], mt[2], mt[3])::int) AS nums
                           FROM regexp_matches(e.ticket_limit,
                                  '([0-9]{1,3})\)?\s*-?\s*ticket limit|ticket limits? of ([0-9]{1,3})|limit of ([0-9]{1,3})', 'gi') mt) tl ON true
     WHERE e.local_date >= CURRENT_DATE - 1
  $v$;

  EXECUTE 'REVOKE ALL ON public.v_tm_discovery_feed FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT SELECT ON public.v_tm_discovery_feed TO service_role';
END
$do$;

NOTIFY pgrst, 'reload schema';
