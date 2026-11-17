-- Migration 20261021223000 · level:secondary-sales · lane:D7 · writes:n2s_gt_order_dryrun_trg · reads:none · pre:20261021180000
--
-- GoTickets auto-buy DRY RUN: would_buy only on gate 1 ("Index") covers.
--
-- Operator direction 2026-10-21, after the first dry-run row was a gate-2
-- (S4KTrading) cover at a $311.64 loss: "Only dry run 1-1 index matches".
-- Gate 1 is the same-section, profitable tier; gate 2 (S4KTrading) is the
-- same-section tier that permits a loss, and 3-6 move the buyer. Gates 2-6
-- are still LOGGED, as 'skip' with gate_moves_buyer in skip_reasons, so the
-- log keeps showing what was passed over.
--
-- Still nothing is sent: this only changes the gate list the trigger passes.
--
-- Already applied to prod · via MCP 2026-10-21 under operator direction.
--
-- rollback: re-create n2s_gt_order_dryrun_trg() with '{1,2}' (20261021180000).

CREATE OR REPLACE FUNCTION public.n2s_gt_order_dryrun_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  BEGIN
    PERFORM public.n2s_gt_order_dryrun_capture(2000, 15000, '{1}');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'n2s_gt_order_dryrun_capture failed: % (%)', SQLERRM, SQLSTATE;
  END;
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_gt_order_dryrun_trg() FROM PUBLIC, anon;
