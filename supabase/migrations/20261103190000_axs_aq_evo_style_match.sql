-- Migration 20261103190000 · level:data-collection · lane:A1 (AXS ingest + AQ hub) · writes:aq_venue_map(+axs_venue_id; axs_venue_id/lat/lon filled; new system_seed venues),axs_aq_venue_sync()(new),axs_aq_tier_match()(new),axs_aq_time_ok()(new),axs_export_match()(replaced),axs_aq_event_xref(+confidence),aq_event_map(optional AXS<id> rows when aq_mint_missing),axs_export_sync(+aq_mint_missing),v_axs_aq_events(+confidence) · reads:axs_export_event,axs_venue_directory,aq_event_map,venue_assets · pre:20261103090000
--
-- ============================================================================
-- AXS → AQ the way EVO maps to AQ (operator 2026-11-03: "you have to map like how evo maps to aq").
--
-- EVO (and every other source) reaches AQ through match_to_aq_event_id(): first hit wins —
--   tier1     the source's own id is already on an aq_event_map row          conf 1.00
--   tier1_5   source venue id → AQ venue (aq_venue_map) + event within ±6 h   conf 0.93
--   tier2     exact venue name (lower/trim) + ±6 h                            conf 0.95
--   tier3     venue name similarity >= 0.7 + ±6 h                             conf 0.80
--   tier4     venue coordinates (venue_assets, by AQ venue name) + ±6 h        conf 0.85
--   nearest event time wins inside a tier; no event-name guard.
--   No hit → create_system_aq_event() mints the AQ row (EVO: SYS-…; AXS precedent mig
--   20260610100000: 'AXS' || axs_event_id, aq_source 'axs').
--
-- axs_aq_tier_match() runs those tiers set-based over every unpaired live US AXS export event
-- (one pass instead of one matcher call per event), with:
--   * tier1_5 using our AXS venue → AQ venue map (axs_venue_directory.aq_venue_short_id);
--   * one AXS id per AQ row and one AQ row per AXS id (aq_event_map.axs_event_id is one column);
--   * an AQ time of 00:00 read as "time unknown": such a row matches on the same local date
--     (2,149 upcoming AQ rows carry 00:00; under a strict ±6 h they could never match);
--   * the AQ write rules of mig 20261103090000 unchanged (fill-only, conflicts recorded, pinned
--     pairings override, pairings withdrawn when the AXS time leaves the window).
-- Minting is behind axs_export_sync.aq_mint_missing (default false): EVO mints AQ rows for its
-- unmatched events, but for AXS that would add up to ~60k rows to the hub, so it is the
-- operator's switch:  UPDATE axs_export_sync SET aq_mint_missing = true;
--
-- VENUES FIRST (operator 2026-11-03: "first map the venues and update venue table"): aq_venue_map
-- gains axs_venue_id (unique, like tevo_venue_id / sg_venue_id / tickpick_venue_id) and every live
-- US AXS venue is mapped or added by axs_aq_venue_sync() — run at the end of this file and then on
-- every axs_export_match pass. tier1_5 reads aq_venue_map.axs_venue_id, as EVO reads tevo_venue_id.
-- The reset + re-pair of the 1,576 pairings the 20261103090000 matcher made is the next file
-- (20261103200000), run once the venue result is reviewed. Until then the 15-minute pass pairs only
-- new / unpaired AXS events, under these tiers.
-- Rollback: re-create axs_export_match from mig 20261103090000; DROP FUNCTION axs_aq_tier_match(int),
--   axs_aq_time_ok(timestamp, text); ALTER TABLE axs_aq_event_xref DROP COLUMN confidence;
--   ALTER TABLE axs_export_sync DROP COLUMN aq_mint_missing; DROP FUNCTION axs_aq_venue_sync(boolean);
--   DELETE FROM aq_venue_map WHERE aq_source = 'system_seed' AND axs_venue_id IS NOT NULL AND imported_at >= '2026-11-03';
--   ALTER TABLE aq_venue_map DROP COLUMN axs_venue_id; DELETE FROM aq_event_map WHERE aq_source = 'axs'
--   AND imported_at >= '2026-11-03';
-- ============================================================================

ALTER TABLE public.axs_aq_event_xref ADD COLUMN IF NOT EXISTS confidence numeric;
ALTER TABLE public.axs_export_sync   ADD COLUMN IF NOT EXISTS aq_mint_missing boolean NOT NULL DEFAULT false;


