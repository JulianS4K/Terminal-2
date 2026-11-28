-- Migration 20261128070000 · level:data-collection · lane:a1 (ProVenue watch) · writes:v_provenue_watch_games(replace) · reads:mlb_ticket_game
--
-- The Reds were never read. Their 80 regular-season games link to https://mlb.tickets.com?orgid=6&agency=MLB_MPV&pid=…
-- with no '/' between the host and the '?', and v_provenue_watch_games required one. The host may now be followed by
-- '/' or '?'. Operator 2026-11-28: "fix the reds". (The other clubs newly on ProVenue in the schedule, the Cubs,
-- White Sox, Tigers, Royals, Dodgers, Brewers, Mariners and Rangers, are spring training only, which the watch
-- leaves out by design: game_type 'R'.)

BEGIN;

CREATE OR REPLACE VIEW public.v_provenue_watch_games AS
SELECT DISTINCT ON (g.primary_event_id)
       g.primary_event_id AS pid, g.mlb_game_id, g.ticket_url, g.game_time_utc, g.game_date, g.game_time_local,
       g.time_zone_local, g.home_abbrev, g.away_abbrev, g.home_name, g.away_name, g.venue_name, g.venue_city,
       g.tevo_event_id, g.on_sale_start
  FROM public.mlb_ticket_game g
 WHERE g.primary_seller = 'provenue'
   AND g.primary_event_id ~ '^[0-9]+$'
   AND g.sport_id = 1 AND g.game_type = 'R'
   AND g.removed_at IS NULL
   -- the host then '/' or '?': the Reds' links are https://mlb.tickets.com?orgid=6&... (no slash)
   AND g.ticket_url ~* '^https://(mlb|mpv)\.tickets\.com[/?]'
   AND g.game_time_utc > now()
   -- on_sale_start is the schedule's Eastern wall time
   AND (g.on_sale_start IS NULL OR g.on_sale_start <= (now() AT TIME ZONE 'America/New_York'))
 ORDER BY g.primary_event_id, g.game_time_utc;
REVOKE ALL ON public.v_provenue_watch_games FROM PUBLIC, anon, authenticated;

COMMIT;
