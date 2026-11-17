-- ============================================================================
-- Migration 20260910340000 — say "never catalogued", don't say "no match"
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_pull_all_sources() (DROP/CREATE — propagates the new counter),
--           v_n2s_orders (CREATE OR REPLACE VIEW — new no_cover_reason value).
-- Pre-reqs: 20260910330000
--
-- READ-ONLY upstream: no API call. RULE 2 untouched.
--
-- Two review findings against 20260910330000, both of the same shape: that
-- migration stopped an uncatalogued event from CRASHING the pull, but left it
-- INVISIBLE afterwards — which was the failure mode it set out to avoid.
--
-- ── 1. THE COUNTER WAS RETURNED BUT NEVER PROPAGATED ──────────────────────
-- 20260910330000's header promises the skip is "counted, not a silent
-- swallow". It is not: n2s_pull_events() returns evo_skipped_unknown, but
-- n2s_pull_all_sources() — its only caller, and what cron actually runs —
-- did not carry the column out. So a loud 23503 became no error, no log and
-- no counter, which is strictly worse for diagnosis than the crash was. The
-- sweep now surfaces it.
--
-- ── 2. THE PANEL CLAIMED WE HAD SEARCHED WHEN WE HAD NOT ──────────────────
-- n2s_pull_all_sources() stamps sources_pulled_at on every order it selected,
-- including ones whose event was skipped. v_n2s_orders reads that stamp as
-- "sources were pulled", so no_cover_reason fell through to 'no_match' —
-- literally "listings were searched; none had the same section, an
-- equal-or-better row and a usable quantity". Nothing was searched. The three
-- existing reasons exist precisely because "we never looked" and "we looked
-- and found nothing" call for opposite responses, and this collapsed them.
--
-- A fourth value, 'event_not_catalogued', is added AHEAD of the pulled-at
-- test, so the catalogue gap outranks the stamp. It means: the obligation is
-- mapped to a real TEvo event that we have never ingested, so no TEvo listing
-- can be pulled for it and nothing was searched. The fix is to ingest the
-- event (evo_event_backfill_pending accepts reason='manual'), not to hunt for
-- inventory that was never queried.
--
-- ⚠ ORDER MATTERS IN THIS CASE EXPRESSION. 'event_not_catalogued' must come
-- after the has-cover and unmapped tests (a covered row needs no reason, and
-- an unmapped row has no event id to look up) but BEFORE
-- awaiting_source_pull/no_match, both of which are statements about a pull
-- that cannot have happened.
-- ============================================================================

DROP FUNCTION IF EXISTS public.n2s_pull_all_sources(integer,interval,interval,boolean,integer);

