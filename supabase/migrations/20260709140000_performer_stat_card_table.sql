-- Migration 20260709140000 · lane:D0 (author) → A1 (apply) · writes:performer_stat_card,refresh_performer_stat_card,get_performer_stat_cards,get_broker_performer_stat_card,cron(performer-stat-card-refresh) · reads:performer_metrics_daily · pre:performer_metrics_daily (mig 20260605151100) + get_broker_performer_stat_card (mig 20260709135000) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates a table + cron + backfills; repoints an existing RPC)
--
-- D0 — materialize the performer Statistics stat-card as a TABLE.
--
-- mig 20260709135000 computed the stat-card per call. This turns it into a
-- persisted table (one row per performer) refreshed on the same 4h cadence as
-- its source (performer_metrics_daily), so:
--   * the single-performer RPC becomes a cheap table read (repointed below), and
--   * the NEW compare window can pull up to 5 performers in one round-trip
--     (get_performer_stat_cards) instead of N per-performer computes.
--
-- The refresh is the set-based form of mig 20260709135000's per-performer CTE:
-- per-performer anchor (its own max 'all'-split day) + LATERAL nearest-on-or-
-- before 7d/30d rows + home/away split rows. Idempotent upsert + prune.
--
-- Table is RLS-locked (no direct anon/auth read); the two SECDEF RPCs
-- (@s4kent.com-gated) are the only read path, same as performer_metrics_daily.

