-- Migration 20261103210000 · level:data-collection · lane:A1 (AXS ingest + AQ hub) · writes:axs_venue_norm()(new),axs_venue_same()(new),axs_aq_venue_sync()(replaced),axs_export_match()(replaced: AXS→TEvo venue rule),axs_aq_tier_match()(replaced: tier1_5 via the venue directory),axs_venue_directory(bad TEvo / AQ venue links cleared and re-placed),aq_venue_map(axs_venue_id / tevo_venue_id cleared where wrong; new system_seed venues),axs_export_event(TEvo matches through a cleared venue link reset),axs_aq_event_xref(tier1_5 pairs through a changed venue reset),aq_event_map(axs_event_id written by those pairs cleared) · reads:venue_assets,axs_events,axs_catalog,td_match_results · pre:20261103190000
--
-- ============================================================================
-- AXS venue mapping fix (operator 2026-11-03, after the first venue sync:
-- {"minted":2943,"by_rule":{"geo":8,"name_city":13,"name_state":48,"tevo_bridge":372},
--  "to_place":3495,"still_unmapped":109,"mapped_existing":441,"attached_same_id":2}).
--
-- What was wrong
--   * The AXS venue → TEvo venue step (mig 20261103090000) accepted any venue_assets row within
--     150 m whatever its name. Next-door venues and rooms of one complex got the wrong TEvo venue
--     (Orpheum Theatre Minneapolis → Fillmore Minneapolis, Fox Tucson → Rialto, Broward Center →
--     its Au-Rene Theater, Infosys Theater → Madison Square Garden); tevo_bridge then carried that
--     into aq_venue_map, and 102 of the 109 unmapped venues were AXS venues whose (wrong) TEvo
--     venue's AQ venue was already claimed.
--   * AXS has duplicate venue ids for one building (Lumen Field, Capital One Arena, McKale Center,
--     Colonial Life Arena …); aq_venue_map.axs_venue_id holds one, so the second id stayed unmapped.
--
-- Fix
--   * axs_venue_same(a, b, city): same venue unless one is a room / area of the other
--     ("<room> at <X>" vs "<X>", "<X> - <area>" vs "<X>"), they are sibling rooms of one complex,
--     their venue types conflict (theater / amphitheater / arena / stadium / field / coliseum …), or
--     they share no distinctive word; a trailing city / state tag ("- Los Angeles", "-CA") is
--     ignored; "… Field at <stadium>" is the stadium. Scored on all 549 current pairs: rejects the
--     wrong ones above, accepts the real duplicates and renamings ("Opry House" / "Grand Ole Opry
--     House", "SAP Center at San Jose" / "SAP Center").
--   * AXS → TEvo venue: within 1 km AND axs_venue_same (no name-blind 150 m rule).
--   * axs_aq_venue_sync v2: tevo_bridge / geo / name_city also need axs_venue_same; a venue CLAIMS a
--     free AQ venue (aq_venue_map.axs_venue_id, one per AQ venue); a duplicate AXS id of a claimed
--     AQ venue SHARES it (axs_venue_directory.aq_venue_short_id, method 'shared_*'); the rest are
--     minted as before. Placement state is axs_venue_directory.aq_venue_short_id.
--   * tier1_5 (AXS venue → AQ venue + ±6 h) reads axs_venue_directory.aq_venue_short_id, so shared
--     duplicate ids reach their AQ events too.
--   * tier3 (similar venue name) and tier4 (coordinates) also need axs_venue_same between the AXS
--     venue and the AQ event's venue: EVO's tier4 takes any venue near the point, which pairs a show
--     in a side room with the main-hall event (Infosys Theater vs a Knicks game at MSG).
--   * Venues file 13 minted only because their real AQ venue was wrongly taken (or because they are
--     a duplicate AXS id) are re-queued; unused minted rows left behind are deleted.
--   * Cost: axs_venue_same costs ~0.7 ms a call on prod (60k same-city pairs = 44 s), so it is
--     declared COST 1000 and every candidate join first applies a raw trigram similarity >= 0.2
--     (all 436 pairs it accepted on the 549 real pairs score >= 0.30). The first editor run of this
--     file hit the role's 15-minute statement_timeout and rolled back, hence SET statement_timeout = 0.
--   * Clean-up, run here: TEvo links and AQ venue claims that fail axs_venue_same are cleared (with
--     the TEvo event matches and tier1_5 event pairings made through them; AQ ids those pairings
--     wrote are cleared only when no other source knows the id); then the venue sync re-places them.
--     The 15-minute pass re-matches the events.
-- Rollback: re-create axs_aq_venue_sync / axs_export_match / axs_aq_tier_match from mig 20261103190000;
--   DROP FUNCTION axs_venue_same(text,text,text,numeric), axs_venue_norm(text,text).
-- ============================================================================

-- The first run places ~3,500 venues; the SQL editor's role has statement_timeout = 15 min.
SET statement_timeout = 0;

-- normalised venue name: case, the/&/spelling variants, punctuation, and a trailing city / state tag
CREATE OR REPLACE FUNCTION public.axs_venue_norm(p_name text, p_city text DEFAULT NULL)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           lower(coalesce(p_name, '')),
           '’|''', '', 'g'),
           '\m(theatre)\M', 'theater', 'g'),
           '\m(amphitheatre)\M', 'amphitheater', 'g'),
           '\m(centre)\M', 'center', 'g'),
           '&', ' and ', 'g'),
           '\mfield house\M', 'fieldhouse', 'g'),
           '\s+', ' ', 'g'))
$$;