CREATE FUNCTION public.n2s_pull_all_sources(
  p_max           integer  DEFAULT 10,
  p_refresh_after interval DEFAULT interval '5 minutes',
  p_sweep_after   interval DEFAULT interval '20 minutes',
  p_uncovered_only boolean DEFAULT true,
  p_new_max       integer  DEFAULT 200
)
RETURNS TABLE(orders integer, new_orders integer, evo_fired integer, gt_fired integer,
              sg_queued integer, td_queued integer,
              sg_orders_stored integer, sg_prices_filled integer,
              evo_skipped_fresh integer, gt_skipped_fresh integer,
              evo_skipped_unknown integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_ids bigint[]; v_events bigint[]; p RECORD; v_new int := 0;
  v_sg_stored int := 0; v_sg_fill int := 0;
BEGIN
  BEGIN
    SELECT d.stored, d.prices_filled INTO v_sg_stored, v_sg_fill
      FROM public.n2s_sg_drain() d;
    PERFORM public.n2s_sg_queue(10);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_all_sources: seatgeek order enrich failed: %', SQLERRM;
    v_sg_stored := 0; v_sg_fill := 0;
  END;

  WITH newly AS (
    SELECT i.n2s_id, i.tevo_event_id
      FROM public.n2s_items i
     WHERE i.tevo_event_id IS NOT NULL
       AND NOT i.is_terminal
       AND i.event_dt::date >= current_date
       AND i.sources_pulled_at IS NULL
     ORDER BY i.alert_at DESC
     LIMIT p_new_max
  ),
  sweep AS (
    SELECT i.n2s_id, i.tevo_event_id
      FROM public.n2s_items i
     WHERE i.tevo_event_id IS NOT NULL
       AND NOT i.is_terminal
       AND i.event_dt::date >= current_date
       AND i.sources_pulled_at < now() - p_sweep_after
       AND (NOT p_uncovered_only
            OR NOT EXISTS (SELECT 1 FROM public.n2s_cover_queue q
                            WHERE q.n2s_id = i.n2s_id))
     ORDER BY i.sources_pulled_at ASC
     LIMIT p_max
  )
  SELECT array_agg(x.n2s_id), array_agg(DISTINCT x.tevo_event_id),
         count(*) FILTER (WHERE x.is_new)
    INTO v_ids, v_events, v_new
    FROM (SELECT n2s_id, tevo_event_id, true  AS is_new FROM newly
          UNION ALL
          SELECT n2s_id, tevo_event_id, false            FROM sweep) x;

  IF v_events IS NULL OR cardinality(v_events) = 0 THEN
    RETURN QUERY SELECT 0,0,0,0,0,0,
                        COALESCE(v_sg_stored,0), COALESCE(v_sg_fill,0), 0, 0, 0;
    RETURN;
  END IF;

  SELECT * INTO p FROM public.n2s_pull_events(v_events, p_refresh_after);

  UPDATE public.n2s_items SET sources_pulled_at = now() WHERE n2s_id = ANY(v_ids);

  RETURN QUERY SELECT cardinality(v_ids), COALESCE(v_new,0), p.evo_fired, p.gt_fired,
                      p.sg_queued, p.td_queued,
                      COALESCE(v_sg_stored,0), COALESCE(v_sg_fill,0),
                      p.evo_skipped_fresh, p.gt_skipped_fresh,
                      COALESCE(p.evo_skipped_unknown, 0);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_pull_all_sources(integer,interval,interval,boolean,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_pull_all_sources(integer,interval,interval,boolean,integer) TO service_role;

CREATE OR REPLACE VIEW public.v_n2s_orders AS
 SELECT n.n2s_id,
    n.order_number,
    n.s4k_source,
    n.status AS n2s_status,
    n.status_label,
    n.fail_reason,
    n.timer_expired,
    n.alert_at,
    n.timer_expires_at,
    n.event_name,
    n.event_dt::date AS event_date,
    n.event_dt,
    n.venue,
    n.tevo_event_id,
    n.mapped_via,
    n.sources_pulled_at,
    n.section,
    n."row" AS order_row,
    n.qty AS quantity,
    n.price_per_ticket AS sold_ea,
    n.grand_total AS sold_total,
    c.sub_source,
    c.sub_listing_id,
    c.sub_section,
    c.sub_row,
    c.sub_qty,
    c.sub_ea,
    c.sub_total,
    c.cover_cost,
    c.rows_closer,
    c.buy_url,
    c.captured_at,
    c.cover_rank,
    c.fifo_position,
    c.refreshed_at,
    c.n2s_id IS NOT NULL AS has_cover,
        CASE
            WHEN c.n2s_id IS NOT NULL THEN NULL::text
            WHEN n.tevo_event_id IS NULL THEN 'unmapped'::text
            WHEN NOT EXISTS (SELECT 1 FROM public.events e
                              WHERE e.id = n.tevo_event_id)
                 THEN 'event_not_catalogued'::text
            WHEN n.sources_pulled_at IS NULL THEN 'awaiting_source_pull'::text
            ELSE 'no_match'::text
        END AS no_cover_reason,
    b.intent_id AS open_intent_id,
    b.requested_by AS open_intent_by,
    c.sub_avail,
    n.n2s_order_key
   FROM n2s_items n
     LEFT JOIN n2s_cover_queue c ON c.n2s_id = n.n2s_id
     LEFT JOIN n2s_buy_intent b ON b.n2s_id = n.n2s_id AND b.status = 'requested'::text
  WHERE NOT n.is_terminal AND n.event_dt::date >= CURRENT_DATE;
