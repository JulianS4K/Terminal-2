-- Migration 20260709150000 · lane:D0 (author) → A1 (apply) · writes:league_season,performer_stat_card(+7 cols),refresh_performer_stat_card · reads:performer_metrics_daily,events,event_listing_snapshot_daily,performer_espn_team_xref · pre:performer_stat_card (mig 20260709140000) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates a table + seed + alters a table + rewrites a refresh fn + backfills)
--
-- D0 — league season calendar + event-level metrics on the stat-card.
--
-- Adds to the performer stat-card:
--   * highest-median EVENT (a real game — season-ticket packages / parking are
--     excluded), tagged with its SEASON + PHASE (preseason / regular / playoff),
--   * median-of-medians across the performer's real events & sources.
--
-- Season/phase come from a new per-LEAGUE calendar (league_season) — season +
-- playoff + preseason start/end dates, seeded from Wikipedia's 2026 / 2026-27
-- schedules (editable rows; correct them as official dates firm up). Sports
-- performers bucket by their league's season window; non-sports (concerts /
-- Broadway) fall back to the event's calendar year.
--
-- The event-level pass is a second UPDATE inside refresh_performer_stat_card
-- (after the base upsert), over events ⋈ event_listing_snapshot_daily (latest
-- slot per event) ⋈ league. occurs_at_local is TEXT → regex-guarded cast (§3).

-- ============================================================
-- 1. Per-league season calendar (season + playoff + preseason)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.league_season (
  league          text NOT NULL,     -- UPPERCASE, matches performer_espn_team_xref.espn_league
  season_label    text NOT NULL,     -- '2026' | '2026-27'
  preseason_start date,
  preseason_end   date,
  regular_start   date NOT NULL,
  regular_end     date NOT NULL,
  playoff_start   date,
  playoff_end     date,
  PRIMARY KEY (league, season_label)
);
ALTER TABLE public.league_season ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.league_season FROM anon, authenticated;

-- Seed — current / upcoming season per major league (Wikipedia 2026 & 2026-27).
INSERT INTO public.league_season
  (league, season_label, preseason_start, preseason_end, regular_start, regular_end, playoff_start, playoff_end)
VALUES
  ('NFL', '2026',    '2026-08-13','2026-08-29','2026-09-09','2027-01-10','2027-01-16','2027-02-14'),
  ('NBA', '2026-27', '2026-10-09','2026-10-18','2026-10-20','2027-04-12','2027-04-14','2027-06-30'),
  ('MLB', '2026',    '2026-02-20','2026-03-24','2026-03-25','2026-09-27','2026-09-29','2026-11-05'),
  ('NHL', '2026-27', '2026-09-20','2026-09-28','2026-09-29','2027-04-12','2027-04-14','2027-06-30'),
  ('MLS', '2026',     NULL,        NULL,       '2026-02-21','2026-11-07','2026-11-18','2026-12-18')
ON CONFLICT (league, season_label) DO UPDATE SET
  preseason_start = EXCLUDED.preseason_start, preseason_end = EXCLUDED.preseason_end,
  regular_start = EXCLUDED.regular_start, regular_end = EXCLUDED.regular_end,
  playoff_start = EXCLUDED.playoff_start, playoff_end = EXCLUDED.playoff_end;

-- ============================================================
-- 2. New stat-card columns
-- ============================================================
ALTER TABLE public.performer_stat_card
  ADD COLUMN IF NOT EXISTS top_event_id        bigint,
  ADD COLUMN IF NOT EXISTS top_event_name      text,
  ADD COLUMN IF NOT EXISTS top_event_date      date,
  ADD COLUMN IF NOT EXISTS top_event_median    numeric,
  ADD COLUMN IF NOT EXISTS top_event_season    text,
  ADD COLUMN IF NOT EXISTS top_event_phase     text,
  ADD COLUMN IF NOT EXISTS median_median_price numeric;

