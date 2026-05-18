-- Migration 20260520250000 · lane:A1 · writes:get_event_chart_extended · reads:(unchanged) · pre:20260520220000
--
-- Fix the listings-series chart collapse on D0 event-page charts.
--
-- ROOT CAUSE
--   `get_event_chart_extended` (PR #237 / mig 20260519150000) dedupes the SG
--   listings firehose GLOBALLY across the chart window before bucketing:
--
--     WITH deduped AS (
--       SELECT DISTINCT ON (sglid)
--         sglid, captured_at, broadcast_price, quantity, is_broker_owned
--       FROM public.seatgeek_listings_snapshots
--       WHERE sg_event_id = v_sg_event_id ...
--       ORDER BY sglid, captured_at DESC
--     )
--
--   `seatgeek_listings_snapshots` is a FULL-INVENTORY firehose (each pull
--   re-inserts every active sglid). A listing active for N days appears in N
--   pulls. The global DISTINCT ON keeps only the row with the latest
--   captured_at per sglid — so a long-lived listing contributes EXACTLY ONE
--   data point to the chart, in the bucket where it was LAST seen.
--
--   Consequence: early-window buckets only contain listings that
--   disappeared during that bucket. The chart line collapses to single-digit
--   counts/totals in early buckets even when ~480 listings were active
--   throughout. The latest bucket inflates with the listings whose most
--   recent appearance happens to be there. Users see a "massive drop" that
--   is purely a rendering artifact.
--
-- VERIFIED ON PROD (read-only dry-run 2026-05-18 vs sg_event_id 17693982,
-- Cleveland Guardians at Philadelphia Phillies May 22, COOL tier, 168h window):
--
--   Bucket          | Buggy (global)        | Fixed (per-bucket)
--   ----------------+-----------------------+-------------------------
--   05-16 18:00     |   6 sglids /   25 tix |  488 sglids / 2126 tix
--   05-16 22:00     |   7 sglids /   20 tix |  482 sglids / 2092 tix
--   05-17 00:00     |   7 sglids /   26 tix |  475 sglids / 2072 tix
--   05-17 14:00     | 152 sglids /  690 tix |  467 sglids / 2029 tix
--   05-18 00:00     | 345 sglids / 1461 tix |  350 sglids / 1478 tix
--   05-18 02:00     |   9 sglids /   32 tix |    9 sglids /   32 tix
--
--   True trajectory: ~480 sglids for 24h, with a real ~25% reduction in the
--   05-17 14:00 → 05-18 00:00 window. The latest bucket (05-18 02:00 = 9)
--   is a SEPARATE concern — see "NOT FIXED IN THIS MIGRATION" below.
--
-- FIX
--   Replace global DISTINCT ON with per-bucket DISTINCT ON. Each bucket gets
--   the latest captured_at row per sglid WITHIN THE BUCKET, so a long-lived
--   listing contributes a data point to EVERY bucket where it was active.
--
--     WITH deduped AS (
--       SELECT DISTINCT ON (date_bin(...), sglid)
--         date_bin(...) AS bucket,
--         sglid, captured_at, broadcast_price, quantity, is_broker_owned
--       FROM ...
--       ORDER BY date_bin(...), sglid, captured_at DESC
--     )
--
--   The downstream `bucketed` CTE collapses to a direct GROUP BY on bucket
--   (since the bucket column is already computed in `deduped`).
--
-- SALES-SIDE — INTENTIONALLY UNCHANGED
--   The sales CTE keeps global DISTINCT ON (sg_sale_id), which is CORRECT
--   for that data shape. A sale is a point event with one true sale_at_utc
--   timestamp; the bible §3 11–23× firehose duplication factor refers to
--   the SAME sale being re-emitted in every poll. Global DISTINCT ON
--   selects the canonical version (latest pulled_at) and the sale falls
--   in exactly ONE bucket via its sale_at_utc. Per-bucket dedup on sales
--   would be a no-op at best and incorrect at worst (it would let the
--   same sale appear in multiple buckets if different pulls happened to
--   land in different buckets).
--
--   Verified (sample 5 sg_sale_ids): each has exactly 1 distinct sale_at_utc
--   and 1 distinct broadcast_price across 25 re-captures.
--
-- NOT FIXED IN THIS MIGRATION (separate concerns, flagged for follow-up)
--   1. The 05-18 02:45 pull returned only 9 listings (rows_persisted=9 in
--      sg_broker_pending, with two -429 rate-limited fires preceding it).
--      No sales recorded between 00:34 → 02:45, so this isn't natural
--      attrition. Could be a real upstream API hiccup or a query-param
--      drift. The raw HTTP response was pruned (net._http_response GC)
--      before inspection. After this migration applies, the chart will
--      correctly show 9 only in the latest bucket and ~480 in prior
--      buckets, which is the right behavior — the chart can only paint
--      what the firehose captured.
--   2. The 12h gap between 05-17 03:00 and 05-17 14:00 with no pulls is
--      tier-policy expected for a COOL event (24 polls/day) plus burst-cap
--      collisions on the 5-min sg_priority_* schedule. Not a bug.
--
-- INVARIANTS PRESERVED
--   - Function signature unchanged (no overload risk per PROJECT_BIBLE §7).
--   - SECDEF + STABLE + search_path + @s4kent.com email gate unchanged.
--   - REVOKE/GRANT matrix unchanged.
--   - Injury partition fix from mig 20260520220000 preserved.
--   - Sales-series CTE byte-identical.
--   - Game-state CTE byte-identical.
--   - Bucket size adaptive logic unchanged.

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
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_window_start := v_now - make_interval(hours => v_hours);

  v_bucket_secs := CASE
    WHEN v_hours <=  24 THEN  900   -- 15 min
    WHEN v_hours <=  72 THEN 3600   --  1 hr
    WHEN v_hours <= 168 THEN 7200   --  2 hr
    WHEN v_hours <= 720 THEN 21600  --  6 hr
    ELSE 86400                      --  1 day
  END;

  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  IF v_sg_event_id IS NULL THEN
    v_sg_hidden := true;
    v_sg_reason := 'no_sg_bridge';
  END IF;

  SELECT ex.espn_event_id, ex.espn_league
  INTO v_espn_event_id, v_espn_league
  FROM public.event_xref ex
  WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  IF (v_home_team IS NULL OR v_away_team IS NULL) AND v_espn_event_id IS NOT NULL THEN
    SELECT home_team_id, away_team_id
    INTO v_home_team, v_away_team
    FROM public.espn_event_date_lookup
    WHERE espn_event_id = v_espn_event_id LIMIT 1;

    IF v_home_team IS NULL OR v_away_team IS NULL THEN
      SELECT home_team_id, away_team_id
      INTO v_home_team, v_away_team
      FROM public.espn_event_snapshots
      WHERE espn_event_id = v_espn_event_id
      ORDER BY captured_at DESC LIMIT 1;
    END IF;
  END IF;

  -- ---------- SG listings series (per-bucket DISTINCT ON sglid) ----------
  -- Dedupe sglid INSIDE each bucket, not globally. A listing active across
  -- multiple buckets must contribute one data point per bucket; the global
  -- DISTINCT ON used pre-mig-20260520250000 collapsed long-lived listings
  -- to a single bucket (their LAST appearance), causing early-window buckets
  -- to look near-empty even when ~480 listings were active throughout.
  IF NOT v_sg_hidden THEN
    WITH deduped AS (
      SELECT DISTINCT ON (
               date_bin(make_interval(secs => v_bucket_secs), captured_at, '2000-01-01'::timestamptz),
               sglid
             )
        date_bin(make_interval(secs => v_bucket_secs), captured_at, '2000-01-01'::timestamptz) AS bucket,
        sglid, captured_at, broadcast_price, quantity, is_broker_owned
      FROM public.seatgeek_listings_snapshots
      WHERE sg_event_id = v_sg_event_id
        AND captured_at > v_window_start
        AND captured_at <= v_now
      ORDER BY
        date_bin(make_interval(secs => v_bucket_secs), captured_at, '2000-01-01'::timestamptz),
        sglid,
        captured_at DESC
    ),
    bucketed AS (
      SELECT bucket, broadcast_price, quantity, is_broker_owned
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
  -- INTENTIONALLY GLOBAL DEDUP: sales are point events. Each sg_sale_id has
  -- exactly 1 true sale_at_utc; bible §3 11-23x firehose dedup applies. The
  -- sale falls into exactly one bucket via its sale_at_utc. Per-bucket dedup
  -- would be a no-op or incorrect here.
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
  -- Injury partition fix from mig 20260520220000 (Arias notification flood) preserved.
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
    WHERE status IS DISTINCT FROM prev_status;
  END IF;

  -- ---------- ESPN game-state transitions ----------
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
  'D0 event chart extension — 5 SG-side series + 2 ESPN annotation arrays. LISTINGS series use PER-BUCKET DISTINCT ON sglid (mig 20260520250000); SALES series use GLOBAL DISTINCT ON sg_sale_id (point-event semantics). Athlete partition keyed on (espn_league, espn_team_id, lower(btrim(coalesce(athlete_name, athlete_id)))) to defend against ESPN provisional negative athlete_ids (mig 20260520220000). Email-gated.';

-- ============================================================
-- Post-apply verification (operator runs after apply_migration)
-- ============================================================
-- 1) Old global-dedup pattern gone for LISTINGS, sales-side unchanged:
--    SELECT pg_get_functiondef(p.oid) ~ 'DISTINCT ON \(\s*date_bin\(make_interval\(secs => v_bucket_secs\)' AS listings_per_bucket,
--           pg_get_functiondef(p.oid) ~ 'DISTINCT ON \(sg_sale_id\)' AS sales_global_dedup_preserved
--    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public' AND p.proname='get_event_chart_extended';
--    -- expect: listings_per_bucket=true, sales_global_dedup_preserved=true
--
-- 2) Live: re-fetch chart for the Cleveland @ Phillies May 22 event
--    (tevo_event_id=3101466) over 168h. Listings buckets that previously
--    showed single-digit counts should now show ~470-490.
--    SELECT jsonb_array_length(public.get_event_chart_extended(3101466, 168)
--           -> 'series' -> 'sg_listings_count') AS bucket_count;
--    -- expect: several non-trivial values, max bucket value ~480 instead of ~345
--
-- 3) Performance smoke: 168h window with adaptive 2h buckets on a busy event
--    should run within the v3 RPC's ~308ms baseline. Per-bucket dedup
--    expands the dedupe key cardinality (bucket × sglid) but the sg_event_id
--    + captured_at filter scoping keeps the working set small.
