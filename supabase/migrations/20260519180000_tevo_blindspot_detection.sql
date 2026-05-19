-- Migration 20260519180000 · lane:A1 · writes:v_tevo_blindspot_movers,get_blind_spots_tevo_selling · pre:20260520370000
--
-- TEvo blindspot detection — companion to SG blindspot system (mig 20260520370000).
--
-- DIFFERENCE FROM SG VERSION (operator design 2026-05-19):
--   * No tier table. SG's TRACK_BLINDSPOT exists because each SG poll burns
--     one of the 10/sec quota, so we tier-classify what's worth polling.
--     TEvo's /v9/events search is broker-side, higher-quota, and supports
--     filtered discovery on demand. Events worth investigating can be pulled
--     ad-hoc via the existing `sg_to_tevo_search_bridge` pattern.
--   * No sales signals. TEvo doesn't expose broker-side sales data — we only
--     see listing-side movement (broker-pool tickets disappearing) +
--     get-in price firming. Composite score drops from 4 signals (SG)
--     to 2 signals (TEvo).
--
-- CANDIDATE GATES (operator-confirmed 2026-05-19):
--   * owned_tickets_count = 0           — the blindspot
--   * tickets_count       >= 25          — real broker market depth
--   * occurs_at in [today+31d, today+365d] — drop game-time noise + open
--     the upper bound to 1 year (was 90d in v1; widened per operator
--     2026-05-19 — longer-horizon inventory is sourcing-actionable too)
--   * US or Canada venue                 — state/province regex match on
--     `events.venue_location` (e.g. "Boston, MA" / "Toronto, ON")
--   * NOT big 5 sports                   — exclude MLB / NBA / NFL / NHL /
--     MLS via `event_xref.espn_league`. Big 5 events are already heavily
--     tracked + dominate the broker pool; the detector adds value on
--     niche sports + concerts + theater where coverage is thinner.
--     Unmapped events (espn_league IS NULL) stay in the pool — they're
--     the actual discovery candidates.
--   * get-in-without-parking >= $50      — recomputed from
--     `listings_snapshots.retail_price` excluding sections matching
--     `%park%|%lot%|%garage%|%valet%`. TEvo bible §3 landmine: parking
--     rows fold into the main listing pool, dragging native `getin_now`
--     down artificially.
--   * event_lifecycle.is_active          — drops ghost/cancelled/postponed
--   * speculative-name filter             — CANCELLED / If Necessary /
--                                            Date TBD
--
-- COMPOSITE 3-SIGNAL DETECTION (mutually-exclusive directions):
--   signal_listings_drop   tevo_tix_d24h <= -10 AND tevo_tix_d24h_pct <= -5%
--                          PAIRED condition (v1.5 fix per algorithm review):
--                          absolute floor filters noise on tiny pools where
--                          a 10-tix drop is 33% (huge); pct floor filters
--                          noise on big pools where 10-tix is 2% churn.
--                          Both must fire.
--   signal_listings_spike  tevo_tix_d24h_pct >= +10%   (pool loading)
--   signal_price_rise      tevo_getin_d24h_pct >= +5%
--
-- DROP + SPIKE are mutually exclusive on the same event (one direction at
-- a time), so they share the listings-side score slot but tell different
-- stories:
--   * drop  = pool draining → "broker selling, we should source"
--   * spike = pool loading  → "broker preparing for demand, watch closely"
--   * rise  = price firming → "demand exceeding supply, regardless of vol"
--
-- SCORES + CONFIDENCE (v1.5 — algorithm review feedback):
--   selling_score    = listings_drop::int + price_rise::int           (0..2)
--   tracking_score   = (listings_drop OR listings_spike)::int + price_rise::int (0..2)
--   confidence_score = avg of per-signal strengths that fire           (0..1)
--                      Per-signal strength is how far past threshold each
--                      signal is, capped at 1.0. RPC sorts by this rather
--                      than by integer score — distinguishes a barely-firing
--                      from a strongly-firing both-signals event.
--
-- DAYS-TO-EVENT BAND (v1.5):
--   imminent_31_60  31-60d out  — sourcing window tightest; act fast
--   near_61_180     61-180d out — mid-cycle decision
--   far_181_365     181-365d out — research / monitor
--   Surfaces on every row; RPC supports filtering.
--
-- VELOCITY FRESHNESS — 24h gate (NOT 3h):
--   Blindspot events are owned=0 → not in the hot polling tier. The
--   collect-listings-1-7d / 7-30d / 30-60d / 60d+ crons hit them only
--   TWICE DAILY (per mig 20260519240000). A 3h freshness gate would
--   exclude virtually all blindspot events. 24h matches the collection
--   cadence + our new tevo_blindspot_metrics_refresh_12h cron.
--
-- KNOWN GAPS (deferred to v2):
--   * No per-performer rolling baseline. A 10-tix drop on the Yankees is
--     normal Tuesday; same drop on Cleveland Symphony is huge news. v2
--     adds a `performer_baselines` matview with rolling mean ± stdev so
--     signals fire on z-score deviation from the performer's own pattern.
--   * No day-of-week or days-to-event seasonality awareness. The bands
--     above are coarse triage, not statistical decomposition.
--   * No outcome tracking. Detector doesn't learn from human sourcing
--     decisions. Future: event_sourcing_decisions table feeding threshold
--     auto-tuning after 90d of data.

