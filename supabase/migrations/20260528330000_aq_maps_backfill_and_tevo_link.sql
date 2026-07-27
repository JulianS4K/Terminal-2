-- 20260528330000_aq_maps_backfill_and_tevo_link.sql
--
-- Fills cross-platform gaps in aq_event_map / aq_venue_map / aq_performer_map
-- and adds a maintained backfill function + daily cron.
--
-- Problem: aq_event_map has no tevo_event_id column, so match_to_aq_event_id()
-- falls through to slow venue+date fuzzy matching on every TEvo-sourced call.
-- We already have tevo_event_id in sg_events_canonical (4,413 events linked).
-- Adding the column and a tier-0 lookup makes the match essentially instant.
--
-- Fills (one-time backfill + ongoing daily maintenance):
--   A. aq_event_map.tevo_event_id (new column) — 4,413 rows via sg_events_canonical
--   B. aq_event_map.sg_event_id (missing) — 21 rows via sg_venue_name + date ±4h
--   C. aq_event_map.venue_short_id (missing) — 629 rows via aq_venue_map name match
--   D. aq_venue_map.tevo_venue_id (missing) — 228 venues via events.venue_name match
--   E. aq_performer_map.tevo_performer_id (missing) — 81 performers via performer_name match
--   F. match_to_aq_event_id() updated: tier0 = tevo_event_id direct lookup (fastest path)
--   G. backfill_aq_maps() function + daily cron for ongoing maintenance


-- ─── Part A: add tevo_event_id to aq_event_map ───────────────────────────────

ALTER TABLE public.aq_event_map
  ADD COLUMN IF NOT EXISTS tevo_event_id bigint;

CREATE INDEX IF NOT EXISTS aq_event_map_tevo_event_id_idx
  ON public.aq_event_map (tevo_event_id)
  WHERE tevo_event_id IS NOT NULL;

-- Fill from sg_events_canonical: sg_event_id → tevo_event_id
UPDATE public.aq_event_map aem
SET tevo_event_id = e.tevo_event_id
FROM public.sg_events_canonical e
WHERE e.sg_event_id = aem.sg_event_id
  AND e.tevo_event_id IS NOT NULL
  AND aem.tevo_event_id IS NULL;


-- ─── Part B: fill aq_event_map.sg_event_id via sg_venue_name + date ──────────

UPDATE public.aq_event_map aem
SET sg_event_id = sub.sg_event_id
FROM (
  SELECT DISTINCT ON (aem2.aq_short_event_id)
    aem2.aq_short_event_id,
    e.sg_event_id
  FROM public.aq_event_map aem2
  JOIN public.sg_events_canonical e
    ON lower(trim(e.sg_venue_name)) = lower(trim(aem2.venue_name))
    AND aem2.event_date::timestamptz
        BETWEEN e.sg_datetime_utc - interval '4 hours'
            AND e.sg_datetime_utc + interval '4 hours'
  WHERE aem2.sg_event_id IS NULL
    AND e.sg_event_id IS NOT NULL
  ORDER BY aem2.aq_short_event_id,
    abs(extract(epoch FROM (aem2.event_date::timestamptz - e.sg_datetime_utc)))
) sub
WHERE aem.aq_short_event_id = sub.aq_short_event_id;

-- Cascade: now fill tevo_event_id for the newly linked sg_event_ids
UPDATE public.aq_event_map aem
SET tevo_event_id = e.tevo_event_id
FROM public.sg_events_canonical e
WHERE e.sg_event_id = aem.sg_event_id
  AND e.tevo_event_id IS NOT NULL
  AND aem.tevo_event_id IS NULL;


-- ─── Part C: fill aq_event_map.venue_short_id from aq_venue_map ──────────────

UPDATE public.aq_event_map aem
SET venue_short_id = sub.venue_short_id
FROM (
  SELECT DISTINCT ON (aem2.aq_short_event_id)
    aem2.aq_short_event_id,
    avm.venue_short_id
  FROM public.aq_event_map aem2
  JOIN public.aq_venue_map avm
    ON lower(trim(avm.venue_name)) = lower(trim(aem2.venue_name))
  WHERE aem2.venue_short_id IS NULL
    AND aem2.venue_name IS NOT NULL
  ORDER BY aem2.aq_short_event_id
) sub
WHERE aem.aq_short_event_id = sub.aq_short_event_id;