-- same venue? (not a room / area of the other, not a sibling room, names close enough)
CREATE OR REPLACE FUNCTION public.axs_venue_same(p_a text, p_b text, p_city text DEFAULT NULL, p_min numeric DEFAULT 0.5)
RETURNS boolean LANGUAGE sql IMMUTABLE COST 1000 SET search_path = public, extensions, pg_temp AS $$
  WITH c AS (SELECT lower(coalesce(p_city, '')) AS city),
  n AS (
    SELECT x.k, x.v,
           -- drop a trailing city / 2-letter state tag: "… - Los Angeles", "…-CA", "… - VA", "… Minneapolis"
           btrim(regexp_replace(regexp_replace(regexp_replace(x.v,
              '\s*-\s*[a-z]{2}$', ''),
              CASE WHEN c.city <> '' THEN '\s*-\s*' || regexp_replace(c.city, '([.()])', '\\\1', 'g') || '(,? [a-z]{2})?$' ELSE '$^' END, ''),
              '^the ', '')) AS s
      FROM c, (VALUES ('a', public.axs_venue_norm(p_a)), ('b', public.axs_venue_norm(p_b))) x(k, v)),
  p AS (
    SELECT (SELECT s FROM n WHERE k = 'a') AS a, (SELECT s FROM n WHERE k = 'b') AS b),
  q AS (
    SELECT a, b,
           CASE WHEN position(' at ' IN a) > 0 THEN split_part(a, ' at ', 1) END AS a_room,
           CASE WHEN position(' at ' IN a) > 0 THEN regexp_replace(substr(a, position(' at ' IN a) + 4), '^the ', '') END AS a_in,
           CASE WHEN position(' at ' IN b) > 0 THEN split_part(b, ' at ', 1) END AS b_room,
           CASE WHEN position(' at ' IN b) > 0 THEN regexp_replace(substr(b, position(' at ' IN b) + 4), '^the ', '') END AS b_in,
           CASE WHEN position(' - ' IN a) > 0 THEN split_part(a, ' - ', 1) END AS a_main,
           CASE WHEN position(' - ' IN a) > 0 THEN substr(a, position(' - ' IN a) + 3) END AS a_area,
           CASE WHEN position(' - ' IN b) > 0 THEN split_part(b, ' - ', 1) END AS b_main,
           CASE WHEN position(' - ' IN b) > 0 THEN substr(b, position(' - ' IN b) + 3) END AS b_area
      FROM p),
  w AS (SELECT q.*,
               ARRAY(SELECT t FROM unnest(regexp_split_to_array(a, '[^a-z0-9]+')) t
                      WHERE t IN ('theater','amphitheater','arena','stadium','field','coliseum','ballroom','pavilion','lounge','auditorium','fieldhouse')) AS ta,
               ARRAY(SELECT t FROM unnest(regexp_split_to_array(b, '[^a-z0-9]+')) t
                      WHERE t IN ('theater','amphitheater','arena','stadium','field','coliseum','ballroom','pavilion','lounge','auditorium','fieldhouse')) AS tb,
               ARRAY(SELECT t FROM unnest(regexp_split_to_array(a, '[^a-z0-9]+')) t
                      WHERE length(t) > 1 AND t NOT IN (SELECT unnest(regexp_split_to_array((SELECT city FROM c), '[^a-z0-9]+')))
                        AND t NOT IN ('the','of','and','at','theater','amphitheater','arena','stadium','field','hall','center',
                                      'club','ballroom','park','pavilion','lounge','house','music','live','concert','events','event',
                                      'performing','arts','auditorium','room','stage','venue','casino','resort','hotel','fieldhouse')) AS da,
               ARRAY(SELECT t FROM unnest(regexp_split_to_array(b, '[^a-z0-9]+')) t
                      WHERE length(t) > 1 AND t NOT IN (SELECT unnest(regexp_split_to_array((SELECT city FROM c), '[^a-z0-9]+')))
                        AND t NOT IN ('the','of','and','at','theater','amphitheater','arena','stadium','field','hall','center',
                                      'club','ballroom','park','pavilion','lounge','house','music','live','concert','events','event',
                                      'performing','arts','auditorium','room','stage','venue','casino','resort','hotel','fieldhouse')) AS db
          FROM q),
  r AS (SELECT * FROM w)
  SELECT CASE
    WHEN a = '' OR b = '' THEN false
    WHEN a = b THEN true
    -- "<room> at <X>" vs "<X>" (a "… Field at <stadium>" naming is the stadium itself)
    WHEN a_in IS NOT NULL AND b_in IS NULL AND similarity(a_in, b) >= 0.6 AND position(a_room IN b) = 0
         AND a_room !~ '\m(field|court)\M' THEN false
    WHEN b_in IS NOT NULL AND a_in IS NULL AND similarity(b_in, a) >= 0.6 AND position(b_room IN a) = 0
         AND b_room !~ '\m(field|court)\M' THEN false
    -- "<room A> at <X>" vs "<room B> at <X>"
    WHEN a_in IS NOT NULL AND b_in IS NOT NULL AND similarity(a_in, b_in) >= 0.4 AND similarity(a_room, b_room) < 0.5 THEN false
    -- "<X> - <area>" vs "<X>" / "<X> - <other area>"
    WHEN a_main IS NOT NULL AND b_main IS NULL AND similarity(a_main, b) >= 0.6 AND position(a_area IN b) = 0 THEN false
    WHEN b_main IS NOT NULL AND a_main IS NULL AND similarity(b_main, a) >= 0.6 AND position(b_area IN a) = 0 THEN false
    WHEN a_main IS NOT NULL AND b_main IS NOT NULL AND similarity(a_main, b_main) >= 0.6 AND similarity(a_area, b_area) < 0.5 THEN false
    -- "<room A> - <X>" vs "<room B> - <X>"
    WHEN a_main IS NOT NULL AND b_main IS NOT NULL AND similarity(a_area, b_area) >= 0.6 AND similarity(a_main, b_main) < 0.5 THEN false
    -- conflicting venue types (theater vs amphitheater, arena vs stadium …)
    WHEN cardinality(ta) > 0 AND cardinality(tb) > 0 AND NOT (ta && tb) THEN false
    -- no distinctive word in common ("Fox Tucson Theatre" vs "Rialto Theatre Tucson")
    WHEN cardinality(da) > 0 AND cardinality(db) > 0 AND NOT (da && db) THEN false
    -- one name contains the other on word boundaries ("Moda Center" / "Moda Center at the Rose Quarter",
    -- "Jack Trice Stadium" / "MidAmerican Energy Field at Jack Trice Stadium")
    WHEN (' ' || b || ' ') LIKE ('% ' || a || ' %') OR (' ' || a || ' ') LIKE ('% ' || b || ' %') THEN true
    ELSE similarity(a, b) >= p_min
  END FROM r
$$;

