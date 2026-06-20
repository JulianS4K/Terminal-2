-- Migration 20260620130000 · level:2 · lane:D0
-- writes: build_venue_section_map() [fn — adds manual-row protection],
--         set_event_section_manual_map() [fn], clear_event_section_manual_map() [fn]
-- reads:  events, seatmap_manifest, venue_section_map
--
-- Purpose: Manual seat-map crosswalk overrides + protecting them from the refresh cron.
--   The venue_section_map crosswalk (mig 20260608120000 / 130000) auto-classifies each
--   (venue, config, platform, raw-section) onto a seatmap polygon, leaving the misses as
--   match_method='unmatched'. The terminal Seat Map tab surfaces those unmapped sections
--   live (real-time tracker); this migration lets an operator MAP one by hand and have it
--   STICK:
--
--     1. build_venue_section_map() — re-created VERBATIM from the config-aware version
--        (mig 20260608130000) with ONE change: the ON CONFLICT DO UPDATE now carries
--        `WHERE m.match_method <> 'manual'`, so the */10 venue_section_map_refresh cron
--        can no longer clobber an operator's manual mapping. (Builder is lane:D0 — see the
--        20260608120000 header.) No other behavior change; signature unchanged.
--     2. set_event_section_manual_map(event, platform, section_raw, seatmap_key) — upserts a
--        match_method='manual', confidence=1.0 row for the event's (venue, config bucket),
--        resolving the bucket EXACTLY as get_event_section_map does (so the UI reads the row
--        back). Validates seatmap_key against the venue's seatmap_manifest keys. Returns the
--        resolved row as json. @s4kent.com-gated, like get_event_section_map.
--     3. clear_event_section_manual_map(event, platform, section_raw) — deletes the manual
--        row (the next cron tick re-derives it from the auto tiers). @s4kent.com-gated.
--
--   Grant pattern mirrors get_event_section_map (mig 20260608140000): EXECUTE to
--   authenticated + an in-body @s4kent.com gate (NOT the service_role-only SECDEF
--   convention — these are user-facing terminal RPCs, same shape as get_event_section_map /
--   get_broker_event_page).
--
-- ## NOT yet applied to prod — author-only (D0). A1 applies after review.
--   Test plan (preview branch): pick an 'unmatched' (venue,config,platform,section) row;
--   call set_event_section_manual_map and confirm get_event_section_map returns it as
--   'manual'; run build_venue_section_map(venue,'evo') and confirm the manual row SURVIVES
--   (not reverted to its auto tier); call clear_event_section_manual_map and confirm the
--   row is gone (so the next build re-derives it).