-- ============================================================
-- 1. View — per-event composite score
-- ============================================================
DROP VIEW IF EXISTS public.v_tevo_blindspot_movers;

CREATE VIEW public.v_tevo_blindspot_movers
WITH (security_invoker = on) AS
WITH base AS (
  SELECT
    e.id                       AS tevo_event_id,
    e.name                     AS event_name,
    e.occurs_at_local,
    e.venue_id,
    e.venue_name,
    e.venue_location,
    e.primary_performer_id,
    e.primary_performer_name,
    lem.owned_tickets_count,
    lem.tickets_count,
    lem.retail_min,
    lem.retail_median,
    lem.captured_at            AS metrics_captured_at,
    -- Get-in without parking — recomputed from raw listings_snapshots
    -- so the parking-section drag (bible §3 landmine) is excluded.
    -- Correlated subquery on PRIMARY KEY (event_id) — fast.
    (SELECT min(ls.retail_price)
       FROM public.listings_snapshots ls
      WHERE ls.event_id = e.id
        AND ls.retail_price IS NOT NULL
        AND NOT (
          ls.section ILIKE '%park%' OR ls.section ILIKE '%lot%'
          OR ls.section ILIKE '%garage%' OR ls.section ILIKE '%valet%'
        )
    )                          AS getin_no_parking
  FROM public.events e
  JOIN public.latest_event_metrics lem ON lem.event_id = e.id
  LEFT JOIN public.event_lifecycle el  ON el.event_id = e.id
  -- Two parallel league-mapping sources joined for big-5 exclusion. Both
  -- are LEFT JOINs so unmapped events stay in the pool — they're the
  -- actual discovery candidates. Coverage on the current 132-event pool:
  --   performer_metadata.espn_league via primary_performer_id   126/132
  --   event_xref.espn_league via tevo_event_id                   96/132
  -- Union catches ~all big-5 events; remaining holes are speculative
  -- "TBD" / "If Necessary" rows already filtered by the name rules below.
  LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
  LEFT JOIN public.event_xref ex         ON ex.tevo_event_id  = e.id
  WHERE
    -- Forward window: 31..365 days out (drop game-time, allow long horizon)
    e.occurs_at_local::date >= CURRENT_DATE + interval '31 days'
    AND e.occurs_at_local::date <= CURRENT_DATE + interval '365 days'
    -- Blindspot: we own nothing
    AND lem.owned_tickets_count = 0
    -- Real market depth
    AND lem.tickets_count >= 25
    -- Active lifecycle
    AND (el.is_active IS NULL OR el.is_active = true)
    -- Big 5 sports already heavily tracked → hard exclude. Either source
    -- saying big-5 is sufficient grounds for exclusion. Concerts, niche
    -- sports, theater, and other discovery candidates stay (both fields
    -- NULL or other-league). Espn league codes are upper-case per
    -- matcher v3 convention.
    AND NOT (
      coalesce(pm.espn_league, '') IN ('MLB','NBA','NFL','NHL','MLS')
      OR coalesce(ex.espn_league, '') IN ('MLB','NBA','NFL','NHL','MLS')
    )
    -- Speculative-name filter (mirrors storefront)
    AND e.name NOT ILIKE '%CANCELLED%'
    AND e.name NOT ILIKE '%(If Necessary)%'
    AND e.name NOT ILIKE '%(Date TBD)%'
    -- US or Canada only (state/province at end of venue_location string)
    AND (
      e.venue_location ~ ',\s*(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\s*$'
      OR e.venue_location ~ ',\s*(AB|BC|MB|NB|NL|NS|ON|PE|QC|SK|YT|NT|NU)\s*$'
    )
),
gated AS (
  -- Apply the parking-aware get-in floor in a second pass so the IS NOT NULL
  -- + threshold gate sit together (clearer than a CASE in the base WHERE).
  SELECT * FROM base
  WHERE getin_no_parking IS NOT NULL
    AND getin_no_parking >= 50
),
velocity AS (
  SELECT
    tevo_event_id,
    tevo_tix_now,
    tevo_tix_d24h,
    -- Listings pct delta — derived since v_event_velocity_windows doesn't
    -- expose it directly. Guarded against div-by-zero (events where 24h
    -- ago count was 0 are ignored — their tix_now alone is the signal).
    CASE WHEN (tevo_tix_now - coalesce(tevo_tix_d24h, 0)) > 0
         THEN round(tevo_tix_d24h * 100.0 / (tevo_tix_now - tevo_tix_d24h), 2)
         ELSE NULL
    END                                                                  AS tevo_tix_d24h_pct,
    tevo_getin_d24h_pct,
    tevo_getin_now,
    tevo_median_now,
    tevo_now_at,
    -- 24h freshness gate (NOT 3h) — blindspot events sit on the 1-7d /
    -- 7-30d / 30-60d / 60d+ collect-listings tracks which fire twice
    -- daily (mig 20260519240000). The 12h refresh cron we ship in
    -- mig 20260519190000 keeps latest_event_metrics fresh between cycles.
    (tevo_now_at IS NOT NULL AND tevo_now_at > now() - interval '24 hours') AS velocity_fresh
  FROM public.v_event_velocity_windows
),
scored AS (
  SELECT
    g.*,
    v.tevo_tix_d24h,
    v.tevo_tix_d24h_pct,
    v.tevo_getin_d24h_pct,
    v.tevo_getin_now,
    v.tevo_median_now,
    v.tevo_now_at,
    v.velocity_fresh,
    -- Signal 1: pool draining (broker selling) — PAIRED condition
    (v.velocity_fresh
     AND v.tevo_tix_d24h     IS NOT NULL AND v.tevo_tix_d24h     <= -10
     AND v.tevo_tix_d24h_pct IS NOT NULL AND v.tevo_tix_d24h_pct <= -5.0) AS signal_listings_drop,
    -- Signal 2: pool loading (broker prepping inventory for demand)
    (v.velocity_fresh AND v.tevo_tix_d24h_pct IS NOT NULL
     AND v.tevo_tix_d24h_pct >= 10.0)                                     AS signal_listings_spike,
    -- Signal 3: price firming
    (v.velocity_fresh AND v.tevo_getin_d24h_pct IS NOT NULL
     AND v.tevo_getin_d24h_pct >= 5.0)                                    AS signal_price_rise,
    -- Per-signal strengths (0..1, capped) — used to derive confidence_score.
    -- Strength = how far past threshold the metric is, normalized to a
    -- "fully developed" point that's roughly 2× the trigger threshold.
    -- A barely-firing signal scores ~0.5; a strongly-firing signal scores 1.0.
    LEAST(1.0, GREATEST(0.0,
      COALESCE(-v.tevo_tix_d24h_pct / 10.0, 0)))                          AS drop_strength,
    LEAST(1.0, GREATEST(0.0,
      COALESCE( v.tevo_tix_d24h_pct / 20.0, 0)))                          AS spike_strength,
    LEAST(1.0, GREATEST(0.0,
      COALESCE( v.tevo_getin_d24h_pct / 10.0, 0)))                        AS price_strength,
    -- Days-to-event cohort (operator triage aid)
    (occurs_at_local::date - CURRENT_DATE)                                AS days_to_event,
    CASE
      WHEN (occurs_at_local::date - CURRENT_DATE) <= 60   THEN 'imminent_31_60'
      WHEN (occurs_at_local::date - CURRENT_DATE) <= 180  THEN 'near_61_180'
      ELSE                                                     'far_181_365'
    END                                                                   AS days_to_event_band
  FROM gated g
  LEFT JOIN velocity v ON v.tevo_event_id = g.tevo_event_id
)
SELECT
  tevo_event_id, event_name, occurs_at_local, venue_id, venue_name,
  venue_location, primary_performer_id, primary_performer_name,
  owned_tickets_count, tickets_count, retail_min, retail_median,
  metrics_captured_at, getin_no_parking, tevo_tix_d24h, tevo_tix_d24h_pct,
  tevo_getin_d24h_pct, tevo_getin_now, tevo_median_now, tevo_now_at,
  velocity_fresh, signal_listings_drop, signal_listings_spike,
  signal_price_rise, days_to_event, days_to_event_band,
  -- Score outputs
  (signal_listings_drop::int + signal_price_rise::int)                                  AS selling_score,
  ((signal_listings_drop OR signal_listings_spike)::int + signal_price_rise::int)        AS tracking_score,
  -- Confidence: average of fired signals' strengths. 0..1. Differentiates
  -- barely-firing (~0.5) from strongly-firing (~1.0). NULL when nothing fires.
  CASE
    WHEN (signal_listings_drop OR signal_listings_spike OR signal_price_rise) THEN
      round((
        (CASE WHEN signal_listings_drop  THEN drop_strength  ELSE 0 END) +
        (CASE WHEN signal_listings_spike THEN spike_strength ELSE 0 END) +
        (CASE WHEN signal_price_rise     THEN price_strength ELSE 0 END)
      ) / NULLIF(
        (signal_listings_drop::int + signal_listings_spike::int + signal_price_rise::int),
        0
      )::numeric, 3)
    ELSE NULL
  END                                                                                    AS confidence_score
