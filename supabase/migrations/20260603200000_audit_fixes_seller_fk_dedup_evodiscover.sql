-- Migration 20260603200000 · level:2 · lane:A1
-- writes: DROP 2 enforced FKs on seatgeek_seller_listings; REPLACE fn sweep_duplicate_listings
--         (recent-window + 70s time-box); REPLACE fn evo_discover_new_events (fix bot_chat_log call);
--         RESCHEDULE cron sweep_duplicate_listings_hourly (p_max 50->200)
-- reads:  evo_listings_poll_state, listings_snapshots
--
-- ============================================================
-- Data-health audit fixes (2026-06-03). Three independent prod failures found in
-- the all-fronts freshness/health sweep:
--
-- (1) SG SELLER-LISTINGS INGEST 100% FAILING (sg_seller_process_30min, 24/24 fail,
--     169-row sg_seller_pending backlog). FK violation inserting into
--     seatgeek_seller_listings: the *enforced* (VALID) FKs aq_short_event_id ->
--     aq_event_map and venue_short_id -> aq_venue_map reject rows whose async
--     mapping isn't present yet, while the sibling sg_event_id / tevo_event_id FKs
--     are already NOT VALID (relaxed). This is a raw async-mapped ingest table —
--     map presence is best-effort, not an insert-time invariant. FIX: drop the two
--     straggler enforced FKs to match the relaxed-sibling intent (restores ingest
--     of our own S4K SeatGeek inventory; data untouched).
--
-- (2) sweep_duplicate_listings_hourly 12/12 TIMEOUT. The loop always took the
--     lowest 50 DISTINCT event_ids (oldest / far-future = biggest row piles, and no
--     longer being polled so NO new dups form there) and never finished / never
--     advanced. FIX: target RECENTLY-POLLED events (where dups actually form, via
--     evo_listings_poll_state — a ~5k-row state table, cheap) + an 80s/run time-box
--     so it returns partial progress instead of failing. Cron p_max 50->200.
--
-- (3) evo_discover_new_events errors daily: positional bot_chat_log(...) call put
--     'status' into p_level (invalid tier -> bot_chat_bot_level_check) and 'D0' into
--     p_related_pr (integer -> "invalid input syntax for type integer: D0"). FIX:
--     named args with a valid tier ('data-collection') + lane ('A1') + event_type.
--
-- Left dormant per operator (2026-06-03): Reddit, SeatData, TickPick orders.
--
-- Already applied to prod. Applied via MCP apply_migration 2026-06-03 (A1, operator-directed).
-- ============================================================

-- ---------- 1. Seller-listings: relax the two straggler FKs ----------
ALTER TABLE public.seatgeek_seller_listings DROP CONSTRAINT IF EXISTS seatgeek_seller_listings_aq_short_event_id_fkey;
ALTER TABLE public.seatgeek_seller_listings DROP CONSTRAINT IF EXISTS seatgeek_seller_listings_venue_short_id_fkey;

