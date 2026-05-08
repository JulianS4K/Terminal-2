-- 20260508100000_event_movers_v3_owned_share.sql
-- Code-owned (broker terminal lane).
--
-- v3 of get_event_movers: surface cur_owned_share so the UI can flag events
-- where S4K owns enough of the post-parking ticket supply that the screen
-- median is reflexive — i.e. we're effectively reading our own quote back to
-- ourselves. Caught in the 2026-05-08 Knicks deep-dive:
--
--   R3 G2 NYK home (TBD if necessary) — Knicks at $1,748 / 1,132 tix.
--   709 of those 1,132 are S4K. owned_share = 0.628.
--   Anyone marking inventory to that "market median" is marking against
--   S4K's own ask. The Movers list flagging this event as a winner/loser
--   is intellectually circular for that line.
--
-- Threshold convention for the UI badge:
--   >= 50% → red "WE ARE THE MARKET" — screen median is our quote
--   >= 30% → amber "HEAVY"           — meaningful price-setting power
--   <  30% → no badge
--
-- The threshold is rendered client-side from cur_owned_share so it's tunable
-- without another migration.

DROP FUNCTION IF EXISTS get_event_movers(int);

CREATE OR REPLACE FUNCTION get_event_movers(p_window_hours int DEFAULT 24)
RETURNS TABLE (
  event_id              bigint,
  name                  text,
  primary_performer_id  bigint,
  primary_performer_name text,
  venue_id              bigint,
  venue_name            text,
  occurs_at_local       text,
  latest_at             timestamptz,
  prior_at              timestamptz,
  cur_market_med        numeric,
  prev_market_med       numeric,
  cur_owned_med         numeric,
  prev_owned_med        numeric,
  cur_market_tix        integer,
  prev_market_tix       integer,
  cur_owned_tix         integer,
  prev_owned_tix        integer,
  cur_owned_share       numeric
) LANGUAGE sql STABLE AS $$
  WITH window_rows AS (
    SELECT m.event_id, m.captured_at,
           m.retail_median, m.owned_median_retail,
           GREATEST(coalesce(m.tickets_count,0) - coalesce(m.ancillary_tickets,0), 0) AS tickets_count,
           m.owned_tickets_count, m.owned_share
    FROM event_metrics m
    WHERE m.captured_at > now() - (p_window_hours * 3 || ' hours')::interval
  ),
  latest AS (SELECT DISTINCT ON (event_id) * FROM window_rows ORDER BY event_id, captured_at DESC),
  prior  AS (SELECT DISTINCT ON (event_id) * FROM window_rows
             WHERE captured_at < now() - (p_window_hours || ' hours')::interval
             ORDER BY event_id, captured_at DESC)
  SELECT
    l.event_id::bigint, e.name,
    e.primary_performer_id::bigint, e.primary_performer_name,
    e.venue_id::bigint, e.venue_name,
    e.occurs_at_local::text,
    l.captured_at, p.captured_at,
    l.retail_median, p.retail_median,
    l.owned_median_retail, p.owned_median_retail,
    l.tickets_count, p.tickets_count,
    l.owned_tickets_count, p.owned_tickets_count,
    l.owned_share
  FROM latest l
  JOIN events e ON e.id = l.event_id
  LEFT JOIN prior p USING (event_id)
  WHERE e.occurs_at_local::timestamptz >= now()
    AND l.captured_at > now() - interval '72 hours'
  ORDER BY l.captured_at DESC;
$$;

GRANT EXECUTE ON FUNCTION get_event_movers(int) TO anon, authenticated, service_role;
COMMENT ON FUNCTION get_event_movers IS
  'v3: + cur_owned_share so the UI can flag we-are-the-market events (owned_share >= 30% = screen quote is reflexive).';
