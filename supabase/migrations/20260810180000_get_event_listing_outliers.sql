-- Migration 20260810180000 · lane:D0 (author) → applier (apply) · writes:get_event_listing_outliers(bigint,numeric,int,int) [fn] · reads:listings_snapshots,ticketsdata_listings_snapshots,ticketsdata_event_xref,aq_event_map,sg_events_canonical,derive_zone_fallback · pre:derive_zone_fallback (mig 20260507000000), ticketsdata xref chain (aq_event_map/sg_events_canonical) · auth:OPERATOR-APPROVED read-only SECDEF (email-gated @s4kent.com; grants authenticated only, no anon)
--
-- WHY (operator-directed 2026-08-10). The listing engine needs to spot mispriced
-- listings — a listing whose price sticks out from the rest of the event's book,
-- in EITHER direction (a LOW steal / underpriced-own-inventory, or a HIGH gouge).
-- This RPC feeds a new "Outliers" tab on the D0 event page. It scans the FULL
-- market book (not just our owned inventory) for BOTH listing sources that carry
-- per-listing price rows:
--   * EVO — public.listings_snapshots (retail_price), keyed by tevo event id.
--   * GoTickets — public.ticketsdata_listings_snapshots WHERE platform='GT'
--     (list_price), keyed by TicketsData event id → resolved to the tevo event via
--     ticketsdata_event_xref ← aq_event_map ← sg_events_canonical (same chain
--     get_event_td_listings uses; one tevo event can map to several TD ids → IN()).
--
-- SCOPE = ZONE-level (operator directive 2026-08-11, changed from event-level):
-- each listing is measured against its PEER seats — the other listings in the same
-- zone (source × zone group) — not the whole event. This is what makes a genuinely
-- MISPRICED seat surface instead of an entire premium tier: e.g. on Red Sox event
-- 3099748 the 10 'club' seats (median $429) all read as HIGH against the ~$160
-- event median, but against each OTHER they are normal, so zone-level flags 0 of
-- them while still surfacing 12 mispriced seats inside the 394-listing lower bowl.
-- The zone is the grouping key, resolved by derive_zone_fallback(section,row).
-- Trade-off (accepted): a zone with < p_min_group seating listings can't be scored,
-- so sparse sources/zones (esp. GoTickets) surface fewer flags — strict zone-level,
-- no event fallback.
--
-- ZONE MAP = SECONDARY GET-IN FILTER (operator directive). Non-seating inventory
-- (parking / lots / garages / hospitality) would drag the get-in down and read as
-- permanent LOW outliers, so it is EXCLUDED from the per-source baseline + get-in:
--   * EVO listings flagged is_ancillary, GT rows flagged is_parking → excluded;
--   * plus a section keyword guard mirroring routers/broker.py _PARKING_SECTION_RE.
-- Each surviving (seating) listing is also LABELLED with its keyword zone via
-- derive_zone_fallback(section,row) — the cheap fallback resolver, NOT the heavy
-- curated v_section_to_curated_zone range-match (that view recomputes per row and
-- times out an on-demand RPC; the seating filter above is what get-in cleanup
-- actually needs). Non-seating rows are counted (n_nonseating_excluded) but never
-- scored.
--
-- ALGORITHM — robust (outlier-resistant), per (source × zone), seating only:
--   For each zone group: median m + MAD (median abs deviation) → modified z =
--   0.6745·(x−m)/MAD (Iglewicz-Hoaglin). |z| ≥ p_z_threshold (default 3.5) ⇒
--   outlier; sign ⇒ HIGH/LOW. When a zone's MAD = 0 (many identical prices) fall
--   back to Tukey IQR fences [Q1−1.5·IQR, Q3+1.5·IQR] within the zone. A zone is
--   scored only when it holds ≥ p_min_group seating listings (default 4); smaller
--   zones are returned in zones[] but produce no flags. Non-robust mean/stdev is
--   deliberately NOT used: one premium seat would blow up the stdev and mask the
--   rest. deviation_pct + mod_z are ZONE-relative (vs the zone median).
--
-- Read-only (SELECT only) + email-gated, mirroring get_event_zones /
-- get_event_zone_sections / get_event_td_listings.
-- ROLLBACK: DROP FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int).

