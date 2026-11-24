-- Migration 20261116160000 · level:feature · lane:A1 (data plane — ML training data) · writes:ml_team_config(new),ml_knicks_games(+team_key),ml_knicks_sales(+team_key),ml_knicks_catalog_tick(),v_ml_knicks_sales_train,v_ml_knicks_sales_playoff,v_ml_knicks_predict_input,v_ml_knicks_form_train,v_ml_knicks_form_predict,v_ml_price_latest(new) · reads:sg_events_canonical,aq_event_map,seatgeek_orders,seatgeek_sales_snapshots,seatdata_sales_snapshots,zone_metrics,event_listing_snapshot_daily,performer_metrics_daily,performer_zones,espn_* · pre:20261028210040
--
-- The NBA price model, by team: the Knicks pipeline now also collects and serves the Philadelphia 76ers
-- (operator 2026-11-16: "expand with another performer with sales volume we can use" → "generalize by
-- team"). The 76ers had the most home-game SeatGeek sales of any NBA team (5,264 vs the Knicks' 3,695 on
-- 2026-11-16), curated zones at Xfinity Mobile Arena (venue 499), daily zone and listing snapshots on all
-- 40 home games, and a daily home-price history (performer_metrics_daily) for the model's fallback anchor.
--
-- WHAT CHANGES
--   · ml_team_config: one row per team (name as it appears in "<opponent> at <team>", home venue pattern,
--     TEvo performer id, ESPN NBA team id, time zone, model name). Adding a team later is one row.
--   · ml_knicks_games / ml_knicks_sales gain team_key. Existing rows are the Knicks ('knicks'). The table
--     names stay (renaming would break the cron and the training script mid-season); they now hold every
--     configured team.
--   · ml_knicks_catalog_tick (cron ml_knicks_catalog_offpeak, unchanged) registers each active team's home
--     games and catalogs their sales with that team's performer id, curated-zone venue and time zone. For
--     the Knicks it does exactly what it did (same name pattern, venue, pin performer and time zone).
--   · The training / prediction / form views gain a team_key column (appended; existing columns
--     unchanged) and take the team's performer and ESPN id from ml_team_config instead of the Knicks pin.
--   · v_ml_price_latest: the latest ok run's predictions for every team's model.
-- The tables, the collector and v_ml_knicks_sales_train / _playoff were created on prod without a
-- migration; their definitions are now in the repo (CREATE ... IF NOT EXISTS, so a re-apply is a no-op).
-- Nothing upstream is called. The training script takes --team (default knicks) — same PR.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ---------------------------------------------------------------------------
-- 1. teams
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ml_team_config (
  team_key      text PRIMARY KEY CHECK (team_key ~ '^[a-z0-9_]+$'),
  team_name     text NOT NULL UNIQUE,     -- as in "<opponent> at <team_name>"
  venue_regex   text NOT NULL,            -- home venue, case-insensitive
  performer_id  bigint NOT NULL,          -- TEvo performer (zones, performer_metrics_daily)
  espn_team_id  text,                     -- ESPN NBA team id (form features)
  tz            text NOT NULL DEFAULT 'America/New_York',
  model         text NOT NULL UNIQUE,     -- ml_model_runs.model
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.ml_team_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ml_team_config FROM anon, authenticated;
GRANT SELECT ON public.ml_team_config TO service_role;

INSERT INTO public.ml_team_config (team_key, team_name, venue_regex, performer_id, espn_team_id, tz, model)
VALUES ('knicks', 'New York Knicks',    'madison square',                       16303, '18', 'America/New_York', 'knicks_price_ridge_v1'),
       ('sixers', 'Philadelphia 76ers', 'xfinity mobile arena|wells fargo center', 16304, '20', 'America/New_York', 'sixers_price_ridge_v1')
ON CONFLICT (team_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. the tables (prod-only until now) + team_key
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ml_knicks_games (
  sg_event_id    bigint PRIMARY KEY,
  tevo_event_id  bigint,
  sd_event_id    bigint,
  event_name     text,
  opponent       text,
  season         text,
  game_type      text CHECK (game_type = ANY (ARRAY['preseason', 'regular', 'cup', 'playoff'])),
  occurs_at      timestamptz,
  occurs_at_tevo timestamptz,
  tip_diff_min   integer,
  name_source    text,
  updated_at     timestamptz
);
CREATE INDEX IF NOT EXISTS ml_knicks_games_tevo_idx ON public.ml_knicks_games (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.ml_knicks_sales (
  source text CHECK (source = ANY (ARRAY['seatgeek', 'seatdata'])),
  sale_key text,
  sg_event_id bigint REFERENCES public.ml_knicks_games (sg_event_id),
  tevo_event_id bigint, season text, game_type text,
  is_regular_season boolean GENERATED ALWAYS AS (game_type = ANY (ARRAY['regular', 'cup'])) STORED,
  opponent text, occurs_at timestamptz, sale_at timestamptz, hours_to_event numeric, days_to_event integer,
  price numeric, quantity integer, section text, row_label text, level text, row_band text,
  zone text, zone_source text, sd_zone text, stock_type text, delivery_method text, is_instant boolean,
  ctx_snapshot_date date, ctx_evo_getin numeric, ctx_evo_median numeric, ctx_evo_tickets integer,
  ctx_owned_share numeric, ctx_sg_getin numeric, ctx_sg_median numeric,
  ctx_zone_getin numeric, ctx_zone_p25 numeric, ctx_zone_median numeric, ctx_zone_tickets integer,
  ctx_zone_owned_share numeric, ctx_zone_at timestamptz,
  ctx_perf_home_getin numeric, ctx_perf_home_median numeric, ctx_perf_home_games integer,
  ctx_stale boolean DEFAULT true, cataloged_at timestamptz DEFAULT now(),
  PRIMARY KEY (source, sale_key)
);
CREATE INDEX IF NOT EXISTS ml_knicks_sales_game_idx  ON public.ml_knicks_sales (sg_event_id, sale_at);
CREATE INDEX IF NOT EXISTS ml_knicks_sales_zone_idx  ON public.ml_knicks_sales (zone, days_to_event);
CREATE INDEX IF NOT EXISTS ml_knicks_sales_train_idx ON public.ml_knicks_sales (is_regular_season, season, level, days_to_event);

CREATE TABLE IF NOT EXISTS public.ml_knicks_catalog_state (
  source text, sg_event_id bigint, last_source_id bigint, rows_upserted bigint, last_run_at timestamptz,
  PRIMARY KEY (source, sg_event_id)
);

ALTER TABLE public.ml_knicks_games ADD COLUMN IF NOT EXISTS team_key text NOT NULL DEFAULT 'knicks';
ALTER TABLE public.ml_knicks_sales ADD COLUMN IF NOT EXISTS team_key text NOT NULL DEFAULT 'knicks';
-- existing rows are the Knicks; new rows must say whose they are
ALTER TABLE public.ml_knicks_games ALTER COLUMN team_key DROP DEFAULT;
ALTER TABLE public.ml_knicks_sales ALTER COLUMN team_key DROP DEFAULT;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ml_knicks_games_team_fk') THEN
    ALTER TABLE public.ml_knicks_games ADD CONSTRAINT ml_knicks_games_team_fk
      FOREIGN KEY (team_key) REFERENCES public.ml_team_config (team_key);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ml_knicks_sales_team_idx ON public.ml_knicks_sales (team_key, sale_at);

ALTER TABLE public.ml_knicks_games ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ml_knicks_sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ml_knicks_catalog_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ml_knicks_games, public.ml_knicks_sales, public.ml_knicks_catalog_state FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. the collector, for every active team
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ml_knicks_catalog_tick(p_budget_seconds integer DEFAULT 240)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start     timestamptz := clock_timestamp();
  g           RECORD;
  c           RECORD;
  v_games     integer := 0;
  v_sg_rows   integer := 0;
  v_sd_rows   integer := 0;
  v_n         integer;
  v_max_id    bigint;
  v_done      integer := 0;
  v_caller    text;
BEGIN
  v_caller := CASE WHEN coalesce(current_setting('role', true), 'none') IN ('', 'none')
                   THEN session_user::text ELSE current_setting('role', true) END;
  IF v_caller NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: ml_knicks_catalog_tick is service-only (caller %)', v_caller USING ERRCODE = '42501';
  END IF;
  IF public.is_peak() THEN
    RETURN jsonb_build_object('skipped', 'peak_hours');
  END IF;

  -- 1. each team's home-game registry
  FOR c IN SELECT * FROM public.ml_team_config WHERE active ORDER BY team_key LOOP
    WITH named AS (
      SELECT cn.sg_event_id, cn.tevo_event_id, NULL::bigint AS sd_event_id, cn.sg_event_name AS nm,
             cn.sg_datetime_utc AS occ, 'canonical' AS src, 1 AS pri
        FROM public.sg_events_canonical cn
       WHERE cn.sg_event_name ~* ('at ' || c.team_name) AND cn.sg_venue_name ~* c.venue_regex
      UNION ALL
      SELECT a.sg_event_id::bigint, a.tevo_event_id::bigint, a.sd_event_id::bigint, a.event_name,
             a.event_date AT TIME ZONE c.tz, 'aq_event_map', 2
        FROM public.aq_event_map a
       WHERE a.event_name ~* ('at ' || c.team_name) AND a.venue_name ~* c.venue_regex
         AND a.sg_event_id IS NOT NULL AND a.sg_event_id::text ~ '^\d+$'
      UNION ALL
      SELECT o.sg_event_id::bigint, o.tevo_event_id::bigint, NULL, o.sg_event_name,
             (o.sg_event_date + time '19:30') AT TIME ZONE c.tz, 'seatgeek_orders', 3
        FROM public.seatgeek_orders o
       WHERE o.sg_event_name ~* ('at ' || c.team_name) AND coalesce(o.sg_venue, '') ~* c.venue_regex
         AND o.sg_event_id IS NOT NULL
    ),
    best AS (
      SELECT DISTINCT ON (sg_event_id)
             sg_event_id,
             (SELECT max(n2.tevo_event_id) FROM named n2 WHERE n2.sg_event_id = n.sg_event_id) AS tevo_event_id,
             (SELECT max(n2.sd_event_id)   FROM named n2 WHERE n2.sg_event_id = n.sg_event_id) AS sd_event_id,
             btrim(regexp_replace(nm, '^ZZ-DUP \([^)]*\)\s*[—-]\s*', '')) AS nm,
             (SELECT n2.occ FROM named n2 WHERE n2.sg_event_id = n.sg_event_id AND n2.occ IS NOT NULL
               ORDER BY n2.pri LIMIT 1) AS occ,
             src
        FROM named n
       WHERE nm !~* 'parking'
       ORDER BY sg_event_id, pri
    )
    INSERT INTO public.ml_knicks_games AS t
      (sg_event_id, team_key, tevo_event_id, sd_event_id, event_name, opponent, season, game_type, occurs_at,
       occurs_at_tevo, tip_diff_min, name_source, updated_at)
    SELECT b.sg_event_id, c.team_key, b.tevo_event_id, b.sd_event_id, b.nm,
           nullif(btrim(regexp_replace(regexp_replace(b.nm, '\s+at ' || c.team_name || '.*$', '', 'i'),
                                       '^(NBA Preseason|Emirates NBA Cup( Quarterfinals| Semifinals)?)\s*-\s*', '', 'i')), 'TBD'),
           CASE WHEN extract(month FROM b.occ) >= 7
                THEN extract(year FROM b.occ)::int || '-' || lpad(((extract(year FROM b.occ)::int + 1) % 100)::text, 2, '0')
                ELSE (extract(year FROM b.occ)::int - 1) || '-' || lpad((extract(year FROM b.occ)::int % 100)::text, 2, '0') END,
           CASE WHEN b.nm ~* 'preseason' THEN 'preseason'
                WHEN b.nm ~* '(game \d|round \d|finals|play-?in|conference|if necessary|home game \d)' THEN 'playoff'
                WHEN b.nm ~* 'nba cup' THEN 'cup'
                ELSE 'regular' END,
           b.occ, te.t, round(abs(extract(epoch FROM b.occ - te.t)) / 60)::int, b.src, now()
      FROM best b
      LEFT JOIN LATERAL (SELECT e.occurs_at_local::timestamptz AS t FROM public.events e
                          WHERE e.id = b.tevo_event_id AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT') te ON true
     WHERE b.occ IS NOT NULL
    ON CONFLICT (sg_event_id) DO UPDATE SET
      tevo_event_id = coalesce(EXCLUDED.tevo_event_id, t.tevo_event_id),
      sd_event_id   = coalesce(EXCLUDED.sd_event_id, t.sd_event_id),
      event_name    = EXCLUDED.event_name,
      opponent      = EXCLUDED.opponent,
      season        = EXCLUDED.season,
      game_type     = EXCLUDED.game_type,
      occurs_at     = EXCLUDED.occurs_at,
      occurs_at_tevo = coalesce(EXCLUDED.occurs_at_tevo, t.occurs_at_tevo),
      tip_diff_min  = coalesce(EXCLUDED.tip_diff_min, t.tip_diff_min),
      name_source   = EXCLUDED.name_source,
      updated_at    = now()
    WHERE t.team_key = EXCLUDED.team_key
      AND (t.tevo_event_id, t.sd_event_id, t.event_name, t.occurs_at, t.game_type, t.opponent, t.season, t.tip_diff_min)
          IS DISTINCT FROM (coalesce(EXCLUDED.tevo_event_id, t.tevo_event_id), coalesce(EXCLUDED.sd_event_id, t.sd_event_id),
                            EXCLUDED.event_name, EXCLUDED.occurs_at, EXCLUDED.game_type, EXCLUDED.opponent, EXCLUDED.season,
                            coalesce(EXCLUDED.tip_diff_min, t.tip_diff_min));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_games := v_games + v_n;
  END LOOP;

  UPDATE public.ml_knicks_sales s
     SET game_type = k.game_type, season = k.season, opponent = k.opponent, occurs_at = k.occurs_at,
         hours_to_event = round((extract(epoch FROM k.occurs_at - s.sale_at) / 3600.0)::numeric, 2),
         days_to_event  = floor(extract(epoch FROM k.occurs_at - s.sale_at) / 86400.0)::int
    FROM public.ml_knicks_games k
   WHERE k.sg_event_id = s.sg_event_id
     AND (s.game_type, s.season, s.opponent, s.occurs_at) IS DISTINCT FROM (k.game_type, k.season, k.opponent, k.occurs_at);

  -- 2. re-zone sales not yet on a curated zone, with each team's own curated venue
  UPDATE public.ml_knicks_sales s
     SET zone = z.zone, zone_source = z.src, level = public._ml_level_of(s.section)
    FROM (SELECT x.source, x.sale_key,
                 coalesce(public.n2s_zone_of(tv.performer_id, tv.venue_id, public._ml_section_clean(x.section), x.row_label),
                          public._ml_generic_zone(x.section)) AS zone,
                 CASE WHEN public.n2s_zone_of(tv.performer_id, tv.venue_id, public._ml_section_clean(x.section), x.row_label) IS NOT NULL THEN 'curated'
                      WHEN public._ml_generic_zone(x.section) IS NOT NULL THEN 'generic' END AS src
            FROM public.ml_knicks_sales x
            JOIN (SELECT tc.team_key, tc.performer_id,
                         (SELECT z.venue_id FROM public.performer_zones z
                           WHERE z.performer_id = tc.performer_id AND z.source = 'curated'
                           GROUP BY z.venue_id ORDER BY count(*) DESC LIMIT 1) AS venue_id
                    FROM public.ml_team_config tc) tv ON tv.team_key = x.team_key AND tv.venue_id IS NOT NULL
           WHERE x.zone_source IS DISTINCT FROM 'curated') z
   WHERE s.source = z.source AND s.sale_key = z.sale_key
     AND (s.zone, s.zone_source, s.level) IS DISTINCT FROM (z.zone, z.src, public._ml_level_of(s.section));

  -- 3. new sales, game by game (least recently scanned first), within the time budget
  FOR g IN
    SELECT k.*, coalesce(s1.last_source_id, 0) AS sg_wm, coalesce(s2.last_source_id, 0) AS sd_wm,
           tc.performer_id AS pid, tc.tz,
           (SELECT z.venue_id FROM public.performer_zones z
             WHERE z.performer_id = tc.performer_id AND z.source = 'curated'
             GROUP BY z.venue_id ORDER BY count(*) DESC LIMIT 1) AS venue
      FROM public.ml_knicks_games k
      JOIN public.ml_team_config tc ON tc.team_key = k.team_key AND tc.active
      LEFT JOIN public.ml_knicks_catalog_state s1 ON s1.source = 'seatgeek' AND s1.sg_event_id = k.sg_event_id
      LEFT JOIN public.ml_knicks_catalog_state s2 ON s2.source = 'seatdata' AND s2.sg_event_id = k.sg_event_id
     ORDER BY least(s1.last_run_at, s2.last_run_at) NULLS FIRST, k.occurs_at DESC
  LOOP
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_seconds);

    SELECT max(id + 0) INTO v_max_id FROM public.seatgeek_sales_snapshots
     WHERE sg_event_id = g.sg_event_id AND id + 0 > g.sg_wm;
    IF v_max_id IS NOT NULL THEN
      INSERT INTO public.ml_knicks_sales AS t
        (source, sale_key, team_key, sg_event_id, tevo_event_id, season, game_type, opponent, occurs_at, sale_at,
         hours_to_event, days_to_event, price, quantity, section, row_label, level, row_band,
         zone, zone_source, stock_type, delivery_method, is_instant,
         ctx_zone_getin, ctx_zone_p25, ctx_zone_median, ctx_zone_tickets, ctx_zone_owned_share, ctx_zone_at,
         ctx_snapshot_date, ctx_evo_getin, ctx_evo_median, ctx_evo_tickets, ctx_owned_share, ctx_sg_getin, ctx_sg_median,
         ctx_perf_home_getin, ctx_perf_home_median, ctx_perf_home_games, ctx_stale,
         cataloged_at)
      SELECT 'seatgeek', s.sg_sale_id::text, g.team_key, g.sg_event_id, g.tevo_event_id, g.season, g.game_type, g.opponent, g.occurs_at, s.sale_at_utc,
             round((extract(epoch FROM g.occurs_at - s.sale_at_utc) / 3600.0)::numeric, 2),
             floor(extract(epoch FROM g.occurs_at - s.sale_at_utc) / 86400.0)::int,
             s.broadcast_price, s.quantity, s.section, s.row,
             public._ml_level_of(s.section), public._ml_row_band(s.row),
             s.zone, s.zone_source, s.stock_type, s.delivery_method, s.is_instant,
             zc.getin_price, zc.retail_p25, zc.retail_median, zc.tickets_count, zc.owned_share, zc.captured_at,
             ctx.snapshot_date, ctx.eg, ctx.em, ctx.et, ctx.own_share, ctx.sgg, ctx.sgm,
             pf.getin_median, pf.price_median, pf.event_count,
             NOT EXISTS (SELECT 1 FROM public.event_metrics m
                          WHERE m.event_id = g.tevo_event_id
                            AND m.captured_at BETWEEN s.sale_at_utc - interval '36 hours' AND s.sale_at_utc + interval '12 hours'),
             now()
        FROM (SELECT d.*,
                     coalesce(d.cz, public._ml_generic_zone(d.section)) AS zone,
                     CASE WHEN d.cz IS NOT NULL THEN 'curated'
                          WHEN public._ml_generic_zone(d.section) IS NOT NULL THEN 'generic' END AS zone_source
                FROM (SELECT DISTINCT ON (x.sg_sale_id) x.*,
                             CASE WHEN g.venue IS NOT NULL THEN public.n2s_zone_of(g.pid, g.venue, public._ml_section_clean(x.section), x.row) END AS cz
                        FROM public.seatgeek_sales_snapshots x
                       WHERE x.sg_event_id = g.sg_event_id AND x.id + 0 > g.sg_wm AND x.id + 0 <= v_max_id
                         AND x.sg_sale_id IS NOT NULL AND x.broadcast_price > 0 AND x.sale_at_utc IS NOT NULL
                       ORDER BY x.sg_sale_id, x.pulled_at DESC) d) s
        LEFT JOIN LATERAL (
          SELECT zm.getin_price, zm.retail_p25, zm.retail_median, zm.tickets_count, zm.owned_share, zm.captured_at
            FROM public.zone_metrics zm
           WHERE zm.event_id = g.tevo_event_id AND zm.zone = s.zone
             AND zm.captured_at BETWEEN s.sale_at_utc - interval '36 hours' AND s.sale_at_utc
           ORDER BY zm.captured_at DESC LIMIT 1) zc ON g.tevo_event_id IS NOT NULL AND s.zone IS NOT NULL
        LEFT JOIN LATERAL (
          SELECT d.snapshot_date, avg(d.evo_retail_getin) eg, avg(d.evo_retail_median) em, avg(d.evo_tickets_count)::int et,
                 round(avg(d.evo_owned_tickets)::numeric / nullif(avg(d.evo_tickets_count), 0), 3) own_share,
                 avg(d.sg_all_getin) sgg, avg(d.sg_all_median) sgm
            FROM public.event_listing_snapshot_daily d
           WHERE d.event_id = g.tevo_event_id
             AND d.snapshot_date = (SELECT max(d2.snapshot_date) FROM public.event_listing_snapshot_daily d2
                                     WHERE d2.event_id = g.tevo_event_id
                                       AND d2.snapshot_date BETWEEN (s.sale_at_utc AT TIME ZONE g.tz)::date - 2
                                                                AND (s.sale_at_utc AT TIME ZONE g.tz)::date)
           GROUP BY d.snapshot_date) ctx ON g.tevo_event_id IS NOT NULL
        LEFT JOIN LATERAL (
          SELECT p.getin_median, p.price_median, p.event_count
            FROM public.performer_metrics_daily p
           WHERE p.performer_id = g.pid AND p.split = 'home'
             AND p.snapshot_date BETWEEN (s.sale_at_utc AT TIME ZONE g.tz)::date - 2
                                     AND (s.sale_at_utc AT TIME ZONE g.tz)::date
           ORDER BY p.snapshot_date DESC LIMIT 1) pf ON g.pid IS NOT NULL
      ON CONFLICT (source, sale_key) DO UPDATE SET
        price = EXCLUDED.price, quantity = EXCLUDED.quantity, sale_at = EXCLUDED.sale_at,
        hours_to_event = EXCLUDED.hours_to_event, days_to_event = EXCLUDED.days_to_event,
        occurs_at = EXCLUDED.occurs_at, zone = EXCLUDED.zone, zone_source = EXCLUDED.zone_source,
        ctx_zone_getin = EXCLUDED.ctx_zone_getin, ctx_zone_p25 = EXCLUDED.ctx_zone_p25,
        ctx_zone_median = EXCLUDED.ctx_zone_median, ctx_zone_tickets = EXCLUDED.ctx_zone_tickets,
        ctx_zone_owned_share = EXCLUDED.ctx_zone_owned_share, ctx_zone_at = EXCLUDED.ctx_zone_at,
        cataloged_at = now();
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_sg_rows := v_sg_rows + v_n;
      INSERT INTO public.ml_knicks_catalog_state (source, sg_event_id, last_source_id, rows_upserted, last_run_at)
      VALUES ('seatgeek', g.sg_event_id, v_max_id, v_n, now())
      ON CONFLICT (source, sg_event_id) DO UPDATE SET
        last_source_id = EXCLUDED.last_source_id,
        rows_upserted = public.ml_knicks_catalog_state.rows_upserted + EXCLUDED.rows_upserted,
        last_run_at = now();
    ELSE
      INSERT INTO public.ml_knicks_catalog_state (source, sg_event_id, last_run_at) VALUES ('seatgeek', g.sg_event_id, now())
      ON CONFLICT (source, sg_event_id) DO UPDATE SET last_run_at = now();
    END IF;

    IF g.tevo_event_id IS NOT NULL THEN
      SELECT max(id + 0) INTO v_max_id FROM public.seatdata_sales_snapshots
       WHERE tevo_event_id = g.tevo_event_id AND id + 0 > g.sd_wm;
      IF v_max_id IS NOT NULL THEN
        INSERT INTO public.ml_knicks_sales AS t
          (source, sale_key, team_key, sg_event_id, tevo_event_id, season, game_type, opponent, occurs_at, sale_at,
           hours_to_event, days_to_event, price, quantity, section, row_label, level, row_band, zone, zone_source, sd_zone,
           ctx_zone_getin, ctx_zone_p25, ctx_zone_median, ctx_zone_tickets, ctx_zone_owned_share, ctx_zone_at,
           ctx_perf_home_getin, ctx_perf_home_median, ctx_perf_home_games, ctx_stale, cataloged_at)
        SELECT 'seatdata', x.content_hash, g.team_key, g.sg_event_id, g.tevo_event_id, g.season, g.game_type, g.opponent, g.occurs_at, x.sale_timestamp,
               round((extract(epoch FROM g.occurs_at - x.sale_timestamp) / 3600.0)::numeric, 2),
               floor(extract(epoch FROM g.occurs_at - x.sale_timestamp) / 86400.0)::int,
               x.price, x.quantity, x.section, x.row,
               public._ml_level_of(x.section), public._ml_row_band(x.row), x.zone_resolved, x.zone_source, x.zone,
               zc.getin_price, zc.retail_p25, zc.retail_median, zc.tickets_count, zc.owned_share, zc.captured_at,
               pf.getin_median, pf.price_median, pf.event_count, true, now()
          FROM (SELECT y.*,
                       coalesce(y.cz, public._ml_generic_zone(y.section)) AS zone_resolved,
                       CASE WHEN y.cz IS NOT NULL THEN 'curated'
                            WHEN public._ml_generic_zone(y.section) IS NOT NULL THEN 'generic' END AS zone_source
                  FROM (SELECT x0.*, CASE WHEN g.venue IS NOT NULL THEN public.n2s_zone_of(g.pid, g.venue, public._ml_section_clean(x0.section), x0.row) END AS cz
                          FROM public.seatdata_sales_snapshots x0
                         WHERE x0.tevo_event_id = g.tevo_event_id AND x0.id + 0 > g.sd_wm AND x0.id + 0 <= v_max_id
                           AND x0.price > 0 AND x0.sale_timestamp IS NOT NULL AND x0.content_hash IS NOT NULL) y) x
          LEFT JOIN LATERAL (
            SELECT zm.getin_price, zm.retail_p25, zm.retail_median, zm.tickets_count, zm.owned_share, zm.captured_at
              FROM public.zone_metrics zm
             WHERE zm.event_id = g.tevo_event_id AND zm.zone = x.zone_resolved
               AND zm.captured_at BETWEEN x.sale_timestamp - interval '36 hours' AND x.sale_timestamp
             ORDER BY zm.captured_at DESC LIMIT 1) zc ON x.zone_resolved IS NOT NULL
          LEFT JOIN LATERAL (
            SELECT p.getin_median, p.price_median, p.event_count
              FROM public.performer_metrics_daily p
             WHERE p.performer_id = g.pid AND p.split = 'home'
               AND p.snapshot_date BETWEEN (x.sale_timestamp AT TIME ZONE g.tz)::date - 2
                                       AND (x.sale_timestamp AT TIME ZONE g.tz)::date
             ORDER BY p.snapshot_date DESC LIMIT 1) pf ON g.pid IS NOT NULL
        ON CONFLICT (source, sale_key) DO NOTHING;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_sd_rows := v_sd_rows + v_n;
        INSERT INTO public.ml_knicks_catalog_state (source, sg_event_id, last_source_id, rows_upserted, last_run_at)
        VALUES ('seatdata', g.sg_event_id, v_max_id, v_n, now())
        ON CONFLICT (source, sg_event_id) DO UPDATE SET
          last_source_id = EXCLUDED.last_source_id,
          rows_upserted = public.ml_knicks_catalog_state.rows_upserted + EXCLUDED.rows_upserted,
          last_run_at = now();
      ELSE
        INSERT INTO public.ml_knicks_catalog_state (source, sg_event_id, last_run_at) VALUES ('seatdata', g.sg_event_id, now())
        ON CONFLICT (source, sg_event_id) DO UPDATE SET last_run_at = now();
      END IF;
    END IF;

    v_done := v_done + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'games_registry_changed', v_games, 'games_processed', v_done,
    'seatgeek_rows', v_sg_rows, 'seatdata_rows', v_sd_rows,
    'seconds', round(extract(epoch FROM clock_timestamp() - v_start)::numeric, 1));
END $function$;
REVOKE ALL ON FUNCTION public.ml_knicks_catalog_tick(integer) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. views: + team_key (appended), team performer / ESPN id / time zone from ml_team_config
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_ml_knicks_sales_train
WITH (security_invoker = true) AS
SELECT s.source, s.sale_key, s.sg_event_id, s.tevo_event_id, s.season, s.game_type, s.is_regular_season,
       s.opponent, s.occurs_at, s.sale_at, s.hours_to_event, s.days_to_event, s.price, s.quantity,
       s.section, s.row_label, s.level, s.row_band, s.zone, s.zone_source, s.sd_zone, s.stock_type,
       s.delivery_method, s.is_instant, s.ctx_snapshot_date, s.ctx_evo_getin, s.ctx_evo_median,
       s.ctx_evo_tickets, s.ctx_owned_share, s.ctx_sg_getin, s.ctx_sg_median, s.ctx_zone_getin,
       s.ctx_zone_p25, s.ctx_zone_median, s.ctx_zone_tickets, s.ctx_zone_owned_share, s.ctx_zone_at,
       s.ctx_perf_home_getin, s.ctx_perf_home_median, s.ctx_perf_home_games, s.ctx_stale, s.cataloged_at,
       round(s.price / NULLIF(s.ctx_evo_median, 0::numeric), 3) AS price_vs_evo_median,
       round(s.price / NULLIF(s.ctx_evo_getin, 0::numeric), 3) AS price_vs_evo_getin,
       round(s.price / NULLIF(s.ctx_sg_median, 0::numeric), 3) AS price_vs_sg_median,
       round(s.price / NULLIF(s.ctx_perf_home_median, 0::numeric), 3) AS price_vs_knicks_home_median,
       round(s.price / NULLIF(s.ctx_zone_median, 0::numeric), 3) AS price_vs_zone_median,
       round(s.price / NULLIF(s.ctx_zone_getin, 0::numeric), 3) AS price_vs_zone_getin,
       round(s.price / NULLIF(s.ctx_zone_p25, 0::numeric), 3) AS price_vs_zone_p25,
       CASE WHEN s.hours_to_event < 0 THEN 'after_tip'
            WHEN s.hours_to_event < 6 THEN 'h0_6'
            WHEN s.hours_to_event < 24 THEN 'h6_24'
            WHEN s.hours_to_event < 72 THEN 'd1_3'
            WHEN s.hours_to_event < 168 THEN 'd3_7'
            WHEN s.hours_to_event < 336 THEN 'd7_14'
            WHEN s.hours_to_event < 720 THEN 'd14_30'
            ELSE 'd30p' END AS horizon_bucket,
       EXTRACT(isodow FROM (s.occurs_at AT TIME ZONE tc.tz))::integer AS game_dow,
       s.team_key
  FROM public.ml_knicks_sales s
  JOIN public.ml_knicks_games k ON k.sg_event_id = s.sg_event_id
  JOIN public.ml_team_config tc ON tc.team_key = s.team_key
 WHERE s.is_regular_season AND s.hours_to_event > -6 AND COALESCE(k.tip_diff_min, 0) <= 120;

CREATE OR REPLACE VIEW public.v_ml_knicks_sales_playoff
WITH (security_invoker = true) AS
SELECT s.source, s.sale_key, s.sg_event_id, s.tevo_event_id, s.season, s.game_type, s.is_regular_season,
       s.opponent, s.occurs_at, s.sale_at, s.hours_to_event, s.days_to_event, s.price, s.quantity,
       s.section, s.row_label, s.level, s.row_band, s.zone, s.zone_source, s.sd_zone, s.stock_type,
       s.delivery_method, s.is_instant, s.ctx_snapshot_date, s.ctx_evo_getin, s.ctx_evo_median,
       s.ctx_evo_tickets, s.ctx_owned_share, s.ctx_sg_getin, s.ctx_sg_median, s.ctx_zone_getin,
       s.ctx_zone_p25, s.ctx_zone_median, s.ctx_zone_tickets, s.ctx_zone_owned_share, s.ctx_zone_at,
       s.ctx_perf_home_getin, s.ctx_perf_home_median, s.ctx_perf_home_games, s.ctx_stale, s.cataloged_at,
       round(s.price / NULLIF(s.ctx_evo_median, 0::numeric), 3) AS price_vs_evo_median,
       round(s.price / NULLIF(s.ctx_evo_getin, 0::numeric), 3) AS price_vs_evo_getin,
       round(s.price / NULLIF(s.ctx_sg_median, 0::numeric), 3) AS price_vs_sg_median,
       round(s.price / NULLIF(s.ctx_perf_home_median, 0::numeric), 3) AS price_vs_knicks_home_median,
       round(s.price / NULLIF(s.ctx_zone_median, 0::numeric), 3) AS price_vs_zone_median,
       round(s.price / NULLIF(s.ctx_zone_getin, 0::numeric), 3) AS price_vs_zone_getin,
       round(s.price / NULLIF(s.ctx_zone_p25, 0::numeric), 3) AS price_vs_zone_p25,
       CASE WHEN s.hours_to_event < 0 THEN 'after_tip'
            WHEN s.hours_to_event < 6 THEN 'h0_6'
            WHEN s.hours_to_event < 24 THEN 'h6_24'
            WHEN s.hours_to_event < 72 THEN 'd1_3'
            WHEN s.hours_to_event < 168 THEN 'd3_7'
            WHEN s.hours_to_event < 336 THEN 'd7_14'
            WHEN s.hours_to_event < 720 THEN 'd14_30'
            ELSE 'd30p' END AS horizon_bucket,
       EXTRACT(isodow FROM (s.occurs_at AT TIME ZONE tc.tz))::integer AS game_dow,
       s.team_key
  FROM public.ml_knicks_sales s
  JOIN public.ml_knicks_games k ON k.sg_event_id = s.sg_event_id
  JOIN public.ml_team_config tc ON tc.team_key = s.team_key
 WHERE s.game_type = 'playoff' AND s.hours_to_event > -6 AND COALESCE(k.tip_diff_min, 0) <= 120;

CREATE OR REPLACE VIEW public.v_ml_knicks_predict_input
WITH (security_invoker = true) AS
SELECT g.sg_event_id, g.tevo_event_id, g.season, g.game_type, g.opponent, g.occurs_at,
       round((extract(epoch FROM g.occurs_at - now()) / 3600.0)::numeric, 2) AS hours_to_event,
       extract(isodow FROM g.occurs_at AT TIME ZONE tc.tz)::int AS game_dow,
       z.zone,
       z.getin_price   AS ctx_zone_getin,
       z.retail_p25    AS ctx_zone_p25,
       z.retail_median AS ctx_zone_median,
       z.tickets_count AS ctx_zone_tickets,
       z.owned_share   AS ctx_zone_owned_share,
       z.captured_at   AS ctx_zone_at,
       ctx.eg  AS ctx_evo_getin, ctx.em AS ctx_evo_median, ctx.sgg AS ctx_sg_getin, ctx.sgm AS ctx_sg_median,
       pf.getin_median AS ctx_perf_home_getin, pf.price_median AS ctx_perf_home_median,
       g.team_key
  FROM public.ml_knicks_games g
  JOIN public.ml_team_config tc ON tc.team_key = g.team_key
  JOIN LATERAL (
    SELECT DISTINCT ON (zm.zone) zm.zone, zm.getin_price, zm.retail_p25, zm.retail_median,
           zm.tickets_count, zm.owned_share, zm.captured_at
      FROM public.zone_metrics zm
     WHERE zm.event_id = g.tevo_event_id AND zm.captured_at > now() - interval '36 hours'
       AND zm.zone IS NOT NULL
     ORDER BY zm.zone, zm.captured_at DESC) z ON true
  LEFT JOIN LATERAL (
    SELECT avg(d.evo_retail_getin) eg, avg(d.evo_retail_median) em, avg(d.sg_all_getin) sgg, avg(d.sg_all_median) sgm
      FROM public.event_listing_snapshot_daily d
     WHERE d.event_id = g.tevo_event_id
       AND d.snapshot_date = (SELECT max(d2.snapshot_date) FROM public.event_listing_snapshot_daily d2
                               WHERE d2.event_id = g.tevo_event_id AND d2.snapshot_date >= current_date - 2)) ctx ON true
  LEFT JOIN LATERAL (
    SELECT p.getin_median, p.price_median
      FROM public.performer_metrics_daily p
     WHERE p.performer_id = tc.performer_id AND p.split = 'home' AND p.snapshot_date >= current_date - 2
     ORDER BY p.snapshot_date DESC LIMIT 1) pf ON true
 WHERE g.game_type IN ('regular', 'cup')
   AND g.occurs_at > now()
   AND g.tevo_event_id IS NOT NULL;

-- form: the columns keep their knicks_* names (the script reads them); they now mean "the home team"
CREATE OR REPLACE VIEW public.v_ml_knicks_form_train
WITH (security_invoker = true) AS
SELECT s.source, s.sale_key,
       kf.win_pct AS knicks_win_pct, kf.games AS knicks_games, kf.streak AS knicks_streak,
       public._ml_team_out(tc.espn_team_id, s.sale_at) AS knicks_out,
       ofm.win_pct AS opp_win_pct, ofm.games AS opp_games, ofm.streak AS opp_streak,
       CASE WHEN o.id IS NOT NULL THEN public._ml_team_out(o.id, s.sale_at) END AS opp_out,
       s.team_key
  FROM public.v_ml_knicks_sales_train s
  JOIN public.ml_team_config tc ON tc.team_key = s.team_key
  LEFT JOIN LATERAL (SELECT public._ml_nba_team_id(s.opponent) AS id) o ON true
  LEFT JOIN LATERAL public._ml_team_form(tc.espn_team_id, s.sale_at) kf ON true
  LEFT JOIN LATERAL public._ml_team_form(o.id, s.sale_at) ofm ON true;

CREATE OR REPLACE VIEW public.v_ml_knicks_form_predict
WITH (security_invoker = true) AS
WITH g AS (SELECT DISTINCT sg_event_id, opponent, team_key FROM public.v_ml_knicks_predict_input)
SELECT g.sg_event_id,
       kf.win_pct AS knicks_win_pct, kf.games AS knicks_games, kf.streak AS knicks_streak,
       public._ml_team_out(tc.espn_team_id, now()) AS knicks_out,
       ofm.win_pct AS opp_win_pct, ofm.games AS opp_games, ofm.streak AS opp_streak,
       CASE WHEN o.id IS NOT NULL THEN public._ml_team_out(o.id, now()) END AS opp_out,
       g.team_key
  FROM g
  JOIN public.ml_team_config tc ON tc.team_key = g.team_key
  LEFT JOIN LATERAL (SELECT public._ml_nba_team_id(g.opponent) AS id) o ON true
  LEFT JOIN LATERAL public._ml_team_form(tc.espn_team_id, now()) kf ON true
  LEFT JOIN LATERAL public._ml_team_form(o.id, now()) ofm ON true;

-- every team's latest ok run
CREATE OR REPLACE VIEW public.v_ml_price_latest
WITH (security_invoker = true) AS
SELECT tc.team_key, r.run_id, r.model, r.trained_at, p.sg_event_id, p.tevo_event_id, g.opponent, p.occurs_at,
       p.zone, p.predicted_price, p.p10, p.p90, p.ctx_zone_getin, p.ctx_zone_median,
       round(p.predicted_price / nullif(p.ctx_zone_getin, 0), 3) AS predicted_vs_zone_getin
  FROM public.ml_team_config tc
  JOIN public.ml_model_runs r
    ON r.run_id = (SELECT max(r2.run_id) FROM public.ml_model_runs r2 WHERE r2.model = tc.model AND r2.status = 'ok')
  JOIN public.ml_price_predictions p ON p.run_id = r.run_id
  LEFT JOIN public.ml_knicks_games g ON g.sg_event_id = p.sg_event_id;

REVOKE ALL ON public.v_ml_knicks_sales_train, public.v_ml_knicks_sales_playoff, public.v_ml_knicks_predict_input,
              public.v_ml_knicks_form_train, public.v_ml_knicks_form_predict, public.v_ml_price_latest
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_ml_knicks_sales_train, public.v_ml_knicks_sales_playoff, public.v_ml_knicks_predict_input,
                public.v_ml_knicks_form_train, public.v_ml_knicks_form_predict, public.v_ml_price_latest
  TO service_role;

-- the read-only analyst roles read every ml_* object today; the views are security_invoker, so they also
-- need the new config table (and the new view)
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['analyst_ro', 'coworker_readonly'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT SELECT ON public.ml_team_config, public.v_ml_price_latest, public.v_ml_knicks_sales_train,
                      public.v_ml_knicks_sales_playoff, public.v_ml_knicks_predict_input, public.v_ml_knicks_form_train,
                      public.v_ml_knicks_form_predict TO %I', r);
    END IF;
  END LOOP;
END $$;

COMMIT;

-- VERIFY:
--   SELECT team_key, count(*) FROM ml_knicks_games GROUP BY 1;              -- knicks unchanged; sixers after the next tick
--   SELECT team_key, count(*) FROM v_ml_knicks_sales_train GROUP BY 1;       -- knicks still 3,695 (2026-11-16)
--   SELECT public.ml_knicks_catalog_tick(240);                              -- off-peak only (is_peak)
-- ROLLBACK: the previous tick + views are in the prod history; team_key columns can stay (all 'knicks').
