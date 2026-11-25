-- Migration 20261125180000 · level:data-collection · lane:A1 (box-office collector) + D0 (the feed's view — cross-lane, flagged to bot_chat) · writes:primary_poll_config(+send_ada),v_primary_poll_listings_feed(re-created, same columns) · reads:primary_poll_listing · pre:20261124230030
--
-- ACCESSIBLE SEATS ARE NOT SENT TO THE API.
-- Operator 2026-11-25: "also dont send out ADA seats too".
--
-- WHERE IT IS DONE. In the feed view, beside the obstructed clause, not in axs_watch_parse. The two withholding
-- styles already in use differ on purpose: a non-transferable listing (mig 20261124233030) is never stored,
-- because we could not deliver it and it is not inventory; an obstructed one IS stored and withheld by the view,
-- because it is real inventory we choose not to offer. Accessible seats are the second kind — real, priced,
-- deliverable inventory we are choosing not to broadcast — so they are kept in primary_poll_listing (metrics,
-- total_available and the event's own picture stay whole) and dropped on the way out. primary_poll_config.send_ada
-- (false) turns it back on without a migration.
--
-- ⚠ THE `ada` COLUMN ALONE IS NOT ENOUGH — the landmine that makes this migration non-obvious.
-- On AXS, 2026-11-25:
--     ada = true                        101 listings     1,113 seats
--     ticket_type = 'ACCESSIBLE'      1,394 listings    ~10,262 seats
--     either                          1,478 listings    ~10,600 seats
-- Only 17 of the 1,394 ACCESSIBLE listings carry ada = true, so a filter on `ada` would have let 93% of the
-- accessible inventory through — and it would have looked like it worked, because the 60-seat Accessible 70 row
-- on Nora En Pure (the event this started from) happens to be one of the 17. Both signals are tested.
-- The ada flag does carry 84 FLASHSEATS (AXS resale) listings that have no ACCESSIBLE type, so neither signal
-- covers the other.
--
-- EVERY SOURCE. The view is shared, so this withholds across the board: AXS 1,478 listings, SI Tickets 21,
-- Timberwolves 0 (its site marks none). That is deliberate — the operator's rule is about what we broadcast, not
-- about one collector.
--
-- NOT CHANGED, a pre-existing wart worth knowing. v_primary_poll_events_feed reports listing_count from
-- primary_poll_event.listing_count, which counts every listing stored — obstructed ones already included, and now
-- accessible ones too. So an event's listing_count can exceed the rows /primary/listings returns. That was
-- already true of obstructed before this change; making the count match the feed would change a number other
-- consumers read, so it is left alone and flagged rather than quietly altered.
--
-- Applied to prod via MCP 2026-11-25 17:51Z, at the second attempt: the first failed with "Failed to initialise
-- history table: Connection terminated" during a database outage, and the state was verified clean (no column, view
-- unchanged) before re-applying. Verified after: send_ada false, 1,499 accessible listings stored, 0 reaching the
-- feed, which holds 175,161 rows. Cross-lane notice filed to D0 as bot_chat 7534. Re-apply is a no-op.
--
-- rollback: UPDATE public.primary_poll_config SET send_ada = true;  (immediate, no re-deploy) or re-create
--           v_primary_poll_listings_feed from mig 20261124230030 and drop the column.

BEGIN;

ALTER TABLE public.primary_poll_config
  ADD COLUMN IF NOT EXISTS send_ada boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.primary_poll_config.send_ada IS
  'false: accessible seats (ada, or ticket_type ACCESSIBLE) are stored but not sent by /primary/listings (mig 20261125180000). true restores them.';

CREATE OR REPLACE VIEW public.v_primary_poll_listings_feed
WITH (security_invoker = true) AS
SELECT l.source,
       l.source_event_id AS event_id,
       t.name AS event_name,
       t.tevo_event_id,
       t.event_date,
       t.start_local_time,
       CASE WHEN p.part IS NOT NULL THEN l.listing_id || '-' || p.part ELSE l.listing_id END AS listing_id,
       l.market,
       l.area,
       l.section,
       l.seat_row,
       CASE WHEN p.part IS NOT NULL THEN p.seat_low  ELSE l.seat_low  END AS seat_low,
       CASE WHEN p.part IS NOT NULL THEN p.seat_high ELSE l.seat_high END AS seat_high,
       CASE WHEN p.part IS NOT NULL THEN p.seats     ELSE l.seats     END AS seats,
       CASE WHEN p.part IS NOT NULL THEN p.quantity  ELSE l.quantity  END AS quantity,
       CASE WHEN p.part IS NOT NULL AND jsonb_typeof(l.allowed_quantities) = 'array'
            THEN (SELECT jsonb_agg(q.v ORDER BY q.i)
                    FROM jsonb_array_elements(l.allowed_quantities) WITH ORDINALITY q(v, i)
                   WHERE jsonb_typeof(q.v) = 'number'
                     AND ((q.v #>> '{}'))::numeric <= (least(l.order_limit, p.quantity))::numeric)
            ELSE l.allowed_quantities END AS allowed_quantities,
       CASE WHEN p.part IS NOT NULL THEN least(l.order_limit, p.quantity)
            WHEN l.order_limit IS NOT NULL THEN least(l.order_limit, l.quantity)
            ELSE l.max_per_order END AS max_per_order,
       t.order_min,
       t.order_max,
       l.price,
       l.fee,
       l.all_in_price,
       l.price_includes_tax,
       t.currency,
       l.ticket_type,
       l.delivery,
       l.ada,
       l.aisle,
       l.general_admission,
       t.poll_ok_at AS as_of,
       l.tax,
       l.order_fee,
       l.price_estimated
  FROM public.primary_poll_listing l
  JOIN public.primary_poll_event t ON t.source = l.source AND t.source_event_id = l.source_event_id
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
  LEFT JOIN public.primary_poll_listing_piece p
         ON p.source = l.source AND p.source_event_id = l.source_event_id AND p.listing_id = l.listing_id
        AND (SELECT c.split_over_limit FROM public.primary_poll_config c)
 WHERE t.poll_status = 'ok'
   AND NOT public.primary_poll_ended(t.start_utc, t.event_date)
   AND now() < greatest(t.poll_ok_at + (SELECT c.listing_max_age FROM public.primary_poll_config c),
                        t.next_poll_at + (SELECT c.listing_grace FROM public.primary_poll_config c))
   AND NOT l.obstructed
   -- accessible seats are withheld: both signals, because ada alone misses 93% of them (see the header)
   AND ((SELECT c.send_ada FROM public.primary_poll_config c)
        OR NOT (coalesce(l.ada, false) OR l.ticket_type = 'ACCESSIBLE'))
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_listings_feed TO service_role;

COMMIT;
