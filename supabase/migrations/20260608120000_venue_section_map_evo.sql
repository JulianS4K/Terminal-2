-- Migration 20260608120000 · level:2 · lane:D0
-- writes: venue_section_token() [fn], venue_section_token_base() [fn],
--         venue_section_map [table], build_venue_section_map() [fn],
--         build_venue_section_map_all() [fn], v_venue_section_map_coverage [view]
-- reads:  seatmap_manifest, listings_snapshots, events, td_normalize_section()
--
-- Purpose: First cut of the cross-platform SEAT-MAP section crosswalk — the
--   "venue map" layer the terminal needs to plot live inventory onto a venue's
--   seat map. seatmap_manifest.section_keys are TEvo's seat-map polygon labels
--   (display names: "Field Infield 112", "Bleachers 201"); the listings firehose
--   uses bare seller codes ("112", "014b", "201"). A naive exact match places
--   only ~2-24% of inventory; the normalized-token join below places 77-95%.
--   (Measured read-only vs prod 2026-06-08: Fenway 95%, Yankee 86-90%, Sphere 77%.)
--
--   This migration builds the EVO (TEvo firehose) path only. The table + token
--   fns are platform-generic (platform IN evo/sg/tp/vd/sh) so sg/tp/vd/sh extend
--   the builder later — each resolves its venue to a canonical tevo_venue_id via
--   the EXISTING venue mapper (cross_source_venue_resolve / aq_venue_map — NOT
--   rebuilt here) then maps that platform's section strings through the same
--   token fns onto the same seatmap namespace.
--
--   Objects:
--     1. venue_section_token(section)      — descriptor-strip (reuses
--        td_normalize_section) + leading-zero-strip + lower → canonical join token
--        ("field infield 112" -> "112", "014b" -> "14b").
--     2. venue_section_token_base(section) — leading-integer core of the token
--        ("14b" -> "14") — recovers a/b field splits vs single-polygon map keys.
--     3. venue_section_map                 — per (venue, platform, raw section)
--        crosswalk row -> seatmap_key + method + confidence + ambiguity.
--     4. build_venue_section_map(venue, platform, window) — populate one venue.
--        EVO source filter: type='event' AND NOT is_ancillary — drops parking,
--        which is is_ancillary=true / type='parking' in the firehose (verified:
--        cleanly isolates address/garage/lot rows; no regex needed).
--     5. build_venue_section_map_all(platform, max_venues, window) — bounded
--        driver over has_map venues that exist in events.
--     6. v_venue_section_map_coverage      — per-venue mapped/unmapped/ambiguous %
--        (the meaningful "unmapped percentage" surface; security_invoker).
--
--   Match tiers (highest confidence first): exact (raw=key) -> token (unique
--   token) -> token_ambiguous (token hits >1 key, flagged) -> token_base (unique
--   leading-integer core) -> unmatched.
--
--   Authored by D0 2026-06-08.
--
-- ## Already applied to prod  Applied via MCP 2026-06-08 (operator-authorized, "do 1-5 in order").
--   Branch-tested end-to-end first (all 5 tiers + parking-exclusion + platform guard +
--   idempotency on a copy-on-write branch). One prod-data bug then surfaced + fixed:
--   venues have MULTIPLE seatmap configs repeating the same section_key, so the
--   exact-match join fanned out and the upsert hit the same PK twice ("ON CONFLICT
--   cannot affect row a second time"). Fixed by SELECT DISTINCT on the keys CTE
--   (applied as venue_section_map_evo_distinct_fix). Sample populate (real prod):
--   Dodger 96.8% / Yankee 85.1% / Citi 81.1% / Fenway 46.4% (alpha-named sections).
--   NOTE: full 366-venue backfill is NOT done one-shot — per-venue firehose scans are
--   too heavy for an MCP call. It is delegated to the refresh cron (follow-up migration),
--   which builds the stalest venues per tick server-side (pg_cron, no connector limit).
--
-- KEY ARCHITECTURE NOTE (do not re-discover):
--   The venue map's canonical section namespace = seatmap_manifest.section_keys
--   (TEvo, per venue + configuration_id). Multiple configs per venue are UNIONed
--   in this first cut; per-event configuration selection is future work
--   (configuration_id is left NULL on rows for now). Sections are joined on the
--   normalized token, NEVER raw string equality (exact match alone places ~2-24%).
--   See PROJECT_BIBLE §3 (seat-map naming landmine) + the seat-map analysis thread.

-- ── PART 1: section-normalization token functions ────────────────────────────
-- venue_section_token: strip a leading descriptor ("Field Infield 112" -> "112")
-- via the house td_normalize_section helper, lowercase, and strip leading zeros
-- on the numeric run ("014b" -> "14b", "0112" -> "112"). Pure-text tokens
-- ("ga", "pit left") pass through for exact-token matching.
CREATE OR REPLACE FUNCTION public.venue_section_token(p_section text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN p_section IS NULL OR btrim(p_section) = '' THEN NULL
    ELSE nullif(
      regexp_replace(
        lower(btrim(public.td_normalize_section(p_section))),
        '^0+([0-9])', '\1'                       -- drop leading zeros on the numeric run
      ), '')
  END;
$function$;

COMMENT ON FUNCTION public.venue_section_token(text) IS
  'Canonical seat-map join token. Applied identically to seatmap_manifest.section_keys and to every platform''s raw section string. Composes td_normalize_section (descriptor strip) + leading-zero strip + lower. "Field Infield 112"->"112", "014b"->"14b".';

-- venue_section_token_base: leading-integer core of the token. Recovers a/b
-- field splits ("14b" -> "14") and space-letter variants ("117 a" -> "117")
-- against single-polygon seatmap keys. NULL for non-numeric tokens.
CREATE OR REPLACE FUNCTION public.venue_section_token_base(p_section text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (regexp_match(coalesce(public.venue_section_token(p_section), ''), '^([0-9]+)'))[1];
$function$;

COMMENT ON FUNCTION public.venue_section_token_base(text) IS
  'Leading-integer core of venue_section_token (e.g. "14b"->"14", "117 a"->"117"). Fallback match tier that bridges a/b sub-section splits to a single parent seatmap polygon. NULL when the token has no leading integer.';

-- vsm_listing_token: PLATFORM-AWARE listing-side tokenizer. The seatmap-key side
-- always uses venue_section_token (keys are TEvo descriptive names). Listings differ
-- by platform: EVO uses bare/descriptor-numbered codes ("014b","field infield 112")
-- -> venue_section_token. SG/TP/VD/SH add alpha-prefix-numeric codes ("BAL316","CL227")
-- with NO space, so we peel a leading 1-4 letter prefix on '^[a-z]{1,4}\d' strings
-- ("bal316"->"316"). The peel is NOT applied to EVO (its alphanumerics like "a1" are
-- distinct suites, not numbered seats — peeling would create false matches).
CREATE OR REPLACE FUNCTION public.vsm_listing_token(p_section text, p_platform text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN p_section IS NULL OR btrim(p_section) = '' THEN NULL
    WHEN p_platform = 'evo' THEN public.venue_section_token(p_section)
    ELSE nullif(regexp_replace(
      CASE WHEN lower(btrim(public.td_normalize_section(p_section))) ~ '^[a-z]{1,4}[0-9]'
           THEN regexp_replace(lower(btrim(public.td_normalize_section(p_section))), '^[a-z]+', '')
           ELSE lower(btrim(public.td_normalize_section(p_section))) END,
      '^0+([0-9])', '\1'), '')
  END;
$function$;

CREATE OR REPLACE FUNCTION public.vsm_listing_token_base(p_section text, p_platform text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (regexp_match(coalesce(public.vsm_listing_token(p_section, p_platform), ''), '^([0-9]+)'))[1];
$function$;

COMMENT ON FUNCTION public.vsm_listing_token(text, text) IS
  'Platform-aware listing-side seat token. evo -> venue_section_token; sg/tp/vd/sh additionally peel a leading 1-4 letter prefix ("BAL316"->"316"). Matched against venue_section_token of the seatmap keys.';

-- ── PART 2: the crosswalk table ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.venue_section_map (
  tevo_venue_id      bigint  NOT NULL,
  platform           text    NOT NULL
                       CHECK (platform IN ('evo','sg','tp','vd','sh')),
  section_raw        text    NOT NULL,           -- platform's section string (lowercased, trimmed)
  section_token      text,                       -- venue_section_token(section_raw)
  section_token_base text,                       -- venue_section_token_base(section_raw)
  seatmap_key        text,                       -- matched seatmap_manifest key (NULL when unmatched)
  configuration_id   integer,                    -- seatmap config the key came from (NULL in v1 — see header)
  match_method       text    NOT NULL
                       CHECK (match_method IN ('exact','token','token_ambiguous',
                                               'token_base','token_base_ambiguous','manual','unmatched')),
  confidence         numeric NOT NULL DEFAULT 0, -- 1.0 exact / 0.9 token / 0.5 token_ambig / 0.75 base / 0.45 base_ambig / 0 unmatched
  candidate_keys     text[],                     -- all keys the token hit when ambiguous (else NULL)
  seen_listings      integer,                    -- support: # listing rows with this raw section in the window
  first_seen_at      timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tevo_venue_id, platform, section_raw)
);

CREATE INDEX IF NOT EXISTS idx_venue_section_map_venue_platform
  ON public.venue_section_map (tevo_venue_id, platform);
CREATE INDEX IF NOT EXISTS idx_venue_section_map_unmatched
  ON public.venue_section_map (tevo_venue_id, platform)
  WHERE match_method = 'unmatched';

COMMENT ON TABLE public.venue_section_map IS
  'Cross-platform seat-map crosswalk: for each (venue, platform, raw section string) the matched seatmap_manifest polygon key + method/confidence. Lets the terminal plot live inventory onto a venue seat map. Written only by build_venue_section_map() (SECURITY DEFINER). EVO populated 2026-06-08; sg/tp/vd/sh extend later via the same token fns.';

-- Reference data — RLS on, read-only to authenticated; writes are via the SECDEF
-- builder (which runs as owner and bypasses RLS).
ALTER TABLE public.venue_section_map ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS venue_section_map_read ON public.venue_section_map;
CREATE POLICY venue_section_map_read ON public.venue_section_map
  FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.venue_section_map TO authenticated;

-- ── PART 3: per-venue builder (EVO) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.build_venue_section_map(
  p_venue_id bigint,
  p_platform text     DEFAULT 'evo',
  p_window   interval DEFAULT interval '7 days'
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now   timestamptz := now();
  v_count integer := 0;
BEGIN
  IF p_platform NOT IN ('evo','sg') THEN
    RAISE EXCEPTION
      'build_venue_section_map: platform % source not yet wired. evo + sg are live; tp/vd/sh need their per-platform listings source added to the raw CTE (TD pulls / SeatData).', p_platform
      USING ERRCODE = '0A000';
  END IF;

  WITH keys AS (  -- seatmap namespace for this venue (DISTINCT: a venue has
                  -- multiple seatmap configs that repeat the same section_key —
                  -- without DISTINCT the exact-match join fans out and the upsert
                  -- hits the same PK twice: "ON CONFLICT cannot affect row a second time")
    SELECT DISTINCT
           public.venue_section_token(k)      AS tok,
           public.venue_section_token_base(k) AS tok_base,
           lower(btrim(k))                    AS seatmap_key
    FROM public.seatmap_manifest sm
    CROSS JOIN LATERAL unnest(sm.section_keys) AS k
    WHERE sm.venue_id = p_venue_id AND sm.has_map
  ),
  keytok AS (
    SELECT tok,
           count(DISTINCT seatmap_key)         AS nkeys,
           (array_agg(DISTINCT seatmap_key))[1] AS first_key,
           array_agg(DISTINCT seatmap_key)      AS all_keys
    FROM keys WHERE tok IS NOT NULL GROUP BY tok
  ),
  keybase AS (
    SELECT tok_base,
           count(DISTINCT seatmap_key)         AS nkeys,
           (array_agg(DISTINCT seatmap_key))[1] AS first_key,
           array_agg(DISTINCT seatmap_key)      AS all_keys
    FROM keys WHERE tok_base IS NOT NULL GROUP BY tok_base
  ),
  raw AS (  -- distinct seat sections at this venue, per platform (parking excluded)
    SELECT lower(btrim(s)) AS section_raw, count(*) AS seen
    FROM (
      -- EVO firehose (type=event drops parking; is_ancillary drops ancillary)
      SELECT ls.section AS s
      FROM public.listings_snapshots ls
      WHERE p_platform = 'evo'
        AND ls.event_id IN (SELECT id FROM public.events WHERE venue_id = p_venue_id)
        AND ls.captured_at > v_now - p_window
        AND ls.type = 'event' AND ls.is_ancillary = false
      UNION ALL
      -- SeatGeek listings, joined to the venue's events via aq_event_map.sg_event_id
      SELECT sl.section AS s
      FROM public.seatgeek_listings_snapshots sl
      WHERE p_platform = 'sg'
        AND sl.sg_event_id IN (
          SELECT m.sg_event_id FROM public.aq_event_map m
          JOIN public.events e ON e.id = m.tevo_event_id
          WHERE e.venue_id = p_venue_id AND m.sg_event_id IS NOT NULL)
        AND sl.captured_at > v_now - p_window
    ) u
    WHERE s IS NOT NULL AND btrim(s) <> ''
    GROUP BY 1
  ),
  scored AS (
    SELECT r.section_raw, r.seen,
           public.vsm_listing_token(r.section_raw, p_platform)      AS tok,
           public.vsm_listing_token_base(r.section_raw, p_platform) AS tok_base,
           kx.seatmap_key AS exact_key,
           kt.nkeys AS kt_n, kt.first_key AS kt_key, kt.all_keys AS kt_keys,
           kb.nkeys AS kb_n, kb.first_key AS kb_key, kb.all_keys AS kb_keys
    FROM raw r
    LEFT JOIN keys    kx ON kx.seatmap_key = r.section_raw
    LEFT JOIN keytok  kt ON kt.tok      = public.vsm_listing_token(r.section_raw, p_platform)
    LEFT JOIN keybase kb ON kb.tok_base = public.vsm_listing_token_base(r.section_raw, p_platform)
  ),
  classed AS (
    -- tiers, highest confidence first. token_base* bridge a/b sub-section splits
    -- ("014a"/"014b" -> parent section "14"); ambiguous = the base hits >1 polygon
    -- (the a/b sub-polygons), still plottable to the parent, flagged lower-confidence.
    SELECT section_raw, seen, tok, tok_base,
      CASE
        WHEN exact_key IS NOT NULL             THEN 'exact'
        WHEN kt_n = 1                          THEN 'token'
        WHEN kt_n > 1                          THEN 'token_ambiguous'
        WHEN tok_base IS NOT NULL AND kb_n = 1 THEN 'token_base'
        WHEN tok_base IS NOT NULL AND kb_n > 1 THEN 'token_base_ambiguous'
        ELSE 'unmatched'
      END AS method,
      CASE
        WHEN exact_key IS NOT NULL             THEN exact_key
        WHEN kt_n = 1                          THEN kt_key
        WHEN kt_n > 1                          THEN kt_key   -- deterministic: first key alphabetically
        WHEN tok_base IS NOT NULL AND kb_n >= 1 THEN kb_key
        ELSE NULL
      END AS seatmap_key,
      CASE
        WHEN kt_n > 1                           THEN kt_keys
        WHEN coalesce(kt_n,0) = 0 AND tok_base IS NOT NULL AND kb_n > 1 THEN kb_keys
        ELSE NULL
      END AS candidate_keys
    FROM scored
  )
  INSERT INTO public.venue_section_map AS m
    (tevo_venue_id, platform, section_raw, section_token, section_token_base,
     seatmap_key, configuration_id, match_method, confidence,
     candidate_keys, seen_listings, first_seen_at, updated_at)
  SELECT p_venue_id, p_platform, section_raw, tok, tok_base,
         seatmap_key, NULL,
         method,
         CASE method
           WHEN 'exact'                THEN 1.0
           WHEN 'token'                THEN 0.9
           WHEN 'token_base'           THEN 0.75
           WHEN 'token_ambiguous'      THEN 0.5
           WHEN 'token_base_ambiguous' THEN 0.45
           ELSE 0
         END,
         candidate_keys, seen, v_now, v_now
  FROM classed
  ON CONFLICT (tevo_venue_id, platform, section_raw) DO UPDATE
    SET section_token      = excluded.section_token,
        section_token_base = excluded.section_token_base,
        seatmap_key        = excluded.seatmap_key,
        match_method       = excluded.match_method,
        confidence         = excluded.confidence,
        candidate_keys     = excluded.candidate_keys,
        seen_listings      = excluded.seen_listings,
        updated_at         = excluded.updated_at;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

COMMENT ON FUNCTION public.build_venue_section_map(bigint, text, interval) IS
  'Populate venue_section_map for one venue (EVO). Reads the venue''s seatmap_manifest section_keys and the distinct non-parking (type=event, not ancillary) EVO listing sections in the window, classifies each via exact/token/token_base tiers, and upserts. Returns rows upserted.';

-- ── PART 4: bounded driver ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.build_venue_section_map_all(
  p_platform   text     DEFAULT 'evo',
  p_max_venues integer  DEFAULT 500,
  p_window     interval DEFAULT interval '7 days'
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_venue  bigint;
  v_venues integer := 0;
BEGIN
  IF p_platform NOT IN ('evo','sg') THEN
    RAISE EXCEPTION 'build_venue_section_map_all: platform % source not yet wired', p_platform
      USING ERRCODE = '0A000';
  END IF;

  FOR v_venue IN
    SELECT DISTINCT sm.venue_id
    FROM public.seatmap_manifest sm
    WHERE sm.has_map
      AND EXISTS (SELECT 1 FROM public.events e WHERE e.venue_id = sm.venue_id)
    ORDER BY sm.venue_id
    LIMIT p_max_venues
  LOOP
    PERFORM public.build_venue_section_map(v_venue, p_platform, p_window);
    v_venues := v_venues + 1;
  END LOOP;

  RETURN v_venues;
END;
$function$;

COMMENT ON FUNCTION public.build_venue_section_map_all(text, integer, interval) IS
  'Bounded driver: rebuilds venue_section_map (EVO) for every has_map venue present in events. Per-venue work is bounded (one venue per build call), avoiding a firehose-wide scan. Returns venue count processed. Run by A1 post-apply; a future cron will call it on a cadence.';

-- builder fns are admin/cron-only — never anon/authenticated executable.
-- NOTE: REVOKE FROM public alone is NOT enough — Supabase grants EXECUTE to anon +
-- authenticated on public functions by default, so they must be revoked explicitly
-- (else callable via /rest/v1/rpc). Caught by the security advisor 2026-06-08.
REVOKE EXECUTE ON FUNCTION public.build_venue_section_map(bigint, text, interval)      FROM anon, authenticated, public;
REVOKE EXECUTE ON FUNCTION public.build_venue_section_map_all(text, integer, interval) FROM anon, authenticated, public;

-- ── PART 5: coverage surface ─────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_venue_section_map_coverage
WITH (security_invoker = true) AS
SELECT
  m.tevo_venue_id,
  m.platform,
  (SELECT e.venue_name FROM public.events e
    WHERE e.venue_id = m.tevo_venue_id AND e.venue_name IS NOT NULL
    LIMIT 1)                                                  AS venue_name,
  count(*)                                                    AS sections,
  count(*) FILTER (WHERE m.match_method <> 'unmatched')       AS mapped,
  count(*) FILTER (WHERE m.match_method = 'unmatched')        AS unmapped,
  count(*) FILTER (WHERE m.match_method IN ('token_ambiguous','token_base_ambiguous')) AS ambiguous,
  count(*) FILTER (WHERE m.match_method = 'exact')            AS exact_matches,
  round(100.0 * count(*) FILTER (WHERE m.match_method = 'unmatched')
        / nullif(count(*), 0), 1)                             AS unmapped_pct,
  max(m.updated_at)                                           AS last_built
FROM public.venue_section_map m
GROUP BY m.tevo_venue_id, m.platform;

COMMENT ON VIEW public.v_venue_section_map_coverage IS
  'Per-venue/platform seat-map coverage: sections, mapped, unmapped, ambiguous, unmapped_pct. The meaningful "unmapped percentage" surface (parking already excluded by the builder). Order by unmapped_pct DESC to find the venues where the seat map plots the least inventory.';

GRANT SELECT ON public.v_venue_section_map_coverage TO authenticated;

-- ── PART 6: refresh batch + cron (Step 3) ────────────────────────────────────
-- Applied live to prod 2026-06-08. Drives the initial backfill AND ongoing
-- freshness: a one-shot build_venue_section_map_all over ~366 venues is too heavy
-- for one transaction, so a cron builds the stalest combos per tick instead.
CREATE OR REPLACE FUNCTION public.build_venue_section_map_batch(
  p_batch integer DEFAULT 25, p_window interval DEFAULT interval '7 days'
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r record; v_n integer := 0;
BEGIN
  FOR r IN
    WITH cand AS (
      SELECT v.venue_id, p.platform
      FROM (SELECT DISTINCT sm.venue_id FROM public.seatmap_manifest sm
            WHERE sm.has_map AND EXISTS(SELECT 1 FROM public.events e WHERE e.venue_id=sm.venue_id)) v
      CROSS JOIN (VALUES ('evo'),('sg')) p(platform)
    ),
    last AS (SELECT tevo_venue_id, platform, max(updated_at) AS lb FROM public.venue_section_map GROUP BY 1,2)
    SELECT c.venue_id, c.platform
    FROM cand c LEFT JOIN last l ON l.tevo_venue_id=c.venue_id AND l.platform=c.platform
    ORDER BY l.lb ASC NULLS FIRST, c.venue_id           -- never-built first, then oldest
    LIMIT p_batch
  LOOP
    BEGIN  -- per-venue subtransaction: a single failing venue can't roll back the
           -- whole tick and stall the backfill (it would always be the stalest).
      PERFORM public.build_venue_section_map(r.venue_id, r.platform, p_window);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'build_venue_section_map_batch: skipped venue % platform %: %', r.venue_id, r.platform, SQLERRM;
    END;
  END LOOP;
  RETURN v_n;
END; $function$;
COMMENT ON FUNCTION public.build_venue_section_map_batch(integer, interval) IS
  'Refresh batch: builds the p_batch stalest (venue,platform) combos across evo+sg (never-built first, then oldest updated_at). Per-venue subtransaction so one poison venue cannot stall the backfill. Drives initial backfill + ongoing freshness from the venue_section_map_refresh cron.';
REVOKE EXECUTE ON FUNCTION public.build_venue_section_map_batch(integer, interval) FROM anon, authenticated, public;

-- cron_policy row (gate) + schedule. cron.schedule is idempotent by jobname.
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, enabled, notes)
VALUES ('venue_section_map_refresh',
  ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
  10, 10, NULL, 144, true,
  'Seat-map crosswalk refresh. 25 stalest (venue,platform) combos/tick across evo+sg.')
ON CONFLICT (jobname) DO UPDATE SET enabled=excluded.enabled, peak_min_interval_min=excluded.peak_min_interval_min, notes=excluded.notes, updated_at=now();

SELECT cron.schedule('venue_section_map_refresh', '*/10 * * * *', $cron$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('venue_section_map_refresh') THEN RETURN; END IF;
  PERFORM public.build_venue_section_map_batch(25);
END $body$;
$cron$);
