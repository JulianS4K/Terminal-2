-- Migration 20260927030000 · level:secondary-sales · lane:D7 · writes:n2s_pipeline_tick · reads:none · pre:20260927023400
--
-- Already applied to prod · via MCP 2026-09-27 02:48 UTC under operator direction
-- ("for this specific project only poll for new orders not the entire book"),
-- after a rolled-back dry run.
--
-- ============================================================================
-- The tick fetched CRM pages 0, 150 and 300 every run. New orders always land
-- on page 0 (880/880 over 7 days); pages 150/300 only re-read orders already
-- past the 10-minute N2S window, and each page is a separate ~114 s request.
-- Now: page 0 only (n2s_crm_fetch_direct also fetches page 0).
-- ============================================================================

DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_pipeline_tick'::regproc);
  v_old text := E'    PERFORM public.n2s_items_queue(150, 0);\n    PERFORM public.n2s_items_queue(150, 150);\n    PERFORM public.n2s_items_queue(150, 300);\n';
  v_new text := E'    -- new orders only: they always land on page 0 (880/880 over 7 days); older\n    -- pages only re-read orders past the 10-minute N2S window (20260927030000).\n    PERFORM public.n2s_items_queue(150, 0);\n';
BEGIN
  IF md5(v_def) <> '3ba6233019ee320937ec8420cc2da0a8' THEN
    RAISE EXCEPTION 'n2s_pipeline_tick drifted from the reviewed body — refusing';
  END IF;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick: 3-page block not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- rollback: re-add PERFORM public.n2s_items_queue(150, 150); and (150, 300);
-- after the page-0 call in n2s_pipeline_tick.
