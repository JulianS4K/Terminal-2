-- Migration 20261117010000 · level:data-collection · lane:A1 (data plane — AXS catalogue) · writes:axs_event_market_map(new),axs_market_fallback_match(new),v_axs_event_map(new)
--
-- AXS-primary events that EVO does not carry get a market event to stand in for it
-- (operator 2026-11-17: "Where no evo map to go tickets and if no go tickets map to seatgeek").
--
-- WHAT IT COVERS. An upcoming US event in the AXS export feed (`axs_export_event`, which
-- `axs_export_match()` matches to TEvo `events`) that is AXS-ticketed (`type = 'axs_primary'`) and has
-- no `tevo_event_id`. On 2026-11-17 that was 3,699 of 7,328.
--
-- THE ORDER. 1. EVO, as before (nothing here touches that match). 2. GoTickets (`gotickets_event`,
-- the whole GoTickets catalogue). 3. SeatGeek (`sg_events_canonical`), only for an event GoTickets
-- did not match. One market event per AXS event, and one AXS event per market event.
--
-- THE MATCH. Same city and state, start times within 90 minutes, then one of:
--   venue_title   venue names alike (similarity >= 0.5) and titles alike (>= 0.3)
--   title_city    titles nearly the same (>= 0.6): the marketplace names the venue differently
--                 ("Absinthe" is "The Spiegeltent at Caesars Palace" on GoTickets)
--   venue_time    venue names the same (>= 0.9), starts within 15 minutes, and no other event of
--                 that marketplace at that venue in the window: the title is worded differently
-- A marketplace's parking listing ("Trivium Parking" at "... Parking") is never a match for a show.
-- Thresholds were set against a sample of the 2026-11-17 list: title-only matches under 0.6 were
-- mostly parking or another venue; venue-only matches at multi-room venues were the wrong room.
--
-- IT FOLLOWS THE DATA. Each run withdraws a pairing whose AXS event has since matched EVO, left the
-- feed, or whose market event was cancelled or moved, and matches again. Withdrawn rows stay, marked.
-- Nothing is written to `aq_event_map` (the hub) or to `axs_export_event`: this is a side table, read
-- through `v_axs_event_map`, which says per event whether it resolved to evo, gotickets or seatgeek.
--
-- No schedule is created here: `SELECT public.axs_market_fallback_match();` is run by hand until the
-- operator approves the hourly job at the foot of this file. Nothing upstream is called (RULE 2).
--
-- rollback: DROP VIEW public.v_axs_event_map; DROP FUNCTION public.axs_market_fallback_match(integer);
--           DROP TABLE public.axs_event_market_map;

CREATE TABLE IF NOT EXISTS public.axs_event_market_map (
  axs_event_id      bigint PRIMARY KEY,
  market            text NOT NULL CHECK (market IN ('gotickets', 'seatgeek')),
  market_event_id   bigint NOT NULL,
  method            text NOT NULL CHECK (method IN ('venue_title', 'title_city', 'venue_time')),
  venue_sim         numeric(4,3),
  title_sim         numeric(4,3),
  time_diff_min     integer,
  market_event_name text,
  market_venue_name text,
  matched_at        timestamptz NOT NULL DEFAULT now(),
  withdrawn_at      timestamptz,                 -- NULL = in force
  withdrawn_reason  text
);
-- one AXS event per market event while the pairing is in force
CREATE UNIQUE INDEX IF NOT EXISTS axs_event_market_map_market_uidx
  ON public.axs_event_market_map (market, market_event_id) WHERE withdrawn_at IS NULL;
ALTER TABLE public.axs_event_market_map ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_event_market_map FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_event_market_map TO service_role;
COMMENT ON TABLE public.axs_event_market_map IS
  'AXS-primary events with no EVO match, paired to a GoTickets event, else a SeatGeek event (axs_market_fallback_match). withdrawn_at NULL = in force. Read through v_axs_event_map. 20261117010000.';