-- ---------------------------------------------------------------------------
-- VENUES FIRST: aq_venue_map gets an axs_venue_id column like tevo_venue_id / sg_venue_id /
-- tickpick_venue_id (one AQ venue per AXS venue), filled by axs_aq_venue_sync()
-- ---------------------------------------------------------------------------
ALTER TABLE public.aq_venue_map ADD COLUMN IF NOT EXISTS axs_venue_id bigint;
CREATE UNIQUE INDEX IF NOT EXISTS aq_venue_map_axs_venue_id_key ON public.aq_venue_map (axs_venue_id)
  WHERE axs_venue_id IS NOT NULL;

-- Every live US AXS venue → an AQ venue, first rule that hits:
--   1 tevo_bridge  the TEvo venue it is already tied to (axs_venue_directory.tevo_venue_id, by
--                  lat/lon + name) is on aq_venue_map.tevo_venue_id
--   2 geo          aq_venue_map lat/lon within 1 km + name similarity >= 0.35, or within 150 m
--   3 name_state   same normalised name, same state, one AQ venue
--   4 name_city    name similarity >= 0.6, same city + state
--   5 minted       none: a new AQ venue (aq_source system_seed, id aq_venue_short_id(name, city,
--                  state) — the scheme every system_seed venue uses), with its AXS id, lat/lon and,
--                  when no other AQ venue holds it, its TEvo venue id. A generated id that already
--                  belongs to a venue with a different name or city is left unmapped (counted).
-- One AXS venue per AQ venue: when two AXS venues pick the same AQ venue, the earlier rule, then
-- the nearer one, then the lower AXS id wins; the other is tried again on the next pass.
-- Also fills aq_venue_map lat/lon where empty, and mirrors the result into
-- axs_venue_directory.aq_venue_short_id / aq_match_method.
CREATE OR REPLACE FUNCTION public.axs_aq_venue_sync(p_mint boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_mapped int := 0; v_minted int := 0; v_attached int := 0; v_coords int := 0; v_left int := 0;
BEGIN
  DROP TABLE IF EXISTS _v, _vp;
  CREATE TEMP TABLE _v ON COMMIT DROP AS
  SELECT d.axs_venue_id::bigint AS axs_venue_id, d.venue_name, d.city, d.state,
         d.venue_lat, d.venue_lon, d.tevo_venue_id,
         regexp_replace(regexp_replace(lower(d.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') AS norm
    FROM public.axs_venue_directory d
   WHERE d.country = 'US' AND d.axs_venue_id ~ '^\d+$' AND d.venue_name IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map a WHERE a.axs_venue_id = d.axs_venue_id::bigint)
     AND EXISTS (SELECT 1 FROM public.axs_export_event x
                  WHERE x.venue_id = d.axs_venue_id::bigint AND x.gone_at IS NULL);

  CREATE TEMP TABLE _vp ON COMMIT DROP AS
  WITH free AS (SELECT * FROM public.aq_venue_map a WHERE a.axs_venue_id IS NULL),
  r1 AS (SELECT v.axs_venue_id, f.venue_short_id, 1 AS rk, 0 AS dist_m, 'tevo_bridge' AS method
           FROM _v v JOIN free f ON f.tevo_venue_id = v.tevo_venue_id),
  r2 AS (SELECT v.axs_venue_id, f.venue_short_id, 2 AS rk,
                round(111320 * sqrt(power(f.latitude - v.venue_lat, 2)
                      + power((f.longitude - v.venue_lon) * cos(radians(v.venue_lat)), 2)))::int AS dist_m,
                'geo' AS method,
                similarity(lower(f.venue_name), lower(v.venue_name)) AS sim
           FROM _v v JOIN free f
             ON v.venue_lat IS NOT NULL AND f.latitude IS NOT NULL
            AND f.latitude  BETWEEN v.venue_lat - 0.01 AND v.venue_lat + 0.01
            AND f.longitude BETWEEN v.venue_lon - 0.013 AND v.venue_lon + 0.013),
  r2ok AS (SELECT axs_venue_id, venue_short_id, rk, dist_m, method FROM r2
            WHERE (dist_m <= 1000 AND sim >= 0.35) OR dist_m <= 150),
  r3 AS (SELECT v.axs_venue_id, min(f.venue_short_id) AS venue_short_id, 3 AS rk, NULL::int AS dist_m, 'name_state' AS method
           FROM _v v JOIN free f
             ON regexp_replace(regexp_replace(lower(f.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') = v.norm
            AND upper(f.state) = upper(v.state)
          GROUP BY v.axs_venue_id HAVING count(DISTINCT f.venue_short_id) = 1),
  r4 AS (SELECT DISTINCT ON (v.axs_venue_id) v.axs_venue_id, f.venue_short_id, 4 AS rk, NULL::int AS dist_m, 'name_city' AS method
           FROM _v v JOIN free f
             ON upper(f.state) = upper(v.state) AND lower(f.city) = lower(v.city)
            AND similarity(lower(f.venue_name), lower(v.venue_name)) >= 0.6
          ORDER BY v.axs_venue_id, similarity(lower(f.venue_name), lower(v.venue_name)) DESC),
  allp AS (SELECT * FROM r1 UNION ALL SELECT * FROM r2ok UNION ALL SELECT * FROM r3 UNION ALL SELECT * FROM r4),
  best_v AS (SELECT DISTINCT ON (axs_venue_id) * FROM allp ORDER BY axs_venue_id, rk, dist_m NULLS LAST, venue_short_id)
  SELECT DISTINCT ON (venue_short_id) * FROM best_v ORDER BY venue_short_id, rk, dist_m NULLS LAST, axs_venue_id;

  UPDATE public.aq_venue_map a
     SET axs_venue_id = p.axs_venue_id,
         latitude  = coalesce(a.latitude,  v.venue_lat),
         longitude = coalesce(a.longitude, v.venue_lon)
    FROM _vp p JOIN _v v USING (axs_venue_id)
   WHERE a.venue_short_id = p.venue_short_id AND a.axs_venue_id IS NULL;
  GET DIAGNOSTICS v_mapped = ROW_COUNT;

  IF p_mint THEN
    -- 5a. a generated id that already exists for the same venue (same name + city): attach
    UPDATE public.aq_venue_map a
       SET axs_venue_id = v.axs_venue_id,
           latitude = coalesce(a.latitude, v.venue_lat), longitude = coalesce(a.longitude, v.venue_lon)
      FROM _v v
     WHERE a.venue_short_id = public.aq_venue_short_id(v.venue_name, v.city, v.state)
       AND a.axs_venue_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM _vp p WHERE p.axs_venue_id = v.axs_venue_id)
       AND regexp_replace(regexp_replace(lower(a.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') = v.norm
       AND lower(coalesce(a.city, '')) = lower(coalesce(v.city, ''));
    GET DIAGNOSTICS v_attached = ROW_COUNT;

    -- 5b. new AQ venues for the rest
    WITH todo AS (
      SELECT DISTINCT ON (public.aq_venue_short_id(v.venue_name, v.city, v.state))
             public.aq_venue_short_id(v.venue_name, v.city, v.state) AS venue_short_id, v.*
        FROM _v v
       WHERE NOT EXISTS (SELECT 1 FROM _vp p WHERE p.axs_venue_id = v.axs_venue_id)
         AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map a WHERE a.axs_venue_id = v.axs_venue_id)
       ORDER BY public.aq_venue_short_id(v.venue_name, v.city, v.state), v.axs_venue_id)
    INSERT INTO public.aq_venue_map (venue_short_id, venue_name, city, state, country, tevo_venue_id,
                                     axs_venue_id, latitude, longitude, aq_source, imported_at)
    SELECT t.venue_short_id, t.venue_name, t.city, upper(t.state), 'US',
           CASE WHEN t.tevo_venue_id IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tevo_venue_id = t.tevo_venue_id)
                THEN t.tevo_venue_id END,
           t.axs_venue_id, t.venue_lat, t.venue_lon, 'system_seed', now()
      FROM todo t
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_minted = ROW_COUNT;
  END IF;

  -- mirror into the AXS venue directory
  UPDATE public.axs_venue_directory d
     SET aq_venue_short_id = a.venue_short_id,
         aq_match_method = coalesce((SELECT p.method FROM _vp p WHERE p.axs_venue_id = a.axs_venue_id),
                                    CASE WHEN a.imported_at = now() THEN 'minted' ELSE 'attached' END)
    FROM public.aq_venue_map a
   WHERE a.axs_venue_id::text = d.axs_venue_id
     AND (d.aq_venue_short_id IS DISTINCT FROM a.venue_short_id
          OR EXISTS (SELECT 1 FROM _v v WHERE v.axs_venue_id = a.axs_venue_id));

  SELECT count(*) INTO v_left FROM _v v
   WHERE NOT EXISTS (SELECT 1 FROM public.aq_venue_map a WHERE a.axs_venue_id = v.axs_venue_id);

  RETURN jsonb_build_object('to_place', (SELECT count(*) FROM _v), 'mapped_existing', v_mapped,
                            'attached_same_id', v_attached, 'minted', v_minted, 'still_unmapped', v_left,
                            'by_rule', (SELECT jsonb_object_agg(method, n) FROM (SELECT method, count(*) n FROM _vp GROUP BY 1) s));
END $$;
REVOKE ALL ON FUNCTION public.axs_aq_venue_sync(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_aq_venue_sync(boolean) TO service_role;

-- ±6 h like match_to_aq_event_id; an AQ 00:00 means date-only → same local date
CREATE OR REPLACE FUNCTION public.axs_aq_time_ok(p_aq timestamp, p_axs_local text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
           WHEN p_aq IS NULL OR p_axs_local !~ '^\d{4}-\d\d-\d\d' THEN false
           WHEN to_char(p_aq, 'HH24:MI') = '00:00' OR p_axs_local !~ '^\d{4}-\d\d-\d\dT\d\d:\d\d'
             THEN p_aq::date = left(p_axs_local, 10)::date
           ELSE p_aq BETWEEN left(p_axs_local, 19)::timestamp - interval '6 hours'
                         AND left(p_axs_local, 19)::timestamp + interval '6 hours'
         END
$$;

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
         (SELECT a.venue_short_id FROM public.aq_venue_map a WHERE a.axs_venue_id = x.venue_id) AS aq_venue_short_id,
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
     WHERE a.venue_lat IS NOT NULL AND q.axs_event_id IS NULL),
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

-- axs_export_match: same body as mig 20261103090000 except step (iii) (→ axs_aq_tier_match) and the
-- withdraw rule (→ axs_aq_time_ok)
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
    SELECT d.axs_venue_id, d.venue_name, d.state, d.venue_lat, d.venue_lon,
           regexp_replace(regexp_replace(lower(d.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') AS norm
      FROM public.axs_venue_directory d
     WHERE d.tevo_venue_id IS NULL AND d.country = 'US'),
  geo AS (
    SELECT DISTINCT ON (t.axs_venue_id) t.axs_venue_id, a.tevo_venue_id,
           round(111320 * sqrt(power(a.latitude - t.venue_lat, 2)
                 + power((a.longitude - t.venue_lon) * cos(radians(t.venue_lat)), 2)))::int AS dist_m,
           similarity(lower(a.venue_name), lower(t.venue_name)) AS sim
      FROM todo t
      JOIN public.venue_assets a
        ON t.venue_lat IS NOT NULL AND a.latitude IS NOT NULL
       AND a.latitude  BETWEEN t.venue_lat - 0.01 AND t.venue_lat + 0.01
       AND a.longitude BETWEEN t.venue_lon - 0.013 AND t.venue_lon + 0.013
     ORDER BY t.axs_venue_id,
              (similarity(lower(a.venue_name), lower(t.venue_name)) >= 0.35) DESC,
              111320 * sqrt(power(a.latitude - t.venue_lat, 2)
                 + power((a.longitude - t.venue_lon) * cos(radians(t.venue_lat)), 2)),
              similarity(lower(a.venue_name), lower(t.venue_name)) DESC),
  geo_ok AS (
    SELECT * FROM geo WHERE (dist_m <= 1000 AND sim >= 0.35) OR dist_m <= 150),
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

-- the desk-shaped list gains the tier confidence
CREATE OR REPLACE VIEW public.v_axs_aq_events WITH (security_invoker = true) AS
SELECT x.axs_event_id::text AS event_id, p.aq_short_event_id AS internal_id,
       x.event_title AS name, x.headliner, x.venue_name AS venue, x.venue_city AS city,
       x.venue_state AS state, left(x.event_date_local, 10) AS date,
       nullif(substr(x.event_date_local, 12, 5), '') AS time, x.event_url,
       x.type, x.axs_ticketed, x.status, x.onsale_utc, x.presale_utc,
       p.method AS match_method, p.venue_how, p.pinned, p.conflict_axs_event_id, p.axs_id_held_by,
       x.venue_id AS axs_venue_id, x.last_synced_at AS updated_at, p.confidence
  FROM public.axs_export_event x
  LEFT JOIN public.axs_aq_event_xref p ON p.axs_event_id = x.axs_event_id
 WHERE x.gone_at IS NULL AND x.venue_country = 'US'
   AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD');
REVOKE ALL ON public.v_axs_aq_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_aq_events TO service_role;

-- VENUES FIRST: map every live US AXS venue into aq_venue_map now. The event reset + re-pair under
-- the EVO tiers is the next file (20261103200000), run after the venue result is reviewed.
SELECT public.axs_aq_venue_sync(true);
