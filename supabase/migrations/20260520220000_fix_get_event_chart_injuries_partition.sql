-- Migration 20260520220000 · lane:A1 · writes:get_event_chart_extended · reads:(unchanged) · pre:20260519150000
--
-- Fix Gabriel Arias notification flood on the Cleveland Guardians @ Phillies chart.
--
-- ROOT CAUSE
--   `public.espn_injuries_snapshots` had 277 rows for athlete_name='Gabriel Arias'
--   (espn_team_id='5', league='MLB', status='10-Day-IL') with 275 distinct
--   negative synthetic `athlete_id` values (and 2 NULL ids). ESPN returns a
--   fresh provisional negative id per poll when no stable athlete id is
--   available, which both:
--     (a) defeats `upsert_espn_injury` content-hash dedup → every row inserts
--         as is_baseline=true;
--     (b) breaks downstream consumers that PARTITION BY athlete_id.
--
--   `get_event_chart_extended` (mig 20260519150000, line 188) used
--     LAG(status) OVER (PARTITION BY athlete_id ORDER BY captured_at)
--   so every Arias row sat in its own partition of size 1 → `prev_status`
--   was always NULL → `status IS DISTINCT FROM prev_status` was always TRUE
--   → the chart painted ~277 identical "10-Day-IL" markers.
--
-- FIX (this migration, RPC-side only)
--   Partition by stable identity instead of unstable athlete_id:
--     PARTITION BY espn_league, espn_team_id,
--                  lower(btrim(coalesce(athlete_name, athlete_id, '')))
--   - `athlete_name` is stable across captures (277 rows, 1 distinct name).
--   - Scoping by `(espn_league, espn_team_id)` prevents cross-league
--     espn_team_id collisions (PROJECT_BIBLE.md §3 landmine: id='28' maps to
--     BOTH MLB Atlanta + an NHL team).
--   - `lower(btrim(...))` defends against whitespace/case noise.
--   - `coalesce(athlete_name, athlete_id, '')` keeps a sensible fallback for
--     rows that lack a name (e.g. the 2 NULL-name Arias rows still fall into
--     a single partition keyed on their athlete_id values).
--   - First-seen NULL→status transition still emits one annotation per
--     athlete (intended behavior — original code comment at line 207 of
--     20260519150000).
--
-- VERIFIED (dry-run on prod 2026-05-18 against live espn_injuries_snapshots)
--   Pre-patch  : Arias emits ~184 transitions in 168h window.
--   Post-patch : Arias emits 1 transition. Other Cleveland athletes still
--                emit their expected 1 transition each (Shawn Armstrong 3
--                rows → 1, Andrew Walters 1 row → 1).
--
-- DEFERRED (Layer 2 — ingest hardening, separate PR)
--   `supabase/functions/espn-collect/index.ts:194-200` should treat
--   `athleteIdRaw < 0` (negative provisional ESPN ids) as "no stable id"
--   and fall through to the `${team_id}:${slug}` synthetic-id branch.
--   That change touches several downstream views/RPCs and warrants its
--   own scoped PR. bot_chat flag to the espn-collect lane owner pending.
--
-- INVARIANTS PRESERVED
--   - Function signature unchanged (no overload risk per PROJECT_BIBLE §7).
--   - SECDEF + STABLE + search_path + @s4kent.com email gate unchanged.
--   - REVOKE/GRANT matrix unchanged (idempotent re-grant included for safety).
--   - All other CTEs (SG listings/sales series, game-state transitions) are
--     byte-identical to mig 20260519150000.

