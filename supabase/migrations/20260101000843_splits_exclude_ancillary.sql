-- Migration 20260606180000 · lane:D0 (operator-authorized prod apply) · writes: get_broker_event_page_v2() · reads: listings_snapshots
--
-- ## Already applied to prod · Applied via MCP 2026-06-06 (operator-authorized)
--
-- Fix: the `splits` block of get_broker_event_page_v2 (the TEvo owned/market get-in
-- by split bucket -> min_px/avg_px/max_px, also the TEvo get-in fallback when there
-- is no SG bridge) did NOT exclude ancillary/parking inventory, unlike the rest of
-- the metrics pipeline (event_metrics, compute_event_zone_metrics both filter
-- is_ancillary). On parking-heavy NBA events the TEvo *market* get-in therefore
-- showed an off-site parking spot instead of the cheapest seat. Verified live on
-- MSG Knicks Finals G3 (tevo_event_id 3346011): market singles min was $28.60
-- ("Manhattan Premium Parking Garage - 30 MIN WALK") vs the real cheapest single
-- of $14,140; quads $56.25 vs $9,399; five_plus $42.30 vs $11,812.50. The `owned`
-- side was already clean (we hold no parking). The canonical event min
-- (event_metrics.retail_min / getin_price = $9,187.50) already excluded parking;
-- only this splits CTE was missing the filter.
--
-- The fix adds `AND is_ancillary IS NOT TRUE` to the splits `latest_per_tg` CTE.
-- No signature change.
--
-- Applied as a GUARDED IN-PLACE PATCH (read the live definition -> exact-substring
-- replace of only the splits WHERE clause -> re-create) so the other ~150 lines of
-- the function are reproduced byte-for-byte with zero transcription risk.
-- Idempotent: no-ops if the def already excludes ancillary; aborts loudly if the
-- target CTE pattern is absent (i.e. the definition drifted and a human should look).

DO $mig$
DECLARE
  v_def text;
  v_old text :=
'    WHERE event_id = p_event_id AND captured_at >= (SELECT max(captured_at) FROM public.listings_snapshots WHERE event_id = p_event_id AND captured_at > now() - interval ''7 days'') - interval ''30 minutes''
    ORDER BY tevo_ticket_group_id, captured_at DESC';
  v_fix text :=
'    WHERE event_id = p_event_id AND is_ancillary IS NOT TRUE AND captured_at >= (SELECT max(captured_at) FROM public.listings_snapshots WHERE event_id = p_event_id AND captured_at > now() - interval ''7 days'') - interval ''30 minutes''
    ORDER BY tevo_ticket_group_id, captured_at DESC';
BEGIN
  SELECT pg_get_functiondef('public.get_broker_event_page_v2(integer,integer)'::regprocedure) INTO v_def;

  IF position(v_fix in v_def) > 0 THEN
    RAISE NOTICE 'get_broker_event_page_v2 splits CTE already excludes ancillary - no-op';
    RETURN;
  END IF;

  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'splits latest_per_tg CTE pattern not found in get_broker_event_page_v2 - aborting (definition drift; patch manually)';
  END IF;

  EXECUTE replace(v_def, v_old, v_fix);
  RAISE NOTICE 'get_broker_event_page_v2 splits CTE patched to exclude ancillary/parking';
END $mig$;
