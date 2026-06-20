-- Migration 20260620154000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — read-only comps RPC)
-- Touches W: CREATE FUNCTION public.get_event_comps(bigint)
-- Touches R: public.events, public.performer_baselines, public.venue_baselines,
--            public.latest_event_metrics
-- Pre-reqs: performer_baselines/venue_baselines, latest_event_metrics matview
-- Already applied to prod · via MCP 2026-06-20
--
-- ============================================================
-- COMPS ENGINE  —  "what did comparable events do?"
--
-- Given a tevo_event_id, return the broker's #1 discovery question answered:
--   * the target event's row
--   * the performer's baseline (median retail/getin/tickets, owned premium) + venue baseline
--   * sibling events: same performer (tour comps) and/or same venue, with their LATEST
--     market metrics (getin, retail median, tickets, owned share), date-ordered.
--
-- Reuses existing baselines (performer_baselines/venue_baselines) + latest_event_metrics;
-- no new ingest. SECURITY INVOKER (SQL fn default) — respects caller RLS. Returns jsonb so
-- the terminal gets one packaged payload. Comps capped at 40, ordered same-performer first.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_event_comps(p_tevo_event_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
WITH tgt AS (
  SELECT id, name, venue_id, venue_name, primary_performer_id, primary_performer_name,
         event_type, occurs_at_local
  FROM public.events
  WHERE id = p_tevo_event_id
),
comps AS (
  SELECT
    e.id              AS comp_event_id,
    e.name,
    e.venue_name,
    e.occurs_at_local,
    (e.primary_performer_id = t.primary_performer_id) AS same_performer,
    (e.venue_id = t.venue_id)                          AS same_venue,
    m.getin_price,
    m.retail_median,
    m.tickets_count,
    m.owned_share
  FROM public.events e
  JOIN tgt t ON TRUE
  LEFT JOIN public.latest_event_metrics m ON m.event_id = e.id
  WHERE e.id <> t.id
    AND (
      e.primary_performer_id = t.primary_performer_id
      OR (t.venue_id IS NOT NULL AND e.venue_id = t.venue_id)
    )
  ORDER BY (e.primary_performer_id = t.primary_performer_id) DESC, e.occurs_at_local
  LIMIT 40
)
SELECT jsonb_build_object(
  'target', (SELECT to_jsonb(t) FROM tgt t),
  'performer_baseline', (
    SELECT to_jsonb(pb) FROM public.performer_baselines pb
    WHERE pb.performer_id = (SELECT primary_performer_id FROM tgt)
  ),
  'venue_baseline', (
    SELECT to_jsonb(vb) FROM public.venue_baselines vb
    WHERE vb.venue_id = (SELECT venue_id FROM tgt)
  ),
  'comps', coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM comps c), '[]'::jsonb)
)
WHERE EXISTS (SELECT 1 FROM tgt);
$$;

COMMENT ON FUNCTION public.get_event_comps(bigint) IS
  'Comps for a tevo_event_id: target + performer/venue baselines + same-performer (tour) '
  'and same-venue sibling events with latest metrics. A1 · mig 20260620154000.';

REVOKE ALL ON FUNCTION public.get_event_comps(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_comps(bigint) TO authenticated, service_role;