-- ─── Part D: fill aq_venue_map.tevo_venue_id from events table ───────────────

-- Pick the most-common venue_id per lowercase venue_name to handle duplicates
UPDATE public.aq_venue_map avm
SET tevo_venue_id = bv.venue_id
FROM (
  WITH counts AS (
    SELECT lower(trim(venue_name)) AS vname_lower,
           venue_id,
           COUNT(*) AS n
    FROM   public.events
    WHERE  venue_id IS NOT NULL AND venue_name IS NOT NULL
    GROUP  BY lower(trim(venue_name)), venue_id
  )
  SELECT DISTINCT ON (vname_lower) vname_lower, venue_id
  FROM   counts
  ORDER  BY vname_lower, n DESC
) bv
WHERE lower(trim(avm.venue_name)) = bv.vname_lower
  AND avm.tevo_venue_id IS NULL;


-- ─── Part E: fill aq_performer_map.tevo_performer_id from events table ───────

UPDATE public.aq_performer_map apm
SET tevo_performer_id = bp.performer_id
FROM (
  WITH counts AS (
    SELECT lower(trim(primary_performer_name)) AS pname_lower,
           primary_performer_id                AS performer_id,
           COUNT(*)                            AS n
    FROM   public.events
    WHERE  primary_performer_id IS NOT NULL AND primary_performer_name IS NOT NULL
    GROUP  BY lower(trim(primary_performer_name)), primary_performer_id
  )
  SELECT DISTINCT ON (pname_lower) pname_lower, performer_id
  FROM   counts
  ORDER  BY pname_lower, n DESC
) bp
WHERE lower(trim(apm.performer_name)) = bp.pname_lower
  AND apm.tevo_performer_id IS NULL;


-- ─── Part F: update match_to_aq_event_id — add tevo_event_id tier0 ───────────

CREATE OR REPLACE FUNCTION public.match_to_aq_event_id(
  p_source          text,
  p_source_event_id bigint,
  p_event_name      text,
  p_venue_name      text,
  p_event_date      timestamp with time zone,
  p_lat             numeric DEFAULT NULL,
  p_lon             numeric DEFAULT NULL,
  p_source_venue_id bigint DEFAULT NULL
)
RETURNS TABLE(aq_short_event_id text, confidence numeric, match_method text)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  v_aq_id          text;
  v_venue_short_id text;