FROM scored
WHERE velocity_fresh
  AND (signal_listings_drop OR signal_listings_spike OR signal_price_rise);

COMMENT ON VIEW public.v_tevo_blindspot_movers IS
  'TEvo blindspot mover candidates: US/CA events 31-365d out where we own 0
   tickets, broker pool has >=25 listings, parking-aware get-in >= $50, and
   the pool is showing demand signals. 3-signal detection: listings_drop
   (PAIRED abs+pct), listings_spike (pool loading), price_rise. Scores:
   selling_score (drop+rise, 0..2), tracking_score (drop|spike+rise, 0..2),
   confidence_score (0..1, avg of fired-signal strengths — preferred sort
   key). v1.5 also tags days_to_event_band for cohort triage. Companion to
   v_sg_blindspot_movers (mig 20260520370000) which uses a 4-signal
   composite on SG data.';

REVOKE ALL ON public.v_tevo_blindspot_movers FROM PUBLIC;
GRANT SELECT ON public.v_tevo_blindspot_movers TO anon, authenticated, service_role;

-- ============================================================
-- 2. RPC — caller-facing wrapper. Returns JSON array sorted by score DESC,
--    then by velocity magnitude. Email-gated per §6 caller guard.
-- ============================================================
DROP FUNCTION IF EXISTS public.get_blind_spots_tevo_selling(int, int, int, text);
DROP FUNCTION IF EXISTS public.get_blind_spots_tevo_selling(int, int, int, text, text);
DROP FUNCTION IF EXISTS public.get_blind_spots_tevo_selling(numeric, int, int, text, text, text);

