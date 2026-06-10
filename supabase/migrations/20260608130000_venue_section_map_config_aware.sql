-- Migration 20260608130000 · level:2 · lane:D0
-- writes: venue_section_map (PK change + configuration_id), build_venue_section_map (config-aware),
--         v_venue_section_map_coverage (per-config)
-- reads:  events.configuration_id, seatmap_manifest, listings_snapshots, seatgeek_listings_snapshots, aq_event_map
--
-- Purpose (Step 4 — per-event seatmap configuration selection): a multi-use venue
--   has several seatmap configurations (e.g. Yankee 44718/53/81935; an arena's
--   basketball vs hockey vs concert). events.configuration_id links each event to
--   its config, and it aligns 1:1 with seatmap_manifest.configuration_id (verified:
--   137/137 multi-config venues align; 97% of events at has_map venues carry a
--   config that exists in the seatmap). Configs are ~90% identical, but the
--   config-specific sections (a concert "Floor 112" vs baseball "Field 112" sharing
--   token "112") are exactly where the venue-level UNION mis-resolves. This makes
--   the crosswalk config-aware:
--     - PK gains configuration_id: (tevo_venue_id, configuration_id, platform, section_raw)
--     - the builder loops the venue's configs; each event's sections match against
--       ITS config's keys only.
--     - configuration_id = 0 is a UNION/fallback bucket for the ~3% of events with a
--       NULL config or a config that has no seatmap — keeps their coverage.
--   The UI resolves: section -> (venue, event.configuration_id) if that config bucket
--   exists, else -> (venue, 0).
--
--   venue_section_map is regenerable (the refresh cron rebuilds it), so this TRUNCATEs
--   and lets the cron + a one-shot batch repopulate. Builder signature is unchanged
--   (loops configs internally) so the batch/cron need no change.
--
-- ## Already applied to prod  Applied via MCP 2026-06-08 (operator-authorized).
--   Branch-tested first: multi-config (token "112" resolves to the right per-config key)
--   + NULL-config fallback (config 0) + idempotency.

-- ── PART 1: table — add configuration_id to the key ──────────────────────────
TRUNCATE public.venue_section_map;  -- regenerable; rebuilt by cron + one-shot batch
ALTER TABLE public.venue_section_map DROP CONSTRAINT venue_section_map_pkey;
ALTER TABLE public.venue_section_map ALTER COLUMN configuration_id SET DEFAULT 0;
UPDATE public.venue_section_map SET configuration_id = 0 WHERE configuration_id IS NULL;  -- no-op after truncate; safety
ALTER TABLE public.venue_section_map ALTER COLUMN configuration_id SET NOT NULL;
ALTER TABLE public.venue_section_map
  ADD CONSTRAINT venue_section_map_pkey PRIMARY KEY (tevo_venue_id, configuration_id, platform, section_raw);
COMMENT ON COLUMN public.venue_section_map.configuration_id IS
  'Seatmap configuration this row resolves under (= events.configuration_id = seatmap_manifest.configuration_id). 0 = union/fallback bucket for events with a NULL config or a config that has no seatmap.';

-- ── PART 2: config-aware builder ─────────────────────────────────────────────
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
          match_method=excluded.match_method, confidence=excluded.confidence, candidate_keys=excluded.candidate_keys, seen_listings=excluded.seen_listings, updated_at=excluded.updated_at;
    GET DIAGNOSTICS v_rc = ROW_COUNT;
    v_count := v_count + v_rc;
  END LOOP;

  RETURN v_count;
END; $function$;
COMMENT ON FUNCTION public.build_venue_section_map(bigint, text, interval) IS
  'Config-aware builder. Loops the venue''s seatmap configurations (+ config 0 union/fallback for NULL/unmapped-config events); each event''s sections match ITS config''s keys. Returns total rows upserted across configs.';
REVOKE EXECUTE ON FUNCTION public.build_venue_section_map(bigint, text, interval) FROM anon, authenticated, public;

-- ── PART 3: coverage view (per config) ───────────────────────────────────────
-- DROP first: CREATE OR REPLACE can't insert configuration_id mid-column-list.
DROP VIEW IF EXISTS public.v_venue_section_map_coverage;
CREATE VIEW public.v_venue_section_map_coverage WITH (security_invoker = true) AS
SELECT m.tevo_venue_id, m.configuration_id, m.platform,
  (SELECT e.venue_name FROM public.events e WHERE e.venue_id = m.tevo_venue_id AND e.venue_name IS NOT NULL LIMIT 1) AS venue_name,
  count(*) AS sections,
  count(*) FILTER (WHERE m.match_method <> 'unmatched') AS mapped,
  count(*) FILTER (WHERE m.match_method = 'unmatched') AS unmapped,
  count(*) FILTER (WHERE m.match_method IN ('token_ambiguous','token_base_ambiguous')) AS ambiguous,
  count(*) FILTER (WHERE m.match_method = 'exact') AS exact_matches,
  round(100.0 * count(*) FILTER (WHERE m.match_method = 'unmatched') / nullif(count(*),0), 1) AS unmapped_pct,
  max(m.updated_at) AS last_built
FROM public.venue_section_map m
GROUP BY m.tevo_venue_id, m.configuration_id, m.platform;
GRANT SELECT ON public.v_venue_section_map_coverage TO authenticated;
