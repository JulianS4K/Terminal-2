-- ============================================================================
-- Migration 20260709130000 — Season-ticket package value engine (D0 broker)
--
-- Lane:     A1 (data plane) + D0 read surface (RPCs)
-- Touches:  season_ticket_package_value (W, new),
--           stpv_seat_rows(bigint,int) (fn, new),
--           stpv_summary(bigint,int) (fn, new),
--           get_season_ticket_value(bigint,int) (RPC, new; email-gated),
--           get_season_ticket_leaderboard() (RPC, new; email-gated),
--           refresh_season_ticket_package_values(int,bigint[],int) (fn, new; service-only),
--           cron.job (W: stpv_refresh_daily), cron_policy (W),
--           events (R), listings_snapshots_recent (R), performer_espn_team_xref (R)
-- Pre-reqs: 20260705153500 (venue_section summary-table/cron pattern this mirrors),
--           20260708042000 (cron_should_fire gate-clamp fix — the cron wrapper relies on it),
--           public.cron_should_fire(text), public.cron_policy, public.trg_set_updated_at()
--
-- Values a season-ticket PACKAGE (e.g. "2026 Dallas Cowboys Season Tickets") against
-- the cost of assembling a COMPARABLE seat game-by-game across the team's regular-season
-- home games. "Comparable" = SAME section + row within a +/- band, PAIR-sellable on both
-- sides (2 = ANY(splits)); parking rows excluded; per-ticket prices. Two baselines per
-- seat: getin (cheapest comparable pair each game) and VWAP (depth/quantity-weighted
-- typical). Per-seat deltas roll up to a per-package verdict (quantity-weighted % of the
-- package's own inventory that undercuts buying game-by-game).
--
-- Scope (per operator, 2026-07-09): MAJOR pro leagues + their teams only for now —
-- NFL/NBA/MLB/NHL/MLS via performer_espn_team_xref.espn_league. College (NCAAF) and
-- WNBA/NWSL are intentionally excluded; widen the STPV_MAJOR_LEAGUES set to add them.
--
-- get_season_ticket_value(pkg) computes ONE package LIVE (always current, ~fast).
-- The daily table + refresh feed a league leaderboard without recomputing all live.
--
-- Row/qty model + read-only validation for Cowboys/Eagles: see PR description.
--
-- WARNING: A1 authors; validate on a Supabase preview branch; prod apply is the gated
-- Applier step (CLAUDE.md Rule 1). Not yet applied to prod.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Summary table (one row per major-league package; rebuilt daily)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.season_ticket_package_value (
  pkg_event_id       bigint      PRIMARY KEY,
  league             text,
  team               text,
  venue_name         text,
  event_date         text,                 -- package listing's occurs_at_local (placeholder date)
  home_games         int,
  seats_valued       int,                  -- package seats with a full-coverage comparable
  pkg_ask_med        numeric,              -- median per-ticket package ask across valued seats
  comp_getin_med     numeric,              -- median season cost buying cheapest comparable pair each game
  comp_vwap_med      numeric,              -- median season cost at depth-weighted typical price
  med_savings_getin  numeric,              -- median (comp_getin - pkg_ask) per seat; +ve => package cheaper
  med_savings_vwap   numeric,              -- median (comp_vwap  - pkg_ask) per seat; +ve => package cheaper
  pct_cheaper_getin  numeric,              -- qty-wtd % of pkg inventory cheaper than getin-assembly
  pct_cheaper_vwap   numeric,              -- qty-wtd % of pkg inventory cheaper than vwap-assembly (verdict driver)
  verdict            text,                 -- BUY / FAIR / SKIP / NO_DATA
  row_band           int         NOT NULL DEFAULT 5,
  computed_at        timestamptz NOT NULL DEFAULT now(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  meta               jsonb
);

CREATE INDEX IF NOT EXISTS idx_stpv_verdict
  ON public.season_ticket_package_value (verdict, pct_cheaper_vwap DESC);
CREATE INDEX IF NOT EXISTS idx_stpv_league
  ON public.season_ticket_package_value (league);

REVOKE ALL ON TABLE public.season_ticket_package_value FROM anon, authenticated;
ALTER TABLE public.season_ticket_package_value ENABLE ROW LEVEL SECURITY;
DO $p$ BEGIN
  CREATE POLICY "service_role_all" ON public.season_ticket_package_value
    TO service_role USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $p$;

DROP TRIGGER IF EXISTS season_ticket_package_value_updated_at ON public.season_ticket_package_value;
CREATE TRIGGER season_ticket_package_value_updated_at
  BEFORE UPDATE ON public.season_ticket_package_value
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. Engine: per-seat valuation for ONE package (single source of truth)
--    Returns one row per package seat (section+row) that has a comparable pair
--    in EVERY regular-season home game, with the season-long comparable cost at
--    both baselines. Internal — the SECDEF RPCs/refresh (run as owner) call it.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stpv_seat_rows(
  p_pkg_event_id bigint,
  p_row_band     int DEFAULT 5
)
RETURNS TABLE (
  section       text,
  row_i         int,
  pkg_price     numeric,
  quantity      bigint,
  home_games    int,
  season_getin  numeric,
  season_vwap   numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  WITH pkg AS (
    SELECT id AS pkg_id, venue_id AS ven, primary_performer_id AS perf
    FROM public.events WHERE id = p_pkg_event_id
  ),
  games AS (   -- future regular-season home games (same venue + home team)
    SELECT e.id AS game_id
    FROM public.events e, pkg
    WHERE e.venue_id = pkg.ven AND e.primary_performer_id = pkg.perf
      AND e.event_type = 'game' AND e.id <> pkg.pkg_id
      AND e.name !~* 'season ticket' AND e.name !~* 'preseason'
      AND e.occurs_at_local >= to_char((now() AT TIME ZONE 'utc')::date, 'YYYY-MM-DD')
  ),
  ng AS (SELECT count(*)::int AS n FROM games),
  pl AS (   -- package seats: cheapest pair per section+row (numeric section+row, pair-sellable, non-parking)
    SELECT l.section,
           (CASE WHEN l.row ~ '^[0-9]+$' THEN l.row::int END) AS row_i,
           min(l.retail_price) AS pkg_price,
           sum(l.quantity)     AS quantity
    FROM public.listings_snapshots_recent l, pkg
    WHERE l.event_id = pkg.pkg_id AND l.type = 'event' AND 2 = ANY(l.splits)
      AND l.section ~ '^[0-9]+$' AND l.row ~ '^[0-9]+$'
    GROUP BY l.section, (CASE WHEN l.row ~ '^[0-9]+$' THEN l.row::int END)
  ),
  gs AS (   -- per game: getin + vwap components per section+row
    SELECT g.game_id, l.section,
           (CASE WHEN l.row ~ '^[0-9]+$' THEN l.row::int END) AS row_i,
           min(l.retail_price)               AS getin,
           sum(l.retail_price * l.quantity)  AS spq,
           sum(l.quantity)                   AS sq
    FROM games g
    JOIN public.listings_snapshots_recent l ON l.event_id = g.game_id
    WHERE l.type = 'event' AND 2 = ANY(l.splits)
      AND l.section ~ '^[0-9]+$' AND l.row ~ '^[0-9]+$'
    GROUP BY g.game_id, l.section, (CASE WHEN l.row ~ '^[0-9]+$' THEN l.row::int END)
  ),
  comp AS (  -- per package seat x game: cheapest / vwap comparable pair within +/- band, same section
    SELECT pl.section, pl.row_i, pl.pkg_price, pl.quantity, g.game_id,
           min(gs.getin) AS band_getin,
           CASE WHEN sum(gs.sq) > 0 THEN sum(gs.spq) / sum(gs.sq) END AS band_vwap
    FROM pl CROSS JOIN games g
    LEFT JOIN gs
      ON gs.game_id = g.game_id AND gs.section = pl.section
     AND gs.row_i BETWEEN pl.row_i - p_row_band AND pl.row_i + p_row_band
    GROUP BY pl.section, pl.row_i, pl.pkg_price, pl.quantity, g.game_id
  )
  SELECT c.section, c.row_i, c.pkg_price, c.quantity,
         (SELECT n FROM ng)         AS home_games,
         sum(c.band_getin)          AS season_getin,
         sum(c.band_vwap)           AS season_vwap
  FROM comp c
  GROUP BY c.section, c.row_i, c.pkg_price, c.quantity
  HAVING (SELECT n FROM ng) > 0
     AND count(c.band_getin) = (SELECT n FROM ng);  -- comparable pair in EVERY home game
$fn$;

-- ----------------------------------------------------------------------------
-- 3. Summary: aggregate the per-seat rows into one verdict row for a package.
--    Always returns exactly one row (seats_valued=0 => NO_DATA / NULLs).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stpv_summary(
  p_pkg_event_id bigint,
  p_row_band     int DEFAULT 5
)
RETURNS TABLE (
  home_games        int,
  seats_valued      int,
  pkg_ask_med       numeric,
  comp_getin_med    numeric,
  comp_vwap_med     numeric,
  med_savings_getin numeric,
  med_savings_vwap  numeric,
  pct_cheaper_getin numeric,
  pct_cheaper_vwap  numeric,
  verdict           text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  WITH r AS (SELECT * FROM public.stpv_seat_rows(p_pkg_event_id, p_row_band)),
  agg AS (
    SELECT
      coalesce(max(home_games), 0)                                                          AS home_games,
      count(*)::int                                                                         AS seats_valued,
      round(percentile_cont(0.5) WITHIN GROUP (ORDER BY pkg_price)::numeric, 2)             AS pkg_ask_med,
      round(percentile_cont(0.5) WITHIN GROUP (ORDER BY season_getin)::numeric, 2)          AS comp_getin_med,
      round(percentile_cont(0.5) WITHIN GROUP (ORDER BY season_vwap)::numeric, 2)           AS comp_vwap_med,
      round(percentile_cont(0.5) WITHIN GROUP (ORDER BY season_getin - pkg_price)::numeric, 2) AS med_savings_getin,
      round(percentile_cont(0.5) WITHIN GROUP (ORDER BY season_vwap  - pkg_price)::numeric, 2) AS med_savings_vwap,
      round(100.0 * sum(quantity * (pkg_price < season_getin)::int) / nullif(sum(quantity), 0), 1) AS pct_cheaper_getin,
      round(100.0 * sum(quantity * (pkg_price < season_vwap)::int)  / nullif(sum(quantity), 0), 1) AS pct_cheaper_vwap
    FROM r
  )
  SELECT home_games, seats_valued, pkg_ask_med, comp_getin_med, comp_vwap_med,
         med_savings_getin, med_savings_vwap, pct_cheaper_getin, pct_cheaper_vwap,
         CASE
           WHEN seats_valued = 0             THEN 'NO_DATA'
           WHEN pct_cheaper_vwap >= 60       THEN 'BUY'
           WHEN pct_cheaper_vwap >= 35       THEN 'FAIR'
           ELSE 'SKIP'
         END AS verdict
  FROM agg;
$fn$;

-- ----------------------------------------------------------------------------
-- 4. RPC: live per-package valuation (summary + per-seat drill-down). Email-gated.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_season_ticket_value(
  p_pkg_event_id bigint,
  p_row_band     int DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $fn$
DECLARE
  v_email text := coalesce(auth.jwt() ->> 'email', '');
  v_out   jsonb;
BEGIN
  -- Server path: called via the service-role client behind the require_auth
  -- route gate (already @s4kent.com-enforced). Direct client path (Path C):
  -- gate on the caller's own @s4kent.com email.
  IF NOT (current_user IN ('service_role', 'postgres', 'supabase_admin')
          OR v_email LIKE '%@s4kent.com') THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'event', jsonb_build_object(
      'pkg_event_id', ev.id,
      'name',         ev.name,
      'league',       x.espn_league,
      'team',         ev.primary_performer_name,
      'venue_name',   ev.venue_name,
      'event_date',   ev.occurs_at_local
    ),
    'params',  jsonb_build_object('row_band', p_row_band),
    'summary', to_jsonb(s),
    'seats', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'section',        r.section,
               'row',            r.row_i,
               'pkg_ask',        r.pkg_price,
               'quantity',       r.quantity,
               'season_getin',   round(r.season_getin, 2),
               'season_vwap',    round(r.season_vwap, 2),
               'savings_getin',  round(r.season_getin - r.pkg_price, 2),
               'savings_vwap',   round(r.season_vwap  - r.pkg_price, 2)
             ) ORDER BY (r.season_vwap - r.pkg_price) DESC)
      FROM public.stpv_seat_rows(p_pkg_event_id, p_row_band) r
    ), '[]'::jsonb)
  )
  INTO v_out
  FROM public.events ev
  LEFT JOIN public.performer_espn_team_xref x ON x.tevo_performer_id = ev.primary_performer_id
  CROSS JOIN LATERAL public.stpv_summary(p_pkg_event_id, p_row_band) s
  WHERE ev.id = p_pkg_event_id;

  RETURN coalesce(v_out, jsonb_build_object('error', 'not_found', 'pkg_event_id', p_pkg_event_id));
