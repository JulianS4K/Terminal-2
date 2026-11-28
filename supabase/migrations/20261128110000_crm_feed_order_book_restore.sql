-- Migration 20261128110000 · level:secondary-sales · lane:a1 (the CRM readers: N2S feed, order book) · writes:s4kcs_orders_process()(patched in place: errors/rows that are not arrays read as empty),cron n2s_crm_direct_20s(command: 250 -> 16 items, temporary) · reads:—
--
-- THE CRM's FEED AND ORDER BOOK, BACK UP. Operator 2026-11-28: "look into crm_feed and order_book and bring back up
-- if off". GET /health had both `down` since 2026-11-27 08:37 UTC, the same minute, for two different reasons.
--
-- ORDER BOOK. s4kcs_orders_process() failed every 10 minutes with "cannot get array length of a scalar" (line 83,
-- `IF jsonb_array_length(v_errors) > 0`). The CRM's GET /api/v1/marketplace/orders answers `"errors": null` when no
-- marketplace failed; COALESCE does not replace a JSON null, so the length of a scalar was asked and the function
-- failed AFTER writing the orders, rolling them back: s4kcs_orders.last_seen_at stopped at 2026-11-27 08:37. (A read
-- made while diagnosing returned errors as a list, a GoTickets 429, which is why some hours could have gone through
-- and none did.) Now `errors` and `rows` count only when they are arrays; anything else reads as empty.
--
-- CRM FEED. n2s_crm_fetch_direct(250, 0, 25000) got HTTP 500 from GET /api/v1/n2s/items at every try since 08:37
-- (about 2,500 a day, each in ~45 ms: the CRM's "Something went wrong on our side"). Measured 2026-11-28 05:2x UTC: the
-- feed answers for offsets 0 to 15 and fails for every request that reaches the 17th item (limit=1 at offset 16,
-- 17, ... 99 all 500; limit=100/150/200/250 at offset 0 all 500). One item there breaks the CRM's own serialisation:
-- a CRM bug, which only the CRM can fix (request ids such as 8c750778 for offset 16). Until then the reader asks for
-- the 16 items it can get: the newest Need-to-Sub items (all open `n2s` items, the newest 16 created from
-- 2026-11-27 23:49 UTC on), which is what starts a lookup. Items further down (older items whose status changes) are
-- not refreshed meanwhile.
-- UNDO once the CRM is fixed (a 200 for limit=250):
--   SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_crm_direct_20s'),
--                         command := 'SELECT public.n2s_crm_fetch_direct(250, 0, 25000);');

BEGIN;

DO $surgery$
DECLARE
  v_src text;
  v_err_old text := $a$v_errors := COALESCE(v_body->'errors', '[]'::jsonb);$a$;
  v_err_new text := $a$v_errors := CASE WHEN jsonb_typeof(v_body->'errors') = 'array' THEN v_body->'errors' ELSE '[]'::jsonb END;  -- "errors": null is not a list (mig 20261128110000)$a$;
  v_rows_old text := $a$v_rows := COALESCE(v_body->'rows', '[]'::jsonb);$a$;
  v_rows_new text := $a$v_rows := CASE WHEN jsonb_typeof(v_body->'rows') = 'array' THEN v_body->'rows' ELSE '[]'::jsonb END;$a$;
BEGIN
  IF to_regprocedure('public.s4kcs_orders_process()') IS NULL THEN
    RAISE NOTICE 's4kcs_orders_process() not here: skipped';
    RETURN;
  END IF;
  SELECT pg_get_functiondef('public.s4kcs_orders_process()'::regprocedure) INTO v_src;
  IF position('mig 20261128110000' in v_src) > 0 THEN
    RAISE NOTICE 's4kcs_orders_process already patched';
    RETURN;
  END IF;
  IF (length(v_src) - length(replace(v_src, v_err_old, ''))) / length(v_err_old) <> 1
     OR (length(v_src) - length(replace(v_src, v_rows_old, ''))) / length(v_rows_old) <> 1 THEN
    RAISE EXCEPTION 's4kcs_orders_process: the lines to patch are not there exactly once';
  END IF;
  EXECUTE replace(replace(v_src, v_err_old, v_err_new), v_rows_old, v_rows_new);
END $surgery$;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'n2s_crm_direct_20s') THEN
    PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_crm_direct_20s'),
                           command := 'SELECT public.n2s_crm_fetch_direct(16, 0, 25000);');
  END IF;
END $cron$;

COMMIT;