CREATE OR REPLACE FUNCTION public.get_event_listing_outliers(
  p_event_id      bigint,
  p_z_threshold   numeric DEFAULT 3.5,
  p_min_group     int     DEFAULT 4,
  p_max_age_hours int     DEFAULT 48
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email  text;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Bound the on-demand cost (parking regex + fallback zone calls over a few
  -- hundred listings). A wedged event page should error fast, not hang.
  PERFORM set_config('statement_timeout', '10000', true);

  WITH params AS (
    SELECT p_event_id AS ev,
           GREATEST(p_z_threshold, 0.1)          AS zt,
           GREATEST(p_min_group, 2)              AS ming,
           GREATEST(p_max_age_hours, 1)          AS age
  ),
  -- GoTickets TD event ids that map to this tevo event (one → many).
  gt_ids AS (
    SELECT DISTINCT tdx.event_id AS td_id
    FROM public.ticketsdata_event_xref tdx
    JOIN public.aq_event_map aem     ON aem.aq_short_event_id = tdx.aq_short_event_id
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id, params
    WHERE tdx.active = true AND sgc.tevo_event_id = params.ev
  ),
  evo_latest AS (
    SELECT max(l.captured_at) AS mx
    FROM public.listings_snapshots l, params
    WHERE l.event_id = params.ev
      AND l.captured_at > now() - (params.age || ' hours')::interval
  ),
  -- Latest capture PER td event id (each mapped GT event contributes its freshest snapshot).
  gt_latest AS (
    SELECT t.event_id, max(t.captured_at) AS mx
    FROM public.ticketsdata_listings_snapshots t, params
    WHERE t.platform = 'GT'
      AND t.event_id IN (SELECT td_id FROM gt_ids)
      AND t.captured_at > now() - (params.age || ' hours')::interval
    GROUP BY t.event_id
  ),
  raw AS (
    SELECT 'EVO'::text AS source,
           l.tevo_ticket_group_id::text AS listing_id,
           l.section, l.row, l.quantity,
           l.retail_price::numeric AS price,
           l.is_owned, l.captured_at,
           (l.is_ancillary IS TRUE) AS nonseat_flag
    FROM public.listings_snapshots l, evo_latest e, params
    WHERE l.event_id = params.ev AND l.captured_at = e.mx AND l.retail_price > 0
    UNION ALL
    SELECT 'GT'::text,
           t.td_listing_id,
           t.section, t.row, t.quantity,
           t.list_price::numeric,
           NULL::boolean, t.captured_at,
           (t.is_parking IS TRUE)
    FROM public.ticketsdata_listings_snapshots t
    JOIN gt_latest g ON g.event_id = t.event_id AND t.captured_at = g.mx
    WHERE t.platform = 'GT' AND t.list_price > 0
  ),
  classed AS (
    SELECT r.*,
           -- zone is the grouping key; NULL/'' fallbacks bucket together as '(unzoned)'
           coalesce(nullif(public.derive_zone_fallback(r.section, r.row), ''), '(unzoned)') AS zone,
           NOT (
             r.nonseat_flag
             OR coalesce(r.section, '') ~* '\y(parking|garage|valet|lot|hospitality|shuttle|prepaid)\y'
           ) AS is_seating
    FROM raw r
  ),
  -- Robust stats PER (source × zone) over seating listings.
  zstats AS (
    SELECT source, zone,
           count(*)                                                        AS n,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY price)::numeric     AS med,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric     AS q1,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric     AS q3,
           min(price)::numeric                                             AS getin
    FROM classed WHERE is_seating GROUP BY source, zone
  ),
  zmad AS (
    SELECT c.source, c.zone,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(c.price - z.med))::numeric AS madv
    FROM classed c JOIN zstats z USING (source, zone)
    WHERE c.is_seating GROUP BY c.source, c.zone
  ),
  scored AS (
    SELECT c.*, z.n AS zone_n, z.med, z.q1, z.q3, m.madv,
           CASE WHEN m.madv > 0 THEN round(0.6745 * (c.price - z.med) / m.madv, 2) END AS mod_z,
           CASE WHEN z.med > 0   THEN round((c.price / z.med - 1) * 100, 1) END         AS dev_pct,
           CASE WHEN m.madv > 0 THEN 'mad' ELSE 'iqr' END                               AS method,
           CASE
             -- non-seating, or a zone too small to judge → never flagged
             WHEN NOT c.is_seating OR z.n < (SELECT ming FROM params) THEN NULL
             -- robust modified z-score, ZONE-relative
             WHEN m.madv > 0 AND abs(0.6745 * (c.price - z.med) / m.madv) >= (SELECT zt FROM params)
               THEN CASE WHEN c.price > z.med THEN 'HIGH' ELSE 'LOW' END
             -- degenerate MAD (identical prices in the zone) → Tukey IQR fences
             WHEN m.madv = 0 AND (c.price > z.q3 + 1.5 * (z.q3 - z.q1)
                              OR  c.price < z.q1 - 1.5 * (z.q3 - z.q1))
               THEN CASE WHEN c.price > z.med THEN 'HIGH' ELSE 'LOW' END
             ELSE NULL
           END AS direction
    FROM classed c JOIN zstats z USING (source, zone) JOIN zmad m USING (source, zone)
  ),
  zone_summary AS (
    SELECT z.source, z.zone, z.n, z.getin, z.med, round(m.madv, 2) AS mad,
           (z.n >= (SELECT ming FROM params)) AS scored,
           (SELECT count(*) FROM scored x WHERE x.source = z.source AND x.zone = z.zone AND x.direction = 'LOW')  AS low_count,
           (SELECT count(*) FROM scored x WHERE x.source = z.source AND x.zone = z.zone AND x.direction = 'HIGH') AS high_count
    FROM zstats z JOIN zmad m USING (source, zone)
  ),
  src_summary AS (
    SELECT d.source,
           (SELECT count(*)     FROM classed c WHERE c.source = d.source AND c.is_seating)      AS n_seat,
           (SELECT count(*)     FROM classed c WHERE c.source = d.source AND NOT c.is_seating)  AS n_nonseat,
           (SELECT min(price)   FROM classed c WHERE c.source = d.source AND c.is_seating)      AS getin,
           (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::numeric
              FROM classed c WHERE c.source = d.source AND c.is_seating)                        AS src_med,
           (SELECT count(*) FROM zstats z WHERE z.source = d.source
              AND z.n >= (SELECT ming FROM params))                                            AS zones_scored,
           (SELECT count(*) FROM scored x WHERE x.source = d.source AND x.direction = 'LOW')    AS low_count,
           (SELECT count(*) FROM scored x WHERE x.source = d.source AND x.direction = 'HIGH')   AS high_count,
           (SELECT max(c.captured_at) FROM classed c WHERE c.source = d.source)                 AS captured_at
    FROM (SELECT DISTINCT source FROM classed) d
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id,
    'generated_at', now(),
    'scope', 'zone',
    'params', jsonb_build_object(
      'z_threshold', p_z_threshold, 'min_group', p_min_group, 'max_age_hours', p_max_age_hours),
    'sources', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'source', source, 'captured_at', captured_at,
        'n_seating', n_seat, 'n_nonseating_excluded', n_nonseat,
        'getin', getin, 'median', src_med, 'zones_scored', zones_scored,
        'low_count', low_count, 'high_count', high_count
      ) ORDER BY source) FROM src_summary), '[]'::jsonb),
    'zones', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'source', source, 'zone', zone, 'n', n, 'getin', getin, 'median', med,
        'mad', mad, 'scored', scored, 'low_count', low_count, 'high_count', high_count
      ) ORDER BY source, n DESC) FROM zone_summary), '[]'::jsonb),
    'outliers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'source', source, 'listing_id', listing_id, 'section', section, 'row', "row",
        'quantity', quantity, 'price', price, 'is_owned', is_owned,
        'zone', zone, 'zone_n', zone_n,
        'baseline_median', med, 'mad', round(madv, 2), 'mod_z', mod_z,
        'deviation_pct', dev_pct, 'direction', direction, 'method', method,
        'captured_at', captured_at
      ) ORDER BY source, abs(coalesce(mod_z, 999)) DESC, dev_pct DESC)
      FROM scored WHERE direction IS NOT NULL), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int) IS
  'D0 event-page "Outliers" tab. ZONE-level robust price-outlier detection (median+MAD modified z-score, IQR fallback) — each listing vs its peer seats in the same zone (derive_zone_fallback), NOT the whole event — over the FULL market book for BOTH per-listing sources: EVO (listings_snapshots.retail_price) + GoTickets (ticketsdata_listings_snapshots platform=GT list_price, tevo→TD via xref chain). Non-seating (parking/lots/hospitality) excluded. A zone scores only with >= p_min_group listings. Returns {scope,sources[],zones[],outliers[]}. Email-gated SECDEF, authenticated-only. Mig 20260810180000.';