END;
$fn$;

-- ----------------------------------------------------------------------------
-- 5. RPC: league leaderboard from the daily table. Email-gated.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_season_ticket_leaderboard()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $fn$
DECLARE
  v_email text := coalesce(auth.jwt() ->> 'email', '');
  v_out   jsonb;
BEGIN
  IF NOT (current_user IN ('service_role', 'postgres', 'supabase_admin')
          OR v_email LIKE '%@s4kent.com') THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY
           CASE t.verdict WHEN 'BUY' THEN 0 WHEN 'FAIR' THEN 1 WHEN 'SKIP' THEN 2 ELSE 3 END,
           t.pct_cheaper_vwap DESC NULLS LAST), '[]'::jsonb)
  INTO v_out
  FROM public.season_ticket_package_value t;

  RETURN jsonb_build_object(
    'packages',    v_out,
    'computed_at', (SELECT max(computed_at) FROM public.season_ticket_package_value)
  );
END;
$fn$;

-- ----------------------------------------------------------------------------
-- 6. Refresh: rebuild the leaderboard table for MAJOR-league packages. Service-only.
--    p_only lets a test/branch run scope to specific package ids.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_season_ticket_package_values(
  p_row_band       int      DEFAULT 5,
  p_only           bigint[] DEFAULT NULL,
  p_budget_seconds int      DEFAULT 300
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_start timestamptz := clock_timestamp();
  v_n     int := 0;
  rec     record;
  s       record;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: refresh_season_ticket_package_values is service-only' USING ERRCODE = '42501';
  END IF;

  FOR rec IN
    SELECT e.id AS pkg_id, x.espn_league AS league,
           e.primary_performer_name AS team, e.venue_name, e.occurs_at_local
    FROM public.events e
    JOIN public.performer_espn_team_xref x ON x.tevo_performer_id = e.primary_performer_id
    WHERE e.name ~* 'season ticket' AND e.name !~* 'parking'
      AND e.event_type = 'game' AND e.venue_id IS NOT NULL AND e.state = 'shown'
      AND x.espn_league IN ('NFL', 'NBA', 'MLB', 'NHL', 'MLS')   -- STPV_MAJOR_LEAGUES
      AND (p_only IS NULL OR e.id = ANY(p_only))
  LOOP
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_seconds);

    SELECT * INTO s FROM public.stpv_summary(rec.pkg_id, p_row_band);
    IF s.seats_valued IS NULL OR s.seats_valued = 0 THEN
      CONTINUE;  -- no valuable comparable coverage yet (e.g. schedule not loaded)
    END IF;

    INSERT INTO public.season_ticket_package_value AS t (
      pkg_event_id, league, team, venue_name, event_date, home_games, seats_valued,
      pkg_ask_med, comp_getin_med, comp_vwap_med, med_savings_getin, med_savings_vwap,
      pct_cheaper_getin, pct_cheaper_vwap, verdict, row_band, computed_at, updated_at, meta
    ) VALUES (
      rec.pkg_id, rec.league, rec.team, rec.venue_name, rec.occurs_at_local, s.home_games, s.seats_valued,
      s.pkg_ask_med, s.comp_getin_med, s.comp_vwap_med, s.med_savings_getin, s.med_savings_vwap,
      s.pct_cheaper_getin, s.pct_cheaper_vwap, s.verdict, p_row_band, now(), now(),
      jsonb_build_object('source', 'refresh_season_ticket_package_values')
    )
    ON CONFLICT (pkg_event_id) DO UPDATE SET
      league            = EXCLUDED.league,
      team              = EXCLUDED.team,
      venue_name        = EXCLUDED.venue_name,
      event_date        = EXCLUDED.event_date,
      home_games        = EXCLUDED.home_games,
      seats_valued      = EXCLUDED.seats_valued,
      pkg_ask_med       = EXCLUDED.pkg_ask_med,
      comp_getin_med    = EXCLUDED.comp_getin_med,
      comp_vwap_med     = EXCLUDED.comp_vwap_med,
      med_savings_getin = EXCLUDED.med_savings_getin,
      med_savings_vwap  = EXCLUDED.med_savings_vwap,
      pct_cheaper_getin = EXCLUDED.pct_cheaper_getin,
      pct_cheaper_vwap  = EXCLUDED.pct_cheaper_vwap,
      verdict           = EXCLUDED.verdict,
      row_band          = EXCLUDED.row_band,
      computed_at       = now(),
      updated_at        = now();

    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$fn$;

