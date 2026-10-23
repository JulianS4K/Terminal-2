-- Migration 20261023044500 · level:ops · lane:A1 (data plane — retention) · writes:retention_policy(rows),venue_section_rollup_catchup()(replace) · reads:retention_policy · pre:20261023043520,20260911162500,20260705153500
--
-- ============================================================================
-- Migration 20261023044500 — retention ladder v3: 7-day raw listings, trend
--   layer indefinite
--
-- Lane:     A1. KANBAN A1-DATA-2 (operator 2026-10-23: "max put individual
--           listing retention at 7 days and adjust other retention accordingly";
--           long-term trends live on the daily layer).
-- Touches:  retention_policy rows (W):
--             listings_snapshots            15 → 7 d · keep_where evidence capped at 90 d
--             gotickets_listings_snapshots  15 → 7 d · keep_where evidence capped at 90 d
--             ticketsdata_listings_snapshots 30 → 7 d
--             event_section_row_snapshots   30 → 7 d
--             section_metrics               60 → 21 d (daily section medians are kept
--                                           forever in venue_section_price_daily)
--             event_metrics                 120 → 60 d (readers ≤ 45 d; the venue page's
--                                           90 d window moves to the daily table — D0 follow-up)
--             axs_seat_snapshots            enable, 15 → 7 d
--             axs_event_snapshots           enable, 30 d
--             zone_metrics                  NEW 60 d (1.6 GB, no policy today)
--           venue_section_rollup_catchup(int,int) (W: trailing window 70 → 14 d so the
--                                           rollup can never fall behind the 21 d raw window)
-- NOT touched: seatgeek_listings_snapshots / seatgeek_sales_snapshots — the
--   2026-09-11 never-purge directive (mig 20260911030000) stands until the
--   operator lifts it explicitly; SALES stay forever regardless. Orders/sales
--   tables, event_listing_snapshot_daily, performer_metrics_daily,
--   venue_section_price_daily, zone_price_observations, sg_market_chart,
--   performer_sales_daily: INDEFINITE (never in the policy table).
--
-- SAFE BECAUSE (verified 2026-10-23): compute_event_listing_snapshot reads raw
-- rows within 25 h; get_broker_event_page_v2's frontier reads 7 d; every
-- longer-window reader (refresh_cast_price_ref, the forecaster, movers) reads
-- event_metrics (now 60 d ≥ their 45 d) or the daily tables.
--
-- Depends on 20261023043520 (engine unstuck) — windows only take effect once
-- the tick runs; the first ticks after apply drain the backlog over ~2 days.
--
-- NOT APPLIED. Apply is operator-gated (CLAUDE.md §1: DML on retention_policy).
-- ============================================================================

UPDATE public.retention_policy SET keep_days = 7,
  keep_where = 'EXISTS (SELECT 1 FROM public.deal_listing_spell s WHERE s.source = ''evo'' AND s.listing_id = -t.tevo_ticket_group_id) AND t.captured_at > now() - interval ''90 days''',
  notes = coalesce(notes,'') || ' | v3 2026-10-23: 7 d (operator: no unsold listing beyond 7 d); deal evidence kept 90 d, not forever.',
  updated_at = now()
WHERE table_name = 'listings_snapshots';

UPDATE public.retention_policy SET keep_days = 7,
  keep_where = 'EXISTS (SELECT 1 FROM public.deal_listing_spell s WHERE s.source = ''gotickets'' AND s.listing_id = t.gt_listing_id) AND t.captured_at > now() - interval ''90 days''',
  notes = coalesce(notes,'') || ' | v3 2026-10-23: 7 d; deal evidence kept 90 d, not forever.',
  updated_at = now()
WHERE table_name = 'gotickets_listings_snapshots';

UPDATE public.retention_policy SET keep_days = 7,
  notes = coalesce(notes,'') || ' | v3 2026-10-23: 7 d.', updated_at = now()
WHERE table_name IN ('ticketsdata_listings_snapshots', 'event_section_row_snapshots');

UPDATE public.retention_policy SET keep_days = 21,
  notes = coalesce(notes,'') || ' | v3 2026-10-23: 21 d (daily section medians kept forever in venue_section_price_daily; catchup window 14 d).',
  updated_at = now()
WHERE table_name = 'section_metrics';

UPDATE public.retention_policy SET keep_days = 60,
  notes = coalesce(notes,'') || ' | v3 2026-10-23: 60 d (readers <= 45 d).', updated_at = now()
WHERE table_name = 'event_metrics';

UPDATE public.retention_policy SET enabled = true, keep_days = 7,
  notes = coalesce(notes,'') || ' | v3 2026-10-23: enabled at 7 d (operator: no unsold listing beyond 7 d).', updated_at = now()
WHERE table_name = 'axs_seat_snapshots';

UPDATE public.retention_policy SET enabled = true,
  notes = coalesce(notes,'') || ' | v3 2026-10-23: enabled at 30 d.', updated_at = now()
WHERE table_name = 'axs_event_snapshots';

INSERT INTO public.retention_policy (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes)
VALUES ('zone_metrics', 'captured_at', 60, true, 50000, 60, 45,
        'Per-zone aggregates — 60 d (v3 2026-10-23). Daily zone features kept forever in zone_price_observations.')
ON CONFLICT (table_name) DO UPDATE SET keep_days = 60, enabled = true, updated_at = now();

-- rollup catch-up window: 70 → 14 days (must stay inside the 21 d section_metrics window)
CREATE OR REPLACE FUNCTION public.venue_section_rollup_catchup(p_max_days integer DEFAULT 2, p_budget_seconds integer DEFAULT 200)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start timestamptz := clock_timestamp();
  v_today date := (now() AT TIME ZONE 'utc')::date;
  v_done  integer := 0;
  v_d     date;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: venue_section_rollup_catchup is service-only' USING ERRCODE='42501';
  END IF;

  FOR v_d IN
    SELECT d FROM (
      SELECT v_today AS d, 0 AS ord
      UNION ALL
      SELECT gs::date, 1
      FROM generate_series(v_today - 14, v_today - 1, interval '1 day') gs
      LEFT JOIN public.venue_section_rollup_state st ON st.snapshot_date = gs::date
      WHERE st.snapshot_date IS NULL
         OR st.processed_at < st.snapshot_date + interval '1 day'
    ) cand
    ORDER BY ord, d
    LIMIT p_max_days
  LOOP
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_seconds);
    PERFORM public.rollup_venue_section_price_daily(v_d);
    v_done := v_done + 1;
  END LOOP;

  IF v_done > 0 THEN
    PERFORM public.refresh_venue_section_aggs();
  END IF;

  RETURN v_done;
END $$;

-- ============================================================================
-- VERIFY: SELECT table_name, keep_days, enabled, left(keep_where,60) FROM public.retention_policy ORDER BY priority, table_name;
--   after ~2 days of ticks: min(captured_at) on listings_snapshots / gotickets_listings_snapshots ≈ now()-7 d
--   (except deal-evidence rows ≤ 90 d), section_metrics ≈ 21 d, event_metrics ≈ 60 d.
-- ROLLBACK: the previous values are in the notes trail (15/15/30/30/60/120; axs rows enabled=false; delete the zone_metrics row);
--   re-apply venue_section_rollup_catchup from mig 20260705153500 (70 d).
-- ============================================================================
