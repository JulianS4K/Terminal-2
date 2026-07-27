-- Migration 20260606170000 · lane:D0 (author) → A1 (apply) · writes:event_watchlist_list · reads:event_watchlist,events,event_metrics · pre:20260603190000 · auth:operator-requested 2026-06-06
--
-- D0 — enrich the home "MY WATCHLIST — TRACKED EVENTS" table with at-a-glance
-- metrics + a change figure per tracked event. Backward-compatible: the payload
-- shape (user_email/count/items) is unchanged; each item gains a `metrics` object
-- (NULL when the event has no event_metrics row yet, e.g. far-future / TEvo-only).
--
-- Metrics are TEvo (public.event_metrics — our canonical, frequently-captured
-- per-event source): get-in, retail median, retail p90, tickets count.
--
-- Change basis ("opening bell" = start of the first peak period, ET 12:00 per
-- collector_cadence / collector_band peak hours 12-23):
--   • if now() is at/after today's 12:00 ET bell → compare vs the snapshot as of
--     the bell (intraday "since open"), basis='bell'
--   • otherwise (pre-bell / overnight) → compare vs ~24h ago, basis='24h'
-- The baseline row is the latest event_metrics capture at/before the baseline
-- instant (the value "as of" that moment); NULL delta if none exists that far back.

CREATE OR REPLACE FUNCTION public.event_watchlist_list()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email    text        := public._wl_require_email();
  v_bell     timestamptz := (date_trunc('day', now() AT TIME ZONE 'America/New_York')
                              + interval '12 hours') AT TIME ZONE 'America/New_York';
  v_basis    text;
  v_baseline timestamptz;
  v_rows     jsonb;
BEGIN
  IF now() >= v_bell THEN
    v_baseline := v_bell;                 v_basis := 'bell';
  ELSE
    v_baseline := now() - interval '24 hours'; v_basis := '24h';
  END IF;

  WITH wl AS (
    SELECT w.tevo_event_id AS eid, w.alert_enabled, w.added_at,
           w.event_name AS snap_name, w.occurs_at_local AS snap_occ, w.venue_name AS snap_venue
    FROM public.event_watchlist w
    WHERE w.user_email = v_email
  ),
  cur AS (
    SELECT DISTINCT ON (m.event_id)
      m.event_id, m.captured_at, m.getin_price, m.retail_median, m.retail_p90, m.tickets_count
    FROM public.event_metrics m JOIN wl ON wl.eid = m.event_id
    ORDER BY m.event_id, m.captured_at DESC
  ),
  base AS (
    SELECT DISTINCT ON (m.event_id)
      m.event_id, m.captured_at AS base_at, m.getin_price AS base_getin, m.retail_median AS base_median
    FROM public.event_metrics m JOIN wl ON wl.eid = m.event_id
    WHERE m.captured_at <= v_baseline
    ORDER BY m.event_id, m.captured_at DESC
  )
  SELECT coalesce(
           jsonb_agg(r ORDER BY (r->>'occurs_at_local') ASC NULLS LAST, (r->>'added_at') DESC),
           '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'tevo_event_id',   wl.eid,
      'event_name',      coalesce(e.name, wl.snap_name),
      'occurs_at_local', coalesce(e.occurs_at_local, wl.snap_occ),
      'venue_name',      coalesce(e.venue_name, wl.snap_venue),
      'venue_location',  e.venue_location,
      'performer',       e.primary_performer_name,
      'alert_enabled',   wl.alert_enabled,
      'added_at',        wl.added_at,
      'metrics', CASE WHEN c.event_id IS NULL THEN NULL ELSE jsonb_build_object(
        'getin',        round(c.getin_price),
        'median',       round(c.retail_median),
        'p90',          round(c.retail_p90),
        'tickets',      c.tickets_count,
        'd_getin',      CASE WHEN b.base_getin IS NOT NULL THEN round(c.getin_price - b.base_getin) END,
        'd_getin_pct',  CASE WHEN b.base_getin IS NOT NULL AND b.base_getin <> 0
                             THEN round((c.getin_price - b.base_getin) / b.base_getin * 100, 1) END,
        'd_median',     CASE WHEN b.base_median IS NOT NULL THEN round(c.retail_median - b.base_median) END,
        'd_median_pct', CASE WHEN b.base_median IS NOT NULL AND b.base_median <> 0
                             THEN round((c.retail_median - b.base_median) / b.base_median * 100, 1) END,
        'basis',        v_basis,
        'cur_at',       c.captured_at,
        'base_at',      b.base_at
      ) END
    ) AS r
    FROM wl
    LEFT JOIN public.events e        ON e.id = wl.eid
    LEFT JOIN cur c                  ON c.event_id = wl.eid
    LEFT JOIN base b                 ON b.event_id = wl.eid
  ) q;

  RETURN jsonb_build_object(
    'user_email',  v_email,
    'count',       jsonb_array_length(v_rows),
    'basis',       v_basis,
    'baseline_at', v_baseline,
    'items',       v_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION public.event_watchlist_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.event_watchlist_list() TO authenticated;