-- ----------------------------------------------------------------------------
-- 7. Grants
-- ----------------------------------------------------------------------------
-- Engine + refresh: internal / service only (SECDEF RPCs call them as owner).
REVOKE ALL ON FUNCTION public.stpv_seat_rows(bigint, int)                              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.stpv_summary(bigint, int)                                FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_season_ticket_package_values(int, bigint[], int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.stpv_seat_rows(bigint, int)                              TO service_role;
GRANT  EXECUTE ON FUNCTION public.stpv_summary(bigint, int)                                TO service_role;
GRANT  EXECUTE ON FUNCTION public.refresh_season_ticket_package_values(int, bigint[], int) TO service_role;

-- Frontend RPCs: anon/authenticated, self-gated on @s4kent.com email inside the body.
REVOKE ALL ON FUNCTION public.get_season_ticket_value(bigint, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_season_ticket_leaderboard()      FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_season_ticket_value(bigint, int) TO anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_season_ticket_leaderboard()      TO anon, authenticated;

COMMENT ON FUNCTION public.get_season_ticket_value(bigint, int) IS
  'D0 broker: live season-ticket package valuation (pkg ask vs comparable game-by-game cost, same section + row +/- band, pair-sellable, getin & VWAP baselines). Email-gated to @s4kent.com.';
COMMENT ON FUNCTION public.get_season_ticket_leaderboard() IS
  'D0 broker: major-league season-ticket package leaderboard from season_ticket_package_value (daily). Email-gated to @s4kent.com.';

-- ----------------------------------------------------------------------------
-- 8. Daily cron — leak-proof BEGIN; SET LOCAL; DO; COMMIT wrapper + gate + policy row
--    (mirrors venue_section_rollup_hourly; depends on the 20260708042000 gate-clamp fix)
-- ----------------------------------------------------------------------------
SELECT cron.schedule(
  'stpv_refresh_daily',
  '40 9 * * *',                                   -- 09:40 UTC, off the :00/:02/:05 stampede
  $cron$BEGIN; SET LOCAL statement_timeout='600s'; DO $b$ BEGIN
    IF NOT public.cron_should_fire('stpv_refresh_daily') THEN RETURN; END IF;
    PERFORM public.refresh_season_ticket_package_values(5, NULL, 500);
  END $b$; COMMIT;$cron$
);

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, work_check_sql, enabled, notes)
VALUES ('stpv_refresh_daily', ARRAY[]::int[], 1440, 1440, 1, 'SELECT true', true,
  'D0 season-ticket package value leaderboard; daily full rebuild for major-league packages')
ON CONFLICT (jobname) DO UPDATE
  SET enabled = true, notes = EXCLUDED.notes, updated_at = now();
