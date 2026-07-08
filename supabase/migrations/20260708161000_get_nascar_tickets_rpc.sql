-- ============================================================================
-- Migration 20260708161000 — get_nascar_tickets(): NASCAR schedule↔ticket matcher
--
-- Lane:     A1 data plane (SECDEF read RPC; consumed by the D0 Leagues hub
--           racing view — enriches the ESPN SCHEDULE panel with live tickets).
-- Touches:  get_nascar_tickets (W/function)
-- Reads:    espn_racing_events, events (event_type='nascar'), latest_event_metrics
-- Pre-reqs: 20260708160000 (NASCAR ingest), 20260704140000 (espn_racing_events)
--
-- WHY. Every NASCAR national race hangs off one generic TEvo performer, so a
-- ticketed event can't be identified by performer — only by venue + date. The
-- ESPN schedule (espn_racing_events) is the authoritative calendar (series +
-- date + race name); the ingested `events` rows (event_type='nascar', mig
-- 20260708160000) carry the tickets + real speedway venue. This matcher joins
-- them so the racing view can show get-in / market / owned inline on each ESPN
-- schedule row, deep-linking to the event page.
--
-- Match key = (series, date). ESPN carries the series authoritatively; the TEvo
-- event's series is classified from its name (Cup / Xfinity a.k.a. "O'Reilly
-- Auto Parts" / Craftsman Truck) — the name is unreliable for the *race* (many
-- marquee Cup races drop the series word) but reliable for the *series bucket*.
-- A ±1-day tolerance absorbs night-race UTC/ET date crossings; the LATERAL
-- picks the single closest-dated same-series event, so a shared race weekend
-- can't double-match. Returns only upcoming (not-completed) races that matched
-- a ticketed event; metrics are null until the listings poller first covers a
-- freshly-ingested event (same as every tournament ingest).
--
-- Keyed on espn_event_id so the front-end merges it onto the existing
-- get_espn_racing_events schedule rows without a second schedule query.
--
-- ROLLBACK: DROP FUNCTION get_nascar_tickets(text).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_nascar_tickets(p_series text)
RETURNS TABLE (
  espn_event_id       text,
  event_id            bigint,
  venue_name          text,
  occurs_at_local     text,
  tickets_count       integer,
  getin_price         numeric,
  retail_median       numeric,
  owned_tickets_count integer,
  owned_share         numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH espn AS (
    SELECT ere.espn_event_id, ere.series,
           (ere.event_date AT TIME ZONE 'America/New_York')::date AS d
    FROM public.espn_racing_events ere
    WHERE ere.series = p_series
      AND ere.completed = false
      AND ere.event_date >= now() - interval '1 day'
  )
  SELECT e.espn_event_id,
         m.event_id,
         m.venue_name,
         m.occurs_at_local,
         lem.tickets_count::integer,
         lem.getin_price,
         lem.retail_median,
         lem.owned_tickets_count::integer,
         lem.owned_share
  FROM espn e
  JOIN LATERAL (
    SELECT ev.id AS event_id, ev.venue_name, ev.occurs_at_local
    FROM public.events ev
    WHERE ev.event_type = 'nascar'
      AND (CASE
             WHEN ev.name ILIKE '%Truck%' THEN 'nascar-truck'
             WHEN ev.name ILIKE '%Xfinity%' OR ev.name ILIKE '%Reilly Auto Parts%' THEN 'nascar-xfinity'
             ELSE 'nascar-cup'
           END) = e.series
      AND abs(left(ev.occurs_at_local, 10)::date - e.d) <= 1
    ORDER BY abs(left(ev.occurs_at_local, 10)::date - e.d) ASC
    LIMIT 1
  ) m ON true
  LEFT JOIN public.latest_event_metrics lem ON lem.event_id = m.event_id;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_nascar_tickets(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_nascar_tickets(text) TO anon, authenticated;

COMMENT ON FUNCTION public.get_nascar_tickets(text) IS
  'D0 racing view — matches ESPN NASCAR schedule races (espn_racing_events) to ingested TEvo ticket events (events.event_type=nascar) by (series, date ±1d), returning live get-in/market/owned + tevo event_id for deep-link. Keyed on espn_event_id for front-end merge. Email-gated read-only.';
