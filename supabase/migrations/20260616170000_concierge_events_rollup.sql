-- Migration 20260616170000 · lane:D3 (author) → A1 (apply) · writes:concierge_events (new table + refresh fn) · reads:broker_listings, events, event_lifecycle · pre:20260616153000_wc_2026_add_seatgeek_market_data · auth:operator-requested 2026-06-16 ("show concierge tickets … top seats, any event")
--
-- D3 — back the storefront "Concierge · premium seats" rail. EVO-ONLY (per the
-- 2026-06-16 directive: the consumer store features no SeatGeek data). For every
-- upcoming owned event we hold PREMIUM top-band seats in, roll up the premium
-- inventory from broker_listings (our EVO/TEvo book):
--   premium seat = owned listing with retail_price >= $500 (the concierge band;
--                  sections are numeric in TEvo so price, not section name, is
--                  the signal — floor/courtside/suite all surface by price).
--   concierge event = holds >= 1 premium seat.
--   from_price = cheapest premium seat (entry into the event's premium tier).
--
-- Maintained by refresh_concierge_events() off the LATEST broker snapshot
-- (captured within 36h => the event is live; this also sidesteps the ghost
-- detector's stale-poll false negatives). Idempotent full rebuild; safe to
-- re-run / cron later. The /api/store/concierge endpoint applies the NYC venue
-- filter + date window at read time.

CREATE TABLE IF NOT EXISTS public.concierge_events (
  event_id                bigint PRIMARY KEY,      -- TEvo event id
  name                    text,
  venue_name              text,
  venue_location          text,
  occurs_at_local         text,
  occurs_date             date,
  primary_performer_name  text,
  from_price              numeric,                 -- min premium seat (>= 500)
  prem_max_price          numeric,                 -- highest premium seat
  prem_tickets            int,                     -- premium tickets we hold
  prem_groups             int,                     -- premium ticket groups
  refreshed_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.concierge_events IS
  'Storefront concierge rail rollup: upcoming owned events with premium (>= $500) top-band seats, from broker_listings (EVO only). Maintained by refresh_concierge_events(). D3 2026-06-16.';

CREATE INDEX IF NOT EXISTS idx_concierge_events_date ON public.concierge_events(occurs_date);
CREATE INDEX IF NOT EXISTS idx_concierge_events_max  ON public.concierge_events(prem_max_price DESC);

ALTER TABLE public.concierge_events ENABLE ROW LEVEL SECURITY;  -- backend-only, matches peers

CREATE OR REPLACE FUNCTION public.refresh_concierge_events()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_rows int;
BEGIN
  DELETE FROM public.concierge_events;
  INSERT INTO public.concierge_events (
    event_id, name, venue_name, venue_location, occurs_at_local, occurs_date,
    primary_performer_name, from_price, prem_max_price, prem_tickets, prem_groups, refreshed_at
  )
  WITH latest AS (
    -- Current premium owned listings: dedupe each ticket group to its newest
    -- snapshot, scoped to upcoming events (bounds the scan).
    SELECT DISTINCT ON (bl.tevo_ticket_group_id)
           bl.event_id, bl.tevo_ticket_group_id, bl.quantity, bl.retail_price
    FROM public.broker_listings bl
    JOIN public.events e ON e.id = bl.event_id
    WHERE bl.is_owned
      AND bl.retail_price >= 500
      AND bl.captured_at >= now() - interval '36 hours'
      AND e.occurs_at_local >= now()::date::text
      AND e.occurs_at_local <  (now() + interval '120 days')::date::text || 'T23:59:59'
    ORDER BY bl.tevo_ticket_group_id, bl.captured_at DESC
  ),
  agg AS (
    SELECT event_id,
           min(retail_price) AS from_price,
           max(retail_price) AS prem_max,
           sum(quantity)     AS prem_tickets,
           count(DISTINCT tevo_ticket_group_id) AS prem_groups
    FROM latest GROUP BY event_id
  )
  SELECT a.event_id, e.name, e.venue_name, e.venue_location, e.occurs_at_local,
         e.occurs_at_local::date, e.primary_performer_name,
         a.from_price, a.prem_max, a.prem_tickets, a.prem_groups, now()
  FROM agg a
  JOIN public.events e ON e.id = a.event_id
  WHERE upper(coalesce(e.name, '')) NOT LIKE '%CANCELLED%';

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('rows', v_rows, 'refreshed_at', now());
END;
$fn$;

SELECT public.refresh_concierge_events();
