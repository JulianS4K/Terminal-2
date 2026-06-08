-- ============================================================================
-- MIG 20260608193000 — TD 402 handler also disables the TP + TM enqueue crons
--
-- KANBAN A1-OPS-13. On a 402 (quota exhausted) from TicketsData, td_normalize_drain
-- disables the TD crons — but the jobname IN (...) list only covered
-- td_pull_drain / td_normalize_drain / td_enqueue_peak_sh / _vd / _gt. The TP and
-- TM enqueue crons (td_enqueue_peak_tp, td_enqueue_peak_tm — both live + active,
-- verified 2026-06-08) were NOT in the list, so they keep enqueuing peak events
-- after the quota is gone (wasteful + inconsistent). This adds them.
--
-- Only the 402-branch jobname list changes; the rest of td_normalize_drain is
-- reproduced verbatim from the live prod definition (pg_get_functiondef,
-- 2026-06-08) so CREATE OR REPLACE is a faithful one-line edit.
--
-- ⏳ NOT YET APPLIED — pending operator apply_migration (no prod mutation here).
--    After apply, change this banner to "Already applied to prod  Applied via MCP YYYY-MM-DD".
-- ============================================================================

CREATE OR REPLACE FUNCTION public.td_normalize_drain(p_max integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r          RECORD;
  listing    RECORD;
  v_sc       int;
  v_quota    int;
  v_hash     text;
  v_count    int := 0;
  v_inserted int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_normalize_drain') THEN RETURN 0; END IF;

  FOR r IN
    SELECT
      p.id, p.event_id, p.platform, p.event_url, p.interval_tag, p.retry_count,
      h.status_code AS http_sc,
      h.content     AS raw_content
    FROM public.td_pull_queue p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL AND p.request_id IS NOT NULL
    ORDER BY p.fired_at ASC
    LIMIT p_max
  LOOP
    BEGIN
      v_sc    := COALESCE((r.raw_content::jsonb->>'status')::int,
                          (r.raw_content::jsonb->>'status_code')::int,
                          r.http_sc);
      v_quota := (r.raw_content::jsonb->>'quota_remaining')::int;

      IF v_sc = 200 THEN
        v_inserted := 0;
        FOR listing IN
          SELECT * FROM public.ticketsdata_normalize_listings(r.platform, r.raw_content::jsonb)
        LOOP
          v_hash := md5(listing.raw::text);
          INSERT INTO public.ticketsdata_listings_snapshots
            (event_id, platform, td_listing_id, section, row, quantity,
             list_price, price_with_fees, is_parking, content_hash, raw)
          VALUES
            (r.event_id, r.platform, listing.td_listing_id, listing.section,
             listing.row, listing.quantity, listing.list_price,
             listing.price_with_fees, listing.is_parking, v_hash, listing.raw)
          ON CONFLICT (event_id, platform, content_hash) DO NOTHING;
          v_inserted := v_inserted + 1;
        END LOOP;

        UPDATE public.td_pull_queue
        SET resolved_at   = clock_timestamp(), status_code = 200,
            credits_used  = 1, rows_inserted = v_inserted
        WHERE id = r.id;

        PERFORM public.td_charge_credit(1, r.event_id, r.platform, '/fetch', 200, v_quota);

        UPDATE public.ticketsdata_event_xref
        SET last_fetched_at = clock_timestamp(), updated_at = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);

      ELSIF v_sc IN (429, 503) AND r.retry_count < 2 THEN
        INSERT INTO public.td_pull_queue
          (event_id, platform, event_url, interval_tag, retry_count)
        VALUES (r.event_id, r.platform, r.event_url, r.interval_tag, r.retry_count + 1);
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = v_sc,
            error_msg   = CASE v_sc WHEN 429 THEN 'rate_limited_requeued'
                                              ELSE 'service_unavailable_requeued' END
        WHERE id = r.id;

      ELSIF v_sc = 504 AND r.retry_count < 1 THEN
        INSERT INTO public.td_pull_queue
          (event_id, platform, event_url, interval_tag, retry_count)
        VALUES (r.event_id, r.platform, r.event_url, r.interval_tag, r.retry_count + 1);
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 504, error_msg = 'timeout_requeued'
        WHERE id = r.id;

      ELSIF v_sc = 402 THEN
        UPDATE public.cron_policy
        SET enabled    = false,
            notes      = notes || ' [DISABLED 402 quota_exhausted ' || now()::date::text || ']',
            updated_at = now()
        WHERE jobname IN ('td_pull_drain','td_normalize_drain',
                          'td_enqueue_peak_sh','td_enqueue_peak_vd','td_enqueue_peak_gt',
                          'td_enqueue_peak_tp','td_enqueue_peak_tm');
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 402,
            error_msg   = 'quota_exhausted — td crons disabled'
        WHERE id = r.id;
        RAISE NOTICE 'td_normalize_drain: 402 quota exhausted — TD crons disabled';
        EXIT;

      ELSIF v_sc = 403 THEN
        UPDATE public.ticketsdata_event_xref
        SET active = false, meta = meta || jsonb_build_object('403_at', now()),
            updated_at = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 403,
            error_msg = 'access_denied — xref deactivated'
        WHERE id = r.id;

      ELSIF v_sc = 404 THEN
        UPDATE public.ticketsdata_event_xref
        SET active = false, meta = meta || jsonb_build_object('404_at', now()),
            updated_at = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 404,
            error_msg = 'event_not_found — xref deactivated'
        WHERE id = r.id;

      ELSIF v_sc = 401 THEN
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = 401,
            error_msg = 'invalid_credentials'
        WHERE id = r.id;
        RAISE EXCEPTION 'td_normalize_drain: 401 invalid credentials — check TICKETSDATA vault secrets';

      ELSE
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = v_sc,
            error_msg   = left(r.raw_content, 500)
        WHERE id = r.id;

      END IF;

      v_count := v_count + 1;

    EXCEPTION
      WHEN query_canceled THEN
        RAISE NOTICE 'td_normalize_drain: query_canceled at row % — exiting gracefully', r.id;
        EXIT;
      WHEN OTHERS THEN
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(), status_code = -1, error_msg = left(SQLERRM, 500)
        WHERE id = r.id;
    END;
  END LOOP;

  RETURN v_count;
END $function$;
