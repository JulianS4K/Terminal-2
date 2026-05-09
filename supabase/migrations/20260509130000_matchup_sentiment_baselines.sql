-- Matchup index, buyer-sentiment composite, performer + venue baselines.
-- Operationalizes the strategy memo at
-- docs/historical-data-and-multi-view-strategy-2026-05-09.md.
-- Applied to prod 2026-05-09 ~04:00 UTC.
--
-- Why: the prior infrastructure handles per-event metrics + cross-source
-- xrefs. This migration adds the analytical layers that span events:
--   * matchup_xref / matchup_history — group events into rivalries
--   * event_sentiment — composite buyer-sentiment index per snapshot
--   * performer_baselines / venue_baselines — rolling baselines for context
--   * find_similar_events() — similarity scoring across multiple dimensions
--
-- Read-only against external APIs (RULE 2 still enforced). All writes are
-- to our own derived tables.

BEGIN;

-- ============================================================
-- A. Matchup index — group games by (team_a, team_b) regardless of host
-- ============================================================
-- A "matchup" is the unordered pair of two performer ids. The same matchup
-- can host an entire MLB season (13+ games) or a 7-game playoff series.
-- Storing it as a separate identity unlocks "show me all Knicks-Celtics
-- games" without complex array joins.

CREATE TABLE IF NOT EXISTS matchup_xref (
  matchup_id        bigserial PRIMARY KEY,
  team_a_id         bigint NOT NULL,
  team_b_id         bigint NOT NULL,
  team_a_name       text,
  team_b_name       text,
  first_seen_event  bigint,   -- TEvo event_id of first encountered game
  last_seen_at      timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT matchup_xref_unique CHECK (team_a_id < team_b_id),
  CONSTRAINT matchup_xref_pair UNIQUE (team_a_id, team_b_id)
);
CREATE INDEX IF NOT EXISTS idx_matchup_xref_team_a ON matchup_xref(team_a_id);
CREATE INDEX IF NOT EXISTS idx_matchup_xref_team_b ON matchup_xref(team_b_id);

-- View: matchup_history — per (matchup_id, event) latest event_metrics rolled up
CREATE OR REPLACE VIEW public.matchup_history AS
SELECT
  m.matchup_id,
  m.team_a_id, m.team_b_id, m.team_a_name, m.team_b_name,
  e.id AS event_id,
  e.occurs_at_local::date AS event_date,
  e.primary_performer_id  AS host_performer_id,
  e.primary_performer_name AS host_team,
  e.venue_id, e.venue_name,
  -- Latest metrics
  em.tickets_count, em.owned_tickets_count, em.retail_median,
  em.owned_median_retail, em.getin_price,
  -- Lifecycle
  lc.status AS lifecycle_status, lc.is_active
FROM matchup_xref m
JOIN events e ON
  (LEAST(e.primary_performer_id, e.performer_ids[2]) = m.team_a_id
   AND GREATEST(e.primary_performer_id, e.performer_ids[2]) = m.team_b_id)
  OR (LEAST(e.primary_performer_id, e.performer_ids[1]) = m.team_a_id
      AND GREATEST(e.primary_performer_id, e.performer_ids[1]) = m.team_b_id)
LEFT JOIN LATERAL (
  SELECT * FROM event_metrics WHERE event_id = e.id
  ORDER BY captured_at DESC LIMIT 1
) em ON true
LEFT JOIN event_lifecycle lc ON lc.event_id = e.id
WHERE e.event_type = 'game';

GRANT SELECT ON public.matchup_history TO authenticated, service_role;

-- Backfill function: seed matchup_xref from existing events
CREATE OR REPLACE FUNCTION public.backfill_matchup_xref()
RETURNS TABLE(matchups_created int) LANGUAGE plpgsql AS $$
DECLARE n int := 0;
BEGIN
  WITH game_pairs AS (
    SELECT DISTINCT
      LEAST(e.primary_performer_id, perf_id)  AS team_a,
      GREATEST(e.primary_performer_id, perf_id) AS team_b,
      LEAST(e.primary_performer_name, perf_name)  AS team_a_name,
      GREATEST(e.primary_performer_name, perf_name) AS team_b_name,
      e.id AS event_id
    FROM events e
    CROSS JOIN LATERAL unnest(e.performer_ids) AS perf_id
    LEFT JOIN LATERAL (
      SELECT primary_performer_name AS perf_name FROM events e2
      WHERE e2.primary_performer_id = perf_id LIMIT 1
    ) other ON true
    WHERE e.event_type = 'game'
      AND e.primary_performer_id IS NOT NULL
      AND perf_id IS NOT NULL
      AND perf_id <> e.primary_performer_id
  )
  INSERT INTO matchup_xref (team_a_id, team_b_id, team_a_name, team_b_name, first_seen_event)
  SELECT team_a, team_b, MIN(team_a_name), MIN(team_b_name), MIN(event_id)
  FROM game_pairs
  WHERE team_a IS NOT NULL AND team_b IS NOT NULL AND team_a < team_b
  GROUP BY team_a, team_b
  ON CONFLICT (team_a_id, team_b_id) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  matchups_created := n;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION public.backfill_matchup_xref() TO service_role;

