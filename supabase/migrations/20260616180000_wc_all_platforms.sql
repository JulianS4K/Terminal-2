-- Migration 20260616180000 · lane:D0 (author) → A1 (apply) · writes:ticketsdata_event_xref (seed TM for WC), get_wc_markets · reads:aq_event_map, sg_events_canonical, seatgeek_listings_snapshots, ticketsdata_listings_snapshots · pre:20260615140000_wc_enable_sh_vd_collection · auth:operator-requested 2026-06-16 ("match wc games across all platforms and track them all")
--
-- D0 — extend World Cup collection to Ticketmaster + add a cross-source markets
-- RPC for the terminal event page.
--
-- (1) TM seed: the TM /fetch URL is derivable from the hub's native id —
--     ticketsdata.com fetches by marketplace URL, and TM's canonical event URL
--     is https://www.ticketmaster.com/event/<HEX> where HEX = upper(to_hex(id))
--     (verified: every existing TM event_url ends in exactly that hex). So seed
--     TM xref rows from aq_event_map.tm_event_id; the active td_enqueue_peak_tm +
--     drains then collect them (budget-gated). Best-effort: if TD won't resolve
--     the slug-less URL it simply yields no rows (no harm). GameTime stays the
--     one gap — its URL is pure slug with no id form, so it needs td_gt_discover
--     (performer-matched) which is a separate follow-up.
--
-- (2) get_wc_markets(p_sg_event_id): resolves the event through the AQ hub and
--     returns the latest per-source summary (get-in / median / listings) across
--     SeatGeek (live snapshots) + StubHub/VividSeats/Ticketmaster (TD raw
--     snapshots, latest pull per platform). Powers the WC event page's
--     cross-source panel. Email-gated, anon revoked.

-- ============================================================================
-- 1. Seed Ticketmaster collection for World Cup
-- ============================================================================
WITH wc AS (
  SELECT DISTINCT a.aq_short_event_id, a.tm_event_id
  FROM public.sg_events_canonical c
  JOIN public.aq_event_map a ON a.sg_event_id = c.sg_event_id
  WHERE c.sg_event_name ILIKE '%world cup - match%' AND a.tm_event_id IS NOT NULL
)
INSERT INTO public.ticketsdata_event_xref
  (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, created_at, updated_at)
SELECT tm_event_id, 'TM', aq_short_event_id,
       'https://www.ticketmaster.com/event/' || upper(to_hex(tm_event_id)),
       true, false, 'hub_seed_wc', now(), now()
FROM wc
ON CONFLICT (event_id, platform) DO UPDATE
  SET active = true, event_url = EXCLUDED.event_url,
      aq_short_event_id = COALESCE(public.ticketsdata_event_xref.aq_short_event_id, EXCLUDED.aq_short_event_id),
      updated_at = now();

-- ============================================================================
-- 2. Cross-source markets summary, resolved through the AQ hub
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_wc_markets(p_sg_event_id bigint)
RETURNS TABLE(source text, getin numeric, median numeric, listings integer, last_pull timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
#variable_conflict use_column
DECLARE
  v_email text := coalesce(auth.jwt()->>'email', '');
  v_sh bigint; v_vd bigint; v_tm bigint;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;
  SELECT a.sh_event_id, a.vivid_event_id, a.tm_event_id
    INTO v_sh, v_vd, v_tm
  FROM public.aq_event_map a WHERE a.sg_event_id = p_sg_event_id LIMIT 1;

  RETURN QUERY
  WITH sg_mx AS (
    SELECT max(s.captured_at) AS mc FROM public.seatgeek_listings_snapshots s WHERE s.sg_event_id = p_sg_event_id
  ),
  sg AS (
    SELECT 'SeatGeek'::text AS source,
           min(s.retail_price_all_in) AS getin,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY s.retail_price_all_in) AS median,
           count(*)::int AS listings, max(s.captured_at) AS last_pull
    FROM public.seatgeek_listings_snapshots s, sg_mx
    WHERE s.sg_event_id = p_sg_event_id AND sg_mx.mc IS NOT NULL
      AND s.captured_at >= sg_mx.mc - interval '6 hours' AND s.retail_price_all_in > 0
  ),
  td_mx AS (
    SELECT t.event_id, t.platform, max(t.captured_at) AS mc
    FROM public.ticketsdata_listings_snapshots t
    WHERE (t.event_id = v_sh AND t.platform = 'SH')
       OR (t.event_id = v_vd AND t.platform = 'VD')
       OR (t.event_id = v_tm AND t.platform = 'TM')
    GROUP BY t.event_id, t.platform
  ),
  td AS (
    SELECT CASE t.platform WHEN 'SH' THEN 'StubHub' WHEN 'VD' THEN 'VividSeats'
                           WHEN 'TM' THEN 'Ticketmaster' ELSE t.platform END AS source,
           min(t.price_with_fees) AS getin,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY t.price_with_fees) AS median,
           count(*)::int AS listings, max(t.captured_at) AS last_pull
    FROM public.ticketsdata_listings_snapshots t
    JOIN td_mx m ON m.event_id = t.event_id AND m.platform = t.platform
                AND t.captured_at >= m.mc - interval '6 hours'
    WHERE coalesce(t.is_parking, false) = false AND t.price_with_fees > 0
    GROUP BY t.platform
  )
  SELECT u.source, u.getin, u.median, u.listings, u.last_pull FROM (
    SELECT source, round(getin)::numeric AS getin, round(median)::numeric AS median, listings, last_pull FROM sg WHERE listings > 0
    UNION ALL
    SELECT source, round(getin)::numeric AS getin, round(median)::numeric AS median, listings, last_pull FROM td
  ) u
  ORDER BY u.getin NULLS LAST;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_wc_markets(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_wc_markets(bigint) TO authenticated;
