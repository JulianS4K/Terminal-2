-- Migration 20260917040000 · level:data-collection · lane:A1 · writes:v_listings_poll_scope_events (view, +1 source), listings_poll_scope_policy (default + the one row's sources[]) · reads:seatgeek_sales_snapshots · pre:20260917030000
--
-- ============================================================================================
-- "SG SALES" MEANS BOTH: OUR SEATGEEK ORDERS AND THE PUBLIC SEATGEEK SALES FEED.
-- ============================================================================================
-- Operator 2026-09-17, on being asked which "sg sales" the poll scope should read:
--   "Both our and public sg orders."
-- Mig 20260917030000 read only seatgeek_orders (our sales). This adds seatgeek_sales_snapshots
-- (the public SeatGeek sales feed, every seller) as a fifth scope source.
--
-- Measured 2026-09-17 00:40Z:
--   seatgeek_sales_snapshots rows                    22,022,820
--   distinct tevo events in it                            5,473
--   of those, future and pollable                         1,255
--   of those, NOT already in scope via the other four       783
--   future events in scope after this change              2,727   (was 1,944)
--
-- HOW IT IS READ. The pollers run this view every two minutes, and a plain
--   SELECT DISTINCT tevo_event_id over 22M rows costs ~3.0 s per tick. A recursive skip scan over
--   idx_sg_sales_event_at (tevo_event_id, sale_at_utc DESC) walks one index probe per distinct
--   id: same 5,473 ids in 85 ms. That is what the view does — no materialisation, no refresh job,
--   a sale that lands in the feed puts its event in scope on the next tick.
--
-- ROLLBACK (data): UPDATE public.listings_poll_scope_policy
--                    SET sources = array_remove(sources, 'seatgeek_sales_snapshots') WHERE key='default';
-- ============================================================================================

CREATE OR REPLACE VIEW public.v_listings_poll_scope_events AS
  WITH RECURSIVE pol AS (
    SELECT sources FROM public.listings_poll_scope_policy WHERE key = 'default'
  ),
  -- loose index scan: one probe per distinct tevo_event_id (see header)
  sg_pub AS (
    SELECT min(s.tevo_event_id) AS id
      FROM public.seatgeek_sales_snapshots s
     WHERE s.tevo_event_id IS NOT NULL
    UNION ALL
    SELECT (SELECT min(s.tevo_event_id)
              FROM public.seatgeek_sales_snapshots s
             WHERE s.tevo_event_id > sg_pub.id)
      FROM sg_pub
     WHERE sg_pub.id IS NOT NULL
  )
  SELECT o.tevo_event_id
    FROM public.s4kcs_orders o, pol
   WHERE o.tevo_event_id IS NOT NULL AND 's4kcs_orders' = ANY(pol.sources)
  UNION
  SELECT n.tevo_event_id
    FROM public.n2s_items n, pol
   WHERE n.tevo_event_id IS NOT NULL AND 'n2s_items' = ANY(pol.sources)
  UNION
  SELECT s.tevo_event_id
    FROM public.seatgeek_orders s, pol
   WHERE s.tevo_event_id IS NOT NULL AND 'seatgeek_orders' = ANY(pol.sources)
  UNION
  SELECT p.tevo_event_id
    FROM public.gotickets_purchases p, pol
   WHERE p.tevo_event_id IS NOT NULL AND 'gotickets_purchases' = ANY(pol.sources)
  UNION
  SELECT sg_pub.id
    FROM sg_pub, pol
   WHERE sg_pub.id IS NOT NULL AND 'seatgeek_sales_snapshots' = ANY(pol.sources);
COMMENT ON VIEW public.v_listings_poll_scope_events IS
  'TEvo event ids the listings pollers are allowed to poll while listings_poll_scope_policy.enabled. UNION of the enabled sources: CRM orders (s4kcs_orders), N2S items, our SeatGeek orders (seatgeek_orders), GoTickets purchases, and the public SeatGeek sales feed (seatgeek_sales_snapshots, read by a recursive skip scan). Not materialised.';
REVOKE ALL ON public.v_listings_poll_scope_events FROM anon, authenticated;

ALTER TABLE public.listings_poll_scope_policy
  ALTER COLUMN sources SET DEFAULT ARRAY['s4kcs_orders','n2s_items','seatgeek_orders','gotickets_purchases','seatgeek_sales_snapshots'];

UPDATE public.listings_poll_scope_policy
   SET sources    = array_append(sources, 'seatgeek_sales_snapshots'),
       note       = coalesce(note,'') || ' + 2026-09-17 "Both our and public sg orders": public SeatGeek sales feed (seatgeek_sales_snapshots) added as a scope source (mig 20260917040000).',
       updated_at = now()
 WHERE key = 'default'
   AND NOT ('seatgeek_sales_snapshots' = ANY(sources));