CREATE OR REPLACE FUNCTION public.axs_market_fallback_match(p_limit integer DEFAULT 100000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_w_evo int := 0; v_w_gone int := 0; v_w_gt int := 0; v_w_sg int := 0;
  v_gt int := 0; v_sg int := 0; v_todo int := 0;
BEGIN
  -- 1. withdraw what no longer holds
  UPDATE public.axs_event_market_map m
     SET withdrawn_at = now(), withdrawn_reason = 'evo_matched'
    FROM public.axs_export_event x
   WHERE x.axs_event_id = m.axs_event_id AND m.withdrawn_at IS NULL AND x.tevo_event_id IS NOT NULL;
  GET DIAGNOSTICS v_w_evo = ROW_COUNT;
  UPDATE public.axs_event_market_map m
     SET withdrawn_at = now(), withdrawn_reason = 'axs_event_gone'
   WHERE m.withdrawn_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.axs_export_event x
                      WHERE x.axs_event_id = m.axs_event_id AND x.gone_at IS NULL AND x.type = 'axs_primary');
  GET DIAGNOSTICS v_w_gone = ROW_COUNT;
  UPDATE public.axs_event_market_map m
     SET withdrawn_at = now(), withdrawn_reason = 'market_event_changed'
    FROM public.axs_export_event x
   WHERE x.axs_event_id = m.axs_event_id AND m.withdrawn_at IS NULL AND m.market = 'gotickets'
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g
                      WHERE g.gt_event_id = m.market_event_id AND g.status = 'AS_SCHEDULED'
                        AND g.event_time_utc BETWEEN x.event_date_utc - interval '90 minutes'
                                                 AND x.event_date_utc + interval '90 minutes');
  GET DIAGNOSTICS v_w_gt = ROW_COUNT;
  UPDATE public.axs_event_market_map m
     SET withdrawn_at = now(), withdrawn_reason = 'market_event_changed'
    FROM public.axs_export_event x
   WHERE x.axs_event_id = m.axs_event_id AND m.withdrawn_at IS NULL AND m.market = 'seatgeek'
     AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical s
                      WHERE s.sg_event_id = m.market_event_id
                        AND s.sg_datetime_utc BETWEEN x.event_date_utc - interval '90 minutes'
                                                  AND x.event_date_utc + interval '90 minutes');
  GET DIAGNOSTICS v_w_sg = ROW_COUNT;

  -- 2. what is to be matched: AXS-primary, upcoming, US, no EVO event, no pairing in force
  SELECT count(*) INTO v_todo FROM (
    SELECT 1 FROM public.axs_export_event x
     WHERE x.type = 'axs_primary' AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_utc >= now() AND x.tevo_event_id IS NULL
       AND x.venue_city IS NOT NULL AND x.venue_state IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.axs_event_id = x.axs_event_id AND m.withdrawn_at IS NULL)
     LIMIT greatest(p_limit, 0)) q;

  -- 3. GoTickets: its events in those cities, parking listings left out
  WITH ax AS MATERIALIZED (
    SELECT x.axs_event_id, lower(btrim(x.venue_name)) AS venue, lower(btrim(x.venue_city)) AS city,
           upper(btrim(x.venue_state)) AS st, x.event_date_utc AS t,
           lower(coalesce(x.event_title_clean, x.event_title, '')) AS title, lower(coalesce(x.headliner, '')) AS head
      FROM public.axs_export_event x
     WHERE x.type = 'axs_primary' AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_utc >= now() AND x.tevo_event_id IS NULL
       AND x.venue_city IS NOT NULL AND x.venue_state IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.axs_event_id = x.axs_event_id AND m.withdrawn_at IS NULL)
     ORDER BY x.event_date_utc
     LIMIT greatest(p_limit, 0)),
  mk AS MATERIALIZED (
    SELECT g.gt_event_id AS id, g.name, g.venue_name, g.event_time_utc AS t,
           lower(btrim(g.venue_name)) AS venue, lower(btrim(g.venue_city)) AS city, upper(btrim(g.venue_state)) AS st,
           lower(coalesce(g.name, '')) AS title, lower(coalesce(g.performer, '')) AS head
      FROM public.gotickets_event g
     WHERE g.event_time_utc >= now() - interval '2 hours' AND g.status = 'AS_SCHEDULED'
       AND (lower(btrim(g.venue_city)), upper(btrim(g.venue_state))) IN (SELECT DISTINCT a.city, a.st FROM ax a)
       AND coalesce(g.name, '') !~* '\mparking\M' AND coalesce(g.venue_name, '') !~* '\mparking\M'
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.market = 'gotickets' AND m.market_event_id = g.gt_event_id AND m.withdrawn_at IS NULL)),
  c AS (
    SELECT a.axs_event_id, k.id, k.name, k.venue_name,
           round(abs(extract(epoch FROM k.t - a.t)) / 60)::int AS dmin,
           similarity(k.venue, a.venue) AS vsim,
           greatest(similarity(k.title, a.title),
                    CASE WHEN a.head <> '' AND k.head <> '' THEN similarity(k.head, a.head) ELSE 0 END) AS tsim
      FROM ax a JOIN mk k ON k.city = a.city AND k.st = a.st
       AND k.t BETWEEN a.t - interval '90 minutes' AND a.t + interval '90 minutes'),
  r AS (
    SELECT c.*, count(*) FILTER (WHERE c.vsim >= 0.9) OVER (PARTITION BY c.axs_event_id) AS n_venue,
           CASE WHEN c.vsim >= 0.5 AND c.tsim >= 0.3 THEN 'venue_title'
                WHEN c.tsim >= 0.6 THEN 'title_city'
                WHEN c.vsim >= 0.9 AND c.dmin <= 15 THEN 'venue_time' END AS method
      FROM c),
  ok AS (SELECT * FROM r WHERE method IN ('venue_title', 'title_city') OR (method = 'venue_time' AND n_venue = 1)),
  b1 AS (SELECT DISTINCT ON (axs_event_id) * FROM ok
          ORDER BY axs_event_id, (method = 'venue_title') DESC, (method = 'title_city') DESC, tsim DESC, vsim DESC, dmin, id),
  b2 AS (SELECT DISTINCT ON (id) * FROM b1
          ORDER BY id, (method = 'venue_title') DESC, (method = 'title_city') DESC, tsim DESC, vsim DESC, dmin, axs_event_id)
  INSERT INTO public.axs_event_market_map AS m
         (axs_event_id, market, market_event_id, method, venue_sim, title_sim, time_diff_min, market_event_name, market_venue_name)
  SELECT axs_event_id, 'gotickets', id, method, round(vsim::numeric, 3), round(tsim::numeric, 3), dmin, name, venue_name FROM b2
  ON CONFLICT (axs_event_id) DO UPDATE SET
    market = EXCLUDED.market, market_event_id = EXCLUDED.market_event_id, method = EXCLUDED.method,
    venue_sim = EXCLUDED.venue_sim, title_sim = EXCLUDED.title_sim, time_diff_min = EXCLUDED.time_diff_min,
    market_event_name = EXCLUDED.market_event_name, market_venue_name = EXCLUDED.market_venue_name,
    matched_at = now(), withdrawn_at = NULL, withdrawn_reason = NULL
   WHERE m.withdrawn_at IS NOT NULL;
  GET DIAGNOSTICS v_gt = ROW_COUNT;

  -- 4. SeatGeek, for what GoTickets did not match (the same list, now without those just paired)
  WITH ax AS MATERIALIZED (
    SELECT x.axs_event_id, lower(btrim(x.venue_name)) AS venue, lower(btrim(x.venue_city)) AS city,
           upper(btrim(x.venue_state)) AS st, x.event_date_utc AS t,
           lower(coalesce(x.event_title_clean, x.event_title, '')) AS title, lower(coalesce(x.headliner, '')) AS head
      FROM public.axs_export_event x
     WHERE x.type = 'axs_primary' AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_utc >= now() AND x.tevo_event_id IS NULL
       AND x.venue_city IS NOT NULL AND x.venue_state IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.axs_event_id = x.axs_event_id AND m.withdrawn_at IS NULL)
     ORDER BY x.event_date_utc
     LIMIT greatest(p_limit, 0)),
  mk AS MATERIALIZED (
    SELECT s.sg_event_id AS id, s.sg_event_name AS name, s.sg_venue_name AS venue_name, s.sg_datetime_utc AS t,
           lower(btrim(s.sg_venue_name)) AS venue, lower(btrim(s.sg_venue_city)) AS city, upper(btrim(s.sg_venue_state)) AS st,
           lower(coalesce(s.sg_event_name, '')) AS title, lower(coalesce(s.sg_event_name, '')) AS head
      FROM public.sg_events_canonical s
     WHERE s.sg_datetime_utc >= now() - interval '2 hours'
       AND (lower(btrim(s.sg_venue_city)), upper(btrim(s.sg_venue_state))) IN (SELECT DISTINCT a.city, a.st FROM ax a)
       AND coalesce(s.sg_event_name, '') !~* '\mparking\M' AND coalesce(s.sg_venue_name, '') !~* '\mparking\M'
       AND NOT EXISTS (SELECT 1 FROM public.axs_event_market_map m
                        WHERE m.market = 'seatgeek' AND m.market_event_id = s.sg_event_id AND m.withdrawn_at IS NULL)),
  c AS (
    SELECT a.axs_event_id, k.id, k.name, k.venue_name,
           round(abs(extract(epoch FROM k.t - a.t)) / 60)::int AS dmin,
           similarity(k.venue, a.venue) AS vsim,
           greatest(similarity(k.title, a.title),
                    CASE WHEN a.head <> '' AND k.head <> '' THEN similarity(k.head, a.head) ELSE 0 END) AS tsim
      FROM ax a JOIN mk k ON k.city = a.city AND k.st = a.st
       AND k.t BETWEEN a.t - interval '90 minutes' AND a.t + interval '90 minutes'),
  r AS (
    SELECT c.*, count(*) FILTER (WHERE c.vsim >= 0.9) OVER (PARTITION BY c.axs_event_id) AS n_venue,
           CASE WHEN c.vsim >= 0.5 AND c.tsim >= 0.3 THEN 'venue_title'
                WHEN c.tsim >= 0.6 THEN 'title_city'
                WHEN c.vsim >= 0.9 AND c.dmin <= 15 THEN 'venue_time' END AS method
      FROM c),
  ok AS (SELECT * FROM r WHERE method IN ('venue_title', 'title_city') OR (method = 'venue_time' AND n_venue = 1)),
  b1 AS (SELECT DISTINCT ON (axs_event_id) * FROM ok
          ORDER BY axs_event_id, (method = 'venue_title') DESC, (method = 'title_city') DESC, tsim DESC, vsim DESC, dmin, id),
  b2 AS (SELECT DISTINCT ON (id) * FROM b1
          ORDER BY id, (method = 'venue_title') DESC, (method = 'title_city') DESC, tsim DESC, vsim DESC, dmin, axs_event_id)
  INSERT INTO public.axs_event_market_map AS m
         (axs_event_id, market, market_event_id, method, venue_sim, title_sim, time_diff_min, market_event_name, market_venue_name)
  SELECT axs_event_id, 'seatgeek', id, method, round(vsim::numeric, 3), round(tsim::numeric, 3), dmin, name, venue_name FROM b2
  ON CONFLICT (axs_event_id) DO UPDATE SET
    market = EXCLUDED.market, market_event_id = EXCLUDED.market_event_id, method = EXCLUDED.method,
    venue_sim = EXCLUDED.venue_sim, title_sim = EXCLUDED.title_sim, time_diff_min = EXCLUDED.time_diff_min,
    market_event_name = EXCLUDED.market_event_name, market_venue_name = EXCLUDED.market_venue_name,
    matched_at = now(), withdrawn_at = NULL, withdrawn_reason = NULL
   WHERE m.withdrawn_at IS NOT NULL;
  GET DIAGNOSTICS v_sg = ROW_COUNT;

  RETURN jsonb_build_object(
    'looked_at', v_todo, 'gotickets_matched', v_gt, 'seatgeek_matched', v_sg,
    'left_unmatched', v_todo - v_gt - v_sg,
    'withdrawn', jsonb_build_object('evo_matched', v_w_evo, 'axs_event_gone', v_w_gone,
                                    'gotickets_event_changed', v_w_gt, 'seatgeek_event_changed', v_w_sg));
