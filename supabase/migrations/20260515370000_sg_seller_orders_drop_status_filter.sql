-- Migration 20260515370000 · admin · fix sg_seller_orders_queue per-status loop · pre:20260515360000
-- D2 (bot_chat 154) root-caused the 89% silent-success: SG renamed `statuses=` (multi-value)
-- → `status=` (singular). Function was sending `status=open,pending,confirmed,fulfilled` (CSV)
-- which SG treats as a single string and matches zero orders.
--
-- First attempt (drop filter entirely) returned 400 "Status is required" (SG error 400114).
-- Final fix: loop over each of the 4 status values, fire 4 net.http_get per tick. Each
-- inserts a separate row into sg_seller_pending; process fn already iterates them all.
--
-- Result on first manual fire: 200 confirmed + 200 fulfilled rows ingested. Upstream
-- shows 6,106 confirmed + 501,118 fulfilled total — pagination follow-up needed to capture
-- the historical tail (out of scope here).

CREATE OR REPLACE FUNCTION public.sg_seller_orders_queue(p_pages int DEFAULT 1, p_statuses text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  v_req_id bigint;
  v_status text;
  v_count int := 0;
  v_statuses text[] := coalesce(
    string_to_array(p_statuses, ','),
    ARRAY['open','pending','confirmed','fulfilled']
  );
BEGIN
  PERFORM p_pages;
  FOREACH v_status IN ARRAY v_statuses LOOP
    SELECT net.http_get(
      url := 'https://sellerdirect-api.seatgeek.com/orders?per_page=200&status='
             || trim(v_status) || '&token=' || v_token,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO sg_seller_pending(request_id, scope, page, per_page, status_csv)
    VALUES (v_req_id, 'orders', 1, 200, trim(v_status));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;
