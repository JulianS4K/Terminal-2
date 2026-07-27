-- Migration 20260709180000 · lane:D0 (author) → A1 (apply) · writes:axs_performer_stat_card,performer_stat_card(+5 cols),refresh_axs_performer_stat_card,merge_axs_into_performer_stat_card,run_axs_match_and_merge,get_axs_stat_cards,cron(axs-performer-match reschedule) · reads:axs_event_performer_xref,axs_event_snapshots · pre:axs_event_performer_xref (mig 20260709170000) + performer_stat_card (mig 20260709140000) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates a table + alters a table + reschedules a cron + backfills)
--
-- D0 — AXS performer stat-card + merge into the canonical card.
--
-- Builds on the AXS name-match job (mig 20260709170000). Two outputs:
--   1. axs_performer_stat_card — one row per matched AXS artist (get-in,
--      listings, seats), carrying the tevo bridge when it exists. This IS the
--      "separate table for when EVO doesn't map" — its tevo_performer_id-NULL
--      rows are the AXS-only acts (tribute/regional).
--   2. MERGE for bridged artists — AXS-source columns on performer_stat_card
--      (axs_event_count / axs_getin_min / axs_getin_median / axs_listings) so a
--      canonical performer's card shows its AXS inventory as a labeled source.
--      Inventory is NOT summed into market_tickets (units never mixed per source
--      — PROJECT_BIBLE); AXS is an additive, clearly-labeled source line.
--
-- A daily orchestrator (run_axs_match_and_merge) chains match → refresh → merge
-- and replaces the match-only cron.

-- ============================================================
-- 1. AXS performer stat-card (keyed by axs_artist_id)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.axs_performer_stat_card (
  axs_artist_id        text PRIMARY KEY,
  axs_performer        text,
  tevo_performer_id    bigint,        -- canonical bridge (NULL = AXS-only act)
  as_of                date,
  event_count          integer,
  priced_event_count   integer,
  getin_min            numeric,
  getin_median         numeric,
  listings_total       bigint,
  seats_primary_total  bigint,
  seats_resale_total   bigint,
  computed_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS axs_performer_stat_card_tevo_idx
  ON public.axs_performer_stat_card (tevo_performer_id) WHERE tevo_performer_id IS NOT NULL;
ALTER TABLE public.axs_performer_stat_card ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.axs_performer_stat_card FROM anon, authenticated;

-- ============================================================
-- 2. AXS-source columns merged onto the canonical card
-- ============================================================
ALTER TABLE public.performer_stat_card
  ADD COLUMN IF NOT EXISTS axs_event_count   integer,
  ADD COLUMN IF NOT EXISTS axs_getin_min     numeric,
  ADD COLUMN IF NOT EXISTS axs_getin_median  numeric,
  ADD COLUMN IF NOT EXISTS axs_listings      bigint,
  ADD COLUMN IF NOT EXISTS axs_as_of         date;

-- ============================================================
-- 3. Refresh the AXS stat-card from the match xref + snapshots
-- ============================================================
CREATE OR REPLACE FUNCTION public.refresh_axs_performer_stat_card()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  TRUNCATE public.axs_performer_stat_card;

  INSERT INTO public.axs_performer_stat_card
    (axs_artist_id, axs_performer, tevo_performer_id, as_of, event_count, priced_event_count,
     getin_min, getin_median, listings_total, seats_primary_total, seats_resale_total, computed_at)
  WITH snap AS (
    SELECT DISTINCT ON (axs_event_id) axs_event_id, getin, listings_count, seats_primary, seats_resale
    FROM public.axs_event_snapshots
    ORDER BY axs_event_id, captured_at DESC
  ),
  j AS (
    SELECT x.axs_artist_id, x.axs_performer, x.tevo_performer_id,
           s.getin, s.listings_count, s.seats_primary, s.seats_resale
    FROM public.axs_event_performer_xref x
    JOIN snap s ON s.axs_event_id = x.axs_event_id
    WHERE x.axs_performer IS NOT NULL
  )
  SELECT
    axs_artist_id,
    max(axs_performer),
    max(tevo_performer_id),
    current_date,
    count(*)::int,
    count(*) FILTER (WHERE getin IS NOT NULL)::int,
    round(min(getin)::numeric, 2),
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY getin)::numeric, 2),
    sum(listings_count)::bigint,
    sum(seats_primary)::bigint,
    sum(seats_resale)::bigint,
    now()
  FROM j
  GROUP BY axs_artist_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_axs_performer_stat_card() FROM PUBLIC;