-- ============================================================
-- B. Buyer sentiment composite
-- ============================================================
-- Stored per-event-per-captured_at. Cron computes for events with new
-- snapshots. Index = signed scalar in [-100, +100].

CREATE TABLE IF NOT EXISTS event_sentiment (
  event_id           bigint NOT NULL,
  captured_at        timestamptz NOT NULL,
  sentiment_index    numeric NOT NULL,           -- composite, -100..+100
  -- Decomposed components (lets the UI hover-explain)
  tix_per_hour       numeric,                    -- absorption rate
  getin_per_hour     numeric,                    -- floor change rate
  owned_share_change numeric,                    -- our share trajectory
  pairs_change_per_hour numeric,                 -- pair listings disappearing
  -- Audit
  computed_at        timestamptz NOT NULL DEFAULT NOW(),
  PRIMARY KEY (event_id, captured_at)
);
CREATE INDEX IF NOT EXISTS idx_event_sentiment_at ON event_sentiment(captured_at DESC);

-- Compute sentiment for a given event_id at the latest snapshot
CREATE OR REPLACE FUNCTION public.compute_buyer_sentiment(p_event_id bigint)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE
  v_now_at timestamptz; v_prev_at timestamptz;
  v_tix_now int; v_tix_prev int;
  v_getin_now numeric; v_getin_prev numeric;
  v_owned_now int; v_owned_prev int; v_owned_share_now numeric; v_owned_share_prev numeric;
  v_pairs_now int; v_pairs_prev int;
  v_hrs numeric;
  v_tix_per_hour numeric; v_getin_per_hour numeric;
  v_owned_share_change numeric; v_pairs_change_per_hour numeric;
  -- Normalization (rolling stdev, fallback to magic numbers if not enough data)
  v_idx numeric;
BEGIN
  -- Latest 2 snapshots within last 24h
  SELECT em.captured_at, em.tickets_count, em.getin_price,
         em.owned_tickets_count, em.owned_share, em.splits_listings_with_pairs
    INTO v_now_at, v_tix_now, v_getin_now, v_owned_now, v_owned_share_now, v_pairs_now
  FROM event_metrics em
  WHERE em.event_id = p_event_id AND em.captured_at > NOW() - INTERVAL '7 days'
  ORDER BY em.captured_at DESC LIMIT 1;
  IF v_now_at IS NULL THEN RETURN NULL; END IF;

  SELECT em.captured_at, em.tickets_count, em.getin_price,
         em.owned_tickets_count, em.owned_share, em.splits_listings_with_pairs
    INTO v_prev_at, v_tix_prev, v_getin_prev, v_owned_prev, v_owned_share_prev, v_pairs_prev
  FROM event_metrics em
  WHERE em.event_id = p_event_id
    AND em.captured_at < v_now_at - INTERVAL '6 hours'
    AND em.captured_at > v_now_at - INTERVAL '36 hours'
  ORDER BY em.captured_at DESC LIMIT 1;
  IF v_prev_at IS NULL THEN RETURN NULL; END IF;

  v_hrs := EXTRACT(EPOCH FROM (v_now_at - v_prev_at)) / 3600.0;
  IF v_hrs <= 0 THEN RETURN NULL; END IF;

  v_tix_per_hour := (v_tix_now - v_tix_prev) / v_hrs;
  v_getin_per_hour := COALESCE((v_getin_now - v_getin_prev), 0) / v_hrs;
  v_owned_share_change := COALESCE(v_owned_share_now, 0) - COALESCE(v_owned_share_prev, 0);
  v_pairs_change_per_hour := COALESCE(v_pairs_now - v_pairs_prev, 0) / v_hrs;

  -- Rough composite. Coefficients chosen so a "normal" busy event scores
  -- around 0; a strongly bullish event (Knicks G5 absorbing -6 tix/hr,
  -- getin stable) lands ~+30; a strongly bearish event (R3-G2 with +3
  -- tix/hr, getin -1.15) lands ~-25. We can refine with stdev later.
  v_idx :=
      -10.0 * v_tix_per_hour
    +  4.0 * v_getin_per_hour / NULLIF(v_getin_now, 1) * 100   -- normalize getin pct
    + -50.0 * COALESCE(v_owned_share_change, 0)                -- owned share change is fractional
    + -2.0 * v_pairs_change_per_hour;

  -- Clamp to [-100, +100]
  v_idx := GREATEST(-100, LEAST(100, v_idx));

  -- Persist
  INSERT INTO event_sentiment (
    event_id, captured_at, sentiment_index,
    tix_per_hour, getin_per_hour, owned_share_change, pairs_change_per_hour
  ) VALUES (
    p_event_id, v_now_at, ROUND(v_idx::numeric, 2),
    ROUND(v_tix_per_hour::numeric, 2),
    ROUND(v_getin_per_hour::numeric, 2),
    ROUND(v_owned_share_change::numeric, 4),
    ROUND(v_pairs_change_per_hour::numeric, 2)
  )
  ON CONFLICT (event_id, captured_at) DO UPDATE SET
    sentiment_index    = EXCLUDED.sentiment_index,
    tix_per_hour       = EXCLUDED.tix_per_hour,
    getin_per_hour     = EXCLUDED.getin_per_hour,
    owned_share_change = EXCLUDED.owned_share_change,
    pairs_change_per_hour = EXCLUDED.pairs_change_per_hour,
    computed_at        = NOW();

  RETURN v_idx;