-- ============================================================
-- 3. Refresh — base upsert (unchanged) + event-level second pass
-- ============================================================
CREATE OR REPLACE FUNCTION public.refresh_performer_stat_card()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  -- ---- base metrics (from the rolled-up daily) --------------------------------
  WITH anchor AS (
    SELECT performer_id, max(snapshot_date) AS as_of
    FROM public.performer_metrics_daily WHERE split = 'all' GROUP BY performer_id
  ),
  cur AS (
    SELECT p.* FROM public.performer_metrics_daily p
    JOIN anchor a ON a.performer_id = p.performer_id AND p.snapshot_date = a.as_of
    WHERE p.split = 'all'
  ),
  computed AS (
    SELECT
      c.performer_id, c.performer_name, c.snapshot_date AS as_of,
      (c.what_event_type = 'game') AS is_sports,
      c.event_count, c.getin_min, c.getin_median, c.price_median, c.price_p90,
      round(c.price_p90 / nullif(c.getin_median,0), 2) AS spread_ratio,
      (coalesce(c.evo_tickets_total,0) + coalesce(c.sg_all_tickets_total,0))::bigint AS market_tickets,
      (coalesce(c.evo_owned_tickets_total,0) + coalesce(c.sg_owned_tickets_total,0))::bigint AS owned_tickets,
      c.owned_book_notional,
      round(coalesce(c.evo_owned_tickets_total,0)::numeric / nullif(coalesce(c.evo_tickets_total,0),0), 4) AS owned_share,
      w7.price_median  AS price_median_7d, w30.price_median AS price_median_30d,
      round(((c.price_median  - w7.price_median)  / nullif(w7.price_median,0))  * 100, 1) AS price_d7_pct,
      round(((c.price_median  - w30.price_median) / nullif(w30.price_median,0)) * 100, 1) AS price_d30_pct,
      round(((c.getin_median  - w7.getin_median)  / nullif(w7.getin_median,0))  * 100, 1) AS getin_d7_pct,
      (coalesce(c.evo_owned_tickets_total,0) - coalesce(w30.evo_owned_tickets_total,0))::bigint AS owned_tickets_d30,
      h.price_median  AS home_price_median, aw.price_median AS away_price_median
    FROM cur c
    LEFT JOIN LATERAL (SELECT price_median, getin_median, evo_owned_tickets_total FROM public.performer_metrics_daily x
      WHERE x.performer_id = c.performer_id AND x.split='all' AND x.snapshot_date <= c.snapshot_date - 7  ORDER BY x.snapshot_date DESC LIMIT 1) w7 ON true
    LEFT JOIN LATERAL (SELECT price_median, getin_median, evo_owned_tickets_total FROM public.performer_metrics_daily x
      WHERE x.performer_id = c.performer_id AND x.split='all' AND x.snapshot_date <= c.snapshot_date - 30 ORDER BY x.snapshot_date DESC LIMIT 1) w30 ON true
    LEFT JOIN LATERAL (SELECT price_median FROM public.performer_metrics_daily x
      WHERE x.performer_id = c.performer_id AND x.split='home' AND x.snapshot_date = c.snapshot_date LIMIT 1) h ON true
    LEFT JOIN LATERAL (SELECT price_median FROM public.performer_metrics_daily x
      WHERE x.performer_id = c.performer_id AND x.split='away' AND x.snapshot_date = c.snapshot_date LIMIT 1) aw ON true
  )
  INSERT INTO public.performer_stat_card AS t (
    performer_id, performer_name, as_of, is_sports, event_count, getin_min, getin_median,
    price_median, price_p90, spread_ratio, market_tickets, owned_tickets, owned_book_notional,
    owned_share, price_median_7d, price_median_30d, price_d7_pct, price_d30_pct, getin_d7_pct,
    owned_tickets_d30, home_price_median, away_price_median, computed_at
  )
  SELECT performer_id, performer_name, as_of, is_sports, event_count, getin_min, getin_median,
    price_median, price_p90, spread_ratio, market_tickets, owned_tickets, owned_book_notional,
    owned_share, price_median_7d, price_median_30d, price_d7_pct, price_d30_pct, getin_d7_pct,
    owned_tickets_d30, home_price_median, away_price_median, now()
  FROM computed
  ON CONFLICT (performer_id) DO UPDATE SET
    performer_name = EXCLUDED.performer_name, as_of = EXCLUDED.as_of, is_sports = EXCLUDED.is_sports,
    event_count = EXCLUDED.event_count, getin_min = EXCLUDED.getin_min, getin_median = EXCLUDED.getin_median,
    price_median = EXCLUDED.price_median, price_p90 = EXCLUDED.price_p90, spread_ratio = EXCLUDED.spread_ratio,
    market_tickets = EXCLUDED.market_tickets, owned_tickets = EXCLUDED.owned_tickets,
    owned_book_notional = EXCLUDED.owned_book_notional, owned_share = EXCLUDED.owned_share,
    price_median_7d = EXCLUDED.price_median_7d, price_median_30d = EXCLUDED.price_median_30d,
    price_d7_pct = EXCLUDED.price_d7_pct, price_d30_pct = EXCLUDED.price_d30_pct, getin_d7_pct = EXCLUDED.getin_d7_pct,
    owned_tickets_d30 = EXCLUDED.owned_tickets_d30, home_price_median = EXCLUDED.home_price_median,
    away_price_median = EXCLUDED.away_price_median, computed_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- ---- event-level second pass: top-median real event + median-of-medians -----
  WITH eld AS (
    SELECT DISTINCT ON (event_id) event_id, amalgam_median
    FROM public.event_listing_snapshot_daily
    WHERE snapshot_date = (SELECT max(snapshot_date) FROM public.event_listing_snapshot_daily)
      AND amalgam_median IS NOT NULL
    ORDER BY event_id,
      CASE snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 WHEN 'morning' THEN 1 ELSE 0 END DESC
  ),
  plg AS (  -- one league per performer
    SELECT tevo_performer_id, max(espn_league) AS league
    FROM public.performer_espn_team_xref WHERE tevo_performer_id IS NOT NULL GROUP BY tevo_performer_id
  ),
  ev AS (  -- performer × event, real events only (drop season-ticket packages / parking)
    SELECT u.pid AS performer_id, e.id AS event_id, e.name,
           CASE WHEN e.occurs_at_local ~ '^\d{4}' THEN e.occurs_at_local::timestamptz::date END AS ev_date,
           d.amalgam_median
    FROM public.events e
    CROSS JOIN LATERAL unnest(e.performer_ids) AS u(pid)
    JOIN eld d ON d.event_id = e.id
    WHERE e.name IS NOT NULL
      AND e.name !~* '(season ticket|season plan|includes tickets to all|ticket package|parking|meet (and|&) greet|hospitality|suite)'
  ),
  evl AS (  -- attach league + season/phase (sports via league_season, else calendar year)
    SELECT ev.*, plg.league,
           coalesce(ls.season_label, to_char(ev.ev_date, 'YYYY')) AS season_label,
           CASE
             WHEN ls.preseason_start IS NOT NULL AND ev.ev_date BETWEEN ls.preseason_start AND ls.preseason_end THEN 'preseason'
             WHEN ev.ev_date BETWEEN ls.regular_start AND ls.regular_end THEN 'regular'
             WHEN ls.playoff_start IS NOT NULL AND ev.ev_date BETWEEN ls.playoff_start AND ls.playoff_end THEN 'playoff'
             ELSE NULL
           END AS phase
    FROM ev
    LEFT JOIN plg ON plg.tevo_performer_id = ev.performer_id
    LEFT JOIN public.league_season ls
      ON ls.league = plg.league
     AND ev.ev_date BETWEEN coalesce(ls.preseason_start, ls.regular_start) AND coalesce(ls.playoff_end, ls.regular_end)
  ),
  mm AS (
    SELECT performer_id, round(percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_median)::numeric, 2) AS median_median
    FROM evl GROUP BY performer_id
  ),
  top AS (
    SELECT DISTINCT ON (performer_id)
           performer_id, event_id, name, ev_date, round(amalgam_median::numeric,2) AS median, season_label, phase
    FROM evl ORDER BY performer_id, amalgam_median DESC NULLS LAST
  )
  UPDATE public.performer_stat_card t SET
    top_event_id = top.event_id, top_event_name = top.name, top_event_date = top.ev_date,
    top_event_median = top.median, top_event_season = top.season_label, top_event_phase = top.phase,
    median_median_price = mm.median_median
  FROM top LEFT JOIN mm ON mm.performer_id = top.performer_id
  WHERE t.performer_id = top.performer_id;

  -- clear stale event-level fields for performers with no current real event
  UPDATE public.performer_stat_card t SET
    top_event_id = NULL, top_event_name = NULL, top_event_date = NULL, top_event_median = NULL,
    top_event_season = NULL, top_event_phase = NULL, median_median_price = NULL
  WHERE t.top_event_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.events e
      JOIN public.event_listing_snapshot_daily d ON d.event_id = e.id
      WHERE t.performer_id = ANY(e.performer_ids)
        AND d.snapshot_date = (SELECT max(snapshot_date) FROM public.event_listing_snapshot_daily)
    );

  -- prune performers no longer present in the source
  DELETE FROM public.performer_stat_card t
  WHERE NOT EXISTS (SELECT 1 FROM public.performer_metrics_daily m
                    WHERE m.performer_id = t.performer_id AND m.split = 'all');

  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_performer_stat_card() FROM PUBLIC;

-- ============================================================
-- 4. Backfill now (single + compare RPCs already read to_jsonb(*), so the new
--    columns flow through automatically)
-- ============================================================
SELECT public.refresh_performer_stat_card();