-- ============================================================
-- 4. Merge bridged AXS stats onto the canonical performer_stat_card
-- ============================================================
CREATE OR REPLACE FUNCTION public.merge_axs_into_performer_stat_card()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  -- clear stale AXS-source fields first (an artist may have dropped off AXS)
  UPDATE public.performer_stat_card
     SET axs_event_count = NULL, axs_getin_min = NULL, axs_getin_median = NULL,
         axs_listings = NULL, axs_as_of = NULL
   WHERE axs_event_count IS NOT NULL;

  WITH agg AS (
    SELECT tevo_performer_id,
           sum(event_count)::int          AS axs_event_count,
           min(getin_min)                 AS axs_getin_min,
           min(getin_median)              AS axs_getin_median,  -- representative (usually 1 artist/performer)
           sum(listings_total)::bigint    AS axs_listings,
           max(as_of)                     AS axs_as_of
    FROM public.axs_performer_stat_card
    WHERE tevo_performer_id IS NOT NULL
    GROUP BY tevo_performer_id
  )
  UPDATE public.performer_stat_card t
     SET axs_event_count = a.axs_event_count, axs_getin_min = a.axs_getin_min,
         axs_getin_median = a.axs_getin_median, axs_listings = a.axs_listings, axs_as_of = a.axs_as_of
    FROM agg a
   WHERE t.performer_id = a.tevo_performer_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.merge_axs_into_performer_stat_card() FROM PUBLIC;

-- ============================================================
-- 5. Daily orchestrator: match → refresh AXS card → merge
-- ============================================================
CREATE OR REPLACE FUNCTION public.run_axs_match_and_merge()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_matched integer; v_axs integer; v_merged integer;
BEGIN
  v_matched := public.match_axs_events_to_performers();
  v_axs     := public.refresh_axs_performer_stat_card();
  v_merged  := public.merge_axs_into_performer_stat_card();
  RETURN jsonb_build_object('matched_events', v_matched, 'axs_artists', v_axs, 'merged_into_canonical', v_merged);
END;
$func$;

REVOKE ALL ON FUNCTION public.run_axs_match_and_merge() FROM PUBLIC;

-- ============================================================
-- 6. Read RPC — AXS stat-cards (gated). p_only_unmatched=true = the AXS-only set.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_axs_stat_cards(p_limit integer DEFAULT 100, p_only_unmatched boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.listings_total DESC NULLS LAST), '[]'::jsonb)
  INTO v_result
  FROM (SELECT * FROM public.axs_performer_stat_card
        WHERE (NOT p_only_unmatched) OR tevo_performer_id IS NULL
        ORDER BY listings_total DESC NULLS LAST
        LIMIT greatest(1, least(coalesce(p_limit,100), 500))) s;
  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_axs_stat_cards(integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_axs_stat_cards(integer, boolean) TO anon, authenticated;

COMMENT ON FUNCTION public.get_axs_stat_cards(integer, boolean) IS
  'D0 AXS performer stat-cards; p_only_unmatched=true returns the AXS-only (no EVO bridge) set. @s4kent.com-gated SECDEF read.';

-- ============================================================
-- 7. Backfill + reschedule the daily cron to the orchestrator
-- ============================================================
SELECT public.run_axs_match_and_merge();

DO $cron$
BEGIN
  PERFORM cron.unschedule('axs-performer-match');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$cron$;

-- Daily 07:25 UTC — match + AXS stat refresh + merge in one pass.
SELECT cron.schedule('axs-performer-match', '25 7 * * *', $cron$
  SELECT public.run_axs_match_and_merge();
$cron$);
