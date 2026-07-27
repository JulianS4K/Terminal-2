-- Migration 20260616153000 · lane:D3 (author) → A1 (apply) · writes:world_cup_2026 (add SG market columns + extend refresh fn) · reads:sg_events_canonical, seatgeek_event_metrics, seatgeek_event_latest · pre:20260616051500_wc_2026_event_mapping_table · auth:operator-requested 2026-06-16 ("merge all the fifa games into a table with sg")
--
-- D3 — enrich world_cup_2026 with SeatGeek market data. EVO/TEvo carries only 1
-- of 104 matches, but SeatGeek carries the full schedule WITH live listings +
-- pricing. Pull the latest SG listing aggregates (from-price, median, counts)
-- and the SG event url onto every match row so the storefront can render the
-- World Cup series off real market data regardless of EVO coverage.
--
-- New columns are maintained by refresh_world_cup_2026() from the latest
-- seatgeek_event_metrics sample per sg_event_id + seatgeek_event_latest +
-- sg_events_canonical.sg_url. Idempotent / re-runnable.

ALTER TABLE public.world_cup_2026
  ADD COLUMN IF NOT EXISTS sg_url                text,
  ADD COLUMN IF NOT EXISTS sg_from_price         numeric,   -- listings_all_min
  ADD COLUMN IF NOT EXISTS sg_median_price       numeric,   -- listings_all_median
  ADD COLUMN IF NOT EXISTS sg_listings_count     int,       -- listings_all_count
  ADD COLUMN IF NOT EXISTS sg_tickets_count      int,       -- listings_all_tickets
  ADD COLUMN IF NOT EXISTS sg_active_listings    int,       -- seatgeek_event_latest.active_listings
  ADD COLUMN IF NOT EXISTS sg_sales_count        int,       -- seatgeek_event_latest.sales_count
  ADD COLUMN IF NOT EXISTS sg_listings_at        timestamptz; -- captured_at of the metrics sample

