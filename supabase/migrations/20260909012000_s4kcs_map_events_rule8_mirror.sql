-- Migration 20260909012000 · level:data-collection · lane:A1 · writes:s4kcs_orders · reads:s4kcs_orders,aq_event_map,events,vivid_orders,tickpick_orders · pre:20260909004500
--
-- NOT YET APPLIED TO PROD — authored and dry-run verified, awaiting the Rule 1
-- operator go-ahead. Every other migration on this branch carries an "Already
-- applied" line; this one deliberately does not.
--
-- s4kcs_map_events() RULE 8 — map CRM orders against the `events` MIRROR
-- directly, instead of only through the hub.
--
-- WHY. Rules 1-7 all read `aq_event_map`. That is the whole problem: an event
-- can be sitting in our own `events` mirror, carrying its TEvo id, at a venue
-- we can already resolve, on the right date — and still be unmappable, because
-- no hub row exists for it. Worked example, measured 2026-09-08:
--
--     CRM  "Florida Panthers vs. Minnesota Wild"  2026-10-10  Amerant Bank Arena
--     mirror  events.id 3438665  "Minnesota Wild at Florida Panthers (Home Opener)"
--             venue_id 1085      occurs_at_local 2026-10-10
--     hub  aq_event_map rows at venue 1085 on that date carrying a tevo id: ZERO
--
-- 12 CRM orders, the event in hand, and nothing could reach it. The hub is a
-- cross-source join table, not a census of TEvo — it only ever gains a row when
-- some source pipeline seeds one. `link_aq_tevo_from_events()` goes the other
-- way (mirror -> hub) but only fills hub rows that ALREADY EXIST with a NULL
-- tevo_event_id; it cannot invent one. So orders for a mirror-known event with
-- no hub row at all were unreachable by every rule in this function.
--
-- WHAT IT MATCHES. Resolved venue id + local date + the SAME name guard rules 6
-- and 7 already use (aq_name_consistent + the vs/at >= 2-shared-token floor),
-- then an ambiguity guard. Overwhelmingly it is HOME/AWAY INVERSION — the CRM
-- writes the home team first with "vs.", TEvo writes the away team first with
-- "at", and the venue settles which is which:
--     CRM "Tampa Bay Lightning vs. Washington Capitals"
--     TEvo "Washington Capitals at Tampa Bay Lightning (Home Opener)"
--     CRM "Los Angeles Lakers vs. Miami Heat"
--     TEvo "Miami Heat at Los Angeles Lakers"
-- plus support-act suffixes ("Bruno Mars" -> "Bruno Mars with RAYE and Anderson
-- .Paak"), sponsor prefixes ("Ryan Garcia vs Conor Benn" -> "WBC - ..."),
-- accents ("Carin Leon" via unaccent), and venue aliases ("Moda Center -
-- Complex" -> "Moda Center at the Rose Quarter").
--
-- THE ORDER OF THE TWO GUARDS IS LOAD-BEARING. Name guard FIRST, then require
-- exactly one survivor. Requiring one raw candidate at the venue+date instead
-- would throw away every correct match at an arena with a second event that
-- night — Washington Capitals at Tampa Bay shares 2026-10-03 with "Los Tigres
-- del Norte", and Utah Mammoth at Colorado shares 2026-09-20 with "Billy
-- Strings". The name guard removes those, one survives, and the match is safe.
--
-- WHAT THE AMBIGUITY GUARD CORRECTLY REFUSES: 59 orders, nearly all US Open
-- tennis, where TEvo's session numbering does not agree with the CRM's --
--     CRM  "2026 US Open Tennis Championships - Session 19"   2026-09-08
--     TEvo  Sessions 20, 21 and 22 all on that date at Arthur Ashe
-- Several survive the token guard, none is distinguishable, so none is taken.
-- That is the right answer: PROJECT_BIBLE §3 records that date matching without
-- a second axis is what bound a Forrest Frank concert to a Knicks game.
--
-- KEYED ON THE REAL PK. The uniqueness check groups by (source, s4k_order_id),
-- which is s4kcs_orders' primary key. s4k_order_id alone is NOT unique across
-- sources.
--
-- NO TIMEZONE LANDMINE HERE. §3 records that aq_event_map.event_date mixes time
-- zones, which is why a venue-id+date hub join was designed, measured and then
-- ABANDONED. This rule joins `events.occurs_at_local`, which is local by
-- definition and therefore in the same frame as s4kcs_orders.event_date. The
-- landmine is specific to the hub column; it does not transfer.
--
-- state = 'shown' only: 'ignored' (286 rows) is TEvo's not-for-sale marker.
--
-- MEASURED (2026-09-08, dry run): 168 orders across 69 distinct events, 59
-- dropped ambiguous. All 78 (crm_name, tevo_name) pairs were read individually
-- before this was authored; every one is the same real event.
--
-- COST: one extra temp table and one indexed join, inside a function that
-- already builds two. Bounded to current_date - 7 days, same window as rule 6.
--
-- REVERSIBLE — the fills are tagged, so they can be unbound precisely:
--   UPDATE public.s4kcs_orders SET tevo_event_id = NULL, map_method = NULL,
--          map_confidence = NULL, mapped_at = NULL
--    WHERE map_method = 'mirror_venue_id_date_nameguard';
--   -- then re-apply the prior definition (this file minus RULE 8).

CREATE OR REPLACE FUNCTION public.s4kcs_map_events()
 RETURNS TABLE(method text, orders_mapped integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = v.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, v.aq_short_event_id),
         map_method = 'order_id_vivid', map_confidence = 1.00, mapped_at = now()
    FROM public.vivid_orders v
   WHERE s.source = 'Vivid Seats'
     AND v.vivid_order_id = s.s4k_order_id
     AND v.tevo_event_id IS NOT NULL
     AND s.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'order_id_vivid'::text, v_n;

  UPDATE public.s4kcs_orders s
     SET tevo_event_id = t.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, t.aq_short_event_id),
         map_method = 'order_id_tickpick', map_confidence = 1.00, mapped_at = now()
    FROM public.tickpick_orders t
   WHERE s.source = 'TickPick'
     AND t.tp_order_id = s.s4k_order_id
     AND t.tevo_event_id IS NOT NULL
     AND s.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'order_id_tickpick'::text, v_n;

  WITH cand AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date AS d,
           lower(trim(a.venue_name)) AS vk,
           min(a.tevo_event_id) AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.event_name IS NOT NULL
       AND a.event_date IS NOT NULL AND a.venue_name IS NOT NULL
     GROUP BY 1,2,3
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'name_date_venue', map_confidence = 0.98, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND regexp_replace(lower(s.event_name), '[^a-z0-9]+', '', 'g') = c.nk
     AND s.event_date = c.d
     AND lower(trim(s.venue_name)) = c.vk;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'name_date_venue'::text, v_n;

  WITH cand AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date AS d,
           min(a.tevo_event_id) AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.event_name IS NOT NULL AND a.event_date IS NOT NULL
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'name_date', map_confidence = 0.92, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND regexp_replace(lower(s.event_name), '[^a-z0-9]+', '', 'g') = c.nk
     AND s.event_date = c.d;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'name_date'::text, v_n;

  WITH cand AS (
    SELECT lower(trim(a.venue_name)) AS vk,
           a.event_date::date AS d,
           min(a.tevo_event_id)     AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id,
           min(a.event_name)        AS hub_name
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.venue_name IS NOT NULL
       AND a.event_date IS NOT NULL
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'venue_date_nameguard', map_confidence = 0.95, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND lower(trim(split_part(s.venue_name, ' - ', 1))) = c.vk
     AND s.event_date = c.d
     AND s.event_name NOT ILIKE '%parking%'
     AND COALESCE(s.venue_name, '') NOT ILIKE '%parking%'
     AND public.aq_name_consistent(c.hub_name, s.event_name)
     AND (
       NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
             AND (c.hub_name  ILIKE '% vs%' OR c.hub_name  ILIKE '% at %') )
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(s.event_name,'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(c.hub_name,'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           ) q(tok) WHERE length(tok) >= 4) >= 2
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venue_date_nameguard'::text, v_n;

  DROP TABLE IF EXISTS _vr;
  CREATE TEMP TABLE _vr ON COMMIT DROP AS
    SELECT v_raw,
           public.cross_source_venue_resolve(
             split_part(v_raw, ' - ', 1), NULL,
             (regexp_match(v_raw, '[,-]\s*([A-Za-z]{2})\s*$'))[1]) AS vid
      FROM (
        SELECT DISTINCT a.venue_name AS v_raw
          FROM public.aq_event_map a
         WHERE a.tevo_event_id IS NOT NULL AND a.venue_name IS NOT NULL
           AND a.event_date >= current_date - interval '7 days'
        UNION
        SELECT DISTINCT s.venue_name
          FROM public.s4kcs_orders s
         WHERE s.tevo_event_id IS NULL AND s.venue_name IS NOT NULL
           AND s.event_date >= current_date - interval '7 days'
      ) u;
  DELETE FROM _vr WHERE vid IS NULL;
  CREATE INDEX ON _vr (v_raw);
  CREATE INDEX ON _vr (vid);
  ANALYZE _vr;

  DROP TABLE IF EXISTS _hub6;
  CREATE TEMP TABLE _hub6 ON COMMIT DROP AS
    SELECT r.vid,
           a.event_date::date AS d,
           min(a.tevo_event_id)     AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id,
           min(a.event_name)        AS hub_name
      FROM public.aq_event_map a
      JOIN _vr r ON r.v_raw = a.venue_name
     WHERE a.tevo_event_id IS NOT NULL
       AND a.event_date >= current_date - interval '7 days'
       AND a.venue_name NOT ILIKE '%parking%'
       AND a.event_name NOT ILIKE '%parking%'
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1;
  CREATE INDEX ON _hub6 (vid, d);
  ANALYZE _hub6;

  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'venue_id_date_nameguard', map_confidence = 0.94, mapped_at = now()
    FROM _vr r
    JOIN _hub6 c ON c.vid = r.vid
   WHERE s.tevo_event_id IS NULL
     AND s.event_date >= current_date - interval '7 days'
     AND r.v_raw = s.venue_name
     AND s.event_date = c.d
     AND s.event_name NOT ILIKE '%parking%'
     AND COALESCE(s.venue_name, '') NOT ILIKE '%parking%'
     AND public.aq_name_consistent(public.unaccent(c.hub_name), public.unaccent(s.event_name))
     AND (
       NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
             AND (c.hub_name  ILIKE '% vs%' OR c.hub_name  ILIKE '% at %') )
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(s.event_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(c.hub_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           ) q(tok) WHERE length(tok) >= 4) >= 2
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venue_id_date_nameguard'::text, v_n;

  WITH cand AS (
    SELECT lower(regexp_replace(a.venue_name, '[^a-z0-9]+', '', 'gi')) AS vc,
           a.event_date::date AS d,
           min(a.tevo_event_id)     AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id,
           min(a.event_name)        AS hub_name
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.venue_name IS NOT NULL
       AND a.event_date IS NOT NULL
       AND a.venue_name NOT ILIKE '%parking%'
       AND a.event_name NOT ILIKE '%parking%'
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'venue_canon_date_nameguard', map_confidence = 0.93, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND lower(regexp_replace(split_part(s.venue_name, ' - ', 1), '[^a-z0-9]+', '', 'gi')) = c.vc
     AND s.event_date = c.d
     AND s.event_name NOT ILIKE '%parking%'
     AND COALESCE(s.venue_name, '') NOT ILIKE '%parking%'
     AND public.aq_name_consistent(public.unaccent(c.hub_name), public.unaccent(s.event_name))
     AND (
       NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
             AND (c.hub_name  ILIKE '% vs%' OR c.hub_name  ILIKE '% at %') )
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(s.event_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(c.hub_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           ) q(tok) WHERE length(tok) >= 4) >= 2
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venue_canon_date_nameguard'::text, v_n;

  -- ------------------------------------------------------------- RULE 8 ---
  -- Order -> the `events` MIRROR directly, on resolved venue id + LOCAL date.
  -- Rules 1-7 all read the hub (aq_event_map); this one does not. See header.
  DROP TABLE IF EXISTS _mir8;
  CREATE TEMP TABLE _mir8 ON COMMIT DROP AS
    SELECT s.source, s.s4k_order_id, e.id AS tevo_event_id
      FROM public.s4kcs_orders s
      JOIN _vr r ON r.v_raw = s.venue_name
      JOIN public.events e
        ON e.venue_id = r.vid
       -- occurs_at_local is TEXT and LOCAL: same frame as s4kcs_orders.event_date,
       -- so this join does NOT inherit the aq_event_map mixed-timezone landmine.
       AND left(e.occurs_at_local, 10)::date = s.event_date
     WHERE s.tevo_event_id IS NULL
       AND s.event_date >= current_date - interval '7 days'
       AND e.state = 'shown'
       AND s.event_name NOT ILIKE '%parking%'
       AND COALESCE(s.venue_name, '') NOT ILIKE '%parking%'
       AND e.name NOT ILIKE '%parking%'
       AND s.event_name !~* 'season tickets?'
       AND s.event_name !~* '(cancelled|if necessary|\(date tbd\))'
       AND public.aq_name_consistent(public.unaccent(e.name), public.unaccent(s.event_name))
       AND (
         NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
               AND (e.name    ILIKE '% vs%' OR e.name    ILIKE '% at %') )
         OR (SELECT count(*) FROM (
               SELECT unnest(string_to_array(trim(regexp_replace(lower(
                        regexp_replace(public.unaccent(s.event_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
               INTERSECT
               SELECT unnest(string_to_array(trim(regexp_replace(lower(
                        regexp_replace(public.unaccent(e.name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             ) q(tok) WHERE length(tok) >= 4) >= 2
       );
  CREATE INDEX ON _mir8 (source, s4k_order_id);
  ANALYZE _mir8;

  -- Ambiguity guard AFTER the name guard: an order maps only if exactly ONE
  -- mirror event at its venue+date survives. Keyed on the real PK
  -- (source, s4k_order_id) -- s4k_order_id alone is NOT unique across sources.
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = u.tevo_event_id,
         map_method = 'mirror_venue_id_date_nameguard', map_confidence = 0.94,
         mapped_at = now()
    FROM (
      SELECT source, s4k_order_id, min(tevo_event_id) AS tevo_event_id
        FROM _mir8
       GROUP BY 1, 2
      HAVING count(DISTINCT tevo_event_id) = 1
    ) u
   WHERE s.source = u.source
     AND s.s4k_order_id = u.s4k_order_id
     AND s.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'mirror_venue_id_date_nameguard'::text, v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.s4kcs_map_events() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_map_events() TO service_role;
