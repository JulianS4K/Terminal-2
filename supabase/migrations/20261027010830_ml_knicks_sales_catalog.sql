-- Migration 20261027010830 · level:feature · lane:A1 (data plane — ML training data) · writes:ml_knicks_games(new),ml_knicks_sales(new),ml_knicks_catalog_state(new),v_ml_knicks_sales_train(new),v_ml_knicks_sales_playoff(new),_ml_level_of()(new),_ml_row_band()(new),_ml_generic_zone()(new),_ml_section_clean()(new),ml_knicks_catalog_tick()(new),cron ml_knicks_catalog_offpeak(new) · reads:sg_events_canonical,aq_event_map,seatgeek_orders,seatgeek_sales_snapshots,seatdata_sales_snapshots,event_listing_snapshot_daily,event_metrics,performer_metrics_daily,listings_poll_pins,performer_zones,zone_rules,zone_metrics,n2s_zone_of() · pre:20261023051000 (listings_poll_pins)
--
-- ============================================================================
-- Knicks sales catalogue: one clean row per sale, ready for model training
--
-- Operator 2026-10-27: "create a worker to sort the Knicks sales data and catalogue so we
-- can use it to train the models faster, after peak hours should work fine".
--
-- Why: the raw SeatGeek feed (seatgeek_sales_snapshots, 28.7 M rows) stores every sale
-- 2–3x (unique key includes pulled_at), has no game names, and old games drop out of
-- events. Training straight off it means re-deduping and re-joining every time.
--
--   ml_knicks_games         every Knicks home game at MSG we can identify, any season:
--                           sg_events_canonical ∪ aq_event_map ∪ seatgeek_orders. Opponent,
--                           season (Jul–Jun), game_type (preseason / regular / cup / playoff),
--                           tip-off, SeatGeek + TEvo + SeatData ids. "ZZ-DUP" names cleaned.
--                           Tip-off = first source that has one (canonical UTC → aq_event_map
--                           local MSG time → orders date @ 7:30 PM ET); TEvo's time is stored
--                           alongside and games > 2 h apart (playoff "Date TBD" placeholders run
--                           up to 2 days off) are kept out of both training views.
--   ml_knicks_sales         one row per unique sale (SeatGeek by sg_sale_id, SeatData by
--                           content_hash) with hours_to_event, level (floor/100s/200s/300s/
--                           400s/other), row band, and the market at the time of sale from
--                           the daily snapshot (EVO get-in/median, SG median). ctx_stale =
--                           true when no live event_metrics existed that day (the Sep 27 –
--                           Oct 23 snapshots are frozen copies), so training can drop them.
--   ml_knicks_catalog_state per-game watermark (last source row id) → each run only reads
--                           new rows through the per-event indexes.
--                           Also the Knicks home-performer level that day (performer_metrics_daily,
--                           split 'home': get-in median, price median, games listed).
--                           ZONE: each sale is placed in the curated Knicks/MSG zone (22 zones —
--                           Courtside Apples … Club Platinum/Gold/Silver … U1–U4 … 400) via
--                           n2s_zone_of(), the unambiguous section+ROW resolver (zones are row
--                           tiers inside a section: 106–108 rows 1–8 Platinum, 9–17 Gold, 18–22
--                           Silver); NULL on ambiguity, then the generic zone_rules (SRO →
--                           standing, Club → club). Dry run on 1,662 real sales: ~98% curated.
--                           Plus that zone's market at sale time from zone_metrics (latest
--                           capture ≤ 36 h before the sale: get-in, p25, median, tickets, our
--                           share) — same zone names, so price_vs_zone_median is like-for-like.
--   v_ml_knicks_sales_train REGULAR SEASON ONLY (regular + NBA Cup group/knockout games, which
--                           count toward the regular-season record). Playoffs and preseason are
--                           excluded — operator 2026-10-27: "Playoffs dont count to regular season".
--   v_ml_knicks_sales_playoff playoff sales on their own, for a separate playoff model.
--   ml_knicks_catalog_tick  the worker. Off-peak only (is_peak() = 9 AM–1 AM ET), 240 s
--                           wall-clock budget per run, least-recently-run games first.
--   cron                    every 20 min 06:00–13:40 UTC (covers 2–8 AM ET in both EDT and
--                           EST); the in-function is_peak() check is the real gate.
--
-- Coverage today: 43 current-season games (5 with SG sales so far) + 6 playoff games from
-- 2025-26 (~1,500 SG sales) + 4 SeatData games (3,021 sales).
-- No 2025-26 REGULAR-season data exists in the DB: every market feed (SG sales, SeatData,
-- SG metrics, daily snapshots, performer metrics) starts 2026-05-09 or later, and no table
-- names a Knicks home game before the 2026 playoffs. Backfilling last season needs its
-- SeatGeek event ids (then the existing post-game sales poll can pull each game's full
-- sales history) — a separate, operator-approved job. Any game any source names later is
-- picked up on the next run.
--
-- Read-only on every source; writes only the three new ml_* tables. No upstream API calls.
-- Cross-lane read: n2s_zone_of() is D7's resolver, reused (not copied) so both agree on zones.
-- ROLLBACK: SELECT cron.unschedule('ml_knicks_catalog_offpeak');
--           DROP VIEW v_ml_knicks_sales_train, v_ml_knicks_sales_playoff; DROP TABLE ml_knicks_sales, ml_knicks_catalog_state, ml_knicks_games;
--           DROP FUNCTION ml_knicks_catalog_tick(integer), _ml_level_of(text), _ml_row_band(text), _ml_generic_zone(text), _ml_section_clean(text);
-- ============================================================================