CREATE OR REPLACE FUNCTION public.get_blind_spots_tevo_selling(
  p_min_confidence numeric DEFAULT 0.5,   -- v1.5: confidence floor (0..1)
  p_horizon_days   int     DEFAULT 365,
  p_limit          int     DEFAULT 25,
  p_venue_pattern  text    DEFAULT NULL,  -- ILIKE wildcards to narrow within US/CA
  p_mode           text    DEFAULT 'selling',   -- 'selling'|'tracking'|'spike_only'
  p_band           text    DEFAULT NULL    -- v1.5: 'imminent_31_60'|'near_61_180'|'far_181_365'|NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  -- §6 caller guard — email-required
  v_email := nullif((select auth.jwt())->>'email', '');
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'email required' USING errcode = '42501';
  END IF;

  IF p_mode NOT IN ('selling', 'tracking', 'spike_only') THEN
    RAISE EXCEPTION 'p_mode must be selling|tracking|spike_only' USING errcode = '22023';
  END IF;
  IF p_band IS NOT NULL AND p_band NOT IN ('imminent_31_60','near_61_180','far_181_365') THEN
    RAISE EXCEPTION 'p_band must be imminent_31_60|near_61_180|far_181_365|null' USING errcode = '22023';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(m) ORDER BY
                              m.confidence_score DESC NULLS LAST,
                              m.occurs_at_local ASC), '[]'::jsonb)
    INTO v_result
  FROM (
    SELECT
      tevo_event_id, event_name, occurs_at_local,
      venue_id, venue_name, venue_location,
      primary_performer_id, primary_performer_name,
      tickets_count, retail_min, retail_median, getin_no_parking,
      tevo_tix_d24h, tevo_tix_d24h_pct, tevo_getin_d24h_pct,
      tevo_getin_now, tevo_median_now,
      signal_listings_drop, signal_listings_spike, signal_price_rise,
      selling_score, tracking_score, confidence_score,
      days_to_event, days_to_event_band
    FROM public.v_tevo_blindspot_movers
    WHERE occurs_at_local::date <= CURRENT_DATE + (p_horizon_days || ' days')::interval
      AND (p_venue_pattern IS NULL OR venue_location ILIKE p_venue_pattern)
      AND (p_band          IS NULL OR days_to_event_band = p_band)
      AND confidence_score >= p_min_confidence
      AND (
        (p_mode = 'selling'    AND selling_score  >= 1)   OR
        (p_mode = 'tracking'   AND tracking_score >= 1)   OR
        (p_mode = 'spike_only' AND signal_listings_spike  = true)
      )
    LIMIT p_limit
  ) m;

  RETURN v_result;
