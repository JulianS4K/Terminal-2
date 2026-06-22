-- ============================================================================
-- Migration 20260621xxxxxx — venue_section_map: support GT + TM platforms
--
-- Lane:     A1 (data plane — owns venue_section_map crosswalk + builders)
-- Touches:  build_venue_section_map()       (W, CREATE OR REPLACE)
--           build_venue_section_map_batch()  (W, CREATE OR REPLACE)
-- Pre-reqs: existing definitions (mig 20260609024738_venue_section_map_td_platforms)
--
-- WHY: the section→seatmap crosswalk supported evo/sg/tp/vd/sh but NOT
--   gametime (GT) or ticketmaster (TM). Those two TicketsData platforms carry
--   real section-level detail (UFC 329 @ T-Mobile: GT 64 sections, TM 46 —
--   numeric "101/102/.. " + floor "1/10/.."), so their listings could never
--   plot on the venue seat map. This adds gt/tm to:
--     1. the build_venue_section_map platform whitelist,
--     2. its TicketsData section-source union (td.platform = upper(platform)),
--     3. the batch builder's platform fan-out (so the */10 cron maintains them).
--
--   Purely additive — no behavior change for existing platforms. The TD union
--   branch already reads ticketsdata_listings_snapshots generically; gt/tm just
--   needed to be allowed through. Tokenization uses the generic (non-evo) path
--   in vsm_listing_token, which already handles numeric section labels.
--
-- NOTE: the venue_section_map.platform (and build_state.platform) CHECK
--   constraints also enumerate allowed platforms — they must be widened to
--   accept gt/tm or the builder INSERT fails with a check violation.
-- ============================================================================

-- 1. Widen the platform CHECK constraints to admit gt/tm.
ALTER TABLE public.venue_section_map DROP CONSTRAINT IF EXISTS venue_section_map_platform_check;
ALTER TABLE public.venue_section_map ADD CONSTRAINT venue_section_map_platform_check
  CHECK (platform = ANY (ARRAY['evo','sg','tp','vd','sh','gt','tm']));

DO $cons$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint
  WHERE conrelid='public.venue_section_map_build_state'::regclass AND contype='c'
    AND pg_get_constraintdef(oid) ILIKE '%platform%';
  IF c IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.venue_section_map_build_state DROP CONSTRAINT %I', c);
    ALTER TABLE public.venue_section_map_build_state ADD CONSTRAINT venue_section_map_build_state_platform_check
      CHECK (platform = ANY (ARRAY['evo','sg','tp','vd','sh','gt','tm']));
  END IF;
END $cons$;

