-- Migration 20261023044000 · level:feature · lane:A1 (data plane — trend layer) · writes:player_game_price(new),player_price_effect(new),performer_sales_daily(new),build_player_price_effect(),build_player_price_effect_all(),build_performer_sales_daily(),v_cast_price_effect(new view),cron.job(2 new) · reads:espn_player_gamelog,espn_athletes,event_xref,events,event_listing_snapshot_daily,seatgeek_sales_snapshots,sg_events_canonical,gotickets_sales,gotickets_event,v_broadway_performer_getin · pre:20260705153500,20260911210000
--
-- ============================================================================
-- Migration 20261023044000 — player / cast value + performer sales trend layer
--
-- Lane:     A1. KANBAN A1-ML-1 phase 1 + A1-DATA-2 (operator 2026-10-23:
--           "build a player/cast sale average so we can see how much anyone
--           is worth in ticket price"; "long term trends between performers
--           and teams and players/cast" on the daily layer, not raw listings).
-- Touches:  player_game_price        (W: new fact — one row per athlete × team game
--                                        in the window: played?, T-1 price, residual)
--           player_price_effect      (W: new — one row per athlete: lift with vs
--                                        without, home/away, confidence)
--           performer_sales_daily    (W: new — per performer × day × source: sales,
--                                        tickets, median price, gross; indefinite)
--           build_player_price_effect(text,int) / build_player_price_effect_all()
--           build_performer_sales_daily(date,date)
--           v_cast_price_effect      (W: new view over v_broadway_performer_getin)
--           cron.job                 (W: player_price_effect_nightly 05:35 UTC,
--                                        performer_sales_daily_nightly 04:35 UTC)
--
-- METHOD (prototyped read-only on prod 2026-10-23, MLB 365 d):
--   price  = amalgam_median from event_listing_snapshot_daily at T-1 (latest
--            snapshot on or before the day before the game; falls back to
--            sg_all_median, evo_retail_median).
--   resid  = ln(price) − mean ln(price) over (team, home/away, month) — removes
--            the team's own level, the home/away gap and the season trend, so a
--            star who was hurt in April (cheap month) is not credited for May.
--   effect = exp(mean resid when played − mean resid when missed) − 1.
--   Naive played-vs-missed medians put Giancarlo Stanton at +230% (2 games
--   played, all in October); the residual version puts Shohei Ohtani first at
--   +38% (87 played / 22 missed) with Ryan McMahon +35%, Andy Pages +32% —
--   the plausible answer. Pitchers (SP/RP/P) and goalies (G in NHL) are
--   excluded: they play 1 in 5 by design, not by availability.
--   Thresholds: MLB/NBA/NHL/WNBA ≥ 20 played & ≥ 10 missed; NFL/NCAAF ≥ 6 & ≥ 3.
--   confidence: high ≥ 40/20 · medium ≥ 20/10 · low otherwise.
--   Cast: v_cast_price_effect = each cast run's median get-in vs the show's
--   median across runs (Oh, Mary!: Maya Rudolph +13%, Meg Stalter −13%).
--   Sales: performer_sales_daily attributes each SeatGeek sale (DISTINCT ON
--   sg_sale_id — the snapshot table re-inserts every poll) and GoTickets sale to
--   the event's primary performer (home team for games).
--
-- CAVEATS written into the row: NBA/NHL coverage is tiny until A1-DB-21 (ESPN
-- schedule 403) lands; `played` means "appeared in the box score", not
-- "started"; the T-1 price is the listing median, not realised sales — the
-- sales-side effect is a phase-2 column once performer_sales_daily has history.
--
-- PARTIALLY APPLIED to prod · via MCP 2026-10-23 19:30 UTC (operator-approved): both player
-- tables, v_cast_price_effect, performer_sales_daily + its builder and nightly cron.
-- build_player_price_effect / _all and the player cron are NOT applied (bodies contain
-- DELETE — SQL editor). The two round(double) bugs found on apply are fixed here.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Fact: athlete × team game
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.player_game_price (
  espn_league      text        NOT NULL,
  espn_athlete_id  text        NOT NULL,
  espn_event_id    text        NOT NULL,
  tevo_event_id    bigint      NOT NULL,
  team_abbr        text,
  home_away        text,
  game_day         date        NOT NULL,
  played           boolean     NOT NULL,
  med_t1           numeric,
  getin_t1         numeric,
  resid            numeric,
  built_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (espn_league, espn_athlete_id, espn_event_id)
);
CREATE INDEX IF NOT EXISTS player_game_price_event_idx ON public.player_game_price (tevo_event_id);
ALTER TABLE public.player_game_price ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.player_game_price FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.player_game_price TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Read layer: one row per athlete
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.player_price_effect (
  espn_league         text        NOT NULL,
  espn_athlete_id     text        NOT NULL,
  athlete_name        text,
  team_abbr           text,
  position_abbr       text,
  games_played        integer     NOT NULL,
  games_missed        integer     NOT NULL,
  med_played          numeric,
  med_missed          numeric,
  lift_pct            numeric,     -- naive median ratio, for reference
  lift_resid_pct      numeric,     -- THE number: residual-based effect
  home_lift_resid_pct numeric,
  away_lift_resid_pct numeric,
  confidence          text        NOT NULL,
  window_days         integer     NOT NULL,
  computed_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (espn_league, espn_athlete_id)
);
CREATE INDEX IF NOT EXISTS player_price_effect_lift_idx ON public.player_price_effect (espn_league, lift_resid_pct DESC);
ALTER TABLE public.player_price_effect ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.player_price_effect FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.player_price_effect TO service_role;

CREATE OR REPLACE FUNCTION public.build_player_price_effect(p_league text, p_days integer DEFAULT 365)
RETURNS TABLE(league text, fact_rows integer, athletes integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_min_played integer := CASE WHEN p_league IN ('NFL','NCAAF','CFL') THEN 6 ELSE 20 END;
  v_min_missed integer := CASE WHEN p_league IN ('NFL','NCAAF','CFL') THEN 3 ELSE 10 END;
  v_fact integer; v_ath integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: build_player_price_effect is service-only' USING ERRCODE='42501';
  END IF;

  DELETE FROM public.player_game_price WHERE espn_league = p_league;

  INSERT INTO public.player_game_price
    (espn_league, espn_athlete_id, espn_event_id, tevo_event_id, team_abbr, home_away, game_day, played, med_t1, getin_t1, resid)
  WITH games AS (
    SELECT DISTINCT gl.espn_event_id, gl.team_abbr, gl.home_away, x.tevo_event_id,
           left(e.occurs_at_local, 10)::date AS game_day
    FROM public.espn_player_gamelog gl
    JOIN public.event_xref x ON x.espn_event_id = gl.espn_event_id
    JOIN public.events e ON e.id = x.tevo_event_id
    WHERE gl.espn_league = p_league
      AND gl.game_date > current_date - p_days
      AND gl.espn_event_id <> 'none'
  ),
  px AS (
    SELECT g.*,
           d.med AS med_t1, d.getin AS getin_t1
    FROM games g
    LEFT JOIN LATERAL (
      SELECT coalesce(s.amalgam_median, s.sg_all_median, s.evo_retail_median) AS med,
             coalesce(s.amalgam_getin, s.sg_all_getin, s.evo_retail_getin)     AS getin
      FROM public.event_listing_snapshot_daily s
      WHERE s.event_id = g.tevo_event_id
        AND s.snapshot_date <= g.game_day - 1
        AND coalesce(s.amalgam_median, s.sg_all_median, s.evo_retail_median) > 0
      ORDER BY s.snapshot_date DESC, s.captured_at DESC
      LIMIT 1
    ) d ON true
  ),
  base AS (
    SELECT *,
           ln(med_t1) - avg(ln(med_t1)) OVER (PARTITION BY team_abbr, home_away, date_trunc('month', game_day)) AS resid
    FROM px WHERE med_t1 IS NOT NULL
  ),
  played AS (
    SELECT DISTINCT gl.espn_athlete_id, gl.team_abbr, gl.espn_event_id
    FROM public.espn_player_gamelog gl
    WHERE gl.espn_league = p_league AND gl.game_date > current_date - p_days AND gl.espn_event_id <> 'none'
  ),
  roster AS (
    SELECT espn_athlete_id, team_abbr
    FROM played GROUP BY 1, 2 HAVING count(*) >= v_min_played
  )
  SELECT p_league, r.espn_athlete_id, b.espn_event_id, b.tevo_event_id, b.team_abbr, b.home_away, b.game_day,
         (p.espn_athlete_id IS NOT NULL), b.med_t1, b.getin_t1, b.resid
  FROM roster r
  JOIN base b ON b.team_abbr = r.team_abbr
  LEFT JOIN played p ON p.espn_athlete_id = r.espn_athlete_id AND p.espn_event_id = b.espn_event_id;
  GET DIAGNOSTICS v_fact = ROW_COUNT;

  DELETE FROM public.player_price_effect WHERE espn_league = p_league;

  INSERT INTO public.player_price_effect
    (espn_league, espn_athlete_id, athlete_name, team_abbr, position_abbr, games_played, games_missed,
     med_played, med_missed, lift_pct, lift_resid_pct, home_lift_resid_pct, away_lift_resid_pct, confidence, window_days)
  WITH agg AS (
    SELECT f.espn_athlete_id, f.team_abbr,
           count(*) FILTER (WHERE f.played)     AS gp,
           count(*) FILTER (WHERE NOT f.played) AS gm,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY f.med_t1) FILTER (WHERE f.played)     AS med_p,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY f.med_t1) FILTER (WHERE NOT f.played) AS med_m,
           avg(f.resid) FILTER (WHERE f.played)     AS r_p,
           avg(f.resid) FILTER (WHERE NOT f.played) AS r_m,
           avg(f.resid) FILTER (WHERE f.played AND f.home_away = 'home')         AS rh_p,
           avg(f.resid) FILTER (WHERE NOT f.played AND f.home_away = 'home')     AS rh_m,
           avg(f.resid) FILTER (WHERE f.played AND f.home_away <> 'home')        AS ra_p,
           avg(f.resid) FILTER (WHERE NOT f.played AND f.home_away <> 'home')    AS ra_m
    FROM public.player_game_price f
    WHERE f.espn_league = p_league
    GROUP BY 1, 2
  )
  SELECT p_league, a.espn_athlete_id, coalesce(at.display_name, at.full_name), a.team_abbr, at.position_abbr,
         a.gp, a.gm,
         round(a.med_p::numeric, 2), round(a.med_m::numeric, 2),
         round(((a.med_p / nullif(a.med_m, 0)) - 1)::numeric * 100, 1),
         round((exp(a.r_p - a.r_m) - 1) * 100, 1),
         round((exp(a.rh_p - a.rh_m) - 1) * 100, 1),
         round((exp(a.ra_p - a.ra_m) - 1) * 100, 1),
         CASE WHEN a.gp >= 2 * v_min_played AND a.gm >= 2 * v_min_missed THEN 'high'
              WHEN a.gp >= v_min_played AND a.gm >= v_min_missed THEN 'medium'
              ELSE 'low' END,
         p_days
  FROM agg a
  LEFT JOIN public.espn_athletes at ON at.espn_athlete_id = a.espn_athlete_id AND at.espn_league = p_league
  WHERE a.gp >= v_min_played AND a.gm >= v_min_missed
    AND coalesce(at.position_abbr, '') NOT IN ('SP','RP','P')
    AND NOT (p_league = 'NHL' AND at.position_abbr = 'G');
  GET DIAGNOSTICS v_ath = ROW_COUNT;

  RETURN QUERY SELECT p_league, v_fact, v_ath;
