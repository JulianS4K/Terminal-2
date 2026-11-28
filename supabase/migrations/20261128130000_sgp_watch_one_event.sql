-- Migration 20261128130000 · level:data-collection · lane:a1 (SeatGeek primary watch, ProVenue watch) · writes:sgp_watch_config(+only_event_ids; on: one game hourly),sgp_watch_tick()(patched in place: only_event_ids),provenue_watch_config(daily_cap 33 -> 20) · reads:—
--
-- ONE SEATGEEK GAME, READ EVERY HOUR, ON THE STARTER PLAN. Operator 2026-11-28: "pick one seatgeek event to poll
-- hourly on starter plan".
--
-- THE GAME: Houston Texans at Washington Commanders, Northwest Stadium, 2026-12-13 18:00 UTC (SeatGeek 18142265, EVO
-- 3286202). Of the SeatGeek-primary games of the next three weeks it is the one our book holds most orders for at
-- its venue on its date (108; then Bruins at Panthers 63, Packers at Saints 61).
--
-- sgp_watch_config.only_event_ids (NULL = every game) narrows what the watch CAPTURES to the games listed; the
-- catalogue (every game in the CRM feed as not_polled, mig 20261128100000) is unchanged. The watch is switched on
-- for it: an hour's band, at most one capture an hour and one in flight, 24 a day. Hourly until kick-off is about
-- 15 x 24 = 360 captures. The plan is shared (Starter: 1,000 a month, 959 left), so the ProVenue watch's daily cap
-- goes from 33 to 20 to leave room for both until the plan renews.
--
-- rollback: UPDATE sgp_watch_config SET enabled = false, only_event_ids = NULL;
--           UPDATE provenue_watch_config SET daily_cap = 33;

BEGIN;

ALTER TABLE public.sgp_watch_config ADD COLUMN IF NOT EXISTS only_event_ids text[];

DO $surgery$
DECLARE
  v_src text;
  v_old text := '     WHERE (v_cfg.horizon_days IS NULL OR g.event_utc < now() + make_interval(days => v_cfg.horizon_days))';
  v_new text := '     WHERE (v_cfg.horizon_days IS NULL OR g.event_utc < now() + make_interval(days => v_cfg.horizon_days))'
                || E'\n       AND (v_cfg.only_event_ids IS NULL OR g.sg_event_id = ANY (v_cfg.only_event_ids))  -- mig 20261128130000';
BEGIN
  SELECT pg_get_functiondef('public.sgp_watch_tick()'::regprocedure) INTO v_src;
  IF position('mig 20261128130000' in v_src) > 0 THEN
    RAISE NOTICE 'sgp_watch_tick already honours only_event_ids';
    RETURN;
  END IF;
  IF (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sgp_watch_tick: the line to patch is not there exactly once';
  END IF;
  EXECUTE replace(v_src, v_old, v_new);
END $surgery$;

UPDATE public.sgp_watch_config
   SET only_event_ids = ARRAY['18142265'], enabled = true, every = interval '1 hour',
       daily_cap = 24, hourly_cap = 1, max_in_flight = 1, fires_per_tick = 1,
       note = 'one game hourly on Starter: Texans at Commanders 2026-12-13 (operator 2026-11-28)';
UPDATE public.provenue_watch_config SET daily_cap = 20,
       note = 'Starter plan shared with the SeatGeek watch''s hourly game: 20 a day (operator 2026-11-28)';

COMMIT;
