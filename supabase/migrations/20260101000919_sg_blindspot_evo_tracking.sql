-- ============================================================================
-- Migration 20260609170000 — SG blindspot → EVO (TEvo) listings/metrics tracking
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-06-09
--   (operator-authorized: "good, audit and merge into main"). Post-apply audit:
--   978 events tracked, 957 (98%) with a live EVO book, data fresh same-day;
--   view ~1.85s (EXPLAIN ANALYZE, < 8s PostgREST cap); email gate verified to
--   raise 42501 for non-@s4kent callers; no new security advisors.
--
-- Lane:     xref+macro (A1 domain) — D0 operator-directed via bot_chat override
--           path ("good, audit and merge into main", 2026-06-09).
-- Touches:  v_sg_blindspot_evo_tracking (W, view),
--           get_sg_blindspot_evo_tracking (W, fn),
--           sg_event_priority_state (R), seatgeek_event_metrics (R),
--           latest_event_metrics (R)
-- Pre-reqs: latest_event_metrics matview (TEvo firehose rollup),
--           sg_event_priority_state (sg_classify_events tiering),
--           seatgeek_event_metrics (SG sales/listings rollup)
--
-- WHY: For the "SG is selling, we hold zero inventory" universe (tier
--   TRACK_BLINDSPOT, future, owned=0) the SG live ask-side book is no longer
--   polled (owned-focus redesign, mig 20260608030000 — non-owned /listings
--   poller dropped), so SG gives us only realized SALES. EVO (our unlimited
--   TEvo consumer) still captures the full live LISTINGS book for every one of
--   these events. This view tracks each blindspot event with SG demand
--   (sold qty/gross/median) alongside the EVO live book (get-in / median / p90
--   / depth / owned share) from latest_event_metrics.
--
-- RELATION TO EXISTING: complements (does NOT duplicate) get_blind_spots_sg_selling()
--   / mv_sg_blindspot_movers (mig 20260524120000), which scores SG-side movers
--   only. This object adds the cross-source EVO tracking dimension and ranks by
--   SG sold dollar volume (the revenue we're missing).
--
-- ROLLBACK: DROP FUNCTION public.get_sg_blindspot_evo_tracking(integer);
--           DROP VIEW public.v_sg_blindspot_evo_tracking;
-- ============================================================================

-- 1) Tracking view: SG blindspot demand + EVO live book ----------------------
CREATE OR REPLACE VIEW public.v_sg_blindspot_evo_tracking
WITH (security_invoker = true) AS
WITH latest_sg AS (
  -- latest SG rollup snapshot per event (seatgeek_event_metrics is a 30d stream)
  SELECT DISTINCT ON (sg_event_id)
    sg_event_id,
    tevo_event_id,
    captured_at                       AS sg_asof,
    sold_quantity,
    sold_gross,
    sold_price_median,
    COALESCE(listings_owned_count, 0) AS sg_owned_listings
  FROM public.seatgeek_event_metrics
  ORDER BY sg_event_id, captured_at DESC
)
SELECT
  row_number() OVER (ORDER BY g.sold_gross DESC NULLS LAST)        AS rank,
  s.sg_event_id,
  COALESCE(s.tevo_event_id, g.tevo_event_id)                      AS tevo_event_id,
  s.sg_event_name                                                  AS event_name,
  s.sg_venue_name                                                  AS venue_name,
  s.sg_datetime_utc                                               AS event_datetime_utc,
  round(EXTRACT(EPOCH FROM (s.sg_datetime_utc - now())) / 86400.0, 1) AS days_to_event,
  -- SG demand side (realized sales)
  g.sold_quantity                                                 AS sg_sold_qty,
  round(g.sold_gross, 2)                                          AS sg_sold_gross,
  round(g.sold_price_median, 2)                                  AS sg_sold_median,
  g.sg_asof,
  -- EVO / TEvo live ask-side book (latest_event_metrics)
  em.tickets_count                                               AS evo_tickets,
  em.groups_count                                               AS evo_groups,
  em.getin_price                                                AS evo_getin,
  em.retail_median                                             AS evo_median,
  em.retail_p90                                               AS evo_p90,
  em.owned_groups_count                                       AS evo_owned_groups,
  em.owned_share                                             AS evo_owned_share,
  em.captured_at                                            AS evo_asof
FROM public.sg_event_priority_state s
JOIN latest_sg g
  ON g.sg_event_id = s.sg_event_id
LEFT JOIN public.latest_event_metrics em
  ON em.event_id = COALESCE(s.tevo_event_id, g.tevo_event_id)
WHERE s.tier = 'TRACK_BLINDSPOT'        -- US event, owned_cnt=0 (we're not in)
  AND s.sg_datetime_utc > now()         -- future only
  AND s.owned_count_last_7d = 0         -- belt: priority-state ownership flag
  AND g.sg_owned_listings = 0           -- suspenders: SG book shows no owned listings
  AND g.sold_quantity > 0;              -- SG is actually selling

-- secure-by-default: only the SECURITY DEFINER RPC (owner) reads the view;
-- no direct anon/authenticated PostgREST surface.
REVOKE ALL ON public.v_sg_blindspot_evo_tracking FROM anon, authenticated;

COMMENT ON VIEW public.v_sg_blindspot_evo_tracking IS
  'SG-selling/we''re-not-in (tier TRACK_BLINDSPOT, future, owned=0) events with SG '
  'realized-sales demand alongside the EVO/TEvo live listings book from '
  'latest_event_metrics. Ranked by SG sold gross. Read via get_sg_blindspot_evo_tracking().';

-- 2) Email-gated SECDEF RPC (D0 terminal surface) ----------------------------
CREATE OR REPLACE FUNCTION public.get_sg_blindspot_evo_tracking(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.rank)
    FROM (
      SELECT * FROM public.v_sg_blindspot_evo_tracking
      ORDER BY rank
      LIMIT greatest(1, least(p_limit, 500))
    ) t
  ), '[]'::jsonb);
END
$function$;

GRANT EXECUTE ON FUNCTION public.get_sg_blindspot_evo_tracking(integer) TO authenticated;
REVOKE ALL ON FUNCTION public.get_sg_blindspot_evo_tracking(integer) FROM anon, public;
