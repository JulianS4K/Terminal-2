-- Migration 20260604120000 · lane:D0 (author) → A1 (apply) · writes:performer_metrics_daily,venue_metrics_daily,refresh_entity_metrics_daily,get_performer_metrics_daily,get_venue_metrics_daily,cron(entity-metrics-daily-refresh) · reads:event_listing_snapshot_daily,events,v_canonical_performer,venues · pre:event_listing_snapshot_daily must exist (compute_event_listing_snapshot) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates tables + a cron + backfills history)
--
-- D0 — DAILY AGGREGATE METRICS at the performer + venue level.
--
-- Problem: event_listing_snapshot_daily gives us one daily metrics row per
-- EVENT (3 intraday slots: morning/midday/evening). We had per-event daily
-- history and single-row rolling baselines (performer_baselines / venue_baselines),
-- but no DAILY TIMESERIES at the performer- or venue-level to chart how a team's
-- or building's whole market moves day over day.
--
-- This migration adds that timeseries, rolling event_listing_snapshot_daily up to:
--   * performer_metrics_daily — one row per (performer, day, split)
--       split ∈ {'all','home','away'}. 'all' for every performer; 'home'/'away'
--       ADDITIONALLY emitted for SPORTS teams only (what_event_type='game').
--   * venue_metrics_daily — one row per (venue, day). (A venue is a venue — no
--       home/away concept; the building just hosts.)
--
-- HOME/AWAY rule (mirrors app.py:1912 is_home + PROJECT_BIBLE §7 home gate):
--   home/away is meaningful ONLY for sports performers (what_event_type='game').
--   A team is HOME for an event when the event's venue is one of the team's home
--   venues (v_canonical_performer.home_venue_ids), else AWAY. Concert/comedy/
--   theater performers get an 'all' row only.
--
-- Daily collapse: event_listing_snapshot_daily has up to 3 slots/day. We take the
-- LATEST present slot per (event, day) via DISTINCT ON (evening > midday > morning)
-- so re-running mid-day upgrades the row as later slots land, and an event with
-- only a morning slot is still counted. Prices roll up the cross-source blended
-- amalgam_* fields (best single signal); inventory totals stay per-source so units
-- never get mixed.
--
-- Refresh: refresh_entity_metrics_daily(p_date) — idempotent (delete+insert for the
-- target date). Cron 'entity-metrics-daily-refresh' runs it for today + yesterday
-- every 4h (intraday progression + late-data catch). Read via the two SECDEF RPCs
-- below (email-gated @s4kent.com like the rest of the D0 surface).

-- ============================================================================
-- 1. Tables
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.performer_metrics_daily (
  performer_id            bigint      NOT NULL,
  snapshot_date           date        NOT NULL,
  split                   text        NOT NULL,            -- 'all' | 'home' | 'away'
  performer_name          text,
  what_event_type         text,
  event_count             integer     NOT NULL DEFAULT 0,
  evo_tickets_total       integer,
  evo_owned_tickets_total integer,
  sg_all_tickets_total    integer,
  sg_owned_tickets_total  integer,
  getin_min               numeric,                          -- cheapest get-in across the entity's events that day
  getin_median            numeric,                          -- median of per-event get-ins
  price_min               numeric,
  price_median            numeric,                          -- median of per-event blended medians
  price_p90               numeric,
  owned_book_notional     numeric,                          -- Σ owned EVO inventory retail value
  computed_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT performer_metrics_daily_pk PRIMARY KEY (performer_id, snapshot_date, split),
  CONSTRAINT performer_metrics_daily_split_chk CHECK (split IN ('all','home','away'))
);
CREATE INDEX IF NOT EXISTS performer_metrics_daily_date_idx
  ON public.performer_metrics_daily (snapshot_date);
CREATE INDEX IF NOT EXISTS performer_metrics_daily_perf_split_date_idx
  ON public.performer_metrics_daily (performer_id, split, snapshot_date);

CREATE TABLE IF NOT EXISTS public.venue_metrics_daily (
  venue_id                bigint      NOT NULL,
  snapshot_date           date        NOT NULL,
  venue_name              text,
  event_count             integer     NOT NULL DEFAULT 0,
  evo_tickets_total       integer,
  evo_owned_tickets_total integer,
  sg_all_tickets_total    integer,
  sg_owned_tickets_total  integer,
  getin_min               numeric,
  getin_median            numeric,
  price_min               numeric,
  price_median            numeric,
  price_p90               numeric,
  owned_book_notional     numeric,
  computed_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT venue_metrics_daily_pk PRIMARY KEY (venue_id, snapshot_date)
);
CREATE INDEX IF NOT EXISTS venue_metrics_daily_date_idx
  ON public.venue_metrics_daily (snapshot_date);

