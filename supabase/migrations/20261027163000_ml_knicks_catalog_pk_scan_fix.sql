-- Migration 20261027163000 · level:ops · lane:A1 (data plane — ML training data) · writes:ml_knicks_catalog_tick()(replace) · reads:seatgeek_sales_snapshots,seatdata_sales_snapshots · pre:20261027010830 (Knicks sales catalogue)
--
-- ============================================================================
-- ml_knicks_catalog_tick: stop the per-game watermark lookups from walking the primary key
--
-- WHAT BROKE (first off-peak window, 2026-10-27 06:00–12:40 UTC): all 20 runs hit the 15-min
-- cron statement timeout and rolled back, so ml_knicks_games / ml_knicks_sales stayed empty.
-- `SELECT max(id) … WHERE sg_event_id = $1 AND id > $wm` on seatgeek_sales_snapshots (28.7 M
-- rows) is planned as a backward scan of the id primary key, filtering sg_event_id row by row
-- — for a game with few sales that walks most of the table. The 240 s budget is only checked
-- between games, so one lookup outlived it.
--
-- FIX: compare `id + 0` instead of `id` in the watermark lookups and the per-game insert
-- filters (SeatGeek and SeatData), which takes the primary key off the table as an access path
-- and leaves the per-event indexes (idx_sg_sales_sg_event_id_time / seatdata_sales_dedup).
-- Measured on prod: one Knicks game's max(id + 0) lookup = 77 ms.
--
-- ROLLBACK: re-apply ml_knicks_catalog_tick from 20261027010830.
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.ml_knicks_catalog_tick(p_budget_seconds integer DEFAULT 240)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start     timestamptz := clock_timestamp();
  g           RECORD;
  v_games     integer := 0;
  v_sg_rows   integer := 0;
  v_sd_rows   integer := 0;
  v_n         integer;
  v_max_id    bigint;
  v_done      integer := 0;
  v_caller    text;
  v_knicks_pid bigint;
  v_venue     bigint;
