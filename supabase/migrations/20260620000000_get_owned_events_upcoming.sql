-- 20260620000000_get_owned_events_upcoming.sql
--
-- New read RPC: get_owned_events_upcoming(p_days) — powers the terminal-home
-- "S4K-OWNED EVENTS — NEXT 30 DAYS" panel.
--
-- WHY: the panel was deriving its rows from the movers index (get_event_movers_v2,
-- via home.js state.rows). That index only carries events that QUALIFY AS MOVERS
-- (price/fill/owned/value signals) for the currently-selected source × window. Net
-- effect verified on prod 2026-06-20: 419 owned events occur in the next 30 days,
-- but at most 19 of them are present in the merged movers index — so the panel was
-- silently hiding ~95% of the broker's owned upcoming inventory, and its contents
-- shifted whenever the operator changed the (unrelated) movers source/window toggle.
--
-- This RPC reads owned inventory directly from latest_event_metrics (the freshest
-- per-event metrics matview, owned_tickets_count > 0) joined to events for the
-- date/venue, independent of the movers index. It LEFT JOINs the merged movers
-- index so the panel can still show a mover category + price delta when the owned
-- event also happens to be a mover (else those columns are NULL → "—" in the UI).
--
-- latest_event_metrics is NOT directly grant-readable by the terminal client
-- (authenticated has no SELECT; RLS off but ungranted), so a SECURITY DEFINER RPC
-- is the correct read path — mirroring get_event_movers_v2 (mig 20260527260000).
--
-- Lane: authored by D0 (terminal FE owner of the consuming panel); prod apply is
-- operator-gated and lands via A1 (CLAUDE.md §1 / PROJECT_BIBLE §2.3).

CREATE OR REPLACE FUNCTION public.get_owned_events_upcoming(
  p_days int DEFAULT 30           -- horizon in days from now (panel uses 30)
) RETURNS TABLE (
  event_id            bigint,
  event_name          text,
  venue_name          text,
  occurs_at_local     text,       -- offset-bearing ISO local string (events.occurs_at_local is TEXT)
  days_to_event       int,
  owned_tickets_count int,
  owned_groups_count  int,
  getin_price         numeric,    -- cheapest current listing (market)
  retail_median       numeric,    -- median current listing (market)
  owned_median_retail numeric,    -- median of OUR owned listings
  category            text,       -- merged-mover category, if this event is also a mover (else NULL)
  price_delta_pct     numeric     -- merged-mover price delta, if available (else NULL)
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    m.event_id,
    e.name                                       AS event_name,
    COALESCE(e.venue_name, e.venue_location)     AS venue_name,
    e.occurs_at_local,
    FLOOR(
      EXTRACT(EPOCH FROM ((e.occurs_at_local)::timestamptz - now())) / 86400.0
    )::int                                       AS days_to_event,
    m.owned_tickets_count,
    m.owned_groups_count,
    m.getin_price,
    m.retail_median,
    m.owned_median_retail,
    mi.category,
    mi.price_delta_pct
  FROM public.latest_event_metrics m
  JOIN public.events e
    ON e.id = m.event_id
  LEFT JOIN LATERAL (
    SELECT i.category, i.price_delta_pct
    FROM   public.event_movers_index i
    WHERE  i.source = 'merged'
      AND  i.event_id = m.event_id
    ORDER BY i.signal_score DESC
    LIMIT 1
  ) mi ON true
  WHERE m.owned_tickets_count > 0
    AND e.occurs_at_local IS NOT NULL
    -- day-of stays visible (>= now - 1d); horizon is p_days out
    AND (e.occurs_at_local)::timestamptz >= now() - interval '1 day'
    AND (e.occurs_at_local)::timestamptz <= now() + make_interval(days => GREATEST(p_days, 1))
  ORDER BY (e.occurs_at_local)::timestamptz ASC;
$function$;

-- Same exposure as get_event_movers_v2: terminal (authenticated) + service_role
-- may read; anon/public may not.
REVOKE ALL ON FUNCTION public.get_owned_events_upcoming(int) FROM anon, public;

COMMENT ON FUNCTION public.get_owned_events_upcoming IS
  'Terminal-home S4K-OWNED panel: owned (owned_tickets_count>0) events occurring within p_days, '
  'from latest_event_metrics + events, independent of the movers index. '
  'LEFT JOINs merged event_movers_index for category/price_delta when the owned event is also a mover.';