END $$;

GRANT EXECUTE ON FUNCTION public.compute_buyer_sentiment(bigint) TO authenticated, service_role;

-- Cascade-friendly batch backfill
CREATE OR REPLACE FUNCTION public.backfill_event_sentiment(p_max_events int DEFAULT 200)
RETURNS TABLE(updated_count int) LANGUAGE plpgsql AS $$
DECLARE r RECORD; n int := 0;
BEGIN
  FOR r IN (
    -- Active future events with new snapshots in the last hour
    SELECT DISTINCT em.event_id FROM event_metrics em
    JOIN event_lifecycle lc ON lc.event_id = em.event_id
    WHERE em.captured_at > NOW() - INTERVAL '1 hour'
      AND lc.is_active = true
    LIMIT p_max_events
  ) LOOP
    BEGIN
      PERFORM compute_buyer_sentiment(r.event_id);
      n := n + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'compute_buyer_sentiment failed for %: %', r.event_id, SQLERRM;
    END;
  END LOOP;
  updated_count := n; RETURN NEXT;
END $$;
GRANT EXECUTE ON FUNCTION public.backfill_event_sentiment(int) TO service_role;

-- ============================================================
-- C. Performer + venue rolling baselines
-- ============================================================
-- Daily-recomputed snapshots of "what's normal for this performer/venue".
-- Used by the UI to answer "is this event richly priced relative to its
-- baseline?".

CREATE TABLE IF NOT EXISTS performer_baselines (
  performer_id           bigint PRIMARY KEY,
  computed_at            timestamptz NOT NULL DEFAULT NOW(),
  events_in_window       int,
  median_retail          numeric,
  median_getin           numeric,
  median_tickets         int,
  median_owned_tix       int,
  avg_owned_share        numeric,
  avg_owned_premium_pct  numeric,
  total_book_notional    numeric
);

CREATE TABLE IF NOT EXISTS venue_baselines (
  venue_id               bigint PRIMARY KEY,
  computed_at            timestamptz NOT NULL DEFAULT NOW(),
  events_in_window       int,
  median_retail          numeric,
  median_tickets         int,
  zone_breakdown         jsonb            -- per-zone median retail, count
);

