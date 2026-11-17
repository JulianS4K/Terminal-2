-- Migration 20260811264000 · lane:D0 · operator-directed 2026-08-11
--   ("auto remove when event is under 14 days away or listing is gone").
--
--   writes: cron gt_ingest_cascade_1min [append a <14d feed-retire step].
--
-- WHY. Deals are for events with runway to flip; once an event is within 14 days the deal is
-- past its useful window, so it should drop off the feed. (Listing-gone retirement is already
-- handled per-pass by gt_listings_drain, mig 20260811261000.) Append a global retire to the
-- 1-min cascade: mark gone_at on any live feed row whose event is now < 14 days out. Cheap
-- (small feed), runs alongside the drain→scan cascade.
--
-- ROLLBACK: SELECT cron.schedule('gt_ingest_cascade_1min','* * * * *',
--   $$SELECT public.gt_listings_drain(3000); SELECT public.scan_gotickets_deals(30);$$);

SELECT cron.schedule('gt_ingest_cascade_1min', '* * * * *', $$
  SELECT public.gt_listings_drain(3000);
  SELECT public.scan_gotickets_deals(30);
  UPDATE public.gotickets_deals_feed SET gone_at = now()
   WHERE gone_at IS NULL AND event_date IS NOT NULL
     AND event_date < (now() + interval '14 days')::date;
$$);