END $$;

REVOKE ALL ON FUNCTION public.build_player_price_effect(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_player_price_effect(text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.build_player_price_effect_all(p_budget_seconds integer DEFAULT 240)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start timestamptz := clock_timestamp();
  v_lg text; v_out jsonb := '{}'::jsonb; v_r RECORD;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';
  END IF;
  FOREACH v_lg IN ARRAY ARRAY['MLB','NFL','WNBA','NBA','NHL','NCAAF'] LOOP
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_seconds);
    SELECT * INTO v_r FROM public.build_player_price_effect(v_lg, 365);
    v_out := v_out || jsonb_build_object(v_lg, jsonb_build_object('fact_rows', v_r.fact_rows, 'athletes', v_r.athletes));
  END LOOP;
  RETURN v_out;
END $$;

REVOKE ALL ON FUNCTION public.build_player_price_effect_all(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_player_price_effect_all(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Cast: per cast run vs the show's median across runs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_cast_price_effect
WITH (security_invoker = true) AS
WITH runs AS (
  SELECT * FROM public.v_broadway_performer_getin WHERE perfs_priced > 0
), base AS (
  SELECT show_slug, percentile_cont(0.5) WITHIN GROUP (ORDER BY median_getin) AS show_median_getin,
         count(*) AS runs_priced
  FROM runs GROUP BY 1
)
SELECT r.cast_run_id, r.show_slug, r.role, r.performer_name, r.engagement_seq, r.run_start, r.run_end,
       r.is_final_confirmed, r.confidence, r.perfs_priced, r.snapshot_rows,
       r.median_getin, r.avg_getin, r.min_getin, r.max_getin, r.closing_night_getin,
       round(b.show_median_getin::numeric, 2) AS show_median_getin,
       round((r.median_getin / nullif(b.show_median_getin::numeric, 0) - 1) * 100, 1) AS lift_pct,
       b.runs_priced,
       CASE WHEN r.perfs_priced >= 20 THEN 'high' WHEN r.perfs_priced >= 5 THEN 'medium' ELSE 'low' END AS confidence_level
FROM runs r JOIN base b USING (show_slug);

REVOKE ALL ON public.v_cast_price_effect FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_cast_price_effect TO service_role;

-- ---------------------------------------------------------------------------
-- 4. performer_sales_daily — the sold side of the trend layer (indefinite)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.performer_sales_daily (
  performer_id   bigint      NOT NULL,
  sale_day       date        NOT NULL,
  source         text        NOT NULL,          -- 'seatgeek' | 'gotickets'
  performer_name text,
  events         integer     NOT NULL,
  sales          integer     NOT NULL,
  tickets        integer     NOT NULL,
  median_price   numeric,
  p25_price      numeric,
  p75_price      numeric,
  gross          numeric,
  computed_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (performer_id, sale_day, source)
);
CREATE INDEX IF NOT EXISTS performer_sales_daily_day_idx ON public.performer_sales_daily (sale_day);
ALTER TABLE public.performer_sales_daily ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.performer_sales_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.performer_sales_daily TO service_role;

CREATE OR REPLACE FUNCTION public.build_performer_sales_daily(p_from date, p_to date DEFAULT current_date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: build_performer_sales_daily is service-only' USING ERRCODE='42501';
  END IF;

  INSERT INTO public.performer_sales_daily
    (performer_id, sale_day, source, performer_name, events, sales, tickets, median_price, p25_price, p75_price, gross, computed_at)
  WITH sg AS (
    SELECT DISTINCT ON (s.sg_sale_id) s.sg_sale_id, s.sg_event_id, s.sale_at_utc::date AS sale_day,
           s.broadcast_price AS price, coalesce(s.quantity, 1) AS qty
    FROM public.seatgeek_sales_snapshots s
    WHERE s.sale_at_utc >= p_from AND s.sale_at_utc < p_to + 1
      AND s.pulled_at >= p_from
    ORDER BY s.sg_sale_id, s.pulled_at DESC
  ),
  sg_j AS (
    SELECT 'seatgeek'::text AS source, e.primary_performer_id, e.primary_performer_name, e.id AS event_id, sg.sale_day, sg.price, sg.qty
    FROM sg JOIN public.sg_events_canonical c ON c.sg_event_id = sg.sg_event_id
    JOIN public.events e ON e.id = c.tevo_event_id
    WHERE e.primary_performer_id IS NOT NULL
  ),
  gt AS (
    SELECT DISTINCT ON (g.gt_sale_id) g.gt_sale_id, g.gt_event_id, coalesce(g.create_time, g.pulled_at)::date AS sale_day,
           CASE WHEN g.quantity > 0 AND g.total_payout IS NOT NULL THEN g.total_payout / g.quantity ELSE g.unit_cost END AS price,
           coalesce(g.quantity, 1) AS qty
    FROM public.gotickets_sales g
    WHERE coalesce(g.create_time, g.pulled_at) >= p_from AND coalesce(g.create_time, g.pulled_at) < p_to + 1
    ORDER BY g.gt_sale_id, g.pulled_at DESC
  ),
  gt_j AS (
    SELECT 'gotickets'::text AS source, e.primary_performer_id, e.primary_performer_name, e.id AS event_id, gt.sale_day, gt.price, gt.qty
    FROM gt JOIN public.gotickets_event ge ON ge.gt_event_id = gt.gt_event_id
    JOIN public.events e ON e.id = ge.tevo_event_id
    WHERE e.primary_performer_id IS NOT NULL
  ),
  u AS (SELECT * FROM sg_j UNION ALL SELECT * FROM gt_j)
  SELECT primary_performer_id, sale_day, source, max(primary_performer_name),
         count(DISTINCT event_id), count(*), sum(qty)::int,
         round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::numeric, 2),
         round(percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric, 2),
         round(percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric, 2),
         round(sum(price * qty)::numeric, 2), now()
  FROM u WHERE price IS NOT NULL
  GROUP BY 1, 2, 3
  ON CONFLICT (performer_id, sale_day, source) DO UPDATE SET
    performer_name = EXCLUDED.performer_name, events = EXCLUDED.events, sales = EXCLUDED.sales,
    tickets = EXCLUDED.tickets, median_price = EXCLUDED.median_price, p25_price = EXCLUDED.p25_price,
    p75_price = EXCLUDED.p75_price, gross = EXCLUDED.gross, computed_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.build_performer_sales_daily(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_performer_sales_daily(date, date) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Crons — single statements, free minutes (:35 at 04 and 05 UTC)
-- ---------------------------------------------------------------------------
SELECT cron.schedule('performer_sales_daily_nightly', '35 4 * * *',
  $c$SELECT public.build_performer_sales_daily(current_date - 3, current_date);$c$);
SELECT cron.schedule('player_price_effect_nightly', '35 5 * * *',
  $c$SELECT public.build_player_price_effect_all(240);$c$);

-- ============================================================================
-- FIRST FILL (operator, after apply; each is one statement, run from the SQL editor):
--   SELECT public.build_performer_sales_daily(current_date - 180, current_date);  -- ~minutes; SG sales go back to 05-09
--   SELECT public.build_player_price_effect_all(600);
-- VERIFY:
--   SELECT espn_league, count(*), max(lift_resid_pct) FROM public.player_price_effect GROUP BY 1;
--   SELECT athlete_name, team_abbr, games_played, games_missed, lift_resid_pct, confidence
--     FROM public.player_price_effect WHERE espn_league='MLB' ORDER BY lift_resid_pct DESC LIMIT 10;
--       -- expect Shohei Ohtani near the top (+38% in the 2026-10-23 prototype)
--   SELECT * FROM public.v_cast_price_effect;   -- Oh, Mary!: Rudolph +13, Stalter −13
--   SELECT performer_name, sum(gross) FROM public.performer_sales_daily WHERE sale_day > current_date-14 GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
-- ROLLBACK: cron.unschedule both; DROP the two tables, the view and the four fns (SQL editor).
-- ============================================================================
