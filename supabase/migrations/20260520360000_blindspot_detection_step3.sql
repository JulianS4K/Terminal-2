-- Migration 20260520360000 · lane:A1 · writes:v_sg_blindspot_movers,get_blind_spots_sg_selling · pre:20260520330000
--
-- STEP 3 of 5 — Blindspot detection view + RPC ("BLIND SPOTS — SG SELLING, WE'RE NOT")
--
-- Operator design (2026-05-18):
--   Trigger: BOTH listings move ≥5% AND price move ≥10% over a 48h rolling window.
--   Window: compare the latest poll snapshot (T-0, last 12h) vs the closest
--           poll snapshot at T-48h (window 42-54h ago).
--   Direction signal: selling_pressure = listings shrinking AND price rising
--     (textbook SG-selling-into-strength pattern).
--
-- BASELINE WARNING
--   Returns 0 rows until ≥48h of TRACK_BLINDSPOT polling history exists.
--   Step 2 polling started 2026-05-18; first useful results ~2026-05-20.
--
-- DESIGN
--   1. View v_sg_blindspot_movers — threshold-free. Returns ALL TRACK_BLINDSPOT
--      events that have BOTH anchor snapshots (T-0 and T-48h) available, with
--      computed deltas. Threshold filtering happens in the RPC.
--   2. RPC get_blind_spots_sg_selling(p_min_listings_delta, p_min_price_delta)
--      — SECDEF + @s4kent.com gate. Filters the view, joins to canonical for
--      display fields, returns JSON array sorted by selling_pressure DESC then
--      abs(price_pct_delta) DESC.
--
-- ANCHOR SELECTION
--   T-0:   max(captured_at) within last 12h. Catches the most recent
--          blindspot poll (cron fires at UTC 04-10 + 16-22, every 5 min).
--   T-48h: max(captured_at) within 42-54h ago. ±6h tolerance accommodates
--          the 12h-per-event eligibility gate (events polled at slightly
--          different timestamps each day).
--
-- DEDUP NOTE
--   We don't need DISTINCT ON (sg_event_id, sglid) per snapshot — a single
--   blindspot poll writes all sglid rows at one clock_timestamp(). Picking
--   `captured_at = anchor` returns exactly one row per sglid per snapshot.
--
-- INDEX SUPPORT
--   idx_sg_listings_sg_event_id_time (sg_event_id, captured_at DESC) — used
--   by both anchor CTEs.

-- ============================================================
-- 1. View
-- ============================================================
CREATE OR REPLACE VIEW public.v_sg_blindspot_movers
WITH (security_invoker = on) AS
WITH t0_anchor AS (
  SELECT s.sg_event_id, max(l.captured_at) AS captured_at
  FROM public.sg_event_priority_state s
  JOIN public.seatgeek_listings_snapshots l ON l.sg_event_id = s.sg_event_id
  WHERE s.tier = 'TRACK_BLINDSPOT'
    AND l.captured_at > now() - interval '12 hours'
  GROUP BY s.sg_event_id
),
t48_anchor AS (
  SELECT s.sg_event_id, max(l.captured_at) AS captured_at
  FROM public.sg_event_priority_state s
  JOIN public.seatgeek_listings_snapshots l ON l.sg_event_id = s.sg_event_id
  WHERE s.tier = 'TRACK_BLINDSPOT'
    AND l.captured_at BETWEEN now() - interval '54 hours' AND now() - interval '42 hours'
  GROUP BY s.sg_event_id
),
now_agg AS (
  SELECT l.sg_event_id,
         count(DISTINCT l.sglid)                                                AS listings_now,
         coalesce(sum(l.quantity), 0)                                            AS tickets_now,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY l.broadcast_price)::numeric AS median_now
  FROM public.seatgeek_listings_snapshots l
  JOIN t0_anchor a ON a.sg_event_id = l.sg_event_id AND a.captured_at = l.captured_at
  WHERE l.broadcast_price IS NOT NULL
  GROUP BY l.sg_event_id
),
prior_agg AS (
  SELECT l.sg_event_id,
         count(DISTINCT l.sglid)                                                AS listings_prior,
         coalesce(sum(l.quantity), 0)                                            AS tickets_prior,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY l.broadcast_price)::numeric AS median_prior
  FROM public.seatgeek_listings_snapshots l
  JOIN t48_anchor a ON a.sg_event_id = l.sg_event_id AND a.captured_at = l.captured_at
  WHERE l.broadcast_price IS NOT NULL
  GROUP BY l.sg_event_id
)
SELECT
  n.sg_event_id,
  n.listings_now,         p.listings_prior,
  n.tickets_now,          p.tickets_prior,
  n.median_now,           p.median_prior,
  CASE WHEN p.listings_prior > 0
       THEN round(100.0 * (n.listings_now - p.listings_prior) / p.listings_prior::numeric, 2)
       END AS listings_pct_delta,
  CASE WHEN p.median_prior > 0
       THEN round(100.0 * (n.median_now - p.median_prior) / p.median_prior, 2)
       END AS price_pct_delta,
  (n.listings_now < p.listings_prior AND n.median_now > p.median_prior) AS selling_pressure