CREATE OR REPLACE FUNCTION public.get_event_chart_extended(
  p_event_id        integer,
  p_chart_hours     integer DEFAULT 168,
  p_espn_home_team  text    DEFAULT NULL,
  p_espn_away_team  text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email          text;
  v_sg_event_id    bigint;
  v_espn_event_id  text;
  v_espn_league    text;
  v_home_team      text := p_espn_home_team;
  v_away_team      text := p_espn_away_team;
  v_hours          int  := greatest(1, least(coalesce(p_chart_hours, 168), 4320));
  v_bucket_secs    int;
  v_window_start   timestamptz;
  v_now            timestamptz := now();
  v_sg_listings    jsonb := '[]'::jsonb;
  v_sg_listings_own jsonb := '[]'::jsonb;
  v_sg_listings_ct jsonb := '[]'::jsonb;
  v_sg_sales       jsonb := '[]'::jsonb;
  v_sg_sales_ct    jsonb := '[]'::jsonb;
  v_injuries       jsonb := '[]'::jsonb;
  v_game_state     jsonb := '[]'::jsonb;
  v_sg_hidden      boolean := false;
  v_sg_reason      text;
BEGIN
  -- ---------- auth gate (mirrors v3 / sibling RPCs) ----------
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_window_start := v_now - make_interval(hours => v_hours);

  -- ---------- bucket size (adapts to window length) ----------
  v_bucket_secs := CASE
    WHEN v_hours <=  24 THEN  900   -- 15 min
    WHEN v_hours <=  72 THEN 3600   --  1 hr
    WHEN v_hours <= 168 THEN 7200   --  2 hr
    WHEN v_hours <= 720 THEN 21600  --  6 hr
    ELSE 86400                      --  1 day
  END;

  -- ---------- bridge resolution ----------
  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  IF v_sg_event_id IS NULL THEN
    v_sg_hidden := true;
    v_sg_reason := 'no_sg_bridge';
  END IF;

  -- ESPN linkage (always attempt — annotations may render even when SG is hidden)
  SELECT ex.espn_event_id, ex.espn_league
  INTO v_espn_event_id, v_espn_league
  FROM public.event_xref ex
  WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  -- Auto-resolve home/away team IDs if not supplied by FE.
  -- Prefer espn_event_date_lookup (populated for forward-look events) over
  -- espn_event_snapshots (gameday-scope only per §10 drift watchlist).
  IF (v_home_team IS NULL OR v_away_team IS NULL) AND v_espn_event_id IS NOT NULL THEN
    SELECT home_team_id, away_team_id
    INTO v_home_team, v_away_team
    FROM public.espn_event_date_lookup
    WHERE espn_event_id = v_espn_event_id LIMIT 1;

    -- Snapshot fallback for past games where date_lookup is sparse
    IF v_home_team IS NULL OR v_away_team IS NULL THEN
      SELECT home_team_id, away_team_id
      INTO v_home_team, v_away_team
      FROM public.espn_event_snapshots
      WHERE espn_event_id = v_espn_event_id
      ORDER BY captured_at DESC LIMIT 1;
    END IF;
  END IF;

  -- ---------- SG listings series (DISTINCT ON sglid, then bucket) ----------
  IF NOT v_sg_hidden THEN
    WITH deduped AS (
      SELECT DISTINCT ON (sglid)
        sglid, captured_at, broadcast_price, quantity, is_broker_owned
      FROM public.seatgeek_listings_snapshots
      WHERE sg_event_id = v_sg_event_id
        AND captured_at > v_window_start
        AND captured_at <= v_now
      ORDER BY sglid, captured_at DESC
    ),
    bucketed AS (
      SELECT
        date_bin(make_interval(secs => v_bucket_secs), captured_at, '2000-01-01'::timestamptz) AS bucket,
        broadcast_price, quantity, is_broker_owned
      FROM deduped
      WHERE broadcast_price IS NOT NULL
    )
    SELECT
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', median_p) ORDER BY bucket), '[]'::jsonb),
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', median_p_owned) ORDER BY bucket) FILTER (WHERE median_p_owned IS NOT NULL), '[]'::jsonb),
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', total_qty) ORDER BY bucket), '[]'::jsonb)
    INTO v_sg_listings, v_sg_listings_own, v_sg_listings_ct
    FROM (
      SELECT
        bucket,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price) AS median_p,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price) FILTER (WHERE is_broker_owned) AS median_p_owned,
        SUM(quantity)::int AS total_qty
      FROM bucketed GROUP BY bucket
    ) b;
  END IF;

  -- ---------- SG sales series (DISTINCT ON sg_sale_id, then bucket on sale_at_utc) ----------
  IF NOT v_sg_hidden THEN
    WITH deduped AS (
      SELECT DISTINCT ON (sg_sale_id)
        sg_sale_id, sale_at_utc, pulled_at, broadcast_price, quantity
      FROM public.seatgeek_sales_snapshots
      WHERE sg_event_id = v_sg_event_id
        AND coalesce(sale_at_utc, pulled_at) > v_window_start
        AND coalesce(sale_at_utc, pulled_at) <= v_now
      ORDER BY sg_sale_id, pulled_at DESC
    ),
    bucketed AS (
      SELECT
        date_bin(make_interval(secs => v_bucket_secs), coalesce(sale_at_utc, pulled_at), '2000-01-01'::timestamptz) AS bucket,
        broadcast_price
      FROM deduped
      WHERE broadcast_price IS NOT NULL
    )
    SELECT
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', median_p) ORDER BY bucket), '[]'::jsonb),
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', sale_ct) ORDER BY bucket), '[]'::jsonb)
    INTO v_sg_sales, v_sg_sales_ct
    FROM (
      SELECT
        bucket,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price) AS median_p,
        count(*)::int AS sale_ct
      FROM bucketed GROUP BY bucket
    ) b;
  END IF;

  -- ---------- ESPN injury transitions (LAG per stable athlete identity, both teams) ----------
  -- espn_team_id is NOT globally unique across leagues — e.g. id="28" maps to
  -- MLB Atlanta Braves AND an NHL team. ALWAYS scope by espn_league so cross-
  -- league fan-out doesn't surface unrelated injuries on a sport-specific chart.
  --
  -- ATHLETE PARTITION (changed 2026-05-19 — Arias notification flood fix):
  -- partition by stable identity (league + team + normalized name) instead of
  -- the raw athlete_id, which ESPN returns as a fresh negative provisional id
  -- per poll for athletes without a stable upstream id. Falls back to
  -- athlete_id when name is NULL.
  IF (v_home_team IS NOT NULL OR v_away_team IS NOT NULL) AND v_espn_league IS NOT NULL THEN
    WITH ordered AS (
      SELECT
        captured_at, espn_team_id, athlete_id, athlete_name, position, status,
        LAG(status) OVER (
          PARTITION BY espn_league, espn_team_id,
                       lower(btrim(coalesce(athlete_name, athlete_id, '')))
          ORDER BY captured_at
        ) AS prev_status
      FROM public.espn_injuries_snapshots
      WHERE espn_league = v_espn_league
        AND espn_team_id IN (v_home_team, v_away_team)
        AND espn_team_id IS NOT NULL
        AND captured_at > v_window_start
        AND captured_at <= v_now
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'at',            to_char(captured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             'athlete_id',    athlete_id,
             'athlete_name',  athlete_name,
             'position',      position,
             'espn_team_id',  espn_team_id,
             'prev_status',   prev_status,
             'new_status',    status
           ) ORDER BY captured_at), '[]'::jsonb)
    INTO v_injuries
    FROM ordered
    WHERE status IS DISTINCT FROM prev_status;  -- transitions only (including first-seen NULL→X)
  END IF;

  -- ---------- ESPN game-state transitions (LAG on status_short, this event) ----------
  IF v_espn_event_id IS NOT NULL THEN
    WITH ordered AS (
      SELECT
        captured_at, espn_event_id, status_short, state,
        LAG(status_short) OVER (PARTITION BY espn_event_id ORDER BY captured_at) AS prev_status
      FROM public.espn_event_snapshots
      WHERE espn_event_id = v_espn_event_id
        AND (v_espn_league IS NULL OR espn_league = v_espn_league)
        AND captured_at > v_window_start
        AND captured_at <= v_now
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'at',             to_char(captured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             'espn_event_id',  espn_event_id,
             'prev_status',    prev_status,
             'new_status',     status_short,
             'state',          state
           ) ORDER BY captured_at), '[]'::jsonb)
    INTO v_game_state
    FROM ordered
    WHERE status_short IS DISTINCT FROM prev_status;
  END IF;

  -- ---------- assemble ----------
  RETURN jsonb_build_object(
    'tevo_event_id',  p_event_id,
    'sg_event_id',    v_sg_event_id,
    'espn_event_id',  v_espn_event_id,
    'espn_league',    v_espn_league,
    'home_team_id',   v_home_team,
    'away_team_id',   v_away_team,
    'range', jsonb_build_object(
      'start',  to_char(v_window_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'end',    to_char(v_now          AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'hours',  v_hours,
      'bucket_seconds', v_bucket_secs
    ),
    'sg_hidden', v_sg_hidden,
    'sg_reason', v_sg_reason,
    'series', jsonb_build_object(
      'sg_listings_median',       v_sg_listings,
      'sg_listings_owned_median', v_sg_listings_own,
      'sg_listings_count',        v_sg_listings_ct,
      'sg_sales_median',          v_sg_sales,
      'sg_sales_count',           v_sg_sales_ct
    ),
    'annotations', jsonb_build_object(
      'injuries',   v_injuries,
      'game_state', v_game_state
    )
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_event_chart_extended(integer, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_chart_extended(integer, integer, text, text) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_chart_extended(integer, integer, text, text) IS
  'D0 event chart extension — 5 SG-side series (listings median + owned median + listings count + sales median + sales count) over adaptive buckets (15min..1d depending on p_chart_hours) + 2 ESPN annotation arrays (injury transitions LAG(status) per stable athlete identity on both teams + game-state transitions LAG(status_short) per espn_event_id). Athlete partition keyed on (espn_league, espn_team_id, lower(btrim(coalesce(athlete_name, athlete_id)))) to defend against ESPN provisional negative athlete_ids (Arias incident, fix mig 20260520220000). DISTINCT ON sg_sale_id|sglid mandatory (§3 landmine). Bridge via seatgeek_event_xref; ESPN via event_xref. Email-gated.';

-- ============================================================
-- Post-apply verification (operator runs after apply_migration)
-- ============================================================
-- 1) Buggy partition gone:
--    SELECT pg_get_functiondef(p.oid) !~ 'PARTITION BY athlete_id\s+ORDER' AS fixed
--    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public' AND p.proname='get_event_chart_extended';
--
-- 2) Arias collapses to 1 transition (in 168h window):
--    WITH ordered AS (
--      SELECT captured_at, athlete_name, status,
--             LAG(status) OVER (PARTITION BY espn_league, espn_team_id,
--                               lower(btrim(coalesce(athlete_name, athlete_id, '')))
--                               ORDER BY captured_at) AS prev_status
--      FROM public.espn_injuries_snapshots
--      WHERE espn_league='MLB' AND espn_team_id='5'
--        AND captured_at > now() - interval '168 hours'
--    )
--    SELECT athlete_name, count(*) AS rows,
--           count(*) FILTER (WHERE status IS DISTINCT FROM prev_status) AS transitions
--    FROM ordered WHERE athlete_name='Gabriel Arias' GROUP BY 1;
--
-- 3) Live RPC smoke (replace <tevo_event_id> with Cleveland @ Phillies id):
--    SELECT jsonb_array_length(
--      public.get_event_chart_extended(<tevo_event_id>, 168) -> 'annotations' -> 'injuries'
--    ) AS injury_marker_count;
--    -- Expect a few dozen across both rosters, not 200+.