-- 2. Builder + batch: allow gt/tm and fan them out.
CREATE OR REPLACE FUNCTION public.build_venue_section_map(p_venue_id bigint, p_platform text DEFAULT 'evo'::text, p_window interval DEFAULT '7 days'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_now timestamptz := now(); v_count integer := 0; v_rc integer; v_cfg integer;
BEGIN
  IF p_platform NOT IN ('evo','sg','tp','vd','sh','gt','tm') THEN RAISE EXCEPTION 'build_venue_section_map: platform % not supported', p_platform USING ERRCODE='0A000'; END IF;
  FOR v_cfg IN
    SELECT DISTINCT configuration_id FROM public.seatmap_manifest WHERE venue_id=p_venue_id AND has_map AND configuration_id IS NOT NULL
    UNION SELECT 0
  LOOP
    WITH keys AS (
      SELECT DISTINCT public.venue_section_token(k) AS tok, public.venue_section_token_base(k) AS tok_base, lower(btrim(k)) AS seatmap_key
      FROM public.seatmap_manifest sm CROSS JOIN LATERAL unnest(sm.section_keys) AS k
      WHERE sm.venue_id=p_venue_id AND sm.has_map AND (v_cfg=0 OR sm.configuration_id=v_cfg)
    ),
    keytok AS (SELECT tok, count(DISTINCT seatmap_key) nkeys, (array_agg(DISTINCT seatmap_key))[1] first_key, array_agg(DISTINCT seatmap_key) all_keys FROM keys WHERE tok IS NOT NULL GROUP BY tok),
    keybase AS (SELECT tok_base, count(DISTINCT seatmap_key) nkeys, (array_agg(DISTINCT seatmap_key))[1] first_key, array_agg(DISTINCT seatmap_key) all_keys FROM keys WHERE tok_base IS NOT NULL GROUP BY tok_base),
    evs AS (
      SELECT e.id FROM public.events e WHERE e.venue_id=p_venue_id AND (
        (v_cfg<>0 AND e.configuration_id=v_cfg)
        OR (v_cfg=0 AND (e.configuration_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.seatmap_manifest s2 WHERE s2.venue_id=p_venue_id AND s2.has_map AND s2.configuration_id=e.configuration_id))))
    ),
    raw AS (
      SELECT lower(btrim(s)) section_raw, count(*) seen FROM (
        SELECT ls.section s FROM public.listings_snapshots ls WHERE p_platform='evo' AND ls.event_id IN (SELECT id FROM evs)
          AND ls.captured_at> v_now-p_window AND ls.type='event' AND ls.is_ancillary=false
        UNION ALL
        SELECT sl.section s FROM public.seatgeek_listings_snapshots sl WHERE p_platform='sg' AND sl.sg_event_id IN (
          SELECT m.sg_event_id FROM public.aq_event_map m JOIN evs ON evs.id=m.tevo_event_id WHERE m.sg_event_id IS NOT NULL)
          AND sl.captured_at> v_now-p_window
        UNION ALL
        SELECT td.section s FROM public.ticketsdata_listings_snapshots td
          JOIN public.ticketsdata_event_xref x ON x.event_id=td.event_id AND x.platform=td.platform
          JOIN public.aq_event_map m ON m.aq_short_event_id=x.aq_short_event_id
          WHERE p_platform IN ('tp','vd','sh','gt','tm') AND td.platform=upper(p_platform)
            AND m.tevo_event_id IN (SELECT id FROM evs) AND td.captured_at> v_now-p_window
      ) u WHERE s IS NOT NULL AND btrim(s)<>'' GROUP BY 1
    ),
    scored AS (
      SELECT r.section_raw, r.seen, public.vsm_listing_token(r.section_raw,p_platform) tok, public.vsm_listing_token_base(r.section_raw,p_platform) tok_base,
        kx.seatmap_key exact_key, kt.nkeys kt_n, kt.first_key kt_key, kt.all_keys kt_keys, kb.nkeys kb_n, kb.first_key kb_key, kb.all_keys kb_keys
      FROM raw r LEFT JOIN keys kx ON kx.seatmap_key=r.section_raw
      LEFT JOIN keytok kt ON kt.tok=public.vsm_listing_token(r.section_raw,p_platform)
      LEFT JOIN keybase kb ON kb.tok_base=public.vsm_listing_token_base(r.section_raw,p_platform)
    ),
    classed AS (
      SELECT section_raw, seen, tok, tok_base,
        CASE WHEN exact_key IS NOT NULL THEN 'exact' WHEN kt_n=1 THEN 'token' WHEN kt_n>1 THEN 'token_ambiguous'
             WHEN tok_base IS NOT NULL AND kb_n=1 THEN 'token_base' WHEN tok_base IS NOT NULL AND kb_n>1 THEN 'token_base_ambiguous' ELSE 'unmatched' END method,
        CASE WHEN exact_key IS NOT NULL THEN exact_key WHEN kt_n=1 THEN kt_key WHEN kt_n>1 THEN kt_key WHEN tok_base IS NOT NULL AND kb_n>=1 THEN kb_key ELSE NULL END seatmap_key,
        CASE WHEN kt_n>1 THEN kt_keys WHEN coalesce(kt_n,0)=0 AND tok_base IS NOT NULL AND kb_n>1 THEN kb_keys ELSE NULL END candidate_keys
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
          match_method=excluded.match_method, confidence=excluded.confidence, candidate_keys=excluded.candidate_keys, seen_listings=excluded.seen_listings, updated_at=excluded.updated_at;
    GET DIAGNOSTICS v_rc = ROW_COUNT; v_count := v_count + v_rc;
  END LOOP;
  RETURN v_count;
END; $function$;

CREATE OR REPLACE FUNCTION public.build_venue_section_map_batch(p_batch integer DEFAULT 25, p_window interval DEFAULT '3 days'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r record; v_n integer := 0; v_rows integer; v_start timestamptz := clock_timestamp();
BEGIN
  FOR r IN
    WITH cand AS (
      SELECT v.venue_id, p.platform
      FROM (SELECT DISTINCT sm.venue_id FROM public.seatmap_manifest sm
            WHERE sm.has_map AND EXISTS(SELECT 1 FROM public.events e WHERE e.venue_id=sm.venue_id)) v
      CROSS JOIN (VALUES ('evo'),('sg'),('tp'),('vd'),('sh'),('gt'),('tm')) p(platform)
    )
    SELECT c.venue_id, c.platform
    FROM cand c
    LEFT JOIN public.venue_section_map_build_state st
      ON st.tevo_venue_id = c.venue_id AND st.platform = c.platform
    ORDER BY st.last_attempt_at ASC NULLS FIRST, c.venue_id
    LIMIT p_batch
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '45 seconds';
    BEGIN
      v_rows := public.build_venue_section_map(r.venue_id, r.platform, p_window);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      v_rows := NULL;
      RAISE WARNING 'build_venue_section_map_batch: skipped venue % platform %: %', r.venue_id, r.platform, SQLERRM;
    END;
    INSERT INTO public.venue_section_map_build_state AS s (tevo_venue_id, platform, last_attempt_at, last_rows)
    VALUES (r.venue_id, r.platform, now(), v_rows)
    ON CONFLICT (tevo_venue_id, platform) DO UPDATE
      SET last_attempt_at = excluded.last_attempt_at, last_rows = excluded.last_rows;
  END LOOP;
  RETURN v_n;
END; $function$;