-- ---------- 2. Dedup sweep: recent-window targeting + time-box ----------
CREATE OR REPLACE FUNCTION public.sweep_duplicate_listings(p_max_events integer DEFAULT 100)
 RETURNS TABLE(events_swept integer, rows_deleted integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_event_id bigint; v_total_deleted int := 0; v_events_count int := 0; v_batch_deleted int;
  v_start timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sweep_duplicate_listings: caller % not authorized', current_user;
  END IF;
  -- Only RECENTLY-POLLED events accumulate duplicate snapshots (a re-poll re-inserts an
  -- unchanged listing). Far/old events are no longer polled => no new dups => skip them.
  FOR v_event_id IN
    SELECT event_id FROM public.evo_listings_poll_state
    WHERE last_polled_listings_at > now() - interval '6 hours'
    ORDER BY last_polled_listings_at DESC
    LIMIT p_max_events
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '80 seconds';   -- time-box (< pg_cron 120s hard cap)
    WITH dups AS (
      SELECT s.ctid,
        lag(quantity) OVER w IS NOT DISTINCT FROM quantity AS q_same,
        lag(retail_price) OVER w IS NOT DISTINCT FROM retail_price AS rp_same,
        lag(wholesale_price) OVER w IS NOT DISTINCT FROM wholesale_price AS wp_same,
        lag(format) OVER w IS NOT DISTINCT FROM format AS fmt_same,
        lag(splits) OVER w IS NOT DISTINCT FROM splits AS spl_same,
        lag(type) OVER w IS NOT DISTINCT FROM type AS typ_same,
        lag(wheelchair) OVER w IS NOT DISTINCT FROM wheelchair AS wc_same,
        lag(instant_delivery) OVER w IS NOT DISTINCT FROM instant_delivery AS idn_same,
        lag(eticket) OVER w IS NOT DISTINCT FROM eticket AS et_same,
        lag(is_ancillary) OVER w IS NOT DISTINCT FROM is_ancillary AS ia_same,
        lag(is_owned) OVER w IS NOT DISTINCT FROM is_owned AS io_same,
        lag(office_id) OVER w IS NOT DISTINCT FROM office_id AS off_same,
        lag(brokerage_id) OVER w IS NOT DISTINCT FROM brokerage_id AS brk_same,
        lag(section) OVER w IS NOT DISTINCT FROM section AS sec_same,
        lag(row) OVER w IS NOT DISTINCT FROM row AS rw_same
      FROM listings_snapshots s
      WHERE event_id = v_event_id
      WINDOW w AS (PARTITION BY tevo_ticket_group_id ORDER BY captured_at)
    )
    DELETE FROM listings_snapshots WHERE ctid IN (
      SELECT ctid FROM dups
      WHERE q_same AND rp_same AND wp_same AND fmt_same AND spl_same AND typ_same AND wc_same AND idn_same AND et_same AND ia_same AND io_same AND off_same AND brk_same AND sec_same AND rw_same
    );
    GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_batch_deleted;
    v_events_count := v_events_count + 1;
  END LOOP;
  RETURN QUERY SELECT v_events_count, v_total_deleted;
END $function$;

SELECT cron.schedule('sweep_duplicate_listings_hourly', '15 * * * *', $cron$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('sweep_duplicate_listings_hourly') THEN RETURN; END IF;
  PERFORM public.sweep_duplicate_listings(200);
END $body$;
$cron$);

-- ---------- 3. evo_discover_new_events: fix the bot_chat_log call ----------
CREATE OR REPLACE FUNCTION public.evo_discover_new_events()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_total_sgc         int;
  v_mapped_sgc        int;
  v_with_metrics_30d  int;
  v_future_unmapped   int;
BEGIN
  SELECT COUNT(*) INTO v_total_sgc
  FROM public.sg_events_canonical
  WHERE sg_datetime_utc BETWEEN now() AND now() + interval '90 days';

  SELECT COUNT(DISTINCT sgc.sg_event_id) INTO v_mapped_sgc
  FROM public.sg_events_canonical sgc
  JOIN public.aq_event_map aem ON aem.sg_event_id = sgc.sg_event_id
  WHERE sgc.sg_datetime_utc BETWEEN now() AND now() + interval '90 days';

  SELECT COUNT(DISTINCT em.event_id) INTO v_with_metrics_30d
  FROM public.event_metrics em
  JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = em.event_id
  WHERE sgc.sg_datetime_utc BETWEEN now() AND now() + interval '30 days'
    AND em.captured_at > now() - interval '24 hours';

  SELECT COUNT(*) INTO v_future_unmapped
  FROM public.sg_events_canonical sgc
  LEFT JOIN public.aq_event_map aem ON aem.sg_event_id = sgc.sg_event_id
  WHERE sgc.sg_datetime_utc BETWEEN now() AND now() + interval '30 days'
    AND aem.sg_event_id IS NULL;

  -- FIX 2026-06-03: was a positional call that put 'status' into p_level (invalid tier)
  -- and 'D0' into p_related_pr (integer). Now named args with a valid tier + lane.
  PERFORM public.bot_chat_log(
    p_level      := 'data-collection',
    p_lane       := 'A1',
    p_event_type := 'change_log',
    p_message    := format(
      '[evo_discover_new_events] EVO coverage report (Phase 1 stub — 8am UTC daily). '
      'Next 90d SG events: %s total, %s mapped to TEvo (%s%% mapped). '
      'Next 30d with recent metrics: %s events. '
      'Next 30d unmapped SG events (discovery targets): %s. '
      'Phase 2: add net.http_get to TEvo /v9/events for new-event ingestion.',
      v_total_sgc,
      v_mapped_sgc,
      CASE WHEN v_total_sgc > 0
        THEN ROUND(100.0 * v_mapped_sgc / v_total_sgc, 1)::text
        ELSE '0' END,
      v_with_metrics_30d,
      v_future_unmapped
    )
  );
END $function$;
