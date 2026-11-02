-- Migration 20261102200000 · level:data-collection · lane:A1 (AXS ingest + AQ hub) · writes:axs_aq_venue_map(new),axs_aq_venue_map_refresh()(new),v_axs_venues(new),aq_venue_map(INSERT system_seed rows on refresh),axs_venue_catalog_refresh()(calls the map refresh) · reads:axs_venue_catalog,aq_venue_map,aq_event_map,events · pre:20261102190000
--
-- ============================================================================
-- AXS venues → AQ venue ids (operator 2026-11-02: "build a list of AXS venues, then a table that
-- gives out the AQ venue, so we can map directly against the AQ catalogue in future").
--
-- v_axs_venues      the list: every venue axs_venue_catalog scores as AXS (or mixed), with its AQ id.
-- axs_aq_venue_map  one row per such venue: TEvo venue id, AQ venue_short_id, AXS venue id / page /
--                   directory name, SeatGeek venue ids, how the AQ id was found. Anything keyed on
--                   AXS (axs_events, axs_catalog, a future sitemap) joins to the AQ catalogue through it.
--
-- HOW THE AQ ID IS FOUND (first hit wins; checked 2026-11-02 on the 2,782 directory-name venues:
-- 310 via TEvo venue, 318 via aq_event_map, 10 where the two disagree — the TEvo link wins)
--   1. aq_tevo_venue   aq_venue_map.tevo_venue_id = the venue
--   2. aq_sg_venue     aq_venue_map.sg_venue_id ∈ the venue's SeatGeek venue ids
--   3. aq_event_map    every aq_event_map row for events at the venue names one venue_short_id
--   4. minted          none of the above: a system_seed aq_venue_map row is created with the
--                      deterministic aq_venue_short_id(name, city, state) — the same id scheme the
--                      171 existing system_seed venues use — and the TEvo venue id attached.
-- Refreshed at the end of axs_venue_catalog_refresh() (daily). Re-runs are idempotent: a mapped
-- venue keeps its id unless an earlier rule starts matching (e.g. a curated AQ venue appears).
-- Rollback: DROP VIEW v_axs_venues; DROP FUNCTION axs_aq_venue_map_refresh(); DROP TABLE axs_aq_venue_map;
--   DELETE FROM aq_venue_map WHERE aq_source = 'system_seed' AND imported_at >= '2026-11-02'
--     AND venue_short_id IN (SELECT venue_short_id FROM axs_aq_venue_map WHERE match_method = 'minted');
--   (run the DELETE before the DROP TABLE), then re-create axs_venue_catalog_refresh from mig 20261102190000.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.axs_aq_venue_map (
  tevo_venue_id      bigint      PRIMARY KEY,
  venue_short_id     text        NOT NULL,
  venue_name         text,
  city               text,
  state              text,
  verdict            text        NOT NULL,
  axs_venue_id       text,
  axs_page           text,
  axs_directory_name text,
  sg_venue_ids       bigint[]    NOT NULL DEFAULT '{}',
  match_method       text        NOT NULL CHECK (match_method IN ('aq_tevo_venue', 'aq_sg_venue', 'aq_event_map', 'minted')),
  mapped_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS axs_aq_venue_map_aq_idx ON public.axs_aq_venue_map (venue_short_id);
CREATE INDEX IF NOT EXISTS axs_aq_venue_map_axs_idx ON public.axs_aq_venue_map (axs_venue_id) WHERE axs_venue_id IS NOT NULL;
COMMENT ON TABLE public.axs_aq_venue_map IS
  'AXS venues (axs_venue_catalog verdict axs / mixed) → AQ venue_short_id, so AXS data joins straight onto the AQ catalogue. Refreshed by axs_aq_venue_map_refresh() (mig 20261102200000).';
ALTER TABLE public.axs_aq_venue_map ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_aq_venue_map FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_aq_venue_map TO service_role;

CREATE OR REPLACE FUNCTION public.axs_aq_venue_map_refresh()
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_minted int;
  v_rows   int;
BEGIN
  DROP TABLE IF EXISTS _axs_v, _axs_m;
  CREATE TEMP TABLE _axs_v ON COMMIT DROP AS
  SELECT c.tevo_venue_id, c.venue_name, c.verdict, c.axs_venue_id, c.axs_page, c.axs_directory_name, c.sg_venue_ids,
         nullif(btrim(reverse(split_part(reverse(c.venue_location), ',', 2))), '') AS city,
         nullif(upper(btrim(reverse(split_part(reverse(c.venue_location), ',', 1)))), '') AS state
    FROM public.axs_venue_catalog c
   WHERE c.verdict IN ('axs', 'mixed') AND c.venue_name IS NOT NULL
     AND public.axs_is_us_location(c.venue_location);

  CREATE TEMP TABLE _axs_m ON COMMIT DROP AS
  SELECT v.*,
         coalesce(t.venue_short_id, s.venue_short_id, e.venue_short_id) AS venue_short_id,
         CASE WHEN t.venue_short_id IS NOT NULL THEN 'aq_tevo_venue'
              WHEN s.venue_short_id IS NOT NULL THEN 'aq_sg_venue'
              WHEN e.venue_short_id IS NOT NULL THEN 'aq_event_map' END AS match_method
    FROM _axs_v v
    LEFT JOIN public.aq_venue_map t ON t.tevo_venue_id = v.tevo_venue_id
    LEFT JOIN LATERAL (SELECT m.venue_short_id FROM public.aq_venue_map m
                        WHERE m.sg_venue_id = ANY (v.sg_venue_ids) ORDER BY m.venue_short_id LIMIT 1) s ON true
    LEFT JOIN LATERAL (SELECT min(a.venue_short_id) AS venue_short_id
                         FROM public.events ev JOIN public.aq_event_map a ON a.tevo_event_id = ev.id
                        WHERE ev.venue_id = v.tevo_venue_id AND a.venue_short_id IS NOT NULL
                       HAVING count(DISTINCT a.venue_short_id) = 1) e ON true;

  -- 4. mint system_seed AQ venues for the rest (same id scheme as the existing system_seed rows)
  INSERT INTO public.aq_venue_map (venue_short_id, venue_name, city, state, country, tevo_venue_id, aq_source, imported_at)
  SELECT public.aq_venue_short_id(m.venue_name, m.city, m.state), m.venue_name, m.city, m.state,
         'US', m.tevo_venue_id, 'system_seed', now()
    FROM _axs_m m
   WHERE m.venue_short_id IS NULL
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_minted = ROW_COUNT;

  UPDATE _axs_m m SET venue_short_id = a.venue_short_id, match_method = 'minted'
    FROM public.aq_venue_map a
   WHERE m.venue_short_id IS NULL AND a.tevo_venue_id = m.tevo_venue_id;

  INSERT INTO public.axs_aq_venue_map AS x
         (tevo_venue_id, venue_short_id, venue_name, city, state, verdict, axs_venue_id, axs_page,
          axs_directory_name, sg_venue_ids, match_method, mapped_at)
  SELECT tevo_venue_id, venue_short_id, venue_name, city, state, verdict, axs_venue_id, axs_page,
         axs_directory_name, sg_venue_ids, match_method, now()
    FROM _axs_m WHERE venue_short_id IS NOT NULL
  ON CONFLICT (tevo_venue_id) DO UPDATE
     SET venue_short_id = EXCLUDED.venue_short_id, venue_name = EXCLUDED.venue_name,
         city = EXCLUDED.city, state = EXCLUDED.state, verdict = EXCLUDED.verdict,
         axs_venue_id = EXCLUDED.axs_venue_id, axs_page = EXCLUDED.axs_page,
         axs_directory_name = EXCLUDED.axs_directory_name, sg_venue_ids = EXCLUDED.sg_venue_ids,
         match_method = CASE WHEN x.venue_short_id = EXCLUDED.venue_short_id AND x.match_method = 'minted'
                             THEN 'minted' ELSE EXCLUDED.match_method END,
         mapped_at = CASE WHEN x.venue_short_id IS DISTINCT FROM EXCLUDED.venue_short_id THEN now() ELSE x.mapped_at END;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- venues that dropped out of axs / mixed leave the map
  DELETE FROM public.axs_aq_venue_map x
   WHERE NOT EXISTS (SELECT 1 FROM _axs_v v WHERE v.tevo_venue_id = x.tevo_venue_id);

  RETURN jsonb_build_object('mapped', v_rows, 'minted_aq_venues', v_minted,
                            'unmapped', (SELECT count(*) FROM _axs_m WHERE venue_short_id IS NULL));
END $$;
REVOKE ALL ON FUNCTION public.axs_aq_venue_map_refresh() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_aq_venue_map_refresh() TO service_role;

CREATE OR REPLACE VIEW public.v_axs_venues WITH (security_invoker = true) AS
SELECT m.venue_short_id AS aq_venue_id, m.tevo_venue_id, m.venue_name, m.city, m.state, m.verdict,
       c.verdict_basis, m.axs_venue_id, m.axs_page, m.axs_directory_name, m.sg_venue_ids,
       m.match_method AS aq_match_method,
       c.seed_axs + c.sg_axs AS axs_events_seen,
       round(c.delivery_axs_rows::numeric / nullif(c.delivery_rows, 0), 3) AS delivery_axs_share,
       m.mapped_at
  FROM public.axs_aq_venue_map m
  JOIN public.axs_venue_catalog c USING (tevo_venue_id);
REVOKE ALL ON public.v_axs_venues FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_venues TO service_role;

-- run the map refresh at the end of the daily venue refresh
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.axs_venue_catalog_refresh(interval)'::regprocedure);
  v_old text := $o$  RETURN jsonb_build_object('axs_venue_records', v_axs_rec, 'verdicts', v_counts);$o$;
  v_new text := $n$  RETURN jsonb_build_object('axs_venue_records', v_axs_rec, 'verdicts', v_counts,
                            'aq_map', public.axs_aq_venue_map_refresh());$n$;
BEGIN
  IF position('axs_aq_venue_map_refresh' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'axs_venue_catalog_refresh: return line not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $patch$;