-- ============================================================================
-- 2. Refresh function — roll event_listing_snapshot_daily up to performer + venue
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refresh_entity_metrics_daily(p_date date DEFAULT current_date)
RETURNS TABLE(performer_rows integer, venue_rows integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_perf integer := 0;
  v_ven  integer := 0;
BEGIN
  -- 2a. canonical daily event row = latest present slot per (event, day)
  CREATE TEMP TABLE _eld ON COMMIT DROP AS
  SELECT DISTINCT ON (event_id)
         event_id,
         evo_tickets_count, evo_owned_tickets, evo_owned_median, evo_retail_median,
         sg_all_tickets, sg_owned_tickets,
         amalgam_getin, amalgam_median
  FROM public.event_listing_snapshot_daily
  WHERE snapshot_date = p_date
  ORDER BY event_id,
           CASE snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2
                              WHEN 'morning' THEN 1 ELSE 0 END DESC;

  -- ---- performers (with home/away split for sports) -------------------------
  DELETE FROM public.performer_metrics_daily WHERE snapshot_date = p_date;

  WITH pe AS (
    SELECT cp.tevo_performer_id   AS performer_id,
           cp.tevo_performer_name AS performer_name,
           cp.what_event_type,
           CASE WHEN cp.what_event_type = 'game'
                THEN CASE WHEN e.venue_id = ANY(cp.home_venue_ids) THEN 'home' ELSE 'away' END
           END AS ha,
           d.*
    FROM public.events e
    CROSS JOIN LATERAL unnest(e.performer_ids) AS u(pid)
    JOIN public.v_canonical_performer cp ON cp.tevo_performer_id = u.pid
    JOIN _eld d ON d.event_id = e.id
  ),
  rolled AS (
    -- 'all' split: every performer, every event
    SELECT performer_id, performer_name, what_event_type, 'all'::text AS split,
           count(DISTINCT event_id)::int                                              AS event_count,
           sum(evo_tickets_count)::int                                                AS evo_tickets_total,
           sum(evo_owned_tickets)::int                                                AS evo_owned_tickets_total,
           sum(sg_all_tickets)::int                                                   AS sg_all_tickets_total,
           sum(sg_owned_tickets)::int                                                 AS sg_owned_tickets_total,
           min(amalgam_getin)                                                         AS getin_min,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_getin)                 AS getin_median,
           min(amalgam_median)                                                        AS price_min,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_median)                AS price_median,
           percentile_cont(0.9) WITHIN GROUP (ORDER BY amalgam_median)                AS price_p90,
           sum(coalesce(evo_owned_median, evo_retail_median) * evo_owned_tickets)     AS owned_book_notional
    FROM pe
    GROUP BY performer_id, performer_name, what_event_type
    UNION ALL
    -- 'home'/'away' splits: sports performers only
    SELECT performer_id, performer_name, what_event_type, ha,
           count(DISTINCT event_id)::int,
           sum(evo_tickets_count)::int, sum(evo_owned_tickets)::int,
           sum(sg_all_tickets)::int,    sum(sg_owned_tickets)::int,
           min(amalgam_getin),          percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_getin),
           min(amalgam_median),         percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_median),
           percentile_cont(0.9) WITHIN GROUP (ORDER BY amalgam_median),
           sum(coalesce(evo_owned_median, evo_retail_median) * evo_owned_tickets)
    FROM pe
    WHERE ha IS NOT NULL
    GROUP BY performer_id, performer_name, what_event_type, ha
  )
  INSERT INTO public.performer_metrics_daily
    (performer_id, snapshot_date, split, performer_name, what_event_type, event_count,
     evo_tickets_total, evo_owned_tickets_total, sg_all_tickets_total, sg_owned_tickets_total,
     getin_min, getin_median, price_min, price_median, price_p90, owned_book_notional)
  SELECT performer_id, p_date, split, performer_name, what_event_type, event_count,
         evo_tickets_total, evo_owned_tickets_total, sg_all_tickets_total, sg_owned_tickets_total,
         getin_min, getin_median, price_min, price_median, price_p90, owned_book_notional
  FROM rolled;
  GET DIAGNOSTICS v_perf = ROW_COUNT;

  -- ---- venues ---------------------------------------------------------------
  DELETE FROM public.venue_metrics_daily WHERE snapshot_date = p_date;

  INSERT INTO public.venue_metrics_daily
    (venue_id, snapshot_date, venue_name, event_count,
     evo_tickets_total, evo_owned_tickets_total, sg_all_tickets_total, sg_owned_tickets_total,
     getin_min, getin_median, price_min, price_median, price_p90, owned_book_notional)
  SELECT e.venue_id, p_date, max(e.venue_name), count(DISTINCT d.event_id)::int,
         sum(d.evo_tickets_count)::int, sum(d.evo_owned_tickets)::int,
         sum(d.sg_all_tickets)::int,    sum(d.sg_owned_tickets)::int,
         min(d.amalgam_getin),          percentile_cont(0.5) WITHIN GROUP (ORDER BY d.amalgam_getin),
         min(d.amalgam_median),         percentile_cont(0.5) WITHIN GROUP (ORDER BY d.amalgam_median),
         percentile_cont(0.9) WITHIN GROUP (ORDER BY d.amalgam_median),
         sum(coalesce(d.evo_owned_median, d.evo_retail_median) * d.evo_owned_tickets)
  FROM public.events e
  JOIN _eld d ON d.event_id = e.id
  WHERE e.venue_id IS NOT NULL
  GROUP BY e.venue_id;
  GET DIAGNOSTICS v_ven = ROW_COUNT;

  DROP TABLE IF EXISTS _eld;
  RETURN QUERY SELECT v_perf, v_ven;