-- ── PART 1: config-aware builder + manual-row protection ─────────────────────
-- Identical to mig 20260608130000 EXCEPT the ON CONFLICT DO UPDATE ... WHERE clause.
CREATE OR REPLACE FUNCTION public.build_venue_section_map(
  p_venue_id bigint, p_platform text DEFAULT 'evo', p_window interval DEFAULT interval '7 days'
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now   timestamptz := now();
  v_count integer := 0;
  v_rc    integer;
  v_cfg   integer;
BEGIN
  IF p_platform NOT IN ('evo','sg') THEN
    RAISE EXCEPTION 'build_venue_section_map: platform % source not yet wired. evo + sg are live; tp/vd/sh need their per-platform listings source.', p_platform USING ERRCODE='0A000';
  END IF;

  -- one pass per real config, plus config 0 (union/fallback)
  FOR v_cfg IN
    SELECT DISTINCT configuration_id FROM public.seatmap_manifest
      WHERE venue_id = p_venue_id AND has_map AND configuration_id IS NOT NULL
    UNION SELECT 0
  LOOP
    WITH keys AS (  -- this config's keys (or ALL configs' keys when v_cfg = 0)
      SELECT DISTINCT public.venue_section_token(k) AS tok, public.venue_section_token_base(k) AS tok_base, lower(btrim(k)) AS seatmap_key
      FROM public.seatmap_manifest sm CROSS JOIN LATERAL unnest(sm.section_keys) AS k
      WHERE sm.venue_id = p_venue_id AND sm.has_map
        AND (v_cfg = 0 OR sm.configuration_id = v_cfg)
    ),
    keytok AS (SELECT tok, count(DISTINCT seatmap_key) nkeys, (array_agg(DISTINCT seatmap_key))[1] first_key, array_agg(DISTINCT seatmap_key) all_keys FROM keys WHERE tok IS NOT NULL GROUP BY tok),
    keybase AS (SELECT tok_base, count(DISTINCT seatmap_key) nkeys, (array_agg(DISTINCT seatmap_key))[1] first_key, array_agg(DISTINCT seatmap_key) all_keys FROM keys WHERE tok_base IS NOT NULL GROUP BY tok_base),
    evs AS (  -- the events feeding this config bucket
      SELECT e.id, e.configuration_id FROM public.events e
      WHERE e.venue_id = p_venue_id
        AND (
          (v_cfg <> 0 AND e.configuration_id = v_cfg)
          OR (v_cfg = 0 AND (e.configuration_id IS NULL
              OR NOT EXISTS (SELECT 1 FROM public.seatmap_manifest s2 WHERE s2.venue_id = p_venue_id AND s2.has_map AND s2.configuration_id = e.configuration_id)))
        )
    ),
    raw AS (
      SELECT lower(btrim(s)) AS section_raw, count(*) AS seen FROM (
        SELECT ls.section AS s FROM public.listings_snapshots ls
          WHERE p_platform = 'evo' AND ls.event_id IN (SELECT id FROM evs)
            AND ls.captured_at > v_now - p_window AND ls.type = 'event' AND ls.is_ancillary = false
        UNION ALL
        SELECT sl.section AS s FROM public.seatgeek_listings_snapshots sl
          WHERE p_platform = 'sg' AND sl.sg_event_id IN (
            SELECT m.sg_event_id FROM public.aq_event_map m JOIN evs ON evs.id = m.tevo_event_id
            WHERE m.sg_event_id IS NOT NULL)
            AND sl.captured_at > v_now - p_window
      ) u WHERE s IS NOT NULL AND btrim(s) <> '' GROUP BY 1
    ),
    scored AS (
      SELECT r.section_raw, r.seen, public.vsm_listing_token(r.section_raw, p_platform) AS tok, public.vsm_listing_token_base(r.section_raw, p_platform) AS tok_base,
        kx.seatmap_key AS exact_key, kt.nkeys AS kt_n, kt.first_key AS kt_key, kt.all_keys AS kt_keys, kb.nkeys AS kb_n, kb.first_key AS kb_key, kb.all_keys AS kb_keys
      FROM raw r LEFT JOIN keys kx ON kx.seatmap_key = r.section_raw
      LEFT JOIN keytok kt ON kt.tok = public.vsm_listing_token(r.section_raw, p_platform)
      LEFT JOIN keybase kb ON kb.tok_base = public.vsm_listing_token_base(r.section_raw, p_platform)
    ),
    classed AS (
      SELECT section_raw, seen, tok, tok_base,
        CASE WHEN exact_key IS NOT NULL THEN 'exact' WHEN kt_n=1 THEN 'token' WHEN kt_n>1 THEN 'token_ambiguous'
             WHEN tok_base IS NOT NULL AND kb_n=1 THEN 'token_base' WHEN tok_base IS NOT NULL AND kb_n>1 THEN 'token_base_ambiguous' ELSE 'unmatched' END AS method,
        CASE WHEN exact_key IS NOT NULL THEN exact_key WHEN kt_n=1 THEN kt_key WHEN kt_n>1 THEN kt_key WHEN tok_base IS NOT NULL AND kb_n>=1 THEN kb_key ELSE NULL END AS seatmap_key,
        CASE WHEN kt_n>1 THEN kt_keys WHEN coalesce(kt_n,0)=0 AND tok_base IS NOT NULL AND kb_n>1 THEN kb_keys ELSE NULL END AS candidate_keys
      FROM scored
    )
    INSERT INTO public.venue_section_map AS m
      (tevo_venue_id, configuration_id, platform, section_raw, section_token, section_token_base, seatmap_key, match_method, confidence, candidate_keys, seen_listings, first_seen_at, updated_at)
    SELECT p_venue_id, v_cfg, p_platform, section_raw, tok, tok_base, seatmap_key, method,
           CASE method WHEN 'exact' THEN 1.0 WHEN 'token' THEN 0.9 WHEN 'token_base' THEN 0.75 WHEN 'token_ambiguous' THEN 0.5 WHEN 'token_base_ambiguous' THEN 0.45 ELSE 0 END,
           candidate_keys, seen, v_now, v_now
    FROM classed
    ON CONFLICT (tevo_venue_id, configuration_id, platform, section_raw) DO UPDATE
      SET section_token=excluded.section_token, section_token_base=excluded.section_token_base, seatmap_key=excluded.seatmap_key,
          match_method=excluded.match_method, confidence=excluded.confidence, candidate_keys=excluded.candidate_keys, seen_listings=excluded.seen_listings, updated_at=excluded.updated_at
      WHERE m.match_method <> 'manual';   -- never clobber an operator's manual mapping
    GET DIAGNOSTICS v_rc = ROW_COUNT;
    v_count := v_count + v_rc;
  END LOOP;

  RETURN v_count;
END; $function$;
COMMENT ON FUNCTION public.build_venue_section_map(bigint, text, interval) IS
  'Config-aware builder. Loops the venue''s seatmap configurations (+ config 0 union/fallback for NULL/unmapped-config events); each event''s sections match ITS config''s keys. Manual rows (match_method=manual) are NEVER overwritten (ON CONFLICT WHERE m.match_method<>manual). Returns total rows upserted across configs.';
REVOKE EXECUTE ON FUNCTION public.build_venue_section_map(bigint, text, interval) FROM anon, authenticated, public;

