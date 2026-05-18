-- A1 PR-4a (part 3 of 5) — migrate v_event_velocity_windows.
-- Source for v3 RPC's `velocity` payload. SG get-in approximated by listings_all_min;
-- SG median by listings_all_median.

DROP VIEW IF EXISTS public.v_event_velocity_windows;

CREATE VIEW public.v_event_velocity_windows AS
WITH tevo_now AS (
  SELECT DISTINCT ON (event_metrics.event_id) event_metrics.event_id,
    event_metrics.captured_at, event_metrics.getin_price,
    event_metrics.retail_median, event_metrics.tickets_count
  FROM public.event_metrics
  ORDER BY event_metrics.event_id, event_metrics.captured_at DESC
),
tevo_w AS (
  SELECT n.event_id,
    n.captured_at AS tevo_now_at,
    n.getin_price AS tevo_getin_now,
    n.retail_median AS tevo_median_now,
    n.tickets_count AS tevo_tix_now,
    (SELECT em.getin_price FROM public.event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '1 hour'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_getin_1h_ago,
    (SELECT em.tickets_count FROM public.event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '1 hour'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_tix_1h_ago,
    (SELECT em.getin_price FROM public.event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '6 hours'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_getin_6h_ago,
    (SELECT em.getin_price FROM public.event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '24 hours'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_getin_24h_ago,
    (SELECT em.tickets_count FROM public.event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '24 hours'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_tix_24h_ago
  FROM tevo_now n
),
sg_w AS (
  SELECT sgm.tevo_event_id AS event_id,
    sgm.captured_at AS sg_now_at,
    -- A1 2026-05-18 PR-4a: cost_min → listings_all_min (cheapest live broker listing = SG "get-in" equivalent)
    sgm.listings_all_min AS sg_getin_now,
    sgm.listings_all_median AS sg_median_now,
    sgm.listings_all_tickets AS sg_tix_now,
    (SELECT x.listings_all_min FROM public.seatgeek_event_metrics x
      WHERE x.tevo_event_id = sgm.tevo_event_id AND x.captured_at <= sgm.captured_at - interval '1 hour'
      ORDER BY x.captured_at DESC LIMIT 1) AS sg_getin_1h_ago,
    (SELECT x.listings_all_min FROM public.seatgeek_event_metrics x
      WHERE x.tevo_event_id = sgm.tevo_event_id AND x.captured_at <= sgm.captured_at - interval '24 hours'
      ORDER BY x.captured_at DESC LIMIT 1) AS sg_getin_24h_ago
  FROM (
    SELECT DISTINCT ON (tevo_event_id) tevo_event_id, captured_at,
           listings_all_min, listings_all_median, listings_all_tickets
    FROM public.seatgeek_event_metrics
    WHERE tevo_event_id IS NOT NULL
    ORDER BY tevo_event_id, captured_at DESC
  ) sgm
)
SELECT e.id AS tevo_event_id,
  e.name, e.occurs_at_local, e.venue_name,
  t.tevo_now_at, t.tevo_getin_now, t.tevo_median_now, t.tevo_tix_now,
  (t.tevo_getin_now - t.tevo_getin_1h_ago) AS tevo_getin_d1h,
  (t.tevo_getin_now - t.tevo_getin_6h_ago) AS tevo_getin_d6h,
  (t.tevo_getin_now - t.tevo_getin_24h_ago) AS tevo_getin_d24h,
  (t.tevo_tix_now - t.tevo_tix_1h_ago) AS tevo_tix_d1h,
  (t.tevo_tix_now - t.tevo_tix_24h_ago) AS tevo_tix_d24h,
  CASE WHEN t.tevo_getin_1h_ago > 0 THEN round(((t.tevo_getin_now - t.tevo_getin_1h_ago) / t.tevo_getin_1h_ago * 100)::numeric, 2) ELSE NULL END AS tevo_getin_d1h_pct,
  CASE WHEN t.tevo_getin_24h_ago > 0 THEN round(((t.tevo_getin_now - t.tevo_getin_24h_ago) / t.tevo_getin_24h_ago * 100)::numeric, 2) ELSE NULL END AS tevo_getin_d24h_pct,
  s.sg_now_at, s.sg_getin_now, s.sg_median_now, s.sg_tix_now,
  (s.sg_getin_now - s.sg_getin_1h_ago) AS sg_getin_d1h,
  (s.sg_getin_now - s.sg_getin_24h_ago) AS sg_getin_d24h
FROM public.events e
LEFT JOIN tevo_w t ON t.event_id = e.id
LEFT JOIN sg_w s ON s.event_id = e.id
WHERE t.event_id IS NOT NULL OR s.event_id IS NOT NULL;

GRANT SELECT ON public.v_event_velocity_windows TO anon, authenticated, service_role;