END;
$func$;

-- ============================================================================
-- 3. Read RPCs (email-gated @s4kent.com, like the rest of the D0 surface)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_performer_metrics_daily(
  p_performer_id bigint,
  p_days         integer DEFAULT 90,
  p_split        text    DEFAULT 'all')
RETURNS SETOF public.performer_metrics_daily
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;
  IF p_split NOT IN ('all','home','away') THEN
    RAISE EXCEPTION 'invalid split %, expected all|home|away', p_split USING ERRCODE='22023';
  END IF;
  RETURN QUERY
    SELECT * FROM public.performer_metrics_daily
    WHERE performer_id = p_performer_id
      AND split = p_split
      AND snapshot_date >= current_date - make_interval(days => p_days)
    ORDER BY snapshot_date;
END;
$func$;

CREATE OR REPLACE FUNCTION public.get_venue_metrics_daily(
  p_venue_id bigint,
  p_days     integer DEFAULT 90)
RETURNS SETOF public.venue_metrics_daily
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    SELECT * FROM public.venue_metrics_daily
    WHERE venue_id = p_venue_id
      AND snapshot_date >= current_date - make_interval(days => p_days)
    ORDER BY snapshot_date;
END;
$func$;

GRANT EXECUTE ON FUNCTION public.get_performer_metrics_daily(bigint, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_venue_metrics_daily(bigint, integer)           TO authenticated;

-- refresh fn is a SECDEF writer with no email gate → keep it off PUBLIC/anon
-- (cron runs as owner, unaffected). Mirrors the D4 write-path revoke pattern.
REVOKE EXECUTE ON FUNCTION public.refresh_entity_metrics_daily(date) FROM PUBLIC;

-- ============================================================================
-- 4. Cron — refresh today + yesterday every 4h
--    (idempotent; later runs upgrade the row as evening slots land, and the
--    yesterday pass catches any late-arriving snapshot data)
-- ============================================================================
DO $$ BEGIN
  PERFORM cron.unschedule('entity-metrics-daily-refresh');
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT cron.schedule('entity-metrics-daily-refresh', '20 */4 * * *', $cron$
  SELECT public.refresh_entity_metrics_daily(current_date);
  SELECT public.refresh_entity_metrics_daily(current_date - 1);
$cron$);

-- ============================================================================
-- 5. Backfill all daily history currently present in the source
-- ============================================================================
DO $$
DECLARE v_d date;
BEGIN
  FOR v_d IN SELECT DISTINCT snapshot_date FROM public.event_listing_snapshot_daily ORDER BY 1 LOOP
    PERFORM public.refresh_entity_metrics_daily(v_d);
  END LOOP;
END $$;