-- ── PART 2: manual-map writer (terminal UI) ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_event_section_manual_map(
  p_event_id bigint, p_platform text, p_section_raw text, p_seatmap_key text
) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_email   text;
  v_venue   bigint;
  v_cfg     integer;
  v_use     integer;
  v_section text;
  v_key     text;   -- canonical lower(btrim) manifest key
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;

  IF p_platform NOT IN ('evo','sg','tp','vd','sh') THEN
    RAISE EXCEPTION 'set_event_section_manual_map: bad platform %', p_platform USING ERRCODE='22023';
  END IF;
  v_section := lower(btrim(coalesce(p_section_raw,'')));
  IF v_section = '' THEN
    RAISE EXCEPTION 'set_event_section_manual_map: empty section_raw' USING ERRCODE='22023';
  END IF;

  SELECT e.venue_id, e.configuration_id INTO v_venue, v_cfg FROM public.events e WHERE e.id = p_event_id;
  IF v_venue IS NULL THEN
    RAISE EXCEPTION 'set_event_section_manual_map: event % has no venue', p_event_id USING ERRCODE='22023';
  END IF;

  -- Validate the target polygon exists in this venue's seatmap manifest; capture the
  -- canonical lower(btrim) form so it joins the same namespace as the auto-built keys.
  SELECT lower(btrim(k)) INTO v_key
  FROM public.seatmap_manifest sm CROSS JOIN LATERAL unnest(sm.section_keys) AS k
  WHERE sm.venue_id = v_venue AND sm.has_map
    AND lower(btrim(k)) = lower(btrim(coalesce(p_seatmap_key,'')))
  LIMIT 1;
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'set_event_section_manual_map: % is not a seatmap key for venue %', p_seatmap_key, v_venue USING ERRCODE='22023';
  END IF;

  -- Resolve the config bucket EXACTLY as get_event_section_map does so the UI reads it back.
  v_use := v_cfg;
  IF v_use IS NULL OR NOT EXISTS (SELECT 1 FROM public.venue_section_map m WHERE m.tevo_venue_id=v_venue AND m.configuration_id=v_use) THEN
    v_use := 0;
  END IF;

  INSERT INTO public.venue_section_map AS m
    (tevo_venue_id, configuration_id, platform, section_raw, section_token, section_token_base,
     seatmap_key, match_method, confidence, candidate_keys, seen_listings, first_seen_at, updated_at)
  VALUES
    (v_venue, v_use, p_platform, v_section,
     public.venue_section_token(v_section), public.venue_section_token_base(v_section),
     v_key, 'manual', 1.0, NULL, NULL, now(), now())
  ON CONFLICT (tevo_venue_id, configuration_id, platform, section_raw) DO UPDATE
    SET seatmap_key  = excluded.seatmap_key,
        match_method = 'manual',
        confidence   = 1.0,
        candidate_keys = NULL,
        updated_at   = now();   -- preserve section_token(_base)/seen_listings already on the row

  RETURN json_build_object(
    'tevo_venue_id', v_venue, 'configuration_id', v_use, 'platform', p_platform,
    'section_raw', v_section, 'seatmap_key', v_key, 'match_method', 'manual');
END $function$;
COMMENT ON FUNCTION public.set_event_section_manual_map(bigint, text, text, text) IS
  'Terminal Seat Map tab: assign a listing section to a venue-map polygon by hand (match_method=manual, confidence=1.0). Resolves the event''s (venue, config bucket) like get_event_section_map, validates seatmap_key against seatmap_manifest, and upserts. Sticky: the refresh cron will not overwrite it. @s4kent.com-gated.';
REVOKE EXECUTE ON FUNCTION public.set_event_section_manual_map(bigint, text, text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.set_event_section_manual_map(bigint, text, text, text) TO authenticated;

-- ── PART 3: clear a manual map ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.clear_event_section_manual_map(
  p_event_id bigint, p_platform text, p_section_raw text
) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_email   text;
  v_venue   bigint;
  v_cfg     integer;
  v_use     integer;
  v_section text;
  v_n       integer;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;
  v_section := lower(btrim(coalesce(p_section_raw,'')));
  SELECT e.venue_id, e.configuration_id INTO v_venue, v_cfg FROM public.events e WHERE e.id = p_event_id;
  IF v_venue IS NULL THEN RETURN false; END IF;
  v_use := v_cfg;
  IF v_use IS NULL OR NOT EXISTS (SELECT 1 FROM public.venue_section_map m WHERE m.tevo_venue_id=v_venue AND m.configuration_id=v_use) THEN
    v_use := 0;
  END IF;
  -- Only deletes manual rows — never touches an auto-classified row. The next
  -- build_venue_section_map tick re-derives this section from the auto tiers.
  DELETE FROM public.venue_section_map m
   WHERE m.tevo_venue_id = v_venue AND m.configuration_id = v_use
     AND m.platform = p_platform AND m.section_raw = v_section
     AND m.match_method = 'manual';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $function$;
COMMENT ON FUNCTION public.clear_event_section_manual_map(bigint, text, text) IS
  'Terminal Seat Map tab: remove a manual section->polygon mapping (only deletes match_method=manual rows). The next venue_section_map_refresh re-derives the section from the auto tiers. @s4kent.com-gated.';
REVOKE EXECUTE ON FUNCTION public.clear_event_section_manual_map(bigint, text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.clear_event_section_manual_map(bigint, text, text) TO authenticated;