-- ---------------------------------------------------------------------------
-- venue sync v2: claim a free AQ venue, share a claimed one (duplicate AXS ids), or mint
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.axs_aq_venue_sync(p_mint boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_claimed int := 0; v_shared int := 0; v_attached int := 0; v_minted int := 0; v_left int := 0;
BEGIN
  DROP TABLE IF EXISTS _v, _best, _res;
  CREATE TEMP TABLE _v ON COMMIT DROP AS
  SELECT d.axs_venue_id::bigint AS axs_venue_id, d.venue_name, d.city, d.state,
         d.venue_lat, d.venue_lon, d.tevo_venue_id,
         regexp_replace(public.axs_venue_norm(d.venue_name), '^the ', '') AS norm
    FROM public.axs_venue_directory d
   WHERE d.country = 'US' AND d.axs_venue_id ~ '^\d+$' AND d.venue_name IS NOT NULL
     AND d.aq_venue_short_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map a WHERE a.axs_venue_id = d.axs_venue_id::bigint)
     AND EXISTS (SELECT 1 FROM public.axs_export_event x
                  WHERE x.venue_id = d.axs_venue_id::bigint AND x.gone_at IS NULL);

  -- candidate AQ venues (claimed or free), first rule then nearest
  CREATE TEMP TABLE _best ON COMMIT DROP AS
  WITH r1 AS (
    SELECT v.axs_venue_id, f.venue_short_id, 1 AS rk, 0 AS dist_m, 'tevo_bridge' AS method
      FROM _v v JOIN public.aq_venue_map f ON f.tevo_venue_id = v.tevo_venue_id
     WHERE public.axs_venue_same(v.venue_name, f.venue_name, v.city)),
  r2 AS (
    SELECT v.axs_venue_id, f.venue_short_id, 2 AS rk,
           round(111320 * sqrt(power(f.latitude - v.venue_lat, 2)
                 + power((f.longitude - v.venue_lon) * cos(radians(v.venue_lat)), 2)))::int AS dist_m,
           'geo' AS method
      FROM _v v JOIN public.aq_venue_map f
        ON v.venue_lat IS NOT NULL AND f.latitude IS NOT NULL
       AND f.latitude  BETWEEN v.venue_lat - 0.01 AND v.venue_lat + 0.01
       AND f.longitude BETWEEN v.venue_lon - 0.013 AND v.venue_lon + 0.013
     WHERE similarity(lower(f.venue_name), lower(v.venue_name)) >= 0.2
       AND public.axs_venue_same(v.venue_name, f.venue_name, v.city)),
  r3 AS (
    SELECT v.axs_venue_id, min(f.venue_short_id) AS venue_short_id, 3 AS rk, NULL::int AS dist_m, 'name_state' AS method
      FROM _v v JOIN public.aq_venue_map f
        ON regexp_replace(public.axs_venue_norm(f.venue_name), '^the ', '') = v.norm
       AND upper(f.state) = upper(v.state)
     GROUP BY v.axs_venue_id HAVING count(DISTINCT f.venue_short_id) = 1),
  r4 AS (
    SELECT DISTINCT ON (v.axs_venue_id) v.axs_venue_id, f.venue_short_id, 4 AS rk, NULL::int AS dist_m, 'name_city' AS method
      FROM _v v JOIN public.aq_venue_map f
        ON upper(f.state) = upper(v.state) AND lower(f.city) = lower(v.city)
     WHERE similarity(lower(f.venue_name), lower(v.venue_name)) >= 0.2
       AND public.axs_venue_same(v.venue_name, f.venue_name, v.city, 0.6)
     ORDER BY v.axs_venue_id, similarity(lower(f.venue_name), lower(v.venue_name)) DESC),
  allp AS (SELECT * FROM r1 UNION ALL SELECT * FROM r2 WHERE dist_m <= 1000 UNION ALL SELECT * FROM r3 UNION ALL SELECT * FROM r4)
  SELECT DISTINCT ON (axs_venue_id) * FROM allp ORDER BY axs_venue_id, rk, dist_m NULLS LAST, venue_short_id;

  CREATE TEMP TABLE _res (axs_venue_id bigint PRIMARY KEY, venue_short_id text, method text) ON COMMIT DROP;

  -- claim: a free AQ venue, one AXS venue each (earlier rule, nearer, lower id wins)
  WITH w AS (
    SELECT DISTINCT ON (b.venue_short_id) b.*
      FROM _best b JOIN public.aq_venue_map a ON a.venue_short_id = b.venue_short_id AND a.axs_venue_id IS NULL
     ORDER BY b.venue_short_id, b.rk, b.dist_m NULLS LAST, b.axs_venue_id),
  u AS (
    UPDATE public.aq_venue_map a
       SET axs_venue_id = w.axs_venue_id,
           latitude = coalesce(a.latitude, v.venue_lat), longitude = coalesce(a.longitude, v.venue_lon)
      FROM w JOIN _v v USING (axs_venue_id)
     WHERE a.venue_short_id = w.venue_short_id AND a.axs_venue_id IS NULL
    RETURNING a.axs_venue_id, a.venue_short_id, w.method)
  INSERT INTO _res SELECT axs_venue_id, venue_short_id, method FROM u;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;

  -- share: the AQ venue is already held by another AXS id and the names say it is the same building
  INSERT INTO _res
  SELECT b.axs_venue_id, b.venue_short_id, 'shared_' || b.method
    FROM _best b JOIN _v v USING (axs_venue_id) JOIN public.aq_venue_map a ON a.venue_short_id = b.venue_short_id
   WHERE NOT EXISTS (SELECT 1 FROM _res r WHERE r.axs_venue_id = b.axs_venue_id)
     AND a.axs_venue_id IS NOT NULL AND a.axs_venue_id <> b.axs_venue_id
     AND public.axs_venue_same(v.venue_name, a.venue_name, v.city, 0.6)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_shared = ROW_COUNT;

  IF p_mint THEN
    -- the generated id already exists for this same venue (same name + city): claim it
    WITH u AS (
      UPDATE public.aq_venue_map a
         SET axs_venue_id = v.axs_venue_id,
             latitude = coalesce(a.latitude, v.venue_lat), longitude = coalesce(a.longitude, v.venue_lon)
        FROM _v v
       WHERE a.venue_short_id = public.aq_venue_short_id(v.venue_name, v.city, v.state)
         AND a.axs_venue_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM _res r WHERE r.axs_venue_id = v.axs_venue_id)
         AND regexp_replace(public.axs_venue_norm(a.venue_name), '^the ', '') = v.norm
         AND lower(coalesce(a.city, '')) = lower(coalesce(v.city, ''))
      RETURNING a.axs_venue_id, a.venue_short_id)
    INSERT INTO _res SELECT axs_venue_id, venue_short_id, 'attached' FROM u ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_attached = ROW_COUNT;

    -- new AQ venues for the rest
    WITH todo AS (
      SELECT DISTINCT ON (public.aq_venue_short_id(v.venue_name, v.city, v.state))
             public.aq_venue_short_id(v.venue_name, v.city, v.state) AS venue_short_id, v.*
        FROM _v v
       WHERE NOT EXISTS (SELECT 1 FROM _res r WHERE r.axs_venue_id = v.axs_venue_id)
       ORDER BY public.aq_venue_short_id(v.venue_name, v.city, v.state), v.axs_venue_id),
    ins AS (
      INSERT INTO public.aq_venue_map (venue_short_id, venue_name, city, state, country, tevo_venue_id,
                                       axs_venue_id, latitude, longitude, aq_source, imported_at)
      SELECT t.venue_short_id, t.venue_name, t.city, upper(t.state), 'US',
             CASE WHEN t.tevo_venue_id IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tevo_venue_id = t.tevo_venue_id)
                  THEN t.tevo_venue_id END,
             t.axs_venue_id, t.venue_lat, t.venue_lon, 'system_seed', now()
        FROM todo t
      ON CONFLICT DO NOTHING
      RETURNING axs_venue_id, venue_short_id)
    INSERT INTO _res SELECT axs_venue_id, venue_short_id, 'minted' FROM ins ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_minted = ROW_COUNT;
  END IF;

  UPDATE public.axs_venue_directory d SET aq_venue_short_id = r.venue_short_id, aq_match_method = r.method
    FROM _res r WHERE d.axs_venue_id = r.axs_venue_id::text;

  SELECT count(*) INTO v_left FROM _v v WHERE NOT EXISTS (SELECT 1 FROM _res r WHERE r.axs_venue_id = v.axs_venue_id);
  RETURN jsonb_build_object('to_place', (SELECT count(*) FROM _v), 'claimed', v_claimed, 'shared', v_shared,
                            'attached_same_id', v_attached, 'minted', v_minted, 'still_unmapped', v_left,
                            'by_rule', (SELECT jsonb_object_agg(method, n) FROM (SELECT method, count(*) n FROM _res GROUP BY 1) s));