-- ============================================================
-- 1. Table
-- ============================================================
CREATE TABLE IF NOT EXISTS public.performer_stat_card (
  performer_id         bigint      PRIMARY KEY,
  performer_name       text,
  as_of                date,
  is_sports            boolean,
  event_count          integer,
  getin_min            numeric,
  getin_median         numeric,
  price_median         numeric,
  price_p90            numeric,
  spread_ratio         numeric,
  market_tickets       bigint,
  owned_tickets        bigint,
  owned_book_notional  numeric,
  owned_share          numeric,
  price_median_7d      numeric,
  price_median_30d     numeric,
  price_d7_pct         numeric,
  price_d30_pct        numeric,
  getin_d7_pct         numeric,
  owned_tickets_d30    bigint,
  home_price_median    numeric,
  away_price_median    numeric,
  computed_at          timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.performer_stat_card ENABLE ROW LEVEL SECURITY;
-- No policy = deny-all for direct anon/authenticated; the SECDEF RPCs (owner =
-- postgres) bypass RLS. Mirrors the performer_metrics_daily lockdown.
REVOKE ALL ON TABLE public.performer_stat_card FROM anon, authenticated;

-- ============================================================
-- 2. Refresh — set-based rebuild from performer_metrics_daily
-- ============================================================
CREATE OR REPLACE FUNCTION public.refresh_performer_stat_card()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  WITH anchor AS (
    SELECT performer_id, max(snapshot_date) AS as_of
    FROM public.performer_metrics_daily
    WHERE split = 'all'
    GROUP BY performer_id
  ),
  cur AS (
    SELECT p.*
    FROM public.performer_metrics_daily p
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
      w7.price_median  AS price_median_7d,
      w30.price_median AS price_median_30d,
      round(((c.price_median  - w7.price_median)  / nullif(w7.price_median,0))  * 100, 1) AS price_d7_pct,
      round(((c.price_median  - w30.price_median) / nullif(w30.price_median,0)) * 100, 1) AS price_d30_pct,
      round(((c.getin_median  - w7.getin_median)  / nullif(w7.getin_median,0))  * 100, 1) AS getin_d7_pct,
      (coalesce(c.evo_owned_tickets_total,0) - coalesce(w30.evo_owned_tickets_total,0))::bigint AS owned_tickets_d30,
      h.price_median  AS home_price_median,
      aw.price_median AS away_price_median
    FROM cur c
    LEFT JOIN LATERAL (
      SELECT price_median, getin_median, evo_owned_tickets_total
      FROM public.performer_metrics_daily x
      WHERE x.performer_id = c.performer_id AND x.split = 'all' AND x.snapshot_date <= c.snapshot_date - 7
      ORDER BY x.snapshot_date DESC LIMIT 1
    ) w7 ON true
    LEFT JOIN LATERAL (
      SELECT price_median, getin_median, evo_owned_tickets_total
      FROM public.performer_metrics_daily x
      WHERE x.performer_id = c.performer_id AND x.split = 'all' AND x.snapshot_date <= c.snapshot_date - 30
      ORDER BY x.snapshot_date DESC LIMIT 1
    ) w30 ON true
    LEFT JOIN LATERAL (
      SELECT price_median FROM public.performer_metrics_daily x
      WHERE x.performer_id = c.performer_id AND x.split = 'home' AND x.snapshot_date = c.snapshot_date LIMIT 1
    ) h ON true
    LEFT JOIN LATERAL (
      SELECT price_median FROM public.performer_metrics_daily x
      WHERE x.performer_id = c.performer_id AND x.split = 'away' AND x.snapshot_date = c.snapshot_date LIMIT 1
    ) aw ON true
  )
  INSERT INTO public.performer_stat_card AS t (
    performer_id, performer_name, as_of, is_sports, event_count, getin_min, getin_median,
    price_median, price_p90, spread_ratio, market_tickets, owned_tickets, owned_book_notional,
    owned_share, price_median_7d, price_median_30d, price_d7_pct, price_d30_pct, getin_d7_pct,
    owned_tickets_d30, home_price_median, away_price_median, computed_at
  )
  SELECT
    performer_id, performer_name, as_of, is_sports, event_count, getin_min, getin_median,
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

  -- prune performers that no longer have any 'all'-split metrics row
  DELETE FROM public.performer_stat_card t
  WHERE NOT EXISTS (
    SELECT 1 FROM public.performer_metrics_daily m
    WHERE m.performer_id = t.performer_id AND m.split = 'all'
  );

  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_performer_stat_card() FROM PUBLIC;

-- ============================================================
-- 3. Batch read RPC — the compare window (up to 5 performers)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_performer_stat_cards(p_ids bigint[])
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_ids   bigint[];
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- cap at 5, preserve caller order
  v_ids := (SELECT array_agg(x) FROM (SELECT unnest(p_ids) AS x LIMIT 5) q);

  SELECT coalesce(
           jsonb_agg(to_jsonb(s) ORDER BY array_position(v_ids, s.performer_id)),
           '[]'::jsonb)
  INTO v_result
  FROM public.performer_stat_card s
  WHERE s.performer_id = ANY(v_ids);

  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_performer_stat_cards(bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_performer_stat_cards(bigint[]) TO anon, authenticated;

COMMENT ON FUNCTION public.get_performer_stat_cards(bigint[]) IS
  'D0 compare window: stat-card rows for up to 5 performers (order preserved) from performer_stat_card. @s4kent.com-gated SECDEF read.';

-- ============================================================
-- 4. Repoint the single-performer RPC to read the table
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_broker_performer_stat_card(p_performer_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(s) INTO v_result
  FROM public.performer_stat_card s
  WHERE s.performer_id = p_performer_id;

  RETURN coalesce(v_result, jsonb_build_object('performer_id', p_performer_id, 'as_of', NULL, 'measures', NULL));
END;
$func$;

REVOKE ALL ON FUNCTION public.get_broker_performer_stat_card(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_performer_stat_card(bigint) TO anon, authenticated;

-- ============================================================
-- 5. Backfill now + schedule refresh (after the 4h entity-metrics refresh)
-- ============================================================
SELECT public.refresh_performer_stat_card();

DO $cron$
BEGIN
  PERFORM cron.unschedule('performer-stat-card-refresh');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$cron$;

-- entity-metrics-daily-refresh runs '20 */4 * * *' (repopulates the source);
-- run this at :35 so the source day is already fresh. Avoids saturated
-- :02/:05/:07 minute clusters.
SELECT cron.schedule('performer-stat-card-refresh', '35 */4 * * *', $cron$
  SELECT public.refresh_performer_stat_card();
$cron$);
