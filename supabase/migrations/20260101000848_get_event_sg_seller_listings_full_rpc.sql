-- 20260606195432_get_event_sg_seller_listings_full_rpc.sql
--
-- ## Already applied to prod — applied via MCP 2026-06-06 (operator-authorized)
--
-- D0 FE: our SG SellerDirect LISTINGS for an event (companion to get_event_sg_seller_orders_full).
-- Keys on tevo_event_id (populated by sg_seller_sync_and_map, mig 20260606195118). Latest
-- snapshot per seller_listing_id (dedup change-history). Email-gated @s4kent.com.
-- Wired into static/terminal/event.{html,js} as the "OUR SG INVENTORY" sub-section.
CREATE OR REPLACE FUNCTION public.get_event_sg_seller_listings_full(p_event_id integer, p_limit integer DEFAULT 250)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $function$
DECLARE v_email text; v_out jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;

  WITH latest AS (
    SELECT DISTINCT ON (seller_listing_id)
      seller_listing_id, sg_listing_id, sg_event_id, sg_event_name, sg_venue,
      sg_event_date, sg_event_time, quantity, section, "row", seat_from, seat_thru,
      cost, is_edelivery, is_instant, in_hand_date, notes, pulled_at
    FROM public.seatgeek_seller_listings
    WHERE tevo_event_id = p_event_id
    ORDER BY seller_listing_id, pulled_at DESC
  )
  SELECT jsonb_build_object(
    'count', (SELECT count(*) FROM latest),
    'event_id', p_event_id,
    'summary', (SELECT jsonb_build_object(
                  'total_listings', count(*),
                  'total_tickets', coalesce(sum(quantity),0),
                  'median_cost', percentile_cont(0.5) WITHIN GROUP (ORDER BY cost) FILTER (WHERE cost IS NOT NULL),
                  'min_cost', min(cost), 'max_cost', max(cost),
                  'captured_at', max(pulled_at)
                ) FROM latest),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.cost NULLS LAST)
                      FROM (SELECT * FROM latest ORDER BY cost NULLS LAST
                            LIMIT greatest(1, least(p_limit,500))) r), '[]'::jsonb)
  ) INTO v_out;

  IF (v_out->>'count')::int = 0 THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'no_seller_listings', 'count', 0, 'rows', '[]'::jsonb);
  END IF;
  RETURN v_out;
END $function$;
GRANT EXECUTE ON FUNCTION public.get_event_sg_seller_listings_full(integer,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.get_event_sg_seller_listings_full(integer,integer) FROM anon, public;