CREATE OR REPLACE FUNCTION public.refresh_world_cup_2026()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_rows int; v_owned int; v_linked int; v_priced int;
BEGIN
  INSERT INTO public.world_cup_2026 AS w (
    match_number, stage, group_label, team_a, team_b, match_label,
    event_datetime, event_date, venue_name, venue_city, venue_state, venue_country,
    sg_event_id, sg_event_name, tevo_event_id, tevo_event_name,
    we_own, owned_tickets_count, owned_median_retail, has_seller_listings,
    match_status,
    sg_url, sg_from_price, sg_median_price, sg_listings_count, sg_tickets_count,
    sg_active_listings, sg_sales_count, sg_listings_at,
    refreshed_at
  )
  SELECT DISTINCT ON (s.match_number)
    s.match_number,
    CASE
      WHEN s.match_number BETWEEN 1  AND 72  THEN 'Group Stage'
      WHEN s.match_number BETWEEN 73 AND 88  THEN 'Round of 32'
      WHEN s.match_number BETWEEN 89 AND 96  THEN 'Round of 16'
      WHEN s.match_number BETWEEN 97 AND 100 THEN 'Quarter-Final'
      WHEN s.match_number BETWEEN 101 AND 102 THEN 'Semi-Final'
      WHEN s.match_number = 103 THEN 'Third-Place Play-off'
      WHEN s.match_number = 104 THEN 'Final'
      ELSE 'Unknown'
    END AS stage,
    CASE WHEN s.group_letter IS NOT NULL THEN 'Group ' || s.group_letter END AS group_label,
    s.team_a, s.team_b,
    CASE WHEN s.team_a IS NOT NULL AND s.team_b IS NOT NULL
         THEN s.team_a || ' vs ' || s.team_b ELSE 'TBD' END AS match_label,
    s.sg_datetime_utc, s.sg_event_date,
    s.sg_venue_name, s.sg_venue_city, s.sg_venue_state, s.sg_venue_country,
    s.sg_event_id, s.sg_event_name,
    s.tevo_event_id, e.name AS tevo_event_name,
    COALESCE(m.owned_tickets_count, 0) > 0 AS we_own,
    COALESCE(m.owned_tickets_count, 0) AS owned_tickets_count,
    NULLIF(m.owned_median_retail::text, '')::numeric AS owned_median_retail,
    COALESCE(s.has_seller_listings, false) AS has_seller_listings,
    s.match_status,
    s.sg_url,
    sgm.listings_all_min, sgm.listings_all_median,
    sgm.listings_all_count, sgm.listings_all_tickets,
    sgl.active_listings::int, sgl.sales_count::int, sgm.captured_at,
    now()
  FROM (
    SELECT
      c.*,
      (regexp_match(c.sg_event_name, 'Match\s+([0-9]+)'))[1]::int AS match_number,
      NULLIF((regexp_match(c.sg_event_name, '^(.*?)\s+vs\s+.+?\s*-\s*World Cup'))[1], '') AS team_a,
      NULLIF((regexp_match(c.sg_event_name, '\s+vs\s+(.+?)\s*-\s*World Cup'))[1], '') AS team_b,
      (regexp_match(c.sg_event_name, '\(Group ([A-L])\)'))[1] AS group_letter
    FROM public.sg_events_canonical c
    WHERE c.sg_event_name ~* 'world cup - match [0-9]+'
  ) s
  LEFT JOIN public.events e               ON e.id = s.tevo_event_id
  LEFT JOIN public.latest_event_metrics m ON m.event_id = s.tevo_event_id
  LEFT JOIN LATERAL (
    SELECT em.listings_all_min, em.listings_all_median,
           em.listings_all_count, em.listings_all_tickets, em.captured_at
    FROM public.seatgeek_event_metrics em
    WHERE em.sg_event_id = s.sg_event_id
    ORDER BY em.captured_at DESC
    LIMIT 1
  ) sgm ON true
  LEFT JOIN public.seatgeek_event_latest sgl ON sgl.sg_event_id = s.sg_event_id
  WHERE s.match_number IS NOT NULL
  ORDER BY s.match_number, (s.tevo_event_id IS NOT NULL) DESC, s.updated_at DESC
  ON CONFLICT (match_number) DO UPDATE SET
    stage               = EXCLUDED.stage,
    group_label         = EXCLUDED.group_label,
    team_a              = EXCLUDED.team_a,
    team_b              = EXCLUDED.team_b,
    match_label         = EXCLUDED.match_label,
    event_datetime      = EXCLUDED.event_datetime,
    event_date          = EXCLUDED.event_date,
    venue_name          = EXCLUDED.venue_name,
    venue_city          = EXCLUDED.venue_city,
    venue_state         = EXCLUDED.venue_state,
    venue_country       = EXCLUDED.venue_country,
    sg_event_id         = EXCLUDED.sg_event_id,
    sg_event_name       = EXCLUDED.sg_event_name,
    tevo_event_id       = EXCLUDED.tevo_event_id,
    tevo_event_name     = EXCLUDED.tevo_event_name,
    we_own              = EXCLUDED.we_own,
    owned_tickets_count = EXCLUDED.owned_tickets_count,
    owned_median_retail = EXCLUDED.owned_median_retail,
    has_seller_listings = EXCLUDED.has_seller_listings,
    match_status        = EXCLUDED.match_status,
    sg_url              = EXCLUDED.sg_url,
    sg_from_price       = EXCLUDED.sg_from_price,
    sg_median_price     = EXCLUDED.sg_median_price,
    sg_listings_count   = EXCLUDED.sg_listings_count,
    sg_tickets_count    = EXCLUDED.sg_tickets_count,
    sg_active_listings  = EXCLUDED.sg_active_listings,
    sg_sales_count      = EXCLUDED.sg_sales_count,
    sg_listings_at      = EXCLUDED.sg_listings_at,
    refreshed_at        = now();

  SELECT count(*), count(*) FILTER (WHERE we_own),
         count(*) FILTER (WHERE tevo_event_id IS NOT NULL),
         count(*) FILTER (WHERE sg_from_price IS NOT NULL)
    INTO v_rows, v_owned, v_linked, v_priced
  FROM public.world_cup_2026;

  RETURN jsonb_build_object(
    'rows', v_rows, 'owned', v_owned, 'evo_linked', v_linked,
    'sg_priced', v_priced, 'refreshed_at', now()
  );
END;
$fn$;

SELECT public.refresh_world_cup_2026();
