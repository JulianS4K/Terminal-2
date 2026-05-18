-- Migration 20260518000000 · lane:D0 (author) → A1 (apply) · writes:get_event_movers_with_sg · reads:get_event_movers,seatgeek_sales_snapshots,seatgeek_event_xref · pre:20260508040000 · auth:operator-approved 2026-05-17
--
-- D0 — wraps existing get_event_movers (mig 20260508040000) and adds a
-- per-event SG sales count over the same window. Powers two new surfaces:
--   1. New `SG 24h sales` column on the movers table (home + movers.html)
--   2. New `BLIND SPOTS — SG SELLING, WE'RE NOT` panel (sg_sales > N AND
--      cur_owned_tix = 0) — surfaces inventory gaps where SG demand is
--      live but our office holds zero.
--
-- Per A1 pre-flight audit (bot_chat #299):
--   - DISTINCT ON (sg_sale_id) is MANDATORY — seatgeek_sales_snapshots
--     has 11x pull dedup (PROJECT_BIBLE §3). Without it, sales_24h would
--     overcount by 11x.
--   - Scope SG join on sg_event_id (uses idx_sg_sales_sg_event_id_time
--     from PR #150 hotfix) for sub-100ms latency.
--   - Bridge tevo_event_id ↔ sg_event_id via seatgeek_event_xref.
--
-- Plain SQL function (no SECDEF / no email gate) — matches the existing
-- get_event_movers pattern. /api/broker/movers FastAPI endpoint already
-- has require_auth wrapping the row-level access; consistent with the
-- companion RPC's auth model. If/when the FE migrates this surface to
-- Path C (direct supabase.rpc), a SECDEF wrapper can be added then.

CREATE OR REPLACE FUNCTION public.get_event_movers_with_sg(p_window_hours int DEFAULT 24)
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
  sg_sales_window       integer
)
LANGUAGE sql STABLE
SET search_path = public, extensions, pg_temp
AS $$
  WITH sg_window AS (
    -- DISTINCT ON sg_sale_id collapses 11x firehose dedup before counting.
    -- Scope by sg_event_id (idx_sg_sales_sg_event_id_time) then bridge to
    -- tevo_event_id via xref. p_window_hours controls the look-back so the
    -- "SG 24h sales" column tracks the same window as the mover deltas.
    SELECT
      x.tevo_event_id,
      COUNT(*)::integer AS sg_sales_window
    FROM (
      SELECT DISTINCT ON (s.sg_sale_id)
        s.sg_sale_id, s.sg_event_id, s.sale_at_utc
      FROM public.seatgeek_sales_snapshots s
      WHERE s.sale_at_utc > now() - (p_window_hours || ' hours')::interval
      ORDER BY s.sg_sale_id, s.pulled_at DESC
    ) deduped
    JOIN public.seatgeek_event_xref x ON x.sg_event_id = deduped.sg_event_id
    GROUP BY x.tevo_event_id
  )
  SELECT
    m.event_id,
    m.name,
    m.primary_performer_id,
    m.primary_performer_name,
    m.venue_id,
    m.venue_name,
    m.occurs_at_local,
    m.latest_at,
    m.prior_at,
    m.cur_market_med,
    m.prev_market_med,
    m.cur_owned_med,
    m.prev_owned_med,
    m.cur_market_tix,
    m.prev_market_tix,
    m.cur_owned_tix,
    m.prev_owned_tix,
    COALESCE(sg.sg_sales_window, 0)::integer AS sg_sales_window
  FROM public.get_event_movers(p_window_hours) m
  LEFT JOIN sg_window sg ON sg.tevo_event_id = m.event_id;
$$;

GRANT EXECUTE ON FUNCTION public.get_event_movers_with_sg(int) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_event_movers_with_sg(int) IS
  'Wraps get_event_movers; adds per-event SG sales count over the same window. DISTINCT ON (sg_sale_id) for 11x firehose dedup. Powers movers SG column + Blind Spots panel.';
