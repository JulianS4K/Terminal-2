-- Migration 20260513000050 · level:supervisor · lane:canonical · writes:sweep_duplicate_listings,sweep_terminal_event_listings,match_listings_to_sg_tick · reads:- · pre:20260513000000

-- Defense-in-depth follow-up to PR #67. A1's #67 closed the grant model
-- (REVOKE FROM PUBLIC + explicit GRANT TO service_role). This migration
-- adds body-level current_user assertions to the same 3 SECURITY DEFINER
-- functions — matches the pattern C1 established in 20260511010000 (bot_chat)
-- and 20260512200000 (pg_net retention sweep).
--
-- Why both gate + body assert: if anyone widens a grant by mistake (e.g.
-- "GRANT EXECUTE … TO authenticated" added by some future migration), the
-- function still rejects non-service_role callers. Belt-and-suspenders.
--
-- All function bodies preserved byte-for-byte; only the IF current_user
-- check at line 1 of the BEGIN block is new.
--
-- Going forward (proposed §6/§12 convention update): every SECURITY DEFINER
-- function ships in one migration with: REVOKE FROM PUBLIC + explicit GRANT
-- TO service_role + current_user assertion at body. Three lines together,
-- every time.

CREATE OR REPLACE FUNCTION public.sweep_duplicate_listings(p_max_events int DEFAULT 100)
RETURNS TABLE(events_swept int, rows_deleted int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event_id bigint;
  v_total_deleted int := 0;
  v_events_count int := 0;
  v_batch_deleted int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sweep_duplicate_listings: caller % not authorized', current_user;
  END IF;
  FOR v_event_id IN
    SELECT DISTINCT event_id
    FROM listings_snapshots
    ORDER BY event_id
    LIMIT p_max_events
  LOOP
    WITH dups AS (
      SELECT s.ctid,
        lag(quantity)         OVER w IS NOT DISTINCT FROM quantity         AS q_same,
        lag(retail_price)     OVER w IS NOT DISTINCT FROM retail_price     AS rp_same,
        lag(wholesale_price)  OVER w IS NOT DISTINCT FROM wholesale_price  AS wp_same,
        lag(format)           OVER w IS NOT DISTINCT FROM format           AS fmt_same,
        lag(splits)           OVER w IS NOT DISTINCT FROM splits           AS spl_same,
        lag(type)             OVER w IS NOT DISTINCT FROM type             AS typ_same,
        lag(wheelchair)       OVER w IS NOT DISTINCT FROM wheelchair       AS wc_same,
        lag(instant_delivery) OVER w IS NOT DISTINCT FROM instant_delivery AS idn_same,
        lag(eticket)          OVER w IS NOT DISTINCT FROM eticket          AS et_same,
        lag(is_ancillary)     OVER w IS NOT DISTINCT FROM is_ancillary     AS ia_same,
        lag(is_owned)         OVER w IS NOT DISTINCT FROM is_owned         AS io_same,
        lag(office_id)        OVER w IS NOT DISTINCT FROM office_id        AS off_same,
        lag(brokerage_id)     OVER w IS NOT DISTINCT FROM brokerage_id     AS brk_same,
        lag(section)          OVER w IS NOT DISTINCT FROM section          AS sec_same,
        lag(row)              OVER w IS NOT DISTINCT FROM row              AS rw_same
      FROM listings_snapshots s
      WHERE event_id = v_event_id
      WINDOW w AS (PARTITION BY tevo_ticket_group_id ORDER BY captured_at)
    )
    DELETE FROM listings_snapshots WHERE ctid IN (
      SELECT ctid FROM dups
      WHERE q_same AND rp_same AND wp_same AND fmt_same AND spl_same AND typ_same
        AND wc_same AND idn_same AND et_same AND ia_same AND io_same AND off_same
        AND brk_same AND sec_same AND rw_same
    );
    GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_batch_deleted;
    v_events_count := v_events_count + 1;
  END LOOP;

  RETURN QUERY SELECT v_events_count, v_total_deleted;
END $$;

CREATE OR REPLACE FUNCTION public.sweep_terminal_event_listings(p_max_events int DEFAULT 50)
RETURNS TABLE(events_swept int, rows_deleted int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event_id bigint;
  v_total_deleted int := 0;
  v_events_count int := 0;
  v_batch_deleted int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sweep_terminal_event_listings: caller % not authorized', current_user;
  END IF;
  FOR v_event_id IN
    SELECT DISTINCT el.event_id
    FROM event_lifecycle el
    WHERE el.status IN ('ghost_eliminated', 'cancelled')
      AND EXISTS (SELECT 1 FROM listings_snapshots ls WHERE ls.event_id = el.event_id)
    ORDER BY el.event_id
    LIMIT p_max_events
  LOOP
    WITH ranked AS (
      SELECT captured_at,
        dense_rank() OVER (ORDER BY captured_at DESC) AS rk
      FROM (SELECT DISTINCT captured_at FROM listings_snapshots WHERE event_id = v_event_id) c
    ),
    keep_set AS (SELECT captured_at FROM ranked WHERE rk <= 5)
    DELETE FROM listings_snapshots
    WHERE event_id = v_event_id
      AND captured_at NOT IN (SELECT captured_at FROM keep_set);
    GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_batch_deleted;
    v_events_count := v_events_count + 1;
  END LOOP;
  RETURN QUERY SELECT v_events_count, v_total_deleted;
END $$;

CREATE OR REPLACE FUNCTION public.match_listings_to_sg_tick()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_matched int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'match_listings_to_sg_tick: caller % not authorized', current_user;
  END IF;
  WITH event_pairs AS (
    SELECT DISTINCT tevo_event_id FROM seatgeek_event_xref WHERE tevo_event_id IS NOT NULL
  ),
  tevo_latest AS (
    SELECT DISTINCT ON (event_id, tevo_ticket_group_id)
      event_id, tevo_ticket_group_id, section, row, quantity, retail_price, captured_at
    FROM listings_snapshots
    WHERE event_id IN (SELECT tevo_event_id FROM event_pairs)
      AND captured_at > now() - interval '24 hours'
    ORDER BY event_id, tevo_ticket_group_id, captured_at DESC
  ),
  sg_latest AS (
    SELECT DISTINCT ON (tevo_event_id, sglid)
      tevo_event_id, sglid::text AS sg_listing_id, section, row, quantity, broadcast_price, captured_at
    FROM seatgeek_listings_snapshots
    WHERE tevo_event_id IN (SELECT tevo_event_id FROM event_pairs)
      AND captured_at > now() - interval '24 hours'
    ORDER BY tevo_event_id, sglid, captured_at DESC
  ),
  candidates AS (
    SELECT
      t.tevo_ticket_group_id, s.sg_listing_id,
      t.captured_at AS captured_at_tevo, s.captured_at AS captured_at_sg,
      t.retail_price, s.broadcast_price,
      (abs(s.broadcast_price - t.retail_price) / NULLIF(t.retail_price, 0))::numeric AS price_spread
    FROM tevo_latest t
    JOIN sg_latest s ON s.tevo_event_id = t.event_id
    WHERE lower(trim(t.section)) = lower(trim(s.section))
      AND lower(trim(t.row)) IS NOT DISTINCT FROM lower(trim(s.row))
      AND t.quantity = s.quantity
      AND s.broadcast_price IS NOT NULL AND t.retail_price > 0
      AND abs(s.broadcast_price - t.retail_price) / t.retail_price < 0.15
  ),
  unique_pairs AS (
    SELECT * FROM candidates c
    WHERE NOT EXISTS (SELECT 1 FROM candidates c2
                        WHERE c2.tevo_ticket_group_id = c.tevo_ticket_group_id
                          AND c2.sg_listing_id <> c.sg_listing_id)
      AND NOT EXISTS (SELECT 1 FROM candidates c2
                        WHERE c2.sg_listing_id = c.sg_listing_id
                          AND c2.tevo_ticket_group_id <> c.tevo_ticket_group_id)
      AND NOT EXISTS (SELECT 1 FROM listing_xref lx
                        WHERE lx.tevo_ticket_group_id = c.tevo_ticket_group_id
                          AND lx.sg_listing_id = c.sg_listing_id
                          AND lx.captured_at_tevo = c.captured_at_tevo
                          AND lx.captured_at_sg = c.captured_at_sg)
  )
  INSERT INTO listing_xref
    (tevo_ticket_group_id, sg_listing_id, captured_at_tevo, captured_at_sg,
     confidence, match_method, price_spread_pct, meta)
  SELECT
    tevo_ticket_group_id, sg_listing_id, captured_at_tevo, captured_at_sg,
    0.80, 'broker_section_row_qty', price_spread,
    jsonb_build_object('tevo_price', retail_price, 'sg_price', broadcast_price,
                       'matched_at', now()::text, 'price_band', '15%')
  FROM unique_pairs;

  GET DIAGNOSTICS v_matched = ROW_COUNT;
  RETURN v_matched;
END $$;