END;
$$;

REVOKE ALL    ON FUNCTION public.get_blind_spots_tevo_selling(numeric, int, int, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_blind_spots_tevo_selling(numeric, int, int, text, text, text) TO anon, authenticated;

COMMENT ON FUNCTION public.get_blind_spots_tevo_selling(numeric, int, int, text, text, text) IS
  'BLIND SPOTS — TEvo SELLING, WE''RE NOT. 3-signal composite over broker
   pool (no sales data on TEvo broker side). Candidate gates: owned=0,
   tickets>=25, 31-365d out, US/CA venue, parking-aware get-in >= $50.
   Signals: listings shrinking (d24h<=-10 AND d24h_pct<=-5%), listings
   spiking (d24h_pct>=+10%), get-in rising (>=+5%).
   v1.5 sort: confidence_score DESC (avg of fired-signal strengths; 0..1).
   Modes: selling|tracking|spike_only. Filter by p_band (imminent_31_60|
   near_61_180|far_181_365|null). Companion to get_blind_spots_sg_selling().';

-- ============================================================
-- VERIFICATION (operator runs after apply):
--
--   -- 1. View population + signal breakdown + confidence distribution
--   SELECT count(*) AS total,
--          count(*) FILTER (WHERE signal_listings_drop)  AS drops,
--          count(*) FILTER (WHERE signal_listings_spike) AS spikes,
--          count(*) FILTER (WHERE signal_price_rise)     AS price_rises,
--          count(*) FILTER (WHERE confidence_score >= 0.8) AS conf_high,
--          count(*) FILTER (WHERE confidence_score >= 0.5
--                            AND confidence_score < 0.8)   AS conf_med,
--          round(avg(getin_no_parking)::numeric, 0)      AS avg_getin
--   FROM public.v_tevo_blindspot_movers;
--
--   -- 2. Band distribution
--   SELECT days_to_event_band, count(*),
--          round(avg(confidence_score)::numeric, 2) AS avg_confidence
--   FROM public.v_tevo_blindspot_movers
--   GROUP BY days_to_event_band ORDER BY 1;
--
--   -- 3. RPC smoke (as authenticated user with email JWT)
--   SELECT public.get_blind_spots_tevo_selling();                                   -- default: conf >= 0.5
--   SELECT public.get_blind_spots_tevo_selling(0.8);                                -- strong only
--   SELECT public.get_blind_spots_tevo_selling(0.5, 365, 25, NULL, 'tracking');     -- include spikes
--   SELECT public.get_blind_spots_tevo_selling(0.0, 365, 25, NULL, 'spike_only');   -- spikes only
--   SELECT public.get_blind_spots_tevo_selling(0.5, 90, 10, '%New York%', 'selling', 'imminent_31_60');
--
--   -- 3. Spot-check gates
--   SELECT count(*) AS leaks
--   FROM public.v_tevo_blindspot_movers
--   WHERE getin_no_parking < 50
--      OR tickets_count < 25
--      OR owned_tickets_count <> 0
--      OR occurs_at_local::date < CURRENT_DATE + interval '31 days'
--      OR occurs_at_local::date > CURRENT_DATE + interval '365 days';
--   -- Expect 0.
-- ============================================================
