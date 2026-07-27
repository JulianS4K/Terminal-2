-- Migration 20260615140000 · lane:D0 (author) → A1 (apply) · writes:ticketsdata_event_xref (seed SH+VD rows for World Cup) · reads:sg_events_canonical, aq_event_map · pre:20260615130000_wc_sg_event_listings_sales · auth:operator-requested 2026-06-15 ("collect for all available sources" for World Cup)
--
-- D0 — enable TicketsData collection (StubHub + VividSeats) for the 2026 World
-- Cup matches, so the terminal can show those markets' listings alongside
-- SeatGeek. The AQ hub already carries the native StubHub + VividSeats event ids
-- for these matches (sh_event_id 90/101, vivid_event_id 101/101); both
-- marketplaces' /fetch URLs are DETERMINISTIC from the native id:
--   SH → https://www.stubhub.com/x/event/<id>/
--   VD → https://www.vividseats.com/production/<id>
-- (verified against 526 SH + 530 VD existing rows — every event_url is the
-- native id). So we can seed ticketsdata_event_xref directly; the already-active
-- td_enqueue_peak_sh / _vd crons (every 10m, budget-gated by td_budget_ok) +
-- td_pull_drain + td_normalize_drain then collect them on the normal cadence.
--
-- NOT seeded here: Ticketmaster + GameTime — their /fetch URLs are slug-based
-- (only 28/145 TM and 177/275 GT rows carry a URL), so they can't be built from
-- the id and need TD's discovery step (td_tm_discover / td_gt_discover, which
-- match by performer_url). Tracked as a follow-up.
--
-- Idempotent: ON CONFLICT (event_id, platform) reactivates + refreshes the URL.
-- enqueue eligibility (td_enqueue_peak): active=true + event_url set + the event
-- resolves through aq_short_event_id → aq_event_map → sg_events_canonical with a
-- future-ish sg_datetime_utc — all satisfied for these rows.

WITH wc AS (
  SELECT DISTINCT a.aq_short_event_id, a.sh_event_id, a.vivid_event_id
  FROM public.sg_events_canonical c
  JOIN public.aq_event_map a ON a.sg_event_id = c.sg_event_id
  WHERE c.sg_event_name ILIKE '%world cup - match%'
)
-- StubHub
INSERT INTO public.ticketsdata_event_xref
  (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, created_at, updated_at)
SELECT sh_event_id, 'SH', aq_short_event_id,
       'https://www.stubhub.com/x/event/' || sh_event_id || '/',
       true, false, 'hub_seed_wc', now(), now()
FROM wc
WHERE sh_event_id IS NOT NULL
ON CONFLICT (event_id, platform) DO UPDATE
  SET active = true,
      event_url = EXCLUDED.event_url,
      aq_short_event_id = COALESCE(public.ticketsdata_event_xref.aq_short_event_id, EXCLUDED.aq_short_event_id),
      updated_at = now();

WITH wc AS (
  SELECT DISTINCT a.aq_short_event_id, a.sh_event_id, a.vivid_event_id
  FROM public.sg_events_canonical c
  JOIN public.aq_event_map a ON a.sg_event_id = c.sg_event_id
  WHERE c.sg_event_name ILIKE '%world cup - match%'
)
-- VividSeats
INSERT INTO public.ticketsdata_event_xref
  (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, created_at, updated_at)
SELECT vivid_event_id, 'VD', aq_short_event_id,
       'https://www.vividseats.com/production/' || vivid_event_id,
       true, false, 'hub_seed_wc', now(), now()
FROM wc
WHERE vivid_event_id IS NOT NULL
ON CONFLICT (event_id, platform) DO UPDATE
  SET active = true,
      event_url = EXCLUDED.event_url,
      aq_short_event_id = COALESCE(public.ticketsdata_event_xref.aq_short_event_id, EXCLUDED.aq_short_event_id),
      updated_at = now();