BEGIN
  -- Inside SECURITY DEFINER, current_user is the function OWNER, so the usual
  -- `current_user NOT IN (...)` guard always passes. Check the CALLER's role instead:
  -- the role GUC set by SET ROLE / PostgREST, falling back to session_user (pg_cron).
  v_caller := CASE WHEN coalesce(current_setting('role', true), 'none') IN ('', 'none')
                   THEN session_user::text ELSE current_setting('role', true) END;
  IF v_caller NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: ml_knicks_catalog_tick is service-only (caller %)', v_caller USING ERRCODE = '42501';
  END IF;
  IF public.is_peak() THEN
    RETURN jsonb_build_object('skipped', 'peak_hours');
  END IF;

  -- 1. Game registry: every Knicks home game at MSG any source can name -----------
  WITH named AS (
    SELECT c.sg_event_id, c.tevo_event_id, NULL::bigint AS sd_event_id, c.sg_event_name AS nm,
           c.sg_datetime_utc AS occ, 'canonical' AS src, 1 AS pri
      FROM public.sg_events_canonical c
     WHERE c.sg_event_name ~* 'at New York Knicks' AND c.sg_venue_name ~* 'madison square'
    UNION ALL
    -- aq_event_map.event_date is MSG local wall-clock time (timestamp without time zone)
    SELECT a.sg_event_id::bigint, a.tevo_event_id::bigint, a.sd_event_id::bigint, a.event_name,
           a.event_date AT TIME ZONE 'America/New_York', 'aq_event_map', 2
      FROM public.aq_event_map a
     WHERE a.event_name ~* 'at New York Knicks' AND a.venue_name ~* 'madison square'
       AND a.sg_event_id IS NOT NULL AND a.sg_event_id::text ~ '^\d+$'
    UNION ALL
    -- seatgeek_orders only has the date: assume a 7:30 PM ET tip (priority 3 = last resort)
    SELECT o.sg_event_id::bigint, o.tevo_event_id::bigint, NULL, o.sg_event_name,
           (o.sg_event_date + time '19:30') AT TIME ZONE 'America/New_York', 'seatgeek_orders', 3
      FROM public.seatgeek_orders o
     WHERE o.sg_event_name ~* 'at New York Knicks' AND coalesce(o.sg_venue, '') ~* 'madison square'
       AND o.sg_event_id IS NOT NULL
  ),
  best AS (
    SELECT DISTINCT ON (sg_event_id)
           sg_event_id,
           -- fill ids from any source, name/date from the highest-priority one
           (SELECT max(n2.tevo_event_id) FROM named n2 WHERE n2.sg_event_id = n.sg_event_id) AS tevo_event_id,
           (SELECT max(n2.sd_event_id)   FROM named n2 WHERE n2.sg_event_id = n.sg_event_id) AS sd_event_id,
           btrim(regexp_replace(nm, '^ZZ-DUP \([^)]*\)\s*[—-]\s*', '')) AS nm,
           -- tip-off from the best source that HAS one (canonical rows can carry a NULL time)
           (SELECT n2.occ FROM named n2 WHERE n2.sg_event_id = n.sg_event_id AND n2.occ IS NOT NULL
             ORDER BY n2.pri LIMIT 1) AS occ,
           src
      FROM named n
     WHERE nm !~* 'parking'
     ORDER BY sg_event_id, pri
  )
  INSERT INTO public.ml_knicks_games AS t
    (sg_event_id, tevo_event_id, sd_event_id, event_name, opponent, season, game_type, occurs_at,
     occurs_at_tevo, tip_diff_min, name_source, updated_at)
  SELECT b.sg_event_id, b.tevo_event_id, b.sd_event_id, b.nm,
         nullif(btrim(regexp_replace(regexp_replace(b.nm, '\s+at New York Knicks.*$', '', 'i'),
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
  WHERE (t.tevo_event_id, t.sd_event_id, t.event_name, t.occurs_at, t.game_type, t.opponent, t.season, t.tip_diff_min)
        IS DISTINCT FROM (coalesce(EXCLUDED.tevo_event_id, t.tevo_event_id), coalesce(EXCLUDED.sd_event_id, t.sd_event_id),
                          EXCLUDED.event_name, EXCLUDED.occurs_at, EXCLUDED.game_type, EXCLUDED.opponent, EXCLUDED.season,
                          coalesce(EXCLUDED.tip_diff_min, t.tip_diff_min));
  GET DIAGNOSTICS v_games = ROW_COUNT;

  -- keep catalogued sales in step with any re-classified / renamed game
  UPDATE public.ml_knicks_sales s
     SET game_type = k.game_type, season = k.season, opponent = k.opponent, occurs_at = k.occurs_at,
         hours_to_event = round((extract(epoch FROM k.occurs_at - s.sale_at) / 3600.0)::numeric, 2),
         days_to_event  = floor(extract(epoch FROM k.occurs_at - s.sale_at) / 86400.0)::int
    FROM public.ml_knicks_games k
   WHERE k.sg_event_id = s.sg_event_id
     AND (s.game_type, s.season, s.opponent, s.occurs_at) IS DISTINCT FROM (k.game_type, k.season, k.opponent, k.occurs_at);

  SELECT performer_id INTO v_knicks_pid FROM public.listings_poll_pins WHERE pin_key = 'knicks_home' LIMIT 1;
  -- the venue the curated Knicks zones are drawn for (MSG); every catalogued game is at MSG
  SELECT z.venue_id INTO v_venue FROM public.performer_zones z
   WHERE z.performer_id = v_knicks_pid AND z.source = 'curated'
   GROUP BY z.venue_id ORDER BY count(*) DESC LIMIT 1;

  -- re-zone sales whose zone was not curated (rules can be added later); cheap — few rows
  UPDATE public.ml_knicks_sales s
     SET zone = z.zone, zone_source = z.src
    FROM (SELECT x.source, x.sale_key,
                 coalesce(public.n2s_zone_of(v_knicks_pid, v_venue, public._ml_section_clean(x.section), x.row_label), public._ml_generic_zone(x.section)) AS zone,
                 CASE WHEN public.n2s_zone_of(v_knicks_pid, v_venue, public._ml_section_clean(x.section), x.row_label) IS NOT NULL THEN 'curated'
                      WHEN public._ml_generic_zone(x.section) IS NOT NULL THEN 'generic' END AS src
            FROM public.ml_knicks_sales x
           WHERE x.zone_source IS DISTINCT FROM 'curated' AND v_venue IS NOT NULL) z
   WHERE s.source = z.source AND s.sale_key = z.sale_key
     AND (s.zone, s.zone_source) IS DISTINCT FROM (z.zone, z.src);

  -- 2. Per game, catalogue new sales (least-recently-run first, wall-clock budget) --
  FOR g IN
    SELECT k.*, coalesce(s1.last_source_id, 0) AS sg_wm, coalesce(s2.last_source_id, 0) AS sd_wm
      FROM public.ml_knicks_games k
      LEFT JOIN public.ml_knicks_catalog_state s1 ON s1.source = 'seatgeek' AND s1.sg_event_id = k.sg_event_id
      LEFT JOIN public.ml_knicks_catalog_state s2 ON s2.source = 'seatdata' AND s2.sg_event_id = k.sg_event_id
     ORDER BY least(s1.last_run_at, s2.last_run_at) NULLS FIRST, k.occurs_at DESC
  LOOP
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_seconds);

    -- SeatGeek: the feed re-stores each sale per pull → keep the latest pull per sg_sale_id
    SELECT max(id + 0) INTO v_max_id FROM public.seatgeek_sales_snapshots   -- + 0: see header
     WHERE sg_event_id = g.sg_event_id AND id + 0 > g.sg_wm;
    IF v_max_id IS NOT NULL THEN
      INSERT INTO public.ml_knicks_sales AS t
        (source, sale_key, sg_event_id, tevo_event_id, season, game_type, opponent, occurs_at, sale_at,
         hours_to_event, days_to_event, price, quantity, section, row_label, level, row_band,
         zone, zone_source, stock_type, delivery_method, is_instant,
         ctx_zone_getin, ctx_zone_p25, ctx_zone_median, ctx_zone_tickets, ctx_zone_owned_share, ctx_zone_at,
         ctx_snapshot_date, ctx_evo_getin, ctx_evo_median, ctx_evo_tickets, ctx_owned_share, ctx_sg_getin, ctx_sg_median,
         ctx_perf_home_getin, ctx_perf_home_median, ctx_perf_home_games, ctx_stale,
         cataloged_at)
      SELECT 'seatgeek', s.sg_sale_id::text, g.sg_event_id, g.tevo_event_id, g.season, g.game_type, g.opponent, g.occurs_at, s.sale_at_utc,
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
                             CASE WHEN v_venue IS NOT NULL THEN public.n2s_zone_of(v_knicks_pid, v_venue, public._ml_section_clean(x.section), x.row) END AS cz
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
                                       AND d2.snapshot_date BETWEEN (s.sale_at_utc AT TIME ZONE 'America/New_York')::date - 2
                                                                AND (s.sale_at_utc AT TIME ZONE 'America/New_York')::date)
           GROUP BY d.snapshot_date) ctx ON g.tevo_event_id IS NOT NULL
        LEFT JOIN LATERAL (
          SELECT p.getin_median, p.price_median, p.event_count
            FROM public.performer_metrics_daily p
           WHERE p.performer_id = v_knicks_pid AND p.split = 'home'
             AND p.snapshot_date BETWEEN (s.sale_at_utc AT TIME ZONE 'America/New_York')::date - 2
                                     AND (s.sale_at_utc AT TIME ZONE 'America/New_York')::date
           ORDER BY p.snapshot_date DESC LIMIT 1) pf ON v_knicks_pid IS NOT NULL
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

    -- SeatData: already unique per (tevo_event_id, content_hash)
    IF g.tevo_event_id IS NOT NULL THEN
      SELECT max(id + 0) INTO v_max_id FROM public.seatdata_sales_snapshots
       WHERE tevo_event_id = g.tevo_event_id AND id + 0 > g.sd_wm;
      IF v_max_id IS NOT NULL THEN
        INSERT INTO public.ml_knicks_sales AS t
          (source, sale_key, sg_event_id, tevo_event_id, season, game_type, opponent, occurs_at, sale_at,
           hours_to_event, days_to_event, price, quantity, section, row_label, level, row_band, zone, zone_source, sd_zone,
           ctx_zone_getin, ctx_zone_p25, ctx_zone_median, ctx_zone_tickets, ctx_zone_owned_share, ctx_zone_at,
           ctx_perf_home_getin, ctx_perf_home_median, ctx_perf_home_games, ctx_stale, cataloged_at)
        SELECT 'seatdata', x.content_hash, g.sg_event_id, g.tevo_event_id, g.season, g.game_type, g.opponent, g.occurs_at, x.sale_timestamp,
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
                  FROM (SELECT x0.*, CASE WHEN v_venue IS NOT NULL THEN public.n2s_zone_of(v_knicks_pid, v_venue, public._ml_section_clean(x0.section), x0.row) END AS cz
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
             WHERE p.performer_id = v_knicks_pid AND p.split = 'home'
               AND p.snapshot_date BETWEEN (x.sale_timestamp AT TIME ZONE 'America/New_York')::date - 2
                                       AND (x.sale_timestamp AT TIME ZONE 'America/New_York')::date
             ORDER BY p.snapshot_date DESC LIMIT 1) pf ON v_knicks_pid IS NOT NULL
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
END $$;

REVOKE ALL ON FUNCTION public.ml_knicks_catalog_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ml_knicks_catalog_tick(integer) TO service_role;

-- VERIFY (after the next off-peak window): SELECT count(*) FROM public.ml_knicks_games;
--         SELECT source, count(*) FROM public.ml_knicks_sales GROUP BY 1;