END $function$;

REVOKE ALL ON FUNCTION public.axs_market_fallback_match(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_market_fallback_match(integer) TO service_role;

-- what each upcoming AXS-primary event resolved to: evo, then gotickets, then seatgeek
CREATE OR REPLACE VIEW public.v_axs_event_map
WITH (security_invoker = true) AS
SELECT x.axs_event_id,
       x.event_title, x.headliner, x.venue_name, x.venue_city, x.venue_state,
       x.event_date_local, x.event_date_utc, x.status, x.event_url,
       CASE WHEN x.tevo_event_id IS NOT NULL THEN 'evo' ELSE m.market END AS mapped_to,
       x.tevo_event_id,
       CASE WHEN x.tevo_event_id IS NULL AND m.market = 'gotickets' THEN m.market_event_id END AS gt_event_id,
       CASE WHEN x.tevo_event_id IS NULL AND m.market = 'seatgeek'  THEN m.market_event_id END AS sg_event_id,
       CASE WHEN x.tevo_event_id IS NOT NULL THEN x.match_method ELSE m.method END AS method,
       CASE WHEN x.tevo_event_id IS NULL THEN m.market_event_name END AS market_event_name,
       CASE WHEN x.tevo_event_id IS NULL THEN m.market_venue_name END AS market_venue_name,
       CASE WHEN x.tevo_event_id IS NULL THEN m.venue_sim END AS venue_sim,
       CASE WHEN x.tevo_event_id IS NULL THEN m.title_sim END AS title_sim,
       CASE WHEN x.tevo_event_id IS NULL THEN m.time_diff_min END AS time_diff_min,
       coalesce(x.matched_at, m.matched_at) AS mapped_at
  FROM public.axs_export_event x
  LEFT JOIN public.axs_event_market_map m ON m.axs_event_id = x.axs_event_id AND m.withdrawn_at IS NULL
 WHERE x.type = 'axs_primary' AND x.gone_at IS NULL AND x.venue_country = 'US' AND x.event_date_utc >= now();

REVOKE ALL ON public.v_axs_event_map FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_event_map TO service_role;

-- THE HOURLY JOB, not created by this migration (a schedule change needs the operator's say-so):
--   INSERT INTO public.cron_policy (jobname, enabled, notes)
--   VALUES ('axs_market_fallback_hourly', true, 'AXS-primary events with no EVO match -> GoTickets, else SeatGeek (20261117010000)')
--   ON CONFLICT (jobname) DO NOTHING;
--   SELECT cron.schedule('axs_market_fallback_hourly', '44 * * * *', $cron$
--     DO $body$ BEGIN
--       IF NOT public.cron_should_fire('axs_market_fallback_hourly') THEN RETURN; END IF;
--       PERFORM public.axs_market_fallback_match();
--     END $body$;$cron$);

NOTIFY pgrst, 'reload schema';