BEGIN
  -- Tier 0: tevo_event_id direct lookup (fastest — resolves instantly when source is TEvo)
  IF p_source_event_id IS NOT NULL AND p_source IN ('tevo', 'evo') THEN
    SELECT a.aq_short_event_id INTO v_aq_id
    FROM public.aq_event_map a
    WHERE a.tevo_event_id = p_source_event_id
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 1.00::numeric(3,2), 'tier0_tevo_id'::text;
      RETURN;
    END IF;
  END IF;

  -- Tier 1: platform-native event_id direct lookup
  IF p_source_event_id IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE (p_source IN ('vivid')              AND a.vivid_event_id = p_source_event_id)
       OR (p_source IN ('seatgeek','sg')      AND a.sg_event_id    = p_source_event_id)
       OR (p_source IN ('stubhub','sh')       AND a.sh_event_id    = p_source_event_id)
       OR (p_source IN ('ticketmaster','tm')  AND a.tm_event_id    = p_source_event_id)
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 1.00::numeric(3,2), 'tier1_direct_id'::text;
      RETURN;
    END IF;
  END IF;

  -- Tier 1.5: source venue_id → aq_venue_map → venue_short_id → event date match
  IF p_source_venue_id IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT m.venue_short_id INTO v_venue_short_id FROM public.aq_venue_map m
    WHERE (p_source IN ('tickpick')         AND m.tickpick_venue_id = p_source_venue_id)
       OR (p_source IN ('seatgeek','sg')    AND m.sg_venue_id       = p_source_venue_id)
       OR (p_source IN ('tevo','evo')       AND m.tevo_venue_id     = p_source_venue_id)
    LIMIT 1;
    IF v_venue_short_id IS NOT NULL THEN
      SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
      WHERE a.venue_short_id = v_venue_short_id
        AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                          AND p_event_date + interval '6 hours'
      ORDER BY abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date)))
      LIMIT 1;
      IF v_aq_id IS NOT NULL THEN
        RETURN QUERY SELECT v_aq_id, 0.93::numeric(3,2), 'tier1_5_venue_id_date'::text;
        RETURN;
      END IF;
    END IF;
  END IF;

  -- Tier 2: venue name exact + date ±6h
  IF p_venue_name IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE lower(trim(a.venue_name)) = lower(trim(p_venue_name))
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date)))
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.95::numeric(3,2), 'tier2_venue_exact_date'::text;
      RETURN;
    END IF;
  END IF;

  -- Tier 3: venue name fuzzy (similarity ≥ 0.7) + date ±6h
  IF p_venue_name IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE similarity(lower(coalesce(a.venue_name,'')), lower(coalesce(p_venue_name,''))) >= 0.7
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY similarity(lower(a.venue_name), lower(p_venue_name)) DESC,
             abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date)))
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.80::numeric(3,2), 'tier3_venue_fuzzy_date'::text;
      RETURN;
    END IF;
  END IF;

  -- Tier 4: coordinate proximity + date ±6h
  IF p_lat IS NOT NULL AND p_lon IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id
    FROM public.aq_event_map a
    JOIN public.venue_assets va ON lower(trim(va.venue_name)) = lower(trim(a.venue_name))
    WHERE va.latitude  BETWEEN p_lat - 0.01 AND p_lat + 0.01
      AND va.longitude BETWEEN p_lon - 0.02 AND p_lon + 0.02
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY (2 * 6371000 * asin(sqrt(
       power(sin(radians((va.latitude  - p_lat)/2)), 2)
       + cos(radians(p_lat)) * cos(radians(va.latitude))
         * power(sin(radians((va.longitude - p_lon)/2)), 2)
    )))
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.85::numeric(3,2), 'tier4_coord_date'::text;
      RETURN;
    END IF;
  END IF;

  RETURN;
END;
$$;


-- ─── Part G: backfill_aq_maps() — maintenance function ───────────────────────

CREATE OR REPLACE FUNCTION public.backfill_aq_maps()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  v_ev_tevo  int := 0;
  v_ev_sg    int := 0;
  v_ev_vsid  int := 0;
  v_venue    int := 0;
  v_perf     int := 0;