END $$;
REVOKE ALL ON FUNCTION public.axs_aq_venue_sync(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_aq_venue_sync(boolean) TO service_role;

-- AXS venue → TEvo venue: within 1 km AND the same venue by name
CREATE OR REPLACE FUNCTION public.axs_export_match(p_limit int DEFAULT 100000)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_venues  int := 0;
  v_vmatch  int := 0;
  v_events  int := 0;
  v_reset   int := 0;
  v_catalog int := 0;
  v_aq_venues    int := 0;
  v_aq_events    int := 0;
  v_aq_written   int := 0;
  v_aq_withdrawn int := 0;
  v_venue_sync   jsonb;
BEGIN
  -- 1. AXS venues seen in the export
  INSERT INTO public.axs_venue_directory AS d
         (axs_venue_id, venue_name, city, state, country, venue_lat, venue_lon, venue_postal_code,
          venue_address, events_seen, axs_ticketed_seen)
  SELECT x.venue_id::text, max(x.venue_name), max(x.venue_city), max(x.venue_state), max(x.venue_country),
         max(x.venue_lat), max(x.venue_lon), max(x.venue_postal_code), max(x.venue_address),
         count(*), count(*) FILTER (WHERE x.axs_ticketed)
    FROM public.axs_export_event x
   WHERE x.venue_id IS NOT NULL AND x.gone_at IS NULL
   GROUP BY x.venue_id
  ON CONFLICT (axs_venue_id) DO UPDATE SET
    venue_name = EXCLUDED.venue_name, city = EXCLUDED.city, state = EXCLUDED.state,
    country = EXCLUDED.country, venue_lat = EXCLUDED.venue_lat, venue_lon = EXCLUDED.venue_lon,
    venue_postal_code = EXCLUDED.venue_postal_code, venue_address = EXCLUDED.venue_address,
    events_seen = greatest(d.events_seen, EXCLUDED.events_seen),
    axs_ticketed_seen = greatest(d.axs_ticketed_seen, EXCLUDED.axs_ticketed_seen),
    last_seen_at = now();
  GET DIAGNOSTICS v_venues = ROW_COUNT;

  -- 2. unmapped AXS venues → TEvo venue
  WITH todo AS (
    SELECT d.axs_venue_id, d.venue_name, d.city, d.state, d.venue_lat, d.venue_lon,
           regexp_replace(regexp_replace(lower(d.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') AS norm
      FROM public.axs_venue_directory d
     WHERE d.tevo_venue_id IS NULL AND d.country = 'US'),
  geo AS (
    SELECT DISTINCT ON (t.axs_venue_id) t.axs_venue_id, a.tevo_venue_id,
           round(111320 * sqrt(power(a.latitude - t.venue_lat, 2)
                 + power((a.longitude - t.venue_lon) * cos(radians(t.venue_lat)), 2)))::int AS dist_m
      FROM todo t
      JOIN public.venue_assets a
        ON t.venue_lat IS NOT NULL AND a.latitude IS NOT NULL
       AND a.latitude  BETWEEN t.venue_lat - 0.01 AND t.venue_lat + 0.01
       AND a.longitude BETWEEN t.venue_lon - 0.013 AND t.venue_lon + 0.013
     WHERE similarity(lower(a.venue_name), lower(t.venue_name)) >= 0.2
       AND public.axs_venue_same(t.venue_name, a.venue_name, t.city)
     ORDER BY t.axs_venue_id,
              111320 * sqrt(power(a.latitude - t.venue_lat, 2)
                 + power((a.longitude - t.venue_lon) * cos(radians(t.venue_lat)), 2))),
  geo_ok AS (
    SELECT * FROM geo WHERE dist_m <= 1000),
  tv AS (   -- TEvo venues as named on upcoming events, with the state from venue_location
    SELECT DISTINCT e.venue_id,
           regexp_replace(regexp_replace(lower(e.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') AS norm,
           upper(btrim(reverse(split_part(reverse(e.venue_location), ',', 1)))) AS state
      FROM public.events e
     WHERE e.occurs_at_local >= to_char(now() - interval '1 day', 'YYYY-MM-DD') AND e.venue_id IS NOT NULL),
  byname AS (
    SELECT t.axs_venue_id, min(tv.venue_id) AS tevo_venue_id
      FROM todo t JOIN tv ON tv.norm = t.norm AND tv.state = upper(t.state)
     WHERE NOT EXISTS (SELECT 1 FROM geo_ok g WHERE g.axs_venue_id = t.axs_venue_id)
     GROUP BY t.axs_venue_id HAVING count(DISTINCT tv.venue_id) = 1),
  pick AS (
    SELECT axs_venue_id, tevo_venue_id, 'geo' AS method, dist_m FROM geo_ok
    UNION ALL
    SELECT axs_venue_id, tevo_venue_id, 'name_state', NULL FROM byname)
  UPDATE public.axs_venue_directory d
     SET tevo_venue_id = p.tevo_venue_id, match_method = p.method, match_distance_m = p.dist_m
    FROM pick p WHERE d.axs_venue_id = p.axs_venue_id;
  GET DIAGNOSTICS v_vmatch = ROW_COUNT;

  -- 3. a matched event whose date moved is matched again
  UPDATE public.axs_export_event x
     SET tevo_event_id = NULL, tevo_venue_id = NULL, match_method = NULL, matched_date = NULL, matched_at = NULL
   WHERE x.tevo_event_id IS NOT NULL AND x.matched_date IS DISTINCT FROM x.event_date_local;
  GET DIAGNOSTICS v_reset = ROW_COUNT;

  -- 4. AXS events → TEvo events: same mapped venue, same local date; time then title break ties
  WITH todo AS (
    SELECT x.axs_event_id, x.event_date_local, x.is_tba,
           coalesce(x.event_title_clean, x.event_title) AS title, d.tevo_venue_id
      FROM public.axs_export_event x
      JOIN public.axs_venue_directory d ON d.axs_venue_id = x.venue_id::text AND d.tevo_venue_id IS NOT NULL
     WHERE x.tevo_event_id IS NULL AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
     ORDER BY x.event_date_local
     LIMIT greatest(p_limit, 0)),
  cand AS (
    SELECT t.axs_event_id, t.event_date_local, e.id AS tevo_event_id, t.tevo_venue_id,
           count(*) OVER (PARTITION BY t.axs_event_id) AS n_same_day,
           CASE WHEN t.is_tba OR substr(e.occurs_at_local, 12, 5) !~ '^\d\d:\d\d$' THEN 0
                ELSE abs(extract(epoch FROM (substr(e.occurs_at_local, 12, 5)::time
                                             - substr(t.event_date_local, 12, 5)::time)) / 60) END AS dmin,
           similarity(lower(coalesce(e.primary_performer_name, '') || ' ' || coalesce(e.name, '')), lower(t.title)) AS sim
      FROM todo t
      JOIN public.events e ON e.venue_id = t.tevo_venue_id AND left(e.occurs_at_local, 10) = left(t.event_date_local, 10)
     WHERE coalesce(e.state, 'shown') <> 'ignored'),
  best_per_axs AS (
    SELECT DISTINCT ON (axs_event_id) * FROM cand
     WHERE n_same_day = 1 OR dmin <= 90 OR sim >= 0.3
     ORDER BY axs_event_id, dmin, sim DESC),
  best_per_tevo AS (   -- one AXS id per TEvo event, not already taken by another AXS id
    SELECT DISTINCT ON (b.tevo_event_id) b.*
      FROM best_per_axs b
     WHERE NOT EXISTS (SELECT 1 FROM public.axs_export_event o
                        WHERE o.tevo_event_id = b.tevo_event_id AND o.axs_event_id <> b.axs_event_id)
     ORDER BY b.tevo_event_id, b.sim DESC, b.dmin, b.axs_event_id)
  UPDATE public.axs_export_event x
     SET tevo_event_id = b.tevo_event_id, tevo_venue_id = b.tevo_venue_id,
         match_method = CASE WHEN b.n_same_day = 1 THEN 'venue_date' ELSE 'venue_date_time' END,
         matched_date = b.event_date_local, matched_at = now()
    FROM best_per_tevo b WHERE x.axs_event_id = b.axs_event_id;
  GET DIAGNOSTICS v_events = ROW_COUNT;

  -- 4b. AXS → AQ directly (no TEvo)
  --   (i) withdraw unpinned pairings whose AXS event moved off the AQ date or left AXS unplayed
  WITH moved AS (
    DELETE FROM public.axs_aq_event_xref p
     USING public.axs_export_event x, public.aq_event_map m
     WHERE p.axs_event_id = x.axs_event_id AND m.aq_short_event_id = p.aq_short_event_id
       AND NOT p.pinned
       AND (NOT public.axs_aq_time_ok(m.event_date, x.event_date_local)
            OR (x.gone_at IS NOT NULL AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')))
    RETURNING p.axs_event_id, p.aq_short_event_id)
  UPDATE public.aq_event_map m SET axs_event_id = NULL
    FROM moved v
   WHERE m.aq_short_event_id = v.aq_short_event_id AND m.axs_event_id = v.axs_event_id::text;
  GET DIAGNOSTICS v_aq_withdrawn = ROW_COUNT;

  --   (ii) AXS venue → AQ venue: aq_venue_map.axs_venue_id (axs_aq_venue_sync)
  v_venue_sync := public.axs_aq_venue_sync(true);
  v_aq_venues := coalesce((v_venue_sync->>'mapped_existing')::int, 0) + coalesce((v_venue_sync->>'attached_same_id')::int, 0)
               + coalesce((v_venue_sync->>'minted')::int, 0);

  --   (iii) AXS event → AQ event: the same tiers match_to_aq_event_id uses for EVO
  v_aq_events := coalesce((public.axs_aq_tier_match(greatest(p_limit, 0))->>'paired')::int, 0);

  --   (iv) write to aq_event_map: fill when empty (pinned pairings override); record conflicts
  UPDATE public.axs_aq_event_xref p SET conflict_axs_event_id = m.axs_event_id
    FROM public.aq_event_map m
   WHERE m.aq_short_event_id = p.aq_short_event_id AND NOT p.pinned
     AND m.axs_event_id IS NOT NULL AND m.axs_event_id <> p.axs_event_id::text
     AND p.conflict_axs_event_id IS DISTINCT FROM m.axs_event_id;
  UPDATE public.axs_aq_event_xref p SET axs_id_held_by = o.aq_short_event_id
    FROM public.aq_event_map o
   WHERE o.axs_event_id = p.axs_event_id::text AND o.aq_short_event_id <> p.aq_short_event_id
     AND NOT p.pinned AND p.axs_id_held_by IS DISTINCT FROM o.aq_short_event_id;
  UPDATE public.aq_event_map m SET axs_event_id = p.axs_event_id::text
    FROM public.axs_aq_event_xref p
   WHERE m.aq_short_event_id = p.aq_short_event_id
     AND m.axs_event_id IS DISTINCT FROM p.axs_event_id::text
     AND (m.axs_event_id IS NULL OR p.pinned)
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o
                      WHERE o.axs_event_id = p.axs_event_id::text AND o.aq_short_event_id <> m.aq_short_event_id);
  GET DIAGNOSTICS v_aq_written = ROW_COUNT;

  -- 5. catalogue feed (every live US upcoming export event)
  INSERT INTO public.axs_catalog AS c
         (axs_event_id, event_url, source, tevo_event_id, event_name, venue_name, event_date,
          axs_ticketed, axs_venue_id)
  SELECT x.axs_event_id::text, coalesce(x.event_url, 'https://www.axs.com/events/' || x.axs_event_id),
         'axs_export', x.tevo_event_id, x.event_title, x.venue_name,
         left(x.event_date_local, 10)::date, x.axs_ticketed, x.venue_id::text
    FROM public.axs_export_event x
   WHERE x.gone_at IS NULL AND x.venue_country = 'US'
     AND x.event_date_local ~ '^\d{4}-\d\d-\d\d' AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
  ON CONFLICT (axs_event_id) DO UPDATE SET
    tevo_event_id = CASE WHEN c.source = 'axs_export' THEN EXCLUDED.tevo_event_id
                         ELSE coalesce(EXCLUDED.tevo_event_id, c.tevo_event_id) END,
    axs_ticketed  = EXCLUDED.axs_ticketed,
    axs_venue_id  = coalesce(EXCLUDED.axs_venue_id, c.axs_venue_id),
    event_date    = EXCLUDED.event_date,
    event_name    = coalesce(c.event_name, EXCLUDED.event_name),
    venue_name    = coalesce(c.venue_name, EXCLUDED.venue_name),
    last_seen_at  = now();
  GET DIAGNOSTICS v_catalog = ROW_COUNT;

  -- export-sourced catalogue rows whose event left AXS (or was played) go
  DELETE FROM public.axs_catalog c
   WHERE c.source = 'axs_export'
     AND NOT EXISTS (SELECT 1 FROM public.axs_export_event x
                      WHERE x.axs_event_id::text = c.axs_event_id AND x.gone_at IS NULL);

  RETURN jsonb_build_object('venues_seen', v_venues, 'venues_mapped_now', v_vmatch,
                            'events_rematched', v_reset, 'events_matched_now', v_events,
                            'aq_venues_mapped_now', v_aq_venues, 'aq_pairs_new', v_aq_events,
                            'aq_ids_written', v_aq_written, 'aq_pairs_withdrawn', v_aq_withdrawn,
                            'catalog_rows', v_catalog);
END $$;
REVOKE ALL ON FUNCTION public.axs_export_match(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_export_match(int) TO service_role;

-- tier1_5 via the AXS venue directory
CREATE OR REPLACE FUNCTION public.axs_aq_tier_match(p_limit int DEFAULT 100000)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_t1 int := 0; v_t15 int := 0; v_t2 int := 0; v_t3 int := 0; v_t4 int := 0; v_mint int := 0;
  v_mint_on boolean;
BEGIN
  SELECT aq_mint_missing INTO v_mint_on FROM public.axs_export_sync WHERE id = 1;
  DROP TABLE IF EXISTS _ax, _aq;

  -- unpaired live US AXS events
  CREATE TEMP TABLE _ax ON COMMIT DROP AS
  SELECT x.axs_event_id, x.event_date_local AS local_txt,
         left(x.event_date_local, 10)::date AS d,
         CASE WHEN x.event_date_local ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN left(x.event_date_local, 19)::timestamp
              ELSE left(x.event_date_local, 10)::timestamp END AS ts,
         x.venue_name, lower(btrim(x.venue_name)) AS vlow, x.venue_lat, x.venue_lon,
         d.aq_venue_short_id,
         coalesce(x.event_title_clean, x.event_title) AS title, x.headliner,
         x.venue_city, x.venue_state
    FROM public.axs_export_event x
    LEFT JOIN public.axs_venue_directory d ON d.axs_venue_id = x.venue_id::text
   WHERE x.gone_at IS NULL AND x.venue_country = 'US'
     AND x.event_date_local ~ '^\d{4}-\d\d-\d\d' AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
     AND NOT EXISTS (SELECT 1 FROM public.axs_aq_event_xref p WHERE p.axs_event_id = x.axs_event_id)
   ORDER BY x.event_date_local
   LIMIT greatest(p_limit, 0);
  CREATE INDEX ON _ax (d);

  -- AQ rows still free for an AXS id
  CREATE TEMP TABLE _aq ON COMMIT DROP AS
  SELECT m.aq_short_event_id, m.event_date AS ts, m.event_date::date AS d, m.venue_short_id,
         lower(btrim(m.venue_name)) AS vlow, m.axs_event_id
    FROM public.aq_event_map m
   WHERE m.event_date >= (now() - interval '1 day')::date
     AND NOT EXISTS (SELECT 1 FROM public.axs_aq_event_xref q WHERE q.aq_short_event_id = m.aq_short_event_id);
  CREATE INDEX ON _aq (d);

  -- tier1: the AXS id is already on the AQ row
  INSERT INTO public.axs_aq_event_xref (axs_event_id, aq_short_event_id, method, venue_how, confidence, n_candidates)
  SELECT DISTINCT ON (a.axs_event_id) a.axs_event_id, q.aq_short_event_id, 'tier1_direct_id', 'id', 1.00, 1
    FROM _ax a JOIN _aq q ON q.axs_event_id = a.axs_event_id::text
   ORDER BY a.axs_event_id, q.aq_short_event_id
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_t1 = ROW_COUNT;
  DELETE FROM _ax a USING public.axs_aq_event_xref p WHERE p.axs_event_id = a.axs_event_id;
  DELETE FROM _aq q USING public.axs_aq_event_xref p WHERE p.aq_short_event_id = q.aq_short_event_id;

  -- tier1_5: AXS venue → AQ venue, ±6 h, nearest time
  WITH c AS (
    SELECT a.axs_event_id, q.aq_short_event_id,
           CASE WHEN to_char(q.ts, 'HH24:MI') = '00:00' THEN NULL
                ELSE abs(extract(epoch FROM (q.ts - a.ts)) / 60)::int END AS dmin,
           count(*) OVER (PARTITION BY a.axs_event_id) AS n
      FROM _ax a JOIN _aq q ON q.d BETWEEN a.d - 1 AND a.d + 1
       AND q.venue_short_id = a.aq_venue_short_id
       AND public.axs_aq_time_ok(q.ts, a.local_txt)
     WHERE a.aq_venue_short_id IS NOT NULL AND q.axs_event_id IS NULL),
  b1 AS (SELECT DISTINCT ON (axs_event_id) * FROM c ORDER BY axs_event_id, dmin NULLS LAST, aq_short_event_id),
  b2 AS (SELECT DISTINCT ON (aq_short_event_id) * FROM b1 ORDER BY aq_short_event_id, dmin NULLS LAST, axs_event_id)
  INSERT INTO public.axs_aq_event_xref (axs_event_id, aq_short_event_id, method, venue_how, time_diff_min, confidence, n_candidates)
  SELECT axs_event_id, aq_short_event_id, 'tier1_5_venue_id_date', 'aq_venue', dmin, 0.93, n FROM b2
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_t15 = ROW_COUNT;
  DELETE FROM _ax a USING public.axs_aq_event_xref p WHERE p.axs_event_id = a.axs_event_id;
  DELETE FROM _aq q USING public.axs_aq_event_xref p WHERE p.aq_short_event_id = q.aq_short_event_id;

  -- tier2: exact venue name, ±6 h, nearest time
  WITH c AS (
    SELECT a.axs_event_id, q.aq_short_event_id,
           CASE WHEN to_char(q.ts, 'HH24:MI') = '00:00' THEN NULL
                ELSE abs(extract(epoch FROM (q.ts - a.ts)) / 60)::int END AS dmin,
           count(*) OVER (PARTITION BY a.axs_event_id) AS n
      FROM _ax a JOIN _aq q ON q.d BETWEEN a.d - 1 AND a.d + 1
       AND q.vlow = a.vlow
       AND public.axs_aq_time_ok(q.ts, a.local_txt)
     WHERE q.axs_event_id IS NULL),
  b1 AS (SELECT DISTINCT ON (axs_event_id) * FROM c ORDER BY axs_event_id, dmin NULLS LAST, aq_short_event_id),
  b2 AS (SELECT DISTINCT ON (aq_short_event_id) * FROM b1 ORDER BY aq_short_event_id, dmin NULLS LAST, axs_event_id)
  INSERT INTO public.axs_aq_event_xref (axs_event_id, aq_short_event_id, method, venue_how, time_diff_min, confidence, n_candidates)
  SELECT axs_event_id, aq_short_event_id, 'tier2_venue_exact_date', 'venue_name', dmin, 0.95, n FROM b2
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_t2 = ROW_COUNT;
  DELETE FROM _ax a USING public.axs_aq_event_xref p WHERE p.axs_event_id = a.axs_event_id;
  DELETE FROM _aq q USING public.axs_aq_event_xref p WHERE p.aq_short_event_id = q.aq_short_event_id;

  -- tier3: venue name similarity >= 0.7, ±6 h, most similar then nearest
  WITH c AS (
    SELECT a.axs_event_id, q.aq_short_event_id,
           CASE WHEN to_char(q.ts, 'HH24:MI') = '00:00' THEN NULL
                ELSE abs(extract(epoch FROM (q.ts - a.ts)) / 60)::int END AS dmin,
           similarity(q.vlow, a.vlow) AS sim,
           count(*) OVER (PARTITION BY a.axs_event_id) AS n
      FROM _ax a JOIN _aq q ON q.d BETWEEN a.d - 1 AND a.d + 1
       AND similarity(coalesce(q.vlow, ''), coalesce(a.vlow, '')) >= 0.7
       AND public.axs_aq_time_ok(q.ts, a.local_txt)
       AND public.axs_venue_same(a.venue_name, q.vlow, a.venue_city)
     WHERE q.axs_event_id IS NULL),
  b1 AS (SELECT DISTINCT ON (axs_event_id) * FROM c ORDER BY axs_event_id, sim DESC, dmin NULLS LAST, aq_short_event_id),
  b2 AS (SELECT DISTINCT ON (aq_short_event_id) * FROM b1 ORDER BY aq_short_event_id, sim DESC, dmin NULLS LAST, axs_event_id)
  INSERT INTO public.axs_aq_event_xref (axs_event_id, aq_short_event_id, method, venue_how, time_diff_min, name_sim, confidence, n_candidates)
  SELECT axs_event_id, aq_short_event_id, 'tier3_venue_fuzzy_date', 'venue_name_fuzzy', dmin, round(sim::numeric, 3), 0.80, n FROM b2
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_t3 = ROW_COUNT;
  DELETE FROM _ax a USING public.axs_aq_event_xref p WHERE p.axs_event_id = a.axs_event_id;
  DELETE FROM _aq q USING public.axs_aq_event_xref p WHERE p.aq_short_event_id = q.aq_short_event_id;

  -- tier4: AQ venue coordinates (venue_assets by AQ venue name) near the AXS venue, ±6 h
  WITH c AS (
    SELECT a.axs_event_id, q.aq_short_event_id,
           CASE WHEN to_char(q.ts, 'HH24:MI') = '00:00' THEN NULL
                ELSE abs(extract(epoch FROM (q.ts - a.ts)) / 60)::int END AS dmin,
           2 * 6371000 * asin(sqrt(power(sin(radians((va.latitude - a.venue_lat) / 2)), 2)
             + cos(radians(a.venue_lat)) * cos(radians(va.latitude))
               * power(sin(radians((va.longitude - a.venue_lon) / 2)), 2))) AS dist_m,
           count(*) OVER (PARTITION BY a.axs_event_id) AS n
      FROM _ax a
      JOIN _aq q ON q.d BETWEEN a.d - 1 AND a.d + 1 AND public.axs_aq_time_ok(q.ts, a.local_txt)
      JOIN public.venue_assets va ON lower(btrim(va.venue_name)) = q.vlow
       AND va.latitude  BETWEEN a.venue_lat - 0.01 AND a.venue_lat + 0.01
       AND va.longitude BETWEEN a.venue_lon - 0.02 AND a.venue_lon + 0.02
     WHERE a.venue_lat IS NOT NULL AND q.axs_event_id IS NULL
       AND similarity(coalesce(q.vlow, ''), coalesce(a.vlow, '')) >= 0.2
       AND public.axs_venue_same(a.venue_name, q.vlow, a.venue_city)),
  b1 AS (SELECT DISTINCT ON (axs_event_id) * FROM c ORDER BY axs_event_id, dist_m, dmin NULLS LAST, aq_short_event_id),
  b2 AS (SELECT DISTINCT ON (aq_short_event_id) * FROM b1 ORDER BY aq_short_event_id, dist_m, dmin NULLS LAST, axs_event_id)
  INSERT INTO public.axs_aq_event_xref (axs_event_id, aq_short_event_id, method, venue_how, time_diff_min, confidence, n_candidates)
  SELECT axs_event_id, aq_short_event_id, 'tier4_coord_date', 'coords', dmin, 0.85, n FROM b2
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_t4 = ROW_COUNT;
  DELETE FROM _ax a USING public.axs_aq_event_xref p WHERE p.axs_event_id = a.axs_event_id;

  -- no hit: mint the AQ row (EVO's create_system_aq_event fallback; AXS id scheme from mig 20260610100000)
  IF v_mint_on THEN
    WITH ins AS (
      INSERT INTO public.aq_event_map
             (aq_short_event_id, event_name, venue_name, event_date, performer, city, state,
              venue_short_id, axs_event_id, category, aq_source, imported_at)
      SELECT 'AXS' || a.axs_event_id, a.title, a.venue_name, a.ts, a.headliner, a.venue_city, a.venue_state,
             a.aq_venue_short_id, a.axs_event_id::text, 'axs', 'axs', now()
        FROM _ax a
       WHERE NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.axs_event_id = a.axs_event_id::text)
      ON CONFLICT (aq_short_event_id) DO NOTHING
      RETURNING aq_short_event_id, axs_event_id)
    INSERT INTO public.axs_aq_event_xref (axs_event_id, aq_short_event_id, method, venue_how, confidence, n_candidates)
    SELECT axs_event_id::bigint, aq_short_event_id, 'minted', 'minted', 0.50, 0 FROM ins
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_mint = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object('paired', v_t1 + v_t15 + v_t2 + v_t3 + v_t4 + v_mint,
                            'tier1_direct_id', v_t1, 'tier1_5_venue_id_date', v_t15,
                            'tier2_venue_exact_date', v_t2, 'tier3_venue_fuzzy_date', v_t3,
                            'tier4_coord_date', v_t4, 'minted', v_mint,
                            'left_unpaired', (SELECT count(*) FROM _ax) - v_mint);
END $$;
REVOKE ALL ON FUNCTION public.axs_aq_tier_match(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_aq_tier_match(int) TO service_role;

-- ---------------------------------------------------------------------------
-- clean-up of the links the old rules made, then re-place the venues
-- ---------------------------------------------------------------------------
-- (a) AXS → TEvo venue links that fail the same-venue test
CREATE TEMP TABLE _bad_tevo AS
SELECT d.axs_venue_id, d.tevo_venue_id
  FROM public.axs_venue_directory d JOIN public.venue_assets a ON a.tevo_venue_id = d.tevo_venue_id
 WHERE d.match_method = 'geo' AND NOT public.axs_venue_same(d.venue_name, a.venue_name, d.city);
UPDATE public.axs_venue_directory d SET tevo_venue_id = NULL, match_method = NULL, match_distance_m = NULL
  FROM _bad_tevo b WHERE d.axs_venue_id = b.axs_venue_id;
UPDATE public.axs_export_event x
   SET tevo_event_id = NULL, tevo_venue_id = NULL, match_method = NULL, matched_date = NULL, matched_at = NULL
  FROM _bad_tevo b WHERE x.venue_id::text = b.axs_venue_id AND x.tevo_event_id IS NOT NULL;
-- an AQ venue minted on 2026-11-03 carrying such a wrong TEvo venue id loses it
UPDATE public.aq_venue_map a SET tevo_venue_id = NULL
  FROM _bad_tevo b
 WHERE a.axs_venue_id::text = b.axs_venue_id AND a.tevo_venue_id = b.tevo_venue_id
   AND a.aq_source = 'system_seed' AND a.imported_at >= '2026-11-03';

-- (b) AQ venue claims that fail the same-venue test
CREATE TEMP TABLE _bad_claim AS
SELECT d.axs_venue_id, a.venue_short_id
  FROM public.axs_venue_directory d JOIN public.aq_venue_map a ON a.axs_venue_id::text = d.axs_venue_id
 WHERE d.aq_match_method IN ('tevo_bridge', 'geo', 'name_state', 'name_city')
   AND NOT public.axs_venue_same(d.venue_name, a.venue_name, d.city);
UPDATE public.aq_venue_map a SET axs_venue_id = NULL
  FROM _bad_claim b WHERE a.venue_short_id = b.venue_short_id AND a.axs_venue_id::text = b.axs_venue_id;
UPDATE public.axs_venue_directory d SET aq_venue_short_id = NULL, aq_match_method = NULL
  FROM _bad_claim b WHERE d.axs_venue_id = b.axs_venue_id;

-- (b2) venues minted on 2026-11-03 whose AQ venue no event uses yet go back into the queue, so a
--      real AQ venue (freed in (b), or a duplicate AXS id's building) can claim / share them first;
--      the generated id is deterministic, so a venue with no better match re-claims its own row
CREATE TEMP TABLE _re_minted AS
SELECT d.axs_venue_id, a.venue_short_id
  FROM public.axs_venue_directory d JOIN public.aq_venue_map a ON a.axs_venue_id::text = d.axs_venue_id
 WHERE d.aq_match_method = 'minted' AND a.aq_source = 'system_seed' AND a.imported_at >= '2026-11-03'
   AND NOT EXISTS (SELECT 1 FROM public.aq_event_map m WHERE m.venue_short_id = a.venue_short_id);
UPDATE public.aq_venue_map a SET axs_venue_id = NULL
  FROM _re_minted r WHERE a.venue_short_id = r.venue_short_id;
UPDATE public.axs_venue_directory d SET aq_venue_short_id = NULL, aq_match_method = NULL
  FROM _re_minted r WHERE d.axs_venue_id = r.axs_venue_id;

-- (c) re-place every unplaced venue under the new rules
CREATE TEMP TABLE _sync AS SELECT public.axs_aq_venue_sync(true) AS r;

-- (c2) AQ venues minted today that no AXS venue holds and nothing references any more go
DELETE FROM public.aq_venue_map a
 USING _re_minted r
 WHERE a.venue_short_id = r.venue_short_id AND a.axs_venue_id IS NULL
   AND NOT EXISTS (SELECT 1 FROM public.axs_venue_directory d WHERE d.aq_venue_short_id = a.venue_short_id)
   AND NOT EXISTS (SELECT 1 FROM public.aq_event_map m WHERE m.venue_short_id = a.venue_short_id);

-- (d) tier1_5 event pairs made through an AQ venue that is no longer this AXS venue's
CREATE TEMP TABLE _bad_pair AS
SELECT p.axs_event_id, p.aq_short_event_id
  FROM public.axs_aq_event_xref p
  JOIN public.axs_export_event x ON x.axs_event_id = p.axs_event_id
  JOIN public.aq_event_map m ON m.aq_short_event_id = p.aq_short_event_id
  LEFT JOIN public.axs_venue_directory d ON d.axs_venue_id = x.venue_id::text
 WHERE NOT p.pinned AND p.method = 'tier1_5_venue_id_date'
   AND m.venue_short_id IS DISTINCT FROM d.aq_venue_short_id
UNION
SELECT p.axs_event_id, p.aq_short_event_id
  FROM public.axs_aq_event_xref p
  JOIN public.axs_export_event x ON x.axs_event_id = p.axs_event_id
  JOIN public.aq_event_map m ON m.aq_short_event_id = p.aq_short_event_id
 WHERE NOT p.pinned AND p.method IN ('tier3_venue_fuzzy_date', 'tier4_coord_date')
   AND NOT public.axs_venue_same(x.venue_name, m.venue_name, x.venue_city);
UPDATE public.aq_event_map m SET axs_event_id = NULL
  FROM _bad_pair b
 WHERE m.aq_short_event_id = b.aq_short_event_id AND m.axs_event_id = b.axs_event_id::text
   AND m.aq_source IS DISTINCT FROM 'axs'
   AND NOT EXISTS (SELECT 1 FROM public.axs_events e WHERE e.axs_event_id = m.axs_event_id)
   AND NOT EXISTS (SELECT 1 FROM public.axs_catalog c WHERE c.axs_event_id = m.axs_event_id AND c.source <> 'axs_export');
DELETE FROM public.axs_aq_event_xref p USING _bad_pair b WHERE p.axs_event_id = b.axs_event_id AND NOT p.pinned;

SELECT r || jsonb_build_object('tevo_links_cleared', (SELECT count(*) FROM _bad_tevo),
                               'aq_claims_cleared', (SELECT count(*) FROM _bad_claim),
                               'minted_requeued', (SELECT count(*) FROM _re_minted),
                               'minted_removed', (SELECT count(*) FROM _re_minted r
                                                   WHERE NOT EXISTS (SELECT 1 FROM public.aq_venue_map a WHERE a.venue_short_id = r.venue_short_id)),
                               'event_pairs_reset', (SELECT count(*) FROM _bad_pair)) AS result
  FROM _sync;
