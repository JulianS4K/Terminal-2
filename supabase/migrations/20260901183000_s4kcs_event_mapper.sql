-- Migration 20260901183000 · level:secondary-sales · lane:D0 · writes:s4kcs_orders · reads:aq_event_map,vivid_orders,tickpick_orders · pre:20260901180000
--
-- Resolve S4K CRM orders to a canonical tevo event.
--
-- THE PROBLEM. 87% of the CRM's events had no tevo_event_id, so the
-- substitution checker could not search them at all — every cover had to be
-- resolved by hand first.
--
-- WHY NOT match_to_aq_event_id(). The CRM payload carries NO source event id
-- — only event_name, event_date (a DATE, no time) and venue_name. That rules
-- out four of that function's five tiers: tier0/tier1 need a source event id,
-- tier1_5 a source venue id, tier4 lat/lon. What remains is venue+date inside
-- a ±6h window, which a date-only feed cannot satisfy (midnight vs a 19:00
-- event) and which is unsafe here anyway: 17.5% of CRM venue-days carry more
-- than one event — the US Open runs up to five sessions at one venue on one
-- day. The hub's own sh_event_id / sg_event_id columns don't help either: the
-- CRM gives ORDER ids, not event ids.
--
-- ⚠ WHY EXACT NAME AND NOT A SIMILARITY THRESHOLD.
-- Calibrated against four orders whose correct event was established
-- independently. The right answer scored trigram similarity 1.000 every time
-- — but the WRONG adjacent session scored 0.907, and other wrong sessions
-- 0.884 / 0.857 / 0.852 / 0.821. No threshold separates them. A 0.9 cutoff
-- would confidently map orders to the wrong session of the same tournament,
-- which is worse than leaving them unmapped: a wrong event silently prices a
-- cover against another event's listings. So only a NORMALIZED-EXACT name
-- match is accepted — case and punctuation folded, so the feed's
-- "Session 8:" and the hub's "Session 8 -" agree — and only when the
-- candidates agree on ONE tevo id.
--
-- Tiers, strongest first; each only fills rows still unmapped:
--   order_id_vivid    1.00  our vivid_orders book, joined on order id
--   order_id_tickpick 1.00  our tickpick_orders book, joined on order id
--   name_date_venue   0.98  exact name + date + exact venue name
--   name_date         0.92  exact name + date (venue strings differ in shape)
--
-- Measured on first run: 12,268 of 22,725 orders mapped (54%, from ~12%),
-- and all four hand-verified orders resolved to the correct session.

ALTER TABLE public.s4kcs_orders
  ADD COLUMN IF NOT EXISTS map_method     text,
  ADD COLUMN IF NOT EXISTS map_confidence numeric(3,2),
  ADD COLUMN IF NOT EXISTS mapped_at      timestamptz;

COMMENT ON COLUMN public.s4kcs_orders.map_method IS
  'How tevo_event_id was resolved: order_id_vivid | order_id_tickpick | name_date_venue | name_date. NULL = unmapped.';

CREATE OR REPLACE FUNCTION public.s4kcs_map_events()
RETURNS TABLE(method text, orders_mapped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n integer;
BEGIN
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = v.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, v.aq_short_event_id),
         map_method = 'order_id_vivid', map_confidence = 1.00, mapped_at = now()
    FROM public.vivid_orders v
   WHERE s.source = 'Vivid Seats' AND v.vivid_order_id = s.s4k_order_id
     AND v.tevo_event_id IS NOT NULL AND s.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'order_id_vivid'::text, v_n;

  UPDATE public.s4kcs_orders s
     SET tevo_event_id = t.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, t.aq_short_event_id),
         map_method = 'order_id_tickpick', map_confidence = 1.00, mapped_at = now()
    FROM public.tickpick_orders t
   WHERE s.source = 'TickPick' AND t.tp_order_id = s.s4k_order_id
     AND t.tevo_event_id IS NOT NULL AND s.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'order_id_tickpick'::text, v_n;

  WITH cand AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date AS d,
           lower(trim(a.venue_name)) AS vk,
           min(a.tevo_event_id) AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.event_name IS NOT NULL
       AND a.event_date IS NOT NULL AND a.venue_name IS NOT NULL
     GROUP BY 1,2,3
    HAVING count(DISTINCT a.tevo_event_id) = 1   -- candidates must agree
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'name_date_venue', map_confidence = 0.98, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND regexp_replace(lower(s.event_name), '[^a-z0-9]+', '', 'g') = c.nk
     AND s.event_date = c.d
     AND lower(trim(s.venue_name)) = c.vk;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'name_date_venue'::text, v_n;

  WITH cand AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date AS d,
           min(a.tevo_event_id) AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.event_name IS NOT NULL AND a.event_date IS NOT NULL
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'name_date', map_confidence = 0.92, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND regexp_replace(lower(s.event_name), '[^a-z0-9]+', '', 'g') = c.nk
     AND s.event_date = c.d;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'name_date'::text, v_n;
END;
$$;

REVOKE ALL ON FUNCTION public.s4kcs_map_events() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_map_events() TO service_role;