FROM now_agg n
JOIN prior_agg p USING (sg_event_id)
WHERE p.listings_prior > 0 AND p.median_prior > 0;

REVOKE ALL ON public.v_sg_blindspot_movers FROM PUBLIC;
GRANT SELECT ON public.v_sg_blindspot_movers TO anon, authenticated, service_role;


-- ============================================================
-- 2. RPC
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_blind_spots_sg_selling(
  p_min_listings_delta numeric DEFAULT 5,
  p_min_price_delta    numeric DEFAULT 10
)
RETURNS jsonb
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

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'sg_event_id',         m.sg_event_id,
             'tevo_event_id',       c.tevo_event_id,
             'sg_event_name',       c.sg_event_name,
             'sg_venue_name',       c.sg_venue_name,
             'sg_venue_city',       c.sg_venue_city,
             'sg_venue_state',      c.sg_venue_state,
             'sg_datetime_utc',     to_char(c.sg_datetime_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             'listings_now',        m.listings_now,
             'listings_prior',      m.listings_prior,
             'tickets_now',         m.tickets_now,
             'tickets_prior',       m.tickets_prior,
             'listings_pct_delta',  m.listings_pct_delta,
             'median_now',          round(m.median_now, 2),
             'median_prior',        round(m.median_prior, 2),
             'price_pct_delta',     m.price_pct_delta,
             'selling_pressure',    m.selling_pressure
           ) ORDER BY m.selling_pressure DESC, abs(m.price_pct_delta) DESC, abs(m.listings_pct_delta) DESC)
    FROM public.v_sg_blindspot_movers m
    JOIN public.sg_events_canonical c ON c.sg_event_id = m.sg_event_id
    WHERE abs(m.listings_pct_delta) >= p_min_listings_delta
      AND abs(m.price_pct_delta)    >= p_min_price_delta
      AND c.sg_datetime_utc > now()
  ), '[]'::jsonb);
END
$func$;

REVOKE ALL    ON FUNCTION public.get_blind_spots_sg_selling(numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_blind_spots_sg_selling(numeric, numeric) TO anon, authenticated;

COMMENT ON FUNCTION public.get_blind_spots_sg_selling(numeric, numeric) IS
  'BLIND SPOTS — SG SELLING, WE''RE NOT. Returns TRACK_BLINDSPOT events where listings count moved >= p_min_listings_delta% AND median price moved >= p_min_price_delta% over a 48h window (T-0 vs T-48h ±6h). Defaults: 5% listings + 10% price (operator AND-trigger 2026-05-18). Sorts selling_pressure DESC (listings shrinking + price rising) first, then by impact. Email-gated.';

-- ============================================================
-- Post-apply verification
-- ============================================================
-- 1) View resolves (returns 0 rows today, only ~4 events polled so far,
--    no 48h history yet):
--    SELECT count(*) FROM public.v_sg_blindspot_movers;
--    -- expect: 0 today; will start surfacing rows ~2026-05-20 21:14 UTC
--    -- (48h after first blindspot poll on 2026-05-18 21:14)
--
-- 2) RPC callable (returns '[]' without auth — fails email gate):
--    SELECT public.get_blind_spots_sg_selling();  -- expects exception
--
-- 3) RPC callable as faked authed user:
--    SELECT set_config('request.jwt.claims', '{"email":"test@s4kent.com"}', true);
--    SELECT public.get_blind_spots_sg_selling();
--    -- expect: '[]' today (no 48h history)
--
-- 4) After 48h+ of blindspot polling, lower thresholds to see all events
--    with both anchors:
--    SELECT public.get_blind_spots_sg_selling(0, 0);
