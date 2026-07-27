-- Migration 20260515280000 · level:admin · lane:Audit/Push · writes:match_tevo_to_sg_canonical() fn, sg_canonical_link_from_tevo_chunked() fn, sg_canonical_link_overnight cron · pre:20260515270100
-- Operator directive 2026-05-14: "use the aq method from before, it should be default
-- mapper for all events until it stops working."
--
-- Extends the universal 4-tier matcher pattern (Tier 2 venue+date exact -> Tier 3 fuzzy
-- -> Tier 4 coord+date) against sg_events_canonical instead of aq_event_map. For each
-- TEvo event lacking a sg_event_id link in sg_canonical, the cron nightly attempts
-- match and UPDATEs the canonical row's tevo_event_id when successful.
--
-- ## Match coverage expectation
-- Bounded by sg_events_canonical population. The 5k currently-seeded SG events catch
-- mostly AQ-curated games. As other ingest paths (per-window collectors, sales orphans)
-- grow sg_canonical, this matcher catches more on subsequent runs. Self-healing.
--
-- Smoke (2026-05-14): 200-event sample produced 6 matches (1 tier2, 5 tier3). 1,376
-- TEvo events remaining in the unlinked-with-listings backlog as of apply time.
--
-- ## Already applied to prod  Applied via MCP 2026-05-14.

CREATE OR REPLACE FUNCTION public.match_tevo_to_sg_canonical(
  p_event_name  text,
  p_venue_name  text,
  p_event_date  timestamptz,
  p_venue_id    bigint DEFAULT NULL,
  p_lat         numeric DEFAULT NULL,
  p_lon         numeric DEFAULT NULL
)
RETURNS TABLE (sg_event_id bigint, confidence numeric(3,2), match_method text)
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_sg_id bigint;
BEGIN
  IF p_venue_name IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT c.sg_event_id INTO v_sg_id FROM public.sg_events_canonical c
    WHERE lower(trim(c.sg_venue_name)) = lower(trim(p_venue_name))
      AND c.sg_datetime_utc BETWEEN p_event_date - interval '6 hours' AND p_event_date + interval '6 hours'
    ORDER BY abs(extract(epoch FROM (c.sg_datetime_utc - p_event_date))) LIMIT 1;
    IF v_sg_id IS NOT NULL THEN
      RETURN QUERY SELECT v_sg_id, 0.95::numeric(3,2), 'tier2_venue_exact_date'::text;
      RETURN;
    END IF;
  END IF;

  IF p_venue_name IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT c.sg_event_id INTO v_sg_id FROM public.sg_events_canonical c
    WHERE similarity(lower(coalesce(c.sg_venue_name,'')), lower(coalesce(p_venue_name,''))) >= 0.7
      AND c.sg_datetime_utc BETWEEN p_event_date - interval '6 hours' AND p_event_date + interval '6 hours'
    ORDER BY similarity(lower(c.sg_venue_name), lower(p_venue_name)) DESC,
             abs(extract(epoch FROM (c.sg_datetime_utc - p_event_date))) LIMIT 1;
    IF v_sg_id IS NOT NULL THEN
      RETURN QUERY SELECT v_sg_id, 0.80::numeric(3,2), 'tier3_venue_fuzzy_date'::text;
      RETURN;
    END IF;
  END IF;

  IF p_lat IS NOT NULL AND p_lon IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT c.sg_event_id INTO v_sg_id
    FROM public.sg_events_canonical c
    JOIN public.venue_assets va ON lower(trim(va.venue_name)) = lower(trim(c.sg_venue_name))
    WHERE va.latitude  BETWEEN p_lat - 0.01 AND p_lat + 0.01
      AND va.longitude BETWEEN p_lon - 0.02 AND p_lon + 0.02
      AND c.sg_datetime_utc BETWEEN p_event_date - interval '6 hours' AND p_event_date + interval '6 hours'
    ORDER BY (2 * 6371000 * asin(sqrt(
       power(sin(radians((va.latitude  - p_lat)/2)), 2)
       + cos(radians(p_lat)) * cos(radians(va.latitude))
         * power(sin(radians((va.longitude - p_lon)/2)), 2)
    ))) LIMIT 1;
    IF v_sg_id IS NOT NULL THEN
      RETURN QUERY SELECT v_sg_id, 0.85::numeric(3,2), 'tier4_coord_date'::text;
      RETURN;
    END IF;
  END IF;

  RETURN;
END $$;

CREATE OR REPLACE FUNCTION public.sg_canonical_link_from_tevo_chunked(p_max_events int DEFAULT 100)
RETURNS TABLE (events_processed int, matches_made int, tier_breakdown jsonb, events_remaining int)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  r RECORD; m RECORD;
  v_proc int := 0; v_matched int := 0;
  v_tiers jsonb := '{}'::jsonb;
  v_remaining int;
BEGIN
  FOR r IN
    SELECT e.id, e.name, e.venue_name, e.venue_id, e.occurs_at_local,
           (SELECT latitude  FROM venue_assets WHERE tevo_venue_id = e.venue_id) AS lat,
           (SELECT longitude FROM venue_assets WHERE tevo_venue_id = e.venue_id) AS lon
    FROM public.events e
    WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '90 days'
      AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical WHERE tevo_event_id = e.id)
    ORDER BY e.occurs_at_local LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    SELECT * INTO m FROM public.match_tevo_to_sg_canonical(
      r.name, r.venue_name, r.occurs_at_local::timestamptz, r.venue_id, r.lat, r.lon
    ) LIMIT 1;
    IF m.sg_event_id IS NOT NULL THEN
      UPDATE public.sg_events_canonical
        SET tevo_event_id = r.id,
            match_method  = m.match_method,
            match_confidence = m.confidence,
            matched_at = now()
        WHERE sg_event_id = m.sg_event_id
          AND (tevo_event_id IS NULL OR tevo_event_id = r.id);
      IF FOUND THEN
        v_matched := v_matched + 1;
        v_tiers := v_tiers || jsonb_build_object(m.match_method, coalesce((v_tiers->>m.match_method)::int, 0) + 1);
      END IF;
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
  SELECT count(*) INTO v_remaining FROM public.events e
    WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '90 days'
      AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical WHERE tevo_event_id = e.id);
  RETURN QUERY SELECT v_proc, v_matched, v_tiers, v_remaining;
END $func$;

-- Overnight cron at 04:46-04:59 UTC (12:46-12:59 AM ET, after deltas backfill 04:30-04:44)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='sg_canonical_link_overnight') THEN
    PERFORM cron.schedule(
      'sg_canonical_link_overnight',
      '46-59 4 * * *',
      $cron$
        DO $body$ DECLARE v_remaining int;
        BEGIN
          SELECT events_remaining INTO v_remaining FROM public.sg_canonical_link_from_tevo_chunked(100);
          IF coalesce(v_remaining, 0) = 0 THEN
            PERFORM cron.unschedule('sg_canonical_link_overnight');
          END IF;
        END $body$;
      $cron$
    );
  END IF;
END $$;