BEGIN
  -- 1. aq_event_map.tevo_event_id from sg_events_canonical
  UPDATE public.aq_event_map aem
  SET tevo_event_id = e.tevo_event_id
  FROM public.sg_events_canonical e
  WHERE e.sg_event_id = aem.sg_event_id
    AND e.tevo_event_id IS NOT NULL
    AND aem.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_ev_tevo = ROW_COUNT;

  -- 2. aq_event_map.sg_event_id via sg_venue_name + date (missing links)
  UPDATE public.aq_event_map aem
  SET sg_event_id = sub.sg_event_id
  FROM (
    SELECT DISTINCT ON (aem2.aq_short_event_id)
      aem2.aq_short_event_id, e.sg_event_id
    FROM public.aq_event_map aem2
    JOIN public.sg_events_canonical e
      ON lower(trim(e.sg_venue_name)) = lower(trim(aem2.venue_name))
      AND aem2.event_date::timestamptz
          BETWEEN e.sg_datetime_utc - interval '4 hours'
              AND e.sg_datetime_utc + interval '4 hours'
    WHERE aem2.sg_event_id IS NULL AND e.sg_event_id IS NOT NULL
    ORDER BY aem2.aq_short_event_id,
      abs(extract(epoch FROM (aem2.event_date::timestamptz - e.sg_datetime_utc)))
  ) sub
  WHERE aem.aq_short_event_id = sub.aq_short_event_id;
  GET DIAGNOSTICS v_ev_sg = ROW_COUNT;

  -- Cascade tevo_event_id for newly linked sg_event_ids
  UPDATE public.aq_event_map aem
  SET tevo_event_id = e.tevo_event_id
  FROM public.sg_events_canonical e
  WHERE e.sg_event_id = aem.sg_event_id
    AND e.tevo_event_id IS NOT NULL
    AND aem.tevo_event_id IS NULL;

  -- 3. aq_event_map.venue_short_id from aq_venue_map
  UPDATE public.aq_event_map aem
  SET venue_short_id = sub.venue_short_id
  FROM (
    SELECT DISTINCT ON (aem2.aq_short_event_id)
      aem2.aq_short_event_id, avm.venue_short_id
    FROM public.aq_event_map aem2
    JOIN public.aq_venue_map avm
      ON lower(trim(avm.venue_name)) = lower(trim(aem2.venue_name))
    WHERE aem2.venue_short_id IS NULL AND aem2.venue_name IS NOT NULL
    ORDER BY aem2.aq_short_event_id
  ) sub
  WHERE aem.aq_short_event_id = sub.aq_short_event_id;
  GET DIAGNOSTICS v_ev_vsid = ROW_COUNT;

  -- 4. aq_venue_map.tevo_venue_id from events table
  UPDATE public.aq_venue_map avm
  SET tevo_venue_id = bv.venue_id
  FROM (
    WITH counts AS (
      SELECT lower(trim(venue_name)) AS vname_lower, venue_id, COUNT(*) AS n
      FROM   public.events
      WHERE  venue_id IS NOT NULL AND venue_name IS NOT NULL
      GROUP  BY lower(trim(venue_name)), venue_id
    )
    SELECT DISTINCT ON (vname_lower) vname_lower, venue_id
    FROM   counts ORDER BY vname_lower, n DESC
  ) bv
  WHERE lower(trim(avm.venue_name)) = bv.vname_lower
    AND avm.tevo_venue_id IS NULL;
  GET DIAGNOSTICS v_venue = ROW_COUNT;

  -- 5. aq_performer_map.tevo_performer_id from events table
  UPDATE public.aq_performer_map apm
  SET tevo_performer_id = bp.performer_id
  FROM (
    WITH counts AS (
      SELECT lower(trim(primary_performer_name)) AS pname_lower,
             primary_performer_id AS performer_id, COUNT(*) AS n
      FROM   public.events
      WHERE  primary_performer_id IS NOT NULL AND primary_performer_name IS NOT NULL
      GROUP  BY lower(trim(primary_performer_name)), primary_performer_id
    )
    SELECT DISTINCT ON (pname_lower) pname_lower, performer_id
    FROM   counts ORDER BY pname_lower, n DESC
  ) bp
  WHERE lower(trim(apm.performer_name)) = bp.pname_lower
    AND apm.tevo_performer_id IS NULL;
  GET DIAGNOSTICS v_perf = ROW_COUNT;

  RETURN jsonb_build_object(
    'ev_tevo_id',    v_ev_tevo,
    'ev_sg_id',      v_ev_sg,
    'ev_venue_sid',  v_ev_vsid,
    'venue_tevo_id', v_venue,
    'perf_tevo_id',  v_perf
  );
END;
$$;


-- ─── Part H: daily maintenance cron ──────────────────────────────────────────

SELECT cron.schedule(
  'aq_maps_backfill_daily',
  '0 5 * * *',
  $$DO $body$
    DECLARE v_result jsonb;
    BEGIN
      IF NOT public.cron_should_fire('aq_maps_backfill_daily') THEN RETURN; END IF;
      v_result := public.backfill_aq_maps();
      IF (v_result->>'ev_tevo_id')::int + (v_result->>'ev_sg_id')::int
         + (v_result->>'venue_tevo_id')::int + (v_result->>'perf_tevo_id')::int > 0 THEN
        PERFORM public.bot_chat_log('data-collection', 'D0', 'status',
          format('aq_maps_backfill: %s', v_result::text));
      END IF;
    END $body$;$$
);

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min)
VALUES ('aq_maps_backfill_daily', '{}'::int[], 1200, 1200)
ON CONFLICT (jobname) DO UPDATE SET
  peak_hours_et            = EXCLUDED.peak_hours_et,
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min;


-- ─── Immediate backfill + status log ─────────────────────────────────────────

DO $$
DECLARE v_result jsonb;
BEGIN
  v_result := public.backfill_aq_maps();
  PERFORM public.bot_chat_log(
    'data-collection', 'D0', 'status',
    format('mig 330000 aq_maps_backfill: %s', v_result::text)
  );
END $$;