SET LOCAL lock_timeout = '10s';

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ml_knicks_games (
  sg_event_id     bigint      PRIMARY KEY,
  tevo_event_id   bigint,
  sd_event_id     bigint,
  event_name      text        NOT NULL,
  opponent        text,
  season          text        NOT NULL,          -- '2025-26' (Jul–Jun)
  game_type       text        NOT NULL CHECK (game_type IN ('preseason','regular','cup','playoff')),
  occurs_at       timestamptz,
  occurs_at_tevo  timestamptz,                   -- TEvo's tip-off, when the event still exists
  tip_diff_min    integer,                       -- |occurs_at − occurs_at_tevo|; > 120 → kept out of training
  name_source     text        NOT NULL,          -- canonical | aq_event_map | seatgeek_orders
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ml_knicks_games_tevo_idx ON public.ml_knicks_games (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.ml_knicks_sales (
  source              text        NOT NULL CHECK (source IN ('seatgeek','seatdata')),
  sale_key            text        NOT NULL,      -- sg_sale_id | seatdata content_hash
  sg_event_id         bigint      NOT NULL REFERENCES public.ml_knicks_games (sg_event_id),
  tevo_event_id       bigint,
  season              text        NOT NULL,
  game_type           text        NOT NULL,
  is_regular_season   boolean     GENERATED ALWAYS AS (game_type IN ('regular','cup')) STORED,
  opponent            text,
  occurs_at           timestamptz,
  sale_at             timestamptz NOT NULL,
  hours_to_event      numeric,                   -- negative = sold after tip-off
  days_to_event       integer,
  price               numeric     NOT NULL,      -- SG broadcast_price / SeatData price, per ticket
  quantity            integer,
  section             text,
  row_label           text,
  level               text        NOT NULL,      -- courtside | baseline | 100s | 200s | 300s | 400s | other
  row_band            text        NOT NULL,      -- 1-3 | 4-7 | 8-12 | 13-18 | 19+ | alpha | unknown
  zone                text,                      -- curated Knicks/MSG zone, else generic zone_rules
  zone_source         text,                      -- curated | generic | NULL (no match)
  sd_zone             text,                      -- SeatData's own zone label (SeatData rows only)
  stock_type          text,
  delivery_method     text,
  is_instant          boolean,
  ctx_snapshot_date   date,
  ctx_evo_getin       numeric,
  ctx_evo_median      numeric,
  ctx_evo_tickets     integer,
  ctx_owned_share     numeric,
  ctx_sg_getin        numeric,
  ctx_sg_median       numeric,
  ctx_zone_getin      numeric,                   -- this sale's zone, latest zone_metrics ≤ 36 h before
  ctx_zone_p25        numeric,
  ctx_zone_median     numeric,
  ctx_zone_tickets    integer,
  ctx_zone_owned_share numeric,
  ctx_zone_at         timestamptz,
  ctx_perf_home_getin  numeric,                  -- Knicks home performer that day
  ctx_perf_home_median numeric,
  ctx_perf_home_games  integer,
  ctx_stale           boolean     NOT NULL DEFAULT true,
  cataloged_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, sale_key)
);
CREATE INDEX IF NOT EXISTS ml_knicks_sales_game_idx  ON public.ml_knicks_sales (sg_event_id, sale_at);
CREATE INDEX IF NOT EXISTS ml_knicks_sales_zone_idx  ON public.ml_knicks_sales (zone, days_to_event);
CREATE INDEX IF NOT EXISTS ml_knicks_sales_train_idx ON public.ml_knicks_sales (is_regular_season, season, level, days_to_event);

CREATE TABLE IF NOT EXISTS public.ml_knicks_catalog_state (
  source          text        NOT NULL,
  sg_event_id     bigint      NOT NULL,
  last_source_id  bigint      NOT NULL DEFAULT 0,
  rows_upserted      bigint      NOT NULL DEFAULT 0,
  last_run_at     timestamptz,
  PRIMARY KEY (source, sg_event_id)
);

ALTER TABLE public.ml_knicks_games         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ml_knicks_sales         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ml_knicks_catalog_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ml_knicks_games, public.ml_knicks_sales, public.ml_knicks_catalog_state FROM anon, authenticated;

COMMENT ON TABLE public.ml_knicks_sales IS
  'One row per unique Knicks-home sale (SeatGeek + SeatData) with time-to-event, level, row band and market context at sale time. Built off-peak by ml_knicks_catalog_tick (mig 20261027010830).';

-- ---------------------------------------------------------------------------
-- Helpers (MSG layout: "4 D"…"12 D" / VIP = courtside, 1–9 = baseline club + risers,
-- 1xx/2xx/3xx/4xx = bowl levels)
-- ---------------------------------------------------------------------------
-- "Section 226" / "Sec. 226" → "226" (feeds sometimes prefix the word; zone rules never do)
CREATE OR REPLACE FUNCTION public._ml_section_clean(p_section text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT nullif(btrim(regexp_replace(coalesce(p_section, ''), '^\s*(section|sec)\.?\s+', '', 'i')), '')
$$;

CREATE OR REPLACE FUNCTION public._ml_level_of(p_section text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN public._ml_section_clean(p_section) IS NULL THEN 'other'
    WHEN public._ml_section_clean(p_section) ~* '^\s*(vip\s*\d+|\d{1,2}\s*d)\s*$' OR public._ml_section_clean(p_section) ~* 'court' THEN 'courtside'
    WHEN public._ml_section_clean(p_section) ~ '^\s*\d\s*$' THEN 'baseline'              -- MSG 1–9: baseline club + risers
    WHEN substring(public._ml_section_clean(p_section) FROM '(\d{3})') ~ '^1' THEN '100s'
    WHEN substring(public._ml_section_clean(p_section) FROM '(\d{3})') ~ '^2' THEN '200s'
    WHEN substring(public._ml_section_clean(p_section) FROM '(\d{3})') ~ '^3' THEN '300s'
    WHEN substring(public._ml_section_clean(p_section) FROM '(\d{3})') ~ '^4' THEN '400s'
    ELSE 'other' END
$$;

CREATE OR REPLACE FUNCTION public._ml_row_band(p_row text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN p_row IS NULL OR btrim(p_row) = '' THEN 'unknown'
    WHEN btrim(p_row) ~ '^\d+$' THEN CASE
      WHEN btrim(p_row)::int <= 3  THEN '1-3'
      WHEN btrim(p_row)::int <= 7  THEN '4-7'
      WHEN btrim(p_row)::int <= 12 THEN '8-12'
      WHEN btrim(p_row)::int <= 18 THEN '13-18'
      ELSE '19+' END
    WHEN btrim(p_row) ~* '^[a-z]{1,2}$' THEN 'alpha'
    ELSE 'unknown' END
$$;

-- Generic fallback for sections no curated zone covers (SRO, clubs, suites…).
-- zone_rules patterns are upper-case; match case-insensitively; higher priority wins
-- (UPPER BLEACHER 60 beats BLEACHER 50).
CREATE OR REPLACE FUNCTION public._ml_generic_zone(p_section text)
RETURNS text LANGUAGE sql STABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT r.zone FROM public.zone_rules r
   WHERE r.active AND public._ml_section_clean(p_section) IS NOT NULL
     AND CASE r.match_type
           WHEN 'prefix'    THEN upper(public._ml_section_clean(p_section)) LIKE upper(r.section_pattern) || '%'
           WHEN 'substring' THEN strpos(upper(public._ml_section_clean(p_section)), upper(r.section_pattern)) > 0
           WHEN 'regex'     THEN public._ml_section_clean(p_section) ~* r.section_pattern
           WHEN 'exact'     THEN upper(public._ml_section_clean(p_section)) = upper(r.section_pattern)
           ELSE false END
   ORDER BY r.priority DESC, r.id
   LIMIT 1
$$;

-- ---------------------------------------------------------------------------
-- Worker
-- ---------------------------------------------------------------------------
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
    SELECT max(id) INTO v_max_id FROM public.seatgeek_sales_snapshots
     WHERE sg_event_id = g.sg_event_id AND id > g.sg_wm;
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
                       WHERE x.sg_event_id = g.sg_event_id AND x.id > g.sg_wm AND x.id <= v_max_id
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
      SELECT max(id) INTO v_max_id FROM public.seatdata_sales_snapshots
       WHERE tevo_event_id = g.tevo_event_id AND id > g.sd_wm;
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
                         WHERE x0.tevo_event_id = g.tevo_event_id AND x0.id > g.sd_wm AND x0.id <= v_max_id
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
REVOKE ALL ON FUNCTION public._ml_level_of(text), public._ml_row_band(text), public._ml_generic_zone(text), public._ml_section_clean(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._ml_level_of(text), public._ml_row_band(text), public._ml_generic_zone(text), public._ml_section_clean(text) TO service_role;

-- ---------------------------------------------------------------------------
-- Training view
-- ---------------------------------------------------------------------------
-- Regular season only: playoffs and preseason never mix into this set.
CREATE OR REPLACE VIEW public.v_ml_knicks_sales_train
WITH (security_invoker = true) AS
SELECT s.*,
       round(s.price / nullif(s.ctx_evo_median, 0), 3) AS price_vs_evo_median,
       round(s.price / nullif(s.ctx_evo_getin, 0), 3)  AS price_vs_evo_getin,
       round(s.price / nullif(s.ctx_sg_median, 0), 3)  AS price_vs_sg_median,
       round(s.price / nullif(s.ctx_perf_home_median, 0), 3) AS price_vs_knicks_home_median,
       round(s.price / nullif(s.ctx_zone_median, 0), 3) AS price_vs_zone_median,
       round(s.price / nullif(s.ctx_zone_getin, 0), 3)  AS price_vs_zone_getin,
       round(s.price / nullif(s.ctx_zone_p25, 0), 3)    AS price_vs_zone_p25,
       CASE WHEN s.hours_to_event < 0    THEN 'after_tip'
            WHEN s.hours_to_event < 6    THEN 'h0_6'
            WHEN s.hours_to_event < 24   THEN 'h6_24'
            WHEN s.hours_to_event < 72   THEN 'd1_3'
            WHEN s.hours_to_event < 168  THEN 'd3_7'
            WHEN s.hours_to_event < 336  THEN 'd7_14'
            WHEN s.hours_to_event < 720  THEN 'd14_30'
            ELSE 'd30p' END AS horizon_bucket,
       extract(isodow FROM s.occurs_at AT TIME ZONE 'America/New_York')::int AS game_dow
  FROM public.ml_knicks_sales s
  JOIN public.ml_knicks_games k ON k.sg_event_id = s.sg_event_id
 WHERE s.is_regular_season AND s.hours_to_event > -6
   AND coalesce(k.tip_diff_min, 0) <= 120;
REVOKE ALL ON public.v_ml_knicks_sales_train FROM anon, authenticated;

-- Playoffs on their own (different demand regime — e.g. Knicks home get-in median
-- $679–887 in the 2026 playoffs vs ~$190–310 in the regular season).
CREATE OR REPLACE VIEW public.v_ml_knicks_sales_playoff
WITH (security_invoker = true) AS
SELECT s.*,
       round(s.price / nullif(s.ctx_evo_median, 0), 3) AS price_vs_evo_median,
       round(s.price / nullif(s.ctx_evo_getin, 0), 3)  AS price_vs_evo_getin,
       round(s.price / nullif(s.ctx_sg_median, 0), 3)  AS price_vs_sg_median,
       round(s.price / nullif(s.ctx_perf_home_median, 0), 3) AS price_vs_knicks_home_median,
       round(s.price / nullif(s.ctx_zone_median, 0), 3) AS price_vs_zone_median,
       round(s.price / nullif(s.ctx_zone_getin, 0), 3)  AS price_vs_zone_getin,
       round(s.price / nullif(s.ctx_zone_p25, 0), 3)    AS price_vs_zone_p25,
       CASE WHEN s.hours_to_event < 0    THEN 'after_tip'
            WHEN s.hours_to_event < 6    THEN 'h0_6'
            WHEN s.hours_to_event < 24   THEN 'h6_24'
            WHEN s.hours_to_event < 72   THEN 'd1_3'
            WHEN s.hours_to_event < 168  THEN 'd3_7'
            WHEN s.hours_to_event < 336  THEN 'd7_14'
            WHEN s.hours_to_event < 720  THEN 'd14_30'
            ELSE 'd30p' END AS horizon_bucket,
       extract(isodow FROM s.occurs_at AT TIME ZONE 'America/New_York')::int AS game_dow
  FROM public.ml_knicks_sales s
  JOIN public.ml_knicks_games k ON k.sg_event_id = s.sg_event_id
 WHERE s.game_type = 'playoff' AND s.hours_to_event > -6
   AND coalesce(k.tip_diff_min, 0) <= 120;
REVOKE ALL ON public.v_ml_knicks_sales_playoff FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Cron: off-peak window. 06:00–13:40 UTC covers 2–8 AM ET under both EDT and EST;
-- is_peak() inside the function is the authoritative gate.
-- ---------------------------------------------------------------------------
DO $c$
BEGIN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'ml_knicks_catalog_offpeak';
  PERFORM cron.schedule('ml_knicks_catalog_offpeak', '*/20 6-13 * * *',
    $cmd$DO $b$ BEGIN IF NOT public.cron_try_lock('ml_knicks_catalog') THEN RETURN; END IF; PERFORM public.ml_knicks_catalog_tick(240); END $b$;$cmd$);
END $c$;

-- ============================================================================
-- VERIFY: SELECT season, game_type, count(*) FROM public.ml_knicks_games GROUP BY 1,2 ORDER BY 1,2;
--         SELECT is_regular_season, game_type, count(*) FROM public.ml_knicks_sales GROUP BY 1,2;
--         SELECT zone_source, zone, count(*), percentile_cont(0.5) WITHIN GROUP (ORDER BY price_vs_zone_median)
--           FROM public.ml_knicks_sales GROUP BY 1,2 ORDER BY 3 DESC;
--         SELECT source, season, level, count(*), percentile_cont(0.5) WITHIN GROUP (ORDER BY price)
--           FROM public.ml_knicks_sales GROUP BY 1,2,3 ORDER BY 1,2,3;
--         SELECT * FROM cron.job WHERE jobname = 'ml_knicks_catalog_offpeak';
-- ============================================================================