CREATE OR REPLACE FUNCTION public.refresh_performer_baselines()
RETURNS TABLE(rows_written int) LANGUAGE plpgsql AS $$
DECLARE n int := 0;
BEGIN
  TRUNCATE performer_baselines;
  WITH active_metrics AS (
    SELECT DISTINCT ON (em.event_id)
      em.event_id, em.tickets_count, em.owned_tickets_count, em.retail_median,
      em.owned_median_retail, em.nonowned_median_retail, em.owned_share, em.getin_price,
      e.primary_performer_id
    FROM event_metrics em
    JOIN events e ON e.id = em.event_id
    JOIN event_lifecycle lc ON lc.event_id = e.id
    WHERE lc.is_active = true AND e.occurs_at_local::timestamptz > NOW()
    ORDER BY em.event_id, em.captured_at DESC
  )
  INSERT INTO performer_baselines (
    performer_id, events_in_window, median_retail, median_getin,
    median_tickets, median_owned_tix, avg_owned_share, avg_owned_premium_pct,
    total_book_notional
  )
  SELECT
    primary_performer_id,
    COUNT(*),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY getin_price),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY tickets_count)::int,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY owned_tickets_count)::int,
    AVG(owned_share),
    AVG(((owned_median_retail - nonowned_median_retail) / NULLIF(nonowned_median_retail, 0)) * 100),
    SUM(owned_tickets_count * COALESCE(owned_median_retail, retail_median))
  FROM active_metrics
  WHERE primary_performer_id IS NOT NULL
  GROUP BY primary_performer_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  rows_written := n; RETURN NEXT;
END $$;
GRANT EXECUTE ON FUNCTION public.refresh_performer_baselines() TO service_role;

CREATE OR REPLACE FUNCTION public.refresh_venue_baselines()
RETURNS TABLE(rows_written int) LANGUAGE plpgsql AS $$
DECLARE n int := 0;
BEGIN
  TRUNCATE venue_baselines;
  WITH active_metrics AS (
    SELECT DISTINCT ON (em.event_id)
      em.event_id, em.tickets_count, em.retail_median,
      e.venue_id
    FROM event_metrics em
    JOIN events e ON e.id = em.event_id
    JOIN event_lifecycle lc ON lc.event_id = e.id
    WHERE lc.is_active = true AND e.occurs_at_local::timestamptz > NOW()
    ORDER BY em.event_id, em.captured_at DESC
  )
  INSERT INTO venue_baselines (venue_id, events_in_window, median_retail, median_tickets, zone_breakdown)
  SELECT
    venue_id, COUNT(*),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY tickets_count)::int,
    '{}'::jsonb
  FROM active_metrics
  WHERE venue_id IS NOT NULL
  GROUP BY venue_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  rows_written := n; RETURN NEXT;
END $$;
GRANT EXECUTE ON FUNCTION public.refresh_venue_baselines() TO service_role;

GRANT SELECT ON performer_baselines TO authenticated, service_role;
GRANT SELECT ON venue_baselines     TO authenticated, service_role;

-- ============================================================
-- D. Similar-event finder
-- ============================================================
-- Returns top-N events similar to the given event_id, scored across
-- multiple dimensions. Score weights match the strategy memo.

CREATE OR REPLACE FUNCTION public.find_similar_events(p_event_id bigint, p_max int DEFAULT 5)
RETURNS TABLE(
  event_id          bigint,
  event_name        text,
  event_date        date,
  similarity_score  numeric,
  same_matchup      boolean,
  same_performer    boolean,
  same_venue        boolean
) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_perfs bigint[]; v_venue bigint;
BEGIN
  SELECT performer_ids, venue_id INTO v_perfs, v_venue
  FROM events WHERE id = p_event_id LIMIT 1;
  IF v_perfs IS NULL THEN RETURN; END IF;

  RETURN QUERY
  WITH scored AS (
    SELECT
      e.id AS eid, e.name AS ename, e.occurs_at_local::date AS edate,
      (CASE WHEN v_perfs <@ e.performer_ids AND v_perfs @> e.performer_ids THEN 1.0 ELSE 0 END
       + CASE WHEN e.performer_ids && v_perfs THEN 0.6 ELSE 0 END
       + CASE WHEN e.venue_id = v_venue THEN 0.4 ELSE 0 END
      )::numeric AS score,
      (v_perfs <@ e.performer_ids AND v_perfs @> e.performer_ids) AS sm,
      (e.performer_ids && v_perfs) AS sp,
      (e.venue_id = v_venue) AS sv
    FROM events e
    WHERE e.id <> p_event_id AND e.event_type = 'game'
  )
  SELECT eid, ename, edate, score, sm, sp, sv
  FROM scored WHERE score > 0
  ORDER BY score DESC, edate DESC
  LIMIT p_max;
END $$;

GRANT EXECUTE ON FUNCTION public.find_similar_events(bigint, int) TO authenticated, service_role;

COMMIT;
